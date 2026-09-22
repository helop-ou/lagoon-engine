import Foundation

/// A credential carried as a request header for one origin, so the URL a
/// transport hands to URLSession never contains it: CFNetwork logs a failed
/// task's full URL into the unified log, and so would any diagnostic that
/// prints one.
public nonisolated struct MediaRequestAuthorization: Sendable, Equatable {
    /// Scheme, host and effective port are what matter; path and query are
    /// ignored when comparing against a request's URL.
    public let origin: URL
    /// The header to send, usually `Authorization`.
    public let headerName: String
    /// What to send in it. Never logged, and never put in a URL.
    public let headerValue: String
    /// Query item names (compared lowercased) that carry the same credential in the URL.
    public let queryNames: Set<String>

    public init(
        origin: URL,
        headerName: String,
        headerValue: String,
        queryNames: Set<String> = []
    ) {
        self.origin = origin
        self.headerName = headerName
        self.headerValue = headerValue
        self.queryNames = queryNames
    }

    /// Same scheme, host (case-insensitive) and effective port as `origin`.
    /// This is the sole authority every media consumer defers to for
    /// same-origin checks — nothing else reimplements it.
    public func applies(to url: URL) -> Bool {
        url.scheme?.lowercased() == origin.scheme?.lowercased()
            && url.host?.lowercased() == origin.host?.lowercased()
            && Self.effectivePort(url) == Self.effectivePort(origin)
    }

    /// Strips `queryNames` from the URL and sets the header when the request
    /// targets `origin`; leaves other requests untouched.
    public func apply(to request: inout URLRequest) {
        guard let url = request.url, applies(to: url) else { return }
        request.url = strippingCredentials(from: url)
        request.setValue(headerValue, forHTTPHeaderField: headerName)
    }

    /// The URL with the credential removed when it targets `origin`; other
    /// origins are left untouched. For consumers that still need a bare URL
    /// (a server-generated HLS manifest reference, a display-only value)
    /// rather than a request they can attach the header to.
    public func sanitizedURL(_ url: URL) -> URL {
        applies(to: url) ? strippingCredentials(from: url) : url
    }

    /// A request for `url` with the credential moved into the header when it
    /// targets `origin`; other origins get an ordinary, untouched request.
    public func request(for url: URL, timeoutInterval: TimeInterval? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
        apply(to: &request)
        return request
    }

    /// The URL with `queryNames` removed (used by tests and by `apply`).
    public func strippingCredentials(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else {
            return url
        }
        let filtered = items.filter { !queryNames.contains($0.name.lowercased()) }
        components.queryItems = filtered.isEmpty ? nil : filtered
        return components.url ?? url
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        return switch url.scheme?.lowercased() {
        case "http": 80
        case "https": 443
        default: nil
        }
    }
}
