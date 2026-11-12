/// How text subtitles look when the engine draws them into the picture
/// itself, for Picture in Picture, where a host's own overlay is not shown.
/// Bitmap and styled (ASS) tracks keep their own look.
public nonisolated struct BurnedInSubtitleStyle: Sendable, Equatable {
    public enum Edge: Sendable, Equatable {
        case none
        case outline
        case dropShadow
    }

    public var textColor: SubtitleTextColor
    public var edgeColor: SubtitleTextColor
    public var edge: Edge
    /// Drawn behind each cue; its alpha is the box's opacity.
    public var backgroundColor: SubtitleTextColor
    /// Line height as a fraction of the picture's height, drawn within
    /// 0.01 to 0.25. A value that is not finite draws at the default.
    public var relativeSize: Double
    /// A PostScript or family name. Nil uses the system font.
    public var fontName: String?

    public init(
        textColor: SubtitleTextColor = SubtitleTextColor(red: 255, green: 255, blue: 255, alpha: 255),
        edgeColor: SubtitleTextColor = SubtitleTextColor(red: 0, green: 0, blue: 0, alpha: 242),
        edge: Edge = .dropShadow,
        backgroundColor: SubtitleTextColor = SubtitleTextColor(red: 0, green: 0, blue: 0, alpha: 89),
        relativeSize: Double = 0.055,
        fontName: String? = nil
    ) {
        self.textColor = textColor
        self.edgeColor = edgeColor
        self.edge = edge
        self.backgroundColor = backgroundColor
        self.relativeSize = relativeSize
        self.fontName = fontName
    }

    public static let standard = BurnedInSubtitleStyle()

    static let relativeSizeRange = 0.01...0.25

    /// A host working the fraction out from a view not yet laid out passes
    /// infinity or NaN, and points passed as a fraction ask for a block of
    /// gigabytes.
    var drawnRelativeSize: Double {
        guard relativeSize.isFinite else { return Self.standard.relativeSize }
        return min(max(relativeSize, Self.relativeSizeRange.lowerBound), Self.relativeSizeRange.upperBound)
    }
}
