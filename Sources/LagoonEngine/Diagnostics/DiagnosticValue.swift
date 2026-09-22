import Foundation

/// One field on a diagnostic event. Only four scalar kinds, which keeps a URL,
/// title or account out of a report by construction.
public nonisolated enum DiagnosticValue: Equatable, Sendable {
    case int(Int)
    case double(Double)
    case bool(Bool)
    case string(String)
}

/// What a string field may contain: letters, digits, `.`, `_`, `-` and `,`.
/// Strings the engine did not choose must pass this, which rules out URLs,
/// query strings and file paths.
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

    /// The value if the string qualifies, else nil. Dropped, not truncated: a
    /// truncated URL is still a URL.
    static func token(_ text: String?) -> DiagnosticValue? {
        guard let text, isToken(text) else { return nil }
        return .string(text)
    }
}

/// Rounding for numeric fields. One decimal place shows what happened without
/// nanosecond noise or a sharper identifier.
nonisolated extension Double {
    public func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
