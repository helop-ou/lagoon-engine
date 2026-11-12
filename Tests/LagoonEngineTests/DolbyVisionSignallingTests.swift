import CoreMedia
import Foundation
import Libavcodec
import Libavutil
import Testing
@testable import LagoonEngine

/// The Dolby Vision atoms a stream reaches VideoToolbox with. Profile 8.6 is
/// refused at session creation on an Apple TV, so it and the other
/// out-of-spec profile 8 ids are signalled as 8.1, and
/// `DolbyVisionRecordPolicy` fixes a wrong or missing record.
@Suite("Dolby Vision signalling")
struct DolbyVisionSignallingTests {
    @Test(arguments: [UInt8(0), 3, 5, 6])
    func anOutOfSpecProfile8IDIsSignalledAsProfile81(_ id: UInt8) throws {
        let dvvC = try signalledDvvC(compatibilityID: id)
        #expect(dvvC[2] >> 1 == 8, "profile 8")
        #expect(dvvC[4] >> 4 == 1, "bl signal compatibility id 1 (HDR10 base layer)")
    }

    @Test func otherProfile8CompatibilityIDsPassThrough() throws {
        for id: UInt8 in [1, 4] {
            let dvvC = try signalledDvvC(compatibilityID: id)
            #expect(dvvC[4] >> 4 == id, "compatibility id \(id)")
        }
    }

    @Test func profile82PlaysItsSDRBase() throws {
        let atoms = try signalledAtoms(record: record(profile: 8, compatibilityID: 2))
        #expect(CMFormatDescriptionGetMediaSubType(atoms.description) == kCMVideoCodecType_HEVC)
        #expect(atoms.dvvC == nil)
        #expect(atoms.dvcC == nil)
    }

    @Test func aProfile5RecordOverAnHDR10BaseIsSignalledAs81() throws {
        let atoms = try signalledAtoms(
            record: record(profile: 5, compatibilityID: 0),
            hdr10: true,
            firstRPUProfile: 8
        )
        #expect(CMFormatDescriptionGetMediaSubType(atoms.description) == kCMVideoCodecType_HEVC)
        #expect(atoms.dvcC == nil)
        let dvvC = try #require(atoms.dvvC)
        #expect(dvvC[2] >> 1 == 8, "profile 8")
        #expect(dvvC[4] >> 4 == 1, "bl signal compatibility id 1 (HDR10 base layer)")
    }

    @Test func aProfile5StreamWithoutARecordGetsOne() throws {
        let atoms = try signalledAtoms(record: nil, firstRPUProfile: 5)
        #expect(CMFormatDescriptionGetMediaSubType(atoms.description) == kCMVideoCodecType_DolbyVisionHEVC)
        #expect(atoms.dvvC == nil)
        let dvcC = try #require(atoms.dvcC)
        #expect(dvcC[2] >> 1 == 5, "profile 5")
        #expect(dvcC[3] & 0b101 == 0b101, "rpu and base layer present")
    }

    private func signalledDvvC(compatibilityID: UInt8) throws -> Data {
        let atoms = try signalledAtoms(record: record(profile: 8, compatibilityID: compatibilityID))
        #expect(CMFormatDescriptionGetMediaSubType(atoms.description) == kCMVideoCodecType_HEVC)
        let dvvC = try #require(atoms.dvvC)
        #expect(dvvC.count == 24)
        return dvvC
    }

    private func record(profile: UInt8, compatibilityID: UInt8) -> AVDOVIDecoderConfigurationRecord {
        AVDOVIDecoderConfigurationRecord(
            dv_version_major: 1,
            dv_version_minor: 0,
            dv_profile: profile,
            dv_level: 9,
            rpu_present_flag: 1,
            el_present_flag: 0,
            bl_present_flag: 1,
            dv_bl_signal_compatibility_id: compatibilityID,
            dv_md_compression: 0
        )
    }

    private struct SignalledAtoms {
        let description: CMFormatDescription
        let dvvC: Data?
        let dvcC: Data?
    }

    private func signalledAtoms(
        record: AVDOVIDecoderConfigurationRecord?,
        hdr10: Bool = false,
        firstRPUProfile: UInt8? = nil
    ) throws -> SignalledAtoms {
        let par = try #require(avcodec_parameters_alloc())
        defer {
            var pointer: UnsafeMutablePointer<AVCodecParameters>? = par
            avcodec_parameters_free(&pointer)
        }
        par.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        par.pointee.codec_id = AV_CODEC_ID_HEVC
        par.pointee.width = 3840
        par.pointee.height = 2160
        // Never parsed here: CoreMedia keeps the hvcC as an opaque atom.
        let hvcC = Data(count: 23)
        let extradata = try #require(av_mallocz(hvcC.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)))
        par.pointee.extradata = extradata.assumingMemoryBound(to: UInt8.self)
        par.pointee.extradata_size = Int32(hvcC.count)

        if hdr10 {
            par.pointee.color_primaries = AVCOL_PRI_BT2020
            par.pointee.color_trc = AVCOL_TRC_SMPTE2084
            par.pointee.color_space = AVCOL_SPC_BT2020_NCL
        }

        if let record {
            let size = MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
            let entry = try #require(av_packet_side_data_new(
                &par.pointee.coded_side_data, &par.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF, size, 0
            ))
            entry.pointee.data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) {
                $0.pointee = record
            }
        }

        let description = try #require(SampleBufferFactory.videoFormatDescription(
            codecpar: par,
            firstRPUProfile: firstRPUProfile,
            frameRate: 24
        ))
        let atoms = try #require(CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Data])
        return SignalledAtoms(description: description, dvvC: atoms["dvvC"], dvcC: atoms["dvcC"])
    }
}
