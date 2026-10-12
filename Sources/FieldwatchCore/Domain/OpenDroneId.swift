import Foundation

/// ASTM F3411 / OpenDroneID packed messages from BLE FFFA or Wi-Fi vendor IE
/// FA:0B:BC type 0x0D. Location, Basic ID, System, Self ID. Heading follows
/// opendroneid.c (direction byte + EW flag), not the catalog *2 scale.
public enum OpenDroneId {
    public static let BLE_UUID = "FFFA"
    public static let WIFI_OUI = "FA:0B:BC"
    public static let WIFI_TYPE = 0x0D
    private static let MSG = 25
    private static let INV_DIR = 255
    private static let INV_SPEED = 255
    /// ASTM Basic ID id_type. 1 is a CTA-2063 serial. Session and CAA are not.
    private static let ID_SERIAL = 1

    public static func fromFacts(facts: RadioFacts) -> PayloadLocation {
        var acc = PayloadLocation()
        for sd in facts.serviceData {
            if uuid16(sd.uuid) != 0xFFFA { continue }
            acc = parseMessages(msgs: messagesBle(dataHex: sd.dataHex)).mergeSticky(prev: acc)
        }
        for ie in facts.vendorIes {
            if !ie.oui.equals(WIFI_OUI, ignoreCase: true) || ie.type != WIFI_TYPE { continue }
            acc = parseMessages(msgs: messagesWifi(dataHex: ie.dataHex)).mergeSticky(prev: acc)
        }
        return acc
    }

    /// Wi-Fi vendor IE payloads framed as BLE FFFA ads: `0x0D` + counter + each
    /// 25-byte ASTM message. Stock Remote ID Decode fields maps then apply.
    public static func wifiFffaPayloads(facts: RadioFacts) -> [String] {
        var out: [String] = []
        for ie in facts.vendorIes {
            if !ie.oui.equals(WIFI_OUI, ignoreCase: true) || ie.type != WIFI_TYPE { continue }
            out += wrapWifiAsFffa(dataHex: ie.dataHex)
        }
        return out
    }

    static func wrapWifiAsFffa(dataHex: String) -> [String] {
        guard let b = hex(dataHex), b.isNotEmpty else { return [] }
        let bleShaped = b.count >= 2 + MSG && b[0] == 0x0D
        let start = bleShaped ? 2 : 1
        if start > b.count { return [] }
        let counter = Int(bleShaped ? b[1] : b[0])
        return framedMessages(b, start).map { msg in "0D" + hex2(counter) + msg.toHexUpper() }
    }

    static func messagesBle(dataHex: String) -> [[UInt8]] {
        guard let b = hex(dataHex), b.isNotEmpty else { return [] }
        let start = (b.count >= 2 + MSG && b[0] == 0x0D) ? 2 : 0
        return framedMessages(b, start)
    }

    static func messagesWifi(dataHex: String) -> [[UInt8]] {
        guard let b = hex(dataHex), b.isNotEmpty else { return [] }
        // BLE-shaped [0x0D][counter][msgs], else ASTM [counter][msgs].
        let start = (b.count >= 2 + MSG && b[0] == 0x0D) ? 2 : 1
        return framedMessages(b, start)
    }

    /// Single 25-byte messages, or an ASTM message pack (type nibble 0xF).
    private static func framedMessages(_ b: [UInt8], _ start: Int) -> [[UInt8]] {
        if start >= b.count { return [] }
        let head = Int(b[start])
        if head >> 4 == 0xF && start + 3 <= b.count {
            let size = Int(b[start + 1]).coerceAtLeast(MSG)
            let count = Int(b[start + 2])
            var out: [[UInt8]] = []
            var i = start + 3
            for _ in 0..<count {
                // Kotlin `return@repeat` skips (does not break); i stays, so later rounds skip too.
                if i + MSG > b.count { continue }
                out.append(b.copyOfRange(i, i + MSG))
                i += size
            }
            return out
        }
        return chunks(b, start)
    }

    private static func chunks(_ b: [UInt8], _ start: Int) -> [[UInt8]] {
        if start + MSG > b.count { return [] }
        var out: [[UInt8]] = []
        var i = start
        while i + MSG <= b.count {
            out.append(b.copyOfRange(i, i + MSG))
            i += MSG
        }
        return out
    }

    static func parseMessages(msgs: [[UInt8]]) -> PayloadLocation {
        var acc = PayloadLocation()
        for m in msgs {
            if m.count < MSG { continue }
            acc = parseOne(m).mergeSticky(prev: acc)
        }
        return acc
    }

    private static func parseOne(_ m: [UInt8]) -> PayloadLocation {
        switch Int(m[0]) >> 4 {
        case 0: return basicId(m)
        case 1: return location(m)
        case 3: return selfId(m)
        case 4: return systemMsg(m)
        default: return PayloadLocation()
        }
    }

    private static func location(_ m: [UInt8]) -> PayloadLocation {
        let flags = Int(m[1])
        let ew = (flags >> 1) & 1
        let speedMult = flags & 1
        let dirRaw = Int(m[2])
        let heading: Double? = dirRaw == INV_DIR ? nil : Double((dirRaw + (ew == 1 ? 180 : 0)) % 360)
        let sh = Int(m[3])
        let speed: Double?
        if sh == INV_SPEED { speed = nil }
        else if speedMult == 0 { speed = Double(sh) * 0.25 }
        else { speed = Double(sh) * 0.75 + 255 * 0.25 }
        let vspeed = Double(m.s8(4)) * 0.5
        let lat = Double(i32le(m, 5)) * 1e-7
        let lon = Double(i32le(m, 9)) * 1e-7
        let altGeo = (Double(u16le(m, 15)) * 0.5) - 1000.0
        return PayloadLocation(lat: lat, lon: lon, alt: altGeo, headingDeg: heading, speedMps: speed, vspeedMps: vspeed)
    }

    private static func basicId(_ m: [UInt8]) -> PayloadLocation {
        let idType = Int(m[1]) >> 4
        let id = ascii(m.copyOfRange(2, 22)).trim("\u{0}", " ")
        let maker = idType == ID_SERIAL ? (Cta2063.label(serial: id) ?? "") : ""
        return PayloadLocation(uasId: id.nonEmpty, aircraft: maker, basicId: true)
    }

    private static func selfId(_ m: [UInt8]) -> PayloadLocation {
        let text = ascii(m.copyOfRange(2, 25)).trim("\u{0}", " ")
        return PayloadLocation(selfId: text.nonEmpty)
    }

    private static func systemMsg(_ m: [UInt8]) -> PayloadLocation {
        let lat = Double(i32le(m, 2)) * 1e-7
        let lon = Double(i32le(m, 6)) * 1e-7
        return PayloadLocation(opLat: lat, opLon: lon)
    }

    /// Java US_ASCII decoding: bytes >= 0x80 become U+FFFD.
    private static func ascii(_ b: [UInt8]) -> String {
        String(b.map { $0 < 0x80 ? Character(UnicodeScalar($0)) : "\u{FFFD}" })
    }

    private static func i32le(_ m: [UInt8], _ at: Int) -> Int {
        let v = UInt32(m[at]) | (UInt32(m[at + 1]) << 8) | (UInt32(m[at + 2]) << 16) | (UInt32(m[at + 3]) << 24)
        return Int(Int32(bitPattern: v))
    }

    private static func u16le(_ m: [UInt8], _ at: Int) -> Int { Int(m[at]) | (Int(m[at + 1]) << 8) }

    private static func uuid16(_ uuid: String) -> Int? {
        let hex = uuid.filterAlnum()
        if hex.count == 4 { return hex.toIntOrNull(16) }
        if hex.count >= 8 && hex.startsWith("0000", ignoreCase: true) { return hex.substring(4, 8).toIntOrNull(16) }
        return hex.take(4).toIntOrNull(16)
    }

    private static func hex(_ s: String) -> [UInt8]? {
        let h = s.filterAlnum()
        if h.isEmpty || h.count % 2 != 0 { return nil }
        return h.hexToBytes()
    }
}
