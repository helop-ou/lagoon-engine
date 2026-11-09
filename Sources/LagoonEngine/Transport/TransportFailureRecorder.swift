import Foundation

/// Keeps the network failure behind one demuxer's latest failed read, until
/// a read succeeds.
///
/// Every byte source fails a read with `AVERROR(EIO)`, so libavformat's error
/// says nothing about the network. Each `FFmpegCachedIO` the demuxer opens,
/// HLS children included, records here what the failed read threw, and that
/// a read was served.
nonisolated final class TransportFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var last: PlaybackTransportFailure?
    private var servedSinceReset = false
    private var firstServedRead: (@Sendable () -> Void)?

    var lastFailure: PlaybackTransportFailure? {
        lock.withLock { last }
    }

    /// Forgets the failure, and arms `firstServedRead` again.
    func reset() {
        lock.withLock {
            last = nil
            servedSinceReset = false
        }
    }

    /// Runs on the reading thread for the first read served after a reset.
    func onFirstServedRead(_ action: (@Sendable () -> Void)?) {
        lock.withLock { firstServedRead = action }
    }

    /// Bytes arrived, so an earlier failure explains nothing now.
    func served() {
        let action: (@Sendable () -> Void)? = lock.withLock {
            last = nil
            guard !servedSinceReset else { return nil }
            servedSinceReset = true
            return firstServedRead
        }
        action?()
    }

    /// Ignores anything that is not the network's answer: a cancelled or
    /// interrupted read, a malformed response, local storage.
    func record(_ error: Error) {
        guard let failure = PlaybackTransportFailure(error) else { return }
        lock.withLock { last = failure }
    }
}

nonisolated extension PlaybackTransportFailure {
    init?(_ error: Error) {
        switch error {
        case FFmpegTransportError.httpStatus(let code, _), PlaybackCacheError.serverStatus(let code, _):
            self = .httpStatus(code)
        case FFmpegTransportError.timeout:
            self = .urlError(URLError.timedOut.rawValue)
        case let urlError as URLError where urlError.code != .cancelled:
            self = .urlError(urlError.code.rawValue)
        default:
            return nil
        }
    }
}
