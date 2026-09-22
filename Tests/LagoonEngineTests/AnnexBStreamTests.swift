import Foundation
import Testing
@testable import LagoonEngine

/// The 118 bytes libavformat hands over as `extradata` for WALL·E's Blu-ray
/// video track, copied off the disc itself.
///
/// This is the record that produced "VideoToolbox could not create a hardware
/// decoder" on hardware: it arrives in the field an `hvcC` would, and it is
/// three Annex-B parameter sets. Nothing about it is malformed, and reading
/// it as a configuration record describes a stream that does not exist.
private let wallEExtradata = Data([
    0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x22, 0x20, 0x00, 0x00, 0x03, 0x00,
    0xb0, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x99, 0x14, 0x8c, 0x0c, 0x00, 0x00, 0x0f, 0xa4,
    0x00, 0x01, 0x77, 0x01, 0x40, 0x00, 0x00, 0x00, 0x00, 0x01, 0x42, 0x01, 0x01, 0x22, 0x20, 0x00,
    0x00, 0x03, 0x00, 0xb0, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x99, 0xa0, 0x01, 0xe0, 0x20,
    0x02, 0x1c, 0x4d, 0xb1, 0x48, 0xe4, 0x90, 0xa5, 0x0b, 0xc0, 0x6d, 0x42, 0x44, 0x02, 0x6d, 0x94,
    0x00, 0x00, 0x0f, 0xa4, 0x00, 0x01, 0x77, 0x01, 0x89, 0x30, 0x39, 0x78, 0x00, 0x05, 0x01, 0xbc,
    0x00, 0x17, 0xd7, 0xbe, 0x78, 0xf1, 0xe8, 0x00, 0x00, 0x00, 0x00, 0x01, 0x44, 0x01, 0xc1, 0x72,
    0x4d, 0xa2, 0x3f, 0xb6, 0x40, 0x00,
])

@Suite("Annex-B streams")
struct AnnexBStreamTests {
    @Test func aStartCodeStreamIsToldApartFromAConfigurationRecord() {
        #expect(AnnexBStream.usesStartCodes(wallEExtradata))
        #expect(AnnexBStream.usesStartCodes(Data([0, 0, 1, 0x40])))
        // Both real records open with a configuration version of 1, so
        // neither can be mistaken for a start code.
        #expect(!AnnexBStream.usesStartCodes(Data([0x01, 0x22, 0x20, 0x00, 0x00])))
        #expect(!AnnexBStream.usesStartCodes(Data([0x01, 0x64, 0x00, 0x28])))
        #expect(!AnnexBStream.usesStartCodes(Data()))
    }

    @Test func theDiscsOwnParameterSetsComeOutInDecoderOrder() throws {
        let sets = try #require(AnnexBStream.parameterSets(inAnnexB: wallEExtradata, codec: .hevc))
        #expect(sets.count == 3)
        // VPS, SPS, PPS: 32, 33, 34, in the order the decoder is handed them.
        #expect(sets.map { ($0[$0.startIndex] >> 1) & 0x3F } == [32, 33, 34])
        // Padding is trimmed; a parameter set never ends on a zero byte.
        #expect(sets.allSatisfy { $0.last != 0 })
        #expect(sets.allSatisfy { !$0.isEmpty })
    }

    @Test func aMissingParameterSetRefusesRatherThanDescribingHalfAStream() {
        // VPS and SPS but no PPS. Building a description from this is the
        // failure the whole path exists to avoid, so it declines and leaves
        // the ladder to fall back to the server.
        let truncated = wallEExtradata.prefix(0x68)
        #expect(AnnexBStream.parameterSets(inAnnexB: truncated, codec: .hevc) == nil)
        // H.264 reads its type from different bits, so HEVC sets are not
        // mistaken for its own.
        #expect(AnnexBStream.parameterSets(inAnnexB: wallEExtradata, codec: .h264) == nil)
    }

    @Test func everyNalIsRewrittenWithItsLength() throws {
        // Three units behind start codes of both lengths, since a stream
        // mixes them: four bytes before a parameter set, three before a
        // slice, in most encoders.
        let payload = Data([
            0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0xaa,
            0x00, 0x00, 0x01, 0x42, 0x01, 0xbb, 0xcc,
            0x00, 0x00, 0x01, 0x26, 0x01,
        ])
        let converted = try #require(payload.withUnsafeBytes { AnnexBStream.lengthPrefixed($0) })
        #expect(Array(converted) == [
            0, 0, 0, 3, 0x40, 0x01, 0xaa,
            0, 0, 0, 4, 0x42, 0x01, 0xbb, 0xcc,
            0, 0, 0, 2, 0x26, 0x01,
        ])
    }

    @Test func aPayloadWithNoStartCodesConvertsToNothingRatherThanToGarbage() {
        let lengthPrefixed = Data([0x00, 0x00, 0x00, 0x03, 0x40, 0x01, 0xaa])
        // Already-framed bytes have no start code to find, so this reports
        // nothing to convert instead of inventing a NAL.
        #expect(lengthPrefixed.withUnsafeBytes { AnnexBStream.lengthPrefixed($0) } == nil)
        #expect(Data().withUnsafeBytes { AnnexBStream.lengthPrefixed($0) } == nil)
    }

    @Test func conversionSurvivesTheBytesThatLookLikeStartCodes() throws {
        // Emulation prevention guarantees 00 00 00 or 00 00 01 cannot occur
        // inside a NAL, but trailing zeros before the next start code can,
        // and they belong to the unit that precedes them.
        let payload = Data([
            0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0x00, 0x00, 0x03, 0x01,
            0x00, 0x00, 0x00, 0x01, 0x42, 0x01,
        ])
        let converted = try #require(payload.withUnsafeBytes { AnnexBStream.lengthPrefixed($0) })
        #expect(Array(converted) == [
            0, 0, 0, 6, 0x40, 0x01, 0x00, 0x00, 0x03, 0x01,
            0, 0, 0, 2, 0x42, 0x01,
        ])
    }
}
