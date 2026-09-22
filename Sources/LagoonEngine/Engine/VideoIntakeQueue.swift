import CoreMedia
import Foundation
import Libavcodec

/// A compressed video access unit read ahead of the decoded-frame limit.
/// The demuxer reads through a fragment's video to reach its audio, and the
/// surplus waits here until the decoded queue has room.
nonisolated enum VideoIntakeItem {
    /// For `VideoToolboxDecoder` or the compressed renderer path.
    case sample(CMSampleBuffer)
    /// A packet for `SoftwareVideoDecodeStage`.
    case packet(SoftwareVideoPacket)

    /// Lets the intake be bounded in bytes as well as count.
    var byteCount: Int {
        switch self {
        case .sample(let buffer): return CMSampleBufferGetTotalSampleSize(buffer)
        case .packet(let packet): return Int(max(packet.packet.pointee.size, 0))
        }
    }
}

/// FIFO of read-ahead compressed video. Locked: the demux queue and whichever
/// queue resets the engine (seek, teardown) both touch it.
nonisolated final class VideoIntakeQueue: @unchecked Sendable {
    private let lock = NSLock()
    // Head-indexed so a pop does not shift the array; compacted in batches.
    private var items: [VideoIntakeItem?] = []
    private var head = 0
    private var storedByteCount = 0
    private var storedPeakCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count - head
    }

    var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedByteCount
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return items.count - head == 0
    }

    /// Highest `count` since the last `removeAll(resetPeak: true)`. Proves
    /// the bound held over a whole session.
    var peakCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedPeakCount
    }

    func append(_ item: VideoIntakeItem) {
        lock.lock()
        items.append(item)
        storedByteCount += item.byteCount
        storedPeakCount = max(storedPeakCount, items.count - head)
        lock.unlock()
    }

    func popFirst() -> VideoIntakeItem? {
        lock.lock()
        defer { lock.unlock() }
        guard head < items.count, let item = items[head] else { return nil }
        items[head] = nil
        head += 1
        storedByteCount -= item.byteCount
        if head >= 64, head * 2 >= items.count {
            items.removeFirst(head)
            head = 0
        }
        return item
    }

    /// Drops everything. The peak survives a seek unless `resetPeak` is true.
    func removeAll(resetPeak: Bool = false) {
        lock.lock()
        items.removeAll()
        head = 0
        storedByteCount = 0
        if resetPeak {
            storedPeakCount = 0
        }
        lock.unlock()
    }
}
