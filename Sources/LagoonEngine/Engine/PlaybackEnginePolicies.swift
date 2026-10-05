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

/// Whether a VideoToolbox bad-data error (`kVTVideoDecoderBadDataErr`) is a
/// damaged run in a stream that decodes, or a verdict on the stream.
///
/// Some files carry pictures VideoToolbox rejects that libavcodec decodes
/// cleanly, and decoding resumes at the next keyframe. Descending for that is
/// a reload, a black screen and a server transcode; dropping the run is a
/// stutter. So once a session has produced pictures on this stream it drops
/// damaged ones, up to a run too long to be one damaged group of pictures. A
/// stream that fails from its first pictures, or keeps failing, still reaches
/// the ladder.
///
/// The proof belongs to the stream, not the session: a seek, including the
/// engine's own recovery seeks, keeps it. Until the new session decodes a
/// picture, only `proofFrames` damaged ones are dropped, so a seek into data
/// that cannot decode is judged in about two seconds, not ten.
nonisolated enum PlaybackCorruptFramePolicy {
    /// Pictures a session must decode after a reset before a bad-data error
    /// reads as damage, not as the stream: two seconds at 24 fps.
    static let proofFrames = 48
    /// Clean pictures after damage that close the run.
    static let recoveryFrames = 48
    /// The longest damaged run dropped: longer than a ten-second group of
    /// pictures at 24 fps.
    static let toleratedRun = 300

    struct State: Equatable {
        private(set) var decodedSinceReset = 0
        /// Some session decoded `proofFrames` pictures of this stream.
        private(set) var proven = false
        private(set) var run = 0
        private(set) var cleanSinceDamage = 0
        /// Every picture dropped as damage, across resets.
        private(set) var dropped = 0

        mutating func recordDecoded() {
            decodedSinceReset += 1
            if decodedSinceReset >= PlaybackCorruptFramePolicy.proofFrames { proven = true }
            cleanSinceDamage += 1
            if cleanSinceDamage >= PlaybackCorruptFramePolicy.recoveryFrames { run = 0 }
        }

        /// True drops the picture; false makes the error a verdict.
        mutating func absorbsDamagedFrame() -> Bool {
            let limit = decodedSinceReset > 0
                ? PlaybackCorruptFramePolicy.toleratedRun
                : PlaybackCorruptFramePolicy.proofFrames
            guard proven, run < limit else { return false }
            run += 1
            dropped += 1
            cleanSinceDamage = 0
            return true
        }

        /// A new session. The stream stays proven; the run starts over.
        mutating func reset() {
            decodedSinceReset = 0
            run = 0
            cleanSinceDamage = 0
        }
    }
}

/// Whether a picture `AVSampleBufferVideoRenderer` failed to decode is
/// damage it plays through, or a verdict on the stream.
///
/// On the Apple TV 4K (3rd gen), a damaged H.264 picture made the renderer
/// post `didFailToDecode` (`-11821`, underlying `-12909`) for it and every
/// picture depending on it, 18 over 0.7 s. Its status stayed `.rendering`, it
/// never asked for a flush, and it decoded on from the next keyframe. Taking
/// the first notification as a verdict threw direct play away for that. So,
/// as `PlaybackCorruptFramePolicy` does for the engine's own decoder, a frame
/// fault in a stream the renderer has already played is counted, not judged,
/// up to a run too long to be one damaged group of pictures.
nonisolated enum PlaybackRendererDamagePolicy {
    /// Samples the renderer must take after a flush before its failures read
    /// as damage: two seconds at 24 fps. The proof outlives seeks.
    static let proofSamples = 48
    /// Media time without a failure that closes a run.
    static let quietSeconds = 2.0
    /// The longest run of failed pictures played through.
    static let toleratedRun = 300

    struct State: Equatable {
        private(set) var proven = false
        private(set) var run = 0
        private(set) var dropped = 0
        private var lastFailureSeconds: Double?

        /// True plays through the failed picture; false makes it a verdict.
        mutating func absorbs(refusedSeconds: Double?, samplesSinceFlush: Int) -> Bool {
            if samplesSinceFlush >= PlaybackRendererDamagePolicy.proofSamples { proven = true }
            guard proven else { return false }
            if let refusedSeconds, let last = lastFailureSeconds,
               abs(refusedSeconds - last) > PlaybackRendererDamagePolicy.quietSeconds {
                run = 0
            }
            guard run < PlaybackRendererDamagePolicy.toleratedRun else { return false }
            run += 1
            dropped += 1
            if let refusedSeconds { lastFailureSeconds = refusedSeconds }
            return true
        }
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
/// judged, so this must not descend the ladder on its own. A rebuild is
/// spent per fault burst: once the rebuilt session has decoded
/// `provenFrames` pictures, a later fault earns another. Only an immediate
/// repeat descends, and in the background not even that: video waits for
/// the foreground instead.
nonisolated enum PlaybackDecodeSessionPolicy {
    /// Pictures a rebuilt session must decode before the burst is over: two
    /// seconds at 24 fps, as for `PlaybackCorruptFramePolicy.proofFrames`.
    static let provenFrames = 48

    enum Resolution: Equatable {
        /// Playback is already over; the fault is its echo.
        case tooLate
        /// Video is suspended; the resume seek builds a fresh session.
        case ignore
        /// A rebuild is under way; other samples report the same fault.
        case alreadyRecovering
        /// Seek to the current position, which makes a new session.
        case rebuild
        /// The host is in the background and the rebuild did not hold:
        /// suspend video until the host returns, whose resume seek makes a
        /// new session.
        case park
        /// The rebuilt session failed before decoding anything worth the
        /// name: tell the ladder.
        case descend
    }

    static func resolve(
        cancelled: Bool,
        videoOutputSuspended: Bool,
        recoveryInFlight: Bool,
        hostInBackground: Bool,
        playbackGeneration: Int,
        rebuiltGeneration: Int?,
        framesSinceRebuild: Int
    ) -> Resolution {
        if cancelled { return .tooLate }
        if videoOutputSuspended { return .ignore }
        if recoveryInFlight { return .alreadyRecovering }
        let immediateRepeat = rebuiltGeneration == playbackGeneration
            && framesSinceRebuild < provenFrames
        guard immediateRepeat else { return .rebuild }
        return hostInBackground ? .park : .descend
    }
}
