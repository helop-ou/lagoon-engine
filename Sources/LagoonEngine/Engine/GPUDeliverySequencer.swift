import Foundation

/// Keeps GPU-converted frames in decode order and bounds how many are in
/// flight.
///
/// Metal completions arrive on any thread, in any order. `complete` runs a
/// frame's delivery only after every earlier one, one at a time. `reserve`
/// blocks at `capacity`, so a slow GPU stalls decode instead of piling up
/// pictures.
nonisolated final class GPUDeliverySequencer: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private var inFlight = 0
    private var nextToReserve: UInt64 = 0
    private var nextToDeliver: UInt64 = 0
    private var held: [UInt64: () -> Void] = [:]
    /// True while one thread is running deliveries. Others hand their frame
    /// over and return, so bodies never overlap or run under the lock.
    private var delivering = false

    public init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    var pendingCount: Int {
        condition.withLock { inFlight }
    }

    /// Blocks at `capacity`, then returns the sequence number to complete.
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

    /// Runs `body` in sequence order. A reservation that never reached the
    /// GPU must still complete (with an empty body), or every later frame waits.
    ///
    /// May return before `body` runs: the thread already delivering picks it
    /// up. A body that calls back in only queues its frame.
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
        // The body never runs under the lock.
        while let next = held.removeValue(forKey: nextToDeliver) {
            nextToDeliver += 1
            condition.unlock()
            next()
            condition.lock()
            inFlight -= 1
            condition.broadcast()
        }
    }

    /// Waits until nothing is outstanding; returns whether it drained. Bounded
    /// so a GPU that never answers cannot wedge a seek or teardown.
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
