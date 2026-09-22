import Foundation

/// What an engine will tell a host about its own internals.
///
/// Separate from `PlayerEngine` on purpose. That protocol is what a player
/// needs to show a picture and drive a transport, and a host that only wants
/// to play something should not have to think about queue depths or renderer
/// observer counts. This is the second, optional surface: everything a host
/// samples when it is building a HUD, a decode trace or an incident report.
///
/// It exists because the alternative was worse. A host that wanted these
/// numbers had to name the concrete engine, which meant exporting a class
/// with around 140 stored properties and every type they reach, and it meant
/// a second engine implementation could never supply a HUD.
///
/// Every member is a read, or a cheap refresh of a read. Nothing here changes
/// what is played.
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
    /// The same thing, condensed for a bench line. Readable off the main
    /// actor because the bench line is assembled on a sampling queue.
    nonisolated var softwareDecodeBenchField: String? { get }
    /// Presentation timing in one line.
    var videoTimingDiagnostic: String? { get }
    /// Samples a just-flushed renderer refused because the container did not
    /// call them a random-access point.
    var videoStartPointDropDiagnostic: Int { get }
    /// How far past the seek the last refused sample sat, in milliseconds.
    /// Together these two say whether a stall faked a delivery verdict.
    var refusedSampleMsDiagnostic: Int? { get }
    /// Frames shown, dropped and composited, as of the last refresh.
    var videoPerformance: VideoPerformanceSnapshot? { get }
    /// Re-reads the renderer's own counters. They are not free, so a host
    /// asks for them rather than having them maintained continuously.
    func refreshVideoPerformanceMetrics()

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
    /// queue, which is why it takes a completion rather than returning.
    nonisolated func measurePumpQueueLatency(_ completion: @escaping @Sendable (Duration) -> Void)
}
