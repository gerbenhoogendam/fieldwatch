import Foundation

// Port of domain/RadioBookmarks.kt. Named radios are watchlist rows with a deviceKey (KIND:MAC).

public enum RadioBookmarks {
    public static let MAX_NAME = 22
    public static let MAX_NOTES = 280

    public static func radios(watchlist: [WatchTarget]) -> [WatchTarget] {
        watchlist.filter { $0.deviceKey != nil }
    }

    public static func namedKeys(watchlist: [WatchTarget]) -> Set<String> { Set(labels(watchlist: watchlist).keys) }

    /// Custom names keyed KIND:MAC. Blank labels omitted.
    public static func labels(watchlist: [WatchTarget]) -> [String: String] {
        var out: [String: String] = [:]
        for row in watchlist {
            guard let key = row.deviceKey else { continue }
            let label = row.label.trim()
            if label.isNotEmpty { out[key] = label }
        }
        return out
    }

    public static func notes(watchlist: [WatchTarget]) -> [String: String] {
        var out: [String: String] = [:]
        for row in watchlist {
            guard let key = row.deviceKey else { continue }
            let note = row.observerNotes.trim()
            if note.isNotEmpty { out[key] = note }
        }
        return out
    }

    public static func clipNotes(text: String) -> String { text.trim().take(MAX_NOTES) }

    public static func observerNotesHint() -> String {
        "Pinned to this MAC. Shows on Debrief, Compare, Path, and AI Export. Does not turn Alert on."
    }

    public static func watchedFleetIds(watchlist: [WatchTarget]) -> Set<String> {
        Set(watchlist.compactMap { $0.deviceKey != nil ? nil : $0.fleetId })
    }

    public static func alertDeviceKeys(watchlist: [WatchTarget]) -> Set<String> {
        Set(watchlist.compactMap { row in row.alert ? row.deviceKey : nil })
    }

    /// Device keys marked mine. Fleet rows are not included.
    public static func mineKeys(watchlist: [WatchTarget]) -> Set<String> {
        Set(watchlist.compactMap { row in row.mine ? row.deviceKey : nil })
    }

    /// Path-list note for a radio that is already plotted.
    /// Mine does not add a dot. A bookmark still gates the observer caption.
    public static func pathNote(bookmarked: Bool, observerNotes: String, mine: Bool) -> String {
        let obs = bookmarked ? observerNotes.trim() : ""
        if obs.isNotEmpty && mine { return "\(obs)\nMarked mine" }
        if mine { return "Marked mine" }
        return obs
    }

    public static func withoutRadios(watchlist: [WatchTarget]) -> [WatchTarget] {
        watchlist.filter { $0.deviceKey == nil }
    }

    public static func parseKey(key: String) -> (RadioKind, String)? {
        let kind: RadioKind
        if key.hasPrefix("WIFI:") { kind = .wifi }
        else if key.hasPrefix("BLE:") { kind = .ble }
        else { return nil }
        let mac = key.substringAfter(":").trim()
        if mac.isEmpty { return nil }
        return (kind, mac)
    }

    public static func suggestLabel(device: Sighting, signatureNames: [String] = []) -> String {
        let title = device.listTitle(signatureNames: signatureNames).trim()
        if title.isNotEmpty && !title.equals(device.mac, ignoreCase: true) {
            return clip(name: title)
        }
        return device.kind == .ble ? "unnamed LE" : clip(name: device.mac.takeLast(8))
    }

    public static func clip(name: String) -> String { name.trim().take(MAX_NAME).ifBlank("Radio") }

    /// BLE privacy addresses rotate; a name would stick to a dead key.
    /// Wi-Fi local-bit BSSIDs (guest / mesh / vehicle APs) usually stay put.
    public static func canSetCustomName(device: Sighting) -> Bool {
        if device.kind == .wifi { return true }
        // macOS: every BLE radio has a per-Mac identifier. It stays put for radios with a fixed address and
        // changes when the radio rotates its address, so naming is allowed and the hint says so.
        if MacUtil.isOpaqueId(device.mac) { return true }
        if device.facts.addressType?.equals("Random", ignoreCase: true) == true { return false }
        return !device.randomized
    }

    public static func customNameHint(device: Sighting) -> String {
        let base = "Shows on Live. Bookmark (top-right) is the alert; this does not turn it on."
        if MacUtil.isOpaqueId(device.mac) {
            return "\(base) Pinned to the identifier macOS gives this radio. Radios with a fixed address keep it; phones, earbuds and most tracker tags change it every few minutes to hours and then show up under a new one."
        }
        if device.kind == .wifi && device.randomized {
            return "\(base) Pinned to this BSSID. Vehicle, mesh, and guest APs often keep a locally administered address."
        }
        return base
    }

    public static func rename(watchlist: [WatchTarget], id: String, name: String) -> [WatchTarget] {
        let label = clip(name: name)
        return watchlist.map { row in
            guard row.id == id && row.deviceKey != nil else { return row }
            var r = row
            r.label = label
            return r
        }
    }

    public static func setNotes(watchlist: [WatchTarget], id: String, notes: String) -> [WatchTarget] {
        let note = clipNotes(text: notes)
        return watchlist.map { row in
            guard row.id == id && row.deviceKey != nil else { return row }
            var r = row
            r.observerNotes = note
            return r
        }
    }

    public static func updateNamedRadio(watchlist: [WatchTarget], id: String, name: String, notes: String) -> [WatchTarget] {
        setNotes(watchlist: rename(watchlist: watchlist, id: id, name: name), id: id, notes: notes)
    }

    public static func remove(watchlist: [WatchTarget], id: String) -> [WatchTarget] {
        watchlist.filter { !($0.id == id && $0.deviceKey != nil) }
    }

    public static func setAlert(watchlist: [WatchTarget], id: String, on: Bool) -> [WatchTarget] {
        watchlist.map { row in
            guard row.id == id && row.deviceKey != nil else { return row }
            var r = row
            r.alert = on
            return r
        }
    }

    /// Mine on a new row writes the suggested name and leaves Alert off.
    /// An existing name is kept. A blank name is filled. Turning Mine off keeps the name.
    public static func setMine(watchlist: [WatchTarget], deviceKey: String, on: Bool, suggestLabel: String) -> [WatchTarget] {
        let i = watchlist.indexOfFirst { $0.deviceKey == deviceKey }
        if !on {
            if i < 0 { return watchlist }
            var out = watchlist
            out[i].mine = false
            return out
        }
        if i < 0 {
            return watchlist + [WatchTarget(
                id: UUID().uuidString.lowercased(),
                deviceKey: deviceKey,
                label: clip(name: suggestLabel),
                alert: false,
                mine: true
            )]
        }
        let row = watchlist[i]
        let label = row.label.trim().isEmpty ? clip(name: suggestLabel) : row.label
        var out = watchlist
        out[i].label = label
        out[i].mine = true
        return out
    }

    /// Named-radios row. A blank label is filled from the key when Mine turns on.
    public static func setMineOnRow(watchlist: [WatchTarget], id: String, on: Bool) -> [WatchTarget] {
        guard let row = watchlist.first(where: { $0.id == id && $0.deviceKey != nil }),
              let key = row.deviceKey else { return watchlist }
        let trimmed = row.label.trim()
        let suggest: String
        if trimmed.isBlank {
            let mac = key.substringAfter(":")
            suggest = key.hasPrefix("BLE:") ? "unnamed LE" : mac.takeLast(8)
        } else {
            suggest = trimmed
        }
        return setMine(watchlist: watchlist, deviceKey: key, on: on, suggestLabel: suggest)
    }

    public static func toggleAlert(watchlist: [WatchTarget], deviceKey: String, suggest: String) -> [WatchTarget] {
        let i = watchlist.indexOfFirst { $0.deviceKey == deviceKey }
        if i < 0 {
            return watchlist + [WatchTarget(
                id: UUID().uuidString.lowercased(),
                deviceKey: deviceKey,
                label: clip(name: suggest),
                alert: true
            )]
        }
        var out = watchlist
        out[i].alert = !watchlist[i].alert
        return out
    }

    public static func upsertName(watchlist: [WatchTarget], deviceKey: String, name: String, alertIfNew: Bool = false) -> [WatchTarget] {
        let label = clip(name: name)
        let i = watchlist.indexOfFirst { $0.deviceKey == deviceKey }
        if i >= 0 {
            var out = watchlist
            out[i].label = label
            return out
        }
        return watchlist + [WatchTarget(
            id: UUID().uuidString.lowercased(),
            deviceKey: deviceKey,
            label: label,
            alert: alertIfNew
        )]
    }

    public static func upsertNotes(watchlist: [WatchTarget], deviceKey: String, notes: String, suggestLabel: String) -> [WatchTarget] {
        let note = clipNotes(text: notes)
        let i = watchlist.indexOfFirst { $0.deviceKey == deviceKey }
        if i >= 0 {
            var out = watchlist
            out[i].observerNotes = note
            return out
        }
        if note.isEmpty { return watchlist }
        return watchlist + [WatchTarget(
            id: UUID().uuidString.lowercased(),
            deviceKey: deviceKey,
            label: clip(name: suggestLabel),
            alert: false,
            observerNotes: note
        )]
    }
}
