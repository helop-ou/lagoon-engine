import Foundation
import Libavformat
import Libavutil

nonisolated private let avSeekSize: Int32 = 0x10000
nonisolated private let avSeekForce: Int32 = 0x20000
nonisolated private let avIOErrorEOF: Int32 = -541_478_725
nonisolated private let avIOErrorIO: Int32 = -5

/// Bridges FFmpeg's synchronous AVIO callbacks to Lagoon's bounded sparse
/// range cache. The object is retained by FFmpegDemuxer for longer than the
/// AVIOContext; the callback's unmanaged reference is therefore unretained.
nonisolated final class FFmpegCachedIO {
    private let source: any FFmpegByteSource
    private var position: Int64 = 0
    private(set) var context: UnsafeMutablePointer<AVIOContext>?

    /// The AVIO buffer defaults to the cache's own request size. Anything
    /// smaller costs a whole network request per buffer whenever the bytes
    /// cannot be stored — a full window, or storage disabled — because the
    /// remainder of each fetch is then discarded instead of cached.
    init(source: any FFmpegByteSource, bufferSize: Int32? = nil) throws {
        let bufferSize = bufferSize
            ?? Int32(min(max(source.requestSize, 64 * 1_024), 1_024 * 1_024))
        self.source = source
        guard let buffer = av_malloc(Int(bufferSize))?.assumingMemoryBound(to: UInt8.self) else {
            throw PlaybackCacheError.storageUnavailable
        }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let context = avio_alloc_context(
            buffer,
            bufferSize,
            0,
            opaque,
            { opaque, buffer, size in
                guard let opaque, let buffer, size > 0 else { return avIOErrorEOF }
                return Unmanaged<FFmpegCachedIO>
                    .fromOpaque(opaque)
                    .takeUnretainedValue()
                    .read(into: buffer, size: size)
            },
            nil,
            { opaque, offset, whence in
                guard let opaque else { return -1 }
                return Unmanaged<FFmpegCachedIO>
                    .fromOpaque(opaque)
                    .takeUnretainedValue()
                    .seek(offset: offset, whence: whence)
            }
        ) else {
            av_free(buffer)
            throw PlaybackCacheError.storageUnavailable
        }
        self.context = context
    }

    func close() {
        guard context != nil else { return }
        if let buffer = context?.pointee.buffer {
            av_free(buffer)
            context?.pointee.buffer = nil
        }
        avio_context_free(&context)
    }

    /// Captures FFmpeg's logical file position after a media-time seek. AVIO
    /// may already have read ahead into its own buffer, so `position` alone
    /// points past the actual demux cursor; ask AVIO for its public logical
    /// SEEK_CUR position instead.
    func setTimelineAnchor(seconds: Double, duration: Double) {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return }
        var byteOffset = position
        if let context {
            let logicalPosition = avio_seek(context, 0, Int32(SEEK_CUR))
            if logicalPosition >= 0 {
                byteOffset = logicalPosition
            }
        }
        setTimelineAnchor(byteOffset: byteOffset, seconds: seconds, duration: duration)
    }

    /// Video packets carry a more precise byte/time pair than the cursor
    /// approximation above. Refreshing the anchor while demuxing also keeps
    /// playback that started at 0:00 aligned as bitrate changes.
    func setTimelineAnchor(byteOffset: Int64, seconds: Double, duration: Double) {
        guard byteOffset >= 0,
              seconds.isFinite,
              duration.isFinite,
              duration > 0 else { return }
        source.setTimelineAnchor(
            byteOffset: max(byteOffset, 0),
            timeFraction: seconds / duration
        )
    }

    private func read(into buffer: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        guard Int64(size) <= Int64.max - position else { return avIOErrorIO }
        do {
            let data = try source.read(
                offset: position,
                length: Int(size),
                priority: URLSessionTask.highPriority
            )
            guard !data.isEmpty else { return avIOErrorEOF }
            guard data.count <= Int(size), Int64(data.count) <= Int64.max - position else { return avIOErrorIO }
            data.copyBytes(to: buffer, count: data.count)
            position += Int64(data.count)
            return Int32(data.count)
        } catch {
            // EOF means a successfully-read resource ended. Turning a range,
            // authentication, connectivity, or storage failure into EOF made
            // libavformat declare a truncated movie complete and left the UI
            // looking like permanent buffering. Preserve it as an I/O error
            // so the demuxer's bounded retry/error path remains authoritative.
            return avIOErrorIO
        }
    }

    private func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence & avSeekSize != 0 {
            return source.contentLength ?? -1
        }
        let origin = whence & ~(avSeekForce)
        let target: Int64
        switch origin {
        case Int32(SEEK_SET):
            target = offset
        case Int32(SEEK_CUR):
            let (value, overflow) = position.addingReportingOverflow(offset)
            guard !overflow else { return -1 }
            target = value
        case Int32(SEEK_END):
            guard let length = source.contentLength else { return -1 }
            let (value, overflow) = length.addingReportingOverflow(offset)
            guard !overflow else { return -1 }
            target = value
        default:
            return -1
        }
        guard target >= 0 else { return -1 }
        position = target
        return target
    }
}
