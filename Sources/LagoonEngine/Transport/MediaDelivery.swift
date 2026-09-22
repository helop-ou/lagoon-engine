import Foundation

/// How the bytes behind a media source behave while they are read.
///
/// The one thing the engine needs from the host's negotiation: an addressable
/// file the server will not rewrite, or a manifest produced as playback runs.
/// It mirrors no server's vocabulary; a host maps its own negotiation onto
/// these two cases.
public nonisolated enum MediaDelivery: Sendable, Equatable {
    /// One stable resource at one URL. Range requests always address the same
    /// bytes, so the cache can keep them.
    case stableFile
    /// A manifest and segments produced as playback advances. No stable byte
    /// range to cache.
    case segmentedManifest
}
