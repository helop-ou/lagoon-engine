import Foundation
import Testing
@testable import LagoonEngine

extension ScriptedDownloadTests {
    @Suite("Bounded downloads")
    struct BoundedDownloadTests {
        @Test(arguments: [401, 403, 404, 500])
        func statusFailuresCannotBecomeSubtitleContent(status: Int) async throws {
            let downloader = makeDownloader()
            DownloadStubProtocol.set("/file", .init(status: status, chunks: [Self.cues("Not a successful response")]))
            do {
                _ = try await downloader.data(from: DownloadStubProtocol.url("/file"), limit: 1024, content: .subtitle)
                Issue.record("HTTP failures must not become subtitle bytes")
            } catch DownloadFailure.httpStatus(let actual, _) { #expect(actual == status) }
        }

        @Test func headerLimitsRejectBeforeWaitingForTheBody() async throws {
            let downloader = makeDownloader()
            DownloadStubProtocol.set("/large", .init(headers: ["Content-Length": "1000000000"], holdBody: true))
            do {
                _ = try await downloader.data(from: DownloadStubProtocol.url("/large"), limit: 1024, content: .image)
                Issue.record("Declared oversize response should fail immediately")
            } catch DownloadFailure.tooLarge(let limit) { #expect(limit == 1024) }
            try await eventuallyTrue { DownloadStubProtocol.stopped.contains("/large") }
        }

        @Test(arguments: [[:], ["Content-Length": "1"], ["Content-Encoding": "gzip"]])
        func receivedBytesAreBoundedRegardlessOfLengthMetadata(headers: [String: String]) async throws {
            let downloader = makeDownloader()
            DownloadStubProtocol.set("/large", .init(
                headers: headers,
                chunks: [Data(repeating: 65, count: 513), Data(repeating: 66, count: 512)]
            ))
            do {
                _ = try await downloader.data(from: DownloadStubProtocol.url("/large"), limit: 1024, content: .subtitle)
                Issue.record("Every received chunk must respect the byte cap")
            } catch DownloadFailure.tooLarge(let limit) { #expect(limit == 1024) }
        }

        @Test func exactLimitSucceedsButTruncationAndHTMLDoNot() async throws {
            let downloader = makeDownloader()
            let bytes = Data(repeating: 65, count: 1024)
            DownloadStubProtocol.set("/exact", .init(headers: ["Content-Length": "1024"], chunks: [bytes]))
            #expect(try await downloader.data(from: DownloadStubProtocol.url("/exact"), limit: 1024, content: .bytes) == bytes)
            DownloadStubProtocol.set("/short", .init(headers: ["Content-Length": "1024"], chunks: [Data([1])]))
            do {
                _ = try await downloader.data(from: DownloadStubProtocol.url("/short"), limit: 1024, content: .image)
                Issue.record("Truncated responses must not be decoded")
            } catch DownloadFailure.truncated {}
            DownloadStubProtocol.set("/html", .init(headers: ["Content-Type": "text/html"], holdBody: true))
            do {
                _ = try await downloader.data(from: DownloadStubProtocol.url("/html"), limit: 1024, content: .subtitle)
                Issue.record("HTML should be rejected before reading a body")
            } catch DownloadFailure.unexpectedContentType {}
        }

        @Test func cancellationStopsAnActiveTransferAndAPrecancelledTaskDoesNotStartOne() async throws {
            let downloader = makeDownloader()
            DownloadStubProtocol.set("/held", .init(holdBody: true))
            let pending = Task { try await downloader.data(from: DownloadStubProtocol.url("/held"), limit: 1024, content: .bytes) }
            try await eventuallyTrue { DownloadStubProtocol.requests.count == 1 }
            pending.cancel()
            do { _ = try await pending.value; Issue.record("Expected cancellation") } catch is CancellationError {}
            try await eventuallyTrue { DownloadStubProtocol.stopped.contains("/held") }
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await downloader.data(from: DownloadStubProtocol.url("/never"), limit: 1024, content: .bytes)
            }
            do { _ = try await cancelled.value; Issue.record("Expected pre-cancellation") } catch is CancellationError {}
            #expect(DownloadStubProtocol.requests.count == 1)
        }

        private func makeDownloader() -> BoundedDownload {
            DownloadStubProtocol.reset()
            return BoundedDownload(configuration: DownloadStubProtocol.configuration())
        }

        private static func cues(_ text: String) -> Data {
            Data("1\n00:00:00,000 --> 00:10:00,000\n\(text)\n".utf8)
        }
    }
}
