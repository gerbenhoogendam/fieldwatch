import Foundation

// Port of domain/CsvCells.kt. Works on Unicode scalars so "\r\n" (one Swift Character) is seen as CR + LF.

/// Spreadsheet CSV text. A cell whose first non-space character is = + - or @
/// is prefixed so Excel and Sheets keep it as text. A plain number, including
/// a negative coordinate, is left alone.
public enum CsvCells {
    private static let NUMBER = KRegex("-?[0-9]+(?:\\.[0-9]+)?")

    public static func quote(s: String) -> String {
        let body = guardCell(s)
        if body.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"\(body.replace("\"", "\"\""))\""
        }
        return body
    }

    /// Log rows that flatten commas instead of quoting.
    public static func plain(s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            scalars.append((u == "," || u == "\n" || u == "\r" || u == "\"") ? " " : u)
        }
        return guardCell(String(scalars))
    }

    private static func guardCell(_ s: String) -> String { formula(s) ? "'\(s)" : s }

    private static func formula(_ s: String) -> Bool {
        guard let i = s.firstIndex(where: { !$0.isWhitespace }) else { return false }
        if !"=+-@".contains(s[i]) { return false }
        return !NUMBER.matches(String(s[i...]))
    }
}
