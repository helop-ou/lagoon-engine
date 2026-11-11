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

    /// The viewer's rate and SyncPlay's correction both reach the clock
    /// through the queue, and multiply.
    @MainActor
    @Test func rateChangesReachTheClock() async throws {
        let engine = try await Self.playingFixture()
        engine.setRate(1.5)
        #expect(try await Self.clockSpeed(of: engine) > 1.3)
        engine.setCorrectionRate(0.5)
        let corrected = try await Self.clockSpeed(of: engine)
        #expect(corrected > 0.6 && corrected < 0.9, "1.5 × 0.5 = 0.75, measured \(corrected)")
        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }

    /// A group start puts the paused position at its host time, so the clock
    /// is half a second behind the time since asking for a start 0.5 s away.
    @MainActor
    @Test func aGroupStartIsAnchoredToItsHostTime() async throws {
        let engine = try await Self.playingFixture()
        engine.pause()
        engine.clockQueue.sync {}
        let paused = engine.clockPosition
        let asked = ContinuousClock.now
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        engine.play(atHostTime: CMTimeAdd(now, CMTime(seconds: 0.5, preferredTimescale: 1_000_000_000)))
        try await Task.sleep(until: asked + .milliseconds(900))
        let advanced = engine.clockPosition - paused
        let elapsed = (ContinuousClock.now - asked) / .seconds(1)
        #expect(abs(advanced - (elapsed - 0.5)) < 0.1, "advanced \(advanced) after \(elapsed) s")
        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }

    @MainActor
    private static func playingFixture() async throws -> SampleBufferPlayerEngine {
        let url = try #require(Bundle.module.url(forResource: "normal", withExtension: "mp4", subdirectory: "PresentationOrder"))
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        engine.prepare(url: url, startSeconds: 0, initialAudioOrdinal: nil)
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        engine.play()
        try await wait { !engine.isBuffering && engine.clockPosition > 0 }
        return engine
    }

    /// Media seconds per wall-clock second over half a second.
    @MainActor
    private static func clockSpeed(of engine: SampleBufferPlayerEngine) async throws -> Double {
        engine.clockQueue.sync {}
        let clock = ContinuousClock()
        let start = clock.now
        let from = engine.clockPosition
        try await Task.sleep(for: .milliseconds(500))
        return (engine.clockPosition - from) / ((clock.now - start) / .seconds(1))
    }

    private static func wait(until condition: () -> Bool) async throws {
        // Generous: other suites' main-actor tests run while this one waits.
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
