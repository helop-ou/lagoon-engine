import Foundation
import os

/// What the engine observed, in its own vocabulary. A host maps these to its
/// own schema; by default they are discarded.
///
/// A struct rather than an enum, so a new event is not a breaking change: a
/// host's switch over it needs a `default`. Add each new event to `allCases`.
public nonisolated struct EngineDiagnosticEvent: RawRepresentable, Hashable, Sendable, CaseIterable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let playbackPlay = Self(rawValue: "playbackPlay")
    public static let playbackPause = Self(rawValue: "playbackPause")
    public static let playbackSeek = Self(rawValue: "playbackSeek")
    public static let playbackFinished = Self(rawValue: "playbackFinished")
    public static let playbackTrack = Self(rawValue: "playbackTrack")
    public static let playbackStallBegin = Self(rawValue: "playbackStallBegin")
    public static let playbackStallEnd = Self(rawValue: "playbackStallEnd")
    public static let playbackRendererRecovery = Self(rawValue: "playbackRendererRecovery")
    public static let playbackCacheFallback = Self(rawValue: "playbackCacheFallback")
    public static let playbackSubtitleLoadFailed = Self(rawValue: "playbackSubtitleLoadFailed")
    /// The first frame is up. Carries the milliseconds to each step of the
    /// start: `firstByteMs`, `containerOpenedMs`, `streamsProbedMs` and
    /// `firstFrameMs`.
    public static let playbackStartup = Self(rawValue: "playbackStartup")
    /// Nothing came back from the source within a few seconds of the open.
    public static let playbackSlowStart = Self(rawValue: "playbackSlowStart")

    public static let allCases: [Self] = [
        .playbackPlay,
        .playbackPause,
        .playbackSeek,
        .playbackFinished,
        .playbackTrack,
        .playbackStallBegin,
        .playbackStallEnd,
        .playbackRendererRecovery,
        .playbackCacheFallback,
        .playbackSubtitleLoadFailed,
        .playbackStartup,
        .playbackSlowStart,
    ]
}

/// Something that went wrong and is worth counting and fingerprinting across
/// viewers, unlike a routine event. A struct for the same reason as
/// `EngineDiagnosticEvent`.
public nonisolated struct EngineDiagnosticIncident: RawRepresentable, Hashable, Sendable, CaseIterable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let playbackStall = Self(rawValue: "playbackStall")
    public static let playbackRendererRecovery = Self(rawValue: "playbackRendererRecovery")
    public static let playbackSubtitleLoadFailed = Self(rawValue: "playbackSubtitleLoadFailed")

    public static let allCases: [Self] = [
        .playbackStall,
        .playbackRendererRecovery,
        .playbackSubtitleLoadFailed,
    ]
}

public nonisolated enum EngineDiagnosticLevel: String, Sendable, Comparable {
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

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Where the engine's diagnostics go, if anywhere. The engine does not know
/// whether a host reports or a viewer consented, so it only states what
/// happened.
public nonisolated protocol EngineDiagnosticSink: Sendable {
    func record(_ event: EngineDiagnosticEvent, _ fields: [String: DiagnosticValue])

    /// Whether the incident was accepted, so a caller can skip work for a
    /// dropped report.
    @discardableResult
    func report(
        _ incident: EngineDiagnosticIncident,
        level: EngineDiagnosticLevel,
        variant: [String],
        fields: [String: DiagnosticValue]
    ) -> Bool
}

/// The default: discard everything. A library must not report to its author
/// about someone else's users.
public nonisolated struct DiscardedDiagnostics: EngineDiagnosticSink {
    public init() {}

    public func record(_ event: EngineDiagnosticEvent, _ fields: [String: DiagnosticValue]) {}

    @discardableResult
    public func report(
        _ incident: EngineDiagnosticIncident,
        level: EngineDiagnosticLevel,
        variant: [String],
        fields: [String: DiagnosticValue]
    ) -> Bool { false }
}

/// Reaches the installed sink. A global, because call sites are spread across
/// the decode path where a stored property per object costs more.
public nonisolated enum EngineDiagnostics {
    private static let installed = OSAllocatedUnfairLock<EngineDiagnosticSink>(
        initialState: DiscardedDiagnostics()
    )

    /// Install once, before playback starts. Without it, diagnostics are
    /// discarded.
    public static func use(_ sink: EngineDiagnosticSink) {
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
