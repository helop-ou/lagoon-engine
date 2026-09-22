import Foundation

/// The one playback cache in the process.
///
/// A host used to own the coordinator, decide when to activate a scope, and
/// run the fill loop itself. That put engine work on the other side of the
/// package boundary: every input the fill loop reads — stall count, rate,
/// duration, whether the picture is buffering — is the engine's, and the
/// host was only relaying them back.
///
/// It is a single shared instance rather than one per engine because the
/// invariant it protects is process-wide: one active scope and at most one
/// staged successor. A successor scope is warmed while the outgoing engine
/// is still playing, and an episode handoff shuts that engine down before
/// the next one opens, so the coordinator has to outlive any one engine.
@MainActor
enum PlaybackCacheOwner {
    static let coordinator = PlaybackCacheCoordinator(
        isEnabled: PlaybackBufferPolicy.backgroundBufferingEnabled
    )
}

/// What a host can see of the cache without being able to steer it.
///
/// Enough to draw a scrub bar's buffered ranges and a diagnostics line, and
/// nothing that would let a caller start, stop or discard a scope — those
/// decisions belong to whichever engine is playing.
public nonisolated struct PlaybackBufferState: Equatable, Sendable {
    /// Whether a cache is in front of the bytes at all. False for a local
    /// file, for a manifest the policy declines to cache, and once playback
    /// has stopped.
    public let isActive: Bool
    /// How much of the file is cached, 0 to 1, or nil when the length is
    /// unknown — a live stream or a manifest the server is still writing.
    public let bufferedFraction: Double?
    /// The cached byte ranges as fractions of the whole, for a scrub bar.
    public let bufferedRanges: [PlaybackBufferedRange]
    /// How many fetches were aimed at the playhead rather than at filling
    /// forward. A high count means seeking is outrunning the fill.
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
