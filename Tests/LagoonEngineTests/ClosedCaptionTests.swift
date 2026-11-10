import AVFoundation
import CoreVideo
import Foundation
import Libavutil
import Testing
@testable import LagoonEngine

/// `cc.ts` and `cc.mkv`: two seconds of 160x90 H.264 at 25 fps from x264
/// (`aud=1:bframes=0:keyint=25`), with an A/53 SEI on every picture before
/// its first slice. CC1 loads "HELLO" pop-on from frame 2, shows it at frame
/// 10 (0.4 s) and erases it at frame 30 (1.2 s); every other pair is null.
/// FFmpeg's own `subcc` reads the same 0.400 to 1.200.
@Suite("Closed captions")
struct ClosedCaptionTests {
    @Test(arguments: ["cc.ts", "cc.mkv"])
    func captionsInTheVideoBecomeATextTrack(_ name: String) throws {
        let parts = name.split(separator: ".")
        let url = try #require(Bundle.module.url(
            forResource: String(parts[0]), withExtension: String(parts[1]), subdirectory: "ClosedCaptions"
        ))
        let demuxer = FFmpegDemuxer()
        defer { demuxer.close() }
        try demuxer.open(url: url.path(percentEncoded: false), recommendedPixelBufferAttributes: CVPixelBufferAttributes())

        var cues: [SubtitleCue] = []
        reading: for _ in 0..<1_000 {
            switch demuxer.readNext() {
            case .subtitle(let events, let streamIndex) where streamIndex == ClosedCaptionTrack.streamIndex:
                for event in events {
                    switch event {
                    case .cue(let cue): cues.append(cue)
                    case .clear: break
                    case .styledChunk: break
                    }
                }
            case .endOfFile, .failed:
                break reading
            default:
                continue
            }
        }
        let cue = try #require(cues.first)
        #expect(cues.count == 1)
        #expect(cue.text == "HELLO")
        #expect(abs(cue.start - 0.4) < 0.001)
        #expect(abs(cue.end - 1.2) < 0.001, "erased at frame 30, not after one picture")
    }

    /// Listed once found, after every other track, and shown when chosen.
    @MainActor
    @Test func theEngineListsCaptionsLastAndShowsThem() async throws {
        let url = try #require(Bundle.module.url(forResource: "cc", withExtension: "mkv", subdirectory: "ClosedCaptions"))
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        var failure: String?
        engine.onError = { failure = $0.message }
        engine.prepare(url: url, startSeconds: 0, initialAudioOrdinal: nil)
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        engine.addExternalSubtitle(ExternalSubtitleTrack(
            url: URL(string: "https://example.invalid/subtitle.srt")!,
            preloadedData: Data("1\n00:00:05,000 --> 00:00:06,000\nSidecar\n".utf8),
            title: "Sidecar",
            language: "eng",
            select: false,
            isDownloaded: true
        ))

        // Generous: other suites' main-actor tests run while this one waits.
        let deadline = ContinuousClock.now + .seconds(30)
        let captionsID = SampleBufferPlayerEngine.closedCaptionTrackID
        engine.play()
        while !engine.subtitleTracks.contains(where: { $0.engineID == captionsID }), failure == nil,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(failure == nil)
        let captions = try #require(engine.subtitleTracks.last)
        #expect(captions.engineID == captionsID)
        #expect(captions.isHearingImpaired)
        #expect(engine.subtitleTracks.first?.displayName == "Sidecar", "the sidecar keeps its ordinal")
        #expect(engine.subtitleTracks.first?.engineID == 1)

        engine.addExternalSubtitle(ExternalSubtitleTrack(
            url: URL(string: "https://example.invalid/later.srt")!,
            preloadedData: Data("1\n00:00:05,000 --> 00:00:06,000\nLater\n".utf8),
            title: "Later",
            language: "eng",
            select: false,
            isDownloaded: true
        ))
        #expect(engine.subtitleTracks.map(\.engineID) == [1, 2, captionsID], "captions stay last")

        engine.selectSubtitleTrack(id: captionsID)
        #expect(engine.subtitleTracks.last?.isSelected == true)
        engine.seek(to: 0.6)
        while engine.currentSubtitleText != "HELLO", failure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(engine.currentSubtitleText == "HELLO")
        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }

    // MARK: - Reading the bytes

    /// HELLO, pop-on, one pair per picture, then shown: what `cc.ts` carries.
    private static let pairs: [(UInt8, UInt8)] = [
        (0x94, 0x20), (0x94, 0x20), (0x94, 0x70), (0x94, 0x70),
        (0xC8, 0x45), (0x4C, 0x4C), (0x4F, 0x80), (0x94, 0x2F),
    ]

    @Test func captionsHeldInDecodeOrderAreReadInPresentationOrder() throws {
        let track = try #require(ClosedCaptionTrack(timeBase: AVRational(num: 1, den: 25), depth: 3))
        // B-frame order: each anchor ahead of the two pictures before it.
        let decodeOrder = [0, 3, 1, 2, 6, 4, 5, 7]
        var events: [SubtitleEvent] = []
        for picture in decodeOrder {
            let (a, b) = Self.pairs[picture]
            events += track.add(Data([0xFC, a, b]), pts: Int64(picture))
        }
        events += track.add(Data([0xFC, 0x94, 0x2C]), pts: 30)
        events += track.drain()
        let text = events.compactMap { if case .cue(let cue) = $0 { cue.text } else { nil } }
        #expect(text == ["HELLO"])
    }

    @Test func hevcCaptionsComeFromAPrefixSEI() {
        let sei = Data([0x4E, 0x01]) + Self.seiBody(Self.ccData([0xFC, 0x94, 0x2F]))
        let slice = Data([0x26, 0x01, 0xAF, 0x00])
        let payload = Self.lengthPrefixed([sei, slice])
        let captions = payload.withUnsafeBytes {
            ClosedCaptionExtractor.captions(in: $0, codec: .hevc, nalLengthSize: 4)
        }
        #expect(captions == Data([0xFC, 0x94, 0x2F]))
    }

    @Test func mpeg2CaptionsComeFromPictureUserData() {
        let payload = Data([0, 0, 1, 0x00, 0x11, 0x22]) // picture header
            + Data([0, 0, 1, 0xB2]) + Self.ccData([0xFC, 0x94, 0x2F])
            + Data([0, 0, 1, 0x01, 0xAA]) // first slice
        let captions = payload.withUnsafeBytes {
            ClosedCaptionExtractor.captions(in: $0, codec: .mpeg2, nalLengthSize: nil)
        }
        #expect(captions == Data([0xFC, 0x94, 0x2F]))
    }

    @Test func otherRegisteredUserDataIsIgnored() {
        // Same country and provider, and bytes that would read as one caption
        // pair, under another identifier than GA94.
        let other = Data([0x44, 0x54, 0x47, 0x31, 0x03, 0x41, 0xFF, 0xFC, 0x94, 0x20, 0xFF])
        let afd = Data([0x06]) + Self.seiBody(other)
        let captions = Data([0x06]) + Self.seiBody(Self.ccData([0xFC, 0x94, 0x2F]))
        let payload = Self.lengthPrefixed([afd, captions, Data([0x65, 0x88])])
        let found = payload.withUnsafeBytes {
            ClosedCaptionExtractor.captions(in: $0, codec: .h264, nalLengthSize: 4)
        }
        #expect(found == Data([0xFC, 0x94, 0x2F]))
    }

    @Test func emulationPreventionBytesAreTakenOut() {
        let unit = Data([0x06, 0x00, 0x00, 0x03, 0x01, 0x00, 0x00, 0x03, 0x03, 0x80])
        let rbsp = unit.withUnsafeBytes { ClosedCaptionExtractor.rbsp($0, dropping: 1) }
        #expect(rbsp == Data([0x00, 0x00, 0x01, 0x00, 0x00, 0x03, 0x80]))
    }

    /// GA94 user data with `cc_data` for the given triplets.
    private static func ccData(_ triplets: [UInt8]) -> Data {
        Data([0x47, 0x41, 0x39, 0x34, 0x03, 0x40 | UInt8(triplets.count / 3), 0xFF]) + Data(triplets) + Data([0xFF])
    }

    /// One registered user-data SEI message around `userData`, with trailing bits.
    private static func seiBody(_ userData: Data) -> Data {
        let message = Data([0xB5, 0x00, 0x31]) + userData
        return Data([0x04, UInt8(message.count)]) + message + Data([0x80])
    }

    private static func lengthPrefixed(_ units: [Data]) -> Data {
        var packet = Data()
        for unit in units {
            withUnsafeBytes(of: UInt32(unit.count).bigEndian) { packet.append(contentsOf: $0) }
            packet.append(unit)
        }
        return packet
    }
}
