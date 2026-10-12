import Foundation

// Port of domain/SignatureFieldDecoder.kt.

public struct DecodedFieldValue: Hashable, Sendable {
    public var fleetId: String
    public var fleetName: String
    public var id: String
    public var label: String
    public var display: String
    public var offset: Int
    public var length: Int
    /// Scaled numeric value when the field is an integer, float, bits, or bool.
    public var number: Double?
    /// Catalog sentence for this named value. Empty when the signature did not write one.
    public var note: String
    /// Signature asked for this field on the live row.
    public var live: Bool
    /// This value uses the stronger live chip.
    public var emphasis: Bool

    public init(
        fleetId: String, fleetName: String, id: String, label: String, display: String, offset: Int, length: Int,
        number: Double? = nil, note: String = "", live: Bool = false, emphasis: Bool = false
    ) {
        self.fleetId = fleetId; self.fleetName = fleetName; self.id = id; self.label = label
        self.display = display; self.offset = offset; self.length = length; self.number = number
        self.note = note; self.live = live; self.emphasis = emphasis
    }
}

/// One decoded label drawn next to the signature name. Text is the catalog's own wording.
public struct LiveDecodeChip: Codable, Hashable, Sendable {
    public var text: String
    public var emphasis: Bool
    public var note: String

    public init(text: String, emphasis: Bool, note: String = "") {
        self.text = text; self.emphasis = emphasis; self.note = note
    }

    enum CodingKeys: String, CodingKey { case text, emphasis, note }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        emphasis = try c.decode(Bool.self, forKey: .emphasis)
        note = try c.decode(.note, default: "")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(emphasis, forKey: .emphasis)
        try c.encode(note, forKey: .note)
    }

    /// Title-case for reports and the live chip. Catalog text is stored lowercase.
    public func reportLabel() -> String {
        let trimmed = text.trim()
        guard let first = trimmed.first else { return trimmed }
        if first.isLowercase {
            return String(first).capitalized(with: Locale(identifier: "en_US")) + trimmed.dropFirst()
        }
        return trimmed
    }
}

public extension Array where Element == LiveDecodeChip {
    func reportLabels() -> [String] { map { $0.reportLabel() }.filter { $0.isNotEmpty } }
}

/// Parses `Fleet.decode` maps from a BLE advertisement, or from Wi-Fi Remote ID
/// framed as BLE FFFA (`OpenDroneId.wifiFffaPayloads`).
/// Used by device detail, reports, and sticky payload coordinates for TAK/CoT.
/// Not a matcher — `SignatureEngine.match` still decides the label.
public enum SignatureFieldDecoder {
    private static let cacheLock = NSLock()
    private static var cache: [String: [DecodedFieldValue]] = [:]

    public static func decodeSighting(device: Sighting, fleets: [Fleet]) -> [DecodedFieldValue] {
        if device.fleetIds.isEmpty { return [] }
        if device.kind != .ble && device.kind != .wifi { return [] }
        let byId = fleets.associateBy { $0.id }
        var out: [DecodedFieldValue] = []
        for id in device.fleetIds {
            guard let fleet = byId[id] else { continue }
            guard let decode = fleet.decode else { continue }
            if decode.fields.isEmpty { continue }
            out += decodeFleet(fleet: fleet, decode: decode, device: device)
        }
        return out
    }

    /// Labels for decode fields marked live. Cached with the field parse. No fleet id is special.
    public static func liveChips(device: Sighting, fleets: [Fleet]) -> [LiveDecodeChip] {
        if device.fleetIds.isEmpty { return [] }
        var out: [LiveDecodeChip] = []
        var seen = Set<String>()
        for row in decodeSighting(device: device, fleets: fleets) {
            if !row.live { continue }
            let text = row.display.trim()
            if text.isEmpty || !seen.insert(text.lowercased()).inserted { continue }
            out.append(LiveDecodeChip(text: text, emphasis: row.emphasis, note: row.note.trim()))
        }
        return out
    }

    public static func payloadHex(decode: FleetDecode, device: Sighting) -> String? {
        payloads(decode, device).first?.1
    }

    public static func decodeFleet(fleet: Fleet, decode: FleetDecode, device: Sighting) -> [DecodedFieldValue] {
        let candidates = payloads(decode, device)
        if candidates.isEmpty { return [] }
        var out: [DecodedFieldValue] = []
        var seen = Set<String>()
        for (bytes, hex) in candidates {
            let key = cacheKey(fleet.id, decode, hex)
            cacheLock.lock()
            let hit = cache[key]
            cacheLock.unlock()
            let parsed: [DecodedFieldValue]
            if let hit {
                parsed = hit
            } else {
                parsed = parse(fleet, decode, bytes)
                cacheLock.lock()
                cache[key] = parsed
                cacheLock.unlock()
            }
            for row in parsed where seen.insert(row.id).inserted { out.append(row) }
        }
        return out
    }

    private static func cacheKey(_ fleetId: String, _ decode: FleetDecode, _ hex: String) -> String {
        let fp = decode.fields.map { f -> String in
            let notes = f.enumNotes.map { m in m.keys.sorted().map { "\($0)=\(m[$0]!)" }.joined(separator: ", ") } ?? "null"
            return "\(f.id):\(f.offset):\(f.type.rawValue):\(f.resolvedLength()):\(f.live):\(f.liveEmphasis):{\(notes)}"
        }.joined(separator: ",")
        return "\(fleetId)|\(decode.source.rawValue)|\(hex)|\(fp)"
    }

    private static func payloads(_ decode: FleetDecode, _ device: Sighting) -> [([UInt8], String)] {
        let hexes: [String]
        switch decode.source {
        case .manufacturerData:
            if device.kind != .ble {
                hexes = []
            } else {
                var records = device.facts.mfgRecords
                if records.isEmpty, let id = device.manufacturerId {
                    records = [MfgRecord(companyId: id, dataHex: device.manufacturerDataHex)]
                }
                let want = decode.companyId.flatMap { $0 != 0 ? $0 : nil }
                let chosen = want.map { w in records.filter { $0.companyId == w } } ?? records
                hexes = chosen.map { rec in
                    decode.includeCompanyId ? companyIdPrefix(rec.companyId) + rec.dataHex : rec.dataHex
                }
            }
        case .serviceData:
            guard let want = decode.serviceUuid.map({ uuidKey($0) }) else { return [] }
            let ads = device.facts.serviceData.filter { uuidKey($0.uuid) == want }.map { $0.dataHex }
            hexes = want == "FFFA" ? ads + OpenDroneId.wifiFffaPayloads(facts: device.facts) : ads
        case .unsupported:
            hexes = []
        }
        var out: [([UInt8], String)] = []
        out.reserveCapacity(hexes.count)
        for hex in hexes {
            guard let raw = hexToBytes(hex) else { continue }
            let bytes = stripIntelliRocks(raw)
            if bytes.isEmpty { continue }
            out.append((bytes, bytes.toHexUpper()))
        }
        return out
    }

    private static func parse(_ fleet: Fleet, _ decode: FleetDecode, _ payload: [UInt8]) -> [DecodedFieldValue] {
        var out: [DecodedFieldValue] = []
        out.reserveCapacity(decode.fields.count)
        for field in decode.fields {
            if !gateOk(field.gate, payload) { continue }
            let len = field.resolvedLength()
            if field.offset < 0 || len < 1 || field.offset + len > payload.count { continue }
            guard let parsed = formatField(field, payload) else { continue }
            if parsed.display.isEmpty { continue }
            out.append(DecodedFieldValue(
                fleetId: fleet.id,
                fleetName: fleet.name,
                id: field.id,
                label: field.label,
                display: parsed.display,
                offset: field.offset,
                length: len,
                number: parsed.number,
                note: enumNote(field, parsed.rawKey),
                live: field.live,
                emphasis: field.live && emphasized(field, parsed.rawKey)
            ))
        }
        return out
    }

    private static func gateOk(_ gate: DecodeWhen?, _ payload: [UInt8]) -> Bool {
        guard let gate else { return true }
        if !gateOkOnce(gate, payload) { return false }
        return gateOk(gate.and, payload)
    }

    private static func gateOkOnce(_ gate: DecodeWhen, _ payload: [UInt8]) -> Bool {
        if gate.op == .len { return payload.count == gate.length.coerceAtLeast(1) }
        guard let want = hexToBytes(gate.valueHex) else { return false }
        let len = want.count.coerceAtLeast(1)
        if gate.offset < 0 || gate.offset + len > payload.count { return false }
        let got = Array(payload[gate.offset..<(gate.offset + len)])
        if want.count != got.count { return false }
        switch gate.op {
        case .len: return payload.count == gate.length
        case .eq: return got == want
        case .neq: return got != want
        case .mask:
            var ok = true
            for i in got.indices where (got[i] & want[i]) != want[i] { ok = false }
            return ok
        case .nmask:
            var ok = true
            for i in got.indices where (got[i] & want[i]) != 0 { ok = false }
            return ok
        }
    }

    private struct ParsedField {
        let display: String
        let number: Double?
        let rawKey: String
    }

    private static func emphasized(_ field: DecodeField, _ rawKey: String) -> Bool {
        if field.liveEmphasis.isEmpty || rawKey.isEmpty { return false }
        let want = Set(field.liveEmphasis.map { normalizeEnumKey(raw: $0) })
        return want.contains(normalizeEnumKey(raw: rawKey)) || field.liveEmphasis.contains(rawKey)
    }

    private static func enumNote(_ field: DecodeField, _ rawKey: String) -> String {
        guard let notes = field.enumNotes else { return "" }
        if rawKey.isEmpty { return "" }
        if let n = notes[rawKey] { return n.trim() }
        let key = normalizeEnumKey(raw: rawKey)
        if let n = notes[key] { return n.trim() }
        // Kotlin took the first matching map entry; sort keys so the pick is stable here.
        for k in notes.keys.sorted() where normalizeEnumKey(raw: k) == key { return notes[k]!.trim() }
        return ""
    }

    private static func formatField(_ field: DecodeField, _ payload: [UInt8]) -> ParsedField? {
        let len = field.resolvedLength()
        let slice = Array(payload[field.offset..<(field.offset + len)])
        let le = field.endian != .be
        let unit = field.unit?.trim() ?? ""
        var rawNum: Double?
        var rawKey = ""
        let text: String?
        switch field.type {
        case .utf8:
            let s = trimControl(String(decoding: slice, as: UTF8.self))
            rawKey = s
            text = s.isEmpty ? nil : s
        case .hex:
            let h = slice.toHexUpper()
            rawKey = h
            text = h.chunked(2).joined(separator: " ")
        case .mac:
            if slice.count < 6 { return nil }
            let mac = slice.take(6).map { hex2(Int($0)) }.joined(separator: ":")
            rawKey = mac
            text = mac
        case .bool:
            let on = slice.contains { $0 != 0 }
            rawNum = on ? 1.0 : 0.0
            rawKey = on ? "1" : "0"
            text = on ? "yes" : "no"
        case .bits:
            let width = (field.bitWidth ?? 1).coerceIn(1, 32)
            let bitStart = field.bitOffset ?? 0
            let word = readU(slice, 0, slice.count, le)
            let value = (word &>> bitStart) & ((1 << width) - 1)
            rawNum = Double(value)
            rawKey = "\(value)"
            text = "\(value)"
        case .f32:
            if slice.count < 4 { return nil }
            let bits = UInt32(truncatingIfNeeded: readU(slice, 0, 4, le))
            let f = Double(Float(bitPattern: bits))
            rawNum = f
            rawKey = kotlinDoubleString(f)
            text = formatNumber(f)
        case .u8, .u16, .u24, .u32:
            let v = readU(slice, 0, slice.count, le)
            rawNum = Double(v)
            rawKey = "\(v)"
            text = "\(v)"
        case .i8, .i16, .i32:
            let bits = slice.count * 8
            let v = signExtend(readU(slice, 0, slice.count, le), bits)
            rawNum = Double(v)
            rawKey = "\(v)"
            text = "\(v)"
        }
        guard let text else { return nil }
        let transformed = field.scale != nil || field.offsetAdd != nil || field.modulo != nil
        let scaledNum: Double? = rawNum.map { raw in
            var n = raw
            if transformed {
                if let m = field.modulo, m != 0.0 { n = n.truncatingRemainder(dividingBy: m) }
                if let s = field.scale { n *= s }
                if let a = field.offsetAdd { n += a }
            }
            return n
        }
        let scaled = (rawNum != nil && transformed) ? formatNumber(scaledNum!) : text
        let n = rawNum
        var mapped: String?
        if let labels = field.enumLabels {
            mapped = labels[rawKey] ?? labels["0x\(rawKey.uppercased())"]
            if mapped == nil, let n {
                let l = kotlinToLong(n)
                mapped = labels["\(l)"] ?? labels["0x" + String(UInt64(bitPattern: Int64(l)), radix: 16, uppercase: true)]
            }
        }
        let shown = mapped ?? scaled
        let display = unit.isEmpty ? shown : "\(shown) \(unit)"
        return ParsedField(display: display, number: scaledNum.flatMap { $0.isFinite ? $0 : nil }, rawKey: rawKey)
    }

    /// Kotlin `trim { it <= ' ' || it == '\u0000' }`.
    private static func trimControl(_ s: String) -> String {
        var scalars = Array(s.unicodeScalars)
        while let f = scalars.first, f.value <= 0x20 { scalars.removeFirst() }
        while let l = scalars.last, l.value <= 0x20 { scalars.removeLast() }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars)
        return String(out)
    }

    /// Kotlin Long shifts mask the shift count to 6 bits; `&<<` / `&>>` do the same.
    private static func readU(_ bytes: [UInt8], _ offset: Int, _ len: Int, _ le: Bool) -> Int {
        var v = 0
        if le {
            for i in 0..<len { v |= (Int(bytes[offset + i]) & 0xff) &<< (8 * i) }
        } else {
            for i in 0..<len { v = (v &<< 8) | (Int(bytes[offset + i]) & 0xff) }
        }
        return v
    }

    private static func signExtend(_ v: Int, _ bits: Int) -> Int {
        let shift = 64 - bits
        return (v &<< shift) &>> shift
    }

    private static func formatNumber(_ n: Double) -> String {
        if !n.isFinite { return kotlinDoubleString(n) }
        if n == Double(kotlinToLong(n)) { return "\(kotlinToLong(n))" }
        var s = fmt(n, 6)
        while s.hasSuffix("0") { s.removeLast() }
        while s.hasSuffix(".") { s.removeLast() }
        return s
    }

    private static func uuidKey(_ uuid: String) -> String {
        let hex = uuid.filterAlnum().uppercased()
        if hex.count == 4 { return hex }
        if hex.count == 32 && hex.hasPrefix("0000") && hex.hasSuffix("00001000800000805F9B34FB") {
            return hex.substring(4, 8)
        }
        return hex
    }

    private static func companyIdPrefix(_ companyId: Int) -> String {
        hex2(companyId & 0xff) + hex2((companyId >> 8) & 0xff)
    }

    /// Nil on empty, odd or non-hex input (Kotlin threw on non-hex letters).
    private static func hexToBytes(_ hex: String) -> [UInt8]? {
        let h = Array(hex.filterAlnum())
        if h.isEmpty || h.count % 2 != 0 { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(h.count / 2)
        var i = 0
        while i < h.count {
            guard let v = UInt8(String(h[i...i + 1]), radix: 16) else { return nil }
            out.append(v)
            i += 2
        }
        return out
    }

    /// Govee sometimes glues ASCII "INTELLI_ROCKS" onto the sensor payload.
    /// Strip it so length-gated H5074/H5075/H510x maps still fit.
    private static func stripIntelliRocks(_ bytes: [UInt8]) -> [UInt8] {
        if bytes.count <= INTELLI_ROCKS.count { return bytes }
        let idx = indexOfSlice(bytes, INTELLI_ROCKS)
        if idx < 0 { return bytes }
        return idx == 0 ? [] : Array(bytes[0..<idx])
    }

    private static func indexOfSlice(_ hay: [UInt8], _ needle: [UInt8]) -> Int {
        let last = hay.count - needle.count
        if last < 0 { return -1 }
        outer: for i in 0...last {
            for j in needle.indices where hay[i + j] != needle[j] { continue outer }
            return i
        }
        return -1
    }

    private static let INTELLI_ROCKS: [UInt8] = Array("INTELLI_ROCKS".utf8)
}

/// Kotlin `Double.toLong()`: truncates, NaN → 0, saturates at the Long range.
private func kotlinToLong(_ d: Double) -> Int {
    if d.isNaN { return 0 }
    if d >= 9.223372036854775807e18 { return Int.max }
    if d <= -9.223372036854775808e18 { return Int.min }
    return Int(d)
}

/// Kotlin/Java `Double.toString()`: "1.0", "21.5", "1.0E7", "1.5E-5", "NaN", "Infinity".
func kotlinDoubleString(_ d: Double) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
    if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
    let a = Swift.abs(d)
    let sign = d < 0 ? "-" : ""
    // Shortest round-trip digits from Swift, re-laid out the Java way.
    let s = "\(a)"
    var mantissa = s
    var exp = 0
    if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        mantissa = String(s[..<e])
        exp = Int(s[s.index(after: e)...]) ?? 0
    }
    let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
    let intPart = String(parts[0])
    let fracPart = parts.count > 1 ? String(parts[1]) : ""
    var digits = intPart + fracPart
    var pointAt = intPart.count + exp // decimal point position within `digits`
    while digits.hasPrefix("0") && digits.count > 1 { digits.removeFirst(); pointAt -= 1 }
    while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() }
    let sciExp = pointAt - 1
    if a >= 1e-3 && a < 1e7 {
        if pointAt <= 0 {
            return sign + "0." + String(repeating: "0", count: -pointAt) + digits
        }
        if pointAt >= digits.count {
            return sign + digits + String(repeating: "0", count: pointAt - digits.count) + ".0"
        }
        return sign + digits.take(pointAt) + "." + digits.drop(pointAt)
    }
    let head = digits.take(1)
    let tail = digits.drop(1)
    return sign + head + "." + (tail.isEmpty ? "0" : tail) + "E\(sciExp)"
}

/// Store enum keys as decimal so 0x05, 05, and 5 all match a u8 of 5.
public func normalizeEnumKey(raw: String) -> String {
    let t = raw.trim()
    if t.isEmpty { return t }
    if t.startsWith("0x", ignoreCase: true) {
        return t.substring(2).toLongOrNull(16).map { "\($0)" } ?? t
    }
    if let v = t.toLongOrNull() { return "\(v)" }
    let hex = t.filterAlnum()
    if hex.contains(where: { ("A"..."F").contains($0) || ("a"..."f").contains($0) }) {
        if let v = hex.toLongOrNull(16) { return "\(v)" }
    }
    return t
}

public extension Sighting {
    /// Keep `liveDecode` in step with the signature's live flags. Unchanged value when nothing changed.
    func withLiveDecode(fleets: [Fleet]) -> Sighting {
        let chips = SignatureFieldDecoder.liveChips(device: self, fleets: fleets)
        if chips == liveDecode { return self }
        var c = self
        c.liveDecode = chips
        return c
    }
}

public func normalizeEnumLabels(map: [String: String]?) -> [String: String]? {
    guard let map, map.isNotEmpty else { return nil }
    var out: [String: String] = [:]
    // Sorted so a key collision resolves the same way every run.
    for k in map.keys.sorted() {
        let key = normalizeEnumKey(raw: k)
        let label = map[k]!.trim()
        if key.isEmpty || label.isEmpty { continue }
        out[key] = label
    }
    return out.isEmpty ? nil : out
}

public func normalizeValueHex(raw: String) -> String {
    var h = raw.trim()
    if h.hasPrefix("0x") { h = String(h.dropFirst(2)) }
    if h.hasPrefix("0X") { h = String(h.dropFirst(2)) }
    h = h.filterAlnum().uppercased()
    if h.count % 2 == 1 { h = "0" + h }
    return h
}

public func normalizeGate(gate: DecodeWhen?) -> DecodeWhen? {
    guard let gate else { return nil }
    let rest = normalizeGate(gate: gate.and)
    if gate.op == .len {
        return DecodeWhen(offset: 0, length: gate.length.coerceAtLeast(1), op: .len, valueHex: "", and: rest)
    }
    let hex = normalizeValueHex(raw: gate.valueHex)
    if hex.isEmpty { return rest }
    let len = (hex.count / 2).coerceAtLeast(1)
    return DecodeWhen(offset: gate.offset.coerceAtLeast(0), length: len, op: gate.op, valueHex: hex, and: rest)
}

public extension DecodeField {
    func normalized() -> DecodeField {
        var c = self
        c.enumLabels = normalizeEnumLabels(map: enumLabels)
        c.gate = normalizeGate(gate: gate)
        return c
    }
}
