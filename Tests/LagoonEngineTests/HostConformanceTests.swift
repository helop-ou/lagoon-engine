import CoreMedia
import Foundation
import Observation
import Testing
@testable import LagoonEngine

/// A host's own engine, written against 1.3.2, must still conform: every
/// requirement added since then has a default. Adding one without a default
/// stops this file compiling.
struct HostConformanceTests {
    @MainActor
    @Test func aConformerFromBeforeTheseRequirementsGetsTheirDefaults() {
        let engine: any PlayerEngine = EarlierPlayerEngine()
        #expect(engine.subtitleOffset == 0)
        engine.setSubtitleOffset(2)
        #expect(engine.subtitleOffset == 0)
        #expect(engine.audioShaping == .off)
        #expect(engine.startupPhase == .started)

        let diagnostics: any PlayerEngineDiagnostics = EarlierDiagnostics()
        #expect(diagnostics.demuxReadAheadSeconds == 0)
        #expect(diagnostics.demuxReadAheadLimit == nil)
    }

    /// Closed captions are told from the other tracks by this id.
    @Test func closedCaptionsKeepTheirPublishedID() {
        #expect(PlayerTrack.closedCaptionsEngineID == 1_000_000)
    }
}

/// Only what `PlayerEngine` required without a default in 1.3.2.
@MainActor
@Observable
private final class EarlierPlayerEngine: PlayerEngine {
    var timePosition: Double = 0
    var duration: Double = 0
    var isPaused = true
    var isBuffering = false
    var rate: Double = 1
    var stallCount = 0
    var videoSize: CGSize?
    var audioTracks: [PlayerTrack] = []
    var subtitleTracks: [PlayerTrack] = []
    var currentSubtitleText: String?
    var currentSubtitleImages: [SubtitleImage] = []
    var audioDelay: Double = 0
    var displayMatchRequest: DisplayMatchRequest?

    func play() {}
    func pause() {}
    func togglePause() {}
    func setRate(_ rate: Double) {}
    func seek(by seconds: Double) {}
    func seek(to seconds: Double) {}
    func selectAudioTrack(id: Int?) {}
    func selectSubtitleTrack(id: Int?) {}
    func addExternalSubtitle(_ track: ExternalSubtitleTrack) {}
    func setAudioDelay(_ seconds: Double) {}
}

/// Everything `PlayerEngineDiagnostics` required in 1.3.2.
@MainActor
private final class EarlierDiagnostics: PlayerEngineDiagnostics {
    var audioBufferedSeconds: Double = 0
    var audioCushionTarget = 0
    var audioDiagnostic: String?
    var audioPacketDropInfo: String?
    var audioTimingGapCount = 0
    var benchStatus: String?
    var dolbyVisionRewriteInfo: String?
    var softwareDecodeDiagnostic: String?
    nonisolated var softwareDecodeBenchField: String? { nil }
    var videoTimingDiagnostic: String?
    var videoStartPointDropDiagnostic = 0
    var refusedSampleMsDiagnostic: Int?
    var videoPerformance: VideoPerformanceSnapshot?
    func refreshVideoPerformanceMetrics() {}
    var decodedVideoQueueCeiling = 0
    var playbackCacheMetrics: PlaybackCacheMetrics?
    var queueDepths: (video: Int, audio: Int) { (0, 0) }
    var subtitleCueCountDiagnostic = 0
    var rendererObserverCountDiagnostic = 0
    func drainMainTickDiagnostic() -> String { "" }
    nonisolated func measurePumpQueueLatency(_ completion: @escaping @Sendable (Duration) -> Void) {}
}
