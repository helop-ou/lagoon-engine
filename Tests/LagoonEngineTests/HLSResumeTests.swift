import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import LagoonEngine

/// A resumed HLS open starts at the segment holding the resume point. The
/// fixture is shaped like a Jellyfin remux: 90 s of H.264 and AAC in 6 s
/// MPEG-TS segments whose clock starts 11.4 s in, with audio slightly ahead of
/// video.
@Suite("HLS resume segment", .serialized)
struct HLSResumeTests {
    static let playlist = Bundle.module.url(
        forResource: "playlist",
        withExtension: "m3u8",
        subdirectory: "HLSResume"
    )

    @Test func anOpenWithoutAStartBeginsAtTheFirstSegment() throws {
        let demuxer = try Self.open(startSeconds: 0)
        defer { demuxer.close() }
        let first = try #require(Self.firstVideoSeconds(demuxer))
        #expect(first < 0.1, "first video at \(first) s")
    }

    @Test func aResumeOpensAtItsSegmentOnThePlaylistsClock() throws {
        // 20 s lies in the fourth segment, which starts at 18 s. Its packets
        // come first, still on the clock a first-segment open would have used.
        let demuxer = try Self.open(startSeconds: 20)
        defer { demuxer.close() }
        let first = try #require(Self.firstVideoSeconds(demuxer))
        #expect(first > 17.9 && first < 18.2, "first video at \(first) s")
        #expect(abs(demuxer.durationSeconds - 90) < 0.1)
    }

    @Test func aSeekAfterAResumeLandsWhereItWouldAfterAFirstSegmentOpen() throws {
        // Backwards past the resume segment, more than 60 s back where
        // libavformat would take a timestamp for a wrap, and forwards. The
        // resumed origin comes from segment durations, so it may differ by an
        // audio frame.
        let resumed = try Self.open(startSeconds: 80)
        let fromStart = try Self.open(startSeconds: 0)
        defer {
            resumed.close()
            fromStart.close()
        }
        for target in [5.0, 50.5, 86.0] {
            try resumed.seek(toSeconds: target)
            try fromStart.seek(toSeconds: target)
            let landing = try #require(Self.firstVideoSeconds(resumed))
            let expected = try #require(Self.firstVideoSeconds(fromStart))
            #expect(abs(landing - expected) < 0.1, "seek to \(target) s landed at \(landing) s, not \(expected) s")
        }
    }

    private static func open(startSeconds: Double) throws -> FFmpegDemuxer {
        let playlist = try #require(Self.playlist)
        let demuxer = FFmpegDemuxer()
        demuxer.startSeconds = startSeconds
        try demuxer.open(
            url: playlist.path(percentEncoded: false),
            recommendedPixelBufferAttributes: CVPixelBufferAttributes()
        )
        return demuxer
    }

    private static func firstVideoSeconds(_ demuxer: FFmpegDemuxer) -> Double? {
        for _ in 0..<500 {
            switch demuxer.readNext() {
            case .video(let buffer):
                return buffer.presentationTimeStamp.seconds
            case .failed, .endOfFile:
                return nil
            default:
                continue
            }
        }
        return nil
    }
}
