import AVFoundation
import CoreMedia

/// Media time for the clock anchor. A seek may enqueue pre-target reference
/// frames, so use the first enqueued PTS only when it is at or past the target.
nonisolated enum PlaybackClockAnchor {
    static func mediaTime(targetSeconds: Double, firstVideoPTS: CMTime?) -> CMTime {
        let target = CMTime(seconds: max(targetSeconds, 0), preferredTimescale: 240_000)
        guard let firstVideoPTS,
              firstVideoPTS.isValid,
              firstVideoPTS.seconds.isFinite,
              CMTimeCompare(firstVideoPTS, target) >= 0 else { return target }
        return firstVideoPTS
    }
}

/// Whether a start anchors the clock to a near-future host time. An AirPlay
/// receiver buffers about two seconds and cannot meet a start that near:
/// after a seek it took a few seconds of audio and never played them. There
/// the synchronizer starts once the renderers have enough, a group start
/// included, since silence costs more than the receiver's own delay.
nonisolated enum PlaybackClockStart {
    static func usesHostTime(outputs: [AVAudioSession.Port]) -> Bool {
        !outputs.contains(.airPlay)
    }

    /// How far ahead of now a start is anchored. At 0.1 s the first pictures
    /// after a start or seek missed their deadline on an Apple TV over HDMI.
    static let leadSeconds = 0.25

    /// The host time a start is anchored to. A group start is honoured only
    /// while it is still ahead: a missed one is the server's to reissue.
    static func hostTime(now: CMTime, scheduledStart: CMTime?) -> CMTime {
        if let scheduledStart, CMTimeCompare(scheduledStart, now) > 0 {
            return scheduledStart
        }
        return CMTimeAdd(now, CMTime(seconds: leadSeconds, preferredTimescale: 1_000_000_000))
    }

    /// Starts `clock` at `time`, at `hostTime` unless the route is AirPlay.
    static func start(
        _ clock: some PlaybackClockStarting,
        rate: Float,
        time: CMTime,
        hostTime: CMTime,
        outputs: [AVAudioSession.Port]
    ) {
        if usesHostTime(outputs: outputs) {
            clock.setRate(rate, time: time, atHostTime: hostTime)
        } else {
            clock.setRate(rate, time: time)
        }
    }
}

/// The two ways a start sets the clock, so a test can see which ran.
nonisolated protocol PlaybackClockStarting {
    func setRate(_ rate: Float, time: CMTime)
    func setRate(_ rate: Float, time: CMTime, atHostTime hostTime: CMTime)
}

extension AVSampleBufferRenderSynchronizer: PlaybackClockStarting {}

/// Resolves EOF from the last sample end. The container duration is only a
/// fallback: it can be missing, or outlast a truncated input.
nonisolated enum PlaybackEndBoundary {
    static func endTime(sampledEnd: Double, declaredDuration: Double) -> Double? {
        if sampledEnd.isFinite, sampledEnd > 0 {
            return sampledEnd
        }
        if declaredDuration.isFinite, declaredDuration >= 0 {
            return declaredDuration
        }
        return nil
    }
}
