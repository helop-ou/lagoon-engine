import CoreMedia
import Foundation

/// Thread-safe FIFO of ready-to-enqueue sample buffers.
nonisolated final class SampleBufferQueue: @unchecked Sendable {
    private let condition = NSCondition()
    // Head-indexed so a dequeue does not shift the array; consumed slots
    // are nilled at once and compacted in batches.
    private var buffers: [CMSampleBuffer?] = []
    private var head = 0
    private var finished = false
    private var waitsInterrupted = false

    var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return buffers.count - head
    }

    var isFinished: Bool {
        condition.lock()
        defer { condition.unlock() }
        return finished
    }

    /// Seconds of queued audio that end after `seconds`; earlier audio is
    /// discarded by the renderer, not a cushion.
    func bufferedDuration(after seconds: Double) -> Double {
        condition.lock()
        defer { condition.unlock() }
        guard head < buffers.count,
              let first = buffers[head],
              let last = buffers.last ?? nil else { return 0 }
        let firstPTS = CMSampleBufferGetPresentationTimeStamp(first)
        let lastPTS = CMSampleBufferGetPresentationTimeStamp(last)
        guard firstPTS.isValid, lastPTS.isValid else { return 0 }
        let duration = CMSampleBufferGetDuration(last)
        let end = duration.isValid && duration.seconds.isFinite
            ? CMTimeAdd(lastPTS, duration).seconds
            : lastPTS.seconds
        return max(end - max(firstPTS.seconds, seconds), 0)
    }

    /// Presentation time the queue covers, from its first and last PTS:
    /// codec-independent, unlike packet counts.
    var bufferedDuration: Double {
        condition.lock()
        defer { condition.unlock() }
        guard head < buffers.count,
              let first = buffers[head],
              let last = buffers.last ?? nil else { return 0 }
        let firstPTS = CMSampleBufferGetPresentationTimeStamp(first)
        let lastPTS = CMSampleBufferGetPresentationTimeStamp(last)
        guard firstPTS.isValid, lastPTS.isValid,
              firstPTS.seconds.isFinite, lastPTS.seconds.isFinite else { return 0 }
        let duration = CMSampleBufferGetDuration(last)
        let end = duration.isValid && duration.seconds.isFinite
            ? CMTimeAdd(lastPTS, duration).seconds
            : lastPTS.seconds
        return max(end - firstPTS.seconds, 0)
    }

    func enqueue(_ buffer: CMSampleBuffer) {
        condition.lock()
        buffers.append(buffer)
        condition.unlock()
    }

    func dequeue() -> CMSampleBuffer? {
        condition.lock()
        defer { condition.unlock() }
        guard head < buffers.count else { return nil }
        let buffer = buffers[head]
        buffers[head] = nil
        head += 1
        if head >= 64, head * 2 >= buffers.count {
            buffers.removeFirst(head)
            head = 0
        }
        condition.signal()
        return buffer
    }

    func markFinished() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    /// Used by the Debug audio hold to discard audio that ended before the
    /// clock; a real recovery never hands the renderer such samples.
    func dropLeading(while shouldDrop: (CMSampleBuffer) -> Bool) {
        condition.lock()
        while head < buffers.count, let buffer = buffers[head], shouldDrop(buffer) {
            buffers[head] = nil
            head += 1
            if head >= 64, head * 2 >= buffers.count {
                buffers.removeFirst(head)
                head = 0
            }
        }
        condition.broadcast()
        condition.unlock()
    }

    func reset() {
        condition.lock()
        buffers.removeAll()
        head = 0
        finished = false
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks the producer until the count drops below target, the queue
    /// finishes, or waits are interrupted.
    ///
    /// `alsoCounting` adds work not yet in the queue (the software decode
    /// stage), re-read on every wake; the stage wakes it via
    /// `signalWaiters()`. `timeout` lets the caller re-check what the queue
    /// cannot see.
    func waitUntilBelow(
        _ targetCount: Int,
        timeout: TimeInterval? = nil,
        alsoCounting: () -> Int = { 0 }
    ) {
        condition.lock()
        let deadline = timeout.map { Date(timeIntervalSinceNow: $0) }
        while buffers.count - head + alsoCounting() >= targetCount, !finished, !waitsInterrupted {
            if let deadline {
                guard condition.wait(until: deadline) else { break }
            } else {
                condition.wait()
            }
        }
        condition.unlock()
    }

    /// Wakes waiters to re-check; the decode stage calls it per packet.
    func signalWaiters() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    func interruptWaits() {
        condition.lock()
        waitsInterrupted = true
        condition.broadcast()
        condition.unlock()
    }
}
