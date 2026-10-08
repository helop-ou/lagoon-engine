import AVFoundation
import Foundation
import Testing
@testable import LagoonEngine

/// Renderer configuration, audio renderer replacement and the lifecycle
/// handoff a host waits on between two playbacks. The lifecycle counters are
/// process-wide, so the suite runs serialized.
@Suite("Engine lifecycle and renderers", .serialized)
struct EngineLifecycleAndRendererTests {
    @Test func everyAudioRendererSpatializesStereoTheWayAVPlayerDoes() {
        // `AVSampleBufferAudioRenderer` defaults to `multichannel` only, unlike
        // `AVPlayerItem`. The first check fails if a future SDK changes that.
        #expect(AVSampleBufferAudioRenderer().allowedAudioSpatializationFormats == .multichannel)
        #expect(
            SampleBufferPlayerEngine.makeAudioRenderer().allowedAudioSpatializationFormats
                == .monoStereoAndMultichannel
        )
        #expect(SampleBufferPlayerEngine.makeAudioRenderer().audioTimePitchAlgorithm == .timeDomain)
    }

    @Test func aShutDownEngineCannotBeBroughtBackToLife() async {
        // SwiftUI re-mounts the player surface after a failure and the host
        // attaches unconditionally. A shut-down engine must ignore it, or it
        // registers renderers that never detach and reopens the stream.
        let before = PlaybackLifecycleDiagnostics.snapshot()
        let engine = SampleBufferPlayerEngine()
        engine.prepare(
            url: URL(string: "https://media.test/never-opened.mkv")!,
            startSeconds: 0,
            initialAudioOrdinal: nil
        )
        engine.shutdown()
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())

        // Nothing registered, so nothing waits on an AVFoundation completion.
        let after = PlaybackLifecycleDiagnostics.snapshot()
        #expect(after.attachedRendererSets == before.attachedRendererSets)
        #expect(after.activeDemuxLoops == before.activeDemuxLoops)
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(5)))
    }

    @Test func onlyAMediaServicesResetLeavesThePlayerPaused() {
        // Apple requires waiting for the viewer after a media-services reset.
        // A renderer that failed on its own is replaced and resumes.
        #expect(AudioRendererReplacement.mediaServicesReset.staysPaused)
        #expect(!AudioRendererReplacement.rendererFailed.staysPaused)
    }

    @Test func aFailedAudioRendererReportsItsOwnReasonWhenItCannotBeReplaced() {
        // Reached only when replacement fails, so show AVFoundation's reason.
        #expect(
            AudioRendererReplacement.rendererFailed
                .failureMessage(detail: "The operation could not be completed")
                .contains("The operation could not be completed")
        )
        // No error: no empty parenthetical.
        let bare = AudioRendererReplacement.rendererFailed.failureMessage(detail: nil)
        #expect(!bare.contains("("))
        #expect(AudioRendererReplacement.rendererFailed.failureMessage(detail: "") == bare)
        // A reset states its cause; the renderer's error is noise.
        #expect(
            AudioRendererReplacement.mediaServicesReset.failureMessage(detail: "ignored")
                == "Playback audio could not recover after the media service restarted."
        )
    }

    @Test func episodeHandoffWaitsForTheSpecificOutgoingPipeline() async {
        let outgoing = UUID()
        let unrelated = UUID()
        PlaybackLifecycleDiagnostics.demuxStarted(outgoing)
        PlaybackLifecycleDiagnostics.renderersAttached(outgoing)
        PlaybackLifecycleDiagnostics.demuxStarted(unrelated)
        defer {
            PlaybackLifecycleDiagnostics.demuxEnded(outgoing)
            PlaybackLifecycleDiagnostics.renderersDetached(outgoing)
            PlaybackLifecycleDiagnostics.demuxEnded(unrelated)
        }

        let retirement = Task {
            await PlaybackLifecycleDiagnostics.waitForMediaResourcesToRetire(
                for: outgoing,
                timeout: .seconds(1)
            )
        }
        try? await Task.sleep(for: .milliseconds(100))
        PlaybackLifecycleDiagnostics.demuxEnded(outgoing)
        PlaybackLifecycleDiagnostics.renderersDetached(outgoing)

        #expect(await retirement.value)
        #expect(PlaybackLifecycleDiagnostics.snapshot().activeDemuxLoops >= 1)
    }

    @Test func episodeHandoffRetirementTimeoutCannotBecomeSuccess() async {
        let outgoing = UUID()
        PlaybackLifecycleDiagnostics.renderersAttached(outgoing)
        defer { PlaybackLifecycleDiagnostics.renderersDetached(outgoing) }

        let retired = await PlaybackLifecycleDiagnostics.waitForMediaResourcesToRetire(
            for: outgoing,
            timeout: .milliseconds(20)
        )

        #expect(!retired)
    }
}
