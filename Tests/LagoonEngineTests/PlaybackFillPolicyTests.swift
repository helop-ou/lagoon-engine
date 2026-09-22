import Foundation
import Testing
@testable import LagoonEngine

/// Pure scheduler-policy coverage: no cache, no clock, no engine —
/// just the decision table `PlaybackController.startBufferFill` drives.
///
/// Eager pacing is judged from measured throughput against the title's
/// average bitrate, not from whether the cushion grew between chunks: that
/// growth guard is gone because production chunks are 1 MiB, too little
/// media at realistic 4K bitrates to move a fixed per-chunk threshold.
@Suite("Playback fill policy")
struct PlaybackFillPolicyTests {
    // MARK: - beforeFetch

    @Test func completeWholeFileStopsTheLoop() {
        let policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.bufferedFraction = 1
        snapshot.isWindowed = false
        #expect(policy.beforeFetch(snapshot) == .stop)
    }

    @Test func completeButWindowedKeepsFetching() {
        let policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.bufferedFraction = 1
        snapshot.isWindowed = true
        #expect(policy.beforeFetch(snapshot) == .fetch)
    }

    @Test func bufferingRendererGetsTheLinkToItselfForACooldown() {
        let policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.isBuffering = true
        #expect(policy.beforeFetch(snapshot) == .wait(PlaybackFillPolicy.stallCooldownSeconds))
    }

    @Test func aNewStallGetsTheLinkToItselfForACooldown() {
        let policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.newStall = true
        #expect(policy.beforeFetch(snapshot) == .wait(PlaybackFillPolicy.stallCooldownSeconds))
    }

    @Test func ordinarilyBeforeFetchProceeds() {
        let policy = PlaybackFillPolicy()
        #expect(policy.beforeFetch(PlaybackFillPolicy.Snapshot()) == .fetch)
    }

    // MARK: - afterFetch: cancellation & exhaustion

    @Test func cancellationAlwaysStops() {
        var policy = PlaybackFillPolicy()
        #expect(policy.afterFetch(.cancelled, PlaybackFillPolicy.Snapshot()) == .stop)
    }

    @Test func exhaustedWindowedWaitsForThePlayheadToMakeRoom() {
        var policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.isWindowed = true
        #expect(policy.afterFetch(.exhausted, snapshot) == .wait(PlaybackFillPolicy.idlePollSeconds))
    }

    @Test func exhaustedWholeFileStops() {
        var policy = PlaybackFillPolicy()
        #expect(policy.afterFetch(.exhausted, PlaybackFillPolicy.Snapshot()) == .stop)
    }

    @Test func exhaustionResetsTheFailureBackoff() {
        var policy = PlaybackFillPolicy()
        let snapshot = PlaybackFillPolicy.Snapshot()
        _ = policy.afterFetch(.failed, snapshot)
        _ = policy.afterFetch(.failed, snapshot)
        #expect(policy.consecutiveFailures == 2)

        _ = policy.afterFetch(.exhausted, snapshot)
        #expect(policy.consecutiveFailures == 0)
        #expect(policy.afterFetch(.failed, snapshot) == .wait(1))
    }

    // MARK: - afterFetch: failure backoff

    @Test func aFailureBacksOffExponentiallyUpToTheCap() {
        var policy = PlaybackFillPolicy()
        let snapshot = PlaybackFillPolicy.Snapshot()
        let expectedWaits: [Double] = [1, 2, 4, 8, 16, 30, 30]
        for expected in expectedWaits {
            #expect(policy.afterFetch(.failed, snapshot) == .wait(expected))
        }
    }

    @Test func aFetchedOutcomeResetsTheFailureBackoff() {
        var policy = PlaybackFillPolicy()
        let stalledSnapshot = PlaybackFillPolicy.Snapshot()
        _ = policy.afterFetch(.failed, stalledSnapshot)
        _ = policy.afterFetch(.failed, stalledSnapshot)
        #expect(policy.consecutiveFailures == 2)

        var pausedSnapshot = PlaybackFillPolicy.Snapshot()
        pausedSnapshot.isPaused = true
        _ = policy.afterFetch(.fetched(bytes: 1_000, seconds: 0.1), pausedSnapshot)
        #expect(policy.consecutiveFailures == 0)

        // The next failure waits a fresh 1 second rather than continuing the
        // old exponent.
        #expect(policy.afterFetch(.failed, stalledSnapshot) == .wait(1))
    }

    // MARK: - afterFetch: fetched, paused

    @Test func fetchedWhilePausedGoesFullSpeed() {
        var policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.isPaused = true
        #expect(policy.afterFetch(.fetched(bytes: 1_000, seconds: 5), snapshot) == .fetch)
    }

    // MARK: - afterFetch: fetched, playing, below the cushion target (hurried)

    @Test func hurriedPacingYieldsAFractionOfTheLastRequestsOwnTime() {
        var policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.aheadSeconds = 30
        // Throughput headroom clearly holds: 1,000 bytes at 100 bytes/s is
        // 10 s of media, far past the 0.33 s this 0.2 s request requires.
        snapshot.averageBytesPerSecond = 100
        let decision = policy.afterFetch(.fetched(bytes: 1_000, seconds: 0.2), snapshot)
        expectWait(decision, 0.1)
    }

    @Test func hurriedPacingKeepsItsShareOnASlowLink() {
        // A slow link still yields the same fraction, so foreground reads
        // keep a third of it however long a chunk takes.
        var policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.aheadSeconds = 30
        // 1,000 bytes at 100 bytes/s is 10 s of media, past the 6.6 s this
        // 4 s request requires.
        snapshot.averageBytesPerSecond = 100
        let decision = policy.afterFetch(.fetched(bytes: 1_000, seconds: 4), snapshot)
        expectWait(decision, 2)
    }

    @Test func anUnknownCushionKeepsTheGentlePace() {
        // Without a measurable cushion the policy cannot see gain, so it
        // never competes with playback on the strength of a guess.
        var policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.aheadSeconds = nil
        let decision = policy.afterFetch(.fetched(bytes: 1_000, seconds: 0.2), snapshot)
        expectWait(decision, 0.8)
    }

    // MARK: - afterFetch: fetched, playing, at/above the cushion target (relaxed)

    @Test func relaxedPacingMultipliesTheLastRequestsOwnTime() {
        var policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.aheadSeconds = PlaybackFillPolicy.targetAheadSeconds
        let decision = policy.afterFetch(.fetched(bytes: 1_000, seconds: 0.5), snapshot)
        expectWait(decision, 2)
    }

    @Test func relaxedPacingFloorsAtTheMinimumMeasuredRequest() {
        var policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.aheadSeconds = PlaybackFillPolicy.targetAheadSeconds + 1
        let decision = policy.afterFetch(.fetched(bytes: 1_000, seconds: 0.01), snapshot)
        expectWait(decision, 0.5)
    }

    @Test func relaxedPacingCapsItsWait() {
        var policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.aheadSeconds = PlaybackFillPolicy.targetAheadSeconds
        let decision = policy.afterFetch(.fetched(bytes: 1_000, seconds: 10), snapshot)
        expectWait(decision, PlaybackFillPolicy.relaxedPacingCapSeconds)
    }

    // MARK: - afterFetch: fetched, playing, throughput headroom(4K)

    private func relaxedWait(_ seconds: Double) -> Double {
        min(
            max(seconds, PlaybackFillPolicy.minimumMeasuredRequestSeconds) * PlaybackFillPolicy.relaxedPacingMultiplier,
            PlaybackFillPolicy.relaxedPacingCapSeconds
        )
    }

    @Test func aOneMebibyteChunkStaysEagerAtHighBitrateWhenTheLinkHasHeadroom() {
        // A 1 MiB chunk carries well under 0.25 s of even a 120 Mbps title —
        // exactly the case the old fixed cushion-gain guard could never pass,
        // since a single chunk could never grow the cushion by that much.
        for titleMbps in [40.0, 80.0, 120.0] {
            var policy = PlaybackFillPolicy()
            var snapshot = PlaybackFillPolicy.Snapshot()
            snapshot.aheadSeconds = 30
            snapshot.averageBytesPerSecond = mbps(titleMbps)
            snapshot.playbackRate = 1
            let seconds = Double(mebibyte) / mbps(400)
            let decision = policy.afterFetch(.fetched(bytes: mebibyte, seconds: seconds), snapshot)
            expectWait(decision, seconds * PlaybackFillPolicy.hurriedYieldFraction)
        }
    }

    @Test func aLinkNearPlaybackDemandKeepsTheGentlePace() {
        for titleMbps in [40.0, 80.0, 120.0] {
            var policy = PlaybackFillPolicy()
            var snapshot = PlaybackFillPolicy.Snapshot()
            snapshot.aheadSeconds = 30
            snapshot.averageBytesPerSecond = mbps(titleMbps)
            snapshot.playbackRate = 1
            let seconds = Double(mebibyte) / mbps(titleMbps * 1.2)
            let decision = policy.afterFetch(.fetched(bytes: mebibyte, seconds: seconds), snapshot)
            expectWait(decision, relaxedWait(seconds))
        }
    }

    @Test func eagerPacingNeedsRoughlyOneAndTwoThirdsOfTheTitleBitrate() {
        // Threshold link factor is (1 + hurriedYieldFraction) * minimumHeadroomRatio
        // = 1.5 * 1.1 = 1.65x the title bitrate.
        let titleMbps = 80.0
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.aheadSeconds = 30
        snapshot.averageBytesPerSecond = mbps(titleMbps)
        snapshot.playbackRate = 1

        var justUnderPolicy = PlaybackFillPolicy()
        let justUnderSeconds = Double(mebibyte) / mbps(titleMbps * 1.6)
        let justUnderDecision = justUnderPolicy.afterFetch(.fetched(bytes: mebibyte, seconds: justUnderSeconds), snapshot)
        expectWait(justUnderDecision, relaxedWait(justUnderSeconds))

        var justOverPolicy = PlaybackFillPolicy()
        let justOverSeconds = Double(mebibyte) / mbps(titleMbps * 1.7)
        let justOverDecision = justOverPolicy.afterFetch(.fetched(bytes: mebibyte, seconds: justOverSeconds), snapshot)
        expectWait(justOverDecision, justOverSeconds * PlaybackFillPolicy.hurriedYieldFraction)
    }

    @Test func fasterPlaybackRaisesTheBarAndShrinksTheCushion() {
        let titleMbps = 40.0
        let linkSeconds = Double(mebibyte) / mbps(100)

        // At normal speed a 100 Mbps link clears 1.65x the 40 Mbps title.
        var normalRateSnapshot = PlaybackFillPolicy.Snapshot()
        normalRateSnapshot.aheadSeconds = 30
        normalRateSnapshot.averageBytesPerSecond = mbps(titleMbps)
        normalRateSnapshot.playbackRate = 1
        var normalRatePolicy = PlaybackFillPolicy()
        let normalRateDecision = normalRatePolicy.afterFetch(.fetched(bytes: mebibyte, seconds: linkSeconds), normalRateSnapshot)
        expectWait(normalRateDecision, linkSeconds * PlaybackFillPolicy.hurriedYieldFraction)

        // Doubling playback rate doubles the bar: 100 < 2 * 1.65 * 40 = 132.
        var doubleRateSnapshot = normalRateSnapshot
        doubleRateSnapshot.playbackRate = 2
        var doubleRatePolicy = PlaybackFillPolicy()
        let doubleRateDecision = doubleRatePolicy.afterFetch(.fetched(bytes: mebibyte, seconds: linkSeconds), doubleRateSnapshot)
        expectWait(doubleRateDecision, relaxedWait(linkSeconds))

        // Doubling the rate also halves the wall-clock cushion: 200 s of
        // ahead at 2x is only a 100 s cushion, still under the 120 s target,
        // so a link fast enough to clear 2 * 1.65 * 40 = 132 Mbps stays eager.
        var wideCushionSnapshot = PlaybackFillPolicy.Snapshot()
        wideCushionSnapshot.aheadSeconds = 200
        wideCushionSnapshot.averageBytesPerSecond = mbps(titleMbps)
        wideCushionSnapshot.playbackRate = 2
        let fastLinkSeconds = Double(mebibyte) / mbps(400)
        var wideCushionPolicy = PlaybackFillPolicy()
        let wideCushionDecision = wideCushionPolicy.afterFetch(.fetched(bytes: mebibyte, seconds: fastLinkSeconds), wideCushionSnapshot)
        expectWait(wideCushionDecision, fastLinkSeconds * PlaybackFillPolicy.hurriedYieldFraction)

        // 250 s of ahead at 2x is a 125 s cushion: over target, so it is
        // relaxed even on the same fast link.
        var narrowCushionSnapshot = wideCushionSnapshot
        narrowCushionSnapshot.aheadSeconds = 250
        var narrowCushionPolicy = PlaybackFillPolicy()
        let narrowCushionDecision = narrowCushionPolicy.afterFetch(.fetched(bytes: mebibyte, seconds: fastLinkSeconds), narrowCushionSnapshot)
        expectWait(narrowCushionDecision, relaxedWait(fastLinkSeconds))
    }

    @Test func anUnknownBitrateKeepsTheGentlePace() {
        var policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.aheadSeconds = 30
        snapshot.averageBytesPerSecond = nil
        let decision = policy.afterFetch(.fetched(bytes: 1_000, seconds: 0.2), snapshot)
        expectWait(decision, relaxedWait(0.2))
    }

    @Test func anEmptyOrUnmeasurableFetchKeepsTheGentlePace() {
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.aheadSeconds = 30
        snapshot.averageBytesPerSecond = mbps(80)
        snapshot.playbackRate = 1

        var zeroBytesPolicy = PlaybackFillPolicy()
        let zeroBytesDecision = zeroBytesPolicy.afterFetch(.fetched(bytes: 0, seconds: 0.2), snapshot)
        expectWait(zeroBytesDecision, relaxedWait(0.2))

        var infiniteSecondsPolicy = PlaybackFillPolicy()
        let infiniteSecondsDecision = infiniteSecondsPolicy.afterFetch(.fetched(bytes: 1_000, seconds: .infinity), snapshot)
        expectWait(infiniteSecondsDecision, 0.5)

        var negativeSecondsPolicy = PlaybackFillPolicy()
        let negativeSecondsDecision = negativeSecondsPolicy.afterFetch(.fetched(bytes: 1_000, seconds: -1), snapshot)
        expectWait(negativeSecondsDecision, 0.5)
    }

    @Test func throughputIsJudgedPerRequestWithNoHistory() {
        var policy = PlaybackFillPolicy()
        var snapshot = PlaybackFillPolicy.Snapshot()
        snapshot.aheadSeconds = 30
        snapshot.averageBytesPerSecond = mbps(80)
        snapshot.playbackRate = 1

        // Fast link: eager.
        let fastSeconds = Double(mebibyte) / mbps(400)
        expectWait(
            policy.afterFetch(.fetched(bytes: mebibyte, seconds: fastSeconds), snapshot),
            fastSeconds * PlaybackFillPolicy.hurriedYieldFraction
        )

        // Slow link, same policy value: relaxed, with no memory of the
        // previous eager decision.
        let slowSeconds = Double(mebibyte) / mbps(90)
        expectWait(
            policy.afterFetch(.fetched(bytes: mebibyte, seconds: slowSeconds), snapshot),
            relaxedWait(slowSeconds)
        )

        // Fast link again: eager again immediately, unaffected by the
        // intervening relaxed chunk.
        expectWait(
            policy.afterFetch(.fetched(bytes: mebibyte, seconds: fastSeconds), snapshot),
            fastSeconds * PlaybackFillPolicy.hurriedYieldFraction
        )
    }

    @Test func averageBytesPerSecondNeedsAKnownLengthAndDuration() {
        let bytesPerSecond = PlaybackFillPolicy.averageBytesPerSecond(
            contentLength: Int64(600 * mebibyte), durationSeconds: 6_000
        )
        #expect(bytesPerSecond != nil)
        #expect(abs((bytesPerSecond ?? 0) - 104_857.6) < 1e-6)

        #expect(PlaybackFillPolicy.averageBytesPerSecond(contentLength: nil, durationSeconds: 6_000) == nil)
        #expect(PlaybackFillPolicy.averageBytesPerSecond(contentLength: 0, durationSeconds: 6_000) == nil)
        #expect(PlaybackFillPolicy.averageBytesPerSecond(contentLength: Int64(600 * mebibyte), durationSeconds: 0) == nil)
        #expect(PlaybackFillPolicy.averageBytesPerSecond(contentLength: Int64(600 * mebibyte), durationSeconds: .infinity) == nil)
    }

    // MARK: - aheadSeconds(cachedBytesAhead:contentLength:durationSeconds:)

    @Test func aheadSecondsProjectsCachedBytesThroughTheAverageBitrate() {
        let mebibyte: Int64 = 1_024 * 1_024
        let ahead = PlaybackFillPolicy.aheadSeconds(
            cachedBytesAhead: 60 * mebibyte,
            contentLength: 600 * mebibyte,
            durationSeconds: 6_000
        )
        #expect(ahead != nil)
        #expect(abs((ahead ?? 0) - 600) < 1e-9)
    }

    @Test func aheadSecondsIsNilWithoutAKnownContentLengthOrDuration() {
        #expect(PlaybackFillPolicy.aheadSeconds(
            cachedBytesAhead: 100, contentLength: nil, durationSeconds: 100
        ) == nil)
        #expect(PlaybackFillPolicy.aheadSeconds(
            cachedBytesAhead: 100, contentLength: 100, durationSeconds: 0
        ) == nil)
    }

    // MARK: - Helpers

    private let mebibyte = 1_024 * 1_024

    /// Megabits per second, converted to bytes per second.
    private func mbps(_ x: Double) -> Double {
        x * 1_000_000 / 8
    }

    private func waitSeconds(_ decision: PlaybackFillPolicy.Decision) -> Double? {
        if case .wait(let seconds) = decision { return seconds }
        return nil
    }

    private func expectWait(_ decision: PlaybackFillPolicy.Decision, _ expected: Double, tolerance: Double = 1e-9) {
        guard let seconds = waitSeconds(decision) else {
            Issue.record("Expected .wait(\(expected)), got \(decision)")
            return
        }
        #expect(abs(seconds - expected) < tolerance)
    }
}
