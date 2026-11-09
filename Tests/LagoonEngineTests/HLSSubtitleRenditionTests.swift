import AVFoundation
import CoreVideo
import Darwin
import Foundation
import os
import Testing
@testable import LagoonEngine

/// libavformat fetches an HLS subtitle rendition inside the audio and video
/// read, one segment at a time, so a subtitle segment the server is slow to
/// produce holds back the picture and the sound. Here every rendition segment
/// is a FIFO: opening one blocks until someone writes, like a server that
/// never answers. Audio and video must still reach the end.
@Suite("HLS subtitle renditions", .serialized)
struct HLSSubtitleRenditionTests {
    @Test func aMasterWithSubtitleRenditionsPlaysToTheEndWithoutFetchingThem() throws {
        let fixture = try RenditionFixture()
        defer { fixture.remove() }
        let demuxer = try Self.open(fixture.master.path(percentEncoded: false))
        defer { demuxer.close() }

        let tally = fixture.readAll(demuxer)

        #expect(!tally.timedOut, "a subtitle rendition was fetched inside the audio and video read")
        #expect(tally.ending == "eof")
        #expect(tally.video > 0)
        #expect(tally.audio > 0)
        #expect(tally.subtitleEvents == 0)
    }

    @Test func renditionsAreListedButNeverRead() throws {
        // Listed so per-type ordinals still match the host's stream list.
        let fixture = try RenditionFixture()
        defer { fixture.remove() }
        let demuxer = try Self.open(fixture.master.path(percentEncoded: false))
        defer { demuxer.close() }

        #expect(demuxer.subtitleStreams.map(\.language) == ["en", "fr"])
        #expect(demuxer.textSubtitleStreamIndices.isEmpty)
        #expect(demuxer.unreadSubtitleStreamIndices == Set(demuxer.subtitleStreams.map(\.streamIndex)))
    }

    @Test func choosingARenditionStillLeavesItUnread() throws {
        let fixture = try RenditionFixture()
        defer { fixture.remove() }
        let demuxer = try Self.open(fixture.master.path(percentEncoded: false))
        defer { demuxer.close() }
        let english = try #require(demuxer.subtitleStreams.first)

        demuxer.selectSubtitle(streamIndex: english.streamIndex)
        let tally = fixture.readAll(demuxer)

        #expect(!tally.timedOut, "a chosen subtitle rendition was fetched inside the audio and video read")
        #expect(tally.ending == "eof")
        #expect(tally.subtitleEvents == 0)
    }

    @MainActor
    @Test func playbackStartsAndChoosingARenditionNeitherBlocksNorSeeks() async throws {
        let fixture = try RenditionFixture()
        defer { fixture.remove() }
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        var started = false
        var failure: String?
        engine.onPlaybackStarted = { started = true }
        engine.onError = { failure = $0.message }
        engine.prepare(url: fixture.master, startSeconds: 0, initialAudioOrdinal: nil)
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        engine.play()

        // Generous: other suites' main-actor tests run while this one waits,
        // and a regression blocks the read for good, not for a while.
        let deadline = ContinuousClock.now + .seconds(60)
        while !started, failure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(started, "playback waited on a subtitle rendition")
        #expect(failure == nil)
        #expect(engine.subtitleTracks.count == 2)

        // A seek starts buffering at once, on the main actor.
        engine.selectSubtitleTrack(id: 1)
        #expect(!engine.isBuffering, "choosing a rendition flushed and re-demuxed")
        #expect(engine.subtitleTracks.first?.isSelected == true)

        engine.shutdown()
        let retired = await fixture.feedingBlockedReaders {
            await engine.waitForMediaResourcesToRetire(timeout: .seconds(10))
        }
        #expect(retired)
    }

    @Test func aDirectPlayedFilesUnselectedTextTracksAreStillRead() throws {
        // The subtitle backlog depends on this: both tracks are read with
        // neither chosen.
        let url = try #require(Bundle.module.url(
            forResource: "two-subrip",
            withExtension: "mkv",
            subdirectory: "TextSubtitles"
        ))
        let demuxer = try Self.open(url.path(percentEncoded: false))
        defer { demuxer.close() }
        #expect(demuxer.subtitleStreams.count == 2)
        #expect(demuxer.textSubtitleStreamIndices == Set(demuxer.subtitleStreams.map(\.streamIndex)))
        #expect(demuxer.unreadSubtitleStreamIndices.isEmpty)

        var linesByStream: [Int32: Int] = [:]
        reading: for _ in 0..<1_000 {
            switch demuxer.readNext() {
            case .subtitle(let events, let streamIndex):
                linesByStream[streamIndex, default: 0] += events.filter {
                    if case .cue = $0 { true } else { false }
                }.count
            case .endOfFile:
                break reading
            case .failed(let message):
                Issue.record("read failed: \(message)")
                break reading
            default:
                continue
            }
        }
        #expect(linesByStream.count == 2)
        #expect(linesByStream.values.allSatisfy { $0 == 2 })
    }

    private static func open(_ path: String) throws -> FFmpegDemuxer {
        let demuxer = FFmpegDemuxer()
        try demuxer.open(url: path, recommendedPixelBufferAttributes: CVPixelBufferAttributes())
        return demuxer
    }
}

private struct Tally: Sendable {
    var video = 0
    var audio = 0
    var subtitleEvents = 0
    var ending = "none"
    var timedOut = false
}

/// A master playlist with two WebVTT renditions whose segments are FIFOs.
/// The media is shaped like a Jellyfin remux of a 50 fps title: one fragment
/// per 10 s segment, all 500 video samples ahead of the audio, so what
/// libavformat buffers while probing holds no audio and starting must read on.
private struct RenditionFixture: Sendable {
    let directory: URL
    let master: URL
    private let fifos: [String]

    init() throws {
        let media = try #require(Bundle.module.url(
            forResource: "playlist",
            withExtension: "m3u8",
            subdirectory: "HLSVideoFirst"
        ))
        directory = FileManager.default.temporaryDirectory
            .appending(path: "hls-renditions-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var fifos: [String] = []
        for language in ["en", "fr"] {
            var playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n#EXT-X-PLAYLIST-TYPE:VOD\n"
            for segment in 0..<2 {
                let name = "\(language)\(segment).vtt"
                let path = directory.appending(path: name).path(percentEncoded: false)
                guard mkfifo(path, 0o600) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                fifos.append(path)
                playlist += "#EXTINF:10.000000,\n\(name)\n"
            }
            playlist += "#EXT-X-ENDLIST\n"
            try playlist.write(to: directory.appending(path: "\(language).m3u8"), atomically: true, encoding: .utf8)
        }
        let masterText = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="en.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="French",LANGUAGE="fr",DEFAULT=NO,AUTOSELECT=YES,URI="fr.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=100000,SUBTITLES="subs"
        \(media.path(percentEncoded: false))

        """
        master = directory.appending(path: "master.m3u8")
        try masterText.write(to: master, atomically: true, encoding: .utf8)
        self.fifos = fifos
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Reads to the end on another thread. Past the deadline the reader is
    /// blocked on a FIFO: feed every FIFO an empty WebVTT file until it
    /// finishes, and report the timeout.
    func readAll(_ demuxer: FFmpegDemuxer, deadline: TimeInterval = 10) -> Tally {
        nonisolated(unsafe) let demuxer = demuxer
        let result = OSAllocatedUnfairLock(initialState: Tally())
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var tally = Tally()
            reading: for _ in 0..<20_000 {
                switch demuxer.readNext() {
                case .video, .videoPacket:
                    tally.video += 1
                case .audio(let buffers, _):
                    tally.audio += buffers.count
                case .subtitle(let events, _):
                    tally.subtitleEvents += events.count
                case .skipped:
                    continue
                case .endOfFile:
                    tally.ending = "eof"
                    break reading
                case .failed(let message):
                    tally.ending = "failed: \(message)"
                    break reading
                }
            }
            result.withLock { $0 = tally }
            finished.signal()
        }
        guard finished.wait(timeout: .now() + deadline) == .timedOut else {
            return result.withLock { $0 }
        }
        while finished.wait(timeout: .now() + 0.01) == .timedOut {
            feedBlockedReaders()
        }
        var tally = result.withLock { $0 }
        tally.timedOut = true
        return tally
    }

    /// Runs `body` while answering any reader blocked on a FIFO, so a
    /// regression fails its expectations instead of hanging teardown.
    func feedingBlockedReaders<Result: Sendable>(_ body: @escaping @Sendable () async -> Result) async -> Result {
        let feeding = Task.detached { [self] in
            while !Task.isCancelled {
                feedBlockedReaders()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { feeding.cancel() }
        return await body()
    }

    private func feedBlockedReaders() {
        for path in fifos {
            // Succeeds only while a reader waits on this FIFO.
            let descriptor = Darwin.open(path, O_WRONLY | O_NONBLOCK)
            guard descriptor >= 0 else { continue }
            _ = "WEBVTT\n\n".withCString { Darwin.write(descriptor, $0, 8) }
            Darwin.close(descriptor)
        }
    }
}
