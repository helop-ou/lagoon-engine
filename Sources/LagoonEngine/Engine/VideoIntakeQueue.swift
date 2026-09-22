import CoreMedia
import Foundation
import Libavcodec

/// One compressed video access unit read from the container but not yet
/// handed to whatever decodes or renders it. The engine keeps
/// reading through a fragment's video block to reach its audio block, and
/// what it reads past the decoded-frame limit waits here, compressed, until
/// the decoded queue has room.
nonisolated enum VideoIntakeItem {
    /// A compressed sample for `VideoToolboxDecoder` or the compressed
    /// renderer path.
    case sample(CMSampleBuffer)
    /// A packet for `SoftwareVideoDecodeStage`.
    case packet(SoftwareVideoPacket)

    /// Payload size, so the intake can be bounded in bytes as well as count.
    var byteCount: Int {
        switch self {
        case .sample(let buffer): return CMSampleBufferGetTotalSampleSize(buffer)
        case .packet(let packet): return Int(max(packet.packet.pointee.size, 0))
        }
    }
}

/// FIFO of compressed video the demux loop has read past the decoded-frame
/// limit. Touched from the demux queue and, on seek and teardown, from
/// whichever queue resets the engine, so it locks.
nonisolated final class VideoIntakeQueue: @unchecked Sendable {
    private let lock = NSLock()
    // Head-indexed like `SampleBufferQueue`: avoids Array.removeFirst()
    // shifting every retained item on every pop, compacted in batches once
    // consumed slots are a majority of the storage.
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

    /// Highest `count` seen since the last `removeAll(resetPeak: true)`;
    /// the HUD and the regression probe use it to prove the bound held over
    /// a whole session rather than at one instant.
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

    /// Drops everything (seek, flush, teardown). The peak survives unless
    /// `resetPeak` is true, because a seek should not erase the evidence.
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
