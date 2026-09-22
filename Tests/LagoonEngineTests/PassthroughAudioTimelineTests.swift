import CoreMedia
import Testing
@testable import LagoonEngine

/// The audio-crackle fix, pinned down: compressed passthrough audio
/// must reach the renderer on a sample-exact timeline no matter how
/// coarsely the container quantized its timestamps.
struct PassthroughAudioTimelineTests {
    /// AAC in Matroska, the case that crackled on hardware: 1024-sample
    /// frames (21.33 ms) stamped at 1 ms precision. The rewritten chain
    /// must advance by exactly 1024 samples per packet regardless.
    @Test func aacMatroskaTimestampsBecomeSampleExact() throws {
        var timeline = PassthroughAudioTimeline(sampleRate: 48_000, framesPerPacket: 1024)
        for index in 0..<200 {
            // What the mux does: the true position rounded to whole ms
            // (measured muxes wander a further ms on top — covered below).
            let containerSeconds = (Double(index) * 1024 / 48_000 * 1000).rounded() / 1000
            let produced = timeline.timing(containerSeconds: containerSeconds)
            let timing = try #require(produced)
            #expect(timing.presentationTimeStamp.value == Int64(index) * 1024)
            #expect(timing.presentationTimeStamp.timescale == 48_000)
            #expect(timing.duration == CMTime(value: 1024, timescale: 48_000))
        }
    }

    /// The measured real-world trace had deltas of 21/22/23 ms — a full
    /// millisecond beyond quantization. Still inside the tolerance, so the
    /// chain must hold.
    @Test func muxJitterBeyondQuantizationStaysChained() {
        var timeline = PassthroughAudioTimeline(sampleRate: 48_000, framesPerPacket: 1024)
        let deltasMS: [Double] = [21, 21, 22, 23, 21, 20, 21, 22, 23, 21]
        var containerSeconds = 5.0
        for (index, delta) in deltasMS.enumerated() {
            let timing = timeline.timing(containerSeconds: containerSeconds)
            #expect(timing?.presentationTimeStamp.value == 240_000 + Int64(index) * 1024)
            containerSeconds += delta / 1000
        }
    }

    /// EAC3 at 48 kHz is 32 ms per packet — exactly representable in
    /// Matroska's milliseconds, so the rewrite must be a no-op: the chain
    /// and the container agree forever.
    @Test func exactlyRepresentableContainerIsNoOp() {
        var timeline = PassthroughAudioTimeline(sampleRate: 48_000, framesPerPacket: 1536)
        for index in 0..<100 {
            let containerSeconds = Double(index) * 0.032
            let timing = timeline.timing(containerSeconds: containerSeconds)
            #expect(timing?.presentationTimeStamp.value == Int64((containerSeconds * 48_000).rounded()))
        }
    }

    /// One packet missing from the mux is a real 21 ms gap: it must
    /// re-anchor so audio stays in sync with the container, not be
    /// smoothed into a permanent desync — the reason the tolerance is
    /// half a packet rather than the LPCM path's 50 ms.
    @Test func missingPacketReanchorsInsteadOfDesyncing() {
        var timeline = PassthroughAudioTimeline(sampleRate: 48_000, framesPerPacket: 1024)
        _ = timeline.timing(containerSeconds: 0)
        // Packet 1 lost in the mux: packet 2 arrives a whole frame late.
        let after = timeline.timing(containerSeconds: 2 * 1024.0 / 48_000)
        #expect(after?.presentationTimeStamp.value == 2048)
    }

    /// HLS segment boundaries can carry a short run of AAC preroll packets
    /// whose timestamps overlap audio already queued. They must not pull the
    /// sample-exact chain backward; playback resumes on the same chain once
    /// the container catches up.
    @Test func overlappingHLSBoundaryPacketsAreDroppedWithoutMovingTheChain() throws {
        var timeline = PassthroughAudioTimeline(sampleRate: 48_000, framesPerPacket: 1024)
        _ = timeline.timing(containerSeconds: 30.997333)
        _ = timeline.timing(containerSeconds: 31.018667)

        #expect(timeline.timing(containerSeconds: 31.018688) == nil)
        #expect(timeline.lastPacketWasOverlapping)
        #expect(timeline.timing(containerSeconds: 31.018708) == nil)
        #expect(timeline.lastPacketWasOverlapping)

        let produced = timeline.timing(containerSeconds: 31.048)
        let resumed = try #require(produced)
        #expect(!timeline.lastPacketWasOverlapping)
        #expect(resumed.presentationTimeStamp.value == 1_489_920)
        #expect(resumed.presentationTimeStamp.timescale == 48_000)
    }

    /// A jump past the gap tolerance is a real discontinuity (mid-stream
    /// seek, source gap): the chain must re-anchor to the container, not
    /// paper over it.
    @Test func realGapReanchorsToContainer() {
        var timeline = PassthroughAudioTimeline(sampleRate: 48_000, framesPerPacket: 1024)
        _ = timeline.timing(containerSeconds: 0)
        _ = timeline.timing(containerSeconds: 0.021)
        let jumped = timeline.timing(containerSeconds: 7.5)
        #expect(jumped?.presentationTimeStamp.value == Int64((7.5 * 48_000).rounded()))
        // And the chain continues from the new anchor.
        let next = timeline.timing(containerSeconds: 7.5 + 1024.0 / 48_000)
        #expect(next?.presentationTimeStamp.value == Int64((7.5 * 48_000).rounded()) + 1024)
    }

    /// If the declared packet size is shorter than the stream's real cadence,
    /// the container disagrees beyond tolerance on every packet and each one
    /// re-anchors instead of accumulating unbounded drift.
    @Test func wrongFramesPerPacketFallsBackToContainerStamps() throws {
        // Assume 1024 but the stream really advances 2048 per packet.
        var timeline = PassthroughAudioTimeline(sampleRate: 48_000, framesPerPacket: 1024)
        for index in 0..<50 {
            let containerSeconds = Double(index) * 2048 / 48_000
            let produced = timeline.timing(containerSeconds: containerSeconds)
            let timing = try #require(produced)
            let error = abs(timing.presentationTimeStamp.seconds - containerSeconds)
            #expect(error < 0.022, "packet \(index) drifted \(error)s from the container")
        }
    }

    /// Packets without a container stamp continue the chain; before any
    /// anchor exists they return nil so the caller keeps its fallback.
    @Test func untimedPacketsContinueChainButCannotAnchor() {
        var timeline = PassthroughAudioTimeline(sampleRate: 48_000, framesPerPacket: 1024)
        #expect(timeline.timing(containerSeconds: nil) == nil)
        _ = timeline.timing(containerSeconds: 1.0)
        let continued = timeline.timing(containerSeconds: nil)
        #expect(continued?.presentationTimeStamp.value == Int64(48_000 + 1024))
    }

    /// reset() forgets the chain: the next packet anchors fresh, exactly
    /// like the first ever packet — the seek/flush contract.
    @Test func resetForgetsTheChain() {
        var timeline = PassthroughAudioTimeline(sampleRate: 48_000, framesPerPacket: 1024)
        _ = timeline.timing(containerSeconds: 100)
        timeline.reset()
        #expect(timeline.timing(containerSeconds: nil) == nil)
        let anchored = timeline.timing(containerSeconds: 42)
        #expect(anchored?.presentationTimeStamp.value == Int64(42 * 48_000))
    }
}
