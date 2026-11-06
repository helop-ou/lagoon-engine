import CoreVideo
import Foundation
import Testing
@testable import LagoonEngine

/// A read that fails on the network reaches libavformat as `AVERROR(EIO)`.
/// What the network said is recorded beside it, so the engine's failure can
/// tell a refused credential or a lost network from a broken file.
@Suite("Transport failures", .serialized)
struct TransportFailureTests {
    @Test func theNetworksAnswerIsKeptInItsOwnCodes() {
        #expect(PlaybackTransportFailure(FFmpegTransportError.httpStatus(401)) == .httpStatus(401))
        #expect(PlaybackTransportFailure(PlaybackCacheError.serverStatus(503, retryAfter: 2)) == .httpStatus(503))
        #expect(PlaybackTransportFailure(URLError(.notConnectedToInternet)) == .urlError(URLError.notConnectedToInternet.rawValue))
        #expect(PlaybackTransportFailure(URLError(.serverCertificateUntrusted)) == .urlError(URLError.serverCertificateUntrusted.rawValue))
        #expect(PlaybackTransportFailure(FFmpegTransportError.timeout) == .urlError(URLError.timedOut.rawValue))
    }

    @Test func whatTheNetworkDidNotSayIsNotKept() {
        let notTheNetwork: [Error] = [
            URLError(.cancelled),
            FFmpegTransportError.closed,
            FFmpegTransportError.interrupted,
            FFmpegTransportError.invalidResponse,
            PlaybackCacheError.cancelled,
            PlaybackCacheError.rangeUnsupported,
            PlaybackCacheError.storageUnavailable,
        ]
        for error in notTheNetwork {
            #expect(PlaybackTransportFailure(error) == nil)
        }
    }

    @Test func theRecorderKeepsTheLatestAnswerUntilReset() {
        let recorder = TransportFailureRecorder()
        recorder.record(FFmpegTransportError.httpStatus(503))
        recorder.record(URLError(.cancelled))
        #expect(recorder.lastFailure == .httpStatus(503))
        recorder.record(URLError(.notConnectedToInternet))
        #expect(recorder.lastFailure == .urlError(URLError.notConnectedToInternet.rawValue))
        recorder.reset()
        #expect(recorder.lastFailure == nil)
    }

    /// A refused credential is not a server that ignores `Range`, and asking
    /// again gets the same answer.
    @Test func aRefusedRangeKeepsItsStatusAndIsNotRetried() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatusStub.self]
        let loader = URLSessionPlaybackRangeLoader(configuration: configuration)
        StatusStub.reset()
        let url = try #require(URL(string: "https://\(StatusStub.host)/401"))

        #expect(throws: PlaybackCacheError.serverStatus(401)) {
            _ = try loader.load(url: url, range: PlaybackByteRange(0, 1_024), priority: URLSessionTask.highPriority)
        }
        #expect(StatusStub.requestCount(path: "/401") == 1)
    }

    @Test func aDemuxerThatCouldNotOpenSaysWhatTheServerAnswered() throws {
        let refused = try Self.session(loader: FailingLoader(error: PlaybackCacheError.serverStatus(401)))
        defer { refused.remove() }
        let demuxer = FFmpegDemuxer()
        defer { demuxer.close() }

        #expect(throws: DemuxError.self) {
            try demuxer.open(url: refused.url.absoluteString, cacheSession: refused.session,
                             recommendedPixelBufferAttributes: CVPixelBufferAttributes())
        }
        #expect(demuxer.lastTransportFailure == .httpStatus(401))

        // The next open starts clean: a file that is not media failed in the
        // container, not on the network.
        let garbage = try Self.session(loader: ZeroLoader())
        defer { garbage.remove() }
        #expect(throws: DemuxError.self) {
            try demuxer.open(url: garbage.url.absoluteString, cacheSession: garbage.session,
                             recommendedPixelBufferAttributes: CVPixelBufferAttributes())
        }
        #expect(demuxer.lastTransportFailure == nil)
    }

    /// A failed open that never reached the network says nothing about it,
    /// whatever the previous one met.
    @Test func eachOpenForgetsThePreviousOnesFailure() throws {
        let refused = try Self.session(loader: FailingLoader(error: PlaybackCacheError.serverStatus(401)))
        defer { refused.remove() }
        let local = try Self.session(loader: FailingLoader(error: PlaybackCacheError.storageUnavailable))
        defer { local.remove() }
        let demuxer = FFmpegDemuxer()
        defer { demuxer.close() }

        for source in [refused, local] {
            #expect(throws: DemuxError.self) {
                try demuxer.open(url: source.url.absoluteString, cacheSession: source.session,
                                 recommendedPixelBufferAttributes: CVPixelBufferAttributes())
            }
        }
        #expect(demuxer.lastTransportFailure == nil)
    }

    @Test func aReadThatSucceedsAgainClearsTheFailure() throws {
        let recorder = TransportFailureRecorder()
        let source = FlakyByteSource()
        let io = try FFmpegCachedIO(source: source, failures: recorder)
        defer { io.close() }
        let context = try #require(io.context).pointee
        let read = try #require(context.read_packet)
        var buffer = [UInt8](repeating: 0, count: 8)

        #expect(buffer.withUnsafeMutableBufferPointer { read(context.opaque, $0.baseAddress, 8) } == -5)
        #expect(recorder.lastFailure == .httpStatus(503))
        #expect(buffer.withUnsafeMutableBufferPointer { read(context.opaque, $0.baseAddress, 8) } == 8)
        #expect(recorder.lastFailure == nil)
    }

    private struct CachedSource {
        let url: URL
        let scope: PlaybackCacheScope
        let session: PlaybackCacheSession

        func remove() { scope.cancelAndRemove() }
    }

    private static func session(loader: PlaybackRangeLoading) throws -> CachedSource {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = try #require(URL(string: "https://transport-failure.invalid/\(UUID().uuidString).mkv"))
        let scope = try PlaybackCacheScope(itemID: url.lastPathComponent, sourceURL: url, expectedLength: 1_048_576,
                                           directory: directory, byteLimit: 1_048_576, requestSize: 65_536,
                                           loader: loader)
        let session = PlaybackCacheSession(itemID: url.lastPathComponent, sourceURL: url, storage: .direct(scope))
        return CachedSource(url: url, scope: scope, session: session)
    }
}

private nonisolated final class FailingLoader: PlaybackRangeLoading, @unchecked Sendable {
    private let error: PlaybackCacheError

    init(error: PlaybackCacheError) {
        self.error = error
    }

    func load(url: URL, range: PlaybackByteRange, priority: Float) throws -> PlaybackRangeResponse {
        throw error
    }

    func cancelAll() {}
}

private nonisolated final class ZeroLoader: PlaybackRangeLoading, @unchecked Sendable {
    func load(url: URL, range: PlaybackByteRange, priority: Float) throws -> PlaybackRangeResponse {
        let count = Int(max(0, min(range.upperBound, 1_048_576) - range.lowerBound))
        return PlaybackRangeResponse(data: Data(repeating: 0, count: count), offset: range.lowerBound, totalLength: 1_048_576)
    }

    func cancelAll() {}
}

/// Fails its first read with a 503, then serves zeros.
private nonisolated final class FlakyByteSource: FFmpegByteSource {
    let requestSize: Int64 = 65_536
    let contentLength: Int64? = 65_536
    private var failed = false

    func read(offset: Int64, length: Int, priority: Float) throws -> Data {
        guard failed else {
            failed = true
            throw FFmpegTransportError.httpStatus(503)
        }
        return Data(repeating: 0, count: length)
    }

    func setTimelineAnchor(byteOffset: Int64, timeFraction: Double) {}
}

/// Answers every request with the status its path names, and no body.
private nonisolated final class StatusStub: URLProtocol, @unchecked Sendable {
    static let host = "transport-status.test"
    private static let lock = NSLock()
    private nonisolated(unsafe) static var counts: [String: Int] = [:]

    static func reset() {
        lock.withLock { counts = [:] }
    }

    static func requestCount(path: String) -> Int {
        lock.withLock { counts[path] ?? 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let status = Int(url.lastPathComponent) else { return }
        Self.lock.withLock { Self.counts[url.path, default: 0] += 1 }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/plain"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
