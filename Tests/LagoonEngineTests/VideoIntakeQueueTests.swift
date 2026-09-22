import CoreMedia
import Testing
@testable import LagoonEngine

/// The demuxer parks compressed video read past the decoded-frame limit here,
/// so it can read on to a fragment's audio. FIFO order, count/byte bookkeeping
/// and the peak the HUD and regression probe read are the contract.
struct VideoIntakeQueueTests {
    @Test func popsInAppendOrderThenReportsEmpty() throws {
        let queue = VideoIntakeQueue()
        queue.append(.sample(try #require(makeSampleBuffer(byteCount: 100))))
        queue.append(.sample(try #require(makeSampleBuffer(byteCount: 250))))
        queue.append(.sample(try #require(makeSampleBuffer(byteCount: 400))))

        #expect(queue.popFirst()?.byteCount == 100)
        #expect(queue.popFirst()?.byteCount == 250)
        #expect(queue.popFirst()?.byteCount == 400)
        #expect(queue.popFirst() == nil)
        #expect(queue.isEmpty)
    }

    @Test func countAndByteCountTrackAppendAndPop() throws {
        let queue = VideoIntakeQueue()
        queue.append(.sample(try #require(makeSampleBuffer(byteCount: 100))))
        queue.append(.sample(try #require(makeSampleBuffer(byteCount: 250))))
        #expect(queue.count == 2)
        #expect(queue.byteCount == 350)

        _ = queue.popFirst()
        #expect(queue.count == 1)
        #expect(queue.byteCount == 250)

        _ = queue.popFirst()
        #expect(queue.count == 0)
        #expect(queue.byteCount == 0)
    }

    @Test func peakCountRisesHoldsOnPopAndOnlyResetsWhenAsked() throws {
        let queue = VideoIntakeQueue()
        queue.append(.sample(try #require(makeSampleBuffer(byteCount: 100))))
        queue.append(.sample(try #require(makeSampleBuffer(byteCount: 250))))
        queue.append(.sample(try #require(makeSampleBuffer(byteCount: 400))))
        #expect(queue.peakCount == 3)

        _ = queue.popFirst()
        _ = queue.popFirst()
        #expect(queue.peakCount == 3, "popping must not lower the peak")

        queue.removeAll()
        #expect(queue.peakCount == 3, "a plain removeAll must not erase the peak")

        queue.removeAll(resetPeak: true)
        #expect(queue.peakCount == 0)
    }

    @Test func removeAllEmptiesCountAndBytes() throws {
        let queue = VideoIntakeQueue()
        queue.append(.sample(try #require(makeSampleBuffer(byteCount: 100))))
        queue.append(.sample(try #require(makeSampleBuffer(byteCount: 250))))

        queue.removeAll()

        #expect(queue.count == 0)
        #expect(queue.byteCount == 0)
        #expect(queue.isEmpty)
    }
}

/// A ready compressed H.264 sample buffer with `byteCount` bytes of filler and
/// a valid 16x16 format description.
private func makeSampleBuffer(byteCount: Int) -> CMSampleBuffer? {
    var formatDescription: CMFormatDescription?
    guard CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: kCMVideoCodecType_H264,
        width: 16,
        height: 16,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    ) == noErr else { return nil }

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
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: .zero,
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
