import Foundation
import Testing
@testable import LagoonEngine

@Suite("Subtitle text decoding")
struct SubtitleTextDecoderTests {
    @Test func legacyEncodedSubtitlesDecodeInsteadOfTurningIntoMojibake() throws {
        // An isoLatin1 fallback cannot fail, so this would decode silently to
        // garbage.
        let russian = "Привет, как дела?"
        let cp1251 = try #require(russian.data(
            using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)
            ))
        ))
        #expect(SubtitleTextDecoder.text(from: cp1251, languageHint: "rus") == russian)
        #expect(SubtitleTextDecoder.text(from: cp1251, languageHint: "ru") == russian)

        // Known limitation: with no hint this still decodes to mojibake.
        // Cyrillic read as Latin-1 becomes ordinary accented letters, and a
        // cheap guess would mis-decode German as Cyrillic. The language hint is
        // the mechanism; the plausibility check only catches control-character
        // garbage.
        let guessed = SubtitleTextDecoder.text(from: cp1251, languageHint: nil)
        #expect(guessed != russian)
        #expect(SubtitleTextDecoder.isPlausibleSubtitleText(guessed ?? ""))

        // What the guard catches: bytes that decode to control characters.
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
