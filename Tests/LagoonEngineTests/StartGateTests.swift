import AVFoundation
import Foundation
import Testing
@testable import LagoonEngine

@Suite("Start gate", .serialized)
struct StartGateTests {
    /// A display mode switch blanks the panel for about three seconds, and a
    /// title that started meanwhile lost them. The host holds the start.
    @MainActor
    @Test func aHeldStartShowsTheFirstPictureAndWaits() async throws {
        let gate = Gate()
        let pictures = PictureCount()
        let engine = try Self.engine(gate: gate, pictures: pictures)
        var started = 0
        engine.onPlaybackStarted = { started += 1 }
        engine.play()

        try await Self.wait { gate.entered == 1 }
        try await Task.sleep(for: .milliseconds(400))
        #expect(pictures.count > 0, "the first picture is up")
        #expect(engine.synchronizerSecondsForTesting < 0.05, "the clock waits: \(engine.synchronizerSecondsForTesting)")
        #expect(engine.isBuffering)
        #expect(started == 0)
        // The first frame is up: the hold is the host's, not the start's.
        #expect(engine.startupPhase == .started)
        let firstFrame = try #require(engine.startupTimeline?.reached[.firstFrame])

        gate.open()
        try await Self.wait { !engine.isBuffering && engine.clockPosition > 0.3 }
        #expect(started == 1)
        #expect(engine.clockPosition > 0.3, "playback started once released")
        #expect(engine.startupTimeline?.reached[.firstFrame] == firstFrame, "timed once, before the hold")

        // Only the first start is held.
        engine.seek(to: 2)
        try await Self.wait { !engine.isBuffering && engine.clockPosition > 2.2 }
        #expect(engine.clockPosition > 2.2)
        #expect(gate.entered == 1)
        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }

    /// The hold must not start the title at the place the viewer left.
    @MainActor
    @Test func aSeekDuringTheHoldStartsAtItsTarget() async throws {
        let gate = Gate()
        let engine = try Self.engine(gate: gate, pictures: PictureCount())
        var anchored = 0
        engine.onSeekReady = { anchored += 1 }
        engine.play()
        try await Self.wait { gate.entered == 1 }

        engine.seek(to: 2)
        gate.open()
        var clocks: [Double] = []
        try await Self.wait {
            clocks.append(engine.clockPosition)
            return !engine.isBuffering && engine.clockPosition > 2.2
        }
        #expect(engine.clockPosition > 2.2)
        #expect(!clocks.contains { (0.1..<1.9).contains($0) }, "never played from the old start: \(clocks.prefix(8))")
        #expect(anchored == 1, "the start the seek replaced never anchored the clock")
        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }

    @MainActor
    @Test func aPauseDuringTheHoldStaysPaused() async throws {
        let gate = Gate()
        let engine = try Self.engine(gate: gate, pictures: PictureCount(), startSeconds: 2)
        engine.play()
        try await Self.wait { gate.entered == 1 }
        // At the start position, or its first picture is not the one shown.
        let held = engine.synchronizerSecondsForTesting
        #expect(abs(held - 2) < 0.05, "the held clock is at the start: \(held)")

        engine.pause()
        gate.open()
        try await Self.wait { !engine.isBuffering }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!engine.isBuffering)
        #expect(engine.isPaused)
        let paused = engine.synchronizerSecondsForTesting
        #expect(abs(paused - 2) < 0.05, "a paused title does not run: \(paused)")
        engine.shutdown()
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(10)))
    }

    /// A host's wait must not keep a dismissed engine, with its demuxer and
    /// renderers, alive until the wait is over.
    @MainActor
    @Test func aDismissedEngineIsReleasedWhileItsGateStillWaits() async throws {
        let gate = Gate()
        var engine: SampleBufferPlayerEngine? = try Self.engine(gate: gate, pictures: PictureCount())
        weak var released = engine
        engine?.play()
        try await Self.wait { gate.entered == 1 }

        engine?.shutdown()
        #expect(await engine?.waitForMediaResourcesToRetire(timeout: .seconds(10)) == true)
        engine = nil
        try await Self.wait { released == nil }
        #expect(released == nil, "the waiting gate holds the engine")
        gate.open()
    }

    @Test func aContainerRateSnapsToTheStandardRateItMeans() {
        let film = 24_000.0 / 1_001
        #expect(DisplayMatchRequest.standardFrameRate(nearest: 23.98) == film)
        #expect(DisplayMatchRequest.standardFrameRate(nearest: 23.976) == film)
        #expect(DisplayMatchRequest.standardFrameRate(nearest: 24) == 24)
        #expect(DisplayMatchRequest.standardFrameRate(nearest: 23.99) == 24)
        #expect(DisplayMatchRequest.standardFrameRate(nearest: 25.000_1) == 25)
        #expect(DisplayMatchRequest.standardFrameRate(nearest: 29.970_03) == 30_000.0 / 1_001)
        #expect(DisplayMatchRequest.standardFrameRate(nearest: 59.94) == 60_000.0 / 1_001)
        #expect(DisplayMatchRequest.standardFrameRate(nearest: 50) == 50)
    }

    @Test func aRateFarFromEveryStandardRateIsLeftAlone() {
        #expect(DisplayMatchRequest.standardFrameRate(nearest: 15) == 15)
        #expect(DisplayMatchRequest.standardFrameRate(nearest: 27) == 27)
        #expect(DisplayMatchRequest.standardFrameRate(nearest: 24.5) == 24.5)
        #expect(DisplayMatchRequest.standardFrameRate(nearest: 120) == 120)
        #expect(DisplayMatchRequest.standardFrameRate(nearest: 0) == 0)
        #expect(DisplayMatchRequest.standardFrameRate(nearest: .nan).isNaN)
    }

    @MainActor
    private static func engine(
        gate: Gate,
        pictures: PictureCount,
        startSeconds: Double = 0
    ) throws -> SampleBufferPlayerEngine {
        let url = try #require(Bundle.module.url(forResource: "av", withExtension: "mp4", subdirectory: "SeekLanding"))
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        engine.rendererVideoObserverForTesting = { if $0 != nil { pictures.add() } }
        engine.startGate = { await gate.wait() }
        engine.prepare(url: url, startSeconds: startSeconds, initialAudioOrdinal: nil)
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        return engine
    }

    private static func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Holds its first caller until opened. Later callers pass.
@MainActor
private final class Gate {
    private(set) var entered = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        entered += 1
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class PictureCount: @unchecked Sendable {
    private let lock = NSLock()
    private var pictures = 0

    var count: Int { lock.withLock { pictures } }

    func add() { lock.withLock { pictures += 1 } }
}
