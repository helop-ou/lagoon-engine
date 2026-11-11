import AVFoundation
import Foundation
import Testing
@testable import LagoonEngine

@Suite("Seek requests")
struct SeekRequestTests {
    /// The audio renderer's flush blocked the main thread for ~40 ms on the
    /// Apple TV, so a seek queues the flush on the pump instead of waiting.
    @MainActor
    @Test func aSeekDoesNotWaitForThePumpQueue() async throws {
        let url = try #require(Bundle.module.url(forResource: "two-subrip", withExtension: "mkv", subdirectory: "TextSubtitles"))
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        engine.prepare(url: url, startSeconds: 0, initialAudioOrdinal: nil)
        engine.pause()
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        try await Self.wait { !engine.audioTracks.isEmpty && !engine.isBuffering }

        engine.pumpQueue.async { Thread.sleep(forTimeInterval: 0.5) }
        let clock = ContinuousClock()
        let start = clock.now
        engine.seek(to: 1.5)
        #expect(clock.now - start < .milliseconds(250))

        try await Self.wait { !engine.isBuffering }
        #expect(!engine.isBuffering)
        #expect(abs(engine.timePosition - 1.5) < 0.1)
        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }

    /// Left at the old position by a seek back, the stopped clock made every
    /// new picture late, and the renderer showed them at about twice speed
    /// behind the loading indicator until they caught up with it.
    @MainActor
    @Test func aSeekBackMovesTheStoppedClockToTheTarget() async throws {
        let url = try #require(Bundle.module.url(forResource: "normal", withExtension: "mp4", subdirectory: "PresentationOrder"))
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        engine.prepare(url: url, startSeconds: 0, initialAudioOrdinal: nil)
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        engine.play()
        try await Self.wait { !engine.isBuffering && engine.clockPosition >= 1.5 }
        #expect(engine.clockPosition >= 1.5)

        engine.seek(to: 0.3)
        engine.clockQueue.sync {}
        #expect(abs(engine.synchronizerTimeForTesting - 0.3) < 0.05, "\(engine.synchronizerTimeForTesting)")
        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }

    private static func wait(until condition: () -> Bool) async throws {
        // Generous: other suites' main-actor tests run while this one waits.
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
