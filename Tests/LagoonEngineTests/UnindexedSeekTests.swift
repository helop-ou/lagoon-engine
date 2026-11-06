import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import LagoonEngine

/// A Matroska file without Cues: libavformat seeks it by reading every
/// cluster up to the target, which through the byte cache downloads the
/// file. `no-cues.mkv` is two minutes of 160x120 H.264 at 24 fps, a keyframe
/// every 2 s, muxed by ffmpeg with its Cues element's ID changed so the
/// demuxer skips it:
/// `ffmpeg -f lavfi -i testsrc=size=160x120:rate=24 -t 120 -c:v libx264 -b:v 30k -g 48 -pix_fmt yuv420p`,
/// then byte 3 of the Cues ID (0x1C53BB6B) set to 0x6C.
@Suite("Seeking a file without an index", .serialized)
struct UnindexedSeekTests {
    @Test func aLateSeekStartsFromANearbyClusterInsteadOfReadingTheFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let demuxer = try fixture.openDemuxer()
        defer { demuxer.close() }

        let before = fixture.loader.servedBytes
        try demuxer.seek(toSeconds: 100)
        let landing = try #require(Self.firstVideoSeconds(demuxer))

        #expect(abs(landing - 100) < 2.5)
        // Without the cluster, the seek reads nearly the whole file.
        #expect(fixture.loader.servedBytes - before < fixture.size * 2 / 3)
    }

    /// Back to a stretch the first seek never indexed. Without a cluster the
    /// demuxer lands on its first index entry, the start of the file. A
    /// cluster lands it a few seconds early at most, which the engine's clock
    /// anchor absorbs.
    @Test func laterSeeksStartFromAClusterToo() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let demuxer = try fixture.openDemuxer()
        defer { demuxer.close() }
        try demuxer.seek(toSeconds: 100)

        try demuxer.seek(toSeconds: 50)
        let landing = try #require(Self.firstVideoSeconds(demuxer))

        #expect((44...50.5).contains(landing))
    }

    /// Landing wherever the demuxer had read to would play the wrong scene.
    @Test func aSeekThatFindsNoClusterInTimeFails() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let demuxer = try fixture.openDemuxer()
        defer { demuxer.close() }
        demuxer.clusterSearchWindow = 0

        #expect(throws: DemuxError.self) { try demuxer.seek(toSeconds: 100) }
    }

    @Test func clustersAreFoundPastACRCAndNotInsideFrames() {
        // ID, size, CRC-32, Timestamp 96000.
        let cluster: [UInt8] = [0x1F, 0x43, 0xB6, 0x75, 0x84, 0xBF, 0x84, 1, 2, 3, 4, 0xE7, 0x83, 0x01, 0x77, 0x00]
        // The same ID with no Timestamp after it, as inside frame data.
        let impostor: [UInt8] = [0x1F, 0x43, 0xB6, 0x75, 0x84, 0xA3, 0x81, 0x00, 0x00]
        let bytes = Data([0xAA, 0xBB] + impostor + cluster + [0, 0, 0, 0])

        let found = MatroskaClusterLocator.firstCluster(in: bytes, baseOffset: 1_000)

        #expect(found == .init(offset: 1_000 + 2 + Int64(impostor.count), timestamp: 96_000))
        #expect(MatroskaClusterLocator.firstCluster(in: Data(impostor), baseOffset: 0) == nil)
    }

    private static func firstVideoSeconds(_ demuxer: FFmpegDemuxer) -> Double? {
        for _ in 0..<400 {
            switch demuxer.readNext() {
            case .video(let buffer):
                return CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            case .endOfFile, .failed:
                return nil
            default:
                continue
            }
        }
        return nil
    }
}

private struct Fixture {
    let url: URL
    let size: Int64
    let loader: SlowFileLoader
    let scope: PlaybackCacheScope
    let session: PlaybackCacheSession

    init() throws {
        let file = try #require(Bundle.module.url(forResource: "no-cues", withExtension: "mkv", subdirectory: "UnindexedSeek"))
        let data = try Data(contentsOf: file)
        size = Int64(data.count)
        // Slow enough that reading the file up to a late target outlasts the
        // test's deadline, as a remote file does a real one.
        loader = SlowFileLoader(data: data, delayPerRequest: 0.15)
        url = try #require(URL(string: "https://unindexed.invalid/\(UUID().uuidString).mkv"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        scope = try PlaybackCacheScope(itemID: url.lastPathComponent, sourceURL: url, expectedLength: size,
                                       directory: directory, byteLimit: 64 * 1_024 * 1_024, requestSize: 65_536,
                                       loader: loader)
        session = PlaybackCacheSession(itemID: url.lastPathComponent, sourceURL: url, storage: .direct(scope))
    }

    func openDemuxer() throws -> FFmpegDemuxer {
        let demuxer = FFmpegDemuxer()
        demuxer.seekReadDeadline = .milliseconds(300)
        // A cluster every ~12 KB here, as one every few MB is in a film.
        demuxer.clusterSearchWindow = 32 * 1_024
        try demuxer.open(url: url.absoluteString, cacheSession: session,
                         recommendedPixelBufferAttributes: CVPixelBufferAttributes())
        return demuxer
    }

    func remove() { scope.cancelAndRemove() }
}

private nonisolated final class SlowFileLoader: PlaybackRangeLoading, @unchecked Sendable {
    private let data: Data
    private let delayPerRequest: TimeInterval
    private let lock = NSLock()
    private var served: Int64 = 0

    init(data: Data, delayPerRequest: TimeInterval) {
        self.data = data
        self.delayPerRequest = delayPerRequest
    }

    var servedBytes: Int64 { lock.withLock { served } }

    func load(url: URL, range: PlaybackByteRange, priority: Float) throws -> PlaybackRangeResponse {
        Thread.sleep(forTimeInterval: delayPerRequest)
        let lower = Int(min(range.lowerBound, Int64(data.count)))
        let upper = Int(min(range.upperBound, Int64(data.count)))
        lock.withLock { served += Int64(upper - lower) }
        return PlaybackRangeResponse(data: data.subdata(in: lower..<upper), offset: Int64(lower), totalLength: Int64(data.count))
    }

    func cancelAll() {}
}
