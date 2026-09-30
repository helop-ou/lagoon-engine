import Foundation
import Libavcodec
import Testing
@testable import LagoonEngine

/// Choosing an embedded text track replays its recent lines instead of
/// seeking, so the backlog decides what appears at once.
@Suite("Subtitle backlog")
struct SubtitleBacklogTests {
    private func cue(_ start: Double, _ end: Double, _ text: String) -> SubtitleEvent {
        .cue(SubtitleCue(start: start, end: end, text: text, images: []))
    }

    private func chunk(_ startMilliseconds: Int64, _ durationMilliseconds: Int64) -> SubtitleEvent {
        .styledChunk(StyledSubtitleChunk(
            data: Data("0,0,Default,,0,0,0,,x".utf8),
            startMilliseconds: startMilliseconds,
            durationMilliseconds: durationMilliseconds
        ))
    }

    private func texts(_ events: [SubtitleEvent]) -> [String] {
        events.compactMap { if case .cue(let cue) = $0 { cue.text } else { nil } }
    }

    @Test func aLineThatStartedLongAgoIsStillThereWhileItShows() {
        var backlog = SubtitleBacklog()
        // A sign up for the whole scene, then ordinary dialogue past it.
        backlog.record([cue(10, 200, "Sign")], streamIndex: 3)
        for second in stride(from: 20.0, through: 180, by: 2) {
            backlog.record([cue(second, second + 1.5, "Line \(Int(second))")], streamIndex: 3)
        }
        let kept = texts(backlog.events(for: 3))
        #expect(kept.first == "Sign")
        // Dialogue that ended more than the window before the newest line goes.
        #expect(!kept.contains("Line 20"))
        #expect(kept.contains("Line 60"))
        #expect(kept.last == "Line 180")
    }

    @Test func streamsAreKeptApartAndInDemuxOrder() {
        var backlog = SubtitleBacklog()
        backlog.record([cue(1, 2, "a1")], streamIndex: 2)
        backlog.record([cue(1, 2, "b1")], streamIndex: 3)
        backlog.record([cue(3, 4, "a2"), chunk(3_000, 1_000)], streamIndex: 2)
        #expect(texts(backlog.events(for: 2)) == ["a1", "a2"])
        #expect(backlog.count(for: 2) == 3)
        #expect(texts(backlog.events(for: 3)) == ["b1"])
        #expect(backlog.events(for: 9).isEmpty)
    }

    @Test func styledChunksAgeByTheirOwnEnd() {
        var backlog = SubtitleBacklog()
        backlog.record([chunk(0, 5_000)], streamIndex: 2)
        backlog.record([chunk(0, 500_000)], streamIndex: 2)
        backlog.record([chunk(200_000, 1_000)], streamIndex: 2)
        // The first ended 195 s before the newest; the second still shows.
        #expect(backlog.count(for: 2) == 2)
    }

    @Test func aDenseStreamStopsAtTheLimitKeepingTheNewest() {
        var backlog = SubtitleBacklog()
        for index in 0..<(SubtitleBacklog.limit + 100) {
            backlog.record([cue(Double(index) / 100, 1_000, "\(index)")], streamIndex: 2)
        }
        let kept = texts(backlog.events(for: 2))
        #expect(kept.count == SubtitleBacklog.limit)
        #expect(kept.first == "100")
        #expect(kept.last == "\(SubtitleBacklog.limit + 99)")
    }

    @Test func aSeekStartsItOver() {
        var backlog = SubtitleBacklog()
        backlog.record([cue(1, 2, "a")], streamIndex: 2)
        backlog.removeAll()
        #expect(backlog.events(for: 2).isEmpty)
    }

    @Test func onlyTextCodecsAreReadWhileUnselected() {
        for codec in [AV_CODEC_ID_ASS, AV_CODEC_ID_SSA, AV_CODEC_ID_SUBRIP, AV_CODEC_ID_WEBVTT, AV_CODEC_ID_MOV_TEXT] {
            #expect(FFmpegDemuxer.isTextSubtitle(codec), "\(codec)")
        }
        for codec in [AV_CODEC_ID_HDMV_PGS_SUBTITLE, AV_CODEC_ID_DVD_SUBTITLE, AV_CODEC_ID_DVB_SUBTITLE] {
            #expect(!FFmpegDemuxer.isTextSubtitle(codec), "\(codec)")
        }
    }
}
