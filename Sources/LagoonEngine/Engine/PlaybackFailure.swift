import Foundation

/// Where a playback attempt failed, in codes rather than prose.
///
/// Deliberately carries no message and nothing out of an error's `userInfo`,
/// which is where URLs, file names and query strings live. A host that
/// reports failures onward gets a stage, a domain token and a code, and
/// nothing that could identify a viewer or a title.
nonisolated struct PlaybackFailureDetail: Equatable, Sendable {
    enum Stage: String, Sendable {
        case negotiate, open, seek, read, decode, videoRenderer, audioRenderer, subtitle, cache, start, handoff, unknown
    }

    let stage: Stage
    /// A token such as `AVFoundationErrorDomain`, `VideoToolbox`, `ffmpeg`,
    /// or `NSURLErrorDomain`. Nil when the layer gave none.
    let domain: String?
    let code: Int?

    init(stage: Stage, domain: String? = nil, code: Int? = nil) {
        self.stage = stage
        self.domain = domain
        self.code = code
    }

    /// Domain and code from any error, and nothing else from it: not the
    /// description, not `userInfo`, which is where URLs and file names live.
    init(stage: Stage, error: Error?) {
        guard let error else {
            self.init(stage: stage)
            return
        }
        let nsError = error as NSError
        self.init(stage: stage, domain: nsError.domain, code: nsError.code)
    }
}

/// A failure the engine could not recover from on its own, handed to whoever
/// owns the decision about what to try next.
///
/// The `cause` is the engine's verdict about the samples, and it is the whole
/// of what a host needs to decide whether asking for the media a different
/// way could help. The engine does not know what other ways exist.
nonisolated struct PlaybackEngineFailure: Equatable, Sendable {
    enum Cause: Equatable, Sendable {
        /// The samples themselves cannot be decoded here — a codec outside
        /// the envelope, a decoder session the hardware declined, a decode
        /// that failed. Only a re-encode changes what the decoder is given.
        case undecodable
        /// The container, the transport, or an AVFoundation object failed.
        /// The same media may well play when it arrives another way.
        case delivery
    }

    let cause: Cause
    /// What the viewer is told if the host runs out of things to try.
    let message: String
    /// The same failure in codes, for a diagnostic report. Never the message.
    let detail: PlaybackFailureDetail?

    init(cause: Cause, message: String, detail: PlaybackFailureDetail? = nil) {
        self.cause = cause
        self.message = message
        self.detail = detail
    }
}
