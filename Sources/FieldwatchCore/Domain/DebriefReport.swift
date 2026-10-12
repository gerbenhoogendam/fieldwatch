import Foundation

// Port of domain/DebriefReport.kt. Wording is the Android text except references to the device
// running Fieldwatch ("this phone" → "this Mac") and the platform tag in the Tool meta row.

public struct ReportBar: Hashable, Sendable {
    public var label: String
    public var value: Int
    public var detail: String
    public var second: Int?

    public init(label: String, value: Int, detail: String = "", second: Int? = nil) {
        self.label = label; self.value = value; self.detail = detail; self.second = second
    }
}

public struct ReportChart: Hashable, Sendable {
    public var rows: [ReportBar]
    public var split: Bool
    public var caption: String

    public init(rows: [ReportBar], split: Bool = false, caption: String = "") {
        self.rows = rows; self.split = split; self.caption = caption
    }

    public func asText() -> String {
        var s = ""
        if caption.isNotBlank { s += caption + "\n" }
        for row in rows {
            if let second = row.second {
                s += "\(row.label): \(row.value) Wi-Fi, \(second) BLE\n"
            } else {
                s += "\(row.label)  \(row.value)"
                if row.detail.isNotBlank { s += "  \(row.detail)" }
                s += "\n"
            }
        }
        return s.trimEnd()
    }
}

public struct DebriefSection: Hashable, Sendable {
    public var number: String
    public var title: String
    public var body: String
    public var alert: Bool
    public var chart: ReportChart?
    public var after: String

    public init(number: String, title: String, body: String, alert: Bool = false, chart: ReportChart? = nil, after: String = "") {
        self.number = number; self.title = title; self.body = body; self.alert = alert; self.chart = chart; self.after = after
    }
}

public struct DebriefPlaces: Hashable, Sendable {
    public var attempted: Bool
    public var available: Bool
    public var note: String
    public var lines: [String]
    public var namesByCell: [String: String]
    /// macOS addition: insertion order of `namesByCell` keys (Kotlin used a LinkedHashMap).
    /// Keys missing here are appended in sorted order.
    public var cellOrder: [String]

    public init(attempted: Bool, available: Bool, note: String, lines: [String] = [],
                namesByCell: [String: String] = [:], cellOrder: [String] = []) {
        self.attempted = attempted; self.available = available; self.note = note; self.lines = lines
        self.namesByCell = namesByCell; self.cellOrder = cellOrder
    }

    public static let Off = DebriefPlaces(attempted: false, available: false, note: "off")

    private func orderedCells() -> [String] {
        let known = cellOrder.filter { namesByCell[$0] != nil }.distinct()
        let seen = Set(known)
        return known + namesByCell.keys.filter { !seen.contains($0) }.sorted()
    }

    /// Exact GPS cell, then nearest named cell within `maxM`.
    public func nameNear(lat: Double, lon: Double, maxM: Double = 90.0) -> String? {
        if let exact = namesByCell[Geo.cellKey(lat: lat, lon: lon)] { return exact }
        var best: String?
        var bestD = maxM
        for key in orderedCells() {
            let name = namesByCell[key]!
            let parts = key.split(",")
            if parts.count != 2 { continue }
            guard let klat = parts[0].toDoubleOrNull(), let klon = parts[1].toDoubleOrNull() else { continue }
            let d = Geo.meters(lat1: lat, lon1: lon, lat2: klat, lon2: klon)
            if d < bestD {
                bestD = d
                best = name
            }
        }
        return best
    }

    public func areaLine() -> String {
        if !attempted { return "off" }
        let named = orderedCells().map { namesByCell[$0]!.trim() }.filter { $0.isNotEmpty }.distinct()
        if named.isEmpty { return note }
        return named.joined(separator: " · ")
    }
}

public struct ExtraAttentionHit: Hashable, Sendable {
    public var signature: String
    public var radioLabel: String
    public var note: String
    public init(signature: String, radioLabel: String, note: String) {
        self.signature = signature; self.radioLabel = radioLabel; self.note = note
    }
}

public struct DebriefDoc {
    public var generatedUtc: String
    public var windowLine: String
    public var meta: [(String, String)]
    public var disclaimer: String
    public var trackingAlert: Bool
    public var takeaway: String
    public var sections: [DebriefSection]
    public var extraAttention: [ExtraAttentionHit]
    public var heading: String
    public var pdfKicker: String
    public var pdfTitle: String
    public var pathFigure: SitPathPlot.Figure?
    public var extraFigures: [SitPathPlot.Figure]

    public init(
        generatedUtc: String, windowLine: String, meta: [(String, String)], disclaimer: String,
        trackingAlert: Bool, takeaway: String, sections: [DebriefSection], extraAttention: [ExtraAttentionHit] = [],
        heading: String = "FIELDWATCH FIELD DEBRIEF", pdfKicker: String = "FIELD DEBRIEF",
        pdfTitle: String = "Field debrief", pathFigure: SitPathPlot.Figure? = nil, extraFigures: [SitPathPlot.Figure] = []
    ) {
        self.generatedUtc = generatedUtc; self.windowLine = windowLine; self.meta = meta; self.disclaimer = disclaimer
        self.trackingAlert = trackingAlert; self.takeaway = takeaway; self.sections = sections
        self.extraAttention = extraAttention; self.heading = heading; self.pdfKicker = pdfKicker
        self.pdfTitle = pdfTitle; self.pathFigure = pathFigure; self.extraFigures = extraFigures
    }

    public func toPlainText() -> String {
        var s = ""
        func line(_ x: String = "") { s += x + "\n" }
        line(heading)
        line()
        line("DISCLAIMER")
        line(disclaimer)
        line()
        for (k, v) in meta { line("\(k.padEnd(14))\(v)") }
        line()
        for sec in sections {
            line("\(sec.number). \(sec.title.uppercased())")
            let body = sec.body.trimEnd()
            if body.isNotEmpty { line(body) }
            if let chart = sec.chart?.asText(), chart.isNotBlank { line(chart) }
            let after = sec.after.trimEnd()
            if after.isNotEmpty { line(after) }
            line()
        }
        line("—")
        line("Takeaway: \(takeaway)")
        return s
    }

    public func withDemoMacs(macs: [String], demo: Bool, uasIds: [String] = []) -> DebriefDoc {
        if !demo { return self }
        func t(_ s: String) -> String { MacUtil.redactPrivateText(text: s, macs: macs, uasIds: uasIds, demo: true) }
        let note = "MAC tails (**:**:**), UAS ids, and GPS coordinates masked. Logs on the Mac are unchanged."
        var c = self
        c.meta = [("Privacy", note)] + meta.map { ($0.0, t($0.1)) }
        c.disclaimer = t(disclaimer)
        c.takeaway = t(takeaway)
        c.sections = sections.map { sec in
            var x = sec
            x.title = t(sec.title)
            x.body = t(sec.body)
            x.after = t(sec.after)
            x.chart = sec.chart.map { chart in
                var ch = chart
                ch.caption = t(chart.caption)
                ch.rows = chart.rows.map { row in
                    var r = row
                    r.label = t(row.label)
                    r.detail = t(row.detail)
                    return r
                }
                return ch
            }
            return x
        }
        c.extraAttention = extraAttention.map {
            ExtraAttentionHit(signature: t($0.signature), radioLabel: t($0.radioLabel), note: t($0.note))
        }
        c.pathFigure = pathFigure?.withDemoText(t)
        c.extraFigures = extraFigures.map { $0.withDemoText(t) }
        return c
    }
}

/// Path-key and caption text. The drawn track keeps its coordinates.
private extension SitPathPlot.Figure {
    func withDemoText(_ t: (String) -> String) -> SitPathPlot.Figure {
        var f = self
        f.caption = t(caption)
        f.craftKeys = craftKeys.map(t)
        f.tracks = tracks.map { track in var x = track; x.name = t(track.name); return x }
        f.pilots = pilots.map { mark in var x = mark; x.label = t(mark.label); return x }
        f.dots = dots.map { dot in
            var x = dot
            x.label = t(dot.label)
            x.mac = MacUtil.screenMac(mac: dot.mac, demo: true)
            x.fleetNames = dot.fleetNames.map(t)
            x.observerNotes = t(dot.observerNotes)
            x.advertisedNote = t(dot.advertisedNote)
            return x
        }
        f.gnss = gnss.map { pin in var x = pin; x.detail = t(pin.detail); x.confidence = t(pin.confidence); return x }
        return f
    }
}

/// Standalone field debrief (not an AI prompt). Heuristic sit report from
/// the last 15 minutes plus GPS co-travel of tracker-like radios.
public enum DebriefReport {
    private static let WINDOW_MS = 15 * 60_000
    private static let SHORT_MS = 5 * 60_000
    private static let MOVE_M = 45.0
    /// Possible-tail extra gates. Own-kit uses a louder, longer “still here” window.
    private static let COVER_FRAC = 0.5
    private static let FADE_DB = 12
    private static let TRAIL_LOUD_DBM = CoTravel.TRAIL_LOUD_DBM
    /// Own-kit “still here” — AirTags advertise slowly and rotate.
    private static let OWN_HERE_MS = 180_000
    private static let TAIL_HERE_MS = 20_000
    private static let ON_BODY_MAX = -55
    private static let ON_BODY_MIN = -70

    public static func build(
        devices: [Sighting],
        fleets: [Fleet],
        settings: AppSettings,
        operatorPath: [GpsSample],
        now: Int = nowMs(),
        places: DebriefPlaces = DebriefPlaces.Off,
        window: DebriefWindow? = nil,
        customNames: [String: String] = [:],
        observerNotes: [String: String] = [:],
        bookmarkedKeys: Set<String> = [],
        watchedFleetIds: Set<String> = [],
        mineKeys: Set<String> = [],
        floods: [FloodBurst] = [],
        gnss: [GnssMark] = []
    ) -> String {
        document(
            devices: devices, fleets: fleets, settings: settings, operatorPath: operatorPath, now: now,
            places: places, window: window, customNames: customNames, observerNotes: observerNotes,
            bookmarkedKeys: bookmarkedKeys, watchedFleetIds: watchedFleetIds, mineKeys: mineKeys,
            floods: floods, gnss: gnss
        ).toPlainText()
    }

    public static func document(
        devices: [Sighting],
        fleets: [Fleet],
        settings: AppSettings,
        operatorPath: [GpsSample],
        now: Int = nowMs(),
        places: DebriefPlaces = DebriefPlaces.Off,
        window: DebriefWindow? = nil,
        customNames: [String: String] = [:],
        observerNotes: [String: String] = [:],
        bookmarkedKeys: Set<String> = [],
        watchedFleetIds: Set<String> = [],
        mineKeys: Set<String> = [],
        floods: [FloodBurst] = [],
        gnss: [GnssMark] = []
    ) -> DebriefDoc {
        let names = fleetNames(fleets)
        let win = window ?? DebriefWindow(startAt: now - WINDOW_MS, endAt: now)
        let windowStart = win.startAt
        let windowEnd = win.endAt
        let aside = FloodBurst.keysOf(floods: floods, start: windowStart, end: windowEnd)
        let inWin = devices
            .filter { ($0.lastSeen >= windowStart || $0.firstSeen >= windowStart) && !aside.contains($0.key) }
            .sortedByDescending { $0.rssi }
        let wifi = inWin.filter { $0.kind == .wifi }
        let ble = inWin.filter { $0.kind == .ble }
        let named = inWin.filter { $0.fleetIds.isNotEmpty }
        let hidden = wifi.filter { $0.hiddenSsid }
        let randomized = ble.count { $0.randomized }
        let arrived = inWin.filter { $0.firstSeen >= windowStart }
        let persistent = inWin.filter { dwellMs($0, windowStart, windowEnd) >= win.durationMs * 2 / 3 }
        let path = operatorPath.filter { inRange($0.at, windowStart, windowEnd) }
        let gnssInWindow = gnss.filter { mark in
            inRange(mark.at, windowStart, windowEnd) || (mark.endedAt > 0 && inRange(mark.endedAt, windowStart, windowEnd))
        }
        let gnssPins = SitPathPlot.gnssPins(marks: gnssInWindow, path: Geo.despikePath(samples: path))
        let gnssOnPath = gnssPins.isNotEmpty
        let pathSpan = Geo.spanM(samples: path)
        let pathLen = Geo.pathLengthM(samples: path)
        let trackers = inWin.filter { TrackerMatch.kind(device: $0, names: names) == .finder }
        let follow = followAssessments(trackers, names, path, windowStart, windowEnd, .finder)
        let beaconFollow = followAssessments(
            inWin.filter { TrackerMatch.kind(device: $0, names: names) == .beacon },
            names, path, windowStart, windowEnd, .beacon
        )
        let wearableFollow = followAssessments(
            inWin.filter { TrackerMatch.kind(device: $0, names: names) == .wearable },
            names, path, windowStart, windowEnd, .wearable
        )
        let assessed = follow + beaconFollow + wearableFollow
        func open(_ l: [FollowHit]) -> [FollowHit] { l.filter { !mineKeys.contains($0.device.key) } }
        let following = open(follow.filter { $0.verdict == .following })
        let withYou = open(follow.filter { $0.verdict == .movedWithYou })
        let ownLikely = open(follow.filter { $0.verdict == .ownLikely })
        let wholeSit = ownLikely + withYou
        let beaconsWithYou = open(stayedWithYou(beaconFollow))
        let wearablesWithYou = open(stayedWithYou(wearableFollow))
        let mineHeard = inWin.count { mineKeys.contains($0.key) }

        let showAll = settings.debriefShowAllRadios
        func listedWhenShort(_ d: Sighting) -> Bool {
            customNames[d.key] != nil || mineKeys.contains(d.key) || bookmarkedKeys.contains(d.key)
        }
        let byCh = wifi.groupByOrdered { $0.channel }.sortedBy { $0.0 }
        let channelChart: ReportChart? = byCh.isEmpty ? nil : ReportChart(
            rows: byCh.map { ch, list in
                let label = ch == 0 ? "unknown" : "ch \(ch)"
                return ReportBar(label: label, value: list.count, detail: "strongest \(list.map { $0.rssi }.max()!) dBm")
            }
        )
        let networks = "Heard \(wifi.count) AP(s); \(hidden.count) hidden SSID; \(persistent.count { $0.kind == .wifi }) sat most of the window."
        let networksAfter: String
        if !showAll {
            networksAfter = wifiLines(
                wifi.filter { listedWhenShort($0) && $0.fleetIds.isEmpty },
                names, windowStart, now, customNames, fleets, mineKeys
            )
        } else {
            var s = "Loudest APs:\n"
            for d in wifi.take(12) {
                s += "  · \(wifiLine(d, names, windowStart, now, customNames))\n"
                if mineKeys.contains(d.key) { s += "    Marked mine\n" }
                for (sig, note) in d.attentionNotes(fleets: fleets) {
                    s += "    extra attention (\(sig)): \(note)\n"
                }
            }
            if hidden.isNotEmpty {
                s += "Hidden SSIDs:\n"
                for h in hidden { s += "  · \(h.mac)  \(h.vendor ?? "")  \(h.rssi) dBm  ch \(h.channel)\n" }
            }
            networksAfter = s.trimEnd()
        }
        let notable = ble.filter {
            inventoryKeep($0, settings, bookmarkedKeys) &&
                ($0.fleetIds.isNotEmpty || $0.name.isNotBlank || $0.rssi >= -65 || $0.manufacturerId != nil)
        }.sortedByDescending { $0.rssi }.take(20)
        let omittedRand = ble.count { !inventoryKeep($0, settings, bookmarkedKeys) }
        var bleBodyRaw = "Heard \(ble.count) advertiser(s); \(randomized) with randomized addresses; \(named.count { $0.kind == .ble }) signature-matched.\n"
        if omittedRand > 0 {
            bleBodyRaw += "Unmatched rotating BLE omitted from lists (\(omittedRand)). Counts include them. Sit export has every radio.\n"
        }
        let bleBody = bleBodyRaw.trimEnd()
        let bleAfter: String
        if showAll && notable.isNotEmpty {
            var s = "Notable BLE:\n"
            for d in notable {
                let guess = DeviceExplain.guess(device: d, signatureNames: d.fleetIds.map { names[$0] ?? $0 })
                s += "  · \(bleLine(d, names, windowStart, now, customNames))  |  \(guess.headline)\n"
                if mineKeys.contains(d.key) { s += "    Marked mine\n" }
                for (sig, note) in d.attentionNotes(fleets: fleets) {
                    s += "    extra attention (\(sig)): \(note)\n"
                }
                let decoded = SignatureFieldDecoder.decodeSighting(device: d, fleets: fleets)
                if decoded.isNotEmpty {
                    for row in decoded {
                        s += "    \(row.label): \(row.display)\n"
                        if row.note.isNotBlank { s += "    \(row.note)\n" }
                    }
                } else {
                    for chip in d.liveDecode {
                        s += "    \(chip.reportLabel())"
                        if chip.note.isNotBlank { s += "  " + chip.note }
                        s += "\n"
                    }
                }
            }
            bleAfter = s.trimEnd()
        } else if !showAll {
            bleAfter = bleLines(
                ble.filter { listedWhenShort($0) && $0.fleetIds.isEmpty },
                names, windowStart, now, customNames, mineKeys
            )
        } else {
            bleAfter = ""
        }
        let sigChart = signatureChart(named, names)
        let sigBody = named.isEmpty ? "None in this window." : ""
        let sigAfter: String
        if named.isEmpty {
            sigAfter = ""
        } else if showAll {
            var s = ""
            let groups = named.groupByOrdered { $0.fleetIds.map { id in names[id] ?? id }.joined(separator: "+") }
                .sortedByDescending { $0.1.count }
            for (sig, list) in groups {
                s += sig + "\n"
                for d in list.sortedByDescending({ $0.rssi }).take(8) {
                    s += "  · \(d.reportName(customNames: customNames))  \(d.mac)  \(d.rssi) dBm"
                    if mineKeys.contains(d.key) { s += "  Marked mine" }
                    let labels = d.liveDecode.reportLabels()
                    if labels.isNotEmpty { s += "  " + labels.joined(separator: ", ") }
                    s += "\n"
                }
                let notes = list.flatMap { $0.attentionNotes(fleets: fleets) }.distinctBy { "\($0.0)\u{0}\($0.1)" }
                for (name, note) in notes {
                    s += "  extra attention (\(name)): \(note)\n"
                }
            }
            sigAfter = s.trimEnd()
        } else {
            var s = ""
            let marked = named.filter { listedWhenShort($0) }.sortedByDescending { $0.rssi }
            if marked.isNotEmpty { s += "Named or marked:\n" }
            for d in marked {
                s += "  · \(d.reportName(customNames: customNames))  \(d.mac)  \(d.rssi) dBm"
                if mineKeys.contains(d.key) { s += "  Marked mine" }
                let labels = d.liveDecode.reportLabels()
                if labels.isNotEmpty { s += "  " + labels.joined(separator: ", ") }
                s += "\n"
            }
            sigAfter = s.trimEnd()
        }
        let persistBody = ("Sat most of this window: \(persistent.count)\n" + "First seen in this window: \(arrived.count)").trimEnd()
        let persistAfter: String
        if !showAll {
            persistAfter = ""
        } else {
            var s = ""
            for d in persistent.filter({ inventoryKeep($0, settings, bookmarkedKeys) }).take(15) {
                s += "  · \(d.reportName(customNames: customNames))  \(d.mac)  dwell \(fmtDur(dwellMs(d, windowStart, now)))\n"
            }
            if persistent.isEmpty { s += "  · None.\n" }
            s += "Loudest first seen:\n"
            for d in arrived.filter({ inventoryKeep($0, settings, bookmarkedKeys) }).sortedByDescending({ $0.rssi }).take(8) {
                s += "  · \(d.reportName(customNames: customNames))  \(d.mac)  \(d.rssi) dBm\n"
            }
            persistAfter = s.trimEnd()
        }
        let flags = anomalyLines(inWin, customNames, settings, bookmarkedKeys, showAll)
        let anomalyBody = flags.isEmpty
            ? "No extra flags. Signature hits, Extra attention, and tracking callouts already cover named pattern matches."
            : flags.map { "  · \($0)" }.joined(separator: "\n")
        let attentionHits: [(Sighting, String, String)] = inWin.flatMap { d in
            d.attentionNotes(fleets: fleets).map { (d, $0.0, $0.1) }
        }
        let actionBody = actions(following, withYou, ownLikely, beaconsWithYou, wearablesWithYou, settings, pathSpan)
            .map { "  · \($0)" }.joined(separator: "\n")

        let distanceLine: String
        if !settings.tagLocation {
            distanceLine = "GPS tagging off — no path"
        } else if path.count < 2 {
            distanceLine = "GPS tagging on, fewer than 2 fixes in this window"
        } else {
            distanceLine = "traveled \(fmtDist(pathLen)) along path · span \(fmtDist(pathSpan)) · \(path.count) fixes"
        }
        let lookupLine: String
        if !places.attempted {
            lookupLine = "off"
        } else if places.namesByCell.isNotEmpty {
            lookupLine = places.areaLine()
        } else {
            lookupLine = places.note
        }
        let pictures = AircraftTrail.pictures(
            sources: inWin.compactMap { d in AircraftTrail.source(device: d, title: d.reportName(customNames: customNames)) },
            path: path
        )
        let aircraftBody = AircraftTrail.body(pictures: pictures)
        var n = 1
        func next() -> String { defer { n += 1 }; return String(n) }
        var sections: [DebriefSection] = []
        sections.append(DebriefSection(
            number: next(),
            title: "Executive summary",
            body: execSummary(wifi, ble, named, hidden, randomized, pathSpan, pathLen, following, withYou, ownLikely,
                              beaconsWithYou, wearablesWithYou, settings, places, win, mineHeard) + craftSentence(pictures),
            chart: classChart(inWin, fleets)
        ))
        sections.append(DebriefSection(
            number: next(), title: "Where you were",
            body: whereYouWere(settings, path, pathLen, pathSpan, inWin, names, places, windowEnd, customNames, bookmarkedKeys)
        ))
        if aircraftBody.isNotEmpty {
            sections.append(DebriefSection(number: next(), title: "Aircraft", body: aircraftBody))
        }
        if let body = observerNotesSection(inWin, customNames, observerNotes) {
            sections.append(DebriefSection(number: next(), title: "Observer notes", body: body))
        }
        if let body = markedMineSection(inWin, customNames, mineKeys, assessed) {
            sections.append(DebriefSection(number: next(), title: "Marked mine", body: body))
        }
        sections.append(DebriefSection(
            number: next(), title: "Tracking assessment",
            body: trackingSection(settings, path, pathSpan, pathLen, following, wholeSit, beaconsWithYou, wearablesWithYou)
        ))
        if wholeSit.isNotEmpty {
            sections.append(DebriefSection(
                number: next(),
                title: "Possible trackers with you",
                body: trackerCallout(
                    "Finder tags (AirTag / Find My, SmartTag, Tile, Chipolo, Pebblebee) and loud pocket Apple BLE. " +
                        "These radios stayed with your GPS path for this sit. " +
                        "Fieldwatch cannot tell your own tag or phone from a tracker planted in the car, bag, or on you before you started. " +
                        "Account for each MAC. Not a finding and not identity.",
                    wholeSit,
                    customNames
                ),
                alert: true
            ))
        }
        if following.isNotEmpty {
            sections.append(DebriefSection(
                number: next(),
                title: "Possible tail",
                body: trackerCallout(
                    "Finder tags that were not heard when this sit started, then stayed with your path. " +
                        "That can mean someone started following you (their phone or tag), or a device was added during the trip. " +
                        "Not a finding and not identity.",
                    following,
                    customNames
                ),
                alert: true
            ))
        }
        if beaconsWithYou.isNotEmpty {
            sections.append(DebriefSection(
                number: next(),
                title: "Retail beacons with you",
                body: trackerCallout(
                    "iBeacon / Minew / Estimote / Kontakt.io / Atrius cart tag radios that stayed with your GPS path. " +
                        "Location beacons are usually fixtures in a store or venue — they do not typically move with you. " +
                        "If one did, account for it (a cart you pushed, your own test tag, a badge, or a short path that still overlaps a fixture). " +
                        "Not the same as a Find My tail. Not a finding and not identity.",
                    beaconsWithYou,
                    customNames
                ),
                alert: true
            ))
        }
        if wearablesWithYou.isNotEmpty {
            sections.append(DebriefSection(
                number: next(),
                title: "Wearables with you",
                body: trackerCallout(
                    "Garmin / Fitbit / Oura / Polar radios that stayed with your GPS path. " +
                        "Watches and rings usually move with the person wearing them — often your own kit or someone walking with you. " +
                        "They are not typically planted trackers. Account for each MAC. Not a finding and not identity.",
                    wearablesWithYou,
                    customNames
                ),
                alert: true
            ))
        }
        sections.append(DebriefSection(number: next(), title: "Environment", body: environment(wifi, ble, randomized, persistent, pathSpan, pathLen)))
        sections.append(DebriefSection(
            number: next(),
            title: "Networks (Wi-Fi access points)",
            body: networks.trimEnd(),
            chart: channelChart,
            after: networksAfter.trimEnd()
        ))
        sections.append(DebriefSection(number: next(), title: "Bluetooth LE", body: bleBody.trimEnd(), after: bleAfter.trimEnd()))
        sections.append(DebriefSection(number: next(), title: "Signature hits", body: sigBody.trimEnd(), chart: sigChart, after: sigAfter.trimEnd()))
        sections.append(DebriefSection(number: next(), title: "Persistence", body: persistBody.trimEnd(), after: persistAfter.trimEnd()))
        if attentionHits.isNotEmpty {
            var s = "Pattern match, not identity, not a skimmer detector, not a safety finding.\n"
            for (d, sig, note) in attentionHits {
                s += "  · \(d.reportName(customNames: customNames))  \(d.mac)  \(d.rssi) dBm  [\(sig)]"
                if mineKeys.contains(d.key) { s += "  Marked mine" }
                s += "\n"
                s += "    \(note)\n"
            }
            sections.append(DebriefSection(number: next(), title: "Extra attention", body: s.trimEnd(), alert: true))
        }
        sections.append(DebriefSection(number: next(), title: "Anomalies", body: anomalyBody))
        if let body = floodBody(floods, windowStart, windowEnd) {
            sections.append(DebriefSection(number: next(), title: "Flood", body: body))
        }
        if let body = gnssBody(gnss, windowStart, windowEnd, onPath: gnssOnPath) {
            sections.append(DebriefSection(number: next(), title: "GNSS", body: body, alert: true))
        }
        sections.append(DebriefSection(number: next(), title: "Privacy", body: privacy(wifi, ble, randomized, hidden, settings, places, pictures.isNotEmpty)))
        sections.append(DebriefSection(number: next(), title: "Recommended actions", body: actionBody))

        let windowLine: String
        let heading: String
        if let sitName = win.sitName {
            windowLine = "sit \(sitName) (\(utc(windowStart)) → \(utc(windowEnd)) UTC)"
            heading = "FIELDWATCH SIT — \(sitName)"
        } else {
            windowLine = "last 15 minutes (\(utc(windowStart)) → \(utc(windowEnd)) UTC)"
            heading = "FIELDWATCH FIELD DEBRIEF"
        }
        var meta: [(String, String)] = []
        meta.append(("Generated", "\(utc(now)) UTC"))
        if let sitName = win.sitName { meta.append(("Sit", sitName)) }
        meta.append(("Window", windowLine))
        meta.append(("Radios", "\(inWin.count)"))
        meta.append(("Tool", "Fieldwatch (app.fieldwatch) · macOS · receive-only Wi-Fi AP + BLE advertiser"))
        meta.append(("Scan", "\(settings.intensity.rawValue.lowercased()) · stale \(settings.staleSec)s · brief hold \(settings.decaySec)s"))
        meta.append(("GPS tag", settings.tagLocation ? "on" : "off"))
        meta.append(("Distance", distanceLine))
        meta.append(("Places", lookupLine))
        meta.append((
            "Classification",
            pictures.isNotEmpty
                ? "Operationally sensitive — neighbor SSIDs, MACs, operator GPS, advertised aircraft track"
                : "Operationally sensitive — neighbor SSIDs, MACs, operator GPS"
        ))
        return DebriefDoc(
            generatedUtc: utc(now),
            windowLine: windowLine,
            meta: meta,
            disclaimer: FieldwatchDisclaimer.report(window: win),
            trackingAlert: following.isNotEmpty || ownLikely.isNotEmpty || withYou.isNotEmpty,
            takeaway: takeaway(following, withYou, ownLikely, beaconsWithYou, wearablesWithYou, pathSpan, settings, named),
            sections: sections,
            extraAttention: attentionHits.map { d, sig, note in
                var label = "\(d.reportName(customNames: customNames))  \(d.mac)  \(d.rssi) dBm"
                if mineKeys.contains(d.key) { label += "  Marked mine" }
                return ExtraAttentionHit(signature: sig, radioLabel: label, note: note)
            },
            heading: heading,
            pdfKicker: win.sitName != nil ? "SIT" : "FIELD DEBRIEF",
            pdfTitle: win.sitName.map { "Sit — \($0)" } ?? "Field debrief",
            pathFigure: AircraftTrail.applyWalk(
                base: pathFigure(
                    win.sitName ?? "Last 15 minutes", path, inWin, fleets,
                    customNames, observerNotes, bookmarkedKeys, watchedFleetIds, mineKeys,
                    gnssPins
                ),
                pictures: pictures,
                secondary: false
            ),
            extraFigures: AircraftTrail.ownFigures(pictures: pictures)
        )
    }

    private static func pathFigure(
        _ title: String,
        _ rawPath: [GpsSample],
        _ devices: [Sighting],
        _ fleets: [Fleet],
        _ customNames: [String: String],
        _ observerNotes: [String: String] = [:],
        _ bookmarkedKeys: Set<String> = [],
        _ watchedFleetIds: Set<String> = [],
        _ mineKeys: Set<String> = [],
        _ gnss: [SitPathPlot.GnssPin] = []
    ) -> SitPathPlot.Figure? {
        let path = Geo.despikePath(samples: rawPath)
        if path.count < 2 { return nil }
        let plot = SitPathPlot.dotsFrom(
            devices: devices, fleets: fleets, namedKeys: Set(customNames.keys),
            customNames: customNames, observerNotes: observerNotes,
            bookmarkedKeys: bookmarkedKeys,
            watchedFleetIds: watchedFleetIds,
            alertsOnly: true,
            mineKeys: mineKeys
        )
        var caption = ""
        caption += "North-up. Line is this Mac (\(lengthLabel(path))). "
        caption += "A MAC alert or a signature alert is drawn once. "
        caption += "A decoded latitude and longitude is the last advertised position. "
        caption += "Anything else is the strongest hear. A number is that place (Path key)."
        if gnss.isNotEmpty {
            caption += " A red diamond is where this Mac was during a GNSS detection. "
            caption += "The Path key has the time and what changed. "
            caption += "It does not say where the interference came from."
        }
        return SitPathPlot.Figure(
            kicker: "OPERATOR PATH",
            tracks: [SitPathPlot.FigureTrack(name: title, samples: path)],
            dots: plot.points,
            lengthM: Geo.pathLengthM(samples: path),
            spanM: Geo.spanM(samples: path),
            caption: caption,
            gnss: gnss
        )
    }

    private static func lengthLabel(_ path: [GpsSample]) -> String {
        let m = Geo.pathLengthM(samples: path)
        return m >= 1000 ? "\(fmt(m / 1000, 1)) km" : "\(m.toIntTruncating()) m"
    }

    /// GPS / places / co-travel block for the AI Export prompt. Same heuristics
    /// as the field debrief; markdown so a chat model can cite it.
    public static func gpsAnalystMarkdown(
        devices: [Sighting],
        fleets: [Fleet],
        settings: AppSettings,
        operatorPath: [GpsSample],
        now: Int = nowMs(),
        places: DebriefPlaces = DebriefPlaces.Off,
        window: DebriefWindow? = nil,
        customNames: [String: String] = [:],
        bookmarkedKeys: Set<String> = [],
        mineKeys: Set<String> = []
    ) -> String {
        var s = ""
        func line(_ x: String = "") { s += x + "\n" }
        let names = fleetNames(fleets)
        let win = window ?? DebriefWindow(startAt: now - WINDOW_MS, endAt: now)
        let windowStart = win.startAt
        let windowEnd = win.endAt
        let path = operatorPath.filter { inRange($0.at, windowStart, windowEnd) }
        let pathSpan = Geo.spanM(samples: path)
        let pathLen = Geo.pathLengthM(samples: path)
        let inWin = devices.filter { $0.lastSeen >= windowStart || $0.firstSeen >= windowStart }
        let trackers = inWin.filter { TrackerMatch.kind(device: $0, names: names) == .finder }
        let follow = followAssessments(trackers, names, path, windowStart, windowEnd, .finder)
        let beaconsMd = stayedWithYou(followAssessments(
            inWin.filter { TrackerMatch.kind(device: $0, names: names) == .beacon },
            names, path, windowStart, windowEnd, .beacon
        ))
        let wearablesMd = stayedWithYou(followAssessments(
            inWin.filter { TrackerMatch.kind(device: $0, names: names) == .wearable },
            names, path, windowStart, windowEnd, .wearable
        ))

        line("## Where you were (operator GPS)")
        line("- Tag detections with GPS: \(settings.tagLocation ? "on" : "off").")
        line(
            "- Online place names: " +
                (places.attempted ? places.note : "off (Settings → Online place names in Debrief). No reverse-geocode this export.")
        )
        s += whereYouWere(settings, path, pathLen, pathSpan, inWin, names, places, windowEnd, customNames, bookmarkedKeys).trimEnd()
        line()
        line()
        if path.count < 2 || pathSpan < MOVE_M {
            line("- Following test: insufficient movement (need ~45 m span). Do not infer a tail.")
            line()
        }
        line("## GPS co-travel")
        line(
            "Only radios that stayed with the operator path are listed. " +
                "House tags and other radios the operator only passed are omitted — they are not tracking. " +
                "Not identity. Find My MAC rotation will not stitch a tail that changes address. " +
                "Possible tail extra gates (walks): trail covers ≥ half the operator path, " +
                "≥ 2/3 of GPS stamps at −75 dBm or louder, last stamp not 12 dB below loudest. " +
                "Fail any one → omit (pass-by), not a tail. " +
                "Finder tags (AirTag / SmartTag / Tile / Chipolo / Pebblebee / Find My / loud pocket Apple) " +
                "are the tracking test. Retail beacons and wearables that co-travel are listed separately — " +
                "they do not typically move with you (beacons) or are usually own kit (wearables)."
        )
        func open(_ l: [FollowHit]) -> [FollowHit] { l.filter { !mineKeys.contains($0.device.key) } }
        let followingMd = open(follow.filter { $0.verdict == .following })
        let wholeSitMd = open(follow.filter { $0.verdict == .ownLikely || $0.verdict == .movedWithYou })
        let beaconsOpen = open(beaconsMd)
        let wearablesOpen = open(wearablesMd)
        if followingMd.isEmpty && wholeSitMd.isEmpty && beaconsOpen.isEmpty && wearablesOpen.isEmpty {
            line("- None stayed with the path.")
        } else {
            func dump(_ title: String, _ rows: [FollowHit]) {
                if rows.isEmpty { return }
                line()
                line("### \(title)")
                for h in rows {
                    let d = h.device
                    line(
                        "- \(h.label)  \(d.reportName(customNames: customNames))  \(d.mac)  RSSI \(d.rssi) dBm " +
                            "(min \(d.rssiMin) / max \(d.rssiMax))  trail \(h.samples) fixes, span \(h.spanM.toIntTruncating()) m"
                    )
                    line("  \(h.detail)")
                }
            }
            dump("Possible trackers with you (finder tags, whole sit — yours or planted before you started)", wholeSitMd)
            dump("Possible tail (finder tags, first heard after this sit started, then stayed)", followingMd)
            dump(
                "Retail beacons with you (iBeacon / Minew / Estimote / Kontakt.io / Atrius cart tag — fixtures; a pushed cart will co-travel)",
                beaconsOpen
            )
            dump("Wearables with you (Garmin / Fitbit / Oura / Polar — usually own kit or a companion)", wearablesOpen)
        }
        return s
    }

    private enum Verdict: Int { case following, movedWithYou, ownLikely, stationary, insufficient }

    private struct FollowHit {
        var device: Sighting
        var label: String
        var verdict: Verdict
        var detail: String
        var spanM: Double
        var samples: Int
    }

    private static func fleetNames(_ fleets: [Fleet]) -> [String: String] {
        var names: [String: String] = [:]
        for f in fleets { names[f.id] = f.name }
        return names
    }

    private static func inRange(_ v: Int, _ lo: Int, _ hi: Int) -> Bool { v >= lo && v <= hi }

    private static func stayedWithYou(_ hits: [FollowHit]) -> [FollowHit] {
        hits.filter { $0.verdict == .following || $0.verdict == .movedWithYou || $0.verdict == .ownLikely }
    }

    private static func followAssessments(
        _ trackers: [Sighting],
        _ names: [String: String],
        _ operatorPath: [GpsSample],
        _ windowStart: Int,
        _ now: Int,
        _ kind: TrackerMatch.Kind
    ) -> [FollowHit] {
        let opSpan = Geo.spanM(samples: operatorPath)
        let opLen = Geo.pathLengthM(samples: operatorPath)
        return trackers.map { d -> FollowHit in
            let label = TrackerMatch.label(device: d, names: names)
            let trail = d.gpsTrail.filter { $0.at >= windowStart }
            let span = Geo.spanM(samples: trail)
            let trailLen = Geo.pathLengthM(samples: trail)
            let presentAtStart = d.firstSeen <= windowStart + 15_000
            let stillHere = now - d.lastSeen <= TAIL_HERE_MS
            let ownHere = now - d.lastSeen <= OWN_HERE_MS
            let onBody = d.rssiMax >= ON_BODY_MAX && d.rssiMin >= ON_BODY_MIN && trail.count >= 2
            let cover = opLen > 0.0 && trailLen >= COVER_FRAC * opLen
            let verdict: Verdict
            let detail: String
            if operatorPath.count < 2 || opSpan < MOVE_M {
                verdict = .insufficient
                detail = "Operator GPS path too short (\(opSpan.toIntTruncating()) m) to test following."
            } else if trail.count < 2 {
                verdict = .insufficient
                detail = "Heard, but not at two GPS points. Cannot test co-travel."
            } else if onBody && ownHere {
                verdict = .ownLikely
                detail = onBodyLine(kind, d, trail.count)
            } else if cover && ownHere && d.rssiMax >= ON_BODY_MAX {
                verdict = .ownLikely
                detail = "Heard along \(trailLen.toIntTruncating()) m of your \(opLen.toIntTruncating()) m path and still loud (\(d.rssiMax) dBm). " +
                    withYouNote(kind, d)
            } else if span < MOVE_M * 0.6 {
                verdict = .stationary
                detail = "Heard near one place (\(span.toIntTruncating()) m span) while you moved \(opSpan.toIntTruncating()) m. Looks stationary — you walked away from it."
            } else if presentAtStart && stillHere && d.rssiMax >= ON_BODY_MAX {
                verdict = .ownLikely
                detail = "Moved \(span.toIntTruncating()) m with you, already on the air when this 15-minute window opened, strong (\(d.rssi) dBm). " +
                    withYouNote(kind, d)
            } else if presentAtStart && stillHere {
                verdict = .movedWithYou
                detail = "GPS samples span \(span.toIntTruncating()) m along your path (\(trail.count) fixes). Already on the air when this window opened and still here. " +
                    withYouNote(kind, d)
            } else if !presentAtStart && span >= MOVE_M && trail.count >= 3 {
                (verdict, detail) = possibleTail(trail, span, opLen, kind, d)
            } else {
                verdict = .stationary
                detail = "Heard along \(span.toIntTruncating()) m (\(trail.count) GPS stamps) but did not stay loud on you. Neighborhood arc / pass-by, not a tail."
            }
            return FollowHit(device: d, label: label, verdict: verdict, detail: detail, spanM: span, samples: trail.count)
        }.sortedBy { $0.verdict.rawValue }
    }

    private static func onBodyLine(_ kind: TrackerMatch.Kind, _ d: Sighting, _ stamps: Int) -> String {
        let loud = "Stayed loud with you the whole sit (\(d.rssiMax) to \(d.rssiMin) dBm, \(stamps) GPS stamps). "
        return loud + withYouNote(kind, d)
    }

    /// Catalog sentence for a live decode, when the signature wrote one.
    /// A label with no sentence is named only. No fleet id is special.
    private static func liveDecodeSentence(_ device: Sighting) -> String? {
        let chips = device.liveDecode
        if chips.isEmpty { return nil }
        let notes = chips.map { $0.note.trim() }.filter { $0.isNotEmpty }.distinct()
        if notes.isNotEmpty { return notes.joined(separator: " ") }
        let labels = chips.reportLabels()
        if labels.isEmpty { return nil }
        return "Decoded: \(labels.joined(separator: ", "))."
    }

    private static func withYouNote(_ kind: TrackerMatch.Kind, _ device: Sighting) -> String {
        let decoded = liveDecodeSentence(device)
        let base: String
        switch kind {
        case .finder:
            base = "With you the whole sit — yours or planted before you started. Account for it."
        case .beacon:
            base = "Location beacons do not typically move with you. Account for it (own test tag, badge, or a short overlap with a fixture)."
        case .wearable:
            base = "Typical of a watch or ring you or a companion are wearing. Not typically a planted tracker."
        }
        if let decoded { return "\(base) \(decoded)" }
        if kind == .finder { return "\(base) Find My / iPhone addresses rotate; this MAC is this session." }
        return base
    }

    /// Extra gates on possible tail only. A neighborhood radio heard on a sidewalk
    /// arc, or that faded as you walked, is stationary — not a follower.
    /// Bag/car tags still cover most of the path and stay loud.
    private static func possibleTail(
        _ trail: [GpsSample],
        _ span: Double,
        _ opLen: Double,
        _ kind: TrackerMatch.Kind,
        _ device: Sighting
    ) -> (Verdict, String) {
        let trailLen = Geo.pathLengthM(samples: trail)
        let peak = trail.map { $0.rssi }.max()!
        let last = trail.last!.rssi
        let fade = peak - last
        let loudN = trail.count { $0.rssi >= TRAIL_LOUD_DBM }
        let loudNeed = (trail.count * 2 + 2) / 3
        let coverNeed = opLen * COVER_FRAC
        let coverPct = opLen <= 0.0 ? 0 : ((trailLen / opLen) * 100.0).toIntTruncating()
        let verdict: Verdict
        let text: String
        if fade >= FADE_DB {
            verdict = .stationary
            text = "Appeared after the sit started, but last GPS stamp was \(last) dBm after a loudest of \(peak) dBm (−\(fade) dB). Looks like you walked away from a fixture, not a tail."
        } else if loudN < loudNeed {
            verdict = .stationary
            text = "Appeared after the sit started and GPS span was \(span.toIntTruncating()) m, but only \(loudN)/\(trail.count) stamps were loud (−75 dBm+). Looks like a pass-by, not a tail."
        } else if trailLen < coverNeed {
            verdict = .stationary
            text = "Appeared after the sit started, but was only heard along \(trailLen.toIntTruncating()) m of your \(opLen.toIntTruncating()) m path (\(coverPct)%). Neighborhood arc / pass-by, not a tail."
        } else {
            let stats =
                "Appeared after the sit started, then stayed loud with you across \(span.toIntTruncating()) m " +
                "(\(trailLen.toIntTruncating()) m of your \(opLen.toIntTruncating()) m path, \(coverPct)%; " +
                "\(loudN)/\(trail.count) GPS stamps ≥ −75 dBm). "
            let note: String
            switch kind {
            case .finder:
                note = "Treat as a possible tail until you visually account for it."
            case .beacon:
                note = "Unusual for a retail/location beacon — they do not typically move with you. Account for it; not the same as a Find My tail."
            case .wearable:
                note = "Typical of a watch that joined the sit (you put it on, or someone walking with you). Not typically a planted tracker."
            }
            verdict = .following
            text = stats + note
        }
        let extra = liveDecodeSentence(device)
        return (verdict, extra == nil ? text : "\(text) \(extra!)")
    }

    private static func execSummary(
        _ wifi: [Sighting],
        _ ble: [Sighting],
        _ named: [Sighting],
        _ hidden: [Sighting],
        _ randomized: Int,
        _ pathSpan: Double,
        _ pathLen: Double,
        _ following: [FollowHit],
        _ withYou: [FollowHit],
        _ ownLikely: [FollowHit],
        _ beaconsWithYou: [FollowHit],
        _ wearablesWithYou: [FollowHit],
        _ settings: AppSettings,
        _ places: DebriefPlaces,
        _ window: DebriefWindow,
        _ mineHeard: Int = 0
    ) -> String {
        var s = ""
        let whenPhrase = window.sitName.map { "In sit \($0)" } ?? "In the last 15 minutes"
        s += "\(whenPhrase) Fieldwatch heard \(wifi.count) Wi-Fi access points and \(ble.count) BLE advertisers"
        s += " (\(named.count) signature-matched"
        if mineHeard > 0 { s += ", \(mineHeard) marked mine" }
        s += ", \(hidden.count) hidden SSIDs, \(randomized) randomized BLE). "
        if settings.tagLocation && pathLen > 0 {
            s += "Overall distance traveled: \(fmtDist(pathLen)) along the GPS path (straight-line span \(fmtDist(pathSpan))). "
        }
        if places.namesByCell.isNotEmpty {
            s += "Stops / area: \(places.areaLine()). "
        } else if places.attempted && settings.tagLocation {
            s += "\(places.note) "
        }
        let wholeSit = ownLikely + withYou
        if following.isNotEmpty || wholeSit.isNotEmpty {
            s += "TRACKING NOTE. "
            if wholeSit.isNotEmpty {
                s += "\(wholeSit.count) finder tag(s) with you the whole sit (your kit or planted before you started): "
                s += wholeSit.map { trackId($0) }.joined(separator: ", ")
                s += ". "
            }
            if following.isNotEmpty {
                s += "\(following.count) possible tail(s) first heard after this sit started: "
                s += following.map { trackId($0) }.joined(separator: ", ")
                s += ". "
            }
            s += "Account for every MAC — Fieldwatch cannot tell yours from a plant. "
        } else if !settings.tagLocation {
            s += "GPS tagging is off, so a following test was not performed. Enable “Tag detections with GPS” and walk to test. "
        } else if pathSpan < MOVE_M {
            s += "GPS displacement was only \(pathSpan.toIntTruncating()) m — too short to test whether a tracker is following. Walk farther with tagging on. "
        } else {
            s += "No finder tag clearly stayed with the GPS path in this window. "
        }
        if beaconsWithYou.isNotEmpty {
            s += "Retail beacon(s) also stayed with the path (unusual — fixtures do not typically move with you): "
            s += beaconsWithYou.map { "\($0.label) \($0.device.mac)" }.joined(separator: ", ")
            s += ". "
        }
        if wearablesWithYou.isNotEmpty {
            s += "Wearable(s) stayed with the path (usually your watch/ring or a companion): "
            s += wearablesWithYou.map { "\($0.label) \($0.device.mac)" }.joined(separator: ", ")
            s += "."
        }
        return s
    }

    private static func trackingSection(
        _ settings: AppSettings,
        _ path: [GpsSample],
        _ pathSpan: Double,
        _ pathLen: Double,
        _ following: [FollowHit],
        _ wholeSit: [FollowHit],
        _ beaconsWithYou: [FollowHit],
        _ wearablesWithYou: [FollowHit]
    ) -> String {
        var s = ""
        func line(_ x: String) { s += x + "\n" }
        if !settings.tagLocation {
            line("GPS tagging is OFF. Fieldwatch cannot test whether a radio moved with you.")
            line("Turn on Settings → Tag detections with GPS, walk or drive 50+ m, then run Debrief again.")
            return s
        }
        line("Overall distance traveled: \(fmtDist(pathLen)) along the GPS path (\(path.count) samples). Straight-line span \(fmtDist(pathSpan)).")
        line("Co-travel is split by class: finder tags (AirTag / Find My, SmartTag, Tile, Chipolo, Pebblebee, loud pocket Apple), retail beacons (iBeacon, Minew, Estimote, Kontakt.io, Atrius cart tag), and wearables (Garmin, Fitbit, Oura, Polar).")
        if path.count < 2 || pathSpan < MOVE_M {
            line("Insufficient movement to distinguish a radio that stayed with you from one you passed. Walk or drive farther and re-run.")
            return s
        }
        if following.isEmpty && wholeSit.isEmpty && beaconsWithYou.isEmpty && wearablesWithYou.isEmpty {
            line("No finder tag, retail beacon, or wearable stayed with you. House tags and other radios you only passed are not listed.")
        } else {
            line("Callouts below are only radios that stayed with the path. Radios you passed (store fixtures, house tags) are omitted.")
        }
        return s
    }

    private static func markedMineSection(
        _ devices: [Sighting],
        _ customNames: [String: String],
        _ mineKeys: Set<String>,
        _ assessed: [FollowHit]
    ) -> String? {
        let hits = devices.filter { mineKeys.contains($0.key) }
        if hits.isEmpty { return nil }
        var s = "Radios you marked mine. Heard in this window. Still listed. No beep while the mark is on.\n"
        let sorted = hits.sortedWithComparator { a, b in
            let c = compareValues(b.rssi, a.rssi)
            return c != 0 ? c : compareValues(a.mac, b.mac)
        }
        for d in sorted {
            let kind = d.kind == .wifi ? "WIFI" : "BLE"
            s += "  · \(kind)  \(d.mac)  \(d.reportName(customNames: customNames))  \(d.rssi) dBm\n"
            let verdict = assessed.firstOrNull { $0.device.key == d.key }?.verdict
            let line: String
            switch verdict {
            case .following?:
                line = "Marked mine. First heard after the sit started and stayed with the path."
            case .ownLikely?, .movedWithYou?:
                line = "Marked mine. With you the whole sit."
            default:
                line = "Marked mine."
            }
            s += "    \(line)\n"
        }
        return s.trimEnd()
    }

    private static func observerNotesSection(
        _ devices: [Sighting],
        _ customNames: [String: String],
        _ observerNotes: [String: String]
    ) -> String? {
        let hits: [(Sighting, String)] = devices.compactMap { d in
            guard let note = observerNotes[d.key]?.trim(), note.isNotEmpty else { return nil }
            return (d, note)
        }
        if hits.isEmpty { return nil }
        var s = "Your captions on radios heard in this window. Same KIND+MAC as Named radios. Not catalog Notes.\n"
        let sorted = hits.sortedWithComparator { a, b in
            let c = compareValues(b.0.rssi, a.0.rssi)
            return c != 0 ? c : compareValues(a.0.mac, b.0.mac)
        }
        for (d, note) in sorted {
            let kind = d.kind == .wifi ? "WIFI" : "BLE"
            s += "  · \(kind)  \(d.reportName(customNames: customNames))  \(d.mac)  \(d.rssi) dBm\n"
            s += "    \(note)\n"
        }
        return s.trimEnd()
    }

    private static func trackerCallout(
        _ intro: String,
        _ rows: [FollowHit],
        _ customNames: [String: String] = [:]
    ) -> String {
        var s = intro + "\n\n"
        for h in rows {
            let d = h.device
            s += "  • \(h.label)\n"
            s += "    \(d.reportName(customNames: customNames))  \(d.mac)  RSSI \(d.rssi) dBm (min \(d.rssiMin) / max \(d.rssiMax))\n"
            s += "    \(h.detail)\n"
        }
        return s.trimEnd()
    }

    private static func whereYouWere(
        _ settings: AppSettings,
        _ path: [GpsSample],
        _ pathLen: Double,
        _ pathSpan: Double,
        _ devices: [Sighting],
        _ names: [String: String],
        _ places: DebriefPlaces,
        _ now: Int,
        _ customNames: [String: String] = [:],
        _ bookmarkedKeys: Set<String> = []
    ) -> String {
        var s = ""
        func line(_ x: String = "") { s += x + "\n" }
        line("Mac GPS at hear-time, not the other radio’s location and not a camera pole. Stays are clusters within about 40 m; hops between them are transit. Coordinates are not repeated on every Wi-Fi/BLE line.")
        if !settings.tagLocation {
            line("GPS tagging is OFF. Turn on Settings → Tag detections with GPS to record where you were when radios were heard.")
            return s
        }
        if path.isEmpty {
            line("GPS tagging is on, but this window has no fixes yet.")
            return s
        }
        line("Overall: \(fmtDist(pathLen)) along-track, span \(fmtDist(pathSpan)), \(path.count) fixes.")
        if places.attempted {
            line(places.note)
            line("Street names are approximate. Do not treat a street as the location of a matched camera or tag.")
        }
        let legs = Geo.legs(samples: path, now: now)
        if legs.isEmpty {
            line("No path legs.")
            return s
        }
        let stopNames = legs.filter { $0.stay }.compactMap { places.nameNear(lat: $0.lat, lon: $0.lon) }
        if stopNames.isNotEmpty {
            line("Stops: " + stopNames.joined(separator: " → "))
        }
        for (i, leg) in legs.enumerated() {
            if leg.stay {
                line()
                line("\(i + 1). Stay  \(clock(leg.startAt))–\(clock(leg.endAt)) UTC  (\(fmtDur(leg.durationMs)))")
                line("   \(placeAndGps(leg.lat, leg.lon, places))")
                let here = devices.filter { heardAt($0, leg) }
                let aps = here.count { $0.kind == .wifi }
                let ble = here.count { $0.kind == .ble }
                let sigs = here.flatMap { d in d.fleetIds.map { names[$0] ?? $0 } }.distinct()
                s += "   Heard here: \(aps) AP(s), \(ble) BLE"
                if sigs.isNotEmpty { s += "  ·  " + sigs.take(6).joined(separator: ", ") }
                line()
                for d in here.filter({ inventoryKeep($0, settings, bookmarkedKeys) }).sortedByDescending({ $0.rssi }).take(4) {
                    line("   · \(d.reportName(customNames: customNames))  \(d.mac)  \(d.rssi) dBm")
                }
                if here.isEmpty { line("   · No GPS-stamped radios tied to this stay (tagging may have started after they were first heard).") }
            } else {
                line()
                line("\(i + 1). Transit  \(clock(leg.startAt))–\(clock(leg.endAt)) UTC  " + "\(fmtDist(leg.pathM)) along track")
                line("   \(placeAndGps(leg.lat, leg.lon, places))")
                line("   → \(placeAndGps(leg.endLat, leg.endLon, places))")
            }
        }
        let stays = legs.count { $0.stay }
        if stays == 1 && pathSpan < MOVE_M {
            line()
            line("One stay — you did not move far enough in this window to split locations.")
        }
        return s
    }

    private static func heardAt(_ device: Sighting, _ leg: Geo.PathLeg) -> Bool {
        let nearM = 60.0
        let trail = device.gpsTrail.filter { $0.at >= leg.startAt && $0.at <= leg.endAt }
        if trail.isNotEmpty {
            return trail.any { Geo.meters(lat1: $0.lat, lon1: $0.lon, lat2: leg.lat, lon2: leg.lon) <= nearM }
        }
        guard let lat = device.latitude, let lon = device.longitude else { return false }
        if device.lastSeen < leg.startAt || device.firstSeen > leg.endAt { return false }
        return Geo.meters(lat1: lat, lon1: lon, lat2: leg.lat, lon2: leg.lon) <= nearM
    }

    private static func environment(
        _ wifi: [Sighting],
        _ ble: [Sighting],
        _ randomized: Int,
        _ persistent: [Sighting],
        _ pathSpan: Double,
        _ pathLen: Double
    ) -> String {
        let ap = wifi.count
        let persistAp = persistent.count { $0.kind == .wifi }
        let guess: String
        if pathSpan > 200 && (1...25).contains(ap) {
            guess = "In motion (walk/vehicle) through mixed RF."
        } else if ap <= 4 && ble.count < 30 && persistAp >= 1 {
            guess = "Likely a dwelling or small office — few sitting APs, limited BLE."
        } else if ap >= 15 && randomized >= 40 {
            guess = "Dense public / retail / street: many APs and phone-like randomized BLE."
        } else if ap >= 8 && persistAp >= 4 {
            guess = "Likely a building with standing infrastructure APs plus patrons."
        } else {
            guess = "Mixed or under-sampled environment."
        }
        return "\(guess)  (\(ap) APs, \(ble.count) BLE, \(persistAp) persistent APs, traveled \(fmtDist(pathLen)), span \(fmtDist(pathSpan)).)"
    }

    private static func wifiLine(
        _ d: Sighting,
        _ names: [String: String],
        _ from: Int,
        _ now: Int,
        _ customNames: [String: String] = [:]
    ) -> String {
        var s = "\(d.reportName(customNames: customNames))  \(d.mac)"
        if let v = d.vendor { s += "  " + v }
        s += "  \(d.rssi) dBm"
        if d.channel != 0 { s += "  ch \(d.channel)" }
        if d.hiddenSsid { s += "  hidden" }
        if d.fleetIds.isNotEmpty { s += "  " + d.fleetIds.map { names[$0] ?? $0 }.joined(separator: "+") }
        s += "  dwell " + fmtDur(dwellMs(d, from, now))
        return s
    }

    private static func bleLine(
        _ d: Sighting,
        _ names: [String: String],
        _ from: Int,
        _ now: Int,
        _ customNames: [String: String] = [:]
    ) -> String {
        var s = "\(d.reportName(customNames: customNames))  \(d.mac)"
        if d.randomized { s += "  RAND" }
        s += "  \(d.rssi) dBm"
        if d.fleetIds.isNotEmpty { s += "  " + d.fleetIds.map { names[$0] ?? $0 }.joined(separator: "+") }
        s += "  dwell " + fmtDur(dwellMs(d, from, now))
        return s
    }

    /// Unmatched rotating BLE stays in counts/export; inventories omit it unless Extra attention, named, bookmark, or payload.
    private static func inventoryKeep(_ d: Sighting, _ settings: AppSettings, _ bookmarkedKeys: Set<String>) -> Bool {
        if settings.debriefShowUnmatchedRandomBle && settings.debriefShowAllRadios { return true }
        if d.kind != .ble { return true }
        if !d.randomized { return true }
        if d.fleetIds.isNotEmpty { return true }
        if d.payloadLat != nil && d.payloadLon != nil { return true }
        if bookmarkedKeys.contains(d.key) { return true }
        return false
    }

    private static func classChart(_ devices: [Sighting], _ fleets: [Fleet]) -> ReportChart? {
        if devices.isEmpty { return nil }
        var byId: [String: SignatureClass] = [:]
        for f in fleets { byId[f.id] = f.kind }
        var counts: [SignatureClass: Int] = [:]
        var unmatched = 0
        var multi = false
        for d in devices {
            let classes = Set(d.fleetIds.compactMap { byId[$0] })
            if classes.isEmpty {
                unmatched += 1
            } else {
                if classes.count > 1 { multi = true }
                for c in classes { counts[c, default: 0] += 1 }
            }
        }
        var rows: [ReportBar] = SignatureClass.allCases.compactMap { kind in
            guard let n = counts[kind] else { return nil }
            return ReportBar(label: kind.label(), value: n)
        }
        if unmatched > 0 { rows.append(ReportBar(label: "Unmatched", value: unmatched)) }
        if rows.isEmpty { return nil }
        return ReportChart(rows: rows, caption: multi ? "A radio in two classes counts in each." : "")
    }

    private static func signatureChart(_ named: [Sighting], _ names: [String: String]) -> ReportChart? {
        if named.isEmpty { return nil }
        var order: [String] = []
        var counts: [String: Int] = [:]
        for d in named {
            let sigs = d.fleetIds.map { names[$0] ?? $0 }.filter { $0.isNotBlank }.distinct()
            let key = sigs.isEmpty ? "Unmatched" : sigs.joined(separator: " + ")
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        let rows = order
            .sortedWithComparator { a, b in
                let c = compareValues(counts[b]!, counts[a]!)
                return c != 0 ? c : compareValues(a, b)
            }
            .map { ReportBar(label: $0, value: counts[$0]!) }
        return ReportChart(rows: rows)
    }

    private static func wifiLines(
        _ rows: [Sighting],
        _ names: [String: String],
        _ from: Int,
        _ now: Int,
        _ customNames: [String: String],
        _ fleets: [Fleet],
        _ mineKeys: Set<String>
    ) -> String {
        if rows.isEmpty { return "" }
        var s = "Named or marked:\n"
        for d in rows.sortedByDescending({ $0.rssi }) {
            s += "  · \(wifiLine(d, names, from, now, customNames))\n"
            if mineKeys.contains(d.key) { s += "    Marked mine\n" }
            for (sig, note) in d.attentionNotes(fleets: fleets) {
                s += "    extra attention (\(sig)): \(note)\n"
            }
        }
        return s.trimEnd()
    }

    private static func bleLines(
        _ rows: [Sighting],
        _ names: [String: String],
        _ from: Int,
        _ now: Int,
        _ customNames: [String: String],
        _ mineKeys: Set<String>
    ) -> String {
        if rows.isEmpty { return "" }
        var s = "Named or marked:\n"
        for d in rows.sortedByDescending({ $0.rssi }) {
            s += "  · \(bleLine(d, names, from, now, customNames))\n"
            if mineKeys.contains(d.key) { s += "    Marked mine\n" }
        }
        return s.trimEnd()
    }

    private static func gnssBody(_ marks: [GnssMark], _ start: Int, _ end: Int, onPath: Bool) -> String? {
        let rows = marks.filter { inRange($0.at, start, end) || ($0.endedAt > 0 && inRange($0.endedAt, start, end)) }
            .sortedBy { $0.at }
        if rows.isEmpty { return nil }
        var s = ""
        s += GnssCopy.INTRO + "\n"
        s += "\n"
        s += GnssCopy.ROUTER + "\n"
        if rows.any({ $0.kind == "spoofing" }) {
            s += "\n"
            s += GnssCopy.SPOOF_LIMIT + "\n"
        }
        s += "\n"
        for r in rows { s += r.reportLine() + "\n" }
        if onPath {
            s += "\n"
            s += "The path map marks where this Mac was. It does not say where the interference came from.\n"
        }
        return s.trimEnd()
    }

    private static func floodBody(_ floods: [FloodBurst], _ start: Int, _ end: Int) -> String? {
        let rows = floods.filter { inRange($0.at, start, end) }.sortedBy { $0.at }
        if rows.isEmpty { return nil }
        var s = FloodBurst.intro(floods: rows) + "\n"
        s += "\n"
        for r in rows { s += r.reportLine(clock: FloodBurst.clock(ms: r.at)) + "\n" }
        return s.trimEnd()
    }

    private static func anomalyLines(
        _ devices: [Sighting],
        _ customNames: [String: String] = [:],
        _ settings: AppSettings,
        _ bookmarkedKeys: Set<String>,
        _ showAll: Bool
    ) -> [String] {
        var out: [String] = []
        let pairing = devices.filter { d in
            d.facts.serviceData.any { $0.uuid.contains("FE2C", ignoreCase: true) && $0.dataHex.count == 6 }
        }
        if pairing.isNotEmpty {
            if showAll || pairing.count <= 8 {
                out.append("Google Fast Pair in pairing mode: " +
                    pairing.map { "\($0.reportName(customNames: customNames)) \($0.mac)" }.joined(separator: ", "))
            } else {
                out.append("Google Fast Pair in pairing mode: \(pairing.count) radios.")
            }
        }
        let loudUnknown = devices.filter {
            $0.rssi >= -50 && $0.fleetIds.isEmpty && $0.name.isBlank && inventoryKeep($0, settings, bookmarkedKeys)
        }
        if loudUnknown.isNotEmpty {
            out.append("Very strong unnamed radios (≥ −50 dBm): " +
                loudUnknown.take(8).map { "\($0.mac) \($0.rssi) dBm" }.joined(separator: ", "))
        }
        let rand = devices.count { $0.kind == .ble && $0.randomized }
        if rand >= 20 {
            out.append("High randomized BLE (\(rand)) — typical of phones, not a tracking finding.")
        }
        return out
    }

    private static func privacy(
        _ wifi: [Sighting],
        _ ble: [Sighting],
        _ randomized: Int,
        _ hidden: [Sighting],
        _ settings: AppSettings,
        _ places: DebriefPlaces,
        _ includeAircraft: Bool
    ) -> String {
        var s = ""
        s += "A passive observer with the same radios would see \(wifi.count) named/hidden APs "
        s += "and \(ble.count) BLE advertisers (\(randomized) randomized). "
        if hidden.isNotEmpty { s += "Hidden SSIDs still beacon and identify the AP by BSSID. " }
        if settings.tagLocation { s += "This debrief includes operator GPS samples used for distance and the following test. " }
        if includeAircraft {
            s += "This debrief includes advertised aircraft positions from radios that broadcast a latitude and longitude. "
        }
        if places.attempted && places.available {
            s += "Street names came from the Mac’s system geocoder while online. "
        }
        s += "Do not share this file off-device without redaction."
        return s
    }

    private static func actions(
        _ following: [FollowHit],
        _ withYou: [FollowHit],
        _ ownLikely: [FollowHit],
        _ beaconsWithYou: [FollowHit],
        _ wearablesWithYou: [FollowHit],
        _ settings: AppSettings,
        _ pathSpan: Double
    ) -> [String] {
        var out: [String] = []
        if following.isNotEmpty {
            out.append("Possible tail (appeared after this sit started): \(following.map { trackId($0) }.joined(separator: ", ")). Pause Live, open detail, note RSSI while you walk a dog-leg. Do not disable someone else’s tag.")
        }
        if ownLikely.isNotEmpty || withYou.isNotEmpty {
            out.append(
                "Possible trackers with you: \((ownLikely + withYou).map { trackId($0) }.joined(separator: ", ")). " +
                    "Could be yours or planted in the car/bag/on you before you started. Account for each MAC — do not dismiss as yours."
            )
        }
        if beaconsWithYou.isNotEmpty {
            out.append(
                "Retail beacons with you (unusual — fixtures do not typically move with you): " +
                    beaconsWithYou.map { $0.label + " " + $0.device.mac }.joined(separator: ", ") +
                    ". Account for a test tag or badge before treating it as a follower."
            )
        }
        if wearablesWithYou.isNotEmpty {
            out.append(
                "Wearables with you (usually own kit or a companion): " +
                    wearablesWithYou.map { $0.label + " " + $0.device.mac }.joined(separator: ", ") +
                    "."
            )
        }
        if !settings.tagLocation {
            out.append("Enable Tag detections with GPS and walk 50+ m, then run Debrief again for a following test.")
        } else if pathSpan < MOVE_M {
            out.append("Walk farther (50+ m) with GPS tagging on, then re-run Debrief.")
        }
        out.append("Use Live → Pause to inspect a busy list. Watch tracker signatures if this sit was noisy.")
        out.append("Station-side Wi-Fi (probes/clients) still needs a dedicated sniffer — Fieldwatch cannot see them.")
        return out
    }

    private static func takeaway(
        _ following: [FollowHit],
        _ withYou: [FollowHit],
        _ ownLikely: [FollowHit],
        _ beaconsWithYou: [FollowHit],
        _ wearablesWithYou: [FollowHit],
        _ pathSpan: Double,
        _ settings: AppSettings,
        _ named: [Sighting]
    ) -> String {
        var extra = ""
        if beaconsWithYou.isNotEmpty {
            extra += " Retail beacon(s) also with the path (unusual): "
            extra += beaconsWithYou.map { $0.label + " (" + $0.device.mac + ")" }.joined(separator: ", ")
            extra += "."
        }
        if wearablesWithYou.isNotEmpty {
            extra += " Wearable(s) with the path (usually own kit): "
            extra += wearablesWithYou.map { $0.label + " (" + $0.device.mac + ")" }.joined(separator: ", ")
            extra += "."
        }
        let core: String
        if following.isNotEmpty && (ownLikely.isNotEmpty || withYou.isNotEmpty) {
            core = "Possible tail (appeared after sit started): \(following.map { trackId($0) }.joined(separator: ", ")). " +
                "Also finder tags with you (yours or planted before): \((ownLikely + withYou).map { trackId($0) }.joined(separator: ", ")). Account for every MAC."
        } else if following.isNotEmpty {
            core = "Possible tail (appeared after this sit started): \(following.map { trackId($0) }.joined(separator: ", ")). Account for it on the person/vehicle."
        } else if !settings.tagLocation {
            core = "Turn on GPS tagging and walk before you can test whether a tracker is following you."
        } else if pathSpan < MOVE_M {
            core = "Not enough GPS movement (\(pathSpan.toIntTruncating()) m) to test following; walk and re-run Debrief."
        } else if ownLikely.isNotEmpty || withYou.isNotEmpty {
            core = "Finder tags with you (yours or planted before you started): \((ownLikely + withYou).map { trackId($0) }.joined(separator: ", ")). No new arrival this window. Account for each MAC — do not dismiss as yours."
        } else if beaconsWithYou.isNotEmpty || wearablesWithYou.isNotEmpty {
            core = "No finder tag stayed with the path."
        } else if named.isEmpty {
            core = "No signature hits and no GPS co-travel of trackers in this 15-minute window."
        } else {
            core = "No finder tag, retail beacon, or wearable clearly stayed with your GPS path in this window."
        }
        return (core + extra).trim()
    }

    /// Label and MAC, plus the live-decode name when the signature asked for one.
    private static func trackId(_ hit: FollowHit) -> String {
        let labels = hit.device.liveDecode.reportLabels()
        let id = "\(hit.label) \(hit.device.mac)"
        return labels.isEmpty ? id : "\(id) (\(labels.joined(separator: ", ")))"
    }

    private static func craftSentence(_ pictures: [AircraftTrail.Picture]) -> String {
        if pictures.isEmpty { return "" }
        let bits = pictures.take(3).map { pic in
            pic.status.isBlank ? pic.title : "\(pic.title) (\(pic.status))"
        }.joined(separator: ", ")
        let more = pictures.count > 3 ? " and \(pictures.count - 3) more" : ""
        return " Advertised position: \(bits)\(more)."
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

    private static func clock(_ ms: Int) -> String { formatMs(ms, "HH:mm", utc: true) }

    private static func fmtDist(_ m: Double) -> String {
        m >= 1000.0 ? format("%.2f km", m / 1000.0) : "\(m.toIntTruncating()) m"
    }

    private static func fmtCoord(_ s: GpsSample) -> String { format("%.5f, %.5f", s.lat, s.lon) }

    private static func placeAndGps(_ lat: Double, _ lon: Double, _ places: DebriefPlaces) -> String {
        let gps = fmtCoord(GpsSample(at: 0, lat: lat, lon: lon))
        let name = places.nameNear(lat: lat, lon: lon)
        if !name.isNullOrBlank {
            return "\(name!)  (\(gps), operator Mac)"
        } else if places.attempted {
            return "\(gps)  (operator Mac; no street name this export)"
        }
        return "\(gps)  (operator Mac)"
    }

    private static func fmtDur(_ ms: Int) -> String {
        let s = (ms / 1000).coerceAtLeast(0)
        let m = s / 60
        let r = s % 60
        if m >= 60 { return "\(m / 60)h\(m % 60)m" }
        if m > 0 { return "\(m)m\(r)s" }
        return "\(r)s"
    }
}
