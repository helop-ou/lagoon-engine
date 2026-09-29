import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import Testing
@testable import LagoonEngine

/// libass behind `StyledSubtitleRenderer`: timing, placement, animation and
/// the premultiplied output the overlay expects. The fixture test adds the
/// demuxer's side: font attachments and raw ASS chunks.
@Suite("Styled subtitles")
struct StyledSubtitleRendererTests {
    private static let script = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 1920
    PlayResY: 1080
    ScaledBorderAndShadow: yes

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Helvetica Neue,64,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,3,0,2,40,40,60,1
    Style: Sign,Helvetica Neue,56,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.00,0:00:03.00,Sign,,0,0,0,,{\\pos(160,200)}Sign
    Dialogue: 0,0:00:04.00,0:00:08.00,Default,,0,0,0,,{\\kf100}Ka{\\kf100}ra{\\kf100}o{\\kf100}ke
    Dialogue: 0,0:00:09.00,0:00:10.00,Sign,,0,0,0,,{\\pos(160,100)}Top
    Dialogue: 0,0:00:09.00,0:00:10.00,Default,,0,0,0,,Bottom
    """

    private func renderer(videoSize: CGSize = CGSize(width: 1920, height: 1080)) throws -> StyledSubtitleRenderer {
        try #require(StyledSubtitleRenderer(
            script: Data(Self.script.utf8), fonts: [], videoSize: videoSize
        ))
    }

    @Test func aLineShowsOnlyInsideItsTime() throws {
        let renderer = try renderer()
        #expect(renderer.render(atMilliseconds: 500).isEmpty)
        #expect(renderer.render(atMilliseconds: 1_500).count == 1)
        #expect(renderer.render(atMilliseconds: 3_500).isEmpty)
    }

    @Test func posPlacesTheSignWhereTheScriptSays() throws {
        let image = try #require(try renderer().render(atMilliseconds: 1_500).first)
        // Alignment 7 anchors the top-left at (160, 200) of 1920x1080; glyph
        // bearings leave a few pixels either way.
        #expect(abs(image.rect.minX - 160.0 / 1920) < 0.01, "\(image.rect)")
        #expect(abs(image.rect.minY - 200.0 / 1080) < 0.02, "\(image.rect)")
    }

    @Test func aKaraokeFillChangesThePictureOverTime() throws {
        let renderer = try renderer()
        let early = try #require(renderer.render(atMilliseconds: 4_200).first)
        let later = try #require(renderer.render(atMilliseconds: 6_200).first)
        #expect(Self.pixels(early.image) != Self.pixels(later.image))
    }

    @Test func aFourKVideoRendersOnACappedCanvasAtTheSamePlace() throws {
        let hd = try #require(try renderer().render(atMilliseconds: 1_500).first)
        let uhd = try #require(
            try renderer(videoSize: CGSize(width: 3840, height: 2160)).render(atMilliseconds: 1_500).first
        )
        #expect(uhd.image.width <= hd.image.width + 2)
        #expect(abs(uhd.rect.minX - hd.rect.minX) < 0.005)
        #expect(abs(uhd.rect.minY - hd.rect.minY) < 0.005)
    }

    @Test func separateLinesBecomeSeparateImages() throws {
        // One image over both would blend the whole frame between them.
        let images = try renderer().render(atMilliseconds: 9_500)
        #expect(images.count == 2)
        let (top, bottom) = (images.min { $0.rect.minY < $1.rect.minY }!, images.max { $0.rect.minY < $1.rect.minY }!)
        #expect(top.rect.maxY < 0.3)
        #expect(bottom.rect.minY > 0.7)
    }

    @Test func divideBy255RoundsExactlyOverTheWholeBlendRange() {
        for x in 0...(255 * 255) {
            #expect(StyledSubtitleRenderer.divide255(x) == Int((Double(x) / 255).rounded()), "\(x)")
        }
    }

    @Test func outputIsPremultiplied() throws {
        let image = try #require(try renderer().render(atMilliseconds: 5_000).first)
        let bytes = Self.pixels(image.image)
        var sawOpaque = false
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = bytes[offset + 3]
            #expect(bytes[offset] <= alpha && bytes[offset + 1] <= alpha && bytes[offset + 2] <= alpha)
            if alpha == 255 { sawOpaque = true }
        }
        #expect(sawOpaque)
    }

    @Test func anASSSidecarIsHandedToLibassAsUTF8AndOthersAreNot() throws {
        // UTF-16 with a BOM, as some sidecars ship.
        var utf16 = Data([0xFF, 0xFE])
        utf16.append(Self.script.data(using: .utf16LittleEndian)!)
        let script = try #require(ExternalSubtitleLoader.styledScript(from: utf16, language: nil))
        #expect(String(data: script, encoding: .utf8)?.hasPrefix("[Script Info]") == true)
        #expect(StyledSubtitleRenderer(script: script, fonts: [], videoSize: nil)?
            .render(atMilliseconds: 1_500).count == 1)

        let srt = Data("1\n00:00:01,000 --> 00:00:02,000\nHello\n".utf8)
        #expect(ExternalSubtitleLoader.styledScript(from: srt, language: nil) == nil)
    }

    @Test func anASSSidecarLoadsAsCuesAndAScriptInsteadOfBeingRejected() async throws {
        let track = ExternalSubtitleTrack(
            url: URL(string: "https://example.test/Stream.ass")!,
            preloadedData: Data(Self.script.utf8),
            title: nil, language: "eng", select: true
        )
        let loaded = try await ExternalSubtitleLoader.load(track, using: .shared)
        #expect(loaded.styledScript != nil)
        #expect(loaded.cues.count == 4)
        let sign = try #require(loaded.cues.first)
        #expect(sign.start == 1 && sign.end == 3)
        #expect(sign.text == "Sign")
        // \pos survives on the fallback path too.
        let position = try #require(sign.textCues.first?.position)
        #expect(abs(position.x - 160.0 / 1920) < 0.001)
        #expect(abs(position.y - 200.0 / 1080) < 0.001)
    }

    @Test func scriptTimesAndCommasInTextParse() {
        let script = """
        [Script Info]
        ScriptType: v4.00

        [Events]
        Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: Marked=0,0:01:02.50,0:01:04.00,Default,,0,0,0,,Well, hello, there
        Comment: 0,0:00:00.00,0:00:05.00,Default,,0,0,0,,not shown
        """
        let cues = SubtitleParser.cues(from: Data(script.utf8))
        #expect(cues.count == 1)
        #expect(cues.first?.start == 62.5)
        #expect(cues.first?.end == 64)
        #expect(cues.first?.text == "Well, hello, there")
    }

    /// Opt-in: `LAGOON_STYLED_ASS_FIXTURE_URL`, a Matroska file with an ASS
    /// track whose Karaoke and Sign styles name a font the file carries as an
    /// attachment (recipe in codecs.md).
    @Test func theFixturesAttachedFontReachesLibass() throws {
        guard let rawURL = ProcessInfo.processInfo.environment["LAGOON_STYLED_ASS_FIXTURE_URL"],
              !rawURL.isEmpty else { return }
        let demuxer = FFmpegDemuxer(
            capabilities: PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: true)
        )
        defer { demuxer.close() }
        try demuxer.open(url: rawURL, recommendedPixelBufferAttributes: CVPixelBufferAttributes())

        let font = try #require(demuxer.subtitleFonts.first)
        #expect(font.name.hasSuffix(".ttf"))
        #expect(font.data.count > 10_000)
        let (streamIndex, header) = try #require(demuxer.styledSubtitleHeaders.first)
        demuxer.selectSubtitle(streamIndex: streamIndex)

        var chunks: [StyledSubtitleChunk] = []
        var reads = 0
        readLoop: while reads < 5_000 {
            reads += 1
            switch demuxer.readNext() {
            case .subtitle(let events, _):
                for case .styledChunk(let chunk) in events { chunks.append(chunk) }
            case .endOfFile, .failed:
                break readLoop
            default:
                continue
            }
        }
        #expect(chunks.count == 5)
        #expect(chunks.first?.startMilliseconds == 1_000)

        func render(with fonts: [SubtitleFontAttachment]) throws -> SubtitleImage {
            let renderer = try #require(StyledSubtitleRenderer(
                header: header, fonts: fonts, videoSize: CGSize(width: 1920, height: 1080)
            ))
            chunks.forEach(renderer.add)
            return try #require(renderer.render(atMilliseconds: 5_000).first)
        }
        // The Karaoke and Sign styles name the attached font; without it they
        // fall back to a system face and draw different pixels. Only where
        // the system lacks that family: iOS ships Chalkduster, tvOS does not.
        let family = (font.name as NSString).deletingPathExtension
        let systemFamily = CTFontCopyFamilyName(CTFontCreateWithName(family as CFString, 12, nil)) as String
        let withFont = try render(with: [font])
        // The same script as a sidecar (`LAGOON_STYLED_ASS_SIDECAR_PATH`) draws
        // the same pixels as the embedded copy.
        if let sidecarPath = ProcessInfo.processInfo.environment["LAGOON_STYLED_ASS_SIDECAR_PATH"],
           let sidecar = FileManager.default.contents(atPath: sidecarPath) {
            let script = try #require(ExternalSubtitleLoader.styledScript(from: sidecar, language: nil))
            let external = try #require(StyledSubtitleRenderer(
                script: script, fonts: [font], videoSize: CGSize(width: 1920, height: 1080)
            ))
            let externalImages = external.render(atMilliseconds: 5_000)
            let embedded = try #require(StyledSubtitleRenderer(
                header: header, fonts: [font], videoSize: CGSize(width: 1920, height: 1080)
            ))
            chunks.forEach(embedded.add)
            let embeddedImages = embedded.render(atMilliseconds: 5_000)
            #expect(externalImages.count == embeddedImages.count)
            #expect(externalImages.map(\.rect) == embeddedImages.map(\.rect))
            #expect(externalImages.map { Self.pixels($0.image) } == embeddedImages.map { Self.pixels($0.image) })
        }
        if systemFamily != family {
            let withoutFont = try render(with: [])
            #expect(Self.pixels(withFont.image) != Self.pixels(withoutFont.image))
        }
    }

    private static func pixels(_ image: CGImage) -> [UInt8] {
        guard let data = image.dataProvider?.data else { return [] }
        return Array(data as Data)
    }
}
