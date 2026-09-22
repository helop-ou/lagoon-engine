import CoreMedia
import Foundation
import Libavcodec
import Libavutil

/// A compressed video access unit detached from the demuxer's reusable
/// packet. `av_packet_clone` shares the refcounted payload, so it is cheap.
nonisolated final class SoftwareVideoPacket: @unchecked Sendable {
    let packet: UnsafeMutablePointer<AVPacket>
    /// Origin-corrected container time and end, for the demux loop's
    /// bookkeeping only. Decoded frames carry their own snapped stamps.
    let presentationSeconds: Double?
    let endSeconds: Double?

    init?(cloning source: UnsafeMutablePointer<AVPacket>, timeBase: AVRational) {
        guard let clone = av_packet_clone(source) else { return nil }
        packet = clone
        let scale = Double(timeBase.num) / Double(max(timeBase.den, 1))
        let stamp = clone.pointee.pts != Int64.min ? clone.pointee.pts : clone.pointee.dts
        if stamp != Int64.min {
            let seconds = Double(stamp) * scale
            presentationSeconds = seconds
            endSeconds = clone.pointee.duration > 0
                ? seconds + Double(clone.pointee.duration) * scale
                : seconds
        } else {
            presentationSeconds = nil
            endSeconds = nil
        }
    }

    deinit {
        var pointer: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&pointer)
    }
}

/// Runs `SoftwareVideoDecoder` on its own queue so reading and decoding
/// overlap, which 4K AV1 needs.
///
/// Shaped like `VideoToolboxDecoder`: submit and move on; frames and errors
/// come back through handlers. The demux loop owns backpressure and counts
/// `pendingCount` as video already asked for (`DemuxBackpressurePolicy`).
nonisolated final class SoftwareVideoDecodeStage: @unchecked Sendable {
    typealias OutputHandler = @Sendable (CMSampleBuffer) -> Void
    typealias ErrorHandler = @Sendable (Error) -> Void

    private let decoder: SoftwareVideoDecoder
    private let queue = DispatchQueue(
        label: "ee.helop.lagoon.videodecode",
        qos: .userInitiated
    )
    private let outputHandler: OutputHandler
    private let errorHandler: ErrorHandler
    /// Called as each packet leaves, so a waiter on the pending count can
    /// re-check it.
    private let packetCompletionHandler: @Sendable () -> Void

    /// A condition so priming can wait for the decoder and teardown can end
    /// that wait.
    private let condition = NSCondition()
    private var mailbox: [SoftwareVideoPacket] = []
    private var inFlight = false
    /// Bumped by seek and teardown; older work discards its frames.
    private var generation: UInt64 = 0
    private var accepting = true
    private var failed = false

    var decodedFrameBytes: Int64 { decoder.decodedFrameBytes }
    var resolvedThreadCount: Int32 { decoder.resolvedThreadCount }
    var outputsToneMappedSDR: Bool { decoder.outputsToneMappedSDR }
    var usesCompressedOutput: Bool { decoder.usesCompressedOutput }
    var outputModeName: String { decoder.outputModeName }
    var codecName: String { decoder.codecName }
    var lowDelayEnabled: Bool { decoder.lowDelayEnabled }
    var maxFrameDelay: Int64? { decoder.maxFrameDelay }
    var decoderDelay: Int32 { decoder.decoderDelay }
    var gridDescription: String? { decoder.gridDescription }
    var profile: SoftwareVideoDecoder.Profile { decoder.profile }
    var detailedTimingLines: [String] { decoder.detailedTimingLines }

    func resetDetailedTimings() {
        decoder.resetDetailedTimings()
    }

    /// Packets submitted but not yet decoded, including the one in flight.
    var pendingCount: Int {
        condition.withLock { mailbox.count + (inFlight ? 1 : 0) } + decoder.pendingOutputCount
    }

    /// Blocks until fewer than `target` packets are outstanding, or the stage
    /// fails or is torn down. For priming, whose cushion may be entirely
    /// inside the decoder.
    func waitUntilPendingBelow(_ target: Int) {
        condition.lock()
        while mailbox.count + (inFlight ? 1 : 0) >= target, accepting, !failed {
            condition.wait()
        }
        condition.unlock()
    }

    public init(
        decoder: SoftwareVideoDecoder,
        outputHandler: @escaping OutputHandler,
        errorHandler: @escaping ErrorHandler,
        packetCompletionHandler: @escaping @Sendable () -> Void
    ) {
        self.decoder = decoder
        self.outputHandler = outputHandler
        self.errorHandler = errorHandler
        self.packetCompletionHandler = packetCompletionHandler
    }

    /// Hands one access unit to the decode queue and returns immediately.
    func submit(_ packet: SoftwareVideoPacket) {
        let generation: UInt64? = condition.withLock {
            guard accepting, !failed else { return nil }
            mailbox.append(packet)
            condition.broadcast()
            return self.generation
        }
        guard let generation else { return }
        queue.async { [weak self] in
            self?.decodeNext(generation: generation)
        }
    }

    /// Seek: discards queued packets and flushes libavcodec. Returns once the
    /// decoder is quiet, so the caller can flush render queues without racing
    /// a frame in flight.
    func reset() {
        condition.withLock {
            generation &+= 1
            mailbox.removeAll(keepingCapacity: true)
            failed = false
            condition.broadcast()
        }
        queue.sync { decoder.flush() }
    }

    /// End of file: decodes everything submitted and drains the frames
    /// libavcodec's frame threading still holds.
    func finish() throws {
        var thrown: Error?
        queue.sync {
            guard condition.withLock({ !failed && accepting }) else { return }
            do {
                try decoder.drain { [outputHandler] buffer in
                    outputHandler(buffer)
                }
            } catch {
                thrown = error
            }
        }
        if let thrown { throw thrown }
    }

    /// Teardown: stops accepting work and waits out the frame in flight, so
    /// the decoder is not released under it.
    func invalidate() {
        condition.withLock {
            accepting = false
            generation &+= 1
            mailbox.removeAll(keepingCapacity: true)
            condition.broadcast()
        }
        queue.sync { decoder.waitForPendingOutput() }
    }

    private func decodeNext(generation: UInt64) {
        ProcessCPUTrace.noteDecodeThread()
        let packet: SoftwareVideoPacket? = condition.withLock {
            guard generation == self.generation, !failed, !mailbox.isEmpty else { return nil }
            inFlight = true
            condition.broadcast()
            return mailbox.removeFirst()
        }
        guard let packet else { return }
        // Long-lived queue: per-frame Core Media temporaries need a pool.
        autoreleasepool {
            do {
                // A seek during decode or GPU work makes this frame stale;
                // drop it at delivery.
                try decoder.decode(packet: packet.packet) { [weak self] frame in
                    guard let self,
                          self.condition.withLock({ generation == self.generation }) else { return }
                    self.outputHandler(frame)
                }
            } catch {
                let alreadyFailed = condition.withLock { () -> Bool in
                    let previous = failed
                    failed = true
                    condition.broadcast()
                    return previous
                }
                if !alreadyFailed {
                    errorHandler(error)
                }
            }
        }
        condition.withLock {
            inFlight = false
            condition.broadcast()
        }
        packetCompletionHandler()
    }
}
