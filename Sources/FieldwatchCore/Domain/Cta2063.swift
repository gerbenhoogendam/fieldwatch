import Foundation

/// Maker line for a CTA-2063 serial already on an ASTM Basic ID.
/// Longest prefix wins. The caller only asks when the ID type is Serial.
enum Cta2063 {
    static func label(serial: String) -> String? {
        let id = serial.trim().uppercased()
        if id.isEmpty { return nil }
        return PREFIXES.first { id.hasPrefix($0.0) }?.1
    }

    private static let PREFIXES: [(String, String)] = [
        ("18179132", "Freefly Alta X Gen2"),
        ("1817913", "Freefly Astro"),
        ("181792", "Freefly Alta X"),
        ("181793", "Freefly Alta X broadcast kit"),
        ("1817", "Freefly"),
        ("1914CL2D", "BRINC Lemur 2"),
        ("1914CR1D", "BRINC Responder"),
        ("1914", "BRINC"),
        ("1839FTD", "Teal 2"),
        ("1839", "Teal"),
        // Declared stems. Bare 1748 and 1668 are not these makers.
        ("1748C", "Autel"),
        ("1668B", "Skydio"),
    ]
}
