import CoreMedia
import CoreVideo
import Foundation
import Libavcodec
import Libavutil
import Testing
import VideoToolbox
@testable import LagoonEngine

/// What the engine has to get right to line up with Apple's decoders and
/// renderers: payload layouts, clock anchors, decoder error classification,
/// pixel conversion, the software fixtures and demux backpressure.
struct ApplePlaybackAlignmentTests {
    @Test func ambientViewingEnvironmentUsesAppleH274PayloadLayout() {
        let metadata = AVAmbientViewingEnvironment(
            ambient_illuminance: AVRational(num: 314, den: 1),
            ambient_light_x: AVRational(num: 15_635, den: 50_000),
            ambient_light_y: AVRational(num: 16_450, den: 50_000)
        )

        #expect(SampleBufferFactory.ambientViewingEnvironmentPayload(metadata) == Data([
            0x00, 0x2F, 0xE9, 0xA0, // 314 lux * 10,000
            0x3D, 0x13,             // CIE x * 50,000
            0x40, 0x42,             // CIE y * 50,000
        ]))
    }

    @Test func invalidAmbientViewingEnvironmentIsNotAttached() {
        let metadata = AVAmbientViewingEnvironment(
            ambient_illuminance: AVRational(num: 0, den: 1),
            ambient_light_x: AVRational(num: 1, den: 2),
            ambient_light_y: AVRational(num: 1, den: 2)
        )

        #expect(SampleBufferFactory.ambientViewingEnvironmentPayload(metadata) == nil)
    }

    @Test func rendererPixelBufferRecommendationsArePreserved() {
        let recommended = CVPixelBufferAttributes(bytesPerRowAlignment: 256)
        let resolved = VideoToolboxDecoder.resolvedPixelBufferAttributes(
            recommended: recommended
        )

        #expect(resolved.bytesPerRowAlignment == 256)
        #expect(resolved.backing == .ioSurface)
        #expect(resolved.compatibility.contains(.metalTexture))
    }

    @Test func hostClockAnchorNeverStartsBeforeTheRequestedPosition() {
        let beforeTarget = PlaybackClockAnchor.mediaTime(
            targetSeconds: 10,
            firstVideoPTS: CMTime(seconds: 9, preferredTimescale: 24_000)
        )
        let afterTarget = PlaybackClockAnchor.mediaTime(
            targetSeconds: 10,
            firstVideoPTS: CMTime(seconds: 10.5, preferredTimescale: 24_000)
        )
        let invalid = PlaybackClockAnchor.mediaTime(
            targetSeconds: 10,
            firstVideoPTS: .invalid
        )

        #expect(beforeTarget.seconds == 10)
        #expect(afterTarget.seconds == 10.5)
        #expect(invalid.seconds == 10)
    }

    @Test func missingReferenceIsARecoverableFrameError() {
        #expect(VideoToolboxDecoder.isRecoverableFrameError(kVTVideoDecoderReferenceMissingErr))
        #expect(!VideoToolboxDecoder.isRecoverableFrameError(kVTVideoDecoderMalfunctionErr))
        #expect(!VideoToolboxDecoder.isRecoverableFrameError(kVTInvalidSessionErr))
    }

    /// A lost session (`-12903`) only means the session needs remaking; it is
    /// not a verdict on the bitstream.
    @Test func lostSessionsAreFaultsInTheSessionNotTheStream() {
        #expect(VideoToolboxDecoder.isSessionFault(kVTInvalidSessionErr))
        #expect(VideoToolboxDecoder.isSessionFault(kVTVideoDecoderMalfunctionErr))
        #expect(VideoToolboxDecoder.isSessionFault(kVTVideoDecoderNotAvailableNowErr))
        // A refused frame in a live session is a real verdict on the samples.
        #expect(!VideoToolboxDecoder.isSessionFault(kVTVideoDecoderReferenceMissingErr))
        #expect(!VideoToolboxDecoder.isSessionFault(kVTVideoDecoderBadDataErr))
        #expect(!VideoToolboxDecoder.isSessionFault(kVTVideoDecoderUnsupportedDataFormatErr))
    }

    /// Every case carries the status, or the classification above is
    /// unreachable.
    @Test func decoderErrorsCarryTheirStatus() {
        #expect(VideoToolboxDecoder.DecoderError.decode(-12903).status == -12903)
        #expect(VideoToolboxDecoder.DecoderError.sessionCreation(-12903).status == -12903)
        #expect(VideoToolboxDecoder.DecoderError.outputFormat(-12911).status == -12911)
        #expect(VideoToolboxDecoder.DecoderError.outputSample(-12913).status == -12913)
    }

    @Test func directPlayAudioCadenceUsesCodecConfiguration() {
        #expect(SampleBufferFactory.audioFramesPerPacket(
            codecID: AV_CODEC_ID_MP3,
            sampleRate: 24_000,
            declaredFrameSize: 0
        ) == 576)
        #expect(SampleBufferFactory.audioFramesPerPacket(
            codecID: AV_CODEC_ID_MP3,
            sampleRate: 48_000,
            declaredFrameSize: 0
        ) == 1152)
        #expect(SampleBufferFactory.audioFramesPerPacket(
            codecID: AV_CODEC_ID_AAC,
            sampleRate: 48_000,
            declaredFrameSize: 960
        ) == 960)
    }

    @Test func planarVC1ChromaIsInterleavedIntoCoreVideoNV12Order() {
        let u: [UInt8] = [10, 20, 30, 40]
        let v: [UInt8] = [50, 60, 70, 80]
        var output = [UInt8](repeating: 0xFF, count: 12)

        u.withUnsafeBufferPointer { sourceU in
            v.withUnsafeBufferPointer { sourceV in
                output.withUnsafeMutableBufferPointer { destination in
                    SoftwareVideoDecoder.interleave420Chroma(
                        sourceU: sourceU.baseAddress!,
                        sourceUStride: 2,
                        sourceV: sourceV.baseAddress!,
                        sourceVStride: 2,
                        destination: destination.baseAddress!,
                        destinationStride: 6,
                        width: 4,
                        rows: 2
                    )
                }
            }
        }

        #expect(output == [10, 50, 20, 60, 0xFF, 0xFF, 30, 70, 40, 80, 0xFF, 0xFF])
    }

    @Test func planar10BitFramesAreShiftedAndInterleavedIntoP010() {
        let y: [UInt16] = [
            0, 1, 512, 1023, 77,
            10, 20, 30, 40, 88,
        ]
        var outputY = [UInt16](repeating: 0xFFFF, count: 12)
        y.withUnsafeBufferPointer { source in
            outputY.withUnsafeMutableBufferPointer { destination in
                SoftwareVideoDecoder.shift10BitPlaneToP010(
                    source: source.baseAddress!,
                    sourceStride: 5 * MemoryLayout<UInt16>.stride,
                    destination: destination.baseAddress!,
                    destinationStride: 6 * MemoryLayout<UInt16>.stride,
                    width: 4,
                    rows: 2
                )
            }
        }
        #expect(outputY == [
            0, 64, 32_768, 65_472, 0xFFFF, 0xFFFF,
            640, 1_280, 1_920, 2_560, 0xFFFF, 0xFFFF,
        ])

        let u: [UInt16] = [1, 512, 77, 2, 100, 88]
        let v: [UInt16] = [1023, 0, 77, 500, 700, 88]
        var outputUV = [UInt16](repeating: 0xFFFF, count: 12)
        u.withUnsafeBufferPointer { sourceU in
            v.withUnsafeBufferPointer { sourceV in
                outputUV.withUnsafeMutableBufferPointer { destination in
                    SoftwareVideoDecoder.interleave420Chroma10BitToP010(
                        sourceU: sourceU.baseAddress!,
                        sourceUStride: 3 * MemoryLayout<UInt16>.stride,
                        sourceV: sourceV.baseAddress!,
                        sourceVStride: 3 * MemoryLayout<UInt16>.stride,
                        destination: destination.baseAddress!,
                        destinationStride: 6 * MemoryLayout<UInt16>.stride,
                        width: 4,
                        rows: 2
                    )
                }
            }
        }
        #expect(outputUV == [
            64, 65_472, 32_768, 0, 0xFFFF, 0xFFFF,
            128, 32_000, 6_400, 44_800, 0xFFFF, 0xFFFF,
        ])
    }

    @Test func fusedPlanar10BitConversionPreservesPlaneStridesAndPadding() {
        let y: [UInt16] = [
            0, 1, 512, 1023, 77,
            10, 20, 30, 40, 88,
            50, 60, 70, 80, 99,
            90, 100, 110, 120, 111,
        ]
        let u: [UInt16] = [1, 512, 77, 2, 100, 88]
        let v: [UInt16] = [1023, 0, 77, 500, 700, 88]
        var outputY = [UInt16](repeating: 0xFFFF, count: 24)
        var outputUV = [UInt16](repeating: 0xFFFF, count: 12)

        y.withUnsafeBufferPointer { sourceY in
            u.withUnsafeBufferPointer { sourceU in
                v.withUnsafeBufferPointer { sourceV in
                    outputY.withUnsafeMutableBufferPointer { destinationY in
                        outputUV.withUnsafeMutableBufferPointer { destinationUV in
                            SoftwareVideoDecoder.convertPlanar10BitToP010(
                                sourceY: sourceY.baseAddress!,
                                sourceYStride: 5 * MemoryLayout<UInt16>.stride,
                                sourceU: sourceU.baseAddress!,
                                sourceUStride: 3 * MemoryLayout<UInt16>.stride,
                                sourceV: sourceV.baseAddress!,
                                sourceVStride: 3 * MemoryLayout<UInt16>.stride,
                                destinationY: destinationY.baseAddress!,
                                destinationYStride: 6 * MemoryLayout<UInt16>.stride,
                                destinationUV: destinationUV.baseAddress!,
                                destinationUVStride: 6 * MemoryLayout<UInt16>.stride,
                                width: 4,
                                height: 4
                            )
                        }
                    }
                }
            }
        }

        #expect(outputY == [
            0, 64, 32_768, 65_472, 0xFFFF, 0xFFFF,
            640, 1_280, 1_920, 2_560, 0xFFFF, 0xFFFF,
            3_200, 3_840, 4_480, 5_120, 0xFFFF, 0xFFFF,
            5_760, 6_400, 7_040, 7_680, 0xFFFF, 0xFFFF,
        ])
        #expect(outputUV == [
            64, 65_472, 32_768, 0, 0xFFFF, 0xFFFF,
            128, 32_000, 6_400, 44_800, 0xFFFF, 0xFFFF,
        ])
    }

    @Test func fusedPlanar10BitConversionMatchesNegativeStrideHelpers() {
        let width = 4
        let height = 4
        let y = (0..<(width * height)).map(UInt16.init)
        let u = (100..<(100 + width * height / 4)).map(UInt16.init)
        let v = (200..<(200 + width * height / 4)).map(UInt16.init)
        var expectedY = [UInt16](repeating: 0, count: width * height)
        var expectedUV = [UInt16](repeating: 0, count: width * height / 2)
        var fusedY = expectedY
        var fusedUV = expectedUV
        let yStride = width * MemoryLayout<UInt16>.stride
        let chromaStride = width / 2 * MemoryLayout<UInt16>.stride

        y.withUnsafeBufferPointer { sourceY in
            u.withUnsafeBufferPointer { sourceU in
                v.withUnsafeBufferPointer { sourceV in
                    expectedY.withUnsafeMutableBufferPointer { destinationY in
                        expectedUV.withUnsafeMutableBufferPointer { destinationUV in
                            SoftwareVideoDecoder.shift10BitPlaneToP010(
                                source: sourceY.baseAddress!,
                                sourceStride: -yStride,
                                destination: destinationY.baseAddress!,
                                destinationStride: yStride,
                                width: width,
                                rows: height
                            )
                            SoftwareVideoDecoder.interleave420Chroma10BitToP010(
                                sourceU: sourceU.baseAddress!,
                                sourceUStride: -chromaStride,
                                sourceV: sourceV.baseAddress!,
                                sourceVStride: -chromaStride,
                                destination: destinationUV.baseAddress!,
                                destinationStride: yStride,
                                width: width,
                                rows: height / 2
                            )
                        }
                    }
                    fusedY.withUnsafeMutableBufferPointer { destinationY in
                        fusedUV.withUnsafeMutableBufferPointer { destinationUV in
                            SoftwareVideoDecoder.convertPlanar10BitToP010(
                                sourceY: sourceY.baseAddress!,
                                sourceYStride: -yStride,
                                sourceU: sourceU.baseAddress!,
                                sourceUStride: -chromaStride,
                                sourceV: sourceV.baseAddress!,
                                sourceVStride: -chromaStride,
                                destinationY: destinationY.baseAddress!,
                                destinationYStride: yStride,
                                destinationUV: destinationUV.baseAddress!,
                                destinationUVStride: yStride,
                                width: width,
                                height: height
                            )
                        }
                    }
                }
            }
        }

        #expect(fusedY == expectedY)
        #expect(fusedUV == expectedUV)
    }

    @Test func AV1CompressedRoutingIsOfferedAndSettledAtRuntime() {
        // VTIsHardwareDecodeSupported reports silicon, and VideoToolbox has a
        // software AV1 decoder on some platforms, so AV1 is offered either way.
        // `VideoToolboxDecoder.canDecode` settles it per stream; where it says
        // no the engine reopens on the software path.
        #expect(FFmpegDemuxer.usesCompressedVideoPath(
            codecID: AV_CODEC_ID_AV1,
            capabilities: PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: false)
        ))
        #expect(FFmpegDemuxer.usesCompressedVideoPath(
            codecID: AV_CODEC_ID_AV1,
            capabilities: PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: true)
        ))
        #expect(!FFmpegDemuxer.usesCompressedVideoPath(
            codecID: AV_CODEC_ID_VP9,
            capabilities: PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: true)
        ))
        #expect(FFmpegDemuxer.usesCompressedVideoPath(
            codecID: AV_CODEC_ID_H264,
            capabilities: PlaybackCapabilities(hardwareHEVC: false, hardwareAV1: false)
        ))
    }

    @Test func av1FixtureProducesReadyP010Frames() throws {
        try assertTenBitSoftwareFixture(
            environmentKey: "LAGOON_AV1_FIXTURE_URL",
            codecName: "av1"
        )
        guard let rawURL = ProcessInfo.processInfo.environment["LAGOON_AV1_FIXTURE_URL"],
              !rawURL.isEmpty else { return }
        let demuxer = FFmpegDemuxer(
            capabilities: PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: true)
        )
        defer { demuxer.close() }
        try demuxer.open(
            url: rawURL,
            recommendedPixelBufferAttributes: CVPixelBufferAttributes()
        )
        #expect(!demuxer.outputsDecodedVideo)
        let subtype = demuxer.videoStream?.formatDescription.map(CMFormatDescriptionGetMediaSubType)
        #expect(subtype == kCMVideoCodecType_AV1)
    }

    /// Opt-in. Set `LAGOON_AV1_FIXTURE_URL` to an AV1 file to report the
    /// libdav1d ceiling apart from the full P010/output path. Simulator values
    /// compare revisions on one Mac; they do not predict device throughput.
    @Test func av1FixtureReportsDecodeOnlyAndOutputCeilings() throws {
        guard let rawURL = ProcessInfo.processInfo.environment["LAGOON_AV1_FIXTURE_URL"],
              !rawURL.isEmpty else { return }
        let requestedFrames = ProcessInfo.processInfo.environment["LAGOON_AV1_BENCHMARK_FRAMES"]
            .flatMap(Int.init) ?? 240
        let frameLimit = max(requestedFrames, 12)

        let decodeOnly = try benchmarkAV1Fixture(
            rawURL,
            frameLimit: frameLimit,
            discardingOutput: true
        )
        let completeOutput = try benchmarkAV1Fixture(
            rawURL,
            frameLimit: frameLimit,
            discardingOutput: false
        )
        let conversionScheduling = benchmarkP010Scheduling()

        #expect(decodeOnly.frames >= 12)
        #expect(completeOutput.frames >= 12)
        #expect(decodeOnly.threadCount == completeOutput.threadCount)
        #expect(decodeOnly.maxFrameDelay == completeOutput.maxFrameDelay)
        #expect(decodeOnly.decoderDelay == completeOutput.decoderDelay)
        let configuration = "threads=\(completeOutput.threadCount)"
            + " requestedDelay=\(completeOutput.maxFrameDelay.map(String.init) ?? "unknown")"
            + " effectiveDelay=\(completeOutput.decoderDelay)"
        print(configuration + " " + String(
            format: "AV1FixtureBench frames=%d decodeOnly=%.2ffps/%.3fms output=%.2ffps/%.3fms profileDecode=%.3fms profileConvert=%.3fms",
            min(decodeOnly.frames, completeOutput.frames),
            decodeOnly.framesPerSecond,
            decodeOnly.millisecondsPerFrame,
            completeOutput.framesPerSecond,
            completeOutput.millisecondsPerFrame,
            completeOutput.profile.decodeMilliseconds,
            completeOutput.profile.conversionMilliseconds
        ))
        print(String(
            format: "P010SchedulingBench separateP50=%.3fms fusedP50=%.3fms change=%.1f%% separateP95=%.3fms fusedP95=%.3fms",
            conversionScheduling.separateP50 * 1_000,
            conversionScheduling.fusedP50 * 1_000,
            (conversionScheduling.fusedP50 / conversionScheduling.separateP50 - 1) * 100,
            conversionScheduling.separateP95 * 1_000,
            conversionScheduling.fusedP95 * 1_000
        ))
    }

    @Test func vp9FixtureProducesReadyP010Frames() throws {
        try assertTenBitSoftwareFixture(
            environmentKey: "LAGOON_VP9_FIXTURE_URL",
            codecName: "vp9"
        )
    }

    /// Opt-in real-bitstream check. The fixture URL stays outside the
    /// repository so no large third-party file ships, while still exercising
    /// libavformat, VC-1 decode, CVPixelBuffer and CMSampleBuffer end to end.
    @Test func vc1FixtureProducesReadyCoreVideoFrames() throws {
        guard let rawURL = ProcessInfo.processInfo.environment["LAGOON_VC1_FIXTURE_URL"],
              !rawURL.isEmpty else { return }
        let demuxer = FFmpegDemuxer()
        defer { demuxer.close() }
        try demuxer.open(
            url: rawURL,
            recommendedPixelBufferAttributes: CVPixelBufferAttributes()
        )
        #expect(demuxer.videoStream?.codecName == "vc1")
        #expect(demuxer.outputsDecodedVideo)
        #expect(!demuxer.audioStreams.isEmpty)
        if let audio = demuxer.audioStreams.first {
            demuxer.selectAudio(streamIndex: audio.streamIndex)
        }

        var decodedFrames = 0
        var audioBuffers = 0
        var audioGaps = 0
        var expectedAudioPTS: CMTime?
        for _ in 0..<1_000 where decodedFrames < 12 || audioBuffers < 2 {
            switch demuxer.readNext() {
            case .video(let buffer):
                #expect(CMSampleBufferDataIsReady(buffer))
                #expect(CMSampleBufferGetImageBuffer(buffer) != nil)
                decodedFrames += 1
            case .audio(let buffers, _):
                for buffer in buffers {
                    let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                    if let expectedAudioPTS,
                       abs(CMTimeSubtract(pts, expectedAudioPTS).seconds) > 0.001 {
                        audioGaps += 1
                    }
                    let duration = CMSampleBufferGetDuration(buffer)
                    expectedAudioPTS = pts.isValid && duration.isValid
                        ? CMTimeAdd(pts, duration)
                        : nil
                    audioBuffers += 1
                }
            case .failed(let message):
                Issue.record("VC-1 fixture failed: \(message)")
                return
            case .endOfFile:
                break
            default:
                continue
            }
        }
        #expect(decodedFrames == 12)
        #expect(audioBuffers >= 2)
        #expect(audioGaps == 0)
    }

    @Test func squareAndNearSquarePixelsCarryNoAspectExtension() {
        // Unknown (0/1) and exactly square stay nil, so the format description
        // handed to the renderer, AVDisplayCriteria and VideoToolbox is
        // unchanged.
        #expect(SampleBufferFactory.pixelAspectRatio(AVRational(num: 0, den: 1)) == nil)
        #expect(SampleBufferFactory.pixelAspectRatio(AVRational(num: 1, den: 1)) == nil)
        #expect(SampleBufferFactory.pixelAspectRatio(AVRational(num: 1920, den: 1920)) == nil)
        // Malformed values fail closed rather than dividing by zero.
        #expect(SampleBufferFactory.pixelAspectRatio(AVRational(num: 16, den: 0)) == nil)
        #expect(SampleBufferFactory.pixelAspectRatio(AVRational(num: -16, den: 15)) == nil)
        // Rounding artifacts from real files (a 3840x1744 remux, a 624x352
        // AVI), a hundredth of a percent off square.
        #expect(SampleBufferFactory.pixelAspectRatio(AVRational(num: 1_744, den: 1_745)) == nil)
        #expect(SampleBufferFactory.pixelAspectRatio(AVRational(num: 180_224, den: 180_219)) == nil)
    }

    @Test func genuineAnamorphicPixelsAreCarriedThrough() {
        // Every standard broadcast/DVD pixel aspect, wide and narrow.
        for (num, den) in [(16, 15), (12, 11), (32, 27), (64, 45), (15, 16), (11, 12)] {
            let aspect = SampleBufferFactory.pixelAspectRatio(
                AVRational(num: Int32(num), den: Int32(den))
            )
            #expect(aspect?.horizontal == Int32(num))
            #expect(aspect?.vertical == Int32(den))
        }
        // The 1% boundary itself, from both sides.
        #expect(SampleBufferFactory.pixelAspectRatio(AVRational(num: 101, den: 100)) != nil)
        #expect(SampleBufferFactory.pixelAspectRatio(AVRational(num: 1_001, den: 1_000)) == nil)
    }

    @Test func interlacedH264FixtureDecodesInSoftwareWithoutCombing() throws {
        if let progressive = ProcessInfo.processInfo.environment["LAGOON_PROGRESSIVE_H264_FIXTURE_URL"],
           !progressive.isEmpty {
            let demuxer = FFmpegDemuxer(
                capabilities: PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: true)
            )
            defer { demuxer.close() }
            try demuxer.open(
                url: progressive,
                recommendedPixelBufferAttributes: CVPixelBufferAttributes()
            )
            #expect(demuxer.videoStream?.codecName == "h264")
            #expect(!demuxer.outputsDecodedVideo)
            #expect(demuxer.takeSoftwareVideoDecoder() == nil)
        }

        guard let rawURL = ProcessInfo.processInfo.environment["LAGOON_INTERLACED_H264_FIXTURE_URL"],
              !rawURL.isEmpty else { return }
        let demuxer = FFmpegDemuxer(
            capabilities: PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: true)
        )
        defer { demuxer.close() }
        try demuxer.open(
            url: rawURL,
            recommendedPixelBufferAttributes: CVPixelBufferAttributes()
        )
        #expect(demuxer.videoStream?.codecName == "h264")
        #expect(demuxer.outputsDecodedVideo)
        let decoder = try #require(demuxer.takeSoftwareVideoDecoder())

        var decodedFrames = 0
        var reads = 0
        var worstCombing = 0.0
        readLoop: while decodedFrames < 24, reads < 2_000 {
            reads += 1
            switch demuxer.readNext() {
            case .videoPacket(let packet):
                for buffer in try decoder.decode(packet: packet.packet) {
                    #expect(CMSampleBufferDataIsReady(buffer))
                    let image = try #require(CMSampleBufferGetImageBuffer(buffer))
                    let format = CVPixelBufferGetPixelFormatType(image)
                    #expect(
                        format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    )
                    worstCombing = max(worstCombing, Self.combingRatio(luma: image))
                    decodedFrames += 1
                    if decodedFrames == 24 { break }
                }
            case .failed(let message):
                Issue.record("interlaced h264 fixture failed: \(message)")
                break readLoop
            case .endOfFile:
                break readLoop
            default:
                continue
            }
        }
        #expect(decodedFrames == 24)
        // A woven field pair in motion makes adjacent rows differ far more than
        // rows two apart. yadif on this fixture lands near 0.7; woven frames
        // above 1.5.
        #expect(worstCombing < 1.0, "worst combing ratio \(worstCombing)")
    }

    /// Mean difference between adjacent luma rows over that between rows two
    /// apart. Above one, rows alternate like a woven field pair.
    private static func combingRatio(luma image: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else { return .infinity }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let width = CVPixelBufferGetWidthOfPlane(image, 0)
        let height = CVPixelBufferGetHeightOfPlane(image, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var adjacent = 0, apart = 0
        for row in 0..<(height - 2) {
            let a = bytes + row * stride
            let b = a + stride
            let c = b + stride
            for x in 0..<width {
                adjacent += abs(Int(a[x]) - Int(b[x]))
                apart += abs(Int(a[x]) - Int(c[x]))
            }
        }
        return apart == 0 ? 0 : Double(adjacent) / Double(apart)
    }

    /// Set `LAGOON_MPEG4_FIXTURE_URL` to an MPEG-4 Part 2 (Xvid/DivX) AVI.
    /// Packed-bitstream rips matter: one chunk can carry two VOPs, so a packet
    /// yields two frames and the next none, and "VOP not coded" markers are
    /// 7-byte packets.
    @Test func mpeg4FixtureProducesReadyCoreVideoFrames() throws {
        guard let rawURL = ProcessInfo.processInfo.environment["LAGOON_MPEG4_FIXTURE_URL"],
              !rawURL.isEmpty else { return }
        let demuxer = FFmpegDemuxer()
        defer { demuxer.close() }
        try demuxer.open(
            url: rawURL,
            recommendedPixelBufferAttributes: CVPixelBufferAttributes()
        )
        #expect(demuxer.videoStream?.codecName == "mpeg4")
        #expect(demuxer.outputsDecodedVideo)
        #expect(!demuxer.audioStreams.isEmpty)
        if let audio = demuxer.audioStreams.first {
            demuxer.selectAudio(streamIndex: audio.streamIndex)
        }

        var decodedFrames = 0
        var audioBuffers = 0
        var audioGaps = 0
        var lastVideoPTS: CMTime?
        var videoWentBackwards = 0
        var expectedAudioPTS: CMTime?
        for _ in 0..<1_000 where decodedFrames < 12 || audioBuffers < 2 {
            switch demuxer.readNext() {
            case .video(let buffer):
                #expect(CMSampleBufferDataIsReady(buffer))
                #expect(CMSampleBufferGetImageBuffer(buffer) != nil)
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                // Frames leave libavcodec in presentation order, even from a
                // packed chunk.
                if let lastVideoPTS, pts.isValid, pts < lastVideoPTS {
                    videoWentBackwards += 1
                }
                if pts.isValid { lastVideoPTS = pts }
                decodedFrames += 1
            case .audio(let buffers, _):
                for buffer in buffers {
                    let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                    if let expectedAudioPTS,
                       abs(CMTimeSubtract(pts, expectedAudioPTS).seconds) > 0.001 {
                        audioGaps += 1
                    }
                    let duration = CMSampleBufferGetDuration(buffer)
                    expectedAudioPTS = pts.isValid && duration.isValid
                        ? CMTimeAdd(pts, duration)
                        : nil
                    audioBuffers += 1
                }
            case .failed(let message):
                Issue.record("MPEG-4 fixture failed: \(message)")
                return
            case .endOfFile:
                break
            default:
                continue
            }
        }
        #expect(decodedFrames == 12)
        #expect(audioBuffers >= 2)
        #expect(audioGaps == 0)
        #expect(videoWentBackwards == 0)
    }

    @Test func failedFFmpegSeekStatusIsRejected() {
        var threw = false
        do {
            try FFmpegDemuxer.validateSeekStatus(-1)
        } catch {
            threw = true
        }
        #expect(threw)
        do {
            try FFmpegDemuxer.validateSeekStatus(0)
        } catch {
            Issue.record("A successful FFmpeg seek status threw: \(error)")
        }
    }

    @Test func embeddedASSFlowsThroughFFmpegWithItsScriptPlaneAndOverrides() throws {
        guard let fixture = ProcessInfo.processInfo.environment["LAGOON_ASS_FIXTURE_URL"],
              !fixture.isEmpty else { return }
        let demuxer = FFmpegDemuxer()
        defer { demuxer.close() }
        try demuxer.open(
            url: fixture,
            recommendedPixelBufferAttributes: CVPixelBufferAttributes()
        )
        let stream = try #require(demuxer.subtitleStreams.first)
        demuxer.selectSubtitle(streamIndex: stream.streamIndex)

        var decoded: SubtitleTextCue?
        for _ in 0..<200 {
            switch demuxer.readNext() {
            case .subtitle(let events, _):
                for event in events {
                    if case .cue(let cue) = event, let text = cue.textCues.first {
                        decoded = text
                        break
                    }
                }
            case .failed(let message):
                Issue.record("ASS fixture failed: \(message)")
                return
            case .endOfFile:
                break
            default:
                continue
            }
            if decoded != nil { break }
        }

        let cue = try #require(decoded)
        #expect(cue.text == "Top sign")
        #expect(cue.alignment == .topLeft)
        #expect(abs((cue.position?.x ?? 0) - (2.0 / 3.0)) < 0.000_001)
        #expect(abs((cue.position?.y ?? 0) - (1.0 / 6.0)) < 0.000_001)
        #expect(cue.runs.first?.isBold == true)
        #expect(cue.runs.first?.isItalic == true)
        #expect(cue.runs.first?.primaryColor == SubtitleTextColor(
            red: 0x11,
            green: 0x22,
            blue: 0x33,
            alpha: 0xFF
        ))
    }

    @Test func playbackEndUsesObservedSamplesWithoutContainerDuration() {
        #expect(PlaybackEndBoundary.endTime(sampledEnd: 42.25, declaredDuration: 0) == 42.25)
        #expect(PlaybackEndBoundary.endTime(sampledEnd: 41.5, declaredDuration: 99) == 41.5)
        #expect(PlaybackEndBoundary.endTime(sampledEnd: 0, declaredDuration: 99) == 99)
        #expect(PlaybackEndBoundary.endTime(sampledEnd: .nan, declaredDuration: .infinity) == nil)
    }

    @Test func demuxSoftVideoLimitYieldsToAudioStarvation() {
        let decision = DemuxBackpressurePolicy.decision(
            videoCount: 90,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: false,
            hasAudio: true
        )

        #expect(decision == .read)
    }

    @Test func demuxHardVideoLimitPacesWithoutGrowingUnbounded() {
        let decision = DemuxBackpressurePolicy.decision(
            videoCount: 120,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: false,
            hasAudio: true
        )

        #expect(decision == .read)

        // The compressed path's hard limit hands over to the intake's once that
        // fills, which keeps this bounded.
        let decisionAtIntakeLimit = DemuxBackpressurePolicy.decision(
            videoCount: 120,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: false,
            hasAudio: true,
            videoIntakeCount: DemuxBackpressurePolicy.videoIntakeHardLimit
        )

        #expect(decisionAtIntakeLimit == .waitForVideo(below: 120))
    }

    @Test func demuxUsesBatchedVideoDrainWhenAudioHasEnoughReserve() {
        let decision = DemuxBackpressurePolicy.decision(
            videoCount: 90,
            audioCount: 100,
            audioBufferedSeconds: 2.1,
            videoFrameRate: 24,
            videoIsDecoded: false,
            hasAudio: true
        )

        #expect(decision == .waitForVideo(below: 72))
    }

    @Test func fasterPlaybackRetainsMoreVideoBeforeBackpressure() {
        let ordinary = DemuxBackpressurePolicy.decision(
            videoCount: 20,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: false
        )
        let faster = DemuxBackpressurePolicy.decision(
            videoCount: 20,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: false,
            playbackRate: 1.5
        )

        #expect(ordinary == .waitForVideo(below: 12))
        #expect(faster == .read)
    }

    @Test func fasterPlaybackKeepsItsBatchedDrainWindow() {
        // Both watermarks scale with rate but are capped separately below the
        // hard limit. Clamping low water against the capped high water
        // collapsed the gap to one frame at 2x, turning the batched drain into
        // a read-one/wait-one handshake.
        func drainTarget(
            videoIsDecoded: Bool,
            videoIsSoftwareDecoded: Bool,
            playbackRate: Double
        ) -> Int? {
            let hardLimit = DemuxBackpressurePolicy.videoHardLimit(
                videoIsDecoded: videoIsDecoded,
                videoIsSoftwareDecoded: videoIsSoftwareDecoded
            )
            // One under the hard limit is above every scaled high water, so the
            // answer is always the low water.
            guard case .waitForVideo(let below) = DemuxBackpressurePolicy.decision(
                videoCount: hardLimit - 1,
                audioCount: 0,
                audioBufferedSeconds: 0,
                videoFrameRate: 24,
                videoIsDecoded: videoIsDecoded,
                videoIsSoftwareDecoded: videoIsSoftwareDecoded,
                hasAudio: false,
                playbackRate: playbackRate
            ) else { return nil }
            return below
        }

        // Software video drains 30 -> 24 at 1x. At 2x high water saturates at
        // 41 of the 42-frame hard limit, so the batch is carved out below it.
        #expect(drainTarget(
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true,
            playbackRate: 1
        ) == 24)
        #expect(drainTarget(
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true,
            playbackRate: 2
        ) == 35)

        // Compressed h264 drains 90 -> 72; high water saturates at 119 from
        // 1.5x.
        #expect(drainTarget(
            videoIsDecoded: false,
            videoIsSoftwareDecoded: false,
            playbackRate: 1
        ) == 72)
        #expect(drainTarget(
            videoIsDecoded: false,
            videoIsSoftwareDecoded: false,
            playbackRate: 1.5
        ) == 101)
        #expect(drainTarget(
            videoIsDecoded: false,
            videoIsSoftwareDecoded: false,
            playbackRate: 2
        ) == 101)
    }

    @Test func demuxDoesNotWaitForAudioOnSilentVideo() {
        let decision = DemuxBackpressurePolicy.decision(
            videoCount: 90,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: false,
            hasAudio: false
        )

        #expect(decision == .waitForVideo(below: 72))
    }

    @Test func demuxHardAudioLimitPacesWhileVideoNeedsData() {
        let decision = DemuxBackpressurePolicy.decision(
            videoCount: 0,
            audioCount: 270,
            audioBufferedSeconds: 6,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true
        )

        #expect(decision == .waitForAudio(below: 270))
    }

    @Test func softwareDecodedVC1KeepsAOneSecondVideoReserve() {
        let decision = DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 100,
            audioBufferedSeconds: 3,
            videoFrameRate: 24,
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true,
            hasAudio: true
        )

        #expect(decision == .waitForVideo(below: 24))
        #expect(DemuxBackpressurePolicy.videoHardLimit(
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true
        ) == 42)
        #expect(StallRecoveryPolicy.confirmationDelay == .seconds(1))
    }

    private func assertTenBitSoftwareFixture(
        environmentKey: String,
        codecName: String
    ) throws {
        guard let rawURL = ProcessInfo.processInfo.environment[environmentKey],
              !rawURL.isEmpty else { return }
        let demuxer = FFmpegDemuxer(
            capabilities: PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: false)
        )
        defer { demuxer.close() }
        if codecName == "av1" {
            // AV1 goes to VideoToolbox first everywhere. This fixture tests the
            // libdav1d contract, so select that route explicitly.
            demuxer.disableVideoToolboxAV1()
        }
        try demuxer.open(
            url: rawURL,
            recommendedPixelBufferAttributes: CVPixelBufferAttributes()
        )
        #expect(demuxer.videoStream?.codecName == codecName)
        #expect(demuxer.outputsDecodedVideo)
        let decoder = try #require(demuxer.takeSoftwareVideoDecoder())

        var decodedFrames = 0
        var reads = 0
        readLoop: while decodedFrames < 12, reads < 1_000 {
            reads += 1
            switch demuxer.readNext() {
            case .videoPacket(let packet):
                for buffer in try decoder.decode(packet: packet.packet) {
                    #expect(CMSampleBufferDataIsReady(buffer))
                    let image = try #require(CMSampleBufferGetImageBuffer(buffer))
                    let format = CVPixelBufferGetPixelFormatType(image)
                    #expect(
                        format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                    )
                    decodedFrames += 1
                    if decodedFrames == 12 { break }
                }
            case .failed(let message):
                Issue.record("\(codecName) fixture failed: \(message)")
                break readLoop
            case .endOfFile:
                break readLoop
            default:
                continue
            }
        }
        #expect(decodedFrames == 12)
    }

    private struct FixtureBenchmarkResult {
        let frames: Int
        let decoderSeconds: Double
        let profile: SoftwareVideoDecoder.Profile
        let threadCount: Int32
        let maxFrameDelay: Int64?
        let decoderDelay: Int32

        var framesPerSecond: Double {
            decoderSeconds > 0 ? Double(frames) / decoderSeconds : 0
        }
        var millisecondsPerFrame: Double {
            frames > 0 ? decoderSeconds / Double(frames) * 1_000 : 0
        }
    }

    private func benchmarkAV1Fixture(
        _ rawURL: String,
        frameLimit: Int,
        discardingOutput: Bool
    ) throws -> FixtureBenchmarkResult {
        let demuxer = FFmpegDemuxer(
            capabilities: PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: false)
        )
        defer { demuxer.close() }
        demuxer.disableVideoToolboxAV1()
        try demuxer.open(
            url: rawURL,
            recommendedPixelBufferAttributes: CVPixelBufferAttributes()
        )
        #expect(demuxer.videoStream?.codecName == "av1")
        let decoder = try #require(demuxer.takeSoftwareVideoDecoder())

        var frames = 0
        var decoderSeconds = 0.0
        var reads = 0
        readLoop: while frames < frameLimit, reads < frameLimit * 8 {
            reads += 1
            switch demuxer.readNext() {
            case .videoPacket(let packet):
                let started = ProcessInfo.processInfo.systemUptime
                if discardingOutput {
                    frames += try decoder.decodeDiscardingOutput(packet: packet.packet)
                } else {
                    frames += try decoder.decode(packet: packet.packet).count
                }
                decoderSeconds += ProcessInfo.processInfo.systemUptime - started
            case .failed(let message):
                Issue.record("AV1 benchmark fixture failed: \(message)")
                break readLoop
            case .endOfFile:
                let started = ProcessInfo.processInfo.systemUptime
                if discardingOutput {
                    frames += try decoder.drainDiscardingOutput()
                } else {
                    frames += try decoder.drain().count
                }
                decoderSeconds += ProcessInfo.processInfo.systemUptime - started
                break readLoop
            default:
                continue
            }
        }
        return FixtureBenchmarkResult(
            frames: frames,
            decoderSeconds: decoderSeconds,
            profile: decoder.profile,
            threadCount: decoder.resolvedThreadCount,
            maxFrameDelay: decoder.maxFrameDelay,
            decoderDelay: decoder.decoderDelay
        )
    }

    private struct P010SchedulingBenchmarkResult {
        let separateP50: Double
        let separateP95: Double
        let fusedP50: Double
        let fusedP95: Double
    }

    /// Compares two-barrier scheduling with the fused production call on
    /// identical 4K planes and NEON kernels. ABBA order spreads cold and warm
    /// iterations evenly.
    private func benchmarkP010Scheduling() -> P010SchedulingBenchmarkResult {
        let width = 3_840
        let height = 2_160
        let chromaWidth = width / 2
        let chromaHeight = height / 2
        let sourceY = [UInt16](repeating: 511, count: width * height)
        let sourceU = [UInt16](repeating: 384, count: chromaWidth * chromaHeight)
        let sourceV = [UInt16](repeating: 640, count: chromaWidth * chromaHeight)
        var destinationY = [UInt16](repeating: 0, count: width * height)
        var destinationUV = [UInt16](repeating: 0, count: width * chromaHeight)
        var separate: [Double] = []
        var fused: [Double] = []

        func run(fused useFusedPath: Bool) -> Double {
            sourceY.withUnsafeBufferPointer { y in
                sourceU.withUnsafeBufferPointer { u in
                    sourceV.withUnsafeBufferPointer { v in
                        destinationY.withUnsafeMutableBufferPointer { outputY in
                            destinationUV.withUnsafeMutableBufferPointer { outputUV in
                                let started = ProcessInfo.processInfo.systemUptime
                                if useFusedPath {
                                    SoftwareVideoDecoder.convertPlanar10BitToP010(
                                        sourceY: y.baseAddress!,
                                        sourceYStride: width * MemoryLayout<UInt16>.stride,
                                        sourceU: u.baseAddress!,
                                        sourceUStride: chromaWidth * MemoryLayout<UInt16>.stride,
                                        sourceV: v.baseAddress!,
                                        sourceVStride: chromaWidth * MemoryLayout<UInt16>.stride,
                                        destinationY: outputY.baseAddress!,
                                        destinationYStride: width * MemoryLayout<UInt16>.stride,
                                        destinationUV: outputUV.baseAddress!,
                                        destinationUVStride: width * MemoryLayout<UInt16>.stride,
                                        width: width,
                                        height: height
                                    )
                                } else {
                                    SoftwareVideoDecoder.shift10BitPlaneToP010(
                                        source: y.baseAddress!,
                                        sourceStride: width * MemoryLayout<UInt16>.stride,
                                        destination: outputY.baseAddress!,
                                        destinationStride: width * MemoryLayout<UInt16>.stride,
                                        width: width,
                                        rows: height
                                    )
                                    SoftwareVideoDecoder.interleave420Chroma10BitToP010(
                                        sourceU: u.baseAddress!,
                                        sourceUStride: chromaWidth * MemoryLayout<UInt16>.stride,
                                        sourceV: v.baseAddress!,
                                        sourceVStride: chromaWidth * MemoryLayout<UInt16>.stride,
                                        destination: outputUV.baseAddress!,
                                        destinationStride: width * MemoryLayout<UInt16>.stride,
                                        width: width,
                                        rows: chromaHeight
                                    )
                                }
                                return ProcessInfo.processInfo.systemUptime - started
                            }
                        }
                    }
                }
            }
        }

        for _ in 0..<3 {
            _ = run(fused: false)
            _ = run(fused: true)
        }
        let order = [false, true, true, false]
        for _ in 0..<32 {
            for useFusedPath in order {
                let duration = run(fused: useFusedPath)
                if useFusedPath { fused.append(duration) } else { separate.append(duration) }
            }
        }

        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            let sorted = values.sorted()
            let index = min(Int(ceil(Double(sorted.count) * fraction)) - 1, sorted.count - 1)
            return sorted[max(index, 0)]
        }
        return P010SchedulingBenchmarkResult(
            separateP50: percentile(separate, 0.50),
            separateP95: percentile(separate, 0.95),
            fusedP50: percentile(fused, 0.50),
            fusedP95: percentile(fused, 0.95)
        )
    }

}
