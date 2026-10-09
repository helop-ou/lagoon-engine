import Foundation

#if DEBUG
/// Debug fault gates for diagnostics and the regression suite. The demux
/// side waits on a condition, so an outage costs no CPU and teardown can
/// always wake it.
nonisolated final class PlaybackDiagnosticFaultGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isCancelled = false
    private var isDemuxDeliverySuspended = false
    private var isAudioDeliverySuspended = false

    var audioDeliverySuspended: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isAudioDeliverySuspended
    }

    func setAudioDeliverySuspended(_ suspended: Bool) {
        condition.lock()
        isAudioDeliverySuspended = suspended && !isCancelled
        condition.unlock()
    }

    func setDemuxDeliverySuspended(_ suspended: Bool) {
        condition.lock()
        isDemuxDeliverySuspended = suspended && !isCancelled
        if !isDemuxDeliverySuspended { condition.broadcast() }
        condition.unlock()
    }

    func waitBeforeDemuxStep() {
        condition.lock()
        while isDemuxDeliverySuspended && !isCancelled {
            condition.wait()
        }
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        isCancelled = true
        isDemuxDeliverySuspended = false
        isAudioDeliverySuspended = false
        condition.broadcast()
        condition.unlock()
    }
}
#endif
