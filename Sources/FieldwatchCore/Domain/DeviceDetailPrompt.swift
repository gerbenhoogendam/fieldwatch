import Foundation

/// Paste-ready analyst prompt for **one** radio from the device-detail screen.
/// One-tap share; no Fieldwatch cloud.
public enum DeviceDetailPrompt {
    public static func build(
        device: Sighting,
        signatureNames: [String],
        settings: AppSettings,
        places: DebriefPlaces = DebriefPlaces.Off,
        now: Int = nowMs(),
        attentionNotes: [(String, String)] = [],
        signatureNotes: [(String, String)] = [],
        fleets: [Fleet] = [],
        mine: Bool = false
    ) -> String {
        let title = device.listTitle(signatureNames: signatureNames)
        let kind = device.kind == .wifi ? "Wi-Fi access point" : "Bluetooth LE advertiser"
        var s = ""
        func appendLine(_ t: String = "") { s += t + "\n" }
        s += DebriefPrompt.experimentalDisclaimerMarkdown()
        appendLine()
        appendLine("You are a field RF / privacy analyst with deep knowledge of IEEE OUI, Bluetooth SIG assigned numbers, GAP Appearance, known advertisement formats (iBeacon, Eddystone, Apple Continuity / Find My, Google Fast Pair, Microsoft), and common consumer products.")
        appendLine()
        appendLine("The user wants **as much information as possible** about **this one radio** from a Fieldwatch observation. Fieldwatch is a macOS, receive-only Wi-Fi + BLE listener. Use the dump below **and** your public knowledge of registries and formats. Cite which field or byte pattern supports each claim.")
        appendLine()
        appendLine("Constraints you must respect:")
        appendLine("- This is **one** advertised radio, not a person, vehicle, or legal identity.")
        appendLine("- Wi-Fi rows are **access points only**. Associated clients are invisible. macOS cannot promiscuously capture stations or probe requests here.")
        appendLine("- BLE rows are advertisers. macOS hides Bluetooth addresses; a BLE ID is a per-Mac identifier, not the radio's MAC, and is not a stable identity.")
        appendLine("- Signature / OUI / company / UUID matches are **hypotheses**, not proof of a serial, owner, or that a tracker is present.")
        appendLine("- GPS stamps (if present) are the **operator Mac** at hear-time, not this radio’s location.")
        appendLine("- Place names (if present) are system reverse-geocode of those stamps. Approximate.")
        appendLine("- RSSI is loudness at the Mac, not a measured distance.")
        appendLine("- Do not invent fields that are not in the dump. If data is thin, say so and say what would help.")
        appendLine("- Do not claim this radio is following anyone. Do not give safety advice.")
        appendLine("- Treat this paste as operationally sensitive (MAC, SSID, payload, GPS).")
        appendLine()
        appendLine("## Collection context")
        appendLine("- Tool: Fieldwatch (app.fieldwatch), receive-only, no association / injection / cloud.")
        appendLine("- Subject: \(kind) titled “\(title)”.")
        appendLine("- Scan intensity: \(settings.intensity.rawValue.lowercased()). Stale after \(settings.staleSec)s. Brief hold \(settings.decaySec)s.")
        appendLine("- Location tags: \(settings.tagLocation ? "on" : "off").")
        appendLine("- Online place names: \(settings.onlineLookup ? "on" : "off").")
        appendLine("- Randomized MAC flag: \(device.randomized ? "yes" : "no").")
        appendLine("- Hits this session: \(device.hitCount). Gone: \(device.gone).")
        if device.gpsTrail.isNotEmpty {
            appendLine("- Operator GPS trail samples on this radio: \(device.gpsTrail.count) (Mac path while it was heard).")
        }
        appendLine()
        if places.attempted {
            appendLine("## Places (operator GPS, optional)")
            appendLine(places.note)
            places.lines.forEach { appendLine($0) }
            appendLine()
        }
        appendLine("## Observation dump (verbatim from the detail page)")
        appendLine()
        s += DeviceDetailText.build(
            device: device, signatureNames: signatureNames, now: now, attentionNotes: attentionNotes,
            signatureNotes: signatureNotes, fleets: fleets, mine: mine
        ).trimEnd()
        appendLine()
        appendLine()
        appendLine("## Your analysis (required sections)")
        appendLine("1. **What it likely is** — Product class, likely brand/family, possible model. Confidence 0–100. Hedge (Most likely / Probably / Could be). List the evidence (name, OUI, company ID, Appearance, services, payload). Competing hypotheses if the data fits more than one product.")
        appendLine("2. **Registry / format decode** — IEEE OUI or CID; Bluetooth SIG company; GAP Appearance; 16-bit UUIDs; iBeacon UUID/major/minor if present; Fast Pair model ID if present; Apple Continuity type if present. Quote the hex you used. If you recognize a well-known UUID or company from public lists, say so and say the list.")
        appendLine("3. **What that product typically does** — Phone, tag, speaker, car, AP, camera, mesh node, accessory, etc. Typical radio behavior (always-on beacon vs intermittent).")
        appendLine("4. **What Fieldwatch actually saw vs what it cannot see** — macOS limits (no station/probe capture, no cellular, no DF, no BLE address). Randomized address implications.")
        appendLine("5. **Signal and presence** — Loud/quiet here; RSSI range this session; on-air windows. Do not convert RSSI to meters.")
        appendLine("6. **Signature match** — If Fieldwatch matched a signature, treat it as a filter hit, not identity. Say whether the payload also supports that family. If Notes are in the dump, use them as catalog context for that family. If Extra attention is in the dump, quote it and treat it as an operator caution on a pattern, not proof — separate from Notes.")
        appendLine("7. **Open questions** — What extra observation (another packet, name, GPS path, a second radio) would raise or lower confidence.")
        appendLine("8. **Must not conclude** — One short list of claims the dump does **not** support (owner, following, legal ID, distance).")
        appendLine()
        appendLine("End with a single one-line **takeaway** (what this radio most likely is, and one thing to check next). No safety advice.")
        return s
    }
}
