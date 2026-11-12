import CoreGraphics
import CoreText
import Foundation

/// Draws the subtitles showing at one moment into pieces for
/// `SubtitleFrameCompositor`, at the frame's own pixel size.
///
/// Text follows `BurnedInSubtitleStyle` and the cue's placement, the way a
/// host's overlay lays it out: unplaced cues stack above the bottom edge, and
/// placed ones anchor at their point by their alignment. Bitmaps (PGS,
/// VobSub, libass) are scaled into their rectangle as they are.
nonisolated enum SubtitleOverlayRasterizer {
    /// Fractions of the frame kept clear at its edges, and the widest a line
    /// may run.
    static let edgeMargin = 0.05
    static let maximumLineWidth = 0.9

    static func overlay(
        textCues: [SubtitleTextCue],
        images: [SubtitleImage],
        style: BurnedInSubtitleStyle,
        frameWidth: Int,
        frameHeight: Int,
        revision: Int
    ) -> SubtitleOverlay {
        guard frameWidth > 1, frameHeight > 1 else { return SubtitleOverlay(revision: revision, pieces: []) }
        var pieces = images.compactMap { piece(for: $0, frameWidth: frameWidth, frameHeight: frameHeight) }
        let fontSize = CGFloat(Double(frameHeight) * style.drawnRelativeSize / 1.2)
        // Stacked from the bottom up, so the last cue sits lowest.
        var bottom = Int(Double(frameHeight) * (1 - edgeMargin))
        for cue in textCues.filter(\.usesDefaultPlacement).reversed() {
            guard let block = block(for: cue, style: style, fontSize: fontSize, frameWidth: frameWidth) else { continue }
            let x = (frameWidth - block.width) / 2
            pieces.append(placed(block, x: x, y: bottom - block.height, frameWidth: frameWidth, frameHeight: frameHeight))
            bottom -= block.height
        }
        for cue in textCues where !cue.usesDefaultPlacement {
            guard let block = block(for: cue, style: style, fontSize: fontSize, frameWidth: frameWidth) else { continue }
            let (x, y) = origin(of: block, cue: cue, frameWidth: frameWidth, frameHeight: frameHeight)
            pieces.append(placed(block, x: x, y: y, frameWidth: frameWidth, frameHeight: frameHeight))
        }
        return SubtitleOverlay(revision: revision, pieces: pieces)
    }

    // MARK: - Placement

    /// The block's top left for a placed cue: its point (or the frame edge
    /// its alignment names) is the block's matching corner, edge or centre.
    static func origin(
        of block: SubtitleOverlayPiece,
        cue: SubtitleTextCue,
        frameWidth: Int,
        frameHeight: Int
    ) -> (Int, Int) {
        let alignment = (cue.alignment ?? .bottomCenter).rawValue
        let column = (alignment - 1) % 3
        let row = (alignment - 1) / 3
        let width = Double(frameWidth)
        let height = Double(frameHeight)
        let anchorX = cue.position.map { $0.x * width }
            ?? [width * edgeMargin, width / 2, width * (1 - edgeMargin)][column]
        let anchorY = cue.position.map { $0.y * height }
            ?? [height * (1 - edgeMargin), height / 2, height * edgeMargin][row]
        let x = anchorX - Double(block.width) * [0, 0.5, 1][column]
        let y = anchorY - Double(block.height) * [1, 0.5, 0][row]
        return (pixel(x, limit: frameWidth), pixel(y, limit: frameHeight))
    }

    /// A coordinate as a pixel. A cue's position is whatever number the
    /// subtitle file holds, and one past the frame converts to no `Int`.
    /// `placed` moves the block inside the frame either way.
    private static func pixel(_ value: Double, limit: Int) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value, -Double(limit)), 2 * Double(limit)).rounded())
    }

    /// Moved inside the frame and onto even pixels.
    private static func placed(
        _ block: SubtitleOverlayPiece,
        x: Int,
        y: Int,
        frameWidth: Int,
        frameHeight: Int
    ) -> SubtitleOverlayPiece {
        let clampedX = max(0, min(x, frameWidth - block.width)) & ~1
        let clampedY = max(0, min(y, frameHeight - block.height)) & ~1
        return SubtitleOverlayPiece(x: clampedX, y: clampedY, width: block.width, height: block.height, pixels: block.pixels)
    }

    // MARK: - Drawing

    private static func piece(for image: SubtitleImage, frameWidth: Int, frameHeight: Int) -> SubtitleOverlayPiece? {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard [image.rect.minX, image.rect.minY, image.rect.maxX, image.rect.maxY].allSatisfy(\.isFinite),
              unit.insetBy(dx: -1, dy: -1).contains(image.rect) else { return nil }
        let x = Int((image.rect.minX * CGFloat(frameWidth)).rounded(.down)) & ~1
        let y = Int((image.rect.minY * CGFloat(frameHeight)).rounded(.down)) & ~1
        let width = evenCeiling(image.rect.maxX * CGFloat(frameWidth)) - x
        let height = evenCeiling(image.rect.maxY * CGFloat(frameHeight)) - y
        guard width > 0, height > 0, x >= 0, y >= 0 else { return nil }
        return draw(width: width, height: height) { context in
            context.interpolationQuality = .high
            context.draw(image.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }.map { SubtitleOverlayPiece(x: x, y: y, width: width, height: height, pixels: $0) }
    }

    /// One cue as a box of text, not yet placed.
    private static func block(
        for cue: SubtitleTextCue,
        style: BurnedInSubtitleStyle,
        fontSize: CGFloat,
        frameWidth: Int
    ) -> SubtitleOverlayPiece? {
        let text = attributedText(cue, style: style, fontSize: fontSize)
        guard text.length > 0, !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let padX = fontSize * 0.25
        let padY = fontSize * 0.1
        let edge = style.edge == .none ? 0 : fontSize * 0.12
        let limit = CGFloat(frameWidth) * CGFloat(maximumLineWidth) - 2 * (padX + edge)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: max(limit, fontSize), height: .greatestFiniteMagnitude), nil
        )
        let width = evenCeiling(size.width + 2 * (padX + edge))
        let height = evenCeiling(size.height + 2 * (padY + edge))
        let textRect = CGRect(x: edge + padX, y: edge + padY, width: ceil(size.width), height: ceil(size.height))
        let pixels = draw(width: width, height: height) { context in
            let box = CGRect(x: edge, y: edge, width: CGFloat(width) - 2 * edge, height: CGFloat(height) - 2 * edge)
            if style.backgroundColor.alpha > 0 {
                context.setFillColor(cgColor(style.backgroundColor))
                context.addPath(CGPath(roundedRect: box, cornerWidth: fontSize * 0.15, cornerHeight: fontSize * 0.15, transform: nil))
                context.fillPath()
            }
            let path = CGPath(rect: textRect, transform: nil)
            switch style.edge {
            case .none:
                break
            case .outline:
                // A mitred join spikes off sharp glyph corners.
                context.setLineJoin(.round)
                let stroked = NSMutableAttributedString(attributedString: text)
                let whole = NSRange(location: 0, length: stroked.length)
                stroked.addAttribute(NSAttributedString.Key(kCTStrokeWidthAttributeName as String), value: 16, range: whole)
                stroked.addAttribute(NSAttributedString.Key(kCTStrokeColorAttributeName as String), value: cgColor(style.edgeColor), range: whole)
                CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(stroked), CFRange(), path, nil), context)
            case .dropShadow:
                context.setShadow(
                    offset: CGSize(width: fontSize * 0.05, height: -fontSize * 0.05),
                    blur: fontSize * 0.08,
                    color: cgColor(style.edgeColor)
                )
            }
            CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), context)
        }
        return pixels.map { SubtitleOverlayPiece(x: 0, y: 0, width: width, height: height, pixels: $0) }
    }

    private static func attributedText(_ cue: SubtitleTextCue, style: BurnedInSubtitleStyle, fontSize: CGFloat) -> NSAttributedString {
        let base: CTFont = style.fontName.map { CTFontCreateWithName($0 as CFString, fontSize, nil) }
            ?? CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let alignment = (cue.alignment ?? .bottomCenter).rawValue
        var textAlignment: CTTextAlignment = [.left, .center, .right][(alignment - 1) % 3]
        let paragraph = withUnsafePointer(to: &textAlignment) { pointer in
            var setting = CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: pointer
            )
            return CTParagraphStyleCreate(&setting, 1)
        }
        let result = NSMutableAttributedString()
        for run in cue.runs {
            var traits: CTFontSymbolicTraits = []
            if run.isBold { traits.insert(.traitBold) }
            if run.isItalic { traits.insert(.traitItalic) }
            let font = traits.isEmpty ? base : (CTFontCreateCopyWithSymbolicTraits(base, fontSize, nil, traits, traits) ?? base)
            result.append(NSAttributedString(string: run.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(run.primaryColor ?? style.textColor),
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
            ]))
        }
        return result
    }

    /// Premultiplied BGRA, top row first, as the compositor uploads it.
    private static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> Data? {
        var data = Data(count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            body(context)
            return true
        }
        return drawn ? data : nil
    }

    private static func cgColor(_ color: SubtitleTextColor) -> CGColor {
        CGColor(
            srgbRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: CGFloat(color.alpha) / 255
        )
    }

    private static func evenCeiling(_ value: CGFloat) -> Int {
        (Int(value.rounded(.up)) + 1) & ~1
    }
}
