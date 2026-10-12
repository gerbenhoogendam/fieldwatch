import Foundation

/// Advertised WGS84 from decode field ids, not the operator's own GPS.
///
/// Canonical ids are `LAT` / `LON`. Stock Remote ID uses those. A custom map
/// with the same ids pins the same way — there is no Remote ID branch.
/// `OP_LAT` / `OP_LON` are the Remote ID *pilot* location and are never the pin.
public struct PayloadLocation: Hashable, Sendable {
    public var lat: Double?
    public var lon: Double?
    public var alt: Double?
    public var opLat: Double?
    public var opLon: Double?
    public var uasId: String?
    public var selfId: String?
    public var headingDeg: Double?
    public var speedMps: Double?
    public var vspeedMps: Double?
    /// Maker from a CTA-2063 serial. Nil when this message did not name one.
    public var aircraft: String?
    /// This message is a Basic ID, including one that clears `aircraft`.
    public var basicId: Bool

    public init(
        lat: Double? = nil, lon: Double? = nil, alt: Double? = nil, opLat: Double? = nil, opLon: Double? = nil,
        uasId: String? = nil, selfId: String? = nil, headingDeg: Double? = nil, speedMps: Double? = nil,
        vspeedMps: Double? = nil, aircraft: String? = nil, basicId: Bool = false
    ) {
        self.lat = lat; self.lon = lon; self.alt = alt; self.opLat = opLat; self.opLon = opLon
        self.uasId = uasId; self.selfId = selfId; self.headingDeg = headingDeg; self.speedMps = speedMps
        self.vspeedMps = vspeedMps; self.aircraft = aircraft; self.basicId = basicId
    }

    public func pin() -> (Double, Double)? {
        PayloadLocation.validCoord(lat: lat, lon: lon) ? (lat!, lon!) : nil
    }

    /// ASTM Remote ID rotates message types. A Basic ID packet has no lat/lon;
    /// keep the last valid Location (and System operator) pair this session.
    /// Basic ID `uas_id` / Self ID stick the same way so TAK can key one aircraft
    /// across BLE address rotation.
    /// A Serial Basic ID can name the maker in `aircraft`. That name sticks across
    /// Location and System. A later Basic ID with no maker clears it. `basicId`
    /// is only for this merge. It is not stored on the radio.
    public func mergeSticky(prev: PayloadLocation?) -> PayloadLocation {
        let p = prev ?? PayloadLocation()
        let nextPin = PayloadLocation.validCoord(lat: lat, lon: lon) ? (lat, lon) : (p.lat, p.lon)
        let nextOp = PayloadLocation.validCoord(lat: opLat, lon: opLon) ? (opLat, opLon) : (p.opLat, p.opLon)
        let nextAlt = alt.flatMap { $0.isFinite ? $0 : nil } ?? p.alt
        let ownAircraft = aircraft.flatMap { $0.isNotBlank ? $0 : nil }
        let nextAircraft = basicId ? ownAircraft : (ownAircraft ?? p.aircraft)
        func fin(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? $0 : nil } }
        return PayloadLocation(
            lat: nextPin.0,
            lon: nextPin.1,
            alt: nextAlt,
            opLat: nextOp.0,
            opLon: nextOp.1,
            uasId: uasId.flatMap { $0.isNotBlank ? $0 : nil } ?? p.uasId,
            selfId: selfId.flatMap { $0.isNotBlank ? $0 : nil } ?? p.selfId,
            headingDeg: fin(headingDeg) ?? p.headingDeg,
            speedMps: fin(speedMps) ?? p.speedMps,
            vspeedMps: fin(vspeedMps) ?? p.vspeedMps,
            aircraft: nextAircraft,
            basicId: basicId || p.basicId
        )
    }

    public static let LAT = "latitude"
    public static let LON = "longitude"
    public static let OP_LAT = "op_lat"
    public static let OP_LON = "op_lon"

    private static let LAT_IDS: Set<String> = ["latitude", "lat"]
    private static let LON_IDS: Set<String> = ["longitude", "lon", "lng"]
    private static let ALT_IDS: Set<String> = ["alt_geo", "altitude", "alt", "hae"]
    private static let OP_LAT_IDS: Set<String> = ["op_lat", "operator_lat"]
    private static let OP_LON_IDS: Set<String> = ["op_lon", "operator_lon"]
    private static let UAS_IDS: Set<String> = ["uas_id", "uasid", "serial"]
    private static let SELF_IDS: Set<String> = ["self_id", "selfid"]
    private static let HEADING_IDS: Set<String> = ["heading", "course"]
    private static let SPEED_IDS: Set<String> = ["speed", "hspeed"]
    private static let VSPEED_IDS: Set<String> = ["vspeed", "vert_speed"]

    public static func fromDecoded(fields: [DecodedFieldValue]) -> PayloadLocation {
        if fields.isEmpty { return PayloadLocation() }
        return PayloadLocation(
            lat: num(fields, LAT_IDS),
            lon: num(fields, LON_IDS),
            alt: num(fields, ALT_IDS),
            opLat: num(fields, OP_LAT_IDS),
            opLon: num(fields, OP_LON_IDS),
            uasId: text(fields, UAS_IDS),
            selfId: text(fields, SELF_IDS),
            headingDeg: num(fields, HEADING_IDS),
            speedMps: num(fields, SPEED_IDS),
            vspeedMps: num(fields, VSPEED_IDS)
        )
    }

    public static func fromSighting(device: Sighting) -> PayloadLocation {
        PayloadLocation(
            lat: device.payloadLat,
            lon: device.payloadLon,
            alt: device.payloadAlt,
            opLat: device.payloadOpLat,
            opLon: device.payloadOpLon,
            uasId: device.payloadUasId,
            selfId: device.payloadSelfId,
            headingDeg: device.payloadHeading,
            speedMps: device.payloadSpeed,
            vspeedMps: device.payloadVspeed,
            aircraft: device.payloadAircraft
        )
    }

    public static func applySticky(device: Sighting, fleets: [Fleet]) -> Sighting {
        let decoded: [DecodedFieldValue] = device.fleetIds.isEmpty ? [] : SignatureFieldDecoder.decodeSighting(device: device, fleets: fleets)
        let fromBytes = OpenDroneId.fromFacts(facts: device.facts)
        if decoded.isEmpty &&
            fromBytes.lat == nil &&
            fromBytes.opLat == nil &&
            fromBytes.uasId == nil &&
            !fromBytes.basicId &&
            device.payloadLat == nil &&
            device.payloadOpLat == nil &&
            device.payloadUasId == nil {
            return device
        }
        let next = fromBytes.mergeSticky(prev: fromDecoded(fields: decoded)).mergeSticky(prev: fromSighting(device: device))
        if next.lat == device.payloadLat &&
            next.lon == device.payloadLon &&
            next.alt == device.payloadAlt &&
            next.opLat == device.payloadOpLat &&
            next.opLon == device.payloadOpLon &&
            next.uasId == device.payloadUasId &&
            next.selfId == device.payloadSelfId &&
            next.headingDeg == device.payloadHeading &&
            next.speedMps == device.payloadSpeed &&
            next.vspeedMps == device.payloadVspeed &&
            next.aircraft == device.payloadAircraft {
            return device
        }
        var d = device
        d.payloadLat = next.lat
        d.payloadLon = next.lon
        d.payloadAlt = next.alt
        d.payloadOpLat = next.opLat
        d.payloadOpLon = next.opLon
        d.payloadUasId = next.uasId
        d.payloadSelfId = next.selfId
        d.payloadHeading = next.headingDeg
        d.payloadSpeed = next.speedMps
        d.payloadVspeed = next.vspeedMps
        d.payloadAircraft = next.aircraft
        return d
    }

    public static func validCoord(lat: Double?, lon: Double?) -> Bool {
        guard let lat, let lon else { return false }
        if !lat.isFinite || !lon.isFinite { return false }
        if lat == 0.0 && lon == 0.0 { return false }
        if !(-90.0...90.0).contains(lat) { return false }
        if !(-180.0...180.0).contains(lon) { return false }
        return true
    }

    private static func num(_ fields: [DecodedFieldValue], _ ids: Set<String>) -> Double? {
        guard let hit = fields.first(where: { ids.contains($0.id.lowercased()) }) else { return nil }
        return hit.number.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func text(_ fields: [DecodedFieldValue], _ ids: Set<String>) -> String? {
        guard let hit = fields.first(where: { ids.contains($0.id.lowercased()) }) else { return nil }
        var s = Substring(hit.display.trim())
        while s.last == "\u{0}" { s.removeLast() }
        return s.isEmpty ? nil : String(s)
    }
}
