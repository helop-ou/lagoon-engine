import CoreMedia
import CoreVideo
import Dovi
import Foundation
import Testing
@testable import LagoonEngine

/// Opt-in end-to-end check on a real profile 7 remux: the head of
/// a UHD Blu-ray episode, fetched with a byte range, is enough for
/// libavformat to open it and hand over a few dozen video packets. The
/// simulator cannot decode or display any of it, but it can prove what the
/// demuxer now emits: a profile 8.1 `dvvC` on the format description, no
/// enhancement-layer units left in the packets, and RPUs that libdovi itself
/// reads back as profile 8. Point `LAGOON_DOVI_P7_FIXTURE` at the file
/// through the xctestrun's environment, as `scripts/test-ffmpeg-tls.py`
/// injects its fixtures; `TEST_RUNNER_*` never reaches a unit bundle.
@Suite("Dolby Vision profile 7 fixture", .serialized)
struct DolbyVisionFixtureTests {
    @Test func profile7RemuxIsRewrittenToProfile81() throws {
        guard let path = ProcessInfo.processInfo.environment["LAGOON_DOVI_P7_FIXTURE"],
              !path.isEmpty else { return }
        let demuxer = FFmpegDemuxer(capabilities: PlaybackCapabilities(hardwareHEVC: false))
        defer { demuxer.close() }
        demuxer.dolbyVisionProfile7Mode = .convert
        try demuxer.open(url: path, recommendedPixelBufferAttributes: CVPixelBufferAttributes())

        let description = try #require(demuxer.videoStream?.formatDescription)
        #expect(CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_HEVC)
        let atoms = CMFormatDescriptionGetExtension(
            description,
            extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any]
        let dvvC = try #require(atoms?["dvvC"] as? Data, "the converted stream must carry a dvvC atom")
        #expect(atoms?["dvcC"] == nil)
        #expect(dvvC.count == 24)
        #expect(dvvC[2] >> 1 == 8, "dvvC must declare profile 8")
        #expect(dvvC[3] & 0b100 != 0, "rpu_present_flag")
        #expect(dvvC[3] & 0b010 == 0, "el_present_flag must be clear")
        #expect(dvvC[3] & 0b001 != 0, "bl_present_flag")
        #expect(dvvC[4] >> 4 == 1, "bl signal compatibility id 1 (HDR10 base layer)")

        var packets = 0
        var rpuUnits = 0
        var enhancementUnits = 0
        var profilesReadBack: Set<UInt8> = []
        for _ in 0..<400 where packets < 48 {
            switch demuxer.readNext() {
            case .video(let buffer):
                packets += 1
                let payload = try Self.bytes(of: buffer)
                payload.withUnsafeBytes { raw in
                    _ = HEVCNALUnitRewriter.rewrite(payload: raw, lengthSize: 4) { nalType, unit in
                        switch nalType {
                        case 63:
                            enhancementUnits += 1
                        case 62:
                            rpuUnits += 1
                            if let rpu = dovi_parse_unspec62_nalu(unit.baseAddress?.assumingMemoryBound(to: UInt8.self), unit.count) {
                                defer { dovi_rpu_free(rpu) }
                                if dovi_rpu_get_error(rpu) == nil, let header = dovi_rpu_get_header(rpu) {
                                    profilesReadBack.insert(header.pointee.guessed_profile)
                                    dovi_rpu_free_header(header)
                                }
                            }
                        default:
                            break
                        }
                        return .keep
                    }
                }
            case .failed(let message):
                Issue.record("profile 7 fixture failed: \(message)")
                return
            default:
                continue
            }
        }
        #expect(packets >= 24, "read \(packets) video packets")
        #expect(enhancementUnits == 0, "no enhancement-layer unit may survive")
        #expect(rpuUnits > 0, "every access unit keeps its RPU")
        #expect(profilesReadBack == [8], "RPUs read back as \(profilesReadBack)")

        let stats = try #require(demuxer.dolbyVisionRewriteStats)
        #expect(stats.mode == .convert)
        #expect(stats.rpusConverted >= rpuUnits)
        #expect(stats.enhancementUnitsDropped > 0)
        #expect(stats.errors == 0)
        #expect(stats.enhancementLayerType == "FEL" || stats.enhancementLayerType == "MEL")
    }

    private static func bytes(of buffer: CMSampleBuffer) throws -> Data {
        let block = try #require(CMSampleBufferGetDataBuffer(buffer))
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
            #expect(status == noErr)
        }
        return data
    }
}
