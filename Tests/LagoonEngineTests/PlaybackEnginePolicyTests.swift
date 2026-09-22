import Foundation
import Testing
@testable import LagoonEngine

/// The verdicts the engine reaches on its own: whether a decode failure is
/// about the stream or only about the point playback restarted from, and
/// what a lost VideoToolbox session means. Both are bounded to one recovery
/// per playback generation, so a stream that really cannot be decoded still
/// descends a host's delivery ladder — one seek later.
@Suite("Playback engine policies")
struct PlaybackEnginePolicyTests {
    @Test func aDecodeFailureRightAfterAFlushEarnsOneRetryBeforeTheLadder() {
        // Exit 8's shape: the picture the seek landed on, then the open
        // GOP's two leading pictures, and the failure names the second of
        // those. Every one of those is inside the window.
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
        // Minutes into a film the decoder has proved nothing about the
        // restart point; this is the ladder's own case and must stay it.
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
        // The second failure at the same position descends the ladder,
        // exactly as every failure did before — one seek later.
        #expect(
            !PlaybackRestartPointPolicy.shouldRetryInPlace(
                videoSamplesSinceFlush: 0,
                alreadyRetriedThisGeneration: true
            )
        )
    }

    /// A decoder the system took away is rebuilt rather than transcoded.
    /// `LAGOON-A` and `LAGOON-G` both spent the one-way rung on a
    /// `-12903` that only ever meant "make another session".
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
        // A generation that already spent its rebuild descends, so a session
        // that genuinely cannot be made still reaches the ladder.
        #expect(
            PlaybackDecodeSessionPolicy.resolve(
                cancelled: false,
                videoOutputSuspended: false,
                recoveryInFlight: false,
                playbackGeneration: 7,
                rebuiltGeneration: 7
            ) == .descend
        )
        // A later seek earns a rebuild of its own: the generation moved on.
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
        // Each buffer inside the decoder reports the lost session on its way
        // out. Without this they would queue a rebuild seek apiece.
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
        // Backgrounding leaves the old session alive on purpose and the
        // resume seek builds a fresh one, so a sample that reached
        // a torn-down session says nothing — and must not end the film. This
        // is `LAGOON-G`: a fallback to transcode with the app in the
        // background, which could not have completed anyway.
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

    /// A rebuild is a seek, and a seek needs a demux loop still running to
    /// apply it. Once playback has been cancelled there is none, so asking
    /// for one would replace a reported failure with a spinner.
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
        // Cancellation outranks the rest: the samples draining out of a
        // decoder being torn down report the session going with it.
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
        // Container and transport problems are exactly what a server-side
        // remux fixes; a codec outside the envelope is not.
        #expect(DemuxError.openFailed("moov atom not found").cause == .delivery)
        #expect(DemuxError.seekFailed("invalid argument").cause == .delivery)
        #expect(DemuxError.unsupportedVideo("av1").cause == .undecodable)
    }

    @Test func aDemuxErrorReportsItsStageAndCodeAndNothingElse() {
        let opened = DemuxError.openFailed("moov atom not found", code: -1094995529).diagnosticDetail
        #expect(opened.stage == .open)
        #expect(opened.code == -1094995529)
        // No code from libavformat means no code in the report, rather than
        // a zero a dashboard would group on.
        #expect(DemuxError.seekFailed("demuxer not open").diagnosticDetail.code == nil)
    }
}
