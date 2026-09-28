import CoreMedia
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Testing
@testable import LagoonEngine

/// A stream whose audio changes shape mid-way (a 5.1 programme joined to a
/// stereo advert, a 44.1 kHz stretch in 48 kHz) keeps the renderer's format
/// and its own duration. The decoder rebuilds its resampler for every new
/// rate or layout; it used to rebuild only for a new sample format, and read
/// six planes from a two-plane frame.
@Suite("Audio decoder resampling")
struct AudioDecoderResampleTests {
    @Test func aLayoutChangeKeepsTheDeclaredFormatAndEverySample() throws {
        // Declared 5.1 first: a resampler kept for six planes reads past a
        // stereo frame's two.
        let decoder = try makeDecoder(channels: 6, rate: 48_000)
        var samples = 0
        for layoutChannels: Int32 in [6, 2, 6, 2] {
            for buffer in try feed(decoder, channels: layoutChannels, rate: 48_000, frames: 24) {
                #expect(CMSampleBufferGetFormatDescription(buffer) == decoder.formatDescription)
                samples += CMSampleBufferGetNumSamples(buffer)
            }
        }
        samples += flushedSamples(decoder)
        // 4 × 24 frames of 1,024 samples, all at the declared 48 kHz.
        #expect(abs(samples - 4 * 24 * 1_024) <= 64)
    }

    @Test func aRateChangeIsResampledNotPlayedAtTheWrongPitch() throws {
        let decoder = try makeDecoder(channels: 2, rate: 48_000)
        var samples = 0
        for buffer in try feed(decoder, channels: 2, rate: 48_000, frames: 47) {
            samples += CMSampleBufferGetNumSamples(buffer)
        }
        // About a second at 44.1 kHz has to come out as about a second at 48.
        for buffer in try feed(decoder, channels: 2, rate: 44_100, frames: 43, startSeconds: 47 * 1_024 / 48_000.0) {
            samples += CMSampleBufferGetNumSamples(buffer)
        }
        samples += flushedSamples(decoder)
        let expected = 47 * 1_024 + Int((43 * 1_024 * 48_000.0 / 44_100).rounded())
        #expect(abs(samples - expected) <= 256, "\(samples) vs \(expected)")
    }

    /// The real decoder over a real stream: MPEG-TS whose ADTS AAC goes
    /// stereo 48 kHz, 5.1 48 kHz, stereo 44.1 kHz, two seconds each. Opt-in:
    /// set `LAGOON_LAYOUT_CHANGE_TS_FIXTURE_URL` (recipe in decode.md).
    @Test func aBroadcastStreamThatChangesShapeDecodesWhole() throws {
        guard let path = ProcessInfo.processInfo.environment["LAGOON_LAYOUT_CHANGE_TS_FIXTURE_URL"],
              !path.isEmpty else { return }
        var format: UnsafeMutablePointer<AVFormatContext>?
        #expect(avformat_open_input(&format, path, nil, nil) >= 0)
        let context = try #require(format)
        defer { avformat_close_input(&format) }
        #expect(avformat_find_stream_info(context, nil) >= 0)
        let index = av_find_best_stream(context, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        let stream = try #require(context.pointee.streams[Int(index)])
        let decoder = try #require(AudioDecoder(codecpar: stream.pointee.codecpar, timeBase: stream.pointee.time_base))
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let current = try #require(packet)
        var samples = 0
        while av_read_frame(context, current) >= 0 {
            if current.pointee.stream_index == index {
                for buffer in decoder.decode(packet: current) {
                    #expect(CMSampleBufferGetFormatDescription(buffer) == decoder.formatDescription)
                    samples += CMSampleBufferGetNumSamples(buffer)
                }
            }
            av_packet_unref(current)
        }
        samples += flushedSamples(decoder)
        let expected = try Self.samplesAt48kHz(path: path)
        #expect(abs(samples - expected) <= 256, "\(samples) samples, expected \(expected)")
    }

    /// What the stream holds at 48 kHz, by plain libavcodec: every decoded
    /// frame's samples scaled from its own rate.
    private static func samplesAt48kHz(path: String) throws -> Int {
        var format: UnsafeMutablePointer<AVFormatContext>?
        #expect(avformat_open_input(&format, path, nil, nil) >= 0)
        let context = try #require(format)
        defer { avformat_close_input(&format) }
        avformat_find_stream_info(context, nil)
        let index = av_find_best_stream(context, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        let parameters = try #require(context.pointee.streams[Int(index)]?.pointee.codecpar)
        var codec: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(avcodec_find_decoder(parameters.pointee.codec_id))
        defer { avcodec_free_context(&codec) }
        let decoder = try #require(codec)
        avcodec_parameters_to_context(decoder, parameters)
        #expect(avcodec_open2(decoder, nil, nil) >= 0)
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_packet_free(&packet); av_frame_free(&frame) }
        var seconds = 0.0
        func receive() {
            while avcodec_receive_frame(decoder, frame) >= 0 {
                seconds += Double(frame!.pointee.nb_samples) / Double(frame!.pointee.sample_rate)
                av_frame_unref(frame)
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
        return Int((seconds * 48_000).rounded())
    }

    // MARK: - Helpers

    private func makeDecoder(channels: Int32, rate: Int32) throws -> AudioDecoder {
        let parameters = try #require(avcodec_parameters_alloc())
        defer {
            var pointer: UnsafeMutablePointer<AVCodecParameters>? = parameters
            avcodec_parameters_free(&pointer)
        }
        parameters.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        parameters.pointee.codec_id = AV_CODEC_ID_PCM_F32LE
        parameters.pointee.sample_rate = rate
        av_channel_layout_default(&parameters.pointee.ch_layout, channels)
        return try #require(AudioDecoder(codecpar: parameters, timeBase: AVRational(num: 1, den: rate)))
    }

    /// Planar float frames of 1,024 samples, as AAC decodes, with pts in
    /// the decoder's time base.
    private func feed(
        _ decoder: AudioDecoder,
        channels: Int32,
        rate: Int32,
        frames: Int,
        startSeconds: Double = 0
    ) throws -> [CMSampleBuffer] {
        var buffers: [CMSampleBuffer] = []
        for index in 0..<frames {
            var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
            let current = try #require(frame)
            defer { av_frame_free(&frame) }
            current.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
            current.pointee.sample_rate = rate
            current.pointee.nb_samples = 1_024
            av_channel_layout_default(&current.pointee.ch_layout, channels)
            #expect(av_frame_get_buffer(current, 0) >= 0)
            for plane in 0..<Int(channels) {
                let samples = UnsafeMutableRawPointer(current.pointee.extended_data[plane]!)
                    .assumingMemoryBound(to: Float.self)
                for sample in 0..<1_024 { samples[sample] = sinf(Float(sample) * 0.05) * 0.25 }
            }
            // The decoder's time base is 1/48000.
            current.pointee.pts = Int64(((startSeconds + Double(index) * 1_024 / Double(rate)) * 48_000).rounded())
            buffers += decoder.append(decodedFrame: current)
        }
        return buffers
    }

    private func flushedSamples(_ decoder: AudioDecoder) -> Int {
        decoder.drain().reduce(0) { $0 + CMSampleBufferGetNumSamples($1) }
    }
}
