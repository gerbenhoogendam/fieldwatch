import Foundation

// Port of domain/TakPublish.kt.
// TakDefaults, TakGnssSend, TakGnssHold and TakFloodSend live in Models.swift (AppSettings needs them).
//
// macOS wording: the user-visible text that named the device running Fieldwatch ("this phone") now says
// "this Mac" (self-marker remarks, GNSS mark remarks). UIDs and CoT types are unchanged so ATAK keeps
// the same markers. `TakUdpPreset.thisPhone` keeps its Kotlin name (raw value "THIS_PHONE").

public enum TakUdpPreset: String, CaseIterable, Sendable {
    case thisPhone = "THIS_PHONE"
    case lanMulticast = "LAN_MULTICAST"
    case custom = "CUSTOM"
}

public struct TakFeedStatus: Hashable, Sendable {
    public var at: Int
    public var sent: Int
    public var gone: Int
    public var onFeed: Int
    public var dest: String
    public var error: String?
    public var paused: Bool
    public var detail: String

    public init(at: Int = 0, sent: Int = 0, gone: Int = 0, onFeed: Int = 0, dest: String = "", error: String? = nil,
                paused: Bool = false, detail: String = "") {
        self.at = at; self.sent = sent; self.gone = gone; self.onFeed = onFeed; self.dest = dest
        self.error = error; self.paused = paused; self.detail = detail
    }
}

public struct TakSent: Hashable, Sendable {
    public var uid: String
    public var deviceKey: String
    public var at: Int
    public var lat: Double
    public var lon: Double
    public var rssi: Int
    /// Last GNSS line sent on the self marker. Empty when that line is off.
    public var note: String
    /// Label last sent for this radio. Nil on the self marker.
    public var face: TakFace?
    /// Stale time last sent. The self marker uses the 2-minute refresh.
    public var staleMs: Int

    public init(uid: String, deviceKey: String, at: Int, lat: Double, lon: Double, rssi: Int = Int.min,
                note: String = "", face: TakFace? = nil, staleMs: Int = TakDefaults.STALE_MS) {
        self.uid = uid; self.deviceKey = deviceKey; self.at = at; self.lat = lat; self.lon = lon; self.rssi = rssi
        self.note = note; self.face = face; self.staleMs = staleMs
    }
}

/// Map label and card for one radio spot. Kept so a departure can be resent without renaming it.
public struct TakFace: Hashable, Sendable {
    public var callsign: String
    public var remarks: String
    public var cotType: String
    public var group: String
    public var role: String
    public var hae: Double
    public var course: Double?
    public var speed: Double?
    public var linkUid: String?
    public var linkType: String?

    public init(callsign: String, remarks: String, cotType: String, group: String, role: String = "Team Member",
                hae: Double = 9999999.0, course: Double? = nil, speed: Double? = nil, linkUid: String? = nil,
                linkType: String? = nil) {
        self.callsign = callsign; self.remarks = remarks; self.cotType = cotType; self.group = group
        self.role = role; self.hae = hae; self.course = course; self.speed = speed
        self.linkUid = linkUid; self.linkType = linkType
    }
}

public enum TakFlood {
    /// The Live flood line, from the moment the flood is detected until it ends.
    public static func line(mode: TakFloodSend, notice: PairingFlood.Notice?) -> String? {
        if mode != .on { return nil }
        return notice?.line().trim().nonBlank
    }
}

public enum TakGnss {
    /// One line for the Fieldwatch heartbeat, or nil when this mode sends nothing.
    /// The line is the same words as the Live banner. No coordinates.
    public static func line(mode: TakGnssSend, notice: GnssNotice?, lives: [GnssLive]) -> String? {
        let active = (notice.map { !$0.ended } ?? false) ? notice!.line.nonBlank : nil
        let ended = (notice?.ended ?? false) ? notice!.line.nonBlank : nil
        let anyLive = lives.isEmpty ? nil : livesBanner(lives)
        switch mode {
        case .off: return nil
        case .alert: return active
        case .redLine: return active ?? ended
        case .any: return active ?? anyLive
        }
    }

    /// Under this span the mark stays a pin at the first fix.
    public static let SPAN_PIN_M = 100.0

    public static let CALLOUT = "Possible GNSS interference"

    /// Pin at the start, or an oval whose tips are the start and the latest fix.
    /// The full width is half the length. `TakGnssPlot.semiMajorM` is center to tip.
    public static func plot(startLat: Double, startLon: Double, endLat: Double, endLon: Double) -> TakGnssPlot {
        let span = Geo.meters(lat1: startLat, lon1: startLon, lat2: endLat, lon2: endLon)
        if span < SPAN_PIN_M {
            return TakGnssPlot(pin: true, lat: startLat, lon: startLon)
        }
        let (lat, lon) = Geo.midpoint(lat1: startLat, lon1: startLon, lat2: endLat, lon2: endLon)
        return TakGnssPlot(
            pin: false,
            lat: lat,
            lon: lon,
            semiMajorM: span / 2.0,
            semiMinorM: span / 4.0,
            angleDeg: Geo.bearingDegrees(lat1: startLat, lon1: startLon, lat2: endLat, lon2: endLon)
        )
    }

    /// True while the hit is still on. The 10-minute ended line does not grow the mark.
    public static func growing(mode: TakGnssSend, notice: GnssNotice?, lives: [GnssLive]) -> Bool {
        if mode == .off || notice?.ended == true { return false }
        if notice?.line.isNotBlank == true { return true }
        return mode == .any && lives.isNotEmpty
    }

    public static func remarks(notice: GnssNotice?, lives: [GnssLive]) -> String {
        let line = (notice?.line.trim() ?? "").ifBlank(lives.isEmpty ? CALLOUT : livesBanner(lives))
        return "\(line)\nWhere this Mac was. Not the source."
    }

    /// Kotlin `GnssCopy.banner(lives.map { it.kind }.toSet(), lives.maxOf { it.confidence })`.
    private static func livesBanner(_ lives: [GnssLive]) -> String {
        let rank: (GnssConfidence) -> Int = { GnssConfidence.allCases.firstIndex(of: $0) ?? 0 }
        let top = lives.map { $0.confidence }.max { rank($0) < rank($1) }!
        return GnssCopy.banner(kinds: Set(lives.map { $0.kind }), confidence: top)
    }

    /// One step of the map mark. `open` is the episode still growing, or nil.
    /// A closed episode is left for the caller to keep until GNSS TAK is turned off.
    /// `hasMarks` nil means Kotlin's default, `open != null`.
    public static func plan(
        open: TakGnssTrack?,
        mode: TakGnssSend,
        notice: GnssNotice?,
        lives: [GnssLive],
        lat: Double?,
        lon: Double?,
        now: Int,
        hold: TakGnssHold,
        hasMarks: Bool? = nil
    ) -> TakGnssAction {
        let hasMarks = hasMarks ?? (open != nil)
        if mode == .off {
            return TakGnssAction(clearAll: hasMarks)
        }
        if !growing(mode: mode, notice: notice, lives: lives) {
            guard let open, open.open else { return TakGnssAction(track: open) }
            let frozen = plot(startLat: open.startLat, startLon: open.startLon, endLat: open.endLat, endLon: open.endLon)
            var track = open
            track.open = false
            track.lastSentAt = now
            track.sentEndLat = open.endLat
            track.sentEndLon = open.endLon
            track.sentPin = frozen.pin
            return TakGnssAction(
                track: track,
                plot: frozen,
                remarks: remarks(notice: notice, lives: lives),
                staleMs: hold.staleMs(),
                send: true
            )
        }
        guard let lat, let lon else { return TakGnssAction(track: open) }
        let firstStart = lives.map { $0.startedWall }.min()
        let key = (firstStart.flatMap { $0 > 0 ? $0 : nil })
            ?? (open.flatMap { $0.open ? $0.episodeKey : nil })
            ?? now
        if let open, open.open, open.episodeKey != key {
            let frozen = plot(startLat: open.startLat, startLon: open.startLon, endLat: open.endLat, endLon: open.endLon)
            var track = open
            track.open = false
            track.lastSentAt = now
            track.sentPin = frozen.pin
            return TakGnssAction(
                track: track,
                plot: frozen,
                remarks: remarks(notice: notice, lives: lives),
                staleMs: hold.staleMs(),
                send: true
            )
        }
        var track: TakGnssTrack
        if let open, open.open {
            track = open
            track.endLat = lat
            track.endLon = lon
        } else {
            track = TakGnssTrack(
                uid: "FIELDWATCH-GNSS-\(key)",
                episodeKey: key,
                startLat: lat,
                startLon: lon,
                endLat: lat,
                endLon: lon,
                open: true
            )
        }
        let drawn = plot(startLat: track.startLat, startLon: track.startLon, endLat: track.endLat, endLon: track.endLon)
        let switching = track.lastSentAt != 0 && track.sentPin && !drawn.pin
        let moved = Geo.meters(lat1: track.sentEndLat, lon1: track.sentEndLon, lat2: lat, lon2: lon) >= TakDefaults.MOVE_M
        let due = track.lastSentAt == 0 || now - track.lastSentAt >= TakDefaults.MIN_INTERVAL_MS
        let send = switching || moved || due
        var stored = track
        if send {
            stored.lastSentAt = now
            stored.sentEndLat = lat
            stored.sentEndLon = lon
            stored.sentPin = drawn.pin
        }
        return TakGnssAction(
            track: stored,
            plot: send ? drawn : nil,
            remarks: remarks(notice: notice, lives: lives),
            staleMs: hold.staleMs(),
            send: send
        )
    }
}

public struct TakGnssPlot: Hashable, Sendable {
    public var pin: Bool
    public var lat: Double
    public var lon: Double
    public var semiMajorM: Double
    public var semiMinorM: Double
    public var angleDeg: Double

    public init(pin: Bool, lat: Double, lon: Double, semiMajorM: Double = 0.0, semiMinorM: Double = 0.0, angleDeg: Double = 0.0) {
        self.pin = pin; self.lat = lat; self.lon = lon
        self.semiMajorM = semiMajorM; self.semiMinorM = semiMinorM; self.angleDeg = angleDeg
    }
}

public struct TakGnssTrack: Hashable, Sendable {
    public var uid: String
    public var episodeKey: Int
    public var startLat: Double
    public var startLon: Double
    public var endLat: Double
    public var endLon: Double
    public var open: Bool
    public var lastSentAt: Int
    public var sentEndLat: Double
    public var sentEndLon: Double
    public var sentPin: Bool

    /// `sentEndLat` / `sentEndLon` nil = Kotlin default (startLat / startLon).
    public init(uid: String, episodeKey: Int, startLat: Double, startLon: Double, endLat: Double, endLon: Double,
                open: Bool, lastSentAt: Int = 0, sentEndLat: Double? = nil, sentEndLon: Double? = nil, sentPin: Bool = true) {
        self.uid = uid; self.episodeKey = episodeKey; self.startLat = startLat; self.startLon = startLon
        self.endLat = endLat; self.endLon = endLon; self.open = open; self.lastSentAt = lastSentAt
        self.sentEndLat = sentEndLat ?? startLat; self.sentEndLon = sentEndLon ?? startLon; self.sentPin = sentPin
    }
}

public struct TakGnssAction: Hashable, Sendable {
    public var track: TakGnssTrack?
    public var plot: TakGnssPlot?
    public var remarks: String
    public var staleMs: Int
    public var send: Bool
    /// GNSS TAK turned off. Drop every mark this feed still knows.
    public var clearAll: Bool

    public init(track: TakGnssTrack? = nil, plot: TakGnssPlot? = nil, remarks: String = "", staleMs: Int = 0,
                send: Bool = false, clearAll: Bool = false) {
        self.track = track; self.plot = plot; self.remarks = remarks; self.staleMs = staleMs
        self.send = send; self.clearAll = clearAll
    }
}

public enum TakHeardHere: String, CaseIterable, Sendable {
    case skip = "SKIP", move = "MOVE", refresh = "REFRESH"
}

public struct TakMarker: Hashable, Sendable {
    public var uid: String
    public var deviceKey: String
    public var lat: Double
    public var lon: Double
    public var advertised: Bool
    public var pilot: Bool
    public var device: Sighting

    public init(uid: String, deviceKey: String, lat: Double, lon: Double, advertised: Bool, pilot: Bool, device: Sighting) {
        self.uid = uid; self.deviceKey = deviceKey; self.lat = lat; self.lon = lon
        self.advertised = advertised; self.pilot = pilot; self.device = device
    }
}

/// Who goes on the TAK/CoT feed and where the pin sits. Pure, so unit tests need no radios.
public enum TakPublish {
    public static func selected(device: Sighting, settings: AppSettings, fleets: [Fleet], watchlist: [WatchTarget]) -> Bool {
        if !settings.takEnabled { return false }
        if settings.demoMode { return false }
        let extra = hasAttention(device: device, fleets: fleets)
        let payload = PayloadLocation.validCoord(lat: device.payloadLat, lon: device.payloadLon)
        let watched = onWatchlist(device: device, watchlist: watchlist)
        let signed = device.fleetIds.isNotEmpty
        if extra && settings.takAttention { return true }
        if payload && settings.takPayloadFix { return true }
        if watched && settings.takWatchlist { return true }
        if signed && settings.takAllSignatures { return true }
        return false
    }

    /// Advertised decode lat/lon win. Otherwise this hear's operator GPS,
    /// and only while GPS tagging is on. GPS off + no payload = no pin.
    /// Heard-here TAK holds the loudest of these (see heardHereAction).
    public static func pin(device: Sighting, settings: AppSettings) -> (Double, Double)? {
        if PayloadLocation.validCoord(lat: device.payloadLat, lon: device.payloadLon) {
            return (device.payloadLat!, device.payloadLon!)
        }
        if !settings.tagLocation { return nil }
        if PayloadLocation.validCoord(lat: device.latitude, lon: device.longitude) {
            return (device.latitude!, device.longitude!)
        }
        return nil
    }

    public static func pilotPin(device: Sighting) -> (Double, Double)? {
        if !PayloadLocation.validCoord(lat: device.payloadOpLat, lon: device.payloadOpLon) { return nil }
        return (device.payloadOpLat!, device.payloadOpLon!)
    }

    public static func eligible(device: Sighting, settings: AppSettings, fleets: [Fleet], watchlist: [WatchTarget]) -> Bool {
        selected(device: device, settings: settings, fleets: fleets, watchlist: watchlist) && pin(device: device, settings: settings) != nil
    }

    public static func advertisedPin(device: Sighting) -> Bool {
        PayloadLocation.validCoord(lat: device.payloadLat, lon: device.payloadLon)
    }

    public static func rank(device: Sighting, fleets: [Fleet], watchlist: [WatchTarget]) -> Int {
        var n = 0
        if hasAttention(device: device, fleets: fleets) { n += 8 }
        if advertisedPin(device: device) { n += 4 }
        if onWatchlist(device: device, watchlist: watchlist) { n += 2 }
        if device.fleetIds.isNotEmpty { n += 1 }
        return n
    }

    public static func shouldEmit(
        lastAt: Int?,
        lastLat: Double?,
        lastLon: Double?,
        now: Int,
        lat: Double,
        lon: Double,
        minIntervalMs: Int = TakDefaults.MIN_INTERVAL_MS,
        moveM: Double = TakDefaults.MOVE_M
    ) -> Bool {
        guard let lastAt, let lastLat, let lastLon else { return true }
        if now - lastAt >= minIntervalMs { return true }
        return Geo.meters(lat1: lastLat, lon1: lastLon, lat2: lat, lon2: lon) >= moveM
    }

    /// Heard-here pins sit on operator GPS. Move only when this hear is
    /// louder than the last send (closer). Weaker hears still refresh the
    /// same lat/lon after minIntervalMs so ATAK does not stale-drop.
    public static func heardHereAction(
        lastAt: Int?,
        lastRssi: Int?,
        now: Int,
        rssi: Int,
        minIntervalMs: Int = TakDefaults.MIN_INTERVAL_MS
    ) -> TakHeardHere {
        guard let lastAt, let lastRssi, lastRssi != Int.min else { return .move }
        if rssi > lastRssi { return .move }
        if now - lastAt >= minIntervalMs { return .refresh }
        return .skip
    }

    public static func hasAttention(device: Sighting, fleets: [Fleet]) -> Bool {
        if device.fleetIds.isEmpty { return false }
        let byId = fleets.associateBy { $0.id }
        return device.fleetIds.contains { id in byId[id]?.attentionNote.isNotBlank == true }
    }

    public static func onWatchlist(device: Sighting, watchlist: [WatchTarget]) -> Bool {
        watchlist.contains { target in
            if let key = target.deviceKey { return key == device.key && target.alert }
            if let fleetId = target.fleetId { return device.fleetIds.contains(fleetId) }
            return false
        }
    }

    public static func callsign(device: Sighting, fleets: [Fleet], watchlist: [WatchTarget]) -> String {
        let advertised = advertisedPin(device: device)
        let base = callsignBase(device, fleets, watchlist, advertised)
        if advertised { return base.take(32) }
        let suffix = " (here)"
        return (base.take((32 - suffix.count).coerceAtLeast(1)) + suffix).take(32)
    }

    public static func pilotCallsign(device: Sighting) -> String {
        let id = device.payloadUasId?.trim().nonEmpty ?? device.payloadSelfId?.trim().nonEmpty
        if let id { return "Pilot · \(id.take(20))".take(32) }
        return "Pilot".take(32)
    }

    public static func markers(device: Sighting, settings: AppSettings, fleets: [Fleet], watchlist: [WatchTarget]) -> [TakMarker] {
        if device.gone { return [] }
        if !selected(device: device, settings: settings, fleets: fleets, watchlist: watchlist) { return [] }
        guard let aircraft = pin(device: device, settings: settings) else { return [] }
        let advertised = advertisedPin(device: device)
        var out: [TakMarker] = []
        out.append(TakMarker(
            uid: CotEvent.uid(device: device),
            deviceKey: device.key,
            lat: aircraft.0,
            lon: aircraft.1,
            advertised: advertised,
            pilot: false,
            device: device
        ))
        if advertised, let pilot = pilotPin(device: device) {
            out.append(TakMarker(
                uid: CotEvent.pilotUid(device: device),
                deviceKey: device.key,
                lat: pilot.0,
                lon: pilot.1,
                advertised: true,
                pilot: true,
                device: device
            ))
        }
        return out
    }

    /// UIDs that must stay on ATAK this tick. Includes every eligible marker, not only
    /// the 24 we send — missing the cap is not gone. Selected radios with no pin this
    /// tick (GPS blip) keep whatever we already sent for that device key.
    /// Returned in insertion order is not guaranteed (Kotlin LinkedHashSet; only membership is used).
    public static func keepUids(
        devices: [Sighting],
        settings: AppSettings,
        fleets: [Fleet],
        watchlist: [WatchTarget],
        previous: [TakSent],
        selfUid: String? = nil,
        selfOk: Bool = false
    ) -> Set<String> {
        var byKey: [String: [TakSent]] = [:]
        for sent in previous { byKey[sent.deviceKey, default: []].append(sent) }
        var keep = Set<String>()
        if selfOk, let selfUid { keep.insert(selfUid) }
        for device in devices {
            if device.gone { continue }
            if !selected(device: device, settings: settings, fleets: fleets, watchlist: watchlist) { continue }
            let next = markers(device: device, settings: settings, fleets: fleets, watchlist: watchlist)
            if next.isNotEmpty {
                next.forEach { keep.insert($0.uid) }
            } else if settings.tagLocation {
                byKey[device.key]?.forEach { keep.insert($0.uid) }
            }
        }
        return keep
    }

    public static func udpPreset(host: String, port: Int) -> TakUdpPreset {
        let h = host.trim()
        if h == TakDefaults.LOOPBACK && port == TakDefaults.PORT { return .thisPhone }
        if (h == TakDefaults.SA_HOST || h == TakDefaults.HOST) && port == TakDefaults.SA_PORT { return .lanMulticast }
        return .custom
    }

    public static func applyPreset(preset: TakUdpPreset) -> (String, Int) {
        switch preset {
        case .thisPhone: return (TakDefaults.LOOPBACK, TakDefaults.PORT)
        case .lanMulticast: return (TakDefaults.SA_HOST, TakDefaults.SA_PORT)
        case .custom: return (TakDefaults.HOST, TakDefaults.PORT)
        }
    }

    private static func callsignBase(_ device: Sighting, _ fleets: [Fleet], _ watchlist: [WatchTarget], _ advertised: Bool) -> String {
        if let label = watchlist.first(where: { $0.deviceKey == device.key })?.label.trim().nonEmpty {
            return label.take(32)
        }
        if advertised {
            if let s = device.payloadSelfId?.trim().nonEmpty { return s.take(32) }
            if let s = device.payloadUasId?.trim().nonEmpty { return s.take(32) }
        }
        let byId = fleets.associateBy { $0.id }
        if let id = device.fleetIds.first(where: { byId[$0]?.attentionNote.isNotBlank == true }),
           let name = byId[id]?.name.trim().nonEmpty {
            return name.take(32)
        }
        if let id = device.fleetIds.first, let name = byId[id]?.name.trim().nonEmpty {
            return name.take(32)
        }
        let advertisedName = device.name.trim()
        if advertisedName.isNotEmpty && !advertisedName.equals(device.mac, ignoreCase: true) {
            return advertisedName.take(32)
        }
        return device.mac.takeLast(8)
    }
}

/// Cursor-on-Target XML. Element and attribute order, number and time formats match the Android build.
public enum CotEvent {
    private static let SELF_UID = "FIELDWATCH-SELF"

    public static func uid(device: Sighting) -> String {
        if let id = stableId(raw: device.payloadUasId) { return "FIELDWATCH-RID-\(id)" }
        let mac = MacUtil.normalize(raw: device.mac).replace(":", "")
        return "FIELDWATCH-\(device.kind.rawValue)-\(mac)"
    }

    public static func pilotUid(device: Sighting) -> String {
        if let id = stableId(raw: device.payloadUasId) { return "FIELDWATCH-PILOT-\(id)" }
        let mac = MacUtil.normalize(raw: device.mac).replace(":", "")
        return "FIELDWATCH-PILOT-\(device.kind.rawValue)-\(mac)"
    }

    public static func selfUid() -> String { SELF_UID }

    public static func stableId(raw: String?) -> String? {
        guard let raw else { return nil }
        var trimmed = raw.trim()
        while trimmed.hasSuffix("\u{0000}") { trimmed.removeLast() }
        var cleaned = ""
        for ch in trimmed {
            if ch.isLetterOrDigit || ch == "-" || ch == "_" || ch == "." {
                cleaned.append(ch)
            } else if ch == " " {
                cleaned.append("-")
            }
        }
        let out = cleaned.take(24)
        return out.count >= 4 ? out : nil
    }

    public static func type(device: Sighting, fleets: [Fleet], advertised: Bool, pilot: Bool = false) -> String {
        if pilot { return "a-u-G" }
        if advertised && fleets.contains(where: { device.fleetIds.contains($0.id) && $0.kind == .drone }) {
            return "a-u-A-M-H-Q"
        }
        return "a-u-G"
    }

    public static func group(device: Sighting, fleets: [Fleet], advertised: Bool, pilot: Bool = false) -> String {
        if pilot { return "Orange" }
        if advertised && fleets.contains(where: { device.fleetIds.contains($0.id) && $0.kind == .drone }) {
            return "Yellow"
        }
        if !advertised && TakPublish.hasAttention(device: device, fleets: fleets) { return "Maroon" }
        return "Cyan"
    }

    public static func face(device: Sighting, fleets: [Fleet], watchlist: [WatchTarget], advertised: Bool, pilot: Bool = false) -> TakFace {
        let linkUid: String?
        if pilot { linkUid = uid(device: device) }
        else if advertised && TakPublish.pilotPin(device: device) != nil { linkUid = pilotUid(device: device) }
        else { linkUid = nil }
        let linkType: String?
        if linkUid == nil { linkType = nil }
        else if pilot { linkType = type(device: device, fleets: fleets, advertised: advertised, pilot: false) }
        else { linkType = type(device: device, fleets: fleets, advertised: advertised, pilot: true) }
        let alt = device.payloadAlt.flatMap { $0.isFinite ? $0 : nil }
        let heading = device.payloadHeading.flatMap { $0.isFinite ? $0 : nil }
        let speed = device.payloadSpeed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return TakFace(
            callsign: pilot ? TakPublish.pilotCallsign(device: device)
                : TakPublish.callsign(device: device, fleets: fleets, watchlist: watchlist),
            remarks: remarks(device: device, fleets: fleets, advertised: advertised, pilot: pilot, watchlist: watchlist),
            cotType: type(device: device, fleets: fleets, advertised: advertised, pilot: pilot),
            group: group(device: device, fleets: fleets, advertised: advertised, pilot: pilot),
            hae: pilot ? 9999999.0 : (alt ?? 9999999.0),
            course: (advertised && !pilot) ? heading : nil,
            speed: (advertised && !pilot) ? speed : nil,
            linkUid: linkUid,
            linkType: linkType
        )
    }

    public static func xml(
        device: Sighting,
        fleets: [Fleet],
        watchlist: [WatchTarget],
        lat: Double,
        lon: Double,
        advertised: Bool,
        now: Int,
        staleMs: Int = TakDefaults.STALE_MS,
        pilot: Bool = false
    ) -> String {
        render(
            uid: pilot ? pilotUid(device: device) : uid(device: device),
            face: face(device: device, fleets: fleets, watchlist: watchlist, advertised: advertised, pilot: pilot),
            lat: lat,
            lon: lon,
            now: now,
            staleMs: staleMs
        )
    }

    /// Same spot again. `staleMs` is how long ATAK keeps it from `now`.
    public static func render(uid: String, face: TakFace, lat: Double, lon: Double, now: Int, staleMs: Int, staleNow: Bool = false) -> String {
        eventXml(
            uid: uid,
            cotType: face.cotType,
            lat: lat,
            lon: lon,
            hae: face.hae,
            course: face.course,
            speed: face.speed,
            callsign: xmlEscape(raw: face.callsign),
            remarks: xmlEscape(raw: face.remarks),
            group: face.group,
            now: now,
            staleMs: staleMs,
            staleNow: staleNow,
            linkUid: face.linkUid,
            linkType: face.linkType,
            role: face.role
        )
    }

    public static func gnssPinXml(uid: String, lat: Double, lon: Double, now: Int, staleMs: Int, remarks: String) -> String {
        eventXml(
            uid: uid,
            cotType: "b-m-p-s-m",
            lat: lat,
            lon: lon,
            hae: 9999999.0,
            callsign: TakGnss.CALLOUT,
            remarks: xmlEscape(raw: remarks),
            group: "Magenta",
            now: now,
            staleMs: staleMs,
            staleNow: false,
            linkUid: nil,
            linkType: nil,
            role: "Team Member"
        )
    }

    public static func gnssOvalXml(
        uid: String,
        lat: Double,
        lon: Double,
        semiMajorM: Double,
        semiMinorM: Double,
        angleDeg: Double,
        now: Int,
        staleMs: Int,
        remarks: String
    ) -> String {
        var extra = ""
        extra += "<shape><ellipse major=\"\(num(semiMajorM))\" minor=\"\(num(semiMinorM))\" "
        extra += "angle=\"\(num(angleDeg))\"/></shape>"
        extra += "<strokeColor value=\"-65281\"/>"
        extra += "<strokeWeight value=\"3.0\"/>"
        extra += "<fillColor value=\"1090453759\"/>"
        extra += "<labels_on value=\"true\"/>"
        return eventXml(
            uid: uid,
            cotType: "u-d-c-e",
            lat: lat,
            lon: lon,
            hae: 9999999.0,
            callsign: TakGnss.CALLOUT,
            remarks: xmlEscape(raw: remarks),
            group: "Magenta",
            now: now,
            staleMs: staleMs,
            staleNow: false,
            linkUid: nil,
            linkType: nil,
            role: "Team Member",
            extraDetail: extra
        )
    }

    public static func tombstoneXml(
        uid: String,
        lat: Double,
        lon: Double,
        now: Int,
        callsign: String = "Fieldwatch",
        remarks: String = "Fieldwatch · gone"
    ) -> String {
        eventXml(
            uid: uid,
            cotType: "a-u-G",
            lat: lat,
            lon: lon,
            hae: 9999999.0,
            callsign: xmlEscape(raw: callsign),
            remarks: xmlEscape(raw: remarks),
            group: "Cyan",
            now: now,
            staleMs: 0,
            staleNow: true,
            linkUid: nil,
            linkType: nil
        )
    }

    public static func selfXml(lat: Double, lon: Double, now: Int, staleMs: Int = TakDefaults.STALE_MS, remarksExtra: String? = nil) -> String {
        var remarks = "Fieldwatch TAK heartbeat (this Mac)"
        let extra = remarksExtra?.trim() ?? ""
        if extra.isNotEmpty {
            remarks += "\n"
            remarks += extra
        }
        remarks = remarks.take(TakDefaults.REMARKS_MAX)
        return eventXml(
            uid: SELF_UID,
            cotType: "a-f-G-U-C",
            lat: lat,
            lon: lon,
            hae: 9999999.0,
            callsign: "Fieldwatch",
            remarks: xmlEscape(raw: remarks),
            group: "Cyan",
            now: now,
            staleMs: staleMs,
            staleNow: false,
            linkUid: nil,
            linkType: nil,
            role: "Team Member"
        )
    }

    public static func remarks(
        device: Sighting,
        fleets: [Fleet],
        advertised: Bool,
        pilot: Bool = false,
        watchlist: [WatchTarget] = []
    ) -> String {
        let callsign = pilot ? TakPublish.pilotCallsign(device: device)
            : TakPublish.callsign(device: device, fleets: fleets, watchlist: watchlist)
        let names = fleets.filter { device.fleetIds.contains($0.id) }.map { $0.name }.distinct()
        let kind = device.kind == .wifi ? "Wi-Fi" : "BLE"
        let whereText: String
        if pilot { whereText = "operator (pilot) position" }
        else if advertised { whereText = "advertised position" }
        else { whereText = "heard here (operator GPS)" }
        var radio = "\(kind)  \(device.mac)  \(device.rssi) dBm"
        if device.kind == .wifi && device.channel > 0 {
            radio += "  ch \(device.channel)"
        } else if device.kind == .wifi && device.frequencyMhz > 0 {
            radio += "  \(device.frequencyMhz) MHz"
        }
        let advertisedName = device.name.trim()
        let showName = advertisedName.isNotEmpty &&
            !advertisedName.equals(device.mac, ignoreCase: true) &&
            !callsign.contains(advertisedName, ignoreCase: true)
        let uas = device.payloadUasId?.trim().nonEmpty
        let sigLine = names.take(3).filter { !callsign.contains($0, ignoreCase: true) }.joined(separator: ", ")
        let extra = device.attentionNotes(fleets: fleets).first
        var s = ""
        s += callsign
        s += "\n"
        s += radio
        s += "\n"
        s += whereText
        if let uas {
            s += " · UAS ID "
            s += uas.take(24)
        }
        if showName {
            s += "\n"
            s += advertisedName.take(32)
        }
        if sigLine.isNotEmpty {
            s += "\n"
            s += sigLine
        }
        if let extra {
            let (name, note) = extra
            s += "\n"
            s += "Extra attention"
            if !callsign.contains(name, ignoreCase: true) && !sigLine.contains(name, ignoreCase: true) {
                s += " ("
                s += name
                s += ")"
            }
            s += ": "
            s += note.take(120)
        }
        return s.trimEnd().take(TakDefaults.REMARKS_MAX)
    }

    private static func eventXml(
        uid: String,
        cotType: String,
        lat: Double,
        lon: Double,
        hae: Double,
        course: Double? = nil,
        speed: Double? = nil,
        callsign: String,
        remarks: String,
        group: String,
        now: Int,
        staleMs: Int,
        staleNow: Bool,
        linkUid: String?,
        linkType: String?,
        role: String = "Team Member",
        extraDetail: String = ""
    ) -> String {
        let t = cotTime(now)
        let stale = cotTime(staleNow ? now : now + staleMs)
        var s = ""
        s += "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        s += "<event version=\"2.0\" uid=\"\(xmlEscape(raw: uid))\" type=\"\(cotType)\" "
        s += "time=\"\(t)\" start=\"\(t)\" stale=\"\(stale)\" how=\"m-g\">"
        s += "<point lat=\"\(num(lat))\" lon=\"\(num(lon))\" hae=\"\(num(hae))\" "
        s += "ce=\"9999999\" le=\"9999999\"/>"
        s += "<detail>"
        s += "<contact callsign=\"\(callsign)\"/>"
        s += "<__group name=\"\(group)\" role=\"\(role)\"/>"
        if let linkUid, let linkType {
            s += "<link uid=\"\(xmlEscape(raw: linkUid))\" type=\"\(linkType)\" relation=\"p-p\"/>"
        }
        if course != nil || speed != nil {
            let c = course ?? 0.0
            let v = speed ?? 0.0
            s += "<track course=\"\(num(c))\" speed=\"\(num(v))\"/>"
        }
        s += "<remarks>\(remarks)</remarks>"
        s += extraDetail
        s += "</detail>"
        s += "</event>"
        return s
    }

    private static let secondsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
    private static let formatterLock = NSLock()

    /// java.time `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` in UTC. Milliseconds are written from the integer
    /// so DateFormatter's fractional-second rounding never shifts them.
    static func cotTime(_ ms: Int) -> String {
        let sec = ms >= 0 ? ms / 1000 : -((-ms + 999) / 1000)
        let milli = ms - sec * 1000
        formatterLock.lock()
        let base = secondsFormatter.string(from: Date(timeIntervalSince1970: Double(sec)))
        formatterLock.unlock()
        return base + "." + String(milli).padStart(3, "0") + "Z"
    }

    /// Kotlin `"%.7f".format(Locale.US, n).trimEnd('0').trimEnd('.')`; non-finite is "9999999".
    static func num(_ n: Double) -> String {
        if !n.isFinite { return "9999999" }
        var s = javaFixed(n, decimals: 7)
        while s.hasSuffix("0") { s.removeLast() }
        while s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// java.util.Formatter `%.Nf`: rounds HALF_UP on the shortest round-trip decimal digits of the
    /// double (C printf rounds the exact binary value instead, which can differ on ties).
    static func javaFixed(_ x: Double, decimals: Int) -> String {
        let negative = x.sign == .minus
        // Swift's description is the shortest round-trip form, e.g. "40.0", "1e-05", "1.5e+16".
        let text = "\(abs(x))"
        var mantissa = text
        var exp = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(text[..<e])
            exp = Int(text[text.index(after: e)...]) ?? 0
        }
        let intPart = mantissa.substringBefore(".")
        let fracPart = mantissa.contains(".") ? mantissa.substringAfter(".") : ""
        var digits = Array(intPart + fracPart).map { Int($0.asciiValue! - 48) }
        var point = intPart.count + exp // digits before the decimal point
        // Normalise so there is at least one integer digit and enough fraction digits.
        if point <= 0 {
            digits = Array(repeating: 0, count: 1 - point) + digits
            point = 1
        }
        if digits.count < point { digits += Array(repeating: 0, count: point - digits.count) }
        let want = point + decimals
        if digits.count > want {
            let roundUp = digits[want] >= 5
            digits = Array(digits[0..<want])
            if roundUp {
                var i = want - 1
                while i >= 0 {
                    if digits[i] == 9 { digits[i] = 0; i -= 1 } else { digits[i] += 1; break }
                }
                if i < 0 { digits.insert(1, at: 0); point += 1 }
            }
        } else if digits.count < want {
            digits += Array(repeating: 0, count: want - digits.count)
        }
        var intDigits = digits[0..<point].map(String.init).joined()
        while intDigits.count > 1 && intDigits.hasPrefix("0") { intDigits.removeFirst() }
        let fracDigits = digits[point...].map(String.init).joined()
        let body = decimals > 0 ? "\(intDigits).\(fracDigits)" : intDigits
        return negative ? "-" + body : body
    }

    public static func xmlEscape(raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count + 8)
        for ch in raw.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\n": out += "&#10;"
            case "\r": break
            default: if ch.value >= 32 { out.unicodeScalars.append(ch) }
            }
        }
        return out
    }
}
