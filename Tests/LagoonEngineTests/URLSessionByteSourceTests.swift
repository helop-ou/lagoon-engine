import CommonCrypto
import Foundation
import Libavformat
import Libavutil
import Testing
@testable import LagoonEngine

@Suite("URLSession transport", .serialized)
struct URLSessionByteSourceTests {
    @Test func sequentialReadsStreamOneRangedRequest() throws {
        let transport = makeTransport()
        let body = Self.body(count: 1_048_576)
        TransportStub.set("/ranged-one", .init(body: body))
        var io: UnsafeMutablePointer<AVIOContext>?
        #expect(Self.open(transport, url: Self.testURL("/ranged-one"), into: &io) >= 0)
        let context = try #require(io)
        defer { _ = transport.close(context) }
        let received = Self.readAll(context)
        #expect(received == body)
        #expect(avio_size(context) == Int64(body.count))
        let requests = TransportStub.requests(path: "/ranged-one")
        #expect(requests.count == 1)
        #expect(requests.first?.range == "bytes=0-")
    }

    @Test func aSeekRestartsFromTheNewOffset() throws {
        let transport = makeTransport()
        let body = Self.body(count: 1_048_576)
        TransportStub.set("/ranged-seek", .init(body: body))
        var io: UnsafeMutablePointer<AVIOContext>?
        #expect(Self.open(transport, url: Self.testURL("/ranged-seek"), into: &io) >= 0)
        let context = try #require(io)
        defer { _ = transport.close(context) }
        var warmup = [UInt8](repeating: 0, count: 100 * 1_024)
        let warmupRead = avio_read(context, &warmup, Int32(warmup.count))
        #expect(warmupRead > 0)
        #expect(avio_seek(context, 700_000, Int32(SEEK_SET)) == 700_000)
        let received = Self.readAll(context)
        #expect(received == body.suffix(from: 700_000))
        let requests = TransportStub.requests(path: "/ranged-seek")
        #expect(requests.count == 2)
        #expect(requests.last?.range == "bytes=700000-")
    }

    @Test func aServerThatIgnoresRangeStillServesFromZero() throws {
        let transport = makeTransport()
        let body = Self.body(count: 256 * 1_024)
        TransportStub.set("/nonranged", .init(ranged: false, body: body))
        var io: UnsafeMutablePointer<AVIOContext>?
        #expect(Self.open(transport, url: Self.testURL("/nonranged"), into: &io) >= 0)
        let context = try #require(io)
        defer { _ = transport.close(context) }
        let received = Self.readAll(context)
        #expect(received == body)
        #expect(TransportStub.requests(path: "/nonranged").count == 1)
    }

    @Test func serverErrorsAreIOErrorsNotEOF() throws {
        let transport = makeTransport()
        TransportStub.set("/error", .init(status: 500))
        var io: UnsafeMutablePointer<AVIOContext>?
        #expect(Self.open(transport, url: Self.testURL("/error"), into: &io) >= 0)
        let context = try #require(io)
        defer { _ = transport.close(context) }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let result = avio_read(context, &buffer, Int32(buffer.count))
        #expect(result < 0)
        #expect(result != -541_478_725) // AVERROR_EOF: a failed read is not a clean end of stream.
        let count = TransportStub.requests(path: "/error").count
        #expect(count >= 2)
        #expect(count <= 4)
    }

    @Test func aDroppedConnectionResumesAtTheSamePosition() throws {
        let transport = makeTransport()
        let body = Self.body(count: 1_048_576)
        TransportStub.set("/dropped", .init(body: body, dropAfterBytes: 300 * 1_024))
        var io: UnsafeMutablePointer<AVIOContext>?
        #expect(Self.open(transport, url: Self.testURL("/dropped"), into: &io) >= 0)
        let context = try #require(io)
        defer { _ = transport.close(context) }
        let received = Self.readAll(context)
        #expect(received == body)
        let requests = TransportStub.requests(path: "/dropped")
        #expect(requests.count == 2)
        let resumeOffset = requests.last.flatMap { parseRangeStart($0.range) } ?? 0
        #expect(resumeOffset > 0)
    }

    @Test func notFoundIsNotRetried() throws {
        let transport = makeTransport()
        TransportStub.set("/missing", .init(status: 404))
        var io: UnsafeMutablePointer<AVIOContext>?
        #expect(Self.open(transport, url: Self.testURL("/missing"), into: &io) >= 0)
        let context = try #require(io)
        defer { _ = transport.close(context) }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let result = avio_read(context, &buffer, Int32(buffer.count))
        #expect(result < 0)
        #expect(TransportStub.requests(path: "/missing").count == 1)
    }

    @Test func anInterruptedReadReturnsPromptly() throws {
        let flag = InterruptFlag()
        let transport = makeTransport(interrupted: { flag.value })
        TransportStub.set("/hold", .init(body: Self.body(count: 4_096), holdBody: true))
        var io: UnsafeMutablePointer<AVIOContext>?
        #expect(Self.open(transport, url: Self.testURL("/hold"), into: &io) >= 0)
        let context = try #require(io)
        defer { _ = transport.close(context) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { flag.set() }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let start = ContinuousClock.now
        let result = avio_read(context, &buffer, Int32(buffer.count))
        let elapsed = ContinuousClock.now - start
        #expect(result < 0)
        #expect(elapsed < .seconds(1))
    }

    @Test func anInterruptedTransportRefusesToOpen() throws {
        let transport = makeTransport(interrupted: { true })
        TransportStub.set("/never", .init(body: Self.body(count: 16)))
        var io: UnsafeMutablePointer<AVIOContext>?
        let result = Self.open(transport, url: Self.testURL("/never"), into: &io)
        #expect(result == ffmpegErrorExit)
        #expect(io == nil)
        #expect(TransportStub.requests(path: "/never").isEmpty)
    }

    @Test func encryptedSegmentsDecryptThroughCryptoURLs() throws {
        let transport = makeTransport()
        let plaintext = Self.body(count: 100 * 1_024)
        let key = Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) })
        let iv = Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &* 3 &+ 2) })
        let ciphertext = try Self.encryptAES128CBC(plaintext, key: key, iv: iv)
        TransportStub.set("/encrypted", .init(body: ciphertext))
        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        av_dict_set(&options, "key", Self.hex(key), 0)
        av_dict_set(&options, "iv", Self.hex(iv), 0)
        var io: UnsafeMutablePointer<AVIOContext>?
        let result = Self.open(
            transport,
            url: "crypto+" + Self.testURL("/encrypted"),
            options: &options,
            into: &io
        )
        #expect(result >= 0)
        let context = try #require(io)
        defer { _ = transport.close(context) }
        let received = Self.readAll(context)
        #expect(received == plaintext)
    }

    @Test func credentialsMoveFromTheQueryToAHeaderOnTheServerOrigin() throws {
        let authorization = MediaRequestAuthorization(
            origin: URL(string: "https://\(TransportStub.host)")!,
            headerName: "Authorization",
            headerValue: #"MediaBrowser Token="secret""#,
            queryNames: ["apikey"]
        )
        let transport = makeTransport(authorization: authorization)
        TransportStub.set("/media", .init(body: Self.body(count: 4_096)))
        var io: UnsafeMutablePointer<AVIOContext>?
        #expect(Self.open(transport, url: Self.testURL("/media") + "?ApiKey=secret&x=1", into: &io) >= 0)
        let context = try #require(io)
        defer { _ = transport.close(context) }
        _ = Self.readAll(context)
        let requests = TransportStub.requests(path: "/media")
        let recorded = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(!recorded.url.contains("ApiKey"))
        #expect(recorded.url.contains("x=1"))
        #expect(recorded.headers["Authorization"] == #"MediaBrowser Token="secret""#)
    }

    @Test func credentialsStayOutOfRequestsToOtherOrigins() throws {
        let authorization = MediaRequestAuthorization(
            origin: URL(string: "https://some-other-server.test")!,
            headerName: "Authorization",
            headerValue: #"MediaBrowser Token="secret""#,
            queryNames: ["apikey"]
        )
        let transport = makeTransport(authorization: authorization)
        TransportStub.set("/media-elsewhere", .init(body: Self.body(count: 4_096)))
        var io: UnsafeMutablePointer<AVIOContext>?
        #expect(Self.open(transport, url: Self.testURL("/media-elsewhere") + "?ApiKey=secret", into: &io) >= 0)
        let context = try #require(io)
        defer { _ = transport.close(context) }
        _ = Self.readAll(context)
        let requests = TransportStub.requests(path: "/media-elsewhere")
        let recorded = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(recorded.url.contains("ApiKey=secret"))
        #expect(recorded.headers["Authorization"] == nil)
    }

    @Test func aCrossOriginRedirectDropsTheCredentialHeader() throws {
        let authorization = MediaRequestAuthorization(
            origin: URL(string: "https://\(TransportStub.host)")!,
            headerName: "Authorization",
            headerValue: #"MediaBrowser Token="secret""#,
            queryNames: ["apikey"]
        )
        let transport = makeTransport(authorization: authorization)
        let redirectTarget = URL(string: "https://\(TransportStub.redirectHost)/elsewhere")!
        TransportStub.set("/redirecting", .init(redirectTo: redirectTarget))
        TransportStub.set("/elsewhere", .init(body: Self.body(count: 4_096)))
        var io: UnsafeMutablePointer<AVIOContext>?
        #expect(Self.open(transport, url: Self.testURL("/redirecting"), into: &io) >= 0)
        let context = try #require(io)
        defer { _ = transport.close(context) }
        _ = Self.readAll(context)
        let firstRequest = try #require(TransportStub.requests(path: "/redirecting").first)
        let secondRequest = try #require(TransportStub.requests(path: "/elsewhere").first)
        #expect(firstRequest.headers["Authorization"] == #"MediaBrowser Token="secret""#)
        #expect(secondRequest.headers["Authorization"] == nil)
    }

    @Test func closingATransportFreesItsContexts() throws {
        let transport = makeTransport()
        var ioA: UnsafeMutablePointer<AVIOContext>?
        var ioB: UnsafeMutablePointer<AVIOContext>?
        #expect(Self.open(transport, url: Self.testURL("/close-a"), into: &ioA) >= 0)
        #expect(Self.open(transport, url: Self.testURL("/close-b"), into: &ioB) >= 0)
        let contextA = try #require(ioA)
        let contextB = try #require(ioB)
        #expect(transport.close(contextA) == 0)
        #expect(transport.close(contextB) == 0)
        // Safe to call again with nothing open.
        transport.closeAll()
    }

    // MARK: - Helpers

    private func makeTransport(
        interrupted: @escaping @Sendable () -> Bool = { false },
        authorization: MediaRequestAuthorization? = nil
    ) -> FFmpegNetworkTransport {
        TransportStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportStub.self]
        return FFmpegNetworkTransport(isInterrupted: interrupted, sessionConfiguration: configuration, authorization: authorization)
    }

    private static func testURL(_ path: String) -> String { "https://\(TransportStub.host)\(path)" }

    private static func body(count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0) })
    }

    @discardableResult
    private static func open(
        _ transport: FFmpegNetworkTransport,
        url: String,
        options: UnsafeMutablePointer<OpaquePointer?>? = nil,
        into io: inout UnsafeMutablePointer<AVIOContext>?
    ) -> Int32 {
        url.withCString { cString in
            transport.open(context: nil, output: &io, url: cString, flags: AVIO_FLAG_READ, options: options)
        }
    }

    private static func readAll(_ context: UnsafeMutablePointer<AVIOContext>, chunkSize: Int = 64 * 1_024) -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let count = avio_read(context, &buffer, Int32(chunkSize))
            if count <= 0 { break }
            result.append(contentsOf: buffer[0..<Int(count)])
        }
        return result
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func encryptAES128CBC(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        var outLength = 0
        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        let status = output.withUnsafeMutableBytes { outBytes in
            plaintext.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            inBytes.baseAddress, plaintext.count,
                            outBytes.baseAddress, outBytes.count,
                            &outLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CocoaError(.coderInvalidValue) }
        output.removeSubrange(outLength..<output.count)
        return output
    }
}

/// The offset from an open-ended `Range: bytes=<offset>-` header.
nonisolated private func parseRangeStart(_ header: String?) -> Int? {
    guard let header, header.hasPrefix("bytes=") else { return nil }
    let spec = header.dropFirst("bytes=".count)
    guard let dash = spec.firstIndex(of: "-") else { return nil }
    return Int(spec[spec.startIndex..<dash])
}

private nonisolated struct TransportFixture: Sendable {
    var status = 200
    var ranged = true
    var body = Data()
    var chunkSize = 64 * 1_024
    /// Fails with `.networkConnectionLost` once this many bytes have streamed
    /// for the path, then behaves normally.
    var dropAfterBytes: Int?
    /// Sends headers, then no body, until the task is cancelled.
    var holdBody = false
    /// Redirects to this URL instead of serving a body, to test that the
    /// credential header does not cross origins.
    var redirectTo: URL?
}

/// A scripted per-path `URLProtocol`: honours `Range` for `ranged` paths,
/// serves the full body as 200 otherwise, and records each URL and Range
/// header.
private nonisolated final class TransportStub: URLProtocol, @unchecked Sendable {
    static let host = "byte-source.test"
    /// A second origin, so a redirect is genuinely cross-origin.
    static let redirectHost = "byte-source-redirect.test"

    private static let lock = NSLock()
    private nonisolated(unsafe) static var fixtures: [String: TransportFixture] = [:]
    private nonisolated(unsafe) static var recorded: [String: [(url: String, range: String?, headers: [String: String])]] = [:]
    private nonisolated(unsafe) static var dropped: Set<String> = []
    private let stateLock = NSLock()
    private var stopped = false
    private var fixture = TransportFixture(status: 404)

    static func reset() {
        lock.withLock {
            fixtures = [:]
            recorded = [:]
            dropped = []
        }
    }

    static func set(_ path: String, _ fixture: TransportFixture) {
        lock.withLock { fixtures[path] = fixture }
    }

    static func requests(path: String) -> [(url: String, range: String?, headers: [String: String])] {
        lock.withLock { recorded[path] ?? [] }
    }

    private static func markDropped(path: String?) -> Bool {
        guard let path else { return false }
        return lock.withLock {
            guard !dropped.contains(path) else { return false }
            dropped.insert(path)
            return true
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host || request.url?.host == redirectHost
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let range = request.value(forHTTPHeaderField: "Range")
        let headers = request.allHTTPHeaderFields ?? [:]
        fixture = Self.lock.withLock {
            Self.recorded[url.path, default: []].append((url: url.absoluteString, range: range, headers: headers))
            return Self.fixtures[url.path] ?? TransportFixture(status: 404)
        }
        respond(url: url, range: range)
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true }
    }

    private func respond(url: URL, range: String?) {
        if let redirectTo = fixture.redirectTo {
            // Like a real redirect, the new request carries this one's headers,
            // Authorization included, so the delegate's stripping is what gets
            // tested.
            var newRequest = URLRequest(url: redirectTo)
            newRequest.allHTTPHeaderFields = request.allHTTPHeaderFields
            let redirectResponse = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": redirectTo.absoluteString]
            )!
            client?.urlProtocol(self, wasRedirectedTo: newRequest, redirectResponse: redirectResponse)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        guard fixture.status == 200 || fixture.status == 206 else {
            deliverHeaders(url: url, status: fixture.status, extra: [:])
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let total = fixture.body.count
        if fixture.ranged {
            let start = min(parseRangeStart(range) ?? 0, total)
            let slice = Data(fixture.body.suffix(from: start))
            let end = max(total - 1, start)
            deliverHeaders(url: url, status: 206, extra: [
                "Content-Range": "bytes \(start)-\(end)/\(total)",
                "Content-Length": "\(slice.count)",
            ])
            stream(slice)
        } else {
            deliverHeaders(url: url, status: 200, extra: ["Content-Length": "\(total)"])
            stream(fixture.body)
        }
    }

    private func deliverHeaders(url: URL, status: Int, extra: [String: String]) {
        // Without a MIME type Foundation may wait for body bytes to sniff,
        // stalling the held-body fixture forever.
        let headers = ["Content-Type": "application/octet-stream"].merging(extra) { _, supplied in supplied }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: headers
        )!, cacheStoragePolicy: .notAllowed)
    }

    private func stream(_ data: Data) {
        if fixture.holdBody { return }
        var sent = 0
        var offset = data.startIndex
        while offset < data.endIndex {
            if stateLock.withLock({ stopped }) { return }
            let end = data.index(offset, offsetBy: fixture.chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            let chunk = Data(data[offset..<end])
            client?.urlProtocol(self, didLoad: chunk)
            sent += chunk.count
            offset = end
            if let dropAfter = fixture.dropAfterBytes, sent >= dropAfter,
               Self.markDropped(path: request.url?.path) {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class InterruptFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
