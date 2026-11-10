import Foundation

/// The compressed packets of every embedded subtitle stream the demuxer has
/// read this session, bitmap streams included, so a switch to one or a seek
/// back can decode the line on screen from here instead of re-demuxing.
///
/// Bounded in bytes across all streams, oldest read first out. A packet read
/// again after a seek is kept once. Runs on the demux queue.
nonisolated struct SubtitlePacketStore {
    struct Packet: Equatable {
        /// In the stream's time base.
        let pts: Int64
        let duration: Int64
        let data: Data
    }

    /// Bytes across all streams. PGS runs to tens of megabytes per film
    /// track, text to a few hundred kilobytes.
    static let budget = 32 << 20

    private(set) var byteCount = 0
    /// Per stream, in pts order.
    private var streams: [Int32: [Packet]] = [:]
    /// Every packet in the order it was read, for eviction.
    private var arrivals: [(stream: Int32, pts: Int64, size: Int)] = []
    private var arrivalsStart = 0

    /// Whether the packet was new.
    @discardableResult
    mutating func add(_ packet: Packet, streamIndex: Int32) -> Bool {
        var packets = streams[streamIndex] ?? []
        let index = Self.insertionIndex(of: packet.pts, in: packets)
        var probe = index
        while probe > 0, packets[probe - 1].pts == packet.pts {
            probe -= 1
            if packets[probe] == packet { return false }
        }
        packets.insert(packet, at: index)
        streams[streamIndex] = packets
        byteCount += packet.data.count
        arrivals.append((streamIndex, packet.pts, packet.data.count))
        evict()
        return true
    }

    /// A stream's packets with `pts` in `range`, in pts order.
    func packets(for streamIndex: Int32, in range: ClosedRange<Int64>) -> [Packet] {
        guard let packets = streams[streamIndex] else { return [] }
        let start = Self.insertionIndex(of: range.lowerBound, in: packets, before: true)
        return Array(packets[start...].prefix { $0.pts <= range.upperBound })
    }

    func count(for streamIndex: Int32) -> Int {
        streams[streamIndex]?.count ?? 0
    }

    mutating func removeAll() {
        streams.removeAll()
        arrivals.removeAll()
        arrivalsStart = 0
        byteCount = 0
    }

    private mutating func evict() {
        while byteCount > Self.budget, arrivalsStart < arrivals.count {
            let oldest = arrivals[arrivalsStart]
            arrivalsStart += 1
            if var packets = streams[oldest.stream],
               let index = packets.firstIndex(where: { $0.pts == oldest.pts && $0.data.count == oldest.size }) {
                packets.remove(at: index)
                streams[oldest.stream] = packets
                byteCount -= oldest.size
            }
        }
        // Drop the consumed front now and then, not on every packet.
        if arrivalsStart > 4_096 {
            arrivals.removeFirst(arrivalsStart)
            arrivalsStart = 0
        }
    }

    /// The first index whose pts is above `pts`, or at or above it when
    /// `before`.
    private static func insertionIndex(of pts: Int64, in packets: [Packet], before: Bool = false) -> Int {
        var low = 0
        var high = packets.count
        while low < high {
            let middle = (low + high) / 2
            if packets[middle].pts < pts || (!before && packets[middle].pts == pts) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}
