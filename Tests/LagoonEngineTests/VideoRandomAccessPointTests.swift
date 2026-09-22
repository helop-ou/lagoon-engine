import Foundation
import Testing
@testable import LagoonEngine

/// One length-prefixed access unit made of NALs of the given types.
///
/// Only the header byte of each unit carries the type, so the payload bytes
/// behind it are arbitrary — what is being pinned down is the walk and the
/// classification, not a decoder.
private func accessUnit(
    types: [UInt8],
    codec: VideoRandomAccessPoint.Codec,
    lengthSize: Int = 4,
    payloadBytes: Int = 3
) -> Data {
    var data = Data()
    for type in types {
        let length = payloadBytes + 1
        for shift in stride(from: (lengthSize - 1) * 8, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: length >> shift))
        }
        switch codec {
        case .h264: data.append(type & 0x1F)
        case .hevc: data.append((type & 0x3F) << 1)
        }
        data.append(contentsOf: [UInt8](repeating: 0xAA, count: payloadBytes))
    }
    return data
}

private func isStartPoint(
    _ data: Data,
    codec: VideoRandomAccessPoint.Codec,
    lengthSize: Int = 4
) -> Bool? {
    data.withUnsafeBytes {
        VideoRandomAccessPoint.isDecoderStartPoint(
            lengthPrefixed: $0, lengthSize: lengthSize, codec: codec
        )
    }
}

@Suite("Video random-access points")
struct VideoRandomAccessPointTests {
    /// The access unit `avformat_seek_file` landed on in Exit 8 (2025),
    /// h264 High 1080p 23.976 in Matroska, as the demuxer trace printed it:
    /// `key=1 size=324156 nals=7,8,6,6,6,1,1,1,1`. The container flags it a
    /// keyframe, it carries its own SPS and PPS and a recovery-point SEI —
    /// and every slice in it is type 1, a coded slice of a *non-IDR*
    /// picture. That is an open GOP, and the two packets behind it in decode
    /// order were presented before it.
    @Test func theOpenGOPPictureExit8SeeksToIsNotADecoderStartPoint() {
        let unit = accessUnit(types: [7, 8, 6, 6, 6, 1, 1, 1, 1], codec: .h264)
        let types = unit.withUnsafeBytes {
            VideoRandomAccessPoint.nalTypes(lengthPrefixed: $0, lengthSize: 4, codec: .h264)
        }
        #expect(types == [7, 8, 6, 6, 6, 1, 1, 1, 1])
        #expect(isStartPoint(unit, codec: .h264) == false)
    }

    @Test func anIDRIsADecoderStartPoint() {
        // What the same seek produces on the HLS transcode rung: one NAL,
        // type 5.
        #expect(isStartPoint(accessUnit(types: [5], codec: .h264), codec: .h264) == true)
        // And the ordinary in-band-parameter-set shape.
        #expect(
            isStartPoint(accessUnit(types: [7, 8, 5, 5], codec: .h264), codec: .h264) == true
        )
    }

    @Test func parameterSetsAloneDoNotMakeAStartPoint() {
        // The trap this exists to avoid: SPS + PPS present, so nothing is
        // *missing*, and the picture still cannot start a decoder.
        #expect(
            isStartPoint(accessUnit(types: [7, 8, 1], codec: .h264), codec: .h264) == false
        )
    }

    @Test func hevcCountsTheWholeIRAPRange() {
        for type in UInt8(16)...UInt8(21) {
            #expect(
                isStartPoint(accessUnit(types: [type], codec: .hevc), codec: .hevc) == true,
                "NAL type \(type) is an IRAP"
            )
        }
        // Trailing pictures, leading pictures and the reserved IRAP types
        // are not assumed decodable.
        for type in [UInt8(0), 1, 8, 9, 15, 22, 23] {
            #expect(
                isStartPoint(accessUnit(types: [type], codec: .hevc), codec: .hevc) == false,
                "NAL type \(type) is not a start point"
            )
        }
        // A real HEVC keyframe leads with its parameter sets.
        #expect(
            isStartPoint(accessUnit(types: [32, 33, 34, 19], codec: .hevc), codec: .hevc) == true
        )
    }

    @Test func theTypeIsReadOutOfTheRightBitsForEachCodec() {
        // 0x65 is an H.264 IDR slice with nal_ref_idc 3; the same byte read
        // as HEVC is type 50, which is not an IRAP. Reading it the wrong way
        // round is the whole failure mode.
        #expect(VideoRandomAccessPoint.Codec.h264.nalType(0x65) == 5)
        #expect(VideoRandomAccessPoint.Codec.hevc.nalType(0x65) == 50)
        #expect(VideoRandomAccessPoint.Codec.hevc.nalType(0x26) == 19)
    }

    @Test func everyLengthPrefixWidthIsWalked() {
        for lengthSize in 1...4 {
            let unit = accessUnit(types: [7, 8, 5], codec: .h264, lengthSize: lengthSize)
            #expect(
                isStartPoint(unit, codec: .h264, lengthSize: lengthSize) == true,
                "lengthSize \(lengthSize)"
            )
        }
    }

    /// nil is "cannot tell", and every caller treats that as "leave the
    /// packet alone" — a payload this cannot read must never be classified
    /// as droppable.
    @Test func anUnreadablePayloadIsNotClassified() {
        // A length prefix that runs past the end of the payload.
        let truncated = Data([0x00, 0x00, 0x10, 0x00, 0x65, 0xAA])
        #expect(isStartPoint(truncated, codec: .h264) == nil)
        // Empty, and a prefix with no room for a header byte.
        #expect(isStartPoint(Data(), codec: .h264) == nil)
        #expect(isStartPoint(Data([0x00, 0x00]), codec: .h264) == nil)
        // A zero-length NAL cannot be walked past.
        #expect(isStartPoint(Data([0, 0, 0, 0, 0x65]), codec: .h264) == nil)
        // Widths no configuration record can describe.
        let unit = accessUnit(types: [5], codec: .h264)
        #expect(isStartPoint(unit, codec: .h264, lengthSize: 0) == nil)
        #expect(isStartPoint(unit, codec: .h264, lengthSize: 5) == nil)
    }

    @Test func theLengthPrefixWidthComesOutOfTheConfigurationRecord() {
        // avcC: configurationVersion, profile, compat, level, then
        // 0b111111xx with lengthSizeMinusOne in the low two bits.
        let avcC = Data([0x01, 0x64, 0x00, 0x28, 0xFF, 0xE1])
        #expect(VideoRandomAccessPoint.nalLengthSize(configurationRecord: avcC, codec: .h264) == 4)
        #expect(
            VideoRandomAccessPoint.nalLengthSize(
                configurationRecord: Data([0x01, 0x64, 0x00, 0x28, 0xFC]),
                codec: .h264
            ) == 1
        )
        // hvcC puts the same field at byte 21, which is what the existing
        // rewriter reads — the two must agree.
        var hvcC = Data(repeating: 0, count: 23)
        hvcC[0] = 0x01
        hvcC[21] = 0xF3
        #expect(VideoRandomAccessPoint.nalLengthSize(configurationRecord: hvcC, codec: .hevc) == 4)
        #expect(
            VideoRandomAccessPoint.nalLengthSize(configurationRecord: hvcC, codec: .hevc)
                == HEVCNALUnitRewriter.nalLengthSize(hvcc: hvcC)
        )
        // A record too short to carry the field says so rather than guessing.
        #expect(
            VideoRandomAccessPoint.nalLengthSize(
                configurationRecord: Data([0x01, 0x64]), codec: .h264
            ) == nil
        )
        #expect(
            VideoRandomAccessPoint.nalLengthSize(
                configurationRecord: Data(repeating: 0, count: 8), codec: .hevc
            ) == nil
        )
    }
}
