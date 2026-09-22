import Foundation

/// Decisions the engine makes on its own about restarting, starting and
/// rebuilding. Which delivery rung to try next stays the host's decision.

/// Whether a video decode failure is a verdict on the stream or only on the
/// point playback restarted from.
///
/// `.undecodable` is expensive and one-way: a reload, lost embedded subtitles
/// and a server transcode. A failure just after a flush is usually the seek
/// point, not the stream, so retry once in place (flush, re-seek). One retry
/// per playback generation; a second failure descends.
nonisolated enum PlaybackRestartPointPolicy {
    /// How close to the flush a failure must be: a B-pyramid of leading
    /// pictures, no more.
    static let samplesAfterFlush = 3

    static func shouldRetryInPlace(
        videoSamplesSinceFlush: Int,
        alreadyRetriedThisGeneration: Bool
    ) -> Bool {
        guard !alreadyRetriedThisGeneration else { return false }
        return videoSamplesSinceFlush <= samplesAfterFlush
    }
}

/// Whether a sample may be the *first* one a flushed renderer is given.
///
/// A read in flight during `flush()` returns a packet from the old position,
/// which would go out as sample one. The renderer refuses it and the ladder
/// would transcode. So the pump admits only a container keyframe first.
nonisolated enum PlaybackRendererStartPolicy {
    /// Samples dropped looking for a start point before the pump gives up,
    /// so a stream with unflagged keyframes still gets a picture.
    static public let startPointSearchLimit = 8

    static public func admits(
        isSyncSample: Bool,
        videoSamplesSinceFlush: Int,
        droppedSinceFlush: Int
    ) -> Bool {
        videoSamplesSinceFlush > 0
            || isSyncSample
            || droppedSinceFlush >= startPointSearchLimit
    }
}

/// What to do about a VideoToolbox *session* fault (`kVTInvalidSessionErr`
/// and siblings). The system reclaimed the session; the samples were never
/// judged, so this must not descend the ladder on its own. One rebuild per
/// playback generation; a second fault descends.
nonisolated enum PlaybackDecodeSessionPolicy {
    enum Resolution: Equatable {
        /// Playback is already over; the fault is its echo.
        case tooLate
        /// Video is suspended; the resume seek builds a fresh session.
        case ignore
        /// A rebuild is under way; other samples report the same fault.
        case alreadyRecovering
        /// Seek to the current position, which makes a new session.
        case rebuild
        /// This generation has spent its rebuild: tell the ladder.
        case descend
    }

    static func resolve(
        cancelled: Bool,
        videoOutputSuspended: Bool,
        recoveryInFlight: Bool,
        playbackGeneration: Int,
        rebuiltGeneration: Int?
    ) -> Resolution {
        if cancelled { return .tooLate }
        if videoOutputSuspended { return .ignore }
        if recoveryInFlight { return .alreadyRecovering }
        guard rebuiltGeneration != playbackGeneration else { return .descend }
        return .rebuild
    }
}
