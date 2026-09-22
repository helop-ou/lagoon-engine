import Foundation
import Testing
@testable import LagoonEngine

/// Pins `MainTickStatistics`' millisecond arithmetic and drain/reset contract.
struct MainTickDiagnosticsTests {
    @Test func emptyDrainDoesNotDivideByZero() {
        var stats = MainTickStatistics()
        #expect(stats.drain() == "tick=0 tickAvgMs=0.0 tickMaxMs=0.0 tickGapMaxMs=0")
    }

    @Test func averageAndMaxOverThreeRecordedDurations() {
        var stats = MainTickStatistics()
        stats.record(duration: .milliseconds(2), interval: .milliseconds(100))
        stats.record(duration: .milliseconds(6), interval: .milliseconds(100))
        stats.record(duration: .milliseconds(4), interval: .milliseconds(150))
        // avg = (2 + 6 + 4) / 3 = 4.0 ms, max duration = 6.0 ms, max gap = 150 ms.
        #expect(stats.drain() == "tick=3 tickAvgMs=4.0 tickMaxMs=6.0 tickGapMaxMs=150")
    }

    @Test func maxIntervalIgnoresNil() {
        var stats = MainTickStatistics()
        stats.record(duration: .milliseconds(1), interval: .milliseconds(500))
        stats.record(duration: .milliseconds(1), interval: nil)
        #expect(stats.drain() == "tick=2 tickAvgMs=1.0 tickMaxMs=1.0 tickGapMaxMs=500")
    }

    @Test func drainResetsToEmpty() {
        var stats = MainTickStatistics()
        stats.record(duration: .milliseconds(9), interval: .milliseconds(200))
        _ = stats.drain()
        #expect(stats == MainTickStatistics())
    }
}
