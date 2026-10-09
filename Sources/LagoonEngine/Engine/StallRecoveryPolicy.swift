import Foundation

nonisolated enum StallRecoveryDecision: Equatable {
    case wait
    case resume
    case reprime
}

/// Which half of the pipeline has run dry, if either.
nonisolated enum PlaybackStarvation: String, Equatable {
    case none
    case video
    case audio
}

/// Video starvation stops the clock. Audio starvation is only counted.
///
/// **`audioQueue` depth does not measure audio starvation.** The renderer
/// drains it, so it reads near zero on a healthy title; treating that as a
/// stall broke every title with audio. Audio uses renderer delivery lead.
nonisolated enum PlaybackStarvationPolicy {
    /// How little lead the clock may have over delivered video before the
    /// picture is called starved.
    static let videoLeadSeconds = 0.2
    /// Renderer delivery lead, not engine queue depth, which AVFoundation
    /// normally drains to zero.
    static let audioFloorSeconds = 0.25

    struct Snapshot {
        var isBuffering = false
        var isPaused = false
        var didFinish = false
        var position: Double = 0
        var duration: Double = 0
        var rate: Double = 1
        var videoQueueCount = 0
        var videoQueueFinished = false
        var videoBufferedTo: Double = 0
        var hasAudio = false
        var audioQueueFinished = false
        /// Nil until the first audio sample reaches the renderer; nothing is
        /// starved before that.
        var audioDeliveryLeadSeconds: Double?
    }

    static func starvation(_ snapshot: Snapshot) -> PlaybackStarvation {
        guard !snapshot.isBuffering,
              !snapshot.isPaused,
              !snapshot.didFinish,
              snapshot.duration <= 0 || snapshot.position < snapshot.duration - 1
        else { return .none }
        // Video first: it freezes the picture. Margins are media time, so
        // they scale with rate to keep the same wall-clock cushion.
        if !snapshot.videoQueueFinished,
           snapshot.videoQueueCount == 0,
           snapshot.videoBufferedTo - snapshot.position < videoLeadSeconds * snapshot.rate {
            return .video
        }
        if snapshot.hasAudio,
           !snapshot.audioQueueFinished,
           let lead = snapshot.audioDeliveryLeadSeconds,
           lead < audioFloorSeconds * snapshot.rate {
            return .audio
        }
        return .none
    }
}

/// Pure, so an endless stall is a deterministic test failure. Twelve frames
/// matches the demuxer's low-water cushion; five seconds allows a normal
/// network refill but stays well below a visibly frozen player.
nonisolated enum StallRecoveryPolicy {
    static let confirmationDelay: Duration = .seconds(1)
    static let resumeVideoCount = 12
    static let reprimeAfter: Duration = .seconds(5)
    /// Renderer delivery lead required before an audio-gated resume, scaled
    /// by rate.
    static let resumeAudioLeadSeconds = 1.0
    /// Lead still required when the renderer reports it is ready: clear of
    /// the 0.25 s starvation floor, so the first tick cannot re-arm a stall.
    static let resumeAudioLeadFloorSeconds = 0.5

    /// `.audio` confirms a stall only when `buffersOnAudioStarvation` is on.
    static func confirms(_ starvation: PlaybackStarvation, buffersOnAudioStarvation: Bool) -> Bool {
        switch starvation {
        case .video: return true
        case .audio: return buffersOnAudioStarvation
        case .none: return false
        }
    }

    /// Audio readiness reads renderer lead and readiness, never `audioQueue`,
    /// which the renderer drains as fast as it fills. Readiness normally
    /// decides: with the clock stopped the lead parks just under 1 s.
    /// Checked only when `audioRequired`, then for video stalls too.
    static func decision(
        elapsed: Duration,
        videoQueueCount: Int,
        videoQueueFinished: Bool,
        playbackRate: Double = 1,
        audioRequired: Bool = false,
        audioDeliveryLeadSeconds: Double? = nil,
        audioRendererHasSufficientData: Bool = false
    ) -> StallRecoveryDecision {
        let requiredVideoCount = Int(ceil(
            Double(resumeVideoCount) * PlaybackRatePolicy.clamped(playbackRate)
        ))
        let videoReady = videoQueueCount >= requiredVideoCount || videoQueueFinished
        let rate = PlaybackRatePolicy.clamped(playbackRate)
        let lead = audioDeliveryLeadSeconds ?? -.infinity
        let audioReady = !audioRequired
            || lead >= resumeAudioLeadSeconds * rate
            || (audioRendererHasSufficientData && lead >= resumeAudioLeadFloorSeconds * rate)
        if videoReady && audioReady {
            return .resume
        }
        if elapsed >= reprimeAfter {
            return .reprime
        }
        return .wait
    }
}
