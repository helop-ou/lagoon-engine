import CoreMedia

/// Snaps video packet timestamps onto an exact frame grid.
///
/// Matroska stamps at 1 ms, so a 23.976 fps pts lands up to ~0.5 ms off the
/// grid (more in real muxes). On a display matched to the content rate there
/// is one vsync per frame and no slack for that.
///
/// Packets arrive in decode order, so stamps step back and forth by whole
/// frames. Each snaps to the nearest whole-frame step from the previous one,
/// in integer ticks of the frame rate's timescale, so it cannot drift. A stamp
/// beyond tolerance (VFR, broken mux) passes through and re-anchors.
nonisolated struct VideoFrameTimeline {
    /// Above mux sloppiness (≤ ~2 ms), below half a frame (≥ 8 ms at 60 fps).
    static let tolerance = 0.005

    /// fps = num/den. The timescale is `num`, so one frame is `den` ticks.
    private let num: Int32
    private let den: Int64
    /// Previous snapped pts in ticks; nil before the first frame.
    private var previousTicks: Int64?

    /// nil when the rate can't form a usable grid.
    init?(frameRateNum: Int32, frameRateDen: Int32) {
        guard frameRateNum > 0, frameRateDen > 0 else { return nil }
        let fps = Double(frameRateNum) / Double(frameRateDen)
        guard fps >= 1, fps <= 240 else { return nil }
        num = frameRateNum
        den = Int64(frameRateDen)
    }

    var frameDuration: CMTime {
        CMTime(value: den, timescale: num)
    }

    /// For the HUD: which grid is in force.
    var gridDescription: String {
        "\(num)/\(den)"
    }

    /// Seek or flush: the next frame re-anchors.
    mutating func reset() {
        previousTicks = nil
    }

    /// The snapped pts, or nil when too far off the grid (the caller keeps
    /// the container timing for that frame).
    mutating func snapped(containerSeconds: Double) -> CMTime? {
        let rawTicks = (containerSeconds * Double(num)).rounded()
        guard let previous = previousTicks else {
            let anchor = Int64(rawTicks)
            previousTicks = anchor
            return CMTime(value: anchor, timescale: num)
        }
        let steps = ((rawTicks - Double(previous)) / Double(den)).rounded()
        let candidate = previous + Int64(steps) * den
        let error = abs(Double(candidate) / Double(num) - containerSeconds)
        guard error <= Self.tolerance, candidate != previous else {
            // Off the grid or a duplicate: pass through and re-anchor.
            previousTicks = Int64(rawTicks)
            return nil
        }
        previousTicks = candidate
        return CMTime(value: candidate, timescale: num)
    }
}
