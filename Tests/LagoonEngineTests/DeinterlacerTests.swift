import Foundation
import Testing
@testable import LagoonEngine

/// A plane laid out the way a decoder hands one over: `height` rows of
/// `width` bytes, at some stride wider than the row itself, so a deinterlacer
/// that ignores the stride is caught here rather than on a television.
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
        // Both fields agree, so nothing is moving and every original sample
        // is detail no prediction could put back. Weaving is the right answer
        // and full vertical resolution survives. No wrap-around in the
        // pattern: that would be a discontinuity the motion test is right to
        // refuse to weave across.
        var plane = TestPlane(width: 32, height: 16) { row, column in
            UInt8(100 + row * 2 + column % 3)
        }
        let before = plane.bytes
        plane.deinterlace(keepingTopField: true)
        #expect(plane.bytes == before)
    }

    @Test func combedRowsAreReplacedRatherThanWoven() {
        // The two fields disagree completely, which is what motion looks like
        // in an interlaced frame. The dropped field's rows have to go.
        var plane = TestPlane(width: 32, height: 16) { row, _ in
            row % 2 == 0 ? 20 : 220
        }
        plane.deinterlace(keepingTopField: true)
        for row in 0..<16 {
            for column in 0..<32 {
                if row % 2 == 0 {
                    #expect(plane[row, column] == 20, "the kept field must survive")
                } else {
                    // Predicted from the rows either side, both of which are
                    // the kept field's 20.
                    #expect(plane[row, column] == 20, "row \(row) still carries the other field")
                }
            }
        }
    }

    @Test func theKeptFieldFollowsTheFieldOrder() {
        // Bottom field first keeps the odd rows, and the even ones are the
        // ones predicted away.
        var plane = TestPlane(width: 16, height: 8) { row, _ in
            row % 2 == 0 ? 0 : 255
        }
        plane.deinterlace(keepingTopField: false)
        for row in 0..<8 {
            #expect(plane[row, 4] == 255, "row \(row) should have taken the bottom field's value")
        }
    }

    @Test func aPredictionFollowsTheEdgeItSitsOn() {
        // A diagonal edge: everything left of the line is dark, right of it
        // bright, and the boundary moves one column per row. Interpolating
        // straight up and down across such an edge lands halfway between the
        // two sides, which is the staircase artefact this avoids; following
        // the diagonal lands on the edge's own values.
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
        // On a predicted row, the pixel well inside each side of the edge
        // takes that side's value rather than an average of the two.
        #expect(plane[5, 2] == 16)
        #expect(plane[5, 38] == 240)
    }

    @Test func interleavedChromaNeverMixesItsComponents() {
        // NV12 chroma is U,V,U,V along a row. A prediction that stepped one
        // byte sideways would average a U sample with a V one and tint the
        // picture, so it steps two.
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
