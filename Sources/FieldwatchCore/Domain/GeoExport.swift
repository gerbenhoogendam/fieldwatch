import Foundation

// Port of domain/GeoExport.kt.

/// Drop CR and LF scalars (Kotlin filters UTF-16 units; Swift keeps "\r\n" as one Character).
private func dropLineBreaks(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.filter { $0 != "\n" && $0 != "\r" }))
}

/// Share/save format for Reports → Log. Disk is always CSV; JSON lines is an export.
public enum LogExportKind: String, Codable, CaseIterable, Sendable {
    case logCsv = "LOG_CSV"
    case logJsonl = "LOG_JSONL"
    case gpx = "GPX"
    case kml = "KML"
    case wigle = "WIGLE"

    public var label: String {
        switch self {
        case .logCsv: return "Log file — CSV"
        case .logJsonl: return "Log file — JSON lines"
        case .gpx: return "GPX — GPS Exchange"
        case .kml: return "KML — Google Earth"
        case .wigle: return "WiGLE CSV — wigle.net"
        }
    }
}

public enum LogExportRadios: String, Codable, CaseIterable, Sendable {
    case both = "BOTH"
    case wifi = "WIFI"
    case ble = "BLE"

    public var label: String {
        switch self {
        case .both: return "Both radios"
        case .wifi: return "Wi-Fi only"
        case .ble: return "BLE only"
        }
    }

    public func matches(kind: RadioKind) -> Bool {
        switch self {
        case .both: return true
        case .wifi: return kind == .wifi
        case .ble: return kind == .ble
        }
    }
}

/// GPX / KML / WiGLE of GPS-tagged log radios. Pins are where this Mac heard
/// each radio, not a radio fix.
public enum GeoExport {
    public enum Format: String, CaseIterable, Sendable {
        case gpx = "GPX"
        case kml = "KML"
        case wigle = "WIGLE"

        public var `extension`: String {
            switch self {
            case .gpx: return "gpx"
            case .kml: return "kml"
            case .wigle: return "csv"
            }
        }

        public var mime: String {
            switch self {
            case .gpx: return "application/gpx+xml"
            case .kml: return "application/vnd.google-earth.kml+xml"
            case .wigle: return "text/csv"
            }
        }
    }

    public static func formatOf(kind: LogExportKind) -> Format? {
        switch kind {
        case .logCsv, .logJsonl: return nil
        case .gpx: return .gpx
        case .kml: return .kml
        case .wigle: return .wigle
        }
    }

    public static func render(
        format: Format,
        radios: [LogRadio],
        names: [String: [String]],
        appVersion: String,
        deviceInfo: String,
        onProgress: (_ done: Int, _ total: Int) -> Void = { _, _ in },
        customNames: [String: String] = [:],
        observerNotes: [String: String] = [:],
        track: [GpsSample] = []
    ) -> String {
        let pins = radios.filter { $0.hasPosition }.sortedBy { $0.firstSeen }
        switch format {
        case .gpx: return gpx(pins, names, appVersion, onProgress, customNames, observerNotes, track)
        case .kml: return kml(pins, names, appVersion, onProgress, customNames, observerNotes, track)
        case .wigle: return wigleCsv(pins, appVersion, deviceInfo, onProgress)
        }
    }

    public static func suggestedName(format: Format, stamp: String) -> String {
        "fieldwatch-map-\(stamp).\(format.extension)"
    }

    private static func gpx(
        _ radios: [LogRadio],
        _ names: [String: [String]],
        _ appVersion: String,
        _ onProgress: (Int, Int) -> Void,
        _ customNames: [String: String],
        _ observerNotes: [String: String],
        _ track: [GpsSample]
    ) -> String {
        var s = ""
        s += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<gpx version=\"1.1\" creator=\"Fieldwatch \(xml(appVersion))\""
        s += " xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        let n = radios.count
        for (i, r) in radios.enumerated() {
            s += "  <wpt lat=\"\(coord(r.latitude!))\" lon=\"\(coord(r.longitude!))\">\n"
            s += "    <time>\(iso(r.lastSeen))</time>\n"
            s += "    <name>\(xml(pinName(r, customNames)))</name>\n"
            s += "    <desc>\(xml(pinDesc(r, names, observerNotes)))</desc>\n"
            s += "    <type>\(r.kind.rawValue)</type>\n"
            s += "  </wpt>\n"
            let done = i + 1
            if done == n || done % 250 == 0 { onProgress(done, n) }
        }
        if n == 0 { onProgress(0, 0) }
        if track.count >= 2 {
            s += "  <trk>\n    <name>Operator path</name>\n    <trkseg>\n"
            for p in track {
                s += "      <trkpt lat=\"\(coord(p.lat))\" lon=\"\(coord(p.lon))\">"
                s += "<time>\(iso(p.at))</time></trkpt>\n"
            }
            s += "    </trkseg>\n  </trk>\n"
        }
        s += "</gpx>\n"
        return s
    }

    private static func kml(
        _ radios: [LogRadio],
        _ names: [String: [String]],
        _ appVersion: String,
        _ onProgress: (Int, Int) -> Void,
        _ customNames: [String: String],
        _ observerNotes: [String: String],
        _ track: [GpsSample]
    ) -> String {
        var s = ""
        s += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<kml xmlns=\"http://www.opengis.net/kml/2.2\"><Document>\n"
        s += "  <name>Fieldwatch \(xml(appVersion)) export</name>\n"
        let n = radios.count
        for (i, r) in radios.enumerated() {
            s += "  <Placemark>\n"
            s += "    <name>\(xml(pinName(r, customNames)))</name>\n"
            s += "    <description>\(xml(pinDesc(r, names, observerNotes)))</description>\n"
            s += "    <TimeStamp><when>\(iso(r.lastSeen))</when></TimeStamp>\n"
            s += "    <Point><coordinates>\(coord(r.longitude!)),\(coord(r.latitude!))</coordinates></Point>\n"
            s += "  </Placemark>\n"
            let done = i + 1
            if done == n || done % 250 == 0 { onProgress(done, n) }
        }
        if n == 0 { onProgress(0, 0) }
        if track.count >= 2 {
            s += "  <Placemark>\n    <name>Operator path</name>\n    <LineString><coordinates>"
            s += track.map { "\(coord($0.lon)),\(coord($0.lat))" }.joined(separator: " ")
            s += "</coordinates></LineString>\n  </Placemark>\n"
        }
        s += "</Document></kml>\n"
        return s
    }

    private static func wigleCsv(
        _ radios: [LogRadio],
        _ appVersion: String,
        _ deviceInfo: String,
        _ onProgress: (Int, Int) -> Void
    ) -> String {
        var s = ""
        s += "WigleWifi-1.4,appRelease=Fieldwatch \(csvRaw(appVersion))"
        if deviceInfo.isNotBlank { s += "," + dropLineBreaks(deviceInfo) }
        s += "\n"
        s += "MAC,SSID,AuthMode,FirstSeen,Channel,RSSI,"
        s += "CurrentLatitude,CurrentLongitude,AltitudeMeters,AccuracyMeters,Type\n"
        let n = radios.count
        for (i, r) in radios.enumerated() {
            let type = r.kind == .wifi ? "WIFI" : "BLE"
            s += [
                r.mac.uppercased(with: Locale(identifier: "en_US")),
                CsvCells.quote(s: r.hiddenSsid ? "" : r.name),
                r.kind == .wifi ? "[ESS]" : "",
                wigleTime(r.firstSeen),
                String(r.kind == .wifi ? r.channel : 0),
                String(r.rssi),
                coord(r.latitude!),
                coord(r.longitude!),
                "0",
                "0",
                type,
            ].joined(separator: ",")
            s += "\n"
            let done = i + 1
            if done == n || done % 250 == 0 { onProgress(done, n) }
        }
        if n == 0 { onProgress(0, 0) }
        return s
    }

    private static func pinName(_ r: LogRadio, _ customNames: [String: String] = [:]) -> String {
        if let custom = customNames[r.key]?.trim(), custom.isNotEmpty { return custom }
        if r.hiddenSsid { return "<hidden>" }
        if r.name.isBlank || r.name.equals(r.mac, ignoreCase: true) { return r.mac }
        return r.name
    }

    private static func pinDesc(
        _ r: LogRadio,
        _ names: [String: [String]],
        _ observerNotes: [String: String] = [:]
    ) -> String {
        var parts: [String] = []
        parts.append("\(r.kind.rawValue) \(r.mac)")
        if let v = r.vendor, v.isNotBlank { parts.append(v) }
        if let list = names[r.key], list.isNotEmpty { parts.append(list.joined(separator: ", ")) }
        parts.append("\(r.rssi) dBm")
        if r.channel != 0 { parts.append("ch \(r.channel)") }
        if let obs = observerNotes[r.key]?.trim(), obs.isNotEmpty { parts.append("Observer: \(obs)") }
        parts.append("Heard at this Mac. Not a radio fix.")
        return parts.joined(separator: " · ")
    }

    private static func xml(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }

    private static func csvRaw(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { $0 != "," && $0 != "\n" && $0 != "\r" }))
    }

    private static func coord(_ v: Double) -> String { fmt(v, 6) }

    private static func iso(_ ms: Int) -> String { formatMs(ms, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc: true) }
    private static func wigleTime(_ ms: Int) -> String { formatMs(ms, "yyyy-MM-dd HH:mm:ss", utc: true) }
}
