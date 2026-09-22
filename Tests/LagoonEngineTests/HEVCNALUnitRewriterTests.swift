import Foundation
import Testing
@testable import LagoonEngine

/// `HEVCNALUnitRewriter` replaced the strip-only `HEVCEnhancementLayerFilter`:
/// it still knows how to drop the Dolby Vision profile 7
/// enhancement layer (unspec-63) and RPU (unspec-62) wholesale, but it can
/// also walk a length-prefixed access unit applying an arbitrary per-NAL
/// transform — the primitive the P7→8.1 RPU rewrite is built on. These tests
/// are what keeps that honest: only the NALs a transform touches change,
/// every kept byte survives verbatim, and anything that doesn't parse (or
/// can't be re-expressed within the prefix width it was given) passes
/// through untouched or is dropped rather than mangled.
struct HEVCNALUnitRewriterTests {
    /// One length-prefixed NAL unit: 4-byte (or shorter) big-endian length,
    /// then the two HEVC header bytes, then filler.
    private func nal(type: UInt8, payloadBytes: Int, lengthSize: Int = 4, filler: UInt8 = 0xAB) -> Data {
        var data = Data()
        let length = payloadBytes + 2
        for shift in stride(from: (lengthSize - 1) * 8, through: 0, by: -8) {
            data.append(UInt8((length >> shift) & 0xFF))
        }
        data.append(type << 1)
        data.append(0x01) // nuh_temporal_id_plus1
        data.append(contentsOf: repeatElement(filler, count: payloadBytes))
        return data
    }

    /// A length-prefixed NAL unit built from already-encoded unit bytes
    /// (header + payload, no prefix of its own) — used to predict what
    /// `rewrite` writes for a `.replace(_:)` result.
    private func prefixed(_ unit: Data, lengthSize: Int = 4) -> Data {
        var data = Data()
        for shift in stride(from: (lengthSize - 1) * 8, through: 0, by: -8) {
            data.append(UInt8((unit.count >> shift) & 0xFF))
        }
        data.append(unit)
        return data
    }

    private func strip(_ payload: Data, lengthSize: Int = 4) -> Data? {
        payload.withUnsafeBytes { bytes in
            HEVCNALUnitRewriter.strippingEnhancementLayer(from: bytes, lengthSize: lengthSize)
        }
    }

    /// The realistic access unit: parameter sets, SEI, a VCL slice, and
    /// the DoVi RPU (62) + EL (63) interleaved the way P7 remuxes do.
    @Test func stripsOnlyEnhancementLayerAndRPU() {
        let kept = nal(type: 32, payloadBytes: 4) + nal(type: 33, payloadBytes: 6)
            + nal(type: 39, payloadBytes: 10) + nal(type: 1, payloadBytes: 500, filler: 0xCD)
        let payload = nal(type: 32, payloadBytes: 4) + nal(type: 33, payloadBytes: 6)
            + nal(type: 62, payloadBytes: 20)
            + nal(type: 39, payloadBytes: 10) + nal(type: 1, payloadBytes: 500, filler: 0xCD)
            + nal(type: 63, payloadBytes: 3000, filler: 0xEF)
        #expect(strip(payload) == kept)
    }

    @Test func nothingToStripReturnsNilSoZeroCopyStays() {
        let payload = nal(type: 32, payloadBytes: 4) + nal(type: 1, payloadBytes: 100)
        #expect(strip(payload) == nil)
    }

    @Test func entirePayloadStrippableLeavesEmptyData() {
        // Degenerate but well-formed: an AU of nothing but EL. The empty
        // result is the caller's cue to keep behavior sane (the factory
        // rejects zero-size payloads rather than enqueue an empty sample).
        let payload = nal(type: 63, payloadBytes: 10)
        #expect(strip(payload) == Data())
    }

    @Test func truncatedLengthPrefixPassesThroughUntouched() {
        var payload = nal(type: 62, payloadBytes: 10)
        payload.append(contentsOf: [0x00, 0x00]) // half a length prefix
        #expect(strip(payload) == nil)
    }

    @Test func lengthOverrunPassesThroughUntouched() {
        var payload = Data([0x00, 0x00, 0x10, 0x00]) // claims 4096 bytes
        payload.append(62 << 1)
        payload.append(0x01)
        #expect(strip(payload) == nil)
    }

    @Test func zeroLengthNALPassesThroughUntouched() {
        var payload = nal(type: 62, payloadBytes: 5)
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // zero-length unit
        #expect(strip(payload) == nil)
    }

    @Test func honorsSmallerLengthPrefixes() {
        let payload = nal(type: 1, payloadBytes: 40, lengthSize: 2)
            + nal(type: 63, payloadBytes: 60, lengthSize: 2)
        let kept = nal(type: 1, payloadBytes: 40, lengthSize: 2)
        #expect(strip(payload, lengthSize: 2) == kept)
    }

    /// hvcC's lengthSizeMinusOne lives in the low bits of byte 21.
    @Test func nalLengthSizeReadFromHvcC() {
        var hvcc = Data(count: 23)
        hvcc[21] = 0xFF // …| lengthSizeMinusOne = 3
        #expect(HEVCNALUnitRewriter.nalLengthSize(hvcc: hvcc) == 4)
        hvcc[21] = 0xFC | 0x01
        #expect(HEVCNALUnitRewriter.nalLengthSize(hvcc: hvcc) == 2)
        #expect(HEVCNALUnitRewriter.nalLengthSize(hvcc: Data(count: 10)) == nil)
    }

    // MARK: - rewrite(payload:lengthSize:transform:)

    /// The primitive the RPU rewrite is built on: a transform can replace
    /// one unit while everything around it survives untouched, and the
    /// replaced unit gets a length prefix computed from its *new* size.
    @Test func rewriteReplacesOneUnitAndKeepsTheRestWithFreshLengthPrefixes() {
        let before = nal(type: 32, payloadBytes: 4)
        let target = nal(type: 62, payloadBytes: 20)
        let after = nal(type: 1, payloadBytes: 500, filler: 0xCD)
        let payload = before + target + after

        // Deliberately a different length than the unit it replaces, so a
        // stale length prefix (copied rather than recomputed) would be
        // caught by this assertion.
        let replacement = Data([0x7C, 0x01, 0x11, 0x22, 0x33])

        let result = payload.withUnsafeBytes { bytes in
            HEVCNALUnitRewriter.rewrite(payload: bytes, lengthSize: 4) { nalType, _ in
                nalType == 62 ? .replace(replacement) : .keep
            }
        }

        #expect(result == before + prefixed(replacement) + after)
    }

    @Test func rewriteReturnsNilWhenTheTransformKeepsEverything() {
        let payload = nal(type: 32, payloadBytes: 4) + nal(type: 1, payloadBytes: 100)
            + nal(type: 62, payloadBytes: 20)
        let result = payload.withUnsafeBytes { bytes in
            HEVCNALUnitRewriter.rewrite(payload: bytes, lengthSize: 4) { _, _ in .keep }
        }
        #expect(result == nil)
    }

    /// A 1-byte length prefix can express at most 255. A transform handing
    /// back more than that for one unit can't be written without lying
    /// about the unit's length, so the rewrite drops the unit instead of
    /// truncating or overflowing the prefix.
    @Test func rewriteTreatsAReplacementTooLargeForThePrefixAsADrop() {
        let kept = nal(type: 32, payloadBytes: 4, lengthSize: 1)
        let target = nal(type: 62, payloadBytes: 10, lengthSize: 1)
        let payload = kept + target
        let oversized = Data(repeating: 0x11, count: 300)

        let result = payload.withUnsafeBytes { bytes in
            HEVCNALUnitRewriter.rewrite(payload: bytes, lengthSize: 1) { nalType, _ in
                nalType == 62 ? .replace(oversized) : .keep
            }
        }

        #expect(result == kept)
    }

    // MARK: - Parameter sets the container may or may not carry

    /// A well-formed record: 22 bytes of header, numOfArrays, then one
    /// array per parameter-set type.
    private func hvcC(arrays: [(type: UInt8, length: Int)]) -> Data {
        var data = Data(count: 22)
        data[21] = 0xFF // lengthSizeMinusOne = 3
        data.append(UInt8(arrays.count))
        for array in arrays {
            data.append(array.type)             // array_completeness | nal type
            data.append(contentsOf: [0x00, 0x01]) // numNalus = 1
            data.append(UInt8((array.length >> 8) & 0xFF))
            data.append(UInt8(array.length & 0xFF))
            data.append(contentsOf: repeatElement(0xAB, count: array.length))
        }
        return data
    }

    /// The exact 23-byte record from the file that found this: an hvcC whose
    /// header is entirely valid and which declares no parameter sets at all.
    /// The decoder cannot be configured from it, and nothing says so until
    /// VTDecompressionSessionCreate refuses.
    @Test func anEmptyParameterSetListIsRecognised() {
        let empty = Data([
            0x01, 0x02, 0x20, 0x00, 0x00, 0x00, 0x90, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x96, 0xf0, 0x00, 0xfc,
            0xfd, 0xfa, 0xfa, 0x00, 0x00, 0x0f, 0x00,
        ])
        #expect(empty.count == 23)
        #expect(SampleBufferFactory.hevcExtradataCarriesParameterSets(empty) == false)
        // The length prefix is still described correctly, which is what the
        // harvest relies on to walk the packets.
        #expect(HEVCNALUnitRewriter.nalLengthSize(hvcc: empty) == 4)
    }

    @Test func aRecordCarryingSPSAndPPSIsAccepted() {
        let full = hvcC(arrays: [(32, 24), (33, 58), (34, 7)])
        #expect(SampleBufferFactory.hevcExtradataCarriesParameterSets(full))
    }

    /// Both have to be there. A VPS on its own configures nothing.
    @Test func aRecordMissingEitherHalfIsRejected() {
        #expect(SampleBufferFactory.hevcExtradataCarriesParameterSets(hvcC(arrays: [(32, 24)])) == false)
        #expect(SampleBufferFactory.hevcExtradataCarriesParameterSets(
            hvcC(arrays: [(32, 24), (33, 58)])
        ) == false)
        #expect(SampleBufferFactory.hevcExtradataCarriesParameterSets(
            hvcC(arrays: [(33, 58), (34, 7)])
        ))
    }

    /// A record that lies about its own lengths is treated as carrying
    /// nothing rather than read past its end.
    @Test func aTruncatedRecordIsRejectedRatherThanOverread() {
        var truncated = hvcC(arrays: [(32, 24), (33, 58), (34, 7)])
        truncated = truncated.prefix(30)
        #expect(SampleBufferFactory.hevcExtradataCarriesParameterSets(truncated) == false)
        #expect(SampleBufferFactory.hevcExtradataCarriesParameterSets(Data(count: 10)) == false)
        #expect(SampleBufferFactory.hevcExtradataCarriesParameterSets(Data()) == false)
    }
}
