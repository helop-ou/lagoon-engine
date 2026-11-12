import CoreMedia
import CoreVideo
import Dovi
import Foundation
import Libavcodec
import Libavutil
import Testing
@testable import LagoonEngine

/// When the container's Dolby Vision record is dropped, replaced or
/// synthesized, and how the first RPU decides it.
@Suite("Dolby Vision record policy")
struct DolbyVisionRecordPolicyTests {
    private typealias Policy = DolbyVisionRecordPolicy

    @Test func profile82IsDropped() {
        #expect(Policy.signalled(container: record(profile: 8, compatibilityID: 2), stream: .init(), firstRPUProfile: nil) == nil)
        let profile81 = Policy.signalled(container: record(profile: 8, compatibilityID: 1), stream: .init(), firstRPUProfile: nil)
        #expect(profile81?.dv_bl_signal_compatibility_id == 1)
    }

    @Test func aProfile5RecordIsCheckedOnlyOverAnHDR10Base() {
        let profile5 = record(profile: 5, compatibilityID: 0)
        #expect(Policy.needsFirstRPU(container: profile5, stream: hdr10, isMatroska: false))
        #expect(!Policy.needsFirstRPU(container: profile5, stream: .init(), isMatroska: true))
        #expect(!Policy.needsFirstRPU(container: record(profile: 8, compatibilityID: 1), stream: hdr10, isMatroska: true))
    }

    @Test func aProfile5RecordFollowsItsFirstRPU() throws {
        let profile5 = record(profile: 5, compatibilityID: 0)
        let converted = try #require(Policy.signalled(container: profile5, stream: hdr10, firstRPUProfile: 8))
        #expect(converted.dv_profile == 8)
        #expect(converted.dv_bl_signal_compatibility_id == 1)
        #expect(converted.dv_level == profile5.dv_level)
        #expect(converted.rpu_present_flag == 1 && converted.bl_present_flag == 1 && converted.el_present_flag == 0)

        #expect(Policy.signalled(container: profile5, stream: hdr10, firstRPUProfile: 5)?.dv_profile == 5)
        // An unreadable RPU is no evidence against the record.
        #expect(Policy.signalled(container: profile5, stream: hdr10, firstRPUProfile: nil)?.dv_profile == 5)
    }

    @Test(arguments: [UInt8(0), 3, 5, 6, 7])
    func anOutOfSpecProfile8RecordTakesItsBaseLayersCompatibilityID(_ id: UInt8) throws {
        let container = record(profile: 8, compatibilityID: id)
        for stream in [hdr10, DolbyVisionRecordPolicy.Stream()] {
            let signalled = try #require(Policy.signalled(container: container, stream: stream, firstRPUProfile: nil))
            #expect(signalled.dv_profile == 8)
            #expect(signalled.dv_bl_signal_compatibility_id == 1)
            #expect(signalled.dv_level == container.dv_level)
        }
        #expect(Policy.signalled(container: container, stream: hlg, firstRPUProfile: nil)?.dv_bl_signal_compatibility_id == 4)
        #expect(Policy.signalled(container: container, stream: sdr, firstRPUProfile: nil) == nil)
    }

    @Test(arguments: [UInt8(1), 4])
    func aProfile8RecordInSpecIsLeftAlone(_ id: UInt8) {
        let container = record(profile: 8, compatibilityID: id)
        for stream in [hdr10, hlg, sdr] {
            #expect(Policy.signalled(container: container, stream: stream, firstRPUProfile: 7)?.dv_bl_signal_compatibility_id == id)
            #expect(!Policy.needsFirstRPU(container: container, stream: stream, isMatroska: true))
            #expect(!Policy.convertsProfile7RPUs(container: container, stream: stream, firstRPU: fullEnhancementLayer))
        }
    }

    @Test(arguments: [UInt8(0), 3, 5, 6])
    func anOutOfSpecProfile8RecordIsCheckedOnlyOverAPQBase(_ id: UInt8) {
        let container = record(profile: 8, compatibilityID: id)
        #expect(Policy.needsFirstRPU(container: container, stream: hdr10, isMatroska: false))
        #expect(Policy.needsFirstRPU(container: container, stream: .init(), isMatroska: false))
        #expect(!Policy.needsFirstRPU(container: container, stream: hlg, isMatroska: true))
        #expect(!Policy.needsFirstRPU(container: container, stream: sdr, isMatroska: true))
        #expect(!Policy.needsFirstRPU(container: record(profile: 8, compatibilityID: 2), stream: hdr10, isMatroska: true))
    }

    @Test(arguments: [UInt8(0), 3, 5, 6])
    func onlyFullEnhancementLayerMetadataIsConverted(_ id: UInt8) {
        let container = record(profile: 8, compatibilityID: id)
        #expect(Policy.convertsProfile7RPUs(container: container, stream: hdr10, firstRPU: fullEnhancementLayer))
        #expect(Policy.convertsProfile7RPUs(container: container, stream: .init(), firstRPU: fullEnhancementLayer))

        let minimal = Policy.FirstRPU(profile: 7, expectsFullEnhancementLayer: false)
        #expect(!Policy.convertsProfile7RPUs(container: container, stream: hdr10, firstRPU: minimal))
        #expect(!Policy.convertsProfile7RPUs(container: container, stream: hdr10, firstRPU: Policy.FirstRPU(profile: 8)))
        // An unreadable RPU is no evidence: the stream is only relabelled.
        #expect(!Policy.convertsProfile7RPUs(container: container, stream: hdr10, firstRPU: nil))
        #expect(!Policy.convertsProfile7RPUs(container: container, stream: hlg, firstRPU: fullEnhancementLayer))
        #expect(!Policy.convertsProfile7RPUs(container: container, stream: sdr, firstRPU: fullEnhancementLayer))
    }

    @Test func otherRecordsAreNeverConverted() {
        #expect(!Policy.convertsProfile7RPUs(container: nil, stream: hdr10, firstRPU: fullEnhancementLayer))
        for (profile, id) in [(UInt8(5), UInt8(0)), (8, 2), (4, 6)] {
            let container = record(profile: profile, compatibilityID: id)
            #expect(!Policy.convertsProfile7RPUs(container: container, stream: hdr10, firstRPU: fullEnhancementLayer))
        }
    }

    @Test(arguments: zip(DolbyVisionProfileConverterTests.fixtures, [false, true]))
    func aProfile7RPUSaysWhichEnhancementLayerItExpects(
        _ fixture: DolbyVisionProfileConverterTests.RPUFixture,
        full: Bool
    ) throws {
        let shipped = try #require(Data(base64Encoded: fixture.originalBase64))
        let packet = try lengthPrefixed([slice, Data([0x7C, 0x01]) + shipped.dropFirst(4)])
        let firstRPU = packet.withUnsafeBytes { Policy.firstRPU(in: $0, lengthSize: 4) }
        #expect(firstRPU == Policy.FirstRPU(profile: 7, expectsFullEnhancementLayer: full))
    }

    @Test func onlyAnUntaggedTenBitMatroskaStreamIsCheckedWithoutARecord() {
        #expect(Policy.needsFirstRPU(container: nil, stream: .init(), isMatroska: true))
        #expect(!Policy.needsFirstRPU(container: nil, stream: .init(), isMatroska: false))
        #expect(!Policy.needsFirstRPU(container: nil, stream: hdr10, isMatroska: true))
        var eightBit = DolbyVisionRecordPolicy.Stream()
        eightBit.profile = AV_PROFILE_HEVC_MAIN
        #expect(!Policy.needsFirstRPU(container: nil, stream: eightBit, isMatroska: true))
        var av1 = DolbyVisionRecordPolicy.Stream()
        av1.codecID = AV_CODEC_ID_AV1
        #expect(!Policy.needsFirstRPU(container: nil, stream: av1, isMatroska: true))
    }

    @Test func aMissingRecordIsSynthesizedOnlyForAProfile5RPU() throws {
        var stream = DolbyVisionRecordPolicy.Stream()
        stream.frameRate = 24_000.0 / 1001
        let synthesized = try #require(Policy.signalled(container: nil, stream: stream, firstRPUProfile: 5))
        #expect(synthesized.dv_profile == 5)
        #expect(synthesized.dv_level == 6)
        #expect(synthesized.dv_bl_signal_compatibility_id == 0)
        #expect(synthesized.rpu_present_flag == 1 && synthesized.bl_present_flag == 1 && synthesized.el_present_flag == 0)

        #expect(Policy.signalled(container: nil, stream: stream, firstRPUProfile: 8) == nil)
        #expect(Policy.signalled(container: nil, stream: stream, firstRPUProfile: nil) == nil)
    }

    @Test(arguments: [
        (1280, 720, 24.0, UInt8(1)),
        (1920, 1080, 23.976, UInt8(3)),
        (1920, 1080, 60.0, UInt8(5)),
        (3840, 2160, 23.976, UInt8(6)),
        (3840, 2160, 60.0, UInt8(9)),
        // Unknown counts as 60.
        (3840, 2160, 0.0, UInt8(9)),
        (7680, 4320, 24.0, UInt8(11)),
        (7680, 4320, 60.0, UInt8(12)),
    ])
    func theLevelHoldsThePixelRateAndWidth(_ width: Int32, _ height: Int32, _ frameRate: Double, _ level: UInt8) {
        var stream = DolbyVisionRecordPolicy.Stream()
        stream.width = width
        stream.height = height
        stream.frameRate = frameRate
        #expect(Policy.level(for: stream) == level)
    }

    @Test(arguments: [("5", UInt8(5)), ("8.1", UInt8(8))])
    func theFirstRPUInAPacketGivesItsProfile(_ generated: String, _ profile: UInt8) throws {
        let packet = try lengthPrefixed([slice, try generatedRPU(profile: generated)])
        #expect(packet.withUnsafeBytes { Policy.firstRPU(in: $0, lengthSize: 4) } == Policy.FirstRPU(profile: profile))
    }

    @Test func aPacketWithoutAnIntactRPUGivesNone() throws {
        let none = try lengthPrefixed([slice])
        #expect(none.withUnsafeBytes { Policy.firstRPU(in: $0, lengthSize: 4) } == nil)

        // The MEL fixture with the bit that aborts libdovi flipped, as the
        // converter's test does. Without the checksum this aborts the process.
        let mel = try #require(DolbyVisionProfileConverterTests.fixtures.first)
        let shipped = try #require(Data(base64Encoded: mel.originalBase64))
        var rpu = Data([0x7C, 0x01]) + shipped.dropFirst(4)
        rpu[177 / 8] ^= UInt8(0x80 >> (177 % 8))
        let corrupt = try lengthPrefixed([slice, rpu])
        #expect(corrupt.withUnsafeBytes { Policy.firstRPU(in: $0, lengthSize: 4) } == nil)
    }

    // MARK: - Helpers

    private var hdr10: DolbyVisionRecordPolicy.Stream {
        var stream = DolbyVisionRecordPolicy.Stream()
        stream.primaries = AVCOL_PRI_BT2020
        stream.transfer = AVCOL_TRC_SMPTE2084
        stream.matrix = AVCOL_SPC_BT2020_NCL
        return stream
    }

    private var hlg: DolbyVisionRecordPolicy.Stream {
        var stream = DolbyVisionRecordPolicy.Stream()
        stream.primaries = AVCOL_PRI_BT2020
        stream.transfer = AVCOL_TRC_ARIB_STD_B67
        stream.matrix = AVCOL_SPC_BT2020_NCL
        return stream
    }

    private var sdr: DolbyVisionRecordPolicy.Stream {
        var stream = DolbyVisionRecordPolicy.Stream()
        stream.primaries = AVCOL_PRI_BT709
        stream.transfer = AVCOL_TRC_BT709
        stream.matrix = AVCOL_SPC_BT709
        return stream
    }

    private var fullEnhancementLayer: DolbyVisionRecordPolicy.FirstRPU {
        .init(profile: 7, expectsFullEnhancementLayer: true)
    }

    /// An IDR slice header's two bytes and some payload. Never decoded.
    private var slice: Data { Data([0x26, 0x01, 0xAF, 0x00, 0x11]) }

    private func record(profile: UInt8, compatibilityID: UInt8) -> AVDOVIDecoderConfigurationRecord {
        AVDOVIDecoderConfigurationRecord(
            dv_version_major: 1,
            dv_version_minor: 0,
            dv_profile: profile,
            dv_level: 6,
            rpu_present_flag: 1,
            el_present_flag: 0,
            bl_present_flag: 1,
            dv_bl_signal_compatibility_id: compatibilityID,
            dv_md_compression: 0
        )
    }

    /// One type-62 NAL from its header, as libdovi generates it for
    /// `profile`, dovi_tool's "5", "8.1" or "8.4".
    private func generatedRPU(profile: String) throws -> Data {
        let json = #"{"cm_version":"V40","length":1,"shots":[{"start":0,"duration":1}],"profile":"\#(profile)"}"#
        let list = try #require(dovi_generate_from_json(json))
        defer { dovi_rpu_list_free(list) }
        try #require(list.pointee.len == 1)
        let rpu = try #require(list.pointee.list[0])
        let written = try #require(dovi_write_unspec62_nalu(rpu))
        defer { dovi_data_free(written) }
        return Data(bytes: try #require(written.pointee.data), count: written.pointee.len)
    }

    private func lengthPrefixed(_ units: [Data]) throws -> Data {
        var packet = Data()
        for unit in units {
            withUnsafeBytes(of: UInt32(unit.count).bigEndian) { packet.append(contentsOf: $0) }
            packet.append(unit)
        }
        return packet
    }
}

/// `untagged-p5.mkv`: twelve 64x64 frames of 10-bit HEVC with no colorimetry
/// and no Dolby Vision record, each carrying the profile 5 RPU libdovi
/// generates. x265 (`aud=1:repeat-headers=1:keyint=12:bframes=0`) to Annex B,
/// the RPU appended to each access unit, then
/// `ffmpeg -c copy -bsf:v "setts=pts=N/(24*TB):dts=N/(24*TB)" -f matroska`.
@Suite("Dolby Vision record from the first RPU")
struct DolbyVisionFirstRPUDemuxTests {
    @Test func anUntaggedProfile5StreamOpensAsDolbyVisionFromItsFirstFrame() throws {
        let url = try #require(Bundle.module.url(
            forResource: "untagged-p5", withExtension: "mkv", subdirectory: "UntaggedDolbyVision"
        ))
        let demuxer = FFmpegDemuxer(capabilities: PlaybackCapabilities(hardwareHEVC: false))
        defer { demuxer.close() }
        try demuxer.open(url: url.path(percentEncoded: false), recommendedPixelBufferAttributes: CVPixelBufferAttributes())

        let description = try #require(demuxer.videoStream?.formatDescription)
        #expect(CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_DolbyVisionHEVC)
        let atoms = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any]
        let dvcC = try #require(atoms?["dvcC"] as? Data)
        #expect(dvcC[2] >> 1 == 5, "profile 5")

        // Reading the RPU rewound, so no frame is lost.
        var timestamps: [Double] = []
        reading: for _ in 0..<100 {
            switch demuxer.readNext() {
            case .video(let buffer):
                timestamps.append(CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
            case .endOfFile, .failed:
                break reading
            default:
                continue
            }
        }
        #expect(timestamps.count == 12)
        #expect(timestamps.first == 0)
    }
}

/// `profile-8-6-mel.mkv` and `profile-8-6-fel.mkv`: twelve 64x64 frames of
/// 10-bit PQ HEVC under a profile 8 record with compatibility id 6, each
/// carrying dovi_tool's profile 7 MEL or FEL test RPU. x265
/// (`aud=1:repeat-headers=1:keyint=12:bframes=0` and the BT.2020 PQ
/// colorimetry) to Annex B, the RPU appended to each access unit, then
/// `ffmpeg -c copy -bsf:v "setts=pts=N/(24*TB):dts=N/(24*TB)" -tag:v hvc1
/// -f mp4`, a `dvvC` box added after the `hvcC`, and `ffmpeg -c copy
/// -f matroska`.
@Suite("Out-of-spec Dolby Vision profile 8")
struct OutOfSpecDolbyVisionProfile8DemuxTests {
    @Test func metadataForAFullEnhancementLayerIsConverted() throws {
        let stream = try read("profile-8-6-fel")
        #expect(stream.compatibilityID == 1)
        #expect(stream.rpuProfiles == Array(repeating: 8, count: 12))
        #expect(stream.fullEnhancementLayerRPUs == 0)
        let stats = try #require(stream.rewriteStats)
        #expect(stats.mode == .convert)
        #expect(stats.rpusConverted == 12)
        #expect(stats.errors == 0)
        #expect(stats.enhancementLayerType == "FEL")
    }

    @Test func metadataForAMinimalEnhancementLayerPassesThrough() throws {
        let stream = try read("profile-8-6-mel")
        #expect(stream.compatibilityID == 1)
        #expect(stream.rpuProfiles == Array(repeating: 7, count: 12))
        #expect(stream.rewriteStats == nil)
    }

    @Test func strippingLeavesAnOutOfSpecProfile8StreamRelabelled() throws {
        let stream = try read("profile-8-6-fel", mode: .stripToHDR10)
        #expect(stream.compatibilityID == 1)
        #expect(stream.rpuProfiles == Array(repeating: 7, count: 12))
        #expect(stream.rewriteStats == nil)
    }

    private struct Stream {
        var compatibilityID: UInt8
        var rpuProfiles: [UInt8] = []
        var fullEnhancementLayerRPUs = 0
        var rewriteStats: DolbyVisionRewriteStats?
    }

    private func read(_ name: String, mode: DolbyVisionProfile7Mode = .convert) throws -> Stream {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "mkv", subdirectory: "OutOfSpecDolbyVision"
        ))
        let demuxer = FFmpegDemuxer(capabilities: PlaybackCapabilities(hardwareHEVC: false))
        defer { demuxer.close() }
        demuxer.dolbyVisionProfile7Mode = mode
        try demuxer.open(url: url.path(percentEncoded: false), recommendedPixelBufferAttributes: CVPixelBufferAttributes())

        let description = try #require(demuxer.videoStream?.formatDescription)
        #expect(CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_HEVC)
        let atoms = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any]
        let dvvC = try #require(atoms?["dvvC"] as? Data)
        #expect(dvvC[2] >> 1 == 8, "profile 8")
        var stream = Stream(compatibilityID: dvvC[4] >> 4)

        var timestamps: [Double] = []
        reading: for _ in 0..<100 {
            switch demuxer.readNext() {
            case .video(let buffer):
                timestamps.append(CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
                let block = try #require(CMSampleBufferGetDataBuffer(buffer))
                var payload = Data(count: CMBlockBufferGetDataLength(block))
                let status = payload.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                #expect(status == noErr)
                if let rpu = payload.withUnsafeBytes({ DolbyVisionRecordPolicy.firstRPU(in: $0, lengthSize: 4) }) {
                    stream.rpuProfiles.append(rpu.profile)
                    stream.fullEnhancementLayerRPUs += rpu.expectsFullEnhancementLayer ? 1 : 0
                }
            case .endOfFile, .failed:
                break reading
            default:
                continue
            }
        }
        // Reading the first RPU rewound, so no frame is lost.
        #expect(timestamps.count == 12)
        #expect(timestamps.first == 0)
        stream.rewriteStats = demuxer.dolbyVisionRewriteStats
        return stream
    }
}
