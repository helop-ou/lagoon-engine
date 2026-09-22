import Foundation
import Testing
@testable import LagoonEngine

/// The measurement discipline that two false positives paid for:
/// warmup before counting, a fixed media-time window, and no window that
/// survives the transport being touched.
struct FrameLossBenchTests {
    private func sample(
        position: Double,
        frames: Int = 0,
        dropped: Int = 0,
        corrupted: Int = 0,
        stalls: Int = 0,
        audioGaps: Int = 0,
        queue: Int = 90,
        footprintMB: Int = 100,
        availableMB: Int = 500
    ) -> FrameLossBench.Sample {
        FrameLossBench.Sample(
            position: position,
            totalFrames: frames,
            droppedFrames: dropped,
            corruptedFrames: corrupted,
            stalls: stalls,
            audioGaps: audioGaps,
            videoQueueDepth: queue,
            footprintBytes: Int64(footprintMB) * 1_048_576,
            availableBytes: availableMB * 1_048_576
        )
    }

    @Test func warmupSamplesAreDiscarded() {
        var bench = FrameLossBench(at: 300, warmupSeconds: 10, windowSeconds: 60)
        #expect(bench.record(sample(position: 302, dropped: 5)) == nil)
        #expect(bench.record(sample(position: 309.9, dropped: 9)) == nil)
        guard case .warming = bench.phase else {
            Issue.record("still warming at 309.9, got \(bench.phase)")
            return
        }
        // First sample at/after 310 becomes the measurement baseline —
        // the warmup drops (9 so far) never enter the result.
        #expect(bench.record(sample(position: 310.2, frames: 240, dropped: 9)) == nil)
        guard case .measuring = bench.phase else {
            Issue.record("expected measuring, got \(bench.phase)")
            return
        }
    }

    @Test func windowCompletesWithDeltas() throws {
        var bench = FrameLossBench(at: 300, warmupSeconds: 10, windowSeconds: 60)
        _ = bench.record(sample(position: 310, frames: 240, dropped: 9, stalls: 1, audioGaps: 100, queue: 80))
        _ = bench.record(sample(
            position: 340,
            frames: 960,
            dropped: 12,
            stalls: 1,
            audioGaps: 150,
            queue: 40,
            footprintMB: 620,
            availableMB: 300
        ))
        #expect(bench.record(sample(position: 369, frames: 1650, dropped: 15, queue: 85)) == nil)
        let final = bench.record(
            sample(
                position: 370.5,
                frames: 1690,
                dropped: 18,
                corrupted: 1,
                stalls: 2,
                audioGaps: 200,
                queue: 90,
                footprintMB: 590,
                availableMB: 320
            )
        )
        let result = try #require(final)
        #expect(result.startPosition == 310)
        #expect(result.windowSeconds == 60.5)
        #expect(result.frames == 1450)
        #expect(result.dropped == 9)
        #expect(result.corrupted == 1)
        #expect(result.stalls == 1)
        #expect(result.audioGaps == 100)
        #expect(result.minVideoQueue == 40)
        #expect(result.startingFootprintBytes == 100 * 1_048_576)
        #expect(result.peakFootprintBytes == 620 * 1_048_576)
        #expect(result.footprintGrowthMB == 520)
        #expect(result.minimumAvailableMB == 300)
        #expect(abs(result.lossPercent - 9.0 / 1450 * 100) < 0.0001)
    }

    /// The bench's summary is also the value of the
    /// `player.regression.frameLoss` probe, and `FrameLossRegressionResult` in
    /// LagoonUITests parses it with this exact regex. Dropping a field from
    /// the summary stops the VC-1 continuity regression reading a window it
    /// actually finished, which is a timeout that looks like a playback
    /// failure and is not one. That has happened.
    @Test func regressionSummaryIsParseable() {
        let result = FrameLossBench.Result(
            startPosition: 310,
            windowSeconds: 60,
            frames: 1_450,
            dropped: 9,
            corrupted: 1,
            stalls: 2,
            audioGaps: 100,
            minVideoQueue: 40,
            optimizedFrames: 0,
            accumulatedDelay: 0,
            startingFootprintBytes: 100 * 1_048_576,
            peakFootprintBytes: 620 * 1_048_576,
            minimumAvailableBytes: 300 * 1_048_576
        )
        let summary = result.regressionSummary
        let pattern = #"([0-9.]+)% \(([0-9]+)/([0-9]+)\).*corrupt ([0-9]+).*stalls ([0-9]+).*aGaps ([0-9]+)"#
        let expression = try? NSRegularExpression(pattern: pattern)
        let match = expression?.firstMatch(
            in: summary,
            range: NSRange(summary.startIndex..., in: summary)
        )
        #expect(match != nil, "the UI regression can no longer parse: \(summary)")
        #expect(match?.numberOfRanges == 7)
        // The memory figures added later have to survive too.
        #expect(summary.contains("peak"))
        #expect(summary.contains("minQ"))
    }

    @Test func decoded4KMain10SurfaceEstimateMatchesP010Storage() {
        let frame = DecodedFrameMemory.bytesPer420Frame(
            width: 3840,
            height: 2160,
            bitDepth: 10
        )
        #expect(frame == 24_883_200)
        #expect(DecodedFrameMemory.queuedBytes(
            width: 3840,
            height: 2160,
            bitDepth: 10,
            frames: 30
        ) == 746_496_000)
    }

    /// The result is delivered exactly once and then frozen — later
    /// samples must not overwrite a finished window.
    @Test func doneIsSticky() {
        var bench = FrameLossBench(at: 0, warmupSeconds: 1, windowSeconds: 2)
        _ = bench.record(sample(position: 1, frames: 24))
        let result = bench.record(sample(position: 3.1, frames: 98, dropped: 2))
        #expect(result != nil)
        #expect(bench.record(sample(position: 9, frames: 500, dropped: 50)) == nil)
        #expect(bench.phase == .done(result!))
    }

    /// Touching the transport re-arms from the new position: fresh warmup,
    /// fresh baseline, min-queue tracking cleared.
    @Test func rearmDiscardsTheRunningWindow() throws {
        var bench = FrameLossBench(at: 0, warmupSeconds: 1, windowSeconds: 2)
        _ = bench.record(sample(position: 1, frames: 24, queue: 3))
        bench.rearm(at: 600)
        #expect(bench.record(sample(position: 599, frames: 1000)) == nil)
        _ = bench.record(sample(position: 601, frames: 1024, queue: 88))
        let final = bench.record(sample(position: 603.5, frames: 1084, dropped: 1, queue: 90))
        let result = try #require(final)
        #expect(result.startPosition == 601)
        #expect(result.frames == 60)
        #expect(result.minVideoQueue == 88)
    }
}
