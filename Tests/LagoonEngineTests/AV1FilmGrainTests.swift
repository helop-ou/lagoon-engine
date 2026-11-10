import CoreMedia
import CoreVideo
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Testing
@testable import LagoonEngine

/// AV1 film grain synthesised on the GPU must be the grain dav1d would have
/// added, sample for sample. The fixture is 10-bit 4:2:0, 208x120 (blocks cut
/// short at both edges), with overlap, a lag-3 filter, two luma points and
/// chroma points of its own: SVT-AV1 `film-grain=25` over noisy testsrc2.
@Suite("AV1 film grain")
struct AV1FilmGrainTests {
    @Test func gpuGrainMatchesDav1dSampleForSample() throws {
        let applied = try Self.decode(exportingGrain: false)
        let exported = try Self.decode(exportingGrain: true)
        #expect(applied.count == exported.count)
        #expect(applied.count >= 6)
        var differedFromBare = false
        for (reference, frame) in zip(applied, exported) {
            let grain = try #require(frame.grain, "every frame carries grain")
            let expected = try Self.convert(reference, grain: nil)
            let actual = try Self.convert(frame, grain: grain)
            let bare = try Self.convert(frame, grain: nil)
            #expect(actual.luma == expected.luma, "luma")
            #expect(actual.chroma == expected.chroma, "chroma")
            differedFromBare = differedFromBare || bare.luma != expected.luma
        }
        #expect(differedFromBare, "the fixture's grain is visible")
    }

    /// The software decoder asks dav1d for the parameters and adds the grain
    /// itself; its frames are dav1d's grained frames.
    @Test func theSoftwareDecoderAddsTheGrainItself() throws {
        let demuxer = FFmpegDemuxer(capabilities: PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: false))
        defer { demuxer.close() }
        // As on an Apple TV without AV1 silicon, where dav1d decodes.
        demuxer.disableVideoToolboxAV1()
        try demuxer.open(url: try Self.fixturePath(), recommendedPixelBufferAttributes: CVPixelBufferAttributes())
        let decoder = try #require(demuxer.takeSoftwareVideoDecoder())
        #expect(decoder.exportsFilmGrain)
        var outputs: [Output] = []
        reading: for _ in 0..<500 {
            switch demuxer.readNext() {
            case .videoPacket(let packet):
                outputs += try decoder.decode(packet: packet.packet).map(Self.output)
            case .endOfFile:
                break reading
            case .failed(let message):
                Issue.record("read failed: \(message)")
                break reading
            default:
                continue
            }
        }
        outputs += try decoder.drain().map(Self.output)
        let expected = try Self.decode(exportingGrain: false).map { try Self.convert($0, grain: nil) }
        #expect(outputs.count == expected.count)
        #expect(decoder.gpuGrainedFrames == expected.count, "dav1d did not add it")
        for (actual, reference) in zip(outputs, expected) {
            #expect(actual.luma == reference.luma)
            #expect(actual.chroma == reference.chroma)
        }
    }

    @Test func onlyAV1BoundForTheGPUHandsItsGrainOver() {
        let gpu = SoftwareVideoDecoder.OutputMode.gpuSource
        #expect(SoftwareVideoDecoder.exportsFilmGrainToGPU(
            codecID: AV_CODEC_ID_AV1, pixelFormat: AV_PIX_FMT_YUV420P10LE, outputMode: gpu, metalAvailable: true
        ))
        // 8-bit 4:2:0 is copied on the CPU, where nothing would add it.
        #expect(!SoftwareVideoDecoder.exportsFilmGrainToGPU(
            codecID: AV_CODEC_ID_AV1, pixelFormat: AV_PIX_FMT_YUV420P, outputMode: gpu, metalAvailable: true
        ))
        #expect(!SoftwareVideoDecoder.exportsFilmGrainToGPU(
            codecID: AV_CODEC_ID_AV1, pixelFormat: AV_PIX_FMT_NONE, outputMode: gpu, metalAvailable: true
        ))
        #expect(!SoftwareVideoDecoder.exportsFilmGrainToGPU(
            codecID: AV_CODEC_ID_AV1, pixelFormat: AV_PIX_FMT_YUV420P10LE, outputMode: .directSource, metalAvailable: true
        ))
        #expect(!SoftwareVideoDecoder.exportsFilmGrainToGPU(
            codecID: AV_CODEC_ID_AV1, pixelFormat: AV_PIX_FMT_YUV420P10LE, outputMode: gpu, metalAvailable: false
        ))
        #expect(!SoftwareVideoDecoder.exportsFilmGrainToGPU(
            codecID: AV_CODEC_ID_VP9, pixelFormat: AV_PIX_FMT_YUV420P10LE, outputMode: gpu, metalAvailable: true
        ))
    }

    /// The specification's register: taps 0, 1, 3 and 12, shifted in at the
    /// top, the answer read from the top bits.
    @Test func theRandomRegisterFollowsTheSpecification() {
        var register = AV1FilmGrain.RandomRegister(state: 1)
        #expect(register.next(bits: 16) == 0x8000)
        #expect(register.next(bits: 16) == 0x4000)
        var seeded = AV1FilmGrain.RandomRegister(state: 0xACE1)
        var values: [Int] = []
        for _ in 0..<3 { values.append(seeded.next(bits: 8)) }
        #expect(values == [0xD6, 0xEB, 0xF5])
    }

    // MARK: - Helpers

    struct Frame {
        let width: Int
        let height: Int
        let luma: [UInt16]
        let cb: [UInt16]
        let cr: [UInt16]
        let grain: AV1FilmGrain?
    }

    struct Output: Equatable {
        let luma: [UInt16]
        let chroma: [UInt16]
    }

    private static func fixturePath() throws -> String {
        try #require(Bundle.module.url(forResource: "grain10", withExtension: "mkv", subdirectory: "FilmGrain"))
            .path(percentEncoded: false)
    }

    /// Every frame through libdav1d, grain applied by dav1d or handed over.
    private static func decode(exportingGrain: Bool) throws -> [Frame] {
        var format: UnsafeMutablePointer<AVFormatContext>?
        #expect(avformat_open_input(&format, try fixturePath(), nil, nil) >= 0)
        let context = try #require(format)
        defer { avformat_close_input(&format) }
        avformat_find_stream_info(context, nil)
        let index = av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        let parameters = try #require(context.pointee.streams[Int(index)]?.pointee.codecpar)
        var codecContext: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(avcodec_find_decoder_by_name("libdav1d"))
        defer { avcodec_free_context(&codecContext) }
        let decoder = try #require(codecContext)
        avcodec_parameters_to_context(decoder, parameters)
        if exportingGrain {
            decoder.pointee.export_side_data |= Int32(AV_CODEC_EXPORT_DATA_FILM_GRAIN)
        }
        #expect(avcodec_open2(decoder, nil, nil) >= 0)
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_packet_free(&packet); av_frame_free(&frame) }
        var frames: [Frame] = []
        func receive() {
            while avcodec_receive_frame(decoder, frame) >= 0, let current = frame {
                frames.append(copy(current))
                av_frame_unref(current)
            }
        }
        while av_read_frame(context, packet) >= 0 {
            if packet!.pointee.stream_index == index {
                avcodec_send_packet(decoder, packet)
                receive()
            }
            av_packet_unref(packet)
        }
        avcodec_send_packet(decoder, nil)
        receive()
        return frames
    }

    private static func copy(_ frame: UnsafeMutablePointer<AVFrame>) -> Frame {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        func plane(_ index: Int, _ planeWidth: Int, _ planeHeight: Int) -> [UInt16] {
            let stride = Int([frame.pointee.linesize.0, frame.pointee.linesize.1, frame.pointee.linesize.2][index])
            let base = [frame.pointee.data.0, frame.pointee.data.1, frame.pointee.data.2][index]!
            var samples: [UInt16] = []
            for row in 0..<planeHeight {
                let line = UnsafeRawPointer(base.advanced(by: row * stride)).assumingMemoryBound(to: UInt16.self)
                samples += UnsafeBufferPointer(start: line, count: planeWidth)
            }
            return samples
        }
        return Frame(
            width: width,
            height: height,
            luma: plane(0, width, height),
            cb: plane(1, width / 2, height / 2),
            cr: plane(2, width / 2, height / 2),
            grain: AV1FilmGrain(frame: frame, bitDepth: 10, subX: 1, subY: 1)
        )
    }

    private static func convert(_ frame: Frame, grain: AV1FilmGrain?) throws -> Output {
        let converter = try MetalFrameConverter(configuration: .init(
            width: frame.width,
            height: frame.height,
            fullRange: false,
            toneMap: false,
            sourcePeakNits: 1000,
            targetPeakNits: 203,
            outputBitDepth: 10
        ))
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault, frame.width, frame.height,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, attributes as CFDictionary, &buffer
        )
        let destination = try #require(buffer)
        var luma = frame.luma
        var cb = frame.cb
        var cr = frame.cr
        try luma.withUnsafeMutableBufferPointer { lumaSamples in
            try cb.withUnsafeMutableBufferPointer { cbSamples in
                try cr.withUnsafeMutableBufferPointer { crSamples in
                    try converter.convert(
                        luma: .init(base: UnsafeRawPointer(lumaSamples.baseAddress!), stride: frame.width * 2, rows: frame.height),
                        cb: .init(base: UnsafeRawPointer(cbSamples.baseAddress!), stride: frame.width, rows: frame.height / 2),
                        cr: .init(base: UnsafeRawPointer(crSamples.baseAddress!), stride: frame.width, rows: frame.height / 2),
                        into: destination,
                        grain: grain
                    )
                }
            }
        }
        return output(destination)
    }

    private static func output(_ buffer: CMSampleBuffer) throws -> Output {
        output(try #require(CMSampleBufferGetImageBuffer(buffer)))
    }

    private static func output(_ pixelBuffer: CVPixelBuffer) -> Output {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        func plane(_ index: Int, samplesPerRow: Int, rows: Int) -> [UInt16] {
            let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, index)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, index)
            var samples: [UInt16] = []
            for row in 0..<rows {
                samples += UnsafeBufferPointer(
                    start: base.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self),
                    count: samplesPerRow
                )
            }
            return samples
        }
        return Output(luma: plane(0, samplesPerRow: width, rows: height), chroma: plane(1, samplesPerRow: width, rows: height / 2))
    }
}
