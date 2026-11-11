import AVFoundation
import Foundation
import Testing
@testable import LagoonEngine

@Suite("Seek landing")
struct SeekLandingTests {
    /// A start or seek lands on the keyframe before its target. Pictures that
    /// end before the target reach the renderer late, and it would race
    /// through them, so each is dropped or marked not to be displayed.
    /// H.264 here, VP9 on the software decoder: three seconds at 24 fps with
    /// a keyframe each second (`vp9.mkv`: testsrc2 160x90, libvpx-vp9 -g 24).
    @MainActor
    @Test(arguments: ["PresentationOrder/normal.mp4", "SeekLanding/vp9.mkv"])
    func picturesBeforeTheTargetAreNeverShown(_ fixture: String) async throws {
        let url = try #require(Bundle.module.url(forResource: fixture, withExtension: nil))
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        let shown = ShownPictures()
        engine.rendererVideoObserverForTesting = { shown.record($0) }
        engine.prepare(url: url, startSeconds: 1.8, initialAudioOrdinal: nil)
        engine.pause()
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        try await Self.wait { !engine.isBuffering && !shown.visibleEnds.isEmpty }
        #expect(shown.visibleEnds.allSatisfy { $0 > 1.8 }, "\(shown.visibleEnds.prefix(3))")

        engine.seek(to: 0.7)
        try await Self.wait { !engine.isBuffering && !shown.visibleEnds.isEmpty }
        #expect(!shown.visibleEnds.isEmpty)
        #expect(shown.visibleEnds.allSatisfy { $0 > 0.7 }, "\(shown.visibleEnds.prefix(3))")
        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }

    private static func wait(until condition: () -> Bool) async throws {
        // Generous: other suites' main-actor tests run while this one waits.
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Presentation ends of the pictures the renderer may show, since its last
/// flush.
private final class ShownPictures: @unchecked Sendable {
    private let lock = NSLock()
    private var ends: [Double] = []

    var visibleEnds: [Double] { lock.withLock { ends } }

    func record(_ buffer: CMSampleBuffer?) {
        guard let buffer else {
            lock.withLock { ends.removeAll() }
            return
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
        guard attachments?.first?[kCMSampleAttachmentKey_DoNotDisplay] as? Bool != true else { return }
        let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(buffer), CMSampleBufferGetDuration(buffer)).seconds
        lock.withLock { ends.append(end) }
    }
}
