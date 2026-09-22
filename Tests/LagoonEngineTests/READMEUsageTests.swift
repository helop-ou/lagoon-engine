import AVFoundation
import Foundation
import Testing
@testable import LagoonEngine

/// Compiles the usage example from README.md.
///
/// Nothing here runs — there is no media and no display. The point is that
/// the README stops compiling if the API it shows changes, so the first
/// thing a newcomer reads cannot quietly go stale.
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
    }

    @Test func theReadmeExampleStillCompiles() {
        // Referencing it is enough; compiling this file is the assertion.
        #expect(!String(describing: type(of: readmeExample)).isEmpty)
    }
}
