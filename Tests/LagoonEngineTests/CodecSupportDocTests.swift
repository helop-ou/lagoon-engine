import Foundation
import Libavcodec
import Testing
@testable import LagoonEngine

/// Renders `EngineCodecSupport` as the published codec table and pins it to the
/// code that routes streams, so drift fails a test.
/// `scripts/generate-codec-support.sh` runs this and copies the result into
/// `docs/codec-support.md`; `--check` fails instead of copying.
@Suite("Codec support document")
struct CodecSupportDocTests {
    @Test func writesTheCodecSupportDocument() {
        // Printed, not written to a file: the runner's container is cleared
        // when the run ends. Every line has its own markers because runner
        // progress lands inside printed lines; the script trims that noise off
        // either end.
        for line in CodecSupportDocument.render().split(
            separator: "\n", omittingEmptySubsequences: false
        ) {
            print("CODEC_DOC|\(line)|CODEC_DOC")
        }
    }

    @Test func theTableAgreesWithTheCompressedPath() {
        // Every codec the table calls VideoToolbox must be routed there, and
        // nothing called software-only may be.
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
        // The other direction: a routed codec with no table entry would
        // understate the engine.
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
