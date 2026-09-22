import Foundation

/// The decisions the engine makes on its own about restarting, starting and
/// rebuilding, extracted from the app's fallback file so that the verdicts
/// the engine reaches travel with the engine. What a host then does with a
/// verdict — which rung of a delivery ladder to try next — stays the host's.

/// Whether a video decode failure is a verdict on the stream or only on the
/// point playback was restarted from.
///
/// The ladder's `.undecodable` rung is expensive and one-way: it costs the
/// viewer three seconds of reload, the embedded subtitle tracks, and the
/// server minutes of CPU per viewer. It should answer "this device cannot
/// decode this bitstream", and a decode failure a few samples after a
/// renderer flush usually is not that — it is the decoder refusing where the
/// seek put it, on a stream whose every other second decodes perfectly. One
/// in-place retry (flush, re-seek to the same position) separates the two,
/// and costs a scrub a hiccup instead of a restart.
///
/// Bounded on purpose. Only one retry is allowed per playback generation, so
/// a stream that really is undecodable descends the ladder on its second
/// failure, exactly as it did before, one seek later.
public nonisolated enum PlaybackRestartPointPolicy {
    /// How close to the flush a failure has to be. An open GOP's leading
    /// pictures arrive immediately behind the picture the seek landed on;
    /// three samples covers a B-pyramid's worth and nothing beyond it.
    static public let samplesAfterFlush = 3

    static public func shouldRetryInPlace(
        videoSamplesSinceFlush: Int,
        alreadyRetriedThisGeneration: Bool
    ) -> Bool {
        guard !alreadyRetriedThisGeneration else { return false }
        return videoSamplesSinceFlush <= samplesAfterFlush
    }
}

/// Whether a sample may be the *first* one a flushed renderer is given.
///
/// `AVSampleBufferVideoRenderer` starts only on a random-access point, and a
/// seek is not the only way a sample reaches it after `flush()`. The demux
/// thread can be parked inside a read at the moment of the flush, and the
/// packet it returns belongs to the position being left: it lands in the
/// emptied queue and goes out as sample one. The renderer refuses it, and the
/// ladder reads that refusal as a verdict on the bitstream and transcodes.
///
/// So the pump asks this first. What the container calls a keyframe is
/// admitted — keeping the open-GOP I picture the demuxer hands over —
/// and anything else waits for one.
public nonisolated enum PlaybackRendererStartPolicy {
    /// How many samples may be dropped looking for a start point before the
    /// pump gives up and enqueues what it has.
    ///
    /// The same escape the demuxer's keyframe search keeps: a stream whose
    /// keyframes are never flagged must not lose its picture altogether. One
    /// stale sample is the expected case, because the flush empties the
    /// intake too and only a read already in flight can still arrive.
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

/// What to do about a VideoToolbox *session* fault, which is not a verdict
/// on the bitstream and must not descend the ladder on its own.
///
/// `kVTInvalidSessionErr` and its siblings say the decode session is gone or
/// was refused. The samples were never judged: the system reclaims decoders,
/// and whatever was in flight when it did reports the loss. Reading that as
/// `.undecodable` spends the one-way transcode rung — three seconds of
/// reload, the embedded subtitle tracks, and minutes of server CPU — on a
/// session a rebuild would have replaced for nothing.
///
/// The same shape as `PlaybackRestartPointPolicy` above, and for the same
/// reason: bounded at one rebuild per playback generation, so a session that
/// genuinely cannot be made descends the ladder on its second fault instead
/// of looping.
public nonisolated enum PlaybackDecodeSessionPolicy {
    public enum Resolution: Equatable {
        /// Playback is already over — something else failed, or the viewer
        /// stopped. The samples still inside the decoder report the session
        /// going down with it, and a rebuild would seek a demux loop that
        /// has already left.
        case tooLate
        /// Suspended video has no session worth saving. Backgrounding leaves
        /// the old one alive deliberately, because making a new one in the
        /// background can be refused, and the resume seek builds a fresh one
        /// anyway — so a sample that reached a session the system
        /// had already torn down says nothing about anything.
        case ignore
        /// A rebuild is already on its way. Every other sample inside the
        /// decoder is about to report the same dead session, and they all
        /// mean the one fault.
        case alreadyRecovering
        /// Rebuild: one seek to the position the playhead is already at,
        /// which resets the decoder onto a keyframe with a new session.
        case rebuild
        /// This generation has spent its rebuild. A session that cannot be
        /// replaced is this device being unable to decode this here after
        /// all, so the ladder is told.
        case descend
    }

    static public func resolve(
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
