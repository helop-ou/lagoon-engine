import AVFoundation
import Foundation
import Testing
@testable import LagoonEngine

/// Runs the usage example from README.md and compiles the calls the usage
/// guide names, so neither can drift from the API.
@Suite("README usage", .serialized)
struct READMEUsageTests {
    /// The README's quick start, in its order, against a real file.
    @MainActor
    @Test func theReadmeExamplePlays() async throws {
        let url = try Self.fixture()
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        var started = false
        var failure: PlaybackEngineFailure?

        let engine = SampleBufferPlayerEngine()

        let displayLayer = AVSampleBufferDisplayLayer()

        engine.onPlaybackStarted = { started = true }
        engine.onError = { failure = $0 }

        engine.prepare(
            url: url,
            startSeconds: 0,
            initialAudioOrdinal: nil
        )
        engine.attach(displayLayer: displayLayer)
        engine.play()

        try await Self.wait { started || failure != nil }
        #expect(started, "the documented quick start reaches its first frame")
        #expect(failure == nil)
        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }

    /// A view often has its layer before it knows what to play. That order
    /// used to open nothing and report nothing.
    @MainActor
    @Test func aLayerAttachedBeforePreparePlaysToo() async throws {
        let url = try Self.fixture()
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        var started = false
        let engine = SampleBufferPlayerEngine()
        engine.onPlaybackStarted = { started = true }

        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        engine.prepare(url: url, startSeconds: 0, initialAudioOrdinal: nil)
        engine.play()

        try await Self.wait { started }
        #expect(started)
        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }

    /// The calls docs/usage.md names. Never run: compiling is the assertion.
    @MainActor
    private func usageGuideExamples(url: URL, serverURL: URL, token: String) async {
        let engine = SampleBufferPlayerEngine()

        // Transport and tracks.
        engine.pause()
        engine.seek(to: 10)
        engine.setRate(1.5)
        engine.selectAudioTrack(id: nil)
        engine.selectSubtitleTrack(id: nil)
        _ = engine.audioTracks
        let captions = engine.subtitleTracks.first { $0.engineID == PlayerTrack.closedCaptionsEngineID }
        engine.selectSubtitleTrack(id: captions?.engineID)
        engine.onTrackSelectionChanged = { }
        engine.onFinished = { }
        engine.onSeekReady = { }
        engine.onBufferingChanged = { _ in }
        engine.onTimeAdvanced = { _, _ in }

        // A credential.
        engine.prepare(
            url: url,
            startSeconds: 0,
            initialAudioOrdinal: nil,
            authorization: MediaRequestAuthorization(
                origin: serverURL,
                headerName: "Authorization",
                headerValue: token
            )
        )

        // Buffering ahead.
        engine.prepare(
            url: url,
            itemID: "episode-412",
            delivery: .stableFile,
            expectedLength: 1_024,
            startSeconds: 0,
            initialAudioOrdinal: nil
        )
        _ = (engine.bufferState.bufferedFraction, engine.bufferState.bufferedRanges)
        engine.suspendBufferFill()
        engine.resumeBufferFill()
        engine.stageSuccessor(
            itemID: "episode-413",
            url: url,
            delivery: .stableFile,
            warms: true
        )

        // Failures.
        engine.onError = { failure in
            switch failure.transport {
            case .httpStatus(let status): _ = status
            case .urlError(let code): _ = code
            case nil: break
            }
            switch failure.cause {
            case .undecodable, .delivery: break
            }
        }

        // The start.
        _ = engine.startupPhase == .connecting
        engine.startGate = { try? await Task.sleep(for: .seconds(1)) }
        if let request = engine.displayMatchRequest {
            _ = (request.formatDescription, request.frameRate)
        }

        // Sound and subtitles.
        engine.setAudioShaping(AudioShaping(nightMode: true, dialogueBoost: false, channelLimit: .stereo))
        engine.setAudioShaping(.off)
        engine.setAudioDelay(0.1)
        engine.setSubtitleOffset(-0.5)
        _ = (engine.audioShaping.isActive, engine.subtitleOffset)
        engine.setPictureInPictureSubtitles(.standard)
        engine.setPictureInPictureSubtitles(nil)
        _ = BurnedInSubtitleStyle(relativeSize: 0.055, fontName: nil)
        _ = (engine.currentSubtitleCues, engine.currentSubtitleImages, engine.subtitleLoadState)
        engine.retrySubtitleLoad()
        engine.addExternalSubtitle(ExternalSubtitleTrack(url: url, title: nil, language: nil, select: true))
        _ = (PlaybackRatePolicy.supported, engine.videoOutputPathDiagnostic)
        _ = EngineTuning().deinterlacesAtFrameRate

        // The system.
        engine.setHostInBackground(true)
        engine.setVideoOutputSuspended(true)
        engine.recoverAfterMediaServicesReset()
        let capabilities = PlaybackCapabilities.current
        _ = (capabilities.hardwareHEVC, capabilities.hardwareAV1, capabilities.hardwareVP9)

        // Diagnostics.
        EngineDiagnostics.use(DiscardedDiagnostics())
        let event = EngineDiagnosticEvent(rawValue: "playbackStartup")
        switch event {
        case .playbackStartup, .playbackSlowStart: break
        default: break
        }
        _ = EngineVersion.current

        // The end.
        engine.shutdown()
        _ = await engine.waitForMediaResourcesToRetire(timeout: .seconds(15))
    }

    @Test func theUsageGuideExamplesStillCompile() {
        #expect(!String(describing: type(of: usageGuideExamples)).isEmpty)
    }

    private static func fixture() throws -> URL {
        try #require(Bundle.module.url(forResource: "av", withExtension: "mp4", subdirectory: "SeekLanding"))
    }

    private static func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
