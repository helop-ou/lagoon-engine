import Foundation
import Libavcodec
import Libavutil

/// Closed captions carried in the video stream, decoded by FFmpeg's
/// `ccaption` as a text subtitle track of their own.
///
/// Captions ride on each picture in decode order but are meant in
/// presentation order, so they are held back `depth` pictures and fed
/// earliest first. Runs on the demux queue.
nonisolated final class ClosedCaptionTrack {
    /// Not a stream in the file: the index the demuxer reports these events
    /// under.
    static let streamIndex = Int32.max

    private let decoder: SubtitleDecoder
    private let timeBase: AVRational
    private let depth: Int
    private var held: [(pts: Int64, captions: Data)] = []

    init?(timeBase: AVRational, depth: Int) {
        guard let parameters = avcodec_parameters_alloc() else { return nil }
        var owned: UnsafeMutablePointer<AVCodecParameters>? = parameters
        defer { avcodec_parameters_free(&owned) }
        parameters.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
        parameters.pointee.codec_id = AV_CODEC_ID_EIA_608
        guard let decoder = SubtitleDecoder(codecpar: parameters, timeBase: timeBase) else { return nil }
        self.decoder = decoder
        self.timeBase = timeBase
        self.depth = max(depth, 1)
    }

    /// One picture's `cc_data` triplets at its presentation time; the events
    /// of pictures now due.
    func add(_ captions: Data, pts: Int64) -> [SubtitleEvent] {
        held.append((pts, captions))
        held.sort { $0.pts < $1.pts }
        var events: [SubtitleEvent] = []
        while held.count > depth {
            events += decode(held.removeFirst())
        }
        return events
    }

    func drain() -> [SubtitleEvent] {
        defer { held.removeAll() }
        return held.flatMap { decode($0) }
    }

    /// A seek: what was held belongs to the old position.
    func flush() {
        held.removeAll()
        decoder.flush()
    }

    private func decode(_ entry: (pts: Int64, captions: Data)) -> [SubtitleEvent] {
        guard let packet = av_packet_alloc() else { return [] }
        var owned: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&owned) }
        guard av_new_packet(packet, Int32(entry.captions.count)) >= 0 else { return [] }
        entry.captions.copyBytes(to: packet.pointee.data, count: entry.captions.count)
        packet.pointee.pts = entry.pts
        packet.pointee.dts = entry.pts
        return decoder.decode(packet: packet)
    }
}
