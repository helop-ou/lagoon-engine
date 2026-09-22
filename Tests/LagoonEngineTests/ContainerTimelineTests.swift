import Foundation
import Libavutil
import Testing
@testable import LagoonEngine

@Suite("Container timelines")
struct ContainerTimelineTests {
    @Test func aContainerThatStartsAtZeroIsLeftExactlyAsItWas() {
        // MP4, Matroska, fMP4 remux and transcode: the offset must be zero,
        // leaving their arithmetic untouched.
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
        // Measured on WALL·E's disc: the format reports 4198.333333 s and the
        // first timestamp is 377850000 at 90 kHz. This is subtracted from every
        // packet; without it the film opens at 1:10:00 and every seek lands
        // before the first frame.
        #expect(ContainerTimeline.startOffset(
            startTime: 4_198_333_333,
            timeBase: AVRational(num: 1, den: 90_000)
        ) == 377_850_000)
    }

    @Test func theOffsetIsExpressedInTheStreamsOwnTimeBase() {
        // Streams can count at different rates, so the origin converts per
        // stream.
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
