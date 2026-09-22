import Foundation
import Testing
@testable import LagoonEngine

/// A plane as a decoder hands it over: `height` rows of `width` bytes at a
/// wider stride, so ignoring the stride fails here.
private struct TestPlane {
    let width: Int
    let height: Int
    let stride: Int
    var bytes: [UInt8]

    init(width: Int, height: Int, stride: Int? = nil, value: (Int, Int) -> UInt8) {
        self.width = width
        self.height = height
        self.stride = stride ?? (width + 16)
        bytes = [UInt8](repeating: 0, count: self.stride * height)
        for row in 0..<height {
            for column in 0..<width {
                bytes[row * self.stride + column] = value(row, column)
            }
        }
    }

    subscript(row: Int, column: Int) -> UInt8 { bytes[row * stride + column] }

    mutating func deinterlace(componentStride: Int = 1, keepingTopField: Bool) {
        bytes.withUnsafeMutableBufferPointer { buffer in
            Deinterlacer.plane(
                base: buffer.baseAddress!,
                stride: stride,
                width: width,
                height: height,
                componentStride: componentStride,
                keepingTopField: keepingTopField
            )
        }
    }
}

@Suite("Deinterlacing")
struct DeinterlacerTests {
    @Test func aStillPictureComesOutUntouched() {
        // Both fields agree, so nothing moves and weaving keeps full
        // resolution. No wrap-around in the pattern, which the motion test
        // would rightly refuse to weave across.
        var plane = TestPlane(width: 32, height: 16) { row, column in
            UInt8(100 + row * 2 + column % 3)
        }
        let before = plane.bytes
        plane.deinterlace(keepingTopField: true)
        #expect(plane.bytes == before)
    }

    @Test func combedRowsAreReplacedRatherThanWoven() {
        // The fields disagree completely, as motion does, so the dropped
        // field's rows must go.
        var plane = TestPlane(width: 32, height: 16) { row, _ in
            row % 2 == 0 ? 20 : 220
        }
        plane.deinterlace(keepingTopField: true)
        for row in 0..<16 {
            for column in 0..<32 {
                if row % 2 == 0 {
                    #expect(plane[row, column] == 20, "the kept field must survive")
                } else {
                    // Predicted from the rows either side, both the kept
                    // field's 20.
                    #expect(plane[row, column] == 20, "row \(row) still carries the other field")
                }
            }
        }
    }

    @Test func theKeptFieldFollowsTheFieldOrder() {
        // Bottom field first keeps the odd rows and predicts the even ones.
        var plane = TestPlane(width: 16, height: 8) { row, _ in
            row % 2 == 0 ? 0 : 255
        }
        plane.deinterlace(keepingTopField: false)
        for row in 0..<8 {
            #expect(plane[row, 4] == 255, "row \(row) should have taken the bottom field's value")
        }
    }

    @Test func aPredictionFollowsTheEdgeItSitsOn() {
        // A diagonal edge moving one column per row. Vertical interpolation
        // would land halfway between the sides (the staircase artefact);
        // following the diagonal lands on the edge's own values.
        var plane = TestPlane(width: 40, height: 12) { row, column in
            column > row + 8 ? 240 : 16
        }
        // Break the field agreement so the row is genuinely predicted.
        for row in stride(from: 1, to: 12, by: 2) {
            for column in 0..<40 {
                plane.bytes[row * plane.stride + column] = 128
            }
        }
        plane.deinterlace(keepingTopField: true)
        // Well inside each side, a predicted pixel takes that side's value, not
        // an average.
        #expect(plane[5, 2] == 16)
        #expect(plane[5, 38] == 240)
    }

    @Test func interleavedChromaNeverMixesItsComponents() {
        // NV12 chroma is U,V,U,V. A one-byte sideways step would mix U with V
        // and tint the picture, so it steps two.
        var plane = TestPlane(width: 32, height: 8) { row, column in
            if row % 2 == 0 {
                return column % 2 == 0 ? 40 : 200
            }
            // The other field, wildly different, so every row is predicted.
            return column % 2 == 0 ? 250 : 10
        }
        plane.deinterlace(componentStride: 2, keepingTopField: true)
        for row in 0..<8 {
            for column in 0..<32 {
                let expected: UInt8 = column % 2 == 0 ? 40 : 200
                #expect(plane[row, column] == expected, "row \(row) column \(column) mixed its components")
            }
        }
    }

    @Test func aPlaneTooSmallToPredictIsLeftAlone() {
        var plane = TestPlane(width: 8, height: 2) { row, _ in row == 0 ? 10 : 250 }
        let before = plane.bytes
        plane.deinterlace(keepingTopField: true)
        #expect(plane.bytes == before)
    }
}
