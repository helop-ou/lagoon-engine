import Foundation

/// The measurement discipline, encoded so nobody has to remember it: a
/// frame-loss number is comparable only from the same scene over the same
/// media-time window, untouched. Both earlier false positives broke that.
///
/// Armed by Settings → Debug → Frame-loss bench. After every start or seek it
/// warms up for `warmupSeconds` of *media time*, measures for
/// `windowSeconds`, then freezes the result (HUD line + `Bench Result`
/// signpost). Touching the transport re-arms from the new position, so "seek
/// to the scene, hands off, read the number" is the whole protocol, identical
/// in the simulator and on hardware.
///
/// Windows key on playback position, not wall time: screenshots and stalls
/// stretch wall time but not media time, so the denominator stays honest.
/// Stalls inside the window are reported, not discarded — a stall is a
/// finding.
nonisolated struct FrameLossBench: Equatable {
    struct Sample: Equatable {
        var position: Double
        var totalFrames: Int
        var droppedFrames: Int
        var corruptedFrames: Int
        var stalls: Int
        /// Of those, the ones called on audio.
        var audioStalls: Int = 0
        /// Audio-dry episodes (`aDry`), counted regardless of whether they
        /// became a confirmed stall.
        var audioDry: Int = 0
        var audioGaps: Int
        var videoQueueDepth: Int
        var optimizedFrames = 0
        var accumulatedDelay = 0.0
        /// Physical footprint and jetsam headroom sampled in the same
        /// controlled window as frame loss.
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
        /// Audio-dry episodes (`aDry`), counted regardless of whether they
        /// became a confirmed stall. Silence used to leave no trace in a
        /// bench window at all.
        var audioDry: Int = 0
        var audioGaps: Int
        var minVideoQueue: Int
        /// Frames that took the direct-display path inside the window —
        /// compare against `frames` to see whether video is being
        /// composited with UI.
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

        /// One line for the HUD *and* for the `player.regression.frameLoss`
        /// probe, which `FrameLossRegressionResult` in the UI tests parses.
        /// Every field named here is part of that contract; removing one
        /// silently stops the regression reading its own result, which is
        /// how `testVC1DirectPlayMaintainsContinuousAudioAndVideo` was once
        /// broken, by dropping `corrupt` and `aGaps` to make room for the
        /// memory figures. `regressionSummaryIsParseable` pins it.
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

    init(at position: Double, warmupSeconds: Double = 10, windowSeconds: Double = 60) {
        self.warmupSeconds = warmupSeconds
        self.windowSeconds = windowSeconds
        phase = .warming(measureFrom: position + warmupSeconds)
    }

    /// The transport was touched (seek, pause) — the running window is no
    /// longer a controlled measurement. Start over from the new position.
    mutating func rearm(at position: Double) {
        phase = .warming(measureFrom: position + warmupSeconds)
        start = nil
        minVideoQueue = .max
        peakFootprintBytes = 0
        minimumAvailableBytes = .max
    }

    /// Feed one metrics snapshot; returns the result exactly once, on the
    /// sample that completes the window.
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
