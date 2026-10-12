import Foundation

// Port of domain/AircraftTrail.kt.

/// One advertised position stored on a sit. Not the Mac's GPS.
public struct PayloadFix: Codable, Hashable, Sendable {
    public var at: Int
    public var lat: Double
    public var lon: Double
    public var alt: Double?
    public var heading: Double?
    public var speed: Double?

    public init(at: Int, lat: Double, lon: Double, alt: Double? = nil, heading: Double? = nil, speed: Double? = nil) {
        self.at = at; self.lat = lat; self.lon = lon; self.alt = alt; self.heading = heading; self.speed = speed
    }

    enum CodingKeys: String, CodingKey { case at, lat, lon, alt, heading, speed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decode(Int.self, forKey: .at)
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        alt = try c.opt(.alt)
        heading = try c.opt(.heading)
        speed = try c.opt(.speed)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(at, forKey: .at)
        try c.encode(lat, forKey: .lat)
        try c.encode(lon, forKey: .lon)
        try c.encode(alt, forKey: .alt)
        try c.encode(heading, forKey: .heading)
        try c.encode(speed, forKey: .speed)
    }
}

/// Advertised fixes for a sit report. Any radio that already carries a payload
/// latitude and longitude can grow a trail. Remote ID is the stock source.
/// The Mac's walking speed filter is not applied here.
public enum AircraftTrail {
    public static let CAP = 40
    public static let MIN_M = 8.0
    public static let MAX_SPEED_MPS = 120.0
    public static let NEAR_M = 2_000.0
    public static let MAX_OWN_FIGURES = 3

    private static let NOT_GPS = "These positions were broadcast by the radio. They are not this Mac's GPS."

    public static func append(trail: [PayloadFix], device: Sighting) -> [PayloadFix] {
        guard let lat = device.payloadLat else { return trail }
        guard let lon = device.payloadLon else { return trail }
        return append(
            trail: trail,
            fix: PayloadFix(
                at: device.lastSeen,
                lat: lat,
                lon: lon,
                alt: device.payloadAlt,
                heading: device.payloadHeading,
                speed: device.payloadSpeed
            )
        )
    }

    public static func append(trail: [PayloadFix], fix: PayloadFix) -> [PayloadFix] {
        if !PayloadLocation.validCoord(lat: fix.lat, lon: fix.lon) { return trail }
        if let last = trail.last {
            let d = Geo.meters(lat1: last.lat, lon1: last.lon, lat2: fix.lat, lon2: fix.lon)
            if d < MIN_M { return trail }
            let dt = fix.at - last.at
            if dt <= 0 { return trail }
            let mps = d / (Double(dt) / 1000.0)
            if mps > MAX_SPEED_MPS { return trail }
        }
        return cap(trail + [fix], CAP)
    }

    public static func consolidate(fixes: [PayloadFix]) -> [PayloadFix] {
        var trail: [PayloadFix] = []
        for fix in fixes.sortedBy({ $0.at }) { trail = append(trail: trail, fix: fix) }
        return trail
    }

    public static func pictures(sources: [Source], path: [GpsSample]) -> [Picture] {
        let named = sources.filter { $0.uasId.isNotBlank }.groupByOrdered { $0.uasId }
        let loose = sources.filter { $0.uasId.isBlank }
        var out: [Picture] = []
        for (id, rows) in named {
            out.append(picture(id, rows, path))
        }
        for row in loose {
            out.append(picture("", [row], path))
        }
        return out.sortedByDescending { $0.fixes.count }
    }

    private static func picture(_ uasId: String, _ rows: [Source], _ path: [GpsSample]) -> Picture {
        let fixes = consolidate(fixes: rows.flatMap { $0.fixes })
        let latest = rows.maxByOrNull { $0.lastSeen }!
        let pilot = rows.filter { PayloadLocation.validCoord(lat: $0.pilotLat, lon: $0.pilotLon) }
            .maxByOrNull { $0.lastSeen }
        let pilotNear = pilot != nil && fixes.any { fix in
            Geo.meters(lat1: fix.lat, lon1: fix.lon, lat2: pilot!.pilotLat!, lon2: pilot!.pilotLon!) <= NEAR_M
        }
        let walkReady = path.count >= 2
        let near = walkReady && fixes.isNotEmpty && fixes.all { fix in
            path.any { sample in Geo.meters(lat1: fix.lat, lon1: fix.lon, lat2: sample.lat, lon2: sample.lon) <= NEAR_M }
        }
        let titled = uasId.ifBlank(latest.title.ifBlank("Advertised position"))
        let aircraft = rows.filter { $0.aircraft.isNotBlank }.maxByOrNull { $0.lastSeen }?.aircraft ?? ""
        return Picture(
            uasId: uasId,
            title: titled,
            fixes: fixes,
            status: latest.status,
            alt: latest.alt,
            heading: latest.heading,
            speed: latest.speed,
            pilotLat: pilot?.pilotLat,
            pilotLon: pilot?.pilotLon,
            pilotOnMap: pilotNear,
            onWalk: near && fixes.isNotEmpty,
            ownFigure: uasId.isNotBlank && !near && fixes.isNotEmpty,
            keys: Set(rows.map { $0.key }.filter { $0.isNotEmpty }),
            who: latest.title,
            mac: latest.mac,
            aircraft: aircraft
        )
    }

    public static func source(device: Sighting, title: String) -> Source? {
        var raw = device.payloadTrail
        if raw.isEmpty {
            guard let lat = device.payloadLat else { return nil }
            guard let lon = device.payloadLon else { return nil }
            raw = [
                PayloadFix(
                    at: device.lastSeen,
                    lat: lat,
                    lon: lon,
                    alt: device.payloadAlt,
                    heading: device.payloadHeading,
                    speed: device.payloadSpeed
                ),
            ]
        }
        let fixes = raw.filter { PayloadLocation.validCoord(lat: $0.lat, lon: $0.lon) }
        if fixes.isEmpty { return nil }
        let last = fixes.last!
        return Source(
            uasId: device.payloadUasId?.trim() ?? "",
            title: title,
            lastSeen: device.lastSeen,
            status: device.liveDecode.reportLabels().joined(separator: ", "),
            fixes: fixes,
            alt: last.alt ?? device.payloadAlt,
            heading: last.heading ?? device.payloadHeading,
            speed: last.speed ?? device.payloadSpeed,
            pilotLat: device.payloadOpLat,
            pilotLon: device.payloadOpLon,
            key: device.key,
            mac: device.mac,
            aircraft: device.payloadAircraft?.trim() ?? ""
        )
    }

    public static func body(pictures: [Picture]) -> String {
        if pictures.isEmpty { return "" }
        var s = ""
        for (index, pic) in pictures.enumerated() {
            if index > 0 { s += "\n" }
            let head = pic.status.isBlank ? pic.title : "\(pic.title) — \(pic.status)"
            s += "• \(head)\n"
            if pic.aircraft.isNotBlank { s += "  \(pic.aircraft)\n" }
            let last = pic.fixes.last!
            s += "  Last \(fmtCoord(last.lat, last.lon))\n"
            let motion = [
                pic.alt.map { "\(fmtNum($0)) m" },
                pic.heading.map { "course \(fmtNum($0))°" },
                pic.speed.map { "\(fmtNum($0)) m/s" },
            ].compactMap { $0 }
            if motion.isNotEmpty { s += "  \(motion.joined(separator: "  ·  "))\n" }
            let length = lengthM(fixes: pic.fixes)
            let count = pic.fixes.count
            let shape = count == 1 ? "1 advertised fix" : "\(count) advertised fixes, \(fmtDist(length))"
            s += "  \(shape)\n"
            if let pLat = pic.pilotLat, let pLon = pic.pilotLon {
                s += "  Pilot \(fmtCoord(pLat, pLon))\n"
            }
        }
        let hidden = (pictures.count { $0.ownFigure } - MAX_OWN_FIGURES).coerceAtLeast(0)
        if hidden > 0 {
            s += "\(hidden) more aircraft tracks are listed here and left off the map.\n"
        }
        s += NOT_GPS
        return s.trimEnd()
    }

    public static func compareBody(leftName: String, left: [Picture], rightName: String, right: [Picture]) -> String {
        let ids = (left.map { $0.uasId } + right.map { $0.uasId }).filter { $0.isNotBlank }.distinct()
        let looseLeft = left.filter { $0.uasId.isBlank }
        let looseRight = right.filter { $0.uasId.isBlank }
        if ids.isEmpty && looseLeft.isEmpty && looseRight.isEmpty { return "" }
        var s = ""
        for (index, id) in ids.enumerated() {
            if index > 0 { s += "\n" }
            let a = left.first { $0.uasId == id }
            let b = right.first { $0.uasId == id }
            s += "• \(id)\n"
            if let a { s += "  \(leftName): \(sideBit(a))\n" }
            if let b { s += "  \(rightName): \(sideBit(b))\n" }
            let aStatus = a?.status ?? ""
            let bStatus = b?.status ?? ""
            if aStatus.isNotBlank && bStatus.isNotBlank && aStatus != bStatus {
                s += "  Status changed: \(aStatus) → \(bStatus)\n"
            }
        }
        looseLeft.forEach { s += "\(leftName), no UAS id: \(sideBit($0)) (\($0.title))\n" }
        looseRight.forEach { s += "\(rightName), no UAS id: \(sideBit($0)) (\($0.title))\n" }
        s += NOT_GPS
        return s.trimEnd()
    }

    public static func track(pic: Picture, secondary: Bool) -> SitPathPlot.FigureTrack {
        SitPathPlot.FigureTrack(
            name: pic.title.take(22),
            samples: samples(fixes: pic.fixes),
            secondary: secondary,
            aircraft: true,
            headingDeg: pic.heading
        )
    }

    public static func pilotMark(pic: Picture) -> SitPathPlot.Mark? {
        guard pic.pilotOnMap, let lat = pic.pilotLat, let lon = pic.pilotLon else { return nil }
        return SitPathPlot.Mark(lat: lat, lon: lon, label: "Pilot")
    }

    public static func applyWalk(base: SitPathPlot.Figure?, pictures: [Picture], secondary: Bool) -> SitPathPlot.Figure? {
        guard let base else { return nil }
        let near = pictures.filter { $0.onWalk }
        if near.isEmpty { return base }
        let added = near.map { track(pic: $0, secondary: secondary) }
        let framed = base.tracks.flatMap { $0.samples } + added.flatMap { $0.samples }
        let covered = Set(near.flatMap { $0.keys }.filter { $0.isNotEmpty })
        var out = base
        out.tracks = base.tracks + added
        out.pilots = base.pilots + near.compactMap { pilotMark(pic: $0) }
        out.dots = base.dots.filter { !covered.contains($0.key) }
        out.craftKeys = base.craftKeys + near.map { pathKeyLine(pic: $0) }
        out.spanM = Geo.spanM(samples: framed)
        if secondary {
            if !base.caption.contains("second sit’s advertised track") {
                out.caption = base.caption + " A blue dotted line is the second sit’s advertised track within 2 km of this path."
            }
        } else if !base.caption.contains("black dotted line is an advertised track") {
            out.caption = base.caption + " A black dotted line is an advertised track within 2 km of this path."
        }
        return out
    }

    public static func ownFigures(pictures: [Picture], secondary: Bool = false) -> [SitPathPlot.Figure] {
        pictures.filter { $0.ownFigure }.take(MAX_OWN_FIGURES).map { pictureFigure($0, secondary: secondary) }
    }

    private static func pictureFigure(_ pic: Picture, secondary: Bool = false) -> SitPathPlot.Figure {
        let samples = samples(fixes: pic.fixes)
        return SitPathPlot.Figure(
            kicker: "AIRCRAFT",
            tracks: [track(pic: pic, secondary: secondary)],
            dots: [],
            lengthM: lengthM(fixes: pic.fixes),
            spanM: Geo.spanM(samples: samples),
            caption: aircraftCaption(pic),
            pilots: [pilotMark(pic: pic)].compactMap { $0 }
        )
    }

    public static func compareOwnFigures(left: [Picture], right: [Picture]) -> [SitPathPlot.Figure] {
        let ids = (left + right).filter { $0.ownFigure }.map { $0.uasId }.filter { $0.isNotBlank }.distinct()
        return ids.take(MAX_OWN_FIGURES).map { id in
            let a = left.first { $0.uasId == id && $0.ownFigure }
            let b = right.first { $0.uasId == id && $0.ownFigure }
            let tracks = [a.map { track(pic: $0, secondary: false) }, b.map { track(pic: $0, secondary: true) }].compactMap { $0 }
            let samples = tracks.flatMap { $0.samples }
            let lenA = a.map { lengthM(fixes: $0.fixes) } ?? 0.0
            let lenB = b.map { lengthM(fixes: $0.fixes) } ?? 0.0
            let caption: String
            if a != nil && b != nil {
                caption = "North-up. Black dots are this sit. Blue dots are the second sit. The marker is the last advertised position."
            } else if let b {
                caption = "North-up. The blue dotted line is the advertised track for \(b.title). The marker is the last advertised position."
            } else {
                caption = aircraftCaption(a!)
            }
            return SitPathPlot.Figure(
                kicker: "AIRCRAFT",
                tracks: tracks,
                dots: [],
                lengthM: max(lenA, lenB),
                spanM: Geo.spanM(samples: samples),
                caption: caption,
                pilots: [a.flatMap { pilotMark(pic: $0) }, b.flatMap { pilotMark(pic: $0) }].compactMap { $0 }
            )
        }
    }

    /// Same near / far split the report uses, for the on-screen Path card.
    /// Near tracks share the Mac's plot. A farther UAS id becomes its own card.
    public static func overlay(model: SitPathPlot.Model, pictures: [Picture]) -> SitPathPlot.Model {
        let near = pictures.filter { $0.onWalk }
        var frames: [GpsSample] = []
        for pic in near {
            frames += samples(fixes: pic.fixes)
            if let m = pilotMark(pic: pic) { frames.append(GpsSample(at: 0, lat: m.lat, lon: m.lon, rssi: 0)) }
        }
        let looseAlerts = pictures.filter { pic in
            !pic.onWalk && !pic.ownFigure && pic.fixes.isNotEmpty && pic.keys.any { key in
                model.dots.any { $0.key == key && $0.advertised }
            }
        }
        let cards = (pictures.filter { $0.ownFigure } + looseAlerts).take(MAX_OWN_FIGURES)
        var cardByKey: [String: Picture] = [:]
        for pic in cards { for k in pic.keys { cardByKey[k] = pic } }
        var walkDots: [SitPathPlot.Dot] = []
        var cardDots: [Picture: [SitPathPlot.Dot]] = [:]
        for dot in model.dots {
            if let pic = cardByKey[dot.key], dot.advertised {
                cardDots[pic, default: []].append(dot)
            } else {
                walkDots.append(dot)
            }
        }
        let cardKeys = Set(cards.flatMap { $0.keys })
        var out = model
        out.dots = walkDots
        out.frameSamples = frames
        out.craft = near.map { track(pic: $0, secondary: false) }
        out.pilots = near.compactMap { pilotMark(pic: $0) }
        out.aircraftCards = cards.map { pic in cardModel(fig: pictureFigure(pic), dots: cardDots[pic] ?? []) }
        out.looseAdvertised = pictures.count { pic in
            pic.fixes.isNotEmpty && !pic.onWalk && pic.uasId.isBlank &&
                pic.keys.none { cardKeys.contains($0) }
        }
        return out
    }

    public static func cardModel(fig: SitPathPlot.Figure, dots: [SitPathPlot.Dot] = []) -> SitPathPlot.Model {
        let tracks = fig.tracks.filter { $0.aircraft }.ifEmpty(fig.tracks)
        let fixes = tracks.flatMap { $0.samples }
        let frames = fixes + fig.pilots.map { GpsSample(at: 0, lat: $0.lat, lon: $0.lon, rssi: 0) }
        let title = tracks.first?.name.nonBlank ?? "Aircraft"
        return SitPathPlot.Model(
            samples: [],
            dots: dots,
            lengthM: fig.lengthM,
            spanM: fig.spanM,
            title: title,
            frameSamples: frames,
            minHalfSpanM: Geo.spanM(samples: fixes) < 80.0 ? 140.0 : 0.0,
            craft: tracks,
            pilots: fig.pilots,
            caption: fig.caption
        )
    }

    public static func samples(fixes: [PayloadFix]) -> [GpsSample] {
        fixes.map { GpsSample(at: $0.at, lat: $0.lat, lon: $0.lon, rssi: 0) }
    }

    public static func lengthM(fixes: [PayloadFix]) -> Double {
        if fixes.count < 2 { return 0.0 }
        var sum = 0.0
        for i in 1..<fixes.count {
            sum += Geo.meters(lat1: fixes[i - 1].lat, lon1: fixes[i - 1].lon, lat2: fixes[i].lat, lon2: fixes[i].lon)
        }
        return sum
    }

    private static func aircraftCaption(_ pic: Picture) -> String {
        if pic.fixes.count < 2 {
            return "Last advertised position for \(pic.title). The marker is that position."
        }
        return "North-up. The black dotted line is the advertised track for \(pic.title). The marker is the last advertised position."
    }

    /// One Path-key line for a radio that advertised a position.
    /// Same facts as the Aircraft section, kept on the row under the map.
    public static func advertisedNote(
        status: String,
        uasId: String,
        label: String,
        lat: Double,
        lon: Double,
        alt: Double?,
        heading: Double?,
        speed: Double?,
        pilotLat: Double?,
        pilotLon: Double?,
        aircraft: String = ""
    ) -> String {
        var bits: [String] = []
        let craft = aircraft.trim()
        if craft.isNotEmpty { bits.append(craft) }
        let state = status.trim()
        if state.isNotEmpty { bits.append(state) }
        let id = uasId.trim()
        if id.isNotEmpty && !id.equals(label.trim(), ignoreCase: true) { bits.append("UAS \(id)") }
        bits.append("last \(fmtCoord(lat, lon))")
        if let alt { bits.append("\(fmtNum(alt)) m") }
        if let heading { bits.append("course \(fmtNum(heading))°") }
        if let speed { bits.append("\(fmtNum(speed)) m/s") }
        if PayloadLocation.validCoord(lat: pilotLat, lon: pilotLon) {
            bits.append("pilot \(fmtCoord(pilotLat!, pilotLon!))")
        }
        return bits.joined(separator: " · ")
    }

    /// Path key row for the class icon at the end of an advertised track.
    public static func pathKeyLine(pic: Picture) -> String {
        let last = pic.fixes.last
        let head = [pic.who.ifBlank(pic.title), pic.mac]
            .map { $0.trim() }
            .filter { $0.isNotEmpty }
            .distinct()
            .joined(separator: " ")
            .ifBlank("Advertised position")
        guard let last else { return head }
        let note = advertisedNote(
            status: pic.status,
            uasId: pic.uasId.ifBlank(pic.title),
            label: head,
            lat: last.lat,
            lon: last.lon,
            alt: pic.alt,
            heading: pic.heading,
            speed: pic.speed,
            pilotLat: pic.pilotLat,
            pilotLon: pic.pilotLon,
            aircraft: pic.aircraft
        )
        return "\(head) — \(note)"
    }

    private static func sideBit(_ pic: Picture) -> String {
        let craft = pic.aircraft.isBlank ? "" : "\(pic.aircraft), "
        let status = pic.status.isBlank ? "" : "\(pic.status), "
        let whereText = pic.fixes.last.map { " last \(fmtCoord($0.lat, $0.lon))" } ?? ""
        let count = pic.fixes.count == 1 ? "1 fix" : "\(pic.fixes.count) fixes"
        return "\(craft)\(status)\(count)\(whereText)".trim()
    }

    private static func cap(_ samples: [PayloadFix], _ limit: Int) -> [PayloadFix] {
        if samples.count <= limit { return samples }
        if limit <= 1 { return [samples.last!] }
        if limit == 2 { return [samples.first!, samples.last!] }
        let lastIdx = samples.count - 1
        var out: [PayloadFix] = []
        out.reserveCapacity(limit)
        for i in 0..<limit {
            let idx = (i * lastIdx) / (limit - 1)
            let sample = samples[idx]
            if out.isEmpty || out.last!.at != sample.at { out.append(sample) }
        }
        if out.last!.at != samples.last!.at { out.append(samples.last!) }
        return out
    }

    private static func fmtCoord(_ lat: Double, _ lon: Double) -> String {
        fmt(lat, 6) + ", " + fmt(lon, 6)
    }

    private static func fmtNum(_ n: Double) -> String {
        n.truncatingRemainder(dividingBy: 1.0) == 0.0 ? String(n.toIntTruncating()) : fmt(n, 1)
    }

    private static func fmtDist(_ m: Double) -> String {
        m >= 1000 ? "\(fmt(m / 1000, 1)) km" : "\(m.toIntTruncating()) m"
    }

    public struct Source: Hashable, Sendable {
        public var uasId: String
        public var title: String
        public var lastSeen: Int
        public var status: String
        public var fixes: [PayloadFix]
        public var alt: Double?
        public var heading: Double?
        public var speed: Double?
        public var pilotLat: Double?
        public var pilotLon: Double?
        /// Device key of the radio that sent these fixes. Empty for a report-only source.
        public var key: String
        public var mac: String
        public var aircraft: String

        public init(
            uasId: String, title: String, lastSeen: Int, status: String, fixes: [PayloadFix],
            alt: Double?, heading: Double?, speed: Double?, pilotLat: Double?, pilotLon: Double?,
            key: String = "", mac: String = "", aircraft: String = ""
        ) {
            self.uasId = uasId; self.title = title; self.lastSeen = lastSeen; self.status = status
            self.fixes = fixes; self.alt = alt; self.heading = heading; self.speed = speed
            self.pilotLat = pilotLat; self.pilotLon = pilotLon; self.key = key; self.mac = mac
            self.aircraft = aircraft
        }
    }

    public struct Picture: Hashable, Sendable {
        public var uasId: String
        public var title: String
        public var fixes: [PayloadFix]
        public var status: String
        public var alt: Double?
        public var heading: Double?
        public var speed: Double?
        public var pilotLat: Double?
        public var pilotLon: Double?
        public var pilotOnMap: Bool
        public var onWalk: Bool
        public var ownFigure: Bool
        /// Device keys joined into this picture.
        public var keys: Set<String>
        /// Radio name when it is not already the UAS id.
        public var who: String
        public var mac: String
        public var aircraft: String

        public init(
            uasId: String, title: String, fixes: [PayloadFix], status: String, alt: Double?,
            heading: Double?, speed: Double?, pilotLat: Double?, pilotLon: Double?, pilotOnMap: Bool,
            onWalk: Bool, ownFigure: Bool, keys: Set<String> = [], who: String = "", mac: String = "",
            aircraft: String = ""
        ) {
            self.uasId = uasId; self.title = title; self.fixes = fixes; self.status = status
            self.alt = alt; self.heading = heading; self.speed = speed; self.pilotLat = pilotLat
            self.pilotLon = pilotLon; self.pilotOnMap = pilotOnMap; self.onWalk = onWalk
            self.ownFigure = ownFigure; self.keys = keys; self.who = who; self.mac = mac
            self.aircraft = aircraft
        }
    }
}
