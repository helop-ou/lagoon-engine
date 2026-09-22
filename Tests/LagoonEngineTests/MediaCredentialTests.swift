import Foundation
import Testing
@testable import LagoonEngine

/// Every media consumer sends the credential as a header, never a query token,
/// because CFNetwork logs a failed task's URL.
@Suite("Media credential travels as a header", .serialized)
struct MediaCredentialTests {
    private static let authorization = MediaRequestAuthorization(
        origin: URL(string: "https://\(MediaCredentialStub.host):8920")!,
        headerName: "Authorization",
        headerValue: #"MediaBrowser Token="secret""#,
        queryNames: ["apikey", "api_key"]
    )

    // MARK: - MediaRequestAuthorization.sanitizedURL

    @Test func sanitizedURLStripsBothSpellingsOnTheOriginAndKeepsOtherItemsAndOrder() {
        let apiKey = URL(string: "https://\(MediaCredentialStub.host):8920/Videos/1/stream?static=true&ApiKey=secret&Tag=abc")!
        #expect(Self.authorization.sanitizedURL(apiKey).absoluteString
            == "https://\(MediaCredentialStub.host):8920/Videos/1/stream?static=true&Tag=abc")

        let legacy = URL(string: "https://\(MediaCredentialStub.host):8920/Videos/1/stream?static=true&api_key=secret&Tag=abc")!
        #expect(Self.authorization.sanitizedURL(legacy).absoluteString
            == "https://\(MediaCredentialStub.host):8920/Videos/1/stream?static=true&Tag=abc")
    }

    @Test func sanitizedURLLeavesACrossOriginURLUntouched() {
        let url = URL(string: "https://elsewhere.test/file.srt?ApiKey=secret")!
        #expect(Self.authorization.sanitizedURL(url) == url)
    }

    // MARK: - MediaRequestAuthorization.request(for:)

    @Test func requestForSetsTheHeaderAndStripsTheQueryOnTheOrigin() {
        let url = URL(string: "https://\(MediaCredentialStub.host):8920/Videos/1/stream?ApiKey=secret&x=1")!
        let request = Self.authorization.request(for: url, timeoutInterval: 30)
        #expect(request.url?.absoluteString == "https://\(MediaCredentialStub.host):8920/Videos/1/stream?x=1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == #"MediaBrowser Token="secret""#)
        #expect(request.timeoutInterval == 30)
    }

    @Test func requestForSetsNoHeaderAndKeepsTheURLForAnotherOrigin() {
        let url = URL(string: "https://elsewhere.test/file.srt?ApiKey=secret")!
        let request = Self.authorization.request(for: url, timeoutInterval: 12)
        #expect(request.url == url)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.timeoutInterval == 12)
    }

    @Test func requestForWithoutATimeoutKeepsURLRequestsOwnDefault() {
        let url = URL(string: "https://\(MediaCredentialStub.host):8920/x")!
        #expect(Self.authorization.request(for: url).timeoutInterval == URLRequest(url: url).timeoutInterval)
    }

    // MARK: - PlaybackRangeRequest (exercised through URLSessionPlaybackRangeLoader:
    // the request type itself is private to PlaybackCache.swift)

    @Test func playbackRangeRequestsCarryTheHeaderAndATokenFreeURL() throws {
        MediaCredentialStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaCredentialStub.self]
        let loader = URLSessionPlaybackRangeLoader(configuration: configuration, authorization: Self.authorization)
        MediaCredentialStub.set("/video.mkv", .init(body: Data(repeating: 7, count: 16)))
        _ = try loader.load(
            url: URL(string: "https://\(MediaCredentialStub.host):8920/video.mkv?ApiKey=secret")!,
            range: PlaybackByteRange(0, 16),
            priority: URLSessionTask.highPriority
        )
        let recorded = try #require(MediaCredentialStub.requests(path: "/video.mkv").first)
        #expect(!recorded.url.contains("ApiKey"))
        #expect(recorded.headers["Authorization"] == #"MediaBrowser Token="secret""#)
        #expect(recorded.headers["Range"] == "bytes=0-15")
        #expect(recorded.headers["Accept-Encoding"] == "identity")
    }

    @Test func playbackRangeRequestsWithoutAuthorizationAreUnchangedFromBefore() throws {
        MediaCredentialStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaCredentialStub.self]
        let loader = URLSessionPlaybackRangeLoader(configuration: configuration)
        MediaCredentialStub.set("/video.mkv", .init(body: Data(repeating: 7, count: 16)))
        _ = try loader.load(
            url: URL(string: "https://\(MediaCredentialStub.host):8920/video.mkv?ApiKey=secret")!,
            range: PlaybackByteRange(0, 16),
            priority: URLSessionTask.highPriority
        )
        let recorded = try #require(MediaCredentialStub.requests(path: "/video.mkv").first)
        #expect(recorded.url.contains("ApiKey=secret"))
        #expect(recorded.headers["Authorization"] == nil)
        #expect(recorded.headers["Range"] == "bytes=0-15")
        #expect(recorded.headers["Accept-Encoding"] == "identity")
    }

    // MARK: - ExternalSubtitleLoader

    @Test func externalSubtitleLoaderSendsTheHeaderAndATokenFreeURLAndStillParsesCues() async throws {
        MediaCredentialStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaCredentialStub.self]
        let downloader = BoundedDownload(configuration: configuration)
        MediaCredentialStub.set("/sub.srt", .init(body: Data(
            "1\n00:00:00,000 --> 00:00:05,000\nHello there\n".utf8
        )))
        let track = ExternalSubtitleTrack(
            url: URL(string: "https://\(MediaCredentialStub.host):8920/sub.srt?ApiKey=secret")!,
            title: "English",
            language: "en",
            select: true
        )
        let cues = try await ExternalSubtitleLoader.load(track, using: downloader, authorization: Self.authorization)
        #expect(cues.first?.text == "Hello there")
        let recorded = try #require(MediaCredentialStub.requests(path: "/sub.srt").first)
        #expect(!recorded.url.contains("ApiKey"))
        #expect(recorded.headers["Authorization"] == #"MediaBrowser Token="secret""#)
    }

    @Test func externalSubtitleLoaderWithNoAuthorizationSendsTheBareURL() async throws {
        MediaCredentialStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaCredentialStub.self]
        let downloader = BoundedDownload(configuration: configuration)
        MediaCredentialStub.set("/webvtt.vtt", .init(body: Data(
            "WEBVTT\n\n00:00:00.000 --> 00:00:05.000\nHello WebVTT\n".utf8
        )))
        let track = ExternalSubtitleTrack(
            url: URL(string: "https://\(MediaCredentialStub.host):8920/webvtt.vtt")!,
            title: "English",
            language: "en",
            select: true
        )
        let cues = try await ExternalSubtitleLoader.load(track, using: downloader)
        #expect(cues.first?.text == "Hello WebVTT")
        let recorded = try #require(MediaCredentialStub.requests(path: "/webvtt.vtt").first)
        #expect(recorded.headers["Authorization"] == nil)
    }
}

// TrickplayLoader builds its request through `request(for:)`, covered above.

private nonisolated struct MediaCredentialFixture: Sendable {
    var body = Data()
}

/// A scripted per-path `URLProtocol`: honours `Range` when sent (for the range
/// loader), serves the whole body as 200 otherwise (for subtitles), and records
/// each request's URL and headers.
private nonisolated final class MediaCredentialStub: URLProtocol {
    static let host = "media-credential.test"

    private static let lock = NSLock()
    private nonisolated(unsafe) static var fixtures: [String: MediaCredentialFixture] = [:]
    private nonisolated(unsafe) static var recorded: [String: [(url: String, headers: [String: String])]] = [:]

    static func reset() {
        lock.withLock {
            fixtures = [:]
            recorded = [:]
        }
    }

    static func set(_ path: String, _ fixture: MediaCredentialFixture) {
        lock.withLock { fixtures[path] = fixture }
    }

    static func requests(path: String) -> [(url: String, headers: [String: String])] {
        lock.withLock { recorded[path] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let range = request.value(forHTTPHeaderField: "Range")
        let headers = request.allHTTPHeaderFields ?? [:]
        let fixture = Self.lock.withLock {
            Self.recorded[url.path, default: []].append((url: url.absoluteString, headers: headers))
            return Self.fixtures[url.path] ?? MediaCredentialFixture()
        }
        if let range {
            let start = min(Self.parseRangeStart(range) ?? 0, fixture.body.count)
            let slice = Data(fixture.body.suffix(from: start))
            let end = max(fixture.body.count - 1, start)
            let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [
                "Content-Range": "bytes \(start)-\(end)/\(fixture.body.count)",
                "Content-Length": "\(slice.count)",
                "Content-Type": "application/octet-stream",
            ])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: slice)
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                "Content-Length": "\(fixture.body.count)",
                "Content-Type": "text/plain",
            ])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: fixture.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func parseRangeStart(_ header: String) -> Int? {
        guard header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        guard let dash = spec.firstIndex(of: "-") else { return nil }
        return Int(spec[spec.startIndex..<dash])
    }
}
