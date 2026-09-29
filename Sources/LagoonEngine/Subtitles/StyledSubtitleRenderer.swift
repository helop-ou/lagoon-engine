import CoreGraphics
import CoreMedia
import Foundation
import Libass

/// A font the media carries as an attachment (Matroska), for styled
/// subtitles that name it.
nonisolated struct SubtitleFontAttachment: Sendable {
    let name: String
    let data: Data
}

/// One ASS event as Matroska stores it: the Dialogue line without its
/// timing, which travels in the packet.
nonisolated struct StyledSubtitleChunk: Sendable {
    let data: Data
    let startMilliseconds: Int64
    let durationMilliseconds: Int64
}

/// Styled ASS/SSA through libass: named styles, the media's own fonts,
/// karaoke, motion, clips and drawings.
///
/// libass draws for a moment rather than per cue (a karaoke fill or a `\move`
/// changes every frame), so this renders on its own queue for the video clock
/// and publishes one image whenever the picture changes. Everything that
/// touches libass runs on `queue`.
nonisolated final class StyledSubtitleRenderer: @unchecked Sendable {
    /// Above this the canvas is scaled down: a 4K frame is 33 MB of RGBA and
    /// the overlay scales the image to the video anyway.
    static let maximumCanvas = CGSize(width: 1920, height: 1080)
    /// Subtitle animation needs no more than this, even on 50 and 60 fps
    /// video.
    static let maximumRefreshRate: Double = 30

    private let queue = DispatchQueue(label: "ee.helop.lagoon.subtitles.libass", qos: .userInitiated)
    private let library: OpaquePointer
    private let renderer: OpaquePointer
    private let track: UnsafeMutablePointer<ASS_Track>
    private let canvasWidth: Int
    private let canvasHeight: Int
    private var timer: DispatchSourceTimer?
    private var lastPublishedEmpty = true
    /// Render and composite cost of the frames that changed, for the bench.
    private let statsLock = NSLock()
    private var renderCount = 0
    private var totalRenderMilliseconds: Double = 0
    private var peakRenderMilliseconds: Double = 0

    /// "renders=… avgMs=… peakMs=…", for the bench result line.
    var benchField: String {
        statsLock.withLock {
            String(
                format: "renders=%d avgMs=%.2f peakMs=%.2f",
                renderCount,
                renderCount > 0 ? totalRenderMilliseconds / Double(renderCount) : 0,
                peakRenderMilliseconds
            )
        }
    }

    /// An embedded track: `header` is the script's `[Script Info]` and
    /// `[V4+ Styles]` from the stream's codec private data; events follow
    /// through `add(_:)`.
    convenience init?(header: String, fonts: [SubtitleFontAttachment], videoSize: CGSize?) {
        self.init(fonts: fonts, videoSize: videoSize) { library in
            guard let track = ass_new_track(library) else { return nil }
            var bytes = Array(header.utf8)
            bytes.withUnsafeMutableBufferPointer { buffer in
                buffer.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                    ass_process_codec_private(track, $0, Int32(buffer.count))
                }
            }
            return track
        }
    }

    /// A whole script, as a sidecar file delivers it.
    convenience init?(script: Data, fonts: [SubtitleFontAttachment], videoSize: CGSize?) {
        self.init(fonts: fonts, videoSize: videoSize) { library in
            // libass wants a mutable, NUL-terminated copy.
            var bytes = [CChar](repeating: 0, count: script.count + 1)
            bytes.withUnsafeMutableBytes { _ = script.copyBytes(to: $0) }
            return bytes.withUnsafeMutableBufferPointer { buffer in
                ass_read_memory(library, buffer.baseAddress, script.count, nil)
            }
        }
    }

    private init?(
        fonts: [SubtitleFontAttachment],
        videoSize: CGSize?,
        makeTrack: (OpaquePointer) -> UnsafeMutablePointer<ASS_Track>?
    ) {
        guard let library = ass_library_init() else { return nil }
        // libass logs every missing glyph and unknown tag; none of it is
        // actionable at runtime.
        ass_set_message_cb(library, nil, nil)
        for font in fonts {
            font.data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return }
                ass_add_font(library, font.name, base, Int32(raw.count))
            }
        }
        guard let renderer = ass_renderer_init(library) else {
            ass_library_done(library)
            return nil
        }
        guard let track = makeTrack(library) else {
            ass_renderer_done(renderer)
            ass_library_done(library)
            return nil
        }
        let video = videoSize.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
            ?? CGSize(width: 1920, height: 1080)
        let scale = min(
            1,
            Self.maximumCanvas.width / video.width,
            Self.maximumCanvas.height / video.height
        )
        canvasWidth = max(1, Int((video.width * scale).rounded()))
        canvasHeight = max(1, Int((video.height * scale).rounded()))
        ass_set_frame_size(renderer, Int32(canvasWidth), Int32(canvasHeight))
        // Scaled borders and blur follow the video, not the canvas.
        ass_set_storage_size(renderer, Int32(video.width), Int32(video.height))
        // Fonts the script names come from the attachments first, then
        // CoreText; anything else falls back to the system sans serif.
        ass_set_fonts(renderer, nil, "Helvetica Neue", Int32(ASS_FONTPROVIDER_AUTODETECT.rawValue), nil, 0)
        self.library = library
        self.renderer = renderer
        self.track = track
    }

    deinit {
        timer?.cancel()
        ass_free_track(track)
        ass_renderer_done(renderer)
        ass_library_done(library)
    }

    /// From the demux queue. libass drops an event it has already seen, by
    /// ReadOrder, so re-demuxing after a seek is harmless.
    func add(_ chunk: StyledSubtitleChunk) {
        queue.async { [self] in
            chunk.data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return }
                ass_process_chunk(
                    track, base, Int32(raw.count),
                    chunk.startMilliseconds, chunk.durationMilliseconds
                )
            }
        }
    }

    /// Renders for `timebase` at up to `frameRate` (capped) until `stop()`,
    /// calling `publish` with the images whenever the picture changes, and
    /// with none once it clears.
    func start(
        timebase: CMTimebase,
        frameRate: Double?,
        publish: @escaping @Sendable ([SubtitleImage]) -> Void
    ) {
        let rate = min(max(frameRate ?? 24, 1), Self.maximumRefreshRate)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: .nanoseconds(Int(1_000_000_000 / rate)),
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let seconds = CMTimebaseGetTime(timebase).seconds
            guard seconds.isFinite else { return }
            if let images = self.renderIfChanged(atMilliseconds: Int64(seconds * 1000)) {
                publish(images)
            }
        }
        queue.async { [self] in
            self.timer?.cancel()
            self.timer = timer
            self.lastPublishedEmpty = true
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    /// Renders one moment. Nil when nothing changed since the last call.
    /// Called on `queue`; `render(atMilliseconds:)` is the synchronous form
    /// for tests.
    private func renderIfChanged(atMilliseconds now: Int64) -> [SubtitleImage]? {
        let started = DispatchTime.now().uptimeNanoseconds
        var change: Int32 = 0
        let head = ass_render_frame(renderer, track, now, &change)
        guard change != 0 || (head == nil && !lastPublishedEmpty) else { return nil }
        let images = head.map { composite($0) } ?? []
        lastPublishedEmpty = images.isEmpty
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        statsLock.withLock {
            renderCount += 1
            totalRenderMilliseconds += elapsed
            peakRenderMilliseconds = max(peakRenderMilliseconds, elapsed)
        }
        return images
    }

    func render(atMilliseconds now: Int64) -> [SubtitleImage] {
        queue.sync {
            var change: Int32 = 0
            let head = ass_render_frame(renderer, track, now, &change)
            return head.map { composite($0) } ?? []
        }
    }

    /// Blends libass's alpha masks into premultiplied RGBA images, one per
    /// cluster of overlapping pieces, placed on the normalized subtitle
    /// plane. One image over their union would blend every pixel between a
    /// top karaoke line and the bottom dialogue, most of the frame.
    private func composite(_ head: UnsafeMutablePointer<ASS_Image>) -> [SubtitleImage] {
        let canvas = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        var pieces: [(image: UnsafeMutablePointer<ASS_Image>, rect: CGRect)] = []
        var node: UnsafeMutablePointer<ASS_Image>? = head
        while let image = node {
            let item = image.pointee
            node = item.next
            guard item.w > 0, item.h > 0, item.color & 0xFF != 0xFF else { continue }
            let rect = CGRect(x: Int(item.dst_x), y: Int(item.dst_y), width: Int(item.w), height: Int(item.h))
                .intersection(canvas)
            if !rect.isNull, !rect.isEmpty { pieces.append((image, rect)) }
        }
        // Pieces of one line (glyph, outline, shadow) overlap; separate lines
        // and signs do not. The margin keeps a line's glyphs together across
        // letter gaps.
        var clusters: [(rect: CGRect, members: [Int])] = []
        for (index, piece) in pieces.enumerated() {
            var rect = piece.rect
            var members = [index]
            var merged = true
            while merged {
                merged = false
                for cluster in (0..<clusters.count).reversed()
                where clusters[cluster].rect.insetBy(dx: -8, dy: -8).intersects(rect) {
                    rect = rect.union(clusters[cluster].rect)
                    members += clusters[cluster].members
                    clusters.remove(at: cluster)
                    merged = true
                }
            }
            clusters.append((rect, members))
        }
        // libass lists pieces back to front; keep that order inside a cluster.
        return clusters.compactMap { cluster in
            image(of: cluster.members.sorted().map { pieces[$0].image }, covering: cluster.rect)
        }
    }

    private func image(of pieces: [UnsafeMutablePointer<ASS_Image>], covering bounds: CGRect) -> SubtitleImage? {
        let minX = Int(bounds.minX), minY = Int(bounds.minY)
        let maxX = Int(bounds.maxX), maxY = Int(bounds.maxY)
        let width = maxX - minX
        let height = maxY - minY
        let bytesPerRow = width * 4
        guard width > 0, height > 0,
              let pixels = CFDataCreateMutable(nil, bytesPerRow * height) else { return nil }
        CFDataSetLength(pixels, bytesPerRow * height)
        let canvas = CFDataGetMutableBytePtr(pixels)!

        for piece in pieces {
            let item = piece.pointee
            guard let bitmap = item.bitmap else { continue }
            // RGBA with the last byte as transparency, not opacity.
            let red = Int((item.color >> 24) & 0xFF)
            let green = Int((item.color >> 16) & 0xFF)
            let blue = Int((item.color >> 8) & 0xFF)
            let opacity = 255 - Int(item.color & 0xFF)
            let left = max(Int(item.dst_x), minX)
            let top = max(Int(item.dst_y), minY)
            let right = min(Int(item.dst_x) + Int(item.w), maxX)
            let bottom = min(Int(item.dst_y) + Int(item.h), maxY)
            guard right > left, bottom > top else { continue }
            for y in top..<bottom {
                let source = bitmap + (y - Int(item.dst_y)) * Int(item.stride) + (left - Int(item.dst_x))
                var target = canvas + (y - minY) * bytesPerRow + (left - minX) * 4
                for x in 0..<(right - left) {
                    let coverage = Int(source[x])
                    if coverage != 0 {
                        // Source over, premultiplied.
                        let alpha = Self.divide255(coverage * opacity)
                        if alpha == 255 {
                            target[0] = UInt8(red)
                            target[1] = UInt8(green)
                            target[2] = UInt8(blue)
                            target[3] = 255
                        } else {
                            let keep = 255 - alpha
                            target[0] = UInt8(Self.divide255(red * alpha + Int(target[0]) * keep))
                            target[1] = UInt8(Self.divide255(green * alpha + Int(target[1]) * keep))
                            target[2] = UInt8(Self.divide255(blue * alpha + Int(target[2]) * keep))
                            target[3] = UInt8(alpha + Self.divide255(Int(target[3]) * keep))
                        }
                    }
                    target += 4
                }
            }
        }

        guard let provider = CGDataProvider(data: pixels),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else { return nil }
        return SubtitleImage(
            image: cgImage,
            rect: CGRect(
                x: Double(minX) / Double(canvasWidth),
                y: Double(minY) / Double(canvasHeight),
                width: Double(width) / Double(canvasWidth),
                height: Double(height) / Double(canvasHeight)
            )
        )
    }

    /// x / 255, rounded, exact for 0...65025 without a division.
    @inline(__always)
    static func divide255(_ x: Int) -> Int {
        let rounded = x + 128
        return (rounded + (rounded >> 8)) >> 8
    }
}
