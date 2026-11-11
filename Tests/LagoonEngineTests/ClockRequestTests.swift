import AVFoundation
import Foundation
import Testing
@testable import LagoonEngine

@Suite("Clock requests")
struct ClockRequestTests {
    /// Stopping the clock held the main thread for 39–55 ms on the Apple TV,
    /// so a pause queues the stop. A play behind it must still land after it,
    /// or the late stop would leave the clock stopped.
    @MainActor
    @Test func aPauseDoesNotWaitForTheClockAndAPlayLandsAfterIt() async throws {
        let url = try #require(Bundle.module.url(forResource: "two-subrip", withExtension: "mkv", subdirectory: "TextSubtitles"))
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        engine.prepare(url: url, startSeconds: 0, initialAudioOrdinal: nil)
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        engine.play()
        try await Self.wait { !engine.audioTracks.isEmpty && !engine.isBuffering }

        engine.clockQueue.async { Thread.sleep(forTimeInterval: 0.5) }
        let clock = ContinuousClock()
        let start = clock.now
        engine.pause()
        #expect(clock.now - start < .milliseconds(250))
        engine.play()

        // Past the blocked stop: a stop that overtook the play has landed.
        try await Task.sleep(for: .milliseconds(700))
        let settled = engine.clockPosition
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.clockPosition > settled + 0.15, "the clock runs after the play")
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
