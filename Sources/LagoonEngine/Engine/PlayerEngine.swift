import CoreMedia
import Foundation
import Observation

/// What the custom player UI is allowed to know about a playback engine.
///
/// The end state is one custom player over a sample-buffer
/// engine; until that exists the mpv engine implements this. The
/// transport/track UI must only ever talk to this protocol so the engine
/// swap doesn't touch it.
@MainActor
protocol PlayerEngine: AnyObject, Observable {
    var timePosition: Double { get }
    /// The media clock as the synchronizer actually reports it. Unlike
    /// `timePosition`, which `seek(to:)` moves optimistically the instant a
    /// scrub commits, this only advances once the clock is anchored — so a
    /// group transport reports where playback *is* rather than where the
    /// viewer just asked it to go.
    var clockPosition: Double { get }
    var duration: Double { get }
    var isPaused: Bool { get }
    var isBuffering: Bool { get }
    /// Requested media-time rate. Pausing stops the clock without discarding
    /// this value, so Play resumes at the viewer's selected speed.
    var rate: Double { get }
    /// Number of renderer underruns recovered during this playback session.
    /// Exposed for the debug regression probe and component preview only.
    var stallCount: Int { get }
    /// AVFoundation audio lifecycle recoveries, exposed to the launch-gated
    /// integration probe so route and media-service events are measurable.
    var audioRendererRecoveryCount: Int { get }
    var mediaServicesResetRecoveryCount: Int { get }
    var videoSize: CGSize? { get }
    var audioTracks: [PlayerTrack] { get }
    /// Debug/regression label for the renderer input, not a user-facing
    /// codec name. Implementations without a distinct path may use unknown.
    var audioOutputPathDiagnostic: String { get }
    /// Debug/regression label for how decoded video reaches the renderer:
    /// "compressed", "videotoolbox", or a software output mode such as
    /// "gpu-sdr-linear".
    var videoOutputPathDiagnostic: String { get }
    /// Times a renderer's media-data request block ran and found nothing to
    /// give. The engine stops requesting when that happens, so this stays
    /// near zero; a runaway count is the half-core loop.
    var idleRequestCallbacks: Int { get }
    /// Renderer-side audio delivery diagnostics. The app
    /// queue is normally empty because AVFoundation takes samples promptly,
    /// so starvation is measured from the last sample actually enqueued to
    /// the renderer instead.
    var audioStarvationCount: Int { get }
    /// Stalls confirmed as audio-caused, a subset of `stallCount`.
    var audioStallCount: Int { get }
    /// Off by default (Settings → Advanced → Playback Diagnostics →
    /// Buffer on Audio Starvation). Read once when the engine is created.
    var buffersOnAudioStarvation: Bool { get }
    var audioDeliveryLeadSeconds: Double { get }
    var audioRendererReadyForPlayback: Bool { get }
    #if DEBUG
    /// Off-by-default fault-injection state exposed to the regression probe.
    var audioDeliverySuspendedForDiagnostics: Bool { get }
    var demuxDeliverySuspendedForDiagnostics: Bool { get }
    #endif
    var videoQueueCountDiagnostic: Int { get }
    var maximumVideoBacklogDiagnostic: Int { get }
    var videoQueueHardLimitDiagnostic: Int { get }
    /// Compressed video parked past the decoded limit while the demuxer
    /// reads on for audio: current count and the session peak.
    var videoIntakeCountDiagnostic: Int { get }
    var maximumVideoIntakeDiagnostic: Int { get }
    var stallReprimeCount: Int { get }
    var subtitleTracks: [PlayerTrack] { get }
    var subtitleLoadState: SubtitleLoadState { get }
    /// Changes on every selection intent, even while a sidecar is loading.
    var subtitleSelectionRevision: Int { get }
    /// The subtitle content on screen right now (M5): joined text lines
    /// and/or decoded bitmap rects, rendered by the player UI as an
    /// overlay. Empty/nil when no cue is active.
    var currentSubtitleText: String? { get }
    /// Individually authored text compositions. Plain subtitles use the
    /// default bottom-centre cue; ASS/SSA can carry independent placement
    /// and inline formatting for simultaneous speakers and signs.
    var currentSubtitleCues: [SubtitleTextCue] { get }
    var currentSubtitleImages: [SubtitleImage] { get }
    /// mpv convention (M6): positive delays the audio relative to video.
    var audioDelay: Double { get }
    /// What the display should be asked to match (tvOS Match Content,
    /// the video's fully tagged format description — colorimetry,
    /// HDR10 metadata, DoVi atoms — plus its frame rate. nil until the
    /// demuxer knows, and when the frame rate is unknowable.
    var displayMatchRequest: DisplayMatchRequest? { get }

    /// Idempotent transport controls are required by system integrations:
    /// interruption, PiP, and Remote Command Center callbacks describe the
    /// desired state rather than asking the app to invert its current one.
    func play()
    func pause()
    func togglePause()
    func setRate(_ rate: Double)
    func seek(by seconds: Double)
    /// Absolute seek, clamped by the engine. Both seeks are optimistic:
    /// `timePosition` lands on the target the instant they're called, so
    /// the transport can commit a scrub without waiting for the demuxer.
    func seek(to seconds: Double)
    /// nil turns the stream off (subtitles); audio pickers shouldn't pass nil.
    func selectAudioTrack(id: Int?)
    func selectSubtitleTrack(id: Int?)
    func retrySubtitleLoad()
    /// Adds a server-downloaded sidecar to the live item and selects it
    /// without rebuilding the renderers or restarting playback.
    func addExternalSubtitle(_ track: ExternalSubtitleTrack)
    func setAudioDelay(_ seconds: Double)
    /// Audio-only playback while the app is in the background.
    func setVideoOutputSuspended(_ suspended: Bool)
    /// Start — or, when already primed and paused, resume — so that the
    /// current media position is presented exactly at `hostTime` on
    /// `CMClockGetHostTimeClock()`. A host time already in the past starts
    /// now. A SyncPlay group start is one host-clock instant every member
    /// agreed on after time sync, so "play, roughly now" is not enough.
    func play(atHostTime hostTime: CMTime)
    /// A sync-correction multiplier applied on top of the viewer's chosen
    /// `rate`. Nudging a member that has drifted from its group must not
    /// change what the speed row and Now Playing say the viewer picked, so
    /// `rate` itself is untouched.
    func setCorrectionRate(_ multiplier: Double)
}

extension PlayerEngine {
    var clockPosition: Double { timePosition }
    func play(atHostTime hostTime: CMTime) { play() }
    func setCorrectionRate(_ multiplier: Double) {}
    var subtitleLoadState: SubtitleLoadState { .idle }
    var subtitleSelectionRevision: Int { 0 }
    func retrySubtitleLoad() {}
    func setVideoOutputSuspended(_ suspended: Bool) {}
    var audioOutputPathDiagnostic: String { "unknown" }
    var videoOutputPathDiagnostic: String { "unknown" }
    var idleRequestCallbacks: Int { 0 }
    var audioStarvationCount: Int { 0 }
    var audioStallCount: Int { 0 }
    var buffersOnAudioStarvation: Bool { false }
    var audioDeliveryLeadSeconds: Double { -1 }
    var audioRendererReadyForPlayback: Bool { false }
    #if DEBUG
    var audioDeliverySuspendedForDiagnostics: Bool { false }
    var demuxDeliverySuspendedForDiagnostics: Bool { false }
    #endif
    var videoQueueCountDiagnostic: Int { 0 }
    var maximumVideoBacklogDiagnostic: Int { 0 }
    var videoQueueHardLimitDiagnostic: Int { 0 }
    var videoIntakeCountDiagnostic: Int { 0 }
    var maximumVideoIntakeDiagnostic: Int { 0 }
    var stallReprimeCount: Int { 0 }
    var audioRendererRecoveryCount: Int { 0 }
    var mediaServicesResetRecoveryCount: Int { 0 }
    var currentSubtitleCues: [SubtitleTextCue] {
        currentSubtitleText.map { [.plain($0)] } ?? []
    }
}

/// The rates Lagoon exposes to its own controls and to Remote Command
/// Center. The engine accepts any finite value inside the same envelope so
/// system integrations do not have to round a supported event twice.
nonisolated enum PlaybackRatePolicy {
    static let supported: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    static let minimum = 0.5
    static let maximum = 2.0

    static func clamped(_ rate: Double) -> Double {
        guard rate.isFinite else { return 1 }
        return min(max(rate, minimum), maximum)
    }

    /// What the media clock actually runs at: the viewer's rate with a sync
    /// correction on top of it. The correction is a nudge for a
    /// group member that has drifted, not a second speed control, so the
    /// product stays inside the one envelope the rest of the engine scales
    /// its cushions and watermarks by. A correction of 1 — the only value
    /// outside a group — returns the viewer's rate unchanged.
    static func effectiveRate(userRate: Double, correction: Double) -> Double {
        let user = clamped(userRate)
        guard correction.isFinite, correction > 0 else { return user }
        return clamped(user * correction)
    }

    /// How a rate is written for the viewer: no trailing zeros, always a
    /// multiplication sign. Lives here so the panel's rows and the readout
    /// beside the player's title cannot drift apart.
    static func title(_ rate: Double) -> String {
        String(format: "%g×", clamped(rate))
    }

    /// Stable identifier for a rate, for accessibility and UI tests.
    static func identifier(_ rate: Double) -> String {
        String(format: "%g", clamped(rate)).replacingOccurrences(of: ".", with: "_")
    }

    /// The adjacent supported rate in `direction`, clamped at both ends.
    ///
    /// Clamped rather than wrapped: the control is a pair of +/- buttons, and
    /// a plus that jumps from 2× to 0.5× would read as a bug rather than as a
    /// wrap. `nearest` first, because the engine accepts anything inside the
    /// envelope — Remote Command Center can hand it 1.1 — so stepping has to
    /// start from a value that may not be in the set.
    static func stepped(from rate: Double, by direction: Int) -> Double {
        let current = clamped(rate)
        guard direction != 0 else { return current }
        if direction > 0 {
            return supported.first { $0 > current + 0.001 } ?? supported[supported.count - 1]
        }
        return supported.last { $0 < current - 0.001 } ?? supported[0]
    }
}

/// What the physical display should be switched to for the current video:
/// tvOS Match Content wants the tagged format description (it
/// derives dynamic range and resolution from it) and the frame rate.
/// Without this request the display stays at its idle mode — typically
/// 60 Hz in whatever range it happens to be in — and the compositor
/// cadence-converts and tone-maps every full-4K HDR frame forever, which
/// is the standing suspect for the 2160p-only frame drops on hardware.
nonisolated struct DisplayMatchRequest: Equatable {
    let formatDescription: CMFormatDescription
    let frameRate: Float

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.frameRate == rhs.frameRate
            && CMFormatDescriptionEqual(lhs.formatDescription, otherFormatDescription: rhs.formatDescription)
    }
}

/// One selectable track as the engine reports it. `engineID` is the
/// engine's own identifier (mpv aid/sid today), unique per kind only.
nonisolated struct PlayerTrack: Identifiable, Equatable {
    enum Kind: String {
        case audio
        case subtitle
    }

    let engineID: Int
    let kind: Kind
    let displayName: String
    let isSelected: Bool
    let languageTag: String?
    let isForced: Bool
    let isHearingImpaired: Bool
    let source: Source

    enum Source: String, Equatable {
        case embedded
        case external
        case downloaded
    }

    init(
        engineID: Int,
        kind: Kind,
        displayName: String,
        isSelected: Bool,
        languageTag: String? = nil,
        isForced: Bool = false,
        isHearingImpaired: Bool = false,
        source: Source = .embedded
    ) {
        self.engineID = engineID
        self.kind = kind
        self.displayName = displayName
        self.isSelected = isSelected
        self.languageTag = languageTag
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.source = source
    }

    var id: String { "\(kind.rawValue)-\(engineID)" }
}

/// Server-authored attributes for an embedded demux track. FFmpeg exposes
/// language/title, but Jellyfin is the authority for accessibility flags;
/// keeping this separate lets the engine merge both sources by ordinal.
nonisolated struct PlayerTrackMetadata: Equatable, Sendable {
    let languageTag: String?
    let isForced: Bool
    let isHearingImpaired: Bool
}

/// A stretch of the item the server has classified — intro, recap, credits.
/// Jellyfin 10.10+ serves these natively from `MediaSegments`,
/// populated by whatever plugin the admin runs.
nonisolated struct MediaSegment: Identifiable, Equatable {
    /// What Jellyfin calls the segment. Only `intro` and `recap` are ever
    /// offered as a skip: `preview` and `commercial` exist in real
    /// libraries — a sampled film carries two `commercial` segments — and
    /// acting on them would raise a skip prompt in the middle of a movie.
    /// `outro` is deliberately not skippable either; the end of an episode
    /// is a hand-off to the next one, not something to jump over.
    enum Kind: String {
        case intro = "Intro"
        case outro = "Outro"
        case recap = "Recap"
        case preview = "Preview"
        case commercial = "Commercial"
        case other

        var isSkippable: Bool { self == .intro || self == .recap }

        /// What the button says. Recap gets its own word — being told
        /// "Skip Intro" over a previously-on montage reads as a bug.
        var skipTitle: String {
            self == .recap ? String(localized: "Skip Recap") : String(localized: "Skip Intro")
        }
    }

    let id: String
    let kind: Kind
    let start: Double
    let end: Double

    func contains(_ seconds: Double) -> Bool {
        seconds >= start && seconds < end
    }
}

/// A chapter mark on the transport.
nonisolated struct PlayerChapter: Identifiable, Equatable {
    /// Position in the chapter list, which is also its display number.
    let id: Int
    let name: String?
    let start: Double
}

/// Everything the transport needs to pull trickplay preview frames: the
/// sheet URLs already resolved (tokens included), plus the grid inside each
/// sheet. Positions map to tiles through `tile(at:)`.
nonisolated struct TrickplaySource: Equatable {
    let sheetURLs: [URL]
    /// One thumbnail's pixel size as the server declared it.
    let tileSize: CGSize
    let columns: Int
    let rows: Int
    /// Seconds between thumbnails (the wire value is milliseconds).
    let interval: Double
    let thumbnailCount: Int
    /// The trickplay route 401s without credentials and `sheetURLs` carry no
    /// query token, so the header credential rides with
    /// the source for `TrickplayLoader` to apply per fetch.
    var authorization: MediaRequestAuthorization? = nil

    var tilesPerSheet: Int { columns * rows }

    /// Which sheet and cell a position lands in, or nil if it falls outside
    /// what the server generated.
    func tile(at seconds: Double) -> TrickplayTile? {
        guard interval > 0, tilesPerSheet > 0, thumbnailCount > 0 else { return nil }
        let index = min(max(Int(seconds / interval), 0), thumbnailCount - 1)
        let sheet = index / tilesPerSheet
        guard sheetURLs.indices.contains(sheet) else { return nil }
        let cell = index % tilesPerSheet
        return TrickplayTile(sheet: sheet, column: cell % columns, row: cell / columns)
    }
}

nonisolated struct TrickplayTile: Equatable {
    let sheet: Int
    let column: Int
    let row: Int
}

/// Everything the player's Info tab and transport show about the item —
/// assembled by the playback controller, engine-independent.
nonisolated struct PlayerItemInfo: Equatable {
    /// Transport headline: the series for episodes, the item otherwise.
    let title: String
    /// Small line above the headline, e.g. "S1 E1 · Freedom Day".
    let subtitle: String?
    let overview: String?
    /// Infuse-style spaced tokens: runtime, year, size, "HEVC (4K DV)",
    /// "Dolby Digital+ 5.1", bitrate, fps, genres, rating.
    let facts: [String]
    /// The Video tab's single read-only line, e.g.
    /// "HEVC · 4K DV · 3840×1600 · 23.976 fps".
    let videoSummary: String?
    let posterURL: URL?
    /// Empty whenever the server has no chapters for the item — the ticks
    /// and chapter jumps simply don't appear.
    var chapters: [PlayerChapter] = []
    /// nil when the server hasn't generated trickplay tiles; the scrub chip
    /// then shows the timestamp alone.
    var trickplay: TrickplaySource?
    /// Empty when the server has no segments for the item.
    var segments: [MediaSegment] = []
}

/// The episode queued behind the one playing, as the Up Next card shows it.
/// Resolved by the host so the player view stays free of the
/// Jellyfin client, exactly as `PlayerItemInfo` is.
nonisolated struct NextUpEpisode: Equatable {
    /// The episode's own name — never the series, which is the one thing
    /// the viewer already knows at this point.
    let title: String
    /// "S1 E4", when the server numbered it.
    let subtitle: String?
    let imageURL: URL?
}

/// A subtitle that lives outside the media file (Jellyfin external stream)
/// for the engine to side-load at start.
nonisolated struct ExternalSubtitleTrack {
    let url: URL
    /// Provider downloads can be played even while Jellyfin's asynchronous
    /// library refresh has not produced a persistent DeliveryUrl yet.
    let preloadedData: Data?
    let title: String?
    let language: String?
    /// Jellyfin's default-subtitle choice pointed at this external stream.
    let select: Bool
    let isForced: Bool
    let isHearingImpaired: Bool
    let isDownloaded: Bool

    init(
        url: URL,
        preloadedData: Data? = nil,
        title: String?,
        language: String?,
        select: Bool,
        isForced: Bool = false,
        isHearingImpaired: Bool = false,
        isDownloaded: Bool = false
    ) {
        self.url = url
        self.preloadedData = preloadedData
        self.title = title
        self.language = language
        self.select = select
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.isDownloaded = isDownloaded
    }
}
