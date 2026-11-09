import Foundation

/// What the link delivers while it is busy, over roughly the last
/// `windowSeconds` of transfer time.
///
/// Idle time between requests does not count, so a paced fill on a fast link
/// still reads as fast. Nor does the wait for a request's first byte, so a
/// distant server does not read as a slow link. Overlapping requests share one busy period, so a
/// foreground read and a prefetch together do not halve the figure. Bytes
/// and busy time decay together and the rate is their ratio, so a transfer
/// that finishes inside another's busy period is not over- or under-counted
/// once the second one lands.
nonisolated struct PlaybackThroughputMeter: Equatable, Sendable {
    /// Busy seconds after which a sample's weight has fallen to 1/e.
    static let windowSeconds: Double = 10
    /// Weight of the newest wait in `firstByteSeconds`.
    static let firstByteSmoothing: Double = 0.25

    private var activeRequests = 0
    /// Start of the busy time not yet sampled; nil while idle.
    private var unsampledSince: TimeInterval?
    private var decayedBytes: Double = 0
    private var decayedSeconds: Double = 0
    /// Seconds a request waits for its first byte, smoothed over recent
    /// requests. Nil until a first byte has arrived.
    private(set) var firstByteSeconds: Double?

    /// Nil until a transfer has completed.
    var bytesPerSecond: Double? {
        guard decayedSeconds > 0, decayedBytes > 0 else { return nil }
        return decayedBytes / decayedSeconds
    }

    /// A request's first byte arrived, `waited` seconds after it was asked
    /// for. Busy time starts here.
    mutating func requestStarted(at now: TimeInterval, waited: TimeInterval? = nil) {
        if let waited, waited.isFinite, waited >= 0 {
            firstByteSeconds = firstByteSeconds.map {
                $0 + (waited - $0) * Self.firstByteSmoothing
            } ?? waited
        }
        if activeRequests == 0 { unsampledSince = now }
        activeRequests += 1
    }

    /// A transfer completed with `bytes` off the network.
    mutating func requestFinished(at now: TimeInterval, bytes: Int64) {
        guard activeRequests > 0 else { return }
        let busy = unsampledSince.map { max(now - $0, 0) } ?? 0
        let decay = exp(-busy / Self.windowSeconds)
        decayedBytes = decayedBytes * decay + Double(max(bytes, 0))
        decayedSeconds = decayedSeconds * decay + busy
        activeRequests -= 1
        unsampledSince = activeRequests > 0 ? now : nil
    }

    /// Cancelled or failed: its time says nothing about the link. Alone, its
    /// busy time is dropped; alongside another transfer the time stays with
    /// that one, which was receiving bytes all along.
    mutating func requestAbandoned(at now: TimeInterval) {
        guard activeRequests > 0 else { return }
        activeRequests -= 1
        if activeRequests == 0 { unsampledSince = nil }
    }
}

/// A meter several cache scopes can share, as an HLS item's segments do.
nonisolated final class PlaybackThroughputMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var meter = PlaybackThroughputMeter()

    var bytesPerSecond: Double? {
        lock.lock()
        defer { lock.unlock() }
        return meter.bytesPerSecond
    }

    var firstByteSeconds: Double? {
        lock.lock()
        defer { lock.unlock() }
        return meter.firstByteSeconds
    }

    func requestStarted(waited: TimeInterval? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        meter.requestStarted(at: now, waited: waited)
        lock.unlock()
    }

    func requestFinished(bytes: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        meter.requestFinished(at: now, bytes: bytes)
        lock.unlock()
    }

    func requestAbandoned() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        meter.requestAbandoned(at: now)
        lock.unlock()
    }
}
