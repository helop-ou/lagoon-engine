import CoreMedia
import CoreVideo
import Foundation
import Libavcodec
import Libavformat
import Libavutil

// Thin wrapper over libavformat. All methods must be called on
// the engine's demux queue; nothing here is thread-safe on its own.
//
// FFmpeg imports as raw C: pointers, manual unref, sentinel values. The
// sentinels are redefined locally because their macros don't import.
/// Where a container decides its own timeline begins.
///
/// MP4, Matroska and Jellyfin's fMP4 all start at zero, so this never came up
/// until a disc did: MPEG-TS begins wherever the muxer felt like, and
/// WALL·E's Blu-ray starts at 4198 s. Everything above the demuxer expects
/// media time from zero, so the origin is subtracted from every packet and
/// added back onto every seek.
nonisolated enum ContainerTimeline {
    /// AV_TIME_BASE, the unit `AVFormatContext.start_time` is expressed in.
    static let microsecondsPerSecond = 1_000_000.0

    /// How much to take off a stream's timestamps, in that stream's own time
    /// base. Zero when the container starts where everything expects it to,
    /// which keeps every source that worked before this on identical
    /// arithmetic.
    static func startOffset(startTime: Int64, timeBase: AVRational) -> Int64 {
        guard startTime != Int64.min, startTime > 0,
              timeBase.den > 0, timeBase.num > 0 else { return 0 }
        let seconds = Double(startTime) / microsecondsPerSecond
        return Int64((seconds * Double(timeBase.den) / Double(timeBase.num)).rounded())
    }
}

nonisolated private let avNoPTS = Int64.min // AV_NOPTS_VALUE
nonisolated private let avTimeBase = 1_000_000.0 // AV_TIME_BASE
nonisolated private let seekBackwardFlag: Int32 = 1 // AVSEEK_FLAG_BACKWARD
nonisolated private let keyPacketFlag: Int32 = 1 // AV_PKT_FLAG_KEY
nonisolated private let avErrorEOF: Int32 = -541_478_725 // AVERROR_EOF = -MKTAG('E','O','F',' ')
nonisolated private let customIOFlag: Int32 = 0x0080 // AVFMT_FLAG_CUSTOM_IO
nonisolated private let noFileFormatFlag: Int32 = 0x0001 // AVFMT_NOFILE

nonisolated enum DemuxError: LocalizedError {
    /// `code` is the AVERROR where libavformat gave one, else 0.
    case openFailed(String, code: Int32 = 0)
    case seekFailed(String, code: Int32 = 0)
    case unsupportedVideo(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let detail, _): "The stream could not be opened (\(detail))."
        case .seekFailed(let detail, _): "The stream could not seek to that position (\(detail))."
        case .unsupportedVideo(let codec): "The Lagoon engine can't decode \(codec) yet."
        }
    }

    /// Stage and AVERROR for the diagnostic report; the codec name of an
    /// unsupported stream is already a fact of the attempt.
    var diagnosticDetail: PlaybackFailureDetail {
        switch self {
        case .openFailed(_, let code):
            PlaybackFailureDetail(stage: .open, domain: "ffmpeg", code: code == 0 ? nil : Int(code))
        case .seekFailed(_, let code):
            PlaybackFailureDetail(stage: .seek, domain: "ffmpeg", code: code == 0 ? nil : Int(code))
        case .unsupportedVideo:
            PlaybackFailureDetail(stage: .decode, domain: "ffmpeg.unsupported")
        }
    }

    /// Whether a different delivery of the same media could help. Opening
    /// and seeking are container and transport problems, which a server-side
    /// remux routinely fixes; an unsupported codec is not.
    var cause: PlaybackEngineFailure.Cause {
        switch self {
        case .openFailed, .seekFailed: .delivery
        case .unsupportedVideo: .undecodable
        }
    }
}

/// AC-3 normally stays compressed through Apple's audio renderer. Alongside
/// Lagoon's software-decoded VC-1 video, however, that path exhibits audible
/// interruptions and sustained MallocHelper growth on tvOS. Decoding only
/// that legacy pairing to LPCM keeps the Jellyfin session Direct Play while
/// preserving E-AC-3/Atmos passthrough for modern media.
nonisolated enum AudioDecodePolicy {
    static func requiresLocalPCM(codecID: AVCodecID, softwareVideoDecoded: Bool) -> Bool {
        softwareVideoDecoded && codecID == AV_CODEC_ID_AC3
    }
}

/// One demuxed stream with everything the render pipeline needs.
nonisolated struct DemuxedStream {
    let streamIndex: Int32
    let codecName: String
    let language: String?
    let title: String?
    let channels: Int
    /// FFmpeg reported the Atmos profile (E-AC3 JOC / TrueHD Atmos) —
    /// surfaces in track names so the JOC track is identifiable.
    let isAtmos: Bool
    /// nil only for subtitle streams — cues render as an overlay, not
    /// through a sample-buffer renderer.
    let formatDescription: CMFormatDescription?
    /// Fallback per-packet duration in seconds for audio packets that
    /// arrive without one (frames-per-packet / sample-rate).
    let fallbackPacketDuration: Double
    /// Video codec reorder lookahead reported by libavformat. Zero for
    /// audio/subtitle streams and video formats without reordered frames.
    let videoReorderDepth: Int
}

nonisolated final class FFmpegDemuxer {
    enum ReadResult {
        case video(CMSampleBuffer)
        /// A compressed access unit for the software decode stage, which
        /// runs off this queue so reading and decoding overlap.
        case videoPacket(SoftwareVideoPacket)
        case audio([CMSampleBuffer], streamIndex: Int32)
        case subtitle([SubtitleEvent], streamIndex: Int32)
        case skipped
        case endOfFile
        case failed(String)
    }

    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private let capabilities: PlaybackCapabilities
    private var cachedIO: FFmpegCachedIO?
    private var transport: FFmpegNetworkTransport?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var videoStreamIndex: Int32 = -1
    private var videoTimeBase = AVRational(num: 1, den: 1)
    private var audioTimeBases: [Int32: AVRational] = [:]
    private var selectedAudioStreamIndex: Int32 = -1
    /// `-debug.disableAudio YES` opens the title with no audio streams at
    /// all, so a hardware CPU trace can tell the audio path's cost apart from
    /// the video path's. Diagnostic only; never a user setting.
    private static let audioDisabledForDiagnostics: Bool = {
        guard let value = SoftwareDecodeThreadPolicy.commandLineString(forKey: "debug.disableAudio") else {
            return false
        }
        return ["yes", "true", "1"].contains(value.lowercased())
    }()
    private var didDrainAudioAtEOF = false
    // M4: codecs CoreAudio can't take compressed decode to LPCM here.
    private var audioDecoders: [Int32: AudioDecoder] = [:]
    private var subtitleDecoders: [Int32: SubtitleDecoder] = [:]
    // Sample-exact pts chains for compressed passthrough audio —
    // container timestamps are quantized (Matroska: 1 ms) and the renderer
    // turns every quantization mismatch into an audible discontinuity.
    private var passthroughTimelines: [Int32: PassthroughAudioTimeline] = [:]
    // Remove Matroska's millisecond quantization from video PTS.
    // This was not the root cause of the measured 10% HEVC frame loss, but
    // keeps both compressed and decoded presentation timing sample-exact.
    private var videoTimeline: VideoFrameTimeline?
    // Apple exposes no tvOS VideoToolbox decoder for VC-1. The original
    // stream still direct-plays: libavcodec produces ready Core Video frames
    // that enter the same AVFoundation renderer/synchronizer as every other
    // codec.
    /// Built here because this is where the codec parameters are, then handed
    /// to the engine, which drives it from a decode queue of its own. Nil
    /// again the moment it is taken: the demuxer does not decode video.
    private var softwareVideoDecoder: SoftwareVideoDecoder?
    private var softwareGridDescription: String?

    /// How a single-track Dolby Vision profile 7 stream is
    /// handled — rewritten to profile 8.1 (`.convert`, default) or stripped
    /// to the HDR10 fallback (`.stripToHDR10`, Settings → Debug).
    /// Set before `open`.
    var dolbyVisionProfile7Mode: DolbyVisionProfile7Mode = .convert
    /// Armed by the open-time gate in `.convert` mode; demux-queue use only.
    private var profile7Converter: DolbyVisionProfileConverter?
    /// A/B toggle: opt back into marking disposable frames droppable
    /// (4e2ad5f's behavior) — see the factory's attachment comment for
    /// why the default volunteers nothing. Set before `open`.
    var markDroppableFrames = false
    /// Non-nil = a profile 7 rewrite (convert or strip) is armed; demux-queue
    /// use only.
    private var videoNALLengthSize: Int?
    /// Set when the video track arrives start-code delimited, which is every
    /// MPEG-TS and so every Blu-ray clip the disc reader opens.
    private var videoUsesStartCodes = false
    /// What the compressed video payloads handed to the renderer are,
    /// so a post-seek packet can be asked whether a decoder can *start* on it
    /// rather than only whether the container would seek to it. Both nil for
    /// software-decoded video and for any codec this cannot read, which
    /// leaves that stream on exactly its earlier path.
    private var videoRandomAccessCodec: VideoRandomAccessPoint.Codec?
    private var videoPayloadNALLengthSize: Int?
    /// Where a seek left the video stream. Demux-queue use only.
    private var postSeekVideoFilter: PostSeekVideoFilter = .idle
    /// Per stream, the container origin to subtract from its timestamps.
    /// Empty for every container that already starts at zero.
    private var streamStartOffsets: [Int32: Int64] = [:]
    // Written per-packet on the demux queue, read by the HUD from the main
    // actor — proof the rewrite engaged (the retraction lesson: verify
    // the gate before trusting the A/B). Strip mode's own snapshot; convert
    // mode forwards the converter's separately locked one instead.
    private let stripStatsLock = NSLock()
    nonisolated(unsafe) private var stripStats: DolbyVisionRewriteStats?

    /// Snapshot of this playback's profile 7 rewrite — nil until the
    /// open-time gate arms strip or convert mode on a real profile 7 stream.
    var dolbyVisionRewriteStats: DolbyVisionRewriteStats? {
        if let profile7Converter {
            return profile7Converter.stats
        }
        stripStatsLock.lock()
        defer { stripStatsLock.unlock() }
        return stripStats
    }

    /// Compressed audio packets `PassthroughAudioTimeline` rejected as
    /// overlapping. These never reach a renderer, so `AudioContinuityMonitor`
    /// cannot see them and `aGaps` stays 0 however many are lost — this is
    /// the only place the loss is visible. `worstOverlap` in packet-multiples
    /// is what says which failure it is: under 1 is the boundary repeat the
    /// guard was written for, far above it is a real discontinuity being
    /// muted rather than re-anchored.
    var audioPacketDropStats: (packets: Int, worstOverlapSeconds: Double, packetSeconds: Double)? {
        audioDropLock.lock()
        defer { audioDropLock.unlock() }
        guard audioDroppedPackets > 0 else { return nil }
        return (audioDroppedPackets, worstAudioOverlapSeconds, droppedAudioPacketSeconds)
    }

    private let audioDropLock = NSLock()
    nonisolated(unsafe) private var audioDroppedPackets = 0
    nonisolated(unsafe) private var worstAudioOverlapSeconds: Double = 0
    nonisolated(unsafe) private var droppedAudioPacketSeconds: Double = 0

    private(set) var videoStream: DemuxedStream?
    private(set) var audioStreams: [DemuxedStream] = []
    private(set) var subtitleStreams: [DemuxedStream] = []
    private(set) var durationSeconds: Double = 0
    /// The video stream's best-guess frame rate (display matching wants
    /// it); 0 when FFmpeg can't tell.
    private(set) var videoFrameRate: Double = 0
    /// The pts grid in force, for the HUD's gate check (demux queue only).
    var videoGridDescription: String? {
        softwareGridDescription ?? videoTimeline?.gridDescription
    }
    /// Whether video leaves here as compressed packets for libavcodec rather
    /// than as samples for an Apple decoder. Stored rather than derived from
    /// the decoder, which is handed away during open.
    private(set) var outputsDecodedVideo = false

    /// Stops routing AV1 to an Apple decoder, for a reopen after one could
    /// not be created. Call before `open`.
    func disableVideoToolboxAV1() {
        routesAV1ToVideoToolbox = false
    }

    private var routesAV1ToVideoToolbox = true

    /// Transfers the software decoder to its caller, which becomes
    /// responsible for decoding, flushing and draining it. Returns it once.
    func takeSoftwareVideoDecoder() -> SoftwareVideoDecoder? {
        defer { softwareVideoDecoder = nil }
        return softwareVideoDecoder
    }

    /// Wall time spent inside `av_read_frame` and the packets it produced —
    /// the delivery half of "where does the time go". Cumulative
    /// since the last seek, matching the decoder's own profile.
    var ioProfile: (readSeconds: Double, packets: Int, elapsedSeconds: Double) {
        ioLock.withLock {
            (ioReadSeconds, ioPackets, ioStartedAt.map { ioLastReadAt - $0 } ?? 0)
        }
    }

    private let ioLock = NSLock()
    nonisolated(unsafe) private var ioReadSeconds: Double = 0
    nonisolated(unsafe) private var ioPackets = 0
    nonisolated(unsafe) private var ioStartedAt: Double?
    nonisolated(unsafe) private var ioLastReadAt: Double = 0

    init(capabilities: PlaybackCapabilities = .current) {
        self.capabilities = capabilities
    }

    /// Whether a stream goes to VideoToolbox as compressed samples or is
    /// decoded here. AV1 is offered and settled per stream at session
    /// creation; otherwise libdav1d produces P010/NV12. VP9 is always software.
    ///
    /// `interlaced` is the stream's own probed field order. Interlaced H.264
    /// takes the software decoder because that is the only path with a
    /// deinterlacing stage — VideoToolbox would hand back woven field pairs
    /// and the picture would comb on motion. Progressive H.264 is untouched.
    /// HEVC has no software route here, so it stays compressed whatever the
    /// field order says.
    static func usesCompressedVideoPath(
        codecID: AVCodecID,
        capabilities: PlaybackCapabilities,
        interlaced: Bool = false
    ) -> Bool {
        switch codecID {
        case AV_CODEC_ID_H264:
            !interlaced
        case AV_CODEC_ID_HEVC:
            true
        case AV_CODEC_ID_AV1:
            capabilities.decodesAV1WithVideoToolbox
        default:
            false
        }
    }

    /// Whether a probed field order describes interlaced pictures. Unknown
    /// is progressive: it is what libavformat reports when nothing in the
    /// stream said otherwise, and sending that to the software decoder
    /// would take H.264 off the hardware for no reason.
    static func isInterlaced(fieldOrder: AVFieldOrder) -> Bool {
        switch fieldOrder {
        case AV_FIELD_TT, AV_FIELD_BB, AV_FIELD_TB, AV_FIELD_BT:
            true
        default:
            false
        }
    }

    func outputsDecodedAudio(streamIndex: Int32) -> Bool {
        audioDecoders[streamIndex] != nil
    }

    // Written from the main actor at shutdown, polled by FFmpeg's interrupt
    // callback from inside blocked network I/O — this is what guarantees a
    // wedged open/read can't hang teardown.
    private let interruptLock = NSLock()
    nonisolated(unsafe) private var interruptedFlag = false

    var isInterrupted: Bool {
        interruptLock.lock()
        defer { interruptLock.unlock() }
        return interruptedFlag
    }

    func interrupt() {
        interruptLock.lock()
        interruptedFlag = true
        interruptLock.unlock()
    }

    func open(
        url: String,
        cacheSession: PlaybackCacheSession? = nil,
        disc: DiscPlaybackRequest? = nil,
        recommendedPixelBufferAttributes: CVPixelBufferAttributes,
        authorization: MediaRequestAuthorization? = nil
    ) throws {
        close()
        formatContext = avformat_alloc_context()
        guard let allocated = formatContext else {
            throw DemuxError.openFailed("out of memory")
        }
        var completedOpen = false
        defer {
            // Own the context from allocation, including disc/custom-I/O
            // setup. avformat_open_input updates this same pointer (and frees
            // it on failure), so every throw has exactly one cleanup path.
            if !completedOpen { close() }
        }
        allocated.pointee.interrupt_callback = AVIOInterruptCB(
            callback: { opaque in
                guard let opaque else { return 0 }
                return Unmanaged<FFmpegDemuxer>.fromOpaque(opaque).takeUnretainedValue().isInterrupted ? 1 : 0
            },
            opaque: Unmanaged.passUnretained(self).toOpaque()
        )
        // Every http/https open this AVFormatContext makes — the top-level
        // URL as well as every HLS child manifest/segment/key — now goes
        // through Lagoon's own transport; libavformat's network stack is
        // gone. Installing unconditionally covers the top-level open too:
        // when a custom `pb` is set below for direct-cache or disc
        // playback, libavformat never calls io_open for the root, so this
        // is a no-op there.
        let transport = FFmpegNetworkTransport(
            isInterrupted: { [weak self] in self?.isInterrupted ?? true },
            hlsCache: cacheSession?.hlsScope,
            authorization: authorization
        )
        self.transport = transport
        transport.install(on: allocated)
        if let disc, let cacheScope = cacheSession?.directScope {
            // A disc image is a filesystem, not a stream. Mount it, choose
            // the title, and hand libavformat that title's clips laid end to
            // end — it never learns the image was a disc. Every failure here
            // is a delivery failure, so a disc this cannot read falls to the
            // server remux exactly as it did before any of this existed.
            do {
                let volume = try UDFVolume(
                    source: PlaybackCacheDiscSource(source: cacheScope),
                    budget: DiscReadBudget(isCancelled: { [weak self] in self?.isInterrupted ?? true })
                )
                let title = try DiscTitle.mainTitle(
                    in: volume,
                    runtimeSeconds: disc.runtimeSeconds
                )
                let cachedIO = try FFmpegCachedIO(
                    source: DiscImageStream(source: cacheScope, map: title.stream)
                )
                allocated.pointee.pb = cachedIO.context
                allocated.pointee.flags |= customIOFlag
                self.cachedIO = cachedIO
            } catch let error as DiscImageError {
                throw DemuxError.openFailed(error.errorDescription ?? "unreadable disc image")
            }
        } else if let cacheScope = cacheSession?.directScope {
            let cachedIO = try FFmpegCachedIO(source: cacheScope)
            allocated.pointee.pb = cachedIO.context
            allocated.pointee.flags |= customIOFlag
            self.cachedIO = cachedIO
        }

        // hls.c reuses a segment's connection for the next request only
        // through FFmpeg's own HTTP protocol, which this libavformat no
        // longer has. Left on, persistence makes every segment fall back to
        // io_open while keeping the previous context alive, one leaked
        // AVIOContext per segment for the length of the film. Off, hls.c
        // closes each segment through io_close2 as it finishes.
        var options: OpaquePointer?
        av_dict_set(&options, "http_persistent", "0", 0)
        defer { av_dict_free(&options) }

        var status = avformat_open_input(&formatContext, url, nil, &options)
        guard status >= 0, let ctx = formatContext else {
            #if DEBUG
            print("FFmpegDemuxer open failed \(status) for \(url)")
            #endif
            throw DemuxError.openFailed(Self.errorText(status), code: status)
        }
        status = avformat_find_stream_info(ctx, nil)
        guard status >= 0 else {
            throw DemuxError.openFailed(Self.errorText(status), code: status)
        }

        if ctx.pointee.duration > 0 {
            durationSeconds = Double(ctx.pointee.duration) / avTimeBase
        }

        // A container that does not start at zero has its origin recorded per
        // stream here, and removed from packets as they are read. Taking the
        // format's origin rather than each stream's own preserves the offsets
        // between them: WALL·E's disc starts video and one audio track
        // together and a second audio track two thirds of a second later,
        // which is content, not clock.
        for index in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[index] else { continue }
            let offset = ContainerTimeline.startOffset(
                startTime: ctx.pointee.start_time,
                timeBase: stream.pointee.time_base
            )
            if offset != 0 {
                streamStartOffsets[stream.pointee.index] = offset
            }
        }

        let bestVideo = av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard bestVideo >= 0, let stream = ctx.pointee.streams[Int(bestVideo)] else {
            throw DemuxError.openFailed("no video stream")
        }

        // M6: in an HLS master every variant becomes a program. Restrict
        // the working set to the chosen video's program — otherwise other
        // variants' audio would duplicate the track list and libavformat
        // would keep downloading their segments. Non-HLS files have no
        // programs and pass everything through.
        var programStreams: Set<Int32> = []
        for programIndex in 0..<Int(ctx.pointee.nb_programs) {
            guard let program = ctx.pointee.programs[programIndex] else { continue }
            let members = (0..<Int(program.pointee.nb_stream_indexes)).map {
                Int32(program.pointee.stream_index[$0])
            }
            if members.contains(bestVideo) {
                programStreams = Set(members)
                break
            }
        }
        let videoPar = stream.pointee.codecpar!
        videoStreamIndex = bestVideo
        videoTimeBase = stream.pointee.time_base
        let guessedRate = av_guess_frame_rate(ctx, stream, nil)
        if guessedRate.num > 0, guessedRate.den > 0 {
            videoFrameRate = Double(guessedRate.num) / Double(guessedRate.den)
        }
        let videoIsInterlaced = Self.isInterlaced(fieldOrder: videoPar.pointee.field_order)
        let usesCompressedVideo = Self.usesCompressedVideoPath(
            codecID: videoPar.pointee.codec_id,
            capabilities: capabilities,
            interlaced: videoIsInterlaced
        ) && (videoPar.pointee.codec_id != AV_CODEC_ID_AV1 || routesAV1ToVideoToolbox)
        // A container that describes no parameter sets has to be caught
        // before the description is built, not after: the description is
        // created successfully either way and only the decoder refuses.
        // MPEG-TS describes its parameter sets in Annex-B, which is not an
        // hvcC however much the field it arrives in says otherwise. Taken at
        // face value it builds a description no decoder accepts, and the
        // refusal arrives as "no hardware decoder" rather than as anything
        // about framing.
        let annexBParameterSets = usesCompressedVideo
            ? annexBParameterSets(codecpar: videoPar)
            : nil
        videoUsesStartCodes = annexBParameterSets != nil
        let harvestedParameterSets = usesCompressedVideo && annexBParameterSets == nil
            ? harvestedHEVCParameterSets(ctx: ctx, streamIndex: bestVideo, codecpar: videoPar)
            : nil
        // Once a start-code stream is converted every NAL carries a
        // four-byte length, whatever the container's own record claimed.
        let filterNALLengthSize: Int? = videoUsesStartCodes
            ? Int(AnnexBStream.nalUnitHeaderLength)
            : videoPar.pointee.extradata.flatMap { extradata in
                videoPar.pointee.extradata_size > 0
                    ? HEVCNALUnitRewriter.nalLengthSize(
                        hvcc: Data(bytes: extradata, count: Int(videoPar.pointee.extradata_size))
                    )
                    : nil
            }
        // A profile 7 remux (UHD Blu-ray) interleaves base-layer,
        // RPU (unspec 62) and enhancement-layer (unspec 63) NALs in one
        // HEVC track. tvOS cannot reconstruct dual-layer DoVi, so by
        // default every RPU is rewritten to profile 8.1 with libdovi and
        // every enhancement-layer unit is dropped, tagging the track hvc1
        // + dvvC so the system engages real Dolby Vision off the rewritten
        // single layer. The debug toggle falls back to the older
        // behaviour: drop both unit types and let the base layer present
        // as HDR10. Neither mode arms without a known NAL length size or a
        // profile other than 7 — MPEG-TS discs carry no DoVi configuration
        // record at all, so they're untouched either way.
        var dolbyVisionOverride: AVDOVIDecoderConfigurationRecord?
        if videoPar.pointee.codec_id == AV_CODEC_ID_HEVC,
           let dovi = SampleBufferFactory.doviConfiguration(codecpar: videoPar),
           dovi.dv_profile == 7,
           let lengthSize = filterNALLengthSize {
            videoNALLengthSize = lengthSize
            switch dolbyVisionProfile7Mode {
            case .convert:
                profile7Converter = DolbyVisionProfileConverter(record: dovi)
                dolbyVisionOverride = profile7Converter?.synthesizedRecord
            case .stripToHDR10:
                stripStatsLock.lock()
                stripStats = DolbyVisionRewriteStats(mode: .stripToHDR10)
                stripStatsLock.unlock()
            }
        }
        var videoDescription: CMFormatDescription? = if usesCompressedVideo {
            SampleBufferFactory.videoFormatDescription(
                codecpar: videoPar,
                parameterSets: annexBParameterSets ?? harvestedParameterSets.map {
                    SampleBufferFactory.BitstreamParameterSets(
                        sets: $0,
                        nalUnitHeaderLength: Int32(
                            videoPar.pointee.extradata.flatMap { extradata in
                                HEVCNALUnitRewriter.nalLengthSize(
                                    hvcc: Data(
                                        bytes: extradata,
                                        count: Int(videoPar.pointee.extradata_size)
                                    )
                                )
                            } ?? 4
                        )
                    )
                },
                dolbyVisionOverride: dolbyVisionOverride
            )
        } else {
            nil
        }
        if videoDescription == nil,
           SoftwareVideoDecoder.supports(
               codecID: videoPar.pointee.codec_id,
               interlaced: videoIsInterlaced
           ) {
            let decoder = try SoftwareVideoDecoder(
                codecpar: videoPar,
                timeBase: videoTimeBase,
                frameRate: guessedRate,
                recommendedPixelBufferAttributes: recommendedPixelBufferAttributes
            )
            softwareVideoDecoder = decoder
            softwareGridDescription = decoder.gridDescription
            outputsDecodedVideo = true
            videoDescription = decoder.formatDescription
        }
        guard let videoDescription else {
            throw DemuxError.unsupportedVideo(String(cString: avcodec_get_name(videoPar.pointee.codec_id)))
        }
        if !outputsDecodedVideo {
            videoTimeline = VideoFrameTimeline(
                frameRateNum: guessedRate.num,
                frameRateDen: guessedRate.den
            )
            // Only the compressed path reaches the renderer, and
            // only these two codecs are length-prefixed NAL streams there.
            switch videoPar.pointee.codec_id {
            case AV_CODEC_ID_H264: videoRandomAccessCodec = .h264
            case AV_CODEC_ID_HEVC: videoRandomAccessCodec = .hevc
            default: videoRandomAccessCodec = nil
            }
            if let codec = videoRandomAccessCodec {
                // A converted start-code payload carries four-byte lengths
                // whatever the container's own record said.
                videoPayloadNALLengthSize = videoUsesStartCodes
                    ? Int(AnnexBStream.nalUnitHeaderLength)
                    : videoPar.pointee.extradata.flatMap { extradata in
                        videoPar.pointee.extradata_size > 0
                            ? VideoRandomAccessPoint.nalLengthSize(
                                configurationRecord: Data(
                                    bytes: extradata,
                                    count: Int(videoPar.pointee.extradata_size)
                                ),
                                codec: codec
                            )
                            : nil
                    }
            }
        }
        videoStream = DemuxedStream(
            streamIndex: bestVideo,
            codecName: String(cString: avcodec_get_name(videoPar.pointee.codec_id)),
            language: Self.metadata(stream, key: "language"),
            title: Self.metadata(stream, key: "title"),
            channels: 0,
            isAtmos: false,
            formatDescription: videoDescription,
            fallbackPacketDuration: 0,
            videoReorderDepth: Int(videoPar.pointee.video_delay)
        )

        for index in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[index], let par = stream.pointee.codecpar else { continue }
            if !programStreams.isEmpty, !programStreams.contains(Int32(index)) {
                stream.pointee.discard = AVDISCARD_ALL
                continue
            }
            switch par.pointee.codec_type {
            case AVMEDIA_TYPE_AUDIO:
                // Passthrough codecs wrap compressed; everything else gets
                // a libavcodec → LPCM decoder (M4). Only codecs FFmpeg has
                // no decoder for drop out of the track list.
                var description: CMFormatDescription?
                var fallbackDuration: Double = 0
                if Self.audioDisabledForDiagnostics {
                    stream.pointee.discard = AVDISCARD_ALL
                    continue
                }
                let requiresLocalPCM = AudioDecodePolicy.requiresLocalPCM(
                    codecID: par.pointee.codec_id,
                    softwareVideoDecoded: outputsDecodedVideo
                )
                if !requiresLocalPCM,
                   let (passthrough, framesPerPacket) = SampleBufferFactory.audioFormatDescription(codecpar: par) {
                    description = passthrough
                    fallbackDuration = Double(framesPerPacket) / Double(max(par.pointee.sample_rate, 1))
                    passthroughTimelines[Int32(index)] = PassthroughAudioTimeline(
                        sampleRate: par.pointee.sample_rate,
                        framesPerPacket: framesPerPacket
                    )
                } else if let decoder = AudioDecoder(codecpar: par, timeBase: stream.pointee.time_base) {
                    description = decoder.formatDescription
                    audioDecoders[Int32(index)] = decoder
                }
                guard let description else {
                    stream.pointee.discard = AVDISCARD_ALL
                    continue
                }
                audioTimeBases[Int32(index)] = stream.pointee.time_base
                audioStreams.append(DemuxedStream(
                    streamIndex: Int32(index),
                    codecName: String(cString: avcodec_get_name(par.pointee.codec_id)),
                    language: Self.metadata(stream, key: "language"),
                    title: Self.metadata(stream, key: "title"),
                    channels: Int(par.pointee.ch_layout.nb_channels),
                    // AV_PROFILE_EAC3_DDP_ATMOS and AV_PROFILE_TRUEHD_ATMOS
                    // share the value 30.
                    isAtmos: (par.pointee.codec_id == AV_CODEC_ID_EAC3 || par.pointee.codec_id == AV_CODEC_ID_TRUEHD)
                        && par.pointee.profile == 30,
                    formatDescription: description,
                    fallbackPacketDuration: fallbackDuration,
                    videoReorderDepth: 0
                ))
            case AVMEDIA_TYPE_SUBTITLE:
                // Every subtitle stream is listed even when undecodable so
                // the engine's per-type ordinals stay aligned with the
                // server's stream list (M5). Unselected streams stay
                // discarded inside libavformat.
                stream.pointee.discard = AVDISCARD_ALL
                if let decoder = SubtitleDecoder(codecpar: par, timeBase: stream.pointee.time_base) {
                    subtitleDecoders[Int32(index)] = decoder
                }
                subtitleStreams.append(DemuxedStream(
                    streamIndex: Int32(index),
                    codecName: String(cString: avcodec_get_name(par.pointee.codec_id)),
                    language: Self.metadata(stream, key: "language"),
                    title: Self.metadata(stream, key: "title"),
                    channels: 0,
                    isAtmos: false,
                    formatDescription: nil,
                    fallbackPacketDuration: 0,
                    videoReorderDepth: 0
                ))
            case AVMEDIA_TYPE_VIDEO:
                if Int32(index) != bestVideo {
                    stream.pointee.discard = AVDISCARD_ALL
                }
            default:
                stream.pointee.discard = AVDISCARD_ALL
            }
        }

        guard let packet = av_packet_alloc() else {
            throw DemuxError.openFailed("out of memory")
        }
        self.packet = packet
        completedOpen = true
    }

    /// Demux only the chosen audio stream; the rest are discarded inside
    /// libavformat so they never cost a packet copy.
    func selectAudio(streamIndex: Int32?) {
        guard let ctx = formatContext else { return }
        selectedAudioStreamIndex = streamIndex ?? -1
        for stream in audioStreams {
            ctx.pointee.streams[Int(stream.streamIndex)]?.pointee.discard =
                stream.streamIndex == streamIndex ? AVDISCARD_DEFAULT : AVDISCARD_ALL
        }
    }

    /// Whether the video stream is read at all. Discarded inside
    /// libavformat while the app plays audio in the background,
    /// so a locked phone neither decodes nor holds pictures nobody sees.
    func setVideoDiscarded(_ discarded: Bool) {
        guard let ctx = formatContext, let videoStream else { return }
        ctx.pointee.streams[Int(videoStream.streamIndex)]?.pointee.discard =
            discarded ? AVDISCARD_ALL : AVDISCARD_DEFAULT
    }

    /// Same discard dance for the chosen embedded subtitle stream (nil =
    /// subtitles off / an external track is active).
    func selectSubtitle(streamIndex: Int32?) {
        guard let ctx = formatContext else { return }
        for stream in subtitleStreams {
            ctx.pointee.streams[Int(stream.streamIndex)]?.pointee.discard =
                stream.streamIndex == streamIndex ? AVDISCARD_DEFAULT : AVDISCARD_ALL
        }
    }

    /// How far to read looking for parameter sets. They are the opening
    /// NALs of the first access unit in every file that muxes this way, so
    /// this only has to cover whatever audio and subtitle packets happen to
    /// be interleaved ahead of the first video one.
    private static let parameterSetProbeLimit = 64

    /// Parameter sets read out of a start-code delimited container record.
    ///
    /// nil for every length-prefixed container, which is all of them but
    /// MPEG-TS, so nothing that worked before this reaches a new path.
    private func annexBParameterSets(
        codecpar: UnsafeMutablePointer<AVCodecParameters>
    ) -> SampleBufferFactory.BitstreamParameterSets? {
        let codec: AnnexBStream.Codec
        switch codecpar.pointee.codec_id {
        case AV_CODEC_ID_HEVC: codec = .hevc
        case AV_CODEC_ID_H264: codec = .h264
        default: return nil
        }
        guard let extradata = codecpar.pointee.extradata,
              codecpar.pointee.extradata_size > 0 else { return nil }
        let record = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
        guard AnnexBStream.usesStartCodes(record),
              let sets = AnnexBStream.parameterSets(inAnnexB: record, codec: codec) else {
            return nil
        }
        return SampleBufferFactory.BitstreamParameterSets(
            sets: sets,
            nalUnitHeaderLength: AnnexBStream.nalUnitHeaderLength
        )
    }

    /// VPS, SPS and PPS taken from the bitstream, for an HEVC track whose
    /// container declared none of its own.
    ///
    /// nil in the ordinary case, so a well-formed `hvcC` keeps the existing
    /// path and reads no packets at all. When it does run, the context is
    /// rewound afterwards: the demux loop has not started yet and still owes
    /// the renderer every packet from the beginning.
    private func harvestedHEVCParameterSets(
        ctx: UnsafeMutablePointer<AVFormatContext>,
        streamIndex: Int32,
        codecpar: UnsafeMutablePointer<AVCodecParameters>
    ) -> [Data]? {
        guard codecpar.pointee.codec_id == AV_CODEC_ID_HEVC,
              let extradata = codecpar.pointee.extradata,
              codecpar.pointee.extradata_size > 0 else { return nil }
        let hvcc = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
        guard !SampleBufferFactory.hevcExtradataCarriesParameterSets(hvcc),
              // The header stays valid even with no arrays behind it, so the
              // NAL length prefix is still described correctly.
              let lengthSize = HEVCNALUnitRewriter.nalLengthSize(hvcc: hvcc),
              let probe = av_packet_alloc() else { return nil }
        var owned: UnsafeMutablePointer<AVPacket>? = probe
        defer { av_packet_free(&owned) }

        var sets: [UInt8: Data] = [:]
        var packetsRead = 0
        while packetsRead < Self.parameterSetProbeLimit, sets.count < 3 {
            guard av_read_frame(ctx, probe) >= 0 else { break }
            packetsRead += 1
            if probe.pointee.stream_index == streamIndex, let data = probe.pointee.data {
                Self.collectParameterSets(
                    from: UnsafeRawBufferPointer(start: data, count: Int(probe.pointee.size)),
                    lengthSize: lengthSize,
                    into: &sets
                )
            }
            av_packet_unref(probe)
        }

        // Rewind whether or not the harvest worked. A failure here costs the
        // opening packets, which is worth strictly less than the decoder the
        // harvest buys, so it is not treated as fatal.
        if avformat_seek_file(ctx, streamIndex, Int64.min, 0, 0, 0) < 0 {
            _ = av_seek_frame(ctx, streamIndex, 0, seekBackwardFlag)
        }

        // VPS, SPS, PPS, in the order the decoder expects them.
        let ordered = [32, 33, 34].compactMap { sets[UInt8($0)] }
        return ordered.count == 3 ? ordered : nil
    }

    /// Walks one length-prefixed packet, keeping the first of each
    /// parameter-set NAL it finds.
    private static func collectParameterSets(
        from payload: UnsafeRawBufferPointer,
        lengthSize: Int,
        into sets: inout [UInt8: Data]
    ) {
        guard let base = payload.baseAddress, (1...4).contains(lengthSize) else { return }
        let count = payload.count
        var offset = 0
        while offset + lengthSize <= count {
            var nalLength = 0
            for index in 0..<lengthSize {
                nalLength = nalLength << 8 | Int(payload[offset + index])
            }
            let start = offset + lengthSize
            let end = start + nalLength
            guard nalLength > 0, end <= count else { return }
            let nalType = (payload[start] >> 1) & 0x3F
            if (32...34).contains(nalType), sets[nalType] == nil {
                sets[nalType] = Data(bytes: base.advanced(by: start), count: nalLength)
            }
            offset = end
        }
    }

    func seek(toSeconds seconds: Double) throws {
        guard let ctx = formatContext else {
            throw DemuxError.seekFailed("demuxer not open")
        }
        // Anchor the request in the selected video stream's clock. HLS can
        // expose a separate audio rendition as its default stream; seeking
        // with stream_index -1 then moves audio correctly while video keeps
        // reading from its prior playlist position.
        // Back into the container's own clock, which is where the seek has
        // to land even though everything above this counts from zero.
        let timestamp = Int64(
            seconds * Double(videoTimeBase.den) / Double(max(videoTimeBase.num, 1))
        ) + (streamStartOffsets[videoStreamIndex] ?? 0)
        // The legacy single-stream seek can leave split HLS audio/video
        // inputs at different playlist positions (observed as a full audio
        // queue and zero video after a backward scrub). The newer API seeks
        // all active streams to a jointly presentable point, and constraining
        // max_ts to the requested time asks for the keyframe at or before it.
        try Self.validateSeekStatus(reposition(ctx, to: timestamp))
        // A container with no index answers that request with whatever packet
        // its binary search stops on, keyframe or not.
        alignLandingToKeyframe(ctx, target: timestamp)
        // The packet the container seeks to is not necessarily one
        // a hardware decoder can be started on, and the packets right behind
        // it may be presented before it. Both are decided on the first video
        // packet this seek produces.
        postSeekVideoFilter = videoRandomAccessCodec != nil ? .awaitingAnchor : .idle
        cachedIO?.setTimelineAnchor(seconds: seconds, duration: durationSeconds)
        didDrainAudioAtEOF = false
        for decoder in audioDecoders.values {
            decoder.flush()
        }
        for index in passthroughTimelines.keys {
            passthroughTimelines[index]?.reset()
        }
        videoTimeline?.reset()
        // The software decoder is the decode stage's, and the stage resets it
        // itself right after this returns. Flushing it from here would touch
        // libavcodec from two queues at once.
        for decoder in subtitleDecoders.values {
            decoder.flush()
        }
        ioLock.withLock {
            ioReadSeconds = 0
            ioPackets = 0
            ioStartedAt = nil
        }
    }

    /// Both seek calls in the order the engine needs them: the newer API
    /// first, then the legacy single-stream one as a compatibility fallback
    /// for demuxers that do not implement `avformat_seek_file`. The alignment
    /// below repositions exactly the way the seek itself does.
    private func reposition(_ ctx: UnsafeMutablePointer<AVFormatContext>, to timestamp: Int64) -> Int32 {
        let status = avformat_seek_file(ctx, videoStreamIndex, Int64.min, timestamp, timestamp, 0)
        return status < 0 ? av_seek_frame(ctx, videoStreamIndex, timestamp, seekBackwardFlag) : status
    }

    /// How far back a mid-GOP landing looks for the keyframe that opens its
    /// GOP, in seconds, widened once for long-GOP encodes.
    private static let landingSearchWindows: [Double] = [8, 24]
    /// Packets one search pass may read: the guard against a stream whose
    /// timestamps never reach the target. 24 s of 24 fps video is ~580 video
    /// packets and a comparable number of audio ones.
    private static let landingSearchPacketBudget = 4_000
    /// The keyframe is repositioned to a little before its own decode stamp,
    /// so a binary search that compares decode stamps cannot step past it
    /// into the pictures that follow. The read path then drops forward onto
    /// it, or onto a scene-cut keyframe just before it, which is equally
    /// decodable and no later than the target either way.
    private static let landingSeekMargin = 0.5
    /// Video is interleaved close behind audio, so the first video packet of
    /// a landing arrives well inside this.
    private static let landingProbePacketBudget = 480

    /// Walks a mid-GOP seek back to the last keyframe at or before the target.
    ///
    /// MPEG-TS has no index, so libavformat binary-searches the PES timestamps
    /// and stops mid-GOP as often as not. libavcodec decodes on regardless;
    /// `AVSampleBufferVideoRenderer` returns kVTVideoDecoderBadDataErr (-8969)
    /// on the first sample after a flush, which the ladder reads as
    /// `.undecodable` — a downloaded transcode fell to a server transcode when
    /// resumed.
    ///
    /// *At or before* is what the engine expects: `PlaybackClockAnchor` holds
    /// the clock at the requested time and the audio floor drops the run-in,
    /// so early costs a decode burst where late would skip content.
    ///
    /// Only for one seekable byte stream — file, direct-play cache, disc
    /// image. `AVFMT_NOFILE` demuxers fetch their own media, and HLS seeks to
    /// a segment boundary, a keyframe by construction.
    private func alignLandingToKeyframe(_ ctx: UnsafeMutablePointer<AVFormatContext>, target: Int64) {
        guard videoRandomAccessCodec != nil, videoStreamIndex >= 0,
              let format = ctx.pointee.iformat, format.pointee.flags & noFileFormatFlag == 0,
              let byteStream = ctx.pointee.pb, byteStream.pointee.seekable != 0,
              let probe = av_packet_alloc() else { return }
        var owned: UnsafeMutablePointer<AVPacket>? = probe
        defer { av_packet_free(&owned) }
        // The ordinary landing is a keyframe and pays one repositioning for
        // the packets this read.
        guard landingIsMidGOP(ctx, probe: probe) else {
            _ = reposition(ctx, to: target)
            return
        }
        let ticksPerSecond = Double(videoTimeBase.den) / Double(max(videoTimeBase.num, 1))
        // Container clock throughout: `target` still carries the stream's
        // origin, and packets are read here before it is taken off them.
        let origin = streamStartOffsets[videoStreamIndex] ?? 0
        let margin = Int64(Self.landingSeekMargin * ticksPerSecond)
        for window in Self.landingSearchWindows {
            let from = max(target - Int64(window * ticksPerSecond), origin)
            guard reposition(ctx, to: from) >= 0 else { break }
            if let keyframe = lastKeyframe(ctx, probe: probe, notAfter: target),
               reposition(ctx, to: max(keyframe - margin, origin)) >= 0 {
                return
            }
            if from == origin { break }
        }
        // No keyframe within reach: the read path drops forward to the next
        // one instead, which is late but decodable.
        _ = reposition(ctx, to: target)
    }

    /// Whether the first video packet this landing produces is one no decoder
    /// can be started on. Reading stops there; the caller repositions.
    private func landingIsMidGOP(
        _ ctx: UnsafeMutablePointer<AVFormatContext>,
        probe: UnsafeMutablePointer<AVPacket>
    ) -> Bool {
        var packets = 0
        while packets < Self.landingProbePacketBudget, !isInterrupted {
            guard av_read_frame(ctx, probe) >= 0 else { return false }
            packets += 1
            let isVideo = probe.pointee.stream_index == videoStreamIndex
            let isKeyframe = probe.pointee.flags & keyPacketFlag != 0
            av_packet_unref(probe)
            if isVideo { return !isKeyframe }
        }
        return false
    }

    /// The decode stamp of the last video keyframe presented at or before
    /// `target`, reading forward from wherever the caller left the cursor.
    ///
    /// The container's key flag is the candidate; the post-seek filter still
    /// classifies the packet the cursor ends up on, so an open GOP keeps its
    /// leading-picture drop. Presentation decides whether a
    /// keyframe is early enough, decode decides where to seek: the search a
    /// container without an index runs compares decode stamps.
    private func lastKeyframe(
        _ ctx: UnsafeMutablePointer<AVFormatContext>,
        probe: UnsafeMutablePointer<AVPacket>,
        notAfter target: Int64
    ) -> Int64? {
        var packets = 0
        var latest: Int64?
        while packets < Self.landingSearchPacketBudget, !isInterrupted {
            guard av_read_frame(ctx, probe) >= 0 else { break }
            packets += 1
            let isVideo = probe.pointee.stream_index == videoStreamIndex
            let isKeyframe = probe.pointee.flags & keyPacketFlag != 0
            let presentation = Self.presentationTimestamp(probe)
            let decode = probe.pointee.dts != avNoPTS ? probe.pointee.dts : presentation
            av_packet_unref(probe)
            guard isVideo, let presentation else { continue }
            if presentation > target { break }
            if isKeyframe { latest = decode ?? presentation }
        }
        return latest
    }

    /// `av_read_frame` with the clock around it. This is the transport: on a
    /// direct-played file it is a cache read, on a stream it is the network,
    /// and either way it is the third of the three costs — the one that
    /// used to be indistinguishable from decode because both happened on this
    /// queue, one after the other.
    private func readFrameTimed(
        _ ctx: UnsafeMutablePointer<AVFormatContext>,
        _ packet: UnsafeMutablePointer<AVPacket>
    ) -> Int32 {
        let started = ProcessInfo.processInfo.systemUptime
        let status = av_read_frame(ctx, packet)
        let finished = ProcessInfo.processInfo.systemUptime
        ioLock.withLock {
            if ioStartedAt == nil { ioStartedAt = started }
            ioReadSeconds += finished - started
            ioLastReadAt = finished
            if status >= 0 { ioPackets += 1 }
        }
        return status
    }

    static func validateSeekStatus(_ status: Int32) throws {
        guard status >= 0 else {
            throw DemuxError.seekFailed(errorText(status), code: status)
        }
    }

    /// Rewrites one video payload for the profile 7 mode armed by `open`'s
    /// gate (`videoNALLengthSize` non-nil implies one of the two is).
    /// Convert mode defers entirely to the converter's own locked stats;
    /// strip mode uses `HEVCNALUnitRewriter.rewrite` directly, rather than
    /// the canned `strippingEnhancementLayer`, so it can keep the RPU/EL
    /// breakdown `dolbyVisionRewriteStats` reports instead of just a byte
    /// count.
    private func rewrittenDolbyVisionPayload(
        payload: UnsafeRawBufferPointer,
        lengthSize: Int
    ) -> Data? {
        if let profile7Converter {
            return profile7Converter.convert(payload: payload, lengthSize: lengthSize)
        }
        var rpuDropped = 0
        var enhancementDropped = 0
        guard let filtered = HEVCNALUnitRewriter.rewrite(payload: payload, lengthSize: lengthSize, transform: { nalType, _ in
            switch nalType {
            case 62:
                rpuDropped += 1
                return .drop
            case 63:
                enhancementDropped += 1
                return .drop
            default:
                return .keep
            }
        }) else { return nil }
        stripStatsLock.lock()
        var stats = stripStats ?? DolbyVisionRewriteStats(mode: .stripToHDR10)
        stats.packets += 1
        stats.rpusDropped += rpuDropped
        stats.enhancementUnitsDropped += enhancementDropped
        stats.bytesRemoved += Int64(payload.count - filtered.count)
        stripStats = stats
        stripStatsLock.unlock()
        return filtered
    }

    /// What a seek left the compressed video stream doing.
    private enum PostSeekVideoFilter {
        case idle
        /// Nothing has been read since the seek: the next video packet is
        /// wherever the decoder is about to be restarted.
        case awaitingAnchor
        /// The container put the cursor inside a GOP and video is
        /// being dropped until a picture a decoder can start on.
        case droppingToKeyframe(dropped: Int)
        /// The seek landed on an *open* GOP — a picture the container flags
        /// as a keyframe, that a decoder can start on, but that has pictures
        /// behind it in decode order presented *before* it. Those reference
        /// the GOP the renderer's flush has already destroyed.
        case droppingLeadingPictures(anchor: Int64, dropped: Int)
    }

    /// How many packets the leading-picture drop may consume before it gives
    /// up and lets everything through. Real open GOPs carry one B-pyramid's
    /// worth (measured: two); this only exists so a stream that lies about
    /// its timestamps cannot lose its video track.
    private static let leadingPictureDropLimit = 32

    /// Whether this packet is one of the open GOP's leading pictures.
    ///
    /// The flush before every seek destroys the decoder's reference pictures,
    /// so a picture referencing the GOP *before* the seek landing cannot be
    /// decoded. `AVSampleBufferVideoRenderer` answers `didFailToDecode` and
    /// the ladder reads `.undecodable`, dropping the viewer onto a server
    /// transcode for the rest of the film. libavcodec is forgiving here and
    /// Apple's decoder is not, which is why software paths never showed it.
    ///
    /// Every such picture presents before the seek landing, which is at or
    /// before what the viewer asked for, so nothing dropped was going to be
    /// shown.
    ///
    /// Armed only when the anchor is a keyframe that is not an IDR/IRAP: an
    /// IDR closes its GOP, so closed-GOP content takes the earlier path.
    private func postSeekVideoDecision(
        packet: UnsafeMutablePointer<AVPacket>,
        payload: Data?
    ) -> PostSeekVideoDecision {
        switch postSeekVideoFilter {
        case .idle:
            return .keep
        case .awaitingAnchor:
            return anchorDecision(packet: packet, payload: payload, dropped: 0)
        case .droppingToKeyframe(let dropped):
            return anchorDecision(packet: packet, payload: payload, dropped: dropped)
        case .droppingLeadingPictures(let anchor, let dropped):
            guard let pts = Self.presentationTimestamp(packet), dropped < Self.leadingPictureDropLimit else {
                postSeekVideoFilter = .idle
                return .keep
            }
            guard pts < anchor else {
                // Decode order has passed the anchor; everything from here
                // is a trailing picture.
                postSeekVideoFilter = .idle
                if ProcessCPUTrace.enabled, dropped > 0 {
                    print(String(
                        format: "SeekLeadingPictures dropped=%d anchor=%.3f",
                        dropped,
                        Double(anchor) * Double(videoTimeBase.num) / Double(max(videoTimeBase.den, 1))
                    ))
                }
                return .keep
            }
            postSeekVideoFilter = .droppingLeadingPictures(anchor: anchor, dropped: dropped + 1)
            return .drop
        }
    }

    /// How many video packets the keyframe search may drop before it gives up
    /// and lets the stream through. A GOP is a second or two of video and the
    /// alignment has usually placed the cursor on the keyframe already; this
    /// only exists so a stream whose keyframes are never flagged cannot lose
    /// its video track.
    private static let keyframeSearchDropLimit = 600

    /// Classifies the first video packet a seek is willing to deliver, and
    /// keeps dropping while the container is still inside a GOP.
    private func anchorDecision(
        packet: UnsafeMutablePointer<AVPacket>,
        payload: Data?,
        dropped: Int
    ) -> PostSeekVideoDecision {
        postSeekVideoFilter = .idle
        guard let codec = videoRandomAccessCodec,
              let lengthSize = videoPayloadNALLengthSize,
              let anchor = Self.presentationTimestamp(packet) else { return .keep }
        let isStartPoint: Bool? = if let payload {
            payload.withUnsafeBytes {
                VideoRandomAccessPoint.isDecoderStartPoint(
                    lengthPrefixed: $0, lengthSize: lengthSize, codec: codec
                )
            }
        } else if let data = packet.pointee.data {
            VideoRandomAccessPoint.isDecoderStartPoint(
                lengthPrefixed: UnsafeRawBufferPointer(
                    start: data, count: Int(packet.pointee.size)
                ),
                lengthSize: lengthSize,
                codec: codec
            )
        } else {
            nil
        }
        switch isStartPoint {
        case .some(false) where packet.pointee.flags & keyPacketFlag == 0:
            // Not a start point and not even a picture the container calls a
            // keyframe: the seek landed inside a GOP. Everything
            // here references pictures the renderer's flush destroyed, so it
            // is dropped until the GOP that can be started on.
            guard dropped < Self.keyframeSearchDropLimit else { return .keep }
            if ProcessCPUTrace.enabled, dropped == 0 {
                print(String(
                    format: "SeekMidGOPLanding at=%.3f",
                    Double(anchor) * Double(videoTimeBase.num) / Double(max(videoTimeBase.den, 1))
                ))
            }
            postSeekVideoFilter = .droppingToKeyframe(dropped: dropped + 1)
            return .drop
        case .some(false):
            // A keyframe that is not a start point is the open GOP: keep it
            // and drop the pictures presented before it.
            postSeekVideoFilter = .droppingLeadingPictures(anchor: anchor, dropped: 0)
            return .keep
        default:
            // true is an IDR/IRAP, the clean start. nil is "cannot tell", and
            // a payload this cannot read must not be acted on.
            return .keep
        }
    }

    private enum PostSeekVideoDecision {
        case keep
        case drop
    }

    private static func presentationTimestamp(
        _ packet: UnsafeMutablePointer<AVPacket>
    ) -> Int64? {
        let stamp = packet.pointee.pts != avNoPTS ? packet.pointee.pts : packet.pointee.dts
        return stamp != avNoPTS ? stamp : nil
    }

    func readNext() -> ReadResult {
        guard let ctx = formatContext, let packet else { return .failed("demuxer not open") }
        var status = readFrameTimed(ctx, packet)
        // M6: only AVERROR_EOF means the stream ended. Anything else is a
        // read failure — retry briefly (FFmpegNetworkTransport already
        // retries transient socket errors on its own; this covers errors
        // that surface past those retries), then report it instead of
        // silently ending playback mid-file.
        var attempts = 0
        while status < 0, status != avErrorEOF, !isInterrupted, attempts < 2 {
            attempts += 1
            Thread.sleep(forTimeInterval: 0.2 * Double(attempts))
            status = readFrameTimed(ctx, packet)
        }
        if status == avErrorEOF || isInterrupted {
            // Delayed pictures still inside libavcodec are the decode stage's
            // to drain; it owns the decoder.
            //
            // Hand the audio decoder's tail (coalesced partial buffer) to the
            // renderer before declaring the end.
            if !didDrainAudioAtEOF {
                didDrainAudioAtEOF = true
                if selectedAudioStreamIndex >= 0,
                   let decoder = audioDecoders[selectedAudioStreamIndex] {
                    let tail = decoder.drain()
                    if !tail.isEmpty {
                        return .audio(tail, streamIndex: selectedAudioStreamIndex)
                    }
                }
            }
            return .endOfFile
        }
        if status < 0 {
            return .failed(Self.errorText(status))
        }
        defer { av_packet_unref(packet) }
        // Before anything reads them: the timeline, the renderers, the cache
        // anchor and the progress report all speak media time from zero.
        if let offset = streamStartOffsets[packet.pointee.stream_index] {
            if packet.pointee.pts != avNoPTS {
                packet.pointee.pts -= offset
            }
            if packet.pointee.dts != avNoPTS {
                packet.pointee.dts -= offset
            }
        }
        let streamIndex = packet.pointee.stream_index

        if streamIndex == videoStreamIndex {
            let timestamp = packet.pointee.pts != avNoPTS
                ? packet.pointee.pts
                : packet.pointee.dts
            if timestamp != avNoPTS {
                let seconds = Double(timestamp)
                    * Double(videoTimeBase.num) / Double(max(videoTimeBase.den, 1))
                cachedIO?.setTimelineAnchor(
                    byteOffset: packet.pointee.pos,
                    seconds: seconds,
                    duration: durationSeconds
                )
            }
        }

        if streamIndex == videoStreamIndex, outputsDecodedVideo {
            // Detached from the reusable packet the `defer` above unrefs, so
            // the decode stage can hold it past this read. A clone shares
            // FFmpeg's buffer; it does not copy the access unit.
            guard let detached = SoftwareVideoPacket(cloning: packet, timeBase: videoTimeBase) else {
                return .failed("out of memory copying a video packet")
            }
            return .videoPacket(detached)
        }
        if streamIndex == videoStreamIndex, let description = videoStream?.formatDescription {
            // Start codes become length prefixes before anything downstream
            // sees the payload, so the filter below and VideoToolbox itself
            // read one framing.
            var strippedPayload: Data?
            if videoUsesStartCodes, let data = packet.pointee.data {
                strippedPayload = AnnexBStream.lengthPrefixed(
                    UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size))
                )
            }
            if let lengthSize = videoNALLengthSize {
                let filtered: Data? = if let converted = strippedPayload {
                    converted.withUnsafeBytes {
                        rewrittenDolbyVisionPayload(payload: $0, lengthSize: lengthSize)
                    }
                } else if let data = packet.pointee.data {
                    rewrittenDolbyVisionPayload(
                        payload: UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)),
                        lengthSize: lengthSize
                    )
                } else {
                    nil
                }
                if let filtered {
                    strippedPayload = filtered
                }
            }
            // Snap the presentation stamp onto the exact frame grid;
            // decode stamps stay the container's (ordering only).
            var timing: CMSampleTimingInfo?
            if videoTimeline != nil, packet.pointee.pts != avNoPTS {
                let containerSeconds = Double(packet.pointee.pts)
                    * Double(videoTimeBase.num) / Double(max(videoTimeBase.den, 1))
                if let snapped = videoTimeline!.snapped(containerSeconds: containerSeconds) {
                    let scaledDTS = packet.pointee.dts == avNoPTS
                        ? nil
                        : packet.pointee.dts.multipliedReportingOverflow(by: Int64(videoTimeBase.num))
                    let dts: CMTime = if let scaledDTS, !scaledDTS.overflow {
                        CMTime(value: scaledDTS.partialValue, timescale: max(videoTimeBase.den, 1))
                    } else {
                        .invalid
                    }
                    timing = CMSampleTimingInfo(
                        duration: videoTimeline!.frameDuration,
                        presentationTimeStamp: snapped,
                        decodeTimeStamp: dts
                    )
                }
            }
            // Ahead of the frame-grid snap below, so a dropped
            // packet never anchors the timeline on a stamp that is about to
            // be stepped backwards over.
            if case .drop = postSeekVideoDecision(packet: packet, payload: strippedPayload) {
                return .skipped
            }
            guard let buffer = SampleBufferFactory.sampleBuffer(
                packet: packet,
                formatDescription: description,
                timeBase: videoTimeBase,
                isVideo: true,
                fallbackDuration: 0,
                isKeyFrame: packet.pointee.flags & keyPacketFlag != 0,
                timingOverride: timing,
                payloadOverride: strippedPayload,
                markDroppableFrames: markDroppableFrames
            ) else { return .skipped }
            return .video(buffer)
        }
        if let decoder = audioDecoders[streamIndex] {
            let buffers = decoder.decode(packet: packet)
            return buffers.isEmpty ? .skipped : .audio(buffers, streamIndex: streamIndex)
        }
        if let audio = audioStreams.first(where: { $0.streamIndex == streamIndex }),
           let description = audio.formatDescription,
           let timeBase = audioTimeBases[streamIndex] {
            // Sample-exact pts for passthrough audio — the
            // container's quantized stamp only anchors the chain.
            let ptsValue = packet.pointee.pts != avNoPTS ? packet.pointee.pts : packet.pointee.dts
            let containerSeconds: Double? = ptsValue == avNoPTS
                ? nil
                : Double(ptsValue) * Double(timeBase.num) / Double(max(timeBase.den, 1))
            let timing = passthroughTimelines[streamIndex]?.timing(containerSeconds: containerSeconds)
            if let timeline = passthroughTimelines[streamIndex], timeline.lastPacketWasOverlapping {
                audioDropLock.lock()
                audioDroppedPackets += 1
                worstAudioOverlapSeconds = max(worstAudioOverlapSeconds, timeline.lastOverlapSeconds)
                droppedAudioPacketSeconds = timeline.packetSeconds
                audioDropLock.unlock()
                return .skipped
            }
            guard let buffer = SampleBufferFactory.sampleBuffer(
                packet: packet,
                formatDescription: description,
                timeBase: timeBase,
                isVideo: false,
                fallbackDuration: audio.fallbackPacketDuration,
                isKeyFrame: true,
                timingOverride: timing
            ) else { return .skipped }
            return .audio([buffer], streamIndex: streamIndex)
        }
        if let decoder = subtitleDecoders[streamIndex] {
            let events = decoder.decode(packet: packet)
            return events.isEmpty ? .skipped : .subtitle(events, streamIndex: streamIndex)
        }
        return .skipped
    }

    func close() {
        if packet != nil {
            av_packet_free(&packet)
        }
        if formatContext != nil {
            avformat_close_input(&formatContext)
        }
        cachedIO?.close()
        cachedIO = nil
        transport?.closeAll()
        transport = nil

        // These wrappers free AVCodecContext/SWR resources in deinit.
        // close() runs on the demux queue; clearing them here prevents that
        // C teardown from being deferred until the main-actor engine is
        // released after dismissal.
        audioDecoders.removeAll(keepingCapacity: false)
        subtitleDecoders.removeAll(keepingCapacity: false)
        softwareVideoDecoder = nil
        audioStreams.removeAll(keepingCapacity: false)
        subtitleStreams.removeAll(keepingCapacity: false)
        videoStream = nil
    }

    private static func metadata(_ stream: UnsafeMutablePointer<AVStream>, key: String) -> String? {
        guard let entry = av_dict_get(stream.pointee.metadata, key, nil, 0),
              let value = entry.pointee.value else { return nil }
        return String(cString: value)
    }

    private static func errorText(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        av_strerror(code, &buffer, buffer.count)
        return String(cString: buffer)
    }
}
