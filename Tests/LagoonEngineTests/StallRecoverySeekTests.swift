import AVFoundation
import Foundation
import Testing
@testable import LagoonEngine

@Suite("Stall recovery and seeks", .serialized)
struct StallRecoverySeekTests {
    /// The stall's poll outlived a seek. It read the seek's own queues:
    /// with a few frames in, it ended buffering and started the clock while
    /// the seek was still priming, or it seeked again and reported a
    /// reprime that never happened.
    @MainActor
    @Test func aSeekEndsTheStallItInterrupts() async throws {
        let url = try #require(Bundle.module.url(forResource: "av", withExtension: "mp4", subdirectory: "SeekLanding"))
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        engine.prepare(url: url, startSeconds: 0, initialAudioOrdinal: nil)
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        engine.play()
        try await Self.wait { !engine.isBuffering && engine.clockPosition > 0.5 }

        engine.beginStallRecoveryForTesting()
        #expect(engine.isBuffering)
        #expect(engine.isRecoveringFromStallForTesting)

        var ended = 0
        engine.onBufferingChanged = { if !$0 { ended += 1 } }
        engine.seek(to: 4)
        #expect(!engine.isRecoveringFromStallForTesting, "the seek owns the restart")

        try await Self.wait { !engine.isBuffering && engine.clockPosition > 4.2 }
        // Long enough for a poll left behind to have acted.
        try await Task.sleep(for: .milliseconds(400))
        #expect(ended == 1, "buffering ended once, with the seek")
        #expect(engine.clockPosition > 4.2)
        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }

    /// Left alone, the recovery still ends by itself.
    @MainActor
    @Test func aStallWithFramesQueuedRecoversOnItsOwn() async throws {
        let url = try #require(Bundle.module.url(forResource: "av", withExtension: "mp4", subdirectory: "SeekLanding"))
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        engine.prepare(url: url, startSeconds: 0, initialAudioOrdinal: nil)
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        engine.play()
        try await Self.wait { !engine.isBuffering && engine.clockPosition > 0.5 }

        engine.beginStallRecoveryForTesting()
        let stalledAt = engine.clockPosition
        try await Self.wait { !engine.isBuffering && engine.clockPosition > stalledAt + 0.3 }
        #expect(!engine.isBuffering)
        #expect(!engine.isRecoveringFromStallForTesting)
        #expect(engine.clockPosition > stalledAt + 0.3)
        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }

    private static func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
