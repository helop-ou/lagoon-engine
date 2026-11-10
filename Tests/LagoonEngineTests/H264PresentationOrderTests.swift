import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import LagoonEngine

/// The rebuild on its own, with an I B B B P pattern at a reorder depth of 2,
/// as x264 writes it with a B-pyramid: I0 P8 B4 B2 B6 in decode order.
@Suite("H.264 presentation order")
struct H264PresentationOrderTests {
    private typealias Order = H264PresentationOrder<Int>

    private let orders: [Int32] = [0, 8, 4, 2, 6, 16, 12, 10, 14]
    /// Each picture's true time, in decode order.
    private let truth: [Int64] = [0, 4, 2, 1, 3, 8, 6, 5, 7]

    @Test func aCorrectStreamKeepsItsOwnTimestamps() {
        var order = Order(depth: 2)
        let out = run(&order, timestamps: truth)
        #expect(out.map(\.1) == truth)
        #expect(out.map(\.0) == Array(0..<orders.count))
        #expect(!order.rewrites)
    }

    @Test func timestampsInDecodeOrderAreRebuiltFromThePictureOrder() {
        var order = Order(depth: 2)
        let out = run(&order, timestamps: Array(0..<Int64(orders.count)))
        #expect(out.map(\.1) == truth)
        #expect(out.map(\.0) == Array(0..<orders.count), "released in decode order")
        #expect(order.rewrites)
    }

    @Test func anIDRStartsAFreshPictureOrder() {
        var order = Order(depth: 2)
        let first = run(&order, timestamps: Array(0..<9), idrAt: [0])
        let second = run(&order, timestamps: Array(9..<18), idrAt: [0], elementOffset: 9)
        #expect((first + second).map(\.1) == truth + truth.map { $0 + 9 })
    }

    @Test func aPictureOrderThatGoesBackPassesTheStreamThrough() {
        var order = Order(depth: 2)
        var out: [(Int, Int64)] = []
        // B2 arrives after P8 and B4 were bumped: no depth explains it.
        for (index, picture) in [(0, Int32(0)), (1, 8), (2, 4), (3, 6), (4, 10), (5, 12), (6, 2)].enumerated() {
            out += order.append(index, .init(order: picture.1, isIDR: index == 0, timestamp: Int64(index)))
        }
        out += order.append(7, .init(order: 14, isIDR: false, timestamp: 7))
        out += order.drain()
        #expect(order.passesThrough)
        #expect(out.map(\.0) == Array(0...7))
        #expect(out.suffix(3).map(\.1) == [5, 6, 7], "held pictures keep their own timestamps")
    }

    @Test func anUnreadablePictureOrderPassesTheStreamThrough() {
        var order = Order(depth: 2)
        var out = order.append(0, .init(order: 0, isIDR: true, timestamp: 0))
        out += order.append(1, .init(order: nil, isIDR: false, timestamp: 1))
        out += order.append(2, .init(order: 4, isIDR: false, timestamp: 2))
        #expect(order.passesThrough)
        #expect(out.map(\.0) == [0, 1, 2])
        #expect(out.map(\.1) == [0, 1, 2])
    }

    @Test func aResetHandsBackWhatItHeld() {
        var order = Order(depth: 2)
        _ = order.append(0, .init(order: 0, isIDR: true, timestamp: 0))
        _ = order.append(1, .init(order: 8, isIDR: false, timestamp: 1))
        #expect(order.reset() == [0, 1])
        #expect(order.drain().isEmpty)
    }

    @Test func onlyAnIDRSliceStartsAPictureOrder() {
        let idr = Data([0, 0, 0, 2, 0x09, 0x10, 0, 0, 0, 2, 0x65, 0x88])
        let nonIDR = Data([0, 0, 0, 2, 0x06, 0x05, 0, 0, 0, 2, 0x41, 0x9A])
        #expect(idr.withUnsafeBytes { H264PictureOrderReader.isIDR($0, nalLengthSize: 4) })
        #expect(!nonIDR.withUnsafeBytes { H264PictureOrderReader.isIDR($0, nalLengthSize: 4) })
    }

    private func run(
        _ order: inout Order,
        timestamps: [Int64],
        idrAt: Set<Int> = [0],
        elementOffset: Int = 0
    ) -> [(Int, Int64)] {
        var out: [(Int, Int64)] = []
        for (index, timestamp) in timestamps.enumerated() {
            out += order.append(
                index + elementOffset,
                .init(order: orders[index], isIDR: idrAt.contains(index), timestamp: timestamp)
            )
        }
        return out + order.drain()
    }
}

/// Three files of one x264 stream, 72 frames of 160x120 at 24 fps in an
/// I B B B P pattern with a B-pyramid (`bframes=3:b-adapt=0:b-pyramid=normal:keyint=24`).
/// `normal.mp4` has its `ctts`. `no-ctts.mp4` and `coding-order.mkv` were
/// remuxed with `-bsf:v "setts=pts=DTS-STARTDTS:dts=DTS-STARTDTS"`, the MP4
/// with `-use_editlist 0`, so every timestamp is in decode order. The
/// `open-gop` pair is the same with `open-gop=1`: one IDR, then I-frames
/// whose leading B-frames show before them.
@Suite("H.264 presentation order from the demuxer", .serialized)
struct H264PresentationOrderDemuxTests {
    @Test(arguments: [
        ("no-ctts.mp4", "normal.mp4"),
        ("coding-order.mkv", "normal.mp4"),
        ("open-gop-no-ctts.mp4", "open-gop.mp4"),
    ])
    func aFileThatLostItsOrderPresentsLikeTheOriginal(_ name: String, _ originalName: String) throws {
        let original = try presentationTimes(originalName)
        #expect(original.count == 72)
        #expect(original != original.sorted(), "the original reorders its B-frames")
        #expect(try presentationTimes(name) == original)
    }

    @Test func theOriginalIsLeftAlone() throws {
        let times = try presentationTimes("normal.mp4")
        // Every frame once, on the 24 fps grid.
        #expect(times.sorted() == (0..<72).map { (Double($0) * 1000 / 24).rounded() })
    }

    /// Back, from pictures held at a later position: what it held must not
    /// carry over into the new one.
    @Test func aSeekBackRebuildsFromWhereItLands() throws {
        let rebuilt = try timesAfterSeekingBack("open-gop-no-ctts.mp4")
        #expect(!rebuilt.isEmpty)
        #expect(rebuilt == (try timesAfterSeekingBack("open-gop.mp4")))
    }

    private func timesAfterSeekingBack(_ name: String) throws -> [Double] {
        let demuxer = try open(name)
        defer { demuxer.close() }
        _ = Self.read(demuxer, limit: 50)
        try demuxer.seek(toSeconds: 1.0)
        return Self.read(demuxer)
    }

    private func presentationTimes(_ name: String) throws -> [Double] {
        let demuxer = try open(name)
        defer { demuxer.close() }
        return Self.read(demuxer)
    }

    private func open(_ name: String) throws -> FFmpegDemuxer {
        let parts = name.split(separator: ".")
        let url = try #require(Bundle.module.url(
            forResource: String(parts[0]), withExtension: String(parts[1]), subdirectory: "PresentationOrder"
        ))
        let demuxer = FFmpegDemuxer()
        try demuxer.open(url: url.path(percentEncoded: false), recommendedPixelBufferAttributes: CVPixelBufferAttributes())
        return demuxer
    }

    /// Milliseconds, in the order the demuxer hands the pictures out.
    private static func read(_ demuxer: FFmpegDemuxer, limit: Int = .max) -> [Double] {
        var times: [Double] = []
        for _ in 0..<1_000 where times.count < limit {
            switch demuxer.readNext() {
            case .video(let buffer):
                times.append((CMSampleBufferGetPresentationTimeStamp(buffer).seconds * 1000).rounded())
            case .videoPacket(let packet):
                times.append(((packet.presentationSeconds ?? -1) * 1000).rounded())
            case .endOfFile, .failed:
                return times
            default:
                continue
            }
        }
        return times
    }
}
