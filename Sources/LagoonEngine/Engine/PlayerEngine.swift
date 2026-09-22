import CoreMedia
import Foundation
import Observation

/// What a host is allowed to know about a playback engine.
///
/// A host's transport and track UI talks to this and never to a concrete
/// engine, which is what keeps FFmpeg's types out of its build and leaves
/// room for a second implementation.
@MainActor
public protocol PlayerEngine: AnyObject, Observable {
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

public extension PlayerEngine {
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
public nonisolated enum PlaybackRatePolicy {
    static public let supported: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    static public let minimum = 0.5
    static public let maximum = 2.0

    static public func clamped(_ rate: Double) -> Double {
        guard rate.isFinite else { return 1 }
        return min(max(rate, minimum), maximum)
    }

    /// What the media clock actually runs at: the viewer's rate with a sync
    /// correction on top of it. The correction is a nudge for a
    /// group member that has drifted, not a second speed control, so the
    /// product stays inside the one envelope the rest of the engine scales
    /// its cushions and watermarks by. A correction of 1 — the only value
    /// outside a group — returns the viewer's rate unchanged.
    static public func effectiveRate(userRate: Double, correction: Double) -> Double {
        let user = clamped(userRate)
        guard correction.isFinite, correction > 0 else { return user }
        return clamped(user * correction)
    }

    /// How a rate is written for the viewer: no trailing zeros, always a
    /// multiplication sign. Lives here so the panel's rows and the readout
    /// beside the player's title cannot drift apart.
    static public func title(_ rate: Double) -> String {
        String(format: "%g×", clamped(rate))
    }

    /// Stable identifier for a rate, for accessibility and UI tests.
    static public func identifier(_ rate: Double) -> String {
        String(format: "%g", clamped(rate)).replacingOccurrences(of: ".", with: "_")
    }

    /// The adjacent supported rate in `direction`, clamped at both ends.
    ///
    /// Clamped rather than wrapped: the control is a pair of +/- buttons, and
    /// a plus that jumps from 2× to 0.5× would read as a bug rather than as a
    /// wrap. `nearest` first, because the engine accepts anything inside the
    /// envelope — Remote Command Center can hand it 1.1 — so stepping has to
    /// start from a value that may not be in the set.
    static public func stepped(from rate: Double, by direction: Int) -> Double {
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
public nonisolated struct DisplayMatchRequest: Equatable {
    public init(
        formatDescription: CMFormatDescription,
        frameRate: Float
    ) {
        self.formatDescription = formatDescription
        self.frameRate = frameRate
    }

    public let formatDescription: CMFormatDescription
    public let frameRate: Float

    static public func == (lhs: Self, rhs: Self) -> Bool {
        lhs.frameRate == rhs.frameRate
            && CMFormatDescriptionEqual(lhs.formatDescription, otherFormatDescription: rhs.formatDescription)
    }
}

/// One selectable track as the engine reports it. `engineID` is the
/// engine's own identifier (mpv aid/sid today), unique per kind only.
public nonisolated struct PlayerTrack: Identifiable, Equatable {
    public enum Kind: String {
        case audio
        case subtitle
    }

    public let engineID: Int
    public let kind: Kind
    public let displayName: String
    public let isSelected: Bool
    public let languageTag: String?
    public let isForced: Bool
    public let isHearingImpaired: Bool
    public let source: Source

    public enum Source: String, Equatable {
        case embedded
        case external
        case downloaded
    }

    public init(
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

    public var id: String { "\(kind.rawValue)-\(engineID)" }
}

/// Server-authored attributes for an embedded demux track. FFmpeg exposes
/// language/title, but Jellyfin is the authority for accessibility flags;
/// keeping this separate lets the engine merge both sources by ordinal.
public nonisolated struct PlayerTrackMetadata: Equatable, Sendable {
    public init(
        languageTag: String? = nil,
        isForced: Bool,
        isHearingImpaired: Bool
    ) {
        self.languageTag = languageTag
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
    }

    public let languageTag: String?
    public let isForced: Bool
    public let isHearingImpaired: Bool
}

/// A stretch of the item the server has classified — intro, recap, credits.
/// Jellyfin 10.10+ serves these natively from `MediaSegments`,
/// populated by whatever plugin the admin runs.
public nonisolated struct MediaSegment: Identifiable, Equatable {
    /// What a server calls the segment; the raw values follow the common
    /// convention. Only `intro` and `recap` are ever
    /// offered as a skip: `preview` and `commercial` exist in real
    /// libraries — a sampled film carries two `commercial` segments — and
    /// acting on them would raise a skip prompt in the middle of a movie.
    /// `outro` is deliberately not skippable either; the end of an episode
    /// is a hand-off to the next one, not something to jump over.
    public enum Kind: String {
        case intro = "Intro"
        case outro = "Outro"
        case recap = "Recap"
        case preview = "Preview"
        case commercial = "Commercial"
        case other

        public var isSkippable: Bool { self == .intro || self == .recap }

        /// What the button says. Recap gets its own word — being told
        /// "Skip Intro" over a previously-on montage reads as a bug.
        public var skipTitle: String {
            self == .recap ? String(localized: "Skip Recap") : String(localized: "Skip Intro")
        }
    }

    public let id: String
    public let kind: Kind
    public let start: Double
    public let end: Double

    public init(id: String, kind: Kind, start: Double, end: Double) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
    }

    public func contains(_ seconds: Double) -> Bool {
        seconds >= start && seconds < end
    }
}

/// A chapter mark on the transport.
public nonisolated struct PlayerChapter: Identifiable, Equatable {
    public init(
        id: Int,
        name: String? = nil,
        start: Double
    ) {
        self.id = id
        self.name = name
        self.start = start
    }

    /// Position in the chapter list, which is also its display number.
    public let id: Int
    public let name: String?
    public let start: Double
}

/// Everything the transport needs to pull trickplay preview frames: the
/// sheet URLs already resolved (tokens included), plus the grid inside each
/// sheet. Positions map to tiles through `tile(at:)`.
public nonisolated struct TrickplaySource: Equatable {
    public let sheetURLs: [URL]
    /// One thumbnail's pixel size as the server declared it.
    public let tileSize: CGSize
    public let columns: Int
    public let rows: Int
    /// Seconds between thumbnails (the wire value is milliseconds).
    public let interval: Double
    public let thumbnailCount: Int
    /// The trickplay route 401s without credentials and `sheetURLs` carry no
    /// query token, so the header credential rides with
    /// the source for `TrickplayLoader` to apply per fetch.
    public var authorization: MediaRequestAuthorization? = nil

    public init(
        sheetURLs: [URL],
        tileSize: CGSize,
        columns: Int,
        rows: Int,
        interval: Double,
        thumbnailCount: Int,
        authorization: MediaRequestAuthorization? = nil
    ) {
        self.sheetURLs = sheetURLs
        self.tileSize = tileSize
        self.columns = columns
        self.rows = rows
        self.interval = interval
        self.thumbnailCount = thumbnailCount
        self.authorization = authorization
    }

    public var tilesPerSheet: Int { columns * rows }

    /// Which sheet and cell a position lands in, or nil if it falls outside
    /// what the server generated.
    public func tile(at seconds: Double) -> TrickplayTile? {
        guard interval > 0, tilesPerSheet > 0, thumbnailCount > 0 else { return nil }
        let index = min(max(Int(seconds / interval), 0), thumbnailCount - 1)
        let sheet = index / tilesPerSheet
        guard sheetURLs.indices.contains(sheet) else { return nil }
        let cell = index % tilesPerSheet
        return TrickplayTile(sheet: sheet, column: cell % columns, row: cell / columns)
    }
}

public nonisolated struct TrickplayTile: Equatable {
    public let sheet: Int
    public let column: Int
    public let row: Int
}

/// Everything the player's Info tab and transport show about the item —
/// assembled by the playback controller, engine-independent.
public nonisolated struct PlayerItemInfo: Equatable {
    public init(
        title: String,
        subtitle: String? = nil,
        overview: String? = nil,
        facts: [String],
        videoSummary: String? = nil,
        posterURL: URL? = nil,
        chapters: [PlayerChapter] = [],
        trickplay: TrickplaySource? = nil,
        segments: [MediaSegment] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.overview = overview
        self.facts = facts
        self.videoSummary = videoSummary
        self.posterURL = posterURL
        self.chapters = chapters
        self.trickplay = trickplay
        self.segments = segments
    }

    /// Transport headline: the series for episodes, the item otherwise.
    public let title: String
    /// Small line above the headline, e.g. "S1 E1 · Freedom Day".
    public let subtitle: String?
    public let overview: String?
    /// Infuse-style spaced tokens: runtime, year, size, "HEVC (4K DV)",
    /// "Dolby Digital+ 5.1", bitrate, fps, genres, rating.
    public let facts: [String]
    /// The Video tab's single read-only line, e.g.
    /// "HEVC · 4K DV · 3840×1600 · 23.976 fps".
    public let videoSummary: String?
    public let posterURL: URL?
    /// Empty whenever the server has no chapters for the item — the ticks
    /// and chapter jumps simply don't appear.
    public var chapters: [PlayerChapter] = []
    /// nil when the server hasn't generated trickplay tiles; the scrub chip
    /// then shows the timestamp alone.
    public var trickplay: TrickplaySource?
    /// Empty when the server has no segments for the item.
    public var segments: [MediaSegment] = []
}

/// The episode queued behind the one playing, as the Up Next card shows it.
/// Resolved by the host so the player view stays free of the
/// Jellyfin client, exactly as `PlayerItemInfo` is.
public nonisolated struct NextUpEpisode: Equatable {
    public init(
        title: String,
        subtitle: String? = nil,
        imageURL: URL? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
    }

    /// The episode's own name — never the series, which is the one thing
    /// the viewer already knows at this point.
    public let title: String
    /// "S1 E4", when the server numbered it.
    public let subtitle: String?
    public let imageURL: URL?
}

/// A subtitle that lives outside the media file (Jellyfin external stream)
/// for the engine to side-load at start.
public nonisolated struct ExternalSubtitleTrack {
    public let url: URL
    /// Provider downloads can be played even while Jellyfin's asynchronous
    /// library refresh has not produced a persistent DeliveryUrl yet.
    public let preloadedData: Data?
    public let title: String?
    public let language: String?
    /// Jellyfin's default-subtitle choice pointed at this external stream.
    public let select: Bool
    public let isForced: Bool
    public let isHearingImpaired: Bool
    public let isDownloaded: Bool

    public init(
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
