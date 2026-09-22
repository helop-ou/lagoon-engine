import Foundation
import Testing
@testable import LagoonEngine

/// Parsing subtitle files into cues, keeping separately authored compositions
/// apart: flattening two speakers and a sign into one cue loses the placement.
@Suite("Subtitle composition")
struct SubtitleCompositionTests {
    @Test func remoteSubtitleFallbackAcceptsTextCuesAndRejectsOtherFiles() {
        let srt = Data("1\n00:00:01,000 --> 00:00:03,000\nFallback works\n".utf8)
        let utf16 = "1\n00:00:01,000 --> 00:00:03,000\nUTF-16 works\n"
            .data(using: .utf16)!
        #expect(SubtitleParser.cues(from: srt).count == 1)
        #expect(SubtitleParser.cues(from: utf16).count == 1)
        #expect(SubtitleParser.cues(from: Data("not a subtitle".utf8)).isEmpty)
    }

    @Test func assOverrideSubsetPreservesPlacementAndInlineStyle() throws {
        let resolution = ASSSubtitleTextParser.playResolution(from: """
        [Script Info]
        PlayResX: 1920
        PlayResY: 1080
        """)
        #expect(resolution == ASSPlayResolution(width: 1920, height: 1080))

        let cue = try #require(ASSSubtitleTextParser.cue(
            from: #"0,0,Default,,0,0,0,,{\an7\pos(1280,180)\b1\i1\c&H332211&}Top{\b0\i0} sign"#,
            playResolution: resolution
        ))
        #expect(cue.alignment == .topLeft)
        #expect(abs((cue.position?.x ?? 0) - (2.0 / 3.0)) < 0.000_001)
        #expect(abs((cue.position?.y ?? 0) - (1.0 / 6.0)) < 0.000_001)
        #expect(cue.text == "Top sign")
        #expect(cue.runs.count == 2)
        #expect(cue.runs[0] == SubtitleTextRun(
            text: "Top",
            primaryColor: SubtitleTextColor(red: 0x11, green: 0x22, blue: 0x33, alpha: 0xFF),
            isBold: true,
            isItalic: true
        ))
        #expect(cue.runs[1].text == " sign")
        #expect(!cue.runs[1].isBold)
        #expect(!cue.runs[1].isItalic)
    }

    @Test func subtitleStoreKeepsSimultaneousAuthoredCompositionsSeparate() {
        let store = SubtitleStore()
        let left = SubtitleTextCue(
            runs: [SubtitleTextRun(text: "Left")],
            alignment: .middleLeft,
            position: nil
        )
        let right = SubtitleTextCue(
            runs: [SubtitleTextRun(text: "Right")],
            alignment: .middleRight,
            position: nil
        )
        store.add(SubtitleCue(start: 1, end: 3, textCues: [left], images: []))
        store.add(SubtitleCue(start: 1, end: 3, textCues: [right], images: []))

        #expect(store.active(at: 2).textCues == [left, right])
    }

    @Test func subtitleValidationRejectsOversizeHTMLAndInvalidTimingButKeepsValidText() async throws {
        do { _ = try await ExternalSubtitleLoader.parse(Data(repeating: 65, count: DownloadLimit.subtitle + 1), language: nil); Issue.record("Expected byte cap") }
        catch SubtitleFileError.tooLarge {}
        do { _ = try await ExternalSubtitleLoader.parse(Data("<html>\n\n1\n00:00:00,000 --> 00:00:10,000\nLogin page\n</html>".utf8), language: nil); Issue.record("Expected HTML rejection") }
        catch SubtitleFileError.invalidFile {}
        #expect(SubtitleParser.cues(from: Data("1\n00:00:00,000 --> 00:00:inf\nBad cue".utf8)).isEmpty)
        #expect(try await ExternalSubtitleLoader.parse(Self.cues("Valid cue"), language: "en").first?.text == "Valid cue")
    }

    private static func cues(_ text: String) -> Data {
        Data("1\n00:00:00,000 --> 00:10:00,000\n\(text)\n".utf8)
    }
}
