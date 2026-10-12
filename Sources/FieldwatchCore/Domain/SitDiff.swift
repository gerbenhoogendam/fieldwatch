import Foundation

// Port of domain/SitDiff.kt. Kotlin key sets are LinkedHashSets; the ordered helpers below keep
// that iteration order (this sit first) so section order and Extra attention order match Android.

/// Two sit windows, keyed kind + MAC. BLE rotation is a new row.
public enum SitDiff {
    public struct Radio: Hashable, Sendable {
        public var key: String
        public var kind: RadioKind
        public var mac: String
        public var name: String
        public var extraAttention: Bool
        public var named: Bool
        public var bookmarked: Bool
        public var fleetNames: [String]
        public var fleetIds: [String]
        public var randomized: Bool
        public var lat: Double?
        public var lon: Double?
        public var observerNotes: String
        public var gpsTrail: [GpsSample]
        public var firstSeen: Int
        public var lastSeen: Int
        public var liveDecode: [LiveDecodeChip]
        public var payloadLat: Double?
        public var payloadLon: Double?
        public var payloadAlt: Double?
        public var payloadHeading: Double?
        public var payloadSpeed: Double?
        public var payloadOpLat: Double?
        public var payloadOpLon: Double?
        public var payloadUasId: String
        public var payloadTrail: [PayloadFix]
        public var payloadAircraft: String
        public var mine: Bool

        public init(
            key: String, kind: RadioKind, mac: String, name: String, extraAttention: Bool, named: Bool,
            bookmarked: Bool = false, fleetNames: [String], fleetIds: [String] = [], randomized: Bool = false,
            lat: Double? = nil, lon: Double? = nil, observerNotes: String = "", gpsTrail: [GpsSample] = [],
            firstSeen: Int = 0, lastSeen: Int = 0, liveDecode: [LiveDecodeChip] = [],
            payloadLat: Double? = nil, payloadLon: Double? = nil, payloadAlt: Double? = nil,
            payloadHeading: Double? = nil, payloadSpeed: Double? = nil, payloadOpLat: Double? = nil,
            payloadOpLon: Double? = nil, payloadUasId: String = "", payloadTrail: [PayloadFix] = [],
            payloadAircraft: String = "", mine: Bool = false
        ) {
            self.key = key; self.kind = kind; self.mac = mac; self.name = name; self.extraAttention = extraAttention
            self.named = named; self.bookmarked = bookmarked; self.fleetNames = fleetNames; self.fleetIds = fleetIds
            self.randomized = randomized; self.lat = lat; self.lon = lon; self.observerNotes = observerNotes
            self.gpsTrail = gpsTrail; self.firstSeen = firstSeen; self.lastSeen = lastSeen; self.liveDecode = liveDecode
            self.payloadLat = payloadLat; self.payloadLon = payloadLon; self.payloadAlt = payloadAlt
            self.payloadHeading = payloadHeading; self.payloadSpeed = payloadSpeed; self.payloadOpLat = payloadOpLat
            self.payloadOpLon = payloadOpLon; self.payloadUasId = payloadUasId; self.payloadTrail = payloadTrail
            self.payloadAircraft = payloadAircraft; self.mine = mine
        }
    }

    public struct Side: Hashable, Sendable {
        public var name: String
        public var ram: Bool
        public var radios: [Radio]
        public var path: [GpsSample]
        public var floods: [FloodBurst]
        public var gnss: [GnssMark]

        public init(name: String, ram: Bool, radios: [Radio], path: [GpsSample] = [], floods: [FloodBurst] = [], gnss: [GnssMark] = []) {
            self.name = name; self.ram = ram; self.radios = radios; self.path = path; self.floods = floods; self.gnss = gnss
        }

        public var keys: Set<String> { Set(radios.map { $0.key }) }

        /// Radio keys in first-seen order (Kotlin `keys` LinkedHashSet order).
        var orderedKeys: [String] { radios.map { $0.key }.distinct() }

        /// The sit file still holds these radios. Reports leave the counted addresses out.
        public func withoutFloodRadios() -> Side {
            let aside = FloodBurst.keysOf(floods: floods)
            if aside.isEmpty { return self }
            var out = self
            out.radios = radios.filter { !aside.contains($0.key) }
            return out
        }
    }

    /// Kotlin `minus` / `intersect` / `union` on LinkedHashSets, keeping the left side's order.
    static func minus(_ a: [String], _ b: [String]) -> [String] { let s = Set(b); return a.filter { !s.contains($0) } }
    static func intersect(_ a: [String], _ b: [String]) -> [String] { let s = Set(b); return a.filter { s.contains($0) } }
    static func union(_ a: [String], _ b: [String]) -> [String] { (a + b).distinct() }

    public static func secondSitChoices(closed: [SitSummary], thisSavedId: String?) -> [SitSummary] {
        closed.filter { $0.id != thisSavedId }
    }

    public static func defaultSecondSitId(closed: [SitSummary], thisSavedId: String?) -> String? {
        secondSitChoices(closed: closed, thisSavedId: thisSavedId).first?.id
    }

    public static func thisSavedId(open: SitSummary?, selectedId: String?) -> String? {
        open != nil ? nil : selectedId
    }

    public static func fromSighting(
        device: Sighting,
        fleets: [Fleet],
        customNames: [String: String],
        observerNotes: [String: String] = [:],
        bookmarkedKeys: Set<String> = [],
        mineKeys: Set<String> = []
    ) -> Radio {
        Radio(
            key: device.key,
            kind: device.kind,
            mac: device.mac,
            name: device.reportName(customNames: customNames),
            extraAttention: device.attentionNotes(fleets: fleets).isNotEmpty,
            named: customNames[device.key] != nil,
            bookmarked: bookmarkedKeys.contains(device.key),
            fleetNames: device.fleetIds.map { id in fleets.first { $0.id == id }?.name ?? id },
            fleetIds: device.fleetIds,
            randomized: device.randomized,
            lat: SitPathPlot.loudestFix(d: device)?.lat ?? device.latitude,
            lon: SitPathPlot.loudestFix(d: device)?.lon ?? device.longitude,
            observerNotes: observerNotes[device.key] ?? "",
            gpsTrail: device.gpsTrail,
            firstSeen: device.firstSeen,
            lastSeen: device.lastSeen,
            liveDecode: device.liveDecode,
            payloadLat: device.payloadLat,
            payloadLon: device.payloadLon,
            payloadAlt: device.payloadAlt,
            payloadHeading: device.payloadHeading,
            payloadSpeed: device.payloadSpeed,
            payloadOpLat: device.payloadOpLat,
            payloadOpLon: device.payloadOpLon,
            payloadUasId: device.payloadUasId?.trim() ?? "",
            payloadTrail: device.payloadTrail,
            payloadAircraft: device.payloadAircraft?.trim() ?? "",
            mine: mineKeys.contains(device.key)
        )
    }

    public static func fromSitRadio(
        row: SitRadio,
        fleets: [Fleet],
        customNames: [String: String],
        observerNotes: [String: String] = [:],
        bookmarkedKeys: Set<String> = [],
        mineKeys: Set<String> = []
    ) -> Radio {
        Radio(
            key: row.key,
            kind: row.kind,
            mac: row.mac,
            name: customNames[row.key]?.trim().nonEmpty ?? row.name.ifBlank(row.mac),
            extraAttention: row.extraAttention,
            named: customNames[row.key] != nil,
            bookmarked: bookmarkedKeys.contains(row.key),
            fleetNames: row.fleetIds.map { id in fleets.first { $0.id == id }?.name ?? id },
            fleetIds: row.fleetIds,
            randomized: row.randomized,
            lat: SitPathPlot.loudestFix(trail: row.gpsTrail)?.lat,
            lon: SitPathPlot.loudestFix(trail: row.gpsTrail)?.lon,
            observerNotes: observerNotes[row.key] ?? "",
            gpsTrail: row.gpsTrail,
            firstSeen: row.firstSeen,
            lastSeen: row.lastSeen,
            liveDecode: row.liveDecode,
            payloadLat: row.payloadLat,
            payloadLon: row.payloadLon,
            payloadAlt: row.payloadAlt,
            payloadHeading: row.payloadHeading,
            payloadSpeed: row.payloadSpeed,
            payloadOpLat: row.payloadOpLat,
            payloadOpLon: row.payloadOpLon,
            payloadUasId: row.payloadUasId?.trim() ?? "",
            payloadTrail: row.payloadTrail,
            payloadAircraft: row.payloadAircraft?.trim() ?? "",
            mine: mineKeys.contains(row.key)
        )
    }

    public static func report(
        thisSit: Side,
        second: Side,
        demoMode: Bool,
        showAllRadios: Bool = false
    ) -> String {
        let radios = thisSit.radios + second.radios
        return document(thisSit: thisSit, second: second, showAllRadios: showAllRadios)
            .withDemoMacs(macs: radios.map { $0.mac }, demo: demoMode, uasIds: radios.map { $0.payloadUasId })
            .toPlainText()
    }

    /// Same shape as Debrief so Compare (PDF) uses the Debrief letter layout.
    public static func document(
        thisSit: Side,
        second: Side,
        watchedFleetIds: Set<String> = [],
        showAllRadios: Bool = false
    ) -> DebriefDoc {
        let thisSit = thisSit.withoutFloodRadios()
        let second = second.withoutFloodRadios()
        let thisKeys = thisSit.orderedKeys
        let secondKeys = second.orderedKeys
        let byKey = (thisSit.radios + second.radios).associateBy { $0.key }
        let onlyThis = minus(thisKeys, secondKeys)
        let onlySecond = minus(secondKeys, thisKeys)
        let both = intersect(thisKeys, secondKeys)
        let ramNote: String? = (thisSit.ram || second.ram)
            ? "Last 15 minutes is the Live RAM set (about 400 radios). " +
                "A named sit keeps up to \(Sit.RADIO_CAP). Counts are not the same net."
            : nil
        let extraHits = exclusiveExtra(onlyThis, onlySecond, byKey)
        var sections: [DebriefSection] = []
        var n = 1
        func next() -> String { defer { n += 1 }; return String(n) }
        var windows = ""
        windows += sideBlock("This sit", thisSit)
        windows += sideBlock("Second sit", second)
        if let ramNote {
            windows += "\(ramNote)\n"
            windows += "\n"
        }
        windows += "Radios this Mac heard. Kind + MAC. BLE rotation is a new row. Not a radio fix."
        sections.append(DebriefSection(
            number: next(),
            title: "Windows",
            body: windows,
            chart: presenceChart(onlyThis, onlySecond, both, byKey)
        ))
        let thisCraft = AircraftTrail.pictures(sources: thisSit.radios.compactMap { toCraftSource($0) }, path: thisSit.path)
        let secondCraft = AircraftTrail.pictures(sources: second.radios.compactMap { toCraftSource($0) }, path: second.path)
        let aircraftBody = AircraftTrail.compareBody(leftName: thisSit.name, left: thisCraft, rightName: second.name, right: secondCraft)
        if aircraftBody.isNotEmpty {
            sections.append(DebriefSection(number: next(), title: "Aircraft", body: aircraftBody))
        }
        if let body = observerNotesSection(thisSit, second) {
            sections.append(DebriefSection(number: next(), title: "Observer notes", body: body))
        }
        if let body = markedMineSection(thisSit, second) {
            sections.append(DebriefSection(number: next(), title: "Marked mine", body: body))
        }
        if extraHits.isNotEmpty {
            sections.append(DebriefSection(
                number: next(),
                title: "Extra attention",
                body: extraHits.map { "\($0.radioLabel)\n\($0.note)" }.joined(separator: "\n"),
                alert: true
            ))
        }
        if let body = floodSection(thisSit, second) {
            sections.append(DebriefSection(number: next(), title: "Flood", body: body))
        }
        if let body = gnssSection(thisSit, second) {
            sections.append(DebriefSection(number: next(), title: "GNSS", body: body, alert: true))
        }
        sections.append(rosterSection(next(), "Only in this sit (\(onlyThis.count))", onlyThis, byKey, showAllRadios))
        sections.append(rosterSection(next(), "Only in second sit (\(onlySecond.count))", onlySecond, byKey, showAllRadios))
        sections.append(bothSection(next(), "In both (\(both.count))", both, thisSit, second, byKey, showAllRadios))
        var meta: [(String, String)] = []
        meta.append(("This sit", thisSit.name))
        meta.append(("Second sit", second.name))
        meta.append(("This radios", String(thisSit.radios.count)))
        meta.append(("Second radios", String(second.radios.count)))
        if ramNote != nil { meta.append(("Caps", "RAM ~400 vs sit \(Sit.RADIO_CAP)")) }
        return DebriefDoc(
            generatedUtc: "",
            windowLine: "\(thisSit.name) vs \(second.name)",
            meta: meta,
            disclaimer: FieldwatchDisclaimer.compare(),
            trackingAlert: extraHits.isNotEmpty,
            takeaway: compareTakeaway(onlyThis.count, onlySecond.count, both.count, mineCount(thisSit, second)),
            sections: sections,
            extraAttention: extraHits,
            heading: "FIELDWATCH SIT COMPARE",
            pdfKicker: "SIT COMPARE",
            pdfTitle: "Sit compare",
            pathFigure: AircraftTrail.applyWalk(
                base: AircraftTrail.applyWalk(
                    base: pathFigure(thisSit, second, watchedFleetIds),
                    pictures: thisCraft,
                    secondary: false
                ),
                pictures: secondCraft,
                secondary: true
            ),
            extraFigures: AircraftTrail.compareOwnFigures(left: thisCraft, right: secondCraft)
        )
    }

    private static func pathFigure(
        _ thisSit: Side,
        _ second: Side,
        _ watchedFleetIds: Set<String>
    ) -> SitPathPlot.Figure? {
        var tracks: [SitPathPlot.FigureTrack] = []
        let thisPath = Geo.despikePath(samples: thisSit.path)
        if thisPath.count >= 2 { tracks.append(SitPathPlot.FigureTrack(name: thisSit.name, samples: thisPath, secondary: false)) }
        let secondPath = Geo.despikePath(samples: second.path)
        if secondPath.count >= 2 { tracks.append(SitPathPlot.FigureTrack(name: second.name, samples: secondPath, secondary: true)) }
        if tracks.isEmpty { return nil }
        let thisTrack = tracks.first { !$0.secondary }
        let secondTrack = tracks.first { $0.secondary }
        var gnss: [SitPathPlot.GnssPin] = []
        if let thisTrack { gnss += SitPathPlot.gnssPins(marks: thisSit.gnss, path: thisTrack.samples) }
        if let secondTrack { gnss += SitPathPlot.gnssPins(marks: second.gnss, path: secondTrack.samples, secondary: true) }
        var pinNote = ""
        pinNote += "A MAC alert or a signature alert is drawn once. "
        pinNote += "A decoded latitude and longitude is the last advertised position. "
        pinNote += "Anything else is the strongest hear. A number is that place (Path key)."
        if gnss.isNotEmpty {
            pinNote += " A red diamond is where this Mac was during a GNSS detection. "
            if gnss.any({ $0.secondary }) {
                pinNote += "A blue diamond is the second sit. "
            }
            pinNote += "The Path key has the time and what changed. "
            pinNote += "It does not say where the interference came from."
        }
        let points: [SitPathPlot.Dot] = (thisSit.radios + second.radios)
            .filter { $0.bookmarked || $0.fleetIds.any { watchedFleetIds.contains($0) } }
            .distinctBy { $0.key }
            .compactMap { r in
                let advertised = advertisedCoord(r)
                guard let pin = advertised ?? hearCoord(r) else { return nil }
                let notes = RadioBookmarks.pathNote(bookmarked: r.bookmarked, observerNotes: r.observerNotes, mine: r.mine)
                let label = r.name.ifBlank(r.mac)
                let kept = r.payloadTrail.last { PayloadLocation.validCoord(lat: $0.lat, lon: $0.lon) }
                return SitPathPlot.Dot(
                    key: r.key,
                    lat: pin.0,
                    lon: pin.1,
                    label: label,
                    extraAttention: r.extraAttention,
                    named: r.bookmarked || r.named,
                    kind: r.kind,
                    mac: r.mac,
                    fleetNames: r.fleetNames,
                    observerNotes: notes,
                    advertised: advertised != nil,
                    advertisedNote: advertised == nil ? "" : AircraftTrail.advertisedNote(
                        status: r.liveDecode.reportLabels().joined(separator: ", "),
                        uasId: r.payloadUasId,
                        label: label,
                        lat: pin.0,
                        lon: pin.1,
                        alt: kept?.alt ?? r.payloadAlt,
                        heading: kept?.heading ?? r.payloadHeading,
                        speed: kept?.speed ?? r.payloadSpeed,
                        pilotLat: r.payloadOpLat,
                        pilotLon: r.payloadOpLon,
                        aircraft: r.payloadAircraft
                    )
                )
            }
            .sortedBy { $0.label }
            .take(48)
        let all = tracks.flatMap { $0.samples }
        let cap = tracks.count == 2
            ? "Two walks on one north-up frame. Green = this sit. Slate = second sit. \(pinNote)"
            : "North-up. Line is this Mac. \(pinNote)"
        return SitPathPlot.Figure(
            kicker: tracks.count == 2 ? "OPERATOR PATHS" : "OPERATOR PATH",
            tracks: tracks,
            dots: points,
            lengthM: Geo.pathLengthM(samples: all),
            spanM: Geo.spanM(samples: all),
            caption: cap,
            gnss: gnss
        )
    }

    private static func advertisedCoord(_ r: Radio) -> (Double, Double)? {
        if let kept = r.payloadTrail.last(where: { PayloadLocation.validCoord(lat: $0.lat, lon: $0.lon) }) {
            return (kept.lat, kept.lon)
        }
        if PayloadLocation.validCoord(lat: r.payloadLat, lon: r.payloadLon) { return (r.payloadLat!, r.payloadLon!) }
        return nil
    }

    private static func hearCoord(_ r: Radio) -> (Double, Double)? {
        guard let la = r.lat, let lo = r.lon else { return nil }
        return PayloadLocation.validCoord(lat: la, lon: lo) ? (la, lo) : nil
    }

    private static func toCraftSource(_ r: Radio) -> AircraftTrail.Source? {
        var raw = r.payloadTrail
        if raw.isEmpty {
            guard let lat = r.payloadLat, let lon = r.payloadLon else { return nil }
            raw = [PayloadFix(at: r.lastSeen, lat: lat, lon: lon, alt: r.payloadAlt, heading: r.payloadHeading, speed: r.payloadSpeed)]
        }
        let fixes = raw.filter { PayloadLocation.validCoord(lat: $0.lat, lon: $0.lon) }
        if fixes.isEmpty { return nil }
        let last = fixes.last!
        return AircraftTrail.Source(
            uasId: r.payloadUasId,
            title: r.name.ifBlank(r.mac),
            lastSeen: r.lastSeen,
            status: r.liveDecode.reportLabels().joined(separator: ", "),
            fixes: fixes,
            alt: last.alt ?? r.payloadAlt,
            heading: last.heading ?? r.payloadHeading,
            speed: last.speed ?? r.payloadSpeed,
            pilotLat: r.payloadOpLat,
            pilotLon: r.payloadOpLon,
            key: r.key,
            mac: r.mac,
            aircraft: r.payloadAircraft
        )
    }

    private static func sideBlock(_ heading: String, _ side: Side) -> String {
        let net = side.ram ? "last 15 minutes in memory (about 400 radios)" : "named window (up to \(Sit.RADIO_CAP))"
        return "\(heading): \(side.name)\n\(side.radios.count) radios · \(net)\n"
    }

    private static func exclusiveExtra(
        _ onlyThis: [String],
        _ onlySecond: [String],
        _ byKey: [String: Radio]
    ) -> [ExtraAttentionHit] {
        func hits(_ keys: [String], _ whereText: String) -> [ExtraAttentionHit] {
            keys.compactMap { key in
                guard let row = byKey[key], row.extraAttention else { return nil }
                return ExtraAttentionHit(
                    signature: row.fleetNames.first ?? "Extra attention",
                    radioLabel: line(row),
                    note: whereText
                )
            }
        }
        return hits(onlyThis, "Only in this sit.") + hits(onlySecond, "Only in second sit.")
    }

    private static func presenceChart(
        _ onlyThis: [String],
        _ onlySecond: [String],
        _ both: [String],
        _ byKey: [String: Radio]
    ) -> ReportChart {
        func row(_ label: String, _ keys: [String]) -> ReportBar {
            var wifi = 0
            var ble = 0
            for key in keys {
                guard let radio = byKey[key] else { continue }
                if radio.kind == .wifi { wifi += 1 } else { ble += 1 }
            }
            return ReportBar(label: label, value: wifi, second: ble)
        }
        return ReportChart(
            rows: [
                row("Only in this sit", onlyThis),
                row("In both", both),
                row("Only in second sit", onlySecond),
            ],
            split: true
        )
    }

    private static func rosterSection(
        _ number: String,
        _ title: String,
        _ keys: [String],
        _ byKey: [String: Radio],
        _ showAll: Bool
    ) -> DebriefSection {
        if keys.isEmpty { return DebriefSection(number: number, title: title, body: "(none)") }
        let radios = keys.compactMap { byKey[$0] }
        let shown = showAll ? keys : keys.filter { byKey[$0].map(keepShort) == true }
        return DebriefSection(
            number: number,
            title: title,
            body: "",
            chart: radioSignatureChart(radios),
            after: shown.isEmpty ? "" : listBody(shown, byKey)
        )
    }

    private static func bothSection(
        _ number: String,
        _ title: String,
        _ keys: [String],
        _ thisSit: Side,
        _ second: Side,
        _ byKey: [String: Radio],
        _ showAll: Bool
    ) -> DebriefSection {
        if keys.isEmpty { return DebriefSection(number: number, title: title, body: "(none)") }
        let earlier = thisSit.radios.associateBy { $0.key }
        let later = second.radios.associateBy { $0.key }
        let shown = showAll ? keys : keys.filter { key in
            guard let a = earlier[key], let b = later[key] else { return false }
            return keepShort(a) || keepShort(b) || decodeChanged(a, b)
        }
        return DebriefSection(
            number: number,
            title: title,
            body: "",
            chart: radioSignatureChart(keys.compactMap { byKey[$0] }),
            after: shown.isEmpty ? "" : bothBody(shown, thisSit, second)
        )
    }

    private static func radioSignatureChart(_ radios: [Radio]) -> ReportChart? {
        if radios.isEmpty { return nil }
        var counts: [String: Int] = [:]
        for radio in radios {
            let sigs = radio.fleetNames.filter { $0.isNotBlank }.distinct()
            let key = sigs.isEmpty ? "Unmatched" : sigs.joined(separator: " + ")
            counts[key, default: 0] += 1
        }
        let rows = counts.map { ($0.key, $0.value) }
            .sortedWithComparator { a, b in
                let c = compareValues(b.1, a.1)
                return c != 0 ? c : compareValues(a.0, b.0)
            }
            .map { ReportBar(label: $0.0, value: $0.1) }
        return ReportChart(rows: rows)
    }

    private static func keepShort(_ r: Radio) -> Bool {
        r.extraAttention || r.named || r.mine || r.bookmarked
    }

    private static func decodeChanged(_ earlier: Radio, _ later: Radio) -> Bool {
        let left = earlier.liveDecode.reportLabels()
        let right = later.liveDecode.reportLabels()
        return left.isNotEmpty && right.isNotEmpty && left != right
    }

    /// extraAttention desc, named desc, kind name, MAC.
    private static func rowOrder(_ a: Radio, _ b: Radio) -> Int {
        var c = compareValues(b.extraAttention ? 1 : 0, a.extraAttention ? 1 : 0)
        if c != 0 { return c }
        c = compareValues(b.named ? 1 : 0, a.named ? 1 : 0)
        if c != 0 { return c }
        c = compareValues(a.kind.rawValue, b.kind.rawValue)
        if c != 0 { return c }
        return compareValues(a.mac, b.mac)
    }

    private static func listBody(_ keys: [String], _ byKey: [String: Radio]) -> String {
        if keys.isEmpty { return "(none)" }
        return keys.compactMap { byKey[$0] }
            .sortedWithComparator(rowOrder)
            .map { line($0) }
            .joined(separator: "\n")
    }

    /// Kind + MAC is the same radio. A live label can still change between windows.
    private static func bothBody(_ keys: [String], _ thisSit: Side, _ second: Side) -> String {
        if keys.isEmpty { return "(none)" }
        let earlier = thisSit.radios.associateBy { $0.key }
        let later = second.radios.associateBy { $0.key }
        return keys.compactMap { key -> (Radio, Radio)? in
            guard let a = earlier[key], let b = later[key] else { return nil }
            return (a, b)
        }
        .sortedWithComparator { x, y in rowOrder(x.1, y.1) }
        .map { bothLine($0.0, $0.1) }
        .joined(separator: "\n")
    }

    private static func bothLine(_ earlier: Radio, _ later: Radio) -> String {
        var s = line(later, chips: false)
        let left = earlier.liveDecode.reportLabels()
        let right = later.liveDecode.reportLabels()
        if left.isNotEmpty && right.isNotEmpty && left != right {
            s += "  decoded value changed: "
            s += left.joined(separator: ", ")
            s += " → "
            s += right.joined(separator: ", ")
        } else {
            s += chipSuffix(right.isNotEmpty ? later.liveDecode : earlier.liveDecode)
        }
        return s
    }

    private static func line(_ row: Radio, chips: Bool = true) -> String {
        var s = row.kind == .wifi ? "WIFI" : "BLE "
        s += "  "
        s += row.mac
        let label = row.name.trim()
        if label.isNotEmpty && !label.equals(row.mac, ignoreCase: true) {
            s += "  "
            s += label
        }
        if row.mine { s += "  Marked mine" }
        for name in row.fleetNames where name.isNotBlank {
            s += "  "
            s += name
        }
        if row.extraAttention { s += "  Extra attention" }
        if chips { s += chipSuffix(row.liveDecode) }
        return s
    }

    private static func chipSuffix(_ chips: [LiveDecodeChip]) -> String {
        let labels = chips.reportLabels()
        let notes = chips.map { $0.note.trim() }.filter { $0.isNotEmpty }.distinct()
        if labels.isEmpty && notes.isEmpty { return "" }
        var s = ""
        if labels.isNotEmpty {
            s += "  "
            s += labels.joined(separator: ", ")
        }
        if notes.isNotEmpty {
            s += "  "
            s += notes.joined(separator: " ")
        }
        return s
    }

    private static func mineCount(_ thisSit: Side, _ second: Side) -> Int {
        (thisSit.radios + second.radios).distinctBy { $0.key }.count { $0.mine }
    }

    private static func compareTakeaway(_ onlyThis: Int, _ onlySecond: Int, _ both: Int, _ mine: Int) -> String {
        let counts = "\(onlyThis) only in this sit · \(onlySecond) only in the second · \(both) in both."
        return mine > 0 ? "\(counts) · \(mine) marked mine." : counts
    }

    private static func gnssSection(_ thisSit: Side, _ second: Side) -> String? {
        if thisSit.gnss.isEmpty && second.gnss.isEmpty { return nil }
        var s = ""
        s += "\(GnssCopy.INTRO)\n"
        s += "\(GnssCopy.ROUTER)\n"
        s += "\n"
        func side(_ name: String, _ marks: [GnssMark]) {
            if marks.isEmpty { return }
            s += "\(name)\n"
            for m in marks.sortedBy({ $0.at }) { s += "  \(m.reportLine())\n" }
        }
        side(thisSit.name, thisSit.gnss)
        if thisSit.gnss.isNotEmpty && second.gnss.isNotEmpty { s += "\n" }
        side(second.name, second.gnss)
        let onPath = SitPathPlot.gnssPins(marks: thisSit.gnss, path: thisSit.path).isNotEmpty ||
            SitPathPlot.gnssPins(marks: second.gnss, path: second.path).isNotEmpty
        if onPath {
            s += "\n"
            s += "The path map marks where this Mac was. It does not say where the interference came from.\n"
        }
        return s.trimEnd()
    }

    private static func floodSection(_ thisSit: Side, _ second: Side) -> String? {
        if thisSit.floods.isEmpty && second.floods.isEmpty { return nil }
        var s = ""
        func linesFor(_ side: Side) {
            if side.floods.isEmpty { return }
            s += "\(side.name)\n"
            for burst in side.floods.sortedBy({ $0.at }) {
                s += "  \(burst.reportLine(clock: FloodBurst.clock(ms: burst.at)))\n"
            }
        }
        s += "\(FloodBurst.intro(floods: thisSit.floods + second.floods))\n"
        s += "\n"
        linesFor(thisSit)
        if thisSit.floods.isNotEmpty && second.floods.isNotEmpty { s += "\n" }
        linesFor(second)
        return s.trimEnd()
    }

    private static func whereLabel(_ key: String, _ thisSit: Side, _ second: Side) -> String {
        let inThis = thisSit.radios.any { $0.key == key }
        let inSecond = second.radios.any { $0.key == key }
        if inThis && inSecond { return "both" }
        if inThis { return "this sit" }
        return "second sit"
    }

    private static func markedMineSection(_ thisSit: Side, _ second: Side) -> String? {
        let rows = (thisSit.radios + second.radios).distinctBy { $0.key }.filter { $0.mine }
        if rows.isEmpty { return nil }
        var s = "Radios you marked mine. Heard in either window. Still listed.\n"
        let sorted = rows.sortedWithComparator { a, b in
            let c = compareValues(whereLabel(a.key, thisSit, second), whereLabel(b.key, thisSit, second))
            return c != 0 ? c : compareValues(a.mac, b.mac)
        }
        for r in sorted {
            let kind = r.kind == .wifi ? "WIFI" : "BLE"
            let label = r.name.trim()
            s += "  · \(kind)  \(r.mac)"
            if label.isNotEmpty && !label.equals(r.mac, ignoreCase: true) { s += "  \(label)" }
            s += "  \(whereLabel(r.key, thisSit, second))"
            s += "\n"
        }
        return s.trimEnd()
    }

    private static func observerNotesSection(_ thisSit: Side, _ second: Side) -> String? {
        let rows: [(Radio, String)] = (thisSit.radios + second.radios)
            .distinctBy { $0.key }
            .compactMap { r in
                guard let note = r.observerNotes.trim().nonEmpty else { return nil }
                return (r, note)
            }
        if rows.isEmpty { return nil }
        var s = "Your captions on radios heard in either window. Same KIND+MAC as Named radios. Not catalog Notes.\n"
        let sorted = rows.sortedWithComparator { a, b in
            let c = compareValues(whereLabel(a.0.key, thisSit, second), whereLabel(b.0.key, thisSit, second))
            return c != 0 ? c : compareValues(a.0.mac, b.0.mac)
        }
        for (r, note) in sorted {
            let kind = r.kind == .wifi ? "WIFI" : "BLE"
            let label = r.name.trim()
            s += "  · \(kind)  \(r.mac)"
            if label.isNotEmpty && !label.equals(r.mac, ignoreCase: true) { s += "  \(label)" }
            s += "  \(whereLabel(r.key, thisSit, second))"
            s += "\n"
            s += "    \(note)\n"
        }
        return s.trimEnd()
    }
}
