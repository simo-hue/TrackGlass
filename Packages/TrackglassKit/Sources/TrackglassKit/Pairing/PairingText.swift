import Foundation

/// Text shown while pairing (§3.4, 2026-10-31).
public enum PairingText {
    /// Longest name a pairing prompt shows, "…" included.
    public static let maxNameLength = 40

    /// A peer-chosen name made safe for a security prompt (PAIR_REQUEST's name can be any 64 KiB of UTF-8): control
    /// and format characters (Unicode Cc and Cf, which include the bidi overrides and isolates and the zero-width
    /// characters) are removed, whitespace runs — tab and newline included — become one space with none at either end,
    /// and a longer result is cut to 40 characters ending in "…". The result can be empty.
    public static func sanitizedName(_ name: String) -> String {
        var cleaned = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in name.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = !cleaned.isEmpty
                continue
            }
            let category = scalar.properties.generalCategory
            if category == .control || category == .format { continue }
            if pendingSpace {
                cleaned.append(" ")
                pendingSpace = false
            }
            cleaned.append(scalar)
        }
        let result = String(cleaned)
        guard result.count > maxNameLength else { return result }
        return String(result.prefix(maxNameLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "123456" → "123 456", the way both screens show the comparison code.
    public static func formattedCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    /// "123456" → "1 2 3 4 5 6", so VoiceOver reads the digits one by one.
    public static func spokenCode(_ code: String) -> String {
        code.map { String($0) }.joined(separator: " ")
    }
}
