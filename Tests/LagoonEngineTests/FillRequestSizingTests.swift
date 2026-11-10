import Foundation
import Testing
@testable import LagoonEngine

/// A fill request pays the wait for its first byte once, so on a distant link
/// it grows until that wait is a small share of the transfer. The meter
/// leaves the wait out, so a host does not read latency as a slow link.
@Suite("Fill request sizing", .serialized)
struct FillRequestSizingTests {
    private static let kibibyte: Int64 = 1_024

    @Test func theWaitForTheFirstByteIsNotCountedAsTransfer() throws {
        let loader = DistantLoader(payload: Data(repeating: 0, count: 1_024 * 1_024), firstByteDelay: 1)
        let scope = try Self.scope(loader: loader, requestSize: 1_024 * 1_024)
        defer { scope.cancelAndRemove() }
        _ = try scope.read(offset: 0, length: 4_096)
        // Counting the wait, 1 MiB over 1 s is about 1 MB/s. Four times that
        // leaves a loaded CI runner 260 ms for the transfer itself.
        let rate = try #require(scope.metrics.networkBytesPerSecond)
        #expect(rate > 4_000_000, "rate \(rate)")
    }

    @Test func fillRequestsGrowOnADistantLinkAndMissesDoNot() async throws {
        let loader = DistantLoader(payload: Data(repeating: 0, count: 4 * 1_024 * 1_024), firstByteDelay: 0.05)
        let scope = try Self.scope(
            loader: loader,
            requestSize: 64 * Self.kibibyte,
            maximumFillRequestSize: 512 * Self.kibibyte
        )
        defer { scope.cancelAndRemove() }

        #expect((await scope.prefetchNextChunk()).advanced)
        #expect(loader.requestedRanges.last?.count == 64 * Self.kibibyte)
        #expect((await scope.prefetchNextChunk()).advanced)
        #expect(loader.requestedRanges.last?.count == 512 * Self.kibibyte)

        _ = try scope.read(offset: 3 * 1_024 * 1_024, length: 4_096)
        #expect(loader.requestedRanges.last == PlaybackByteRange(3 * 1_024 * 1_024, 3 * 1_024 * 1_024 + 64 * Self.kibibyte))
    }

    @Test func aFillWithoutAMaximumKeepsTheMissSize() async throws {
        let loader = DistantLoader(payload: Data(repeating: 0, count: 1_024 * 1_024), firstByteDelay: 0.05)
        let scope = try Self.scope(loader: loader, requestSize: 64 * Self.kibibyte)
        defer { scope.cancelAndRemove() }

        #expect((await scope.prefetchNextChunk()).advanced)
        #expect((await scope.prefetchNextChunk()).advanced)
        #expect(loader.requestedRanges.map(\.count) == [64 * Self.kibibyte, 64 * Self.kibibyte])
    }

    @Test func aLimitHoldsBackARequestTheLinkWouldGrow() async throws {
        let loader = DistantLoader(payload: Data(repeating: 0, count: 4 * 1_024 * 1_024), firstByteDelay: 0.05)
        let scope = try Self.scope(
            loader: loader,
            requestSize: 64 * Self.kibibyte,
            maximumFillRequestSize: 512 * Self.kibibyte
        )
        defer { scope.cancelAndRemove() }

        #expect((await scope.prefetchNextChunk()).advanced)
        #expect((await scope.prefetchNextChunk(limit: 100 * Self.kibibyte)).advanced)
        #expect(loader.requestedRanges.last?.count == 100 * Self.kibibyte)
    }

    @Test func theLoaderReportsTheFirstByteOnceAndNotForARefusal() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirstByteURLProtocol.self]
        let loader = URLSessionPlaybackRangeLoader(configuration: configuration)
        defer { loader.cancelAll() }
        let calls = FirstByteCalls()

        let response = try loader.load(
            url: URL(string: "https://first-byte.test/partial.mkv")!,
            range: PlaybackByteRange(0, 16),
            priority: URLSessionTask.highPriority,
            firstByte: { calls.record() }
        )
        #expect(response.data.count == 16)
        #expect(calls.count == 1)

        #expect(throws: PlaybackCacheError.serverStatus(404)) {
            try loader.load(
                url: URL(string: "https://first-byte.test/missing.mkv")!,
                range: PlaybackByteRange(0, 16),
                priority: URLSessionTask.highPriority,
                firstByte: { calls.record() }
            )
        }
        #expect(calls.count == 1)
    }

    private static func scope(
        loader: PlaybackRangeLoading,
        requestSize: Int64,
        maximumFillRequestSize: Int64? = nil
    ) throws -> PlaybackCacheScope {
        try PlaybackCacheScope(
            itemID: "sizing",
            sourceURL: URL(string: "https://media.test/film.mkv")!,
            expectedLength: nil,
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            byteLimit: 64 * 1_024 * 1_024,
            requestSize: requestSize,
            maximumFillRequestSize: maximumFillRequestSize,
            loader: loader
        )
    }
}

/// Answers after `firstByteDelay`, then delivers the whole range at once.
private nonisolated final class DistantLoader: PlaybackRangeLoading, @unchecked Sendable {
    private let payload: Data
    private let firstByteDelay: TimeInterval
    private let lock = NSLock()
    private var ranges: [PlaybackByteRange] = []

    init(payload: Data, firstByteDelay: TimeInterval) {
        self.payload = payload
        self.firstByteDelay = firstByteDelay
    }

    var requestedRanges: [PlaybackByteRange] {
        lock.withLock { ranges }
    }

    func load(url: URL, range: PlaybackByteRange, priority: Float) throws -> PlaybackRangeResponse {
        try load(url: url, range: range, priority: priority, firstByte: {})
    }

    func load(
        url: URL,
        range: PlaybackByteRange,
        priority: Float,
        firstByte: @escaping @Sendable () -> Void
    ) throws -> PlaybackRangeResponse {
        Thread.sleep(forTimeInterval: firstByteDelay)
        firstByte()
        lock.withLock { ranges.append(range) }
        let lower = min(Int(range.lowerBound), payload.count)
        let upper = min(Int(range.upperBound), payload.count)
        return PlaybackRangeResponse(
            data: payload.subdata(in: lower..<upper),
            offset: Int64(lower),
            totalLength: Int64(payload.count)
        )
    }

    func cancelAll() {}
}

private nonisolated final class FirstByteCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int { lock.withLock { calls } }

    func record() {
        lock.withLock { calls += 1 }
    }
}

/// A 206 for `partial.mkv` and a 404 for anything else.
private final class FirstByteURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "first-byte.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let found = url.lastPathComponent == "partial.mkv"
        let response = HTTPURLResponse(
            url: url,
            statusCode: found ? 206 : 404,
            httpVersion: "HTTP/1.1",
            headerFields: found ? ["Content-Range": "bytes 0-15/64", "Content-Length": "16"] : [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if found {
            client?.urlProtocol(self, didLoad: Data(repeating: 7, count: 16))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
