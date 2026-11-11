import Foundation
import Testing
@testable import LagoonEngine

@Suite("Unreferenced pictures")
struct UnreferencedPictureReaderTests {
    /// Length-prefixed (4 bytes) NAL units, each a header plus a byte of body.
    private static func accessUnit(_ headers: [[UInt8]]) -> Data {
        var data = Data()
        for header in headers {
            let unit = header + [0x80]
            data.append(contentsOf: [0, 0, 0, UInt8(unit.count)] + unit)
        }
        return data
    }

    private static func check(_ reader: UnreferencedPictureReader, _ headers: [[UInt8]]) -> Bool {
        accessUnit(headers).withUnsafeBytes { reader.isUnreferenced($0) }
    }

    @Test func h264PicturesWithNoReferenceIndicatorAreUnreferenced() {
        let reader = UnreferencedPictureReader(codec: .h264, lengthSize: 4)
        // SEI (ref_idc 0) then a non-reference slice (type 1, ref_idc 0).
        #expect(Self.check(reader, [[0x06, 0x00], [0x01, 0x00]]))
        // A reference slice (ref_idc 2) and an IDR are not.
        #expect(!Self.check(reader, [[0x41, 0x00]]))
        #expect(!Self.check(reader, [[0x65, 0x00]]))
        // Parameter sets alone hold no picture.
        #expect(!Self.check(reader, [[0x67, 0x00]]))
    }

    @Test func hevcSubLayerNonReferencePicturesInTheTopLayerAreUnreferenced() {
        let single = UnreferencedPictureReader(codec: .hevc, lengthSize: 4, highestTemporalID: 0)
        // TRAIL_N (0) in temporal layer 0 of a one-layer stream; two slices.
        #expect(Self.check(single, [[0x00, 0x01], [0x00, 0x01]]))
        // TRAIL_R (1) and IDR_W_RADL (19) are referenced.
        #expect(!Self.check(single, [[0x02, 0x01]]))
        #expect(!Self.check(single, [[0x26, 0x01]]))
        // One referenced slice makes the picture referenced.
        #expect(!Self.check(single, [[0x00, 0x01], [0x02, 0x01]]))
        // With two layers, a TRAIL_N in layer 0 may still be referenced by layer 1.
        let layered = UnreferencedPictureReader(codec: .hevc, lengthSize: 4, highestTemporalID: 1)
        #expect(!Self.check(layered, [[0x00, 0x01]]))
        #expect(Self.check(layered, [[0x00, 0x02]]))
    }

    @Test func aPayloadThatDoesNotParseIsNeverSkipped() {
        let reader = UnreferencedPictureReader(codec: .h264, lengthSize: 4)
        let truncated = Data([0, 0, 0, 9, 0x01, 0x00])
        #expect(!truncated.withUnsafeBytes { reader.isUnreferenced($0) })
    }
}
