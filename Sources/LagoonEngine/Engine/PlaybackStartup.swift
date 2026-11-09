import Foundation

/// How far a playback has got towards its first frame. A host can show it,
/// or give up early on a start that is not moving.
public enum PlaybackStartupPhase: String, Sendable, CaseIterable {
    /// Not started.
    case idle
    /// Waiting for the source's first byte.
    case connecting
    /// Bytes are arriving and the container's header is being read.
    case openingContainer
    /// The header is read and the streams are being probed.
    case probingStreams
    /// The streams are known and the queues are filling to the first frame.
    case priming
    /// The first frame is up.
    case started
}

/// When each step of a start was reached, measured from the moment the demux
/// queue was asked to open. Stages can arrive in any order, and only the
/// first of each counts: a reopen after a cache fallback does not move them.
nonisolated struct PlaybackStartupTimeline: Equatable, Sendable {
    enum Stage: String, CaseIterable, Sendable {
        case firstByte
        case containerOpened
        case streamsProbed
        case firstFrame
    }

    /// Long enough for a slow server to answer, short enough that a host
    /// still has a reason to say something.
    static let slowStartSeconds: TimeInterval = 5

    let began: TimeInterval
    private(set) var reached: [Stage: TimeInterval] = [:]

    init(began: TimeInterval) {
        self.began = began
    }

    mutating func mark(_ stage: Stage, at now: TimeInterval) {
        guard reached[stage] == nil else { return }
        reached[stage] = max(now - began, 0)
    }

    var phase: PlaybackStartupPhase {
        if reached[.firstFrame] != nil { return .started }
        if reached[.streamsProbed] != nil { return .priming }
        if reached[.containerOpened] != nil { return .probingStreams }
        if reached[.firstByte] != nil { return .openingContainer }
        return .connecting
    }

    /// Nothing has come back from the source in `threshold` seconds. A local
    /// file never reports a first byte, so its opened container counts.
    func isSlow(at now: TimeInterval, threshold: TimeInterval = slowStartSeconds) -> Bool {
        phase == .connecting && now - began >= threshold
    }

    /// Milliseconds from the start to each stage reached, for the diagnostic
    /// sink.
    var fields: [String: DiagnosticValue] {
        var fields: [String: DiagnosticValue] = [:]
        for (stage, seconds) in reached {
            fields["\(stage.rawValue)Ms"] = .int(Int((seconds * 1_000).rounded()))
        }
        return fields
    }
}
