import AVFoundation
import CoreMedia
import Foundation
import Libavcodec
import Libavutil
import Testing
@testable import LagoonEngine

/// Night mode, dialogue boost and the channel limit, on generated signals.
@Suite("Audio shaping")
struct AudioShapingTests {
    // MARK: - Remix

    @Test func theChannelLimitDownmixesToTheLimitsLayout() throws {
        let capped = try makeDecoder(channels: 6, shaping: AudioShaping(channelLimit: .stereo))
        #expect(Self.channels(of: capped.formatDescription) == 2)
        let surround = try makeDecoder(channels: 8, shaping: AudioShaping(channelLimit: .surround))
        #expect(Self.channels(of: surround.formatDescription) == 6)
        // A limit above the source changes nothing.
        let stereo = try makeDecoder(channels: 2, shaping: AudioShaping(channelLimit: .surround))
        #expect(Self.channels(of: stereo.formatDescription) == 2)
    }

    /// Downmixed to stereo, the centre reaches each side at -3 dB and the
    /// front left at 0 dB. The boost moves the centre 3 dB up and the rest
    /// 3 dB down.
    @Test func theDialogueBoostLiftsTheCentreOverTheOtherChannels() throws {
        let plain = AudioShaping(channelLimit: .stereo)
        let boosted = AudioShaping(dialogueBoost: true, channelLimit: .stereo)
        var surround = AVChannelLayout()
        av_channel_layout_default(&surround, 6)
        let centre = av_channel_layout_index_from_channel(&surround, AV_CHAN_FRONT_CENTER)
        let frontLeft = av_channel_layout_index_from_channel(&surround, AV_CHAN_FRONT_LEFT)

        let plainCentre = try leftPeak(shaping: plain, channel: centre)
        let plainFront = try leftPeak(shaping: plain, channel: frontLeft)
        #expect(abs(plainCentre - 0.1 / Float(2).squareRoot()) < 0.002)
        #expect(abs(plainFront - 0.1) < 0.002)

        #expect(abs(try leftPeak(shaping: boosted, channel: centre) - 0.1) < 0.002)
        #expect(abs(try leftPeak(shaping: boosted, channel: frontLeft) - 0.1 / Float(2).squareRoot()) < 0.002)
    }

    @Test func withoutACentreTheMatrixIsSwresamplesOwn() {
        var stereo = AVChannelLayout()
        av_channel_layout_default(&stereo, 2)
        #expect(AudioShapingMatrix.coefficients(from: &stereo, to: &stereo, liftingCentre: true) == nil)
        var surround = AVChannelLayout()
        av_channel_layout_default(&surround, 6)
        #expect(AudioShapingMatrix.coefficients(from: &surround, to: &stereo, liftingCentre: false) == nil)
        // Mono is all centre, with nothing to lift it over.
        var mono = AVChannelLayout()
        av_channel_layout_default(&mono, 1)
        #expect(AudioShapingMatrix.coefficients(from: &mono, to: &mono, liftingCentre: true) == nil)
    }

    /// `swr_build_matrix2` scales 64 rows of 64 whatever the layouts. A
    /// matrix sized to the channels had it rewriting the heap past its end.
    @Test func theMatrixHasRoomForEverythingSwresampleTouches() throws {
        var surround = AVChannelLayout()
        av_channel_layout_default(&surround, 6)
        var stereo = AVChannelLayout()
        av_channel_layout_default(&stereo, 2)
        let matrix = try #require(AudioShapingMatrix.coefficients(from: &surround, to: &stereo, liftingCentre: true))
        #expect(AudioShapingMatrix.stride >= 64)
        #expect(matrix.count >= AudioShapingMatrix.stride * 64)
    }

    // MARK: - Speech band

    @Test func stereoDialogueBoostLiftsTheSharedSpeechBand() throws {
        let decoder = try makeDecoder(channels: 2, shaping: AudioShaping(dialogueBoost: true))
        let shared = try peaks(decoder, channels: 2, seconds: 0.5) { _, sample in Self.sine(1_000, sample) * 0.1 }
        // About 6 dB at 1 kHz.
        #expect(shared.allSatisfy { abs($0 - 0.2) < 0.01 }, "\(shared)")
    }

    @Test func soundOnOneSideAndLowFrequenciesStayPut() {
        var shaper = AudioShaper(shaping: AudioShaping(dialogueBoost: true), sampleRate: 48_000, channels: 2)
        shaper.liftsSpeechBand = true
        let opposed = Self.shaped(&shaper, channels: 2, seconds: 0.5) { channel, sample in
            Self.sine(1_000, sample) * (channel == 0 ? 0.1 : -0.1)
        }
        #expect(opposed.allSatisfy { abs($0 - 0.1) < 0.001 }, "\(opposed)")
        shaper.reset()
        let bass = Self.shaped(&shaper, channels: 2, seconds: 0.5) { _, sample in Self.sine(100, sample) * 0.1 }
        #expect(bass.allSatisfy { $0 < 0.11 }, "\(bass)")
    }

    // MARK: - Night mode

    /// -30 dB threshold, 4:1, 10 dB makeup: full scale settles at -12.5 dB
    /// and anything under the threshold comes up 10 dB. A square wave, so the
    /// detector settles on the level itself rather than under a sine's peak.
    @Test func nightModeBringsLoudDownAndQuietUp() {
        var shaper = AudioShaper(shaping: AudioShaping(nightMode: true), sampleRate: 48_000, channels: 2)
        let loud = Self.shaped(&shaper, channels: 2, seconds: 1) { _, sample in Self.square(1_000, sample) }
        let expectedLoud = powf(10, -12.5 / 20)
        #expect(loud.allSatisfy { abs($0 - expectedLoud) < expectedLoud * 0.03 }, "\(loud)")

        shaper.reset()
        let quiet = Self.shaped(&shaper, channels: 2, seconds: 1) { _, sample in Self.square(1_000, sample) * 0.01 }
        let expectedQuiet = 0.01 * powf(10, 10.0 / 20)
        #expect(quiet.allSatisfy { abs($0 - expectedQuiet) < expectedQuiet * 0.03 }, "\(quiet)")
    }

    @Test func nightModeIsLinkedAcrossChannels() {
        var shaper = AudioShaper(shaping: AudioShaping(nightMode: true), sampleRate: 48_000, channels: 2)
        let peaks = Self.shaped(&shaper, channels: 2, seconds: 1) { channel, sample in
            Self.sine(1_000, sample) * (channel == 0 ? 1 : 0.5)
        }
        // A quieter right channel keeps its place against the left.
        #expect(abs(peaks[1] / peaks[0] - 0.5) < 0.01, "\(peaks)")
    }

    // MARK: - Limiter

    /// One bad sample in a float PCM track silenced the rest of playback:
    /// it stayed in the speech filter and the compressor's envelope.
    @Test func aSampleThatIsNotANumberDoesNotOutliveItsBuffer() {
        for bad in [Float.nan, .infinity, -.infinity] {
            var shaper = AudioShaper(
                shaping: AudioShaping(nightMode: true, dialogueBoost: true), sampleRate: 48_000, channels: 2
            )
            shaper.liftsSpeechBand = true
            var first = [Float](repeating: 0.1, count: 2 * 480)
            first[200] = bad
            first.withUnsafeMutableBufferPointer { shaper.process($0.baseAddress!, frames: 480) }
            let firstIsFinite = first.allSatisfy { $0.isFinite }
            #expect(firstIsFinite, "\(bad): its own buffer")
            var later = (0..<(2 * 4_800)).map { Float(sin(Double($0 / 2) * 2 * .pi * 1_000 / 48_000)) * 0.1 }
            later.withUnsafeMutableBufferPointer { shaper.process($0.baseAddress!, frames: 4_800) }
            let laterIsFinite = later.allSatisfy { $0.isFinite }
            #expect(laterIsFinite, "\(bad): what follows")
            let loudest = later.map(abs).max() ?? 0
            #expect(loudest > 0.01, "\(bad): still sound")
        }
    }

    @Test func theLimiterHoldsEverySampleUnderTheCeiling() {
        var shaper = AudioShaper(shaping: AudioShaping(channelLimit: .stereo), sampleRate: 48_000, channels: 2)
        var samples = Self.interleaved(channels: 2, seconds: 0.5) { _, sample in Self.sine(440, sample) * 2 }
        samples.withUnsafeMutableBufferPointer { shaper.process($0.baseAddress!, frames: $0.count / 2) }
        let loudest = samples.map(abs).max() ?? 0
        #expect(loudest <= AudioShaper.limiterCeiling + 1e-6, "\(loudest)")
        #expect(loudest > AudioShaper.limiterCeiling * 0.95)
    }

    @Test func theLimiterLeavesSignalUnderTheCeilingAlone() {
        var shaper = AudioShaper(shaping: AudioShaping(channelLimit: .stereo), sampleRate: 48_000, channels: 2)
        let original = Self.interleaved(channels: 2, seconds: 0.25) { _, sample in Self.sine(440, sample) * 0.5 }
        var samples = original
        samples.withUnsafeMutableBufferPointer { shaper.process($0.baseAddress!, frames: $0.count / 2) }
        #expect(samples == original)
    }

    // MARK: - Passthrough

    /// A stream that can pass through decodes while shaping is on, and goes
    /// back to passthrough when it is turned off, without a reopen.
    @Test func shapingMovesAPassthroughStreamToDecodingAndBack() throws {
        let url = try #require(Bundle.module.url(forResource: "two-subrip", withExtension: "mkv", subdirectory: "TextSubtitles"))
        let demuxer = FFmpegDemuxer()
        try demuxer.open(url: url.path(percentEncoded: false), recommendedPixelBufferAttributes: CVPixelBufferAttributes())
        defer { demuxer.close() }
        let audio = try #require(demuxer.audioStreams.first)
        demuxer.selectAudio(streamIndex: audio.streamIndex)
        #expect(!demuxer.outputsDecodedAudio(streamIndex: audio.streamIndex))
        #expect(try Self.firstAudioFormat(demuxer) == kAudioFormatMPEG4AAC)

        demuxer.setAudioShaping(AudioShaping(nightMode: true))
        try demuxer.seek(toSeconds: 0)
        #expect(demuxer.outputsDecodedAudio(streamIndex: audio.streamIndex))
        #expect(try Self.firstAudioFormat(demuxer) == kAudioFormatLinearPCM)

        demuxer.setAudioShaping(.off)
        try demuxer.seek(toSeconds: 0)
        #expect(!demuxer.outputsDecodedAudio(streamIndex: audio.streamIndex))
        #expect(try Self.firstAudioFormat(demuxer) == kAudioFormatMPEG4AAC)
    }

    /// Set before `prepare`, the title opens shaped. Changed while playing,
    /// it applies from the current position.
    @MainActor
    @Test func theEngineOpensWithShapingAndFollowsAChange() async throws {
        let url = try #require(Bundle.module.url(forResource: "two-subrip", withExtension: "mkv", subdirectory: "TextSubtitles"))
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        var failure: String?
        engine.onError = { failure = $0.message }
        engine.setAudioShaping(AudioShaping(dialogueBoost: true))
        engine.prepare(url: url, startSeconds: 0, initialAudioOrdinal: nil)
        engine.pause()
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())

        try await Self.wait(until: { engine.audioOutputPathDiagnostic == "LPCM" && !engine.isBuffering }, failure: { failure })
        #expect(engine.audioOutputPathDiagnostic == "LPCM")
        engine.setAudioShaping(.off)
        try await Self.wait(until: { engine.audioOutputPathDiagnostic == "compressed" && !engine.isBuffering }, failure: { failure })
        #expect(engine.audioOutputPathDiagnostic == "compressed")
        #expect(failure == nil)
        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }

    // MARK: - Helpers

    private static func sine(_ frequency: Float, _ sample: Int) -> Float {
        sinf(2 * .pi * frequency * Float(sample) / 48_000)
    }

    private static func square(_ frequency: Float, _ sample: Int) -> Float {
        sine(frequency, sample) < 0 ? -1 : 1
    }

    private static func channels(of description: CMFormatDescription) -> UInt32? {
        CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mChannelsPerFrame
    }

    /// The left output's peak over the last half second, with a 0.1 sine on
    /// one input channel of a 5.1 source.
    private func leftPeak(shaping: AudioShaping, channel: Int32) throws -> Float {
        let decoder = try makeDecoder(channels: 6, shaping: shaping)
        return try peaks(decoder, channels: 6, seconds: 1) { input, sample in
            input == Int(channel) ? Self.sine(1_000, sample) * 0.1 : 0
        }[0]
    }

    private func makeDecoder(channels: Int32, shaping: AudioShaping) throws -> AudioDecoder {
        let parameters = try #require(avcodec_parameters_alloc())
        defer {
            var pointer: UnsafeMutablePointer<AVCodecParameters>? = parameters
            avcodec_parameters_free(&pointer)
        }
        parameters.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        parameters.pointee.codec_id = AV_CODEC_ID_PCM_F32LE
        parameters.pointee.sample_rate = 48_000
        av_channel_layout_default(&parameters.pointee.ch_layout, channels)
        return try #require(AudioDecoder(codecpar: parameters, timeBase: AVRational(num: 1, den: 48_000), shaping: shaping))
    }

    /// Feeds planar frames through the decoder and returns each output
    /// channel's peak over the second half, once the stages have settled.
    private func peaks(
        _ decoder: AudioDecoder,
        channels: Int32,
        seconds: Double,
        signal: (Int, Int) -> Float
    ) throws -> [Float] {
        let frameSize = 1_024
        let frameCount = Int(seconds * 48_000) / frameSize
        var output: [Float] = []
        for index in 0..<frameCount {
            var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
            let current = try #require(frame)
            defer { av_frame_free(&frame) }
            current.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
            current.pointee.sample_rate = 48_000
            current.pointee.nb_samples = Int32(frameSize)
            av_channel_layout_default(&current.pointee.ch_layout, channels)
            #expect(av_frame_get_buffer(current, 0) >= 0)
            for plane in 0..<Int(channels) {
                let samples = UnsafeMutableRawPointer(current.pointee.extended_data[plane]!)
                    .assumingMemoryBound(to: Float.self)
                for sample in 0..<frameSize { samples[sample] = signal(plane, index * frameSize + sample) }
            }
            current.pointee.pts = Int64(index * frameSize)
            for buffer in decoder.append(decodedFrame: current) {
                output += try Self.samples(of: buffer)
            }
        }
        for buffer in decoder.drain() {
            output += try Self.samples(of: buffer)
        }
        let outputChannels = Int(Self.channels(of: decoder.formatDescription) ?? 1)
        return Self.channelPeaks(output, channels: outputChannels)
    }

    private static func shaped(
        _ shaper: inout AudioShaper,
        channels: Int,
        seconds: Double,
        signal: (Int, Int) -> Float
    ) -> [Float] {
        var samples = interleaved(channels: channels, seconds: seconds, signal: signal)
        samples.withUnsafeMutableBufferPointer { shaper.process($0.baseAddress!, frames: $0.count / channels) }
        return channelPeaks(samples, channels: channels)
    }

    private static func interleaved(channels: Int, seconds: Double, signal: (Int, Int) -> Float) -> [Float] {
        let frames = Int(seconds * 48_000)
        var samples = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels {
                samples[frame * channels + channel] = signal(channel, frame)
            }
        }
        return samples
    }

    private static func channelPeaks(_ samples: [Float], channels: Int) -> [Float] {
        let frames = samples.count / channels
        var peaks = [Float](repeating: 0, count: channels)
        for frame in (frames / 2)..<frames {
            for channel in 0..<channels {
                peaks[channel] = max(peaks[channel], abs(samples[frame * channels + channel]))
            }
        }
        return peaks
    }

    private static func samples(of buffer: CMSampleBuffer) throws -> [Float] {
        let block = try #require(CMSampleBufferGetDataBuffer(buffer))
        let length = CMBlockBufferGetDataLength(block)
        var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        let status = samples.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        #expect(status == noErr)
        return samples
    }

    private static func firstAudioFormat(_ demuxer: FFmpegDemuxer) throws -> AudioFormatID? {
        for _ in 0..<500 {
            switch demuxer.readNext() {
            case .audio(let buffers, _):
                guard let description = buffers.first.flatMap(CMSampleBufferGetFormatDescription) else { continue }
                return CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mFormatID
            case .endOfFile, .failed:
                return nil
            default:
                continue
            }
        }
        return nil
    }

    @MainActor
    private static func wait(until condition: () -> Bool, failure: () -> String?) async throws {
        // Generous: other suites' main-actor tests run while this one waits.
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), failure() == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
