import Foundation
import Libavutil
import Testing
@testable import LagoonEngine

@Suite("Container timelines")
struct ContainerTimelineTests {
    @Test func aContainerThatStartsAtZeroIsLeftExactlyAsItWas() {
        // Every source the engine had before disc images: MP4, Matroska, and
        // Jellyfin's fMP4 remux and transcode. The offset has to be zero for
        // these, so their arithmetic is untouched.
        #expect(ContainerTimeline.startOffset(
            startTime: 0,
            timeBase: AVRational(num: 1, den: 90_000)
        ) == 0)
        // AV_NOPTS_VALUE, for a container that does not say.
        #expect(ContainerTimeline.startOffset(
            startTime: Int64.min,
            timeBase: AVRational(num: 1, den: 90_000)
        ) == 0)
        // Nonsense time bases cannot produce a nonsense offset.
        #expect(ContainerTimeline.startOffset(
            startTime: 4_198_333_333,
            timeBase: AVRational(num: 0, den: 0)
        ) == 0)
        #expect(ContainerTimeline.startOffset(
            startTime: -1,
            timeBase: AVRational(num: 1, den: 90_000)
        ) == 0)
    }

    @Test func aBlurayStartsSeventyMinutesIntoItsOwnClock() {
        // WALL·E's disc, measured: the format reports 4198.333333 s and the
        // streams' first timestamp is 377850000 at 90 kHz. Reproducing that
        // number exactly is the whole job, because it is what gets subtracted
        // from every packet: without it the film opens reading 1:10:00 and
        // every seek lands 70 minutes before the first frame, which the
        // demuxer clamps to the start.
        #expect(ContainerTimeline.startOffset(
            startTime: 4_198_333_333,
            timeBase: AVRational(num: 1, den: 90_000)
        ) == 377_850_000)
    }

    @Test func theOffsetIsExpressedInTheStreamsOwnTimeBase() {
        // Streams in one container can count at different rates, so the
        // format's origin has to be converted per stream rather than shared.
        let startTime: Int64 = 4_198_333_333
        #expect(ContainerTimeline.startOffset(
            startTime: startTime,
            timeBase: AVRational(num: 1, den: 1_000)
        ) == 4_198_333)
        #expect(ContainerTimeline.startOffset(
            startTime: startTime,
            timeBase: AVRational(num: 1, den: 48_000)
        ) == 201_520_000)
        // A non-unit numerator is a rate too, not a special case.
        #expect(ContainerTimeline.startOffset(
            startTime: 2_000_000,
            timeBase: AVRational(num: 2, den: 90_000)
        ) == 90_000)
    }
}
