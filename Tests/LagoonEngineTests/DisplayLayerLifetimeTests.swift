import AVFoundation
import Foundation
import QuartzCore
import Testing
@testable import LagoonEngine

@Suite("Display layer lifetime", .serialized)
struct DisplayLayerLifetimeTests {
    /// A layer nothing else held deallocated mid-playback, inside a Core
    /// Animation commit that held the video queue's layer lock. Its dealloc
    /// waited for the renderer's queue while the pump, on that queue, waited
    /// for the lock: the title never started.
    @MainActor
    @Test func theEngineKeepsItsLayerUntilTheRenderersAreGone() async throws {
        let url = try #require(Bundle.module.url(forResource: "av", withExtension: "mp4", subdirectory: "SeekLanding"))
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        weak var layer: AVSampleBufferDisplayLayer?
        engine.prepare(url: url, startSeconds: 0, initialAudioOrdinal: nil)
        autoreleasepool {
            let attached = AVSampleBufferDisplayLayer()
            layer = attached
            engine.attach(displayLayer: attached)
        }
        engine.play()
        try await Self.wait { !engine.isBuffering && engine.clockPosition > 0.5 }
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(200))
        #expect(layer != nil, "the layer outlives the caller's reference while the title plays")

        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
        try await Self.wait { layer == nil }
        #expect(layer == nil, "and is let go once the renderers are")
    }

    private static func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
