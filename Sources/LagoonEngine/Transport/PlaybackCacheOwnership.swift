import Foundation

/// The one playback cache in the process.
///
/// Shared rather than per engine because its invariant is process-wide: one
/// active scope and at most one staged successor. The successor warms while the
/// outgoing engine plays, and a handoff stops that engine before the next
/// opens, so the coordinator must outlive any one engine.
@MainActor
enum PlaybackCacheOwner {
    static let coordinator = PlaybackCacheCoordinator(
        isEnabled: PlaybackBufferPolicy.backgroundBufferingEnabled
    )
}

/// What a host can see of the cache without steering it: enough for a scrub bar
/// and a diagnostics line. Starting, stopping and discarding belong to the
/// engine.
public nonisolated struct PlaybackBufferState: Equatable, Sendable {
    /// Whether a cache sits in front of the bytes. False for a local file, an
    /// uncached manifest, and after stop.
    public let isActive: Bool
    /// Fraction of the file cached, 0 to 1; nil when the length is unknown.
    public let bufferedFraction: Double?
    /// The cached byte ranges as fractions of the whole, for a scrub bar.
    public let bufferedRanges: [PlaybackBufferedRange]
    /// Fetches aimed at the playhead rather than filling forward. A high count
    /// means seeks are outrunning the fill.
    public let playheadPrefetchCount: Int

    public init(
        isActive: Bool = false,
        bufferedFraction: Double? = nil,
        bufferedRanges: [PlaybackBufferedRange] = [],
        playheadPrefetchCount: Int = 0
    ) {
        self.isActive = isActive
        self.bufferedFraction = bufferedFraction
        self.bufferedRanges = bufferedRanges
        self.playheadPrefetchCount = playheadPrefetchCount
    }

    public static let empty = PlaybackBufferState()
}

extension PlaybackCacheMetrics {
    var bufferState: PlaybackBufferState {
        PlaybackBufferState(
            isActive: true,
            bufferedFraction: bufferedFraction,
            bufferedRanges: bufferedRanges,
            playheadPrefetchCount: playheadPrefetchCount
        )
    }
}
