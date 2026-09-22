import Foundation
import Testing
@testable import LagoonEngine

/// The two seams a host configures the engine through, both defaulting to "do
/// nothing". Serialized: two tests swap a process-wide source that other suites
/// read.
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
        // Some knobs are re-read at each playback, so an installed source must
        // keep answering.
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
        // SwiftPM cannot tell a consumer what it resolved, so this constant
        // must parse as a version.
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
        // The default drops them rather than buffering.
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
