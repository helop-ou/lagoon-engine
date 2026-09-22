import Foundation
import os

/// The engine's tuning knobs, as a host supplies them.
///
/// A library must not read its host's preferences, so the host passes these in.
/// Defaults are off, empty or automatic, giving plain playback with no
/// instrumentation. These are diagnostics and experiments; never wire one to a
/// viewer-facing setting.
public nonisolated struct EngineTuning: Sendable {
    public init() {}

    // MARK: Decode experiments

    /// Rewrite a Dolby Vision profile 7 stream to plain HDR10 by dropping the
    /// enhancement layer, instead of converting the RPU to profile 8.1.
    public var stripsDolbyVisionEnhancementLayer = false
    /// Tag non-reference frames as droppable, so the renderer may skip them
    /// under load rather than falling behind.
    public var marksDroppableFrames = false
    /// The software decoder's output mode, by name. Nil picks per platform
    /// and content: tvOS tone-maps HDR, everything else stays direct.
    public var softwareDecodeOutputMode: String?
    /// The superseded boolean form of the above. Nil unless a host still sets
    /// it.
    public var softwareDecodeCompressedOutput: Bool?

    // MARK: Measurement

    /// Arm the frame-loss bench for each playback.
    public var runsFrameLossBench = false
    /// Print a per-thread CPU trace beside the decode trace.
    public var tracesDecodeThreads = false
    /// Print AV1 pipeline stage timings, and decode failures, to the console.
    public var profilesAV1Pipeline = false
    /// Log engine and controller lifecycle transitions.
    public var logsPlaybackLifecycle = false
    /// Whether the host is showing its own playback HUD. The engine only
    /// reports this in a diagnostic line; it changes nothing.
    public var hostShowsPlaybackHUD = false

    /// Treat a starving audio renderer as buffering and stop the clock, instead
    /// of letting the picture run on. Read once per engine.
    public var buffersOnAudioStarvation = false

    // MARK: Cache

    /// Cache segmented manifests too. Off because the cache assumes one stable,
    /// seekable resource; it exists to test whether buffering a transcode
    /// helps.
    public var cachesSegmentedManifests = false
    /// Force a small cache cap in megabytes, so the sliding window shows within
    /// a minute. Zero picks from free space.
    public var cacheCapacityMegabytes = 0

    // MARK: Fault injection

    /// Sleep this long while retiring a renderer, mimicking a 4K hardware
    /// decoder, so a handoff must prove it never overlaps old and new
    /// renderers.
    public var rendererRetirementDelaySeconds: Double = 0

    // MARK: Installation

    /// Install the source of these values once, before playback starts. A
    /// closure, because some values are re-read at each playback: an A/B
    /// experiment must not change mid-playback but must change at the next one.
    public static func use(_ source: @escaping @Sendable () -> EngineTuning) {
        installed.withLock { $0 = source }
    }

    /// What the engine reads. Without an installed source, the defaults.
    public static var current: EngineTuning { installed.withLock { $0 }() }

    private static let installed = OSAllocatedUnfairLock<@Sendable () -> EngineTuning>(
        initialState: { EngineTuning() }
    )
}
