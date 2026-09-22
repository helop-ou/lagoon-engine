import CoreMedia
import Testing
@testable import LagoonEngine

/// A flushed renderer starts on a random-access point or nothing. Anything else
/// raises `didFailToDecodeNotification`, which the ladder reads as a bitstream
/// verdict and pays for with a transcode. The offending sample may come from a
/// read already in flight at the seek, so the check runs at the pump, on the
/// sample itself.
struct PlaybackRendererStartTests {
    @Test func aStaleSampleIsRefusedAsARenderersFirst() {
        #expect(
            PlaybackRendererStartPolicy.admits(
                isSyncSample: false,
                videoSamplesSinceFlush: 0,
                droppedSinceFlush: 0
            ) == false
        )
    }

    /// Including the open-GOP I picture the demuxer keeps: the container calls
    /// it a keyframe, and its leading pictures are dropped earlier.
    @Test func aKeyframeStartsTheRenderer() {
        #expect(
            PlaybackRendererStartPolicy.admits(
                isSyncSample: true,
                videoSamplesSinceFlush: 0,
                droppedSinceFlush: 0
            )
        )
    }

    /// Only the first sample is checked; after that the P and B pictures are
    /// what the renderer wants, and a per-frame check would be wasted cost.
    @Test func everySampleAfterTheFirstIsAdmittedUnasked() {
        #expect(
            PlaybackRendererStartPolicy.admits(
                isSyncSample: false,
                videoSamplesSinceFlush: 1,
                droppedSinceFlush: 0
            )
        )
    }

    /// A stream that never flags keyframes must not lose its picture; where
    /// this cannot tell, behave as before.
    @Test func theSearchGivesUpRatherThanShowingNothing() {
        let limit = PlaybackRendererStartPolicy.startPointSearchLimit
        #expect(
            PlaybackRendererStartPolicy.admits(
                isSyncSample: false,
                videoSamplesSinceFlush: 0,
                droppedSinceFlush: limit - 1
            ) == false
        )
        #expect(
            PlaybackRendererStartPolicy.admits(
                isSyncSample: false,
                videoSamplesSinceFlush: 0,
                droppedSinceFlush: limit
            )
        )
    }

    // MARK: - What the sample itself says

    @Test func aSampleWithoutAttachmentsReadsAsSync() throws {
        let buffer = try #require(Self.sampleBuffer(notSync: nil))
        #expect(SampleBufferFactory.isSyncSample(buffer))
    }

    @Test func theNotSyncAttachmentIsWhatMakesASampleUnusableAsAStart() throws {
        let buffer = try #require(Self.sampleBuffer(notSync: true))
        #expect(SampleBufferFactory.isSyncSample(buffer) == false)
    }

    /// The factory writes `NotSync` only for non-keyframes, so false or absent
    /// both mean sync.
    @Test func aNotSyncAttachmentSetFalseIsStillAStart() throws {
        let buffer = try #require(Self.sampleBuffer(notSync: false))
        #expect(SampleBufferFactory.isSyncSample(buffer))
    }

    /// `nil` omits the attachment, as on a decoded frame.
    private static func sampleBuffer(notSync: Bool?) -> CMSampleBuffer? {
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
        var sampleSize = byteCount
        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: 1.0 / 24, preferredTimescale: 90_000),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &buffer
        ) == noErr, let buffer else { return nil }
        guard let notSync else { return buffer }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            buffer,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 else { return nil }
        let dictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
            Unmanaged.passUnretained(notSync ? kCFBooleanTrue : kCFBooleanFalse).toOpaque()
        )
        return buffer
    }
}
