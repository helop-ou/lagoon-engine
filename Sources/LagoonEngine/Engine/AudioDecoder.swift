import AudioToolbox
import CoreMedia
import Foundation
import Libavcodec
import Libavutil
import Libswresample

/// Decodes audio codecs CoreAudio won't take compressed
/// (DTS, TrueHD, FLAC, Opus, Vorbis, …) into interleaved Float32 LPCM
/// sample buffers for AVSampleBufferAudioRenderer. Passthrough codecs
/// never come here — SampleBufferFactory.audioFormatDescription wraps
/// those first. All methods run on the demux queue.
nonisolated final class AudioDecoder {
    private let codecContext: UnsafeMutablePointer<AVCodecContext>
    private let frame: UnsafeMutablePointer<AVFrame>
    private let timeBase: AVRational
    private let sampleRate: Int32
    private let channels: Int32
    private var resampler: OpaquePointer?
    private var resamplerInputFormat = AV_SAMPLE_FMT_NONE

    /// LPCM Float32 interleaved at the stream's declared rate/layout —
    /// known up front, so the renderer format never changes mid-stream.
    let formatDescription: CMFormatDescription

    // Decoders like TrueHD emit tiny frames (40 samples per access unit);
    // coalesce into ~2048-sample buffers so the renderer queue holds
    // seconds, not thousands of slivers.
    // Mutable storage swresample fills in place and emit copies out of.
    // TrueHD commonly yields 40-sample frames, so avoiding a temporary
    // allocation + append for every one matters far more than it would for
    // codecs that already produce large frames. The buffer is reused across
    // emits: only its length is reset, never its allocation.
    private var pendingSamples = NSMutableData()
    private var pendingSampleCount = 0
    private var pendingStartSeconds: Double?
    /// Sample-accurate end of everything emitted so far. Successive
    /// buffers anchor here, NOT to container pts: Matroska stamps at 1 ms
    /// precision while TrueHD frames are 0.83 ms, so trusting each pts
    /// would jitter every buffer boundary by up to half a millisecond —
    /// audible as steady clicking (found in the first 7.1 TrueHD sim pass).
    private var continuationSeconds: Double?

    init?(codecpar: UnsafeMutablePointer<AVCodecParameters>, timeBase: AVRational) {
        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id),
              let context = avcodec_alloc_context3(codec) else {
            return nil
        }
        guard avcodec_parameters_to_context(context, codecpar) >= 0 else {
            var ctx: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&ctx)
            return nil
        }
        context.pointee.pkt_timebase = timeBase
        guard avcodec_open2(context, codec, nil) >= 0, let frame = av_frame_alloc() else {
            var ctx: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&ctx)
            return nil
        }

        let rate = max(codecpar.pointee.sample_rate, 1)
        let channelCount = max(codecpar.pointee.ch_layout.nb_channels, 1)
        guard let description = Self.lpcmFormatDescription(
            sampleRate: rate,
            channels: channelCount,
            layout: codecpar.pointee.ch_layout
        ) else {
            var ctx: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&ctx)
            var framePtr: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&framePtr)
            return nil
        }

        codecContext = context
        self.frame = frame
        self.timeBase = timeBase
        sampleRate = rate
        channels = channelCount
        formatDescription = description
        pendingSamples = NSMutableData(
            capacity: 2048 * Int(channelCount) * MemoryLayout<Float32>.size
        ) ?? NSMutableData()
    }

    deinit {
        if resampler != nil {
            swr_free(&resampler)
        }
        var framePtr: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&framePtr)
        var ctx: UnsafeMutablePointer<AVCodecContext>? = codecContext
        avcodec_free_context(&ctx)
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>) -> [CMSampleBuffer] {
        guard avcodec_send_packet(codecContext, packet) >= 0 else { return [] }
        var buffers: [CMSampleBuffer] = []
        while avcodec_receive_frame(codecContext, frame) >= 0 {
            accumulate(into: &buffers)
            av_frame_unref(frame)
        }
        return buffers
    }

    func flush() {
        avcodec_flush_buffers(codecContext)
        pendingSamples.length = 0
        pendingSampleCount = 0
        pendingStartSeconds = nil
        continuationSeconds = nil
    }

    /// End of stream: pull the decoder's remaining frames and the
    /// coalescing tail so the last fraction of a second isn't dropped.
    /// Flushes afterwards, so a later seek can reuse the decoder.
    func drain() -> [CMSampleBuffer] {
        var buffers: [CMSampleBuffer] = []
        avcodec_send_packet(codecContext, nil)
        while avcodec_receive_frame(codecContext, frame) >= 0 {
            accumulate(into: &buffers)
            av_frame_unref(frame)
        }
        emitPending(into: &buffers)
        avcodec_flush_buffers(codecContext)
        return buffers
    }

    // MARK: - Frame → coalesced LPCM

    private func accumulate(into buffers: inout [CMSampleBuffer]) {
        let frameSeconds: Double? = frame.pointee.pts == Int64.min
            ? nil
            : Double(frame.pointee.pts) * Double(timeBase.num) / Double(max(timeBase.den, 1))

        // A real pts jump means a gap (or a seek landed mid-stream): emit
        // what we have and re-anchor to the container's clock. Anything
        // within the tolerance is timestamp quantization, not a gap.
        let expected = pendingStartSeconds.map { $0 + Double(pendingSampleCount) / Double(sampleRate) }
            ?? continuationSeconds
        if let frameSeconds, let expected, abs(frameSeconds - expected) > 0.05 {
            emitPending(into: &buffers)
            continuationSeconds = nil
        }

        guard let convertedSamples = appendConvertedFrame() else { return }
        if pendingStartSeconds == nil {
            pendingStartSeconds = continuationSeconds ?? frameSeconds
        }
        pendingSampleCount += convertedSamples

        if pendingSampleCount >= 2048 {
            emitPending(into: &buffers)
        }
    }

    /// Converts directly into the coalescing buffer. This removes the old
    /// per-decoded-frame temporary Data allocation and its append copy.
    private func appendConvertedFrame() -> Int? {
        let inputFormat = AVSampleFormat(rawValue: frame.pointee.format)
        if resampler == nil || resamplerInputFormat != inputFormat {
            if resampler != nil {
                swr_free(&resampler)
            }
            var context: OpaquePointer?
            let status = withUnsafePointer(to: codecContext.pointee.ch_layout) { outLayout in
                withUnsafePointer(to: frame.pointee.ch_layout) { inLayout in
                    swr_alloc_set_opts2(
                        &context,
                        outLayout, AV_SAMPLE_FMT_FLT, sampleRate,
                        inLayout, inputFormat, frame.pointee.sample_rate,
                        0, nil
                    )
                }
            }
            guard status >= 0, swr_init(context) >= 0 else { return nil }
            resampler = context
            resamplerInputFormat = inputFormat
        }

        let inSamples = Int(frame.pointee.nb_samples)
        let capacity = inSamples + 256
        let bytesPerFrame = Int(channels) * MemoryLayout<Float32>.size
        let previousLength = pendingSamples.length
        pendingSamples.length = previousLength + capacity * bytesPerFrame
        var outPointer: UnsafeMutablePointer<UInt8>? = pendingSamples.mutableBytes
            .advanced(by: previousLength)
            .assumingMemoryBound(to: UInt8.self)
        let inPointers = UnsafeMutableRawPointer(frame.pointee.extended_data)?
            .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        let convertedSamples = withUnsafeMutablePointer(to: &outPointer) { outArray in
            swr_convert(resampler, outArray, Int32(capacity), inPointers, Int32(inSamples))
        }
        guard convertedSamples > 0 else {
            pendingSamples.length = previousLength
            return nil
        }
        pendingSamples.length = previousLength + Int(convertedSamples) * bytesPerFrame
        return Int(convertedSamples)
    }

    private func emitPending(into buffers: inout [CMSampleBuffer]) {
        defer {
            // Length only — NSMutableData keeps the allocation, so the
            // steady state costs no allocation per emitted buffer.
            pendingSamples.length = 0
            pendingSampleCount = 0
            pendingStartSeconds = nil
        }
        guard pendingSampleCount > 0 else { return }
        if let start = pendingStartSeconds {
            continuationSeconds = start + Double(pendingSampleCount) / Double(sampleRate)
        }
        guard let buffer = makeSampleBuffer(
            data: pendingSamples,
            samples: pendingSampleCount,
            startSeconds: pendingStartSeconds
        ) else { return }
        buffers.append(buffer)
    }

    /// The LPCM payload is copied into a CoreMedia-owned block rather than
    /// handed over zero-copy. An earlier attempt tried the handoff (this
/// buffer behind a
    /// CMBlockBufferCustomBlockSource) and it leaked the entire decoded
    /// stream — ~2.3 MB/s on TrueHD 7.1, which walked the app into the 2 GB
    /// per-process limit and got it jetsam-killed mid-playback. The copy that
    /// bought is 1.5 MB/s on the demux queue, ~0.03% of a core. The video
    /// path keeps its zero-copy AVBufferRef handoff: that one is both far
    /// larger (8.65 MB/s on a 4K remux) and measured leak-free.
    private func makeSampleBuffer(data: NSMutableData, samples: Int, startSeconds: Double?) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.length,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { return nil }
        guard CMBlockBufferReplaceDataBytes(
            with: data.bytes,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: data.length
        ) == noErr else { return nil }

        // Timescale = the stream's own rate, so consecutive buffers land
        // exactly sample-adjacent (90 kHz can't represent 48 kHz sample
        // boundaries — the rounding error alone is audible as clicks).
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: startSeconds.map {
                CMTime(value: CMTimeValue(($0 * Double(sampleRate)).rounded()), timescale: sampleRate)
            } ?? .invalid,
            decodeTimeStamp: .invalid
        )
        var sampleSize = Int(channels) * MemoryLayout<Float32>.size
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: samples,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }

    // MARK: - Format description

    private static func lpcmFormatDescription(
        sampleRate: Int32,
        channels: Int32,
        layout: AVChannelLayout
    ) -> CMFormatDescription? {
        let bytesPerFrame = UInt32(channels) * UInt32(MemoryLayout<Float32>.size)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var channelLayout = coreAudioLayout(for: layout, channels: channels)
        var description: CMFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: MemoryLayout<AudioChannelLayout>.size,
            layout: &channelLayout,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        return status == noErr ? description : nil
    }

    /// FFmpeg's native channel-bit order and CoreAudio's channel bitmap
    /// agree bit-for-bit on the first 18 positions (FL…TBR), and both
    /// order samples by ascending bit — so a native mask under 1<<18 maps
    /// straight across. Anything else falls back to discrete channels.
    private static func coreAudioLayout(for layout: AVChannelLayout, channels: Int32) -> AudioChannelLayout {
        var result = AudioChannelLayout()
        let mask: UInt64 = layout.order == AV_CHANNEL_ORDER_NATIVE ? layout.u.mask : 0
        if mask != 0, mask < (1 << 18) {
            result.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap
            result.mChannelBitmap = AudioChannelBitmap(rawValue: UInt32(mask))
        } else if channels == 1 {
            result.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        } else if channels == 2 {
            result.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        } else {
            result.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        }
        return result
    }
}
