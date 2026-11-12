import AVFoundation
import Foundation
import Testing
@testable import LagoonEngine

/// Over AirPlay the clock starts without a host time and lets the
/// synchronizer wait for the receiver. Playback must still start and keep
/// time.
@Suite("AirPlay start", .serialized)
@MainActor
struct AirPlayStartTests {
    @Test func aStartOnAnAirPlayRouteStillPlays() async throws {
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        engine.audioOutputsForTesting = [.airPlay]
        defer { engine.shutdown() }
        var started = false
        var failure: String?
        engine.onPlaybackStarted = { started = true }
        engine.onError = { failure = $0.message }
        let url = try #require(Bundle.module.url(forResource: "no-cues", withExtension: "mkv", subdirectory: "UnindexedSeek"))
        engine.prepare(url: url, startSeconds: 0, initialAudioOrdinal: nil)
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        engine.play()
        let deadline = ContinuousClock.now + .seconds(30)
        while !started, failure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(failure == nil && started)
        let startedAt = engine.synchronizerTimeForTesting
        try await Task.sleep(for: .milliseconds(600))
        #expect(engine.synchronizerTimeForTesting > startedAt + 0.3)
    }
}
