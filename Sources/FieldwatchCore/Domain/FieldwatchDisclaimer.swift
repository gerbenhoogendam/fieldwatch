import Foundation

// Port of domain/FieldwatchDisclaimer.kt. Wording is the Android text; only references to the
// device running Fieldwatch ("this phone") read "this Mac".

/// Operator-facing disclaimer. First-run, Debrief, and AI Export share the same core.
public enum FieldwatchDisclaimer {
    public static let HOBBY =
        "This is a hobby project, provided as-is under the MIT License. Use at your own risk."

    public static let HYPOTHESES =
        "Detections, pattern matches, “Moving with you” / “possible tail,” Debrief text, " +
        "and AI Export are hypotheses — not identity, not a legal finding, and not a " +
        "complete RF capture. Radios that are off, asleep, randomized, cellular-only, " +
        "or hidden by the OS will not appear."

    public static let LIABILITY =
        "You are solely responsible for how you use this app and for following local law. " +
        "To the maximum extent permitted by law, Off Grid Pete LLC is not liable for " +
        "indirect, incidental, special, consequential, or punitive damages arising from its use."

    public static let LOCATION =
        "GPS stamps are this Mac at hear-time, not the other radio, unless a decode map " +
        "advertises its own latitude/longitude (Remote ID Location). Sharing a Debrief, " +
        "sit compare, AI Export (sit or one radio), radio-detail Share as text, or log can take that " +
        "path off the device. A TAK/CoT feed, when you turn it on, sends markers onto " +
        "the LAN; that is on the operator."

    public static let ACCEPT =
        "By checking the box and continuing, you accept these terms and the MIT License."

    public static let LICENSE_TITLE = "MIT License"

    /// Body of LICENSE in the repository, without the title line.
    public static let LICENSE_BODY =
        "Copyright (c) 2026 Off Grid Pete LLC\n" +
        "\n" +
        "Permission is hereby granted, free of charge, to any person obtaining a copy " +
        "of this software and associated documentation files (the \"Software\"), to deal " +
        "in the Software without restriction, including without limitation the rights " +
        "to use, copy, modify, merge, publish, distribute, sublicense, and/or sell " +
        "copies of the Software, and to permit persons to whom the Software is " +
        "furnished to do so, subject to the following conditions:\n" +
        "\n" +
        "The above copyright notice and this permission notice shall be included in all " +
        "copies or substantial portions of the Software.\n" +
        "\n" +
        "THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR " +
        "IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, " +
        "FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE " +
        "AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER " +
        "LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, " +
        "OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE " +
        "SOFTWARE."

    public static let LICENSE_TEXT = "\(LICENSE_TITLE)\n\n\(LICENSE_BODY)"

    public static let firstRunDisclaimer: String = "\(HOBBY)\n\n\(HYPOTHESES)\n\n\(LIABILITY)"

    public static let firstRun: String = "\(firstRunDisclaimer)\n\n\(LICENSE_TEXT)\n\n\(ACCEPT)"

    /// Debrief text / PDF. Same core as first-run, without the click-through line.
    public static func report(window: DebriefWindow? = nil) -> String {
        let source: String
        if let sitName = window?.sitName {
            source = "named sit “\(sitName)” (radios heard in that window; Live list cap still applied while watching). "
        } else {
            source = "the in-memory live set (last 15 minutes, cap about 400). "
        }
        return "\(HOBBY)\n\n\(HYPOTHESES)\n\n\(LIABILITY)\n\n\(LOCATION)\n\n" +
            "This sit report is from \(source)" +
            "Do not use it in any situation where safety is in question."
    }

    public static func compare() -> String {
        "\(HOBBY)\n\n\(HYPOTHESES)\n\n\(LIABILITY)\n\n\(LOCATION)\n\n" +
            "This compare is two windows of radios this Mac heard (kind + MAC). " +
            "BLE rotation is a new row. Do not use it in any situation where safety is in question."
    }

    public static func experimentalMarkdown() -> String {
        var s = ""
        s += "## Disclaimer (repeat this in your answer)\n"
        s += HOBBY + "\n"
        s += HYPOTHESES + "\n"
        s += LIABILITY + "\n"
        s += LOCATION + "\n"
        s += "Do not use Fieldwatch, this paste, or your analysis in any situation where safety is in question.\n"
        s += "Begin your reply with this disclaimer. Do not give safety advice.\n"
        return s
    }
}
