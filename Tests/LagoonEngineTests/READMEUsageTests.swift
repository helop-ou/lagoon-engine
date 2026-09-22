import AVFoundation
import Foundation
import Testing
@testable import LagoonEngine

/// Compiles the usage example from README.md. Nothing runs; the README stops
/// compiling if the API it shows changes.
struct READMEUsageTests {
    @MainActor
    private func readmeExample(url: URL, serverURL: URL, token: String) {
        let engine = SampleBufferPlayerEngine()

        let displayLayer = AVSampleBufferDisplayLayer()
        engine.attach(displayLayer: displayLayer)

        engine.onPlaybackStarted = { }
        engine.onError = { failure in
            _ = (failure.cause, failure.message)
        }

        engine.prepare(
            url: url,
            startSeconds: 0,
            initialAudioOrdinal: nil
        )
        engine.play()

        // The rest of what the README names.
        engine.pause()
        engine.seek(to: 10)
        engine.setRate(1.5)
        engine.selectAudioTrack(id: nil)
        engine.selectSubtitleTrack(id: nil)
        _ = engine.audioTracks
        _ = engine.subtitleTracks
        engine.shutdown()

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
    }

    @Test func theReadmeExampleStillCompiles() {
        // Referencing it is enough; compiling this file is the assertion.
        #expect(!String(describing: type(of: readmeExample)).isEmpty)
    }
}
