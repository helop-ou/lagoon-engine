import Testing
@testable import LagoonEngine

@Suite("Playback seek callbacks")
@MainActor
struct PlayerSeekReentrancyTests {
    @Test func anInstantSkipFromASeekRemainsThePendingPosition() {
        let engine = SampleBufferPlayerEngine()
        defer { engine.shutdown() }
        var reportedPositions: [Double] = []
        engine.onTimeAdvanced = { [weak engine] position, _ in
            reportedPositions.append(position)
            if position == 12 { engine?.seek(to: 70) }
        }

        // An instant intro skip can synchronously request another seek
        // when the viewer scrubs into its segment.
        engine.seek(to: 12)

        #expect(reportedPositions == [12, 70])
        #expect(engine.timePosition == 70)
        #expect(engine.clockPosition == 70)
    }
}
