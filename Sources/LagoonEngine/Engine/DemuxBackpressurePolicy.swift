import Foundation

nonisolated enum DemuxBackpressureDecision: Equatable {
    case read
    case waitForVideo(below: Int)
    case waitForAudio(below: Int)
}

/// Which limit stopped the demuxer reading, for diagnostics. Without a byte
/// cache this decides how far ahead a stream is buffered.
public nonisolated enum DemuxReadAheadLimit: String, Sendable {
    /// The audio queue reached its high water.
    case audio
    /// The decoded video queue reached its high water with audio to spare.
    case video
    /// Compressed video parked past the decoded queue reached its unit limit.
    case videoIntake
    /// The same, by bytes.
    case videoIntakeBytes
    /// An uncached stream reached its read-ahead target.
    case target
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

    /// Without a cache the queues read on to this much media ahead of the
    /// clock, at normal speed, past the watermarks above. A 24 fps transcode
    /// stopped 7 to 10 s ahead on the compressed video high water, so one slow
    /// segment response stalled it. The hard limits and the byte budget still
    /// hold: a 4K remux reaches the intake's 128 MB first, about 13 s at
    /// 80 Mbps.
    static let uncachedReadAheadSeconds: Double = 30
    /// Intake units without a cache: 30 s at 60 fps. The byte budget still
    /// bounds the memory.
    static let uncachedVideoIntakeHardLimit = 1_800
    /// Audio held while reading to the target, by bytes rather than buffers:
    /// a buffer is 21 ms to 128 ms depending on the path, so 540 of them
    /// stopped a transcode at 16 s. The budget is what 540 buffers cost at
    /// worst (2048 samples of 8-channel float each), so no ceiling rises.
    static let uncachedAudioByteBudget = 540 * 2_048 * 8 * 4
    /// And a count no stream should need, so buffer overhead stays bounded.
    static let uncachedAudioCountCeiling = 4_000

    /// Whether an uncached stream reads on past the watermarks: short of its
    /// target, with audio under its hard water and the intake under its
    /// bounds.
    static func readsOnToTarget(
        readAheadSeconds: Double?,
        playbackRate: Double,
        audioCount: Int,
        audioBytes: Int,
        hasAudio: Bool,
        deliveryIsCached: Bool,
        videoIntakeCount: Int,
        videoIntakeBytes: Int
    ) -> Bool {
        guard !deliveryIsCached, let readAheadSeconds, readAheadSeconds.isFinite,
              readAheadSeconds < uncachedReadAheadSeconds * PlaybackRatePolicy.clamped(playbackRate) else { return false }
        if hasAudio, audioBytes >= uncachedAudioByteBudget || audioCount >= uncachedAudioCountCeiling { return false }
        return videoIntakeCount < uncachedVideoIntakeHardLimit && videoIntakeBytes < videoIntakeByteBudget
    }

    /// Which limit a wait decision stopped on; nil for a read. Mirrors the
    /// branches of `decision`, which it is only ever called after.
    static func limit(
        for decision: DemuxBackpressureDecision,
        audioCount: Int,
        hasAudio: Bool,
        deliveryIsCached: Bool,
        videoIntakeCount: Int,
        videoIntakeBytes: Int,
        readAheadSeconds: Double? = nil,
        playbackRate: Double = 1
    ) -> DemuxReadAheadLimit? {
        if case .read = decision { return nil }
        if !deliveryIsCached, let readAheadSeconds,
           readAheadSeconds >= uncachedReadAheadSeconds * PlaybackRatePolicy.clamped(playbackRate) {
            return .target
        }
        switch decision {
        case .read:
            return nil
        case .waitForAudio:
            return .audio
        case .waitForVideo:
            guard hasAudio else { return .video }
            if audioCount >= audioCushionTarget(deliveryIsCached: deliveryIsCached) { return .audio }
            if videoIntakeCount >= videoIntakeHardLimit { return .videoIntake }
            if videoIntakeBytes >= videoIntakeByteBudget { return .videoIntakeBytes }
            return .video
        }
    }

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
        videoIntakeBytes: Int = 0,
        readAheadSeconds: Double? = nil,
        audioBytes: Int = 0
    ) -> DemuxBackpressureDecision {
        if readsOnToTarget(
            readAheadSeconds: readAheadSeconds,
            playbackRate: playbackRate,
            audioCount: audioCount,
            audioBytes: audioBytes,
            hasAudio: hasAudio,
            deliveryIsCached: deliveryIsCached,
            videoIntakeCount: videoIntakeCount,
            videoIntakeBytes: videoIntakeBytes
        ) {
            return .read
        }
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
