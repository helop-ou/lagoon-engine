import CoreMedia
import Testing
@testable import LagoonEngine

/// Passthrough audio reaches the renderer on a sample-exact timeline however
/// coarsely the container quantized its timestamps.
struct PassthroughAudioTimelineTests {
    /// AAC in Matroska, which crackled on hardware: 1024-sample frames (21.33
    /// ms) stamped to 1 ms. The chain advances exactly 1024 samples per packet.
    @Test func aacMatroskaTimestampsBecomeSampleExact() throws {
        var timeline = PassthroughAudioTimeline(sampleRate: 48_000, framesPerPacket: 1024)
        for index in 0..<200 {
            // The true position rounded to whole ms, as the mux does. Extra
            // jitter is covered below.
            let containerSeconds = (Double(index) * 1024 / 48_000 * 1000).rounded() / 1000
            let produced = timeline.timing(containerSeconds: containerSeconds)
            let timing = try #require(produced)
            #expect(timing.presentationTimeStamp.value == Int64(index) * 1024)
            #expect(timing.presentationTimeStamp.timescale == 48_000)
            #expect(timing.duration == CMTime(value: 1024, timescale: 48_000))
        }
    }

    /// A real trace had 21/22/23 ms deltas, a millisecond beyond quantization,
    /// and still inside the tolerance.
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

    /// EAC3 at 48 kHz is 32 ms per packet, exact in Matroska, so the rewrite is
    /// a no-op.
    @Test func exactlyRepresentableContainerIsNoOp() {
        var timeline = PassthroughAudioTimeline(sampleRate: 48_000, framesPerPacket: 1536)
        for index in 0..<100 {
            let containerSeconds = Double(index) * 0.032
            let timing = timeline.timing(containerSeconds: containerSeconds)
            #expect(timing?.presentationTimeStamp.value == Int64((containerSeconds * 48_000).rounded()))
        }
    }

    /// One missing packet is a real 21 ms gap and must re-anchor, not become a
    /// permanent desync. Hence a half-packet tolerance, not the LPCM path's 50
    /// ms.
    @Test func missingPacketReanchorsInsteadOfDesyncing() {
        var timeline = PassthroughAudioTimeline(sampleRate: 48_000, framesPerPacket: 1024)
        _ = timeline.timing(containerSeconds: 0)
        // Packet 1 lost in the mux: packet 2 arrives a whole frame late.
        let after = timeline.timing(containerSeconds: 2 * 1024.0 / 48_000)
        #expect(after?.presentationTimeStamp.value == 2048)
    }

    /// HLS segment boundaries can repeat a few AAC preroll packets that overlap
    /// queued audio. They must not pull the chain backward.
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

    /// A jump past the tolerance is a real discontinuity: re-anchor to the
    /// container.
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

    /// A declared packet size shorter than the real cadence re-anchors every
    /// packet rather than drifting without bound.
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

    /// Untimed packets continue the chain; before any anchor they return nil so
    /// the caller keeps its fallback.
    @Test func untimedPacketsContinueChainButCannotAnchor() {
        var timeline = PassthroughAudioTimeline(sampleRate: 48_000, framesPerPacket: 1024)
        #expect(timeline.timing(containerSeconds: nil) == nil)
        _ = timeline.timing(containerSeconds: 1.0)
        let continued = timeline.timing(containerSeconds: nil)
        #expect(continued?.presentationTimeStamp.value == Int64(48_000 + 1024))
    }

    /// reset() forgets the chain, so the next packet anchors fresh: the
    /// seek/flush contract.
    @Test func resetForgetsTheChain() {
        var timeline = PassthroughAudioTimeline(sampleRate: 48_000, framesPerPacket: 1024)
        _ = timeline.timing(containerSeconds: 100)
        timeline.reset()
        #expect(timeline.timing(containerSeconds: nil) == nil)
        let anchored = timeline.timing(containerSeconds: 42)
        #expect(anchored?.presentationTimeStamp.value == Int64(42 * 48_000))
    }
}
