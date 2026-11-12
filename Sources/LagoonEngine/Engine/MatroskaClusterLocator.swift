import Foundation

/// Finds a Matroska cluster and its timestamp in raw bytes.
///
/// Without Cues, libavformat's Matroska demuxer seeks by reading every
/// cluster from the last one it indexed up to the target, which through the
/// byte cache means downloading the file up to there. A byte seek does not
/// help: the demuxer resyncs to the start. One index entry at a cluster near
/// the target makes it scan only from there.
nonisolated enum MatroskaClusterLocator {
    struct Cluster: Equatable {
        /// File offset of the Cluster element's ID.
        let offset: Int64
        /// The cluster's Timestamp, in the segment's timestamp scale, which
        /// is the demuxer's stream time base.
        let timestamp: Int64
    }

    /// ID, size, CRC-32 and Timestamp at their longest.
    static let longestHeader = 4 + 8 + 6 + 1 + 1 + 8
    /// Windows without a cluster before giving up. Muxers start a cluster at
    /// least every 5 MiB and a window is 1 MiB, so four of them could all
    /// fall inside one cluster.
    static let emptyWindowLimit = 6
    static let overshootLimit = 4

    /// Bytes to step back from a cluster `overshootTicks` past the target:
    /// the overshoot's share of the file. The timestamp is whatever eight
    /// bytes the file holds, so the step is never more than the file.
    static func stepBack(
        overshootTicks: Int64,
        ticksPerSecond: Double,
        length: Int64,
        durationSeconds: Double
    ) -> Int64 {
        let share = Double(length) * (Double(overshootTicks) / ticksPerSecond) / durationSeconds
        guard share.isFinite, share < Double(length) else { return length }
        return Int64(max(share, 0))
    }

    /// A cluster at or before `timestamp`, looking a window at a time from
    /// `estimate` and stepping back when a window holds none or the one it
    /// holds is past the target. nil when none is found.
    static func lastCluster(
        atOrBefore timestamp: Int64,
        estimate: Int64,
        window: Int64,
        length: Int64,
        ticksPerSecond: Double,
        durationSeconds: Double,
        read: (_ offset: Int64, _ count: Int) -> Data
    ) -> Cluster? {
        var estimate = estimate
        // Counted apart: stepping back over a cluster longer than the window
        // must not use up the tries an overshoot needs, nor the reverse.
        var emptyWindows = 0
        var overshoots = 0
        while emptyWindows < emptyWindowLimit, overshoots < overshootLimit {
            estimate = min(max(estimate, 0), length - 1)
            let bytes = read(estimate, Int(min(window, length - estimate)))
            guard let cluster = firstCluster(in: bytes, baseOffset: estimate) else {
                guard estimate > 0 else { return nil }
                emptyWindows += 1
                // Overlapping, so a header across the edge is in one of them.
                estimate -= max(window - Int64(longestHeader), 1)
                continue
            }
            if cluster.timestamp <= timestamp { return cluster }
            overshoots += 1
            estimate -= stepBack(
                overshootTicks: cluster.timestamp - timestamp,
                ticksPerSecond: ticksPerSecond,
                length: length,
                durationSeconds: durationSeconds
            ) + window
        }
        return nil
    }

    private static let clusterID: [UInt8] = [0x1F, 0x43, 0xB6, 0x75]
    private static let timestampID: UInt8 = 0xE7
    private static let crc32ID: UInt8 = 0xBF

    /// The first cluster in `bytes`, which start at `baseOffset` in the file,
    /// whose first child is its Timestamp, after an optional CRC-32. That
    /// child check keeps four matching bytes inside a frame from passing.
    static func firstCluster(in bytes: Data, baseOffset: Int64) -> Cluster? {
        let buffer = [UInt8](bytes)
        var index = 0
        while index + clusterID.count < buffer.count {
            defer { index += 1 }
            guard buffer[index] == clusterID[0],
                  Array(buffer[index..<(index + clusterID.count)]) == clusterID,
                  let size = variableInteger(buffer, at: index + clusterID.count) else { continue }
            var child = index + clusterID.count + size.length
            if child + 1 < buffer.count, buffer[child] == crc32ID, buffer[child + 1] == 0x84 {
                child += 6
            }
            guard child < buffer.count, buffer[child] == timestampID,
                  let length = variableInteger(buffer, at: child + 1),
                  (1...8).contains(length.value),
                  child + 1 + length.length + Int(length.value) <= buffer.count else { continue }
            let start = child + 1 + length.length
            let timestamp = buffer[start..<(start + Int(length.value))].reduce(Int64(0)) { ($0 << 8) | Int64($1) }
            guard timestamp >= 0 else { continue }
            return Cluster(offset: baseOffset + Int64(index), timestamp: timestamp)
        }
        return nil
    }

    /// An EBML variable-length integer: its value without the length marker,
    /// and how many bytes it took.
    private static func variableInteger(_ buffer: [UInt8], at index: Int) -> (value: UInt64, length: Int)? {
        guard index < buffer.count, buffer[index] != 0 else { return nil }
        let length = buffer[index].leadingZeroBitCount + 1
        guard index + length <= buffer.count else { return nil }
        var value = UInt64(buffer[index] & (0xFF >> length))
        for offset in 1..<length {
            value = (value << 8) | UInt64(buffer[index + offset])
        }
        return (value, length)
    }
}
