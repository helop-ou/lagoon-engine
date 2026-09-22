import Foundation

/// What is wrong with a subtitle file the engine was handed.
///
/// Only the failures that are a property of the bytes themselves. Why a
/// server refused to supply them — an expired session, a missing permission,
/// a provider that ran out of downloads — is the host's to describe, because
/// the host is the only party that knows what it asked and of whom.
public nonisolated enum SubtitleFileError: LocalizedError, Equatable {
    /// Past the byte ceiling a subtitle is allowed to occupy.
    case tooLarge
    /// Parsed, but nothing in it was a cue. Usually the wrong file entirely.
    case unsupportedFile
    /// Not a subtitle at all — most often an HTML error page served with a
    /// success status.
    case invalidFile

    public var errorDescription: String? {
        switch self {
        case .tooLarge:
            "This subtitle file is too large to load."
        case .unsupportedFile:
            "This subtitle file is in a format Lagoon cannot read."
        case .invalidFile:
            "This file is not a subtitle."
        }
    }
}
