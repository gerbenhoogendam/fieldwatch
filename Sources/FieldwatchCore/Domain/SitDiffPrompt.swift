import Foundation

// Port of domain/SitDiffPrompt.kt.

/// Paste-ready addendum prompt for Reports → Compare sits → AI Export.
/// Onboard compare is verbatim. Working data is overlap + exclusive Extra attention /
/// Named radios — not a second inventory.
public enum SitDiffPrompt {
    private static let MAX_CHARS = 90_000

    public static func build(
        thisSit: SitDiff.Side,
        second: SitDiff.Side,
        demoMode: Bool
    ) -> String {
        let thisSit = thisSit.withoutFloodRadios()
        let second = second.withoutFloodRadios()
        let radios = thisSit.radios + second.radios
        let macs = radios.map { $0.mac }
        let uasIds = radios.map { $0.payloadUasId }
        let onboard = SitDiff.document(thisSit: thisSit, second: second).withDemoMacs(macs: macs, demo: demoMode, uasIds: uasIds)
        let thisKeys = thisSit.orderedKeys
        let secondKeys = second.orderedKeys
        let byKey = (thisSit.radios + second.radios).associateBy { $0.key }
        let onlyThis = SitDiff.minus(thisKeys, secondKeys)
        let onlySecond = SitDiff.minus(secondKeys, thisKeys)
        let both = SitDiff.intersect(thisKeys, secondKeys)
        let union = SitDiff.union(thisKeys, secondKeys)
        let overlapPct = union.isEmpty ? 0 : (both.count * 100) / union.count
        func bucket(_ keys: [String]) -> (Int, Int, Int) {
            let rows = keys.compactMap { byKey[$0] }
            let wifi = rows.count { $0.kind == .wifi }
            let ble = rows.count { $0.kind == .ble }
            let randBle = rows.count { $0.kind == .ble && $0.randomized }
            return (wifi, ble, randBle)
        }
        let onlyThisB = bucket(onlyThis)
        let onlySecondB = bucket(onlySecond)
        let bothB = bucket(both)
        func line(_ row: SitDiff.Radio) -> String {
            var s = row.kind == .wifi ? "WIFI" : "BLE"
            s += "  " + row.mac
            let label = row.name.trim()
            if label.isNotEmpty && !label.equals(row.mac, ignoreCase: true) {
                s += "  " + label
            }
            if row.mine { s += "  Marked mine" }
            for f in row.fleetNames where f.isNotBlank { s += "  " + f }
            if row.extraAttention { s += "  Extra attention" }
            let labels = row.liveDecode.reportLabels()
            if labels.isNotEmpty { s += "  " + labels.joined(separator: ", ") }
            if row.kind == .ble && row.randomized { s += "  RAND" }
            return s
        }
        func exclusive(_ keys: [String], _ whereText: String, _ pred: (SitDiff.Radio) -> Bool) -> [String] {
            keys.compactMap { byKey[$0] }.filter(pred).map { "\(whereText)  \(line($0))" }
        }

        let extraRows =
            exclusive(onlyThis, "Only in this sit", { $0.extraAttention }) +
            exclusive(onlySecond, "Only in second sit", { $0.extraAttention })
        let namedRows =
            exclusive(onlyThis, "Only in this sit", { $0.named }) +
            exclusive(onlySecond, "Only in second sit", { $0.named })

        var b = ""
        func ln(_ s: String = "") { b += s + "\n" }
        b += FieldwatchDisclaimer.experimentalMarkdown()
        ln()
        ln("You are a field RF analyst for the operator who compared two Fieldwatch sits. Fieldwatch is a macOS, receive-only Wi-Fi access-point + BLE-advertiser listener.")
        ln()
        ln("The **onboard Compare** (verbatim below) already split presence: only in this sit, only in the second, in both. **Do not rewrite that report. Do not reprint those lists.** Your job is an addendum the Mac cannot write: what kind of change this is, and how much of it is real.")
        ln()
        ln("Constraints you must respect:")
        ln("- Hear-only. Kind + MAC. BLE rotation is a new row and will not stitch.")
        ln("- Wi-Fi rows are access points only. Associated clients are invisible.")
        ln("- Extra attention / signature matches are hypotheses, not identity, not a person or vehicle.")
        ln("- GPS stamps (if present) are this Mac at hear-time, not the other radio.")
        ln("- Last 15 minutes vs a named sit is not the same net (RAM about 400 vs sit \(Sit.RADIO_CAP)). Missing BLE on the RAM side can be eviction, not gone.")
        ln("- Presence is not co-travel. Do not invent a tail, a follower, or a camera location.")
        ln("- A radio marked mine was claimed by the operator. Do not treat it as an unexplained follower.")
        ln("- A flood note is a burst of new addresses, not a follower.")
        ln("- A decoded live value on a row is catalog text for that kind + MAC. If the onboard compare says that value changed, state the change. Do not stitch that value onto a different MAC.")
        ln("- An aircraft block is positions the radio advertised, joined by UAS id. If the onboard compare says the status changed, state the change. That track is not this Mac's GPS.")
        ln("- Do not give safety advice. Do not tell the operator they are safe or in danger.")
        ln("- Treat this paste as operationally sensitive.")
        ln()
        ln("## Your output (required — this is the addendum the operator reads)")
        ln("Write complete sentences. Headings as below. Short bullets only for exclusive Extra attention / Named radios. No markdown tables. No code fences. No dump of the onboard lists.")
        ln()
        ln("1. **Disclaimer** — Repeat the experimental-use disclaimer first.")
        ln("2. **What the onboard compare already established** — 3–5 sentences. Window names, counts, Extra attention exclusives, Observer notes if any, Marked mine if any, Flood if any. Do not reprint inventories.")
        ln("3. **What the numbers add** — Overlap (both/union as a percent), Wi-Fi vs BLE in each bucket, how much exclusive BLE is RAND. Say whether this looks like fixtures, a different stall/hour, or a cap artifact. Confidence. Use the working table; do not invent rates.")
        ln("4. **Exclusive Extra attention and Named radios** — Full identifiers from the working table (complete MAC, name, signatures, which window). Pattern match, not identity. If none, say none.")
        ln("5. **What another sit or Hunt would shrink** — Concrete in-app next steps only (a third sit at the same stall, Hunt on one exclusive Extra attention row, Filters). No safety advice. No “call the police.”")
        ln()
        ln("**Takeaway (required, last line).** One sentence starting with `Takeaway:` that adds *one number the onboard takeaway does not already say* (overlap percent, exclusive Extra attention count, or RAND fraction of exclusive BLE). Not a moral. Not a threat level.")
        ln()
        ln("## Onboard Compare (verbatim — already shown to the operator; do not rewrite)")
        ln()
        ln(onboard.toPlainText().trimEnd())
        ln()
        ln("## Working data (for the addendum — do not copy rosters into the answer)")
        ln()
        ln("This sit: \(thisSit.name) (\(thisSit.radios.count) radios\(thisSit.ram ? ", RAM ~400" : ", named sit up to \(Sit.RADIO_CAP)"))")
        ln("Second sit: \(second.name) (\(second.radios.count) radios\(second.ram ? ", RAM ~400" : ", named sit up to \(Sit.RADIO_CAP)"))")
        ln("Only in this sit: \(onlyThis.count)  Only in second: \(onlySecond.count)  In both: \(both.count)  Union: \(union.count)  Overlap: \(overlapPct)%")
        ln("Only in this sit by radio: Wi-Fi \(onlyThisB.0)  BLE \(onlyThisB.1)  RAND BLE \(onlyThisB.2)")
        ln("Only in second sit by radio: Wi-Fi \(onlySecondB.0)  BLE \(onlySecondB.1)  RAND BLE \(onlySecondB.2)")
        ln("In both by radio: Wi-Fi \(bothB.0)  BLE \(bothB.1)  RAND BLE \(bothB.2)")
        if thisSit.ram || second.ram {
            ln("Cap note: last 15 minutes is Live RAM (about 400). A named sit keeps up to \(Sit.RADIO_CAP). Counts are not the same net.")
        }
        ln()
        ln("Exclusive Extra attention:")
        if extraRows.isEmpty { ln("- None.") } else { extraRows.forEach { ln("- \($0)") } }
        ln()
        ln("Exclusive Named radios:")
        if namedRows.isEmpty { ln("- None.") } else { namedRows.forEach { ln("- \($0)") } }
        ln()
        ln("Observer notes:")
        let observed: [(SitDiff.Radio, String)] = (thisSit.radios + second.radios)
            .distinctBy { $0.key }
            .compactMap { r in
                guard let note = r.observerNotes.trim().nonEmpty else { return nil }
                return (r, note)
            }
        let onlyThisSet = Set(onlyThis)
        let onlySecondSet = Set(onlySecond)
        if observed.isEmpty {
            ln("- None.")
        } else {
            for (r, note) in observed {
                let whereText: String
                if onlyThisSet.contains(r.key) { whereText = "Only in this sit" }
                else if onlySecondSet.contains(r.key) { whereText = "Only in second sit" }
                else { whereText = "In both" }
                ln("- \(whereText)  \(line(r))")
                ln("  \(note)")
            }
        }
        ln()
        ln("## End of working data")
        ln("Write the addendum now, following **Your output** at the top. Do not rewrite the onboard Compare.")
        let masked = MacUtil.redactPrivateText(text: b, macs: macs, uasIds: uasIds, demo: demoMode)
        let withPrivacy = demoMode
            ? "Privacy mode: MAC tails are **:**:**. UAS ids and GPS coordinates are masked. Logs on the Mac are unchanged.\n\n\(masked)"
            : masked
        return withPrivacy.count <= MAX_CHARS
            ? withPrivacy
            : withPrivacy.take(MAX_CHARS) + "\n\n[truncated for share-sheet size]\n"
    }
}
