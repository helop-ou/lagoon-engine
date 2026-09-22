import Foundation

/// The proactive fill scheduler's decisions, kept free of the engine, the
/// cache and the clock so a unit test can walk it through a session.
/// `PlaybackController.startBufferFill` owns the loop; this owns
/// what the loop does next.
///
/// Below the cushion target, the measured fetch throughput must exceed the
/// title's consumption rate even after yielding time to foreground reads.
/// Use actual returned bytes: a production 1 MiB chunk contains much less
/// than 0.25 seconds of high-bitrate 4K media, so a fixed per-chunk cushion
/// gain cannot identify spare capacity. Throughput also remains measurable
/// after gentle pacing, which would otherwise hide that capacity indefinitely.
nonisolated struct PlaybackFillPolicy: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        case fetch
        case wait(TimeInterval)
        case stop
    }

    /// What the scheduler sees between fetches. `aheadSeconds` is nil when
    /// the title's duration or length is unknown; the policy then cannot
    /// compare fetch throughput with playback and keeps the gentle pace.
    struct Snapshot: Equatable, Sendable {
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
    /// Wall-clock seconds of cached playback the scheduler tries to keep at
    /// the viewer's current rate, within the existing disk cache capacity.
    static let targetAheadSeconds: Double = 120
    /// Below the target: yield this fraction of the last request's own time
    /// between chunks, so foreground requests keep a fixed share of the link
    /// however slow it is, and a fast link never idles. Deliberately not
    /// capped in seconds: a cap would shrink that share on exactly the slow
    /// links where the hurried branch is the steady state.
    static let hurriedYieldFraction: Double = 0.5
    /// Leave a margin beyond break-even throughput after the foreground
    /// yield. An average container bitrate is an estimate, and a link that
    /// only just carries playback should keep the gentle background pace.
    static let minimumHeadroomRatio: Double = 1.1
    /// Above the target: the earlier pacing, roughly a 20% duty cycle.
    static let relaxedPacingMultiplier: Double = 4
    static let relaxedPacingCapSeconds: TimeInterval = 8
    static let minimumMeasuredRequestSeconds: TimeInterval = 0.125
    static let failureBackoffBaseSeconds: TimeInterval = 1
    static let failureBackoffCapSeconds: TimeInterval = 30

    private(set) var consecutiveFailures = 0

    /// Before a fetch: a title that fits under the cap finishes and the loop
    /// ends; a stall or buffering renderer gets the link to itself for a
    /// while.
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
            // A windowed cache's read-ahead is full: wait for the playhead to
            // make room rather than give up on the rest of the movie. A
            // whole-file cache with nothing left is done.
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
            // No cushion history crosses a seek, pause, rate change, failure,
            // or full-window wait. Each request measures today's capacity,
            // including any contention with foreground reads during it.
            return .wait(seconds * Self.hurriedYieldFraction)
        }
    }

    /// Seconds of media a byte cushion represents, assuming the title's
    /// average bitrate. Nil when either side is unknown.
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
