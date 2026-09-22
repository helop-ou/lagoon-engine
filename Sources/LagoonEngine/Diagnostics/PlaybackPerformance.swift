import Foundation
import OSLog
import os

/// Instruments/Console category shared by the controller and engine.
/// Signposts stay enabled in Release so the TestFlight-only hardware path
/// can be measured without shipping a separate diagnostics build.
enum PlaybackPerformance {
    nonisolated static let log = OSLog(
        subsystem: "ee.helop.lagoon",
        category: "PlaybackPerformance"
    )
}

/// Resource-level playback accounting. A process footprint by itself cannot
/// distinguish allocator caching from a player that is still decoding after
/// its cover disappeared, so lifecycle benchmarks use both signals.
nonisolated struct PlaybackLifecycleSnapshot: Sendable {
    let liveEngines: Int
    let liveControllers: Int
    let activeDemuxLoops: Int
    let attachedRendererSets: Int
    let enginesCreated: Int
    let enginesDestroyed: Int
    let uncleanEngineDestructions: Int
    let footprintBytes: Int64

    var footprintMB: Double { Double(footprintBytes) / 1_048_576 }
    var mediaResourcesAreQuiescent: Bool {
        activeDemuxLoops == 0 && attachedRendererSets == 0
    }

    var regressionValue: String {
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

/// Thread-safe because demux closure and renderer removal complete on their
/// own queues. It deliberately ships in Release: the Apple TV hardware path
/// is where renderer retirement and jetsam headroom are meaningful.
nonisolated enum PlaybackLifecycleDiagnostics {
    private static let state = State()

    static func controllerCreated(_ id: UUID) {
        state.controllerCreated(id)
        emit("controller-created", id)
    }
    static func controllerDestroyed(_ id: UUID) {
        state.controllerDestroyed(id)
        emit("controller-destroyed", id)
    }
    static func engineCreated(_ id: UUID) {
        state.engineCreated(id)
        emit("engine-created", id)
    }
    static func engineShutdownStarted(_ id: UUID) {
        state.engineShutdownStarted(id)
        emit("shutdown-started", id)
    }
    static func engineDestroyed(_ id: UUID) {
        state.engineDestroyed(id)
        emit("engine-destroyed", id)
    }
    static func demuxStarted(_ id: UUID) {
        state.demuxStarted(id)
        emit("demux-started", id)
    }
    static func demuxEnded(_ id: UUID) {
        state.demuxEnded(id)
        emit("demux-ended", id)
    }
    static func renderersAttached(_ id: UUID) {
        state.renderersAttached(id)
        emit("renderers-attached", id)
    }
    static func renderersDetached(_ id: UUID) {
        state.renderersDetached(id)
        emit("renderers-detached", id)
    }

    static func snapshot() -> PlaybackLifecycleSnapshot {
        state.snapshot(memory: .current())
    }

    /// Starting a replacement player while the previous demuxer or renderer
    /// set is retiring recreates the exact playback → Settings → replay
    /// resource overlap that this diagnostic tracks. The wait is bounded so
    /// a broken AVFoundation callback can be measured without deadlocking UI.
    static func waitForMediaResourcesToRetire(
        timeout: Duration = .seconds(3)
    ) async -> Bool {
        await waitForMediaResourcesToRetire(engineID: nil, timeout: timeout)
    }

    /// Handoffs care about the engine they just stopped, not an unrelated
    /// diagnostic probe. Waiting by identity also lets the controller retain
    /// the old engine until both its demux loop and asynchronous renderer
    /// removals have completed.
    static func waitForMediaResourcesToRetire(
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
        // `debug.playbackLifecycleLog`: the same events the signpost carries,
        // on stdout, because signposts do not reach `simctl launch --console`
        // and renderer retirement is exactly what needs watching there.
        if UserDefaults.standard.bool(forKey: "debug.playbackLifecycleLog") {
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
        // Do not clear demux/renderer membership here. Renderer removal is
        // intentionally asynchronous and can outlive the lightweight Swift
        // engine object; its real AVFoundation completion must balance the
        // counter or the lifecycle benchmark should fail visibly.
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

/// App memory at a point in time. Playback is the only place where a slow
/// leak is invisible until it is fatal: jetsam kills for `per-process-limit`
/// leave a JetsamEvent report, not a crash trace, so nothing in the signpost
/// stream explains the disappearance. Sampling it alongside the other
/// playback metrics makes the climb obvious while it is still harmless.
nonisolated struct MemorySnapshot {
    /// What jetsam weighs against the per-process limit.
    let footprintBytes: Int64
    /// Headroom left before that limit; 0 when the platform won't report it.
    let availableBytes: Int

    var footprintMB: Double { Double(footprintBytes) / 1_048_576 }
    var availableMB: Double { Double(availableBytes) / 1_048_576 }

    static func current() -> MemorySnapshot {
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

/// The storage cost of a decoded 4:2:0 surface. Core Video's NV12 output is
/// 1.5 bytes per pixel; P010 stores each 10-bit component in a 16-bit word,
/// so it is 3 bytes per pixel. This is an estimate of Lagoon's visible queue,
/// not VideoToolbox or renderer-private surfaces; the controlled bench peak
/// above is the authority for the process ceiling.
nonisolated enum DecodedFrameMemory {
    static func bytesPer420Frame(width: Int, height: Int, bitDepth: Int) -> Int64 {
        guard width > 0, height > 0 else { return 0 }
        let samples = Int64(width) * Int64(height) * 3 / 2
        return samples * (bitDepth > 8 ? 2 : 1)
    }

    static func queuedBytes(width: Int, height: Int, bitDepth: Int, frames: Int) -> Int64 {
        bytesPer420Frame(width: width, height: height, bitDepth: bitDepth)
            * Int64(max(frames, 0))
    }
}

nonisolated struct VideoPerformanceSnapshot {
    let totalFrames: Int
    let droppedFrames: Int
    let corruptedFrames: Int
    /// Frames shown via the power-efficient direct path that bypasses UI
    /// compositing ("optimized/detached mode"). The ratio of this to
    /// `totalFrames` is the measurable answer to "is our video being
    /// composited with UI every frame?".
    let optimizedCompositingFrames: Int
    /// Apple's own jitter metric: accumulated seconds between prescribed
    /// and actual display times. "Non-zero delays are a sign of playback
    /// jitter and possible loss of A/V sync."
    let accumulatedFrameDelay: Double
}
