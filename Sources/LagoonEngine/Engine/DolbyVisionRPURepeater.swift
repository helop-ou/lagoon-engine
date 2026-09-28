import Foundation

/// Keeps every frame of a native Dolby Vision HEVC stream (profile 5 or 8)
/// carrying an RPU.
///
/// VideoToolbox refuses a frame of a Dolby Vision stream that has no RPU
/// (`-12704`) and every picture that references it (`-12909`). On the Apple
/// TV 4K (3rd gen), a profile 8.1 clip with the RPU missing from one frame in
/// four for ten seconds lost 223 of 755 pictures that way. Such a frame gets
/// the previous frame's RPU, as `DolbyVisionProfileConverter` does for a
/// converted profile 7 stream and as dovi_tool's editor duplicates one.
///
/// A frame that has its own RPU passes through untouched and zero-copy.
/// Demux queue only, except `repeatedCount`.
nonisolated final class DolbyVisionRPURepeater {
    /// Kept across seeks: a stale RPU for a frame is a brief tone-mapping
    /// mismatch, a missing one a lost picture.
    private var lastRPU: Data?
    private let lock = NSLock()
    nonisolated(unsafe) private var repeated = 0

    /// Frames given the previous RPU so far.
    var repeatedCount: Int {
        lock.withLock { repeated }
    }

    /// Profiles whose frames each carry an RPU the decoder reads.
    static func applies(toProfile profile: UInt8) -> Bool {
        profile == 5 || profile == 8
    }

    /// The payload with the previous RPU appended, or nil when the frame has
    /// its own, none has been seen yet, or the payload does not parse.
    func fill(payload: UnsafeRawBufferPointer, lengthSize: Int) -> Data? {
        if let rpu = HEVCNALUnitRewriter.firstUnit(ofType: 62, in: payload, lengthSize: lengthSize) {
            lastRPU = Data(rpu)
            return nil
        }
        guard let lastRPU,
              let base = HEVCNALUnitRewriter.copyIfWellFormed(payload: payload, lengthSize: lengthSize),
              let filled = HEVCNALUnitRewriter.appending(unit: lastRPU, to: base, lengthSize: lengthSize)
        else { return nil }
        lock.withLock { repeated += 1 }
        return filled
    }
}
