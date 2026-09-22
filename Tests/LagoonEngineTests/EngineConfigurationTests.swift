import Foundation
import Testing
@testable import LagoonEngine

/// The two seams a host configures the engine through. Both default to
/// "do nothing", which is the whole point: a library that instrumented or
/// reported by default would be making a decision about someone else's
/// users.
/// Serialized: two of these install a process-wide source and restore it
/// afterwards, and a global that other suites can read must not be swapped
/// underneath them.
@Suite("Engine configuration", .serialized)
struct EngineConfigurationTests {
    @Test func tuningIsInertUntilAHostInstallsASource() {
        let untouched = EngineTuning()
        #expect(!untouched.runsFrameLossBench)
        #expect(!untouched.profilesAV1Pipeline)
        #expect(!untouched.tracesDecodeThreads)
        #expect(!untouched.cachesSegmentedManifests)
        #expect(!untouched.stripsDolbyVisionEnhancementLayer)
        #expect(!untouched.marksDroppableFrames)
        #expect(!untouched.buffersOnAudioStarvation)
        #expect(untouched.softwareDecodeOutputMode == nil)
        #expect(untouched.softwareDecodeCompressedOutput == nil)
        #expect(untouched.cacheCapacityMegabytes == 0)
        #expect(untouched.rendererRetirementDelaySeconds == 0)
    }

    @Test func aTuningSourceIsAskedAgainRatherThanSnapshotted() {
        // Several knobs are read afresh at each playback — the Dolby Vision
        // experiment must not change mid-A/B, but it must change when the
        // next one starts. A source installed once has to keep answering.
        let answers = TuningAnswers()
        EngineTuning.use { answers.value }
        defer { EngineTuning.use { EngineTuning() } }

        #expect(!EngineTuning.current.runsFrameLossBench)
        var next = EngineTuning()
        next.runsFrameLossBench = true
        answers.value = next
        #expect(EngineTuning.current.runsFrameLossBench)
        #expect(answers.reads == 2)
    }

    @Test func theVersionIsSomethingAHostCanReportAndParse() {
        // A consumer cannot ask SwiftPM what it resolved, so this constant
        // is the only answer — and a report that cannot be parsed back into
        // a version is no better than none.
        let parts = EngineVersion.current.split(separator: ".")
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { Int($0) != nil })
        #expect(EngineVersion.ffmpeg.hasPrefix("lavf"))
        #expect(EngineVersion.summary == "\(EngineVersion.current) (\(EngineVersion.ffmpeg))")
    }

    @Test func diagnosticsAreDiscardedUntilAHostInstallsASink() {
        let sink = RecordingSink()
        EngineDiagnostics.use(sink)
        defer { EngineDiagnostics.use(DiscardedDiagnostics()) }

        EngineDiagnostics.record(.playbackPlay, ["position": .double(12)])
        let accepted = EngineDiagnostics.report(
            .playbackStall, level: .warning, variant: ["sustained"], fields: [:]
        )

        #expect(sink.events == [.playbackPlay])
        #expect(sink.incidents == [.playbackStall])
        #expect(accepted)
        // And the default really does drop them, rather than buffering.
        #expect(!DiscardedDiagnostics().report(
            .playbackStall, level: .error, variant: [], fields: [:]
        ))
    }
}

private final class TuningAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = EngineTuning()
    private(set) var reads = 0

    var value: EngineTuning {
        get { lock.withLock { reads += 1; return stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class RecordingSink: EngineDiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [EngineDiagnosticEvent] = []
    private var storedIncidents: [EngineDiagnosticIncident] = []

    var events: [EngineDiagnosticEvent] { lock.withLock { storedEvents } }
    var incidents: [EngineDiagnosticIncident] { lock.withLock { storedIncidents } }

    func record(_ event: EngineDiagnosticEvent, _ fields: [String: DiagnosticValue]) {
        lock.withLock { storedEvents.append(event) }
    }

    func report(
        _ incident: EngineDiagnosticIncident,
        level: EngineDiagnosticLevel,
        variant: [String],
        fields: [String: DiagnosticValue]
    ) -> Bool {
        lock.withLock { storedIncidents.append(incident) }
        return true
    }
}
