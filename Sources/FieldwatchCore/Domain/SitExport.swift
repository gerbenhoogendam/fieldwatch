import Foundation

// Port of domain/SitExport.kt.

/// Share/Save of the selected sit (or last 15 minutes). Not the rotating log.
public enum SitExport {
    public static let CSV_HEADER =
        "kind,mac,name,custom_name,observer_notes,rssi,rssi_min,rssi_max,channel,frequency_mhz," +
        "randomized,hidden,first_seen,last_seen,hits,lat,lon,extra_attention," +
        "signatures,extra_attention_families,mine"

    public static func csv(
        devices: [Sighting],
        radios: LogExportRadios,
        customNames: [String: String],
        observerNotes: [String: String],
        extraKeys: Set<String>,
        fleets: [Fleet] = [],
        mineKeys: Set<String> = []
    ) -> String {
        var s = CSV_HEADER + "\n"
        for d in rows(devices: devices, radios: radios) {
            let pin = hearPoint(d: d)
            s += [
                cell(d.kind.rawValue),
                cell(d.mac),
                cell(d.name),
                cell(customNames[d.key] ?? ""),
                cell(observerNotes[d.key] ?? ""),
                String(d.rssi),
                String(d.rssiMin),
                String(d.rssiMax),
                String(d.channel),
                String(d.frequencyMhz),
                String(d.randomized),
                String(d.hiddenSsid),
                iso(d.firstSeen),
                iso(d.lastSeen),
                String(d.hitCount),
                pin.map { coord($0.lat) } ?? "",
                pin.map { coord($0.lon) } ?? "",
                String(extraKeys.contains(d.key)),
                cell(joinedNames(d, fleets)),
                cell(joinedAttention(d, fleets)),
                String(mineKeys.contains(d.key)),
            ].joined(separator: ",")
            s += "\n"
        }
        return s
    }

    public static func jsonl(
        devices: [Sighting],
        radios: LogExportRadios,
        customNames: [String: String],
        observerNotes: [String: String],
        extraKeys: Set<String>,
        fleets: [Fleet] = [],
        mineKeys: Set<String> = []
    ) -> String {
        var s = ""
        for d in rows(devices: devices, radios: radios) {
            let pin = hearPoint(d: d)
            var obj = LogJsonWriter()
            obj.put("kind", .string(d.kind.rawValue))
            obj.put("mac", .string(d.mac))
            obj.put("name", .string(d.name))
            obj.put("custom_name", .string(customNames[d.key] ?? ""))
            obj.put("observer_notes", .string(observerNotes[d.key] ?? ""))
            obj.put("rssi", .int(d.rssi))
            obj.put("rssi_min", .int(d.rssiMin))
            obj.put("rssi_max", .int(d.rssiMax))
            obj.put("channel", .int(d.channel))
            obj.put("frequency_mhz", .int(d.frequencyMhz))
            obj.put("randomized", .bool(d.randomized))
            obj.put("hidden", .bool(d.hiddenSsid))
            obj.put("first_seen", .string(iso(d.firstSeen)))
            obj.put("last_seen", .string(iso(d.lastSeen)))
            obj.put("hits", .int(d.hitCount))
            if let pin {
                obj.put("lat", .double(pin.lat))
                obj.put("lon", .double(pin.lon))
            } else {
                obj.put("lat", .null)
                obj.put("lon", .null)
            }
            obj.put("extra_attention", .bool(extraKeys.contains(d.key)))
            obj.put("signatures", .string(joinedNames(d, fleets)))
            obj.put("extra_attention_families", .string(joinedAttention(d, fleets)))
            obj.put("mine", .bool(mineKeys.contains(d.key)))
            s += obj.toString() + "\n"
        }
        return s
    }

    public static func mapRadios(devices: [Sighting], radios: LogExportRadios) -> [LogRadio] {
        rows(devices: devices, radios: radios).compactMap { d in
            guard let pin = hearPoint(d: d) else { return nil }
            return LogRadio(
                kind: d.kind,
                mac: d.mac,
                name: d.name,
                vendor: d.vendor,
                manufacturerId: d.manufacturerId,
                manufacturerDataHex: d.manufacturerDataHex,
                serviceUuids: d.serviceUuids,
                vendorIeOuis: [],
                randomized: d.randomized,
                hiddenSsid: d.hiddenSsid,
                rssi: d.rssi,
                firstSeen: d.firstSeen,
                lastSeen: d.lastSeen,
                hits: d.hitCount,
                channel: d.channel,
                frequencyMhz: d.frequencyMhz,
                latitude: pin.lat,
                longitude: pin.lon
            )
        }
    }

    public static func rows(devices: [Sighting], radios: LogExportRadios) -> [Sighting] {
        devices.filter { radios.matches(kind: $0.kind) }
            .sortedWithComparator { a, b in
                let c = compareValues(b.rssi, a.rssi)
                return c != 0 ? c : compareValues(a.mac, b.mac)
            }
    }

    public static func hearPoint(d: Sighting) -> GpsSample? {
        if let loudest = d.gpsTrail.maxByOrNull({ $0.rssi }) { return loudest }
        if let lat = d.latitude, let lon = d.longitude { return GpsSample(at: d.lastSeen, lat: lat, lon: lon, rssi: d.rssi) }
        return nil
    }

    public static func suggestedName(kind: LogExportKind, sitName: String, stamp: String) -> String {
        let slug = KRegex("[^a-z0-9]+").replace(sitName.lowercased(with: Locale(identifier: "en_US")), "-")
            .trim("-")
            .take(24)
            .ifBlank("sit")
        let prefix = kind == .wigle ? "fieldwatch-sit-wigle" : "fieldwatch-sit"
        let ext: String
        switch kind {
        case .logCsv, .wigle: ext = "csv"
        case .logJsonl: ext = "jsonl"
        case .gpx: ext = "gpx"
        case .kml: ext = "kml"
        }
        return "\(prefix)-\(slug)-\(stamp).\(ext)"
    }

    public static func mime(kind: LogExportKind) -> String {
        switch kind {
        case .logCsv, .wigle: return "text/csv"
        case .logJsonl: return "application/x-ndjson"
        case .gpx, .kml: return GeoExport.formatOf(kind: kind)!.mime
        }
    }

    public static func subject(kind: LogExportKind, sitName: String) -> String {
        switch kind {
        case .logCsv: return "Fieldwatch sit \(sitName) (CSV)"
        case .logJsonl: return "Fieldwatch sit \(sitName) (JSON lines)"
        case .gpx: return "Fieldwatch sit \(sitName) (GPX)"
        case .kml: return "Fieldwatch sit \(sitName) (KML)"
        case .wigle: return "Fieldwatch sit \(sitName) (WiGLE CSV)"
        }
    }

    public static func emptyHint(kind: LogExportKind, radios: LogExportRadios) -> String {
        let which: String
        switch radios {
        case .both: which = "radios"
        case .wifi: which = "Wi-Fi radios"
        case .ble: which = "BLE radios"
        }
        if kind == .logCsv || kind == .logJsonl {
            return "No \(which) in this sit."
        }
        return "No GPS-tagged \(which) in this sit. Settings → Tag detections with GPS."
    }

    private static func joinedNames(_ d: Sighting, _ fleets: [Fleet]) -> String {
        if d.fleetIds.isEmpty || fleets.isEmpty { return "" }
        let byId = fleets.associateBy { $0.id }
        return d.fleetIds.compactMap { byId[$0]?.name.trim().nonEmpty }
            .sorted()
            .joined(separator: "; ")
    }

    private static func joinedAttention(_ d: Sighting, _ fleets: [Fleet]) -> String {
        d.attentionNotes(fleets: fleets).map { $0.0 }.joined(separator: "; ")
    }

    private static func cell(_ s: String) -> String { CsvCells.quote(s: s) }

    private static func coord(_ v: Double) -> String { fmt(v, 6) }

    private static func iso(_ ms: Int) -> String { formatMs(ms, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc: true) }
}
