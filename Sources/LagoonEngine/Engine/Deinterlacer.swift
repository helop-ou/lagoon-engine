import Foundation

/// Turns an interlaced frame into a progressive one, in place.
///
/// Written rather than linked. Deinterlacing normally means libavfilter's
/// yadif, and libavfilter is not among the FFmpeg artifacts this project
/// pins — adding one to deinterlace a DVD is a dependency decision that
/// wants more deliberation than a feature branch.
///
/// What it does instead is the useful half of yadif's spatial pass: for each
/// row of the field being dropped, predict along whichever direction the
/// image actually runs, and keep the original pixel where the two fields
/// already agree. The second half of yadif — looking at neighbouring frames
/// to decide *whether* a pixel is moving — is what this gives up, and the
/// per-pixel agreement test below stands in for it. On a static shot the
/// output is the original frame; on motion it is a single field interpolated
/// rather than two fields combed together.
nonisolated enum Deinterlacer {
    /// How far the two fields may disagree at a pixel before it is treated as
    /// motion. Below this the rows are woven, which keeps full vertical
    /// detail on the still parts of a shot; above it the row is predicted.
    ///
    /// Deliberately low. Weaving something that is moving shows as combing,
    /// which the eye finds immediately; interpolating something that is still
    /// costs a little sharpness, which it does not.
    static let motionThreshold = 10

    /// Replaces the rows of the dropped field with predictions from the rows
    /// that surround them.
    ///
    /// `componentStride` is 1 for a planar plane and 2 for interleaved
    /// chroma, so that a prediction never mixes a U sample with a V one.
    static func plane(
        base: UnsafeMutablePointer<UInt8>,
        stride: Int,
        width: Int,
        height: Int,
        componentStride: Int = 1,
        keepingTopField: Bool
    ) {
        guard width > 0, height > 2, stride >= width else { return }
        let keptParity = keepingTopField ? 0 : 1
        for row in 0..<height where row % 2 != keptParity {
            // The kept field's rows either side. At the top and bottom edges
            // there is only one, and it is simply copied down.
            let above = row > 0 ? row - 1 : row + 1
            let below = row < height - 1 ? row + 1 : row - 1
            guard above >= 0, below < height else { continue }
            let target = base.advanced(by: row * stride)
            let upper = base.advanced(by: above * stride)
            let lower = base.advanced(by: below * stride)
            for column in 0..<width {
                target[column] = predicted(
                    original: target[column],
                    upper: upper,
                    lower: lower,
                    column: column,
                    width: width,
                    componentStride: componentStride
                )
            }
        }
    }

    /// One pixel of the dropped field.
    ///
    /// Written out rather than looped over a list of directions: this runs
    /// for every pixel of every dropped row, and a literal array here costs
    /// an allocation per pixel, which measured at three times the cost of the
    /// arithmetic it was carrying.
    @inline(__always)
    private static func predicted(
        original: UInt8,
        upper: UnsafeMutablePointer<UInt8>,
        lower: UnsafeMutablePointer<UInt8>,
        column: Int,
        width: Int,
        componentStride: Int
    ) -> UInt8 {
        // Where the fields already agree there is nothing moving, and the
        // original sample carries detail no prediction can put back. Tested
        // first because it is both the cheapest answer and the common one.
        let up = Int(upper[column])
        let down = Int(lower[column])
        let vertical = (up + down + 1) / 2
        if abs(Int(original) - vertical) <= motionThreshold {
            return original
        }

        var bestScore = score(upper, lower, column, 0, width, componentStride)
        var prediction = vertical
        // Diagonals, nearest first, so an edge running at an angle is
        // interpolated along itself instead of across it. A tie keeps the
        // steeper direction already chosen, and vertical is scored first, so
        // a flat area is never interpolated along a diagonal it has no reason
        // to prefer.
        for step in 1...2 {
            let shift = step * componentStride
            for signed in [shift, -shift] where column + signed >= 0
                && column + signed < width
                && column - signed >= 0
                && column - signed < width {
                let candidate = score(upper, lower, column, signed, width, componentStride)
                if candidate < bestScore {
                    bestScore = candidate
                    prediction = (Int(upper[column + signed]) + Int(lower[column - signed]) + 1) / 2
                }
            }
        }
        return UInt8(clamping: prediction)
    }

    /// How well the two fields line up across three samples in one direction.
    /// Three rather than one so a single noisy pixel cannot choose it.
    @inline(__always)
    private static func score(
        _ upper: UnsafeMutablePointer<UInt8>,
        _ lower: UnsafeMutablePointer<UInt8>,
        _ column: Int,
        _ shift: Int,
        _ width: Int,
        _ componentStride: Int
    ) -> Int {
        var total = 0
        var offset = -componentStride
        while offset <= componentStride {
            let upperColumn = column + offset + shift
            let lowerColumn = column + offset - shift
            if upperColumn >= 0, upperColumn < width, lowerColumn >= 0, lowerColumn < width {
                total += abs(Int(upper[upperColumn]) - Int(lower[lowerColumn]))
            } else {
                // An edge that runs off the frame is never the best guess.
                total += 255
            }
            offset += componentStride
        }
        return total
    }
}
