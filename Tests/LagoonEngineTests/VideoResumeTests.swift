import AVFoundation
import Foundation
import Testing
@testable import LagoonEngine

@Suite("Video resume", .serialized)
struct VideoResumeTests {
    /// Unlocking an iPhone resumed video with a seek: the audio renderer was
    /// flushed, a second of silence on the speaker, and over AirPlay the
    /// refilled renderer stalled. Only the picture restarts now.
    @MainActor
    @Test func resumingVideoLeavesTheAudioAndTheClockAlone() async throws {
        let (engine, audio, pictures) = try await Self.playingFixture()
        var bufferingChanges = 0
        engine.onBufferingChanged = { _ in bufferingChanges += 1 }
        engine.setVideoOutputSuspended(true)
        // Past a keyframe and more than the resume's lead before the next,
        // so the landing keyframe is behind the clock and the decoder has
        // pictures to skip.
        try await Self.wait {
            let clock = engine.clockPosition
            return clock > 2.5 && (0.1..<0.4).contains(clock.truncatingRemainder(dividingBy: 1))
        }

        let resumedAt = engine.clockPosition
        pictures.forget()
        engine.setVideoOutputSuspended(false)
        var clocks: [Double] = []
        try await Self.wait {
            clocks.append(engine.clockPosition)
            return !pictures.visibleStarts.isEmpty
        }
        try await Task.sleep(for: .milliseconds(300))
        clocks.append(engine.clockPosition)

        #expect(!pictures.visibleStarts.isEmpty, "the picture came back")
        #expect(pictures.visibleStarts.allSatisfy { $0 >= resumedAt }, "\(pictures.visibleStarts.prefix(3)) before \(resumedAt)")
        #expect(bufferingChanges == 0, "a resume does not buffer")
        #expect(zip(clocks, clocks.dropFirst()).allSatisfy { $0 <= $1 }, "the clock never went back")
        #expect((clocks.last ?? 0) > (clocks.first ?? 0) + 0.2, "the clock kept running")
        #expect(audio.overlaps.isEmpty, "audio was queued once: \(audio.overlaps.prefix(3))")
        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }

    /// A seek asked for in the same turn as a resume restarts both from the
    /// target, with nothing of the resume's chase or floors left over.
    @MainActor
    @Test func aSeekDuringAResumeWins() async throws {
        let (engine, audio, pictures) = try await Self.playingFixture()
        engine.setVideoOutputSuspended(true)
        try await Self.wait { engine.clockPosition > 2.5 }

        engine.setVideoOutputSuspended(false)
        engine.seek(to: 1)
        try await Self.wait { !engine.isBuffering && !pictures.visibleStarts.isEmpty && engine.clockPosition > 1.3 }

        // A keyframe, so the target's own picture is the first.
        let first = try #require(pictures.visibleStarts.min())
        #expect(first >= 1 - 0.001 && first < 1 + 0.05, "the first picture after the seek starts at \(first)")
        let afterSeek = audio.startsAfterLastJumpBack
        #expect((afterSeek.min() ?? .infinity) < 1 + 0.05, "audio restarts at the target: \(afterSeek.prefix(3))")
        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }

    @Test func audioReadAgainIsDroppedOrCutAtTheFloor() throws {
        // 1024 frames at 48 kHz from 1 s: ends at 1.021333 s.
        let pcm = try Self.lpcm(start: 1, frames: 1_024)
        #expect(AudioReplayTrim.remainder(of: pcm, after: -.infinity) === pcm)
        #expect(AudioReplayTrim.remainder(of: pcm, after: 0.99) === pcm)
        #expect(AudioReplayTrim.remainder(of: pcm, after: 1.0214) == nil)
        let tail = try #require(AudioReplayTrim.remainder(of: pcm, after: 1.01))
        #expect(CMSampleBufferGetNumSamples(tail) == 1_024 - 480)
        #expect(abs(CMSampleBufferGetPresentationTimeStamp(tail).seconds - 1.01) < 0.000_1)
        // Within the tolerance of a re-anchored stamp, the buffer is whole.
        #expect(AudioReplayTrim.remainder(of: pcm, after: 1.001) === pcm)

        // A compressed packet stays only if most of it is new.
        let packet = try Self.lpcm(start: 1, frames: 1, frameDuration: CMTime(value: 32, timescale: 1_000))
        #expect(AudioReplayTrim.remainder(of: packet, after: 1.01) === packet)
        #expect(AudioReplayTrim.remainder(of: packet, after: 1.02) == nil)
    }

    /// Subtitles read again after a resume are already in the store.
    @Test func subtitlesReadAgainAreDropped() {
        let early = SubtitleCue(start: 4, end: 6, textCues: [], images: [])
        let late = SubtitleCue(start: 9, end: 10, textCues: [], images: [])
        let events: [SubtitleEvent] = [
            .cue(early),
            .clear(at: 7),
            .styledChunk(StyledSubtitleChunk(data: Data(), startMilliseconds: 7_500, durationMilliseconds: 100)),
            .cue(late),
        ]
        #expect(SubtitleReplay.unread(events, after: nil).count == 4)
        #expect(SubtitleReplay.unread(events, after: 7).map(SubtitleReplay.time(of:)) == [7.5, 9])
        #expect(SubtitleReplay.unread(events, after: 9).isEmpty)
    }

    /// Ten seconds of H.264 and AAC, a keyframe a second (`av.mp4`: testsrc2
    /// 160x90 at 12 fps, -g 12 -bf 0, a 440 Hz sine), playing past 1 s.
    @MainActor
    private static func playingFixture() async throws -> (SampleBufferPlayerEngine, AudioLog, PictureLog) {
        let url = try #require(Bundle.module.url(forResource: "av", withExtension: "mp4", subdirectory: "SeekLanding"))
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        let audio = AudioLog()
        let pictures = PictureLog()
        engine.queuedAudioObserverForTesting = { audio.record($0) }
        engine.rendererVideoObserverForTesting = { pictures.record($0) }
        engine.prepare(url: url, startSeconds: 0, initialAudioOrdinal: nil)
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        engine.play()
        try await wait { !engine.isBuffering && engine.clockPosition > 1 }
        return (engine, audio, pictures)
    }

    private static func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func lpcm(
        start: Double,
        frames: Int,
        frameDuration: CMTime = CMTime(value: 1, timescale: 48_000)
    ) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format
        )
        let length = frames * 8
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        var timing = CMSampleTimingInfo(
            duration: frameDuration,
            presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 48_000),
            decodeTimeStamp: .invalid
        )
        var size = 8
        var buffer: CMSampleBuffer?
        CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: try #require(block), formatDescription: try #require(format),
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer
        )
        return try #require(buffer)
    }
}

/// Audio queued for the renderer, in order.
private final class AudioLog: @unchecked Sendable {
    private let lock = NSLock()
    private var spans: [(start: Double, end: Double)] = []

    func record(_ buffer: CMSampleBuffer) {
        let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        let end = start + CMSampleBufferGetDuration(buffer).seconds
        lock.withLock { spans.append((start, end)) }
    }

    /// Buffers that start before the one before them ended.
    var overlaps: [Double] {
        lock.withLock {
            zip(spans, spans.dropFirst()).compactMap { $1.start < $0.end - 0.003 ? $1.start : nil }
        }
    }

    /// Starts from the last time audio went back by more than a second, as
    /// a seek back does.
    var startsAfterLastJumpBack: [Double] {
        lock.withLock {
            let starts = spans.map(\.start)
            guard let jump = starts.indices.dropFirst().last(where: { starts[$0] < starts[$0 - 1] - 1 }) else { return [] }
            return Array(starts[jump...])
        }
    }
}

/// Starts of the pictures the renderer may show since its last flush, or
/// since `forget()`.
private final class PictureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [Double] = []

    var visibleStarts: [Double] { lock.withLock { starts } }

    func forget() { lock.withLock { starts.removeAll() } }

    func record(_ buffer: CMSampleBuffer?) {
        guard let buffer else {
            forget()
            return
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
        guard attachments?.first?[kCMSampleAttachmentKey_DoNotDisplay] as? Bool != true else { return }
        let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        lock.withLock { starts.append(start) }
    }
}
