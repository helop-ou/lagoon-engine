import Testing
@testable import LagoonEngine

/// Polls until `condition` holds. The budget is long because a loaded
/// runner can hold a test for seconds, and it costs nothing when the
/// condition holds early. Running out is recorded here, so a timeout does
/// not read as a wrong value in the expectation that follows.
func waitUntil(
    timeout: Duration = .seconds(30),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Waited \(timeout) for a condition that never held", sourceLocation: sourceLocation)
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

extension SampleBufferPlayerEngine {
    /// Shuts down and expects the demuxer and both renderers gone, so a
    /// test leaves nothing running under the next one.
    func shutdownAndRetire(sourceLocation: SourceLocation = #_sourceLocation) async {
        shutdown()
        await expectRetired(sourceLocation: sourceLocation)
    }

    /// For a test that has to unblock the engine between the two.
    func expectRetired(sourceLocation: SourceLocation = #_sourceLocation) async {
        #expect(
            await waitForMediaResourcesToRetire(timeout: .seconds(30)),
            "the engine's media resources retire",
            sourceLocation: sourceLocation
        )
    }
}

@Suite("Engine waits")
struct EngineWaitsTests {
    @Test func aWaitThatRunsOutSaysSo() async throws {
        await withKnownIssue {
            try await waitUntil(timeout: .milliseconds(60)) { false }
        }
    }

    @Test func aWaitEndsOnceItsConditionHolds() async throws {
        var polls = 0
        try await waitUntil {
            polls += 1
            return polls == 3
        }
        #expect(polls == 3)
    }
}
