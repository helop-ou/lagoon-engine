import Foundation
import Testing
@testable import LagoonEngine

/// Empty audio must count as starvation, or a film plays silent while every
/// indicator reads healthy. Pure policy: no engine, renderer or clock.
@Suite("Playback starvation and stall recovery")
struct PlaybackStarvationPolicyTests {
    private func healthy(
        _ mutate: (inout PlaybackStarvationPolicy.Snapshot) -> Void = { _ in }
    ) -> PlaybackStarvationPolicy.Snapshot {
        var snapshot = PlaybackStarvationPolicy.Snapshot()
        snapshot.position = 100
        snapshot.duration = 6_000
        snapshot.rate = 1
        snapshot.videoQueueCount = 30
        snapshot.videoBufferedTo = 130
        snapshot.hasAudio = true
        snapshot.audioDeliveryLeadSeconds = 2
        mutate(&snapshot)
        return snapshot
    }

    @Test func healthyPlaybackIsNotStarved() {
        #expect(PlaybackStarvationPolicy.starvation(healthy()) == .none)
    }

    /// Video is full but the renderer has consumed every audio sample. Queue
    /// depth plays no part.
    @Test func exhaustedRendererAudioLeadIsStarvationEvenWithVideoFull() {
        let snapshot = healthy {
            $0.videoQueueCount = 30
            $0.audioDeliveryLeadSeconds = 0
        }
        #expect(PlaybackStarvationPolicy.starvation(snapshot) == .audio)
    }

    /// Lead is measured at the renderer; the engine's own queue is ignored.
    @Test func audioIsJudgedOnRendererDeliveryLead() {
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.audioDeliveryLeadSeconds = PlaybackStarvationPolicy.audioFloorSeconds + 0.01
        }) == .none)
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.audioDeliveryLeadSeconds = PlaybackStarvationPolicy.audioFloorSeconds - 0.01
        }) == .audio)
    }

    @Test func audioCannotBeCalledStarvedBeforeTheRendererReceivesItsFirstSample() {
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.audioDeliveryLeadSeconds = nil
        }) == .none)
    }

    /// Both dry reports video: it is the half the viewer can see freeze,
    /// and the recovery wanted is the same either way.
    @Test func videoWinsWhenBothAreDry() {
        let snapshot = healthy {
            $0.videoQueueCount = 0
            $0.videoBufferedTo = $0.position
            $0.audioDeliveryLeadSeconds = 0
        }
        #expect(PlaybackStarvationPolicy.starvation(snapshot) == .video)
    }

    /// A silent film cannot starve for sound, and must not be held in
    /// buffering waiting for a cushion that will never arrive.
    @Test func aTitleWithoutAudioNeverStarvesOnIt() {
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.hasAudio = false
            $0.audioDeliveryLeadSeconds = 0
        }) == .none)
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.audioQueueFinished = true
            $0.audioDeliveryLeadSeconds = 0
        }) == .none)
    }

    /// The margin is media time, so it has to scale with rate to keep the
    /// same wall-clock cushion.
    @Test func theAudioFloorScalesWithPlaybackRate() {
        let justOverAt1x = PlaybackStarvationPolicy.audioFloorSeconds + 0.01
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.audioDeliveryLeadSeconds = justOverAt1x
        }) == .none)
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.rate = 2
            $0.audioDeliveryLeadSeconds = justOverAt1x
        }) == .audio)
    }

    @Test func statesThatCannotStarve() {
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.isPaused = true
            $0.audioDeliveryLeadSeconds = 0
        }) == .none)
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.isBuffering = true
            $0.audioDeliveryLeadSeconds = 0
        }) == .none)
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.didFinish = true
            $0.audioDeliveryLeadSeconds = 0
        }) == .none)
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.position = $0.duration - 0.5
            $0.audioDeliveryLeadSeconds = 0
        }) == .none)
    }

    // MARK: - Audio-gated recovery (off by default)

    @Test func confirmsGatesAudioOnTheModeAndAlwaysConfirmsVideo() {
        #expect(StallRecoveryPolicy.confirms(.video, buffersOnAudioStarvation: false))
        #expect(StallRecoveryPolicy.confirms(.video, buffersOnAudioStarvation: true))
        #expect(!StallRecoveryPolicy.confirms(.audio, buffersOnAudioStarvation: false))
        #expect(StallRecoveryPolicy.confirms(.audio, buffersOnAudioStarvation: true))
        #expect(!StallRecoveryPolicy.confirms(.none, buffersOnAudioStarvation: false))
        #expect(!StallRecoveryPolicy.confirms(.none, buffersOnAudioStarvation: true))
    }

    /// With `audioRequired` true, resume needs the renderer's own lead back
    /// as well as the video cushion; either missing waits, and a wait long
    /// enough still falls back to reprime.
    @Test func audioRequiredResumeNeedsBothQueuesReady() {
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false,
            audioRequired: true,
            audioDeliveryLeadSeconds: 1.0
        ) == .resume)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false,
            audioRequired: true,
            audioDeliveryLeadSeconds: 0.5
        ) == .wait)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false,
            audioRequired: true,
            audioDeliveryLeadSeconds: nil
        ) == .wait)
        #expect(StallRecoveryPolicy.decision(
            elapsed: StallRecoveryPolicy.reprimeAfter,
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false,
            audioRequired: true,
            audioDeliveryLeadSeconds: 0.5
        ) == .reprime)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount - 1,
            videoQueueFinished: false,
            audioRequired: true,
            audioDeliveryLeadSeconds: 3.0
        ) == .wait)
    }

    /// The renderer's own readiness flag lets a resume through once the
    /// lead clears `resumeAudioLeadFloorSeconds`, without waiting for the
    /// full-second fallback; without the flag, only the full second does.
    @Test func rendererReadinessFlagResumesAboveTheFloor() {
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false,
            audioRequired: true,
            audioDeliveryLeadSeconds: 0.6,
            audioRendererHasSufficientData: true
        ) == .resume)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false,
            audioRequired: true,
            audioDeliveryLeadSeconds: 0.2,
            audioRendererHasSufficientData: true
        ) == .wait)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false,
            audioRequired: true,
            audioDeliveryLeadSeconds: 0.6,
            audioRendererHasSufficientData: false
        ) == .wait)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false,
            audioRequired: true,
            audioDeliveryLeadSeconds: 1.0,
            audioRendererHasSufficientData: false
        ) == .resume)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false,
            audioRequired: true,
            audioDeliveryLeadSeconds: nil,
            audioRendererHasSufficientData: true
        ) == .wait)
        let requiredAtDoubleRate = Int(ceil(Double(StallRecoveryPolicy.resumeVideoCount) * 2))
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: requiredAtDoubleRate,
            videoQueueFinished: false,
            playbackRate: 2,
            audioRequired: true,
            audioDeliveryLeadSeconds: 0.9,
            audioRendererHasSufficientData: true
        ) == .wait)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: requiredAtDoubleRate,
            videoQueueFinished: false,
            playbackRate: 2,
            audioRequired: true,
            audioDeliveryLeadSeconds: 1.0,
            audioRendererHasSufficientData: true
        ) == .resume)
    }

    /// The mode-off contract: with `audioRequired` false, a dry renderer
    /// never blocks a video-ready resume.
    @Test func audioNotRequiredResumesOnVideoAloneWithNoLead() {
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false,
            audioRequired: false,
            audioDeliveryLeadSeconds: 0
        ) == .resume)
    }

    /// The audio lead floor scales with rate exactly as the video cushion
    /// does.
    @Test func audioLeadFloorScalesWithPlaybackRate() {
        let requiredAtDoubleRate = StallRecoveryPolicy.resumeVideoCount * 2
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: requiredAtDoubleRate,
            videoQueueFinished: false,
            playbackRate: 2,
            audioRequired: true,
            audioDeliveryLeadSeconds: 1.5
        ) == .wait)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: requiredAtDoubleRate,
            videoQueueFinished: false,
            playbackRate: 2,
            audioRequired: true,
            audioDeliveryLeadSeconds: 2.0
        ) == .resume)
    }

    // MARK: - Stall recovery

    @Test func stallRecoveryResumesOnlyWithACushionAndCannotWaitForever() {
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount - 1,
            videoQueueFinished: false
        ) == .wait)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false
        ) == .resume)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: 0,
            videoQueueFinished: true
        ) == .resume)
        #expect(StallRecoveryPolicy.decision(
            elapsed: StallRecoveryPolicy.reprimeAfter,
            videoQueueCount: 0,
            videoQueueFinished: false
        ) == .reprime)
    }

    @Test func stallRecoveryKeepsItsWallClockCushionAtFasterRates() {
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: 12,
            videoQueueFinished: false,
            playbackRate: 1.5
        ) == .wait)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: 18,
            videoQueueFinished: false,
            playbackRate: 1.5
        ) == .resume)
    }
}
