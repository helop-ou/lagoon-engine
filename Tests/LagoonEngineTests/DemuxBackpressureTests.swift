import Foundation
import Testing
@testable import LagoonEngine

/// How far the demuxer reads ahead, and when it is told to wait. The
/// watermarks differ between a cached stream and an uncached one, because
/// without a byte cache in front of it the only cushion is the one these
/// queues hold.
@Suite("Demux backpressure")
struct DemuxBackpressureTests {
    /// Audio grows and video does not, which is the whole design: a decoded
    /// 4K frame is 24.9 MB and a second of compressed audio is about 80 KB.
    @Test func onlyTheAudioCushionGrowsWithoutACache() {
        #expect(
            DemuxBackpressurePolicy.audioCushionTarget(deliveryIsCached: false)
                > DemuxBackpressurePolicy.audioCushionTarget(deliveryIsCached: true)
        )
        // Video's hard limit is not a function of delivery at all.
        #expect(DemuxBackpressurePolicy.videoHardLimit(videoIsDecoded: true) == 30)
        #expect(DemuxBackpressurePolicy.videoHardLimit(videoIsDecoded: false) == 120)
    }

    /// The cached profile is unchanged, so a direct play behaves exactly as
    /// it did before this existed. Video has to be off the floor first:
    /// the policy never parks on audio while video is the starved one.
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

    /// The same queue depth that parks a cached stream keeps reading on an
    /// uncached one, which is the cushion actually being built.
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

    /// Video may not park on its own high water while audio is short of the
    /// drain it would have to survive, and without a cache that margin is
    /// larger because the drain is a network round trip rather than a cache
    /// read.
    @Test func videoWaitsLongerForAudioWithoutACache() {
        // 18 frames of 24 fps video drains to 12 in 0.25 s; a cached stream
        // needs 1.25 s + that, an uncached one 3 s + that.
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

    /// The absolute bound still holds: a deeper cushion is not an unbounded
    /// one, and video's hard limit is untouched by any of this.
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
        // The decoded queue's own bound hands over to the intake's, which is
        // what still bounds it once that fills too.
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
        // and is stopped by the absolute bound even when video is starved
        // and the loop would otherwise keep reading for it.
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

    /// At the hard limit on every decode path, with audio still short of
    /// its own high water, the loop reads on instead of parking. Once it
    /// does, video parked in the intake does not count against the decoded
    /// queue's own hard limit, so the same shape keeps reading even once
    /// `videoCount` has run past it.
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

    /// A silent title cannot starve on audio, so it never reaches this
    /// branch at all: `audioCanCoverDrain` is vacuously true without audio,
    /// which is the pre-existing one-slot-below-the-high-water pacing.
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

    /// The read-ahead only exists to keep audio from starving, so it stops
    /// the moment audio itself has enough queued: 180 packets is the cached
    /// profile's own high water, and going uncached moves that ceiling to
    /// 360 rather than changing the rule.
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

    /// The intake this rule reads into is bounded on its own, both by count
    /// and by bytes, so a stuck audio track cannot turn it into an unbounded
    /// compressed-packet queue: hitting either cap falls back to the
    /// ordinary hard-limit pacing even while audio is short of its own high
    /// water.
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

    /// Below the hard limit this is all unchanged: over the high water but
    /// short of the hard limit already read on for audio before any of this
    /// existed, because the batch-drain branch above it returns `.read`
    /// directly whenever audio cannot cover the drain and the hard limit has
    /// not been reached.
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
