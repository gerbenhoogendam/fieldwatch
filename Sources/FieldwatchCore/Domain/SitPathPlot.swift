import Foundation

// Port of domain/SitPathPlot.kt. Kotlin Float screen math is Double here.

private func toRadians(_ deg: Double) -> Double { deg * 0.017453292519943295 }

/// North-up path of this Mac. Alert dots are hear-points, unless the radio advertised a position.
public enum SitPathPlot {
    /// Shortest half-width of the walk plot, in meters. A sit that barely moved
    /// still shows the surrounding streets. A longer walk is unchanged.
    public static let MIN_HALF_SPAN_M = 180.0

    public struct Dot: Hashable, Sendable {
        public var key: String
        public var lat: Double
        public var lon: Double
        public var label: String
        public var extraAttention: Bool
        public var named: Bool
        public var kind: RadioKind
        public var mac: String
        public var fleetNames: [String]
        public var observerNotes: String
        public var rssiMin: Int
        public var rssiMax: Int
        /// First matched signature class, for the path icon. Nil when the radio has no signature.
        public var classKind: SignatureClass?
        /// Palette color of that signature. 0 when there is no signature.
        public var accentArgb: Int
        /// On-screen Path. `lat`/`lon` is the last advertised fix, not this Mac's hear.
        /// The aircraft marker is the tap target. No second class icon on that point.
        public var advertised: Bool
        /// Letter Path key. Live status, UAS id, last position, motion, and pilot
        /// when this radio advertised them. Empty for a hear-point.
        public var advertisedNote: String

        public init(
            key: String, lat: Double, lon: Double, label: String, extraAttention: Bool, named: Bool,
            kind: RadioKind = .wifi, mac: String = "", fleetNames: [String] = [], observerNotes: String = "",
            rssiMin: Int = 0, rssiMax: Int = 0, classKind: SignatureClass? = nil, accentArgb: Int = 0,
            advertised: Bool = false, advertisedNote: String = ""
        ) {
            self.key = key; self.lat = lat; self.lon = lon; self.label = label
            self.extraAttention = extraAttention; self.named = named; self.kind = kind; self.mac = mac
            self.fleetNames = fleetNames; self.observerNotes = observerNotes; self.rssiMin = rssiMin
            self.rssiMax = rssiMax; self.classKind = classKind; self.accentArgb = accentArgb
            self.advertised = advertised; self.advertisedNote = advertisedNote
        }
    }

    public struct Model: Hashable, Sendable {
        public var samples: [GpsSample]
        public var dots: [Dot]
        public var lengthM: Double
        public var spanM: Double
        public var title: String
        public var emptyHint: String?
        public var live: Bool
        /// Extra points that must stay inside the frame, without the walking speed filter.
        public var frameSamples: [GpsSample]
        /// When the track is a single advertised fix, give the marker some ground around it.
        public var minHalfSpanM: Double
        /// Advertised tracks drawn on this plot. They are not part of `samples`.
        public var craft: [FigureTrack]
        /// Pilot pins already limited to tracks within range.
        public var pilots: [Mark]
        /// Farther aircraft, each its own north-up plot.
        public var aircraftCards: [Model]
        /// Advertised positions with no UAS id that do not get a map.
        public var looseAdvertised: Int
        public var caption: String
        /// GNSS detections placed on this Mac's line. Not drawn on an aircraft card.
        public var gnss: [GnssPin]

        public init(
            samples: [GpsSample], dots: [Dot], lengthM: Double, spanM: Double, title: String,
            emptyHint: String? = nil, live: Bool = false, frameSamples: [GpsSample] = [],
            minHalfSpanM: Double = 0.0, craft: [FigureTrack] = [], pilots: [Mark] = [],
            aircraftCards: [Model] = [], looseAdvertised: Int = 0, caption: String = "", gnss: [GnssPin] = []
        ) {
            self.samples = samples; self.dots = dots; self.lengthM = lengthM; self.spanM = spanM
            self.title = title; self.emptyHint = emptyHint; self.live = live; self.frameSamples = frameSamples
            self.minHalfSpanM = minHalfSpanM; self.craft = craft; self.pilots = pilots
            self.aircraftCards = aircraftCards; self.looseAdvertised = looseAdvertised; self.caption = caption
            self.gnss = gnss
        }
    }

    public struct Pt: Hashable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public struct Layout {
        public var path: [Pt]
        public var dots: [(Dot, Pt)]
        public var scaleBarM: Double
        public var scaleBarFrac: Double
        public var project: (Double, Double) -> Pt
        public var plotLeft: Double
        public var plotTop: Double
        public var plotRight: Double
        public var plotBottom: Double
        public var samples: [GpsSample]

        public init(
            path: [Pt], dots: [(Dot, Pt)], scaleBarM: Double, scaleBarFrac: Double,
            project: @escaping (Double, Double) -> Pt = { _, _ in Pt(x: 0, y: 0) },
            plotLeft: Double = 0, plotTop: Double = 0, plotRight: Double = 0, plotBottom: Double = 0,
            samples: [GpsSample] = []
        ) {
            self.path = path; self.dots = dots; self.scaleBarM = scaleBarM; self.scaleBarFrac = scaleBarFrac
            self.project = project; self.plotLeft = plotLeft; self.plotTop = plotTop
            self.plotRight = plotRight; self.plotBottom = plotBottom; self.samples = samples
        }
    }

    public struct Mark: Hashable, Sendable {
        public var lat: Double
        public var lon: Double
        public var label: String
        public init(lat: Double, lon: Double, label: String) { self.lat = lat; self.lon = lon; self.label = label }
    }

    /// Where this Mac was when a GNSS detection started.
    /// The spot is the path sample nearest in time. It is not the source of the interference.
    public struct GnssPin: Hashable, Sendable {
        public var at: Int
        public var endedAt: Int
        public var kind: String
        public var confidence: String
        public var detail: String
        public var lat: Double
        public var lon: Double
        public var secondary: Bool

        public init(at: Int, endedAt: Int = 0, kind: String, confidence: String, detail: String, lat: Double, lon: Double, secondary: Bool = false) {
            self.at = at; self.endedAt = endedAt; self.kind = kind; self.confidence = confidence
            self.detail = detail; self.lat = lat; self.lon = lon; self.secondary = secondary
        }

        public func title() -> String {
            switch kind {
            case "spoofing": return "Possible GNSS spoofing"
            case "mock": return "Mock location app"
            default: return "Possible GNSS interference"
            }
        }

        /// Local clock, same as the times drawn on the path.
        public func whenLine() -> String {
            let start = GnssCopy.localHm(ms: at)
            return endedAt > at ? "\(start)–\(GnssCopy.localHm(ms: endedAt))" : start
        }

        public func keyLine() -> String {
            let sit = secondary ? "Second sit. " : ""
            let what = detail.trim().ifBlank("Signal changed.")
            return "\(sit)\(title()) · \(confidence) · \(whenLine()). \(what)"
        }
    }

    /// One pin per mark, on the path sample closest in time to the start.
    /// An empty path leaves the mark in the report text only.
    public static func gnssPins(marks: [GnssMark], path: [GpsSample], secondary: Bool = false) -> [GnssPin] {
        if marks.isEmpty || path.isEmpty { return [] }
        return marks.sortedBy { $0.at }.map { mark in
            let sample = path.minByOrNull { abs($0.at - mark.at) }!
            return GnssPin(
                at: mark.at,
                endedAt: mark.endedAt,
                kind: mark.kind,
                confidence: mark.confidence,
                detail: mark.detail,
                lat: sample.lat,
                lon: sample.lon,
                secondary: secondary
            )
        }
    }

    public struct FigureTrack: Hashable, Sendable {
        public var name: String
        public var samples: [GpsSample]
        public var secondary: Bool
        /// Advertised latitude/longitude. Drawn apart from the Mac's path.
        public var aircraft: Bool
        /// Last advertised course, degrees clockwise from north. Nil draws a diamond.
        public var headingDeg: Double?

        public init(name: String, samples: [GpsSample], secondary: Bool = false, aircraft: Bool = false, headingDeg: Double? = nil) {
            self.name = name; self.samples = samples; self.secondary = secondary; self.aircraft = aircraft
            self.headingDeg = headingDeg
        }
    }

    public struct Figure: Hashable, Sendable {
        public var kicker: String
        public var tracks: [FigureTrack]
        public var dots: [Dot]
        public var lengthM: Double
        public var spanM: Double
        public var caption: String
        public var pilots: [Mark]
        /// Advertised aircraft drawn on this figure as a class icon, not a numbered alert.
        /// One line each, same order as the tracks.
        public var craftKeys: [String]
        /// GNSS detections on this Mac's line. Empty on an aircraft figure.
        public var gnss: [GnssPin]

        public init(
            kicker: String, tracks: [FigureTrack], dots: [Dot], lengthM: Double, spanM: Double, caption: String,
            pilots: [Mark] = [], craftKeys: [String] = [], gnss: [GnssPin] = []
        ) {
            self.kicker = kicker; self.tracks = tracks; self.dots = dots; self.lengthM = lengthM
            self.spanM = spanM; self.caption = caption; self.pilots = pilots; self.craftKeys = craftKeys
            self.gnss = gnss
        }

        public var drawable: Bool {
            tracks.any { $0.samples.count >= 2 || ($0.aircraft && $0.samples.isNotEmpty) }
        }
    }

    public struct Cluster: Hashable, Sendable {
        public var id: String
        public var center: Pt
        public var members: [Member]
        public init(id: String, center: Pt, members: [Member]) { self.id = id; self.center = center; self.members = members }
        public var stacked: Bool { members.count > 1 }
    }

    public struct Member: Hashable, Sendable {
        public var number: Int
        public var dot: Dot
        public var at: Pt
        public init(number: Int, dot: Dot, at: Pt) { self.number = number; self.dot = dot; self.at = at }
    }

    /// `numberOf` nil = 1-based index of the first dot with the same key (Kotlin default).
    public static func clusters(
        dots: [(Dot, Pt)],
        threshPx: Double = 28,
        numberOf: ((Dot) -> Int)? = nil
    ) -> [Cluster] {
        let numberOf: (Dot) -> Int = numberOf ?? { dot in
            let i = dots.indexOfFirst { $0.0.key == dot.key }
            return i < 0 ? 1 : i + 1
        }
        var used = [Bool](repeating: false, count: dots.count)
        var out: [Cluster] = []
        for i in 0..<dots.count {
            if used[i] { continue }
            var idx: [Int] = []
            var q: [Int] = [i]
            var head = 0
            used[i] = true
            while head < q.count {
                let j = q[head]
                head += 1
                idx.append(j)
                for k in 0..<dots.count {
                    if used[k] { continue }
                    let dx = dots[j].1.x - dots[k].1.x
                    let dy = dots[j].1.y - dots[k].1.y
                    if dx * dx + dy * dy <= threshPx * threshPx {
                        used[k] = true
                        q.append(k)
                    }
                }
            }
            let members = idx.sorted().map { m -> Member in
                let pair = dots[m]
                return Member(number: numberOf(pair.0), dot: pair.0, at: pair.1)
            }
            let cx = members.map { $0.at.x }.average()
            let cy = members.map { $0.at.y }.average()
            let id = members.map { $0.dot.key }.sorted().joined(separator: "|")
            out.append(Cluster(id: id, center: Pt(x: cx, y: cy), members: members))
        }
        return out
    }

    /// Start or end mark. A tap on the dot or its label belongs to a detection it covers.
    public struct HitMarker: Hashable, Sendable {
        public var x: Double
        public var y: Double
        public var radius: Double
        public var labelLeft: Double
        public var labelTop: Double
        public var labelRight: Double
        public var labelBottom: Double

        public init(x: Double, y: Double, radius: Double, labelLeft: Double, labelTop: Double, labelRight: Double, labelBottom: Double) {
            self.x = x; self.y = y; self.radius = radius; self.labelLeft = labelLeft; self.labelTop = labelTop
            self.labelRight = labelRight; self.labelBottom = labelBottom
        }

        public func contains(px: Double, py: Double, pad: Double = 0) -> Bool {
            if hypot(px - x, py - y) <= radius + pad { return true }
            return px >= labelLeft - pad && px <= labelRight + pad &&
                py >= labelTop - pad && py <= labelBottom + pad
        }

        public func overlaps(cluster: Cluster, visual: Double) -> Bool {
            if hypot(cluster.center.x - x, cluster.center.y - y) <= radius + visual { return true }
            let nearestX = cluster.center.x.coerceIn(labelLeft, labelRight)
            let nearestY = cluster.center.y.coerceIn(labelTop, labelBottom)
            return hypot(cluster.center.x - nearestX, cluster.center.y - nearestY) <= visual
        }
    }

    public static func clusterVisualRadius(cluster: Cluster) -> Double { cluster.stacked ? 20 : 16 }

    /// Detection under a tap. The start and end marks are included, so the part of an
    /// icon they cover still opens that detection.
    public static func clusterAt(
        clusters: [Cluster],
        x: Double,
        y: Double,
        markers: [HitMarker] = [],
        slopPx: Double = 40
    ) -> Cluster? {
        func dist(_ c: Cluster) -> Double { hypot(c.center.x - x, c.center.y - y) }
        let direct = clusters.filter { dist($0) <= slopPx }
        let marked = markers.flatMap { marker -> [Cluster] in
            if !marker.contains(px: x, py: y) { return [] }
            return clusters.filter { marker.overlaps(cluster: $0, visual: clusterVisualRadius(cluster: $0)) }
        }
        return (direct + marked).distinctBy { $0.id }.minByOrNull { dist($0) }
    }

    public static func layout(
        model: Model,
        width: Double,
        height: Double,
        pad: Double = 16,
        scaleBarReserve: Double = 44
    ) -> Layout? {
        if width <= pad * 2 || height <= pad * 2 + scaleBarReserve { return nil }
        let cleaned = Geo.despikePath(samples: model.samples)
        let phone = cleaned.count >= 2 ? cleaned : model.samples
        let pts = phone + model.frameSamples
        if pts.isEmpty { return nil }
        let lat0 = pts.map { $0.lat }.average()
        let lon0 = pts.map { $0.lon }.average()
        let cos0 = cos(toRadians(lat0)).coerceAtLeast(0.2)
        func mx(_ lat: Double, _ lon: Double) -> Double { (lon - lon0) * 111_320.0 * cos0 }
        func my(_ lat: Double, _ lon: Double) -> Double { (lat - lat0) * 110_540.0 }
        let raw = pts.map { (mx($0.lat, $0.lon), my($0.lat, $0.lon)) }
        var minX = raw.map { $0.0 }.min()!
        var maxX = raw.map { $0.0 }.max()!
        var minY = raw.map { $0.1 }.min()!
        var maxY = raw.map { $0.1 }.max()!
        for d in model.dots {
            let x = mx(d.lat, d.lon)
            let y = my(d.lat, d.lon)
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        do {
            let midX = (minX + maxX) / 2
            let midY = (minY + maxY) / 2
            let floor = model.minHalfSpanM > 0 ? model.minHalfSpanM : MIN_HALF_SPAN_M
            let hx = ((maxX - minX) / 2).coerceAtLeast(floor) * 1.22
            let hy = ((maxY - minY) / 2).coerceAtLeast(floor) * 1.22
            minX = midX - hx
            maxX = midX + hx
            minY = midY - hy
            maxY = midY + hy
        }
        let spanX = (maxX - minX).coerceAtLeast(8)
        let spanY = (maxY - minY).coerceAtLeast(8)
        let innerW = width - pad * 2
        let innerH = height - pad * 2 - scaleBarReserve
        let scale = min(innerW / spanX, innerH / spanY)
        let usedW = spanX * scale
        let usedH = spanY * scale
        let ox = pad + (innerW - usedW) / 2
        let oy = pad + (innerH - usedH) / 2
        let fMinX = minX, fMaxY = maxY
        func map(_ mxv: Double, _ myv: Double) -> Pt {
            Pt(x: ox + (mxv - fMinX) * scale, y: oy + (fMaxY - myv) * scale)
        }
        let path = phone.map { map(mx($0.lat, $0.lon), my($0.lat, $0.lon)) }
        let dots = model.dots.map { ($0, map(mx($0.lat, $0.lon), my($0.lat, $0.lon))) }
        let barM = niceMeters(raw: spanX / scale * 0.28)
        let barFrac = ((barM * scale) / innerW).coerceIn(0.08, 0.45)
        return Layout(
            path: path,
            dots: dots,
            scaleBarM: barM,
            scaleBarFrac: barFrac,
            project: { lat, lon in map(mx(lat, lon), my(lat, lon)) },
            plotLeft: pad,
            plotTop: pad,
            plotRight: width - pad,
            plotBottom: height - pad - scaleBarReserve,
            samples: phone
        )
    }

    public static func niceMeters(raw: Double) -> Double {
        let v = raw.coerceAtLeast(5.0)
        let mag = pow(10.0, Foundation.floor(log(v) / log(10.0)))
        let n = v / mag
        let nice: Double
        if n < 1.5 { nice = 1.0 } else if n < 3.5 { nice = 2.0 } else if n < 7.5 { nice = 5.0 } else { nice = 10.0 }
        return nice * mag
    }

    public struct PlotRadios: Hashable, Sendable {
        public var points: [Dot]
        public init(points: [Dot]) { self.points = points }
    }

    public static func dotsFrom(
        devices: [Sighting],
        fleets: [Fleet],
        namedKeys: Set<String>,
        cap: Int = 48,
        customNames: [String: String] = [:],
        observerNotes: [String: String] = [:],
        bookmarkedKeys: Set<String> = [],
        /// Signatures with Alert on. Used when `alertsOnly` is set.
        watchedFleetIds: Set<String> = [],
        /// Reports → Path and the letter-size path figure.
        /// MAC alerts and signature alerts. A decoded position uses the last advertised fix.
        alertsOnly: Bool = false,
        mineKeys: Set<String> = []
    ) -> PlotRadios {
        var points: [Dot] = []
        let groups = devices
            .filter { device in
                let macAlert = bookmarkedKeys.contains(device.key)
                let signatureAlert = device.fleetIds.any { watchedFleetIds.contains($0) }
                return alertsOnly ? (macAlert || signatureAlert) : (macAlert || device.attentionNotes(fleets: fleets).isNotEmpty)
            }
            .groupByOrdered { $0.key }
        for (_, group) in groups {
            let d = group.maxByOrNull { $0.rssi }!
            let pin = alertsOnly ? advertisedFix(d: d) : nil
            guard let fix = pin ?? loudestFix(d: d) else { continue }
            let bookmarked = bookmarkedKeys.contains(d.key)
            let notes = RadioBookmarks.pathNote(
                bookmarked: bookmarked,
                observerNotes: observerNotes[d.key] ?? "",
                mine: mineKeys.contains(d.key)
            )
            let fleet = d.fleetIds.lazy.compactMap { id in fleets.first { $0.id == id && watchedFleetIds.contains(id) } }.first
                ?? d.fleetIds.lazy.compactMap { id in fleets.first { $0.id == id } }.first
            var advertisedNote = ""
            if pin != nil {
                let kept = d.payloadTrail.last { PayloadLocation.validCoord(lat: $0.lat, lon: $0.lon) }
                advertisedNote = AircraftTrail.advertisedNote(
                    status: d.liveDecode.reportLabels().joined(separator: ", "),
                    uasId: d.payloadUasId?.trim() ?? "",
                    label: d.reportName(customNames: customNames),
                    lat: fix.lat,
                    lon: fix.lon,
                    alt: kept?.alt ?? d.payloadAlt,
                    heading: kept?.heading ?? d.payloadHeading,
                    speed: kept?.speed ?? d.payloadSpeed,
                    pilotLat: d.payloadOpLat,
                    pilotLon: d.payloadOpLon,
                    aircraft: d.payloadAircraft?.trim() ?? ""
                )
            }
            points.append(Dot(
                key: d.key,
                lat: fix.lat,
                lon: fix.lon,
                label: d.reportName(customNames: customNames).ifBlank(d.mac),
                extraAttention: d.attentionNotes(fleets: fleets).isNotEmpty,
                named: bookmarked || namedKeys.contains(d.key),
                kind: d.kind,
                mac: d.mac,
                fleetNames: d.fleetIds.compactMap { id in fleets.first { $0.id == id }?.name },
                observerNotes: notes,
                rssiMin: d.rssiMin,
                rssiMax: d.rssiMax,
                classKind: fleet?.kind,
                accentArgb: fleet.map { Palette.color(index: $0.colorIndex) } ?? 0,
                advertised: pin != nil,
                advertisedNote: advertisedNote
            ))
        }
        let sorted: [Dot]
        if alertsOnly {
            sorted = points.sortedBy { $0.label }
        } else {
            sorted = points.sortedWithComparator { a, b in
                let c = compareValues(b.extraAttention ? 1 : 0, a.extraAttention ? 1 : 0)
                return c != 0 ? c : compareValues(a.label, b.label)
            }
        }
        return PlotRadios(points: sorted.take(cap))
    }

    /// Last advertised fix the sit kept. Empty trail uses the current payload pin
    /// (last 15 minutes, or a sit from before the trail). Pilot coordinates are not a pin.
    public static func advertisedFix(d: Sighting) -> GpsSample? {
        if let kept = d.payloadTrail.last(where: { PayloadLocation.validCoord(lat: $0.lat, lon: $0.lon) }) {
            return GpsSample(at: kept.at, lat: kept.lat, lon: kept.lon, rssi: 0)
        }
        guard let lat = d.payloadLat, let lon = d.payloadLon else { return nil }
        if !PayloadLocation.validCoord(lat: lat, lon: lon) { return nil }
        return GpsSample(at: d.lastSeen, lat: lat, lon: lon, rssi: 0)
    }

    /// True when `dot` is the end marker of an advertised track on this plot.
    public static func sitsOnCraft(dot: Dot, craft: [FigureTrack], meters: Double = 30.0) -> Bool {
        if !dot.advertised { return false }
        return craft.any { track in
            guard let end = track.samples.last else { return false }
            return Geo.meters(lat1: end.lat, lon1: end.lon, lat2: dot.lat, lon2: dot.lon) <= meters
        }
    }

    /// One hear-point per radio: loudest GPS-trail sample. rssi 0 is treated as unset.
    public static func loudestFix(trail: [GpsSample]) -> GpsSample? {
        guard var best = trail.first else { return nil }
        func key(_ s: GpsSample) -> Int { (s.rssi == 0 || !Rssi.measured(rssi: s.rssi)) ? Int.min : s.rssi }
        for s in trail.dropFirst() {
            let c = compareValues(key(best), key(s))
            if c < 0 || (c == 0 && best.at < s.at) { best = s }
        }
        return best
    }

    public static func loudestFix(d: Sighting) -> GpsSample? {
        if let f = loudestFix(trail: d.gpsTrail) { return f }
        guard let lat = d.latitude, let lon = d.longitude else { return nil }
        return GpsSample(at: d.lastSeen, lat: lat, lon: lon, rssi: d.rssi)
    }
}
