import Foundation

/// Where a playback attempt failed, in codes rather than prose.
///
/// Deliberately carries no message and nothing out of an error's `userInfo`,
/// which is where URLs, file names and query strings live. A host that
/// reports failures onward gets a stage, a domain token and a code, and
/// nothing that could identify a viewer or a title.
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

    /// Domain and code from any error, and nothing else from it: not the
    /// description, not `userInfo`, which is where URLs and file names live.
    public init(stage: Stage, error: Error?) {
        guard let error else {
            self.init(stage: stage)
            return
        }
        let nsError = error as NSError
        self.init(stage: stage, domain: nsError.domain, code: nsError.code)
    }

    /// The failure as diagnostic fields: stage always, domain only if it
    /// passes the token rule, code if there was one.
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

/// A failure the engine could not recover from on its own, handed to whoever
/// owns the decision about what to try next.
///
/// The `cause` is the engine's verdict about the samples, and it is the whole
/// of what a host needs to decide whether asking for the media a different
/// way could help. The engine does not know what other ways exist.
public nonisolated struct PlaybackEngineFailure: Equatable, Sendable {
    public enum Cause: Equatable, Sendable {
        /// The samples themselves cannot be decoded here — a codec outside
        /// the envelope, a decoder session the hardware declined, a decode
        /// that failed. Only a re-encode changes what the decoder is given.
        case undecodable
        /// The container, the transport, or an AVFoundation object failed.
        /// The same media may well play when it arrives another way.
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
