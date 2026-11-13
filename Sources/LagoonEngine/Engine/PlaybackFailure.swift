import Foundation

/// Where a playback attempt failed, in codes rather than prose.
///
/// Carries no message and nothing from `userInfo`, where URLs and file names
/// live, so nothing in it can identify a viewer or a title.
public nonisolated struct PlaybackFailureDetail: Equatable, Sendable {
    /// Where an attempt failed. The engine names the stages it reports, and
    /// a host adds its own in an extension for what it does around the
    /// engine. A struct rather than an enum, so a new stage on either side
    /// is not a breaking change: a switch over it needs a `default`.
    public nonisolated struct Stage: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let open = Self(rawValue: "open")
        public static let seek = Self(rawValue: "seek")
        public static let read = Self(rawValue: "read")
        public static let decode = Self(rawValue: "decode")
        public static let videoRenderer = Self(rawValue: "videoRenderer")
        public static let audioRenderer = Self(rawValue: "audioRenderer")
        public static let subtitle = Self(rawValue: "subtitle")
    }

    public let stage: Stage
    /// A token such as `AVFoundationErrorDomain`, `VideoToolbox`, `ffmpeg`,
    /// or `NSURLErrorDomain`. Nil when the layer gave none.
    public let domain: String?
    public let code: Int?

    public init(stage: Stage, domain: String? = nil, code: Int? = nil) {
        self.stage = stage
        self.domain = domain
        self.code = code
    }

    /// Takes only the domain and code from `error`.
    public init(stage: Stage, error: Error?) {
        guard let error else {
            self.init(stage: stage)
            return
        }
        let nsError = error as NSError
        self.init(stage: stage, domain: nsError.domain, code: nsError.code)
    }

    /// Stage and domain only if they pass the token rule, code if any. A
    /// host names its own stages, so the engine did not choose every one.
    public var fields: [String: DiagnosticValue] {
        var fields: [String: DiagnosticValue] = [:]
        if let stage = DiagnosticToken.token(stage.rawValue) {
            fields["stage"] = stage
        }
        if let domain = DiagnosticToken.token(domain) {
            fields["errorDomain"] = domain
        }
        if let code {
            fields["errorCode"] = .int(code)
        }
        return fields
    }

    /// The part of a fingerprint that separates one kind of failure at a
    /// stage from another.
    public var fingerprint: [String] {
        var parts = [stage.rawValue, domain].compactMap(\.self).filter(DiagnosticToken.isToken)
        if let code {
            parts.append(String(code))
        }
        return parts
    }
}

/// A failure the engine could not recover from, handed to the host to decide
/// what to try next.
///
/// `cause` is the engine's verdict about the samples: all a host needs to
/// decide whether asking for the media another way could help.
public nonisolated struct PlaybackEngineFailure: Equatable, Sendable {
    public enum Cause: Equatable, Sendable {
        /// The samples cannot be decoded here (unsupported codec, session
        /// declined, decode failed). Only a re-encode can help.
        case undecodable
        /// The container, transport or an AVFoundation object failed. The
        /// same media may play when delivered another way.
        case delivery
    }

    public let cause: Cause
    /// What the viewer is told if the host runs out of things to try.
    public let message: String
    /// The same failure in codes, for a diagnostic report. Never the message.
    public let detail: PlaybackFailureDetail?
    /// What the network last answered when a read failed, if it failed
    /// there. A refused credential or a lost network fails the same way
    /// however the media is delivered, which the host may want to know before
    /// it asks again.
    public let transport: PlaybackTransportFailure?

    public init(
        cause: Cause,
        message: String,
        detail: PlaybackFailureDetail? = nil,
        transport: PlaybackTransportFailure? = nil
    ) {
        self.cause = cause
        self.message = message
        self.detail = detail
        self.transport = transport
    }
}

/// Why the network stopped giving bytes, in the codes it gave.
public nonisolated enum PlaybackTransportFailure: Equatable, Sendable {
    /// The server answered with this status instead of the bytes asked for.
    case httpStatus(Int)
    /// The request failed before an answer, with this `NSURLErrorDomain`
    /// code: offline, an unknown host, a refused certificate, a timeout.
    case urlError(Int)
}
