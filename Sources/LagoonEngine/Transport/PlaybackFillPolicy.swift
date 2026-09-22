import Foundation

/// The fill scheduler's decisions, free of engine, cache and clock so a test
/// can walk it through a session. The engine runs the loop; this decides each
/// step.
///
/// Below the cushion target, measured throughput must beat the title's
/// consumption rate even after yielding to foreground reads. It uses returned
/// bytes because a 1 MiB chunk can hold under 0.25 s of high-bitrate 4K, so a
/// fixed per-chunk gain cannot reveal spare capacity.
nonisolated struct PlaybackFillPolicy: Equatable, Sendable {
    init() {}

    enum Decision: Equatable, Sendable {
        case fetch
        case wait(TimeInterval)
        case stop
    }

    /// What the scheduler sees between fetches. `aheadSeconds` is nil when
    /// duration or length is unknown, and the policy keeps the gentle pace.
    struct Snapshot: Equatable, Sendable {
        init(
            isPaused: Bool = false,
            isBuffering: Bool = false,
            newStall: Bool = false,
            aheadSeconds: Double? = nil,
            averageBytesPerSecond: Double? = nil,
            playbackRate: Double = 1,
            isWindowed: Bool = false,
            bufferedFraction: Double? = nil
        ) {
            self.isPaused = isPaused
            self.isBuffering = isBuffering
            self.newStall = newStall
            self.aheadSeconds = aheadSeconds
            self.averageBytesPerSecond = averageBytesPerSecond
            self.playbackRate = playbackRate
            self.isWindowed = isWindowed
            self.bufferedFraction = bufferedFraction
        }

        var isPaused = false
        var isBuffering = false
        var newStall = false
        var aheadSeconds: Double?
        var averageBytesPerSecond: Double?
        var playbackRate: Double = 1
        var isWindowed = false
        var bufferedFraction: Double?
    }

    /// Fill only begins after the player has presented its initial cushion.
    static let warmupSeconds: TimeInterval = 3
    /// A renderer stall means the foreground needs every byte it can get.
    static let stallCooldownSeconds: TimeInterval = 20
    /// A full window waits for the playhead to make room.
    static let idlePollSeconds: TimeInterval = 2
    /// Wall-clock seconds of cached playback to keep at the current rate,
    /// within the cache capacity.
    static let targetAheadSeconds: Double = 120
    /// Below the target, yield this fraction of the last request's time between
    /// chunks, so foreground reads keep a fixed share of any link. Not capped
    /// in seconds: a cap would shrink that share on slow links, where this
    /// branch is the steady state.
    static let hurriedYieldFraction: Double = 0.5
    /// Margin over break-even throughput. Average bitrate is an estimate, and a
    /// link that barely carries playback should stay at the gentle pace.
    static let minimumHeadroomRatio: Double = 1.1
    /// Above the target: roughly a 20% duty cycle.
    static let relaxedPacingMultiplier: Double = 4
    static let relaxedPacingCapSeconds: TimeInterval = 8
    static let minimumMeasuredRequestSeconds: TimeInterval = 0.125
    static let failureBackoffBaseSeconds: TimeInterval = 1
    static let failureBackoffCapSeconds: TimeInterval = 30

    private(set) var consecutiveFailures = 0

    /// Before a fetch: a title that fits the cap finishes and the loop ends; a
    /// stall or buffering renderer gets the link to itself for a while.
    func beforeFetch(_ snapshot: Snapshot) -> Decision {
        if snapshot.bufferedFraction == 1, !snapshot.isWindowed {
            return .stop
        }
        if snapshot.isBuffering || snapshot.newStall {
            return .wait(Self.stallCooldownSeconds)
        }
        return .fetch
    }

    /// After a fetch: pace, poll, back off, or stop, by what the fetch did.
    mutating func afterFetch(_ outcome: PlaybackPrefetchOutcome, _ snapshot: Snapshot) -> Decision {
        switch outcome {
        case .cancelled:
            return .stop
        case .failed:
            consecutiveFailures += 1
            let exponent = Double(min(consecutiveFailures - 1, 10))
            let backoff = Self.failureBackoffBaseSeconds * pow(2, exponent)
            return .wait(min(backoff, Self.failureBackoffCapSeconds))
        case .exhausted:
            consecutiveFailures = 0
            // A full window waits for the playhead to make room; a whole-file
            // cache with nothing left is done.
            return snapshot.isWindowed ? .wait(Self.idlePollSeconds) : .stop
        case .fetched(let bytes, let seconds):
            consecutiveFailures = 0
            if snapshot.isPaused {
                // No foreground demux request is consuming: full speed.
                return .fetch
            }
            let validMeasurement = seconds.isFinite && seconds >= 0
            let measured = validMeasurement ? max(seconds, Self.minimumMeasuredRequestSeconds)
                : Self.minimumMeasuredRequestSeconds
            let relaxed = Decision.wait(min(measured * Self.relaxedPacingMultiplier, Self.relaxedPacingCapSeconds))
            guard validMeasurement, bytes > 0,
                  let ahead = snapshot.aheadSeconds, ahead.isFinite,
                  let bytesPerSecond = snapshot.averageBytesPerSecond,
                  bytesPerSecond.isFinite, bytesPerSecond > 0,
                  snapshot.playbackRate.isFinite, snapshot.playbackRate > 0,
                  ahead / snapshot.playbackRate < Self.targetAheadSeconds else { return relaxed }

            let fetchedMediaSeconds = Double(bytes) / bytesPerSecond
            let pacedRequestSeconds = seconds * (1 + Self.hurriedYieldFraction)
            let requiredMediaSeconds = pacedRequestSeconds * snapshot.playbackRate * Self.minimumHeadroomRatio
            guard fetchedMediaSeconds > requiredMediaSeconds else { return relaxed }
            // No cushion history crosses a seek, pause, rate change, failure or
            // wait. Each request measures current capacity, contention
            // included.
            return .wait(seconds * Self.hurriedYieldFraction)
        }
    }

    /// Media seconds a byte cushion represents at the average bitrate; nil when
    /// either is unknown.
    static func aheadSeconds(cachedBytesAhead: Int64, contentLength: Int64?, durationSeconds: Double) -> Double? {
        guard let bytesPerSecond = averageBytesPerSecond(
            contentLength: contentLength, durationSeconds: durationSeconds
        ) else { return nil }
        return Double(max(cachedBytesAhead, 0)) / bytesPerSecond
    }

    static func averageBytesPerSecond(contentLength: Int64?, durationSeconds: Double) -> Double? {
        guard let contentLength, contentLength > 0,
              durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        let bytesPerSecond = Double(contentLength) / durationSeconds
        return bytesPerSecond.isFinite && bytesPerSecond > 0 ? bytesPerSecond : nil
    }
}
