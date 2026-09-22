import CoreGraphics
import Foundation
import Libavcodec
import Libavutil

/// Decodes embedded subtitle packets via libavcodec, which
/// normalizes every text codec (srt/ass/ssa/mov_text/webvtt) to ASS event
/// payloads and every bitmap codec (PGS/VobSub) to paletted rects.
/// All methods run on the demux queue.
nonisolated final class SubtitleDecoder {
    private let codecContext: UnsafeMutablePointer<AVCodecContext>
    private let timeBase: AVRational
    private let playResolution: ASSPlayResolution

    init?(codecpar: UnsafeMutablePointer<AVCodecParameters>, timeBase: AVRational) {
        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id),
              let context = avcodec_alloc_context3(codec) else {
            return nil
        }
        guard avcodec_parameters_to_context(context, codecpar) >= 0,
              avcodec_open2(context, codec, nil) >= 0 else {
            var ctx: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&ctx)
            return nil
        }
        context.pointee.pkt_timebase = timeBase
        codecContext = context
        self.timeBase = timeBase
        playResolution = ASSSubtitleTextParser.playResolution(
            from: Self.subtitleHeader(from: context)
        )
    }

    deinit {
        var ctx: UnsafeMutablePointer<AVCodecContext>? = codecContext
        avcodec_free_context(&ctx)
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>) -> [SubtitleEvent] {
        var subtitle = AVSubtitle()
        var gotSubtitle: Int32 = 0
        guard avcodec_decode_subtitle2(codecContext, &subtitle, &gotSubtitle, packet) >= 0,
              gotSubtitle != 0 else { return [] }
        defer { avsubtitle_free(&subtitle) }

        // avcodec rebases subtitle pts to AV_TIME_BASE; display times are
        // millisecond offsets from it.
        let base: Double = if subtitle.pts != Int64.min {
            Double(subtitle.pts) / 1_000_000
        } else if packet.pointee.pts != Int64.min {
            Double(packet.pointee.pts) * Double(timeBase.num) / Double(max(timeBase.den, 1))
        } else {
            0
        }
        let start = base + Double(subtitle.start_display_time) / 1000

        guard subtitle.num_rects > 0, let rects = subtitle.rects else {
            return [.clear(at: start)]
        }

        var textCues: [SubtitleTextCue] = []
        var images: [SubtitleImage] = []
        for index in 0..<Int(subtitle.num_rects) {
            guard let rect = rects[index] else { continue }
            switch rect.pointee.type {
            case SUBTITLE_ASS:
                if let ass = rect.pointee.ass,
                   let cue = ASSSubtitleTextParser.cue(
                       from: String(cString: ass),
                       playResolution: playResolution
                   ) {
                    textCues.append(cue)
                }
            case SUBTITLE_TEXT:
                if let raw = rect.pointee.text, let text = Self.cleaned(String(cString: raw)) {
                    textCues.append(.plain(text))
                }
            case SUBTITLE_BITMAP:
                if let image = bitmap(from: rect) {
                    images.append(image)
                }
            default:
                break
            }
        }
        guard !textCues.isEmpty || !images.isEmpty else { return [.clear(at: start)] }

        // Bitmap events routinely leave the end open (0 or sentinel) and
        // clear via a later empty composition; text without a duration
        // gets a readable default instead of sticking forever.
        var end: Double = .infinity
        if subtitle.end_display_time > subtitle.start_display_time, subtitle.end_display_time != UInt32.max {
            end = base + Double(subtitle.end_display_time) / 1000
        } else if packet.pointee.duration > 0 {
            end = start + Double(packet.pointee.duration) * Double(timeBase.num) / Double(max(timeBase.den, 1))
        } else if images.isEmpty {
            end = start + 4
        }

        return [.cue(SubtitleCue(
            start: start,
            end: end,
            textCues: textCues,
            images: images
        ))]
    }

    func flush() {
        avcodec_flush_buffers(codecContext)
    }

    // MARK: - Text

    private static func cleaned(_ raw: String) -> String? {
        let text = raw
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
            .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func subtitleHeader(
        from context: UnsafeMutablePointer<AVCodecContext>
    ) -> String? {
        let count = Int(context.pointee.subtitle_header_size)
        guard count > 0, let bytes = context.pointee.subtitle_header else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    // MARK: - Bitmap

    /// PAL8 rect → premultiplied RGBA CGImage, positioned relative to the
    /// codec's graphics plane (PGS composes on the video-sized plane).
    private func bitmap(from rect: UnsafeMutablePointer<AVSubtitleRect>) -> SubtitleImage? {
        let width = Int(rect.pointee.w)
        let height = Int(rect.pointee.h)
        guard width > 0, height > 0,
              let indices = rect.pointee.data.0,
              let paletteData = rect.pointee.data.1 else { return nil }
        let lineSize = Int(rect.pointee.linesize.0)
        let colorCount = min(Int(rect.pointee.nb_colors), 256)
        let palette = UnsafeRawPointer(paletteData).assumingMemoryBound(to: UInt32.self)

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let paletteIndex = Int(indices[row * lineSize + column])
                guard paletteIndex < colorCount else { continue }
                let color = palette[paletteIndex] // packed ARGB
                let alpha = UInt16((color >> 24) & 0xFF)
                let offset = (row * width + column) * 4
                pixels[offset] = UInt8(UInt16((color >> 16) & 0xFF) * alpha / 255)
                pixels[offset + 1] = UInt8(UInt16((color >> 8) & 0xFF) * alpha / 255)
                pixels[offset + 2] = UInt8(UInt16(color & 0xFF) * alpha / 255)
                pixels[offset + 3] = UInt8(alpha)
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else { return nil }

        let planeWidth = Double(codecContext.pointee.width > 0 ? codecContext.pointee.width : 1920)
        let planeHeight = Double(codecContext.pointee.height > 0 ? codecContext.pointee.height : 1080)
        return SubtitleImage(
            image: image,
            rect: CGRect(
                x: Double(rect.pointee.x) / planeWidth,
                y: Double(rect.pointee.y) / planeHeight,
                width: Double(width) / planeWidth,
                height: Double(height) / planeHeight
            )
        )
    }
}
