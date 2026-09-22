import CoreMedia

/// Snaps passthrough audio timestamps onto a sample-exact timeline.
///
/// Matroska stamps at 1 ms, but an AAC frame is 21.33 ms at 48 kHz. Trusting
/// each pts gives the renderer a discontinuity on nearly every buffer, heard
/// as steady crackle.
///
/// Anchors once, then advances exactly `framesPerPacket` per packet. Forward
/// gaps re-anchor, overlapping packets are rejected, seek and flush reset.
nonisolated struct PassthroughAudioTimeline {
    let sampleRate: Int32
    let framesPerPacket: Int64
    /// Half a packet: above quantization error (≤ ~2 ms), below a missing
    /// packet, which must re-anchor or audio stays a packet out of sync.
    /// (The LPCM path's fixed 50 ms would swallow a missing packet.)
    private let gapTolerance: Double
    /// Next packet's position in samples; nil before the first packet.
    private var nextSampleTime: Int64?
    /// Tells a rejected overlap apart from the nil before the first timestamp.
    private(set) var lastPacketWasOverlapping = false
    /// How far behind the chain the last rejected packet sat, in seconds.
    /// Separates a boundary repeat from a real backward jump being muted.
    private(set) var lastOverlapSeconds: Double = 0

    var packetSeconds: Double { Double(framesPerPacket) / Double(sampleRate) }

    public init(sampleRate: Int32, framesPerPacket: Int) {
        self.sampleRate = max(sampleRate, 1)
        self.framesPerPacket = Int64(max(framesPerPacket, 1))
        gapTolerance = Double(self.framesPerPacket) / Double(self.sampleRate) / 2
    }

    /// Seek or flush: the next packet re-anchors.
    mutating func reset() {
        nextSampleTime = nil
        lastPacketWasOverlapping = false
    }

    /// Sample-exact timing for the next packet. A packet without a pts
    /// continues the chain, or returns nil before any anchor.
    mutating func timing(containerSeconds: Double?) -> CMSampleTimingInfo? {
        lastPacketWasOverlapping = false
        var sampleTime: Int64
        if let expected = nextSampleTime {
            sampleTime = expected
            if let containerSeconds {
                let delta = containerSeconds - Double(expected) / Double(sampleRate)
                if delta < -gapTolerance {
                    // Segmented AAC can repeat boundary packets inside audio
                    // already queued. Re-anchoring back causes an audible cut
                    // on tvOS, so reject it; a real seek has called reset().
                    lastPacketWasOverlapping = true
                    lastOverlapSeconds = -delta
                    return nil
                }
                if delta > gapTolerance {
                    sampleTime = Int64((containerSeconds * Double(sampleRate)).rounded())
                }
            }
        } else if let containerSeconds {
            sampleTime = Int64((containerSeconds * Double(sampleRate)).rounded())
        } else {
            return nil
        }
        nextSampleTime = sampleTime + framesPerPacket
        return CMSampleTimingInfo(
            duration: CMTime(value: framesPerPacket, timescale: sampleRate),
            presentationTimeStamp: CMTime(value: sampleTime, timescale: sampleRate),
            decodeTimeStamp: .invalid
        )
    }
}
