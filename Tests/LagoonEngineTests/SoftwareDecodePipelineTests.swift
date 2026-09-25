import Foundation
import Libavcodec
import Testing
@testable import LagoonEngine

/// Decoded-frame memory and libavcodec thread arithmetic for the software path.
/// Moving decode off the demux queue can only be scored on a device.
struct SoftwareDecodePipelineTests {
    /// A 4:2:0 P010 surface at 3840x2160: luma plus half as many chroma
    /// samples, 16 bits each.
    private let fourKP010Bytes: Int64 = 3840 * 2160 * 3

    @Test func decodedQueueLimitFallsBackToBytesWhenFramesAreHuge() {
        #expect(fourKP010Bytes == 24_883_200)

        // Count alone allowed 42 frames: 1.05 GB of surfaces, in a process
        // jetsam has killed at 2.1 GB.
        let byCountOnly = DemuxBackpressurePolicy.videoHardLimit(
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true
        )
        #expect(byCountOnly == 42)
        #expect(Int64(byCountOnly) * fourKP010Bytes > 1_000_000_000)

        let capped = DemuxBackpressurePolicy.videoHardLimit(
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true,
            decodedFrameBytes: fourKP010Bytes
        )
        #expect(capped == 12)
        #expect(Int64(capped) * fourKP010Bytes == DemuxBackpressurePolicy.decodedQueueByteBudget)
    }

    @Test func smallerFramesKeepTheLimitTheyWereMeasuredWith() {
        // 1080p 10-bit is 6.2 MB a frame, so 42 is 250 MB: inside the budget,
        // and the count stays the binding limit.
        let hd10Bit: Int64 = 1920 * 1080 * 3
        #expect(DemuxBackpressurePolicy.videoHardLimit(
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true,
            decodedFrameBytes: hd10Bit
        ) == 42)

        // The hardware path at 4K is where the budget came from; it must not
        // move.
        #expect(DemuxBackpressurePolicy.videoHardLimit(
            videoIsDecoded: true,
            decodedFrameBytes: fourKP010Bytes
        ) == 30)

        // Compressed samples are not surfaces and are not bounded by this.
        #expect(DemuxBackpressurePolicy.videoHardLimit(videoIsDecoded: false) == 120)
    }

    @Test func decodedQueueKeepsAFloorHoweverLargeAFrameGets() {
        // 8K is outside the advertised profile, but the limit must still leave
        // room for a reorder ladder.
        let eightKP010: Int64 = 7680 * 4320 * 3
        #expect(DemuxBackpressurePolicy.videoHardLimit(
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true,
            decodedFrameBytes: eightKP010
        ) == 8)
    }

    @Test func packetsInsideTheDecoderCountAsVideoAlreadyRead() {
        // The demux loop passes queue depth plus what the decoder still owes.
        // Six frames with 25 packets in the decoder is a full pipeline, not an
        // empty queue.
        let frameBytes = fourKP010Bytes
        let queuedOnly = DemuxBackpressurePolicy.decision(
            videoCount: 6,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true,
            hasAudio: false,
            decodedFrameBytes: frameBytes
        )
        #expect(queuedOnly == .read)

        let queuedPlusPending = DemuxBackpressurePolicy.decision(
            videoCount: 6 + 25,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true,
            hasAudio: false,
            decodedFrameBytes: frameBytes
        )
        // At 4K the byte budget caps the hard limit at 12, so high water is
        // 11 and low water keeps the six-frame drain batch: 5.
        #expect(queuedPlusPending == .waitForVideo(below: 5))
    }

    @Test func av1IsAlwaysOfferedToVideoToolboxAndSettledAtRuntime() {
        // VTIsHardwareDecodeSupported reports only silicon. AV1 is always
        // offered and `VideoToolboxDecoder.canDecode` settles it per stream, so
        // a software AV1 decoder in VideoToolbox gets used.
        let noAV1Silicon = PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: false)
        #expect(noAV1Silicon.decodesAV1WithVideoToolbox)
        #expect(FFmpegDemuxer.usesCompressedVideoPath(
            codecID: AV_CODEC_ID_AV1, capabilities: noAV1Silicon
        ))

        // No other codec moves.
        #expect(!FFmpegDemuxer.usesCompressedVideoPath(
            codecID: AV_CODEC_ID_VP9, capabilities: noAV1Silicon
        ))
        #expect(FFmpegDemuxer.usesCompressedVideoPath(
            codecID: AV_CODEC_ID_H264, capabilities: noAV1Silicon
        ))
    }

    @Test func threadCountIsExplicitUnlessTheHardwareProbeRequestsAuto() {
        #expect(SoftwareDecodeThreadPolicy.resolvedThreadCount(
            explicit: nil, activeProcessors: 6
        ) == 6)
        #expect(SoftwareDecodeThreadPolicy.resolvedThreadCount(
            explicit: nil, activeProcessors: 0
        ) == 1)
        #expect(SoftwareDecodeThreadPolicy.resolvedThreadCount(
            explicit: 0, activeProcessors: 6
        ) == 0)
        #expect(SoftwareDecodeThreadPolicy.resolvedThreadCount(
            explicit: 8, activeProcessors: 6
        ) == 8)

        // Movies favor throughput over dav1d's lower square-root default.
        #expect(SoftwareDecodeThreadPolicy.resolvedMaxFrameDelay(
            explicit: nil, threadCount: 5
        ) == 5)
        #expect(SoftwareDecodeThreadPolicy.resolvedMaxFrameDelay(
            explicit: nil, threadCount: 0
        ) == 0)
        #expect(SoftwareDecodeThreadPolicy.resolvedMaxFrameDelay(
            explicit: 3, threadCount: 5
        ) == 3)
        #expect(SoftwareDecodeThreadPolicy.resolvedMaxFrameDelay(
            explicit: -1, threadCount: 5
        ) == 0)
        #expect(SoftwareDecodeThreadPolicy.resolvedMaxFrameDelay(
            explicit: 8, threadCount: 5
        ) == 5)
    }

    @Test func decoderExperimentValuesComeOnlyFromProcessArguments() {
        let key = SoftwareDecodeThreadPolicy.threadCountDefaultsKey
        #expect(SoftwareDecodeThreadPolicy.commandLineInteger(
            forKey: key,
            arguments: ["Lagoon", "-\(key)", "0"]
        ) == 0)
        #expect(SoftwareDecodeThreadPolicy.commandLineInteger(
            forKey: key,
            arguments: ["Lagoon", "--\(key)", "8"]
        ) == 8)
        #expect(SoftwareDecodeThreadPolicy.commandLineInteger(
            forKey: key,
            arguments: ["Lagoon"]
        ) == nil)
        #expect(SoftwareDecodeThreadPolicy.commandLineInteger(
            forKey: key,
            arguments: ["Lagoon", "-\(key)"]
        ) == nil)
    }

    @Test func outputModeMatrixSeparatesStorageFromColorConversion() {
        let resolve: (String?) -> SoftwareVideoDecoder.OutputMode = { value in
            SoftwareVideoDecoder.outputMode(
                requestedValue: value,
                legacyCompressedOutput: nil,
                toneMapHDRByDefault: true
            )
        }
        #expect(resolve("direct-pq") == .directSource)
        #expect(resolve("lossless-pq") == .losslessSource)
        #expect(resolve("linear-sdr") == .linearSDR)
        #expect(resolve("compressed-sdr") == .losslessSDR)
        #expect(resolve("gpu-pq") == .gpuSource)
        #expect(resolve("gpu-sdr") == .gpuSDR)

        #expect(!SoftwareVideoDecoder.OutputMode.directSource.usesPixelTransfer)
        #expect(!SoftwareVideoDecoder.OutputMode.gpuSDR.usesPixelTransfer)
        #expect(SoftwareVideoDecoder.OutputMode.gpuSDR.usesGPU)
        #expect(SoftwareVideoDecoder.OutputMode.gpuSDR.convertsToSDR)
        #expect(!SoftwareVideoDecoder.OutputMode.gpuSource.convertsToSDR)
        #expect(SoftwareVideoDecoder.OutputMode.gpuSDR.pixelTransferFallback == .losslessSDR)
        #expect(SoftwareVideoDecoder.OutputMode.gpuSource.pixelTransferFallback == .losslessSource)
        #expect(SoftwareVideoDecoder.OutputMode.losslessSource.usesPixelTransfer)
        #expect(SoftwareVideoDecoder.OutputMode.losslessSource.usesLosslessStorage)
        #expect(!SoftwareVideoDecoder.OutputMode.losslessSource.convertsToSDR)
        #expect(!SoftwareVideoDecoder.OutputMode.linearSDR.usesLosslessStorage)
        #expect(SoftwareVideoDecoder.OutputMode.linearSDR.convertsToSDR)

        // The legacy A/B argument and the measured default.
        #expect(SoftwareVideoDecoder.outputMode(
            requestedValue: nil,
            legacyCompressedOutput: false,
            toneMapHDRByDefault: true
        ) == .directSource)
        // The default is the GPU stage; its fallback is the transfer route.
        #expect(SoftwareVideoDecoder.outputMode(
            requestedValue: nil,
            legacyCompressedOutput: nil,
            toneMapHDRByDefault: true
        ) == .gpuSDR)
        #expect(SoftwareVideoDecoder.outputMode(
            requestedValue: nil,
            legacyCompressedOutput: nil,
            toneMapHDRByDefault: false
        ) == .gpuSource)
    }

    @Test func decodeProfileSeparatesTheThreeCostsAsSharesOfOneCore() {
        // 24 frames in one wall-clock second, 0.44 s in libavcodec and 0.12 s
        // converting. Fractions are per-stage shares of a core.
        let profile = SoftwareVideoDecoder.Profile(
            frames: 24,
            packets: 24,
            decodeSeconds: 0.44,
            conversionSeconds: 0.12,
            elapsedSeconds: 1
        )
        #expect(profile.framesPerSecond == 24)
        #expect(abs(profile.decodeFraction - 0.44) < 0.0001)
        #expect(abs(profile.conversionFraction - 0.12) < 0.0001)

        // Nothing measured yet must not read as a stage taking no time.
        let empty = SoftwareVideoDecoder.Profile()
        #expect(empty.framesPerSecond == 0)
        #expect(empty.decodeFraction == 0)
        #expect(empty.conversionFraction == 0)
    }

    @Test func rendererReadinessUsesElapsedTimeRatherThanCallbackCount() {
        let timings = RendererPipelineTimings(enabled: true)
        timings.reset(at: 100)
        // Backpressured for one second, starved for nine. Counting callbacks
        // would say 33% not-ready.
        timings.sample(
            at: 100,
            rendererReady: false,
            renderQueue: 4,
            decodePending: 3
        )
        timings.sample(
            at: 101,
            rendererReady: true,
            renderQueue: 0,
            decodePending: 3
        )
        timings.sample(
            at: 110,
            rendererReady: true,
            renderQueue: 0,
            decodePending: 3
        )

        let summary = timings.summaryLines().joined(separator: "\n")
        #expect(summary.contains("measured=10.00s rendererNotReady=10.00%"))
        #expect(summary.contains("producerStarved=90.00%"))
        #expect(summary.contains("downstreamBackpressure=10.00%"))
    }
}
