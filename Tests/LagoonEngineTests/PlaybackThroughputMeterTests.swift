import Foundation
import Testing
@testable import LagoonEngine

/// HEL-262: stall reports could not tell a slow link from an engine problem.
/// The meter reports what the link carries while it is busy.
@Suite("Playback throughput meter")
struct PlaybackThroughputMeterTests {
    private static let megabyte: Int64 = 1_000_000

    @Test func nothingIsReportedBeforeATransferCompletes() {
        var meter = PlaybackThroughputMeter()
        #expect(meter.bytesPerSecond == nil)
        meter.requestStarted(at: 0)
        #expect(meter.bytesPerSecond == nil)
        meter.requestAbandoned(at: 3)
        #expect(meter.bytesPerSecond == nil)
    }

    @Test func idleTimeBetweenRequestsDoesNotCount() {
        // A paced fill: one megabyte a second, then a long wait.
        var meter = PlaybackThroughputMeter()
        for start in stride(from: 0.0, to: 60, by: 10) {
            meter.requestStarted(at: start)
            meter.requestFinished(at: start + 1, bytes: Self.megabyte)
        }
        #expect(abs((meter.bytesPerSecond ?? 0) - 1_000_000) < 1)
    }

    @Test func overlappingRequestsShareOneBusyPeriod() {
        // A foreground read and a prefetch side by side on a 2 MB/s link:
        // two megabytes each over two seconds together.
        var meter = PlaybackThroughputMeter()
        meter.requestStarted(at: 0)
        meter.requestStarted(at: 0)
        meter.requestFinished(at: 1.5, bytes: 2 * Self.megabyte)
        meter.requestFinished(at: 2, bytes: 2 * Self.megabyte)
        // The decay between the two samples costs about a percent.
        let rate = meter.bytesPerSecond ?? 0
        #expect(abs(rate - 2_000_000) < 40_000)
    }

    @Test func aLinkThatSlowsDownIsReportedWithinTheWindow() {
        var meter = PlaybackThroughputMeter()
        var now = 0.0
        // A minute at 5 MB/s, then twenty busy seconds at 1 MB/s.
        for _ in 0..<60 {
            meter.requestStarted(at: now)
            now += 1
            meter.requestFinished(at: now, bytes: 5 * Self.megabyte)
        }
        for _ in 0..<20 {
            meter.requestStarted(at: now)
            now += 1
            meter.requestFinished(at: now, bytes: Self.megabyte)
        }
        // The old rate keeps e^-2 of its weight: about 1.5 MB/s.
        let rate = meter.bytesPerSecond ?? 0
        #expect(rate < 1_700_000)
        #expect(rate > 1_000_000)
    }

    @Test func anAbandonedTransferLeavesItsTimeToOneStillReceiving() {
        // A seek cancels the prefetch while a foreground read carries on.
        var meter = PlaybackThroughputMeter()
        meter.requestStarted(at: 0)
        meter.requestStarted(at: 0)
        meter.requestAbandoned(at: 1)
        meter.requestFinished(at: 2, bytes: 2 * Self.megabyte)
        #expect(meter.bytesPerSecond == 1_000_000)
    }

    @Test func unmatchedEndsAreIgnored() {
        var meter = PlaybackThroughputMeter()
        meter.requestFinished(at: 1, bytes: Self.megabyte)
        meter.requestAbandoned(at: 1)
        #expect(meter.bytesPerSecond == nil)
        meter.requestStarted(at: 2)
        meter.requestFinished(at: 4, bytes: Self.megabyte)
        #expect(meter.bytesPerSecond == 500_000)
    }
}
