import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import LagoonEngine

@Suite("Subtitle packet store")
struct SubtitlePacketStoreTests {
    @Test func packetsComeBackInOrderAndOnce() {
        var store = SubtitlePacketStore()
        for pts: Int64 in [30, 10, 20] {
            store.add(.init(pts: pts, duration: 0, data: Data([UInt8(pts)])), streamIndex: 1)
        }
        // Read again after a seek.
        let again = store.add(.init(pts: 20, duration: 0, data: Data([20])), streamIndex: 1)
        #expect(!again)
        // Same time, other bytes: a second segment of one display set.
        let segment = store.add(.init(pts: 20, duration: 0, data: Data([21])), streamIndex: 1)
        #expect(segment)
        #expect(store.packets(for: 1, in: 15...30).map(\.pts) == [20, 20, 30])
        #expect(store.packets(for: 2, in: 0...100).isEmpty)
    }

    @Test func theOldestReadGoFirstPastTheBudget() {
        var store = SubtitlePacketStore()
        let megabyte = Data(count: 1 << 20)
        for index in 0..<40 {
            store.add(.init(pts: Int64(index), duration: 0, data: megabyte), streamIndex: Int32(index % 2))
        }
        #expect(store.byteCount <= SubtitlePacketStore.budget)
        #expect(store.count(for: 0) + store.count(for: 1) == 32)
        #expect(store.packets(for: 0, in: 0...7).isEmpty, "the first read went first")
        #expect(store.packets(for: 1, in: 39...39).count == 1)
    }
}

/// `late-pgs.mkv`: one PGS line from 10.958 s to 13.333 s, another from
/// 14.708 s, and video keyframes at 10.375, 12.375 and 14.375 s.
@Suite("Subtitles from the packet store", .serialized)
struct SubtitleReplayTests {
    private static let lineStart = 10.958

    @Test func anUnselectedBitmapTrackIsStoredNotDecoded() throws {
        let demuxer = try open()
        defer { demuxer.close() }
        demuxer.selectSubtitle(streamIndex: nil)
        let read = Self.read(demuxer, untilVideo: 15)
        #expect(read.events.isEmpty)
    }

    @Test func choosingABitmapTrackShowsTheLineAlreadyOnScreen() throws {
        let demuxer = try open()
        defer { demuxer.close() }
        let pgs = try #require(demuxer.subtitleStreams.first?.streamIndex)
        demuxer.selectSubtitle(streamIndex: nil)
        _ = Self.read(demuxer, untilVideo: 12)

        let events = demuxer.selectSubtitle(streamIndex: pgs, at: 12)
        let cue = try #require(Self.cues(events).first)
        #expect(abs(cue.start - Self.lineStart) < 0.01)
        #expect(!cue.images.isEmpty)
    }

    /// 13 s lands on the 12.375 s keyframe, after the line began. 11.5 s
    /// lands on 10.375 s, so the line is read again behind the replay.
    @Test(arguments: [13.0, 11.5])
    func aSeekBackShowsALineOnScreenOnce(_ target: Double) throws {
        let demuxer = try open()
        defer { demuxer.close() }
        let pgs = try #require(demuxer.subtitleStreams.first?.streamIndex)
        demuxer.selectSubtitle(streamIndex: pgs)
        _ = Self.read(demuxer, untilVideo: 15)

        try demuxer.seek(toSeconds: target)
        let read = Self.read(demuxer, untilVideo: 15)
        let starts = Self.cues(read.events).map(\.start)
        #expect(starts.filter { abs($0 - Self.lineStart) < 0.01 }.count == 1, "\(starts)")
        #expect(starts.contains { abs($0 - 14.708) < 0.01 })
    }

    private func open() throws -> FFmpegDemuxer {
        let url = try #require(Bundle.module.url(forResource: "late-pgs", withExtension: "mkv", subdirectory: "LatePGS"))
        let demuxer = FFmpegDemuxer()
        try demuxer.open(url: url.path(percentEncoded: false), recommendedPixelBufferAttributes: CVPixelBufferAttributes())
        return demuxer
    }

    private static func cues(_ events: [SubtitleEvent]) -> [SubtitleCue] {
        events.compactMap { if case .cue(let cue) = $0 { cue } else { nil } }
    }

    /// Subtitle events read until a video picture at or past `seconds`.
    private static func read(_ demuxer: FFmpegDemuxer, untilVideo seconds: Double) -> (events: [SubtitleEvent], ended: Bool) {
        var events: [SubtitleEvent] = []
        for _ in 0..<5_000 {
            switch demuxer.readNext() {
            case .subtitle(let more, _):
                events += more
            case .video(let buffer):
                if CMSampleBufferGetPresentationTimeStamp(buffer).seconds >= seconds { return (events, false) }
            case .videoPacket(let packet):
                if (packet.presentationSeconds ?? 0) >= seconds { return (events, false) }
            case .endOfFile, .failed:
                return (events, true)
            default:
                continue
            }
        }
        return (events, false)
    }
}

/// The engine switch: no seek, so no buffering, and the line shows.
@Suite("Bitmap subtitle switch on the engine", .serialized)
struct BitmapSubtitleSwitchTests {
    @MainActor
    @Test func choosingAPGSTrackNeitherSeeksNorWaitsForTheNextLine() async throws {
        let url = try #require(Bundle.module.url(forResource: "late-pgs", withExtension: "mkv", subdirectory: "LatePGS"))
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        var failure: String?
        engine.onError = { failure = $0.message }
        // Paused before it is ready, so the position stays inside the line
        // however loaded the simulator is, and nothing refreshes the display
        // on its own.
        engine.prepare(url: url, startSeconds: 11.5, initialAudioOrdinal: nil)
        engine.pause()
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        // Generous: other suites' main-actor tests run while this one waits.
        let deadline = ContinuousClock.now + .seconds(30)
        while engine.subtitleTracks.isEmpty || engine.isBuffering, failure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(failure == nil)
        try #require(!engine.isBuffering)

        engine.selectSubtitleTrack(id: 1)
        #expect(!engine.isBuffering, "the switch seeked")
        while engine.currentSubtitleImages.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!engine.currentSubtitleImages.isEmpty, "the line from 10.958 s never showed")
        #expect(abs(engine.timePosition - 11.5) < 0.5, "position \(engine.timePosition)")
        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }
}
