import Foundation
import Libavcodec

/// What this engine can decode, as data. `docs/codec-support.md` is rendered
/// from it.
///
/// The real decision lives in `FFmpegDemuxer.usesCompressedVideoPath` and
/// `SoftwareVideoDecoder.supports`; tests pin this table against both.
/// Internal because entries carry `AVCodecID`, which stays out of the public API.
nonisolated enum EngineCodecSupport {
    enum VideoPath: String {
        /// Handed to AVFoundation compressed.
        case videoToolbox = "VideoToolbox"
        /// Decoded by libavcodec on the CPU.
        case software = "Software"
        /// VideoToolbox if it can make a session for the stream, else libavcodec.
        case either = "VideoToolbox, software fallback"
    }

    struct Video {
        let id: AVCodecID
        let name: String
        let path: VideoPath
        /// True when the software path takes this codec only interlaced.
        let softwareOnlyWhenInterlaced: Bool
        let note: String

        init(
            _ id: AVCodecID,
            _ name: String,
            _ path: VideoPath,
            softwareOnlyWhenInterlaced: Bool = false,
            note: String
        ) {
            self.id = id
            self.name = name
            self.path = path
            self.softwareOnlyWhenInterlaced = softwareOnlyWhenInterlaced
            self.note = note
        }
    }

    struct Audio {
        let name: String
        /// The CoreAudio format passed through, or nil when decoded to PCM.
        let native: String?
        let note: String
    }

    static let video: [Video] = [
        Video(AV_CODEC_ID_H264, "H.264", .either, softwareOnlyWhenInterlaced: true, note:
            "Progressive H.264 is handed to the renderer compressed. Interlaced "
            + "H.264 decodes in software, because that is the only path with a "
            + "deinterlacer."),
        Video(AV_CODEC_ID_HEVC, "HEVC", .videoToolbox, note:
            "Always compressed, interlaced included. There is no software "
            + "fallback, and a device without HEVC hardware fails the title "
            + "rather than decoding it on the CPU."),
        Video(AV_CODEC_ID_AV1, "AV1", .either, note:
            "VideoToolbox when the device can make a session for the stream, "
            + "and libdav1d when it cannot. Which one you get is decided by "
            + "trying, once, at open."),
        Video(AV_CODEC_ID_VP9, "VP9", .software, note: "Always software."),
        Video(AV_CODEC_ID_VC1, "VC-1", .software, note:
            "Always software: Apple ships no VideoToolbox decoder for it."),
        Video(AV_CODEC_ID_WMV3, "WMV3", .software, note:
            "Always software: Apple ships no VideoToolbox decoder for it."),
        Video(AV_CODEC_ID_MPEG4, "MPEG-4 Part 2", .software, note:
            "Always software. The Xvid and DivX envelope."),
        Video(AV_CODEC_ID_MPEG2VIDEO, "MPEG-2", .software, note:
            "Always software, and deinterlaced when the frames say they are "
            + "interlaced."),
    ]

    static let audio: [Audio] = [
        Audio(name: "AAC", native: "kAudioFormatMPEG4AAC", note:
            "Passed through with the stream's own AudioSpecificConfig."),
        Audio(name: "AC-3", native: "kAudioFormatAC3", note:
            "Passed through, except alongside software-decoded video, where it "
            + "is decoded to PCM instead: the two together interrupted audio."),
        Audio(name: "E-AC-3", native: "kAudioFormatEnhancedAC3", note:
            "Passed through with a synthesized EC3SpecificBox."),
        Audio(name: "E-AC-3 with Atmos", native: "'ec+3'", note:
            "Joint object coding is passed through whole. Tagging it as "
            + "ordinary E-AC-3 would have the system decode the core only."),
        Audio(name: "MP3", native: "kAudioFormatMPEGLayer3", note: "Passed through."),
        Audio(name: "Anything else", native: nil, note:
            "Decoded to linear PCM by the linked FFmpeg build, which is what "
            + "decides the real list — this engine keeps no allow-list. DTS, "
            + "TrueHD, FLAC, Opus and Vorbis reach the renderer this way. "
            + "TrueHD is never passed through, Atmos or not."),
    ]
}
