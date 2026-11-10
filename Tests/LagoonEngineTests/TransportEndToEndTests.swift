import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import LagoonEngine

/// The real cache, loader, fill and HLS transport against a server behind a
/// modelled link, so a change to any of them is checked the way a viewer on
/// a slow or faulty connection meets it.
///
/// Every blocking read runs on its own thread. On the cooperative pool it held
/// a thread for seconds, and other suites' tasks missed their timeouts.
@Suite("Transport end to end", .serialized)
struct TransportEndToEndTests {
    private static let mebibyte = 1_024 * 1_024
    /// 100 Mbps.
    private static let fastLink: Double = 12_500_000

    // MARK: - Direct play through the cache

    /// A server 100 ms away on a 100 Mbps link. Fixed 1 MiB requests spent
    /// about as long waiting for the first byte as transferring, so the fill
    /// carried under half of what the link delivered. Measured against that
    /// fixed fill under the same load, since a loaded CI runner slows both.
    @Test func aDistantLinkFillsNearItsRate() async throws {
        let fixed = try #require(await Self.sizedFillRate(growing: false))
        let sized = try #require(await Self.sizedFillRate(growing: true))
        #expect(sized > 1.3 * fixed, "filled at \(Int(sized)) B/s against \(Int(fixed)) fixed")
    }

    /// The rate of the second fill request, the one sized from the first.
    private static func sizedFillRate(growing: Bool) async throws -> Double? {
        SimulatedOrigin.reset(link: SimulatedLink(roundTrip: 0.1, bytesPerSecond: Self.fastLink))
        let body = Self.pattern(count: 32 * Self.mebibyte)
        SimulatedOrigin.serve("/distant.mkv", body: body)
        let scope = try Self.scope(
            path: "/distant.mkv", length: body.count, requestSize: Int64(Self.mebibyte),
            maximumFillRequestSize: growing ? PlaybackFillPolicy.maximumRequestBytes : Int64(Self.mebibyte)
        )
        defer { scope.cancelAndRemove() }
        // It is timed by its own request: under the parallel suites, the fill's
        // utility task can wait seconds to be scheduled at all.
        guard (await scope.prefetchNextChunk()).advanced,
              case .fetched(let bytes, let seconds) = await scope.prefetchNextChunk() else {
            Issue.record("The sized request did not fetch")
            return nil
        }
        return Double(bytes) / seconds
    }

    /// Bytes still arriving are not progress enough. The read gives up on the
    /// connection and asks again, instead of waiting for the trickle.
    @Test func aTricklingMissIsAskedAgainAndThenFails() async throws {
        SimulatedOrigin.reset()
        SimulatedOrigin.serve("/trickle.mkv", body: Self.pattern(count: Self.mebibyte), fault: .trickle(bytesPerSecond: 16_000))
        let loader = Self.loader()
        loader.stallTimeout = 0.3
        loader.retryPolicy = NetworkRetryPolicy(budget: 0.5, delays: [0.05])
        let scope = try Self.scope(path: "/trickle.mkv", length: Self.mebibyte, requestSize: 256 * 1_024, loader: loader)
        defer { scope.cancelAndRemove() }

        // Timed on the reading thread: the test itself can wait seconds to be
        // resumed while the other suites hold the cooperative pool.
        let result = await Self.bounded(seconds: 5, cancelling: scope) {
            let started = ProcessInfo.processInfo.systemUptime
            let read = Result { try scope.read(offset: 0, length: 4_096) }
            return (read, ProcessInfo.processInfo.systemUptime - started)
        }
        let (read, elapsed) = try result.get()
        #expect(throws: URLError(.timedOut)) { try read.get() }
        #expect(elapsed < 3, "gave up after \(elapsed) s")
        #expect(SimulatedOrigin.requests(path: "/trickle.mkv").count >= 2)
    }

    /// Ten times the floor, so a slow link that keeps up is left alone.
    @Test func aSlowLinkAboveTheFloorIsNotGivenUpOn() async throws {
        SimulatedOrigin.reset(link: SimulatedLink(bytesPerSecond: 2_000_000))
        let body = Self.pattern(count: Self.mebibyte)
        SimulatedOrigin.serve("/slow.mkv", body: body)
        let loader = Self.loader()
        loader.stallTimeout = 0.3
        let scope = try Self.scope(path: "/slow.mkv", length: body.count, requestSize: Int64(Self.mebibyte), loader: loader)
        defer { scope.cancelAndRemove() }

        let result = await Self.bounded(seconds: 5, cancelling: scope) { try scope.read(offset: 0, length: Self.mebibyte) }
        #expect(try result.get() == body)
        #expect(SimulatedOrigin.requests(path: "/slow.mkv").count == 1)
    }

    @Test func aConnectionLostMidBodyStillDemuxesToTheEnd() async throws {
        SimulatedOrigin.reset(link: SimulatedLink(roundTrip: 0.01))
        let film = try Self.fixture()
        SimulatedOrigin.serve("/clean.mkv", body: film)
        SimulatedOrigin.serve("/dropped.mkv", body: film, fault: .dropOnce(atByte: 100_000))

        let clean = try await Self.demux(path: "/clean.mkv", length: film.count)
        let dropped = try await Self.demux(path: "/dropped.mkv", length: film.count)
        #expect(clean.ending == "eof")
        #expect(dropped.ending == "eof")
        #expect(dropped.packets == clean.packets)
        // The next read asks from the byte the connection was lost at.
        #expect(SimulatedOrigin.requests(path: "/dropped.mkv").contains { $0?.hasPrefix("bytes=100000-") == true })
    }

    /// Lost after the headers and before any of the body: an empty range
    /// would read as the end of the file.
    @Test func aConnectionLostBeforeItsBodyIsNotTheEndOfTheFile() async throws {
        SimulatedOrigin.reset(link: SimulatedLink(roundTrip: 0.01))
        let film = try Self.fixture()
        SimulatedOrigin.serve("/clean.mkv", body: film)
        SimulatedOrigin.serve("/headers-only.mkv", body: film, fault: .dropAfterHeadersOnce(fromByte: 200_000))

        let clean = try await Self.demux(path: "/clean.mkv", length: film.count)
        let dropped = try await Self.demux(path: "/headers-only.mkv", length: film.count)
        #expect(dropped.ending == "eof")
        #expect(dropped.packets == clean.packets)
        #expect(SimulatedOrigin.requests(path: "/headers-only.mkv").count > SimulatedOrigin.requests(path: "/clean.mkv").count)
    }

    @Test func aRefusedCredentialFailsTheOpenOnceWithItsStatus() async throws {
        SimulatedOrigin.reset(link: SimulatedLink(roundTrip: 0.01))
        SimulatedOrigin.serve("/refused.mkv", body: Data(), fault: .status(401))
        let scope = try Self.scope(path: "/refused.mkv", length: Self.mebibyte, requestSize: 64 * 1_024)
        defer { scope.cancelAndRemove() }
        let session = PlaybackCacheSession(itemID: "refused", sourceURL: scope.sourceURL, storage: .direct(scope))

        let (opened, failure) = try await Self.offPool {
            let demuxer = FFmpegDemuxer()
            defer { demuxer.close() }
            let opened = (try? demuxer.open(url: scope.sourceURL.absoluteString, cacheSession: session,
                                            recommendedPixelBufferAttributes: CVPixelBufferAttributes())) != nil
            return (opened, demuxer.lastTransportFailure)
        }
        #expect(!opened)
        #expect(failure == .httpStatus(401))
        #expect(SimulatedOrigin.requests(path: "/refused.mkv").count == 1)
    }

    // MARK: - HLS through the network transport

    /// A segment lost mid-body and another refused once with a 503 are
    /// ridden out: every packet a local open reads still arrives.
    @Test func anHLSStreamRidesOutADropAndAServerErrorToTheEnd() async throws {
        SimulatedOrigin.reset(link: SimulatedLink(roundTrip: 0.02))
        let directory = try #require(Bundle.module.url(forResource: "playlist", withExtension: "m3u8", subdirectory: "HLSResume"))
            .deletingLastPathComponent()
        for file in try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) {
            let fault: SimulatedFault? = switch file {
            case "segment3.ts": .dropOnce(atByte: 10_000)
            case "segment7.ts": .statusFirst(503, times: 1)
            default: nil
            }
            SimulatedOrigin.serve("/hls/\(file)", body: try Data(contentsOf: directory.appendingPathComponent(file)), fault: fault)
        }

        let local = directory.appendingPathComponent("playlist.m3u8").path(percentEncoded: false)
        let expected = try await Self.offPool {
            let demuxer = FFmpegDemuxer()
            defer { demuxer.close() }
            try demuxer.open(url: local, recommendedPixelBufferAttributes: CVPixelBufferAttributes())
            return Self.readAll(demuxer)
        }
        let streamed = try await Self.offPool {
            let demuxer = FFmpegDemuxer()
            demuxer.transportSessionConfiguration = SimulatedOrigin.configuration()
            defer { demuxer.close() }
            try demuxer.open(url: SimulatedOrigin.url("/hls/playlist.m3u8").absoluteString,
                             recommendedPixelBufferAttributes: CVPixelBufferAttributes())
            return Self.readAll(demuxer)
        }

        #expect(streamed.ending == "eof")
        #expect(streamed.packets == expected.packets)
        #expect(SimulatedOrigin.requests(path: "/hls/segment3.ts").count == 2)
        #expect(SimulatedOrigin.requests(path: "/hls/segment7.ts").count == 2)
    }

    /// Without a byte cache the demux queues are the whole cushion, so how far
    /// ahead they reach, and what stopped them, is published.
    @MainActor
    @Test func anHLSStreamReportsHowFarAheadItIsRead() async throws {
        SimulatedOrigin.reset(link: SimulatedLink(roundTrip: 0.02))
        let directory = try #require(Bundle.module.url(forResource: "playlist", withExtension: "m3u8", subdirectory: "HLSResume"))
            .deletingLastPathComponent()
        for file in try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) {
            SimulatedOrigin.serve("/hls/\(file)", body: try Data(contentsOf: directory.appendingPathComponent(file)))
        }
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        engine.transportSessionConfiguration = SimulatedOrigin.configuration()
        var started = false
        engine.onPlaybackStarted = { started = true }
        engine.prepare(url: SimulatedOrigin.url("/hls/playlist.m3u8"), delivery: .segmentedManifest,
                       startSeconds: 0, initialAudioOrdinal: nil)
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        engine.play()
        // Generous: a CI runner running the other suites took over 20 s to start.
        let deadline = ContinuousClock.now + .seconds(60)
        while !(started && engine.demuxReadAheadLimit != nil), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(started)
        #expect(engine.demuxReadAheadLimit != nil)
        #expect(engine.demuxReadAheadSeconds > 1)
        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }

    // MARK: - Helpers

    private static func loader() -> URLSessionPlaybackRangeLoader {
        URLSessionPlaybackRangeLoader(configuration: SimulatedOrigin.configuration())
    }

    private static func scope(
        path: String,
        length: Int,
        requestSize: Int64,
        maximumFillRequestSize: Int64 = PlaybackFillPolicy.maximumRequestBytes,
        loader: URLSessionPlaybackRangeLoader? = nil
    ) throws -> PlaybackCacheScope {
        try PlaybackCacheScope(
            itemID: path,
            sourceURL: SimulatedOrigin.url(path),
            expectedLength: Int64(length),
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            byteLimit: Int64(length),
            requestSize: requestSize,
            maximumFillRequestSize: maximumFillRequestSize,
            loader: loader ?? Self.loader()
        )
    }

    private static func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "no-cues", withExtension: "mkv", subdirectory: "UnindexedSeek"))
        return try Data(contentsOf: url)
    }

    private struct Tally: Equatable, Sendable {
        var packets = 0
        var ending = "limit"
    }

    /// Opens the path through the cache, as direct play does, and reads it out.
    private static func demux(path: String, length: Int) async throws -> Tally {
        let scope = try scope(path: path, length: length, requestSize: 64 * 1_024)
        defer { scope.cancelAndRemove() }
        let session = PlaybackCacheSession(itemID: path, sourceURL: scope.sourceURL, storage: .direct(scope))
        return try await offPool {
            let demuxer = FFmpegDemuxer()
            defer { demuxer.close() }
            try demuxer.open(url: scope.sourceURL.absoluteString, cacheSession: session,
                             recommendedPixelBufferAttributes: CVPixelBufferAttributes())
            return readAll(demuxer)
        }
    }

    private static func readAll(_ demuxer: FFmpegDemuxer) -> Tally {
        var tally = Tally()
        for _ in 0..<50_000 {
            switch demuxer.readNext() {
            case .video, .videoPacket:
                tally.packets += 1
            case .audio(let buffers, _):
                tally.packets += buffers.count
            case .endOfFile:
                tally.ending = "eof"
                return tally
            case .failed(let message):
                tally.ending = "failed: \(message)"
                return tally
            case .subtitle, .skipped:
                continue
            }
        }
        return tally
    }

    private static func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread { continuation.resume(with: Result { try body() }) }.start()
        }
    }

    /// Cancels the scope if the read outlasts `seconds`, so a regression
    /// fails instead of hanging the suite.
    private static func bounded<T: Sendable>(
        seconds: TimeInterval,
        cancelling scope: PlaybackCacheScope,
        _ body: @escaping @Sendable () throws -> T
    ) async -> Result<T, Error> {
        let watchdog = Task {
            try await Task.sleep(for: .seconds(seconds))
            scope.cancelAndRemove()
            Issue.record("The read was still waiting after \(seconds) s")
        }
        defer { watchdog.cancel() }
        do {
            return .success(try await offPool(body))
        } catch {
            return .failure(error)
        }
    }

    /// A block that never lines up with a request, repeated.
    private static func pattern(count: Int) -> Data {
        let block = Data((0..<65_521).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var data = Data(capacity: count)
        while data.count < count {
            data.append(block.prefix(count - data.count))
        }
        return data
    }
}
