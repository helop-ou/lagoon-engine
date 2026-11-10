import CoreMedia
import CoreVideo
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Testing
@testable import LagoonEngine

/// H.264 that VideoToolbox does not decode on Apple TV or iPhone: x264 at
/// 64x48, 24 fps, half a second, as `-pix_fmt yuv422p`, `yuv444p` and
/// `yuv422p10le`. It decodes in software and leaves the GPU stage as 10-bit
/// 4:2:0.
@Suite("Extended chroma in software")
struct ExtendedChromaDecodeTests {
    @Test(arguments: ["h264-422", "h264-444", "h264-422-10"])
    func aFourTwoTwoOrFourFourFourStreamDecodesToTenBit420(_ name: String) throws {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "mkv", subdirectory: "ExtendedChroma"))
        let demuxer = FFmpegDemuxer(capabilities: PlaybackCapabilities(hardwareHEVC: true, hardwareAV1: true))
        defer { demuxer.close() }
        try demuxer.open(url: url.path(percentEncoded: false), recommendedPixelBufferAttributes: CVPixelBufferAttributes())
        #expect(demuxer.outputsDecodedVideo, "sent to VideoToolbox")
        let decoder = try #require(demuxer.takeSoftwareVideoDecoder())

        let reference = try Self.referenceChroma(of: url)
        var buffers: [CMSampleBuffer] = []
        reading: for _ in 0..<500 {
            switch demuxer.readNext() {
            case .videoPacket(let packet):
                buffers += try decoder.decode(packet: packet.packet)
            case .failed(let message):
                Issue.record("\(name): \(message)")
                break reading
            case .endOfFile:
                break reading
            default:
                continue
            }
        }
        // Frame threading holds a short clip back until the drain.
        buffers += try decoder.drain()
        #expect(buffers.count == 12)
        let images = buffers.compactMap(CMSampleBufferGetImageBuffer)
        #expect(images.count == buffers.count)
        for image in images {
            #expect(CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            #expect(CVPixelBufferGetWidth(image) == 64 && CVPixelBufferGetHeight(image) == 48)
        }
        let first = try #require(images.first)
        #expect(Self.chroma(of: first) == reference, "first frame's chroma")
    }

    /// The output's interleaved chroma codes, 10-bit, row by row.
    private static func chroma(of image: CVPixelBuffer) -> [Int] {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 1) else { return [] }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        return (0..<CVPixelBufferGetHeightOfPlane(image, 1)).flatMap { row in
            let samples = base.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)
            return (0..<(CVPixelBufferGetWidthOfPlane(image, 1) * 2)).map { Int(samples[$0] >> 6) }
        }
    }

    /// The first frame decoded by libavcodec alone, its chroma taken to 10-bit
    /// 4:2:0 the way the GPU stage does: each code to 10 bits, then the
    /// rounded mean of the samples under each 2x2 block.
    private static func referenceChroma(of url: URL) throws -> [Int] {
        var context: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_open_input(&context, url.path(percentEncoded: false), nil, nil) >= 0)
        defer { avformat_close_input(&context) }
        try #require(avformat_find_stream_info(context, nil) >= 0)
        let parameters = try #require(context?.pointee.streams[0]?.pointee.codecpar)
        let codec = try #require(avcodec_find_decoder(parameters.pointee.codec_id))
        var decoder = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&decoder) }
        avcodec_parameters_to_context(decoder, parameters)
        try #require(avcodec_open2(decoder, codec, nil) >= 0)
        var packet = av_packet_alloc()
        var frame = av_frame_alloc()
        defer { av_packet_free(&packet); av_frame_free(&frame) }
        var decoded = false
        while !decoded, av_read_frame(context, packet) >= 0 {
            avcodec_send_packet(decoder, packet)
            av_packet_unref(packet)
            decoded = avcodec_receive_frame(decoder, frame) >= 0
        }
        if !decoded {
            avcodec_send_packet(decoder, nil)
            decoded = avcodec_receive_frame(decoder, frame) >= 0
        }
        try #require(decoded)
        let format = AVPixelFormat(rawValue: frame!.pointee.format)
        let layout = try #require(SoftwareVideoDecoder.gpuSourceLayout(format))
        let (width, height) = (Int(frame!.pointee.width), Int(frame!.pointee.height))
        func code(_ plane: Int, _ x: Int, _ y: Int) -> Int {
            let base = plane == 1 ? frame!.pointee.data.1! : frame!.pointee.data.2!
            let stride = Int(plane == 1 ? frame!.pointee.linesize.1 : frame!.pointee.linesize.2)
            if layout.bitDepth == 8 { return Int(base[y * stride + x]) << 2 }
            let value = Int(UnsafeRawPointer(base + y * stride).assumingMemoryBound(to: UInt16.self)[x])
            return layout.bitDepth == 12 ? min((value + 2) >> 2, 1023) : min(value, 1023)
        }
        let spanX = 2 >> layout.chromaShiftX
        let spanY = 2 >> layout.chromaShiftY
        let count = spanX * spanY
        var codes: [Int] = []
        for y in 0..<(height / 2) {
            for x in 0..<(width / 2) {
                for plane in [1, 2] {
                    var sum = 0
                    for dy in 0..<spanY {
                        for dx in 0..<spanX { sum += code(plane, x * spanX + dx, y * spanY + dy) }
                    }
                    codes.append((sum + count / 2) / count)
                }
            }
        }
        return codes
    }

    @Test func fourTwoTwoAndFourFourFourProfilesLeaveHardware() {
        for profile: Int32 in [122, 122 | 2048, 144, 244, 244 | 2048, 44] {
            #expect(FFmpegDemuxer.isExtendedChromaH264(profile: profile, pixelFormat: AV_PIX_FMT_NONE), "\(profile)")
        }
        #expect(FFmpegDemuxer.isExtendedChromaH264(profile: 100, pixelFormat: AV_PIX_FMT_YUV444P))
        #expect(!FFmpegDemuxer.isExtendedChromaH264(profile: 100, pixelFormat: AV_PIX_FMT_YUV420P))
        #expect(!FFmpegDemuxer.isExtendedChromaH264(profile: 110, pixelFormat: AV_PIX_FMT_YUV420P10LE))
    }

    @Test func everyGPULayoutIsTenBitOut() {
        for format in [AV_PIX_FMT_YUV422P, AV_PIX_FMT_YUV444P10LE, AV_PIX_FMT_YUV420P12LE] {
            #expect(SoftwareVideoDecoder.outputBitDepth(
                pixelFormat: format, bitsPerRawSample: 0, bitsPerCodedSample: 0, codecID: AV_CODEC_ID_H264
            ) == 10)
        }
        #expect(SoftwareVideoDecoder.gpuSourceLayout(AV_PIX_FMT_YUV420P) == nil, "8-bit 4:2:0 keeps its CPU path")
    }
}
