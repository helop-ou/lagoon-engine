import Foundation

/// What `FFmpegCachedIO` needs from the source beneath it: the playback cache,
/// or a disc title mapped onto one.
nonisolated protocol FFmpegByteSource: AnyObject {
    /// Bytes one cache miss fetches; the AVIO buffer is sized to match.
    var requestSize: Int64 { get }
    /// The length AVIO reports for `SEEK_SIZE`, nil while it is unknown.
    var contentLength: Int64? { get }
    func read(offset: Int64, length: Int, priority: Float) throws -> Data
    func setTimelineAnchor(byteOffset: Int64, timeFraction: Double)
}

// The scope is used off the main actor; without `nonisolated` Swift 6 treats
// the conformance as main-actor-bound.
nonisolated extension PlaybackCacheScope: FFmpegByteSource {}

/// The volume reader's view of a cached image: small scattered reads, served
/// from the cache that later streams the title.
nonisolated final class PlaybackCacheDiscSource: DiscImageSource {
    private let source: any FFmpegByteSource

    public init(source: any FFmpegByteSource) {
        self.source = source
    }

    var imageLength: Int64? { source.contentLength }

    func read(at offset: Int64, count: Int) throws -> Data {
        if let cache = source as? PlaybackCacheScope {
            return try cache.readMetadata(offset: offset, length: count)
        }
        return try source.read(offset: offset, length: count, priority: URLSessionTask.highPriority)
    }
}

/// A Blu-ray title as one contiguous stream over the image. FFmpeg reads and
/// seeks in title bytes; this reads in image bytes.
nonisolated final class DiscImageStream: FFmpegByteSource {
    private let source: any FFmpegByteSource
    private let map: DiscStreamMap

    public init(source: any FFmpegByteSource, map: DiscStreamMap) {
        self.source = source
        self.map = map
    }

    var requestSize: Int64 { source.requestSize }

    var contentLength: Int64? { map.length }

    func read(offset: Int64, length: Int, priority: Float) throws -> Data {
        guard length > 0, let position = map.locate(offset) else { return Data() }
        // Never read across an extent boundary: the next bytes live elsewhere
        // in the image. AVIO accepts the short read.
        return try source.read(
            offset: position.imageOffset,
            length: min(length, position.available),
            priority: priority
        )
    }

    func setTimelineAnchor(byteOffset: Int64, timeFraction: Double) {
        guard let position = map.locate(byteOffset) else { return }
        // The cache reads ahead in image bytes, so the anchor is an image byte
        // too.
        source.setTimelineAnchor(byteOffset: position.imageOffset, timeFraction: timeFraction)
    }
}
