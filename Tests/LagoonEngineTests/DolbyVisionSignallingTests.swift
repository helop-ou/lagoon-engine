import CoreMedia
import Foundation
import Libavcodec
import Libavutil
import Testing
@testable import LagoonEngine

/// The `dvvC` a profile 8 stream reaches VideoToolbox with. Profile 8.6 is
/// refused at session creation on an Apple TV, so it is signalled as 8.1.
@Suite("Dolby Vision signalling")
struct DolbyVisionSignallingTests {
    @Test func profile86IsSignalledAsProfile81() throws {
        let dvvC = try signalledDvvC(compatibilityID: 6)
        #expect(dvvC[2] >> 1 == 8, "profile 8")
        #expect(dvvC[4] >> 4 == 1, "bl signal compatibility id 1 (HDR10 base layer)")
    }

    @Test func otherProfile8CompatibilityIDsPassThrough() throws {
        for id: UInt8 in [1, 2, 4] {
            let dvvC = try signalledDvvC(compatibilityID: id)
            #expect(dvvC[4] >> 4 == id, "compatibility id \(id)")
        }
    }

    private func signalledDvvC(compatibilityID: UInt8) throws -> Data {
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

        let size = MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
        let entry = try #require(av_packet_side_data_new(
            &par.pointee.coded_side_data, &par.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF, size, 0
        ))
        entry.pointee.data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) {
            $0.pointee = AVDOVIDecoderConfigurationRecord(
                dv_version_major: 1,
                dv_version_minor: 0,
                dv_profile: 8,
                dv_level: 9,
                rpu_present_flag: 1,
                el_present_flag: 0,
                bl_present_flag: 1,
                dv_bl_signal_compatibility_id: compatibilityID,
                dv_md_compression: 0
            )
        }

        let description = try #require(SampleBufferFactory.videoFormatDescription(codecpar: par))
        #expect(CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_HEVC)
        let atoms = try #require(CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Data])
        let dvvC = try #require(atoms["dvvC"])
        #expect(dvvC.count == 24)
        return dvvC
    }
}
