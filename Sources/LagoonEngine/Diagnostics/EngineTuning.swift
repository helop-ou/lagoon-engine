import Foundation
import os

/// The engine's tuning knobs, as a host supplies them.
///
/// Every one of these used to be a `UserDefaults.standard` read inside the
/// engine, against keys spelled `debug.…` that belonged to one particular
/// app. A library reaching into its host's preference domain is wrong twice
/// over: it guesses at key names nobody else uses, and it makes behaviour
/// depend on state a consumer cannot see from the API.
///
/// Every value is off, empty or automatic by default, so a host that
/// installs nothing gets ordinary playback with no instrumentation. These
/// are diagnostics and experiments, not product settings — nothing here
/// should be wired to something a viewer can reach.
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
    /// The superseded boolean form of the above. Nil unless a host still
    /// carries the older switch.
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

    /// Treat a starving audio renderer as a buffering condition and stop
    /// the clock, rather than letting the picture run on. Read once when an
    /// engine is created.
    public var buffersOnAudioStarvation = false

    // MARK: Cache

    /// Put the byte cache in front of a segmented manifest as well as a
    /// stable file. Off because a manifest is mutable and the cache assumes
    /// one stable, seekable resource; it exists to answer whether buffering
    /// a transcode helps.
    public var cachesSegmentedManifests = false
    /// Force a small cache cap, in megabytes, so the sliding window becomes
    /// observable within a minute of playback. Zero picks from free space.
    public var cacheCapacityMegabytes = 0

    // MARK: Fault injection

    /// Sleep this long while retiring a renderer, reproducing the seconds
    /// hardware spends on a 4K decoder so a handoff has to prove it never
    /// overlaps the outgoing renderer with its successor.
    public var rendererRetirementDelaySeconds: Double = 0

    // MARK: Installation

    /// Install the source of these values, once, before playback starts.
    ///
    /// A closure rather than a value because several of them are read afresh
    /// at each playback — the Dolby Vision experiment must not change in the
    /// middle of an A/B, but it must change when the next one starts. A host
    /// backing these with live preferences keeps that behaviour; one using a
    /// constant gets a constant.
    public static func use(_ source: @escaping @Sendable () -> EngineTuning) {
        installed.withLock { $0 = source }
    }

    /// What the engine reads. Without an installed source, the defaults.
    public static var current: EngineTuning { installed.withLock { $0 }() }

    private static let installed = OSAllocatedUnfairLock<@Sendable () -> EngineTuning>(
        initialState: { EngineTuning() }
    )
}
