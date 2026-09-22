import Foundation

/// Keeps GPU-converted frames in decode order and bounds how many are in
/// flight.
///
/// The decode queue reserves a slot per frame before submitting the kernel and
/// moves on; Metal's completions arrive on any thread, in no order. `complete`
/// runs a frame's delivery only once every earlier frame has been delivered,
/// so the renderer sees libavcodec's order and only one delivery runs at a
/// time. `reserve` blocks once `capacity` frames are outstanding — the only
/// backpressure this stage needs, so a slow GPU stalls the decode queue rather
/// than piling up pictures.
nonisolated final class GPUDeliverySequencer: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private var inFlight = 0
    private var nextToReserve: UInt64 = 0
    private var nextToDeliver: UInt64 = 0
    private var held: [UInt64: () -> Void] = [:]
    /// True while one thread is running deliveries. Every other thread hands
    /// its frame over and returns, so no two bodies ever overlap and none of
    /// them runs under the lock.
    private var delivering = false

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    /// Frames reserved and not yet delivered.
    var pendingCount: Int {
        condition.withLock { inFlight }
    }

    /// Blocks while `capacity` frames are outstanding, then returns the
    /// sequence number the caller must complete.
    func reserve() -> UInt64 {
        condition.lock()
        defer { condition.unlock() }
        while inFlight >= capacity {
            condition.wait()
        }
        inFlight += 1
        let sequence = nextToReserve
        nextToReserve += 1
        return sequence
    }

    /// Delivers `sequence` in order: runs `body` now if every earlier frame
    /// has been delivered, otherwise holds it until they have. A reservation
    /// that never reached the GPU completes with an empty body, so a failed
    /// submission cannot hold every later frame hostage.
    ///
    /// The caller may return before its own body has run: whichever thread is
    /// already delivering picks the frame up in turn. That is what makes the
    /// ordering a guarantee of this class rather than of the queue its callers
    /// happen to use — two completion threads calling this at once cannot run
    /// two frames' bodies side by side, and a body that calls back in only
    /// leaves its frame for the drain to reach.
    func complete(_ sequence: UInt64, _ body: @escaping () -> Void) {
        condition.lock()
        held[sequence] = body
        if delivering {
            condition.unlock()
            return
        }
        delivering = true
        defer {
            delivering = false
            condition.unlock()
        }
        // The lock is held at the top of every iteration and given up around
        // the body, which must never run under it, and reclaimed to account
        // for the slot the body just freed.
        while let next = held.removeValue(forKey: nextToDeliver) {
            nextToDeliver += 1
            condition.unlock()
            next()
            condition.lock()
            inFlight -= 1
            condition.broadcast()
        }
    }

    /// Waits until nothing is outstanding. Bounded, because a GPU that never
    /// answers must not wedge a seek or a teardown; returns whether it did
    /// drain.
    @discardableResult
    func waitUntilDrained(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while inFlight > 0 {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }
}
