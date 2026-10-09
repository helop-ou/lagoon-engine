import Foundation

nonisolated enum DemuxBackpressureDecision: Equatable {
    case read
    case waitForVideo(below: Int)
    case waitForAudio(below: Int)
}

/// Balances two streams read through one interleaved demux cursor. Soft
/// limits drain in batches while both are healthy. If one side is short, the
/// fuller side grows only to a hard limit, then paces one dequeue at a time
/// so the cursor can reach the other side's packets.
nonisolated enum DemuxBackpressurePolicy {
    private static let audioHighWater = 180
    private static let audioLowWater = 144
    private static let audioHardWater = 270
    private static let audioSafetySeconds = 1.25

    // Without a cache the demux queues are the whole cushion, so they grow.
    // **Only audio grows.** A 4K 10-bit decoded frame is 24.9 MB; compressed
    // audio is ~80 KB/s, so doubling it costs ~1.5 MB (~26 MB worst case,
    // 8-channel float LPCM). Audio also has no cushion of its own, while the
    // video renderer coasts on frames it holds.
    private static let uncachedAudioHighWater = 360
    private static let uncachedAudioLowWater = 288
    private static let uncachedAudioHardWater = 540
    /// Audio cover video must leave before parking on its high water.
    /// Larger without a cache: it must outlast a network segment fetch.
    private static let uncachedAudioSafetySeconds = 3.0
    /// Bounds on compressed video parked past the decoded limit while the
    /// loop reads on for audio. Each must hold a whole fragment, since the
    /// audio sits behind the video: 600 units is 25 s at 24 fps or 10 s at
    /// 60 fps; 128 MB is 10 s at 100 Mbps. The read-ahead starts as soon as
    /// the decoded queue is full (waiting for low lead starved a 4K remux);
    /// the audio high water bounds it.
    static let videoIntakeHardLimit = 600
    static let videoIntakeByteBudget = 128 * 1_048_576

    /// The audio depth aimed for, so the HUD can show which profile applies.
    static func audioCushionTarget(deliveryIsCached: Bool) -> Int {
        deliveryIsCached ? audioHighWater : uncachedAudioHighWater
    }

    /// Byte ceiling for the software-decoded queue, which is also bounded by
    /// count. 42 frames is 250 MB at 1080p 10-bit but 1.05 GB at 4K, in a
    /// process jetsam has killed at 2.1 GB. Twelve 4K P010 frames, about
    /// 300 MB: dav1d decodes a 4K frame in a tenth of its period, so a deeper
    /// queue costs headroom and buys no smoothness. 1080p keeps its count
    /// limit. The measurement is in docs/reference/frame-loss-bench.md.
    static let decodedQueueByteBudget: Int64 = Int64(
        SoftwareDecodeThreadPolicy.commandLineInteger(forKey: decodedQueueFramesDefaultsKey)
            .map { max($0, 1) } ?? 12
    ) * 24_883_200

    /// Launch argument for device sweeps: the budget in 4K P010 frames,
    /// `-debug.softwareDecodedQueueFrames 20`.
    static let decodedQueueFramesDefaultsKey = "debug.softwareDecodedQueueFrames"

    /// Floor however large a frame is: reorder depth plus a cushion.
    private static let decodedQueueFrameFloor = 8

    static func videoHardLimit(
        videoIsDecoded: Bool,
        videoIsSoftwareDecoded: Bool = false,
        decodedFrameBytes: Int64 = 0
    ) -> Int {
        let byCount = videoIsSoftwareDecoded ? 42 : (videoIsDecoded ? 30 : 120)
        guard videoIsSoftwareDecoded, decodedFrameBytes > 0 else { return byCount }
        let byBytes = Int(decodedQueueByteBudget / decodedFrameBytes)
        return max(min(byCount, byBytes), decodedQueueFrameFloor)
    }

    static func decision(
        videoCount: Int,
        audioCount: Int,
        audioBufferedSeconds: Double,
        videoFrameRate: Double,
        videoIsDecoded: Bool,
        videoIsSoftwareDecoded: Bool = false,
        hasAudio: Bool,
        deliveryIsCached: Bool = true,
        playbackRate: Double = 1,
        decodedFrameBytes: Int64 = 0,
        videoIntakeCount: Int = 0,
        videoIntakeBytes: Int = 0
    ) -> DemuxBackpressureDecision {
        let audioHighWater = deliveryIsCached ? Self.audioHighWater : uncachedAudioHighWater
        let audioLowWater = deliveryIsCached ? Self.audioLowWater : uncachedAudioLowWater
        let audioHardWater = deliveryIsCached ? Self.audioHardWater : uncachedAudioHardWater
        let audioSafetySeconds = deliveryIsCached
            ? Self.audioSafetySeconds
            : uncachedAudioSafetySeconds
        let videoHardWater = videoHardLimit(
            videoIsDecoded: videoIsDecoded,
            videoIsSoftwareDecoded: videoIsSoftwareDecoded,
            decodedFrameBytes: decodedFrameBytes
        )
        let safePlaybackRate = PlaybackRatePolicy.clamped(playbackRate)
        let baseVideoHighWater = videoIsSoftwareDecoded ? 30 : (videoIsDecoded ? 18 : 90)
        let baseVideoLowWater = videoIsSoftwareDecoded ? 24 : (videoIsDecoded ? 12 : 72)
        // Scale both watermarks with rate, then clamp them as a pair.
        // Clamping low water against the already clamped high water shrinks
        // the drain batch to one frame at 2x, parking the decoded queue one
        // frame under the hard limit (~254 MB of 1080p P010).
        let drainBatch = max(baseVideoHighWater - baseVideoLowWater, 1)
        let videoHighWater = min(
            Int(ceil(Double(baseVideoHighWater) * safePlaybackRate)),
            max(videoHardWater - 1, 1)
        )
        let scaledVideoLowWater = min(
            Int(ceil(Double(baseVideoLowWater) * safePlaybackRate)),
            videoHighWater - drainBatch
        )
        let videoLowWater = max(min(scaledVideoLowWater, videoHighWater - 1), 1)
        let safeFrameRate = videoFrameRate.isFinite && videoFrameRate >= 1
            ? videoFrameRate
            : 24

        if videoCount >= videoHighWater {
            let drainSeconds = Double(max(videoCount - videoLowWater, 0)) / safeFrameRate
            let audioCanCoverDrain = !hasAudio
                || audioBufferedSeconds >= audioSafetySeconds * safePlaybackRate + drainSeconds
            // With audio this is rarely true: the engine's audio queue
            // sits near zero, so the loop usually paces at the hard limit.
            if audioCanCoverDrain {
                return .waitForVideo(below: videoLowWater)
            }
            if videoCount >= videoHardWater {
                // Decoded queue full. With audio, read on and park video
                // in the intake to reach the audio behind it; the audio high
                // water and intake bounds stop it. Without audio, pace one
                // slot at a time.
                if hasAudio,
                   audioCount < audioHighWater,
                   videoIntakeCount < videoIntakeHardLimit,
                   videoIntakeBytes < videoIntakeByteBudget {
                    return .read
                }
                return .waitForVideo(below: videoHardWater)
            }
            return .read
        }

        if hasAudio, audioCount >= audioHighWater {
            let baseVideoSafetyCount = videoIsSoftwareDecoded ? 24 : (videoIsDecoded ? 12 : 36)
            let videoSafetyCount = min(
                Int(ceil(Double(baseVideoSafetyCount) * safePlaybackRate)),
                max(videoHardWater - 1, 1)
            )
            if videoCount >= videoSafetyCount {
                return .waitForAudio(below: audioLowWater)
            }
            if audioCount >= audioHardWater {
                return .waitForAudio(below: audioHardWater)
            }
        }

        return .read
    }
}
