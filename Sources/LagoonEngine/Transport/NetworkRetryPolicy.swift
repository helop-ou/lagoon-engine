import Foundation

/// How long a transient network fault is ridden out before a read fails.
///
/// A dropped Wi-Fi link or a restarting server answers fast (`-1009`,
/// `-1005`, a 503), so three retries ran out in under two seconds and the
/// host's ladder then reloaded over the same dead network. Buffered media
/// keeps playing while a read waits, so the budget is time rather than a
/// count: long enough to ride out a short outage, bounded so a real failure
/// still reaches the host.
nonisolated struct NetworkRetryPolicy: Sendable {
    /// Seconds from the first failure after which a read gives up.
    var budget: TimeInterval
    /// Pauses before successive retries; the last one repeats.
    var delays: [TimeInterval]

    static let playback = NetworkRetryPolicy(budget: 30, delays: [0.25, 0.5, 1, 2])

    /// The pause before retry `attempt` (from zero), or nil once the budget
    /// since the first failure would be spent.
    func delay(beforeAttempt attempt: Int, elapsedSinceFirstFailure elapsed: TimeInterval) -> TimeInterval? {
        guard let last = delays.last else { return nil }
        let pause = attempt < delays.count ? delays[attempt] : last
        guard elapsed + pause <= budget else { return nil }
        return pause
    }

    /// Whether another attempt could succeed: the network or the server, not
    /// the request. A refused certificate, a bad URL or a 4xx answer the same
    /// way every time.
    static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled, .badURL, .unsupportedURL,
                 .userCancelledAuthentication, .userAuthenticationRequired,
                 .appTransportSecurityRequiresSecureConnection,
                 .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
                 .clientCertificateRejected, .clientCertificateRequired:
                return false
            default:
                return true
            }
        }
        switch error {
        case FFmpegTransportError.httpStatus(let code), PlaybackCacheError.serverStatus(let code):
            return isTransient(httpStatus: code)
        case FFmpegTransportError.timeout:
            return true
        default:
            return false
        }
    }

    static func isTransient(httpStatus code: Int) -> Bool {
        (500...599).contains(code) || code == 408 || code == 429
    }

    /// Sleeps `seconds` in short slices, returning early (false) once
    /// `stopped` says the read is no longer wanted.
    static func pause(_ seconds: TimeInterval, unless stopped: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if stopped() { return false }
            Thread.sleep(forTimeInterval: min(0.1, max(deadline.timeIntervalSinceNow, 0)))
        }
        return !stopped()
    }
}
