import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import LagoonEngine

/// Subtitles drawn into the frames for Picture in Picture, where the host's
/// overlay is not shown.
@Suite("Picture in Picture subtitles")
struct PictureInPictureSubtitleTests {
    // MARK: - Blending

    @Test func opaqueWhiteBecomesVideoRangeWhiteInsideThePieceOnly() throws {
        let frame = try Self.frame(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let compositor = try #require(SubtitleFrameCompositor())
        #expect(compositor.composite(Self.overlay(Self.piece(red: 255, green: 255, blue: 255, alpha: 255)), into: frame))
        #expect(Self.luma(frame, x: 10, y: 10) == 235)
        #expect(Self.luma(frame, x: 23, y: 23) == 235)
        #expect(Self.luma(frame, x: 6, y: 6) == 16, "outside the piece")
        #expect(Self.luma(frame, x: 24, y: 24) == 16, "outside the piece")
        #expect(Self.chroma(frame, x: 5, y: 5) == (128, 128))
    }

    @Test func halfCoverageBlendsHalfway() throws {
        let frame = try Self.frame(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let compositor = try #require(SubtitleFrameCompositor())
        compositor.composite(Self.overlay(Self.piece(red: 128, green: 128, blue: 128, alpha: 128)), into: frame)
        // White at 128/255 coverage over black.
        let expected = 16 + (235 - 16) * 128 / 255
        #expect(abs(Int(Self.luma(frame, x: 12, y: 12)) - expected) <= 1)
    }

    /// Pins the matrix: pure red on BT.709 is Y' 0.2126 and Cr at its top.
    @Test func redTakesTheFramesMatrix() throws {
        let frame = try Self.frame(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let compositor = try #require(SubtitleFrameCompositor())
        compositor.composite(Self.overlay(Self.piece(red: 255, green: 0, blue: 0, alpha: 255)), into: frame)
        #expect(abs(Int(Self.luma(frame, x: 12, y: 12)) - 63) <= 1)
        let (cb, cr) = Self.chroma(frame, x: 6, y: 6)
        #expect(abs(Int(cr) - 240) <= 1)
        #expect(abs(Int(cb) - 102) <= 1)
    }

    /// Subtitle white on PQ sits at the BT.2408 reference white, 203 nits,
    /// far below a 1,000-nit grade's peak.
    @Test func pqWhiteLandsAtReferenceWhiteNotPeak() throws {
        let frame = try Self.frame(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, transfer: .pq)
        let compositor = try #require(SubtitleFrameCompositor())
        compositor.composite(Self.overlay(Self.piece(red: 255, green: 255, blue: 255, alpha: 255)), into: frame)
        let expected = 64 + 876 * Self.pq(nits: 203)
        #expect(abs(Double(Self.luma10(frame, x: 12, y: 12)) - expected) <= 2, "\(Self.luma10(frame, x: 12, y: 12)) vs \(expected)")
        #expect(Self.luma10(frame, x: 12, y: 12) < 64 + Int(876 * Self.pq(nits: 1_000)))
        #expect(Self.luma10(frame, x: 4, y: 4) == 64, "outside the piece")
    }

    /// HLG reference white is 75% signal.
    @Test func hlgWhiteLandsAtSeventyFivePercent() throws {
        let frame = try Self.frame(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, transfer: .hlg)
        let compositor = try #require(SubtitleFrameCompositor())
        compositor.composite(Self.overlay(Self.piece(red: 255, green: 255, blue: 255, alpha: 255)), into: frame)
        #expect(abs(Self.luma10(frame, x: 12, y: 12) - (64 + 657)) <= 3, "\(Self.luma10(frame, x: 12, y: 12))")
    }

    @Test func aFormatItCannotDrawOnIsLeftAlone() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, Self.attributes, &buffer)
        let frame = try #require(buffer)
        let compositor = try #require(SubtitleFrameCompositor())
        #expect(!compositor.composite(Self.overlay(Self.piece(red: 255, green: 255, blue: 255, alpha: 255)), into: frame))
    }

    // MARK: - Layout

    @Test func anUnplacedCueSitsCentredAboveTheBottomEdge() throws {
        let overlay = SubtitleOverlayRasterizer.overlay(
            textCues: [.plain("Hello there")], images: [], style: .standard,
            frameWidth: 1920, frameHeight: 1080, revision: 1
        )
        let piece = try #require(overlay.pieces.first)
        #expect(overlay.pieces.count == 1)
        #expect(abs((piece.x + piece.width / 2) - 960) <= 2)
        #expect(abs((piece.y + piece.height) - 1026) <= 2, "bottom at 95%")
        #expect(piece.height < 1080 / 8)
        #expect(Self.hasOpaqueWhite(piece), "white text drawn")
    }

    @Test func aPlacedCueAnchorsAtItsPoint() throws {
        let cue = SubtitleTextCue(
            runs: [SubtitleTextRun(text: "Sign")],
            alignment: .topLeft,
            position: SubtitleTextPosition(x: 0.1, y: 0.2)
        )
        let overlay = SubtitleOverlayRasterizer.overlay(
            textCues: [cue], images: [], style: .standard, frameWidth: 1920, frameHeight: 1080, revision: 1
        )
        let piece = try #require(overlay.pieces.first)
        #expect(abs(piece.x - 192) <= 2)
        #expect(abs(piece.y - 216) <= 2)
    }

    @Test func aBitmapFillsItsRectangle() throws {
        let image = try #require(Self.solidImage(width: 10, height: 4))
        let overlay = SubtitleOverlayRasterizer.overlay(
            textCues: [], images: [SubtitleImage(image: image, rect: CGRect(x: 0.25, y: 0.75, width: 0.5, height: 0.1))],
            style: .standard, frameWidth: 400, frameHeight: 200, revision: 1
        )
        let piece = try #require(overlay.pieces.first)
        #expect(piece.x == 100 && piece.y == 150)
        #expect(piece.width == 200 && piece.height == 20)
    }

    @Test func nothingShowingDrawsNothing() {
        let overlay = SubtitleOverlayRasterizer.overlay(
            textCues: [.plain("  ")], images: [], style: .standard, frameWidth: 1920, frameHeight: 1080, revision: 1
        )
        #expect(overlay.pieces.isEmpty)
    }

    @Test func peekingAheadKeepsCuesTheClockStillNeeds() {
        let store = SubtitleStore()
        store.add(SubtitleCue(start: 1, end: 2, textCues: [.plain("one")], images: []))
        store.add(SubtitleCue(start: 3, end: 4, textCues: [.plain("two")], images: []))
        #expect(store.peek(at: 3.5).textCues.map(\.text) == ["two"])
        #expect(store.active(at: 1.5).textCues.map(\.text) == ["one"])
    }

    // MARK: - Engine

    /// H.264 is decoded here, not by the display layer, so Picture in
    /// Picture draws subtitles into its frames with no re-demux. The
    /// fixture is shorter than what the renderer holds, so the style is set
    /// before the first frame is queued.
    @MainActor
    @Test func pictureInPictureDrawsSubtitlesIntoDecodedH264() async throws {
        let plain = try await Self.openFixture(subtitleOrdinal: 1)
        plain.play()
        try await Task.sleep(for: .milliseconds(600))
        #expect(plain.burnedInSubtitleFrames == 0, "no drawing outside Picture in Picture")
        plain.shutdown()
        #expect(await plain.waitForMediaResourcesToRetire(timeout: .seconds(10)))

        let engine = try await Self.openFixture(subtitleOrdinal: 1, pictureInPicture: .standard)
        #expect(engine.videoOutputPathDiagnostic == "videotoolbox")
        engine.play()
        try await Self.wait { engine.burnedInSubtitleFrames > 0 }
        #expect(engine.burnedInSubtitleFrames > 0)
        #expect(engine.videoOutputPathDiagnostic == "videotoolbox")
        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }

    /// With no subtitle chosen there is nothing to draw.
    @MainActor
    @Test func withoutSubtitlesPictureInPictureDrawsNothing() async throws {
        let engine = try await Self.openFixture(subtitleOrdinal: 0, pictureInPicture: .standard)
        engine.play()
        try await Task.sleep(for: .milliseconds(600))
        #expect(engine.burnedInSubtitleFrames == 0)
        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }

    // MARK: - Helpers

    private static let attributes: CFDictionary = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true,
    ] as CFDictionary

    /// 32x32, black, with one piece at (8, 8) of 16x16.
    private static func piece(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) -> SubtitleOverlayPiece {
        var pixels = Data(count: 16 * 16 * 4)
        for index in 0..<(16 * 16) {
            pixels[index * 4] = blue
            pixels[index * 4 + 1] = green
            pixels[index * 4 + 2] = red
            pixels[index * 4 + 3] = alpha
        }
        return SubtitleOverlayPiece(x: 8, y: 8, width: 16, height: 16, pixels: pixels)
    }

    private static func overlay(_ piece: SubtitleOverlayPiece) -> SubtitleOverlay {
        SubtitleOverlay(revision: Int.random(in: 1...Int.max), pieces: [piece])
    }

    private static func frame(format: OSType, transfer: SubtitleFrameCompositor.Transfer = .sdr) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, format, attributes, &buffer)
        let frame = try #require(buffer)
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        CVPixelBufferLockBaseAddress(frame, [])
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(frame, plane)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(frame, plane)
            let rows = CVPixelBufferGetHeightOfPlane(frame, plane)
            if tenBit {
                let value: UInt16 = (plane == 0 ? 64 : 512) << 6
                for row in 0..<rows {
                    let line = base.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)
                    for index in 0..<(stride / 2) { line[index] = value }
                }
            } else {
                memset(base, plane == 0 ? 16 : 128, stride * rows)
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        let colour = transfer == .sdr ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_ITU_R_2020
        CVBufferSetAttachment(frame, kCVImageBufferColorPrimariesKey, colour, .shouldPropagate)
        let function: CFString = switch transfer {
        case .sdr: kCVImageBufferTransferFunction_ITU_R_709_2
        case .pq: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case .hlg: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        }
        CVBufferSetAttachment(frame, kCVImageBufferTransferFunctionKey, function, .shouldPropagate)
        let matrix = transfer == .sdr ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_2020
        CVBufferSetAttachment(frame, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        return frame
    }

    private static func luma(_ frame: CVPixelBuffer, x: Int, y: Int) -> UInt8 {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(frame, 0)!.assumingMemoryBound(to: UInt8.self)
        return base[y * CVPixelBufferGetBytesPerRowOfPlane(frame, 0) + x]
    }

    private static func luma10(_ frame: CVPixelBuffer, x: Int, y: Int) -> Int {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(frame, 0)!
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(frame, 0)).assumingMemoryBound(to: UInt16.self)
        return Int(row[x] >> 6)
    }

    /// The chroma pair at chroma site (x, y).
    private static func chroma(_ frame: CVPixelBuffer, x: Int, y: Int) -> (UInt8, UInt8) {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(frame, 1)!.assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRowOfPlane(frame, 1) + x * 2
        return (base[offset], base[offset + 1])
    }

    private static func pq(nits: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let y = pow(nits / 10_000, m1)
        return pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }

    private static func hasOpaqueWhite(_ piece: SubtitleOverlayPiece) -> Bool {
        stride(from: 0, to: piece.pixels.count, by: 4).contains { index in
            piece.pixels[index + 3] == 255 && piece.pixels[index] > 240 && piece.pixels[index + 2] > 240
        }
    }

    private static func solidImage(width: Int, height: Int) -> CGImage? {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }

    @MainActor
    private static func openFixture(
        subtitleOrdinal: Int,
        pictureInPicture: BurnedInSubtitleStyle? = nil
    ) async throws -> SampleBufferPlayerEngine {
        let url = try #require(Bundle.module.url(forResource: "two-subrip", withExtension: "mkv", subdirectory: "TextSubtitles"))
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        engine.setPictureInPictureSubtitles(pictureInPicture)
        engine.prepare(url: url, startSeconds: 0.4, initialAudioOrdinal: nil, initialSubtitleOrdinal: subtitleOrdinal)
        engine.pause()
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        try await wait { !engine.audioTracks.isEmpty && !engine.isBuffering }
        return engine
    }

    @MainActor
    private static func wait(until condition: () -> Bool) async throws {
        // Generous: other suites' main-actor tests run while this one waits.
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
