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
