import Foundation
import Testing
@testable import LagoonEngine

/// The rate envelope and the engine state it governs. A host reads these for
/// its controls, Now Playing and sync correction.
@Suite("Playback rate", .serialized)
struct PlaybackRatePolicyTests {
    @Test func playbackRateStepsAndRendersFromOnePlace() {
        #expect(PlaybackRatePolicy.title(1) == "1×")
        #expect(PlaybackRatePolicy.title(1.25) == "1.25×")
        #expect(PlaybackRatePolicy.title(0.5) == "0.5×")
        // A host can send a rate outside the set; it renders clamped.
        #expect(PlaybackRatePolicy.title(99) == "2×")

        // Stepping clamps, never wraps.
        #expect(PlaybackRatePolicy.stepped(from: 1, by: 1) == 1.25)
        #expect(PlaybackRatePolicy.stepped(from: 1, by: -1) == 0.75)
        #expect(PlaybackRatePolicy.stepped(from: 2, by: 1) == 2)
        #expect(PlaybackRatePolicy.stepped(from: 0.5, by: -1) == 0.5)
        // A value the engine accepts but the set does not contain still steps.
        #expect(PlaybackRatePolicy.stepped(from: 1.1, by: 1) == 1.25)
        #expect(PlaybackRatePolicy.stepped(from: 1.1, by: -1) == 1)

        #expect(PlaybackRatePolicy.identifier(1) == "1")
        #expect(PlaybackRatePolicy.identifier(1.25) == "1_25")
        #expect(PlaybackRatePolicy.identifier(0.75) == "0_75")
    }

    @Test func aSyncCorrectionRidesOnTheViewersRateWithoutLeavingTheEnvelope() {
        // A group nudge multiplies the viewer's rate; no correction leaves it alone.
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 1, correction: 1) == 1)
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 1.5, correction: 1) == 1.5)
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 1, correction: 1.05) == 1.05)
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 2, correction: 0.5) == 1)

        // The product stays inside the engine's rate envelope.
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 2, correction: 4) == PlaybackRatePolicy.maximum)
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 0.5, correction: 0.1) == PlaybackRatePolicy.minimum)
        // The viewer's rate is clamped before the correction applies.
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 99, correction: 0.5) == 1)

        // A nonsense multiplier is ignored; stopping is `pause`, never a zero correction.
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 1.25, correction: 0) == 1.25)
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 1.25, correction: -1) == 1.25)
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 1.25, correction: .nan) == 1.25)
    }

    @Test func systemCommandsUseIdempotentPlaybackState() {
        let engine = SampleBufferPlayerEngine()
        defer { engine.shutdown() }
        engine.pause()
        engine.pause()
        #expect(engine.isPaused)
        engine.play()
        engine.play()
        #expect(!engine.isPaused)
    }

    @Test func playbackRateSurvivesPauseAndIsBounded() {
        let engine = SampleBufferPlayerEngine()
        defer { engine.shutdown() }
        engine.setRate(1.5)
        #expect(engine.rate == 1.5)
        engine.pause()
        engine.play()
        #expect(engine.rate == 1.5)
        engine.setRate(99)
        #expect(engine.rate == PlaybackRatePolicy.maximum)
        engine.setRate(.nan)
        #expect(engine.rate == 1)
    }

    @Test func aCorrectionRateLeavesTheViewersChosenRateAlone() {
        // The speed row and Now Playing show `rate`, so a nudge must not move it.
        let engine = SampleBufferPlayerEngine()
        defer { engine.shutdown() }
        engine.setRate(1.25)
        engine.setCorrectionRate(1.05)
        #expect(engine.rate == 1.25)
        #expect(engine.correctionRate == 1.05)
        engine.setCorrectionRate(1)
        #expect(engine.rate == 1.25)
        #expect(engine.correctionRate == 1)
    }
}
