import Foundation
import OSLog
import os

/// Instruments/Console category for playback. Signposts stay on in Release so
/// hardware builds can be measured without a diagnostics build.
public enum PlaybackPerformance {
    nonisolated static public let log = OSLog(
        subsystem: "ee.helop.lagoon",
        category: "PlaybackPerformance"
    )
}

/// Resource-level playback accounting. Footprint alone cannot tell allocator
/// caching from a player still decoding after it closed, so benchmarks use
/// both.
nonisolated public struct PlaybackLifecycleSnapshot: Sendable {
    public let liveEngines: Int
    public let liveControllers: Int
    public let activeDemuxLoops: Int
    public let attachedRendererSets: Int
    public let enginesCreated: Int
    public let enginesDestroyed: Int
    public let uncleanEngineDestructions: Int
    public let footprintBytes: Int64

    public var footprintMB: Double { Double(footprintBytes) / 1_048_576 }
    public var mediaResourcesAreQuiescent: Bool {
        activeDemuxLoops == 0 && attachedRendererSets == 0
    }

    public var regressionValue: String {
        [
            "engines=\(liveEngines)",
            "controllers=\(liveControllers)",
            "demux=\(activeDemuxLoops)",
            "renderers=\(attachedRendererSets)",
            "created=\(enginesCreated)",
            "destroyed=\(enginesDestroyed)",
            "unclean=\(uncleanEngineDestructions)",
            String(format: "memoryMB=%.1f", footprintMB),
        ].joined(separator: " ")
    }
}

/// Thread-safe because demux close and renderer removal finish on their own
/// queues. Ships in Release: renderer retirement and jetsam headroom only mean
/// something on Apple TV hardware.
public nonisolated enum PlaybackLifecycleDiagnostics {
    private static let state = State()

    static public func controllerCreated(_ id: UUID) {
        state.controllerCreated(id)
        emit("controller-created", id)
    }
    static public func controllerDestroyed(_ id: UUID) {
        state.controllerDestroyed(id)
        emit("controller-destroyed", id)
    }
    static public func engineCreated(_ id: UUID) {
        state.engineCreated(id)
        emit("engine-created", id)
    }
    static public func engineShutdownStarted(_ id: UUID) {
        state.engineShutdownStarted(id)
        emit("shutdown-started", id)
    }
    static public func engineDestroyed(_ id: UUID) {
        state.engineDestroyed(id)
        emit("engine-destroyed", id)
    }
    static public func demuxStarted(_ id: UUID) {
        state.demuxStarted(id)
        emit("demux-started", id)
    }
    static public func demuxEnded(_ id: UUID) {
        state.demuxEnded(id)
        emit("demux-ended", id)
    }
    static public func renderersAttached(_ id: UUID) {
        state.renderersAttached(id)
        emit("renderers-attached", id)
    }
    static public func renderersDetached(_ id: UUID) {
        state.renderersDetached(id)
        emit("renderers-detached", id)
    }

    static public func snapshot() -> PlaybackLifecycleSnapshot {
        state.snapshot(memory: .current())
    }

    /// A replacement player must not start while the previous demuxer or
    /// renderers are retiring. The wait is bounded so a broken AVFoundation
    /// callback cannot deadlock the UI.
    static public func waitForMediaResourcesToRetire(
        timeout: Duration = .seconds(3)
    ) async -> Bool {
        await waitForMediaResourcesToRetire(engineID: nil, timeout: timeout)
    }

    /// Waits for one engine by identity, so a handoff waits for the engine it
    /// stopped and can retain it until demux and renderer removal complete.
    static public func waitForMediaResourcesToRetire(
        for engineID: UUID,
        timeout: Duration = .seconds(15)
    ) async -> Bool {
        await waitForMediaResourcesToRetire(engineID: engineID, timeout: timeout)
    }

    private static func waitForMediaResourcesToRetire(
        engineID: UUID?,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if state.mediaResourcesAreQuiescent(for: engineID) { return true }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return state.mediaResourcesAreQuiescent(for: engineID)
    }

    private static func emit(_ event: String, _ id: UUID? = nil) {
        let value = snapshot()
        #if DEBUG
        // The signpost events on stdout too, because signposts do not reach
        // `simctl launch --console`.
        if EngineTuning.current.logsPlaybackLifecycle {
            let who = id.map { String($0.uuidString.prefix(4)) } ?? "----"
            print("Lifecycle \(event) id=\(who) \(value.regressionValue)")
        }
        #endif
        os_signpost(
            .event,
            log: PlaybackPerformance.log,
            name: "Playback Lifecycle",
            "event=%{public}s engines=%{public}d controllers=%{public}d demux=%{public}d renderers=%{public}d unclean=%{public}d footprintMB=%{public}.1f",
            event,
            value.liveEngines,
            value.liveControllers,
            value.activeDemuxLoops,
            value.attachedRendererSets,
            value.uncleanEngineDestructions,
            value.footprintMB
        )
    }
}

nonisolated private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var controllers: Set<UUID> = []
    private var engines: Set<UUID> = []
    private var shuttingDownEngines: Set<UUID> = []
    private var demuxLoops: Set<UUID> = []
    private var rendererSets: Set<UUID> = []
    private var created = 0
    private var destroyed = 0
    private var uncleanDestructions = 0

    func mediaResourcesAreQuiescent(for engineID: UUID?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let engineID {
            return !demuxLoops.contains(engineID) && !rendererSets.contains(engineID)
        }
        return demuxLoops.isEmpty && rendererSets.isEmpty
    }

    func controllerCreated(_ id: UUID) {
        lock.lock()
        controllers.insert(id)
        lock.unlock()
    }

    func controllerDestroyed(_ id: UUID) {
        lock.lock()
        controllers.remove(id)
        lock.unlock()
    }

    func engineCreated(_ id: UUID) {
        lock.lock()
        if engines.insert(id).inserted { created += 1 }
        lock.unlock()
    }

    func engineShutdownStarted(_ id: UUID) {
        lock.lock()
        shuttingDownEngines.insert(id)
        lock.unlock()
    }

    func engineDestroyed(_ id: UUID) {
        lock.lock()
        if engines.remove(id) != nil { destroyed += 1 }
        if !shuttingDownEngines.contains(id) {
            uncleanDestructions += 1
        }
        shuttingDownEngines.remove(id)
        // Keep demux/renderer membership. Renderer removal is asynchronous and
        // can outlive the engine; its AVFoundation completion must balance the
        // counter, or the benchmark should fail visibly.
        lock.unlock()
    }

    func demuxStarted(_ id: UUID) {
        lock.lock()
        demuxLoops.insert(id)
        lock.unlock()
    }

    func demuxEnded(_ id: UUID) {
        lock.lock()
        demuxLoops.remove(id)
        lock.unlock()
    }

    func renderersAttached(_ id: UUID) {
        lock.lock()
        rendererSets.insert(id)
        lock.unlock()
    }

    func renderersDetached(_ id: UUID) {
        lock.lock()
        rendererSets.remove(id)
        lock.unlock()
    }

    func snapshot(memory: MemorySnapshot) -> PlaybackLifecycleSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return PlaybackLifecycleSnapshot(
            liveEngines: engines.count,
            liveControllers: controllers.count,
            activeDemuxLoops: demuxLoops.count,
            attachedRendererSets: rendererSets.count,
            enginesCreated: created,
            enginesDestroyed: destroyed,
            uncleanEngineDestructions: uncleanDestructions,
            footprintBytes: memory.footprintBytes
        )
    }
}

/// App memory at a point in time. A jetsam `per-process-limit` kill leaves no
/// crash trace, so sampling memory with playback metrics shows a slow leak
/// while it is still harmless.
public nonisolated struct MemorySnapshot {
    /// What jetsam weighs against the per-process limit.
    public let footprintBytes: Int64
    /// Headroom left before that limit; 0 when the platform won't report it.
    public let availableBytes: Int

    public var footprintMB: Double { Double(footprintBytes) / 1_048_576 }
    public var availableMB: Double { Double(availableBytes) / 1_048_576 }

    static public func current() -> MemorySnapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return MemorySnapshot(
            footprintBytes: status == KERN_SUCCESS ? Int64(info.phys_footprint) : 0,
            availableBytes: os_proc_available_memory()
        )
    }
}

/// Estimated storage of a decoded 4:2:0 surface: NV12 is 1.5 bytes per pixel,
/// P010 3. Covers the engine's visible queue only, not VideoToolbox or renderer
/// surfaces; the bench peak is the authority on the process ceiling.
public nonisolated enum DecodedFrameMemory {
    static public func bytesPer420Frame(width: Int, height: Int, bitDepth: Int) -> Int64 {
        guard width > 0, height > 0 else { return 0 }
        let samples = Int64(width) * Int64(height) * 3 / 2
        return samples * (bitDepth > 8 ? 2 : 1)
    }

    static public func queuedBytes(width: Int, height: Int, bitDepth: Int, frames: Int) -> Int64 {
        bytesPer420Frame(width: width, height: height, bitDepth: bitDepth)
            * Int64(max(frames, 0))
    }
}

nonisolated public struct VideoPerformanceSnapshot {
    public let totalFrames: Int
    public let droppedFrames: Int
    public let corruptedFrames: Int
    /// Frames shown on the direct path that bypasses UI compositing. Compare
    /// with `totalFrames` to see whether video is composited every frame.
    public let optimizedCompositingFrames: Int
    /// Apple's jitter metric: accumulated seconds between prescribed and actual
    /// display times.
    public let accumulatedFrameDelay: Double
}
