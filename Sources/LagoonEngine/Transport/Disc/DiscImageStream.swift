import Foundation

/// What `FFmpegCachedIO` needs from whatever is underneath it.
///
/// The playback cache was the only answer until a disc image needed one more
/// layer: the same reads, addressed to a title rather than to a file. Naming
/// the requirement lets that layer exist without the AVIO shim knowing which
/// of the two it is talking to.
nonisolated protocol FFmpegByteSource: AnyObject {
    /// Bytes one cache miss fetches, which is also how the AVIO buffer is
    /// sized.
    var requestSize: Int64 { get }
    /// The length AVIO reports for `SEEK_SIZE`, nil while it is unknown.
    var contentLength: Int64? { get }
    func read(offset: Int64, length: Int, priority: Float) throws -> Data
    func setTimelineAnchor(byteOffset: Int64, timeFraction: Double)
}

// The demuxer and the transport use the scope as a byte source off the main
// actor; the conformance has to say so or Swift 6 treats it as main-actor-bound.
nonisolated extension PlaybackCacheScope: FFmpegByteSource {}

/// The volume reader's view of a cached image: small scattered reads, served
/// from the same cache that will later stream the title.
nonisolated final class PlaybackCacheDiscSource: DiscImageSource {
    private let source: any FFmpegByteSource

    init(source: any FFmpegByteSource) {
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

/// A Blu-ray title as one contiguous stream, mapped onto the image behind it.
///
/// Every read and seek FFmpeg makes is in title bytes; every read this makes
/// is in image bytes. Nothing above this needs to know the film arrives as
/// dozens of clips, and nothing below it needs to know the image is a disc.
nonisolated final class DiscImageStream: FFmpegByteSource {
    private let source: any FFmpegByteSource
    private let map: DiscStreamMap

    init(source: any FFmpegByteSource, map: DiscStreamMap) {
        self.source = source
        self.map = map
    }

    var requestSize: Int64 { source.requestSize }

    var contentLength: Int64? { map.length }

    func read(offset: Int64, length: Int, priority: Float) throws -> Data {
        guard length > 0, let position = map.locate(offset) else { return Data() }
        // Never read across an extent boundary in one go: the bytes after it
        // belong somewhere else in the image entirely. A short read is what
        // AVIO expects anyway, and the next one continues from the extent
        // that follows.
        return try source.read(
            offset: position.imageOffset,
            length: min(length, position.available),
            priority: priority
        )
    }

    func setTimelineAnchor(byteOffset: Int64, timeFraction: Double) {
        guard let position = map.locate(byteOffset) else { return }
        // The cache reads ahead in image bytes, so the anchor it is given has
        // to be an image byte too.
        source.setTimelineAnchor(byteOffset: position.imageOffset, timeFraction: timeFraction)
    }
}
