import Foundation

/// One field on a diagnostic event.
///
/// Four scalar kinds and nothing else. Anything a host eventually sends
/// onward has to be built out of these, which is what keeps a URL, a title or
/// an account out of a report by construction rather than by review.
nonisolated enum DiagnosticValue: Equatable, Sendable {
    case int(Int)
    case double(Double)
    case bool(Bool)
    case string(String)
}

/// What a string field may contain.
///
/// Strings are the only kind that could carry private content, so a string
/// the engine did not choose itself has to pass this before it becomes a
/// field: letters, digits, `.`, `_`, `-` and `,`, never whitespace, `/`, `:`,
/// `@` or `?`. That rules out URLs, hostnames with paths, query strings and
/// file paths.
nonisolated enum DiagnosticToken {
    static let maximumLength = 48

    static func isToken(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= maximumLength else { return false }
        return text.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: ","):
                true
            default:
                false
            }
        }
    }

    /// The value for a string that qualifies, and nothing for one that does
    /// not. A field is dropped rather than truncated, because a truncated
    /// URL is still a URL.
    static func token(_ text: String?) -> DiagnosticValue? {
        guard let text, isToken(text) else { return nil }
        return .string(text)
    }
}

/// Rounding for numbers that become diagnostic fields.
///
/// A playback position reported to the nanosecond is both noise and a
/// sharper identifier than it needs to be; one decimal place is enough to
/// see what happened.
nonisolated extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
