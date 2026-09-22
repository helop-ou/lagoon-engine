import Dispatch
import Foundation

/// How libavcodec is configured for software video decode.
///
/// Threads = active processors (five on Apple TV). dav1d auto and six were no
/// better; eight improved median latency but worsened tail latency and drops.
///
/// dav1d's default frame delay is only `ceil(sqrt(threads))`, three pictures
/// at five threads. Matching it to the thread count cut 4K 10-bit decode time
/// by ~25-30%, worth two extra frames of latency.
nonisolated enum SoftwareDecodeThreadPolicy {
    /// Threads for libavcodec. Explicit so the HUD can report it; a launch
    /// argument can select zero (dav1d auto), which still reads as zero after
    /// `avcodec_open2`.
    static func resolvedThreadCount(
        explicit: Int? = commandLineThreadCount(),
        activeProcessors: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> Int32 {
        if let explicit {
            return Int32(min(max(explicit, 0), max(activeProcessors * 4, 2)))
        }
        return Int32(max(activeProcessors, 1))
    }

    /// Launch argument for controlled sweeps: `-debug.softwareDecodeThreadCount 8`.
    /// Never compare settings from the HUD's cumulative average: decode cost
    /// tracks the scene.
    static let threadCountDefaultsKey = "debug.softwareDecodeThreadCount"

    /// Maximum pictures dav1d keeps in flight: the thread count, unless a
    /// launch argument overrides it (`-debug.softwareDecodeMaxFrameDelay 3`).
    static func resolvedMaxFrameDelay(
        explicit: Int? = commandLineMaxFrameDelay(),
        threadCount: Int32
    ) -> Int64 {
        if let explicit {
            // dav1d clamps to its worker count; with thread_count=0 its hard
            // ceiling is 256.
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

    /// Reads the process arguments, not `UserDefaults.standard`: a device can
    /// still carry a stale persisted value for these keys.
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
