import Foundation
import Libavformat

/// This package's identity, for a host's About screen and crash reports.
/// SwiftPM cannot tell a consumer a package's version, so it lives here and
/// must move with the release tag: see "Releasing" in the contributing guide.
public nonisolated enum EngineVersion {
    /// This package's own version, as its tag spells it.
    public static let current = "1.0.4"

    /// The linked libavformat, as `lavf<major>.<minor>.<micro>`. The same
    /// engine version can be built against a different FFmpeg, so reports name
    /// both.
    public static var ffmpeg: String {
        let version = avformat_version()
        return "lavf\(version >> 16).\((version >> 8) & 0xFF).\(version & 0xFF)"
    }

    /// Both, for a single diagnostic field: `1.0.0 (lavf61.7.100)`.
    public static var summary: String { "\(current) (\(ffmpeg))" }
}
