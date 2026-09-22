import Foundation
import Testing
@testable import LagoonEngine

/// How far the demuxer reads ahead and when it waits. Without a byte cache the
/// queues are the only cushion, so uncached watermarks are deeper.
@Suite("Demux backpressure")
struct DemuxBackpressureTests {
    /// Only audio grows: a decoded 4K frame is 24.9 MB, a second of compressed
    /// audio about 80 KB.
    @Test func onlyTheAudioCushionGrowsWithoutACache() {
        #expect(
            DemuxBackpressurePolicy.audioCushionTarget(deliveryIsCached: false)
                > DemuxBackpressurePolicy.audioCushionTarget(deliveryIsCached: true)
        )
        // Video's hard limit is not a function of delivery at all.
        #expect(DemuxBackpressurePolicy.videoHardLimit(videoIsDecoded: true) == 30)
        #expect(DemuxBackpressurePolicy.videoHardLimit(videoIsDecoded: false) == 120)
    }

    /// Cached watermarks are unchanged. Video must be off the floor first: the
    /// policy never parks on audio while video starves.
    @Test func aCachedStreamKeepsTheWatermarksItAlwaysHad() {
        #expect(DemuxBackpressurePolicy.audioCushionTarget(deliveryIsCached: true) == 180)
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 12,
            audioCount: 180,
            audioBufferedSeconds: 6,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true
        ) == .waitForAudio(below: 144))
    }

    /// The depth that parks a cached stream keeps an uncached one reading.
    @Test func anUncachedStreamKeepsReadingWhereACachedOneParks() {
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 12,
            audioCount: 180,
            audioBufferedSeconds: 6,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            deliveryIsCached: false
        ) == .read)
    }

    /// Video may not park at high water while audio is short of the drain it
    /// must survive. Uncached, that margin is larger because the drain is a
    /// network round trip.
    @Test func videoWaitsLongerForAudioWithoutACache() {
        // 18 frames of 24 fps video drain to 12 in 0.25 s; cached needs 1.25 s
        // more, uncached 3 s more.
        let betweenTheTwo = 2.0
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 18,
            audioCount: 40,
            audioBufferedSeconds: betweenTheTwo,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true
        ) == .waitForVideo(below: 12))
        // The same state, uncached, keeps reading to build audio instead.
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 18,
            audioCount: 40,
            audioBufferedSeconds: betweenTheTwo,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            deliveryIsCached: false
        ) == .read)
    }

    /// A deeper cushion is still bounded, and video's hard limit is unchanged.
    @Test func theHardLimitsStillBound() {
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 40,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            deliveryIsCached: false
        ) == .read)
        // The decoded queue's bound hands over to the intake's, which still
        // bounds it.
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 40,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            deliveryIsCached: false,
            videoIntakeCount: DemuxBackpressurePolicy.videoIntakeHardLimit
        ) == .waitForVideo(below: 30))
        // Audio parks at its own high water once video is off the floor,
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 12,
            audioCount: 360,
            audioBufferedSeconds: 12,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            deliveryIsCached: false
        ) == .waitForAudio(below: 288))
        // and is stopped by the absolute bound even when video is starved.
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 0,
            audioCount: 540,
            audioBufferedSeconds: 20,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            deliveryIsCached: false
        ) == .waitForAudio(below: 540))
    }

    /// At the hard limit on every decode path, with audio short of high water,
    /// the loop reads on. Video parked in the intake does not count against the
    /// decoded queue's limit, so it keeps reading even past `videoCount`.
    @Test func fullDecodedQueueReadsAheadForAudio() {
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true
        ) == .read)
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 120,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: false,
            hasAudio: true
        ) == .read)
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 42,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true,
            hasAudio: true
        ) == .read)
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 45,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true
        ) == .read)
    }

    /// Without audio `audioCanCoverDrain` is vacuously true, so the usual one
    /// slot below high water pacing applies.
    @Test func silentTitleKeepsOneSlotPacing() {
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: false
        ) == .waitForVideo(below: 12))
    }

    /// The read-ahead stops once audio has enough: 180 packets cached, 360
    /// uncached.
    @Test func audioHighWaterStopsTheReadAhead() {
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 180,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true
        ) == .waitForVideo(below: 30))
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 180,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            deliveryIsCached: false
        ) == .read)
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 360,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            deliveryIsCached: false
        ) == .waitForVideo(below: 30))
    }

    /// The intake is bounded by count and bytes, so a stuck audio track cannot
    /// grow it without limit: either cap falls back to hard-limit pacing.
    @Test func intakeBoundsStopTheReadAhead() {
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            videoIntakeCount: DemuxBackpressurePolicy.videoIntakeHardLimit
        ) == .waitForVideo(below: 30))
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            videoIntakeCount: 10,
            videoIntakeBytes: DemuxBackpressurePolicy.videoIntakeByteBudget
        ) == .waitForVideo(below: 30))
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            videoIntakeCount: DemuxBackpressurePolicy.videoIntakeHardLimit - 1,
            videoIntakeBytes: DemuxBackpressurePolicy.videoIntakeByteBudget - 1
        ) == .read)
    }

    /// Between high water and the hard limit, the batch-drain branch already
    /// reads on whenever audio cannot cover the drain.
    @Test func belowTheHardLimitNothingChanged() {
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 20,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true
        ) == .read)
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 10,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true
        ) == .read)
    }
}
