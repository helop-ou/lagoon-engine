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
    /// since the first failure would be spent. A server's `Retry-After` on
    /// `error` stretches the pause, never the budget.
    func delay(
        beforeAttempt attempt: Int,
        elapsedSinceFirstFailure elapsed: TimeInterval,
        after error: Error? = nil
    ) -> TimeInterval? {
        guard let last = delays.last else { return nil }
        var pause = attempt < delays.count ? delays[attempt] : last
        if let asked = error.flatMap(Self.retryAfter(of:)) {
            pause = max(pause, asked)
        }
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
        case FFmpegTransportError.httpStatus(let code, _), PlaybackCacheError.serverStatus(let code, _):
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

    private static func retryAfter(of error: Error) -> TimeInterval? {
        switch error {
        case FFmpegTransportError.httpStatus(_, let seconds), PlaybackCacheError.serverStatus(_, let seconds):
            seconds
        default:
            nil
        }
    }

    /// `Retry-After` in seconds from now, as either form RFC 9110 allows.
    static func retryAfter(_ response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = Int(value) {
            return seconds >= 0 ? TimeInterval(seconds) : nil
        }
        guard let date = httpDate.date(from: value) else { return nil }
        return max(date.timeIntervalSince(now), 0)
    }

    nonisolated(unsafe) private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

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
