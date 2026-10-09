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
