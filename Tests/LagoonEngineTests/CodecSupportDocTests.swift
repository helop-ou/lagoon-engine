import Foundation
import Libavcodec
import Testing
@testable import LagoonEngine

/// Renders `EngineCodecSupport` as the published codec table, and pins that
/// table against the code that actually routes a stream.
///
/// Generated rather than written by hand, for the reason a hand-written list
/// always ends up wrong: it drifts from the switches the moment somebody adds
/// a codec to one of them. Here the drift is a test failure instead.
///
/// `scripts/generate-codec-support.sh` runs this and copies the result into
/// `docs/codec-support.md`; its `--check` mode fails instead of copying.
@Suite("Codec support document")
struct CodecSupportDocTests {
    @Test func writesTheCodecSupportDocument() {
        // Printed rather than written to a file: a package test target runs
        // in a generic runner whose container is cleared once the run ends,
        // so a path reported from inside it is gone by the time a script
        // looks. The markers are what the script cuts between.
        print("CODEC_SUPPORT_DOC_BEGIN")
        print(CodecSupportDocument.render())
        print("CODEC_SUPPORT_DOC_END")
    }

    @Test func theTableAgreesWithTheCompressedPath() {
        // Every codec the table calls VideoToolbox must be one the demuxer
        // actually sends there, and nothing the table calls software-only
        // may be.
        let capabilities = PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: true)
        for entry in EngineCodecSupport.video {
            let compressed = FFmpegDemuxer.usesCompressedVideoPath(
                codecID: entry.id, capabilities: capabilities, interlaced: false
            )
            switch entry.path {
            case .videoToolbox, .either:
                #expect(compressed, "\(entry.name) is documented as compressed but is not routed there")
            case .software:
                #expect(!compressed, "\(entry.name) is documented as software but is routed compressed")
            }
        }
    }

    @Test func theTableAgreesWithTheSoftwareDecoder() {
        for entry in EngineCodecSupport.video {
            let progressive = SoftwareVideoDecoder.supports(codecID: entry.id, interlaced: false)
            let interlaced = SoftwareVideoDecoder.supports(codecID: entry.id, interlaced: true)
            if entry.softwareOnlyWhenInterlaced {
                #expect(!progressive, "\(entry.name) should reach software only interlaced")
                #expect(interlaced, "\(entry.name) is documented as deinterlaced in software")
            } else if entry.path == .software || entry.path == .either {
                #expect(progressive, "\(entry.name) is documented as software-capable but is refused")
            }
        }
    }

    @Test func nothingTheEngineDecodesIsMissingFromTheTable() {
        // The other direction: a codec added to either router without a table
        // entry would otherwise publish a document that understates the
        // engine, which is the drift that is easy to miss.
        let documented = Set(EngineCodecSupport.video.map(\.id.rawValue))
        let everyCodec = [
            AV_CODEC_ID_H264, AV_CODEC_ID_HEVC, AV_CODEC_ID_AV1, AV_CODEC_ID_VP9,
            AV_CODEC_ID_VC1, AV_CODEC_ID_WMV3, AV_CODEC_ID_MPEG4, AV_CODEC_ID_MPEG2VIDEO,
            AV_CODEC_ID_MJPEG, AV_CODEC_ID_THEORA, AV_CODEC_ID_PRORES, AV_CODEC_ID_FLV1,
        ]
        let capabilities = PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: true)
        for codec in everyCodec {
            let routed = FFmpegDemuxer.usesCompressedVideoPath(
                codecID: codec, capabilities: capabilities, interlaced: false
            ) || SoftwareVideoDecoder.supports(codecID: codec, interlaced: false)
                || SoftwareVideoDecoder.supports(codecID: codec, interlaced: true)
            if routed {
                #expect(
                    documented.contains(codec.rawValue),
                    "a codec the engine decodes is missing from the table"
                )
            }
        }
    }
}

/// Turns the support table into the Markdown published as
/// `docs/codec-support.md`.
enum CodecSupportDocument {
    static func render() -> String {
        var lines = [
            "# Codec support",
            "",
            "What the engine decodes, and by which path. Generated from"
            + " `EngineCodecSupport`",
            "by `scripts/generate-codec-support.sh` — edit that table, not this"
            + " file.",
            "",
            "A codec reaching VideoToolbox is handed to AVFoundation in its"
            + " container's",
            "own bitstream form and never touches this engine's decoder. A"
            + " software codec",
            "is decoded by libavcodec on the CPU.",
            "",
            "## Video",
            "",
            "| Codec | Path | Notes |",
            "| --- | --- | --- |",
        ]
        for entry in EngineCodecSupport.video {
            lines.append("| \(entry.name) | \(entry.path.rawValue) | \(entry.note) |")
        }
        lines += [
            "",
            "The software path takes 8-bit and 10-bit 4:2:0 only. Anything"
            + " else — 4:2:2,",
            "4:4:4, 12-bit — fails the title rather than being converted,"
            + " because a",
            "silent conversion is worse than an error that says what happened.",
            "",
            "## Audio",
            "",
            "| Codec | Given to the renderer as | Notes |",
            "| --- | --- | --- |",
        ]
        for entry in EngineCodecSupport.audio {
            lines.append("| \(entry.name) | \(entry.native ?? "Linear PCM") | \(entry.note) |")
        }
        lines += [
            "",
            "## Dynamic range",
            "",
            "HDR10 is carried whole: mastering display colour volume, content"
            + " light level",
            "and the ambient viewing environment all reach the renderer. HLG"
            + " and the",
            "ordinary BT.709 and BT.2020 transfers are tagged from the"
            + " container.",
            "",
            "Dolby Vision profile 5 is presented as Dolby Vision. Profile 8"
            + " keeps its",
            "base layer's tags and adds the Dolby Vision record beside them,"
            + " so a display",
            "without Dolby Vision still gets HDR10. Profile 7's enhancement"
            + " layer is",
            "dropped and its RPU converted to profile 8.1 in flight. Profile 4"
            + " and any",
            "other profile play as HDR10 off the colour tags.",
            "",
            "HDR10+ is not read, and not removed either: its metadata rides"
            + " inside the",
            "bitstream on the compressed path. Whether a display acts on it is"
            + " not",
            "something this engine decides, so it is not claimed here.",
            "",
            "On tvOS, HDR that decodes in software is tone-mapped to SDR by"
            + " default.",
            "",
            "## Interlacing",
            "",
            "Interlaced H.264, MPEG-2, VC-1, WMV3 and MPEG-4 Part 2 are"
            + " deinterlaced,",
            "8-bit only, by a spatial filter that weaves where the fields"
            + " agree and",
            "interpolates along the best-matching direction where they do not.",
            "",
            "Interlaced HEVC is not deinterlaced. It stays on the compressed"
            + " path,",
            "whatever its field order says.",
            "",
        ]
        return lines.joined(separator: "\n")
    }
}
