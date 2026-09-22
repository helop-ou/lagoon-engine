import CoreMedia
import Testing
@testable import LagoonEngine

/// After a seek, audio queued before the target is discarded by the renderer,
/// so it is not a cushion. `bufferedDuration(after:)` counts only what lands
/// after the target; plain `bufferedDuration` counts everything.
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
        // Straddling the second buffer: its second half plus the third, 1.5 s.
        #expect(queue.bufferedDuration(after: 1.5) == 1.5)
        // Exactly at the end: nothing queued lands after it.
        #expect(queue.bufferedDuration(after: 3.0) == 0)
        // Past the end entirely: still nothing.
        #expect(queue.bufferedDuration(after: 5.0) == 0)
        // At or before the first PTS this matches plain bufferedDuration.
        #expect(queue.bufferedDuration(after: -1) == queue.bufferedDuration)
    }
}

/// A ready sample buffer at `presentationSeconds` lasting `durationSeconds`, on
/// a timescale that holds both exactly.
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
