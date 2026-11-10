import Foundation
import Libavcodec
import Libavutil

/// Rebuilds presentation timestamps for an H.264 stream whose container lost
/// them: an MP4 without `ctts`, where every pts equals its dts, or a Matroska
/// file that stored its timestamps in coding order. Without it, B-frames show
/// in decode order and the picture stutters or steps back.
///
/// Pictures are bumped in picture order count as a decoder's buffer bumps
/// them, holding `depth` back, and the k-th picture shown takes the k-th
/// smallest timestamp. On a correct file that is every picture's own
/// timestamp, so nothing changes until the two orders disagree once. A
/// picture order that goes back within one IDR period, or one the parser
/// cannot read, stops the rebuild and passes the stream through as it is.
///
/// Elements come out in the order they went in, which is decode order.
nonisolated struct H264PresentationOrder<Element> {
    struct Picture {
        /// Picture order count, or nil when the parser could not read it.
        var order: Int32?
        var isIDR: Bool
        var timestamp: Int64
    }

    private struct Entry {
        let element: Element
        let picture: Picture
        var assigned: Int64?
    }

    let depth: Int
    private var entries: [Entry] = []
    /// Indexes into `entries` not yet bumped, kept in arrival order.
    private var unbumped: [Int] = []
    /// Timestamps not yet handed out.
    private var timestamps: [Int64] = []
    private var lastBumpedOrder: Int32?
    private(set) var rewrites = false
    private(set) var passesThrough = false

    init(depth: Int) {
        self.depth = max(depth, 1)
    }

    /// Takes one picture in decode order and returns those whose timestamp is
    /// settled, in decode order.
    mutating func append(_ element: Element, _ picture: Picture) -> [(Element, Int64)] {
        if passesThrough {
            return [(element, picture.timestamp)]
        }
        guard picture.order != nil else {
            entries.append(Entry(element: element, picture: picture, assigned: picture.timestamp))
            return stopRebuilding()
        }
        if picture.isIDR {
            bumpAll()
            lastBumpedOrder = nil
        }
        entries.append(Entry(element: element, picture: picture, assigned: nil))
        unbumped.append(entries.count - 1)
        timestamps.append(picture.timestamp)
        while unbumped.count > depth, !passesThrough {
            bump()
        }
        return passesThrough ? stopRebuilding() : released()
    }

    /// End of stream: every held picture, in decode order.
    mutating func drain() -> [(Element, Int64)] {
        if !passesThrough {
            bumpAll()
        }
        return passesThrough ? stopRebuilding() : released()
    }

    /// A seek: the held pictures belong to the old position. Returned so the
    /// caller can free them.
    mutating func reset() -> [Element] {
        let held = entries.map(\.element)
        entries.removeAll()
        unbumped.removeAll()
        timestamps.removeAll()
        lastBumpedOrder = nil
        return held
    }

    private mutating func bumpAll() {
        while !unbumped.isEmpty, !passesThrough {
            bump()
        }
    }

    private mutating func bump() {
        guard let position = unbumped.indices.min(by: { order(at: $0) < order(at: $1) }),
              let smallest = timestamps.indices.min(by: { timestamps[$0] < timestamps[$1] }) else { return }
        let index = unbumped.remove(at: position)
        let order = entries[index].picture.order!
        if let lastBumpedOrder, order <= lastBumpedOrder {
            passesThrough = true
            return
        }
        lastBumpedOrder = order
        let timestamp = timestamps.remove(at: smallest)
        entries[index].assigned = timestamp
        if timestamp != entries[index].picture.timestamp {
            rewrites = true
        }
    }

    private func order(at position: Int) -> Int32 {
        entries[unbumped[position]].picture.order ?? .max
    }

    /// The settled run at the front, with the rebuilt timestamps once the
    /// stream has needed one, else their own.
    private mutating func released() -> [(Element, Int64)] {
        var ready: [(Element, Int64)] = []
        while let first = entries.first, let assigned = first.assigned {
            ready.append((first.element, rewrites ? assigned : first.picture.timestamp))
            entries.removeFirst()
            unbumped = unbumped.map { $0 - 1 }
        }
        return ready
    }

    private mutating func stopRebuilding() -> [(Element, Int64)] {
        passesThrough = true
        let held = entries.map { ($0.element, $0.picture.timestamp) }
        entries.removeAll()
        unbumped.removeAll()
        timestamps.removeAll()
        return held
    }
}

/// Reads each H.264 access unit's picture order count with FFmpeg's parser,
/// which tracks the state the count depends on across pictures.
nonisolated final class H264PictureOrderReader {
    private var parser: UnsafeMutablePointer<AVCodecParserContext>?
    private var context: UnsafeMutablePointer<AVCodecContext>?
    private let nalLengthSize: Int

    /// nil unless the stream is length-prefixed H.264 with an `avcC`.
    init?(codecpar: UnsafeMutablePointer<AVCodecParameters>) {
        guard codecpar.pointee.codec_id == AV_CODEC_ID_H264,
              let extradata = codecpar.pointee.extradata,
              codecpar.pointee.extradata_size >= 7,
              extradata[0] == 1 else { return nil }
        nalLengthSize = Int(extradata[4] & 0x03) + 1
        context = avcodec_alloc_context3(nil)
        guard let context, avcodec_parameters_to_context(context, codecpar) >= 0 else { return nil }
        reset()
        guard parser != nil else { return nil }
    }

    deinit {
        if let parser {
            av_parser_close(parser)
        }
        avcodec_free_context(&context)
    }

    /// A seek: the counts after it do not follow from those before.
    func reset() {
        if let parser {
            av_parser_close(parser)
        }
        parser = av_parser_init(Int32(AV_CODEC_ID_H264.rawValue))
        parser?.pointee.flags |= PARSER_FLAG_COMPLETE_FRAMES
    }

    /// The access unit's count and whether it is an IDR picture. nil count
    /// for a field picture or one the parser could not read.
    func picture(in packet: UnsafeMutablePointer<AVPacket>) -> (order: Int32?, isIDR: Bool) {
        guard let parser, let context, let data = packet.pointee.data, packet.pointee.size > 0 else {
            return (nil, false)
        }
        let isIDR = Self.isIDR(
            UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)),
            nalLengthSize: nalLengthSize
        )
        parser.pointee.output_picture_number = .min
        var output: UnsafeMutablePointer<UInt8>?
        var outputSize: Int32 = 0
        _ = av_parser_parse2(
            parser, context, &output, &outputSize,
            data, packet.pointee.size,
            Int64.min, Int64.min, 0
        )
        guard parser.pointee.picture_structure == AV_PICTURE_STRUCTURE_FRAME,
              parser.pointee.output_picture_number != .min else {
            return (nil, isIDR)
        }
        return (parser.pointee.output_picture_number, isIDR)
    }

    /// Whether the first slice in a length-prefixed access unit is an IDR
    /// slice (NAL type 5).
    static func isIDR(_ payload: UnsafeRawBufferPointer, nalLengthSize: Int) -> Bool {
        var offset = 0
        while offset + nalLengthSize < payload.count {
            var length = 0
            for index in 0..<nalLengthSize {
                length = length << 8 | Int(payload[offset + index])
            }
            let start = offset + nalLengthSize
            guard length > 0, start + length <= payload.count else { return false }
            switch payload[start] & 0x1F {
            case 5: return true
            case 1: return false
            default: offset = start + length
            }
        }
        return false
    }
}
