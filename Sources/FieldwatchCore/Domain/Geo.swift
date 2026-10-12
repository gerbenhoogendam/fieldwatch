import Foundation

// Port of domain/Geo.kt (Geo, CoTravel, TrackerMatch).

/// java.lang.Math.toRadians / toDegrees (JDK 9+: multiply by the constant).
private func toRadians(_ deg: Double) -> Double { deg * 0.017453292519943295 }
private func toDegrees(_ rad: Double) -> Double { rad * 57.29577951308232 }

public enum Geo {
    public static func meters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = toRadians(lat1)
        let p2 = toRadians(lat2)
        let dp = toRadians(lat2 - lat1)
        let dl = toRadians(lon2 - lon1)
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Degrees clockwise from true north, from the first point to the second.
    public static func bearingDegrees(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let p1 = toRadians(lat1)
        let p2 = toRadians(lat2)
        let dl = toRadians(lon2 - lon1)
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        let wrapped = toDegrees(atan2(y, x)).truncatingRemainder(dividingBy: 360.0)
        return wrapped < 0.0 ? wrapped + 360.0 : wrapped
    }

    public static func midpoint(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> (Double, Double) {
        let p1 = toRadians(lat1)
        let l1 = toRadians(lon1)
        let p2 = toRadians(lat2)
        let dl = toRadians(lon2 - lon1)
        let bx = cos(p2) * cos(dl)
        let by = cos(p2) * sin(dl)
        let lat = atan2(
            sin(p1) + sin(p2),
            sqrt((cos(p1) + bx) * (cos(p1) + bx) + by * by)
        )
        let lon = l1 + atan2(by, cos(p1) + bx)
        return (toDegrees(lat), toDegrees(lon))
    }

    public static func pathLengthM(samples: [GpsSample]) -> Double {
        var sum = 0.0
        if samples.count < 2 { return sum }
        for i in 1..<samples.count {
            sum += meters(lat1: samples[i - 1].lat, lon1: samples[i - 1].lon, lat2: samples[i].lat, lon2: samples[i].lon)
        }
        return sum
    }

    public static func spanM(samples: [GpsSample]) -> Double {
        if samples.count < 2 { return 0.0 }
        var max = 0.0
        for i in 0..<samples.count {
            for j in (i + 1)..<samples.count {
                let d = meters(lat1: samples[i].lat, lon1: samples[i].lon, lat2: samples[j].lat, lon2: samples[j].lon)
                if d > max { max = d }
            }
        }
        return max
    }

    /// One stretch of the operator path: a sit (clustered within `stayM`) or a
    /// hop between sits. Coordinates are the Mac at hear-time.
    public struct PathLeg: Hashable, Sendable {
        public var stay: Bool
        public var startAt: Int
        public var endAt: Int
        public var lat: Double
        public var lon: Double
        public var endLat: Double
        public var endLon: Double
        public var samples: Int
        public var pathM: Double

        public init(stay: Bool, startAt: Int, endAt: Int, lat: Double, lon: Double, endLat: Double, endLon: Double, samples: Int, pathM: Double) {
            self.stay = stay; self.startAt = startAt; self.endAt = endAt; self.lat = lat; self.lon = lon
            self.endLat = endLat; self.endLon = endLon; self.samples = samples; self.pathM = pathM
        }

        public var durationMs: Int { (endAt - startAt).coerceAtLeast(0) }
        public func cellKey() -> String { Geo.cellKey(lat: lat, lon: lon) }
    }

    public static func cellKey(lat: Double, lon: Double) -> String {
        "\(fmt(lat, 4)),\(fmt(lon, 4))"
    }

    public static func screenCoord(lat: Double?, lon: Double?, demo: Bool) -> String? {
        guard let lat, let lon else { return nil }
        if demo { return "masked" }
        return "\(fmt(lat, 5)), \(fmt(lon, 5))"
    }

    public static func redactCoordsIn(text: String, demo: Bool) -> String {
        if !demo || text.isEmpty { return text }
        return COORD_RE.replace(text, "masked")
    }

    private static let COORD_RE = KRegex("-?\\d{1,3}\\.\\d{3,8}\\s*,\\s*-?\\d{1,3}\\.\\d{3,8}")

    /// Split a time-ordered path into stays (~40 m) and transits. A single GPS
    /// sample that holds until the next hop is a stay (sitting still does not
    /// add points). Caps at 10 legs.
    /// `now` nil = last sample time (Kotlin default `samples.lastOrNull()?.at ?: 0L`).
    public static func legs(
        samples: [GpsSample],
        stayM: Double = 40.0,
        minStayMs: Int = 40_000,
        now: Int? = nil
    ) -> [PathLeg] {
        if samples.isEmpty { return [] }
        let now = now ?? (samples.last?.at ?? 0)
        var clusters: [[GpsSample]] = []
        var cur = [samples[0]]
        var cLat = samples[0].lat
        var cLon = samples[0].lon
        for i in 1..<samples.count {
            let s = samples[i]
            if meters(lat1: cLat, lon1: cLon, lat2: s.lat, lon2: s.lon) <= stayM {
                cur.append(s)
                var slat = 0.0
                var slon = 0.0
                for p in cur {
                    slat += p.lat
                    slon += p.lon
                }
                cLat = slat / Double(cur.count)
                cLon = slon / Double(cur.count)
            } else {
                clusters.append(cur)
                cur = [s]
                cLat = s.lat
                cLon = s.lon
            }
        }
        clusters.append(cur)
        let classified: [PathLeg] = clusters.enumerated().map { i, cluster in
            let start = cluster.first!
            let endSample = cluster.last!
            let nextStart = clusters.getOrNull(i + 1)?.first?.at
            let endAt = nextStart ?? now.coerceAtLeast(endSample.at)
            var slat = 0.0
            var slon = 0.0
            for p in cluster {
                slat += p.lat
                slon += p.lon
            }
            let n = Double(cluster.count)
            let lat = slat / n
            let lon = slon / n
            let dur = (endAt - start.at).coerceAtLeast(0)
            let stay = clusters.count == 1 || dur >= minStayMs || spanM(samples: cluster) <= 25.0
            return PathLeg(
                stay: stay,
                startAt: start.at,
                endAt: endAt,
                lat: lat,
                lon: lon,
                endLat: endSample.lat,
                endLon: endSample.lon,
                samples: cluster.count,
                pathM: pathLengthM(samples: cluster)
            )
        }
        var merged: [PathLeg] = []
        for leg in classified {
            if let last = merged.last, !last.stay, !leg.stay {
                var m = last
                m.endAt = leg.endAt
                m.endLat = leg.endLat
                m.endLon = leg.endLon
                m.samples = last.samples + leg.samples
                m.pathM = last.pathM + meters(lat1: last.endLat, lon1: last.endLon, lat2: leg.lat, lon2: leg.lon) + leg.pathM
                merged[merged.count - 1] = m
            } else {
                merged.append(leg)
            }
        }
        return merged.take(10)
    }

    /// ~150 km/h. Walking sits and city driving stay under this; a GPS glitch does not.
    public static let SPIKE_MAX_SPEED_MPS = 42.0
    public static let SPIKE_MIN_HOP_M = 40.0
    public static let SPIKE_MIN_DT_MS = 800

    public static func hopPlausible(
        from: GpsSample,
        lat: Double,
        lon: Double,
        at: Int,
        maxSpeedMps: Double = SPIKE_MAX_SPEED_MPS
    ) -> Bool {
        let d = meters(lat1: from.lat, lon1: from.lon, lat2: lat, lon2: lon)
        let dt = at - from.at
        if d <= SPIKE_MIN_HOP_M { return true }
        if dt < SPIKE_MIN_DT_MS { return true }
        let mps = d / (Double(dt) / 1000.0).coerceAtLeast(0.001)
        return mps <= maxSpeedMps
    }

    /// Drop GPS glitches: a point that shoots out and back, or a hop faster than
    /// `SPIKE_MAX_SPEED_MPS` over at least `SPIKE_MIN_DT_MS`. Existing sits clean
    /// up on Path; new samples are rejected in recordPath.
    public static func despikePath(samples: [GpsSample]) -> [GpsSample] {
        if samples.count < 2 { return samples }
        var cur = samples
        for _ in 0..<4 {
            let next = despikeOnce(cur)
            if next.count == cur.count { return next }
            cur = next
            if cur.count < 2 { return cur }
        }
        return cur
    }

    private static func despikeOnce(_ samples: [GpsSample]) -> [GpsSample] {
        if samples.count < 2 { return samples }
        var out: [GpsSample] = []
        out.reserveCapacity(samples.count)
        out.append(samples[0])
        var i = 1
        while i < samples.count {
            let prev = out.last!
            let cur = samples[i]
            if let next = samples.getOrNull(i + 1) {
                let dAb = meters(lat1: prev.lat, lon1: prev.lon, lat2: cur.lat, lon2: cur.lon)
                let dBc = meters(lat1: cur.lat, lon1: cur.lon, lat2: next.lat, lon2: next.lon)
                let dAc = meters(lat1: prev.lat, lon1: prev.lon, lat2: next.lat, lon2: next.lon)
                let spike = dAb > SPIKE_MIN_HOP_M && dBc > SPIKE_MIN_HOP_M &&
                    dAc < dAb * 0.4 && dAc < dBc * 0.4
                if spike {
                    i += 1
                    continue
                }
            }
            if !hopPlausible(from: prev, lat: cur.lat, lon: cur.lon, at: cur.at) {
                i += 1
                continue
            }
            out.append(cur)
            i += 1
        }
        return out.count >= 2 ? out : samples.take(1) + samples.takeLast(1)
    }

    public static func append(trail: [GpsSample], at: Int, lat: Double, lon: Double, rssi: Int, cap: Int = 48) -> [GpsSample] {
        if let last = trail.last {
            let d = meters(lat1: last.lat, lon1: last.lon, lat2: lat, lon2: lon)
            if d < 8.0 { return trail }
            if d < 18.0 && at - last.at < 30_000 { return trail }
        }
        let next = trail + [GpsSample(at: at, lat: lat, lon: lon, rssi: rssi)]
        return capSpread(samples: next, cap: cap)
    }

    /// Keep `cap` samples spread across the whole trail (first, last, and even
    /// steps). takeLast would only keep the end of a long sit.
    public static func capSpread(samples: [GpsSample], cap: Int) -> [GpsSample] {
        if samples.count <= cap { return samples }
        if cap <= 1 { return [samples.last!] }
        if cap == 2 { return [samples.first!, samples.last!] }
        let lastIdx = samples.count - 1
        var out: [GpsSample] = []
        out.reserveCapacity(cap)
        for i in 0..<cap {
            let idx = (i * lastIdx) / (cap - 1)
            let s = samples[idx]
            if out.isEmpty || out.last!.at != s.at { out.append(s) }
        }
        if out.last!.at != samples.last!.at { out.append(samples.last!) }
        return out
    }
}

/// Live co-travel, BLE only. The Mac's GPS is stamped at hear-time. A bag/car tag
/// stays loud along the path. Wi-Fi APs are excluded: a loud AP you drive past
/// paints hundreds of meters of your path and looks like it moved with you.
/// Cheap loud-RSSI reject first so the list is not O(n²) GPS on every radio.
public enum CoTravel {
    public static let MOVE_M = 45.0
    public static let NEAR_M = 50.0
    public static let HEARD_MS = 90_000
    public static let LOUD_DBM = -70
    public static let TRAIL_LOUD_DBM = -75

    public struct Ctx: Hashable, Sendable {
        public var pathLengthM: Double
        public var durationMs: Int
        public var here: GpsSample?
        public var ready: Bool

        public init(pathLengthM: Double, durationMs: Int, here: GpsSample?, ready: Bool) {
            self.pathLengthM = pathLengthM; self.durationMs = durationMs; self.here = here; self.ready = ready
        }

        public static let None = Ctx(pathLengthM: 0.0, durationMs: 0, here: nil, ready: false)

        public static func of(path: [GpsSample]) -> Ctx {
            if path.count < 2 { return None }
            let len = Geo.pathLengthM(samples: path)
            let dur = (path.last!.at - path.first!.at).coerceAtLeast(0)
            return Ctx(pathLengthM: len, durationMs: dur, here: path.last, ready: len >= MOVE_M)
        }
    }

    private struct TrailGeom {
        let n: Int
        let at: Int
        let lat: Double
        let lon: Double
        let len: Double
        let bbox: Double
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var trailGeom: [String: TrailGeom] = [:]

    public static func withYou(device: Sighting, ctx: Ctx, now: Int = nowMs()) -> Bool {
        if device.kind == .wifi { return false }
        guard ctx.ready, let here = ctx.here else { return false }
        if now - device.lastSeen > HEARD_MS { return false }
        // Last packet can dip on a highway; the cheap reject is the trail floor, not −70 instant.
        if device.rssi < TRAIL_LOUD_DBM { return false }
        let trail = device.gpsTrail
        if trail.count < 2 { return false }
        guard let geom = geomFor(key: device.key, trail: trail) else { return false }
        if geom.bbox < MOVE_M * 0.6 { return false }
        var loud = 0
        for s in trail where s.rssi >= TRAIL_LOUD_DBM { loud += 1 }
        if loud < (trail.count * 2 + 2) / 3 { return false }
        if geom.len < MOVE_M * 0.6 { return false }
        let last = trail.last!
        let moved = Geo.meters(lat1: here.lat, lon1: here.lon, lat2: last.lat, lon2: last.lon)
        // Last GPS stamp is the Mac at hear-time. 50 m of driving is ~2 s on an interstate,
        // so a bag tag that advertises every few seconds would flash without a speed-aware slack.
        let speed = (ctx.pathLengthM / (Double(ctx.durationMs) / 1000.0).coerceAtLeast(1.0)).coerceIn(0.0, 40.0)
        let allowM = max(NEAR_M, speed * 15.0) + 25.0
        return moved <= allowM
    }

    private static func geomFor(key: String, trail: [GpsSample]) -> TrailGeom? {
        guard let last = trail.last else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let hit = trailGeom[key], hit.n == trail.count, hit.at == last.at,
           hit.lat == last.lat, hit.lon == last.lon {
            return hit
        }
        let next = TrailGeom(
            n: trail.count,
            at: last.at,
            lat: last.lat,
            lon: last.lon,
            len: Geo.pathLengthM(samples: trail),
            bbox: bboxSpanM(trail)
        )
        trailGeom[key] = next
        if trailGeom.count > 1024 { trailGeom.removeAll() }
        return next
    }

    private static func bboxSpanM(_ samples: [GpsSample]) -> Double {
        var minLat = samples[0].lat
        var maxLat = minLat
        var minLon = samples[0].lon
        var maxLon = minLon
        for s in samples.dropFirst() {
            if s.lat < minLat { minLat = s.lat }
            if s.lat > maxLat { maxLat = s.lat }
            if s.lon < minLon { minLon = s.lon }
            if s.lon > maxLon { maxLon = s.lon }
        }
        return Geo.meters(lat1: minLat, lon1: minLon, lat2: maxLat, lon2: maxLon)
    }
}

public enum TrackerMatch {
    public enum Kind: String, CaseIterable, Sendable { case finder = "FINDER", beacon = "BEACON", wearable = "WEARABLE" }

    private static let finderTokens = [
        "airtag", "smarttag", "tile", "chipolo", "pebblebee", "moto tag", "find my",
        "find hub", "dult",
    ]
    private static let beaconTokens = ["ibeacon", "minew", "estimote", "kontakt"]
    private static let wearableTokens = ["garmin", "fitbit", "oura", "polar"]

    /// Apple Continuity / pairing types — not Offline Finding 0x12.
    private static let APPLE_CONTINUITY_PREFIXES: Set<String> = [
        "05", "07", "08", "09", "0A", "0B", "0C", "0D", "0E", "0F", "10",
    ]

    public static func isTrackerFleet(name: String) -> Bool {
        let n = name.lowercased()
        return finderTokens.any { n.contains($0) }
    }

    private static func nameHits(_ device: Sighting, _ names: [String: String], _ tokens: [String]) -> [String] {
        device.fleetIds.compactMap { id in
            guard let n = names[id] else { return nil }
            let low = n.lowercased()
            return tokens.any { low.contains($0) } ? n : nil
        }
    }

    public static func fleetHits(device: Sighting, names: [String: String]) -> [String] {
        nameHits(device, names, finderTokens)
    }

    public static func isFindMyPayload(device: Sighting) -> Bool {
        if isAppleContinuity(device: device) { return false }
        if device.facts.mfgRecords.any({ $0.companyId == 0x004C && mfgPrefix($0) == "12" }) { return true }
        return device.manufacturerId == 0x004C &&
            device.manufacturerDataHex.filterAlnum().take(2).uppercased() == "12"
    }

    /// Nearby Info / Handoff / AirDrop / AirPods / … — a phone, Mac, or buds, not a tag.
    public static func isAppleContinuity(device: Sighting) -> Bool {
        var recs = device.facts.mfgRecords
        if recs.isEmpty {
            guard let id = device.manufacturerId else { return false }
            recs = [MfgRecord(companyId: id, dataHex: device.manufacturerDataHex)]
        }
        return recs.any { rec in
            rec.companyId == 0x004C && APPLE_CONTINUITY_PREFIXES.contains(mfgPrefix(rec))
        }
    }

    private static func mfgPrefix(_ rec: MfgRecord) -> String {
        rec.dataHex.filterAlnum().take(2).uppercased()
    }

    public static func isAppleCompany(device: Sighting) -> Bool {
        if device.manufacturerId == 0x004C { return true }
        return device.facts.mfgRecords.any { $0.companyId == 0x004C }
    }

    public static func isTracker(device: Sighting, names: [String: String]) -> Bool {
        kind(device: device, names: names) == .finder
    }

    /// Pocket iPhone / Continuity: loud Apple BLE that stayed loud.
    /// Not every Apple TV on the block — followAssessments still requires a GPS trail.
    /// Not iBeacon / Minew — those are `Kind.beacon` even though the payload is 0x004C.
    public static func isCarriedApple(device: Sighting, names: [String: String]) -> Bool {
        if device.kind != .ble { return false }
        if device.rssiMax < -55 || device.rssiMin < -70 { return false }
        if nameHits(device, names, beaconTokens).isNotEmpty { return false }
        if isAppleCompany(device: device) { return true }
        return device.fleetIds.any { id in (names[id] ?? "").contains("apple", ignoreCase: true) }
    }

    public static func kind(device: Sighting, names: [String: String]) -> Kind? {
        if nameHits(device, names, finderTokens).isNotEmpty || isFindMyPayload(device: device) { return .finder }
        if nameHits(device, names, beaconTokens).isNotEmpty { return .beacon }
        if nameHits(device, names, wearableTokens).isNotEmpty { return .wearable }
        if isCarriedApple(device: device, names: names) { return .finder }
        return nil
    }

    public static func label(device: Sighting, names: [String: String]) -> String {
        let finder = nameHits(device, names, finderTokens)
        if finder.isNotEmpty { return finder.joined(separator: " + ") }
        let beacon = nameHits(device, names, beaconTokens)
        if beacon.isNotEmpty { return beacon.joined(separator: " + ") }
        let wear = nameHits(device, names, wearableTokens)
        if wear.isNotEmpty { return wear.joined(separator: " + ") }
        if isFindMyPayload(device: device) { return "Apple Find My / Offline Finding" }
        if isCarriedApple(device: device, names: names) { return "Apple BLE (phone / Continuity)" }
        return "tracker-like"
    }
}
