import Foundation

// Port of domain/Sit.kt. SitSummary / SitRadio / SitFile are persisted by SitStore as JSON
// in the kotlinx shape (defaults on missing keys, nulls written, @EncodeDefault(NEVER) omitted).

/// Kotlin `replace('\n', ' ').replace('\r', ' ')` on UTF-16 units. Swift treats "\r\n" as one Character.
private func spaceOutLineBreaks(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.map { ($0 == "\n" || $0 == "\r") ? " " : $0 }))
}

public enum Sit {
    public static let NAME_MAX = 40
    public static let RADIO_CAP = 6000
    public static let PATH_CAP = 2000
    public static let CLOSED_CAP = 10
    public static let TRAIL_CAP = 40
    public static let PATH_MIN_M = 10.0
    public static let PATH_MIN_MS = 5_000
    public static let FLUSH_MS = 10_000
    public static let FORMAT = "fieldwatch-sit"
    public static let FORMAT_VERSION = 1

    public static func clipName(raw: String) -> String {
        spaceOutLineBreaks(raw.trim()).take(NAME_MAX)
    }

    /// "d MMM HH:mm" in the Mac's time zone.
    public static func defaultName(at: Int, locale: Locale = Locale(identifier: "en_US")) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone.current
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(at) / 1000.0))
    }

    public static func resolveName(raw: String, at: Int, locale: Locale = Locale(identifier: "en_US")) -> String {
        clipName(raw: raw).ifBlank(defaultName(at: at, locale: locale))
    }

    public static func fmtDuration(ms: Int) -> String {
        let s = (ms / 1000).coerceAtLeast(0)
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 { return "\(h) h \(m) min" }
        if m > 0 { return "\(m) min" }
        return "\(s) s"
    }

    public static func newId() -> String { UUID().uuidString.lowercased() }

    /// Closed list is newest-first. Nil unless ending another sit would drop the oldest.
    public static func dropWarning(closed: [SitSummary]) -> String? {
        if closed.count < CLOSED_CAP { return nil }
        guard let oldest = closed.last else { return nil }
        return "You already have \(CLOSED_CAP) saved sits. When you end this one, the oldest (“\(oldest.name)”) will be deleted."
    }

    public static func pinned(
        key: String,
        fleetIds: [String],
        payload: Bool,
        extraAttention: Bool,
        watchDeviceKeys: Set<String>,
        watchedFleetIds: Set<String>
    ) -> Bool {
        if extraAttention { return true }
        if payload { return true }
        if watchDeviceKeys.contains(key) { return true }
        if fleetIds.any({ watchedFleetIds.contains($0) }) { return true }
        return false
    }
}

public struct SitSummary: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var startAt: Int
    public var endAt: Int?
    public var radioCount: Int
    public var extraAttentionCount: Int

    public init(id: String, name: String, startAt: Int, endAt: Int? = nil, radioCount: Int = 0, extraAttentionCount: Int = 0) {
        self.id = id; self.name = name; self.startAt = startAt; self.endAt = endAt
        self.radioCount = radioCount; self.extraAttentionCount = extraAttentionCount
    }

    public var open: Bool { endAt == nil }

    public func durationMs(now: Int = nowMs()) -> Int {
        ((endAt ?? now) - startAt).coerceAtLeast(0)
    }

    enum CodingKeys: String, CodingKey { case id, name, startAt, endAt, radioCount, extraAttentionCount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        startAt = try c.decode(Int.self, forKey: .startAt)
        endAt = try c.opt(.endAt)
        radioCount = try c.decode(.radioCount, default: 0)
        extraAttentionCount = try c.decode(.extraAttentionCount, default: 0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(startAt, forKey: .startAt)
        try c.encode(endAt, forKey: .endAt)
        try c.encode(radioCount, forKey: .radioCount)
        try c.encode(extraAttentionCount, forKey: .extraAttentionCount)
    }
}

public struct SitRadio: Codable, Hashable, Sendable {
    public var key: String
    public var kind: RadioKind
    public var mac: String
    public var name: String
    /// Kotlin `Set<String>` (LinkedHashSet). Ordered and distinct here, like `Sighting.fleetIds`.
    public var fleetIds: [String]
    public var firstSeen: Int
    public var lastSeen: Int
    public var hitCount: Int
    public var rssi: Int
    public var rssiMin: Int
    public var rssiMax: Int
    public var channel: Int
    public var frequencyMhz: Int
    public var randomized: Bool
    public var hiddenSsid: Bool
    public var gone: Bool
    public var extraAttention: Bool
    public var payloadLat: Double?
    public var payloadLon: Double?
    public var payloadUasId: String?
    /// Omitted from JSON when nil.
    public var payloadAircraft: String?
    /// Omitted from JSON when nil.
    public var payloadAlt: Double?
    /// Omitted from JSON when nil.
    public var payloadHeading: Double?
    /// Omitted from JSON when nil.
    public var payloadSpeed: Double?
    /// Omitted from JSON when nil.
    public var payloadOpLat: Double?
    /// Omitted from JSON when nil.
    public var payloadOpLon: Double?
    /// Omitted from JSON when empty.
    public var payloadTrail: [PayloadFix]
    public var gpsTrail: [GpsSample]
    /// Live-row labels captured at hear-time. Saved sits do not keep the advertisement bytes.
    public var liveDecode: [LiveDecodeChip]

    public init(
        key: String, kind: RadioKind, mac: String, name: String, fleetIds: [String] = [], firstSeen: Int,
        lastSeen: Int, hitCount: Int, rssi: Int, rssiMin: Int, rssiMax: Int, channel: Int = 0,
        frequencyMhz: Int = 0, randomized: Bool = false, hiddenSsid: Bool = false, gone: Bool = false,
        extraAttention: Bool = false, payloadLat: Double? = nil, payloadLon: Double? = nil,
        payloadUasId: String? = nil, payloadAircraft: String? = nil, payloadAlt: Double? = nil,
        payloadHeading: Double? = nil, payloadSpeed: Double? = nil, payloadOpLat: Double? = nil,
        payloadOpLon: Double? = nil, payloadTrail: [PayloadFix] = [], gpsTrail: [GpsSample] = [],
        liveDecode: [LiveDecodeChip] = []
    ) {
        self.key = key; self.kind = kind; self.mac = mac; self.name = name; self.fleetIds = fleetIds.distinct()
        self.firstSeen = firstSeen; self.lastSeen = lastSeen; self.hitCount = hitCount; self.rssi = rssi
        self.rssiMin = rssiMin; self.rssiMax = rssiMax; self.channel = channel; self.frequencyMhz = frequencyMhz
        self.randomized = randomized; self.hiddenSsid = hiddenSsid; self.gone = gone
        self.extraAttention = extraAttention; self.payloadLat = payloadLat; self.payloadLon = payloadLon
        self.payloadUasId = payloadUasId; self.payloadAircraft = payloadAircraft; self.payloadAlt = payloadAlt
        self.payloadHeading = payloadHeading; self.payloadSpeed = payloadSpeed; self.payloadOpLat = payloadOpLat
        self.payloadOpLon = payloadOpLon; self.payloadTrail = payloadTrail; self.gpsTrail = gpsTrail
        self.liveDecode = liveDecode
    }

    enum CodingKeys: String, CodingKey {
        case key, kind, mac, name, fleetIds, firstSeen, lastSeen, hitCount, rssi, rssiMin, rssiMax, channel
        case frequencyMhz, randomized, hiddenSsid, gone, extraAttention, payloadLat, payloadLon, payloadUasId
        case payloadAircraft, payloadAlt, payloadHeading, payloadSpeed, payloadOpLat, payloadOpLon, payloadTrail
        case gpsTrail, liveDecode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        kind = try c.decode(RadioKind.self, forKey: .kind)
        mac = try c.decode(String.self, forKey: .mac)
        name = try c.decode(String.self, forKey: .name)
        fleetIds = (try c.decode(.fleetIds, default: [String]())).distinct()
        firstSeen = try c.decode(Int.self, forKey: .firstSeen)
        lastSeen = try c.decode(Int.self, forKey: .lastSeen)
        hitCount = try c.decode(Int.self, forKey: .hitCount)
        rssi = try c.decode(Int.self, forKey: .rssi)
        rssiMin = try c.decode(Int.self, forKey: .rssiMin)
        rssiMax = try c.decode(Int.self, forKey: .rssiMax)
        channel = try c.decode(.channel, default: 0)
        frequencyMhz = try c.decode(.frequencyMhz, default: 0)
        randomized = try c.decode(.randomized, default: false)
        hiddenSsid = try c.decode(.hiddenSsid, default: false)
        gone = try c.decode(.gone, default: false)
        extraAttention = try c.decode(.extraAttention, default: false)
        payloadLat = try c.opt(.payloadLat)
        payloadLon = try c.opt(.payloadLon)
        payloadUasId = try c.opt(.payloadUasId)
        payloadAircraft = try c.opt(.payloadAircraft)
        payloadAlt = try c.opt(.payloadAlt)
        payloadHeading = try c.opt(.payloadHeading)
        payloadSpeed = try c.opt(.payloadSpeed)
        payloadOpLat = try c.opt(.payloadOpLat)
        payloadOpLon = try c.opt(.payloadOpLon)
        payloadTrail = try c.decode(.payloadTrail, default: [])
        gpsTrail = try c.decode(.gpsTrail, default: [])
        liveDecode = try c.decode(.liveDecode, default: [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(kind, forKey: .kind)
        try c.encode(mac, forKey: .mac)
        try c.encode(name, forKey: .name)
        try c.encode(fleetIds, forKey: .fleetIds)
        try c.encode(firstSeen, forKey: .firstSeen)
        try c.encode(lastSeen, forKey: .lastSeen)
        try c.encode(hitCount, forKey: .hitCount)
        try c.encode(rssi, forKey: .rssi)
        try c.encode(rssiMin, forKey: .rssiMin)
        try c.encode(rssiMax, forKey: .rssiMax)
        try c.encode(channel, forKey: .channel)
        try c.encode(frequencyMhz, forKey: .frequencyMhz)
        try c.encode(randomized, forKey: .randomized)
        try c.encode(hiddenSsid, forKey: .hiddenSsid)
        try c.encode(gone, forKey: .gone)
        try c.encode(extraAttention, forKey: .extraAttention)
        try c.encode(payloadLat, forKey: .payloadLat)
        try c.encode(payloadLon, forKey: .payloadLon)
        try c.encode(payloadUasId, forKey: .payloadUasId)
        try c.encodeIfPresent(payloadAircraft, forKey: .payloadAircraft)
        try c.encodeIfPresent(payloadAlt, forKey: .payloadAlt)
        try c.encodeIfPresent(payloadHeading, forKey: .payloadHeading)
        try c.encodeIfPresent(payloadSpeed, forKey: .payloadSpeed)
        try c.encodeIfPresent(payloadOpLat, forKey: .payloadOpLat)
        try c.encodeIfPresent(payloadOpLon, forKey: .payloadOpLon)
        if payloadTrail.isNotEmpty { try c.encode(payloadTrail, forKey: .payloadTrail) }
        try c.encode(gpsTrail, forKey: .gpsTrail)
        try c.encode(liveDecode, forKey: .liveDecode)
    }

    public func toSighting() -> Sighting {
        Sighting(
            key: key,
            kind: kind,
            mac: mac,
            name: name,
            rssi: rssi,
            rssiMin: rssiMin,
            rssiMax: rssiMax,
            channel: channel,
            frequencyMhz: frequencyMhz,
            vendor: nil,
            randomized: randomized,
            hiddenSsid: hiddenSsid,
            serviceUuids: [],
            manufacturerId: nil,
            manufacturerDataHex: "",
            rawHex: "",
            extras: "",
            firstSeen: firstSeen,
            lastSeen: lastSeen,
            hitCount: hitCount,
            fleetIds: fleetIds,
            rssiHistory: [],
            presence: [PresenceSpan(start: firstSeen, end: gone ? lastSeen : nil)],
            gone: gone,
            gpsTrail: gpsTrail,
            payloadLat: payloadLat,
            payloadLon: payloadLon,
            payloadAlt: payloadAlt,
            payloadOpLat: payloadOpLat,
            payloadOpLon: payloadOpLon,
            payloadUasId: payloadUasId,
            payloadAircraft: payloadAircraft,
            payloadHeading: payloadHeading,
            payloadSpeed: payloadSpeed,
            payloadTrail: payloadTrail,
            liveDecode: liveDecode
        )
    }

    public static func from(device: Sighting, fleets: [Fleet]) -> SitRadio {
        SitRadio(
            key: device.key,
            kind: device.kind,
            mac: device.mac,
            name: device.name,
            fleetIds: device.fleetIds,
            firstSeen: device.firstSeen,
            lastSeen: device.lastSeen,
            hitCount: device.hitCount,
            rssi: device.rssi,
            rssiMin: device.rssiMin,
            rssiMax: device.rssiMax,
            channel: device.channel,
            frequencyMhz: device.frequencyMhz,
            randomized: device.randomized,
            hiddenSsid: device.hiddenSsid,
            gone: device.gone,
            extraAttention: device.attentionNotes(fleets: fleets).isNotEmpty,
            payloadLat: device.payloadLat,
            payloadLon: device.payloadLon,
            payloadUasId: device.payloadUasId,
            payloadAircraft: device.payloadAircraft,
            payloadAlt: device.payloadAlt,
            payloadHeading: device.payloadHeading,
            payloadSpeed: device.payloadSpeed,
            payloadOpLat: device.payloadOpLat,
            payloadOpLon: device.payloadOpLon,
            payloadTrail: AircraftTrail.append(trail: [], device: device),
            gpsTrail: trailSample(device: device),
            liveDecode: device.liveDecode
        )
    }

    public static func trailSample(device: Sighting) -> [GpsSample] {
        let fromDevice = Geo.capSpread(samples: device.gpsTrail, cap: Sit.TRAIL_CAP)
        guard let lat = device.latitude, let lon = device.longitude else { return fromDevice }
        let pin = GpsSample(at: device.lastSeen, lat: lat, lon: lon, rssi: device.rssi)
        if fromDevice.any({ $0.at == pin.at }) { return fromDevice }
        return Geo.capSpread(samples: fromDevice + [pin], cap: Sit.TRAIL_CAP)
    }
}

public struct SitFile: Codable, Hashable, Sendable {
    public var format: String
    public var formatVersion: Int
    public var summary: SitSummary
    public var radios: [SitRadio]
    public var operatorPath: [GpsSample]
    public var floods: [FloodBurst]
    public var gnss: [GnssMark]

    public init(
        format: String = Sit.FORMAT, formatVersion: Int = Sit.FORMAT_VERSION, summary: SitSummary,
        radios: [SitRadio] = [], operatorPath: [GpsSample] = [], floods: [FloodBurst] = [], gnss: [GnssMark] = []
    ) {
        self.format = format; self.formatVersion = formatVersion; self.summary = summary; self.radios = radios
        self.operatorPath = operatorPath; self.floods = floods; self.gnss = gnss
    }

    enum CodingKeys: String, CodingKey { case format, formatVersion, summary, radios, operatorPath, floods, gnss }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(.format, default: Sit.FORMAT)
        formatVersion = try c.decode(.formatVersion, default: Sit.FORMAT_VERSION)
        summary = try c.decode(SitSummary.self, forKey: .summary)
        radios = try c.decode(.radios, default: [])
        operatorPath = try c.decode(.operatorPath, default: [])
        floods = try c.decode(.floods, default: [])
        gnss = try c.decode(.gnss, default: [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(summary, forKey: .summary)
        try c.encode(radios, forKey: .radios)
        try c.encode(operatorPath, forKey: .operatorPath)
        try c.encode(floods, forKey: .floods)
        try c.encode(gnss, forKey: .gnss)
    }
}

public struct SitUi: Hashable, Sendable {
    public var open: SitSummary?
    public var radioCount: Int
    public var atCap: Bool
    public var memoryTight: Bool
    public var closed: [SitSummary]
    public var selectedId: String?
    public var compareId: String?
    public var notice: String?

    public init(
        open: SitSummary? = nil, radioCount: Int = 0, atCap: Bool = false, memoryTight: Bool = false,
        closed: [SitSummary] = [], selectedId: String? = nil, compareId: String? = nil, notice: String? = nil
    ) {
        self.open = open; self.radioCount = radioCount; self.atCap = atCap; self.memoryTight = memoryTight
        self.closed = closed; self.selectedId = selectedId; self.compareId = compareId; self.notice = notice
    }
}

public struct SitDebrief: Hashable, Sendable {
    public var name: String
    public var startAt: Int
    public var endAt: Int
    public var devices: [Sighting]
    public var operatorPath: [GpsSample]
    public var floods: [FloodBurst]
    public var gnss: [GnssMark]

    public init(
        name: String, startAt: Int, endAt: Int, devices: [Sighting], operatorPath: [GpsSample],
        floods: [FloodBurst] = [], gnss: [GnssMark] = []
    ) {
        self.name = name; self.startAt = startAt; self.endAt = endAt; self.devices = devices
        self.operatorPath = operatorPath; self.floods = floods; self.gnss = gnss
    }
}

public struct DebriefWindow: Hashable, Sendable {
    public var startAt: Int
    public var endAt: Int
    public var sitName: String?

    public init(startAt: Int, endAt: Int, sitName: String? = nil) {
        self.startAt = startAt; self.endAt = endAt; self.sitName = sitName
    }

    public var durationMs: Int { (endAt - startAt).coerceAtLeast(1) }
}

public final class SitSession {
    public private(set) var summary: SitSummary
    /// Kotlin LinkedHashMap: insertion order in `radioOrder`, rows in `radioRows`.
    private var radioOrder: [String] = []
    private var radioRows: [String: SitRadio] = [:]
    private var path: [GpsSample]
    private var floods: [FloodBurst]
    private var gnss: [GnssMark]
    public private(set) var dirty: Bool = false

    public init(
        summary: SitSummary,
        radios: [SitRadio] = [],
        path: [GpsSample] = [],
        floods: [FloodBurst] = [],
        gnss: [GnssMark] = []
    ) {
        self.summary = summary
        self.path = path
        self.floods = floods
        self.gnss = gnss
        for r in radios { put(r) }
    }

    private func put(_ row: SitRadio) {
        if radioRows[row.key] == nil { radioOrder.append(row.key) }
        radioRows[row.key] = row
    }

    private func remove(_ key: String) {
        if radioRows.removeValue(forKey: key) != nil {
            if let i = radioOrder.firstIndex(of: key) { radioOrder.remove(at: i) }
        }
    }

    private var radioValues: [SitRadio] { radioOrder.map { radioRows[$0]! } }

    public var open: Bool { summary.open }
    public var radioCount: Int { radioRows.count }
    public var atCap: Bool { radioRows.count >= Sit.RADIO_CAP }
    public var operatorPath: [GpsSample] { path }

    public func markClean() {
        dirty = false
    }

    public func snapshot(fleets: [Fleet] = []) -> SitFile {
        let values = radioValues
        let extra = values.count { $0.extraAttention }
        var sum = summary
        sum.radioCount = values.count
        sum.extraAttentionCount = extra
        summary = sum
        return SitFile(
            summary: sum,
            radios: values,
            operatorPath: path,
            floods: floods,
            gnss: gnss
        )
    }

    /// Copy GNSS hits that started during this sit. The same start time updates in place.
    public func noteGnss(incoming: [GnssMark]) {
        if !open || incoming.isEmpty { return }
        let start = summary.startAt
        var changed = false
        for mark in incoming {
            if mark.at < start && (mark.endedAt <= 0 || mark.endedAt < start) { continue }
            let index = gnss.indexOfFirst { $0.at == mark.at && $0.kind == mark.kind }
            if index < 0 {
                gnss.append(mark)
                changed = true
            } else if gnss[index] != mark {
                gnss[index] = mark
                changed = true
            }
        }
        if gnss.count > 40 {
            gnss.removeFirst(gnss.count - 40)
            changed = true
        }
        if changed { dirty = true }
    }

    /// Copy bursts that started during this sit. The same start time updates in place.
    public func noteFloods(incoming: [FloodBurst]) {
        if !open || incoming.isEmpty { return }
        let start = summary.startAt
        var changed = false
        for burst in incoming {
            if burst.at < start { continue }
            let index = floods.indexOfFirst { $0.at == burst.at && $0.wifi == burst.wifi }
            if index < 0 {
                floods.append(burst)
                changed = true
            } else if floods[index] != burst {
                floods[index] = burst
                changed = true
            }
        }
        if floods.count > 40 {
            floods.removeFirst(floods.count - 40)
            changed = true
        }
        if changed { dirty = true }
    }

    public func sightings() -> [Sighting] { radioValues.map { $0.toSighting() } }

    public func rename(raw: String) -> Bool {
        if !open { return false }
        let next = Sit.clipName(raw: raw)
        if next.isEmpty || next == summary.name { return false }
        summary.name = next
        dirty = true
        return true
    }

    public func end(now: Int, fleets: [Fleet]) -> SitFile {
        summary.endAt = now
        dirty = true
        return snapshot(fleets: fleets)
    }

    @discardableResult
    public func ingest(
        device: Sighting,
        fleets: [Fleet],
        watchDeviceKeys: Set<String>,
        watchedFleetIds: Set<String>,
        tight: Bool = false
    ) -> Bool {
        if !open { return false }
        if let existing = radioRows[device.key] {
            radioRows[device.key] = merge(existing, device, fleets)
            dirty = true
            return true
        }
        let pin = pinned(device, fleets, watchDeviceKeys, watchedFleetIds)
        let full = radioRows.count >= Sit.RADIO_CAP || tight
        if full && !pin {
            evict(fleets, watchDeviceKeys, watchedFleetIds)
            if radioRows.count >= Sit.RADIO_CAP || tight { return false }
        }
        put(SitRadio.from(device: device, fleets: fleets))
        dirty = true
        evict(fleets, watchDeviceKeys, watchedFleetIds)
        return true
    }

    public func seedHeard(
        heard: [Sighting],
        fleets: [Fleet],
        watchDeviceKeys: Set<String>,
        watchedFleetIds: Set<String>
    ) {
        for device in heard {
            if device.gone { continue }
            ingest(device: device, fleets: fleets, watchDeviceKeys: watchDeviceKeys, watchedFleetIds: watchedFleetIds)
        }
    }

    @discardableResult
    public func recordPath(lat: Double, lon: Double, at: Int) -> Bool {
        if !open { return false }
        if let last = path.last {
            if !Geo.hopPlausible(from: last, lat: lat, lon: lon, at: at) { return false }
            let d = Geo.meters(lat1: last.lat, lon1: last.lon, lat2: lat, lon2: lon)
            let dt = at - last.at
            if d < Sit.PATH_MIN_M && dt < Sit.PATH_MIN_MS {
                path[path.count - 1] = GpsSample(at: at, lat: lat, lon: lon)
                dirty = true
                return true
            }
        }
        path.append(GpsSample(at: at, lat: lat, lon: lon))
        if path.count > Sit.PATH_CAP {
            path.removeFirst(path.count - Sit.PATH_CAP)
        }
        dirty = true
        return true
    }

    private func pinned(
        _ device: Sighting,
        _ fleets: [Fleet],
        _ watchDeviceKeys: Set<String>,
        _ watchedFleetIds: Set<String>
    ) -> Bool {
        Sit.pinned(
            key: device.key,
            fleetIds: device.fleetIds,
            payload: device.payloadLat != nil && device.payloadLon != nil,
            extraAttention: device.attentionNotes(fleets: fleets).isNotEmpty,
            watchDeviceKeys: watchDeviceKeys,
            watchedFleetIds: watchedFleetIds
        )
    }

    private func pinnedRadio(
        _ row: SitRadio,
        _ watchDeviceKeys: Set<String>,
        _ watchedFleetIds: Set<String>
    ) -> Bool {
        Sit.pinned(
            key: row.key,
            fleetIds: row.fleetIds,
            payload: row.payloadLat != nil && row.payloadLon != nil,
            extraAttention: row.extraAttention,
            watchDeviceKeys: watchDeviceKeys,
            watchedFleetIds: watchedFleetIds
        )
    }

    private func evict(
        _ fleets: [Fleet],
        _ watchDeviceKeys: Set<String>,
        _ watchedFleetIds: Set<String>
    ) {
        if radioRows.count <= Sit.RADIO_CAP { return }
        func drop(_ predicate: (SitRadio) -> Bool) {
            if radioRows.count <= Sit.RADIO_CAP { return }
            let victims = radioValues.filter(predicate).sortedBy { $0.lastSeen }
            let need = radioRows.count - Sit.RADIO_CAP
            for v in victims.take(need) { remove(v.key) }
        }
        drop { row in
            !pinnedRadio(row, watchDeviceKeys, watchedFleetIds) &&
                row.kind == .ble &&
                row.fleetIds.isEmpty
        }
        drop { row in !pinnedRadio(row, watchDeviceKeys, watchedFleetIds) }
    }

    private func merge(_ old: SitRadio, _ next: Sighting, _ fleets: [Fleet]) -> SitRadio {
        let extra = old.extraAttention || next.attentionNotes(fleets: fleets).isNotEmpty
        let trail = Geo.capSpread(
            samples: (old.gpsTrail + SitRadio.trailSample(device: next))
                .distinctBy { $0.at }
                .sortedBy { $0.at },
            cap: Sit.TRAIL_CAP
        )
        let nextMeasured = Rssi.measured(rssi: next.rssi)
        var out = old
        out.name = next.name.ifBlank(old.name)
        out.fleetIds = (old.fleetIds + next.fleetIds).distinct()
        out.firstSeen = min(old.firstSeen, next.firstSeen)
        out.lastSeen = max(old.lastSeen, next.lastSeen)
        out.hitCount = max(old.hitCount, next.hitCount)
        out.rssi = nextMeasured ? next.rssi : old.rssi
        out.rssiMin = nextMeasured
            ? (Rssi.measured(rssi: old.rssiMin) ? min(old.rssiMin, next.rssi) : next.rssi)
            : old.rssiMin
        out.rssiMax = nextMeasured
            ? (Rssi.measured(rssi: old.rssiMax) ? max(old.rssiMax, next.rssi) : next.rssi)
            : old.rssiMax
        out.channel = next.channel > 0 ? next.channel : old.channel
        out.frequencyMhz = next.frequencyMhz > 0 ? next.frequencyMhz : old.frequencyMhz
        out.randomized = old.randomized || next.randomized
        out.hiddenSsid = old.hiddenSsid || next.hiddenSsid
        out.gone = next.gone
        out.extraAttention = extra
        out.payloadLat = next.payloadLat ?? old.payloadLat
        out.payloadLon = next.payloadLon ?? old.payloadLon
        out.payloadUasId = next.payloadUasId ?? old.payloadUasId
        if next.payloadUasId != nil && next.payloadUasId != old.payloadUasId {
            out.payloadAircraft = next.payloadAircraft
        } else {
            out.payloadAircraft = next.payloadAircraft ?? old.payloadAircraft
        }
        out.payloadAlt = next.payloadAlt ?? old.payloadAlt
        out.payloadHeading = next.payloadHeading ?? old.payloadHeading
        out.payloadSpeed = next.payloadSpeed ?? old.payloadSpeed
        out.payloadOpLat = next.payloadOpLat ?? old.payloadOpLat
        out.payloadOpLon = next.payloadOpLon ?? old.payloadOpLon
        out.payloadTrail = AircraftTrail.append(trail: old.payloadTrail, device: next)
        out.gpsTrail = trail
        out.liveDecode = next.liveDecode.ifEmpty(old.liveDecode)
        return out
    }

    public static func start(
        name: String,
        now: Int,
        heard: [Sighting],
        fleets: [Fleet],
        watchDeviceKeys: Set<String>,
        watchedFleetIds: Set<String>,
        id: String = Sit.newId()
    ) -> SitSession {
        let session = SitSession(
            summary: SitSummary(id: id, name: Sit.resolveName(raw: name, at: now), startAt: now)
        )
        session.seedHeard(heard: heard, fleets: fleets, watchDeviceKeys: watchDeviceKeys, watchedFleetIds: watchedFleetIds)
        session.dirty = true
        return session
    }
}
