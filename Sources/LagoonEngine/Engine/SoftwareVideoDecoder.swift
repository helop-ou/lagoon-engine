import CoreMedia
import CoreVideo
import VideoToolbox
import Foundation
import Libavcodec
import Libavutil
import LagoonPixelOps

/// Software video fallback for codecs Apple does not expose through
/// VideoToolbox — VC-1/WMV3, MPEG-4 Part 2 (the Xvid/DivX envelope AVI
/// rips carry), progressive MPEG-2, VP9, and AV1 on devices without an AV1
/// hardware decoder. Each is decoded by Lagoon's pinned libavcodec, copied into
/// renderer-recommended Core Video buffers, and wrapped as ready image sample
/// buffers. AVFoundation still owns presentation, color conversion, A/V sync,
/// display matching, and output.
///
/// The accepted output is deliberately narrow: 8-bit planar/NV12 becomes
/// NV12, while little-endian 10-bit planar/P010 becomes Core Video P010.
/// Anything else fails closed instead of silently presenting incorrect color.
nonisolated final class SoftwareVideoDecoder: @unchecked Sendable {
    /// Concrete controls for the output matrix. "Source" preserves
    /// the decoded color signalling (PQ/BT.2020 for the HDR test title), while
    /// "SDR" asks VTPixelTransfer to convert to BT.709. Lossless modes use
    /// Apple's tiled lossless pixel formats; direct/linear modes remain
    /// ordinary bi-planar Core Video buffers.
    enum OutputMode: String, CaseIterable, Sendable {
        case directSource = "direct-source"
        case losslessSource = "lossless-source"
        case linearSDR = "linear-sdr"
        case losslessSDR = "lossless-sdr"
        /// The Metal kernel repacks (and, for `gpuSDR`, tone-maps) straight
        /// into the renderer's buffer: no CPU conversion, no VideoToolbox.
        /// Where Metal cannot serve the stream these fall back to
        /// their pixel-transfer equivalents.
        case gpuSource = "gpu-source"
        case gpuSDR = "gpu-sdr"

        var usesPixelTransfer: Bool {
            self == .losslessSource || self == .linearSDR || self == .losslessSDR
        }
        var usesGPU: Bool { self == .gpuSource || self == .gpuSDR }
        var usesLosslessStorage: Bool {
            self == .losslessSource || self == .losslessSDR
        }
        var convertsToSDR: Bool {
            self == .linearSDR || self == .losslessSDR || self == .gpuSDR
        }
        var pixelTransferFallback: OutputMode {
            convertsToSDR ? .losslessSDR : .losslessSource
        }

        func diagnosticName(sourceIsHDR: Bool) -> String {
            switch self {
            case .directSource:
                sourceIsHDR ? "direct-pq" : rawValue
            case .losslessSource:
                sourceIsHDR ? "lossless-pq" : rawValue
            case .gpuSource:
                sourceIsHDR ? "gpu-pq" : rawValue
            case .linearSDR, .losslessSDR, .gpuSDR:
                rawValue
            }
        }
    }

    enum DecoderError: LocalizedError {
        case codecSetup(String)
        case pixelBufferPool(OSStatus)
        case pixelBuffer(OSStatus)
        case unsupportedPixelFormat(String)
        case outputFormat(OSStatus)
        case outputSample(OSStatus)
        case pixelTransfer(OSStatus)
        case decode(Int32)

        var errorDescription: String? {
            switch self {
            case .codecSetup(let detail):
                "The software video decoder could not start (\(detail))."
            case .pixelBufferPool(let status):
                "Core Video could not create the software decode frame pool (\(status))."
            case .pixelBuffer(let status):
                "Core Video could not allocate a software-decoded frame (\(status))."
            case .unsupportedPixelFormat(let format):
                "The software video decoder produced an unsupported pixel format (\(format))."
            case .outputFormat(let status):
                "Core Media could not describe a software-decoded frame (\(status))."
            case .outputSample(let status):
                "Core Media could not wrap a software-decoded frame (\(status))."
            case .pixelTransfer(let status):
                "VideoToolbox could not prepare a software-decoded frame (\(status))."
            case .decode(let status):
                "The software video decoder failed (\(status))."
            }
        }
    }

    private struct ColorProperties {
        let primaries: CFString?
        let transfer: CFString?
        let matrix: CFString?
        let chromaLocation: CFString?
        /// HDR10 static metadata. The compressed path puts these straight
        /// into the format description; here they have to travel as buffer
        /// attachments, because the description is derived from a pixel
        /// buffer rather than built by hand.
        let masteringDisplay: Data?
        let contentLightLevel: Data?
        let ambientViewingEnvironment: Data?

        var isHDR: Bool {
            transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
                || transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG
        }

        /// What the frame is tagged as after the transfer session tone-maps it to
        /// SDR: BT.709 end to end, no HDR metadata to mislead the display.
        var sdrToneMapped: ColorProperties {
            ColorProperties(
                primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
                matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                chromaLocation: chromaLocation,
                masteringDisplay: nil,
                contentLightLevel: nil,
                ambientViewingEnvironment: nil
            )
        }
    }

    private let codecContext: UnsafeMutablePointer<AVCodecContext>
    private let frame: UnsafeMutablePointer<AVFrame>
    private let timeBase: AVRational
    private let width: Int
    private let height: Int
    private let outputBitDepth: Int
    private let pixelBufferPool: CVPixelBufferPool
    /// Non-nil when frames leave here in Apple's lossless-compressed tiled
    /// format rather than as linear planes.
    ///
    /// The renderer's power-efficient-compositing metric reached about 87%
    /// for these surfaces and 0% for the linear surfaces on the test Apple TV.
    /// That is correlation, not proof of where the work runs. A transfer is
    /// probed once at open; if the device refuses it, the linear path remains
    /// the fallback.
    private let transferSession: VTPixelTransferSession?
    private let transferOutputPool: CVPixelBufferPool?
    private let gpuConverter: MetalFrameConverter?
    private let gpuOutputPool: CVPixelBufferPool?

    /// A decoded frame, ready for the renderer. The CPU paths deliver
    /// synchronously from inside `decode`; the GPU path delivers from its
    /// own queue once the kernel has finished, in decode order.
    typealias Delivery = @Sendable (CMSampleBuffer) -> Void

    /// GPU frames in flight. The decode queue submits and moves
    /// on, so dav1d's wait and the GPU's latency overlap instead of adding;
    /// the cap keeps a slow GPU from running away with pictures.
    private let deliveryQueue = DispatchQueue(label: "ee.helop.lagoon.gpuoutput", qos: .userInitiated)
    private let sequencer = GPUDeliverySequencer(capacity: 3)
    private let failureLock = NSLock()
    private var gpuFailure: Error?
    /// What the frames leaving this decoder are tagged as. Identical to
    /// `colorProperties` except on tvOS for HDR sources, where it is the
    /// BT.709 result of the transfer-session tone map.
    private let outputProperties: ColorProperties
    /// True when HDR content leaves here as tone-mapped SDR on tvOS. In the
    /// controlled A/B, this compressed SDR path dropped fewer frames and used
    /// less memory than direct linear PQ. Its optimized-composition counter
    /// was also higher, but that metric alone does not establish the cause.
    let outputsToneMappedSDR: Bool
    private let colorProperties: ColorProperties
    private let pixelAspectRatio: (horizontal: Int32, vertical: Int32)?
    private var timeline: VideoFrameTimeline?
    private let profileLock = NSLock()
    private var profileStorage = Profile()
    private let detailedTimings: PipelineStageTimings
    private var profileStartedAt: Double?
    /// Rolling window, so the HUD can show what the decoder is managing now
    /// rather than an average dragged up by a fast start.
    private var windowStartedAt: Double?
    private var windowFrames = 0
    private static let windowSeconds = 2.0

    let formatDescription: CMVideoFormatDescription
    let usesCompressedOutput: Bool
    /// Resolved rather than merely requested, so every benchmark line proves
    /// which of the four output controls the device actually accepted.
    let outputModeName: String
    let codecName: String
    let codecLongName: String
    let lowDelayEnabled: Bool
    /// Configured dav1d option. Zero asks dav1d to select its normal delay.
    let maxFrameDelay: Int64?
    /// Frames libavcodec reports buffering after the decoder is open.
    let decoderDelay: Int32
    var gridDescription: String? { timeline?.gridDescription }

    /// Configured libavcodec thread count after opening. Zero means automatic;
    /// libavcodec does not expose dav1d's resulting worker count here.
    let resolvedThreadCount: Int32

    /// Where the software path's time goes, so nobody has to guess which stage
    /// is expensive. Cumulative since the last flush, which is every seek — the
    /// same boundary the frame-loss bench re-arms on, so a bench window and
    /// this profile describe the same stretch.
    ///
    /// `decodeSeconds` is libavcodec (dav1d's workers bill elsewhere, so on a
    /// threaded decoder this is the wait, not the work). `conversionSeconds`
    /// is everything between a decoded AVFrame and a ready `CMSampleBuffer`.
    /// Both are wall time on the decode queue, so against `elapsedSeconds`
    /// they read as the share of one core this stage holds.
    struct Profile: Equatable, Sendable {
        var frames = 0
        var packets = 0
        var decodeSeconds = 0.0
        var conversionSeconds = 0.0
        /// Of the conversion, getting a surface to write into rather than
        /// writing to it. Measured at 0.06 ms on an Apple TV: the pool
        /// recycles, so allocation is not a cost worth chasing.
        var surfaceSeconds = 0.0
        var elapsedSeconds = 0.0
        /// Frames per second over the last completed rolling window, rather
        /// than since the seek. See `recentFramesPerSecond`.
        var recentFramesPerSecond = 0.0

        /// Frames per second since the last seek.
        ///
        /// **This cannot tell a healthy pipeline from a struggling one**, and
        /// two builds of measurements were read wrongly because of it. Once the
        /// queues fill, backpressure throttles the decoder to playback rate,
        /// so a decoder with headroom to spare and one with none both settle
        /// here at the frame rate of the content. Read `decodeMilliseconds`
        /// for capacity and `recentFramesPerSecond` for what is happening now.
        var framesPerSecond: Double {
            elapsedSeconds > 0 ? Double(frames) / elapsedSeconds : 0
        }

        /// What one frame costs libavcodec, in milliseconds.
        ///
        /// The number that actually answers "does this device have the
        /// headroom", because unlike a rate it does not move when the decoder
        /// is deliberately held back. Compare against the frame budget: 41.7 ms
        /// at 23.976 fps.
        var decodeMilliseconds: Double {
            frames > 0 ? decodeSeconds / Double(frames) * 1_000 : 0
        }

        /// What one frame costs to turn into a renderer surface, in
        /// milliseconds.
        var conversionMilliseconds: Double {
            frames > 0 ? conversionSeconds / Double(frames) * 1_000 : 0
        }

        /// Of that, acquiring and locking the destination surface.
        var surfaceMilliseconds: Double {
            frames > 0 ? surfaceSeconds / Double(frames) * 1_000 : 0
        }

        /// Everything a frame costs this stage, which is what has to fit
        /// inside a frame period. Reporting decode alone read 76% of budget
        /// while the real total was over 100%, and hid the conversion for
        /// four builds.
        var frameMilliseconds: Double {
            decodeMilliseconds + conversionMilliseconds
        }

        /// Share of one core spent inside libavcodec.
        var decodeFraction: Double {
            elapsedSeconds > 0 ? decodeSeconds / elapsedSeconds : 0
        }

        /// Share of one core spent turning frames into renderer surfaces.
        var conversionFraction: Double {
            elapsedSeconds > 0 ? conversionSeconds / elapsedSeconds : 0
        }

        /// How much of a frame period the decoder is using, where 1.0 is
        /// exactly keeping up and nothing above it can hold frame rate.
        func decodeBudgetUsed(frameRate: Double) -> Double {
            guard frameRate > 0, frameMilliseconds > 0 else { return 0 }
            return frameMilliseconds / (1_000 / frameRate)
        }
    }

    /// Bytes one decoded surface occupies, for the queue limit that has to
    /// bound them (a 4K P010 frame is 23.7 MiB).
    var decodedFrameBytes: Int64 {
        DecodedFrameMemory.bytesPer420Frame(
            width: width,
            height: height,
            bitDepth: outputBitDepth
        )
    }

    var profile: Profile {
        profileLock.withLock { profileStorage }
    }

    var detailedTimingLines: [String] { detailedTimings.summaryLines() }

    func resetDetailedTimings() {
        detailedTimings.reset()
    }

    /// H.264 is accepted only when the stream is interlaced. The
    /// progressive case belongs to VideoToolbox, and keeping it out of here
    /// means a hardware description that fails to build for progressive
    /// H.264 still surfaces as the failure it is rather than quietly
    /// decoding on the CPU.
    static func supports(codecID: AVCodecID, interlaced: Bool = false) -> Bool {
        codecID == AV_CODEC_ID_VC1
            || codecID == AV_CODEC_ID_WMV3
            || codecID == AV_CODEC_ID_MPEG4
            || codecID == AV_CODEC_ID_MPEG2VIDEO
            || codecID == AV_CODEC_ID_AV1
            || codecID == AV_CODEC_ID_VP9
            || (codecID == AV_CODEC_ID_H264 && interlaced)
    }

    /// Resolves the new four-way selector while preserving the old boolean
    /// launch argument for existing scripts. The HDR-oriented aliases are
    /// accepted because those are the names used in the experiment matrix.
    static func outputMode(
        requestedValue: String?,
        legacyCompressedOutput: Bool?,
        toneMapHDRByDefault: Bool
    ) -> OutputMode {
        if let value = requestedValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
            switch value {
            case "direct-pq", "direct-source":
                return .directSource
            case "lossless-pq", "compressed-pq", "lossless-source", "compressed-source":
                return .losslessSource
            case "linear-sdr":
                return .linearSDR
            case "lossless-sdr", "compressed-sdr":
                return .losslessSDR
            case "gpu-pq", "gpu-source":
                return .gpuSource
            case "gpu-sdr":
                return .gpuSDR
            default:
                break
            }
        }
        if legacyCompressedOutput == false { return .directSource }
        return toneMapHDRByDefault ? .gpuSDR : .gpuSource
    }

    init(
        codecpar: UnsafeMutablePointer<AVCodecParameters>,
        timeBase: AVRational,
        frameRate: AVRational,
        recommendedPixelBufferAttributes: CVPixelBufferAttributes
    ) throws {
        let codecID = codecpar.pointee.codec_id
        let selectedCodec = codecID == AV_CODEC_ID_AV1
            ? avcodec_find_decoder_by_name("libdav1d")
            : avcodec_find_decoder(codecID)
        guard Self.supports(
                  codecID: codecID,
                  interlaced: FFmpegDemuxer.isInterlaced(fieldOrder: codecpar.pointee.field_order)
              ),
              let codec = selectedCodec,
              let context = avcodec_alloc_context3(codec) else {
            throw DecoderError.codecSetup("decoder unavailable")
        }
        guard avcodec_parameters_to_context(context, codecpar) >= 0 else {
            var pointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&pointer)
            throw DecoderError.codecSetup("invalid codec parameters")
        }
        context.pointee.pkt_timebase = timeBase
        // The production default is the device's active processor count; the
        // diagnostic launch argument may request zero to test dav1d auto or a
        // specific value. `drain()` and `flush()` already handle the delay
        // frame threading introduces.
        let requestedThreadCount = SoftwareDecodeThreadPolicy.resolvedThreadCount()
        context.pointee.thread_count = requestedThreadCount
        if codecID == AV_CODEC_ID_AV1 {
            // dav1d's zero/automatic frame delay is ceil(sqrt(n_threads)): only
            // three frames for the five workers exposed by the test Apple TV.
            // Exposing the full frame-context limit improved two independent
            // 4K 10-bit decode-only fixtures by 34-43% in throughput.
            // This is set on libdav1d's private AVOptions before avcodec_open2,
            // exactly where FFmpeg copies it into Dav1dSettings.
            let requestedDelay = SoftwareDecodeThreadPolicy.resolvedMaxFrameDelay(
                threadCount: requestedThreadCount
            )
            guard let privateOptions = context.pointee.priv_data,
                  av_opt_set_int(privateOptions, "max_frame_delay", requestedDelay, 0) >= 0 else {
                var pointer: UnsafeMutablePointer<AVCodecContext>? = context
                avcodec_free_context(&pointer)
                throw DecoderError.codecSetup("libdav1d max frame delay is unavailable")
            }
        }
        guard avcodec_open2(context, codec, nil) >= 0, let decodedFrame = av_frame_alloc() else {
            var pointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&pointer)
            throw DecoderError.codecSetup("libavcodec rejected the stream")
        }
        if codecID == AV_CODEC_ID_AV1 {
            Dav1dWorkerQoS.applyIfRequested()
        }

        let resolvedWidth = Int(codecpar.pointee.width)
        let resolvedHeight = Int(codecpar.pointee.height)
        guard resolvedWidth > 0, resolvedHeight > 0,
              resolvedWidth.isMultiple(of: 2), resolvedHeight.isMultiple(of: 2) else {
            var framePointer: UnsafeMutablePointer<AVFrame>? = decodedFrame
            av_frame_free(&framePointer)
            var contextPointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&contextPointer)
            throw DecoderError.codecSetup("invalid frame dimensions")
        }

        let probedPixelFormat = AVPixelFormat(rawValue: codecpar.pointee.format)
        let contextPixelFormat = context.pointee.pix_fmt
        let sourcePixelFormat = probedPixelFormat == AV_PIX_FMT_NONE
            ? contextPixelFormat
            : probedPixelFormat
        guard let resolvedBitDepth = Self.outputBitDepth(
            pixelFormat: sourcePixelFormat,
            bitsPerRawSample: codecpar.pointee.bits_per_raw_sample,
            bitsPerCodedSample: codecpar.pointee.bits_per_coded_sample,
            codecID: codecpar.pointee.codec_id
        ) else {
            var framePointer: UnsafeMutablePointer<AVFrame>? = decodedFrame
            av_frame_free(&framePointer)
            var contextPointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&contextPointer)
            let name = av_get_pix_fmt_name(sourcePixelFormat).map(String.init(cString:))
                ?? "pixel-format \(sourcePixelFormat.rawValue)"
            throw DecoderError.codecSetup("unsupported \(name)")
        }
        let fullRange = codecpar.pointee.color_range == AVCOL_RANGE_JPEG
        let outputPixelFormat: OSType = if resolvedBitDepth == 10 {
            fullRange
                ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        } else {
            fullRange
                ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        var attributes = VideoToolboxDecoder.resolvedPixelBufferAttributes(
            recommended: recommendedPixelBufferAttributes
        ).rawAttributes
        attributes[kCVPixelBufferWidthKey as String] = resolvedWidth
        attributes[kCVPixelBufferHeightKey as String] = resolvedHeight
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = outputPixelFormat
        // Without this the surface cannot be wrapped as a Metal texture and
        // the GPU conversion silently falls back to the CPU for every frame.
        attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        // Match the Core Animation compatibility hint carried by
        // VideoToolbox surfaces. It did not make Lagoon's linear buffers enter
        // the renderer's optimized-composition mode on the test Apple TV, but
        // remains part of the recommended-compatible surface description.
        attributes[kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey as String] = true
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 18,
        ]

        var createdPool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            attributes as CFDictionary,
            &createdPool
        )
        guard poolStatus == kCVReturnSuccess, let createdPool else {
            var framePointer: UnsafeMutablePointer<AVFrame>? = decodedFrame
            av_frame_free(&framePointer)
            var contextPointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&contextPointer)
            throw DecoderError.pixelBufferPool(poolStatus)
        }

        // The transfer function is what puts tvOS into HDR; the primaries and
        // matrix are left alone so the colour is as close as it can be without
        // tone mapping. Dropping the static metadata with it keeps
        // the display from being told about a master it is no longer being
        // shown in.
        let properties = ColorProperties(
            primaries: SampleBufferFactory.colorPrimaries(codecpar.pointee.color_primaries),
            transfer: SampleBufferFactory.transferFunction(codecpar.pointee.color_trc),
            matrix: SampleBufferFactory.yCbCrMatrix(codecpar.pointee.color_space),
            chromaLocation: SampleBufferFactory.chromaLocation(codecpar.pointee.chroma_location),
            masteringDisplay: SampleBufferFactory.masteringDisplayColorVolume(codecpar),
            contentLightLevel: SampleBufferFactory.contentLightLevel(codecpar),
            ambientViewingEnvironment: SampleBufferFactory.ambientViewingEnvironment(codecpar)
        )
        var prototype: CVPixelBuffer?
        let prototypeStatus = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            createdPool,
            &prototype
        )
        guard prototypeStatus == kCVReturnSuccess, let prototype else {
            var framePointer: UnsafeMutablePointer<AVFrame>? = decodedFrame
            av_frame_free(&framePointer)
            var contextPointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&contextPointer)
            throw DecoderError.pixelBuffer(prototypeStatus)
        }
        let aspect = SampleBufferFactory.pixelAspectRatio(codecpar.pointee.sample_aspect_ratio)
        Self.apply(properties, pixelAspectRatio: aspect, to: prototype)

        // Production keeps the measured tvOS choice, while the explicit
        // selector below can separate storage conversion from color
        // conversion. iOS retains source color by default.
        #if os(tvOS)
        let toneMapHDRByDefault = properties.isHDR
        #else
        let toneMapHDRByDefault = false
        #endif

        let defaults = UserDefaults.standard
        let outputModeKey = "debug.softwareDecodeOutputMode"
        let compressedOutputKey = "debug.softwareDecodeCompressedOutput"
        let legacyCompressedOutput = defaults.object(forKey: compressedOutputKey) == nil
            ? nil
            : defaults.bool(forKey: compressedOutputKey)
        var requestedOutputMode = Self.outputMode(
            requestedValue: defaults.string(forKey: outputModeKey),
            legacyCompressedOutput: legacyCompressedOutput,
            toneMapHDRByDefault: toneMapHDRByDefault
        )

        // Every transfer mode gets a distinct destination pool and one probe
        // transfer. This splits source versus SDR color from ordinary versus
        // lossless destination storage. Direct-source still differs from all
        // three controls by having no VT transfer at all; see playback.md for
        // the comparisons the matrix can and cannot isolate.
        // The GPU stage comes first: it replaces both CPU passes, and where
        // Metal cannot serve the stream the mode degrades to its transfer
        // equivalent so the matrix below still applies.
        var gpuSetup: (MetalFrameConverter, CVPixelBufferPool, CVPixelBuffer, lossless: Bool)?
        if requestedOutputMode.usesGPU {
            gpuSetup = Self.makeGPUOutput(
                mode: requestedOutputMode,
                codecpar: codecpar,
                sourcePixelFormat: sourcePixelFormat,
                width: resolvedWidth,
                height: resolvedHeight,
                fullRange: fullRange,
                properties: properties
            )
            if gpuSetup == nil {
                if defaults.object(forKey: outputModeKey) != nil {
                    var framePointer: UnsafeMutablePointer<AVFrame>? = decodedFrame
                    av_frame_free(&framePointer)
                    var contextPointer: UnsafeMutablePointer<AVCodecContext>? = context
                    avcodec_free_context(&contextPointer)
                    throw DecoderError.codecSetup(
                        "requested output mode \(requestedOutputMode.rawValue) is unavailable"
                    )
                }
                requestedOutputMode = requestedOutputMode.pixelTransferFallback
            }
        }

        var transferSetup: (VTPixelTransferSession, CVPixelBufferPool, CVPixelBuffer)?
        if requestedOutputMode.usesPixelTransfer {
            var transferAttributes = attributes
            if requestedOutputMode.usesLosslessStorage {
                let destinationIsFullRange = fullRange && !requestedOutputMode.convertsToSDR
                let losslessFormat: OSType = if resolvedBitDepth == 10 {
                    destinationIsFullRange
                        ? kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange
                        : kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange
                } else {
                    destinationIsFullRange
                        ? kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange
                        : kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange
                }
                transferAttributes = [
                    kCVPixelBufferWidthKey as String: resolvedWidth,
                    kCVPixelBufferHeightKey as String: resolvedHeight,
                    kCVPixelBufferPixelFormatTypeKey as String: losslessFormat,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                ]
            } else if requestedOutputMode.convertsToSDR {
                // The SDR lossless formats are video-range, so the ordinary
                // SDR control must use the equivalent range even if the
                // decoded source happened to be full-range.
                transferAttributes[kCVPixelBufferPixelFormatTypeKey as String] = resolvedBitDepth == 10
                    ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                    : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            }
            var sessionOut: VTPixelTransferSession?
            var poolOut: CVPixelBufferPool?
            CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                [kCVPixelBufferPoolMinimumBufferCountKey as String: 18] as CFDictionary,
                transferAttributes as CFDictionary,
                &poolOut
            )
            if let poolOut,
               VTPixelTransferSessionCreate(
                   allocator: kCFAllocatorDefault,
                   pixelTransferSessionOut: &sessionOut
               ) == noErr,
               let sessionOut {
                var sessionUsable = true
                if requestedOutputMode.convertsToSDR {
                    let destination: [(CFString, CFString)] = [
                        (kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                         kCVImageBufferColorPrimaries_ITU_R_709_2),
                        (kVTPixelTransferPropertyKey_DestinationTransferFunction,
                         kCVImageBufferTransferFunction_ITU_R_709_2),
                        (kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                         kCVImageBufferYCbCrMatrix_ITU_R_709_2),
                    ]
                    for (key, value) in destination
                    where VTSessionSetProperty(sessionOut, key: key, value: value) != noErr {
                        sessionUsable = false
                    }
                }
                var probe: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, poolOut, &probe)
                if sessionUsable,
                   let probe,
                   VTPixelTransferSessionTransferImage(sessionOut, from: prototype, to: probe) == noErr {
                    transferSetup = (sessionOut, poolOut, probe)
                } else {
                    VTPixelTransferSessionInvalidate(sessionOut)
                }
            }
        }
        if defaults.object(forKey: outputModeKey) != nil,
           requestedOutputMode.usesPixelTransfer,
           transferSetup == nil {
            var framePointer: UnsafeMutablePointer<AVFrame>? = decodedFrame
            av_frame_free(&framePointer)
            var contextPointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&contextPointer)
            throw DecoderError.codecSetup(
                "requested output mode \(requestedOutputMode.rawValue) is unavailable"
            )
        }
        let resolvedOutputMode: OutputMode = if gpuSetup != nil {
            requestedOutputMode
        } else if transferSetup == nil {
            .directSource
        } else {
            requestedOutputMode
        }
        let resolvedOutputProperties = resolvedOutputMode.convertsToSDR
            ? properties.sdrToneMapped
            : properties
        if let probe = gpuSetup?.2 ?? transferSetup?.2 {
            Self.apply(resolvedOutputProperties, pixelAspectRatio: aspect, to: probe)
        }

        let descriptionSource = gpuSetup?.2 ?? transferSetup?.2 ?? prototype
        var description: CMVideoFormatDescription?
        let descriptionStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: descriptionSource,
            formatDescriptionOut: &description
        )
        guard descriptionStatus == noErr, let description else {
            var framePointer: UnsafeMutablePointer<AVFrame>? = decodedFrame
            av_frame_free(&framePointer)
            var contextPointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&contextPointer)
            throw DecoderError.outputFormat(descriptionStatus)
        }

        transferSession = transferSetup?.0
        transferOutputPool = transferSetup?.1
        gpuConverter = gpuSetup?.0
        gpuOutputPool = gpuSetup?.1
        usesCompressedOutput = resolvedOutputMode.usesLosslessStorage || gpuSetup?.lossless == true
        outputModeName = resolvedOutputMode.diagnosticName(sourceIsHDR: properties.isHDR)
            + (gpuSetup.map { $0.lossless ? "-lossless" : "-linear" } ?? "")
        outputProperties = resolvedOutputProperties
        outputsToneMappedSDR = properties.isHDR && resolvedOutputMode.convertsToSDR
        codecContext = context
        resolvedThreadCount = context.pointee.thread_count
        codecName = codec.pointee.name.map(String.init(cString:)) ?? "unknown"
        codecLongName = codec.pointee.long_name.map(String.init(cString:)) ?? codecName
        lowDelayEnabled = (context.pointee.flags & AV_CODEC_FLAG_LOW_DELAY) != 0
        var resolvedMaxFrameDelay: Int64 = 0
        if codecID == AV_CODEC_ID_AV1,
           let privateOptions = context.pointee.priv_data,
           av_opt_get_int(privateOptions, "max_frame_delay", 0, &resolvedMaxFrameDelay) >= 0 {
            maxFrameDelay = resolvedMaxFrameDelay
        } else {
            maxFrameDelay = nil
        }
        decoderDelay = context.pointee.delay
        frame = decodedFrame
        self.timeBase = timeBase
        width = resolvedWidth
        height = resolvedHeight
        outputBitDepth = resolvedBitDepth
        pixelBufferPool = createdPool
        colorProperties = properties
        pixelAspectRatio = aspect
        timeline = VideoFrameTimeline(
            frameRateNum: frameRate.num,
            frameRateDen: frameRate.den
        )
        formatDescription = description
        detailedTimings = PipelineStageTimings(
            enabled: codecpar.pointee.codec_id == AV_CODEC_ID_AV1
                && UserDefaults.standard.bool(forKey: "debug.av1PipelineProfile")
        )
        if detailedTimings.enabled {
            print("SoftwareVideoDecoder codec=\"\(codecName)\" longName=\"\(codecLongName)\""
                + " threads=\(resolvedThreadCount) lowDelay=\(lowDelayEnabled ? "on" : "off")"
                + " maxFrameDelay=\(maxFrameDelay.map(String.init) ?? "unknown")"
                + " decoderDelay=\(decoderDelay) output=\"\(outputModeName)\""
                + (gpuConverter.map {
                    " gpuPeakNits=\($0.configuration.sourcePeakNits)->\($0.configuration.targetPeakNits)"
                } ?? ""))
        }
    }

    deinit {
        if let transferSession {
            VTPixelTransferSessionInvalidate(transferSession)
        }
        var framePointer: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&framePointer)
        var contextPointer: UnsafeMutablePointer<AVCodecContext>? = codecContext
        avcodec_free_context(&contextPointer)
    }

    /// Synchronous convenience for callers that want every frame back in
    /// hand: benchmarks and fixtures. Playback uses the delivering variant.
    func decode(packet: UnsafeMutablePointer<AVPacket>) throws -> [CMSampleBuffer] {
        let collected = CollectedFrames()
        try decode(packet: packet) { collected.append($0) }
        waitForPendingOutput()
        return collected.frames
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>, deliver: @escaping Delivery) throws {
        try rethrowGPUFailure()
        let sent = Self.now()
        beginProfileIfNeeded(at: sent)
        let status = avcodec_send_packet(codecContext, packet)
        let elapsed = Self.now()
        detailedTimings.record(.sendPacket, from: sent, to: elapsed)
        recordProfile(at: elapsed) {
            $0.packets += 1
            $0.decodeSeconds += elapsed - sent
        }
        guard status >= 0 else { throw DecoderError.decode(status) }
        try receiveFrames(deliver: deliver)
    }

    func drain() throws -> [CMSampleBuffer] {
        let collected = CollectedFrames()
        try drain { collected.append($0) }
        return collected.frames
    }

    /// End of stream: every picture libavcodec still holds comes out, and
    /// this returns only once the GPU has delivered the last of them.
    func drain(deliver: @escaping Delivery) throws {
        try rethrowGPUFailure()
        let status = avcodec_send_packet(codecContext, nil)
        guard status >= 0 else { throw DecoderError.decode(status) }
        try receiveFrames(deliver: deliver)
        waitForPendingOutput()
        try rethrowGPUFailure()
    }

    private final class CollectedFrames: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [CMSampleBuffer] = []
        var frames: [CMSampleBuffer] { lock.withLock { storage } }
        func append(_ frame: CMSampleBuffer) { lock.withLock { storage.append(frame) } }
    }

    /// GPU frames submitted and not yet delivered; the decode stage counts
    /// them as video already read.
    var pendingOutputCount: Int {
        sequencer.pendingCount
    }

    /// Blocks until every submitted GPU frame has been delivered. Bounded,
    /// because a GPU that never answers must not wedge the demux loop.
    func waitForPendingOutput() {
        sequencer.waitUntilDrained(timeout: 2)
    }

    private func rethrowGPUFailure() throws {
        if let failure = failureLock.withLock({ gpuFailure }) {
            throw failure
        }
    }

    private func recordGPUFailure(_ error: Error) {
        failureLock.withLock { gpuFailure = gpuFailure ?? error }
    }

    /// Benchmark-only sink for establishing dav1d's ceiling without Core
    /// Video allocation, P010 conversion, VideoToolbox transfer, sample
    /// wrapping, or rendering. The normal playback stage never calls this;
    /// the opt-in fixture benchmark owns a fresh decoder instance so its
    /// discard run cannot affect presentation state.
    func decodeDiscardingOutput(packet: UnsafeMutablePointer<AVPacket>) throws -> Int {
        let status = avcodec_send_packet(codecContext, packet)
        guard status >= 0 else { throw DecoderError.decode(status) }
        return receiveFramesDiscardingOutput()
    }

    /// Flushes delayed pictures for `decodeDiscardingOutput(packet:)`.
    func drainDiscardingOutput() throws -> Int {
        let status = avcodec_send_packet(codecContext, nil)
        guard status >= 0 else { throw DecoderError.decode(status) }
        return receiveFramesDiscardingOutput()
    }

    func flush() {
        waitForPendingOutput()
        avcodec_flush_buffers(codecContext)
        timeline?.reset()
        // A seek starts a new stretch of playback, which is also the boundary
        // the frame-loss bench re-arms on. Averaging across one would mix two
        // scenes into a single number, and the whole point of the profile is
        // that it describes the scene the bench is measuring.
        profileLock.withLock {
            profileStorage = Profile()
            profileStartedAt = nil
            windowStartedAt = nil
            windowFrames = 0
        }
    }

    private func receiveFrames(deliver: @escaping Delivery) throws {
        while true {
            let waited = Self.now()
            let status = avcodec_receive_frame(codecContext, frame)
            let received = Self.now()
            detailedTimings.record(.receiveFrame, from: waited, to: received)
            recordProfile(at: received) { $0.decodeSeconds += received - waited }
            guard status >= 0 else { break }
            defer { av_frame_unref(frame) }
            let buffer = try makeSampleBuffer(deliver: deliver)
            let converted = Self.now()
            detailedTimings.recordOutput(at: converted)
            recordProfile(at: converted) {
                $0.frames += 1
                $0.conversionSeconds += converted - received
            }
            if let buffer {
                deliver(buffer)
            }
        }
    }

    private func receiveFramesDiscardingOutput() -> Int {
        var frames = 0
        while avcodec_receive_frame(codecContext, frame) >= 0 {
            frames += 1
            av_frame_unref(frame)
        }
        return frames
    }

    /// Monotonic and cheap; `ProcessInfo.systemUptime` reads the same mach
    /// timebase the signposts do.
    private static func now() -> Double {
        ProcessInfo.processInfo.systemUptime
    }

    private func beginProfileIfNeeded(at instant: Double) {
        profileLock.withLock {
            if profileStartedAt == nil { profileStartedAt = instant }
        }
    }

    private func recordProfile(at instant: Double, _ body: (inout Profile) -> Void) {
        profileLock.withLock {
            let before = profileStorage.frames
            body(&profileStorage)
            if let start = profileStartedAt {
                profileStorage.elapsedSeconds = instant - start
            }
            guard profileStorage.frames > before else { return }
            windowFrames += profileStorage.frames - before
            guard let windowStart = windowStartedAt else {
                windowStartedAt = instant
                return
            }
            let span = instant - windowStart
            guard span >= Self.windowSeconds else { return }
            profileStorage.recentFramesPerSecond = Double(windowFrames) / span
            windowStartedAt = instant
            windowFrames = 0
        }
    }

    /// Returns the ready sample for the CPU paths, or nil once the frame has
    /// been handed to the GPU, which delivers it itself.
    private func makeSampleBuffer(deliver: @escaping Delivery) throws -> CMSampleBuffer? {
        let decodedFormat = AVPixelFormat(rawValue: frame.pointee.format)
        let isSupported8Bit = outputBitDepth == 8 && (
            decodedFormat == AV_PIX_FMT_YUV420P
                || decodedFormat == AV_PIX_FMT_YUVJ420P
                || decodedFormat == AV_PIX_FMT_NV12
        )
        let isSupported10Bit = outputBitDepth == 10 && (
            decodedFormat == AV_PIX_FMT_YUV420P10LE
                || decodedFormat == AV_PIX_FMT_P010LE
        )
        guard isSupported8Bit || isSupported10Bit,
              Int(frame.pointee.width) == width,
              Int(frame.pointee.height) == height else {
            let name = av_get_pix_fmt_name(decodedFormat).map(String.init(cString:)) ?? "\(frame.pointee.format)"
            throw DecoderError.unsupportedPixelFormat(name)
        }

        // An interlaced frame is made progressive before it is copied out,
        // so nothing downstream ever sees a field pair. Ten-bit
        // formats are left alone: interlaced content at that depth is not
        // something this engine has met, and guessing at one is worse than
        // the transcode the profile still asks for.
        if isSupported8Bit, frame.pointee.flags & Self.interlacedFrameFlag != 0 {
            deinterlaceInPlace(decodedFormat: decodedFormat)
        }
        // Resolve every property that belongs to the AVFrame before copying
        // its pixels. Once the copy is complete the dav1d picture can return to
        // its pool; keeping a 4K 10-bit source referenced through a synchronous
        // VT transfer needlessly adds one more ~24 MiB live picture.
        let timing = resolvedTiming()

        if let gpuConverter, let gpuOutputPool, decodedFormat == AV_PIX_FMT_YUV420P10LE {
            try submitGPUSample(converter: gpuConverter, pool: gpuOutputPool, timing: timing, deliver: deliver)
            return nil
        }

        let surfaceStart = Self.now()
        var pixelBuffer: CVPixelBuffer?
        let pixelStatus = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pixelBufferPool,
            &pixelBuffer
        )
        let surfaceAllocated = Self.now()
        detailedTimings.record(
            .pixelBufferAllocation,
            from: surfaceStart,
            to: surfaceAllocated
        )
        guard pixelStatus == kCVReturnSuccess, let pixelBuffer else {
            throw DecoderError.pixelBuffer(pixelStatus)
        }
        let lockStarted = Self.now()
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let surfaceAcquired = Self.now()
        detailedTimings.record(.pixelBufferLock, from: lockStarted, to: surfaceAcquired)
        guard lockStatus == kCVReturnSuccess else {
            throw DecoderError.pixelBuffer(lockStatus)
        }
        profileLock.withLock { profileStorage.surfaceSeconds += surfaceAcquired - surfaceStart }

        let conversionStarted = Self.now()
        let conversionEnded: Double
        do {
            // CPU ownership ends at this scope. In particular, the pixel
            // buffer must be unlocked before VideoToolbox is asked to read it;
            // holding a base-address lock across GPU/accelerator work can force
            // synchronization and was the old production behaviour.
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
            guard let sourceY = planePointer(0),
                  let destinationY = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self),
                  let destinationUV = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self) else {
                throw DecoderError.unsupportedPixelFormat("missing image planes")
            }
            if decodedFormat == AV_PIX_FMT_YUV420P10LE {
                guard let sourceU = planePointer(1), let sourceV = planePointer(2) else {
                    throw DecoderError.unsupportedPixelFormat("missing 10-bit planar chroma")
                }
                Self.convertPlanar10BitToP010(
                    sourceY: UnsafeRawPointer(sourceY).assumingMemoryBound(to: UInt16.self),
                    sourceYStride: planeStride(0),
                    sourceU: UnsafeRawPointer(sourceU).assumingMemoryBound(to: UInt16.self),
                    sourceUStride: planeStride(1),
                    sourceV: UnsafeRawPointer(sourceV).assumingMemoryBound(to: UInt16.self),
                    sourceVStride: planeStride(2),
                    destinationY: UnsafeMutableRawPointer(destinationY).assumingMemoryBound(to: UInt16.self),
                    destinationYStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
                    destinationUV: UnsafeMutableRawPointer(destinationUV).assumingMemoryBound(to: UInt16.self),
                    destinationUVStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1),
                    width: width,
                    height: height
                )
            } else if decodedFormat == AV_PIX_FMT_P010LE {
                guard let sourceUV = planePointer(1) else {
                    throw DecoderError.unsupportedPixelFormat("missing P010 chroma plane")
                }
                Self.copyRows(
                    source: sourceY,
                    sourceStride: planeStride(0),
                    destination: destinationY,
                    destinationStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
                    rowBytes: width * MemoryLayout<UInt16>.stride,
                    rows: height
                )
                Self.copyRows(
                    source: sourceUV,
                    sourceStride: planeStride(1),
                    destination: destinationUV,
                    destinationStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1),
                    rowBytes: width * MemoryLayout<UInt16>.stride,
                    rows: height / 2
                )
            } else {
                Self.copyRows(
                    source: sourceY,
                    sourceStride: planeStride(0),
                    destination: destinationY,
                    destinationStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
                    rowBytes: width,
                    rows: height
                )
            }

            if decodedFormat == AV_PIX_FMT_NV12 {
                guard let sourceUV = planePointer(1) else {
                    throw DecoderError.unsupportedPixelFormat("missing NV12 chroma plane")
                }
                Self.copyRows(
                    source: sourceUV,
                    sourceStride: planeStride(1),
                    destination: destinationUV,
                    destinationStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1),
                    rowBytes: width,
                    rows: height / 2
                )
            } else if decodedFormat == AV_PIX_FMT_YUV420P || decodedFormat == AV_PIX_FMT_YUVJ420P {
                guard let sourceU = planePointer(1), let sourceV = planePointer(2) else {
                    throw DecoderError.unsupportedPixelFormat("missing planar chroma")
                }
                Self.interleave420Chroma(
                    sourceU: sourceU,
                    sourceUStride: planeStride(1),
                    sourceV: sourceV,
                    sourceVStride: planeStride(2),
                    destination: destinationUV,
                    destinationStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1),
                    width: width,
                    rows: height / 2
                )
            }
            conversionEnded = Self.now()
        }
        detailedTimings.record(.p010Conversion, from: conversionStarted, to: conversionEnded)
        Self.apply(colorProperties, pixelAspectRatio: pixelAspectRatio, to: pixelBuffer)

        // The source picture is no longer read below this point. Releasing it
        // before a synchronous transfer reduces decoder-pool residency and can
        // let dav1d schedule the next frame sooner.
        av_frame_unref(frame)
        return try makeReadySample(from: try finished(pixelBuffer), timing: timing)
    }

    /// The source-linear surface, or the configured transfer destination.
    /// The call is synchronous from this producer's perspective; its internal
    /// execution mechanism is private. Once setup selects a transfer format,
    /// a per-frame failure must not fall back to the source buffer because the
    /// decoder's fixed format description describes the transfer output.
    private func finished(_ linear: CVPixelBuffer) throws -> CVPixelBuffer {
        guard let transferSession, let transferOutputPool else { return linear }
        var transferred: CVPixelBuffer?
        let allocationStarted = Self.now()
        let allocationStatus = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, transferOutputPool, &transferred
        )
        let allocationEnded = Self.now()
        detailedTimings.record(
            .transferOutputBufferAllocation,
            from: allocationStarted,
            to: allocationEnded
        )
        guard allocationStatus == kCVReturnSuccess, let transferred else {
            throw DecoderError.pixelBuffer(allocationStatus)
        }
        let transferStarted = Self.now()
        let transferStatus = VTPixelTransferSessionTransferImage(
            transferSession, from: linear, to: transferred
        )
        let transferEnded = Self.now()
        detailedTimings.record(.pixelTransfer, from: transferStarted, to: transferEnded)
        guard transferStatus == noErr else {
            throw DecoderError.pixelTransfer(transferStatus)
        }
        profileLock.withLock {
            profileStorage.surfaceSeconds += transferEnded - allocationStarted
        }
        Self.apply(outputProperties, pixelAspectRatio: pixelAspectRatio, to: transferred)
        return transferred
    }

    /// Presentation timing for the frame the decoder is holding. Resolved
    /// before the pixels are converted, so the CPU and GPU paths hand the same
    /// stamps to the renderer.
    private func resolvedTiming() -> CMSampleTimingInfo {
        let rawPTS = frame.pointee.best_effort_timestamp != Int64.min
            ? frame.pointee.best_effort_timestamp
            : frame.pointee.pts
        let containerSeconds: Double? = rawPTS == Int64.min
            ? nil
            : Double(rawPTS) * Double(timeBase.num) / Double(max(timeBase.den, 1))
        let exactPTS: CMTime = if let containerSeconds {
            CMTime(seconds: containerSeconds, preferredTimescale: max(timeBase.den, 1))
        } else {
            .invalid
        }
        let presentationTime = containerSeconds.flatMap { timeline?.snapped(containerSeconds: $0) }
            ?? exactPTS
        let duration: CMTime = if let timeline {
            timeline.frameDuration
        } else if frame.pointee.duration > 0 {
            CMTime(
                value: frame.pointee.duration * Int64(timeBase.num),
                timescale: max(timeBase.den, 1)
            )
        } else {
            .invalid
        }
        return CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
    }

    /// The GPU output stage: one pool allocation, one kernel dispatch, no
    /// intermediate buffer and no transfer session. The dav1d
    /// picture is kept alive by a frame reference until the kernel has read
    /// it; the sample is wrapped and delivered from the delivery queue.
    private func submitGPUSample(
        converter: MetalFrameConverter,
        pool: CVPixelBufferPool,
        timing: CMSampleTimingInfo,
        deliver: @escaping Delivery
    ) throws {
        let surfaceStart = Self.now()
        var pixelBuffer: CVPixelBuffer?
        let pixelStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        let surfaceAllocated = Self.now()
        detailedTimings.record(.pixelBufferAllocation, from: surfaceStart, to: surfaceAllocated)
        guard pixelStatus == kCVReturnSuccess, let pixelBuffer else {
            throw DecoderError.pixelBuffer(pixelStatus)
        }
        profileLock.withLock { profileStorage.surfaceSeconds += surfaceAllocated - surfaceStart }
        guard let sourceY = planePointer(0), let sourceU = planePointer(1), let sourceV = planePointer(2) else {
            throw DecoderError.unsupportedPixelFormat("missing 10-bit planar planes")
        }
        guard let held = av_frame_alloc() else { throw DecoderError.pixelBuffer(-1) }
        // The reference is what keeps the dav1d picture alive until the kernel
        // has read it. If it fails — it allocates, so it can — `held` points at
        // nothing, and freeing it later would release the frame's planes out
        // from under a running dispatch. Give up before the slot is reserved.
        let referenceStatus = av_frame_ref(held, frame)
        guard referenceStatus >= 0 else {
            var pointer: UnsafeMutablePointer<AVFrame>? = held
            av_frame_free(&pointer)
            throw DecoderError.decode(referenceStatus)
        }
        let sequence = sequencer.reserve()
        let submitted = Self.now()
        // Both of these are handed to the GPU stage and belong to this
        // dispatch alone from here on. `heldFrame` is the reference taken
        // above, owned by the Metal completion thread, which frees it the
        // moment the kernel is done reading the planes; the surface came
        // straight out of the pool a few lines up and is written by the GPU,
        // then read by the delivery queue after that completion, so the two
        // never touch it at the same time. Neither Core Video nor an FFmpeg
        // pointer is Sendable, and neither needs to be for a hand-off.
        nonisolated(unsafe) let heldFrame = held
        nonisolated(unsafe) let destination = pixelBuffer
        do {
            try converter.convertAsync(
                luma: .init(base: UnsafeRawPointer(sourceY), stride: planeStride(0), rows: height),
                cb: .init(base: UnsafeRawPointer(sourceU), stride: planeStride(1), rows: height / 2),
                cr: .init(base: UnsafeRawPointer(sourceV), stride: planeStride(2), rows: height / 2),
                into: destination
            ) { [self] result in
                var pointer: UnsafeMutablePointer<AVFrame>? = heldFrame
                av_frame_free(&pointer)
                detailedTimings.record(.gpuConversion, from: submitted, to: Self.now())
                deliveryQueue.async { [self] in
                    // The sequencer holds this until the frames before it have
                    // been delivered, so the capture of the decoder is
                    // explicit, as it is for the two closures around it.
                    sequencer.complete(sequence) { [self] in
                        switch result {
                        case .success:
                            Self.apply(outputProperties, pixelAspectRatio: pixelAspectRatio, to: destination)
                            do {
                                deliver(try makeReadySample(from: destination, timing: timing))
                            } catch {
                                recordGPUFailure(error)
                            }
                        case .failure(let error):
                            recordGPUFailure(error)
                        }
                    }
                }
            }
        } catch {
            var pointer: UnsafeMutablePointer<AVFrame>? = heldFrame
            av_frame_free(&pointer)
            sequencer.complete(sequence) {}
            throw error
        }
        let submitEnded = Self.now()
        detailedTimings.record(.p010Conversion, from: surfaceAllocated, to: submitEnded)
        av_frame_unref(frame)
    }

    /// Builds the Metal output stage when the stream is one the kernel
    /// handles: little-endian 10-bit planar 4:2:0 and, for tone mapping, PQ
    /// BT.2020. Nil means the caller falls back to VideoToolbox. Destinations
    /// are linear P010 unless `-debug.softwareDecodeGPULossless YES` asks for
    /// Apple's lossless-compressed layout, which Metal may or may not accept.
    private static func makeGPUOutput(
        mode: OutputMode,
        codecpar: UnsafeMutablePointer<AVCodecParameters>,
        sourcePixelFormat: AVPixelFormat,
        width: Int,
        height: Int,
        fullRange: Bool,
        properties: ColorProperties
    ) -> (MetalFrameConverter, CVPixelBufferPool, CVPixelBuffer, lossless: Bool)? {
        guard sourcePixelFormat == AV_PIX_FMT_YUV420P10LE else { return nil }
        if mode.convertsToSDR {
            guard properties.transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                  properties.matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 else { return nil }
        }
        let targetNits = SoftwareDecodeThreadPolicy.commandLineInteger(
            forKey: "debug.softwareDecodeTargetNits"
        ) ?? 203
        guard let converter = try? MetalFrameConverter(configuration: .init(
            width: width,
            height: height,
            fullRange: fullRange,
            toneMap: mode.convertsToSDR,
            sourcePeakNits: sourcePeakNits(codecpar),
            targetPeakNits: Float(min(max(targetNits, 100), 1000)),
            outputBitDepth: 10,
            verbose: UserDefaults.standard.bool(forKey: "debug.av1PipelineProfile")
        )) else { return nil }
        let destinationFullRange = fullRange && !mode.convertsToSDR
        let preferLossless = SoftwareDecodeThreadPolicy.commandLineString(
            forKey: "debug.softwareDecodeGPULossless"
        ).map { ["yes", "true", "1"].contains($0.lowercased()) } ?? false
        for lossless in preferLossless ? [true, false] : [false] {
            let format: OSType = if lossless {
                destinationFullRange
                    ? kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange
                    : kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange
            } else {
                destinationFullRange
                    ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                    : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            }
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey as String: true,
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                [kCVPixelBufferPoolMinimumBufferCountKey as String: 18] as CFDictionary,
                attributes as CFDictionary,
                &pool
            ) == kCVReturnSuccess, let pool else { continue }
            var probe: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &probe) == kCVReturnSuccess,
                  let probe,
                  converter.canWrite(probe) else { continue }
            // Metal accepts a lossless-compressed destination at texture
            // creation and can still refuse it at dispatch (tvOS 26 on an
            // A15 did), so that layout is proven with one real conversion
            // before it counts. Linear P010 has never needed the trial.
            if lossless, !trialConvert(converter: converter, into: probe, width: width, height: height) {
                continue
            }
            return (converter, pool, probe, lossless)
        }
        return nil
    }

    private static func trialConvert(
        converter: MetalFrameConverter,
        into probe: CVPixelBuffer,
        width: Int,
        height: Int
    ) -> Bool {
        let lumaBytes = width * height * MemoryLayout<UInt16>.stride
        let chromaBytes = (width / 2) * (height / 2) * MemoryLayout<UInt16>.stride
        let total = lumaBytes + 2 * chromaBytes
        let memory = UnsafeMutableRawPointer.allocate(byteCount: total, alignment: Int(getpagesize()))
        defer { memory.deallocate() }
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: total)
        let luma = MetalFrameConverter.Plane(
            base: UnsafeRawPointer(memory), stride: width * 2, rows: height
        )
        let cb = MetalFrameConverter.Plane(
            base: UnsafeRawPointer(memory + lumaBytes), stride: width, rows: height / 2
        )
        let cr = MetalFrameConverter.Plane(
            base: UnsafeRawPointer(memory + lumaBytes + chromaBytes), stride: width, rows: height / 2
        )
        return (try? converter.convert(luma: luma, cb: cb, cr: cr, into: probe)) != nil
    }

    /// The grade's peak: mastering-display maximum luminance, MaxCLL failing
    /// that, and the HDR10 convention of 1000 nits when the stream says
    /// nothing usable.
    static func sourcePeakNits(_ codecpar: UnsafeMutablePointer<AVCodecParameters>) -> Float {
        if let mastering: AVMasteringDisplayMetadata = SampleBufferFactory.sideData(
            codecpar, type: AV_PKT_DATA_MASTERING_DISPLAY_METADATA
        ), mastering.has_luminance != 0, mastering.max_luminance.den != 0 {
            let nits = Float(mastering.max_luminance.num) / Float(mastering.max_luminance.den)
            if nits >= 400 { return min(nits, 10000) }
        }
        if let light: AVContentLightMetadata = SampleBufferFactory.sideData(
            codecpar, type: AV_PKT_DATA_CONTENT_LIGHT_LEVEL
        ), light.MaxCLL >= 400 {
            return min(Float(light.MaxCLL), 10000)
        }
        return 1000
    }

    private func makeReadySample(
        from pixelBuffer: CVPixelBuffer,
        timing: CMSampleTimingInfo
    ) throws -> CMSampleBuffer {
        var timing = timing
        var output: CMSampleBuffer?
        let sampleStarted = Self.now()
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &output
        )
        let sampleEnded = Self.now()
        detailedTimings.record(.sampleBufferCreation, from: sampleStarted, to: sampleEnded)
        guard sampleStatus == noErr, let output else {
            throw DecoderError.outputSample(sampleStatus)
        }
        return output
    }

    /// libavutil declares these as macros, which do not reach Swift.
    private static let interlacedFrameFlag: Int32 = 1 << 3
    private static let topFieldFirstFlag: Int32 = 1 << 4

    /// Deinterlaces the decoded frame in place, before it is copied out.
    ///
    /// Only the software path has this. It is where MPEG-2 is decoded and so
    /// where DVD lives, and where interlaced H.264 is sent so
    /// that 1080i broadcast recordings direct-play; the hardware path has no
    /// deinterlacing stage, which is why the device profile still asks the
    /// server to handle interlaced HEVC.
    ///
    /// The frame is made writable first. What the decoder handed over may
    /// still be a reference frame that later pictures are predicted from, and
    /// editing that in place would corrupt everything that follows it.
    private func deinterlaceInPlace(decodedFormat: AVPixelFormat) {
        guard av_frame_make_writable(frame) >= 0 else { return }
        let topFieldFirst = frame.pointee.flags & Self.topFieldFirstFlag != 0
        guard let luma = planePointer(0) else { return }
        Deinterlacer.plane(
            base: UnsafeMutablePointer(mutating: luma),
            stride: planeStride(0),
            width: width,
            height: height,
            keepingTopField: topFieldFirst
        )
        if decodedFormat == AV_PIX_FMT_NV12 {
            guard let chroma = planePointer(1) else { return }
            // Interleaved chroma: a prediction steps two bytes at a time so
            // it never mixes a U sample with a V one.
            Deinterlacer.plane(
                base: UnsafeMutablePointer(mutating: chroma),
                stride: planeStride(1),
                width: width,
                height: height / 2,
                componentStride: 2,
                keepingTopField: topFieldFirst
            )
            return
        }
        for plane in 1...2 {
            guard let chroma = planePointer(plane) else { return }
            Deinterlacer.plane(
                base: UnsafeMutablePointer(mutating: chroma),
                stride: planeStride(plane),
                width: width / 2,
                height: height / 2,
                keepingTopField: topFieldFirst
            )
        }
    }

    private func planePointer(_ index: Int) -> UnsafePointer<UInt8>? {
        withUnsafePointer(to: frame.pointee.data) { tuple in
            UnsafeRawPointer(tuple)
                .assumingMemoryBound(to: UnsafeMutablePointer<UInt8>?.self)[index]
                .map { UnsafePointer($0) }
        }
    }

    private func planeStride(_ index: Int) -> Int {
        withUnsafePointer(to: frame.pointee.linesize) { tuple in
            Int(UnsafeRawPointer(tuple).assumingMemoryBound(to: Int32.self)[index])
        }
    }

    /// Resolves the storage contract before Core Video creates its fixed-format
    /// pool. Stream probing normally supplies the pixel format; the bit-depth
    /// fields cover containers that only declare depth. Legacy codecs are
    /// intrinsically 8-bit inside Lagoon's advertised envelope.
    static func outputBitDepth(
        pixelFormat: AVPixelFormat,
        bitsPerRawSample: Int32,
        bitsPerCodedSample: Int32,
        codecID: AVCodecID
    ) -> Int? {
        switch pixelFormat {
        case AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUVJ420P, AV_PIX_FMT_NV12:
            return 8
        case AV_PIX_FMT_YUV420P10LE, AV_PIX_FMT_P010LE:
            return 10
        default:
            let declared = bitsPerRawSample > 0 ? bitsPerRawSample : bitsPerCodedSample
            if declared > 0, declared <= 8 { return 8 }
            if declared > 8, declared <= 10 { return 10 }
            if codecID == AV_CODEC_ID_VC1
                || codecID == AV_CODEC_ID_WMV3
                || codecID == AV_CODEC_ID_MPEG4
                || codecID == AV_CODEC_ID_MPEG2VIDEO {
                return 8
            }
            return nil
        }
    }

    /// Splits a plane's rows across cores.
    ///
    /// The primitives below are NEON but single-threaded. Row ranges are
    /// independent, so this needs no coordination beyond the split, and a
    /// negative stride is not a special case: the caller has already pointed
    /// the base at the last row.
    ///
    /// Worth 0.5 ms of a 4.8 ms conversion on an Apple TV, measured — only
    /// that much because the copy is bandwidth-bound, not core-bound. Chunks
    /// stay below the core count for the same reason: these threads compete
    /// with dav1d's.
    private static let conversionChunks: Int = {
        let override = SoftwareDecodeThreadPolicy.commandLineInteger(
            forKey: "debug.softwareDecodeConvertChunks"
        )
        if let override, override > 0 { return min(override, 8) }
        return min(max(ProcessInfo.processInfo.activeProcessorCount / 2, 1), 3)
    }()

    static func parallelRows(_ rows: Int, _ body: (_ start: Int, _ count: Int) -> Void) {
        // Below a few hundred rows the split costs more than it saves.
        let chunks = min(conversionChunks, max(rows / 128, 1))
        guard chunks > 1 else {
            body(0, rows)
            return
        }
        let perChunk = (rows + chunks - 1) / chunks
        DispatchQueue.concurrentPerform(iterations: chunks) { index in
            let start = index * perChunk
            guard start < rows else { return }
            body(start, min(perChunk, rows - start))
        }
    }

    static func copyRows(
        source: UnsafePointer<UInt8>,
        sourceStride: Int,
        destination: UnsafeMutablePointer<UInt8>,
        destinationStride: Int,
        rowBytes: Int,
        rows: Int
    ) {
        let firstSource = sourceStride >= 0
            ? source
            : source.advanced(by: (rows - 1) * -sourceStride)
        for row in 0..<rows {
            memcpy(
                destination.advanced(by: row * destinationStride),
                firstSource.advanced(by: row * sourceStride),
                rowBytes
            )
        }
    }

    static func interleave420Chroma(
        sourceU: UnsafePointer<UInt8>,
        sourceUStride: Int,
        sourceV: UnsafePointer<UInt8>,
        sourceVStride: Int,
        destination: UnsafeMutablePointer<UInt8>,
        destinationStride: Int,
        width: Int,
        rows: Int
    ) {
        let firstU = sourceUStride >= 0
            ? sourceU
            : sourceU.advanced(by: (rows - 1) * -sourceUStride)
        let firstV = sourceVStride >= 0
            ? sourceV
            : sourceV.advanced(by: (rows - 1) * -sourceVStride)
        parallelRows(rows) { start, count in
            lagoon_interleave_420_chroma(
                firstU.advanced(by: start * sourceUStride),
                sourceUStride,
                firstV.advanced(by: start * sourceVStride),
                sourceVStride,
                destination.advanced(by: start * destinationStride),
                destinationStride,
                width,
                count
            )
        }
    }

    static func shift10BitPlaneToP010(
        source: UnsafePointer<UInt16>,
        sourceStride: Int,
        destination: UnsafeMutablePointer<UInt16>,
        destinationStride: Int,
        width: Int,
        rows: Int
    ) {
        let firstSource: UnsafePointer<UInt16> = if sourceStride >= 0 {
            source
        } else {
            UnsafeRawPointer(source)
                .advanced(by: (rows - 1) * -sourceStride)
                .assumingMemoryBound(to: UInt16.self)
        }
        parallelRows(rows) { start, count in
            lagoon_shift_10bit_plane_to_p010(
                UnsafeRawPointer(firstSource)
                    .advanced(by: start * sourceStride)
                    .assumingMemoryBound(to: UInt16.self),
                sourceStride,
                UnsafeMutableRawPointer(destination)
                    .advanced(by: start * destinationStride)
                    .assumingMemoryBound(to: UInt16.self),
                destinationStride,
                width,
                count
            )
        }
    }

    static func interleave420Chroma10BitToP010(
        sourceU: UnsafePointer<UInt16>,
        sourceUStride: Int,
        sourceV: UnsafePointer<UInt16>,
        sourceVStride: Int,
        destination: UnsafeMutablePointer<UInt16>,
        destinationStride: Int,
        width: Int,
        rows: Int
    ) {
        let firstU: UnsafePointer<UInt16> = if sourceUStride >= 0 {
            sourceU
        } else {
            UnsafeRawPointer(sourceU)
                .advanced(by: (rows - 1) * -sourceUStride)
                .assumingMemoryBound(to: UInt16.self)
        }
        let firstV: UnsafePointer<UInt16> = if sourceVStride >= 0 {
            sourceV
        } else {
            UnsafeRawPointer(sourceV)
                .advanced(by: (rows - 1) * -sourceVStride)
                .assumingMemoryBound(to: UInt16.self)
        }
        parallelRows(rows) { start, count in
            lagoon_interleave_420_chroma_10bit_to_p010(
                UnsafeRawPointer(firstU)
                    .advanced(by: start * sourceUStride)
                    .assumingMemoryBound(to: UInt16.self),
                sourceUStride,
                UnsafeRawPointer(firstV)
                    .advanced(by: start * sourceVStride)
                    .assumingMemoryBound(to: UInt16.self),
                sourceVStride,
                UnsafeMutableRawPointer(destination)
                    .advanced(by: start * destinationStride)
                    .assumingMemoryBound(to: UInt16.self),
                destinationStride,
                width,
                count
            )
        }
    }

    /// Converts all three planar 10-bit source planes into P010 with one
    /// parallel dispatch. The old path called the luma and chroma helpers
    /// separately, paying two `concurrentPerform` barriers per 4K frame even
    /// though both operations are independent and use the same chunk count.
    /// Keeping both kernels in each worker also reduces scheduler traffic
    /// while preserving the hand-written NEON loops in `LagoonPixelOps`.
    static func convertPlanar10BitToP010(
        sourceY: UnsafePointer<UInt16>,
        sourceYStride: Int,
        sourceU: UnsafePointer<UInt16>,
        sourceUStride: Int,
        sourceV: UnsafePointer<UInt16>,
        sourceVStride: Int,
        destinationY: UnsafeMutablePointer<UInt16>,
        destinationYStride: Int,
        destinationUV: UnsafeMutablePointer<UInt16>,
        destinationUVStride: Int,
        width: Int,
        height: Int
    ) {
        guard width > 0, height > 0 else { return }
        let chromaRows = height / 2
        let firstY: UnsafePointer<UInt16> = if sourceYStride >= 0 {
            sourceY
        } else {
            UnsafeRawPointer(sourceY)
                .advanced(by: (height - 1) * -sourceYStride)
                .assumingMemoryBound(to: UInt16.self)
        }
        let firstU: UnsafePointer<UInt16> = if sourceUStride >= 0 || chromaRows == 0 {
            sourceU
        } else {
            UnsafeRawPointer(sourceU)
                .advanced(by: (chromaRows - 1) * -sourceUStride)
                .assumingMemoryBound(to: UInt16.self)
        }
        let firstV: UnsafePointer<UInt16> = if sourceVStride >= 0 || chromaRows == 0 {
            sourceV
        } else {
            UnsafeRawPointer(sourceV)
                .advanced(by: (chromaRows - 1) * -sourceVStride)
                .assumingMemoryBound(to: UInt16.self)
        }

        let chunks = min(conversionChunks, max(height / 128, 1))
        let convertChunk: (Int) -> Void = { index in
            let lumaStart = height * index / chunks
            let lumaEnd = height * (index + 1) / chunks
            lagoon_shift_10bit_plane_to_p010(
                UnsafeRawPointer(firstY)
                    .advanced(by: lumaStart * sourceYStride)
                    .assumingMemoryBound(to: UInt16.self),
                sourceYStride,
                UnsafeMutableRawPointer(destinationY)
                    .advanced(by: lumaStart * destinationYStride)
                    .assumingMemoryBound(to: UInt16.self),
                destinationYStride,
                width,
                lumaEnd - lumaStart
            )

            let chromaStart = chromaRows * index / chunks
            let chromaEnd = chromaRows * (index + 1) / chunks
            guard chromaEnd > chromaStart else { return }
            lagoon_interleave_420_chroma_10bit_to_p010(
                UnsafeRawPointer(firstU)
                    .advanced(by: chromaStart * sourceUStride)
                    .assumingMemoryBound(to: UInt16.self),
                sourceUStride,
                UnsafeRawPointer(firstV)
                    .advanced(by: chromaStart * sourceVStride)
                    .assumingMemoryBound(to: UInt16.self),
                sourceVStride,
                UnsafeMutableRawPointer(destinationUV)
                    .advanced(by: chromaStart * destinationUVStride)
                    .assumingMemoryBound(to: UInt16.self),
                destinationUVStride,
                width,
                chromaEnd - chromaStart
            )
        }
        if chunks == 1 {
            convertChunk(0)
        } else {
            DispatchQueue.concurrentPerform(iterations: chunks) { index in
                convertChunk(index)
            }
        }
    }

    private static func apply(
        _ properties: ColorProperties,
        pixelAspectRatio: (horizontal: Int32, vertical: Int32)?,
        to pixelBuffer: CVPixelBuffer
    ) {
        if let pixelAspectRatio {
            // `CMVideoFormatDescriptionCreateForImageBuffer` reads this back
            // off the buffer, so the description built from the prototype
            // carries the same geometry the compressed path advertises.
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferPixelAspectRatioKey,
                [
                    kCVImageBufferPixelAspectRatioHorizontalSpacingKey: pixelAspectRatio.horizontal,
                    kCVImageBufferPixelAspectRatioVerticalSpacingKey: pixelAspectRatio.vertical,
                ] as CFDictionary,
                .shouldPropagate
            )
        } else {
            CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferPixelAspectRatioKey)
        }
        if let primaries = properties.primaries {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferColorPrimariesKey,
                primaries,
                .shouldPropagate
            )
        } else {
            CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey)
        }
        if let transfer = properties.transfer {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferTransferFunctionKey,
                transfer,
                .shouldPropagate
            )
        } else {
            CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey)
        }
        if let matrix = properties.matrix {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferYCbCrMatrixKey,
                matrix,
                .shouldPropagate
            )
        } else {
            CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey)
        }
        if let chromaLocation = properties.chromaLocation {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferChromaLocationTopFieldKey,
                chromaLocation,
                .shouldPropagate
            )
        } else {
            CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferChromaLocationTopFieldKey)
        }
        // HDR10 static metadata. The transfer function alone is what switches
        // tvOS into HDR, but without these the display tone-maps from its own
        // defaults instead of the master's — and the codecs that reach this
        // path (VP9 always, AV1 wherever there is no hardware decoder) are
        // advertised for HDR10/HLG/HDR10+ in `DeviceProfile`.
        //
        // `CMVideoFormatDescriptionCreateForImageBuffer` copies propagated
        // attachments into the description's extensions, and these three
        // CVBuffer keys are the same strings as their CMFormatDescription
        // counterparts, so the prototype carries them into the format
        // description and every decoded frame carries them to the renderer.
        if let masteringDisplay = properties.masteringDisplay {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferMasteringDisplayColorVolumeKey,
                masteringDisplay as CFData,
                .shouldPropagate
            )
        } else {
            CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferMasteringDisplayColorVolumeKey)
        }
        if let contentLightLevel = properties.contentLightLevel {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferContentLightLevelInfoKey,
                contentLightLevel as CFData,
                .shouldPropagate
            )
        } else {
            CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferContentLightLevelInfoKey)
        }
        if let ambientViewingEnvironment = properties.ambientViewingEnvironment {
            // Apple TN3145: custom sample-buffer playback has to carry `amve`
            // through to presentation for correct HDR adaptation.
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferAmbientViewingEnvironmentKey,
                ambientViewingEnvironment as CFData,
                .shouldPropagate
            )
        } else {
            CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferAmbientViewingEnvironmentKey)
        }
        if properties.transfer == kCVImageBufferTransferFunction_ITU_R_709_2 {
            // An ICC profile or gamma value can override/conflict with the
            // explicit BT.709 transfer description. The source path does not
            // create either, but VT is allowed to propagate unknown source
            // attachments, so make the SDR contract unambiguous.
            CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferICCProfileKey)
            CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferGammaLevelKey)
        }
    }
}
