import AVFoundation
import CoreVideo
import Darwin
import Foundation
import Testing
@testable import LagoonEngine

/// A slow start used to look the same as a hung one. The engine now times each
/// step of the open, publishes how far it has got, and says when nothing has
/// come back from the source at all.
@Suite("Playback startup", .serialized)
struct PlaybackStartupTests {
    // MARK: - The timeline

    @Test func thePhaseFollowsTheFurthestStageReached() {
        var timeline = PlaybackStartupTimeline(began: 100)
        #expect(timeline.phase == .connecting)
        timeline.mark(.firstByte, at: 100.2)
        #expect(timeline.phase == .openingContainer)
        timeline.mark(.containerOpened, at: 100.3)
        #expect(timeline.phase == .probingStreams)
        timeline.mark(.streamsProbed, at: 100.5)
        #expect(timeline.phase == .priming)
        timeline.mark(.firstFrame, at: 101)
        #expect(timeline.phase == .started)
    }

    @Test func onlyTheFirstMarkOfAStageCounts() {
        // A reopen after a cache fallback reaches the same stages again.
        var timeline = PlaybackStartupTimeline(began: 10)
        timeline.mark(.containerOpened, at: 10.25)
        timeline.mark(.containerOpened, at: 12)
        #expect(timeline.fields["containerOpenedMs"] == .int(250))
    }

    @Test func theFieldsAreMillisecondsFromTheStart() {
        var timeline = PlaybackStartupTimeline(began: 50)
        timeline.mark(.firstByte, at: 50.0404)
        timeline.mark(.firstFrame, at: 51.5)
        #expect(timeline.fields == ["firstByteMs": .int(40), "firstFrameMs": .int(1_500)])
    }

    @Test func aStartIsSlowOnlyWhileNothingHasComeBack() {
        var timeline = PlaybackStartupTimeline(began: 0)
        #expect(!timeline.isSlow(at: 4.9))
        #expect(timeline.isSlow(at: PlaybackStartupTimeline.slowStartSeconds))
        timeline.mark(.firstByte, at: 6)
        #expect(!timeline.isSlow(at: 7))
        // A local file reports no first byte; its opened container is enough.
        var local = PlaybackStartupTimeline(began: 0)
        local.mark(.containerOpened, at: 0.1)
        #expect(!local.isSlow(at: 9))
    }

    // MARK: - The demuxer's stages

    @Test func theRecorderReportsTheFirstServedReadOncePerReset() {
        let recorder = TransportFailureRecorder()
        let count = Counter()
        recorder.onFirstServedRead { count.add() }
        recorder.record(URLError(.notConnectedToInternet))
        recorder.served()
        recorder.served()
        #expect(count.value == 1)
        #expect(recorder.lastFailure == nil)
        recorder.reset()
        recorder.served()
        #expect(count.value == 2)
    }

    @Test func aCachedOpenReportsEveryStageInOrder() throws {
        let film = try Self.fixture()
        let scope = try PlaybackCacheScope(
            itemID: "startup", sourceURL: URL(string: "https://media.test/startup.mkv")!,
            expectedLength: Int64(film.count),
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            byteLimit: Int64(film.count), requestSize: 64 * 1_024, loader: FixtureLoader(payload: film)
        )
        defer { scope.cancelAndRemove() }
        let session = PlaybackCacheSession(itemID: "startup", sourceURL: scope.sourceURL, storage: .direct(scope))
        let stages = StageLog()
        let demuxer = FFmpegDemuxer()
        defer { demuxer.close() }
        demuxer.onStartupStage = { stages.append($0) }

        try demuxer.open(url: scope.sourceURL.absoluteString, cacheSession: session,
                         recommendedPixelBufferAttributes: CVPixelBufferAttributes())
        #expect(stages.all == [.firstByte, .containerOpened, .streamsProbed])
    }

    @Test func aLocalOpenHasNoFirstByte() throws {
        let stages = StageLog()
        let demuxer = FFmpegDemuxer()
        defer { demuxer.close() }
        demuxer.onStartupStage = { stages.append($0) }

        try demuxer.open(url: try Self.fixtureURL().path(percentEncoded: false),
                         recommendedPixelBufferAttributes: CVPixelBufferAttributes())
        #expect(stages.all == [.containerOpened, .streamsProbed])
    }

    /// FFmpeg's probe waits for a PGS track's size, which only its first
    /// subtitle carries. Here that is 11 s in, so it read to its 5 s limit:
    /// 120 frames and 42 KB, against 6 KB once sized. On a real 1080p remux
    /// the 5 MB limit binds first, before every PGS title could start.
    @Test func aPGSTrackDoesNotHoldTheProbeToItsLimit() throws {
        let url = try #require(Bundle.module.url(forResource: "late-pgs", withExtension: "mkv", subdirectory: "LatePGS"))
        let demuxer = FFmpegDemuxer()
        defer { demuxer.close() }

        try demuxer.open(url: url.path(percentEncoded: false), recommendedPixelBufferAttributes: CVPixelBufferAttributes())
        #expect(demuxer.probedBytes > 0)
        #expect(demuxer.probedBytes < 20_000, "probed \(demuxer.probedBytes) bytes")

        // The size it was given does not stop the subtitles drawing.
        let pgs = try #require(demuxer.subtitleStreams.first)
        demuxer.selectSubtitle(streamIndex: pgs.streamIndex)
        var cues = 0
        reading: for _ in 0..<5_000 {
            switch demuxer.readNext() {
            case .subtitle(let events, _):
                cues += events.filter { if case .cue(let cue) = $0 { !cue.images.isEmpty } else { false } }.count
            case .endOfFile, .failed:
                break reading
            default:
                continue
            }
        }
        #expect(cues == 2)
    }

    // MARK: - The engine

    @MainActor
    @Test func aStartPublishesItsPhaseAndRecordsItsTimings() async throws {
        let sink = FieldSink()
        EngineDiagnostics.use(sink)
        defer { EngineDiagnostics.use(DiscardedDiagnostics()) }
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        var started = false
        var failure: String?
        engine.onPlaybackStarted = { started = true }
        engine.onError = { failure = $0.message }
        #expect(engine.startupPhase == .idle)

        engine.prepare(url: try Self.fixtureURL(), startSeconds: 0, initialAudioOrdinal: nil)
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        engine.play()
        #expect(engine.startupPhase == .connecting)
        let deadline = ContinuousClock.now + .seconds(30)
        while !started, failure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(failure == nil)
        #expect(engine.startupPhase == .started)
        let timeline = try #require(engine.startupTimeline)
        #expect(Set(timeline.reached.keys) == [.containerOpened, .streamsProbed, .firstFrame])
        let fields = try #require(sink.fields(of: .playbackStartup).first)
        #expect(fields["firstFrameMs"] != nil)
        #expect(fields["containerOpenedMs"] != nil)
        engine.shutdown()
    }

    /// A FIFO blocks the open until someone writes, like a server that never
    /// answers.
    @MainActor
    @Test func aSourceThatNeverAnswersIsReportedAsASlowStart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("silent.mkv")
        #expect(mkfifo(fifo.path(percentEncoded: false), 0o600) == 0)
        let sink = FieldSink()
        EngineDiagnostics.use(sink)
        defer { EngineDiagnostics.use(DiscardedDiagnostics()) }
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        engine.slowStartSeconds = 0.3

        engine.prepare(url: fifo, startSeconds: 0, initialAudioOrdinal: nil)
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        engine.play()
        let deadline = ContinuousClock.now + .seconds(10)
        while sink.fields(of: .playbackSlowStart).isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(engine.startupPhase == .connecting)
        let fields = try #require(sink.fields(of: .playbackSlowStart).first)
        if case .int(let elapsed) = fields["elapsedMs"] {
            #expect(elapsed >= 300)
        } else {
            Issue.record("No elapsed time: \(fields)")
        }
        engine.shutdown()
        // Unblock the open: a writer that closes at once ends it as empty.
        let writer = open(fifo.path(percentEncoded: false), O_WRONLY)
        if writer >= 0 { close(writer) }
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }

    /// The viewer backs out while the title is still opening. The open ends
    /// because it was interrupted, which is not a failure to tell a host
    /// about: one that descends on a delivery failure would start again.
    @MainActor
    @Test func aTitleDismissedWhileOpeningReportsNoFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("silent.mkv")
        #expect(mkfifo(fifo.path(percentEncoded: false), 0o600) == 0)
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        var failures = 0
        engine.onError = { _ in failures += 1 }

        engine.prepare(url: fifo, startSeconds: 0, initialAudioOrdinal: nil)
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        engine.play()
        try await Task.sleep(for: .milliseconds(300))
        engine.shutdown()
        let writer = open(fifo.path(percentEncoded: false), O_WRONLY)
        if writer >= 0 { close(writer) }
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
        try await Task.sleep(for: .milliseconds(200))
        #expect(failures == 0)
    }

    // MARK: - Helpers

    private static func fixtureURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "no-cues", withExtension: "mkv", subdirectory: "UnindexedSeek"))
    }

    private static func fixture() throws -> Data {
        try Data(contentsOf: try fixtureURL())
    }
}

private nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

private nonisolated final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [PlaybackStartupTimeline.Stage] = []
    var all: [PlaybackStartupTimeline.Stage] { lock.withLock { stages } }
    func append(_ stage: PlaybackStartupTimeline.Stage) { lock.withLock { stages.append(stage) } }
}

private nonisolated final class FieldSink: EngineDiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(EngineDiagnosticEvent, [String: DiagnosticValue])] = []

    func fields(of event: EngineDiagnosticEvent) -> [[String: DiagnosticValue]] {
        lock.withLock { recorded.filter { $0.0 == event }.map(\.1) }
    }

    func record(_ event: EngineDiagnosticEvent, _ fields: [String: DiagnosticValue]) {
        lock.withLock { recorded.append((event, fields)) }
    }

    func report(
        _ incident: EngineDiagnosticIncident,
        level: EngineDiagnosticLevel,
        variant: [String],
        fields: [String: DiagnosticValue]
    ) -> Bool { false }
}

private nonisolated final class FixtureLoader: PlaybackRangeLoading, @unchecked Sendable {
    private let payload: Data

    init(payload: Data) {
        self.payload = payload
    }

    func load(url: URL, range: PlaybackByteRange, priority: Float) throws -> PlaybackRangeResponse {
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
