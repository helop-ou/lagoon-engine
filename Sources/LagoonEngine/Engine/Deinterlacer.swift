import Foundation

/// Turns an interlaced frame into a progressive one, in place.
///
/// Written here because libavfilter (yadif) is not linked. It does yadif's
/// spatial pass only: each dropped-field row is predicted along the edge
/// direction, and pixels where both fields agree are kept. A per-pixel
/// agreement test replaces yadif's temporal check, so a static shot comes out
/// unchanged and motion becomes one interpolated field.
nonisolated enum Deinterlacer {
    /// Field disagreement above which a pixel counts as motion and is
    /// predicted; below it the original is kept. Low on purpose: combing is
    /// far more visible than lost sharpness.
    static let motionThreshold = 10

    /// Replaces the dropped field's rows with predictions.
    /// `componentStride` is 2 for interleaved chroma so U never mixes with V.
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
            // The kept rows either side; at the edges there is only one.
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

    /// One pixel of the dropped field. Unrolled on purpose: an array literal
    /// here allocates per pixel and tripled the cost.
    @inline(__always)
    private static func predicted(
        original: UInt8,
        upper: UnsafeMutablePointer<UInt8>,
        lower: UnsafeMutablePointer<UInt8>,
        column: Int,
        width: Int,
        componentStride: Int
    ) -> UInt8 {
        // Fields agree: keep the original. Cheapest and most common case.
        let up = Int(upper[column])
        let down = Int(lower[column])
        let vertical = (up + down + 1) / 2
        if abs(Int(original) - vertical) <= motionThreshold {
            return original
        }

        var bestScore = score(upper, lower, column, 0, width, componentStride)
        var prediction = vertical
        // Diagonals, nearest first, so an angled edge is interpolated along
        // itself. Ties keep the steeper direction, so flat areas stay vertical.
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

    /// Field mismatch across three samples in one direction, so one noisy
    /// pixel cannot decide it.
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
