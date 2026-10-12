import Foundation

// Port of domain/DebriefPrompt.kt. Wording is the Android text except references to the
// device running Fieldwatch (now "this Mac") and the platform ("macOS" instead of "stock-Android").

/// Paste-ready addendum prompt for Reports → AI Export.
/// Onboard Debrief is verbatim. Working data is rates, RSSI bands, Extra attention,
/// and finder-tag rows for a tracking stress-test — not a second inventory.
public enum DebriefPrompt {
    public static let WINDOW_SHORT_MS = 5 * 60_000
    public static let WINDOW_MS = 15 * 60_000
    private static let MAX_CHARS = 90_000

    public static func build(
        devices: [Sighting],
        fleets: [Fleet],
        settings: AppSettings,
        now: Int = nowMs(),
        operatorPath: [GpsSample] = [],
        places: DebriefPlaces = DebriefPlaces.Off,
        window: DebriefWindow? = nil,
        customNames: [String: String] = [:],
        observerNotes: [String: String] = [:],
        bookmarkedKeys: Set<String> = [],
        mineKeys: Set<String> = [],
        floods: [FloodBurst] = [],
        gnss: [GnssMark] = []
    ) -> String {
        var names: [String: String] = [:]
        for f in fleets { names[f.id] = f.name }
        let win = window ?? DebriefWindow(startAt: now - WINDOW_MS, endAt: now)
        let windowStart = win.startAt
        let windowEnd = win.endAt
        let aside = FloodBurst.keysOf(floods: floods, start: windowStart, end: windowEnd)
        let in15 = devices.filter {
            ($0.lastSeen >= windowStart || $0.firstSeen >= windowStart) && !aside.contains($0.key)
        }
        let shortStart = Swift.max(windowStart, windowEnd - WINDOW_SHORT_MS)
        let in5 = in15.filter { $0.lastSeen >= shortStart || $0.firstSeen >= shortStart }
        let wifi = in15.filter { $0.kind == .wifi }
        let ble = in15.filter { $0.kind == .ble }
        let signed = in15.filter { $0.fleetIds.isNotEmpty }
        let randomized = ble.count { $0.randomized }
        let arrived = in15.filter { $0.firstSeen >= windowStart }
        let departed = in15.filter { $0.gone || $0.lastSeen < windowEnd - 45_000 }
        let persistent = in15.filter { dwellMs($0, windowStart, windowEnd) >= win.durationMs * 2 / 3 }
        let path = operatorPath.filter { $0.at >= windowStart && $0.at <= windowEnd }
        let pathSpan = Geo.spanM(samples: path)
        let pathLen = Geo.pathLengthM(samples: path)
        let extraHits: [(Sighting, String, String)] = in15.flatMap { d in
            d.attentionNotes(fleets: fleets).map { (d, $0.0, $0.1) }
        }
        let finders = in15.filter {
            !mineKeys.contains($0.key) && TrackerMatch.kind(device: $0, names: names) == .finder
        }
        let sigFamilies = signed
            .groupByOrdered { d in d.fleetIds.map { names[$0] ?? $0 }.joined(separator: "+") }
            .map { ($0.0, $0.1.count) }
            .sortedByDescending { $0.1 }
        let bleRssi = ble.map { $0.rssi }
        let wifiRssi = wifi.map { $0.rssi }
        let onboard = DebriefReport.build(
            devices: devices, fleets: fleets, settings: settings, operatorPath: operatorPath, now: now,
            places: places, window: win, customNames: customNames, observerNotes: observerNotes,
            bookmarkedKeys: bookmarkedKeys, mineKeys: mineKeys, floods: floods, gnss: gnss
        )
        let iso = utc(windowEnd)
        let start = utc(windowStart)

        var b = ""
        func line(_ s: String = "") { b += s + "\n" }
        b += experimentalDisclaimerMarkdown()
        line()
        line("You are a field RF analyst for the operator who collected this sit. Fieldwatch is a macOS, receive-only Wi-Fi access-point + BLE-advertiser listener.")
        line()
        line("The **onboard Debrief** (verbatim below) already tabulated the sit: counts, Where you were, tracking callouts, inventories, Extra attention, takeaway. **Do not rewrite that report. Do not reprint inventories or stay lists.** Your job is an addendum the Mac cannot write: rates, competing hypotheses, and a stress-test of the onboard tracking callouts.")
        line()
        line("Constraints you must respect:")
        line("- Hear-only. Wi-Fi rows are access points only. BLE rows are advertisers. Kind + MAC. BLE rotation is a new row and will not stitch.")
        line("- Signature / OUI / company matches are hypotheses, not identity, not a person or vehicle.")
        line("- GPS stamps (if present) are this Mac at hear-time, not the other radio. Do not place a camera or tag at the GPS pin.")
        line("- Place names (if present) are system reverse-geocode of those stamps.")
        line("- RSSI is loudness at the Mac, not meters.")
        line("- Live RAM cap is about 400 radios; unnamed BLE evicts after ~3 min. A named sit keeps more. This is not a complete capture.")
        line("- Do not claim a tracker is following unless the onboard GPS co-travel section supports it. A radio with you the whole sit is not automatically yours — it may be planted. Do not dismiss it. Do not invent a tail the onboard test did not flag. Do not treat a retail beacon as a Find My tail.")
        line("- A radio marked mine was claimed by the operator. Do not treat it as an unexplained follower.")
        line("- A flood note is a burst of new addresses, not a follower.")
        line("- A decoded live value on a tracking row is catalog text for that advertisement. Quote the catalog sentence when the onboard report includes one. Do not stitch that value onto a different MAC.")
        line("- An aircraft block and an amber track are positions the radio advertised. Trails with the same UAS id are one aircraft. They are not this Mac's GPS and they are not a finding that the aircraft followed the operator.")
        line("- Do not give safety advice. Do not tell the operator they are safe or in danger.")
        line("- Treat this paste as operationally sensitive.")
        line()
        line("## Your output (required — this is the addendum the operator reads)")
        line("Write complete sentences. Headings as below. Short bullets only for Extra attention and tracking rows from the working table. No markdown tables. No code fences. No dump of the onboard inventories.")
        line()
        line("1. **Disclaimer** — Repeat the experimental-use disclaimer first.")
        line("2. **What the onboard Debrief already established** — 3–5 sentences. Counts, distance, tracking callouts, Extra attention hits, Observer notes if any, Marked mine if any, Flood if any. Do not reprint inventories.")
        line("3. **What the numbers add** — 5- vs 15-minute counts, RSSI bands, RAND BLE percent, arrivals per minute, persistent vs gone, signature-family mix. Say street vs dwelling vs retail vs vehicle, and 5-minute vs 15-minute change (denser, quieter, stable). Confidence. If GPS ran, path length/span from the working table — do not pin a radio to a stay.")
        line("4. **Extra attention and tracking callouts** — Full identifiers from the working table (complete MAC, name, RSSI min/max, signatures, dwell). Stress-test onboard Possible trackers with you / Possible tail / Retail beacons / Wearables. Agree, qualify, or say the data are too thin. Pattern match, not identity. If none, say none.")
        line("5. **What another sit or Hunt would shrink** — Concrete in-app next steps only (Hunt on one Extra attention row, a longer GPS path, Compare sits, Filters). No safety advice. No “call the police.”")
        line()
        line("**Takeaway (required, last line).** One sentence starting with `Takeaway:` that adds *one number the onboard takeaway does not already say* (a rate, RAND percent, 5- vs 15-minute change, path span). Not a moral. Not a threat level.")
        line()
        line("## Collection context")
        line("- Tool: Fieldwatch (app.fieldwatch), receive-only, no association / injection / cloud.")
        if let sitName = win.sitName {
            line("- Window: sit **\(sitName)** (\(start) → \(iso) UTC), with a 5-minute recent slice.")
        } else {
            line("- Window: last **15 minutes** (\(start) → \(iso) UTC), with a **5-minute** recent slice.")
        }
        line("- Scan intensity: \(settings.intensity.rawValue.lowercased()). Stale after \(settings.staleSec)s.")
        line("- Location tags: \(settings.tagLocation ? "on" : "off"). Online place names: \(settings.onlineLookup ? "on" : "off").")
        line()
        line("## Onboard Debrief (verbatim — already shown to the operator; do not rewrite)")
        line()
        line(onboard.trimEnd())
        line()
        line("## Working data (for the addendum — do not copy rosters into the answer)")
        line()
        line(
            "15 min: Wi-Fi \(wifi.count)  BLE \(ble.count)  signed \(signed.count)  hidden SSIDs \(wifi.count { $0.hiddenSsid })  " +
                "RAND BLE \(randomized)/\(ble.count) (\(pct(randomized, ble.count))%)  " +
                "first-seen \(arrived.count) (\(perMin(arrived.count))/min)  persistent \(persistent.count)  gone/quiet \(departed.count)"
        )
        line(
            "5 min: Wi-Fi \(in5.count { $0.kind == .wifi })  BLE \(in5.count { $0.kind == .ble })  " +
                "signed \(in5.count { $0.fleetIds.isNotEmpty })  first-seen \(in5.count { $0.firstSeen >= shortStart })"
        )
        line(
            "BLE RSSI (n=\(ble.count)): ≥−50 \(bandGe(bleRssi, -50))  −51..−70 \(band(bleRssi, -70, -51))  " +
                "−71..−85 \(band(bleRssi, -85, -71))  <−85 \(bandLt(bleRssi, -85))"
        )
        line(
            "Wi-Fi RSSI (n=\(wifi.count)): ≥−50 \(bandGe(wifiRssi, -50))  −51..−70 \(band(wifiRssi, -70, -51))  " +
                "−71..−85 \(band(wifiRssi, -85, -71))  <−85 \(bandLt(wifiRssi, -85))"
        )
        if sigFamilies.isEmpty {
            line("Signature families: none.")
        } else {
            line("Signature families (count): " + sigFamilies.take(12).map { "\($0.0)=\($0.1)" }.joined(separator: ", "))
        }
        line(
            "GPS path: tagging \(settings.tagLocation ? "on" : "off")  " +
                "fixes \(path.count)  length \(pathLen.toIntTruncating()) m  span \(pathSpan.toIntTruncating()) m  " +
                "places \(places.attempted ? places.note : "off")"
        )
        line()
        line("Extra attention:")
        if extraHits.isEmpty {
            line("- None.")
        } else {
            for (d, sig, note) in extraHits {
                b += "- " + row(d, names, now, windowStart, customNames, observerNotes)
                if mineKeys.contains(d.key) { b += "  Marked mine" }
                b += " | \(sig): \(note)"
                line()
            }
        }
        line()
        line("Observer notes:")
        let observed: [(Sighting, String)] = in15.compactMap { d in
            guard let note = observerNotes[d.key]?.trim(), note.isNotEmpty else { return nil }
            return (d, note)
        }
        if observed.isEmpty {
            line("- None.")
        } else {
            for (d, note) in observed.sortedByDescending({ $0.0.rssi }) {
                b += "- " + row(d, names, now, windowStart, customNames, [:])
                line()
                line("  \(note)")
            }
        }
        line()
        line("Finder-tag-like radios (for stress-test of onboard tracking; not a tail list):")
        if finders.isEmpty {
            line("- None.")
        } else {
            for d in finders.sortedByDescending({ $0.rssi }).take(20) {
                b += "- " + row(d, names, now, windowStart, customNames, observerNotes)
                b += " rssiMin=\(d.rssiMin) rssiMax=\(d.rssiMax)"
                line()
            }
        }
        line()
        line("## End of working data")
        line("Write the addendum now, following **Your output** at the top. Do not rewrite the onboard Debrief.")
        // Kotlin length counts UTF-16 units.
        if b.utf16.count <= MAX_CHARS { return b }
        let head = String(b.utf16.prefix(MAX_CHARS)) ?? b.take(MAX_CHARS)
        return head + "\n\n[truncated for share-sheet size]\n"
    }

    public static func experimentalDisclaimerMarkdown() -> String { FieldwatchDisclaimer.experimentalMarkdown() }

    private static func row(
        _ d: Sighting,
        _ names: [String: String],
        _ now: Int,
        _ windowStart: Int,
        _ customNames: [String: String] = [:],
        _ observerNotes: [String: String] = [:]
    ) -> String {
        var s = d.kind == .wifi ? "WIFI" : "BLE"
        s += " " + d.mac
        let label = d.reportName(customNames: customNames).trim()
        if label.isNotEmpty && !label.equals(d.mac, ignoreCase: true) {
            s += "  " + label.take(32)
        }
        if let note = observerNotes[d.key] { s += "  Observer: " + note.take(80) }
        s += " rssi=\(d.rssi)dBm"
        if d.randomized { s += " RAND" }
        if d.fleetIds.isNotEmpty {
            s += " sig=" + d.fleetIds.map { names[$0] ?? $0 }.joined(separator: "+")
        }
        let labels = d.liveDecode.reportLabels()
        if labels.isNotEmpty { s += " decoded=" + labels.joined(separator: ",") }
        let notes = d.liveDecode.map { $0.note.trim() }.filter { $0.isNotEmpty }.distinct()
        if notes.isNotEmpty { s += " decodeNote=" + notes.joined(separator: " ") }
        s += " dwell=" + fmtDur(dwellMs(d, windowStart, now))
        return s
    }

    private static func dwellMs(_ d: Sighting, _ from: Int, _ to: Int) -> Int {
        var sum = 0
        let spans = d.presence.ifEmpty([PresenceSpan(start: d.firstSeen, end: d.gone ? d.lastSeen : nil)])
        for span in spans {
            let a = Swift.max(span.start, from)
            let b = Swift.min(span.end ?? to, to)
            if b > a { sum += b - a }
        }
        return sum
    }

    private static func utc(_ ms: Int) -> String { formatMs(ms, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc: true) }

    private static func fmtDur(_ ms: Int) -> String {
        let s = (ms / 1000).coerceAtLeast(0)
        let m = s / 60
        let r = s % 60
        if m >= 60 { return "\(m / 60)h\(m % 60)m" }
        if m > 0 { return "\(m)m\(r)s" }
        return "\(r)s"
    }

    private static func pct(_ n: Int, _ d: Int) -> Int { d <= 0 ? 0 : (n * 100) / d }

    private static func perMin(_ n: Int) -> String {
        let rate = Double(n) / 15.0
        return rate >= 10 ? String(rate.toIntTruncating()) : fmt(rate, 1)
    }

    private static func band(_ list: [Int], _ lo: Int, _ hi: Int) -> Int { list.count { $0 >= lo && $0 <= hi } }
    private static func bandGe(_ list: [Int], _ lo: Int) -> Int { list.count { $0 >= lo } }
    private static func bandLt(_ list: [Int], _ hi: Int) -> Int { list.count { $0 < hi } }
}
