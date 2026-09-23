import CoreMedia
import CoreVideo
import Foundation
import Libavcodec
import Libavformat
import Libavutil

// Thin wrapper over libavformat. Call only on the engine's demux queue;
// nothing here is thread-safe. FFmpeg sentinels are redefined below because
// their macros do not import.
/// Where a container's timeline begins.
///
/// MPEG-TS can start anywhere (one Blu-ray starts at 4198 s), but everything
/// above the demuxer expects zero, so the origin is subtracted from every
/// packet and added back onto every seek.
nonisolated enum ContainerTimeline {
    /// AV_TIME_BASE, the unit `AVFormatContext.start_time` is expressed in.
    static let microsecondsPerSecond = 1_000_000.0

    /// How much to take off a stream's timestamps, in its own time base.
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

    /// Stage and AVERROR for the diagnostic report.
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

    /// Open and seek failures are delivery problems (a remux may fix them);
    /// an unsupported codec is not.
    var cause: PlaybackEngineFailure.Cause {
        switch self {
        case .openFailed, .seekFailed: .delivery
        case .unsupportedVideo: .undecodable
        }
    }
}

/// AC-3 alongside software-decoded video is decoded to LPCM: passed through,
/// it interrupted audio and grew memory on tvOS. Everything else keeps
/// passthrough.
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
    /// FFmpeg reported an Atmos profile (E-AC3 JOC or TrueHD Atmos).
    let isAtmos: Bool
    /// nil only for subtitle streams, which render as an overlay.
    let formatDescription: CMFormatDescription?
    /// Seconds, for audio packets that arrive without a duration.
    let fallbackPacketDuration: Double
    /// Video reorder depth from libavformat; zero when there is none.
    let videoReorderDepth: Int
}

nonisolated final class FFmpegDemuxer {
    enum ReadResult {
        case video(CMSampleBuffer)
        /// A compressed access unit for the software decode stage.
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
    /// `-debug.disableAudio YES` opens with no audio, to isolate video's CPU
    /// cost in a trace. Diagnostic only.
    private static let audioDisabledForDiagnostics: Bool = {
        guard let value = SoftwareDecodeThreadPolicy.commandLineString(forKey: "debug.disableAudio") else {
            return false
        }
        return ["yes", "true", "1"].contains(value.lowercased())
    }()
    private var didDrainAudioAtEOF = false
    // Codecs CoreAudio can't take compressed are decoded to LPCM.
    private var audioDecoders: [Int32: AudioDecoder] = [:]
    private var subtitleDecoders: [Int32: SubtitleDecoder] = [:]
    // Sample-exact timing for passthrough audio; see `PassthroughAudioTimeline`.
    private var passthroughTimelines: [Int32: PassthroughAudioTimeline] = [:]
    // Removes Matroska's millisecond quantization from video PTS.
    private var videoTimeline: VideoFrameTimeline?
    /// Built here from the codec parameters, then taken by the engine, which
    /// runs it on its own queue. The demuxer never decodes video.
    private var softwareVideoDecoder: SoftwareVideoDecoder?
    private var softwareGridDescription: String?

    /// How Dolby Vision profile 7 is handled. Set before `open`.
    var dolbyVisionProfile7Mode: DolbyVisionProfile7Mode = .convert
    /// Armed by the open-time gate in `.convert` mode; demux-queue use only.
    private var profile7Converter: DolbyVisionProfileConverter?
    /// Marks disposable frames droppable; see the attachment comment in
    /// `SampleBufferFactory.sampleBuffer`. Set before `open`.
    var markDroppableFrames = false
    /// Non-nil when a profile 7 rewrite is armed. Demux queue only.
    private var videoNALLengthSize: Int?
    /// Set when video is start-code delimited (MPEG-TS).
    private var videoUsesStartCodes = false
    /// Lets a post-seek packet be checked as a decoder start point. Both nil
    /// for software-decoded video and unreadable codecs, which skip the check.
    private var videoRandomAccessCodec: VideoRandomAccessPoint.Codec?
    private var videoPayloadNALLengthSize: Int?
    /// Where a seek left the video stream. Demux-queue use only.
    private var postSeekVideoFilter: PostSeekVideoFilter = .idle
    /// Per stream, the container origin to subtract from its timestamps.
    private var streamStartOffsets: [Int32: Int64] = [:]
    // Strip mode's stats: written on the demux queue, read by the HUD.
    // Convert mode reports the converter's own instead.
    private let stripStatsLock = NSLock()
    nonisolated(unsafe) private var stripStats: DolbyVisionRewriteStats?

    /// This playback's profile 7 rewrite, or nil when none is armed.
    var dolbyVisionRewriteStats: DolbyVisionRewriteStats? {
        if let profile7Converter {
            return profile7Converter.stats
        }
        stripStatsLock.lock()
        defer { stripStatsLock.unlock() }
        return stripStats
    }

    /// Audio packets `PassthroughAudioTimeline` rejected as overlapping; the
    /// only place this loss is visible. A worst overlap under one packet is a
    /// boundary repeat; far above is a real jump being muted.
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
    /// Best-guess frame rate for display matching; 0 when unknown.
    private(set) var videoFrameRate: Double = 0
    /// The pts grid in force, for the HUD (demux queue only).
    var videoGridDescription: String? {
        softwareGridDescription ?? videoTimeline?.gridDescription
    }
    /// Whether video goes to libavcodec rather than an Apple decoder. Stored,
    /// because the decoder is handed away.
    private(set) var outputsDecodedVideo = false

    /// For a reopen after VideoToolbox refused AV1. Call before `open`.
    func disableVideoToolboxAV1() {
        routesAV1ToVideoToolbox = false
    }

    private var routesAV1ToVideoToolbox = true

    /// Hands the software decoder to the caller, once.
    func takeSoftwareVideoDecoder() -> SoftwareVideoDecoder? {
        defer { softwareVideoDecoder = nil }
        return softwareVideoDecoder
    }

    /// Wall time in `av_read_frame` and packets read, since the last seek.
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

    public init(capabilities: PlaybackCapabilities = .current) {
        self.capabilities = capabilities
    }

    /// Whether a stream goes to VideoToolbox compressed or is decoded in
    /// software. AV1 is settled per stream at session creation.
    ///
    /// Interlaced H.264 goes to software, the only path with a deinterlacer;
    /// VideoToolbox would comb on motion. HEVC has no software route.
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

    /// Whether a field order is interlaced. Unknown counts as progressive,
    /// so H.264 is not taken off hardware for nothing.
    static func isInterlaced(fieldOrder: AVFieldOrder) -> Bool {
        switch fieldOrder {
        case AV_FIELD_TT, AV_FIELD_BB, AV_FIELD_TB, AV_FIELD_BT:
            true
        default:
            false
        }
    }

    /// Rates a display can match. A header that rounds one of these to the
    /// millisecond is corrected back to it.
    private static let standardFrameRates: [AVRational] = [
        AVRational(num: 24_000, den: 1001), AVRational(num: 24, den: 1),
        AVRational(num: 25, den: 1), AVRational(num: 30_000, den: 1001),
        AVRational(num: 30, den: 1), AVRational(num: 48_000, den: 1001),
        AVRational(num: 48, den: 1), AVRational(num: 50, den: 1),
        AVRational(num: 60_000, den: 1001), AVRational(num: 60, den: 1),
    ]

    /// The rate to snap timestamps to and ask the display for.
    ///
    /// Some Matroska muxers write the default frame duration rounded to the
    /// millisecond, so 23.976 fps is declared as 42 ms, 23.81 fps, and
    /// FFmpeg's guess trusts it. The display refuses a 23.81 Hz mode and
    /// stays at 60 Hz, and the frame grid drifts off the real stamps. When a
    /// whole-millisecond duration on a 1 ms time base is what a standard
    /// rate rounds to, and the frame count and duration statistics mkvmerge
    /// writes agree with that rate, the standard rate wins. Without the
    /// statistics nothing tells 23.976 from 24, so the guess stands.
    static func correctedFrameRate(
        guessed: AVRational,
        timeBase: AVRational,
        frameCountTag: String?,
        durationTag: String?
    ) -> AVRational {
        guard guessed.num > 0, guessed.den > 0,
              timeBase.num == 1, timeBase.den == 1000 else { return guessed }
        let declaredMilliseconds = 1000 * Double(guessed.den) / Double(guessed.num)
        guard abs(declaredMilliseconds - declaredMilliseconds.rounded()) < 1e-9,
              let frameCount = frameCountTag.flatMap({ Double($0) }), frameCount > 0,
              let duration = durationTag.flatMap(Self.seconds(statisticsDuration:)), duration > 0 else {
            return guessed
        }
        let measured = frameCount / duration
        // 23.976 and 24 differ by 0.1%; the tolerance must stay under half that.
        let match = standardFrameRates
            .map { (rate: $0, fps: Double($0.num) / Double($0.den)) }
            .filter { (1000 / $0.fps).rounded() == declaredMilliseconds.rounded() }
            .filter { abs(measured - $0.fps) / $0.fps < 0.0004 }
            .min { abs(measured - $0.fps) < abs(measured - $1.fps) }
        return match?.rate ?? guessed
    }

    /// Seconds in a Matroska statistics `DURATION` tag, `HH:MM:SS.nnnnnnnnn`.
    static func seconds(statisticsDuration tag: String) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    func outputsDecodedAudio(streamIndex: Int32) -> Bool {
        audioDecoders[streamIndex] != nil
    }

    // Set at shutdown, polled by FFmpeg's interrupt callback inside blocked
    // I/O, so a wedged open or read cannot hang teardown.
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
            // One cleanup path for every throw. avformat_open_input updates
            // this pointer and frees it on failure.
            if !completedOpen { close() }
        }
        allocated.pointee.interrupt_callback = AVIOInterruptCB(
            callback: { opaque in
                guard let opaque else { return 0 }
                return Unmanaged<FFmpegDemuxer>.fromOpaque(opaque).takeUnretainedValue().isInterrupted ? 1 : 0
            },
            opaque: Unmanaged.passUnretained(self).toOpaque()
        )
        // Every http(s) open, including HLS children, goes through this
        // transport; libavformat has no network stack. With a custom `pb`
        // below, the root never calls io_open.
        let transport = FFmpegNetworkTransport(
            isInterrupted: { [weak self] in self?.isInterrupted ?? true },
            hlsCache: cacheSession?.hlsScope,
            authorization: authorization
        )
        self.transport = transport
        transport.install(on: allocated)
        if let disc, let cacheScope = cacheSession?.directScope {
            // Mount the disc image, pick the title, and hand libavformat its
            // clips end to end. Failures here are delivery failures.
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

        // Without FFmpeg's HTTP protocol, persistent HLS connections leak one
        // AVIOContext per segment. Off, hls.c closes each via io_close2.
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

        // Use the format's origin, not each stream's, to keep the offsets
        // between streams: a late-starting audio track is content, not clock.
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

        // In an HLS master each variant is a program. Keep only the chosen
        // video's program, or other variants duplicate the track list and
        // keep downloading.
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
        let guessedRate = Self.correctedFrameRate(
            guessed: av_guess_frame_rate(ctx, stream, nil),
            timeBase: stream.pointee.time_base,
            frameCountTag: Self.metadata(stream, key: "NUMBER_OF_FRAMES")
                ?? Self.metadata(stream, key: "NUMBER_OF_FRAMES-eng"),
            durationTag: Self.metadata(stream, key: "DURATION")
                ?? Self.metadata(stream, key: "DURATION-eng")
        )
        if guessedRate.num > 0, guessedRate.den > 0 {
            videoFrameRate = Double(guessedRate.num) / Double(guessedRate.den)
        }
        let videoIsInterlaced = Self.isInterlaced(fieldOrder: videoPar.pointee.field_order)
        let usesCompressedVideo = Self.usesCompressedVideoPath(
            codecID: videoPar.pointee.codec_id,
            capabilities: capabilities,
            interlaced: videoIsInterlaced
        ) && (videoPar.pointee.codec_id != AV_CODEC_ID_AV1 || routesAV1ToVideoToolbox)
        // Catch missing or Annex B parameter sets before building the
        // description: it builds either way and only the decoder refuses,
        // looking like "no hardware decoder". See `AnnexBStream`.
        let annexBParameterSets = usesCompressedVideo
            ? annexBParameterSets(codecpar: videoPar)
            : nil
        videoUsesStartCodes = annexBParameterSets != nil
        let harvestedParameterSets = usesCompressedVideo && annexBParameterSets == nil
            ? harvestedHEVCParameterSets(ctx: ctx, streamIndex: bestVideo, codecpar: videoPar)
            : nil
        // Converted start-code streams always carry four-byte lengths.
        let filterNALLengthSize: Int? = videoUsesStartCodes
            ? Int(AnnexBStream.nalUnitHeaderLength)
            : videoPar.pointee.extradata.flatMap { extradata in
                videoPar.pointee.extradata_size > 0
                    ? HEVCNALUnitRewriter.nalLengthSize(
                        hvcc: Data(bytes: extradata, count: Int(videoPar.pointee.extradata_size))
                    )
                    : nil
            }
        // Dolby Vision profile 7: convert to 8.1 or strip to HDR10 (see
        // `DolbyVisionProfileConverter`). Needs a known NAL length size.
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
            // The only length-prefixed NAL codecs on the compressed path.
            switch videoPar.pointee.codec_id {
            case AV_CODEC_ID_H264: videoRandomAccessCodec = .h264
            case AV_CODEC_ID_HEVC: videoRandomAccessCodec = .hevc
            default: videoRandomAccessCodec = nil
            }
            if let codec = videoRandomAccessCodec {
                // Converted start-code payloads carry four-byte lengths.
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
                // Passthrough codecs stay compressed; the rest decode to
                // LPCM. Only codecs FFmpeg cannot decode are dropped.
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
                // List every subtitle stream, decodable or not, so per-type
                // ordinals match the host's stream list. Unselected streams
                // stay discarded.
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

    /// Demuxes only the chosen audio stream; libavformat discards the rest.
    func selectAudio(streamIndex: Int32?) {
        guard let ctx = formatContext else { return }
        selectedAudioStreamIndex = streamIndex ?? -1
        for stream in audioStreams {
            ctx.pointee.streams[Int(stream.streamIndex)]?.pointee.discard =
                stream.streamIndex == streamIndex ? AVDISCARD_DEFAULT : AVDISCARD_ALL
        }
    }

    /// Discards video during background audio-only playback.
    func setVideoDiscarded(_ discarded: Bool) {
        guard let ctx = formatContext, let videoStream else { return }
        ctx.pointee.streams[Int(videoStream.streamIndex)]?.pointee.discard =
            discarded ? AVDISCARD_ALL : AVDISCARD_DEFAULT
    }

    /// The same for embedded subtitles; nil when off or external.
    func selectSubtitle(streamIndex: Int32?) {
        guard let ctx = formatContext else { return }
        for stream in subtitleStreams {
            ctx.pointee.streams[Int(stream.streamIndex)]?.pointee.discard =
                stream.streamIndex == streamIndex ? AVDISCARD_DEFAULT : AVDISCARD_ALL
        }
    }

    /// Packets to read looking for in-band parameter sets. They open the first
    /// video access unit, so this only covers interleaved audio before it.
    private static let parameterSetProbeLimit = 64

    /// Parameter sets from a start-code delimited record (MPEG-TS); nil for
    /// length-prefixed containers.
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

    /// VPS, SPS and PPS read from the bitstream, for an HEVC track whose
    /// `hvcC` declares none. Rewinds afterwards, since the demux loop has not
    /// started. nil (no reads) for a complete `hvcC`.
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
              // The header's length size is valid even with no arrays.
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

        // Rewind either way. Failing costs the opening packets, not fatal.
        if avformat_seek_file(ctx, streamIndex, Int64.min, 0, 0, 0) < 0 {
            _ = av_seek_frame(ctx, streamIndex, 0, seekBackwardFlag)
        }

        // VPS, SPS, PPS, in decoder order.
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
        // Seek on the video stream's clock, not stream -1: HLS may default
        // to a separate audio rendition, leaving video behind. Add the
        // container origin back.
        let timestamp = Int64(
            seconds * Double(videoTimeBase.den) / Double(max(videoTimeBase.num, 1))
        ) + (streamStartOffsets[videoStreamIndex] ?? 0)
        // `avformat_seek_file` moves split HLS audio and video together; the
        // legacy seek could leave them apart. max_ts = target asks for the
        // keyframe at or before it.
        try Self.validateSeekStatus(reposition(ctx, to: timestamp))
        // A container with no index may land on any packet.
        alignLandingToKeyframe(ctx, target: timestamp)
        // The landing may not be a decoder start point, and packets right
        // behind it may present before it. Decided on the first video packet.
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
        // Not the software decoder: the decode stage resets it on its own
        // queue, and flushing here would touch libavcodec from two queues.
        for decoder in subtitleDecoders.values {
            decoder.flush()
        }
        ioLock.withLock {
            ioReadSeconds = 0
            ioPackets = 0
            ioStartedAt = nil
        }
    }

    /// `avformat_seek_file`, falling back to `av_seek_frame` for demuxers
    /// without it.
    private func reposition(_ ctx: UnsafeMutablePointer<AVFormatContext>, to timestamp: Int64) -> Int32 {
        let status = avformat_seek_file(ctx, videoStreamIndex, Int64.min, timestamp, timestamp, 0)
        return status < 0 ? av_seek_frame(ctx, videoStreamIndex, timestamp, seekBackwardFlag) : status
    }

    /// Seconds a mid-GOP landing searches back for its keyframe; widened
    /// once for long GOPs.
    private static let landingSearchWindows: [Double] = [8, 24]
    /// Packets one search pass may read, in case timestamps never reach the
    /// target. 24 s at 24 fps is ~580 video packets plus audio.
    private static let landingSearchPacketBudget = 4_000
    /// Seconds before the keyframe's decode stamp to seek to, so the binary
    /// search cannot step past it. The read path drops forward onto it.
    private static let landingSeekMargin = 0.5
    /// Packets to read for a landing's first video packet.
    private static let landingProbePacketBudget = 480

    /// Walks a mid-GOP seek back to the last keyframe at or before the target.
    ///
    /// MPEG-TS has no index, so the binary search often lands mid-GOP. The
    /// renderer then fails the first sample (-8969), which the ladder reads
    /// as `.undecodable`.
    ///
    /// *At or before*: `PlaybackClockAnchor` holds the clock at the target and
    /// the audio floor drops the run-in, so early costs a decode burst where
    /// late would skip content.
    ///
    /// Seekable byte streams only. `AVFMT_NOFILE` demuxers fetch their own
    /// media, and HLS lands on segment boundaries, which are keyframes.
    private func alignLandingToKeyframe(_ ctx: UnsafeMutablePointer<AVFormatContext>, target: Int64) {
        guard videoRandomAccessCodec != nil, videoStreamIndex >= 0,
              let format = ctx.pointee.iformat, format.pointee.flags & noFileFormatFlag == 0,
              let byteStream = ctx.pointee.pb, byteStream.pointee.seekable != 0,
              let probe = av_packet_alloc() else { return }
        var owned: UnsafeMutablePointer<AVPacket>? = probe
        defer { av_packet_free(&owned) }
        // Usually a keyframe: reposition once to undo the probe's reads.
        guard landingIsMidGOP(ctx, probe: probe) else {
            _ = reposition(ctx, to: target)
            return
        }
        let ticksPerSecond = Double(videoTimeBase.den) / Double(max(videoTimeBase.num, 1))
        // Container clock throughout: origin not yet removed.
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
        // No keyframe in reach: the read path drops forward to the next one.
        _ = reposition(ctx, to: target)
    }

    /// Whether the landing's first video packet is not a keyframe. The
    /// caller repositions afterwards.
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
    /// `target`, reading forward from the cursor. Presentation time decides
    /// "early enough"; decode time is returned because an unindexed seek
    /// compares decode stamps. The post-seek filter still handles open GOPs.
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

    /// `av_read_frame`, timed: the transport cost (cache or network), kept
    /// apart from decode.
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

    /// Rewrites one video payload for the armed profile 7 mode. Strip mode
    /// calls `rewrite` directly, not `strippingEnhancementLayer`, to count
    /// RPU and EL units separately.
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
        /// The next video packet is where the decoder restarts.
        case awaitingAnchor
        /// Landed mid-GOP; dropping until a start point.
        case droppingToKeyframe(dropped: Int)
        /// Landed on an *open* GOP keyframe. Pictures after it in decode
        /// order but presented before it reference the flushed GOP.
        case droppingLeadingPictures(anchor: Int64, dropped: Int)
    }

    /// Cap on dropped leading pictures (real open GOPs have about two), so a
    /// stream with bad timestamps keeps its video.
    private static let leadingPictureDropLimit = 32

    /// Whether to drop this packet after a seek.
    ///
    /// Leading pictures of an open GOP reference the GOP the flush destroyed.
    /// Apple's decoder fails them (libavcodec does not), and the ladder would
    /// read `.undecodable` and transcode. They present before the target, so
    /// dropping them loses nothing. Only armed for a non-IDR/IRAP keyframe.
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
                // Past the anchor: trailing pictures from here.
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

    /// Cap on packets dropped looking for a keyframe, so a stream that never
    /// flags one keeps its video.
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
            // Mid-GOP: references flushed pictures. Drop to the next start.
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
            // Open GOP: keep it, drop the pictures presented before it.
            postSeekVideoFilter = .droppingLeadingPictures(anchor: anchor, dropped: 0)
            return .keep
        default:
            // true: a clean start. nil: cannot tell, so leave it alone.
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
        // Only AVERROR_EOF ends the stream. Other errors (past the
        // transport's own retries) retry briefly, then fail rather than end
        // playback silently.
        var attempts = 0
        while status < 0, status != avErrorEOF, !isInterrupted, attempts < 2 {
            attempts += 1
            Thread.sleep(forTimeInterval: 0.2 * Double(attempts))
            status = readFrameTimed(ctx, packet)
        }
        if status == avErrorEOF || isInterrupted {
            // The decode stage drains video. Emit the audio decoder's tail
            // before declaring the end.
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
        // First: everything downstream expects media time from zero.
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
            // Detached from the reusable packet so the decode stage can keep it.
            guard let detached = SoftwareVideoPacket(cloning: packet, timeBase: videoTimeBase) else {
                return .failed("out of memory copying a video packet")
            }
            return .videoPacket(detached)
        }
        if streamIndex == videoStreamIndex, let description = videoStream?.formatDescription {
            // Convert start codes first, so everything below sees one framing.
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
            // Drop mid-GOP and leading pictures after a seek. Before the snap,
            // so a dropped packet never anchors the frame grid.
            if case .drop = postSeekVideoDecision(packet: packet, payload: strippedPayload) {
                return .skipped
            }
            // Snap pts to the frame grid; dts stays the container's.
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
            // Sample-exact pts; the container stamp only anchors the chain.
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

        // Free decoder C resources here, on the demux queue, rather than
        // whenever the engine is released.
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
