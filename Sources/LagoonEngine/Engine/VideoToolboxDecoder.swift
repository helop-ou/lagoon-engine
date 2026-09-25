import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware-decodes the demuxer's compressed video samples.
///
/// Given compressed 4K Main10 directly, `AVSampleBufferVideoRenderer` missed
/// deadlines even with a full queue, so this decodes ahead and hands it
/// IOSurface-backed frames.
nonisolated final class VideoToolboxDecoder: @unchecked Sendable {
    enum DecoderError: LocalizedError {
        case sessionCreation(OSStatus)
        case decode(OSStatus)
        case outputFormat(OSStatus)
        case outputSample(OSStatus)

        var errorDescription: String? {
            switch self {
            case .sessionCreation(let status):
                "VideoToolbox could not create a hardware decoder (\(status))."
            case .decode(let status):
                "VideoToolbox could not decode a video frame (\(status))."
            case .outputFormat(let status):
                "VideoToolbox produced an unsupported image format (\(status))."
            case .outputSample(let status):
                "VideoToolbox could not wrap a decoded video frame (\(status))."
            }
        }

        /// The status VideoToolbox reported. Often what tells a dead session
        /// from a dead stream.
        var status: OSStatus {
            switch self {
            case .sessionCreation(let status),
                 .decode(let status),
                 .outputFormat(let status),
                 .outputSample(let status):
                status
            }
        }
    }

    typealias OutputHandler = @Sendable (CMSampleBuffer) -> Void
    typealias ErrorHandler = @Sendable (DecoderError) -> Void

    private let formatDescription: CMVideoFormatDescription
    /// False only for AV1 without AV1 silicon, so Apple's software decoder
    /// may answer.
    let requiresHardware: Bool
    private let imageBufferAttributes: CFDictionary
    private let ambientViewingEnvironment: Data?
    private let outputHandler: OutputHandler
    private let errorHandler: ErrorHandler
    private let stateLock = NSLock()
    private var acceptingOutput = true
    private var recoverableFrameErrorCount = 0
    private var corruptFrames = PlaybackCorruptFramePolicy.State()
    private var presentationQueue: VideoPresentationOrderQueue<CMSampleBuffer>
    private var session: VTDecompressionSession?
    /// Six covers common HEVC B-pyramids; a larger container-reported depth
    /// is honoured, up to a bound.
    let reorderDepth: Int

    /// A missing reference drops one access unit, not the session. It is
    /// common in HEVC preroll after a seek; treating it as fatal aborted
    /// playable titles after scrubs and track changes.
    var droppedFrameCount: Int {
        stateLock.withLock { recoverableFrameErrorCount }
    }

    /// Pictures dropped as damage in a stream that otherwise decodes; see
    /// `PlaybackCorruptFramePolicy`.
    var corruptFrameCount: Int {
        stateLock.withLock { corruptFrames.dropped }
    }

    /// Whether VideoToolbox can create a session for this stream at all,
    /// hardware or software. `VTIsHardwareDecodeSupported` only reports
    /// silicon. (AV1 on an A15 has neither and fails with -12906.)
    static func canDecode(_ formatDescription: CMVideoFormatDescription) -> Bool {
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        return status == noErr && session != nil
    }

    static func isRecoverableFrameError(_ status: OSStatus) -> Bool {
        status == kVTVideoDecoderReferenceMissingErr
    }

    /// VideoToolbox reports a damaged picture either from the decode call or
    /// in the callback, so both ask here.
    private func absorbsDamagedFrame(_ status: OSStatus) -> Bool {
        guard status == kVTVideoDecoderBadDataErr else { return false }
        return stateLock.withLock { corruptFrames.absorbsDamagedFrame() }
    }

    /// Whether a status is about the decode *session*, not the samples. The
    /// fix is a new session, never the ladder's transcode rung.
    ///
    /// `isRecoverableFrameError` is different: one bad access unit in a live
    /// session.
    static func isSessionFault(_ status: OSStatus) -> Bool {
        status == kVTInvalidSessionErr
            || status == kVTVideoDecoderMalfunctionErr
            || status == kVTVideoDecoderNotAvailableNowErr
    }

    public init(
        formatDescription: CMVideoFormatDescription,
        recommendedPixelBufferAttributes: CVPixelBufferAttributes,
        reportedReorderDepth: Int,
        requiresHardware: Bool = true,
        outputHandler: @escaping OutputHandler,
        errorHandler: @escaping ErrorHandler
    ) throws {
        self.requiresHardware = requiresHardware
        self.formatDescription = formatDescription
        let resolvedAttributes = Self.resolvedPixelBufferAttributes(
            recommended: recommendedPixelBufferAttributes
        )
        imageBufferAttributes = resolvedAttributes.rawAttributes as CFDictionary
        ambientViewingEnvironment = CMFormatDescriptionGetExtension(
            formatDescription,
            extensionKey: kCMFormatDescriptionExtension_AmbientViewingEnvironment
        ) as? Data
        reorderDepth = min(max(reportedReorderDepth, 6), 16)
        presentationQueue = VideoPresentationOrderQueue(depth: reorderDepth)
        self.outputHandler = outputHandler
        self.errorHandler = errorHandler
        session = try Self.makeSession(
            formatDescription: formatDescription,
            imageBufferAttributes: imageBufferAttributes,
            requiresHardware: requiresHardware,
            owner: self
        )
    }

    /// Submits one access unit. Uses the session callback with temporal
    /// processing; the per-frame handler API does not promise display order.
    func decode(_ sampleBuffer: CMSampleBuffer) throws {
        guard let session else {
            throw DecoderError.sessionCreation(kVTInvalidSessionErr)
        }
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableTemporalProcessing],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        guard status == noErr || absorbsDamagedFrame(status) else { throw DecoderError.decode(status) }
    }

    /// Seek: recreates the session so the next keyframe starts clean.
    func reset() throws {
        stateLock.withLock {
            acceptingOutput = false
            presentationQueue.reset()
            corruptFrames.reset()
        }
        discardSession()
        session = try Self.makeSession(
            formatDescription: formatDescription,
            imageBufferAttributes: imageBufferAttributes,
            requiresHardware: requiresHardware,
            owner: self
        )
        stateLock.withLock { acceptingOutput = true }
    }

    /// Emits frames retained for presentation-order processing before EOF.
    func finish() throws {
        guard let session else { return }
        // Temporal processing may retain frames; finish before waiting.
        let finishStatus = VTDecompressionSessionFinishDelayedFrames(session)
        guard finishStatus == noErr else { throw DecoderError.decode(finishStatus) }
        let waitStatus = VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard waitStatus == noErr else { throw DecoderError.decode(waitStatus) }
        drainPresentationQueue()
    }

    func invalidate() {
        stateLock.withLock {
            acceptingOutput = false
            presentationQueue.reset()
        }
        discardSession()
    }

    deinit {
        discardSession()
    }

    private static func makeSession(
        formatDescription: CMVideoFormatDescription,
        imageBufferAttributes: CFDictionary,
        requiresHardware: Bool,
        owner: VideoToolboxDecoder
    ) throws -> VTDecompressionSession {
        // Require hardware: failing beats silently decoding 4K Main10 on the
        // CPU. Except AV1 without silicon, where Apple's software decoder
        // beats the libdav1d alternative.
        let decoderSpecification: CFDictionary? = requiresHardware
            ? [
                kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true
            ] as CFDictionary
            : nil
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { outputRefcon, _, status, _, imageBuffer, pts, duration in
                guard let outputRefcon else { return }
                let decoder = Unmanaged<VideoToolboxDecoder>
                    .fromOpaque(outputRefcon)
                    .takeUnretainedValue()
                decoder.receive(
                    status: status,
                    imageBuffer: imageBuffer,
                    presentationTimeStamp: pts,
                    duration: duration
                )
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(owner).toOpaque()
        )
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpecification,
            imageBufferAttributes: imageBufferAttributes,
            outputCallback: &callback,
            decompressionSessionOut: &created
        )
        guard status == noErr, let created else {
            throw DecoderError.sessionCreation(status)
        }
        return created
    }

    /// The renderer's preferred attributes plus this path's two requirements.
    /// Pixel format stays open so native 8/10-bit and HDR survive.
    static func resolvedPixelBufferAttributes(
        recommended: CVPixelBufferAttributes
    ) -> CVPixelBufferAttributes {
        var required = CVPixelBufferAttributes(compatibility: [.metalTexture])
        required.backing = .ioSurface
        return CVPixelBufferAttributes(merging: [recommended, required]) ?? required
    }

    /// Stops the old callback generation before a new session emits, so a
    /// pre-seek frame cannot race into the reset queue.
    private func discardSession() {
        guard let session else { return }
        self.session = nil
        _ = VTDecompressionSessionFinishDelayedFrames(session)
        _ = VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
    }

    private func receive(
        status: OSStatus,
        imageBuffer: CVImageBuffer?,
        presentationTimeStamp: CMTime,
        duration: CMTime
    ) {
        guard stateLock.withLock({ acceptingOutput }) else { return }
        guard status == noErr else {
            if Self.isRecoverableFrameError(status) {
                stateLock.withLock { recoverableFrameErrorCount += 1 }
                return
            }
            if absorbsDamagedFrame(status) { return }
            errorHandler(.decode(status))
            return
        }
        // Nil with no error is suppressed output (e.g. a leading frame after
        // a seek), not a failure.
        guard let imageBuffer else { return }
        stateLock.withLock { corruptFrames.recordDecoded() }
        var outputFormat: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &outputFormat
        )
        guard formatStatus == noErr, let outputFormat else {
            errorHandler(.outputFormat(formatStatus))
            return
        }
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var output: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: outputFormat,
            sampleTiming: &timing,
            sampleBufferOut: &output
        )
        guard sampleStatus == noErr, let output else {
            errorHandler(.outputSample(sampleStatus))
            return
        }
        if let ambientViewingEnvironment {
            // Fallback on the sample (TN3145), since the pixel buffer may not
            // be modifiable.
            CMSetAttachment(
                output,
                key: kCVImageBufferAmbientViewingEnvironmentKey,
                value: ambientViewingEnvironment as CFData,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }
        enqueueForPresentation(output)
    }

    /// Callbacks are not ordered. Holds the codec's reorder depth and
    /// releases the smallest PTS.
    private func enqueueForPresentation(_ buffer: CMSampleBuffer) {
        stateLock.withLock {
            guard acceptingOutput else { return }
            if let ready = presentationQueue.append(
                buffer,
                presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(buffer)
            ) {
                outputHandler(ready)
            }
        }
    }

    private func drainPresentationQueue() {
        stateLock.withLock {
            for buffer in presentationQueue.drain() {
                outputHandler(buffer)
            }
        }
    }
}

/// Presentation-order lookahead. A sequence number breaks ties so duplicate
/// or invalid timestamps stay deterministic.
nonisolated struct VideoPresentationOrderQueue<Element> {
    private struct Entry {
        let value: Element
        let presentationTimeStamp: CMTime
        let sequence: Int
    }

    let depth: Int
    private var entries: [Entry] = []
    private var nextSequence = 0

    public init(depth: Int) {
        self.depth = max(depth, 0)
    }

    mutating func append(_ value: Element, presentationTimeStamp: CMTime) -> Element? {
        entries.append(Entry(
            value: value,
            presentationTimeStamp: presentationTimeStamp,
            sequence: nextSequence
        ))
        nextSequence += 1
        entries.sort(by: Self.precedes)
        return entries.count > depth ? entries.removeFirst().value : nil
    }

    mutating func drain() -> [Element] {
        entries.sort(by: Self.precedes)
        let values = entries.map(\.value)
        reset()
        return values
    }

    mutating func reset() {
        entries.removeAll()
        nextSequence = 0
    }

    private static func precedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
        let left = lhs.presentationTimeStamp
        let right = rhs.presentationTimeStamp
        if left.isValid, right.isValid {
            let comparison = CMTimeCompare(left, right)
            return comparison == 0 ? lhs.sequence < rhs.sequence : comparison < 0
        }
        if left.isValid != right.isValid { return left.isValid }
        return lhs.sequence < rhs.sequence
    }
}
