import Foundation

/// What is wrong with a subtitle file's bytes. Why a server refused to supply
/// them is the host's to describe.
nonisolated enum SubtitleFileError: LocalizedError, Equatable {
    /// Past the byte ceiling a subtitle is allowed to occupy.
    case tooLarge
    /// Parsed, but nothing in it was a cue. Usually the wrong file entirely.
    case unsupportedFile
    /// Not a subtitle at all, most often an HTML error page sent with a success
    /// status.
    case invalidFile

    var errorDescription: String? {
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
