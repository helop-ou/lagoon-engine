import Foundation

/// How the bytes behind a media source behave while they are read.
///
/// The engine needs exactly one thing from the negotiation its host carried
/// out: whether it is reading an addressable file the server will not rewrite
/// underneath it, or a manifest the server is producing as it goes. That is
/// the whole of the distinction the cache and the custom I/O layer make.
///
/// It deliberately does not mirror any server's vocabulary. Jellyfin's
/// `PlayMethod` used to be read here directly, which put a wire enum from one
/// media server inside the decode path; a host maps its own negotiation onto
/// these two cases instead.
public nonisolated enum MediaDelivery: Sendable, Equatable {
    /// One resource at one URL, whole and stable for the life of the read.
    /// Range requests address the same bytes every time, so the cache can
    /// keep what it has already fetched.
    case stableFile
    /// A manifest and its segments, produced as playback advances. There is
    /// no stable byte range to cache, and the server is doing work per
    /// segment.
    case segmentedManifest
}
