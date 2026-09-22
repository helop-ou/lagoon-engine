import CoreMedia
import Foundation
import Observation

/// What a host is allowed to know about a playback engine.
///
/// Host UI talks only to this, never to a concrete engine, which keeps
/// FFmpeg's types out of the host's build.
@MainActor
public protocol PlayerEngine: AnyObject, Observable {
    /// Playback position in seconds. Jumps as soon as a seek is asked for; use
    /// `clockPosition` for what is actually presented.
    var timePosition: Double { get }
    /// The synchronizer's clock. Unlike `timePosition`, it moves only once the
    /// clock is anchored, so it is where playback *is*.
    var clockPosition: Double { get }
    /// How long the media is, in seconds. Zero until the container says.
    var duration: Double { get }
    /// Whether the viewer has paused. A stall is not a pause; see `isBuffering`.
    var isPaused: Bool { get }
    /// Whether playback is stopped waiting for data rather than for the viewer.
    var isBuffering: Bool { get }
    /// Requested rate. Survives a pause, so Play resumes at the chosen speed.
    var rate: Double { get }
    /// Renderer underruns recovered this session. Diagnostic.
    var stallCount: Int { get }
    /// Audio renderer recoveries after route or media-service events.
    var audioRendererRecoveryCount: Int { get }
    /// Rebuilds after the system reset its media services.
    var mediaServicesResetRecoveryCount: Int { get }
    /// The picture's size in pixels, or nil before the first frame is decoded.
    var videoSize: CGSize? { get }
    /// Every audio track the container offers, in the order it lists them.
    var audioTracks: [PlayerTrack] { get }
    /// Diagnostic label for the audio renderer input; not a codec name.
    var audioOutputPathDiagnostic: String { get }
    /// Diagnostic label for the video path: "compressed", "videotoolbox",
    /// or a software mode such as "gpu-sdr-linear".
    var videoOutputPathDiagnostic: String { get }
    /// Request-block callbacks that found nothing to give. Should stay near
    /// zero; a runaway count is a busy loop burning half a core.
    var idleRequestCallbacks: Int { get }
    /// Audio starvations, measured from the last sample enqueued to the
    /// renderer (the engine's own queue is normally empty).
    var audioStarvationCount: Int { get }
    /// Stalls confirmed as audio-caused, a subset of `stallCount`.
    var audioStallCount: Int { get }
    /// Whether audio starvation triggers buffering. Off by default; read once
    /// at creation.
    var buffersOnAudioStarvation: Bool { get }
    /// Audio buffered ahead of the clock. Near zero means audio is starving.
    var audioDeliveryLeadSeconds: Double { get }
    /// Whether the audio renderer has enough to start without stuttering.
    var audioRendererReadyForPlayback: Bool { get }
    #if DEBUG
    /// Fault injection for tests; false in normal use.
    var audioDeliverySuspendedForDiagnostics: Bool { get }
    /// Whether delivery to the demuxer is held. Test hook; false in normal use.
    var demuxDeliverySuspendedForDiagnostics: Bool { get }
    #endif
    /// Decoded video frames waiting to be shown.
    var videoQueueCountDiagnostic: Int { get }
    /// The largest that backlog has been during this playback.
    var maximumVideoBacklogDiagnostic: Int { get }
    /// The backlog cap; at it, the demuxer waits.
    var videoQueueHardLimitDiagnostic: Int { get }
    /// Compressed video read ahead of the decoded limit to reach audio.
    var videoIntakeCountDiagnostic: Int { get }
    /// The largest that intake has been during this playback.
    var maximumVideoIntakeDiagnostic: Int { get }
    /// How many times playback has restarted itself after a stall.
    var stallReprimeCount: Int { get }
    /// Every subtitle track on offer, embedded and side-loaded together.
    var subtitleTracks: [PlayerTrack] { get }
    var subtitleLoadState: SubtitleLoadState { get }
    /// Changes on every selection intent, even while a sidecar is loading.
    var subtitleSelectionRevision: Int { get }
    /// The subtitle text on screen now, or nil when no cue is active.
    var currentSubtitleText: String? { get }
    /// Positioned text cues. Plain subtitles use one bottom-centre cue;
    /// ASS/SSA can place several with inline formatting.
    var currentSubtitleCues: [SubtitleTextCue] { get }
    var currentSubtitleImages: [SubtitleImage] { get }
    /// Seconds; positive delays audio relative to video.
    var audioDelay: Double { get }
    /// What the byte cache is holding, for a scrub bar's buffered ranges.
    /// `.empty` for an engine that caches nothing, and for a local file.
    var bufferState: PlaybackBufferState { get }
    /// What the display should match (tvOS Match Content). nil until the
    /// demuxer knows, or when the frame rate is unknown.
    var displayMatchRequest: DisplayMatchRequest? { get }

    /// Idempotent: system callbacks (interruption, PiP, Remote Command
    /// Center) state the desired state, not a toggle.
    func play()
    func pause()
    func togglePause()
    func setRate(_ rate: Double)
    func seek(by seconds: Double)
    /// Absolute seek, clamped. Both seeks move `timePosition` at once.
    func seek(to seconds: Double)
    /// nil turns the stream off (subtitles); audio pickers shouldn't pass nil.
    func selectAudioTrack(id: Int?)
    func selectSubtitleTrack(id: Int?)
    func retrySubtitleLoad()
    /// Adds and selects a sidecar subtitle without restarting playback.
    func addExternalSubtitle(_ track: ExternalSubtitleTrack)
    func setAudioDelay(_ seconds: Double)
    /// Audio-only playback while the app is in the background.
    func setVideoOutputSuspended(_ suspended: Bool)
    /// Starts or resumes so the current position is presented exactly at
    /// `hostTime` on `CMClockGetHostTimeClock()`; a past time starts now.
    /// For group playback, where members agree on one instant.
    func play(atHostTime hostTime: CMTime)
    /// A sync-correction multiplier on top of `rate`, which it leaves
    /// untouched so the UI still shows the viewer's choice.
    func setCorrectionRate(_ multiplier: Double)
}

public extension PlayerEngine {
    var clockPosition: Double { timePosition }
    func play(atHostTime hostTime: CMTime) { play() }
    func setCorrectionRate(_ multiplier: Double) {}
    var subtitleLoadState: SubtitleLoadState { .idle }
    var bufferState: PlaybackBufferState { .empty }
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

/// Playback rates offered to controls. The engine accepts any finite value
/// inside the same envelope.
public nonisolated enum PlaybackRatePolicy {
    static public let supported: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    static public let minimum = 0.5
    static public let maximum = 2.0

    static public func clamped(_ rate: Double) -> Double {
        guard rate.isFinite else { return 1 }
        return min(max(rate, minimum), maximum)
    }

    /// The clock's real rate: the viewer's rate times the sync correction,
    /// clamped to the envelope the engine's cushions are scaled by.
    static public func effectiveRate(userRate: Double, correction: Double) -> Double {
        let user = clamped(userRate)
        guard correction.isFinite, correction > 0 else { return user }
        return clamped(user * correction)
    }

    /// A rate for display, e.g. "1.5×". One place, so every readout agrees.
    static public func title(_ rate: Double) -> String {
        String(format: "%g×", clamped(rate))
    }

    /// Stable identifier for a rate, for accessibility and UI tests.
    static public func identifier(_ rate: Double) -> String {
        String(format: "%g", clamped(rate)).replacingOccurrences(of: ".", with: "_")
    }

    /// The adjacent supported rate in `direction`, clamped, not wrapped.
    /// `rate` may be off the list (e.g. 1.1 from Remote Command Center).
    static public func stepped(from rate: Double, by direction: Int) -> Double {
        let current = clamped(rate)
        guard direction != 0 else { return current }
        if direction > 0 {
            return supported.first { $0 > current + 0.001 } ?? supported[supported.count - 1]
        }
        return supported.last { $0 < current - 0.001 } ?? supported[0]
    }
}

/// The display mode to request for the current video (tvOS Match Content):
/// the tagged format description and the frame rate. Without it the display
/// stays in its idle mode and the compositor converts every frame.
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

/// One selectable track as the engine reports it.
public nonisolated struct PlayerTrack: Identifiable, Equatable {
    public enum Kind: String {
        case audio
        case subtitle
    }

    /// Pass back to select the track. Unique per kind, this playback only.
    public let engineID: Int
    /// Whether this is audio or subtitles.
    public let kind: Kind
    /// What to show a viewer; already disambiguated.
    public let displayName: String
    /// Whether this track is the one currently playing.
    public let isSelected: Bool
    /// The track's language, or nil when the container does not say.
    public let languageTag: String?
    /// Forced: signs and songs rather than dialogue.
    public let isForced: Bool
    /// Whether the track is marked for viewers who are deaf or hard of hearing.
    public let isHearingImpaired: Bool
    /// Where the track came from: inside the file, side-loaded, or downloaded.
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

/// Host-supplied attributes for an embedded track, merged by ordinal with
/// what FFmpeg reads. The host is the authority on accessibility flags.
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

    /// The track's language, or nil when the container does not say.
    public let languageTag: String?
    /// Forced: signs and songs rather than dialogue.
    public let isForced: Bool
    /// Whether the track is marked for viewers who are deaf or hard of hearing.
    public let isHearingImpaired: Bool
}

/// A classified stretch of the item: intro, recap, credits.
public nonisolated struct MediaSegment: Identifiable, Equatable {
    /// The segment type. Only `intro` and `recap` are skippable: real films
    /// carry `commercial` segments mid-movie, and an `outro` hands off to the
    /// next episode instead.
    public enum Kind: String {
        case intro = "Intro"
        case outro = "Outro"
        case recap = "Recap"
        case preview = "Preview"
        case commercial = "Commercial"
        case other

        public var isSkippable: Bool { self == .intro || self == .recap }

        /// The skip button's title.
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
    /// What to call the chapter, if the container named it.
    public let name: String?
    /// Where the chapter begins, in seconds.
    public let start: Double
}

/// Trickplay preview sheets: resolved URLs plus each sheet's grid.
/// `tile(at:)` maps a position to a tile.
public nonisolated struct TrickplaySource: Equatable {
    public let sheetURLs: [URL]
    /// One thumbnail's pixel size as the server declared it.
    public let tileSize: CGSize
    public let columns: Int
    public let rows: Int
    /// Seconds between thumbnails (the wire value is milliseconds).
    public let interval: Double
    public let thumbnailCount: Int
    /// Header credential `TrickplayLoader` applies per fetch; the URLs carry
    /// no token and the route refuses requests without one.
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

/// What the player's Info tab and transport show about the item.
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
    /// A synopsis to show while the picture is loading, if there is one.
    public let overview: String?
    /// Short tokens: runtime, year, "HEVC (4K DV)", "Dolby Digital+ 5.1", …
    public let facts: [String]
    /// One line, e.g. "HEVC · 4K DV · 3840×1600 · 23.976 fps".
    public let videoSummary: String?
    /// Artwork for the system's Now Playing panel, if there is any.
    public let posterURL: URL?
    /// Empty when the item has no chapters.
    public var chapters: [PlayerChapter] = []
    /// nil when there are no trickplay tiles.
    public var trickplay: TrickplaySource?
    /// Empty when the server has no segments for the item.
    public var segments: [MediaSegment] = []
}

/// The episode queued next, as the Up Next card shows it.
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

    /// The episode's name, never the series.
    public let title: String
    /// "S1 E4", when the server numbered it.
    public let subtitle: String?
    public let imageURL: URL?
}

/// A subtitle outside the media file, side-loaded at start.
public nonisolated struct ExternalSubtitleTrack {
    /// Where to fetch the subtitle file.
    public let url: URL
    /// The file's bytes, when the host already has them and `url` may not
    /// serve them yet.
    public let preloadedData: Data?
    /// What to call it in a track list.
    public let title: String?
    /// Its language, if known.
    public let language: String?
    /// Whether to select it at start.
    public let select: Bool
    /// Forced: signs and songs rather than dialogue.
    public let isForced: Bool
    /// Whether the track is marked for viewers who are deaf or hard of hearing.
    public let isHearingImpaired: Bool
    /// Whether the file is already on disk rather than to be fetched.
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
