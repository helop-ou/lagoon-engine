import Foundation

/// What an engine tells a host about its internals, for a HUD, a decode trace
/// or an incident report.
///
/// Separate from `PlayerEngine`, which is all a host needs to play something.
/// Without this a host would have to name the concrete engine, and a second
/// engine could never supply a HUD. Every member is a read; nothing here
/// changes playback.
@MainActor
public protocol PlayerEngineDiagnostics: AnyObject {
    // MARK: Audio delivery

    /// How much audio the renderer is holding, in seconds.
    var audioBufferedSeconds: Double { get }
    /// How much it is trying to hold, in packets.
    var audioCushionTarget: Int { get }
    /// The audio path in one line, or nil before one is chosen.
    var audioDiagnostic: String? { get }
    /// Packets the audio path discarded, and why, or nil if none were.
    var audioPacketDropInfo: String? { get }
    /// Gaps observed between presentation timestamps.
    var audioTimingGapCount: Int { get }

    // MARK: Video

    /// The frame-loss window's result once it has completed, else nil.
    var benchStatus: String? { get }
    /// Whether a Dolby Vision profile 7 stream is being rewritten, and how.
    var dolbyVisionRewriteInfo: String? { get }
    /// The software decoder's state, or nil when video decodes in hardware.
    var softwareDecodeDiagnostic: String? { get }
    /// The same, condensed for a bench line. Nonisolated because the bench line
    /// is built on a sampling queue.
    nonisolated var softwareDecodeBenchField: String? { get }
    /// Presentation timing in one line.
    var videoTimingDiagnostic: String? { get }
    /// Samples a just-flushed renderer refused because the container did not
    /// call them a random-access point.
    var videoStartPointDropDiagnostic: Int { get }
    /// How far past the seek the last refused sample sat, in milliseconds. With
    /// the count above, says whether a stall faked a delivery verdict.
    var refusedSampleMsDiagnostic: Int? { get }
    /// Frames shown, dropped and composited, as of the last refresh.
    var videoPerformance: VideoPerformanceSnapshot? { get }
    /// Re-reads the renderer's counters. Not free, so a host asks when it needs
    /// them.
    func refreshVideoPerformanceMetrics()

    /// The most decoded frames the engine will ever hold. Use this for a
    /// worst-case memory line; `videoQueueHardLimitDiagnostic` moves with
    /// delivery.
    var decodedVideoQueueCeiling: Int { get }

    // MARK: Byte cache

    /// The active cache scope's full counters, or nil.
    /// `PlayerEngine.bufferState` is the viewer-facing summary.
    var playbackCacheMetrics: PlaybackCacheMetrics? { get }

    // MARK: Queues and scheduling

    /// What the two queues are holding right now.
    var queueDepths: (video: Int, audio: Int) { get }
    /// How many subtitle cues are live.
    var subtitleCueCountDiagnostic: Int { get }
    /// How many observers the renderers have attached.
    var rendererObserverCountDiagnostic: Int { get }
    /// Takes the accumulated main-actor tick summary and clears it.
    func drainMainTickDiagnostic() -> String
    /// Times a round trip through the pump queue. Answers on an arbitrary
    /// queue.
    nonisolated func measurePumpQueueLatency(_ completion: @escaping @Sendable (Duration) -> Void)
}
