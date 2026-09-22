import CoreMedia
import Testing
@testable import LagoonEngine

/// Priming after a seek lands inside a fragment whose audio block
/// starts at the keyframe, so audio queued from before the seek target is
/// audio the renderer will discard, not a cushion. `bufferedDuration(after:)`
/// is what tells the demux loop and `primeAndStart` how much of the queue
/// actually lands after that target, as opposed to plain `bufferedDuration`,
/// which counts everything queued regardless of where playback is headed.
struct SampleBufferQueueTests {
    @Test func bufferedDurationAfterIgnoresAudioBeforeTheTarget() throws {
        let queue = SampleBufferQueue()
        for pts in [0.0, 1.0, 2.0] {
            queue.enqueue(try #require(makeTimedSampleBuffer(
                presentationSeconds: pts,
                durationSeconds: 1.0
            )))
        }
        // Three 1 s buffers back to back: PTS 0, 1, 2, ending at 3.0.

        // Before the first buffer even starts, the whole 3 s counts.
        #expect(abs(queue.bufferedDuration(after: 0) - 3.0) < 0.001)
        // Straddling the second buffer: only the second half of it plus
        // the third buffer count — 1.5 s, not the 3 s still queued.
        #expect(queue.bufferedDuration(after: 1.5) == 1.5)
        // Exactly at the end: nothing queued lands after it.
        #expect(queue.bufferedDuration(after: 3.0) == 0)
        // Past the end entirely: still nothing.
        #expect(queue.bufferedDuration(after: 5.0) == 0)
        // At or before the first buffer's own PTS, the target cannot pull
        // anything backward, so this matches plain bufferedDuration exactly.
        #expect(queue.bufferedDuration(after: -1) == queue.bufferedDuration)
    }
}

/// A ready sample buffer stamped at `presentationSeconds` with a
/// `durationSeconds`-long duration, on a timescale fine enough to hold both
/// exactly — cribbed from `VideoIntakeQueueTests`' `makeSampleBuffer`, which
/// only needed a fixed zero PTS and had no reason to vary it.
private func makeTimedSampleBuffer(
    presentationSeconds: Double,
    durationSeconds: Double
) -> CMSampleBuffer? {
    var formatDescription: CMFormatDescription?
    guard CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: kCMVideoCodecType_H264,
        width: 16,
        height: 16,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    ) == noErr else { return nil }

    let byteCount = 16
    var blockBuffer: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: byteCount,
        flags: 0,
        blockBufferOut: &blockBuffer
    ) == noErr, let blockBuffer else { return nil }

    let filler = [UInt8](repeating: 0, count: byteCount)
    let filled = filler.withUnsafeBytes { bytes -> OSStatus in
        guard let baseAddress = bytes.baseAddress else { return OSStatus(kCMBlockBufferBadPointerParameterErr) }
        return CMBlockBufferReplaceDataBytes(
            with: baseAddress,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
    }
    guard filled == noErr else { return nil }

    var sampleSize = byteCount
    var timing = CMSampleTimingInfo(
        duration: CMTime(seconds: durationSeconds, preferredTimescale: 90_000),
        presentationTimeStamp: CMTime(seconds: presentationSeconds, preferredTimescale: 90_000),
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: 1,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer
    ) == noErr else { return nil }
    return sampleBuffer
}
