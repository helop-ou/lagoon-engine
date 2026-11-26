import AVFoundation
import Foundation
import Testing
@testable import LagoonEngine

@Suite("Seek pickup")
struct SeekPickupTests {
    /// The renderers' flushes come after the queues are empty, so a demux loop
    /// waiting for room starts its seek during them, not after. Audio is held
    /// back from its renderer, so its queue is full when the seek arrives.
    /// `pickup.mp4`: 8 s of testsrc2 160x90 H.264 (`-g 24`) and AAC.
    @MainActor
    @Test func theQueuesAreEmptyBeforeTheRenderersFlush() async throws {
        let url = try #require(Bundle.module.url(forResource: "SeekLanding/pickup.mp4", withExtension: nil))
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        let flushes = QueuedAtFlush()
        engine.prepare(url: url, startSeconds: 0, initialAudioOrdinal: nil)
        engine.pause()
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        try await waitUntil { !engine.isBuffering }
        engine.simulateAudioStarvationForDiagnostics(durationSeconds: 60)
        try await waitUntil { engine.queuedSamplesForTesting.audio > 0 }
        #expect(engine.queuedSamplesForTesting.audio > 0, "the queues must hold something for the order to matter")

        engine.rendererVideoObserverForTesting = { @Sendable [engine] buffer in
            if buffer == nil { flushes.record(engine.queuedSamplesForTesting) }
        }
        engine.seek(to: 5)
        try await waitUntil { !flushes.all.isEmpty }
        #expect(!flushes.all.isEmpty)
        for queued in flushes.all {
            #expect(queued.intake == 0 && queued.video == 0 && queued.audio == 0, "\(queued)")
        }
        await engine.shutdownAndRetire()
    }

    /// What is parked when a seek is requested is from before it.
    @Test func parkedVideoWaitsWhileASeekIsPending() {
        #expect(!SampleBufferPlayerEngine.drainsVideoIntake(backlog: 0, hardLimit: 30, seekPending: true))
        #expect(SampleBufferPlayerEngine.drainsVideoIntake(backlog: 0, hardLimit: 30, seekPending: false))
        #expect(!SampleBufferPlayerEngine.drainsVideoIntake(backlog: 30, hardLimit: 30, seekPending: false))
    }
}

/// The engine's queue depths at each video renderer flush.
private final class QueuedAtFlush: @unchecked Sendable {
    private let lock = NSLock()
    private var depths: [(intake: Int, video: Int, audio: Int)] = []

    var all: [(intake: Int, video: Int, audio: Int)] { lock.withLock { depths } }

    func record(_ queued: (intake: Int, video: Int, audio: Int)) {
        lock.withLock { depths.append(queued) }
    }
}
