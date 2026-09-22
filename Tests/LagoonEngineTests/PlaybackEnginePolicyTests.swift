import Foundation
import Testing
@testable import LagoonEngine

/// Verdicts the engine reaches alone: whether a decode failure is about the
/// stream or only the restart point, and what a lost VideoToolbox session
/// means. Each allows one recovery per playback generation, so a truly
/// undecodable stream still descends the host's ladder, one seek later.
@Suite("Playback engine policies")
struct PlaybackEnginePolicyTests {
    @Test func aDecodeFailureRightAfterAFlushEarnsOneRetryBeforeTheLadder() {
        // Exit 8's shape: the seek's landing picture, then the open GOP's two
        // leading pictures, and the failure names the second. All inside the
        // window.
        for samples in 0...PlaybackRestartPointPolicy.samplesAfterFlush {
            #expect(
                PlaybackRestartPointPolicy.shouldRetryInPlace(
                    videoSamplesSinceFlush: samples,
                    alreadyRetriedThisGeneration: false
                ),
                "\(samples) samples after a flush is a restart-point failure"
            )
        }
    }

    @Test func aFailureInSteadyPlaybackIsAVerdictOnTheStream() {
        // Minutes into a film nothing is known about the restart point; this is
        // the ladder's case.
        #expect(
            !PlaybackRestartPointPolicy.shouldRetryInPlace(
                videoSamplesSinceFlush: PlaybackRestartPointPolicy.samplesAfterFlush + 1,
                alreadyRetriedThisGeneration: false
            )
        )
        #expect(
            !PlaybackRestartPointPolicy.shouldRetryInPlace(
                videoSamplesSinceFlush: 4_000,
                alreadyRetriedThisGeneration: false
            )
        )
    }

    @Test func theRetryCannotLoop() {
        // A second failure at the same position descends, one seek later.
        #expect(
            !PlaybackRestartPointPolicy.shouldRetryInPlace(
                videoSamplesSinceFlush: 0,
                alreadyRetriedThisGeneration: true
            )
        )
    }

    /// A decoder the system took away is rebuilt, not transcoded: `-12903` only
    /// means "make another session".
    @Test func aLostDecodeSessionIsRebuiltRatherThanDescended() {
        #expect(
            PlaybackDecodeSessionPolicy.resolve(
                cancelled: false,
                videoOutputSuspended: false,
                recoveryInFlight: false,
                playbackGeneration: 7,
                rebuiltGeneration: nil
            ) == .rebuild
        )
        // A generation that spent its rebuild descends, so a session that
        // cannot be made still reaches the ladder.
        #expect(
            PlaybackDecodeSessionPolicy.resolve(
                cancelled: false,
                videoOutputSuspended: false,
                recoveryInFlight: false,
                playbackGeneration: 7,
                rebuiltGeneration: 7
            ) == .descend
        )
        // A later seek is a new generation with its own rebuild.
        #expect(
            PlaybackDecodeSessionPolicy.resolve(
                cancelled: false,
                videoOutputSuspended: false,
                recoveryInFlight: false,
                playbackGeneration: 8,
                rebuiltGeneration: 7
            ) == .rebuild
        )
    }

    @Test func everySampleInADeadDecoderIsTheSameOneFault() {
        // Each buffer in the decoder reports the lost session on its way out;
        // without this each would queue a rebuild seek.
        #expect(
            PlaybackDecodeSessionPolicy.resolve(
                cancelled: false,
                videoOutputSuspended: false,
                recoveryInFlight: true,
                playbackGeneration: 7,
                rebuiltGeneration: nil
            ) == .alreadyRecovering
        )
    }

    @Test func suspendedVideoHasNoSessionWorthSaving() {
        // Backgrounding keeps the old session and the resume seek builds a new
        // one, so a sample reaching a torn-down session says nothing and must
        // not end playback.
        #expect(
            PlaybackDecodeSessionPolicy.resolve(
                cancelled: false,
                videoOutputSuspended: true,
                recoveryInFlight: false,
                playbackGeneration: 7,
                rebuiltGeneration: 7
            ) == .ignore
        )
    }

    /// A rebuild is a seek, which needs a running demux loop. After
    /// cancellation there is none, so asking would swap a reported failure for
    /// a spinner.
    @Test func aFaultAfterPlaybackEndedAsksForNothing() {
        #expect(
            PlaybackDecodeSessionPolicy.resolve(
                cancelled: true,
                videoOutputSuspended: false,
                recoveryInFlight: false,
                playbackGeneration: 7,
                rebuiltGeneration: nil
            ) == .tooLate
        )
        // Cancellation wins: samples draining from a torn-down decoder report
        // the session going with it.
        #expect(
            PlaybackDecodeSessionPolicy.resolve(
                cancelled: true,
                videoOutputSuspended: true,
                recoveryInFlight: true,
                playbackGeneration: 7,
                rebuiltGeneration: 7
            ) == .tooLate
        )
    }

    @Test func demuxErrorsSayWhetherRedeliveryCouldHelp() {
        // Container and transport problems are what a server remux fixes; a
        // codec outside the envelope is not.
        #expect(DemuxError.openFailed("moov atom not found").cause == .delivery)
        #expect(DemuxError.seekFailed("invalid argument").cause == .delivery)
        #expect(DemuxError.unsupportedVideo("av1").cause == .undecodable)
    }

    @Test func aDemuxErrorReportsItsStageAndCodeAndNothingElse() {
        let opened = DemuxError.openFailed("moov atom not found", code: -1094995529).diagnosticDetail
        #expect(opened.stage == .open)
        #expect(opened.code == -1094995529)
        // No libavformat code means none in the report, not a zero a dashboard
        // groups on.
        #expect(DemuxError.seekFailed("demuxer not open").diagnosticDetail.code == nil)
    }
}
