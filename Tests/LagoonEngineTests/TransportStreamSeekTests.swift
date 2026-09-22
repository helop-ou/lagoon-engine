import CoreMedia
import CoreVideo
import os
import Foundation
import Testing
@testable import LagoonEngine

/// Opt-in check on a real progressive MPEG-TS transcode, the shape a download
/// arrives in: `Videos/{id}/stream.ts`, H.264 High and AAC, no index. A seek
/// that lands mid-GOP fails with `kVTVideoDecoderBadDataErr` (-8969) and drops
/// a playable file to a server transcode.
///
/// Set `LAGOON_TS_SEEK_FIXTURE_URL`; `xcodebuild` passes
/// `TEST_RUNNER_LAGOON_TS_SEEK_FIXTURE_URL` with the prefix stripped, so both
/// are read.
@Suite("Transport-stream seek landing", .serialized)
struct TransportStreamSeekTests {
    nonisolated static let fixture: URL? = {
        let environment = ProcessInfo.processInfo.environment
        let raw = environment["LAGOON_TS_SEEK_FIXTURE_URL"]
            ?? environment["TEST_RUNNER_LAGOON_TS_SEEK_FIXTURE_URL"]
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("file://") { return URL(string: raw) }
        return URL(fileURLWithPath: raw)
    }()

    @Test(.enabled(if: TransportStreamSeekTests.fixture != nil))
    func aSeekIntoATransportStreamStartsOnADecodableKeyframe() throws {
        let fixture = try #require(Self.fixture)
        let demuxer = FFmpegDemuxer()
        defer { demuxer.close() }
        try demuxer.open(
            url: fixture.path,
            recommendedPixelBufferAttributes: CVPixelBufferAttributes()
        )
        let description = try #require(demuxer.videoStream?.formatDescription)
        #expect(CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_H264)

        // Two different targets: libavformat's binary search records index
        // entries, so a later seek takes a different route.
        for target in [24.8, 96.5] {
            try check(demuxer: demuxer, description: description, target: target)
        }
    }

    private func check(demuxer: FFmpegDemuxer, description: CMVideoFormatDescription, target: Double) throws {
        try demuxer.seek(toSeconds: target)
        let samples = Self.readVideo(from: demuxer, count: 12)
        let first = try #require(samples.first, "the seek delivered no video at all")

        // 1. The first sample after the flush must be a random-access point a
        // decoder can start on, not just a packet the container would seek to.
        let payload = try Self.bytes(of: first)
        let types = try #require(
            payload.withUnsafeBytes {
                VideoRandomAccessPoint.nalTypes(lengthPrefixed: $0, lengthSize: 4, codec: .h264)
            },
            "the first sample did not parse as length-prefixed NAL units"
        )
        #expect(
            VideoRandomAccessPoint.isDecoderStartPoint(nalTypes: types, codec: .h264),
            "first sample after the seek is \(VideoRandomAccessPoint.traceDescription(nalTypes: types)), not an IDR"
        )
        #expect(Self.isSyncSample(first), "the first sample must not be marked NotSync")

        // 2. It must land at or before the request, like an indexed seek, so
        // the run-in is discarded rather than content skipped. And near it, or
        // the file's head would pass.
        let start = first.presentationTimeStamp.seconds
        #expect(start <= target + 0.05, "first sample at \(start) s is past the \(target) s request")
        #expect(start > target - 24, "first sample at \(start) s for a \(target) s seek")

        // 3. VideoToolbox must accept the same samples directly (the -8969
        // case).
        try Self.decode(samples, description: description)
    }

    private static func readVideo(from demuxer: FFmpegDemuxer, count: Int) -> [CMSampleBuffer] {
        var samples: [CMSampleBuffer] = []
        for _ in 0..<4_000 where samples.count < count {
            switch demuxer.readNext() {
            case .video(let buffer):
                samples.append(buffer)
            case .failed(let message):
                Issue.record("read failed after the seek: \(message)")
                return samples
            case .endOfFile:
                return samples
            default:
                continue
            }
        }
        return samples
    }

    private static func decode(_ samples: [CMSampleBuffer], description: CMVideoFormatDescription) throws {
        guard VideoToolboxDecoder.canDecode(description) else { return }
        let failures = OSAllocatedUnfairLock<[String]>(initialState: [])
        let frames = OSAllocatedUnfairLock(initialState: 0)
        let decoder = try VideoToolboxDecoder(
            formatDescription: description,
            recommendedPixelBufferAttributes: CVPixelBufferAttributes(),
            reportedReorderDepth: 4,
            requiresHardware: false,
            outputHandler: { _ in frames.withLock { $0 += 1 } },
            errorHandler: { error in failures.withLock { $0.append("\(error)") } }
        )
        defer { decoder.invalidate() }
        for sample in samples {
            try decoder.decode(sample)
        }
        try? decoder.finish()
        let statuses = failures.withLock { $0 }
        #expect(statuses.isEmpty, "VideoToolbox rejected the post-seek samples: \(statuses)")
        #expect(frames.withLock { $0 } > 0, "no frame came out of the post-seek samples")
    }

    private static func isSyncSample(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
            as? [[CFString: Any]], let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    private static func bytes(of buffer: CMSampleBuffer) throws -> Data {
        let block = try #require(CMSampleBufferGetDataBuffer(buffer))
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            #expect(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base) == noErr)
        }
        return data
    }
}
