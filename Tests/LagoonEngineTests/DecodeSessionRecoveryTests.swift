import AVFoundation
import Foundation
import Testing
import VideoToolbox
@testable import LagoonEngine

/// A decode session the system takes away is rebuilt with a seek, unless
/// video was suspended before the rebuild ran: locking an iPhone does both
/// in quick succession, and the seek then only cost the audio a second.
/// A seek is read off this engine's buffering, not the global diagnostics,
/// which other suites write to in parallel.
@Suite("Decode session recovery", .serialized)
@MainActor
struct DecodeSessionRecoveryTests {
    @Test func aClaimedRebuildSeeksToTheSamePosition() async throws {
        let (engine, seeks) = try await Self.playingEngine()
        defer { engine.shutdown() }
        engine.absorbVideoSessionFaultForTesting(kVTInvalidSessionErr)
        try await Task.sleep(for: .milliseconds(300))
        #expect(seeks.count == 1)
    }

    @Test func aRebuildClaimedBeforeVideoWasSuspendedDoesNotSeek() async throws {
        let (engine, seeks) = try await Self.playingEngine()
        defer { engine.shutdown() }
        engine.absorbVideoSessionFaultForTesting(kVTInvalidSessionErr)
        // Same turn of the main actor, before the claimed rebuild runs.
        engine.setVideoOutputSuspended(true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(seeks.count == 0)
    }

    private final class SeekCount {
        var count = 0
    }

    /// Playing, with every later turn into buffering counted as a seek.
    private static func playingEngine() async throws -> (SampleBufferPlayerEngine, SeekCount) {
        SampleBufferPlayerEngine.mutesAudioForTesting = true
        let engine = SampleBufferPlayerEngine()
        var started = false
        var failure: String?
        engine.onPlaybackStarted = { started = true }
        engine.onError = { failure = $0.message }
        let url = try #require(Bundle.module.url(forResource: "no-cues", withExtension: "mkv", subdirectory: "UnindexedSeek"))
        engine.prepare(url: url, startSeconds: 0, initialAudioOrdinal: nil)
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())
        engine.play()
        let deadline = ContinuousClock.now + .seconds(30)
        while !started, failure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(failure == nil && started)
        let seeks = SeekCount()
        engine.onBufferingChanged = { buffering in
            if buffering { seeks.count += 1 }
        }
        return (engine, seeks)
    }
}
