import Foundation

/// Where a playback attempt failed, in codes rather than prose.
///
/// Carries no message and nothing from `userInfo`, where URLs and file names
/// live, so nothing in it can identify a viewer or a title.
public nonisolated struct PlaybackFailureDetail: Equatable, Sendable {
    public enum Stage: String, Sendable {
        case negotiate, open, seek, read, decode, videoRenderer, audioRenderer, subtitle, cache, start, handoff, unknown
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

    /// Stage always, domain only if it passes the token rule, code if any.
    public var fields: [String: DiagnosticValue] {
        var fields: [String: DiagnosticValue] = ["stage": .string(stage.rawValue)]
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
        var parts = [stage.rawValue]
        if let domain, DiagnosticToken.isToken(domain) {
            parts.append(domain)
        }
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

    public init(cause: Cause, message: String, detail: PlaybackFailureDetail? = nil) {
        self.cause = cause
        self.message = message
        self.detail = detail
    }
}
