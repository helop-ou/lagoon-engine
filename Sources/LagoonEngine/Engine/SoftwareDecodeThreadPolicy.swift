import Dispatch
import Foundation

/// How libavcodec is configured for software video decode.
///
/// The worker-count baseline survived measurement on an Apple TV: it stays at
/// the device's five active processors; controlled runs found dav1d auto and
/// six no better, while eight improved median latency but made tail latency
/// and dropped frames worse. The decode queue's scheduling band was never the
/// constraint.
///
/// The thread count is not dav1d's frame-parallelism limit by default. A zero
/// `max_frame_delay` resolves to only `ceil(sqrt(n_threads))`, which is three
/// pictures for Lagoon's five-thread Apple TV configuration. Decode-only runs
/// of two 4K 10-bit streams consistently cut wall time by roughly 25-30%
/// (34-43% more throughput) when the limit matched the worker count. Movies
/// can afford the two extra frames of latency, so AV1 uses all configured
/// workers as its frame-delay ceiling.
nonisolated enum SoftwareDecodeThreadPolicy {
    /// Threads for libavcodec. Production remains explicit so the HUD can
    /// report the requested value; a launch argument can deliberately select
    /// zero to exercise dav1d's own automatic thread selection on hardware.
    ///
    /// A configured zero remains zero after `avcodec_open2`; it proves auto
    /// was requested, not how many worker threads dav1d ultimately created.
    static func resolvedThreadCount(
        explicit: Int? = commandLineThreadCount(),
        activeProcessors: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> Int32 {
        if let explicit {
            return Int32(min(max(explicit, 0), max(activeProcessors * 4, 2)))
        }
        return Int32(max(activeProcessors, 1))
    }

    /// Diagnostic knob with no Settings UI, read from a launch argument:
    /// `-debug.softwareDecodeThreadCount 8`.
    ///
    /// It lives here rather than on the Advanced page because it is for
    /// sweeping from a Mac against a paired Apple TV, not for anyone to set.
    /// It was once "measured" from the HUD and that answer was worthless:
    /// decode cost on this content tracks scene complexity, so a cumulative
    /// average read at a different playback position compares scenes rather
    /// than settings.
    static let threadCountDefaultsKey = "debug.softwareDecodeThreadCount"

    /// Maximum pictures dav1d may keep in flight. Production matches the
    /// explicit worker count instead of taking dav1d's lower square-root
    /// default. A launch argument can still select zero (dav1d auto) or a
    /// smaller value for controlled comparisons:
    /// `-debug.softwareDecodeMaxFrameDelay 3`.
    static func resolvedMaxFrameDelay(
        explicit: Int? = commandLineMaxFrameDelay(),
        threadCount: Int32
    ) -> Int64 {
        if let explicit {
            // dav1d clamps frame contexts to its worker count. Reflect that
            // useful limit in our requested/reported value when the worker
            // count is explicit; with thread_count=0, 256 is dav1d's public
            // hard ceiling and the library resolves the actual core count.
            let upperBound = threadCount > 0 ? Int(threadCount) : 256
            return Int64(min(max(explicit, 0), upperBound))
        }
        return Int64(max(threadCount, 0))
    }

    static let maxFrameDelayDefaultsKey = "debug.softwareDecodeMaxFrameDelay"

    private static func commandLineThreadCount() -> Int? {
        commandLineInteger(forKey: threadCountDefaultsKey)
    }

    private static func commandLineMaxFrameDelay() -> Int? {
        commandLineInteger(forKey: maxFrameDelayDefaultsKey)
    }

    /// Reads NSArgumentDomain directly from the process arguments. Looking up
    /// these keys in `UserDefaults.standard` is unsafe: older Lagoon builds
    /// persisted the thread-count experiment, so an upgraded device can still
    /// carry an obsolete value such as eight in its application domain.
    static func commandLineInteger(
        forKey key: String,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Int? {
        let acceptedKeys = ["-\(key)", "--\(key)"]
        guard let keyIndex = arguments.lastIndex(where: acceptedKeys.contains),
              arguments.indices.contains(keyIndex + 1) else {
            return nil
        }
        return Int(arguments[keyIndex + 1])
    }

    static func commandLineString(
        forKey key: String,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> String? {
        let acceptedKeys = ["-\(key)", "--\(key)"]
        guard let keyIndex = arguments.lastIndex(where: acceptedKeys.contains),
              arguments.indices.contains(keyIndex + 1) else {
            return nil
        }
        return arguments[keyIndex + 1]
    }
}
