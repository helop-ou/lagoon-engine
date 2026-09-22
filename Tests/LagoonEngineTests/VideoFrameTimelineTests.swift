import CoreMedia
import Testing
@testable import LagoonEngine

/// Every quantized container PTS lands exactly on the frame grid, including
/// through B-frame reordering.
struct VideoFrameTimelineTests {
    private let period = 1001.0 / 24_000

    /// 23.976 fps stamped at Matroska's 1 ms: every snapped stamp is an
    /// exact whole-frame step from the anchor, duration exactly 1001/24000.
    @Test func quantizedStampsLandOnExactGrid() throws {
        var timeline = try #require(VideoFrameTimeline(frameRateNum: 24_000, frameRateDen: 1001))
        var anchor: Int64?
        for index in 0..<500 {
            let trueSeconds = Double(index) * period
            let containerSeconds = (trueSeconds * 1000).rounded() / 1000
            let produced = timeline.snapped(containerSeconds: containerSeconds)
            let snapped = try #require(produced)
            #expect(snapped.timescale == 24_000)
            let base = anchor ?? snapped.value
            anchor = base
            #expect(snapped.value == base + Int64(index) * 1001)
            #expect(timeline.frameDuration == CMTime(value: 1001, timescale: 24_000))
        }
    }

    /// Decode order steps back and forth by whole frames (I P B B, pts 0, 3, 1,
    /// 2), so the chain follows signed steps.
    @Test func bFrameReorderingFollowsSignedSteps() throws {
        var timeline = try #require(VideoFrameTimeline(frameRateNum: 24_000, frameRateDen: 1001))
        let presentationOrder: [Int64] = [0, 3, 1, 2, 6, 4, 5, 9, 7, 8]
        for frame in presentationOrder {
            let containerSeconds = ((Double(frame) * period) * 1000).rounded() / 1000
            let produced = timeline.snapped(containerSeconds: containerSeconds)
            let snapped = try #require(produced)
            #expect(snapped.value == frame * 1001)
        }
    }

    /// A stamp far off the grid (VFR, broken mux) passes through as nil and
    /// re-anchors the chain there.
    @Test func offGridStampPassesThroughAndReanchors() throws {
        var timeline = try #require(VideoFrameTimeline(frameRateNum: 24_000, frameRateDen: 1001))
        _ = timeline.snapped(containerSeconds: 0)
        #expect(timeline.snapped(containerSeconds: period + 0.020) == nil)
        // The chain continues from the off-grid position.
        let next = timeline.snapped(containerSeconds: period + 0.020 + period)
        let expected = ((period + 0.020) * 24_000).rounded() + 1001
        #expect(next?.value == Int64(expected))
    }

    /// A duplicate stamp can't silently collapse onto the previous frame.
    @Test func duplicateStampPassesThrough() throws {
        var timeline = try #require(VideoFrameTimeline(frameRateNum: 24_000, frameRateDen: 1001))
        _ = timeline.snapped(containerSeconds: 5.0)
        #expect(timeline.snapped(containerSeconds: 5.0) == nil)
    }

    /// Chaining is relative, so a slightly-off rate (23.976 vs 24000/1001)
    /// never drifts past the tolerance as a fixed anchor would.
    @Test func relativeChainingAbsorbsRateRoundingDrift() throws {
        var timeline = try #require(VideoFrameTimeline(frameRateNum: 23_976, frameRateDen: 1000))
        for index in 0..<5000 {
            let trueSeconds = Double(index) * period // true 24000/1001 cadence
            let containerSeconds = (trueSeconds * 1000).rounded() / 1000
            #expect(timeline.snapped(containerSeconds: containerSeconds) != nil, "frame \(index) fell off the grid")
        }
    }

    /// Exact-millisecond rates (25 fps) match the container's stamps: a no-op.
    @Test func exactRateIsNoOp() throws {
        var timeline = try #require(VideoFrameTimeline(frameRateNum: 25, frameRateDen: 1))
        for index in 0..<100 {
            let containerSeconds = Double(index) * 0.040
            let produced = timeline.snapped(containerSeconds: containerSeconds)
            let snapped = try #require(produced)
            #expect(abs(snapped.seconds - containerSeconds) < 1e-9)
        }
    }

    /// reset() forgets the chain; the next stamp anchors fresh (the seek/flush
    /// contract).
    @Test func resetReanchors() throws {
        var timeline = try #require(VideoFrameTimeline(frameRateNum: 24_000, frameRateDen: 1001))
        _ = timeline.snapped(containerSeconds: 100)
        timeline.reset()
        let anchored = timeline.snapped(containerSeconds: 42)
        #expect(anchored?.value == Int64((42.0 * 24_000).rounded()))
    }

    /// Degenerate rates can't form a grid at all.
    @Test func degenerateRatesAreRejected() {
        #expect(VideoFrameTimeline(frameRateNum: 0, frameRateDen: 1) == nil)
        #expect(VideoFrameTimeline(frameRateNum: 24, frameRateDen: 0) == nil)
        #expect(VideoFrameTimeline(frameRateNum: 1, frameRateDen: 10) == nil)
    }
}
