import Foundation
import os

/// What the engine observed, in its own vocabulary.
///
/// These are the engine's events, not a host's. A host that reports
/// diagnostics onward maps them to whatever its own schema calls them; a host
/// that does not care never sees them, because the default sink discards
/// everything.
nonisolated enum EngineDiagnosticEvent: String, Sendable, CaseIterable {
    case playbackPlay
    case playbackPause
    case playbackSeek
    case playbackFinished
    case playbackTrack
    case playbackStall
    case playbackStallBegin
    case playbackStallEnd
    case playbackRendererRecovery
    case playbackCacheFallback
    case playbackSubtitleLoadFailed
}

/// Something that went wrong and is worth grouping across viewers.
///
/// Distinct from an event: an incident is a thing a maintainer would want
/// counted and fingerprinted, not a step in normal playback.
nonisolated enum EngineDiagnosticIncident: String, Sendable, CaseIterable {
    case playbackStall
    case playbackRendererRecovery
    case playbackSubtitleLoadFailed
}

nonisolated enum EngineDiagnosticLevel: String, Sendable, Comparable {
    case info
    case warning
    case error

    private var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .error: 2
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Where the engine's diagnostics go, if anywhere.
///
/// The engine has no opinion about reporting. It does not know whether a host
/// has a diagnostics service, whether a viewer consented to one, or what a
/// report costs — so it states what happened and stops there.
nonisolated protocol EngineDiagnosticSink: Sendable {
    func record(_ event: EngineDiagnosticEvent, _ fields: [String: DiagnosticValue])

    /// Returns whether the incident was accepted, which a caller may use to
    /// avoid doing expensive work for a report that was going to be dropped.
    @discardableResult
    func report(
        _ incident: EngineDiagnosticIncident,
        level: EngineDiagnosticLevel,
        variant: [String],
        fields: [String: DiagnosticValue]
    ) -> Bool
}

/// The default: everything is discarded.
///
/// A library that reports by default would be reporting to its author about
/// someone else's users, which is not a decision a dependency gets to make.
nonisolated struct DiscardedDiagnostics: EngineDiagnosticSink {
    public init() {}

    func record(_ event: EngineDiagnosticEvent, _ fields: [String: DiagnosticValue]) {}

    @discardableResult
    func report(
        _ incident: EngineDiagnosticIncident,
        level: EngineDiagnosticLevel,
        variant: [String],
        fields: [String: DiagnosticValue]
    ) -> Bool { false }
}

/// The engine's own way of reaching whatever sink is installed.
///
/// A global rather than a value threaded through every type, because the call
/// sites are spread across the decode path where an extra stored property per
/// object costs more than the indirection saves.
nonisolated enum EngineDiagnostics {
    private static let installed = OSAllocatedUnfairLock<EngineDiagnosticSink>(
        initialState: DiscardedDiagnostics()
    )

    /// Install once, before playback starts.
    static func use(_ sink: EngineDiagnosticSink) {
        installed.withLock { $0 = sink }
    }

    static var sink: EngineDiagnosticSink {
        installed.withLock { $0 }
    }

    static func record(_ event: EngineDiagnosticEvent, _ fields: [String: DiagnosticValue] = [:]) {
        sink.record(event, fields)
    }

    @discardableResult
    static func report(
        _ incident: EngineDiagnosticIncident,
        level: EngineDiagnosticLevel,
        variant: [String] = [],
        fields: [String: DiagnosticValue] = [:]
    ) -> Bool {
        sink.report(incident, level: level, variant: variant, fields: fields)
    }
}
