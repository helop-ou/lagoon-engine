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
        #expect(shown.hiddenUnreferenced == 0, "a picture nothing references is not decoded before the start")

        engine.seek(to: 0.7)
        try await Self.wait { !engine.isBuffering && !shown.visibleEnds.isEmpty }
        #expect(!shown.visibleEnds.isEmpty)
        #expect(shown.visibleEnds.allSatisfy { $0 > 0.7 }, "\(shown.visibleEnds.prefix(3))")
        #expect(shown.hiddenUnreferenced == 0, "a picture nothing references is not decoded before the target")
        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }

    /// The software decoder takes only so many packets at once, and the
    /// pictures it makes on the way to the target are dropped, so nothing
    /// reaches the queue to pull the next packets in. A start or a seek far
    /// from its keyframe never began. `one-keyframe-444.mkv`: testsrc 96x54,
    /// thirty seconds at 24 fps on a single keyframe, H.264 4:4:4, which
    /// every device decodes in software.
    @MainActor
    @Test func aTargetFarFromItsKeyframeStillStarts() async throws {
        let url = try #require(Bundle.module.url(forResource: "SeekLanding/one-keyframe-444.mkv", withExtension: nil))
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        let shown = ShownPictures()
        engine.rendererVideoObserverForTesting = { shown.record($0) }
        engine.prepare(url: url, startSeconds: 4, initialAudioOrdinal: nil)
        engine.pause()
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        try await Self.wait { !engine.isBuffering && !shown.visibleEnds.isEmpty }
        try #require(!engine.isBuffering, "the start never finished priming")
        #expect(shown.visibleEnds.allSatisfy { $0 > 4 }, "\(shown.visibleEnds.prefix(3))")

        engine.seek(to: 20)
        try await Self.wait { !engine.isBuffering && !shown.visibleEnds.isEmpty }
        try #require(!engine.isBuffering, "the seek never finished priming")
        #expect(shown.visibleEnds.allSatisfy { $0 > 20 }, "\(shown.visibleEnds.prefix(3))")
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
    private var unreferenced = 0

    var visibleEnds: [Double] { lock.withLock { ends } }
    /// Hidden pictures that nothing references, which need not reach the
    /// renderer at all.
    var hiddenUnreferenced: Int { lock.withLock { unreferenced } }

    func record(_ buffer: CMSampleBuffer?) {
        guard let buffer else {
            lock.withLock { ends.removeAll(); unreferenced = 0 }
            return
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
        guard attachments?.first?[kCMSampleAttachmentKey_DoNotDisplay] as? Bool != true else {
            let reader = CMSampleBufferGetFormatDescription(buffer).flatMap { UnreferencedPictureReader(formatDescription: $0) }
            if reader?.isUnreferenced(buffer) == true { lock.withLock { unreferenced += 1 } }
            return
        }
        let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(buffer), CMSampleBufferGetDuration(buffer)).seconds
        lock.withLock { ends.append(end) }
    }
}

@Suite("Hidden pictures")
struct HiddenPictureMarkTests {
    /// The compressed path hands pictures before the target to the display
    /// layer, which needs them to decode the rest, marked not to be shown.
    @Test func aMarkedPictureIsNotDisplayed() throws {
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCMVideoCodecType_H264, width: 16, height: 16, extensions: nil,
            formatDescriptionOut: &format
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 24), presentationTimeStamp: .zero, decodeTimeStamp: .invalid
        )
        var buffer: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: try #require(format), sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer
        )
        let sample = try #require(buffer)
        func doNotDisplay() -> Bool? {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            return attachments?.first?[kCMSampleAttachmentKey_DoNotDisplay] as? Bool
        }
        #expect(doNotDisplay() != true)
        SampleBufferFactory.markDoNotDisplay(sample)
        #expect(doNotDisplay() == true)
    }
}
