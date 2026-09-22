import CoreGraphics
import Foundation

// Subtitle model shared by the demuxed (embedded) and
// downloaded (Jellyfin external) paths. Cues render as a SwiftUI overlay
// in the player — nothing here touches the sample-buffer renderers.

/// One decoded bitmap (PGS/VobSub) with its position, normalized to the
/// subtitle plane so the overlay can scale it onto the displayed video.
nonisolated struct SubtitleImage: Equatable {
    let image: CGImage
    let rect: CGRect

    static func == (lhs: SubtitleImage, rhs: SubtitleImage) -> Bool {
        lhs.image === rhs.image && lhs.rect == rhs.rect
    }
}

/// An authored ASS/SSA alignment, using the format's numeric-keypad layout.
/// The value is kept independent of SwiftUI so parsing remains testable and
/// safe on the demux queue.
nonisolated enum SubtitleTextAlignment: Int, Equatable, Sendable {
    case bottomLeft = 1
    case bottomCenter = 2
    case bottomRight = 3
    case middleLeft = 4
    case middleCenter = 5
    case middleRight = 6
    case topLeft = 7
    case topCenter = 8
    case topRight = 9
}

/// A point on the ASS script plane, normalized before it crosses from the
/// decoder to the UI. The overlay can therefore map it onto the displayed
/// presentation rect, including anamorphic sources.
nonisolated struct SubtitleTextPosition: Equatable, Sendable {
    let x: Double
    let y: Double
}

/// ASS primary colour after its BGR/inverted-alpha representation has been
/// converted to ordinary RGBA bytes.
nonisolated struct SubtitleTextColor: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8
}

/// One inline-styled span. Keeping formatting on runs rather than on the
/// whole event preserves mid-line emphasis without taking on a full libass
/// renderer, karaoke timing, drawing commands, or transforms.
nonisolated struct SubtitleTextRun: Equatable, Sendable {
    let text: String
    let primaryColor: SubtitleTextColor?
    let isBold: Bool
    let isItalic: Bool

    init(
        text: String,
        primaryColor: SubtitleTextColor? = nil,
        isBold: Bool = false,
        isItalic: Bool = false
    ) {
        self.text = text
        self.primaryColor = primaryColor
        self.isBold = isBold
        self.isItalic = isItalic
    }
}

/// A text composition that must stay independent from simultaneous cues.
/// Joining these into one string is what used to stack left/right speakers
/// and move authored signs to the dialogue shelf.
nonisolated struct SubtitleTextCue: Equatable, Sendable {
    let runs: [SubtitleTextRun]
    let alignment: SubtitleTextAlignment?
    let position: SubtitleTextPosition?

    static func plain(_ text: String) -> SubtitleTextCue {
        SubtitleTextCue(
            runs: [SubtitleTextRun(text: text)],
            alignment: nil,
            position: nil
        )
    }

    var text: String { runs.map(\.text).joined() }

    var usesDefaultStyle: Bool {
        runs.allSatisfy { $0.primaryColor == nil && !$0.isBold && !$0.isItalic }
    }

    var usesDefaultPlacement: Bool { alignment == nil && position == nil }
}

nonisolated struct SubtitleCue {
    let start: Double
    /// `.infinity` marks an open-ended cue (the PGS norm: display until
    /// the next composition event) — the store closes it on the next event.
    var end: Double
    let textCues: [SubtitleTextCue]
    let images: [SubtitleImage]

    /// Compatibility projection for parsers/tests and accessibility. The
    /// renderer consumes `textCues` so authored compositions stay separate.
    var text: String? {
        let joined = textCues.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    init(start: Double, end: Double, text: String?, images: [SubtitleImage]) {
        self.init(
            start: start,
            end: end,
            textCues: text.map { [.plain($0)] } ?? [],
            images: images
        )
    }

    init(start: Double, end: Double, textCues: [SubtitleTextCue], images: [SubtitleImage]) {
        self.start = start
        self.end = end
        self.textCues = textCues
        self.images = images
    }
}

/// What one demuxed subtitle packet decodes to.
nonisolated enum SubtitleEvent {
    case cue(SubtitleCue)
    /// An empty composition (PGS clear screen): close open cues here.
    case clear(at: Double)
}

/// The demux loop appends embedded cues; display refresh releases them as
/// they expire. Seeking an embedded track resets this window and re-demuxes
/// it. Downloaded tracks retain their complete timeline for backward seeks.
/// Every mutable field is protected by `lock`, including the lookup cursor;
/// no caller receives a reference to mutable storage.
nonisolated final class SubtitleStore: @unchecked Sendable {
    private enum Source {
        case embedded
        case external
    }

    private let lock = NSLock()
    private var source: Source = .embedded
    private var cues: [SubtitleCue] = []
    private var externalNextIndex = 0
    private var externalActiveIndices: [Int] = []
    private var externalLastSeconds: Double?

    func add(_ cue: SubtitleCue) {
        lock.lock()
        defer { lock.unlock() }
        guard source == .embedded else { return }
        closeOpenCuesLocked(at: cue.start)
        cues.append(cue)
    }

    func closeOpenCues(at seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard source == .embedded else { return }
        closeOpenCuesLocked(at: seconds)
    }

    func replaceExternalTrack(with newCues: [SubtitleCue]) {
        // Sorting is independent of the live store and must not hold up the
        // display tick's lock. Preserve authored order at equal timestamps.
        let sorted = newCues.enumerated().sorted {
            $0.element.start == $1.element.start
                ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
        lock.lock()
        source = .external
        cues = sorted
        resetExternalCursorLocked()
        lock.unlock()
    }

    /// Call when selecting an embedded track or seeking it. The engine
    /// serializes this reset against demux writes using its seek generation.
    func resetForEmbeddedPlayback() {
        lock.lock()
        source = .embedded
        cues.removeAll()
        resetExternalCursorLocked()
        lock.unlock()
    }

    /// Soak diagnostic: how many cues the store is holding, so a
    /// growing embedded window is visible alongside the other DecodeTrace
    /// figures. External tracks intentionally retain their full cue count.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cues.count
    }

    func active(at seconds: Double) -> (textCues: [SubtitleTextCue], images: [SubtitleImage]) {
        lock.lock()
        defer { lock.unlock() }
        guard seconds.isFinite else { return ([], []) }
        var textCues: [SubtitleTextCue] = []
        var images: [SubtitleImage] = []
        switch source {
        case .embedded:
            // Remove the elements themselves so expired CGImages
            // are released, not just skipped behind an advancing index.
            // Only the demuxer's current read-ahead window remains to scan;
            // future and overlapping/open-ended compositions stay intact.
            cues.removeAll { $0.end <= seconds }
            for cue in cues where cue.start <= seconds && seconds < cue.end {
                textCues.append(contentsOf: cue.textCues)
                images.append(contentsOf: cue.images)
            }
        case .external:
            updateExternalCursorLocked(at: seconds)
            for index in externalActiveIndices {
                textCues.append(contentsOf: cues[index].textCues)
                images.append(contentsOf: cues[index].images)
            }
        }
        return (textCues, images)
    }

    private func resetExternalCursorLocked() {
        externalNextIndex = 0
        externalActiveIndices.removeAll()
        externalLastSeconds = nil
    }

    private func updateExternalCursorLocked(at seconds: Double) {
        if let previous = externalLastSeconds, seconds < previous {
            resetExternalCursorLocked()
        }
        externalActiveIndices.removeAll { cues[$0].end <= seconds }
        // Each cue is visited once during forward playback. Rebuild only
        // when time moves backward; retaining the full track makes that
        // independent of another download or demux seek.
        while externalNextIndex < cues.count, cues[externalNextIndex].start <= seconds {
            if seconds < cues[externalNextIndex].end {
                externalActiveIndices.append(externalNextIndex)
            }
            externalNextIndex += 1
        }
        externalLastSeconds = seconds
    }

    private func closeOpenCuesLocked(at seconds: Double) {
        for index in cues.indices where cues[index].end == .infinity && cues[index].start < seconds {
            cues[index].end = seconds
        }
    }
}

nonisolated struct ASSPlayResolution: Equatable, Sendable {
    let width: Double
    let height: Double

    /// ASS historically defaults to this script plane when the header omits
    /// PlayRes. Real authored files nearly always supply both dimensions.
    static let fallback = ASSPlayResolution(width: 384, height: 288)
}

/// The intentionally small ASS/SSA subset Lagoon renders. Positioning,
/// alignment, primary colour, bold and italic cover signs and simultaneous
/// speakers; unsupported tags are consumed and ignored so plain dialogue
/// retains today's presentation.
nonisolated enum ASSSubtitleTextParser {
    private struct Style: Equatable {
        var primaryColor: SubtitleTextColor?
        var isBold = false
        var isItalic = false
    }

    static func playResolution(from header: String?) -> ASSPlayResolution {
        guard let header else { return .fallback }
        let width = firstCapture(#"(?im)^\s*PlayResX\s*:\s*([0-9]+(?:\.[0-9]+)?)\s*$"#, in: header)
            .flatMap(Double.init)
        let height = firstCapture(#"(?im)^\s*PlayResY\s*:\s*([0-9]+(?:\.[0-9]+)?)\s*$"#, in: header)
            .flatMap(Double.init)
        guard let width, width > 0, let height, height > 0 else { return .fallback }
        return ASSPlayResolution(width: width, height: height)
    }

    /// `payload` is FFmpeg's normalized ASS event:
    /// ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text.
    static func cue(
        from payload: String,
        playResolution: ASSPlayResolution = .fallback
    ) -> SubtitleTextCue? {
        let fields = payload.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        let raw = fields.count == 9 ? String(fields[8]) : payload
        var alignment: SubtitleTextAlignment?
        var position: SubtitleTextPosition?
        var style = Style()
        var runs: [SubtitleTextRun] = []
        var cursor = raw.startIndex

        func appendText(_ fragment: Substring) {
            guard !fragment.isEmpty else { return }
            let text = String(fragment)
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
            guard !text.isEmpty else { return }
            let run = SubtitleTextRun(
                text: text,
                primaryColor: style.primaryColor,
                isBold: style.isBold,
                isItalic: style.isItalic
            )
            if let last = runs.last,
               last.primaryColor == run.primaryColor,
               last.isBold == run.isBold,
               last.isItalic == run.isItalic {
                runs[runs.count - 1] = SubtitleTextRun(
                    text: last.text + run.text,
                    primaryColor: run.primaryColor,
                    isBold: run.isBold,
                    isItalic: run.isItalic
                )
            } else {
                runs.append(run)
            }
        }

        while cursor < raw.endIndex,
              let open = raw[cursor...].firstIndex(of: "{") {
            appendText(raw[cursor..<open])
            guard let close = raw[raw.index(after: open)...].firstIndex(of: "}") else {
                appendText(raw[open...])
                cursor = raw.endIndex
                break
            }
            let block = String(raw[raw.index(after: open)..<close])
            apply(
                block: block,
                playResolution: playResolution,
                alignment: &alignment,
                position: &position,
                style: &style
            )
            cursor = raw.index(after: close)
        }
        if cursor < raw.endIndex {
            appendText(raw[cursor...])
        }

        trimOuterWhitespace(from: &runs)
        guard !runs.isEmpty, !runs.map(\.text).joined().isEmpty else { return nil }
        return SubtitleTextCue(runs: runs, alignment: alignment, position: position)
    }

    private static func apply(
        block: String,
        playResolution: ASSPlayResolution,
        alignment: inout SubtitleTextAlignment?,
        position: inout SubtitleTextPosition?,
        style: inout Style
    ) {
        // \r or \rStyle resets inline state. The named style table remains
        // deliberately out of scope.
        //
        // Overrides apply left to right, so a reset only clears what precedes
        // it: `{\i1\r}` ends up plain and `{\r\i1}` ends up italic. Style
        // tags are therefore read from whatever follows the last reset, while
        // alignment and position — which are not part of `Style` — keep
        // reading the whole block.
        var styleScope = block
        if let reset = lastResetRange(in: block) {
            style = Style()
            styleScope = String(block[reset.upperBound...])
        }
        if let raw = lastCapture(#"\\an([1-9])"#, in: block),
           let value = Int(raw),
           let parsed = SubtitleTextAlignment(rawValue: value) {
            alignment = parsed
        }
        if let captures = lastCaptures(
            #"\\pos\(\s*(-?(?:\d+(?:\.\d*)?|\.\d+))\s*,\s*(-?(?:\d+(?:\.\d*)?|\.\d+))\s*\)"#,
            count: 2,
            in: block
        ), let x = Double(captures[0]), let y = Double(captures[1]) {
            position = SubtitleTextPosition(
                x: x / playResolution.width,
                y: y / playResolution.height
            )
        }
        if let raw = lastCapture(#"\\b(-?\d+)"#, in: styleScope), let value = Int(raw) {
            style.isBold = value != 0
        }
        if let raw = lastCapture(#"\\i(-?\d+)"#, in: styleScope), let value = Int(raw) {
            style.isItalic = value != 0
        }
        if let raw = lastCapture(#"\\(?:1)?c&H([0-9A-Fa-f]{6,8})&"#, in: styleScope) {
            style.primaryColor = color(fromASSHex: raw)
        }
    }

    /// Range of the last `\r` / `\rStyle` reset in an override block.
    private static func lastResetRange(in block: String) -> Range<String.Index>? {
        guard let expression = try? NSRegularExpression(pattern: #"\\r(?:[^\\}]*)"#) else { return nil }
        let range = NSRange(block.startIndex..<block.endIndex, in: block)
        guard let match = expression.matches(in: block, range: range).last else { return nil }
        return Range(match.range, in: block)
    }

    private static func color(fromASSHex raw: String) -> SubtitleTextColor? {
        guard let value = UInt32(raw, radix: 16) else { return nil }
        let alpha: UInt8 = raw.count == 8
            ? 255 &- UInt8((value >> 24) & 0xFF)
            : 255
        return SubtitleTextColor(
            red: UInt8(value & 0xFF),
            green: UInt8((value >> 8) & 0xFF),
            blue: UInt8((value >> 16) & 0xFF),
            alpha: alpha
        )
    }

    private static func trimOuterWhitespace(from runs: inout [SubtitleTextRun]) {
        while !runs.isEmpty {
            let first = runs[0]
            let text = first.text.drop(while: { $0.isWhitespace })
            if text.isEmpty {
                runs.removeFirst()
            } else {
                runs[0] = SubtitleTextRun(
                    text: String(text),
                    primaryColor: first.primaryColor,
                    isBold: first.isBold,
                    isItalic: first.isItalic
                )
                break
            }
        }
        while !runs.isEmpty {
            let lastIndex = runs.count - 1
            let last = runs[lastIndex]
            let text = last.text.reversed().drop(while: { $0.isWhitespace }).reversed()
            if text.isEmpty {
                runs.removeLast()
            } else {
                runs[lastIndex] = SubtitleTextRun(
                    text: String(text),
                    primaryColor: last.primaryColor,
                    isBold: last.isBold,
                    isItalic: last.isItalic
                )
                break
            }
        }
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        captures(pattern, count: 1, in: text).first?.first
    }

    private static func lastCapture(_ pattern: String, in text: String) -> String? {
        captures(pattern, count: 1, in: text).last?.first
    }

    private static func lastCaptures(_ pattern: String, count: Int, in text: String) -> [String]? {
        captures(pattern, count: count, in: text).last
    }

    private static func captures(_ pattern: String, count: Int, in text: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > count else { return nil }
            var result: [String] = []
            for index in 1...count {
                guard let range = Range(match.range(at: index), in: text) else { return nil }
                result.append(String(text[range]))
            }
            return result
        }
    }
}

/// Parses the external subtitle files Jellyfin delivers (vtt per the
/// device profile; srt tolerated since the timestamp shapes overlap).
nonisolated enum SubtitleParser {
    static func cues(from data: Data, languageHint: String? = nil) -> [SubtitleCue] {
        guard data.count <= DownloadLimit.subtitle, !Task.isCancelled,
              let content = SubtitleTextDecoder.text(from: data, languageHint: languageHint) else {
            return []
        }
        var result: [SubtitleCue] = []

        let blocks = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        for block in blocks {
            guard !Task.isCancelled else { return [] }
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2,
                  let start = seconds(fromTimestamp: timing[0]),
                  let end = seconds(fromTimestamp: timing[1]),
                  start.isFinite, end.isFinite, start >= 0, end > start else { continue }
            let text = lines[(timingIndex + 1)...]
                .map { $0.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            result.append(SubtitleCue(start: start, end: end, text: text, images: []))
        }
        return result
    }

    /// "hh:mm:ss.mmm", "mm:ss.mmm", or the srt comma variant; vtt cue
    /// settings after the timestamp are ignored.
    private static func seconds(fromTimestamp raw: String) -> Double? {
        let stamp = raw.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ").first ?? ""
        let parts = stamp.replacingOccurrences(of: ",", with: ".")
            .components(separatedBy: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total: Double = 0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }
}

/// Turns subtitle bytes into text without silently inventing them.
///
/// The previous chain ended in `isoLatin1`, which cannot fail — it maps every
/// byte — so a Windows-1251 Cyrillic file decoded to mojibake with no error
/// anywhere. Jellyfin converts to UTF-8 on the way out, which hid it; a
/// provider fetched directly does not.
///
/// The language is the strongest signal for a legacy file, a codepage not
/// being recoverable from bytes alone: Cyrillic is almost certainly
/// Windows-1251, Baltic Windows-1257. Every candidate is still
/// sanity-checked, so a wrong hint degrades to the next option.
nonisolated enum SubtitleTextDecoder {
    static func text(from data: Data, languageHint: String? = nil) -> String? {
        guard !data.isEmpty else { return nil }
        if let viaBOM = decodeUsingBOM(data) { return viaBOM }
        // Valid UTF-8 is never accidental at any real length, so it wins
        // outright and needs no plausibility check.
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }

        var candidates: [String.Encoding] = []
        if let legacy = legacyEncoding(forLanguage: languageHint) {
            candidates.append(legacy)
        }
        candidates.append(contentsOf: [.windowsCP1252, .isoLatin1])

        var fallback: String?
        for encoding in candidates {
            guard let decoded = String(data: data, encoding: encoding) else { continue }
            if isPlausibleSubtitleText(decoded) { return decoded }
            if fallback == nil { fallback = decoded }
        }
        // Nothing looked like prose. Returning the first decodable form still
        // beats dropping the file: the caller validates that cues parsed out
        // of it, which is the check that actually protects playback.
        return fallback
    }

    private static func decodeUsingBOM(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        return nil
    }

    /// The single-byte codepage a subtitle in this language is written in when
    /// it is not UTF-8. Mapped from ISO 639 through Lagoon's existing
    /// normalisation so both two- and three-letter forms resolve.
    static func legacyEncoding(forLanguage language: String?) -> String.Encoding? {
        guard let language,
              let code = JellyfinSubtitleLanguageCode.twoLetter(for: language) else { return nil }
        switch code {
        case "ru", "uk", "bg", "be", "sr", "mk":
            return encoding(.windowsCyrillic)
        case "cs", "pl", "hu", "ro", "hr", "sk", "sl", "sq", "bs":
            return encoding(.windowsLatin2)
        case "el":
            return encoding(.windowsGreek)
        case "tr":
            return encoding(.windowsLatin5)
        case "he", "yi":
            return encoding(.windowsHebrew)
        case "ar", "fa", "ur":
            return encoding(.windowsArabic)
        case "et", "lv", "lt":
            return encoding(.windowsBalticRim)
        case "vi":
            return encoding(.windowsVietnamese)
        case "th":
            return encoding(.dosThai)
        default:
            return nil
        }
    }

    /// Only a handful of these have `String.Encoding` constants; going through
    /// CoreFoundation keeps the whole table in one shape.
    private static func encoding(_ value: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(value.rawValue)
        ))
    }

    /// Subtitle text is prose: letters, digits, punctuation and whitespace.
    /// A codepage applied to the wrong bytes produces a scatter of symbols and
    /// control characters instead, which this is enough to notice.
    static func isPlausibleSubtitleText(_ text: String) -> Bool {
        var plausible = 0
        var implausible = 0
        for scalar in text.unicodeScalars.prefix(4_000) {
            if scalar == "\u{FFFD}" {
                implausible += 1
            } else if CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.symbols.contains(scalar) {
                plausible += 1
            } else if CharacterSet.controlCharacters.contains(scalar) {
                implausible += 1
            } else {
                implausible += 1
            }
        }
        let total = plausible + implausible
        guard total > 0 else { return false }
        return Double(implausible) / Double(total) < 0.05
    }
}
