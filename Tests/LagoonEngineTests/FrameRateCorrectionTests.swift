import Libavutil
import Testing
@testable import LagoonEngine

/// A Matroska header that rounds the frame duration to the millisecond is
/// corrected back to the standard rate the stream's statistics agree with.
struct FrameRateCorrectionTests {
    private let millisecondTimeBase = AVRational(num: 1, den: 1000)
    /// 42 ms: what 23.976 fps is declared as when rounded to the millisecond.
    private let roundedFilmRate = AVRational(num: 500, den: 21)

    private func corrected(
        _ guessed: AVRational,
        timeBase: AVRational? = nil,
        frames: String?,
        duration: String?
    ) -> AVRational {
        FFmpegDemuxer.correctedFrameRate(
            guessed: guessed,
            timeBase: timeBase ?? millisecondTimeBase,
            frameCountTag: frames,
            durationTag: duration
        )
    }

    /// The mkvmerge episode that played at 60 Hz: declared 500/21, stamps
    /// and statistics at 23.976.
    @Test func roundedFilmRateBecomesNTSCFilm() {
        let rate = corrected(roundedFilmRate, frames: "27808", duration: "00:19:19.826000000")
        #expect(rate.num == 24_000 && rate.den == 1001)
    }

    /// 24 and 23.976 both round to 42 ms; the statistics decide.
    @Test func roundedTrueFilmRateBecomesTwentyFour() {
        let rate = corrected(roundedFilmRate, frames: "28800", duration: "00:20:00.000000000")
        #expect(rate.num == 24 && rate.den == 1)
    }

    @Test func roundedVideoRateBecomesNTSCVideo() {
        // 33 ms declared, 29.97 measured.
        let rate = corrected(AVRational(num: 1000, den: 33), frames: "35964", duration: "00:20:00.000000000")
        #expect(rate.num == 30_000 && rate.den == 1001)
    }

    /// Without statistics nothing separates 23.976 from 24, so the header stands.
    @Test func missingStatisticsKeepTheGuess() {
        let rate = corrected(roundedFilmRate, frames: nil, duration: "00:19:19.826000000")
        #expect(rate.num == 500 && rate.den == 21)
        let other = corrected(roundedFilmRate, frames: "27808", duration: nil)
        #expect(other.num == 500 && other.den == 21)
    }

    /// Statistics far from every standard rate (a genuinely odd stream) change nothing.
    @Test func nonstandardMeasuredRateKeepsTheGuess() {
        let rate = corrected(roundedFilmRate, frames: "28572", duration: "00:20:00.000000000")
        #expect(rate.num == 500 && rate.den == 21)
    }

    /// Only a 1 ms time base produces the rounding; other containers are left alone.
    @Test func otherTimeBasesKeepTheGuess() {
        let rate = corrected(
            roundedFilmRate,
            timeBase: AVRational(num: 1, den: 90_000),
            frames: "27808",
            duration: "00:19:19.826000000"
        )
        #expect(rate.num == 500 && rate.den == 21)
    }

    /// A declared rate that is not a whole millisecond is not rounding.
    @Test func exactHeaderIsLeftAlone() {
        let rate = corrected(AVRational(num: 24_000, den: 1001), frames: "27808", duration: "00:19:19.826000000")
        #expect(rate.num == 24_000 && rate.den == 1001)
    }

    @Test func statisticsDurationParses() {
        #expect(FFmpegDemuxer.seconds(statisticsDuration: "00:19:19.826000000") == 1159.826)
        #expect(FFmpegDemuxer.seconds(statisticsDuration: "01:00:00.5") == 3600.5)
        #expect(FFmpegDemuxer.seconds(statisticsDuration: "19:19.826") == nil)
        #expect(FFmpegDemuxer.seconds(statisticsDuration: "garbage") == nil)
    }

    /// Why the correction matters for the grid: 23.976 stamps on a 42 ms
    /// grid drift out of tolerance within a second, and every miss is a
    /// frame the renderer gets off-cadence.
    @Test func roundedGridDropsRealStampsOffTheGrid() throws {
        var timeline = try #require(VideoFrameTimeline(frameRateNum: 500, frameRateDen: 21))
        let period = 1001.0 / 24_000
        var misses = 0
        for index in 0..<240 {
            let containerSeconds = ((Double(index) * period) * 1000).rounded() / 1000
            if timeline.snapped(containerSeconds: containerSeconds) == nil { misses += 1 }
        }
        #expect(misses > 5)
    }
}
