import CoreMedia
import Testing
@testable import LagoonEngine

/// A renderer that has just been flushed starts on a random-access point or
/// on nothing: hand it anything else and it answers
/// `didFailToDecodeNotification`, which the delivery ladder reads as a
/// verdict on the bitstream and pays for with a server-side transcode.
///
/// The sample that reaches it that way need not be the seek's landing. It
/// can be the packet a read already in flight returned, delivered into the
/// emptied queue before the demux loop noticed the seek. So the question is
/// asked at the pump, of the sample itself.
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

    /// Including the open-GOP I picture the demuxer deliberately keeps: the
    /// container calls it a keyframe, and the leading pictures that would
    /// have broken it are dropped before they get here.
    @Test func aKeyframeStartsTheRenderer() {
        #expect(
            PlaybackRendererStartPolicy.admits(
                isSyncSample: true,
                videoSamplesSinceFlush: 0,
                droppedSinceFlush: 0
            )
        )
    }

    /// Only the first sample is asked about. Once the renderer has started,
    /// the P and B pictures behind the keyframe are exactly what it wants,
    /// and stopping to inspect every one of them would be a per-frame cost
    /// for a question that has already been answered.
    @Test func everySampleAfterTheFirstIsAdmittedUnasked() {
        #expect(
            PlaybackRendererStartPolicy.admits(
                isSyncSample: false,
                videoSamplesSinceFlush: 1,
                droppedSinceFlush: 0
            )
        )
    }

    /// A stream whose keyframes are never flagged must not lose its picture
    /// altogether — the same escape the demuxer's keyframe search keeps.
    /// Behaving exactly as it did before is the right answer where this
    /// cannot tell.
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

    /// The factory writes `NotSync` only for a non-keyframe, so a keyframe
    /// carries the attachment set false or not at all. Both are sync.
    @Test func aNotSyncAttachmentSetFalseIsStillAStart() throws {
        let buffer = try #require(Self.sampleBuffer(notSync: false))
        #expect(SampleBufferFactory.isSyncSample(buffer))
    }

    /// `nil` leaves the attachment off entirely, which is what a decoded
    /// frame arrives with.
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
