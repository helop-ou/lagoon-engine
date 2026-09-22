import Foundation

nonisolated enum SubtitleLoadState: Equatable {
    case idle
    case loading(id: Int, title: String)
    case failed(id: Int, title: String, message: String)
}

nonisolated enum ExternalSubtitleLoader {
    /// `authorization` attaches the session credential as a header rather
    /// than letting it ride in `track.url`'s query — Jellyfin delivery URLs
    /// can arrive with a legacy `api_key`, and any URL is otherwise a
    /// potential unified-log leak if the request fails.
    static func load(
        _ track: ExternalSubtitleTrack,
        using downloader: BoundedDownload,
        authorization: MediaRequestAuthorization? = nil
    ) async throws -> [SubtitleCue] {
        let data: Data
        if let preloaded = track.preloadedData {
            data = preloaded
        } else {
            let request = authorization?.request(for: track.url, timeoutInterval: 30) ?? {
                var request = URLRequest(url: track.url)
                request.timeoutInterval = 30
                return request
            }()
            data = try await downloader.data(for: request, limit: DownloadLimit.subtitle, content: .subtitle)
        }
        return try await parse(data, language: track.language)
    }

    static func parse(_ data: Data, language: String?) async throws -> [SubtitleCue] {
        try Task.checkCancellation()
        guard data.count <= DownloadLimit.subtitle else { throw SubtitleDownloadError.tooLarge }
        let parsing = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let prefix = SubtitleTextDecoder.text(from: Data(data.prefix(1_024)), languageHint: language)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if ["<!doctype html", "<html", "<head", "<body"].contains(where: prefix.hasPrefix) {
                throw SubtitleDownloadError.invalidFile
            }
            let cues = SubtitleParser.cues(from: data, languageHint: language)
            try Task.checkCancellation()
            guard !cues.isEmpty else { throw SubtitleDownloadError.unsupportedFile }
            return cues
        }
        return try await withTaskCancellationHandler {
            let cues = try await parsing.value
            try Task.checkCancellation()
            return cues
        } onCancel: { parsing.cancel() }
    }

    /// External sidecars may come from a CDN or another service. Do not
    /// mislabel their access failures as a Jellyfin account being expired.
    static func message(for error: Error) -> String {
        if let failure = error as? DownloadFailure {
            switch failure {
            case .httpStatus(let status, _):
                switch status {
                case 401, 403: return "The server rejected access to this subtitle (\(status)). Check your sign-in or ask the server administrator."
                case 404, 410: return "This subtitle file is no longer available. Choose another track or try again."
                default: return "The subtitle server returned an error (\(status)). Try again."
                }
            case .tooLarge: return SubtitleDownloadError.tooLarge.localizedDescription
            case .unsafeRedirect: return "The subtitle download redirected to an insecure or unsupported address."
            case .invalidResponse, .unexpectedContentType, .truncated:
                return "The server returned an incomplete or unreadable subtitle file. Choose another track or try again."
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut: return "The subtitle download timed out. Try again."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return "A secure connection to the subtitle server could not be verified."
            default: return "The subtitle file could not be downloaded. Check your connection and try again."
            }
        }
        if let subtitle = error as? SubtitleDownloadError {
            if subtitle == .unsupportedFile || subtitle == .invalidFile {
                return "This file contains no readable subtitle cues. Choose another track or try again."
            }
            return subtitle.localizedDescription
        }
        return "The subtitle file could not be loaded. Choose another track or try again."
    }
}
