import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware-decodes the compressed video samples produced by the demuxer.
///
/// `AVSampleBufferVideoRenderer` can accept compressed samples directly, but
/// on full-raster 4K Main10 that path was missing presentation deadlines even
/// with a permanently full input queue. Decoding ahead here keeps the Lagoon
/// engine, synchronizer, transport, tracks, and subtitle pipeline intact while
/// handing the renderer ready-to-display IOSurface-backed frames.
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

        /// The status VideoToolbox reported, whichever stage produced it.
        /// Every case carries one, and what it says is often the difference
        /// between a dead session and a dead stream.
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
    /// False only for AV1 where the device has no AV1 silicon, so that Apple's
    /// software decoder is allowed to answer instead of the session being
    /// refused.
    let requiresHardware: Bool
    private let imageBufferAttributes: CFDictionary
    private let ambientViewingEnvironment: Data?
    private let outputHandler: OutputHandler
    private let errorHandler: ErrorHandler
    private let stateLock = NSLock()
    private var acceptingOutput = true
    private var recoverableFrameErrorCount = 0
    private var presentationQueue: VideoPresentationOrderQueue<CMSampleBuffer>
    private var session: VTDecompressionSession?
    /// Six covers hierarchical B-frame ladders used by the HEVC encoders in
    /// the supported envelope; honor a larger depth when the container's
    /// codec parameters explicitly report one, with a defensive upper bound.
    let reorderDepth: Int

    /// A missing reference is scoped to the access unit reported by the
    /// callback. It is common in HEVC preroll after a random-access seek:
    /// later pictures (or the next IRAP) can still decode in the same
    /// session. Treating it as a session failure made an otherwise playable
    /// title abort after intro skips, scrubs, and audio-track changes.
    var droppedFrameCount: Int {
        stateLock.withLock { recoverableFrameErrorCount }
    }

    /// Whether VideoToolbox will actually give us a decoder for this stream.
    ///
    /// Not the question `VTIsHardwareDecodeSupported` answers. That reports
    /// silicon; this reports whether a session can be created at all, which is
    /// what the caller actually needs to know before committing a stream to
    /// the compressed path. The two differ for AV1 on an A15: no hardware, and
    /// no software decoder behind it either, so the session is refused with
    /// -12906 whether or not hardware is required.
    ///
    /// Asked with no specification and no callback, so it answers for the
    /// decoder itself rather than for any particular configuration of it.
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

    /// Whether a status is about the decode *session* rather than the samples
    /// it was handed.
    ///
    /// `kVTInvalidSessionErr` is the session having gone away underneath us:
    /// the system reclaims decoders, and a sample in flight when it does
    /// reports this. The other two are the decoder declining to work rather
    /// than declining this bitstream — a malfunction, and a decoder the
    /// system will not hand out at this moment. Apple's answer to all three
    /// is a new session, and not one of them is a statement about the
    /// samples, so none is grounds for the ladder's one-way transcode rung.
    ///
    /// Distinct from `isRecoverableFrameError` above, which is about a single
    /// access unit inside a session that is still perfectly alive.
    static func isSessionFault(_ status: OSStatus) -> Bool {
        status == kVTInvalidSessionErr
            || status == kVTVideoDecoderMalfunctionErr
            || status == kVTVideoDecoderNotAvailableNowErr
    }

    init(
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

    /// Submits one compressed access unit. The session-level callback is
    /// intentional: Apple's per-frame output-handler API explicitly does not
    /// promise display-order callbacks. Temporal processing on the session
    /// callback lets VideoToolbox retain and emit reordered codecs by PTS.
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
        guard status == noErr else { throw DecoderError.decode(status) }
    }

    /// A seek must discard the decoder's reference frames along with the
    /// render queues. Recreating the session guarantees the next keyframe
    /// starts a clean dependency chain.
    func reset() throws {
        stateLock.withLock {
            acceptingOutput = false
            presentationQueue.reset()
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
        // Temporal processing permits VideoToolbox to retain frames
        // indefinitely. Apple requires an explicit finish before waiting.
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
        // Failure is preferable to silently moving 4K Main10 onto a software
        // decoder. All video formats Lagoon advertises here are supported by
        // the Apple TV hardware decoder.
        //
        // The exception is AV1 on a device with no AV1 silicon.
        // There the alternative is not a better decoder but libdav1d on the
        // CPU, so Apple's own software decoder is worth having if it exists,
        // and requiring hardware would refuse it.
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

    /// Reconcile AVSampleBufferVideoRenderer's tvOS 26 preferences with the
    /// two hard requirements of this path. Pixel format remains unconstrained
    /// so VideoToolbox can preserve native 8/10-bit and HDR output.
    static func resolvedPixelBufferAttributes(
        recommended: CVPixelBufferAttributes
    ) -> CVPixelBufferAttributes {
        var required = CVPixelBufferAttributes(compatibility: [.metalTexture])
        required.backing = .ioSurface
        return CVPixelBufferAttributes(merging: [recommended, required]) ?? required
    }

    /// Stop the old callback generation completely before a new session is
    /// allowed to emit. This prevents a frame decoded before a seek from
    /// racing into the new presentation queue after it has been reset.
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
            errorHandler(.decode(status))
            return
        }
        // A nil image with no error is VideoToolbox intentionally
        // suppressing output (for example, an undecodable leading frame
        // immediately after a seek), not a failed decoder session.
        guard let imageBuffer else { return }
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
            // VideoToolbox normally propagates this from the source format.
            // Attach it to the sample as an explicit fallback, which TN3145
            // permits and which avoids mutating a non-modifiable pixel buffer.
            CMSetAttachment(
                output,
                key: kCVImageBufferAmbientViewingEnvironmentKey,
                value: ambientViewingEnvironment as CFData,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }
        enqueueForPresentation(output)
    }

    /// VideoToolbox's callbacks are not an ordering contract. Keep exactly
    /// the codec's reorder lookahead, then release the smallest PTS. This is
    /// both stricter and dramatically smaller than buffering a GOP.
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

/// Small, testable presentation-order lookahead. Sequence breaks ties so
/// duplicate/invalid timestamps remain deterministic instead of depending on
/// the standard library sort implementation.
nonisolated struct VideoPresentationOrderQueue<Element> {
    private struct Entry {
        let value: Element
        let presentationTimeStamp: CMTime
        let sequence: Int
    }

    let depth: Int
    private var entries: [Entry] = []
    private var nextSequence = 0

    init(depth: Int) {
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
