import CoreGraphics
import Foundation
import Testing
@testable import LagoonEngine

/// A positive offset shows subtitles later, a negative one earlier, for text,
/// bitmap and styled tracks alike.
@Suite("Subtitle offset")
struct SubtitleOffsetTests {
    @Test func embeddedTextAndBitmapCuesMoveTogether() throws {
        let store = SubtitleStore()
        store.resetForEmbeddedPlayback()
        store.add(SubtitleCue(start: 1, end: 2, text: "Line", images: []))
        store.add(SubtitleCue(start: 1, end: 2, text: nil, images: [try bitmap()]))

        store.setOffset(1.5)
        #expect(store.active(at: 1.5).textCues.isEmpty)
        #expect(store.active(at: 1.5).images.isEmpty)
        let later = store.active(at: 3)
        #expect(later.textCues.map(\.text) == ["Line"])
        #expect(later.images.count == 1)
        #expect(store.active(at: 3.5).textCues.isEmpty)
    }

    @Test func anExternalTrackShowsEarlierAndBackAgain() {
        let store = SubtitleStore()
        store.replaceExternalTrack(with: [SubtitleCue(start: 10, end: 12, text: "Line", images: [])])

        store.setOffset(-4)
        #expect(store.active(at: 7).textCues.map(\.text) == ["Line"])
        #expect(store.active(at: 9).textCues.isEmpty)
        store.setOffset(0)
        #expect(store.active(at: 11).textCues.map(\.text) == ["Line"])
    }

    @Test func aStyledScriptRendersAtTheShiftedTime() throws {
        let renderer = try #require(StyledSubtitleRenderer(
            script: Data(StyledSubtitleRendererTests.script.utf8), fonts: [], videoSize: CGSize(width: 1920, height: 1080)
        ))
        renderer.setOffset(milliseconds: 2_000)
        // The sign runs 1-3 s in the script.
        #expect(renderer.render(atMilliseconds: 1_500).isEmpty)
        #expect(renderer.render(atMilliseconds: 3_500).count == 1)
        renderer.setOffset(milliseconds: -500)
        #expect(renderer.render(atMilliseconds: 700).count == 1)
    }

    @Test func theEngineShiftsWhatIsOnScreenAtOnce() async throws {
        let engine = SampleBufferPlayerEngine()
        defer { engine.shutdown() }
        engine.addExternalSubtitle(ExternalSubtitleTrack(
            url: URL(string: "https://example.invalid/subtitle.srt")!,
            preloadedData: Data("1\n00:00:03,000 --> 00:00:05,000\nLater line\n".utf8),
            title: "English",
            language: "eng",
            select: true,
            isDownloaded: true
        ))
        // The selection lands on the main actor, which a loaded simulator
        // running the other suites can hold for seconds.
        try await eventuallyTrue(timeout: .seconds(10)) { engine.subtitleTracks.first?.isSelected == true }
        #expect(engine.currentSubtitleText == nil)

        engine.setSubtitleOffset(-4)
        #expect(engine.subtitleOffset == -4)
        #expect(engine.currentSubtitleText == "Later line")

        engine.setSubtitleOffset(0)
        #expect(engine.currentSubtitleText == nil)
    }

    @Test func theOffsetIsClampedToMilliseconds() {
        let engine = SampleBufferPlayerEngine()
        defer { engine.shutdown() }
        engine.setSubtitleOffset(45)
        #expect(engine.subtitleOffset == 30)
        engine.setSubtitleOffset(-1.2344)
        #expect(engine.subtitleOffset == -1.234)
    }

    private func bitmap() throws -> SubtitleImage {
        let context = try #require(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return SubtitleImage(image: try #require(context.makeImage()), rect: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
