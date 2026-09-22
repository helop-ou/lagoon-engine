import CoreVideo
import Darwin
import Foundation
import Testing
@testable import LagoonEngine

@Suite("Failed demuxer setup", .serialized)
struct DemuxerLifetimeTests {
    @Test func repeatedDiscAndCustomIOFailuresCanBeClosedAndReopened() throws {
        try exerciseFailures(iterations: 32, measureAllocations: false)
    }

    // Run alone with LAGOON_DEMUX_LIFETIME_CHECK=1. Live allocator bytes, not
    // RSS/high-water memory, distinguish leaked native contexts from caches.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LAGOON_DEMUX_LIFETIME_CHECK"] == "1"))
    func failedOpensDoNotAccumulateNativeAllocations() throws {
        try exerciseFailures(iterations: 2_000, measureAllocations: true)
    }

    private func exerciseFailures(iterations: Int, measureAllocations: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = URL(string: "https://disc.invalid/malformed.iso")!
        let scope = try PlaybackCacheScope(itemID: "malformed", sourceURL: url, expectedLength: 1_048_576,
                                           directory: directory, byteLimit: 1_048_576, requestSize: 65_536,
                                           loader: ZeroDiscLoader())
        defer { scope.cancelAndRemove() }
        let session = PlaybackCacheSession(itemID: "malformed", sourceURL: url, storage: .direct(scope))
        let demuxer = FFmpegDemuxer()
        defer { demuxer.close() }
        // Disc setup throws before avformat_open_input; ordinary custom I/O
        // fails inside it. Their ownership rules differ.
        for disc in [DiscPlaybackRequest(runtimeSeconds: nil), nil] {
            func attempt() throws {
                try autoreleasepool {
                    do {
                        try demuxer.open(url: url.absoluteString, cacheSession: session, disc: disc,
                                         recommendedPixelBufferAttributes: CVPixelBufferAttributes())
                        Issue.record("Zero-filled input unexpectedly opened")
                    } catch is DemuxError {
                        // No caller close here: failed open must release its own resources.
                    }
                }
            }
            for _ in 0..<32 { try attempt() } // Warm native/framework caches.
            let before = liveHeapBytes()
            for _ in 0..<iterations { try attempt() }
            let after = liveHeapBytes()
            if measureAllocations {
                print("DemuxLifetime stage=\(disc == nil ? "custom-io" : "disc-setup") iterations=\(iterations) heapDelta=\(after - before)")
                // A context leak retains several MiB over this many opens;
                // allow a little OS bookkeeping.
                #expect(after - before < 512 * 1_024)
            }
            demuxer.close()
            demuxer.close() // Caller cleanup remains idempotent.
        }
    }

    private func liveHeapBytes() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return statistics.size_in_use
    }
}

private nonisolated final class ZeroDiscLoader: PlaybackRangeLoading, @unchecked Sendable {
    func load(url: URL, range: PlaybackByteRange, priority: Float) throws -> PlaybackRangeResponse {
        let count = Int(max(0, min(range.upperBound, 1_048_576) - range.lowerBound))
        return PlaybackRangeResponse(data: Data(repeating: 0, count: count), offset: range.lowerBound, totalLength: 1_048_576)
    }
    func cancelAll() {}
}
