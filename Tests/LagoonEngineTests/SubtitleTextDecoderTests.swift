import Foundation
import Testing
@testable import LagoonEngine

@Suite("Subtitle text decoding")
struct SubtitleTextDecoderTests {
    @Test func legacyEncodedSubtitlesDecodeInsteadOfTurningIntoMojibake() throws {
        // The previous chain ended in isoLatin1, which cannot fail — so this
        // Cyrillic file decoded to garbage and rendered with no error at all.
        let russian = "Привет, как дела?"
        let cp1251 = try #require(russian.data(
            using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)
            ))
        ))
        #expect(SubtitleTextDecoder.text(from: cp1251, languageHint: "rus") == russian)
        #expect(SubtitleTextDecoder.text(from: cp1251, languageHint: "ru") == russian)

        // Documented limitation: with no hint this still decodes to mojibake.
        // Cyrillic bytes read as Latin-1 become accented Latin letters, which
        // are perfectly ordinary characters — telling that apart from real
        // Western-European text needs statistical models, and a cheap
        // heuristic that guessed would mis-decode German as Cyrillic, which is
        // worse than the status quo. The language is the mechanism; the
        // plausibility check is only a guard against control-character
        // garbage. Every path that fetches a subtitle now carries a language.
        let guessed = SubtitleTextDecoder.text(from: cp1251, languageHint: nil)
        #expect(guessed != russian)
        #expect(SubtitleTextDecoder.isPlausibleSubtitleText(guessed ?? ""))

        // What the guard does catch: bytes that decode to control characters.
        let binary = Data((0..<256).map { UInt8($0 % 32) })
        #expect(!SubtitleTextDecoder.isPlausibleSubtitleText(
            SubtitleTextDecoder.text(from: binary, languageHint: nil) ?? ""
        ))
    }

    @Test func utf8AndBOMsWinOverAnyLanguageHint() throws {
        let text = "Ordinary subtitle line"
        let utf8 = Data(text.utf8)
        // Valid UTF-8 is never accidental, so a wrong hint cannot corrupt it.
        #expect(SubtitleTextDecoder.text(from: utf8, languageHint: "rus") == text)

        let bom = Data([0xEF, 0xBB, 0xBF]) + utf8
        #expect(SubtitleTextDecoder.text(from: bom, languageHint: nil) == text)

        var utf16 = Data([0xFF, 0xFE])
        utf16.append(try #require(text.data(using: .utf16LittleEndian)))
        #expect(SubtitleTextDecoder.text(from: utf16, languageHint: nil) == text)

        #expect(SubtitleTextDecoder.text(from: Data(), languageHint: nil) == nil)
    }

    @Test func cuesParseThroughTheLanguageAwareDecoder() throws {
        let srt = "1\r\n00:00:01,000 --> 00:00:03,000\r\nПривет\r\n"
        let cp1251 = try #require(srt.data(
            using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)
            ))
        ))
        let cues = SubtitleParser.cues(from: cp1251, languageHint: "rus")
        #expect(cues.count == 1)
        #expect(cues.first?.text == "Привет")
    }
}
