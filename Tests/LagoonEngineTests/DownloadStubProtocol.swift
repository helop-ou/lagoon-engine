import Foundation
import Testing

nonisolated struct DownloadFixture: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var chunks: [Data] = []
    var holdBody = false
    var holdResponse = false
}

/// A scripted `URLProtocol` for bounded downloads. It can hold a response or
/// a body open until a test releases it, and records which paths were
/// cancelled, so a test can tell a stopped transfer from a finished one.
nonisolated final class DownloadStubProtocol: URLProtocol, @unchecked Sendable {
    static let host = "media.download.test"
    private static let lock = NSLock()
    private nonisolated(unsafe) static var fixtures: [String: DownloadFixture] = [:]
    private nonisolated(unsafe) static var recorded: [URLRequest] = []
    private nonisolated(unsafe) static var cancelled: [String] = []
    private nonisolated(unsafe) static var held: [DownloadStubProtocol] = []
    private let stateLock = NSLock()
    private var stopped = false
    private var fixture = DownloadFixture()

    static var requests: [URLRequest] { lock.withLock { recorded } }
    static var stopped: [String] { lock.withLock { cancelled } }
    static func isHeld(_ path: String) -> Bool { lock.withLock { held.contains { $0.request.url?.path == path } } }
    static func reset() { lock.withLock { fixtures = [:]; recorded = []; cancelled = []; held = [] } }
    static func set(_ path: String, _ fixture: DownloadFixture) { lock.withLock { fixtures[path] = fixture } }

    static func release(_ path: String) {
        let pending = lock.withLock {
            let pending = held.filter { $0.request.url?.path == path }
            held.removeAll { $0.request.url?.path == path }
            return pending
        }
        for item in pending {
            if item.fixture.holdResponse { item.deliverResponse() }
            item.deliverBody()
        }
    }

    static func url(_ path: String) -> URL { URL(string: "https://\(host)\(path)")! }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadStubProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        fixture = Self.lock.withLock {
            Self.recorded.append(request)
            return Self.fixtures[url.path] ?? DownloadFixture(status: 404)
        }
        if fixture.holdResponse {
            Self.lock.withLock { Self.held.append(self) }
            return
        }
        deliverResponse()
        if fixture.holdBody { Self.lock.withLock { Self.held.append(self) } }
        else { deliverBody() }
    }

    private func deliverResponse() {
        guard let url = request.url else { return }
        // Without a MIME type Foundation may hold the response to sniff content.
        let headers = ["Content-Type": "application/octet-stream"].merging(fixture.headers) { _, supplied in supplied }
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: nil, headerFields: headers)!,
            cacheStoragePolicy: .notAllowed
        )
    }

    private func deliverBody() {
        guard !stateLock.withLock({ stopped }) else { return }
        for chunk in fixture.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true }
        Self.lock.withLock {
            Self.cancelled.append(request.url?.path ?? "")
            Self.held.removeAll { $0 === self }
        }
    }
}

/// Polls a main-actor condition and fails the test when it never holds.
@MainActor
func eventuallyTrue(
    timeout: Duration = .seconds(3),
    line: UInt = #line,
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    if !condition() { throw DownloadWaitTimeout(line: line) }
}

struct DownloadWaitTimeout: Error, CustomStringConvertible {
    var line: UInt
    var description: String { "Timed out waiting for the observable result at line \(line)" }
}

/// `DownloadStubProtocol` keeps process-wide state, so every suite that
/// scripts it nests here and the whole group runs one test at a time.
@Suite("Scripted downloads", .serialized)
struct ScriptedDownloadTests {}
