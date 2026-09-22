import Darwin
import Foundation

/// Where the CPU goes while software video decodes.
///
/// A software decoder shares six cores with everything else the process and
/// the system do, so "dav1d is slower in the app than in a bare test process"
/// has to be split into *who else is running*. This samples every thread in
/// the process through `thread_info(THREAD_EXTENDED_INFO)` — name, CPU time
/// and scheduling priority — and every core's load through
/// `host_processor_info`, and reports the deltas as one `CPUTrace` line per
/// decode-trace tick. Off unless `-debug.decodeTrace YES`.
nonisolated final class ProcessCPUTrace: @unchecked Sendable {
    static let enabled = UserDefaults.standard.bool(forKey: "debug.decodeTrace")

    /// Unnamed GCD threads are indistinguishable from each other, so the
    /// decode queue tags the thread it last ran on; it is the one thread whose
    /// share matters most, because it blocks inside libavcodec.
    nonisolated(unsafe) private static var decodeThreadID: UInt64 = 0
    nonisolated(unsafe) private static var mainThreadID: UInt64 = 0

    static func noteDecodeThread() {
        guard enabled else { return }
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        decodeThreadID = id
    }

    private struct ThreadSample {
        let name: String
        let cpuSeconds: Double
        let priority: Int32
        let currentPriority: Int32
    }

    private var previousThreads: [UInt64: ThreadSample] = [:]
    private var previousCores: [[Int64]] = []
    private var previousInstant = ProcessInfo.processInfo.systemUptime

    func tick() -> String {
        if Thread.isMainThread, Self.mainThreadID == 0 {
            pthread_threadid_np(nil, &Self.mainThreadID)
        }
        let now = ProcessInfo.processInfo.systemUptime
        let interval = now - previousInstant
        previousInstant = now

        let threads = Self.sampleThreads()
        var groups: [String: (cpu: Double, count: Int, priority: Int32, current: Int32)] = [:]
        var processCPU = 0.0
        for (id, sample) in threads {
            let delta = sample.cpuSeconds - (previousThreads[id]?.cpuSeconds ?? sample.cpuSeconds)
            processCPU += delta
            var group = groups[sample.name] ?? (0, 0, sample.priority, sample.currentPriority)
            group.cpu += delta
            group.count += 1
            groups[sample.name] = group
        }
        previousThreads = threads

        var line = String(format: "CPUTrace dt=%.2fs", interval)
        let cores = Self.sampleCores()
        if !cores.isEmpty, cores.count == previousCores.count {
            let busy = zip(cores, previousCores).map { current, previous -> String in
                let total = zip(current, previous).reduce(0) { $0 + ($1.0 - $1.1) }
                let idle = current[Int(CPU_STATE_IDLE)] - previous[Int(CPU_STATE_IDLE)]
                guard total > 0 else { return "-" }
                return String(100 - Int(idle * 100 / total))
            }
            line += " coresBusy%=" + busy.joined(separator: "/")
        }
        previousCores = cores
        line += String(format: " procMs=%.0f", processCPU * 1000)
        for (name, group) in groups.sorted(by: { $0.value.cpu > $1.value.cpu }).prefix(9) {
            guard group.cpu * 1000 >= 1 else { continue }
            line += String(
                format: " %@=%.0fms(x%d pri%d/%d)",
                name, group.cpu * 1000, group.count, group.priority, group.current
            )
        }
        return line
    }

    private static func sampleThreads() -> [UInt64: ThreadSample] {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [:] }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: list),
                vm_size_t(count) * vm_size_t(MemoryLayout<thread_t>.stride)
            )
        }
        var samples: [UInt64: ThreadSample] = [:]
        for index in 0..<Int(count) {
            let thread = list[index]
            defer { mach_port_deallocate(mach_task_self_, thread) }
            var identifier = thread_identifier_info()
            var identifierCount = mach_msg_type_number_t(
                MemoryLayout<thread_identifier_info>.size / MemoryLayout<integer_t>.size
            )
            let identified = withUnsafeMutablePointer(to: &identifier) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(identifierCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identifierCount)
                }
            }
            guard identified == KERN_SUCCESS else { continue }
            var extended = thread_extended_info()
            var extendedCount = mach_msg_type_number_t(
                MemoryLayout<thread_extended_info>.size / MemoryLayout<integer_t>.size
            )
            let described = withUnsafeMutablePointer(to: &extended) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(extendedCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &extendedCount)
                }
            }
            guard described == KERN_SUCCESS else { continue }
            var name = withUnsafeBytes(of: &extended.pth_name) { raw -> String in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if identifier.thread_id == decodeThreadID {
                name = "videodecode-q"
            } else if identifier.thread_id == mainThreadID {
                name = "main"
            } else if name.isEmpty {
                // GCD workers carry no name. Reading their queue through the
                // debugger slot the kernel exposes was tried and retained a
                // dead queue; the answer it gave (the pump queue) is in
                // docs/playback.md, and the shipping fix removed that load.
                name = "unnamed"
            }
            samples[identifier.thread_id] = ThreadSample(
                name: name,
                cpuSeconds: Double(extended.pth_user_time + extended.pth_system_time) / 1e9,
                priority: extended.pth_priority,
                currentPriority: extended.pth_curpri
            )
        }
        return samples
    }

    private static func sampleCores() -> [[Int64]] {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount
        ) == KERN_SUCCESS, let info else { return [] }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(coreCount)).map { core in
            (0..<states).map { Int64(info[core * states + $0]) }
        }
    }
}

/// Experiment: raise the scheduling class of dav1d's worker threads.
///
/// dav1d creates its pool with plain `pthread_create`, which on Darwin lands
/// in the default (legacy, priority 31) band, below every `.userInitiated`
/// queue in this engine. `-debug.dav1dWorkerQoS userInitiated` (or
/// `userInteractive`) applies a QoS override to every thread named
/// `dav1d-worker` right after libavcodec opens the decoder. Diagnostic only:
/// the override handles are kept for the life of the process.
nonisolated enum Dav1dWorkerQoS {
    static let defaultsKey = "debug.dav1dWorkerQoS"
    nonisolated(unsafe) private static var overrides: [pthread_override_t] = []

    static func applyIfRequested() {
        guard let requested = SoftwareDecodeThreadPolicy.commandLineString(forKey: defaultsKey) else { return }
        let qos: qos_class_t
        switch requested {
        case "userInteractive": qos = QOS_CLASS_USER_INTERACTIVE
        case "userInitiated": qos = QOS_CLASS_USER_INITIATED
        case "default": qos = QOS_CLASS_DEFAULT
        default:
            print("Dav1dWorkerQoS ignored value=\"\(requested)\"")
            return
        }
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: list),
                vm_size_t(count) * vm_size_t(MemoryLayout<thread_t>.stride)
            )
        }
        var applied = 0
        for index in 0..<Int(count) {
            let thread = list[index]
            defer { mach_port_deallocate(mach_task_self_, thread) }
            var extended = thread_extended_info()
            var extendedCount = mach_msg_type_number_t(
                MemoryLayout<thread_extended_info>.size / MemoryLayout<integer_t>.size
            )
            let described = withUnsafeMutablePointer(to: &extended) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(extendedCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &extendedCount)
                }
            }
            guard described == KERN_SUCCESS else { continue }
            let name = withUnsafeBytes(of: &extended.pth_name) { raw -> String in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard name == "dav1d-worker", let pthread = pthread_from_mach_thread_np(thread) else { continue }
            overrides.append(pthread_override_qos_class_start_np(pthread, qos, 0))
            applied += 1
        }
        print("Dav1dWorkerQoS applied=\(applied) qos=\(requested)")
    }
}
