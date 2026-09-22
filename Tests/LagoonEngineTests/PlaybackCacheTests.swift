import Foundation
import Testing
@testable import LagoonEngine

@Suite("Playback cache", .serialized)
struct PlaybackCacheTests {
    @Test func discMetadataDoesNotAmplifyItsReadBudgetIntoStreamingReadAhead() throws {
        let loader = PlaybackCacheLoaderStub(payload: Data(repeating: 0, count: 2 * 1_024 * 1_024))
        let scope = try PlaybackCacheScope(
            itemID: "disc", sourceURL: URL(string: "https://media.test/disc.iso")!,
            expectedLength: nil, directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            byteLimit: 2 * 1_024 * 1_024, requestSize: 1_024 * 1_024, loader: loader
        )
        defer { scope.cancelAndRemove() }
        let metadata = PlaybackCacheDiscSource(source: scope)
        #expect(try metadata.read(at: 0, count: 2_048).count == 2_048)
        #expect(loader.requestedRanges == [PlaybackByteRange(0, 2_048)])
        #expect(try metadata.read(at: 0, count: 2_048).count == 2_048)
        #expect(loader.requestCount == 1)
        #expect(throws: PlaybackCacheError.invalidResponse) {
            try scope.read(offset: Int64.max, length: 2)
        }
        #expect(loader.requestCount == 1)
        // Ordinary playback retains streaming read-ahead after mount.
        #expect(try scope.read(offset: 4_096, length: 2_048).count == 2_048)
        #expect(loader.requestedRanges.last == PlaybackByteRange(4_096, 4_096 + 1_024 * 1_024))
    }

    @Test func directFilesUseCachedTransportWhileReleaseHLSStaysNative() {
        let suiteName = "PlaybackCacheTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(PlaybackBufferPolicy.customIOEnabled(for: .stableFile, defaults: defaults))
        #expect(PlaybackBufferPolicy.customIOEnabled(for: .stableFile, defaults: defaults))
        #expect(!PlaybackBufferPolicy.customIOEnabled(for: .segmentedManifest, defaults: defaults))
        defaults.set(true, forKey: "debug.experimentalPlaybackCache")
        #if DEBUG
        #expect(PlaybackBufferPolicy.customIOEnabled(for: .segmentedManifest, defaults: defaults))
        #else
        #expect(!PlaybackBufferPolicy.customIOEnabled(for: .segmentedManifest, defaults: defaults))
        #endif
    }

    @Test func aCompleteFilePlaysWithoutTheSessionUnlessItIsADisc() {
        let suiteName = "PlaybackCacheTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Streaming: the session is the transport.
        #expect(PlaybackBufferPolicy.engineUsesCacheSession(
            playsFromCompleteFile: false, disc: false, delivery: .stableFile, defaults: defaults))
        // A complete ordinary file plays straight from disk.
        #expect(!PlaybackBufferPolicy.engineUsesCacheSession(
            playsFromCompleteFile: true, disc: false, delivery: .stableFile, defaults: defaults))
        // A complete disc image still needs the session: the UDF reader
        // mounts it through the session's byte source, and without one the
        // raw image reached libavformat and fell to a server remux.
        #expect(PlaybackBufferPolicy.engineUsesCacheSession(
            playsFromCompleteFile: true, disc: true, delivery: .stableFile, defaults: defaults))
        // A transcode never gets the session in Release, disc or not.
        #expect(!PlaybackBufferPolicy.engineUsesCacheSession(
            playsFromCompleteFile: false, disc: true, delivery: .segmentedManifest, defaults: defaults))
    }

    @Test func adaptiveCapacityPreservesFreeSpaceAndHonorsMaximum() {
        let mebibyte: Int64 = 1_024 * 1_024

        #expect(PlaybackCacheCoordinator.recommendedByteLimit(availableBytes: nil) == 2_048 * mebibyte)
        #expect(PlaybackCacheCoordinator.recommendedByteLimit(availableBytes: 319 * mebibyte) == 0)
        #expect(PlaybackCacheCoordinator.recommendedByteLimit(availableBytes: 320 * mebibyte) == 64 * mebibyte)
        #expect(PlaybackCacheCoordinator.recommendedByteLimit(availableBytes: 1_024 * mebibyte) == 384 * mebibyte)
        #expect(PlaybackCacheCoordinator.recommendedByteLimit(availableBytes: 4_096 * mebibyte) == 1_920 * mebibyte)
    }

    @Test func rangeLoaderDoesNotRetainItselfThroughItsSessionDelegate() {
        weak var releasedLoader: URLSessionPlaybackRangeLoader?
        do {
            let loader = URLSessionPlaybackRangeLoader()
            releasedLoader = loader
            #expect(releasedLoader != nil)
        }
        #expect(releasedLoader == nil)
    }

    @Test func rangesMergeOverlapAndAdjacencyWithoutDoubleCounting() {
        var ranges = PlaybackByteRangeSet()
        #expect(ranges.insert(PlaybackByteRange(10, 20)) == 10)
        #expect(ranges.insert(PlaybackByteRange(20, 30)) == 10)
        #expect(ranges.insert(PlaybackByteRange(15, 25)) == 0)
        #expect(ranges.ranges == [PlaybackByteRange(10, 30)])
        #expect(ranges.byteCount == 20)
        #expect(ranges.contiguousUpperBound == 0)
        #expect(ranges.contains(PlaybackByteRange(12, 28)))
        #expect(!ranges.contains(PlaybackByteRange(0, 12)))

        #expect(ranges.insert(PlaybackByteRange(0, 10)) == 10)
        #expect(ranges.contiguousUpperBound == 30)
    }

    @Test func removingAnIntervalSplitsTheIslandItLandsInside() {
        var ranges = PlaybackByteRangeSet()
        ranges.insert(PlaybackByteRange(0, 100))

        #expect(ranges.remove(PlaybackByteRange(40, 60)) == 20)
        #expect(ranges.ranges == [PlaybackByteRange(0, 40), PlaybackByteRange(60, 100)])
        #expect(!ranges.contains(PlaybackByteRange(50, 55)))
        #expect(ranges.contiguousUpperBound == 40)

        // Overlapping the edges of two islands only takes what they hold.
        #expect(ranges.remove(PlaybackByteRange(30, 70)) == 20)
        #expect(ranges.ranges == [PlaybackByteRange(0, 30), PlaybackByteRange(70, 100)])
        #expect(ranges.remove(PlaybackByteRange(200, 300)) == 0)
        #expect(ranges.byteCount == 60)
    }

    @Test func boundedPrefetchPublishesProgressAndOnlyCompletesAWholeFile() async throws {
        let payload = Data((0..<96).map(UInt8.init))
        let loader = PlaybackCacheLoaderStub(payload: payload)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scope = try PlaybackCacheScope(
            itemID: "episode-buffered",
            sourceURL: URL(string: "https://media.test/video.mkv")!,
            expectedLength: Int64(payload.count),
            directory: directory,
            byteLimit: Int64(payload.count),
            requestSize: 32,
            loader: loader
        )
        defer { scope.cancelAndRemove() }

        #expect(scope.metrics.bufferedFraction == 0)
        #expect(!scope.metrics.isWindowed)
        #expect(scope.completeFileURL == nil)
        #expect((await scope.prefetchNextChunk()).advanced)
        #expect(scope.metrics.contiguousCachedBytes == 32)
        #expect(scope.metrics.bufferedFraction == 1.0 / 3.0)
        #expect(scope.completeFileURL == nil)
        #expect((await scope.prefetchNextChunk()).advanced)
        #expect((await scope.prefetchNextChunk()).advanced)
        #expect(scope.metrics.bufferedFraction == 1)
        #expect(scope.completeFileURL == scope.fileURL)
        #expect(await scope.prefetchNextChunk() == .exhausted)
    }

    @Test func seekMovesProactiveFillToPlayheadThenWrapsBackWithoutLosingPrefix() async throws {
        let payload = Data((0..<256).map(UInt8.init))
        let loader = PlaybackCacheLoaderStub(payload: payload)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scope = try PlaybackCacheScope(
            itemID: "movie-seek-buffer",
            sourceURL: URL(string: "https://media.test/movie.mkv")!,
            expectedLength: Int64(payload.count),
            directory: directory,
            byteLimit: Int64(payload.count),
            requestSize: 32,
            loader: loader
        )
        defer { scope.cancelAndRemove() }

        // Establish the ordinary byte-zero prefix, then model FFmpeg's real
        // high-priority range read after a seek to the middle of the file.
        #expect((await scope.prefetchNextChunk()).advanced)
        #expect(try scope.read(offset: 128, length: 8) == payload.subdata(in: 128..<136))
        #expect(loader.requestedRanges == [
            PlaybackByteRange(0, 32),
            PlaybackByteRange(128, 160),
        ])

        // Proactive traffic must continue after the seek's cached island,
        // not resume at byte 32. Both islands remain visible to the UI.
        #expect((await scope.prefetchNextChunk()).advanced)
        #expect(loader.requestedRanges.last == PlaybackByteRange(160, 192))
        #expect(scope.metrics.cachedByteRanges == [
            PlaybackByteRange(0, 32),
            PlaybackByteRange(128, 192),
        ])
        #expect(scope.metrics.bufferedRanges == [
            PlaybackBufferedRange(lowerFraction: 0, upperFraction: 0.125),
            PlaybackBufferedRange(lowerFraction: 0.5, upperFraction: 0.75),
        ])
        #expect(scope.metrics.playheadPrefetchCount == 1)

        // Finish playhead-to-EOF first, then verify the scheduler wraps back
        // to the earliest hole and can still promote a complete sparse file.
        #expect((await scope.prefetchNextChunk()).advanced)
        #expect(loader.requestedRanges.last == PlaybackByteRange(192, 224))
        #expect((await scope.prefetchNextChunk()).advanced)
        #expect(loader.requestedRanges.last == PlaybackByteRange(224, 256))
        #expect((await scope.prefetchNextChunk()).advanced)
        #expect(loader.requestedRanges.last == PlaybackByteRange(32, 64))
        while (await scope.prefetchNextChunk()).advanced {}

        #expect(scope.metrics.cachedByteRanges == [PlaybackByteRange(0, 256)])
        #expect(scope.metrics.bufferedFraction == 1)
        #expect(scope.completeFileURL == scope.fileURL)
    }

    @Test func timelineAnchorMapsSparseByteRangesThroughTheActualPlayhead() {
        let metrics = PlaybackCacheMetrics(
            cachedBytes: 30,
            networkBytes: 30,
            cacheHitBytes: 0,
            requestCount: 1,
            networkRequestSeconds: 0.1,
            contiguousCachedBytes: 10,
            contentLength: 100,
            cachedByteRanges: [
                PlaybackByteRange(0, 10),
                PlaybackByteRange(70, 90),
            ],
            timelineAnchor: PlaybackTimelineAnchor(
                byteOffset: 75,
                timeFraction: 0.5
            )
        )

        let ranges = metrics.bufferedRanges
        #expect(ranges.count == 2)
        #expect(abs(ranges[0].upperFraction - (1.0 / 15.0)) < 0.000_001)
        #expect(ranges[1].lowerFraction < 0.5)
        #expect(ranges[1].upperFraction > 0.5)
        #expect(abs(ranges[1].upperFraction - 0.8) < 0.000_001)
        // The legacy prefix metric remains byte-based for diagnostics.
        #expect(metrics.bufferedFraction == 0.1)
    }

    @Test func repeatedReadComesFromSparseFileAndReportsAHit() throws {
        let payload = Data((0..<128).map(UInt8.init))
        let loader = PlaybackCacheLoaderStub(payload: payload)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scope = try PlaybackCacheScope(
            itemID: "episode-1",
            sourceURL: URL(string: "https://media.test/video.mkv")!,
            expectedLength: Int64(payload.count),
            directory: directory,
            byteLimit: 128,
            requestSize: 64,
            loader: loader
        )
        defer { scope.cancelAndRemove() }

        let first = try scope.read(offset: 16, length: 8)
        let second = try scope.read(offset: 16, length: 8)

        #expect(first == payload.subdata(in: 16..<24))
        #expect(second == first)
        #expect(loader.requestCount == 1)
        #expect(scope.metrics.networkBytes == 64)
        #expect(scope.metrics.cacheHitBytes == 8)
        #expect(scope.metrics.cachedBytes == 64)
    }

    @Test func aFullCacheStopsReadingAheadInsteadOfDiscardingMostOfEveryFetch() throws {
        let payload = Data(repeating: 0xAB, count: 256)
        let loader = PlaybackCacheLoaderStub(payload: payload)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scope = try PlaybackCacheScope(
            itemID: "movie-1",
            sourceURL: URL(string: "https://media.test/video.mkv")!,
            expectedLength: Int64(payload.count),
            directory: directory,
            byteLimit: 32,
            requestSize: 64,
            loader: loader
        )
        defer { scope.cancelAndRemove() }

        // The first read may still buffer a whole request ahead. The second
        // cannot store anything — the cap is reached and these byte ranges are
        // too small for the filesystem to punch back out — so it must ask for
        // the 16 bytes it needs rather than a full request it would discard.
        #expect(try scope.read(offset: 0, length: 16).count == 16)
        #expect(try scope.read(offset: 128, length: 16).count == 16)
        #expect(scope.metrics.cachedBytes == 32)
        #expect(loader.requestedRanges == [
            PlaybackByteRange(0, 64),
            PlaybackByteRange(128, 144),
        ])
        #expect(scope.metrics.networkBytes == 80)
    }

    @Test func readsThatCannotBeStoredFetchOnlyWhatWasAsked() throws {
        let payload = PlaybackCacheTests.pattern(byteCount: 256)
        let loader = PlaybackCacheLoaderStub(payload: payload)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scope = try PlaybackCacheScope(
            itemID: "movie-unstorable",
            sourceURL: URL(string: "https://media.test/video.mkv")!,
            expectedLength: Int64(payload.count),
            directory: directory,
            byteLimit: 0,
            requestSize: 64,
            loader: loader
        )
        defer { scope.cancelAndRemove() }

        #expect(try scope.read(offset: 0, length: 8) == payload.subdata(in: 0..<8))
        #expect(try scope.read(offset: 8, length: 8) == payload.subdata(in: 8..<16))
        #expect(loader.requestedRanges == [
            PlaybackByteRange(0, 8),
            PlaybackByteRange(8, 16),
        ])
        #expect(scope.metrics.networkBytes == 16)
    }

    @Test func aTitleLargerThanTheCapBuffersThroughASlidingWindow() throws {
        let requestSize: Int64 = 64 * 1_024
        let byteLimit = 4 * requestSize
        let payload = PlaybackCacheTests.pattern(byteCount: Int(16 * requestSize))
        let loader = PlaybackCacheLoaderStub(payload: payload)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scope = try PlaybackCacheScope(
            itemID: "movie-windowed",
            sourceURL: URL(string: "https://media.test/remux.mkv")!,
            expectedLength: Int64(payload.count),
            directory: directory,
            byteLimit: byteLimit,
            requestSize: requestSize,
            loader: loader
        )
        defer { scope.cancelAndRemove() }

        #expect(scope.metrics.isWindowed)
        try PlaybackCacheTests.play(scope, payload: payload, from: 0, to: 12 * requestSize, step: requestSize)

        let metrics = scope.metrics
        // Playing three times the cap must not cost more than one request per
        // read: the window gives bytes back instead of refusing new ones.
        #expect(loader.requestCount == 12)
        #expect(loader.requestedRanges.allSatisfy { $0.count == requestSize })
        #expect(metrics.evictionCount > 0)
        #expect(metrics.cachedBytes <= byteLimit)
        #expect(metrics.cachedByteRanges.first?.lowerBound ?? 0 > 0)

        // What the window kept is the recent past, so playback that pauses and
        // resumes does not pay for the same bytes twice.
        let hits = metrics.cacheHitBytes
        _ = try scope.read(offset: 11 * requestSize, length: Int(requestSize))
        #expect(scope.metrics.cacheHitBytes == hits + requestSize)
        #expect(loader.requestCount == 12)
    }

    @Test func pausingNearTheStartFillsTheWholeCapAndThenStopsFetching() async throws {
        let requestSize: Int64 = 64 * 1_024
        let byteLimit = 16 * requestSize
        let payload = PlaybackCacheTests.pattern(byteCount: Int(64 * requestSize))
        let loader = PlaybackCacheLoaderStub(payload: payload)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scope = try PlaybackCacheScope(
            itemID: "movie-paused",
            sourceURL: URL(string: "https://media.test/remux.mkv")!,
            expectedLength: Int64(payload.count),
            directory: directory,
            byteLimit: byteLimit,
            requestSize: requestSize,
            loader: loader
        )
        defer { scope.cancelAndRemove() }
        #expect(scope.metrics.isWindowed)

        // The demuxer reads the opening chunk and the viewer pauses, so the
        // playhead stops one request in — nearer the start than the reserve
        // behind it. That reserve has nothing to hold, and read-ahead must
        // get it: the window used to hang off the front of the file and leave
        // that much of the cap unspent.
        _ = try scope.read(offset: 0, length: Int(requestSize))
        var chunks = 0
        while chunks < 64, (await scope.prefetchNextChunk()).advanced { chunks += 1 }

        let filled = scope.metrics
        #expect(filled.cachedBytes == byteLimit)
        #expect(filled.evictionCount == 0)

        // Full, with nothing outside the window to give back: proactive fill
        // has to stop rather than spend requests it cannot keep.
        let requests = loader.requestCount
        let outcome = await scope.prefetchNextChunk()
        #expect(outcome == .exhausted)
        #expect(loader.requestCount == requests)
    }

    @Test func seekingBackwardsRecentresTheWindowAndNeverReadsAPunchedHole() throws {
        let requestSize: Int64 = 64 * 1_024
        let byteLimit = 4 * requestSize
        let payload = PlaybackCacheTests.pattern(byteCount: Int(16 * requestSize))
        let loader = PlaybackCacheLoaderStub(payload: payload)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scope = try PlaybackCacheScope(
            itemID: "movie-seek-back",
            sourceURL: URL(string: "https://media.test/remux.mkv")!,
            expectedLength: Int64(payload.count),
            directory: directory,
            byteLimit: byteLimit,
            requestSize: requestSize,
            loader: loader
        )
        defer { scope.cancelAndRemove() }

        try PlaybackCacheTests.play(scope, payload: payload, from: 0, to: 12 * requestSize, step: requestSize)
        #expect(scope.metrics.cachedByteRanges.first?.lowerBound ?? 0 > 0)
        let evictionsBeforeSeek = scope.metrics.evictionCount

        // Back to the start. Those blocks were deallocated, so this has to come
        // back from the network byte-exact — a hole must never read as zeros.
        #expect(try scope.read(offset: 0, length: Int(requestSize))
            == payload.subdata(in: 0..<Int(requestSize)))

        // Playing on from the new position re-centres the window; the island
        // left far ahead is what pays for the room now.
        try PlaybackCacheTests.play(scope, payload: payload, from: requestSize, to: 5 * requestSize, step: requestSize)

        let metrics = scope.metrics
        #expect(metrics.cachedBytes <= byteLimit)
        #expect(metrics.evictionCount > evictionsBeforeSeek)
        #expect(metrics.cachedByteRanges.last?.upperBound ?? 0 <= 12 * requestSize)
        #expect(loader.requestedRanges.allSatisfy { $0.count <= requestSize })
    }

    /// Reads a scope the way FFmpeg's AVIO buffer does, checking every byte.
    private static func play(
        _ scope: PlaybackCacheScope,
        payload: Data,
        from start: Int64,
        to end: Int64,
        step: Int64
    ) throws {
        var offset = start
        while offset < end {
            let count = Int(min(step, end - offset))
            let chunk = try scope.read(offset: offset, length: count)
            #expect(chunk == payload.subdata(in: Int(offset)..<Int(offset) + count))
            offset += Int64(count)
        }
    }

    private static func pattern(byteCount: Int) -> Data {
        Data((0..<byteCount).map { UInt8($0 % 251) })
    }

    @Test func cancellationStopsRequestsAndRejectsLaterReads() throws {
        let loader = PlaybackCacheLoaderStub(payload: Data(repeating: 1, count: 64))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scope = try PlaybackCacheScope(
            itemID: "episode-cancelled",
            sourceURL: URL(string: "https://media.test/video.mkv")!,
            expectedLength: 64,
            directory: directory,
            byteLimit: 64,
            requestSize: 16,
            loader: loader
        )

        scope.cancelAndRemove()

        #expect(loader.wasCancelled)
        do {
            _ = try scope.read(offset: 0, length: 8)
            Issue.record("A cancelled playback scope accepted another read")
        } catch {
            #expect(error as? PlaybackCacheError != nil)
        }
    }

    @Test func ignoredRangeResponseFallsBackBeforeBufferingTheBody() throws {
        PlaybackCacheURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackCacheURLProtocol.self]
        let loader = URLSessionPlaybackRangeLoader(configuration: configuration)

        do {
            _ = try loader.load(
                url: URL(string: "https://cache.test/video.mkv")!,
                range: PlaybackByteRange(0, 16),
                priority: URLSessionTask.highPriority
            )
            Issue.record("A whole-body response was accepted as seekable range data")
        } catch PlaybackCacheError.rangeUnsupported {
            // Expected: the engine can now reopen through native HTTP.
        }
        #expect(PlaybackCacheURLProtocol.rangeHeaders == ["bytes=0-15"])
    }

    @Test func ignoredRangeResponseCannotTriggerQuadraticPrefixDownloads() throws {
        PlaybackCacheURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackCacheURLProtocol.self]
        let loader = URLSessionPlaybackRangeLoader(configuration: configuration)

        do {
            _ = try loader.load(
                url: URL(string: "https://cache.test/video.mkv")!,
                range: PlaybackByteRange(32, 48),
                priority: URLSessionTask.highPriority
            )
            Issue.record("A later whole-body response was accepted as range data")
        } catch PlaybackCacheError.rangeUnsupported {
            // Expected: no prefix is downloaded or discarded.
        }
        #expect(PlaybackCacheURLProtocol.rangeHeaders == ["bytes=32-47"])
    }

    @Test func hlsCacheSkipsMutablePlaylistsAndUnsupportedSchemes() {
        #expect(!HLSPlaybackCacheScope.shouldCache(
            url: URL(string: "https://media.test/master.m3u8?token=one")!
        ))
        #expect(HLSPlaybackCacheScope.shouldCache(
            url: URL(string: "https://media.test/hls/main/001.ts?token=one")!
        ))
        #expect(!HLSPlaybackCacheScope.shouldCache(
            url: URL(string: "file:///tmp/001.ts")!
        ))
    }

    @Test func hlsManifestReferencesResolveRelativeResources() {
        let manifest = Data("""
        #EXTM3U
        #EXT-X-MAP:URI="init.mp4"
        #EXT-X-KEY:METHOD=AES-128,URI="keys/one.bin"
        #EXTINF:6.0,
        segment-001.m4s
        """.utf8)
        let base = URL(string: "https://media.test/hls/main/index.m3u8?token=one")!

        let references = HLSPlaybackCacheScope.playlistReferences(
            data: manifest,
            relativeTo: base
        )

        #expect(references.map(\.absoluteString) == [
            "https://media.test/hls/main/init.mp4",
            "https://media.test/hls/main/keys/one.bin",
            "https://media.test/hls/main/segment-001.m4s"
        ])
    }

    @Test func hlsVariantSelectionDoesNotMistakeAlternateAudioForVideo() {
        let manifest = Data("""
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",URI="audio/main.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=8000000,AUDIO="audio"
        video/main.m3u8
        """.utf8)
        let base = URL(string: "https://media.test/master.m3u8")!

        let variants = HLSPlaybackCacheScope.variantPlaylistURLs(
            data: manifest,
            relativeTo: base
        )

        #expect(variants.map(\.absoluteString) == ["https://media.test/video/main.m3u8"])
    }

    @Test func hlsCacheEvictsInactiveLRUWithinSharedByteBudget() throws {
        let payload = Data(repeating: 0xCD, count: 256)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = try HLSPlaybackCacheScope(
            itemID: "episode-hls",
            sourceURL: URL(string: "https://media.test/master.m3u8")!,
            directory: directory,
            byteLimit: 64,
            maxResources: 3,
            requestSize: 32,
            resourceLoader: PlaybackCacheLoaderStub(payload: payload)
        )
        defer { cache.cancelAndRemove() }
        let firstURL = URL(string: "https://media.test/one.ts")!
        let secondURL = URL(string: "https://media.test/two.ts")!
        let thirdURL = URL(string: "https://media.test/three.ts")!

        let firstLease = try cache.leaseResource(at: firstURL)
        let first = try #require(firstLease)
        #expect(try first.scope.read(offset: 0, length: 8).count == 8)
        first.close()
        let secondLease = try cache.leaseResource(at: secondURL)
        let second = try #require(secondLease)
        #expect(try second.scope.read(offset: 0, length: 8).count == 8)
        second.close()
        let thirdLease = try cache.leaseResource(at: thirdURL)
        let third = try #require(thirdLease)
        #expect(try third.scope.read(offset: 0, length: 8).count == 8)
        third.close()

        #expect(cache.metrics.cachedBytes == 64)
        #expect(cache.metrics.networkBytes == 96)
        #expect(cache.metrics.requestCount == 3)
        #expect(cache.metrics.evictionCount == 1)
        #expect(cache.metrics.resourceCount == 2)
        #expect(cache.cachedResourceURLs == [secondURL, thirdURL])
    }

    @Test func hlsCacheNeverEvictsAnActivelyLeasedResource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = try HLSPlaybackCacheScope(
            itemID: "active-hls",
            sourceURL: URL(string: "https://media.test/master.m3u8")!,
            directory: directory,
            byteLimit: 64,
            maxResources: 1,
            requestSize: 32
        )
        defer { cache.cancelAndRemove() }
        let activeURL = URL(string: "https://media.test/active.ts")!
        let blockedURL = URL(string: "https://media.test/blocked.ts")!

        let activeLease = try cache.leaseResource(at: activeURL)
        let active = try #require(activeLease)
        #expect(try cache.leaseResource(at: blockedURL) == nil)
        #expect(cache.cachedResourceURLs == [activeURL])
        active.close()
    }

    @Test func hlsCacheReopensSuspendedFilesWithoutLosingHits() throws {
        let payload = Data((0..<128).map(UInt8.init))
        let loader = PlaybackCacheLoaderStub(payload: payload)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = try HLSPlaybackCacheScope(
            itemID: "resume-hls",
            sourceURL: URL(string: "https://media.test/master.m3u8")!,
            directory: directory,
            byteLimit: 128,
            maxResources: 2,
            requestSize: 64,
            resourceLoader: loader
        )
        defer { cache.cancelAndRemove() }
        let segmentURL = URL(string: "https://media.test/segment.ts")!

        let firstLease = try cache.leaseResource(at: segmentURL)
        let first = try #require(firstLease)
        #expect(try first.scope.read(offset: 16, length: 8).count == 8)
        first.close()

        let resumedLease = try cache.leaseResource(at: segmentURL)
        let resumed = try #require(resumedLease)
        #expect(try resumed.scope.read(offset: 16, length: 8).count == 8)
        resumed.close()

        #expect(loader.requestCount == 1)
        #expect(cache.metrics.cacheHitBytes == 8)
    }

    @MainActor
    @Test func coordinatorPromotesOnlyThePreparedSuccessor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let coordinator = PlaybackCacheCoordinator(
            rootDirectory: root,
            isEnabled: true,
            allowsTranscodeCaching: true
        )
        let current = coordinator.activate(
            itemID: "episode-1",
            url: URL(string: "https://media.test/one.mkv")!,
            delivery: .stableFile,
            expectedLength: 1_024
        )
        let prepared = coordinator.stageNext(
            itemID: "episode-2",
            url: URL(string: "https://media.test/two.mkv")!,
            delivery: .stableFile,
            expectedLength: 1_024
        )

        #expect(current != nil)
        #expect(prepared != nil)
        #expect(coordinator.current === current)
        #expect(coordinator.next === prepared)

        let promoted = coordinator.activate(
            itemID: "episode-2",
            url: URL(string: "https://media.test/two.mkv")!,
            delivery: .stableFile,
            expectedLength: 1_024
        )

        #expect(promoted === prepared)
        #expect(coordinator.current === prepared)
        #expect(coordinator.next == nil)
        coordinator.discardAll()
    }

    @MainActor
    @Test func coordinatorCreatesAndPromotesTranscodeResourceCaches() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let coordinator = PlaybackCacheCoordinator(
            rootDirectory: root,
            isEnabled: true,
            allowsTranscodeCaching: true
        )
        let hlsURL = URL(string: "https://media.test/Videos/id/master.m3u8?token=one")!

        let staged = coordinator.stageNext(
            itemID: "episode-hls",
            url: hlsURL,
            delivery: .segmentedManifest,
            expectedLength: nil
        )
        #expect(staged?.hlsScope != nil)
        #expect(staged?.directScope == nil)

        let promoted = coordinator.activate(
            itemID: "episode-hls",
            url: hlsURL,
            delivery: .segmentedManifest,
            expectedLength: nil
        )
        #expect(promoted === staged)
        #expect(coordinator.current === staged)
        #expect(coordinator.next == nil)
        coordinator.discardAll()
    }

    @MainActor
    @Test func coordinatorCannotCacheTranscodeWhenReleasePolicyDisallowsIt() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let coordinator = PlaybackCacheCoordinator(
            rootDirectory: root,
            isEnabled: true,
            allowsTranscodeCaching: false
        )

        #expect(coordinator.activate(
            itemID: "episode-hls",
            url: URL(string: "https://media.test/Videos/id/master.m3u8")!,
            delivery: .segmentedManifest,
            expectedLength: nil
        ) == nil)
        #expect(coordinator.current == nil)

        // Release's HLS boundary must not disable the direct-file buffer.
        #expect(coordinator.activate(
            itemID: "movie-direct",
            url: URL(string: "https://media.test/movie.mkv")!,
            delivery: .stableFile,
            expectedLength: 1_024
        )?.directScope != nil)
        coordinator.discardAll()
    }

    @MainActor
    @Test func disabledCoordinatorCannotReplaceNativePlaybackTransport() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let coordinator = PlaybackCacheCoordinator(rootDirectory: root, isEnabled: false)
        let url = URL(string: "https://media.test/movie.mkv")!

        #expect(coordinator.activate(
            itemID: "movie",
            url: url,
            delivery: .stableFile,
            expectedLength: 1_024
        ) == nil)
        #expect(coordinator.stageNext(
            itemID: "next",
            url: url,
            delivery: .segmentedManifest,
            expectedLength: nil
        ) == nil)
        #expect(coordinator.current == nil)
        #expect(coordinator.next == nil)
    }

    @Test func aFailedPrefetchIsReportedAsFailedAndTheNextOneRecovers() async throws {
        let payload = Data((0..<96).map(UInt8.init))
        let loader = PlaybackCacheLoaderStub(payload: payload)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scope = try PlaybackCacheScope(
            itemID: "episode-flaky",
            sourceURL: URL(string: "https://media.test/video.mkv")!,
            expectedLength: Int64(payload.count),
            directory: directory,
            byteLimit: Int64(payload.count),
            requestSize: 32,
            loader: loader
        )
        defer { scope.cancelAndRemove() }

        loader.failNextLoads = 1
        let failed = await scope.prefetchNextChunk()
        #expect(failed == .failed)
        #expect(scope.metrics.cachedBytes == 0)

        let recovered = await scope.prefetchNextChunk()
        guard case .fetched(let bytes, _) = recovered else {
            Issue.record("Expected a fetched outcome, got \(recovered)")
            return
        }
        #expect(bytes == 32)
        #expect(scope.metrics.contiguousCachedBytes == 32)

        // Fill's momentum survives the failure: it resumes without any seek
        // or new session and still reaches a complete file.
        #expect((await scope.prefetchNextChunk()).advanced)
        #expect((await scope.prefetchNextChunk()).advanced)
        #expect(scope.metrics.bufferedFraction == 1)
        #expect(await scope.prefetchNextChunk() == .exhausted)
    }

    @Test func aFetchedOutcomeReportsItsOwnRequestTime() async throws {
        let payload = Data((0..<64).map(UInt8.init))
        let loader = PlaybackCacheLoaderStub(payload: payload)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scope = try PlaybackCacheScope(
            itemID: "episode-timed",
            sourceURL: URL(string: "https://media.test/video.mkv")!,
            expectedLength: Int64(payload.count),
            directory: directory,
            byteLimit: Int64(payload.count),
            requestSize: 32,
            loader: loader
        )
        defer { scope.cancelAndRemove() }

        let outcome = await scope.prefetchNextChunk()
        guard case .fetched(let bytes, let seconds) = outcome else {
            Issue.record("Expected a fetched outcome, got \(outcome)")
            return
        }
        #expect(bytes == 32)
        #expect(seconds >= 0)
    }

    @Test func aForegroundReadWaitsForAPromotedPrefetchInsteadOfDownloadingTwice() async throws {
        let payload = Data((0..<128).map(UInt8.init))
        let loader = PlaybackCacheLoaderStub(payload: payload)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scope = try PlaybackCacheScope(
            itemID: "movie-shared-fetch",
            sourceURL: URL(string: "https://media.test/video.mkv")!,
            expectedLength: Int64(payload.count),
            directory: directory,
            byteLimit: Int64(payload.count),
            requestSize: 32,
            loader: loader
        )
        defer { scope.cancelAndRemove() }

        loader.hold(range: PlaybackByteRange(0, 32))
        let prefetch = Task { await scope.prefetchNextChunk() }
        try await Self.eventually { loader.requestCount == 1 }

        async let readResult = Self.blockingRead(scope, offset: 0, length: 16, priority: URLSessionTask.highPriority)
        try await Task.sleep(for: .milliseconds(100))
        loader.release()

        let outcome = await prefetch.value

        #expect(outcome.advanced)
        #expect(try await readResult == payload.subdata(in: 0..<16))
        #expect(loader.requestCount == 1)
        #expect(loader.promotedRanges == [PlaybackByteRange(0, 32)])
        #expect(scope.metrics.sharedFetchCount == 1)
        #expect(scope.metrics.duplicateNetworkBytes == 0)
    }

    @Test func aForegroundReadPastTheSharedWaitFallsThroughToItsOwnRequest() async throws {
        let payload = Data((0..<128).map(UInt8.init))
        let loader = PlaybackCacheLoaderStub(payload: payload)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scope = try PlaybackCacheScope(
            itemID: "movie-shared-fetch-timeout",
            sourceURL: URL(string: "https://media.test/video.mkv")!,
            expectedLength: Int64(payload.count),
            directory: directory,
            byteLimit: Int64(payload.count),
            requestSize: 32,
            loader: loader
        )
        defer { scope.cancelAndRemove() }

        loader.hold(range: PlaybackByteRange(0, 32))
        let prefetch = Task { await scope.prefetchNextChunk() }
        try await Self.eventually { loader.requestCount == 1 }

        // Never release before the read comes back: the shared-fetch wait
        // must time out and fall through to its own request rather than
        // hang behind a prefetch that never lands.
        let readResult = try await Self.blockingRead(
            scope, offset: 0, length: 16, priority: URLSessionTask.highPriority
        )

        #expect(readResult == payload.subdata(in: 0..<16))
        #expect(loader.requestCount == 2)

        loader.release()
        _ = await prefetch.value

        // The prefetch's bytes were already cached by the foreground's own
        // request by the time it landed.
        #expect(scope.metrics.duplicateNetworkBytes > 0)
    }

    @Test func contiguousUpperBoundFromAnOffsetReportsTheIslandEnd() {
        var ranges = PlaybackByteRangeSet()
        #expect(ranges.contiguousUpperBound(from: 10) == 10)

        ranges.insert(PlaybackByteRange(0, 40))
        ranges.insert(PlaybackByteRange(60, 100))

        #expect(ranges.contiguousUpperBound(from: 20) == 40)
        #expect(ranges.contiguousUpperBound(from: 50) == 50)
        // Half-open: sitting exactly at an island's upper bound is not inside it.
        #expect(ranges.contiguousUpperBound(from: 40) == 40)
    }

    @Test func metricsReportTheCushionAheadOfTheLastForegroundRead() async throws {
        let payload = Data((0..<128).map(UInt8.init))
        let loader = PlaybackCacheLoaderStub(payload: payload)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scope = try PlaybackCacheScope(
            itemID: "movie-cushion",
            sourceURL: URL(string: "https://media.test/video.mkv")!,
            expectedLength: Int64(payload.count),
            directory: directory,
            byteLimit: Int64(payload.count),
            requestSize: 32,
            loader: loader
        )
        defer { scope.cancelAndRemove() }

        #expect(scope.metrics.cachedBytesAheadOfPlayhead == 0)

        let read = try scope.read(offset: 0, length: 16, priority: URLSessionTask.highPriority)
        #expect(read.count == 16)
        #expect(scope.metrics.cachedBytesAheadOfPlayhead == 32 - 16)

        #expect((await scope.prefetchNextChunk()).advanced)
        #expect((await scope.prefetchNextChunk()).advanced)

        let islandEnd = scope.metrics.cachedByteRanges.first?.upperBound ?? 0
        #expect(islandEnd > 32)
        #expect(scope.metrics.cachedBytesAheadOfPlayhead == islandEnd - 16)
    }

    private static func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for the observable result")
        throw PlaybackCacheError.cancelled
    }

    /// Runs a blocking `PlaybackCacheScope.read` on a dedicated thread rather
    /// than the cooperative pool. `read` can block for real (an `NSCondition`
    /// wait up to `sharedFetchWaitSeconds`) while promoting an in-flight
    /// prefetch; parking that wait on the pool competes with the pool thread
    /// the test itself needs to wake from `Task.sleep` and call `release()`,
    /// which is what turned a same-run promotion into a false shared-fetch
    /// timeout under load.
    private static func blockingRead(
        _ scope: PlaybackCacheScope,
        offset: Int64,
        length: Int,
        priority: Float
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do {
                    let data = try scope.read(offset: offset, length: length, priority: priority)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private nonisolated final class PlaybackCacheURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var recordedRanges: [String] = []

    static var rangeHeaders: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRanges
    }

    static func reset() {
        lock.lock()
        recordedRanges = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cache.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recordedRanges.append(request.value(forHTTPHeaderField: "Range") ?? "")
        Self.lock.unlock()
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Length": "256"]
              ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((0..<256).map(UInt8.init)))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private nonisolated final class PlaybackCacheLoaderStub: PlaybackRangeLoading, @unchecked Sendable {
    private let payload: Data
    private let lock = NSLock()
    private var requests = 0
    private var ranges: [PlaybackByteRange] = []
    private var cancelled = false
    private var failuresRemaining = 0
    private var heldRange: PlaybackByteRange?
    private var holdSemaphore: DispatchSemaphore?
    private var promoted: [PlaybackByteRange] = []

    init(payload: Data) {
        self.payload = payload
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    var requestedRanges: [PlaybackByteRange] {
        lock.lock()
        defer { lock.unlock() }
        return ranges
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// While positive, the next `load` calls decrement this and fail instead
    /// of serving their range, without recording the range as served.
    var failNextLoads: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return failuresRemaining
        }
        set {
            lock.lock()
            failuresRemaining = newValue
            lock.unlock()
        }
    }

    /// Ranges a foreground read promoted while they were still in flight.
    var promotedRanges: [PlaybackByteRange] {
        lock.lock()
        defer { lock.unlock() }
        return promoted
    }

    /// Makes the next `load` for exactly this range block outside the lock
    /// until `release()` is called, so a test can land a foreground read
    /// while the matching prefetch is still in flight. Consumed by
    /// the first matching call; later calls for the same range are unaffected.
    func hold(range: PlaybackByteRange) {
        lock.lock()
        heldRange = range
        holdSemaphore = DispatchSemaphore(value: 0)
        lock.unlock()
    }

    func release() {
        lock.lock()
        let semaphore = holdSemaphore
        holdSemaphore = nil
        lock.unlock()
        semaphore?.signal()
    }

    func load(url: URL, range: PlaybackByteRange, priority: Float) throws -> PlaybackRangeResponse {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            throw PlaybackCacheError.cancelled
        }
        requests += 1
        // Capture the semaphore without clearing the stored property: `hold`
        // and `release` race with this call from another thread, and if
        // `release` ran first (or `holdSemaphore` were cleared here before
        // waiting) the signal would land on nobody and this wait would never
        // return. Only the matched range is consumed, so a later `load` for
        // the same range does not also block.
        var waitSemaphore: DispatchSemaphore?
        if heldRange == range {
            heldRange = nil
            waitSemaphore = holdSemaphore
        }
        lock.unlock()
        if let waitSemaphore {
            waitSemaphore.wait()
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                throw PlaybackCacheError.cancelled
            }
        } else {
            lock.lock()
        }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            lock.unlock()
            throw PlaybackCacheError.invalidResponse
        }
        ranges.append(range)
        let lower = min(Int(range.lowerBound), payload.count)
        let upper = min(Int(range.upperBound), payload.count)
        lock.unlock()
        return PlaybackRangeResponse(
            data: payload.subdata(in: lower..<upper),
            offset: Int64(lower),
            totalLength: Int64(payload.count)
        )
    }

    func cancelAll() {
        lock.lock()
        cancelled = true
        let semaphore = holdSemaphore
        lock.unlock()
        semaphore?.signal()
    }

    func promote(range: PlaybackByteRange) {
        lock.lock()
        promoted.append(range)
        lock.unlock()
    }
}
