import Foundation

/// Benchmark-only timing storage. Recording is deliberately
/// allocation-light and silent: printing once per frame changes the pipeline
/// being measured. Exact samples are sorted only when the completed bench
/// asks for its summary.
nonisolated final class PipelineStageTimings: @unchecked Sendable {
    /// Enough for more than thirteen minutes at 24 fps while preventing an
    /// accidentally enabled diagnostic from becoming an unbounded leak.
    private static let maximumSamplesPerStage = 20_000

    enum Stage: String, CaseIterable {
        case sendPacket = "send"
        case receiveFrame = "receive"
        case outputInterval = "produceInterval"
        case pixelBufferAllocation = "pixelBufferAlloc"
        case transferOutputBufferAllocation = "transferOutputBufferAlloc"
        case pixelBufferLock = "pixelBufferLock"
        case p010Conversion = "p010"
        case pixelTransfer = "vtTransfer"
        case gpuConversion = "gpu"
        case sampleBufferCreation = "sampleBufferCreate"
    }

    private struct Sample {
        let elapsed: Double
        let milliseconds: Double
    }

    let enabled: Bool
    private let lock = NSLock()
    private var startedAt: Double?
    private var lastOutputAt: Double?
    private var storage: [Stage: [Sample]] = [:]

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func reset(at instant: Double = ProcessInfo.processInfo.systemUptime) {
        guard enabled else { return }
        lock.withLock {
            startedAt = instant
            lastOutputAt = nil
            storage.removeAll(keepingCapacity: true)
        }
    }

    func record(_ stage: Stage, from start: Double, to end: Double) {
        guard enabled, end >= start else { return }
        lock.withLock {
            let origin = startedAt ?? start
            if startedAt == nil { startedAt = origin }
            if storage[stage, default: []].count < Self.maximumSamplesPerStage {
                storage[stage, default: []].append(Sample(
                    elapsed: end - origin,
                    milliseconds: (end - start) * 1_000
                ))
            }
        }
    }

    func recordOutput(at instant: Double) {
        guard enabled else { return }
        lock.withLock {
            let origin = startedAt ?? instant
            if startedAt == nil { startedAt = origin }
            if let lastOutputAt, instant >= lastOutputAt {
                if storage[.outputInterval, default: []].count < Self.maximumSamplesPerStage {
                    storage[.outputInterval, default: []].append(Sample(
                        elapsed: instant - origin,
                        milliseconds: (instant - lastOutputAt) * 1_000
                    ))
                }
            }
            lastOutputAt = instant
        }
    }

    func summaryLines() -> [String] {
        guard enabled else { return [] }
        let snapshot = lock.withLock { storage }
        var lines = Stage.allCases.compactMap { stage -> String? in
            guard let samples = snapshot[stage], !samples.isEmpty else { return nil }
            return Self.summary(label: stage.rawValue, samples: samples)
        }
        let bands: [(String, ClosedRange<Double>)] = [
            ("0-10", 0...10),
            ("20-30", 20...30),
            ("40-50", 40...50),
            ("60-70", 60...70),
        ]
        for (label, range) in bands {
            let fields = [
                Stage.sendPacket,
                .receiveFrame,
                .p010Conversion,
                .pixelTransfer,
                .gpuConversion,
                .outputInterval,
            ]
                .compactMap { stage -> String? in
                    guard let samples = snapshot[stage] else { return nil }
                    let selected = samples.filter { range.contains($0.elapsed) }
                    guard !selected.isEmpty else { return nil }
                    return Self.compactSummary(label: stage.rawValue, samples: selected)
                }
            if !fields.isEmpty {
                lines.append("band=\(label)s " + fields.joined(separator: " "))
            }
        }
        return lines
    }

    private static func summary(label: String, samples: [Sample]) -> String {
        let values = samples.map(\.milliseconds).sorted()
        return String(
            format: "stage=%@ n=%d p50=%.3fms p95=%.3fms p99=%.3fms max=%.3fms",
            label,
            values.count,
            percentile(values, 0.50),
            percentile(values, 0.95),
            percentile(values, 0.99),
            values.last ?? 0
        )
    }

    private static func compactSummary(label: String, samples: [Sample]) -> String {
        let values = samples.map(\.milliseconds).sorted()
        return String(
            format: "%@=%.2f/%.2f/%.2f",
            label,
            percentile(values, 0.50),
            percentile(values, 0.95),
            percentile(values, 0.99)
        )
    }

    private static func percentile(_ sorted: [Double], _ percentile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = max(Int(ceil(percentile * Double(sorted.count))) - 1, 0)
        return sorted[min(rank, sorted.count - 1)]
    }
}

/// Time-weighted samples from the renderer side of the pipeline. A periodic
/// sampler is necessary: checking readiness only when a decoded frame arrives
/// would systematically miss the periods where the producer has nothing to
/// offer.
nonisolated final class RendererPipelineTimings: @unchecked Sendable {
    private static let maximumStateSamples = 20_000
    private static let maximumEnqueueSamples = 20_000
    private static let maximumThermalSamples = 7_200

    private struct StateSample {
        let elapsed: Double
        let ready: Bool
        let renderQueue: Int
        let decodePending: Int
    }

    private struct StateMetrics {
        var duration = 0.0
        var notReady = 0.0
        var renderQueueArea = 0.0
        var decodePendingArea = 0.0
        var producerStarved = 0.0
        var pumpLag = 0.0
        var rendererInternallyBuffered = 0.0
        var downstreamBackpressure = 0.0
        var inputStarved = 0.0
    }

    let enabled: Bool
    private let lock = NSLock()
    private var startedAt: Double?
    private var samples: [StateSample] = []
    private var enqueueMilliseconds: [Double] = []
    private var thermalSamples: [(elapsed: Double, state: String)] = []
    private var lastThermalSecond = -1

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func reset(at instant: Double = ProcessInfo.processInfo.systemUptime) {
        guard enabled else { return }
        lock.withLock {
            startedAt = instant
            samples.removeAll(keepingCapacity: true)
            enqueueMilliseconds.removeAll(keepingCapacity: true)
            thermalSamples.removeAll(keepingCapacity: true)
            lastThermalSecond = -1
        }
    }

    func sample(
        at instant: Double,
        rendererReady: Bool,
        renderQueue: Int,
        decodePending: Int
    ) {
        guard enabled else { return }
        lock.withLock {
            let origin = startedAt ?? instant
            if startedAt == nil { startedAt = origin }
            let elapsed = instant - origin
            if samples.count < Self.maximumStateSamples {
                samples.append(StateSample(
                    elapsed: elapsed,
                    ready: rendererReady,
                    renderQueue: renderQueue,
                    decodePending: decodePending
                ))
            }
            let second = max(Int(elapsed.rounded(.down)), 0)
            if second != lastThermalSecond {
                lastThermalSecond = second
                if thermalSamples.count < Self.maximumThermalSamples {
                    thermalSamples.append((elapsed, Self.thermalDescription(
                        ProcessInfo.processInfo.thermalState
                    )))
                }
            }
        }
    }

    func recordEnqueue(from start: Double, to end: Double) {
        guard enabled, end >= start else { return }
        lock.withLock {
            if enqueueMilliseconds.count < Self.maximumEnqueueSamples {
                enqueueMilliseconds.append((end - start) * 1_000)
            }
        }
    }

    func summaryLines() -> [String] {
        guard enabled else { return [] }
        let snapshot = lock.withLock {
            (samples, enqueueMilliseconds, thermalSamples)
        }
        guard !snapshot.0.isEmpty else { return [] }
        let state = snapshot.0
        guard let metrics = Self.metrics(for: state) else { return [] }
        let queue = state.map(\.renderQueue)
        let pending = state.map(\.decodePending)
        var lines = [String(
            format: "readySamples=%d measured=%.2fs rendererNotReady=%.2f%% renderQueue=%d/%.2f/%d/%d decodePending=%d/%.2f/%d/%d",
            state.count,
            metrics.duration,
            Self.percent(metrics.notReady, of: metrics.duration),
            queue.min() ?? 0,
            metrics.renderQueueArea / metrics.duration,
            queue.max() ?? 0,
            queue.last ?? 0,
            pending.min() ?? 0,
            metrics.decodePendingArea / metrics.duration,
            pending.max() ?? 0,
            pending.last ?? 0
        )]
        lines.append(String(
            format: "states producerStarved=%.2f%% pumpLag=%.2f%% rendererBuffered=%.2f%% downstreamBackpressure=%.2f%% inputStarved=%.2f%%",
            Self.percent(metrics.producerStarved, of: metrics.duration),
            Self.percent(metrics.pumpLag, of: metrics.duration),
            Self.percent(metrics.rendererInternallyBuffered, of: metrics.duration),
            Self.percent(metrics.downstreamBackpressure, of: metrics.duration),
            Self.percent(metrics.inputStarved, of: metrics.duration)
        ))
        let intervals = zip(state, state.dropFirst())
            .map { ($1.elapsed - $0.elapsed) * 1_000 }
            .filter { $0 >= 0 }
            .sorted()
        if !intervals.isEmpty {
            lines.append(String(
                format: "samplerInterval n=%d p50=%.2fms p95=%.2fms max=%.2fms",
                intervals.count,
                Self.percentile(intervals, 0.50),
                Self.percentile(intervals, 0.95),
                intervals.last ?? 0
            ))
        }
        if !snapshot.1.isEmpty {
            let values = snapshot.1.sorted()
            lines.append(String(
                format: "stage=rendererEnqueue n=%d p50=%.3fms p95=%.3fms p99=%.3fms max=%.3fms",
                values.count,
                Self.percentile(values, 0.50),
                Self.percentile(values, 0.95),
                Self.percentile(values, 0.99),
                values.last ?? 0
            ))
        }
        let thermalPoints = [0.0, 15.0, 30.0, 60.0].compactMap { target -> String? in
            guard let closest = snapshot.2.min(by: {
                abs($0.elapsed - target) < abs($1.elapsed - target)
            }) else { return nil }
            return "t\(Int(target))=\(closest.state)"
        }
        if !thermalPoints.isEmpty {
            lines.append("thermal " + thermalPoints.joined(separator: " "))
        }
        for (label, range) in [
            ("0-10", 0.0...10.0),
            ("20-30", 20.0...30.0),
            ("40-50", 40.0...50.0),
            ("60-70", 60.0...70.0),
        ] {
            guard let selected = Self.metrics(for: state, in: range) else { continue }
            lines.append(String(
                format: "band=%@s rendererNotReady=%.2f%% renderQueueAvg=%.2f decodePendingAvg=%.2f producerStarved=%.2f%% downstreamBackpressure=%.2f%% inputStarved=%.2f%%",
                label,
                Self.percent(selected.notReady, of: selected.duration),
                selected.renderQueueArea / selected.duration,
                selected.decodePendingArea / selected.duration,
                Self.percent(selected.producerStarved, of: selected.duration),
                Self.percent(selected.downstreamBackpressure, of: selected.duration),
                Self.percent(selected.inputStarved, of: selected.duration)
            ))
        }
        return lines
    }

    /// Treat each sample as the state until the next callback. Clipping each
    /// interval to a requested band makes the readiness percentages genuinely
    /// time-weighted even when the sampler itself is delayed.
    private static func metrics(
        for samples: [StateSample],
        in range: ClosedRange<Double>? = nil
    ) -> StateMetrics? {
        guard samples.count > 1 else { return nil }
        var result = StateMetrics()
        for (sample, next) in zip(samples, samples.dropFirst()) {
            let start = max(sample.elapsed, range?.lowerBound ?? sample.elapsed)
            let end = min(next.elapsed, range?.upperBound ?? next.elapsed)
            let duration = end - start
            guard duration > 0 else { continue }
            result.duration += duration
            if !sample.ready { result.notReady += duration }
            result.renderQueueArea += Double(sample.renderQueue) * duration
            result.decodePendingArea += Double(sample.decodePending) * duration
            if sample.ready, sample.renderQueue == 0, sample.decodePending > 0 {
                result.producerStarved += duration
            }
            if sample.ready, sample.renderQueue > 0 {
                result.pumpLag += duration
            }
            if !sample.ready, sample.renderQueue == 0 {
                result.rendererInternallyBuffered += duration
            }
            if !sample.ready, sample.renderQueue > 0 {
                result.downstreamBackpressure += duration
            }
            if sample.renderQueue == 0, sample.decodePending == 0 {
                result.inputStarved += duration
            }
        }
        return result.duration > 0 ? result : nil
    }

    private static func percent(_ value: Double, of total: Double) -> Double {
        total > 0 ? value / total * 100 : 0
    }

    private static func percentile(_ sorted: [Double], _ percentile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = max(Int(ceil(percentile * Double(sorted.count))) - 1, 0)
        return sorted[min(rank, sorted.count - 1)]
    }

    private static func thermalDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
