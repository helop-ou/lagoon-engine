import CoreMedia
import CoreVideo
import Foundation
import Libavutil
import Testing
@testable import LagoonEngine

/// Field-rate deinterlacing: two pictures per interlaced frame, the shown
/// field's rows as they were, the other field's predicted from both sides.
@Suite("Field-rate deinterlacing")
struct FieldRateDeinterlacerTests {
    static let width = 64
    static let height = 32

    /// Where nothing moves the fields agree, and the missing rows come back
    /// as they were. (A row that is a peak against both neighbours is
    /// deliberately let off that bound, so the check uses smooth content.)
    @Test func aStillPictureComesBackWhole() throws {
        let deinterlacer = try #require(FieldRateDeinterlacer(width: Self.width, height: Self.height, format: AV_PIX_FMT_YUV420P))
        let still = Self.picture { x, y in UInt8(10 + x * 2 + y * 3) }
        var fields: [FieldRateDeinterlacer.Field] = []
        for index in 0..<3 {
            let frame = try Self.frame(top: still, bottom: still, interlaced: true, topFirst: true)
            defer { Self.free(frame) }
            fields += try deinterlacer.push(frame, timing: Self.timing(index))
        }
        defer { fields.forEach { Self.free($0.frame) } }
        #expect(fields.count == 4)
        for field in fields {
            #expect(Self.luma(of: field.frame) == still.flatMap { $0 })
        }
    }

    /// Stripes two rows high: a spatial guess alone averages each missing
    /// row into grey. The fields either side agree on it, so it comes back.
    @Test func stillDetailFinerThanAFieldSurvives() throws {
        let deinterlacer = try #require(FieldRateDeinterlacer(width: Self.width, height: Self.height, format: AV_PIX_FMT_YUV420P))
        let stripes = Self.picture { _, y in y % 4 < 2 ? 50 : 200 }
        var fields: [FieldRateDeinterlacer.Field] = []
        for index in 0..<3 {
            let frame = try Self.frame(top: stripes, bottom: stripes, interlaced: true, topFirst: true)
            defer { Self.free(frame) }
            fields += try deinterlacer.push(frame, timing: Self.timing(index))
        }
        defer { fields.forEach { Self.free($0.frame) } }
        #expect(fields.count == 4)
        for field in fields {
            #expect(Self.rows(of: field.frame) == stripes)
        }
    }

    @Test func eachPictureKeepsItsOwnFieldsRowsAndTheTopComesFirst() throws {
        let deinterlacer = try #require(FieldRateDeinterlacer(width: Self.width, height: Self.height, format: AV_PIX_FMT_YUV420P))
        let top = Self.picture { x, _ in UInt8(40 + x) }
        let bottom = Self.picture { x, _ in UInt8(160 + x) }
        let first = try Self.frame(top: top, bottom: bottom, interlaced: true, topFirst: true)
        let second = try Self.frame(top: top, bottom: bottom, interlaced: true, topFirst: true)
        defer { Self.free(first); Self.free(second) }
        #expect(try deinterlacer.push(first, timing: Self.timing(0)).isEmpty, "one frame of delay")
        let fields = try deinterlacer.push(second, timing: Self.timing(1))
        defer { fields.forEach { Self.free($0.frame) } }
        #expect(fields.count == 2)
        let shownTop = Self.rows(of: fields[0].frame)
        let shownBottom = Self.rows(of: fields[1].frame)
        for row in stride(from: 0, to: Self.height, by: 2) {
            #expect(shownTop[row] == top[row])
            #expect(shownBottom[row + 1] == bottom[row + 1])
        }
    }

    @Test func bottomFieldFirstShowsTheBottomRowsFirst() throws {
        let deinterlacer = try #require(FieldRateDeinterlacer(width: Self.width, height: Self.height, format: AV_PIX_FMT_YUV420P))
        let top = Self.picture { _, _ in 50 }
        let bottom = Self.picture { _, _ in 200 }
        let first = try Self.frame(top: top, bottom: bottom, interlaced: true, topFirst: false)
        defer { Self.free(first) }
        _ = try deinterlacer.push(first, timing: Self.timing(0))
        let fields = try deinterlacer.drain()
        defer { fields.forEach { Self.free($0.frame) } }
        #expect(fields.count == 2)
        #expect(Self.rows(of: fields[0].frame)[1] == bottom[1])
        #expect(Self.rows(of: fields[1].frame)[0] == top[0])
    }

    /// A bar moving between fields: woven, every other row jumps; shown a
    /// field at a time, it does not.
    @Test func motionDoesNotComb() throws {
        let deinterlacer = try #require(FieldRateDeinterlacer(width: Self.width, height: Self.height, format: AV_PIX_FMT_YUV420P))
        func bar(at position: Int) -> [[UInt8]] {
            Self.picture { x, _ in (position..<(position + 12)).contains(x) ? 230 : 30 }
        }
        var fields: [FieldRateDeinterlacer.Field] = []
        var woven: [[UInt8]] = []
        for index in 0..<4 {
            let top = bar(at: index * 12)
            let bottom = bar(at: index * 12 + 6)
            woven = (0..<Self.height).map { $0 % 2 == 0 ? top[$0] : bottom[$0] }
            let frame = try Self.frame(top: top, bottom: bottom, interlaced: true, topFirst: true)
            defer { Self.free(frame) }
            fields += try deinterlacer.push(frame, timing: Self.timing(index))
        }
        defer { fields.forEach { Self.free($0.frame) } }
        #expect(Self.combing(woven) > 1.5, "the woven frame combs")
        for field in fields {
            #expect(Self.combing(Self.rows(of: field.frame)) < 1.0)
        }
    }

    @Test func fieldsSplitTheFramesInterval() {
        let (first, second) = FieldRateDeinterlacer.fieldTimings(Self.timing(3))
        #expect(first.presentationTimeStamp == CMTime(value: 120, timescale: 1000))
        #expect(second.presentationTimeStamp == CMTime(value: 140, timescale: 1000))
        #expect(first.duration == CMTime(value: 20, timescale: 1000))
        #expect(second.duration == CMTime(value: 20, timescale: 1000))
    }

    /// A progressive frame in an interlaced stream is shown twice, so the
    /// rate the display was set to holds.
    @Test func aProgressiveFrameIsShownTwice() throws {
        let deinterlacer = try #require(FieldRateDeinterlacer(width: Self.width, height: Self.height, format: AV_PIX_FMT_YUV420P))
        let picture = Self.picture { x, y in UInt8((x + y) % 256) }
        let frame = try Self.frame(top: picture, bottom: picture, interlaced: false, topFirst: true)
        defer { Self.free(frame) }
        _ = try deinterlacer.push(frame, timing: Self.timing(0))
        let fields = try deinterlacer.drain()
        defer { fields.forEach { Self.free($0.frame) } }
        #expect(fields.count == 2)
        #expect(fields.allSatisfy { Self.luma(of: $0.frame) == picture.flatMap { $0 } })
        #expect(try deinterlacer.drain().isEmpty, "drained")
    }

    @Test func aSeekDropsWhatWasHeld() throws {
        let deinterlacer = try #require(FieldRateDeinterlacer(width: Self.width, height: Self.height, format: AV_PIX_FMT_YUV420P))
        let picture = Self.picture { _, _ in 100 }
        let frame = try Self.frame(top: picture, bottom: picture, interlaced: true, topFirst: true)
        defer { Self.free(frame) }
        _ = try deinterlacer.push(frame, timing: Self.timing(0))
        deinterlacer.reset()
        #expect(try deinterlacer.drain().isEmpty)
    }

    /// The decoder end to end: an interlaced MPEG-2 file at 25 frames a
    /// second leaves at 50 pictures a second, evenly spaced, and the display
    /// is asked for 50.
    @Test func anInterlacedFileLeavesTheDecoderAtFieldRate() throws {
        let url = try #require(Bundle.module.url(forResource: "interlaced", withExtension: "mkv", subdirectory: "Interlaced"))
        let demuxer = FFmpegDemuxer()
        defer { demuxer.close() }
        try demuxer.open(url: url.path(percentEncoded: false), recommendedPixelBufferAttributes: CVPixelBufferAttributes())
        #expect(demuxer.videoFrameRate == 25)
        #expect(demuxer.outputFrameRate == 50)
        let decoder = try #require(demuxer.takeSoftwareVideoDecoder())
        #expect(decoder.outputsFieldRate)
        var times: [Double] = []
        reading: for _ in 0..<500 {
            switch demuxer.readNext() {
            case .videoPacket(let packet):
                times += try decoder.decode(packet: packet.packet).map { CMSampleBufferGetPresentationTimeStamp($0).seconds }
            case .endOfFile:
                break reading
            case .failed(let message):
                Issue.record("read failed: \(message)")
                break reading
            default:
                continue
            }
        }
        times += try decoder.drain().map { CMSampleBufferGetPresentationTimeStamp($0).seconds }
        #expect(times.count == 32, "16 frames, two fields each")
        for (earlier, later) in zip(times, times.dropFirst()) {
            #expect(abs((later - earlier) - 0.02) < 0.001, "\(earlier) → \(later)")
        }
    }

    // MARK: - Helpers

    private static func picture(_ value: (Int, Int) -> UInt8) -> [[UInt8]] {
        (0..<height).map { y in (0..<width).map { x in value(x, y) } }
    }

    private static func timing(_ index: Int) -> CMSampleTimingInfo {
        CMSampleTimingInfo(
            duration: CMTime(value: 40, timescale: 1000),
            presentationTimeStamp: CMTime(value: Int64(index * 40), timescale: 1000),
            decodeTimeStamp: .invalid
        )
    }

    /// A woven frame: even rows from `top`, odd rows from `bottom`; flat grey
    /// chroma.
    private static func frame(top: [[UInt8]], bottom: [[UInt8]], interlaced: Bool, topFirst: Bool) throws -> UnsafeMutablePointer<AVFrame> {
        let frame = try #require(av_frame_alloc())
        frame.pointee.format = AV_PIX_FMT_YUV420P.rawValue
        frame.pointee.width = Int32(width)
        frame.pointee.height = Int32(height)
        #expect(av_frame_get_buffer(frame, 0) >= 0)
        let luma = frame.pointee.data.0!
        let stride = Int(frame.pointee.linesize.0)
        for y in 0..<height {
            let row = y % 2 == 0 ? top[y] : bottom[y]
            for x in 0..<width { luma[y * stride + x] = row[x] }
        }
        for plane in [frame.pointee.data.1!, frame.pointee.data.2!] {
            memset(plane, 128, Int(frame.pointee.linesize.1) * height / 2)
        }
        frame.pointee.flags = Int32((interlaced ? 1 << 3 : 0) | (topFirst ? 1 << 4 : 0))
        return frame
    }

    private static func rows(of frame: UnsafeMutablePointer<AVFrame>) -> [[UInt8]] {
        let stride = Int(frame.pointee.linesize.0)
        let base = frame.pointee.data.0!
        return (0..<height).map { y in (0..<width).map { base[y * stride + $0] } }
    }

    private static func luma(of frame: UnsafeMutablePointer<AVFrame>) -> [UInt8] {
        rows(of: frame).flatMap { $0 }
    }

    /// Mean difference between neighbouring rows over that between rows two
    /// apart: woven motion is far above 1, a single field's picture near it.
    private static func combing(_ rows: [[UInt8]]) -> Double {
        var adjacent = 0
        var apart = 0
        for y in 1..<(rows.count - 1) {
            for x in 0..<rows[y].count {
                adjacent += abs(Int(rows[y][x]) - Int(rows[y - 1][x]))
                apart += abs(Int(rows[y + 1][x]) - Int(rows[y - 1][x]))
            }
        }
        return Double(adjacent) / Double(max(apart, 1))
    }

    private static func free(_ frame: UnsafeMutablePointer<AVFrame>) {
        var pointer: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&pointer)
    }
}
