import Foundation

// Port of domain/LogReplay.kt. org.json JSONObject read/write semantics are emulated by
// LogJsonObject / LogJsonWriter below (also used by SitExport.jsonl).

/// One unique radio collapsed from many log rows. Re-match with the current
/// catalog — do not trust the write-time fleets column.
public struct LogRadio: Hashable, Sendable {
    public var kind: RadioKind
    public var mac: String
    public var name: String
    public var vendor: String?
    public var manufacturerId: Int?
    public var manufacturerDataHex: String
    public var serviceUuids: [String]
    public var vendorIeOuis: [String]
    public var randomized: Bool
    public var hiddenSsid: Bool
    public var rssi: Int
    public var firstSeen: Int
    public var lastSeen: Int
    public var hits: Int
    public var channel: Int
    public var frequencyMhz: Int
    public var latitude: Double?
    public var longitude: Double?

    public init(
        kind: RadioKind, mac: String, name: String, vendor: String?, manufacturerId: Int?,
        manufacturerDataHex: String, serviceUuids: [String], vendorIeOuis: [String], randomized: Bool,
        hiddenSsid: Bool, rssi: Int, firstSeen: Int, lastSeen: Int, hits: Int, channel: Int = 0,
        frequencyMhz: Int = 0, latitude: Double? = nil, longitude: Double? = nil
    ) {
        self.kind = kind; self.mac = mac; self.name = name; self.vendor = vendor
        self.manufacturerId = manufacturerId; self.manufacturerDataHex = manufacturerDataHex
        self.serviceUuids = serviceUuids; self.vendorIeOuis = vendorIeOuis; self.randomized = randomized
        self.hiddenSsid = hiddenSsid; self.rssi = rssi; self.firstSeen = firstSeen; self.lastSeen = lastSeen
        self.hits = hits; self.channel = channel; self.frequencyMhz = frequencyMhz
        self.latitude = latitude; self.longitude = longitude
    }

    public var key: String { "\(kind.rawValue):\(mac)" }
    public var hasPosition: Bool { latitude != nil && longitude != nil }
}

/// Split on any of the given single-character delimiters, keeping empty pieces (Kotlin `split(a, b)`).
private func splitAny(_ s: String, _ delims: Set<Unicode.Scalar>) -> [String] {
    var out: [String] = []
    var cur = String.UnicodeScalarView()
    for u in s.unicodeScalars {
        if delims.contains(u) {
            out.append(String(cur))
            cur = String.UnicodeScalarView()
        } else {
            cur.append(u)
        }
    }
    out.append(String(cur))
    return out
}

/// Kotlin `trimEnd('\r')` on scalars.
private func trimEndCR(_ s: String) -> String {
    var v = s.unicodeScalars
    while let l = v.last, l == "\r" { v.removeLast() }
    return String(v)
}

/// Parse rotating / exported Fieldwatch logs into unique radios.
public enum LogReplay {
    public static func parse(text: String) -> [LogRadio] {
        var acc: [String: LogRadio] = [:]
        var order: [String] = []
        let trimmed = text.replace("\u{0000}", "")
        let lines = trimmed.lines()
        let json = lines.map { $0.trim() }.first { $0.isNotEmpty }?.hasPrefix("{") == true
        ingest(lines: lines, json: json, acc: &acc, order: &order)
        return order.map { acc[$0]! }
    }

    /// Kotlin passes a LinkedHashMap. A plain Swift dictionary loses order; use the `order:` overload
    /// to keep first-seen order.
    public static func ingest<S: Sequence>(
        lines: S,
        json: Bool,
        acc: inout [String: LogRadio]
    ) where S.Element == String {
        var order: [String] = []
        ingest(lines: lines, json: json, acc: &acc, order: &order)
    }

    /// Same as Kotlin `ingest`, with first-seen key order appended to `order`.
    public static func ingest<S: Sequence>(
        lines: S,
        json: Bool,
        acc: inout [String: LogRadio],
        order: inout [String]
    ) where S.Element == String {
        var header: [String]? = nil
        for raw in lines {
            let line = trimEndCR(raw.replace("\u{0000}", ""))
            if line.isBlank { continue }
            if json {
                if !line.hasPrefix("{") { continue }
                ingestJson(line, &acc, &order)
                continue
            }
            if header == nil {
                if line.hasPrefix("timestamp") {
                    header = line.split(",")
                    continue
                }
                header = DEFAULT_CSV_HEADER
            }
            ingestCsv(line, header!, &acc, &order)
        }
    }

    private static func ingestCsv(_ line: String, _ header: [String], _ acc: inout [String: LogRadio], _ order: inout [String]) {
        let cols = line.split(",")
        func col(_ name: String) -> String {
            guard let i = header.firstIndex(of: name), i < cols.count else { return "" }
            return cols[i]
        }
        guard let kind = RadioKind(rawValue: col("kind").trim()) else { return }
        let mac = MacUtil.normalize(raw: col("mac"))
        if mac.isBlank { return }
        let flags = col("flags").uppercased()
        let uuids = splitAny(col("uuids"), ["|", ","]).map { $0.trim() }.filter { $0.isNotEmpty }
        let ies = col("vendor_ie").split("|").map { $0.trim() }.filter { $0.isNotEmpty }
            .map { MacUtil.normalize(raw: $0) }
        let mfgRaw = col("mfg").trim()
        let mfg = mfgRaw.toIntOrNull(16) ?? mfgRaw.toIntOrNull()
        let ts = col("timestamp").toLongOrNull() ?? 0
        merge(
            &acc, &order,
            LogRadio(
                kind: kind,
                mac: mac,
                name: col("name").trim(),
                vendor: col("vendor").trim().nonBlank,
                manufacturerId: mfg,
                manufacturerDataHex: col("raw").trim(),
                serviceUuids: uuids,
                vendorIeOuis: ies,
                randomized: flags.contains("RAND") || MacUtil.isRandomized(mac: mac),
                hiddenSsid: flags.contains("HIDDEN"),
                rssi: col("rssi").toIntOrNull() ?? -100,
                firstSeen: ts,
                lastSeen: ts,
                hits: 1,
                channel: col("channel").toIntOrNull() ?? 0,
                frequencyMhz: col("freq").toIntOrNull() ?? 0,
                latitude: col("lat").toDoubleOrNull(),
                longitude: col("lon").toDoubleOrNull()
            )
        )
    }

    private static func ingestJson(_ line: String, _ acc: inout [String: LogRadio], _ order: inout [String]) {
        guard let obj = LogJsonObject(line) else { return }
        func str(_ key: String) -> String { obj.optString(key, "") }
        guard let kind = RadioKind(rawValue: str("kind")) else { return }
        let mac = MacUtil.normalize(raw: str("mac"))
        if mac.isBlank { return }
        let uuids = splitAny(str("uuids"), [",", "|"]).map { $0.trim() }.filter { $0.isNotEmpty }
        let ies = str("vendor_ie").split("|").map { $0.trim() }.filter { $0.isNotEmpty }
            .map { MacUtil.normalize(raw: $0) }
        let mfg: Int?
        if !obj.has("mfg") || obj.isNull("mfg") {
            mfg = nil
        } else {
            let n = obj.optInt("mfg", Int(Int32.min))
            mfg = n != Int(Int32.min) ? n : str("mfg").toIntOrNull(16)
        }
        let ts = obj.optLong("ts", 0)
        let rand = obj.optBoolean("rand", MacUtil.isRandomized(mac: mac))
        merge(
            &acc, &order,
            LogRadio(
                kind: kind,
                mac: mac,
                name: str("name"),
                vendor: str("vendor").nonBlank,
                manufacturerId: mfg,
                manufacturerDataHex: str("raw"),
                serviceUuids: uuids,
                vendorIeOuis: ies,
                randomized: rand,
                hiddenSsid: obj.optBoolean("hidden", false),
                rssi: obj.optInt("rssi", -100),
                firstSeen: ts,
                lastSeen: ts,
                hits: 1,
                channel: obj.optInt("channel", 0),
                frequencyMhz: obj.optInt("freq", 0),
                latitude: (obj.has("lat") && !obj.isNull("lat")) ? obj.optDouble("lat") : nil,
                longitude: (obj.has("lon") && !obj.isNull("lon")) ? obj.optDouble("lon") : nil
            )
        )
    }

    private static func merge(_ acc: inout [String: LogRadio], _ order: inout [String], _ row: LogRadio) {
        guard let prev = acc[row.key] else {
            acc[row.key] = row
            order.append(row.key)
            return
        }
        var out = prev
        out.name = row.name.ifBlank(prev.name)
        out.vendor = row.vendor ?? prev.vendor
        out.manufacturerId = row.manufacturerId ?? prev.manufacturerId
        out.manufacturerDataHex = row.manufacturerDataHex.ifBlank(prev.manufacturerDataHex)
        out.serviceUuids = (prev.serviceUuids + row.serviceUuids).distinct()
        out.vendorIeOuis = (prev.vendorIeOuis + row.vendorIeOuis).distinct()
        out.randomized = prev.randomized || row.randomized
        out.hiddenSsid = prev.hiddenSsid || row.hiddenSsid
        out.rssi = row.rssi
        out.firstSeen = prev.firstSeen == 0 ? row.firstSeen : min(prev.firstSeen, row.firstSeen)
        out.lastSeen = max(prev.lastSeen, row.lastSeen)
        out.hits = prev.hits + row.hits
        out.channel = row.channel != 0 ? row.channel : prev.channel
        out.frequencyMhz = row.frequencyMhz != 0 ? row.frequencyMhz : prev.frequencyMhz
        out.latitude = row.latitude ?? prev.latitude
        out.longitude = row.longitude ?? prev.longitude
        acc[row.key] = out
    }

    /// Kotlin `internal`; public here so LogStore can read it.
    public static let DEFAULT_CSV_HEADER = [
        "timestamp", "iso", "kind", "mac", "name", "rssi", "channel", "freq",
        "oui", "vendor", "fleets", "mfg", "uuids", "flags", "raw", "lat", "lon", "vendor_ie",
    ]

    public static func lineKind(line: String, json: Bool, header: [String] = DEFAULT_CSV_HEADER) -> RadioKind? {
        if json {
            guard let obj = LogJsonObject(line) else { return nil }
            return RadioKind(rawValue: obj.optString("kind", ""))
        }
        let cols = line.split(",")
        guard let i = header.firstIndex(of: "kind"), i < cols.count else { return nil }
        return RadioKind(rawValue: cols[i].trim())
    }

    /// One CSV data line → JSONL object (no trailing newline).
    public static func csvRowToJson(line: String, header: [String] = DEFAULT_CSV_HEADER) -> String? {
        let cols = line.split(",")
        if cols.count < 5 { return nil }
        func col(_ name: String) -> String {
            guard let i = header.firstIndex(of: name), i < cols.count else { return "" }
            return cols[i]
        }
        let kind = col("kind").trim()
        if kind != "WIFI" && kind != "BLE" { return nil }
        let flags = col("flags").uppercased()
        var obj = LogJsonWriter()
        obj.put("ts", .int(col("timestamp").toLongOrNull() ?? 0))
        obj.put("iso", .string(col("iso")))
        obj.put("kind", .string(kind))
        obj.put("mac", .string(col("mac")))
        obj.put("name", .string(col("name")))
        obj.put("rssi", .int(col("rssi").toIntOrNull() ?? -100))
        obj.put("channel", .int(col("channel").toIntOrNull() ?? 0))
        obj.put("freq", .int(col("freq").toIntOrNull() ?? 0))
        obj.put("oui", .string(col("oui")))
        let vendor = col("vendor")
        obj.put("vendor", vendor.isBlank ? .null : .string(vendor))
        obj.put("fleets", .string(col("fleets")))
        let mfgRaw = col("mfg").trim()
        let mfg = mfgRaw.toIntOrNull(16) ?? mfgRaw.toIntOrNull()
        obj.put("mfg", mfg.map { .int($0) } ?? .null)
        obj.put("uuids", .string(col("uuids").replace("|", ",")))
        obj.put("raw", .string(col("raw")))
        obj.put("vendor_ie", .string(col("vendor_ie")))
        obj.put("rand", .bool(flags.contains("RAND")))
        obj.put("hidden", .bool(flags.contains("HIDDEN")))
        let lat = col("lat").trim()
        let lon = col("lon").trim()
        obj.put("lat", lat.isNotEmpty ? (lat.toDoubleOrNull().map { .double($0) } ?? .string(lat)) : .null)
        obj.put("lon", lon.isNotEmpty ? (lon.toDoubleOrNull().map { .double($0) } ?? .string(lon)) : .null)
        return obj.toString()
    }

    /// One JSONL object → CSV data line (no trailing newline).
    public static func jsonRowToCsv(line: String) -> String? {
        guard let obj = LogJsonObject(line) else { return nil }
        let kind = obj.optString("kind", "").trim()
        if kind != "WIFI" && kind != "BLE" { return nil }
        func str(_ key: String) -> String { obj.optString(key, "") }
        var flags = ""
        if obj.optBoolean("rand", false) { flags += "RAND " }
        if obj.optBoolean("hidden", false) { flags += "HIDDEN " }
        flags = flags.trim()
        let mfg: String
        if !obj.has("mfg") || obj.isNull("mfg") {
            mfg = ""
        } else {
            let n = obj.optInt("mfg", Int(Int32.min))
            mfg = n != Int(Int32.min) ? String(n, radix: 16).uppercased() : str("mfg")
        }
        func coord(_ key: String) -> String {
            if !obj.has(key) || obj.isNull(key) { return "" }
            let d = obj.optDouble(key, .nan)
            return d.isNaN ? str(key) : fmt(d, 6)
        }
        let uuids = str("uuids").replace(",", "|")
        return [
            String(obj.optLong("ts", 0)),
            str("iso"),
            kind,
            str("mac"),
            CsvCells.plain(s: str("name")),
            String(obj.optInt("rssi", -100)),
            String(obj.optInt("channel", 0)),
            String(obj.optInt("freq", 0)),
            str("oui"),
            CsvCells.plain(s: str("vendor")),
            CsvCells.plain(s: str("fleets")),
            mfg,
            uuids,
            flags,
            str("raw"),
            coord("lat"),
            coord("lon"),
            str("vendor_ie"),
        ].joined(separator: ",")
    }
}

// MARK: - org.json stand-ins

/// Read side of org.json `JSONObject` (the real library, as on the JVM test classpath).
struct LogJsonObject {
    private let map: [String: Any]

    init?(_ line: String) {
        guard let data = line.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = any as? [String: Any] else { return nil }
        map = dict
    }

    private static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    func has(_ key: String) -> Bool { map[key] != nil }

    func isNull(_ key: String) -> Bool {
        guard let v = map[key] else { return true }
        return v is NSNull
    }

    /// Null / missing → fallback; numbers and booleans print as text.
    func optString(_ key: String, _ fallback: String) -> String {
        guard let v = map[key], !(v is NSNull) else { return fallback }
        if let s = v as? String { return s }
        if LogJsonObject.isBool(v) { return (v as! NSNumber).boolValue ? "true" : "false" }
        if let n = v as? NSNumber { return LogJsonWriter.numberText(n) }
        if let d = try? JSONSerialization.data(withJSONObject: v, options: []), let s = String(data: d, encoding: .utf8) { return s }
        return fallback
    }

    private func number(_ key: String) -> Double? {
        guard let v = map[key], !(v is NSNull) else { return nil }
        if LogJsonObject.isBool(v) { return nil }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.trim()) }
        return nil
    }

    func optInt(_ key: String, _ fallback: Int) -> Int {
        guard let v = map[key], !(v is NSNull), !LogJsonObject.isBool(v) else { return fallback }
        if let n = v as? NSNumber { return Int(n.int32Value) }
        if let s = v as? String {
            if let i = Int32(s.trim()) { return Int(i) }
            if let d = Double(s.trim()), d.isFinite { return Int(Int32(truncatingIfNeeded: Int64(d))) }
        }
        return fallback
    }

    func optLong(_ key: String, _ fallback: Int) -> Int {
        guard let v = map[key], !(v is NSNull), !LogJsonObject.isBool(v) else { return fallback }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String {
            if let i = Int(s.trim()) { return i }
            if let d = Double(s.trim()), d.isFinite, abs(d) < 9.2e18 { return Int(d) }
        }
        return fallback
    }

    func optBoolean(_ key: String, _ fallback: Bool) -> Bool {
        guard let v = map[key] else { return fallback }
        if LogJsonObject.isBool(v) { return (v as! NSNumber).boolValue }
        if let s = v as? String {
            if s.lowercased() == "true" { return true }
            if s.lowercased() == "false" { return false }
        }
        return fallback
    }

    func optDouble(_ key: String, _ fallback: Double = .nan) -> Double {
        number(key) ?? fallback
    }
}

/// Write side of org.json `JSONObject.put(...).toString()`. Keys stay in put order
/// (org.json uses a HashMap, so Android's key order was arbitrary anyway).
struct LogJsonWriter {
    enum Value {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case null
    }

    private var keys: [String] = []
    private var values: [String: Value] = [:]

    mutating func put(_ key: String, _ value: Value) {
        if values[key] == nil { keys.append(key) }
        values[key] = value
    }

    func toString() -> String {
        var s = "{"
        for (i, k) in keys.enumerated() {
            if i > 0 { s += "," }
            s += LogJsonWriter.quote(k)
            s += ":"
            s += LogJsonWriter.text(values[k]!)
        }
        s += "}"
        return s
    }

    static func text(_ v: Value) -> String {
        switch v {
        case .string(let s): return quote(s)
        case .int(let i): return String(i)
        case .double(let d): return doubleText(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }

    /// org.json numberToString: Double.toString without a trailing ".0".
    static func doubleText(_ d: Double) -> String {
        if !d.isFinite { return "null" }
        var s = "\(d)"
        if s.contains(".") && !s.contains("e") && !s.contains("E") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    static func numberText(_ n: NSNumber) -> String {
        let d = n.doubleValue
        if d == d.rounded(), abs(d) < 9.0e15, !String(describing: n).contains(".") { return String(n.int64Value) }
        return doubleText(d)
    }

    /// org.json JSONObject.quote.
    static func quote(_ s: String) -> String {
        var out = "\""
        var prev: Unicode.Scalar = "\0"
        for c in s.unicodeScalars {
            switch c {
            case "\\", "\"":
                out += "\\"
                out.unicodeScalars.append(c)
            case "/":
                if prev == "<" { out += "\\" }
                out.unicodeScalars.append(c)
            case "\u{08}": out += "\\b"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\r": out += "\\r"
            default:
                let v = c.value
                if v < 0x20 || (v >= 0x80 && v < 0xA0) || (v >= 0x2000 && v < 0x2100) {
                    out += "\\u" + hexN(Int(v), 4).lowercased()
                } else {
                    out.unicodeScalars.append(c)
                }
            }
            prev = c
        }
        out += "\""
        return out
    }
}
