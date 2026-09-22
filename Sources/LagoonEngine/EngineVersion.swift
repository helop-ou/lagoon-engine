import Foundation
import Libavformat

/// What this package is, for a host's About screen and its crash reports.
///
/// SwiftPM gives a consumer no way to read the version of a package it
/// resolved, so the number lives here and moves with the git tag a release
/// is cut from. The two must change together: see "Releasing" in the
/// contributing guide.
public nonisolated enum EngineVersion {
    /// This package's own version, as its tag spells it.
    public static let current = "1.0.1"

    /// The linked libavformat, as `lavf<major>.<minor>.<micro>`.
    ///
    /// Versioned upstream and independently of this package, so a report
    /// naming only one of the two cannot say which demuxer produced it — the
    /// same engine version can be built against a different FFmpeg.
    public static var ffmpeg: String {
        let version = avformat_version()
        return "lavf\(version >> 16).\((version >> 8) & 0xFF).\(version & 0xFF)"
    }

    /// Both, for a single diagnostic field: `1.0.0 (lavf61.7.100)`.
    public static var summary: String { "\(current) (\(ffmpeg))" }
}
