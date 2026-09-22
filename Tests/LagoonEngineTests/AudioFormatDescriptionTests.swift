import CoreMedia
import Foundation
import Libavcodec
import Libavutil
import Testing
@testable import LagoonEngine

/// Compressed-audio format descriptions, pinned byte for byte. The E-AC-3 JOC
/// recipe was settled on hardware: `ec+3` plus a 16-channel presentation
/// engages Atmos, with the synthesized `dec3` box as the sample description
/// atom. A wrong bit plays as plain DD+ with every counter healthy.
///
/// JOC detection is FFmpeg's: its E-AC-3 parser sets profile 30
/// (`AV_PROFILE_EAC3_DDP_ATMOS`) from the bitstream, never a track name.
@Suite("Audio format descriptions")
struct AudioFormatDescriptionTests {
    /// `'ec+3'`, the subtype Apple's own JOC descriptions carry.
    private let jocFormatID = AudioFormatID(0x6563_2B33)

    @Test func eac3WithTheJOCProfileGetsTheAtmosShape() throws {
        let par = try codecParameters(codec: AV_CODEC_ID_EAC3, profile: 30, channels: 6, bitRate: 768_000)
        defer { free(par) }
        let (description, framesPerPacket) = try #require(SampleBufferFactory.audioFormatDescription(codecpar: par))
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(asbd.mFormatID == jocFormatID)
        #expect(asbd.mChannelsPerFrame == 16)
        #expect(asbd.mSampleRate == 48_000)
        #expect(asbd.mFramesPerPacket == 1_536)
        #expect(framesPerPacket == 1_536)
        // dec3 for 5.1 at 768 kbps, 48 kHz, one independent substream, with
        // flag_ec3_extension_type_a and 16 objects. The first five bytes match
        // FFmpeg's mp4 muxer for plain 5.1 768 kbps.
        #expect(try dec3Atom(of: description) == Data([0x18, 0x00, 0x20, 0x0F, 0x00, 0x01, 0x10]))
        #expect(try magicCookie(of: description) == Data([0x18, 0x00, 0x20, 0x0F, 0x00, 0x01, 0x10]))
    }

    @Test func eac3WithoutTheJOCProfileStaysPlainDDPlus() throws {
        let par = try codecParameters(codec: AV_CODEC_ID_EAC3, profile: 0, channels: 6, bitRate: 768_000)
        defer { free(par) }
        let (description, _) = try #require(SampleBufferFactory.audioFormatDescription(codecpar: par))
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(asbd.mFormatID == kAudioFormatEnhancedAC3)
        #expect(asbd.mChannelsPerFrame == 6)
        // Same box without the extension: no JOC flag, no object count.
        #expect(try dec3Atom(of: description) == Data([0x18, 0x00, 0x20, 0x0F, 0x00]))
    }

    @Test func sevenPointOneJOCCarriesTheDependentSubstream() throws {
        let par = try codecParameters(codec: AV_CODEC_ID_EAC3, profile: 30, channels: 8, bitRate: 1_536_000)
        defer { free(par) }
        let (description, _) = try #require(SampleBufferFactory.audioFormatDescription(codecpar: par))
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(asbd.mFormatID == jocFormatID)
        #expect(asbd.mChannelsPerFrame == 16)
        // num_dep_sub = 1 with the Lrs/Rrs location, then the JOC extension.
        #expect(try dec3Atom(of: description) == Data([0x30, 0x00, 0x20, 0x0F, 0x02, 0x02, 0x01, 0x10]))
    }

    @Test func stereoEAC3HasNoLFEAndNoSurrounds() throws {
        let par = try codecParameters(codec: AV_CODEC_ID_EAC3, profile: 0, channels: 2, bitRate: 256_000)
        defer { free(par) }
        let (description, _) = try #require(SampleBufferFactory.audioFormatDescription(codecpar: par))
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(asbd.mFormatID == kAudioFormatEnhancedAC3)
        #expect(asbd.mChannelsPerFrame == 2)
        #expect(try dec3Atom(of: description) == Data([0x08, 0x00, 0x20, 0x04, 0x00]))
    }

    @Test func ac3IsSelfDescribingAndTrueHDIsNotPassedThrough() throws {
        let ac3 = try codecParameters(codec: AV_CODEC_ID_AC3, profile: 0, channels: 6, bitRate: 640_000)
        defer { free(ac3) }
        let (description, _) = try #require(SampleBufferFactory.audioFormatDescription(codecpar: ac3))
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(asbd.mFormatID == kAudioFormatAC3)
        #expect(asbd.mChannelsPerFrame == 6)
        #expect(CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) == nil)

        // TrueHD has no renderer format: it decodes to LPCM, without objects,
        // so a switch to a JOC track changes the format entirely.
        let trueHD = try codecParameters(codec: AV_CODEC_ID_TRUEHD, profile: 30, channels: 8, bitRate: 0)
        defer { free(trueHD) }
        #expect(SampleBufferFactory.audioFormatDescription(codecpar: trueHD) == nil)
    }

    @Test func twoJOCTracksWithTheSameParametersDescribeTheSameFormat() throws {
        // Switching back to an equivalent track must compare equal, or the
        // renderer reconfigures for nothing.
        let first = try codecParameters(codec: AV_CODEC_ID_EAC3, profile: 30, channels: 6, bitRate: 768_000)
        let second = try codecParameters(codec: AV_CODEC_ID_EAC3, profile: 30, channels: 6, bitRate: 768_000)
        defer { free(first); free(second) }
        let a = try #require(SampleBufferFactory.audioFormatDescription(codecpar: first)).0
        let b = try #require(SampleBufferFactory.audioFormatDescription(codecpar: second)).0
        #expect(CMFormatDescriptionEqual(a, otherFormatDescription: b))
    }

    // MARK: - Helpers

    private func codecParameters(
        codec: AVCodecID, profile: Int32, channels: Int32, bitRate: Int64
    ) throws -> UnsafeMutablePointer<AVCodecParameters> {
        let par = try #require(avcodec_parameters_alloc())
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = codec
        par.pointee.profile = profile
        par.pointee.sample_rate = 48_000
        par.pointee.bit_rate = bitRate
        par.pointee.frame_size = codec == AV_CODEC_ID_TRUEHD ? 40 : 1_536
        av_channel_layout_default(&par.pointee.ch_layout, channels)
        return par
    }

    private func free(_ par: UnsafeMutablePointer<AVCodecParameters>) {
        var pointer: UnsafeMutablePointer<AVCodecParameters>? = par
        avcodec_parameters_free(&pointer)
    }

    private func dec3Atom(of description: CMFormatDescription) throws -> Data {
        let atoms = try #require(CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Data])
        return try #require(atoms["dec3"])
    }

    private func magicCookie(of description: CMFormatDescription) throws -> Data {
        var size = 0
        let cookie = try #require(CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size))
        return Data(bytes: cookie, count: size)
    }
}
