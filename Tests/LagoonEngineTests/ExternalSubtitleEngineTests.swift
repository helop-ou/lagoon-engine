import Foundation
import Testing
@testable import LagoonEngine

/// External subtitles through the engine: what is committed, selected and
/// shown while a download is in flight, replaced or cancelled.
extension ScriptedDownloadTests {
    @Suite("External subtitles on the engine")
    struct ExternalSubtitleEngineTests {
        @Test func downloadedSubtitleIsInsertedAndSelectedAtRuntime() async throws {
            let engine = SampleBufferPlayerEngine()
            defer { engine.shutdown() }
            engine.addExternalSubtitle(ExternalSubtitleTrack(
                url: URL(string: "https://example.invalid/subtitle.vtt")!,
                preloadedData: Data("WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nHello\n".utf8),
                title: "English SDH",
                language: "eng",
                select: true,
                isHearingImpaired: true,
                isDownloaded: true
            ))
            #expect(engine.subtitleTracks.count == 1)
            try await eventuallyTrue { engine.subtitleTracks.first?.isSelected == true }
            let track = try #require(engine.subtitleTracks.first)
            #expect(track.isSelected)
            #expect(track.source == .downloaded)
            #expect(track.isHearingImpaired)
        }

        @Test func failedReplacementKeepsWorkingCaptionsAndRetryCommitsOnlyAfterSuccess() async throws {
            let engine = makeEngine()
            defer { engine.shutdown() }
            engine.addExternalSubtitle(Self.track("working", data: Self.cues("Working captions")))
            try await eventuallyTrue { engine.subtitleTracks.first?.isSelected == true }
            #expect(engine.currentSubtitleText == "Working captions")
            DownloadStubProtocol.set("/replacement", .init(status: 404, chunks: [Data()]))
            engine.addExternalSubtitle(Self.track("replacement"))
            try await eventuallyTrue { if case .failed = engine.subtitleLoadState { true } else { false } }
            #expect(engine.subtitleTracks.first?.isSelected == true)
            #expect(engine.subtitleTracks.last?.isSelected == false)
            #expect(engine.currentSubtitleText == "Working captions")
            DownloadStubProtocol.set("/replacement", .init(chunks: [Self.cues("Replacement captions")], holdBody: true))
            engine.retrySubtitleLoad()
            try await eventuallyTrue { DownloadStubProtocol.requests.count == 2 }
            #expect(engine.currentSubtitleText == "Working captions")
            DownloadStubProtocol.release("/replacement")
            try await eventuallyTrue { engine.subtitleLoadState == .idle }
            #expect(engine.currentSubtitleText == "Replacement captions")
            #expect(engine.subtitleTracks.last?.isSelected == true)
        }

        @Test func offNewSelectionAndShutdownCancelPendingSubtitlesWithoutLateReplacement() async throws {
            let engine = makeEngine()
            defer { engine.shutdown() }
            DownloadStubProtocol.set("/slow", .init(chunks: [Self.cues("Stale captions")], holdBody: true))
            engine.addExternalSubtitle(Self.track("slow"))
            try await eventuallyTrue { DownloadStubProtocol.requests.count == 1 }
            engine.addExternalSubtitle(Self.track("new", data: Self.cues("New captions")))
            try await eventuallyTrue { engine.subtitleTracks.last?.isSelected == true }
            try await eventuallyTrue { DownloadStubProtocol.stopped.contains("/slow") }
            DownloadStubProtocol.release("/slow")
            #expect(engine.currentSubtitleText == "New captions")
            engine.selectSubtitleTrack(id: 1)
            try await eventuallyTrue { DownloadStubProtocol.requests.count == 2 }
            engine.selectSubtitleTrack(id: nil)
            #expect(engine.currentSubtitleText == nil)
            #expect(engine.subtitleLoadState == .idle)
            #expect(engine.subtitleTracks.allSatisfy { !$0.isSelected })
            engine.selectSubtitleTrack(id: 1)
            try await eventuallyTrue { DownloadStubProtocol.requests.count == 3 }
            engine.shutdown()
            DownloadStubProtocol.release("/slow")
            #expect(engine.subtitleLoadState == .idle)
            #expect(engine.currentSubtitleText == nil)
        }

        private func makeEngine() -> SampleBufferPlayerEngine {
            DownloadStubProtocol.reset()
            return SampleBufferPlayerEngine(
                subtitleDownloader: BoundedDownload(configuration: DownloadStubProtocol.configuration())
            )
        }

        private static func cues(_ text: String) -> Data {
            Data("1\n00:00:00,000 --> 00:10:00,000\n\(text)\n".utf8)
        }

        private static func track(_ path: String, data: Data? = nil) -> ExternalSubtitleTrack {
            ExternalSubtitleTrack(
                url: DownloadStubProtocol.url("/" + path),
                preloadedData: data,
                title: path,
                language: "en",
                select: true
            )
        }
    }
}
