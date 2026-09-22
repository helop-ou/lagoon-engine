import Synchronization
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import OSLog

/// The Lagoon playback engine: libavformat demux into CMSampleBuffers rendered
/// by AVSampleBufferDisplayLayer / AVSampleBufferAudioRenderer under an
/// AVSampleBufferRenderSynchronizer.
///
/// h264 passes through compressed; HEVC and hardware AV1 decode with
/// VideoToolbox; other AV1, VP9 and legacy codecs software-decode to
/// NV12/P010. aac/mp3/ac3/eac3 pass through, other audio decodes to LPCM.
/// `DeviceProfile.lagoon` advertises exactly this, so anything else arrives
/// as an fMP4 HLS transcode.
///
/// Threading: state and transport on the main actor; demux on its own serial
/// queue, feeding two thread-safe queues the renderers' pumps drain.
@Observable
public final class SampleBufferPlayerEngine: PlayerEngine, PlayerEngineDiagnostics {
    private(set) public var timePosition: Double = 0
    private(set) public var duration: Double = 0
    private(set) public var isPaused = false
    private(set) public var isBuffering = true
    private(set) public var rate: Double = 1
    /// Sync correction on top of `rate`; 1 outside a SyncPlay group. The
    /// synchronizer only ever gets `effectiveRate`.
    @ObservationIgnored private(set) var correctionRate: Double = 1
    private(set) public var videoSize: CGSize?
    private(set) public var audioTracks: [PlayerTrack] = []
    private(set) public var subtitleTracks: [PlayerTrack] = []
    private(set) public var subtitleLoadState: SubtitleLoadState = .idle
    public var subtitleSelectionRevision: Int { externalLoadToken }
    private(set) public var currentSubtitleText: String?
    private(set) public var currentSubtitleCues: [SubtitleTextCue] = []
    private(set) public var currentSubtitleImages: [SubtitleImage] = []
    /// Positive delays the audio, as in mpv.
    private(set) public var audioDelay: Double = 0
    /// HUD line: the selected audio stream as the demuxer sees it (codec,
    /// channels, FFmpeg's Atmos/JOC verdict).
    public private(set) var audioDiagnostic: String?
    private(set) public var audioOutputPathDiagnostic = "compressed"
    public private(set) var videoPerformance: VideoPerformanceSnapshot?
    private(set) public var stallCount = 0
    /// Stalls confirmed as audio-caused; a subset of `stallCount`.
    private(set) public var audioStallCount = 0
    /// Episodes with no audio scheduled ahead of the clock. Counted whether
    /// or not `buffersOnAudioStarvation` also stops the clock.
    private(set) public var audioStarvationCount = 0
    /// Off by default: audio starvation is counted but never stops the
    /// clock. Keep it off until hardware shows a healthy title's lead well
    /// above `PlaybackStarvationPolicy.audioFloorSeconds`.
    public let buffersOnAudioStarvation = EngineTuning.current.buffersOnAudioStarvation
    /// Stall recovery should refill in place. This counts the five-second
    /// seek fallback, so a regression run can prove whether it was needed.
    private(set) public var stallReprimeCount = 0
    /// Session-scoped, so the regression probe can prove an injected
    /// AVFoundation event took the same path as a real notification.
    private(set) public var audioRendererRecoveryCount = 0
    private(set) public var mediaServicesResetRecoveryCount = 0
    /// Frame-loss bench progress for the HUD; nil unless the bench is on.
    public private(set) var benchStatus: String?
    /// True once a bench window freezes its result, so a scripted run can
    /// leave through the clean teardown path instead of being killed.
    public private(set) var benchCompleted = false
    /// Display-matching request, published once the stream is known. The
    /// player view applies it.
    private(set) public var displayMatchRequest: DisplayMatchRequest?
    /// "grid 24000/1001" when video pts are snapped to the exact frame
    /// grid, nil when container stamps pass through.
    public private(set) var videoTimingDiagnostic: String?

    /// The media clock as the synchronizer reports it.
    /// While the clock is stopped for a load or seek, answers with the
    /// position being headed for, which a group Buffering report needs.
    public var clockPosition: Double {
        if isBuffering { return bufferingTargetSeconds ?? timePosition }
        let seconds = synchronizer.currentTime().seconds
        return seconds.isFinite ? seconds : timePosition
    }

    /// The viewer's rate with sync correction folded in: the speed the clock
    /// really drains at. Scale every media-time cushion by this.
    private var effectiveRate: Double {
        PlaybackRatePolicy.effectiveRate(userRate: rate, correction: correctionRate)
    }

    public var queueDepths: (video: Int, audio: Int) {
        (videoQueue.count, audioQueue.count)
    }

    /// Seconds of audio queued on the engine's side. A demux-backpressure
    /// input only: AVFoundation drains it to zero while keeping its own
    /// queue, so it cannot show starvation.
    public var audioBufferedSeconds: Double { audioQueue.bufferedDuration }
    /// Media time handed to AVFoundation beyond the clock. The starvation
    /// signal: it stays positive after the engine's queue drains.
    public var audioDeliveryLeadSeconds: Double {
        guard let deliveredThrough = shared.withLock({ $0.lastEnqueuedAudioEndSeconds }) else {
            return -1
        }
        return deliveredThrough - timePosition
    }
    public var audioRendererReadyForPlayback: Bool {
        audioRenderer?.hasSufficientMediaDataForReliablePlaybackStart ?? false
    }
    #if DEBUG
    private(set) public var audioDeliverySuspendedForDiagnostics = false
    private(set) public var demuxDeliverySuspendedForDiagnostics = false
    /// A simulated fault fires once per engine, not on every re-prime
    /// (`onPlaybackStarted` also runs after a seek).
    @ObservationIgnored private var didSimulateAudioStarvation = false
    @ObservationIgnored private var didSimulateDeliveryStall = false
    #endif
    public var videoQueueCountDiagnostic: Int {
        videoQueue.count + (softwareDecodeStage?.pendingCount ?? 0)
    }
    public var maximumVideoBacklogDiagnostic: Int {
        shared.withLock { $0.maximumVideoBacklog }
    }
    public var videoQueueHardLimitDiagnostic: Int {
        shared.withLock { $0.videoQueueHardLimit }
    }
    public var decodedVideoQueueCeiling: Int {
        DemuxBackpressurePolicy.videoHardLimit(videoIsDecoded: true)
    }
    public var videoIntakeCountDiagnostic: Int { videoIntake.count }
    /// Samples refused as a flushed renderer's first, for this attempt.
    public var videoStartPointDropDiagnostic: Int { shared.withLock { $0.videoStartPointDrops } }
    /// Media stamp of the last sample a renderer refused to decode.
    public var refusedSampleMsDiagnostic: Int? { shared.withLock { $0.lastRefusedSampleMs } }
    public var maximumVideoIntakeDiagnostic: Int { videoIntake.peakCount }
    /// A silent title must never wait in buffering for an audio cushion.
    private var hasAudioTrack: Bool { !audioTracks.isEmpty }
    /// Edge tracking for `audioStarvationCount`, which counts episodes
    /// rather than the 10 Hz observer ticks inside one.
    @ObservationIgnored private var wasAudioStarved = false
    /// The audio depth the demux loop aims for.
    public var audioCushionTarget: Int {
        DemuxBackpressurePolicy.audioCushionTarget(
            deliveryIsCached: shared.withLock { $0.deliveryIsCached }
        )
    }

    /// Timestamp gaps in the audio feed: measurable crackle. Should stay 0;
    /// growth means the renderer is fed a misaligned timeline.
    public var audioTimingGapCount: Int {
        audioContinuity.gapCount
    }

    /// Software decode cost: libavcodec, surface conversion and container
    /// reads, each as a share of one core (they do not sum to 100%).
    /// Cumulative since the last seek. Nil unless libavcodec decodes video.
    public var softwareDecodeDiagnostic: String? {
        guard let stage = softwareDecodeStage else { return nil }
        let profile = stage.profile
        guard profile.elapsedSeconds > 0, profile.frames > 0 else { return nil }
        let io = demuxer.ioProfile
        let readFraction = io.elapsedSeconds > 0 ? io.readSeconds / io.elapsedSeconds : 0
        // Cost per frame first: unlike a rate, it does not fall when the
        // decoder is throttled. `budget` is it as a share of one frame
        // period; at 100% or more the device cannot hold frame rate.
        let frameRate = demuxer.videoFrameRate > 0 ? demuxer.videoFrameRate : 24
        var line = String(
            format: "%.1f ms/frame · budget %.0f%% · decode %.1f · convert %.1f (surface %.1f) · %.1f fps now · read %.0f%% · pending %d",
            profile.frameMilliseconds,
            profile.decodeBudgetUsed(frameRate: frameRate) * 100,
            profile.decodeMilliseconds,
            profile.conversionMilliseconds,
            profile.surfaceMilliseconds,
            profile.recentFramesPerSecond,
            readFraction * 100,
            stage.pendingCount
        )
        line += " · \(stage.resolvedThreadCount) threads"
        line += " · \(stage.outputModeName)"
        if stage.outputsToneMappedSDR {
            line += " · SDR tone-mapped"
        }
        return line
    }

    /// The same three costs as one field for the bench's self-describing
    /// result line, where a console log is all a hardware run leaves behind.
    nonisolated public var softwareDecodeBenchField: String? {
        guard let stage = softwareDecodeStage else { return nil }
        let profile = stage.profile
        guard profile.elapsedSeconds > 0, profile.frames > 0 else { return nil }
        let io = demuxer.ioProfile
        let readFraction = io.elapsedSeconds > 0 ? io.readSeconds / io.elapsedSeconds : 0
        let frameRate = demuxer.videoFrameRate > 0 ? demuxer.videoFrameRate : 24
        return String(
            format: "frameMs=%.2f budget=%.3f decodeMs=%.2f convertMs=%.2f surfaceMs=%.2f fpsNow=%.2f fpsAvg=%.2f read=%.3f frames=%d threads=%d sdr=%@ output=%@",
            profile.frameMilliseconds,
            profile.decodeBudgetUsed(frameRate: frameRate),
            profile.decodeMilliseconds,
            profile.conversionMilliseconds,
            profile.surfaceMilliseconds,
            profile.recentFramesPerSecond,
            profile.framesPerSecond,
            readFraction,
            profile.frames,
            stage.resolvedThreadCount,
            stage.outputsToneMappedSDR ? "tonemapped" : "native",
            stage.outputModeName
        ) + " codec=\(stage.codecName) lowDelay=\(stage.lowDelayEnabled ? "on" : "off")"
            + " maxFrameDelay=\(stage.maxFrameDelay.map(String.init) ?? "unknown")"
            + " decoderDelay=\(stage.decoderDelay)"
    }

    /// Proof the Dolby Vision profile 7 rewrite engaged, for the HUD; nil
    /// until a profile 7 track appears.
    public var dolbyVisionRewriteInfo: String? {
        guard let stats = demuxer.dolbyVisionRewriteStats else { return nil }
        let megabytes = Double(stats.bytesRemoved) / 1_000_000
        switch stats.mode {
        case .convert:
            var line = String(
                format: "convert · %d RPU → 8.1 · %d EL dropped · %.1f MB",
                stats.rpusConverted,
                stats.enhancementUnitsDropped,
                megabytes
            )
            if stats.rpusDropped > 0 {
                line += " · \(stats.rpusDropped) RPU dropped"
            }
            if let elType = stats.enhancementLayerType {
                line += " · \(elType)"
            }
            line += " · errors \(stats.errors)"
            return line
        case .stripToHDR10:
            return String(
                format: "HDR10 fallback · %d units dropped · %.1f MB",
                stats.rpusDropped + stats.enhancementUnitsDropped,
                megabytes
            )
        }
    }

    /// Passthrough audio the demuxer dropped before any renderer saw it; nil
    /// until something drops. `aGaps` cannot see this path, so drops here
    /// are a different fault from `aGaps` climbing.
    public var audioPacketDropInfo: String? {
        guard let stats = demuxer.audioPacketDropStats, stats.packetSeconds > 0 else { return nil }
        return String(
            format: "%d pkts · worst %.1f× packet (%.0f ms)",
            stats.packets,
            stats.worstOverlapSeconds / stats.packetSeconds,
            stats.worstOverlapSeconds * 1000
        )
    }

    @ObservationIgnored public var onFinished: (() -> Void)?
    /// The clock moved: `timePosition` and `duration`, on the main actor
    /// every 0.1 s. Timed host decisions hang off this rather than a view
    /// body, so they run with the screen locked.
    @ObservationIgnored public var onTimeAdvanced: ((Double, Double) -> Void)?
    /// Playback could not continue. The failure's cause says whether another
    /// delivery of the same media might work.
    @ObservationIgnored public var onError: ((PlaybackEngineFailure) -> Void)?

    /// Extra `key="value"` fragments a host wants on the bench result line,
    /// such as display-match state, which the host owns.
    @ObservationIgnored var benchGatesSupplement: (() -> String)?
    @ObservationIgnored public var onTrackSelectionChanged: (() -> Void)?
    /// Fires once the first audio/video cushion is enqueued and the clock
    /// anchored: user-visible readiness, not merely an open.
    @ObservationIgnored public var onPlaybackStarted: (() -> Void)?
    /// Fires every time the clock is anchored after a load or a seek, unlike
    /// one-shot `onPlaybackStarted`. SyncPlay reports Ready on it.
    @ObservationIgnored public var onSeekReady: (() -> Void)?
    /// Buffering began or ended (a stall, a seek, the first prime), fired
    /// only on a change. A SyncPlay group waits for its slowest member, so
    /// it must hear about stalls the engine recovers from on its own.
    @ObservationIgnored public var onBufferingChanged: ((Bool) -> Void)?
    // MARK: Cross-thread state

    @ObservationIgnored nonisolated private let demuxer = FFmpegDemuxer()
    @ObservationIgnored nonisolated private let videoQueue = SampleBufferQueue()
    @ObservationIgnored nonisolated private let audioQueue = SampleBufferQueue()
    @ObservationIgnored nonisolated private let demuxQueue = DispatchQueue(label: "ee.helop.lagoon.demux", qos: .userInitiated)
    @ObservationIgnored nonisolated private let pumpQueue = DispatchQueue(label: "ee.helop.lagoon.pump", qos: .userInteractive)
    @ObservationIgnored nonisolated private let pumpKickState = PumpKickState()
    /// Compressed video read past the decoded-frame limit while the demuxer
    /// reads on for audio. Demux queue, plus the resets.
    @ObservationIgnored nonisolated private let videoIntake = VideoIntakeQueue()
    /// Serialises intake admission and drain: the demux loop and the video
    /// pump both feed decoders from it, and decode order must survive that.
    @ObservationIgnored nonisolated private let videoFeedLock = NSLock()
    /// Longest a backpressure wait sleeps before re-checking the policy. A
    /// full decoded queue under a stopped clock never dequeues, and audio
    /// can run dry behind it.
    nonisolated private static let demuxWaitTimeout: TimeInterval = 0.25
    #if DEBUG
    @ObservationIgnored nonisolated private let diagnosticFaultGate = PlaybackDiagnosticFaultGate()
    #endif
    /// Whether each renderer's request block is registered. Pump queue only,
    /// apart from attach and teardown, which run before and after any pump.
    @ObservationIgnored nonisolated(unsafe) private var videoRequestsArmed = false
    @ObservationIgnored nonisolated(unsafe) private var audioRequestsArmed = false
    /// Request-block calls that found nothing to give. The pump disarms on
    /// each, so this stays near zero; a busy loop would count thousands a
    /// second. Atomic because the regression probe reads it.
    @ObservationIgnored nonisolated private let idleRequestCounter = Atomic<Int>(0)

    nonisolated public var idleRequestCallbacks: Int {
        idleRequestCounter.load(ordering: .relaxed)
    }

    nonisolated public var videoOutputPathDiagnostic: String {
        if let stage = softwareDecodeStage { return stage.outputModeName }
        return videoDecoder != nil ? "videotoolbox" : "compressed"
    }
    @ObservationIgnored nonisolated let performanceSignpostID = OSSignpostID(log: PlaybackPerformance.log)
    @ObservationIgnored nonisolated private let lifecycleID = UUID()
    @ObservationIgnored nonisolated private let audioContinuity = AudioContinuityMonitor()
    @ObservationIgnored nonisolated private let av1PipelineTimings = RendererPipelineTimings(
        enabled: EngineTuning.current.profilesAV1Pipeline
    )
    @ObservationIgnored nonisolated(unsafe) private var av1PipelineTimer: DispatchSourceTimer?
    @ObservationIgnored nonisolated(unsafe) private var videoDecoder: VideoToolboxDecoder?
    /// libavcodec's decoder, driven from a queue of its own so reading and
    /// decoding overlap. Non-nil exactly when the software path is in use.
    @ObservationIgnored nonisolated(unsafe) private var softwareDecodeStage: SoftwareVideoDecodeStage?
    @ObservationIgnored private var bench: FrameLossBench?
    @ObservationIgnored private var benchEnabled = false
    @ObservationIgnored private var benchTickCount = 0
    @ObservationIgnored private var performanceMetricsLoadInFlight = false

    // Written on main, read on the demux loop (or vice versa) — all simple
    // value types behind one lock.
    @ObservationIgnored nonisolated private let shared = SharedState()
    @ObservationIgnored nonisolated private let subtitleStore = SubtitleStore()

    @ObservationIgnored private var externalSubtitles: [ExternalSubtitleTrack] = []
    @ObservationIgnored private var embeddedSubtitleCount = 0
    // Bumped on every subtitle selection change so a stale external
    // download can't overwrite a newer choice's cues.
    @ObservationIgnored private var externalLoadToken = 0
    @ObservationIgnored private var externalLoadTask: Task<Void, Never>?
    @ObservationIgnored private let subtitleDownloader: BoundedDownload

    @ObservationIgnored nonisolated(unsafe) private var videoRenderer: AVSampleBufferVideoRenderer?
    @ObservationIgnored nonisolated(unsafe) private var audioRenderer: AVSampleBufferAudioRenderer?
    @ObservationIgnored nonisolated private let synchronizer = AVSampleBufferRenderSynchronizer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var finishObserver: Any?
    @ObservationIgnored private var didFinish = false
    @ObservationIgnored private var didNotifyPlaybackStarted = false
    /// Where the clock is heading while stopped for a load or seek. Nil while
    /// running and during a stall, when `timePosition` is live.
    @ObservationIgnored private var bufferingTargetSeconds: Double?
    /// A group start instant that arrived while buffering. `beginPlayback`
    /// anchors on it unless it has already passed.
    @ObservationIgnored private var scheduledStartHostTime: CMTime?
    @ObservationIgnored private var stallRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var stallConfirmationTask: Task<Void, Never>?
    @ObservationIgnored private var stallConfirmationID: UUID?
    @ObservationIgnored private var stallSignpostActive = false
    @ObservationIgnored private var shutdownRequested = false
    /// Cost and cadence of the 10 Hz main-actor tick, gathered only while
    /// `ProcessCPUTrace.enabled` and drained into DecodeTrace every 2 s.
    @ObservationIgnored private var mainTick = MainTickStatistics()
    @ObservationIgnored private var lastTickInstant: ContinuousClock.Instant?
    @ObservationIgnored private var rendererNotificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var audioRendererNotificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var rendererRecoveryInProgress = false
    /// The playback generation that has spent its one restart-point retry.
    @ObservationIgnored private var restartPointRetryGeneration: Int?
    @ObservationIgnored private var audioRendererRecoveryInProgress = false
    /// Non-nil while a fresh audio renderer is swapped in, so a flush
    /// notification cannot start a second swap on top of the first.
    @ObservationIgnored private var audioRendererReplacementID: UUID?
    @ObservationIgnored private var audioStatusObservation: NSKeyValueObservation?

    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored nonisolated(unsafe) private var pendingCacheSession: PlaybackCacheSession?
    /// The session the fill loop works on. Differs from the demuxer's: a
    /// complete cache file plays from disk but is still worth finishing.
    @ObservationIgnored var cacheSessionForFill: PlaybackCacheSession?
    @ObservationIgnored var bufferFillTask: Task<Void, Never>?
    @ObservationIgnored var bufferFillGeneration: UUID?
    @ObservationIgnored var successorWarmTask: Task<Void, Never>?
    @ObservationIgnored var successorWarmGeneration: UUID?

    /// What the cache is holding, for a scrub bar and a diagnostics line.
    public internal(set) var bufferState = PlaybackBufferState.empty

    /// The active scope's full counters, for a host's HUD and decode trace.
    public var playbackCacheMetrics: PlaybackCacheMetrics? {
        PlaybackCacheOwner.coordinator.current?.metrics
    }
    @ObservationIgnored nonisolated(unsafe) private var pendingDisc: DiscPlaybackRequest?
    @ObservationIgnored private var pendingAuthorization: MediaRequestAuthorization?
    @ObservationIgnored private var pendingStartSeconds: Double = 0

    public init(subtitleDownloader: BoundedDownload = .shared) {
        self.subtitleDownloader = subtitleDownloader
        PlaybackLifecycleDiagnostics.engineCreated(lifecycleID)
    }

    deinit {
        av1PipelineTimer?.cancel()
        externalLoadTask?.cancel()
        PlaybackLifecycleDiagnostics.engineDestroyed(lifecycleID)
    }

    /// Whether a cache would sit in front of these bytes.
    ///
    /// `prepare` decides this itself. It is exposed because an incident
    /// report records the delivery before the attempt starts.
    public nonisolated static func cachesPlayback(url: URL, delivery: MediaDelivery) -> Bool {
        // A file on disk is already local.
        url.isFileURL || PlaybackBufferPolicy.customIOEnabled(for: delivery)
    }

    /// Opens a media source and gets ready to play it.
    ///
    /// Returns immediately; opening, probing and first decode run on the
    /// engine's queues. Watch `onPlaybackStarted` and `onError`.
    ///
    /// The engine decides from `delivery` whether to cache: a stable file
    /// can be cached and filled ahead, a segmented manifest cannot.
    ///
    /// - Parameters:
    ///   - url: Where the media is. A file URL plays straight from disk.
    ///   - itemID: The host's opaque ID, matched against a staged
    ///     successor. Empty plays without a cache.
    ///   - delivery: Whether the bytes are a stable file or a manifest.
    ///   - expectedLength: The content length if known; saves a probe.
    ///   - initialAudioOrdinal: Audio track to select, or nil for the
    ///     container's default.
    ///   - authorization: A credential sent with every request.
    public func prepare(
        url: URL,
        itemID: String = "",
        delivery: MediaDelivery = .stableFile,
        expectedLength: Int64? = nil,
        disc: DiscPlaybackRequest? = nil,
        startSeconds: Double,
        initialAudioOrdinal: Int?,
        initialSubtitleOrdinal: Int? = nil,
        audioTrackMetadata: [PlayerTrackMetadata] = [],
        embeddedSubtitleMetadata: [PlayerTrackMetadata] = [],
        externalSubtitles: [ExternalSubtitleTrack] = [],
        authorization: MediaRequestAuthorization? = nil
    ) {
        // A local file needs nothing in front of it, and neither does
        // media the host has not named.
        let session: PlaybackCacheSession? = url.isFileURL || itemID.isEmpty ? nil
            : PlaybackCacheOwner.coordinator.activate(
                itemID: itemID,
                url: url,
                delivery: delivery,
                expectedLength: expectedLength,
                authorization: authorization
            )
        // A complete cache file plays from disk without the session, except
        // a disc image, whose reader lives behind the session.
        let playbackURL = session?.completeFileURL ?? url
        let usesSession = PlaybackBufferPolicy.engineUsesCacheSession(
            playsFromCompleteFile: playbackURL.isFileURL,
            disc: disc != nil,
            delivery: delivery
        )
        cacheSessionForFill = session
        publishBufferState(session?.metrics)

        pendingURL = playbackURL
        pendingCacheSession = usesSession ? session : nil
        pendingDisc = disc
        pendingAuthorization = authorization
        pendingStartSeconds = startSeconds
        self.externalSubtitles = externalSubtitles
        shared.withLock {
            $0.initialAudioOrdinal = initialAudioOrdinal
            $0.initialSubtitleOrdinal = initialSubtitleOrdinal
            $0.audioTrackMetadata = audioTrackMetadata
            $0.embeddedSubtitleMetadata = embeddedSubtitleMetadata
            $0.externalSubtitles = externalSubtitles
        }
    }

    /// Warms a cache scope for media the host expects to play next.
    ///
    /// One successor at a time. A later `prepare` with the same `itemID` and
    /// URL promotes the warmed scope, so a handoff keeps what it fetched.
    /// Staging suspends this engine's own fill (one proactive download at a
    /// time); the active file's cached bytes stay readable.
    ///
    /// - Parameter warms: Whether to also fetch a bounded head start. False
    ///   when the handoff is already under way.
    public func stageSuccessor(
        itemID: String,
        url: URL,
        delivery: MediaDelivery,
        expectedLength: Int64? = nil,
        authorization: MediaRequestAuthorization? = nil,
        warms: Bool
    ) {
        suspendBufferFillInternal()
        let staged = PlaybackCacheOwner.coordinator.stageNext(
            itemID: itemID,
            url: url,
            delivery: delivery,
            expectedLength: expectedLength,
            authorization: authorization
        )
        guard warms, let staged else {
            stopSuccessorWarm()
            return
        }
        startSuccessorWarm(staged)
    }

    /// Stops warming a staged successor without discarding what it holds.
    /// The handoff is starting and must not queue behind the warm-up.
    public func endSuccessorWarming() {
        stopSuccessorWarm()
    }

    /// Throws away a staged successor. A non-nil `itemID` only discards that
    /// item's scope, so a cancelled preparation cannot remove its replacement.
    public func discardStagedSuccessor(itemID: String? = nil) {
        stopSuccessorWarm()
        PlaybackCacheOwner.coordinator.discardNext(itemID: itemID)
    }

    /// Retires the active scope. A handoff keeps the staged successor, which
    /// the next engine's `prepare` promotes.
    public func discardPlaybackCache(preservingStagedSuccessor: Bool) {
        suspendBufferFillInternal()
        if !preservingStagedSuccessor { stopSuccessorWarm() }
        cacheSessionForFill = nil
        PlaybackCacheOwner.coordinator.discardCurrent(preservingNext: preservingStagedSuccessor)
        publishBufferState(nil)
    }

    /// Stops filling ahead without discarding what is cached. For a host
    /// going to the background.
    public func suspendBufferFill() {
        suspendBufferFillInternal()
    }

    /// Resumes filling after a suspension. A successor being warmed keeps
    /// the link; nothing restarts underneath it.
    public func resumeBufferFill() {
        guard bufferFillTask == nil, successorWarmTask == nil else { return }
        startBufferFill()
    }

    public func attach(displayLayer: AVSampleBufferDisplayLayer) {
        // Never revive a shut-down engine. `finishRendererShutdown` nils
        // `videoRenderer`, so the nil check alone would let one pass when
        // SwiftUI re-mounts the surface after a failure, starting a second
        // demux loop whose renderers can never detach.
        guard !shutdownRequested, videoRenderer == nil, let url = pendingURL else { return }

        // Read once per playback so a switch cannot change mid-A/B. The
        // bench arms in beginPlayback.
        let tuning = EngineTuning.current
        demuxer.dolbyVisionProfile7Mode = tuning.stripsDolbyVisionEnhancementLayer
            ? .stripToHDR10 : .convert
        demuxer.markDroppableFrames = tuning.marksDroppableFrames
        benchEnabled = tuning.runsFrameLossBench

        os_signpost(
            .event,
            log: PlaybackPerformance.log,
            name: "Renderer Attach",
            signpostID: performanceSignpostID
        )

        let video = displayLayer.sampleBufferRenderer
        let audio = Self.makeAudioRenderer()
        videoRenderer = video
        audioRenderer = audio
        synchronizer.addRenderer(video)
        synchronizer.addRenderer(audio)
        PlaybackLifecycleDiagnostics.renderersAttached(lifecycleID)
        observeVideoRenderer(video)
        observeAudioRenderer(audio)

        armVideoRequests(video)
        armAudioRequests(audio)
        if av1PipelineTimings.enabled {
            let timer = DispatchSource.makeTimerSource(queue: pumpQueue)
            timer.schedule(
                deadline: .now(),
                repeating: .milliseconds(50),
                leeway: .milliseconds(10)
            )
            timer.setEventHandler { [weak self] in
                self?.sampleAV1Pipeline()
            }
            av1PipelineTimer = timer
            timer.resume()
        }

        // 0.1 s so subtitle cues land on time; timePosition still only
        // publishes on 0.25 s deltas.
        timeObserver = synchronizer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.observeTime(time)
            }
        }

        bufferingTargetSeconds = max(pendingStartSeconds, 0)
        shared.withLock {
            let start = max(pendingStartSeconds, 0)
            $0.pendingSeekSeconds = start
            $0.videoBufferedTo = start
            $0.playbackGeneration += 1
        }
        let startURL = url
        let startCacheSession = pendingCacheSession
        let startDisc = pendingDisc
        let startAuthorization = pendingAuthorization
        let recommendedPixelBufferAttributes = video.recommendedPixelBufferAttributes
        PlaybackLifecycleDiagnostics.demuxStarted(lifecycleID)
        let demuxLifecycleID = lifecycleID
        demuxQueue.async { [weak self] in
            guard let self else {
                // Released before the block ran: no demuxer opened, but the
                // diagnostic start still needs its matching end.
                PlaybackLifecycleDiagnostics.demuxEnded(demuxLifecycleID)
                return
            }
            self.runDemuxLoop(
                url: startURL,
                cacheSession: startCacheSession,
                disc: startDisc,
                recommendedPixelBufferAttributes: recommendedPixelBufferAttributes,
                authorization: startAuthorization
            )
        }
    }

    /// Every audio renderer this engine owns, so a replacement after a
    /// failure or media-services reset sounds the same.
    ///
    /// `AVSampleBufferAudioRenderer` defaults to spatializing `multichannel`
    /// only, unlike `AVPlayerItem`, so stereo would play flat on AirPods.
    /// This only permits spatialization; the viewer's setting still decides.
    static func makeAudioRenderer() -> AVSampleBufferAudioRenderer {
        let renderer = AVSampleBufferAudioRenderer()
        renderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        // Otherwise pitch changes with rate. Time-domain keeps speech natural
        // at 1.25x/1.5x.
        renderer.audioTimePitchAlgorithm = .timeDomain
        return renderer
    }

    // MARK: - Transport (PlayerEngine)

    public func play() {
        guard isPaused || synchronizer.rate == 0 else { return }
        isPaused = false
        EngineDiagnostics.record(.playbackPlay, ["position": .double(timePosition.rounded(toPlaces: 1))])
        // A buffering engine resumes when its queue gate is satisfied;
        // forcing the clock here would run its timebase ahead of the samples.
        if !isBuffering {
            synchronizer.rate = Float(effectiveRate)
        }
        rearmBench(at: timePosition)
    }

    /// Group start: present the current position at `hostTime` on the host
    /// clock. A time already past falls through to `play()`.
    public func play(atHostTime hostTime: CMTime) {
        guard hostTime.isValid, hostTime.isNumeric else {
            play()
            return
        }
        if isBuffering {
            // A seek or the initial open owns the anchor. Hand the instant
            // to `beginPlayback` and let the normal resume happen now.
            scheduledStartHostTime = hostTime
            play()
            return
        }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        guard CMTimeCompare(hostTime, now) > 0 else {
            play()
            return
        }
        guard isPaused || synchronizer.rate == 0 else { return }
        isPaused = false
        EngineDiagnostics.record(.playbackPlay, ["position": .double(timePosition.rounded(toPlaces: 1))])
        synchronizer.setRate(
            Float(effectiveRate),
            time: synchronizer.currentTime(),
            atHostTime: hostTime
        )
        rearmBench(at: timePosition)
    }

    /// The one writer of `isBuffering`, so the transition can be announced.
    private func setBuffering(_ buffering: Bool) {
        guard isBuffering != buffering else { return }
        isBuffering = buffering
        onBufferingChanged?(buffering)
    }

    /// Nudges a drifted group member without touching the viewer's `rate`.
    /// 1 restores the viewer's rate exactly.
    public func setCorrectionRate(_ multiplier: Double) {
        let resolved = multiplier.isFinite && multiplier > 0 ? multiplier : 1
        guard resolved != correctionRate else { return }
        correctionRate = resolved
        let effective = effectiveRate
        // Demux watermarks scale by the effective rate, correction included.
        shared.withLock { $0.playbackRate = effective }
        if !isPaused, !isBuffering {
            synchronizer.rate = Float(effective)
        }
    }

    public func pause() {
        guard !isPaused || synchronizer.rate > 0 else { return }
        clearPendingStallConfirmation()
        // A group pause overrides a group start that has not arrived yet.
        scheduledStartHostTime = nil
        EngineDiagnostics.record(.playbackPause, ["position": .double(timePosition.rounded(toPlaces: 1))])
        // Soak diagnostic: the one pause call into AVFoundation's state, so
        // a slow pause shows up here.
        if ProcessCPUTrace.enabled {
            let waitStart = ContinuousClock.now
            synchronizer.rate = 0
            print(String(
                format: "SoakWait name=pauseRate ms=%.1f",
                Self.milliseconds(ContinuousClock.now - waitStart)
            ))
        } else {
            synchronizer.rate = 0
        }
        isPaused = true
        rearmBench(at: timePosition)
    }

    public func togglePause() {
        if isPaused {
            play()
        } else {
            pause()
        }
        // play() and pause() re-arm the bench from here.
    }

    public func setRate(_ requestedRate: Double) {
        let requestedRate = PlaybackRatePolicy.clamped(requestedRate)
        guard rate != requestedRate else { return }
        rate = requestedRate
        let effective = effectiveRate
        shared.withLock { $0.playbackRate = effective }
        if !isPaused, !isBuffering {
            synchronizer.rate = Float(effective)
        }
        rearmBench(at: timePosition)
    }

    public func seek(by seconds: Double) {
        seek(to: timePosition + seconds)
    }

    public func selectAudioTrack(id: Int?) {
        guard let id, id - 1 < audioTracks.count else { return }
        EngineDiagnostics.record(.playbackTrack, [
            "track": .string("audio"),
            "trackSource": .string(audioTracks.first { $0.engineID == id }?.source.rawValue ?? "embedded"),
            "position": .double(timePosition.rounded(toPlaces: 1)),
        ])
        shared.withLock { $0.selectedAudioOrdinal = id }
        audioTracks = audioTracks.map {
            PlayerTrack(
                engineID: $0.engineID,
                kind: .audio,
                displayName: $0.displayName,
                isSelected: $0.engineID == id,
                languageTag: $0.languageTag,
                isForced: $0.isForced,
                isHearingImpaired: $0.isHearingImpaired,
                source: $0.source
            )
        }
        onTrackSelectionChanged?()
        // Re-demux from the current position with the new stream selected.
        seek(to: timePosition)
    }

    public func setAudioDelay(_ seconds: Double) {
        let clamped = ((max(-5, min(5, seconds))) * 1000).rounded() / 1000
        guard clamped != audioDelay else { return }
        audioDelay = clamped
        shared.withLock { $0.audioDelaySeconds = clamped }
        // Compressed buffers carry demuxer stamps, so re-demux from here to
        // stamp every new buffer with the new offset.
        seek(to: timePosition)
    }

    public func selectSubtitleTrack(id: Int?) {
        let ordinal = id ?? 0
        guard !shutdownRequested, ordinal >= 0,
              ordinal <= embeddedSubtitleCount + externalSubtitles.count else { return }
        EngineDiagnostics.record(.playbackTrack, [
            "track": .string("subtitle"),
            "trackSource": .string(ordinal == 0 ? "off" : ordinal > embeddedSubtitleCount ? "external" : "embedded"),
            "position": .double(timePosition.rounded(toPlaces: 1)),
        ])
        cancelExternalSubtitleLoad()
        if ordinal > embeddedSubtitleCount {
            loadExternalSubtitle(ordinal: ordinal)
        } else {
            commitSubtitleSelection(ordinal: ordinal)
        }
    }

    public func retrySubtitleLoad() {
        if case .failed(let id, _, _) = subtitleLoadState { selectSubtitleTrack(id: id) }
    }

    private func cancelExternalSubtitleLoad() {
        externalLoadToken += 1
        externalLoadTask?.cancel()
        externalLoadTask = nil
        subtitleLoadState = .idle
    }

    private func commitSubtitleSelection(ordinal: Int, cues: [SubtitleCue] = []) {
        shared.withLock { state in
            state.selectedSubtitleOrdinal = ordinal
            state.selectedSubtitleStreamIndex = ordinal > 0 && ordinal <= embeddedSubtitleCount
                ? state.embeddedSubtitleStreamIndices[ordinal - 1] : -1
            // The demux subtitle callback holds this lock through its cue
            // write, so an old embedded packet cannot land after an external
            // track is committed.
            if ordinal > embeddedSubtitleCount {
                subtitleStore.replaceExternalTrack(with: cues)
            } else {
                subtitleStore.resetForEmbeddedPlayback()
            }
        }
        currentSubtitleText = nil
        currentSubtitleCues = []
        currentSubtitleImages = []
        subtitleTracks = subtitleTracks.map {
            PlayerTrack(
                engineID: $0.engineID,
                kind: .subtitle,
                displayName: $0.displayName,
                isSelected: $0.engineID == ordinal,
                languageTag: $0.languageTag,
                isForced: $0.isForced,
                isHearingImpaired: $0.isHearingImpaired,
                source: $0.source
            )
        }
        onTrackSelectionChanged?()
        if ordinal >= 1, ordinal <= embeddedSubtitleCount {
            // Re-demux from the previous keyframe so a line already due
            // appears now, not at the next cue.
            seek(to: timePosition)
        } else {
            refreshSubtitles(at: timePosition)
        }
    }

    /// Fetches and parses a Jellyfin external subtitle (vtt/srt delivery).
    private func loadExternalSubtitle(ordinal: Int) {
        let index = ordinal - embeddedSubtitleCount - 1
        guard externalSubtitles.indices.contains(index) else { return }
        let track = externalSubtitles[index]
        let token = externalLoadToken
        let title = Self.externalTrackName(for: track)
        subtitleLoadState = .loading(id: ordinal, title: title)
        // `pendingAuthorization` lives for the engine, so a track added
        // mid-playback still has it.
        externalLoadTask = Task { [weak self, subtitleDownloader, pendingAuthorization] in
            do {
                let cues = try await ExternalSubtitleLoader.load(track, using: subtitleDownloader, authorization: pendingAuthorization)
                try Task.checkCancellation()
                guard let self, !self.shutdownRequested, self.externalLoadToken == token else { return }
                self.commitSubtitleSelection(ordinal: ordinal, cues: cues)
                self.subtitleLoadState = .idle
                self.externalLoadTask = nil
            } catch {
                guard !Task.isCancelled, let self, !self.shutdownRequested, self.externalLoadToken == token else { return }
                self.subtitleLoadState = .failed(id: ordinal, title: title, message: ExternalSubtitleLoader.message(for: error))
                self.externalLoadTask = nil
                // Playback continues without the track; worth a report
                // because the viewer asked for it and did not get it.
                let detail = PlaybackFailureDetail(stage: .subtitle, error: error)
                var fields = detail.fields
                fields["track"] = .string("subtitle")
                fields["trackSource"] = .string(track.isDownloaded ? "downloaded" : "external")
                EngineDiagnostics.record(.playbackSubtitleLoadFailed, fields)
                EngineDiagnostics.report(.playbackSubtitleLoadFailed, level: .warning, variant: detail.fingerprint, fields: fields)
            }
        }
    }

    public func addExternalSubtitle(_ track: ExternalSubtitleTrack) {
        guard !shutdownRequested else { return }
        externalSubtitles.append(track)
        shared.withLock { $0.externalSubtitles = externalSubtitles }
        let ordinal = embeddedSubtitleCount + externalSubtitles.count
        subtitleTracks += [PlayerTrack(
            engineID: ordinal,
            kind: .subtitle,
            displayName: Self.externalTrackName(for: track),
            isSelected: false,
            languageTag: track.language,
            isForced: track.isForced,
            isHearingImpaired: track.isHearingImpaired,
            source: track.isDownloaded ? .downloaded : .external
        )]
        selectSubtitleTrack(id: ordinal)
    }

    public func shutdown() {
        guard !shutdownRequested else { return }
        shutdownRequested = true
        cancelExternalSubtitleLoad()
        suspendBufferFillInternal()
        PlaybackLifecycleDiagnostics.engineShutdownStarted(lifecycleID)
        for token in rendererNotificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        rendererNotificationTokens.removeAll()
        removeAudioRendererObservers()
        audioRendererReplacementID = nil
        av1PipelineTimer?.cancel()
        av1PipelineTimer = nil
        stallRecoveryTask?.cancel()
        clearPendingStallConfirmation()
        if stallSignpostActive {
            stallSignpostActive = false
            os_signpost(
                .end,
                log: PlaybackPerformance.log,
                name: "Playback Stall",
                signpostID: performanceSignpostID,
                "outcome=shutdown"
            )
        }
        shared.withLock { $0.cancelled = true }
        #if DEBUG
        diagnosticFaultGate.cancel()
        audioDeliverySuspendedForDiagnostics = false
        demuxDeliverySuspendedForDiagnostics = false
        #endif
        // Wake a demux loop asleep on backpressure so it sees cancellation.
        videoQueue.interruptWaits()
        audioQueue.interruptWaits()
        // Aborts any av_* call blocked in network I/O; a wedged open would
        // otherwise freeze teardown.
        demuxer.interrupt()
        if let timeObserver {
            synchronizer.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        removeFinishObserver()
        synchronizer.rate = 0

        let depths = queueDepths
        os_signpost(
            .begin,
            log: PlaybackPerformance.log,
            name: "Renderer Teardown",
            signpostID: performanceSignpostID,
            "videoQueued=%{public}d audioQueued=%{public}d",
            depths.video,
            depths.audio
        )

        // Teardown runs on the pump queue: no race with an in-flight pump,
        // and flushes and sample-buffer releases stay off the main actor
        // while the UI animates back.
        pumpQueue.async { [self] in
            finishRendererShutdown()
        }
    }

    /// Completes once FFmpeg is closed and AVFoundation has removed both
    /// renderers. Keep the engine alive while awaiting this.
    nonisolated public func waitForMediaResourcesToRetire(
        timeout: Duration = .seconds(15)
    ) async -> Bool {
        await PlaybackLifecycleDiagnostics.waitForMediaResourcesToRetire(
            for: lifecycleID,
            timeout: timeout
        )
    }

    public func refreshVideoPerformanceMetrics() {
        guard !shutdownRequested,
              !performanceMetricsLoadInFlight,
              let renderer = videoRenderer else { return }
        performanceMetricsLoadInFlight = true
        renderer.loadVideoPerformanceMetrics { [weak self] metrics in
            let snapshot = metrics.map {
                VideoPerformanceSnapshot(
                    totalFrames: $0.totalNumberOfFrames,
                    droppedFrames: $0.numberOfDroppedFrames,
                    corruptedFrames: $0.numberOfCorruptedFrames,
                    optimizedCompositingFrames: $0.numberOfFramesDisplayedUsingOptimizedCompositing,
                    accumulatedFrameDelay: $0.totalAccumulatedFrameDelay
                )
            }
            Task { @MainActor [weak self, snapshot] in
                guard let self else { return }
                self.performanceMetricsLoadInFlight = false
                guard !self.shutdownRequested, let snapshot else { return }
                let previous = self.videoPerformance
                let droppedDelta = max(snapshot.droppedFrames - (previous?.droppedFrames ?? 0), 0)
                let corruptedDelta = max(snapshot.corruptedFrames - (previous?.corruptedFrames ?? 0), 0)
                self.feedBench(snapshot)
                if droppedDelta > 0 || corruptedDelta > 0 {
                    let depths = self.queueDepths
                    os_signpost(
                        .event,
                        log: PlaybackPerformance.log,
                        name: "Video Frame Loss",
                        signpostID: self.performanceSignpostID,
                        "droppedDelta=%{public}d droppedTotal=%{public}d corruptedDelta=%{public}d corruptedTotal=%{public}d frames=%{public}d position=%{public}.3f videoQueued=%{public}d audioQueued=%{public}d stalls=%{public}d",
                        droppedDelta,
                        snapshot.droppedFrames,
                        corruptedDelta,
                        snapshot.corruptedFrames,
                        snapshot.totalFrames,
                        self.timePosition,
                        depths.video,
                        depths.audio,
                        self.stallCount
                    )
                }
                self.videoPerformance = snapshot
            }
        }
    }

    // MARK: - soak diagnostics (report-only)

    /// Drains the main-actor tick statistics into one DecodeTrace field.
    public func drainMainTickDiagnostic() -> String { mainTick.drain() }

    /// Cue count the subtitle overlay is scanning, to spot a leak.
    public var subtitleCueCountDiagnostic: Int { subtitleStore.count }

    /// Renderer notification observers registered. Growth means a recovery
    /// path re-observes without releasing.
    public var rendererObserverCountDiagnostic: Int {
        rendererNotificationTokens.count + audioRendererNotificationTokens.count
    }

    /// Measures how long work handed to the pump queue waits. Touches no
    /// engine state.
    nonisolated public func measurePumpQueueLatency(_ completion: @escaping @Sendable (Duration) -> Void) {
        let start = ContinuousClock.now
        pumpQueue.async {
            completion(ContinuousClock.now - start)
        }
    }

    /// Milliseconds for a `Duration`, for the `SoakWait` prints.
    nonisolated private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    nonisolated private func finishRendererShutdown() {
        // Nil first so any kickPumps block already queued behind this one
        // becomes a no-op instead of enqueueing after the flush.
        let video = videoRenderer
        let audio = audioRenderer
        videoRenderer = nil
        audioRenderer = nil

        video?.stopRequestingMediaData()
        audio?.stopRequestingMediaData()
        videoRequestsArmed = false
        audioRequestsArmed = false
        video?.flush()
        audio?.flush()
        videoIntake.removeAll()
        videoQueue.reset()
        audioQueue.reset()
        shared.withLock {
            $0.lastEnqueuedAudioEndSeconds = nil
            $0.endOfFilePendingIntake = false
        }

        #if DEBUG
        // Hardware can take seconds to retire a 4K decoder. This hook
        // reproduces that in the simulator, so autoplay must prove it never
        // overlaps the old renderer with the successor.
        let regressionDelay = EngineTuning.current.rendererRetirementDelaySeconds
        if regressionDelay > 0 {
            Thread.sleep(forTimeInterval: regressionDelay)
        }
        #endif

        // The synchronizer otherwise retains both renderers until the engine
        // dies. Removing them asynchronously lets decoders retire without
        // hitching the UI. `retirementStart` times the removal (soak only).
        let retirementStart = ProcessCPUTrace.enabled ? ContinuousClock.now : nil
        let removals = DispatchGroup()
        if let video {
            removals.enter()
            // `.invalid` is Apple's immediate-removal sentinel. Wait for the
            // completion before declaring the renderer retired.
            synchronizer.removeRenderer(video, at: .invalid) { _ in
                removals.leave()
            }
        }
        if let audio {
            removals.enter()
            synchronizer.removeRenderer(audio, at: .invalid) { _ in
                removals.leave()
            }
        }
        removals.notify(queue: pumpQueue) { [performanceSignpostID, lifecycleID, retirementStart] in
            if let retirementStart {
                print(String(
                    format: "SoakWait name=rendererRetirement ms=%.1f",
                    Self.milliseconds(ContinuousClock.now - retirementStart)
                ))
            }
            PlaybackLifecycleDiagnostics.renderersDetached(lifecycleID)
            os_signpost(
                .end,
                log: PlaybackPerformance.log,
                name: "Renderer Teardown",
                signpostID: performanceSignpostID
            )
        }
    }

    // MARK: - Seeking

    /// Empties the renderers and their queues, and forgets their anchors.
    /// Pump queue only, to serialize with enqueues. `seek(to:)` calls it, and
    /// the demux loop calls it again when it performs the seek: a read
    /// blocked during the first call returns an old-position packet whose
    /// PTS `PlaybackClockAnchor` would otherwise anchor a backward scrub on.
    nonisolated private func flushRenderersAndQueues() {
        videoRenderer?.flush()
        audioRenderer?.flush()
        videoIntake.removeAll()
        videoQueue.reset()
        audioQueue.reset()
        shared.withLock {
            $0.firstEnqueuedVideoPTS = nil
            $0.lastEnqueuedAudioEndSeconds = nil
            $0.endOfFilePendingIntake = false
            $0.videoSamplesSinceFlush = 0
            $0.videoStartPointDropsSinceFlush = 0
        }
    }

    public func seek(to target: Double) {
        let clamped = max(0, duration > 0 ? min(target, duration - 1) : target)
        EngineDiagnostics.record(.playbackSeek, ["position": .double(clamped.rounded(toPlaces: 1))])
        // Optimistic: the playhead moves now; the engine resumes from here.
        timePosition = clamped
        didFinish = false
        removeFinishObserver()
        bufferingTargetSeconds = clamped
        setBuffering(true)
        // A pending group start is now stale; a new one follows Ready.
        scheduledStartHostTime = nil
        synchronizer.rate = 0
        shared.withLock {
            $0.pendingSeekSeconds = clamped
            $0.videoBufferedTo = clamped
            $0.playbackGeneration += 1
        }
        // Enqueue, flush and reset share the pump queue, so no old sample
        // can race in after the flush (Apple's post-flush keyframe rule).
        // The soak branch times this sync wait.
        if ProcessCPUTrace.enabled {
            let waitStart = ContinuousClock.now
            pumpQueue.sync { self.flushRenderersAndQueues() }
            print(String(
                format: "SoakWait name=pumpSync ms=%.1f",
                Self.milliseconds(ContinuousClock.now - waitStart)
            ))
        } else {
            pumpQueue.sync { self.flushRenderersAndQueues() }
        }
        // The first buffer after a flush must not read as a discontinuity.
        audioContinuity.reset()
        // Embedded cues re-arrive after the seek, so drop them to avoid
        // duplicates. External cue lists are complete and stay.
        let embeddedSubtitleActive = shared.withLock { state -> Bool in
            return state.selectedSubtitleStreamIndex >= 0
        }
        if embeddedSubtitleActive {
            subtitleStore.resetForEmbeddedPlayback()
        }
        currentSubtitleText = nil
        currentSubtitleCues = []
        currentSubtitleImages = []
        // Publish last: a host may seek again synchronously, and that nested
        // seek must stay newest.
        onTimeAdvanced?(clamped, duration)
    }

    /// Audio-only playback in the background: video is discarded and not
    /// decoded; audio, the clock, subtitles and the finish boundary carry
    /// on. Resuming seeks in place so the picture restarts on a keyframe
    /// with a fresh decoder session.
    public func setVideoOutputSuspended(_ suspended: Bool) {
        let changed = shared.withLock { state -> Bool in
            guard state.videoOutputSuspended != suspended else { return false }
            state.videoOutputSuspended = suspended
            return true
        }
        guard changed, !shutdownRequested else { return }
        if suspended {
            pumpQueue.sync { self.flushVideoPath() }
        } else if !didFinish, duration <= 0 || timePosition < duration - 1 {
            // In the last second `seek` would clamp backwards.
            seek(to: timePosition)
        }
    }

    /// The video half of `flushRenderersAndQueues`. A finished queue stays
    /// finished, or the loop would read end of file twice.
    nonisolated private func flushVideoPath() {
        let wasFinished = videoQueue.isFinished
        videoRenderer?.flush()
        videoIntake.removeAll()
        videoQueue.reset()
        if wasFinished { videoQueue.markFinished() }
        shared.withLock {
            $0.firstEnqueuedVideoPTS = nil
            $0.videoSamplesSinceFlush = 0
            $0.videoStartPointDropsSinceFlush = 0
        }
    }

    /// Demux primed after open or seek: start, or reposition if paused.
    private func beginPlayback(at seconds: Double, firstVideoPTS: CMTime?) {
        // High-precision anchor: with a matched display rate each frame has
        // one vsync of slack, and a 600/s anchor spends up to 1.7 ms of it.
        let time = PlaybackClockAnchor.mediaTime(
            targetSeconds: seconds,
            firstVideoPTS: firstVideoPTS
        )
        timePosition = time.seconds
        let scheduledStart = scheduledStartHostTime
        scheduledStartHostTime = nil
        if isPaused {
            synchronizer.setRate(0, time: time)
        } else {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            // Apple's recommended start: anchor to a near-future host time so
            // the renderers meet the first deadline together.
            let defaultHostTime = CMTimeAdd(
                now,
                CMTime(seconds: 0.1, preferredTimescale: 1_000_000_000)
            )
            // Honour a group start only while it is still ahead; a missed
            // one is the server's to reissue.
            let hostTime: CMTime
            if let scheduledStart, CMTimeCompare(scheduledStart, now) > 0 {
                hostTime = scheduledStart
            } else {
                hostTime = defaultHostTime
            }
            synchronizer.setRate(Float(effectiveRate), time: time, atHostTime: hostTime)
        }
        // Only after anchoring: SyncPlay's Ready carries `clockPosition`,
        // which reads the synchronizer. Before the anchor it holds the old
        // position, and the server would drag the whole group there.
        setBuffering(false)
        bufferingTargetSeconds = nil
        kickPumps()
        rearmBench(at: time.seconds)
        if !didNotifyPlaybackStarted {
            didNotifyPlaybackStarted = true
            // Fill starts only once the picture is up; until then the
            // foreground read has the link.
            startBufferFill()
            onPlaybackStarted?()
        }
        // Every open and seek.
        onSeekReady?()
        os_signpost(
            .event,
            log: PlaybackPerformance.log,
            name: "Playback Cushion Ready",
            signpostID: performanceSignpostID,
            "position=%{public}.3f",
            time.seconds
        )
    }

    /// EOF is a renderer-timeline event: the demuxer can finish while
    /// AVFoundation still holds media, so a boundary observer waits for it.
    private func armFinishBoundary(at seconds: Double, generation: Int) {
        guard !shutdownRequested, !didFinish, seconds.isFinite else { return }
        let isCurrent = shared.withLock { !$0.cancelled && $0.playbackGeneration == generation }
        guard isCurrent else { return }
        removeFinishObserver()
        if timePosition >= seconds {
            finishPlayback(generation: generation)
            return
        }
        let boundary = CMTime(seconds: seconds, preferredTimescale: 240_000)
        finishObserver = synchronizer.addBoundaryTimeObserver(
            forTimes: [NSValue(time: boundary)],
            queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated {
                self?.finishPlayback(generation: generation)
            }
        }
    }

    private func finishPlayback(generation: Int) {
        let isCurrent = shared.withLock { !$0.cancelled && $0.playbackGeneration == generation }
        guard isCurrent, !didFinish else { return }
        didFinish = true
        removeFinishObserver()
        EngineDiagnostics.record(.playbackFinished, ["position": .double(timePosition.rounded(toPlaces: 1))])
        onFinished?()
    }

    private func removeFinishObserver() {
        guard let finishObserver else { return }
        synchronizer.removeTimeObserver(finishObserver)
        self.finishObserver = nil
    }

    // MARK: - Renderer recovery

    private func observeVideoRenderer(_ renderer: AVSampleBufferVideoRenderer) {
        let center = NotificationCenter.default
        rendererNotificationTokens.append(center.addObserver(
            forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
            object: renderer,
            queue: .main
        ) { [weak self, weak renderer] _ in
            guard let self, let renderer else { return }
            MainActor.assumeIsolated {
                self.recoverVideoRendererIfRequired(renderer)
            }
        })
        rendererNotificationTokens.append(center.addObserver(
            forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification,
            object: renderer,
            queue: .main
        ) { [weak self, weak renderer] notification in
            guard let self, let renderer else { return }
            MainActor.assumeIsolated {
                self.handleVideoRendererFailure(renderer, notification: notification)
            }
        })
    }

    private func observeAudioRenderer(_ renderer: AVSampleBufferAudioRenderer) {
        let center = NotificationCenter.default
        audioRendererNotificationTokens.append(center.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: renderer,
            queue: .main
        ) { [weak self, weak renderer] notification in
            guard let self, let renderer else { return }
            MainActor.assumeIsolated {
                let flushTime = (notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey]
                    as? NSValue)?.timeValue
                self.recoverAudioRenderer(
                    renderer,
                    from: flushTime,
                    reason: "automaticFlush"
                )
            }
        })
        audioRendererNotificationTokens.append(center.addObserver(
            forName: .AVSampleBufferAudioRendererOutputConfigurationDidChange,
            object: renderer,
            queue: .main
        ) { [weak self, weak renderer] _ in
            guard let self, let renderer else { return }
            MainActor.assumeIsolated {
                self.recoverAudioRenderer(
                    renderer,
                    from: nil,
                    reason: "outputConfiguration"
                )
            }
        })
        // Hard failure has no notification, only KVO on `status`; unobserved,
        // a failed renderer plays on silently. KVO arrives off the main
        // thread, hence the hop instead of `assumeIsolated`.
        audioStatusObservation = renderer.observe(\.status, options: [.new]) {
            [weak self, weak renderer] _, _ in
            Task { @MainActor [weak self, weak renderer] in
                guard let self, let renderer else { return }
                self.handleAudioRendererStatus(renderer)
            }
        }
    }

    private func handleAudioRendererStatus(_ renderer: AVSampleBufferAudioRenderer) {
        guard !shutdownRequested,
              renderer === audioRenderer,
              renderer.status == .failed else { return }
        replaceAudioRenderer(renderer, for: .rendererFailed)
    }

    private func removeAudioRendererObservers() {
        for token in audioRendererNotificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        audioRendererNotificationTokens.removeAll()
        audioStatusObservation?.invalidate()
        audioStatusObservation = nil
    }

    /// After an automatic flush AVFoundation requires our flush to be
    /// serialized with enqueueing. `seek` does that on `pumpQueue` and
    /// refills from the playhead.
    private func recoverAudioRenderer(
        _ renderer: AVSampleBufferAudioRenderer,
        from flushTime: CMTime?,
        reason: StaticString
    ) {
        guard !shutdownRequested,
              renderer === audioRenderer,
              !audioRendererRecoveryInProgress,
              audioRendererReplacementID == nil else { return }
        audioRendererRecoveryInProgress = true
        defer { audioRendererRecoveryInProgress = false }
        let notifiedTime = flushTime?.seconds
        let recoveryPosition = if let notifiedTime, notifiedTime.isFinite, notifiedTime >= 0 {
            notifiedTime
        } else {
            timePosition
        }
        audioRendererRecoveryCount += 1
        os_signpost(
            .event,
            log: PlaybackPerformance.log,
            name: "Renderer Recovery",
            signpostID: performanceSignpostID,
            "position=%{public}.3f reason=%{public}s",
            recoveryPosition,
            String(describing: reason)
        )
        seek(to: recoveryPosition)
    }

    /// Replaces the audio renderer after a media-services reset, keeping the
    /// video surface. Stays paused until something calls `play()`.
    public func recoverAfterMediaServicesReset() {
        guard let outgoingAudio = audioRenderer else { return }
        replaceAudioRenderer(outgoingAudio, for: .mediaServicesReset)
    }

    /// Swaps in a fresh audio renderer and refills it from the playhead.
    /// A failed or invalidated renderer cannot be cleared in place. Video
    /// stays attached, so the viewer loses only a moment of audio.
    private func replaceAudioRenderer(
        _ outgoingAudio: AVSampleBufferAudioRenderer,
        for replacement: AudioRendererReplacement
    ) {
        guard !shutdownRequested,
              audioRendererReplacementID == nil,
              outgoingAudio === audioRenderer else { return }
        if replacement.staysPaused {
            pause()
        }
        setBuffering(true)
        let recoveryPosition = timePosition
        let replacementID = UUID()
        audioRendererReplacementID = replacementID
        // Also stops the status observation, so a failed renderer cannot
        // re-report while being retired.
        removeAudioRendererObservers()
        let outgoingError = outgoingAudio.error?.localizedDescription
        let outgoingFailure = PlaybackFailureDetail(stage: .audioRenderer, error: outgoingAudio.error)
        EngineDiagnostics.record(.playbackRendererRecovery, outgoingFailure.fields.merging([
            "recovery": .string(replacement.reason.description),
            "position": .double(recoveryPosition.rounded(toPlaces: 1)),
        ]) { _, new in new })
        os_signpost(
            .event,
            log: PlaybackPerformance.log,
            name: "Renderer Recovery",
            signpostID: performanceSignpostID,
            "position=%{public}.3f reason=%{public}s",
            recoveryPosition,
            String(describing: replacement.reason)
        )

        pumpQueue.async { [weak self, weak outgoingAudio] in
            guard let self, let outgoingAudio,
                  !self.shared.withLock({ $0.cancelled }),
                  self.audioRenderer === outgoingAudio else { return }
            self.audioRenderer = nil
            outgoingAudio.stopRequestingMediaData()
            self.audioRequestsArmed = false
            outgoingAudio.flush()
            self.audioQueue.reset()
            self.shared.withLock { $0.lastEnqueuedAudioEndSeconds = nil }
            self.audioContinuity.reset()
            self.synchronizer.removeRenderer(outgoingAudio, at: .invalid) { [weak self] removed in
                Task { @MainActor [weak self] in
                    guard let self,
                          !self.shutdownRequested,
                          self.audioRendererReplacementID == replacementID else { return }
                    guard removed else {
                        self.audioRendererReplacementID = nil
                        self.onError?(PlaybackEngineFailure(
                            cause: .delivery,
                            message: replacement.failureMessage(detail: outgoingError),
                            detail: outgoingFailure
                        ))
                        return
                    }
                    let incoming = Self.makeAudioRenderer()
                    self.audioRenderer = incoming
                    self.synchronizer.addRenderer(incoming)
                    self.observeAudioRenderer(incoming)
                    self.armAudioRequests(incoming)
                    switch replacement {
                    case .mediaServicesReset:
                        self.mediaServicesResetRecoveryCount += 1
                    case .rendererFailed:
                        self.audioRendererRecoveryCount += 1
                    }
                    self.audioRendererReplacementID = nil
                    EngineDiagnostics.report(
                        .playbackRendererRecovery,
                        level: .warning,
                        variant: [replacement.reason.description] + outgoingFailure.fingerprint.dropFirst(),
                        fields: outgoingFailure.fields.merging([
                            "recovery": .string(replacement.reason.description),
                            "outcome": .string("recovered"),
                            "position": .double(recoveryPosition.rounded(toPlaces: 1)),
                        ]) { _, new in new }
                    )
                    // Refills and re-anchors; a paused engine stays paused.
                    self.seek(to: recoveryPosition)
                }
            }
        }
    }

    #if DEBUG
    /// Debug fault injection: withholds audio from AVFoundation while demux
    /// and video continue, isolating audio starvation.
    public func simulateAudioStarvationForDiagnostics(durationSeconds: Double = 3) {
        guard !shutdownRequested,
              !didSimulateAudioStarvation,
              durationSeconds > 0 else { return }
        didSimulateAudioStarvation = true
        diagnosticFaultGate.setAudioDeliverySuspended(true)
        audioDeliverySuspendedForDiagnostics = true
        pumpQueue.async { [weak self] in
            guard let self, let renderer = self.audioRenderer else { return }
            if self.audioRequestsArmed {
                self.audioRequestsArmed = false
                renderer.stopRequestingMediaData()
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int64(durationSeconds * 1_000)))
            guard let self, !self.shutdownRequested else { return }
            self.diagnosticFaultGate.setAudioDeliverySuspended(false)
            self.audioDeliverySuspendedForDiagnostics = false
            // Drop audio the clock already passed; a real recovery never
            // hands it over, and it uses up the resume rule's budget.
            let clock = self.timePosition
            self.audioQueue.dropLeading { Self.presentationEnd(of: $0).map { $0 < clock } ?? false }
            self.kickPumps()
        }
    }

    /// Stops `av_read_frame` without touching either renderer. Releasing the
    /// gate exercises the real demux/backpressure refill path.
    public func simulateDeliveryStallForDiagnostics(durationSeconds: Double = 3) {
        guard !shutdownRequested,
              !didSimulateDeliveryStall,
              durationSeconds > 0 else { return }
        didSimulateDeliveryStall = true
        diagnosticFaultGate.setDemuxDeliverySuspended(true)
        demuxDeliverySuspendedForDiagnostics = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int64(durationSeconds * 1_000)))
            guard let self, !self.shutdownRequested else { return }
            self.diagnosticFaultGate.setDemuxDeliverySuspended(false)
            self.demuxDeliverySuspendedForDiagnostics = false
        }
    }
    #endif

    #if DEBUG
    /// Regression hook: runs the automatic-flush recovery path.
    public func simulateAudioRendererFlushForRegression() {
        guard let audioRenderer else { return }
        recoverAudioRenderer(audioRenderer, from: nil, reason: "regression")
    }

    /// Regression hook for hard failure, which cannot be induced on demand.
    public func simulateAudioRendererFailureForRegression() {
        guard let audioRenderer else { return }
        replaceAudioRenderer(audioRenderer, for: .rendererFailed)
    }
    #endif

    private func recoverVideoRendererIfRequired(_ renderer: AVSampleBufferVideoRenderer) {
        // A suspended picture is flushed on resume anyway.
        guard !shutdownRequested,
              renderer === videoRenderer,
              renderer.requiresFlushToResumeDecoding,
              !rendererRecoveryInProgress,
              !shared.withLock({ $0.videoOutputSuspended }) else { return }
        rendererRecoveryInProgress = true
        let recoveryPosition = timePosition
        os_signpost(
            .event,
            log: PlaybackPerformance.log,
            name: "Renderer Recovery",
            signpostID: performanceSignpostID,
            "position=%{public}.3f reason=requiresFlush",
            recoveryPosition
        )
        let detail = PlaybackFailureDetail(stage: .videoRenderer, error: renderer.error)
        let fields = detail.fields.merging([
            "recovery": .string("requiresFlush"),
            "position": .double(recoveryPosition.rounded(toPlaces: 1)),
        ]) { _, new in new }
        EngineDiagnostics.record(.playbackRendererRecovery, fields)
        EngineDiagnostics.report(.playbackRendererRecovery, level: .warning, variant: ["requiresFlush"] + detail.fingerprint.dropFirst(), fields: fields)
        seek(to: recoveryPosition)
        rendererRecoveryInProgress = false
    }

    private func handleVideoRendererFailure(
        _ renderer: AVSampleBufferVideoRenderer,
        notification: Notification
    ) {
        guard !shutdownRequested, renderer === videoRenderer,
              !shared.withLock({ $0.videoOutputSuspended }) else { return }
        if renderer.requiresFlushToResumeDecoding {
            recoverVideoRendererIfRequired(renderer)
            return
        }
        let notificationError = notification.userInfo?[
            AVSampleBufferVideoRenderer.didFailToDecodeNotificationErrorKey
        ] as? Error
        // Record the refused sample: it tells a restart-point failure from a
        // verdict on the stream.
        if let milliseconds = Self.refusedSampleMilliseconds(notificationError ?? renderer.error) {
            shared.withLock { $0.lastRefusedSampleMs = milliseconds }
        }
        // For hands-off device runs. `AVErrorPresentationTimeStampKey` names
        // the refused sample.
        if ProcessCPUTrace.enabled {
            let underlying = (notificationError ?? renderer.error) as NSError?
            print(String(
                format: "RendererFailure position=%.3f samplesSinceFlush=%d domain=%@ code=%d info=%@",
                timePosition,
                shared.withLock { $0.videoSamplesSinceFlush },
                underlying?.domain ?? "none",
                underlying?.code ?? 0,
                String(describing: underlying?.userInfo ?? [:])
            ))
        }
        // A failure this soon after a flush is about the restart point, not
        // the bitstream: one flush-and-re-seek before the ladder descends.
        // Once per generation, so it cannot loop.
        let (samplesSinceFlush, generation) = shared.withLock {
            ($0.videoSamplesSinceFlush, $0.playbackGeneration)
        }
        if PlaybackRestartPointPolicy.shouldRetryInPlace(
            videoSamplesSinceFlush: samplesSinceFlush,
            alreadyRetriedThisGeneration: restartPointRetryGeneration == generation
        ) {
            let recoveryPosition = timePosition
            os_signpost(
                .event,
                log: PlaybackPerformance.log,
                name: "Renderer Recovery",
                signpostID: performanceSignpostID,
                "position=%{public}.3f reason=restartPoint",
                recoveryPosition
            )
            let detail = PlaybackFailureDetail(stage: .videoRenderer, error: notificationError ?? renderer.error)
            let fields = detail.fields.merging([
                "recovery": .string("restartPoint"),
                "position": .double(recoveryPosition.rounded(toPlaces: 1)),
                "samplesSinceFlush": .int(samplesSinceFlush),
            ]) { _, new in new }
            EngineDiagnostics.record(.playbackRendererRecovery, fields)
            EngineDiagnostics.report(.playbackRendererRecovery, level: .warning, variant: ["restartPoint"] + detail.fingerprint.dropFirst(), fields: fields)
            seek(to: recoveryPosition)
            // After the seek, which bumps the generation: a second failure
            // here descends the ladder, a later viewer seek earns a retry.
            restartPointRetryGeneration = shared.withLock { $0.playbackGeneration }
            return
        }
        let detail = notificationError?.localizedDescription
            ?? renderer.error?.localizedDescription
            ?? "unknown renderer error"
        // The renderer decodes what it was handed. Nothing about the way
        // those samples were delivered will change its verdict.
        onError?(PlaybackEngineFailure(
            cause: .undecodable,
            message: "Playback failed in the Lagoon video renderer (\(detail)).",
            detail: PlaybackFailureDetail(stage: .videoRenderer, error: notificationError ?? renderer.error)
        ))
    }

    /// The stamp of the sample a renderer refused, in media milliseconds.
    /// The only `userInfo` field read: a number, never a name or URL.
    nonisolated private static func refusedSampleMilliseconds(_ error: Error?) -> Int? {
        guard let value = (error as? NSError)?
            .userInfo[AVErrorPresentationTimeStampKey] as? NSValue else { return nil }
        let stamp = value.timeValue
        guard stamp.isValid, stamp.seconds.isFinite else { return nil }
        return Int((stamp.seconds * 1_000).rounded())
    }

    private func observeTime(_ time: CMTime) {
        // Soak diagnostic into `mainTick`; costs one Bool read when off.
        let tick: (start: ContinuousClock.Instant, interval: Duration?)?
        if ProcessCPUTrace.enabled {
            let start = ContinuousClock.now
            let interval = lastTickInstant.map { start - $0 }
            lastTickInstant = start
            tick = (start, interval)
        } else {
            tick = nil
        }
        defer {
            if let tick {
                mainTick.record(duration: ContinuousClock.now - tick.start, interval: tick.interval)
            }
        }
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        // 0.1 s so the animated scrubber has fresh targets.
        if abs(seconds - timePosition) >= 0.1 {
            timePosition = seconds
            onTimeAdvanced?(seconds, duration)
        }
        refreshSubtitles(at: seconds)
        // Stall detection: the clock caught up with the demuxer before the
        // end. Hold the clock rather than freeze frames under it. Video
        // always recovers; audio is counted, and recovers only when
        // `buffersOnAudioStarvation` is on.
        switch starvation(at: seconds) {
        case .video:
            wasAudioStarved = false
            confirmStallIfPersistent()
        case .audio:
            if StallRecoveryPolicy.confirms(.audio, buffersOnAudioStarvation: buffersOnAudioStarvation) {
                confirmStallIfPersistent()
            } else {
                clearPendingStallConfirmation()
            }
            // Count episodes, not observer ticks: this fires at 10 Hz.
            if !wasAudioStarved {
                wasAudioStarved = true
                audioStarvationCount += 1
            }
        case .none:
            // Buffering answers `.none` without judging audio. A starvation
            // episode that became a stall ends only once playback runs, or
            // the dip after resume would count twice.
            if !isBuffering {
                wasAudioStarved = false
            }
            clearPendingStallConfirmation()
        }
        // Bench sampling rides this observer at ~1 Hz.
        if bench != nil {
            benchTickCount += 1
            if benchTickCount >= 10 {
                benchTickCount = 0
                refreshVideoPerformanceMetrics()
            }
        }
    }

    // MARK: - Frame-loss bench

    /// Restarts the bench window from `position`. Called at start and on
    /// every transport change: a window spanning a seek or pause is invalid.
    private func rearmBench(at position: Double) {
        guard benchEnabled else { return }
        if bench == nil {
            bench = FrameLossBench(at: position)
        } else {
            bench?.rearm(at: position)
        }
        benchCompleted = false
        benchStatus = String(format: "arming @%.0fs", position)
        av1PipelineTimings.reset()
        softwareDecodeStage?.resetDetailedTimings()
    }

    private func feedBench(_ snapshot: VideoPerformanceSnapshot) {
        guard bench != nil else { return }
        let memory = MemorySnapshot.current()
        let sample = FrameLossBench.Sample(
            position: timePosition,
            totalFrames: snapshot.totalFrames,
            droppedFrames: snapshot.droppedFrames,
            corruptedFrames: snapshot.corruptedFrames,
            stalls: stallCount,
            audioStalls: audioStallCount,
            audioDry: audioStarvationCount,
            audioGaps: audioContinuity.gapCount,
            videoQueueDepth: videoQueue.count,
            optimizedFrames: snapshot.optimizedCompositingFrames,
            accumulatedDelay: snapshot.accumulatedFrameDelay,
            footprintBytes: memory.footprintBytes,
            availableBytes: memory.availableBytes
        )
        if let result = bench!.record(sample) {
            benchStatus = result.regressionSummary
            // Plain stdout so `devicectl ... --console` can capture it on a
            // device. Carries the gate states so a run is self-describing.
            var gates = "vtime=\"\(videoTimingDiagnostic ?? "container")\""
            gates += " droppable=\"\(demuxer.markDroppableFrames ? "on" : "off")\""
            if let stats = demuxer.dolbyVisionRewriteStats {
                switch stats.mode {
                case .convert:
                    gates += " doviP7=\"convert rpu=\(stats.rpusConverted) rpuDrop=\(stats.rpusDropped)"
                        + " elDrop=\(stats.enhancementUnitsDropped) bytes=\(stats.bytesRemoved)"
                        + " errors=\(stats.errors) el=\(stats.enhancementLayerType ?? "unknown")\""
                case .stripToHDR10:
                    gates += " doviP7=\"strip rpuDrop=\(stats.rpusDropped) elDrop=\(stats.enhancementUnitsDropped)"
                        + " bytes=\(stats.bytesRemoved)\""
                }
            } else {
                gates += " doviP7=\"off\""
            }
            if let software = softwareDecodeBenchField {
                gates += " swdecode=\"\(software)\""
            }
            if let stage = softwareDecodeStage {
                gates += " output=\"\(stage.outputModeName)\""
            }
            gates += " hud=\"\(EngineTuning.current.hostShowsPlaybackHUD ? "on" : "off")\""
            if let supplement = benchGatesSupplement?(), !supplement.isEmpty {
                gates += " " + supplement
            }
            if let size = videoSize {
                gates += " playing=\"\(Int(size.width))x\(Int(size.height))\""
            }
            print("BenchResult dropped=\(result.dropped) frames=\(result.frames) "
                + String(format: "percent=%.3f", result.lossPercent)
                + " corrupted=\(result.corrupted) stalls=\(result.stalls)"
                + " audioStalls=\(result.audioStalls) audioDry=\(result.audioDry) audioGaps=\(result.audioGaps)"
                + " minVideoQueue=\(result.minVideoQueue)"
                + " optimized=\(result.optimizedFrames)"
                + String(format: " delayMs=%.1f", result.accumulatedDelay * 1000)
                + String(format: " memoryStartMB=%.1f memoryPeakMB=%.1f memoryGrowthMB=%.1f",
                    Double(result.startingFootprintBytes) / 1_048_576,
                    result.peakFootprintMB,
                    result.footprintGrowthMB)
                + (result.minimumAvailableBytes > 0
                    ? String(format: " minimumAvailableMB=%.1f", result.minimumAvailableMB)
                    : "")
                + String(format: " start=%.2f window=%.2f ", result.startPosition, result.windowSeconds)
                + gates)
            for line in softwareDecodeStage?.detailedTimingLines ?? [] {
                print("PipelineDecode \(line)")
            }
            for line in av1PipelineTimings.summaryLines() {
                print("PipelineRenderer \(line)")
            }
            benchCompleted = true
            os_signpost(
                .event,
                log: PlaybackPerformance.log,
                name: "Bench Result",
                signpostID: performanceSignpostID,
                "dropped=%{public}d frames=%{public}d percent=%{public}.3f corrupted=%{public}d stalls=%{public}d audioStalls=%{public}d audioDry=%{public}d audioGaps=%{public}d minVideoQueue=%{public}d memoryStartMB=%{public}.1f memoryPeakMB=%{public}.1f memoryGrowthMB=%{public}.1f minimumAvailableMB=%{public}.1f start=%{public}.2f window=%{public}.2f",
                result.dropped,
                result.frames,
                result.lossPercent,
                result.corrupted,
                result.stalls,
                result.audioStalls,
                result.audioDry,
                result.audioGaps,
                result.minVideoQueue,
                Double(result.startingFootprintBytes) / 1_048_576,
                result.peakFootprintMB,
                result.footprintGrowthMB,
                result.minimumAvailableMB,
                result.startPosition,
                result.windowSeconds
            )
        } else if case .warming(let measureFrom) = bench!.phase {
            benchStatus = String(format: "warming · measures @%.0fs", measureFrom)
        } else if case .measuring(let since) = bench!.phase {
            benchStatus = String(format: "measuring %.0f/%.0fs", timePosition - since, bench!.windowSeconds)
        }
    }

    /// Pauses the clock, polls until the cushion is rebuilt, then restarts.
    /// Needs its own loop: the periodic observer stops at rate 0.
    private func beginStallRecovery(cause: PlaybackStarvation) {
        clearPendingStallConfirmation()
        setBuffering(true)
        synchronizer.rate = 0
        stallCount += 1
        if cause == .audio {
            audioStallCount += 1
        }
        EngineDiagnostics.record(.playbackStallBegin, [
            "position": .double(timePosition.rounded(toPlaces: 1)),
            "stallCause": .string(cause.rawValue),
            "stalls": .int(stallCount),
            "videoQueued": .int(videoQueue.count),
            "audioLead": .double(audioDeliveryLeadSeconds.rounded(toPlaces: 2)),
        ])
        if !stallSignpostActive {
            stallSignpostActive = true
            os_signpost(
                .begin,
                log: PlaybackPerformance.log,
                name: "Playback Stall",
                signpostID: performanceSignpostID,
                "position=%{public}.3f count=%{public}d audioDry=%{public}d cause=%{public}s",
                timePosition,
                stallCount,
                audioStarvationCount,
                cause.rawValue
            )
        }
        stallRecoveryTask?.cancel()
        let recoveryStarted = ContinuousClock.now
        stallRecoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                // A seek or shutdown owns the restart from here.
                if self.shared.withLock({ $0.cancelled || $0.pendingSeekSeconds != nil }) { return }
                let decision = StallRecoveryPolicy.decision(
                    elapsed: ContinuousClock.now - recoveryStarted,
                    videoQueueCount: self.videoQueue.count,
                    videoQueueFinished: self.videoQueue.isFinished
                        || self.shared.withLock { $0.videoOutputSuspended },
                    playbackRate: self.effectiveRate,
                    audioRequired: self.buffersOnAudioStarvation
                        && self.hasAudioTrack
                        && !self.audioQueue.isFinished,
                    audioDeliveryLeadSeconds: self.shared.withLock {
                        $0.lastEnqueuedAudioEndSeconds.map { $0 - self.timePosition }
                    },
                    audioRendererHasSufficientData: self.audioRendererReadyForPlayback
                )
                switch decision {
                case .wait:
                    continue
                case .resume:
                    self.setBuffering(false)
                    self.recordStallEnd(outcome: "recovered", since: recoveryStarted, cause: cause)
                    if self.stallSignpostActive {
                        self.stallSignpostActive = false
                        os_signpost(
                            .end,
                            log: PlaybackPerformance.log,
                            name: "Playback Stall",
                            signpostID: self.performanceSignpostID,
                            "outcome=recovered videoQueued=%{public}d",
                            self.videoQueue.count
                        )
                    }
                    if !self.isPaused {
                        self.synchronizer.rate = Float(self.effectiveRate)
                    }
                    return
                case .reprime:
                    self.stallReprimeCount += 1
                    let recoveryPosition = self.timePosition
                    self.recordStallEnd(outcome: "reprimed", since: recoveryStarted, cause: cause)
                    if self.stallSignpostActive {
                        self.stallSignpostActive = false
                        os_signpost(
                            .end,
                            log: PlaybackPerformance.log,
                            name: "Playback Stall",
                            signpostID: self.performanceSignpostID,
                            "outcome=reprime videoQueued=%{public}d",
                            self.videoQueue.count
                        )
                    }
                    os_signpost(
                        .event,
                        log: PlaybackPerformance.log,
                        name: "Playback Stall Reprime",
                        signpostID: self.performanceSignpostID,
                        "position=%{public}.3f count=%{public}d",
                        recoveryPosition,
                        self.stallCount
                    )
                    // A seek rebuilds queues and anchor, so a lost read
                    // cannot leave rate 0 polling forever.
                    self.seek(to: recoveryPosition)
                    return
                }
            }
        }
    }

    /// A stall is reported when it reprimed or lasted this long.
    static let sustainedStallSeconds: Double = 8

    private func recordStallEnd(outcome: String, since: ContinuousClock.Instant, cause: PlaybackStarvation) {
        let elapsedMs = Self.milliseconds(ContinuousClock.now - since)
        let fields: [String: DiagnosticValue] = [
            "position": .double(timePosition.rounded(toPlaces: 1)),
            "outcome": .string(outcome),
            "stallCause": .string(cause.rawValue),
            "elapsedMs": .double(elapsedMs.rounded()),
            "stalls": .int(stallCount),
            "reprimes": .int(stallReprimeCount),
            "videoQueued": .int(videoQueue.count),
        ]
        EngineDiagnostics.record(.playbackStallEnd, fields)
        if outcome == "reprimed" {
            EngineDiagnostics.report(.playbackStall, level: .warning, variant: ["reprime", cause.rawValue], fields: fields)
        } else if elapsedMs >= Self.sustainedStallSeconds * 1_000 {
            EngineDiagnostics.report(.playbackStall, level: .warning, variant: ["sustained", cause.rawValue], fields: fields)
        }
    }

    /// One dry 100 ms tick is not starvation; the queue may refill next
    /// turn. Confirm first, or healthy VC-1 playback micro-stalls.
    private func confirmStallIfPersistent() {
        guard stallConfirmationTask == nil else { return }
        let identifier = UUID()
        stallConfirmationID = identifier
        stallConfirmationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: StallRecoveryPolicy.confirmationDelay)
            } catch {
                return
            }
            guard let self,
                  self.stallConfirmationID == identifier else { return }
            self.stallConfirmationID = nil
            self.stallConfirmationTask = nil
            // Re-read: the dip may have cleared.
            let cause = self.starvation(at: self.timePosition)
            guard StallRecoveryPolicy.confirms(cause, buffersOnAudioStarvation: self.buffersOnAudioStarvation)
            else { return }
            self.beginStallRecovery(cause: cause)
        }
    }

    private func clearPendingStallConfirmation() {
        stallConfirmationID = nil
        stallConfirmationTask?.cancel()
        stallConfirmationTask = nil
    }

    private func starvation(at seconds: Double) -> PlaybackStarvation {
        PlaybackStarvationPolicy.starvation(PlaybackStarvationPolicy.Snapshot(
            isBuffering: isBuffering,
            isPaused: isPaused,
            didFinish: didFinish,
            position: seconds,
            duration: duration,
            rate: effectiveRate,
            videoQueueCount: videoQueue.count,
            videoQueueFinished: videoQueue.isFinished || shared.withLock { $0.videoOutputSuspended },
            videoBufferedTo: shared.withLock { $0.videoBufferedTo },
            hasAudio: hasAudioTrack,
            audioQueueFinished: audioQueue.isFinished,
            audioDeliveryLeadSeconds: shared.withLock {
                $0.lastEnqueuedAudioEndSeconds.map { $0 - seconds }
            }
        ))
    }

    private func refreshSubtitles(at seconds: Double) {
        let active = subtitleStore.active(at: seconds)
        if active.textCues != currentSubtitleCues {
            currentSubtitleCues = active.textCues
            let text = active.textCues.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
            currentSubtitleText = text.isEmpty ? nil : text
        }
        if active.images != currentSubtitleImages {
            currentSubtitleImages = active.images
        }
    }

    private func publishStreams(
        duration: Double,
        videoSize: CGSize,
        displayMatch: DisplayMatchRequest?,
        videoTiming: String?,
        tracks: [PlayerTrack],
        subtitles: [PlayerTrack],
        embeddedSubtitleCount: Int,
        activeSubtitleOrdinal: Int
    ) {
        self.duration = duration
        self.videoSize = videoSize
        displayMatchRequest = displayMatch
        videoTimingDiagnostic = videoTiming
        audioTracks = tracks
        subtitleTracks = subtitles
        self.embeddedSubtitleCount = embeddedSubtitleCount
        // An initially selected external track downloads once the counts
        // are known.
        if activeSubtitleOrdinal > embeddedSubtitleCount {
            commitSubtitleSelection(ordinal: 0)
            selectSubtitleTrack(id: activeSubtitleOrdinal)
        }
    }

    // MARK: - Demux loop (demux queue only)

    nonisolated private func runDemuxLoop(
        url: URL,
        cacheSession: PlaybackCacheSession?,
        disc: DiscPlaybackRequest?,
        recommendedPixelBufferAttributes: CVPixelBufferAttributes,
        authorization: MediaRequestAuthorization?
    ) {
        defer {
            PlaybackLifecycleDiagnostics.demuxEnded(lifecycleID)
        }
        // Whether a cache ended up in front: this, not the delivery,
        // decides the demux cushion.
        var deliveryIsCached = cacheSession != nil
        // libavformat's file protocol takes a path; it does not
        // percent-decode a URL.
        let openTarget = url.isFileURL ? url.path(percentEncoded: false) : url.absoluteString
        do {
            do {
                try demuxer.open(
                    url: openTarget,
                    cacheSession: cacheSession,
                    disc: disc,
                    recommendedPixelBufferAttributes: recommendedPixelBufferAttributes,
                    authorization: authorization
                )
            // No uncached retry for a disc: only the cache can read its
            // filesystem.
            } catch where cacheSession != nil && disc == nil {
                demuxer.close()
                deliveryIsCached = false
                EngineDiagnostics.record(.playbackCacheFallback, ["recovery": .string("cacheFallback")])
                // Retire the unusable scope, keeping any staged successor.
                Task { @MainActor in
                    self.discardPlaybackCache(preservingStagedSuccessor: true)
                }
                try demuxer.open(
                    url: openTarget,
                    cacheSession: nil,
                    recommendedPixelBufferAttributes: recommendedPixelBufferAttributes,
                    authorization: authorization
                )
            }
        } catch {
            let demuxError = error as? DemuxError
            let failure = PlaybackEngineFailure(
                cause: demuxError?.cause ?? .delivery,
                message: demuxError?.errorDescription ?? "The stream could not be opened.",
                detail: demuxError?.diagnosticDetail ?? PlaybackFailureDetail(stage: .open, error: error)
            )
            Task { @MainActor in self.onError?(failure) }
            return
        }
        shared.withLock { $0.deliveryIsCached = deliveryIsCached }
        // A refused VideoToolbox AV1 session reopens once on libdav1d rather
        // than failing the title. Never for HEVC, which has no fallback and
        // must fail loudly.
        if demuxer.videoStream?.codecName == "av1",
           !demuxer.outputsDecodedVideo,
           let description = demuxer.videoStream?.formatDescription,
           !VideoToolboxDecoder.canDecode(description) {
            demuxer.close()
            demuxer.disableVideoToolboxAV1()
            do {
                try demuxer.open(
                    url: openTarget,
                    cacheSession: deliveryIsCached ? cacheSession : nil,
                    disc: disc,
                    recommendedPixelBufferAttributes: recommendedPixelBufferAttributes,
                    authorization: authorization
                )
            } catch {
                let demuxError = error as? DemuxError
                let failure = PlaybackEngineFailure(
                    cause: demuxError?.cause ?? .delivery,
                    message: demuxError?.errorDescription
                        ?? "The stream could not be opened.",
                    detail: demuxError?.diagnosticDetail ?? PlaybackFailureDetail(stage: .open, error: error)
                )
                Task { @MainActor in self.onError?(failure) }
                return
            }
        }
        // The demuxer builds the software decoder but a separate stage
        // drives it, so reading and decoding overlap; 4K AV1 needs that.
        if demuxer.outputsDecodedVideo, let decoder = demuxer.takeSoftwareVideoDecoder() {
            softwareDecodeStage = SoftwareVideoDecodeStage(
                decoder: decoder,
                outputHandler: { [weak self] buffer in
                    self?.acceptSoftwareDecodedVideo(buffer)
                },
                errorHandler: { [weak self] error in
                    self?.failVideoDecode(error)
                },
                packetCompletionHandler: { [weak self] in
                    // Waiters on the in-flight count must re-read it.
                    self?.videoQueue.signalWaiters()
                }
            )
        }
        if let codecName = demuxer.videoStream?.codecName,
           codecName == "hevc" || codecName == "av1",
           !demuxer.outputsDecodedVideo,
           let description = demuxer.videoStream?.formatDescription {
            do {
                // AV1 may have only Apple's software decoder here; demand
                // hardware only where the silicon has it.
                let requiresHardware = codecName != "av1"
                    || PlaybackCapabilities.current.hardwareAV1
                videoDecoder = try VideoToolboxDecoder(
                    formatDescription: description,
                    recommendedPixelBufferAttributes: recommendedPixelBufferAttributes,
                    reportedReorderDepth: demuxer.videoStream?.videoReorderDepth ?? 0,
                    requiresHardware: requiresHardware,
                    outputHandler: { [weak self] buffer in
                        self?.acceptDecodedVideo(buffer)
                    },
                    errorHandler: { [weak self] error in
                        self?.failVideoDecode(error)
                    }
                )
            } catch {
                // No demux loop yet to run a rebuild's seek, so report it.
                failVideoDecode(error, allowSessionRecovery: false)
                demuxer.close()
                return
            }
        }
        // Ordinals are 1-based positions in the demuxed audio list. One
        // lock acquisition: nesting withLock deadlocks.
        let initialOrdinal = shared.withLock { state -> Int in
            if state.selectedAudioOrdinal == 0 {
                state.selectedAudioOrdinal = state.initialAudioOrdinal ?? 1
            }
            return state.selectedAudioOrdinal
        }
        applyAudioSelection(ordinal: initialOrdinal)

        let streams = demuxer.audioStreams
        let audioMetadata = shared.withLock { $0.audioTrackMetadata }
        let demuxedDuration = demuxer.durationSeconds
        let size = videoDimensions()
        // Without a known rate there is no meaningful mode to request.
        let displayMatch: DisplayMatchRequest? = if demuxer.videoFrameRate > 0,
            let description = demuxer.videoStream?.formatDescription {
            DisplayMatchRequest(formatDescription: description, frameRate: Float(demuxer.videoFrameRate))
        } else {
            nil
        }
        let tracks = Self.disambiguated(streams.enumerated().map { offset, stream in
            let metadata = audioMetadata.indices.contains(offset) ? audioMetadata[offset] : nil
            return PlayerTrack(
                engineID: offset + 1,
                kind: .audio,
                displayName: Self.trackName(for: stream),
                isSelected: offset + 1 == initialOrdinal,
                languageTag: metadata?.languageTag ?? stream.language,
                isForced: metadata?.isForced ?? false,
                isHearingImpaired: metadata?.isHearingImpaired ?? false
            )
        })

        // Subtitle ordinals: embedded streams in demux order, then external
        // tracks.
        let embeddedSubtitles = demuxer.subtitleStreams
        let (externals, subtitleMetadata, subtitleOrdinal) = shared.withLock { state -> ([ExternalSubtitleTrack], [PlayerTrackMetadata], Int) in
            state.embeddedSubtitleStreamIndices = embeddedSubtitles.map(\.streamIndex)
            if state.selectedSubtitleOrdinal < 0 {
                state.selectedSubtitleOrdinal = state.initialSubtitleOrdinal ?? 0
            }
            let ordinal = state.selectedSubtitleOrdinal
            if ordinal >= 1, ordinal <= embeddedSubtitles.count {
                state.selectedSubtitleStreamIndex = embeddedSubtitles[ordinal - 1].streamIndex
            }
            return (state.externalSubtitles, state.embeddedSubtitleMetadata, ordinal)
        }
        let subtitleTracks = embeddedSubtitles.enumerated().map { offset, stream in
            let metadata = subtitleMetadata.indices.contains(offset) ? subtitleMetadata[offset] : nil
            return PlayerTrack(
                engineID: offset + 1,
                kind: .subtitle,
                displayName: Self.trackName(for: stream),
                isSelected: offset + 1 == subtitleOrdinal,
                languageTag: metadata?.languageTag ?? stream.language,
                isForced: metadata?.isForced ?? false,
                isHearingImpaired: metadata?.isHearingImpaired ?? false
            )
        } + externals.enumerated().map { offset, track in
            PlayerTrack(
                engineID: embeddedSubtitles.count + offset + 1,
                kind: .subtitle,
                displayName: Self.externalTrackName(for: track),
                isSelected: embeddedSubtitles.count + offset + 1 == subtitleOrdinal,
                languageTag: track.language,
                isForced: track.isForced,
                isHearingImpaired: track.isHearingImpaired,
                source: track.isDownloaded ? .downloaded : .external
            )
        }
        Task { @MainActor in
            self.publishStreams(
                duration: demuxedDuration,
                videoSize: size,
                displayMatch: displayMatch,
                videoTiming: demuxer.videoGridDescription.map {
                    if demuxer.outputsDecodedVideo {
                        "grid \($0) · libavcodec \(demuxer.videoStream?.codecName ?? "?") SW"
                    } else if let videoDecoder {
                        "grid \($0) · VideoToolbox \(videoDecoder.requiresHardware ? "HW" : "system")"
                            + " · reorder \(videoDecoder.reorderDepth)"
                    } else {
                        "grid \($0)"
                    }
                },
                tracks: tracks,
                subtitles: subtitleTracks,
                embeddedSubtitleCount: embeddedSubtitles.count,
                activeSubtitleOrdinal: subtitleOrdinal
            )
        }

        // Last applied subtitle stream, compared each pass so main-actor
        // switches land without a queue hop.
        var appliedSubtitleStreamIndex: Int32 = -1
        // Same for audio-only mode; the resume seek restores video.
        var appliedVideoOutputSuspended = false
        // Opening at zero needs no seek. Every later request, even to zero,
        // must reposition so the first sample after a flush is a keyframe.
        var hasPrimedPlayback = false

        while !shared.withLock({ $0.cancelled }) {
            let desiredSubtitle = shared.withLock { $0.selectedSubtitleStreamIndex }
            if desiredSubtitle != appliedSubtitleStreamIndex {
                demuxer.selectSubtitle(streamIndex: desiredSubtitle >= 0 ? desiredSubtitle : nil)
                appliedSubtitleStreamIndex = desiredSubtitle
            }
            let desiredVideoSuspended = shared.withLock { $0.videoOutputSuspended }
            if desiredVideoSuspended != appliedVideoOutputSuspended {
                demuxer.setVideoDiscarded(desiredVideoSuspended)
                if desiredVideoSuspended {
                    // Leave a VideoToolbox session alone: creating one in the
                    // background can be refused.
                    softwareDecodeStage?.reset()
                    pumpQueue.sync { self.flushVideoPath() }
                }
                appliedVideoOutputSuspended = desiredVideoSuspended
            }
            if let target = shared.withLock({ state -> Double? in
                defer {
                    if let target = state.pendingSeekSeconds {
                        // Everything buffered so far is being flushed.
                        state.videoBufferedTo = target
                        state.mediaEndSeconds = target
                        state.pendingSeekSeconds = nil
                    }
                }
                return state.pendingSeekSeconds
            }) {
                if hasPrimedPlayback || target > 0 {
                    do {
                        try demuxer.seek(toSeconds: target)
                    } catch {
                        let demuxError = error as? DemuxError
                        let failure = PlaybackEngineFailure(
                            cause: demuxError?.cause ?? .delivery,
                            message: demuxError?.errorDescription
                                ?? "The stream could not seek to that position.",
                            detail: demuxError?.diagnosticDetail ?? PlaybackFailureDetail(stage: .seek, error: error)
                        )
                        shared.withLock { $0.cancelled = true }
                        videoQueue.markFinished()
                        audioQueue.markFinished()
                        Task { @MainActor in self.onError?(failure) }
                        break
                    }
                }
                guard prepareVideoDecoderForSeek() else { break }
                // First and synchronously: a frame still in libavcodec is
                // pre-seek and must not land in the emptied queues.
                softwareDecodeStage?.reset()
                // Flush again: anything enqueued since the request-time
                // flush is pre-seek (see the helper).
                pumpQueue.sync { self.flushRenderersAndQueues() }
                applyAudioSelection(ordinal: shared.withLock { $0.selectedAudioOrdinal })
                hasPrimedPlayback = true
                primeAndStart(at: target)
                continue
            }

            if videoQueue.isFinished {
                // EOF reached; idle until a seek arrives or we shut down.
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            // Streams share one demux cursor, so blocking on full video also
            // starves audio; the policy handles that. Parked video goes
            // first: it is older than the next read.
            drainVideoIntake()
            let decodedFrameBytes = softwareDecodeStage?.decodedFrameBytes ?? 0
            let videoIsDecoded = videoDecoder != nil || demuxer.outputsDecodedVideo
            let videoIsSoftwareDecoded = demuxer.outputsDecodedVideo
            let videoHardLimit = DemuxBackpressurePolicy.videoHardLimit(
                videoIsDecoded: videoIsDecoded,
                videoIsSoftwareDecoded: videoIsSoftwareDecoded,
                decodedFrameBytes: decodedFrameBytes
            )
            let videoBacklog = recordVideoBacklog(hardLimit: videoHardLimit)
            let (playbackRate, endOfFilePending) = shared.withLock {
                ($0.playbackRate, $0.endOfFilePendingIntake)
            }
            if endOfFilePending {
                // Nothing left to read; finish once the intake has drained.
                if videoIntake.isEmpty {
                    finishVideoInput()
                } else {
                    videoQueue.waitUntilBelow(videoHardLimit, timeout: Self.demuxWaitTimeout) {
                        self.softwareDecodeStage?.pendingCount ?? 0
                    }
                }
                continue
            }
            switch DemuxBackpressurePolicy.decision(
                videoCount: videoBacklog,
                audioCount: audioQueue.count,
                audioBufferedSeconds: audioQueue.bufferedDuration,
                videoFrameRate: demuxer.videoFrameRate,
                videoIsDecoded: videoIsDecoded,
                videoIsSoftwareDecoded: videoIsSoftwareDecoded,
                hasAudio: !demuxer.audioStreams.isEmpty,
                deliveryIsCached: deliveryIsCached,
                playbackRate: playbackRate,
                decodedFrameBytes: decodedFrameBytes,
                videoIntakeCount: videoIntake.count,
                videoIntakeBytes: videoIntake.byteCount
            ) {
            case .read:
                performDemuxStep()
            case .waitForVideo(let target):
                // Bounded: with the clock stopped nothing dequeues.
                videoQueue.waitUntilBelow(target, timeout: Self.demuxWaitTimeout) {
                    self.softwareDecodeStage?.pendingCount ?? 0
                }
            case .waitForAudio(let target):
                audioQueue.waitUntilBelow(target, timeout: Self.demuxWaitTimeout)
            }
        }
        os_signpost(
            .begin,
            log: PlaybackPerformance.log,
            name: "Demux Close",
            signpostID: performanceSignpostID
        )
        videoDecoder?.invalidate()
        videoDecoder = nil
        softwareDecodeStage?.invalidate()
        softwareDecodeStage = nil
        demuxer.close()
        os_signpost(
            .end,
            log: PlaybackPerformance.log,
            name: "Demux Close",
            signpostID: performanceSignpostID
        )
    }

    /// One av_read_frame worth of work; routes to the queues.
    /// The pool matters: the demux loop is one long-lived work item, so
    /// autoreleased temporaries would otherwise live until close.
    nonisolated private func performDemuxStep() {
        #if DEBUG
        diagnosticFaultGate.waitBeforeDemuxStep()
        #endif
        autoreleasepool {
            step()
        }
    }

    /// Records the video backlog and its peak beside the active bound, so the
    /// HUD can prove the ceiling held over a whole outage.
    @discardableResult
    nonisolated private func recordVideoBacklog(hardLimit: Int) -> Int {
        let backlog = videoQueue.count + (softwareDecodeStage?.pendingCount ?? 0)
        shared.withLock {
            $0.videoQueueHardLimit = hardLimit
            $0.maximumVideoBacklog = max($0.maximumVideoBacklog, backlog)
        }
        return backlog
    }

    /// Everything the container had is in the queues or the decoders:
    /// flush the decoders, close the queues, and arm the finish boundary.
    nonisolated private func finishVideoInput() {
        shared.withLock { $0.endOfFilePendingIntake = false }
        do {
            try videoDecoder?.finish()
            // Frame threading leaves pictures in libavcodec; drain them
            // before the queue is marked finished.
            try softwareDecodeStage?.finish()
        } catch {
            // A dead session at the end costs only its last frames, and the
            // boundary still fires; rebuilding or descending would be worse.
            // Anything else is a real decode failure.
            if let status = (error as? VideoToolboxDecoder.DecoderError)?.status,
               VideoToolboxDecoder.isSessionFault(status) {
                recordVideoSessionFault(status, recovery: "decodeSessionIgnored")
            } else {
                failVideoDecode(error, allowSessionRecovery: false)
                return
            }
        }
        videoQueue.markFinished()
        audioQueue.markFinished()
        let (sampledEnd, generation) = shared.withLock { ($0.mediaEndSeconds, $0.playbackGeneration) }
        if let end = PlaybackEndBoundary.endTime(
            sampledEnd: sampledEnd,
            declaredDuration: demuxer.durationSeconds
        ) {
            Task { @MainActor in
                self.armFinishBoundary(at: end, generation: generation)
            }
        }
    }

    /// Recreates the decode session this seek is about to feed.
    /// A declined session says nothing about the samples, so it gets one
    /// retry, which often succeeds once the old session is gone. Not via
    /// `absorbVideoSessionFault`: the seek needs the loop running. Ignored
    /// while video is suspended; the resume seek runs this again.
    ///
    /// Returns false when the demux loop must stop.
    nonisolated private func prepareVideoDecoderForSeek() -> Bool {
        guard let videoDecoder else { return true }
        do {
            try videoDecoder.reset()
            return true
        } catch {
            guard let status = (error as? VideoToolboxDecoder.DecoderError)?.status,
                  VideoToolboxDecoder.isSessionFault(status) else {
                failVideoDecode(error, allowSessionRecovery: false)
                return false
            }
            if shared.withLock({ $0.videoOutputSuspended }) {
                recordVideoSessionFault(status, recovery: "decodeSessionIgnored")
                return true
            }
            do {
                try videoDecoder.reset()
                recordVideoSessionFault(status, recovery: "decodeSessionRebuilt")
                return true
            } catch {
                // Two failures at the same point: report it.
                failVideoDecode(error, allowSessionRecovery: false)
                return false
            }
        }
    }

    /// Hands video on in order: straight through while there is room and
    /// nothing is parked, otherwise into the intake.
    nonisolated private func admitVideo(_ item: VideoIntakeItem) {
        videoFeedLock.lock()
        defer { videoFeedLock.unlock() }
        if videoIntake.isEmpty, decodedVideoBacklog() < currentVideoHardLimit() {
            deliverVideo(item)
        } else {
            videoIntake.append(item)
        }
    }

    nonisolated private func deliverVideo(_ item: VideoIntakeItem) {
        switch item {
        case .sample(let buffer):
            if let videoDecoder {
                do {
                    try videoDecoder.decode(buffer)
                } catch {
                    failVideoDecode(error)
                }
            } else {
                videoQueue.enqueue(buffer)
                kickPumps()
            }
        case .packet(let packet):
            softwareDecodeStage?.submit(packet)
        }
    }

    /// Moves parked video into the decoders while there is room. The video
    /// pump calls this too: the loop can sit in a network read for seconds,
    /// and the decoded queue must not run dry behind a full intake.
    nonisolated private func drainVideoIntake() {
        guard !shared.withLock({ $0.cancelled }) else { return }
        videoFeedLock.lock()
        defer { videoFeedLock.unlock() }
        let hardLimit = currentVideoHardLimit()
        while decodedVideoBacklog() < hardLimit, let item = videoIntake.popFirst() {
            deliverVideo(item)
        }
    }

    /// Decoded frames plus packets the software stage still owes; every
    /// video limit is measured against this.
    nonisolated private func decodedVideoBacklog() -> Int {
        videoQueue.count + (softwareDecodeStage?.pendingCount ?? 0)
    }

    nonisolated private func currentVideoHardLimit() -> Int {
        DemuxBackpressurePolicy.videoHardLimit(
            videoIsDecoded: videoDecoder != nil || demuxer.outputsDecodedVideo,
            videoIsSoftwareDecoded: demuxer.outputsDecodedVideo,
            decodedFrameBytes: softwareDecodeStage?.decodedFrameBytes ?? 0
        )
    }

    nonisolated private func step() {
        switch demuxer.readNext() {
        case .video(let buffer):
            recordMediaEnd(buffer)
            if let seconds = Self.presentationEnd(of: buffer) {
                // Stall detection reads this. Parked video counts too.
                shared.withLock { $0.videoBufferedTo = max($0.videoBufferedTo, seconds) }
            }
            admitVideo(.sample(buffer))
        case .videoPacket(let packet):
            // Stall detection and the finish boundary use the packet's time.
            if let seconds = packet.endSeconds {
                shared.withLock {
                    $0.mediaEndSeconds = max($0.mediaEndSeconds, seconds)
                    $0.videoBufferedTo = max($0.videoBufferedTo, seconds)
                }
            }
            admitVideo(.packet(packet))
        case .audio(let buffers, let streamIndex):
            let (selected, delay, floor) = shared.withLock {
                ($0.selectedAudioStreamIndex, $0.audioDelaySeconds, $0.audioAdmissionFloorSeconds)
            }
            if streamIndex == selected {
                for buffer in buffers {
                    // Pre-delay is fine: the delay shifts every stamp alike.
                    audioContinuity.observe(buffer)
                    let output = delay == 0 ? buffer : Self.retimed(buffer, by: delay)
                    // Drop audio before the seek target; a coarse fragment
                    // starts earlier and that part never plays.
                    if let end = Self.presentationEnd(of: output), end <= floor { continue }
                    recordMediaEnd(output)
                    audioQueue.enqueue(output)
                }
                kickPumps()
            }
        case .subtitle(let events, let streamIndex):
            shared.withLock { state in
                guard streamIndex == state.selectedSubtitleStreamIndex else { return }
                for event in events {
                    switch event {
                    case .cue(let cue):
                        subtitleStore.add(cue)
                    case .clear(let seconds):
                        subtitleStore.closeOpenCues(at: seconds)
                    }
                }
            }
        case .skipped:
            break
        case .endOfFile:
            // Parked video is the end of the film too; the loop finishes
            // once it drains.
            guard videoIntake.isEmpty else {
                shared.withLock { $0.endOfFilePendingIntake = true }
                return
            }
            finishVideoInput()
        case .failed(let message):
            videoQueue.markFinished()
            audioQueue.markFinished()
            // Failing past libavformat's reconnects: transport, not samples.
            let failure = PlaybackEngineFailure(
                cause: .delivery,
                message: "Playback failed in the Lagoon engine (\(message)).",
                detail: PlaybackFailureDetail(stage: .read, domain: "ffmpeg.read")
            )
            Task { @MainActor in self.onError?(failure) }
            shared.withLock { $0.cancelled = true }
        }
    }

    /// Frames from the software decode stage. Unlike `acceptDecodedVideo`,
    /// never drops on a pending seek (the stage discards pre-seek work on
    /// reset); dropping here starved stall re-priming.
    nonisolated private func acceptSoftwareDecodedVideo(_ buffer: CMSampleBuffer) {
        guard !shared.withLock({ $0.cancelled }) else { return }
        videoQueue.enqueue(buffer)
        kickPumps()
    }

    nonisolated private func acceptDecodedVideo(_ buffer: CMSampleBuffer) {
        let shouldDrop = shared.withLock { $0.cancelled || $0.pendingSeekSeconds != nil }
        guard !shouldDrop else { return }
        videoQueue.enqueue(buffer)
        kickPumps()
    }

    nonisolated private func recordMediaEnd(_ buffer: CMSampleBuffer) {
        guard let end = Self.presentationEnd(of: buffer) else { return }
        shared.withLock { $0.mediaEndSeconds = max($0.mediaEndSeconds, end) }
    }

    nonisolated private static func presentationEnd(of buffer: CMSampleBuffer) -> Double? {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard pts.isValid, pts.seconds.isFinite else { return nil }
        let sampleDuration = CMSampleBufferGetDuration(buffer)
        let end = sampleDuration.isValid && sampleDuration.seconds.isFinite
            ? CMTimeAdd(pts, sampleDuration).seconds
            : pts.seconds
        return end.isFinite ? end : nil
    }

    /// - Parameter allowSessionRecovery: false where the caller stops the
    ///   demux loop anyway. A rebuild is a seek that needs a running loop, so
    ///   absorbing the fault there would turn a failure into a silent hang.
    nonisolated private func failVideoDecode(_ error: Error, allowSessionRecovery: Bool = true) {
        // A lost or refused session is not a verdict on the bitstream.
        if allowSessionRecovery, absorbVideoSessionFault(error) { return }
        let wasAlreadyCancelled = shared.withLock { state -> Bool in
            let previous = state.cancelled
            state.cancelled = true
            return previous
        }
        guard !wasAlreadyCancelled else { return }
        videoQueue.markFinished()
        audioQueue.markFinished()
        videoQueue.interruptWaits()
        audioQueue.interruptWaits()
        demuxer.interrupt()
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if EngineTuning.current.profilesAV1Pipeline {
            let output = softwareDecodeStage?.outputModeName ?? "unknown"
            print("SoftwareVideoDecodeFailure output=\"\(output)\" detail=\"\(detail)\"")
        }
        // What is left is a verdict on the samples. Redelivering the same
        // bitstream cannot change it.
        let failure = PlaybackEngineFailure(
            cause: .undecodable,
            message: "Playback failed in the Lagoon engine (\(detail)).",
            detail: Self.decodeFailureDetail(error)
        )
        Task { @MainActor in
            self.onError?(failure)
        }
    }

    /// Handles a lost VideoToolbox session, as opposed to undecodable
    /// samples. True when handled here; it must not reach the ladder, or a
    /// reclaimed session reads as "cannot decode this file".
    nonisolated private func absorbVideoSessionFault(_ error: Error) -> Bool {
        guard let status = (error as? VideoToolboxDecoder.DecoderError)?.status,
              VideoToolboxDecoder.isSessionFault(status) else { return false }
        let resolution = shared.withLock { state -> PlaybackDecodeSessionPolicy.Resolution in
            let resolution = PlaybackDecodeSessionPolicy.resolve(
                cancelled: state.cancelled,
                videoOutputSuspended: state.videoOutputSuspended,
                recoveryInFlight: state.videoSessionRecoveryInFlight,
                playbackGeneration: state.playbackGeneration,
                rebuiltGeneration: state.videoSessionRebuiltGeneration
            )
            // Claim under the same lock, or every queued sample starts a
            // rebuild.
            if resolution == .rebuild { state.videoSessionRecoveryInFlight = true }
            return resolution
        }
        switch resolution {
        case .descend:
            return false
        case .tooLate:
            return true
        case .alreadyRecovering:
            // Not recorded: dozens of samples report the same dead session,
            // and would evict the history that explains the incident.
            return true
        case .ignore:
            recordVideoSessionFault(status, recovery: "decodeSessionIgnored")
            return true
        case .rebuild:
            // Recorded on the main actor, where the outcome is known.
            Task { @MainActor in self.rebuildVideoDecodeSession(after: status) }
            return true
        }
    }

    /// Rebuilds by seeking in place: the seek resets the decoder, so the new
    /// session starts on a keyframe.
    private func rebuildVideoDecodeSession(after status: OSStatus) {
        // In the last second `seek` clamps backwards; losing the final
        // frames costs less than replaying the last second.
        guard !shutdownRequested, !didFinish,
              duration <= 0 || timePosition < duration - 1 else {
            recordVideoSessionFault(status, recovery: "decodeSessionIgnored")
            shared.withLock {
                // Mark spent anyway, or every remaining sample asks for
                // another rebuild.
                $0.videoSessionRebuiltGeneration = $0.playbackGeneration
                $0.videoSessionRecoveryInFlight = false
            }
            return
        }
        recordVideoSessionFault(status, recovery: "decodeSessionRebuilt")
        let position = timePosition
        os_signpost(
            .event,
            log: PlaybackPerformance.log,
            name: "Renderer Recovery",
            signpostID: performanceSignpostID,
            "position=%{public}.3f reason=decodeSession",
            position
        )
        seek(to: position)
        // After the seek, which bumps the generation: a second dead session
        // here descends the ladder, a later viewer seek earns a rebuild.
        shared.withLock {
            $0.videoSessionRebuiltGeneration = $0.playbackGeneration
            $0.videoSessionRecoveryInFlight = false
        }
    }

    /// A session fault that did not fail playback. Always recorded; reported
    /// only when it cost a rebuild, since ignored ones are expected noise.
    nonisolated private func recordVideoSessionFault(_ status: OSStatus, recovery: String) {
        let detail = PlaybackFailureDetail(
            stage: .decode,
            domain: "VideoToolbox.session",
            code: Int(status)
        )
        let fields = detail.fields.merging([
            "recovery": .string(recovery),
        ]) { _, new in new }
        EngineDiagnostics.record(.playbackRendererRecovery, fields)
        guard recovery == "decodeSessionRebuilt" else { return }
        EngineDiagnostics.report(
            .playbackRendererRecovery,
            level: .warning,
            variant: [recovery] + detail.fingerprint.dropFirst(),
            fields: fields
        )
    }

    /// VideoToolbox failures carry an OSStatus worth keeping; every other
    /// decoder error reports its domain and case index only.
    nonisolated private static func decodeFailureDetail(_ error: Error) -> PlaybackFailureDetail {
        if let failure = error as? VideoToolboxDecoder.DecoderError {
            switch failure {
            case .sessionCreation(let status):
                return PlaybackFailureDetail(stage: .decode, domain: "VideoToolbox.sessionCreation", code: Int(status))
            case .decode(let status):
                return PlaybackFailureDetail(stage: .decode, domain: "VideoToolbox.decode", code: Int(status))
            case .outputFormat(let status):
                return PlaybackFailureDetail(stage: .decode, domain: "VideoToolbox.outputFormat", code: Int(status))
            case .outputSample(let status):
                return PlaybackFailureDetail(stage: .decode, domain: "VideoToolbox.outputSample", code: Int(status))
            }
        }
        if error is SoftwareVideoDecoder.DecoderError {
            return PlaybackFailureDetail(stage: .decode, domain: "SoftwareVideoDecoder", code: (error as NSError).code)
        }
        return PlaybackFailureDetail(stage: .decode, error: error)
    }

    /// Fills the queues enough to start cleanly, then hands the clock to
    /// the main actor.
    nonisolated private func primeAndStart(at target: Double) {
        let generation = shared.withLock { state -> Int in
            state.audioAdmissionFloorSeconds = target
            return state.playbackGeneration
        }
        let hasAudio = !demuxer.audioStreams.isEmpty
        let videoHardLimit = DemuxBackpressurePolicy.videoHardLimit(
            videoIsDecoded: videoDecoder != nil || demuxer.outputsDecodedVideo,
            videoIsSoftwareDecoded: demuxer.outputsDecodedVideo,
            decodedFrameBytes: softwareDecodeStage?.decodedFrameBytes ?? 0
        )
        recordVideoBacklog(hardLimit: videoHardLimit)
        let playbackRate = shared.withLock { $0.playbackRate }
        let baseVideoReserve = demuxer.outputsDecodedVideo ? 18 : 12
        let minimumVideoReserve = min(
            Int(ceil(Double(baseVideoReserve) * playbackRate)),
            max(videoHardLimit - 1, 1)
        )
        let minimumAudioReserve = 1.25 * playbackRate
        // Audio ahead of the target, in the renderer or the queue; the pump
        // may already have moved some. Audio before the target counts for
        // nothing, or a coarse fragment would prime on it.
        let audioAhead = { () -> Double in
            let delivered = self.shared.withLock { state in
                state.lastEnqueuedAudioEndSeconds.map { max($0 - target, 0) } ?? 0
            }
            return delivered + self.audioQueue.bufferedDuration(after: target)
        }
        // With video suspended, only audio decides end of input.
        let videoSuspended = shared.withLock { $0.videoOutputSuspended }
        let inputOpen = { videoSuspended ? !self.audioQueue.isFinished : !self.videoQueue.isFinished }
        while ((!videoSuspended && videoQueue.count < minimumVideoReserve)
                || (hasAudio && audioAhead() < minimumAudioReserve)),
              inputOpen(),
              !shared.withLock({ $0.cancelled }) {
            if shared.withLock({ $0.pendingSeekSeconds != nil }) { return }
            let pendingDecode = softwareDecodeStage?.pendingCount ?? 0
            recordVideoBacklog(hardLimit: videoHardLimit)
            guard videoQueue.count + pendingDecode >= videoHardLimit else {
                performDemuxStep()
                continue
            }
            // Decoded queue full, audio still short: in an HLS fragment the
            // audio sits behind the video, so read on and park video
            // compressed, within the intake's bounds.
            if hasAudio, audioAhead() < minimumAudioReserve,
               videoIntake.count < DemuxBackpressurePolicy.videoIntakeHardLimit,
               videoIntake.byteCount < DemuxBackpressurePolicy.videoIntakeByteBudget,
               !shared.withLock({ $0.endOfFilePendingIntake }) {
                performDemuxStep()
                continue
            }
            // Read all the memory limit allows. Wait for frames still in the
            // decoder, or playback starts on an empty renderer.
            guard let stage = softwareDecodeStage, pendingDecode > 0 else { break }
            stage.waitUntilPendingBelow(pendingDecode)
        }
        recordVideoBacklog(hardLimit: videoHardLimit)
        // After any scheduled pumps, so the first enqueued video PTS can
        // anchor the clock; otherwise the target is the fallback.
        pumpQueue.async { [weak self] in
            guard let self else { return }
            let isCurrentGeneration = self.shared.withLock {
                !$0.cancelled
                    && $0.pendingSeekSeconds == nil
                    && $0.playbackGeneration == generation
            }
            guard isCurrentGeneration else { return }
            self.pumpVideo()
            self.pumpAudio()
            let firstVideoPTS = self.shared.withLock { $0.firstEnqueuedVideoPTS }
            Task { @MainActor in
                let isStillCurrent = self.shared.withLock {
                    !$0.cancelled
                        && $0.pendingSeekSeconds == nil
                        && $0.playbackGeneration == generation
                }
                guard isStillCurrent else { return }
                self.beginPlayback(at: target, firstVideoPTS: firstVideoPTS)
            }
        }
    }

    nonisolated private func applyAudioSelection(ordinal: Int) {
        let streams = demuxer.audioStreams
        guard !streams.isEmpty else { return }
        let index = min(max(ordinal - 1, 0), streams.count - 1)
        let stream = streams[index]
        shared.withLock { $0.selectedAudioStreamIndex = stream.streamIndex }
        demuxer.selectAudio(streamIndex: stream.streamIndex)

        var diagnostic = "\(stream.codecName) · \(stream.channels)ch"
        let locallyDecoded = demuxer.outputsDecodedAudio(streamIndex: stream.streamIndex)
        if locallyDecoded {
            diagnostic += " · local LPCM"
        }
        if stream.isAtmos {
            diagnostic += " · Atmos (JOC)"
        } else if stream.codecName == "eac3" {
            diagnostic += " · no JOC"
        }
        let publishedDiagnostic = diagnostic
        Task { @MainActor in
            self.audioDiagnostic = publishedDiagnostic
            self.audioOutputPathDiagnostic = locallyDecoded ? "LPCM" : "compressed"
        }
    }

    /// Copy with all timestamps shifted by the audio delay.
    nonisolated private static func retimed(_ buffer: CMSampleBuffer, by delay: Double) -> CMSampleBuffer {
        var entryCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &entryCount
        ) == noErr, entryCount > 0 else { return buffer }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: entryCount)
        guard CMSampleBufferGetSampleTimingInfoArray(
            buffer, entryCount: entryCount, arrayToFill: &timings, entriesNeededOut: &entryCount
        ) == noErr else { return buffer }
        let offset = CMTime(seconds: delay, preferredTimescale: 90_000)
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp = timings[index].presentationTimeStamp + offset
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = timings[index].decodeTimeStamp + offset
            }
        }
        var retimed: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleTimingEntryCount: entryCount,
            sampleTimingArray: &timings,
            sampleBufferOut: &retimed
        ) == noErr, let retimed else { return buffer }
        return retimed
    }

    nonisolated private func videoDimensions() -> CGSize {
        guard let description = demuxer.videoStream?.formatDescription else { return .zero }
        // Presentation, not coded, dimensions: the subtitle overlay is laid
        // out against this, and anamorphic streams differ.
        return CMVideoFormatDescriptionGetPresentationDimensions(
            description,
            usePixelAspectRatio: true,
            useCleanAperture: true
        )
    }

    nonisolated private static func trackName(for stream: DemuxedStream) -> String {
        let language = stream.language.flatMap {
            Locale.current.localizedString(forLanguageCode: $0) ?? $0.uppercased()
        }
        var detail = stream.title
        if detail == nil {
            var facts = Self.friendlyCodecName(stream.codecName)
            if let layout = Self.channelLabel(stream.channels) {
                facts += " \(layout)"
            }
            detail = facts
        }
        var name = [language, detail].compactMap(\.self).joined(separator: " · ")
        // Most mux titles do not mention Atmos.
        if stream.isAtmos, !name.localizedCaseInsensitiveContains("atmos") {
            name += " · Atmos"
        }
        return name.isEmpty ? "Track \(stream.streamIndex)" : name
    }

    /// Appends the track number to any display name that is not unique.
    nonisolated public static func disambiguated(_ tracks: [PlayerTrack]) -> [PlayerTrack] {
        var counts: [String: Int] = [:]
        for track in tracks {
            counts[track.displayName, default: 0] += 1
        }
        guard counts.values.contains(where: { $0 > 1 }) else { return tracks }
        return tracks.map { track in
            guard counts[track.displayName, default: 0] > 1 else { return track }
            return PlayerTrack(
                engineID: track.engineID,
                kind: track.kind,
                displayName: "\(track.displayName) · Track \(track.engineID)",
                isSelected: track.isSelected,
                languageTag: track.languageTag,
                isForced: track.isForced,
                isHearingImpaired: track.isHearingImpaired,
                source: track.source
            )
        }
    }

    nonisolated private static func friendlyCodecName(_ codecName: String) -> String {
        switch codecName {
        case "eac3": "Dolby Digital+"
        case "ac3": "Dolby Digital"
        case "truehd": "Dolby TrueHD"
        case "dts": "DTS"
        default: codecName.uppercased()
        }
    }

    nonisolated private static func channelLabel(_ channels: Int) -> String? {
        switch channels {
        case 0: nil
        case 1: "1.0"
        case 2: "2.0"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(channels)ch"
        }
    }

    nonisolated private static func externalTrackName(for track: ExternalSubtitleTrack) -> String {
        track.title
            ?? track.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
            ?? String(localized: "External")
    }

    // MARK: - Renderer pumps (pump queue only)

    nonisolated private func kickPumps() {
        guard pumpKickState.request() else { return }
        pumpQueue.async { [weak self] in
            guard let self else { return }
            repeat {
                self.pumpVideo()
                self.pumpAudio()
                self.rearmRequestsIfNeeded()
            } while self.pumpKickState.completeCycle()
        }
    }

    /// Arm a request block only while there is something to give: a block
    /// that returns empty-handed is called again at once, a busy loop that
    /// cost 0.4 of a core. A pump that finds its queue empty disarms, and
    /// `kickPumps()` re-arms when a buffer arrives.
    nonisolated private func armVideoRequests(_ renderer: AVSampleBufferVideoRenderer) {
        guard !videoRequestsArmed else { return }
        videoRequestsArmed = true
        renderer.requestMediaDataWhenReady(on: pumpQueue) { [weak self] in
            self?.pumpVideo(fromRequest: true)
        }
    }

    nonisolated private func armAudioRequests(_ renderer: AVSampleBufferAudioRenderer) {
        guard !audioRequestsArmed else { return }
        audioRequestsArmed = true
        renderer.requestMediaDataWhenReady(on: pumpQueue) { [weak self] in
            self?.pumpAudio(fromRequest: true)
        }
    }

    nonisolated private func rearmRequestsIfNeeded() {
        if let renderer = videoRenderer, videoQueue.count > 0 {
            armVideoRequests(renderer)
        }
        #if DEBUG
        // Not during an injected hold: the queue keeps filling, and each
        // cycle would re-arm a block that only disarms again.
        if let renderer = audioRenderer, audioQueue.count > 0, !diagnosticFaultGate.audioDeliverySuspended {
            armAudioRequests(renderer)
        }
        #else
        if let renderer = audioRenderer, audioQueue.count > 0 {
            armAudioRequests(renderer)
        }
        #endif
    }

    /// Apple's post-flush keyframe rule. Only the first sample after a flush
    /// is checked; a drop leaves the counter at zero so the next is too.
    nonisolated private func admitsAsRendererStart(_ buffer: CMSampleBuffer) -> Bool {
        let (samples, dropped) = shared.withLock {
            ($0.videoSamplesSinceFlush, $0.videoStartPointDropsSinceFlush)
        }
        guard samples == 0 else { return true }
        guard !PlaybackRendererStartPolicy.admits(
            isSyncSample: SampleBufferFactory.isSyncSample(buffer),
            videoSamplesSinceFlush: samples,
            droppedSinceFlush: dropped
        ) else { return true }
        shared.withLock {
            $0.videoStartPointDropsSinceFlush += 1
            $0.videoStartPointDrops += 1
        }
        if ProcessCPUTrace.enabled {
            print(String(
                format: "RendererStartDrop pts=%.3f dropped=%d",
                CMSampleBufferGetPresentationTimeStamp(buffer).seconds,
                dropped + 1
            ))
        }
        return false
    }

    nonisolated private func pumpVideo(fromRequest: Bool = false) {
        guard let renderer = videoRenderer else { return }
        while renderer.isReadyForMoreMediaData {
            guard let buffer = videoQueue.dequeue() else {
                if fromRequest {
                    idleRequestCounter.wrappingAdd(1, ordering: .relaxed)
                }
                if videoRequestsArmed {
                    videoRequestsArmed = false
                    renderer.stopRequestingMediaData()
                }
                return
            }
            guard admitsAsRendererStart(buffer) else {
                // A refused sample still made room for the intake.
                drainVideoIntake()
                continue
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            shared.withLock { state in
                if pts.isValid, state.firstEnqueuedVideoPTS == nil {
                    state.firstEnqueuedVideoPTS = pts
                }
                state.videoSamplesSinceFlush += 1
            }
            let enqueueStarted = ProcessInfo.processInfo.systemUptime
            renderer.enqueue(buffer)
            av1PipelineTimings.recordEnqueue(
                from: enqueueStarted,
                to: ProcessInfo.processInfo.systemUptime
            )
            drainVideoIntake()
        }
    }

    nonisolated private func sampleAV1Pipeline() {
        guard let renderer = videoRenderer else { return }
        av1PipelineTimings.sample(
            at: ProcessInfo.processInfo.systemUptime,
            rendererReady: renderer.isReadyForMoreMediaData,
            renderQueue: videoQueue.count,
            decodePending: softwareDecodeStage?.pendingCount ?? 0
        )
    }

    nonisolated private func pumpAudio(fromRequest: Bool = false) {
        guard let renderer = audioRenderer else { return }
        #if DEBUG
        guard !diagnosticFaultGate.audioDeliverySuspended else {
            if audioRequestsArmed {
                audioRequestsArmed = false
                renderer.stopRequestingMediaData()
            }
            return
        }
        #endif
        while renderer.isReadyForMoreMediaData {
            guard let buffer = audioQueue.dequeue() else {
                if fromRequest {
                    idleRequestCounter.wrappingAdd(1, ordering: .relaxed)
                }
                if audioRequestsArmed {
                    audioRequestsArmed = false
                    renderer.stopRequestingMediaData()
                }
                return
            }
            renderer.enqueue(buffer)
            if let end = Self.presentationEnd(of: buffer) {
                shared.withLock { $0.lastEnqueuedAudioEndSeconds = end }
            }
        }
    }
}

// MARK: - Support types

/// Why an audio renderer is being replaced; the cases differ only in
/// whether playback resumes.
nonisolated enum AudioRendererReplacement: Equatable {
    /// Media services restarted. Apple requires waiting for an explicit
    /// user action before resuming, so this stays paused.
    case mediaServicesReset
    /// The renderer reported terminal `.failed`; playback resumes on its own
    /// once the replacement is fed.
    case rendererFailed

    var staysPaused: Bool {
        switch self {
        case .mediaServicesReset: true
        case .rendererFailed: false
        }
    }

    var reason: StaticString {
        switch self {
        case .mediaServicesReset: "mediaServicesReset"
        case .rendererFailed: "rendererFailed"
        }
    }

    /// Used when the replacement itself fails. `detail` is the renderer's
    /// own error, preferred where there is one.
    func failureMessage(detail: String?) -> String {
        switch self {
        case .mediaServicesReset:
            "Playback audio could not recover after the media service restarted."
        case .rendererFailed:
            if let detail, !detail.isEmpty {
                "Playback audio failed and could not be restarted (\(detail))."
            } else {
                "Playback audio failed and could not be restarted."
            }
        }
    }
}

nonisolated enum StallRecoveryDecision: Equatable {
    case wait
    case resume
    case reprime
}

/// Which half of the pipeline has run dry, if either.
nonisolated enum PlaybackStarvation: String, Equatable {
    case none
    case video
    case audio
}

/// Video starvation stops the clock. Audio starvation is only counted.
///
/// **`audioQueue` depth does not measure audio starvation.** The renderer
/// drains it, so it reads near zero on a healthy title; treating that as a
/// stall broke every title with audio. Audio uses renderer delivery lead.
nonisolated enum PlaybackStarvationPolicy {
    /// How little lead the clock may have over delivered video before the
    /// picture is called starved.
    static let videoLeadSeconds = 0.2
    /// Renderer delivery lead, not engine queue depth, which AVFoundation
    /// normally drains to zero.
    static let audioFloorSeconds = 0.25

    struct Snapshot {
        var isBuffering = false
        var isPaused = false
        var didFinish = false
        var position: Double = 0
        var duration: Double = 0
        var rate: Double = 1
        var videoQueueCount = 0
        var videoQueueFinished = false
        var videoBufferedTo: Double = 0
        var hasAudio = false
        var audioQueueFinished = false
        /// Nil until the first audio sample reaches the renderer; nothing is
        /// starved before that.
        var audioDeliveryLeadSeconds: Double?
    }

    static func starvation(_ snapshot: Snapshot) -> PlaybackStarvation {
        guard !snapshot.isBuffering,
              !snapshot.isPaused,
              !snapshot.didFinish,
              snapshot.duration <= 0 || snapshot.position < snapshot.duration - 1
        else { return .none }
        // Video first: it freezes the picture. Margins are media time, so
        // they scale with rate to keep the same wall-clock cushion.
        if !snapshot.videoQueueFinished,
           snapshot.videoQueueCount == 0,
           snapshot.videoBufferedTo - snapshot.position < videoLeadSeconds * snapshot.rate {
            return .video
        }
        if snapshot.hasAudio,
           !snapshot.audioQueueFinished,
           let lead = snapshot.audioDeliveryLeadSeconds,
           lead < audioFloorSeconds * snapshot.rate {
            return .audio
        }
        return .none
    }
}

#if DEBUG
/// Debug fault gates for diagnostics and the regression suite. The demux
/// side waits on a condition, so an outage costs no CPU and teardown can
/// always wake it.
nonisolated final class PlaybackDiagnosticFaultGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isCancelled = false
    private var isDemuxDeliverySuspended = false
    private var isAudioDeliverySuspended = false

    var audioDeliverySuspended: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isAudioDeliverySuspended
    }

    func setAudioDeliverySuspended(_ suspended: Bool) {
        condition.lock()
        isAudioDeliverySuspended = suspended && !isCancelled
        condition.unlock()
    }

    func setDemuxDeliverySuspended(_ suspended: Bool) {
        condition.lock()
        isDemuxDeliverySuspended = suspended && !isCancelled
        if !isDemuxDeliverySuspended { condition.broadcast() }
        condition.unlock()
    }

    func waitBeforeDemuxStep() {
        condition.lock()
        while isDemuxDeliverySuspended && !isCancelled {
            condition.wait()
        }
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        isCancelled = true
        isDemuxDeliverySuspended = false
        isAudioDeliverySuspended = false
        condition.broadcast()
        condition.unlock()
    }
}
#endif

/// Pure, so an endless stall is a deterministic test failure. Twelve frames
/// matches the demuxer's low-water cushion; five seconds allows a normal
/// network refill but stays well below a visibly frozen player.
nonisolated enum StallRecoveryPolicy {
    static let confirmationDelay: Duration = .seconds(1)
    static let resumeVideoCount = 12
    static let reprimeAfter: Duration = .seconds(5)
    /// Renderer delivery lead required before an audio-gated resume, scaled
    /// by rate.
    static let resumeAudioLeadSeconds = 1.0
    /// Lead still required when the renderer reports it is ready: clear of
    /// the 0.25 s starvation floor, so the first tick cannot re-arm a stall.
    static let resumeAudioLeadFloorSeconds = 0.5

    /// `.audio` confirms a stall only when `buffersOnAudioStarvation` is on.
    static func confirms(_ starvation: PlaybackStarvation, buffersOnAudioStarvation: Bool) -> Bool {
        switch starvation {
        case .video: return true
        case .audio: return buffersOnAudioStarvation
        case .none: return false
        }
    }

    /// Audio readiness reads renderer lead and readiness, never `audioQueue`,
    /// which the renderer drains as fast as it fills. Readiness normally
    /// decides: with the clock stopped the lead parks just under 1 s.
    /// Checked only when `audioRequired`, then for video stalls too.
    static func decision(
        elapsed: Duration,
        videoQueueCount: Int,
        videoQueueFinished: Bool,
        playbackRate: Double = 1,
        audioRequired: Bool = false,
        audioDeliveryLeadSeconds: Double? = nil,
        audioRendererHasSufficientData: Bool = false
    ) -> StallRecoveryDecision {
        let requiredVideoCount = Int(ceil(
            Double(resumeVideoCount) * PlaybackRatePolicy.clamped(playbackRate)
        ))
        let videoReady = videoQueueCount >= requiredVideoCount || videoQueueFinished
        let rate = PlaybackRatePolicy.clamped(playbackRate)
        let lead = audioDeliveryLeadSeconds ?? -.infinity
        let audioReady = !audioRequired
            || lead >= resumeAudioLeadSeconds * rate
            || (audioRendererHasSufficientData && lead >= resumeAudioLeadFloorSeconds * rate)
        if videoReady && audioReady {
            return .resume
        }
        if elapsed >= reprimeAfter {
            return .reprime
        }
        return .wait
    }
}

/// State shared by the main actor, demux loop and pumps, behind one lock.
nonisolated private final class SharedState: @unchecked Sendable {
    struct State {
        var cancelled = false
        var pendingSeekSeconds: Double?
        /// Invalidates an already-primed start when a newer seek is issued.
        var playbackGeneration = 0
        var selectedAudioOrdinal = 0
        var selectedAudioStreamIndex: Int32 = -1
        var initialAudioOrdinal: Int?
        /// -1 = not yet set (the demux loop applies the initial choice on
        /// open); 0 = subtitles off.
        var selectedSubtitleOrdinal = -1
        var selectedSubtitleStreamIndex: Int32 = -1
        var initialSubtitleOrdinal: Int?
        var audioTrackMetadata: [PlayerTrackMetadata] = []
        var embeddedSubtitleMetadata: [PlayerTrackMetadata] = []
        var embeddedSubtitleStreamIndices: [Int32] = []
        var externalSubtitles: [ExternalSubtitleTrack] = []
        /// Highest video pts the demuxer has delivered, for stall detection.
        var videoBufferedTo: Double = 0
        /// Audio-only background playback: video is discarded, and anything
        /// that would wait for video treats it as finished.
        var videoOutputSuspended = false
        /// Whether the stream got a playback cache; decides the demux cushion.
        var deliveryIsCached = true
        /// Furthest presentation end across audio and video; the EOF
        /// boundary, even without a container duration.
        var mediaEndSeconds: Double = 0
        var audioDelaySeconds: Double = 0
        /// Media seconds per wall-clock second; scales demux watermarks.
        var playbackRate: Double = 1
        /// First sample actually accepted by the renderer after attach/flush.
        var firstEnqueuedVideoPTS: CMTime?
        /// Video samples enqueued since the last flush. A failure within the
        /// first few is about the restart point, not the stream, and earns
        /// one in-place retry.
        var videoSamplesSinceFlush = 0
        /// Samples refused as a flushed renderer's first: since the flush,
        /// and for the whole attempt (reported; a climbing count means a race).
        var videoStartPointDropsSinceFlush = 0
        var videoStartPointDrops = 0
        /// Presentation stamp of the last sample a renderer refused, in
        /// media milliseconds.
        var lastRefusedSampleMs: Int?
        /// One VideoToolbox session rebuild per generation, and whether one
        /// is in flight: every sample in a dead decoder reports the same
        /// fault.
        var videoSessionRebuiltGeneration: Int?
        var videoSessionRecoveryInFlight = false
        /// Furthest audio presentation end handed to AVFoundation, compared
        /// with the clock for starvation.
        var lastEnqueuedAudioEndSeconds: Double?
        /// The active bound, so the probe can assert it is never exceeded.
        var videoQueueHardLimit = 0
        /// Peak video backlog under that bound, for the engine's lifetime.
        var maximumVideoBacklog = 0
        /// EOF read while the intake still held video; the loop finishes the
        /// queues once it drains.
        var endOfFilePendingIntake = false
        /// Where playback last started. Earlier audio is never played, and
        /// queued it would throttle read-ahead when the renderer holds least.
        var audioAdmissionFloorSeconds: Double = -.infinity
    }

    private let lock = NSLock()
    private var state = State()

    func withLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

/// Media time for the clock anchor. A seek may enqueue pre-target reference
/// frames, so use the first enqueued PTS only when it is at or past the target.
nonisolated enum PlaybackClockAnchor {
    static func mediaTime(targetSeconds: Double, firstVideoPTS: CMTime?) -> CMTime {
        let target = CMTime(seconds: max(targetSeconds, 0), preferredTimescale: 240_000)
        guard let firstVideoPTS,
              firstVideoPTS.isValid,
              firstVideoPTS.seconds.isFinite,
              CMTimeCompare(firstVideoPTS, target) >= 0 else { return target }
        return firstVideoPTS
    }
}

/// Resolves EOF from the last sample end. The container duration is only a
/// fallback: it can be missing, or outlast a truncated input.
nonisolated enum PlaybackEndBoundary {
    static func endTime(sampledEnd: Double, declaredDuration: Double) -> Double? {
        if sampledEnd.isFinite, sampledEnd > 0 {
            return sampledEnd
        }
        if declaredDuration.isFinite, declaredDuration >= 0 {
            return declaredDuration
        }
        return nil
    }
}

nonisolated enum DemuxBackpressureDecision: Equatable {
    case read
    case waitForVideo(below: Int)
    case waitForAudio(below: Int)
}

/// Balances two streams read through one interleaved demux cursor. Soft
/// limits drain in batches while both are healthy. If one side is short, the
/// fuller side grows only to a hard limit, then paces one dequeue at a time
/// so the cursor can reach the other side's packets.
nonisolated enum DemuxBackpressurePolicy {
    private static let audioHighWater = 180
    private static let audioLowWater = 144
    private static let audioHardWater = 270
    private static let audioSafetySeconds = 1.25

    // Without a cache the demux queues are the whole cushion, so they grow.
    // **Only audio grows.** A 4K 10-bit decoded frame is 24.9 MB; compressed
    // audio is ~80 KB/s, so doubling it costs ~1.5 MB (~26 MB worst case,
    // 8-channel float LPCM). Audio also has no cushion of its own, while the
    // video renderer coasts on frames it holds.
    private static let uncachedAudioHighWater = 360
    private static let uncachedAudioLowWater = 288
    private static let uncachedAudioHardWater = 540
    /// Audio cover video must leave before parking on its high water.
    /// Larger without a cache: it must outlast a network segment fetch.
    private static let uncachedAudioSafetySeconds = 3.0
    /// Bounds on compressed video parked past the decoded limit while the
    /// loop reads on for audio. Each must hold a whole fragment, since the
    /// audio sits behind the video: 600 units is 25 s at 24 fps or 10 s at
    /// 60 fps; 128 MB is 10 s at 100 Mbps. The read-ahead starts as soon as
    /// the decoded queue is full (waiting for low lead starved a 4K remux);
    /// the audio high water bounds it.
    static let videoIntakeHardLimit = 600
    static let videoIntakeByteBudget = 128 * 1_048_576

    /// The audio depth aimed for, so the HUD can show which profile applies.
    static func audioCushionTarget(deliveryIsCached: Bool) -> Int {
        deliveryIsCached ? audioHighWater : uncachedAudioHighWater
    }

    /// Byte ceiling for the decoded queue, which is also bounded by count.
    /// 42 frames is 250 MB at 1080p 10-bit but 1.05 GB at 4K, in a process
    /// jetsam has killed at 2.1 GB. This is 30 frames of 4K P010, the
    /// hardware path's ceiling, so only 4K software decode is affected.
    static let decodedQueueByteBudget: Int64 = 30 * 24_883_200

    /// Floor however large a frame is: reorder depth plus a cushion.
    private static let decodedQueueFrameFloor = 8

    static func videoHardLimit(
        videoIsDecoded: Bool,
        videoIsSoftwareDecoded: Bool = false,
        decodedFrameBytes: Int64 = 0
    ) -> Int {
        let byCount = videoIsSoftwareDecoded ? 42 : (videoIsDecoded ? 30 : 120)
        guard decodedFrameBytes > 0 else { return byCount }
        let byBytes = Int(decodedQueueByteBudget / decodedFrameBytes)
        return max(min(byCount, byBytes), decodedQueueFrameFloor)
    }

    static func decision(
        videoCount: Int,
        audioCount: Int,
        audioBufferedSeconds: Double,
        videoFrameRate: Double,
        videoIsDecoded: Bool,
        videoIsSoftwareDecoded: Bool = false,
        hasAudio: Bool,
        deliveryIsCached: Bool = true,
        playbackRate: Double = 1,
        decodedFrameBytes: Int64 = 0,
        videoIntakeCount: Int = 0,
        videoIntakeBytes: Int = 0
    ) -> DemuxBackpressureDecision {
        let audioHighWater = deliveryIsCached ? Self.audioHighWater : uncachedAudioHighWater
        let audioLowWater = deliveryIsCached ? Self.audioLowWater : uncachedAudioLowWater
        let audioHardWater = deliveryIsCached ? Self.audioHardWater : uncachedAudioHardWater
        let audioSafetySeconds = deliveryIsCached
            ? Self.audioSafetySeconds
            : uncachedAudioSafetySeconds
        let videoHardWater = videoHardLimit(
            videoIsDecoded: videoIsDecoded,
            videoIsSoftwareDecoded: videoIsSoftwareDecoded,
            decodedFrameBytes: decodedFrameBytes
        )
        let safePlaybackRate = PlaybackRatePolicy.clamped(playbackRate)
        let baseVideoHighWater = videoIsSoftwareDecoded ? 30 : (videoIsDecoded ? 18 : 90)
        let baseVideoLowWater = videoIsSoftwareDecoded ? 24 : (videoIsDecoded ? 12 : 72)
        // Scale both watermarks with rate, then clamp them as a pair.
        // Clamping low water against the already clamped high water shrinks
        // the drain batch to one frame at 2x, parking the decoded queue one
        // frame under the hard limit (~254 MB of 1080p P010).
        let drainBatch = max(baseVideoHighWater - baseVideoLowWater, 1)
        let videoHighWater = min(
            Int(ceil(Double(baseVideoHighWater) * safePlaybackRate)),
            max(videoHardWater - 1, 1)
        )
        let scaledVideoLowWater = min(
            Int(ceil(Double(baseVideoLowWater) * safePlaybackRate)),
            videoHighWater - drainBatch
        )
        let videoLowWater = max(min(scaledVideoLowWater, videoHighWater - 1), 1)
        let safeFrameRate = videoFrameRate.isFinite && videoFrameRate >= 1
            ? videoFrameRate
            : 24

        if videoCount >= videoHighWater {
            let drainSeconds = Double(max(videoCount - videoLowWater, 0)) / safeFrameRate
            let audioCanCoverDrain = !hasAudio
                || audioBufferedSeconds >= audioSafetySeconds * safePlaybackRate + drainSeconds
            // With audio this is rarely true: the engine's audio queue
            // sits near zero, so the loop usually paces at the hard limit.
            if audioCanCoverDrain {
                return .waitForVideo(below: videoLowWater)
            }
            if videoCount >= videoHardWater {
                // Decoded queue full. With audio, read on and park video
                // in the intake to reach the audio behind it; the audio high
                // water and intake bounds stop it. Without audio, pace one
                // slot at a time.
                if hasAudio,
                   audioCount < audioHighWater,
                   videoIntakeCount < videoIntakeHardLimit,
                   videoIntakeBytes < videoIntakeByteBudget {
                    return .read
                }
                return .waitForVideo(below: videoHardWater)
            }
            return .read
        }

        if hasAudio, audioCount >= audioHighWater {
            let baseVideoSafetyCount = videoIsSoftwareDecoded ? 24 : (videoIsDecoded ? 12 : 36)
            let videoSafetyCount = min(
                Int(ceil(Double(baseVideoSafetyCount) * safePlaybackRate)),
                max(videoHardWater - 1, 1)
            )
            if videoCount >= videoSafetyCount {
                return .waitForAudio(below: audioLowWater)
            }
            if audioCount >= audioHardWater {
                return .waitForAudio(below: audioHardWater)
            }
        }

        return .read
    }
}

/// Counts audio timestamp gaps or overlaps over 1 ms: measurable crackle.
/// Written on the demux queue, read on the main actor.
nonisolated private final class AudioContinuityMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var expectedNext: CMTime?
    private var gaps = 0

    var gapCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return gaps
    }

    /// Seek/flush: the next buffer starts a new chain, not a gap.
    func reset() {
        lock.lock()
        expectedNext = nil
        lock.unlock()
    }

    func observe(_ buffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard pts.isValid else { return }
        let duration = CMSampleBufferGetDuration(buffer)
        lock.lock()
        if let expectedNext {
            let delta = CMTimeSubtract(pts, expectedNext).seconds
            if abs(delta) > 0.001 {
                gaps += 1
                os_signpost(
                    .event,
                    log: PlaybackPerformance.log,
                    name: "Audio Timestamp Gap",
                    "deltaMs=%{public}.3f expected=%{public}.6f actual=%{public}.6f durationMs=%{public}.3f count=%{public}d",
                    delta * 1_000,
                    expectedNext.seconds,
                    pts.seconds,
                    duration.seconds * 1_000,
                    gaps
                )
            }
        }
        expectedNext = duration.isValid ? CMTimeAdd(pts, duration) : nil
        lock.unlock()
    }
}

/// Thread-safe FIFO of ready-to-enqueue sample buffers.
nonisolated final class SampleBufferQueue: @unchecked Sendable {
    private let condition = NSCondition()
    // Head-indexed so a dequeue does not shift the array; consumed slots
    // are nilled at once and compacted in batches.
    private var buffers: [CMSampleBuffer?] = []
    private var head = 0
    private var finished = false
    private var waitsInterrupted = false

    var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return buffers.count - head
    }

    var isFinished: Bool {
        condition.lock()
        defer { condition.unlock() }
        return finished
    }

    /// Seconds of queued audio that end after `seconds`; earlier audio is
    /// discarded by the renderer, not a cushion.
    func bufferedDuration(after seconds: Double) -> Double {
        condition.lock()
        defer { condition.unlock() }
        guard head < buffers.count,
              let first = buffers[head],
              let last = buffers.last ?? nil else { return 0 }
        let firstPTS = CMSampleBufferGetPresentationTimeStamp(first)
        let lastPTS = CMSampleBufferGetPresentationTimeStamp(last)
        guard firstPTS.isValid, lastPTS.isValid else { return 0 }
        let duration = CMSampleBufferGetDuration(last)
        let end = duration.isValid && duration.seconds.isFinite
            ? CMTimeAdd(lastPTS, duration).seconds
            : lastPTS.seconds
        return max(end - max(firstPTS.seconds, seconds), 0)
    }

    /// Presentation time the queue covers, from its first and last PTS:
    /// codec-independent, unlike packet counts.
    var bufferedDuration: Double {
        condition.lock()
        defer { condition.unlock() }
        guard head < buffers.count,
              let first = buffers[head],
              let last = buffers.last ?? nil else { return 0 }
        let firstPTS = CMSampleBufferGetPresentationTimeStamp(first)
        let lastPTS = CMSampleBufferGetPresentationTimeStamp(last)
        guard firstPTS.isValid, lastPTS.isValid,
              firstPTS.seconds.isFinite, lastPTS.seconds.isFinite else { return 0 }
        let duration = CMSampleBufferGetDuration(last)
        let end = duration.isValid && duration.seconds.isFinite
            ? CMTimeAdd(lastPTS, duration).seconds
            : lastPTS.seconds
        return max(end - firstPTS.seconds, 0)
    }

    func enqueue(_ buffer: CMSampleBuffer) {
        condition.lock()
        buffers.append(buffer)
        condition.unlock()
    }

    func dequeue() -> CMSampleBuffer? {
        condition.lock()
        defer { condition.unlock() }
        guard head < buffers.count else { return nil }
        let buffer = buffers[head]
        buffers[head] = nil
        head += 1
        if head >= 64, head * 2 >= buffers.count {
            buffers.removeFirst(head)
            head = 0
        }
        condition.signal()
        return buffer
    }

    func markFinished() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    /// Used by the Debug audio hold to discard audio that ended before the
    /// clock; a real recovery never hands the renderer such samples.
    func dropLeading(while shouldDrop: (CMSampleBuffer) -> Bool) {
        condition.lock()
        while head < buffers.count, let buffer = buffers[head], shouldDrop(buffer) {
            buffers[head] = nil
            head += 1
            if head >= 64, head * 2 >= buffers.count {
                buffers.removeFirst(head)
                head = 0
            }
        }
        condition.broadcast()
        condition.unlock()
    }

    func reset() {
        condition.lock()
        buffers.removeAll()
        head = 0
        finished = false
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks the producer until the count drops below target, the queue
    /// finishes, or waits are interrupted.
    ///
    /// `alsoCounting` adds work not yet in the queue (the software decode
    /// stage), re-read on every wake; the stage wakes it via
    /// `signalWaiters()`. `timeout` lets the caller re-check what the queue
    /// cannot see.
    func waitUntilBelow(
        _ targetCount: Int,
        timeout: TimeInterval? = nil,
        alsoCounting: () -> Int = { 0 }
    ) {
        condition.lock()
        let deadline = timeout.map { Date(timeIntervalSinceNow: $0) }
        while buffers.count - head + alsoCounting() >= targetCount, !finished, !waitsInterrupted {
            if let deadline {
                guard condition.wait(until: deadline) else { break }
            } else {
                condition.wait()
            }
        }
        condition.unlock()
    }

    /// Wakes waiters to re-check; the decode stage calls it per packet.
    func signalWaiters() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    func interruptWaits() {
        condition.lock()
        waitsInterrupted = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Coalesces per-packet pump wakeups, so a fast demux pass does not queue
/// hundreds of pump blocks.
nonisolated private final class PumpKickState: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = false
    private var requestedAgain = false

    /// Returns true only for the request that must schedule the worker.
    func request() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if scheduled {
            requestedAgain = true
            return false
        }
        scheduled = true
        return true
    }

    /// Returns true when work arrived during the completed pump cycle.
    func completeCycle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if requestedAgain {
            requestedAgain = false
            return true
        }
        scheduled = false
        return false
    }
}
