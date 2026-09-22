import Foundation

/// A credential sent as a header to one origin, so it never appears in a URL:
/// CFNetwork logs a failed task's full URL, and so would any diagnostic.
public nonisolated struct MediaRequestAuthorization: Sendable, Equatable {
    /// Only scheme, host and effective port are compared.
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

    /// Same scheme, host (case-insensitive) and effective port as `origin`. The
    /// only same-origin check; nothing else reimplements it.
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

    /// The URL without the credential when it targets `origin`. For callers
    /// that need a bare URL, such as an HLS manifest reference, not a request.
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
