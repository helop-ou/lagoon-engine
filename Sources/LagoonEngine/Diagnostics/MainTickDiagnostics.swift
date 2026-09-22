import Foundation

/// Cost and cadence of the engine's 10 Hz main-actor tick between two
/// DecodeTrace lines. Pure so a test can pin it; used only while
/// `ProcessCPUTrace.enabled`.
nonisolated struct MainTickStatistics: Equatable, Sendable {
    private(set) var count = 0
    private(set) var totalDuration: Duration = .zero
    private(set) var maxDuration: Duration = .zero
    /// Longest gap between ticks; a late tick means the main actor was busy.
    private(set) var maxInterval: Duration = .zero

    mutating func record(duration: Duration, interval: Duration?) {
        count += 1
        totalDuration += duration
        if duration > maxDuration {
            maxDuration = duration
        }
        if let interval, interval > maxInterval {
            maxInterval = interval
        }
    }

    /// One-line summary for a DecodeTrace tick; resets the accumulator.
    mutating func drain() -> String {
        let averageMs = count > 0 ? Self.milliseconds(totalDuration) / Double(count) : 0
        let line = String(
            format: "tick=%d tickAvgMs=%.1f tickMaxMs=%.1f tickGapMaxMs=%.0f",
            count,
            averageMs,
            Self.milliseconds(maxDuration),
            Self.milliseconds(maxInterval)
        )
        self = MainTickStatistics()
        return line
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
