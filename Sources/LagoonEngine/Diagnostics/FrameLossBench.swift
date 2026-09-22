import Foundation

/// The measurement discipline in code: a frame-loss number compares only from
/// the same scene over the same media-time window, untouched.
///
/// Armed by `EngineTuning.runsFrameLossBench`. After every start or seek it
/// warms up for `warmupSeconds` of media time, measures for `windowSeconds`,
/// then freezes the result (HUD line and `Bench Result` signpost). Touching the
/// transport re-arms. Windows use media time, so screenshots and stalls do not
/// skew the denominator. Stalls inside the window are reported, not discarded.
nonisolated struct FrameLossBench: Equatable {
    struct Sample: Equatable {
        var position: Double
        var totalFrames: Int
        var droppedFrames: Int
        var corruptedFrames: Int
        var stalls: Int
        /// Of those, the ones called on audio.
        var audioStalls: Int = 0
        /// Audio-dry episodes (`aDry`), whether or not they became a stall.
        var audioDry: Int = 0
        var audioGaps: Int
        var videoQueueDepth: Int
        var optimizedFrames = 0
        var accumulatedDelay = 0.0
        /// Footprint and jetsam headroom, sampled in the same window.
        var footprintBytes: Int64 = 0
        var availableBytes: Int = 0
    }

    struct Result: Equatable {
        var startPosition: Double
        var windowSeconds: Double
        var frames: Int
        var dropped: Int
        var corrupted: Int
        var stalls: Int
        /// Of those, the ones called on audio.
        var audioStalls: Int = 0
        /// Audio-dry episodes (`aDry`), whether or not they became a stall.
        var audioDry: Int = 0
        var audioGaps: Int
        var minVideoQueue: Int
        /// Frames on the direct-display path; compare with `frames` to see
        /// whether video is composited with UI.
        var optimizedFrames = 0
        /// Seconds of accumulated display lateness inside the window.
        var accumulatedDelay = 0.0
        var startingFootprintBytes: Int64 = 0
        var peakFootprintBytes: Int64 = 0
        /// Zero when the platform does not expose jetsam headroom.
        var minimumAvailableBytes: Int = 0

        var lossPercent: Double {
            frames > 0 ? Double(dropped) / Double(frames) * 100 : 0
        }

        /// One line for the HUD and the `player.regression.frameLoss` probe,
        /// which the UI tests' `FrameLossRegressionResult` parses. Every field
        /// named here is part of that contract; dropping one silently breaks
        /// the regression. `regressionSummaryIsParseable` pins it.
        var regressionSummary: String {
            String(
                format: "%.2f%% (%d/%d) · corrupt %d · stalls %d · aStalls %d · aDry %d · aGaps %d · minQ %d · peak %.0f MB (+%.0f) · @%.0f+%.0fs",
                lossPercent, dropped, frames,
                corrupted, stalls, audioStalls, audioDry, audioGaps, minVideoQueue,
                peakFootprintMB, footprintGrowthMB,
                startPosition, windowSeconds
            )
        }

        var peakFootprintMB: Double { Double(peakFootprintBytes) / 1_048_576 }
        var footprintGrowthMB: Double {
            Double(max(peakFootprintBytes - startingFootprintBytes, 0)) / 1_048_576
        }
        var minimumAvailableMB: Double { Double(minimumAvailableBytes) / 1_048_576 }
    }

    enum Phase: Equatable {
        case warming(measureFrom: Double)
        case measuring(since: Double)
        case done(Result)
    }

    let warmupSeconds: Double
    let windowSeconds: Double
    private(set) var phase: Phase
    private var start: Sample?
    private var minVideoQueue = Int.max
    private var peakFootprintBytes: Int64 = 0
    private var minimumAvailableBytes = Int.max

    public init(at position: Double, warmupSeconds: Double = 10, windowSeconds: Double = 60) {
        self.warmupSeconds = warmupSeconds
        self.windowSeconds = windowSeconds
        phase = .warming(measureFrom: position + warmupSeconds)
    }

    /// The transport was touched, so the window is no longer controlled. Start
    /// over.
    mutating func rearm(at position: Double) {
        phase = .warming(measureFrom: position + warmupSeconds)
        start = nil
        minVideoQueue = .max
        peakFootprintBytes = 0
        minimumAvailableBytes = .max
    }

    /// Feeds one snapshot; returns the result once, on the sample that
    /// completes the window.
    mutating func record(_ sample: Sample) -> Result? {
        switch phase {
        case .done:
            return nil
        case .warming(let measureFrom):
            guard sample.position >= measureFrom else { return nil }
            start = sample
            minVideoQueue = sample.videoQueueDepth
            peakFootprintBytes = sample.footprintBytes
            minimumAvailableBytes = sample.availableBytes > 0 ? sample.availableBytes : .max
            phase = .measuring(since: sample.position)
            return nil
        case .measuring:
            guard let start else { return nil }
            minVideoQueue = min(minVideoQueue, sample.videoQueueDepth)
            peakFootprintBytes = max(peakFootprintBytes, sample.footprintBytes)
            if sample.availableBytes > 0 {
                minimumAvailableBytes = min(minimumAvailableBytes, sample.availableBytes)
            }
            guard sample.position - start.position >= windowSeconds else { return nil }
            let result = Result(
                startPosition: start.position,
                windowSeconds: sample.position - start.position,
                frames: sample.totalFrames - start.totalFrames,
                dropped: sample.droppedFrames - start.droppedFrames,
                corrupted: sample.corruptedFrames - start.corruptedFrames,
                stalls: sample.stalls - start.stalls,
                audioStalls: sample.audioStalls - start.audioStalls,
                audioDry: sample.audioDry - start.audioDry,
                audioGaps: sample.audioGaps - start.audioGaps,
                minVideoQueue: minVideoQueue,
                optimizedFrames: sample.optimizedFrames - start.optimizedFrames,
                accumulatedDelay: sample.accumulatedDelay - start.accumulatedDelay,
                startingFootprintBytes: start.footprintBytes,
                peakFootprintBytes: peakFootprintBytes,
                minimumAvailableBytes: minimumAvailableBytes == .max ? 0 : minimumAvailableBytes
            )
            phase = .done(result)
            return result
        }
    }
}
