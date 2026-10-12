import Foundation

// Port of domain/RadioDb.kt.

/// Offline assigned-number tables packed from official IEEE MA-L/M/S/CID
/// and Bluetooth SIG Assigned Numbers YAML. Binary-searched; names decoded
/// only on a hit.
///
/// Android needed `init(context)`. Here the table loads from `Bundle.module` on the first
/// lookup; `initialize()` can warm it up early. All little-endian, like the Kotlin ByteBuffer.
public enum RadioDb {
    private final class Tables {
        var malKeys: [Int] = []
        var malIdx: [UInt16] = []
        var cidKeys: [Int] = []
        var cidIdx: [UInt16] = []
        var longKeys: [Int] = []
        var longIdx: [UInt16] = []
        var btKeys: [Int] = []
        var btIdx: [UInt16] = []
        var appKeys: [Int] = []
        var appIdx: [UInt16] = []
        var uuidKeys: [Int] = []
        var uuidIdx: [UInt16] = []
        var nameOff: [Int] = []
        var nameBlob: [UInt8] = []
        var builtYmd = 0
        var nameCount = 0
    }

    private static let lock = NSLock()
    private static var loaded: Tables?
    private static var attempted = false

    public static var builtYmd: Int { tables()?.builtYmd ?? 0 }
    public static var nameCount: Int { tables()?.nameCount ?? 0 }

    /// Load the tables now (idempotent). Lookups also load on first use.
    public static func initialize() { _ = tables() }

    /// True once the tables are loaded. Loads on first call, so callers never see "not ready".
    public static func isReady() -> Bool { tables() != nil }

    private static func tables() -> Tables? {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return loaded }
        if attempted { return nil }
        attempted = true
        guard let url = Bundle.module.url(forResource: "radiodb", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else {
            NSLog("Fieldwatch: radiodb.bin missing from bundle")
            return nil
        }
        loaded = parse([UInt8](data))
        if loaded == nil { NSLog("Fieldwatch: radiodb.bin could not be parsed") }
        return loaded
    }

    public static func vendorForMac(mac: String) -> String? {
        guard let t = tables() else { return nil }
        if MacUtil.isRandomized(mac: mac) {
            guard let univ = MacUtil.wifiOui24Universal(mac: mac) else { return nil }
            guard let name = vendorForOui24(oui: univ) else { return nil }
            return isPhoneHouseVendor(name) ? nil : name
        }
        let hex = mac.filterAlnum().uppercased()
        if hex.count >= 9, let p = Int(hex.take(9), radix: 16), let n = longName(t, 36, p) { return n }
        if hex.count >= 7, let p = Int(hex.take(7), radix: 16), let n = longName(t, 28, p) { return n }
        if hex.count >= 6 {
            guard let k = Int(hex.take(6), radix: 16) else { return nil }
            return keyName(t, t.malKeys, t.malIdx, k)
        }
        return nil
    }

    public static func vendorForOui24(oui: String) -> String? {
        guard let t = tables() else { return nil }
        let hex = oui.filterAlnum().uppercased()
        if hex.count < 6 { return nil }
        guard let key = Int(hex.take(6), radix: 16) else { return nil }
        return keyName(t, t.malKeys, t.malIdx, key) ?? keyName(t, t.cidKeys, t.cidIdx, key)
    }

    public static func company(id: Int) -> String? {
        guard let t = tables() else { return nil }
        return keyName(t, t.btKeys, t.btIdx, id & 0xFFFF)
    }

    public static func appearance(value: Int) -> String? {
        guard let t = tables() else { return nil }
        let v = value & 0xFFFF
        if let n = keyName(t, t.appKeys, t.appIdx, v) { return n }
        let category = v & 0xFFC0
        if category != v, let n = keyName(t, t.appKeys, t.appIdx, category) { return n }
        return nil
    }

    public static func serviceUuid(uuid: String) -> String? {
        guard let t = tables() else { return nil }
        let hex = uuid.filterAlnum().uppercased()
        let short: Int?
        if hex.count == 4 {
            short = Int(hex, radix: 16)
        } else if hex.count == 8 {
            short = Int(hex.takeLast(4), radix: 16)
        } else if hex.count == 32 && hex.hasPrefix("0000") && hex.hasSuffix("00001000800000805F9B34FB") {
            short = Int(hex.substring(4, 8), radix: 16)
        } else {
            return nil
        }
        guard let short else { return nil }
        return keyName(t, t.uuidKeys, t.uuidIdx, short)
    }

    private static func longName(_ t: Tables, _ bits: Int, _ prefix: Int) -> String? {
        keyName(t, t.longKeys, t.longIdx, (bits << 56) | prefix)
    }

    /// Binary search shared by the u32 / u16 / long tables (Kotlin had three copies).
    private static func keyName(_ t: Tables, _ keys: [Int], _ idx: [UInt16], _ target: Int) -> String? {
        var lo = 0
        var hi = keys.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let v = keys[mid]
            if v < target { lo = mid + 1 } else if v > target { hi = mid - 1 } else { return nameAt(t, Int(idx[mid])) }
        }
        return nil
    }

    private static func nameAt(_ t: Tables, _ index: Int) -> String? {
        if index < 0 || index + 1 >= t.nameOff.count { return nil }
        let start = t.nameOff[index]
        let end = t.nameOff[index + 1]
        if start < 0 || end > t.nameBlob.count || end < start { return nil }
        return String(decoding: t.nameBlob[start..<end], as: UTF8.self)
    }

    /// Little-endian cursor over the file (Kotlin ByteBuffer.order(LITTLE_ENDIAN)).
    private struct Reader {
        let b: [UInt8]
        var pos: Int
        mutating func u8() throws -> Int {
            guard pos < b.count else { throw ParseError.short }
            defer { pos += 1 }
            return Int(b[pos])
        }
        mutating func u16() throws -> Int { let a = try u8(); return a | (try u8() << 8) }
        /// Signed 32-bit (Kotlin `buf.int`).
        mutating func i32() throws -> Int {
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(try u8()) << (8 * UInt32(i)) }
            return Int(Int32(bitPattern: v))
        }
        /// Signed 64-bit (Kotlin `buf.long`).
        mutating func i64() throws -> Int {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(try u8()) << (8 * UInt64(i)) }
            return Int(Int64(bitPattern: v))
        }
        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard n >= 0, pos + n <= b.count else { throw ParseError.short }
            defer { pos += n }
            return Array(b[pos..<pos + n])
        }
    }

    private enum ParseError: Error { case short, bad(String) }

    private static func parse(_ bytes: [UInt8]) -> Tables? {
        do { return try parseOrThrow(bytes) } catch { return nil }
    }

    private static func parseOrThrow(_ bytes: [UInt8]) throws -> Tables {
        let t = Tables()
        var buf = Reader(b: bytes, pos: 0)
        let magic = try buf.bytes(4)
        guard magic == Array("SPLK".utf8) else { throw ParseError.bad("radiodb magic") }
        let version = try buf.u16()
        _ = try buf.u16()
        guard version == 1 else { throw ParseError.bad("radiodb version \(version)") }
        t.builtYmd = try buf.i32()
        let nsec = try buf.i32()
        var sections: [String: Int] = [:]
        for _ in 0..<max(0, nsec) {
            let tag = try buf.bytes(4)
            let off = try buf.i32()
            var name = String(decoding: tag, as: UTF8.self)
            while name.hasSuffix("\u{0}") { name.removeLast() }
            sections[name] = off
        }
        func slice(_ tag: String) throws -> Reader {
            guard let off = sections[tag] else { throw ParseError.bad("missing \(tag)") }
            return Reader(b: bytes, pos: off)
        }
        func count(_ r: inout Reader) throws -> Int {
            let n = try r.i32()
            guard n >= 0 else { throw ParseError.bad("negative count") }
            return n
        }
        var b = try slice("mal")
        var n = try count(&b)
        t.malKeys = try (0..<n).map { _ in try b.i32() }
        t.malIdx = try (0..<n).map { _ in UInt16(try b.u16()) }
        b = try slice("cid"); n = try count(&b)
        t.cidKeys = try (0..<n).map { _ in try b.i32() }
        t.cidIdx = try (0..<n).map { _ in UInt16(try b.u16()) }
        b = try slice("long"); n = try count(&b)
        t.longKeys = try (0..<n).map { _ in try b.i64() }
        t.longIdx = try (0..<n).map { _ in UInt16(try b.u16()) }
        b = try slice("btc"); n = try count(&b)
        t.btKeys = try (0..<n).map { _ in try b.u16() }
        t.btIdx = try (0..<n).map { _ in UInt16(try b.u16()) }
        b = try slice("app"); n = try count(&b)
        t.appKeys = try (0..<n).map { _ in try b.u16() }
        t.appIdx = try (0..<n).map { _ in UInt16(try b.u16()) }
        b = try slice("uuid"); n = try count(&b)
        t.uuidKeys = try (0..<n).map { _ in try b.u16() }
        t.uuidIdx = try (0..<n).map { _ in UInt16(try b.u16()) }
        b = try slice("noff"); n = try count(&b)
        t.nameCount = n
        t.nameOff = try (0..<(n + 1)).map { _ in try b.i32() }
        guard let nstrAt = sections["nstr"] else { throw ParseError.bad("missing nstr") }
        let last = t.nameOff.last ?? 0
        guard nstrAt >= 0, last >= 0, nstrAt + last <= bytes.count else { throw ParseError.short }
        t.nameBlob = Array(bytes[nstrAt..<(nstrAt + last)])
        return t
    }

    private static func isPhoneHouseVendor(_ vendor: String) -> Bool {
        let v = vendor.lowercased()
        return PHONE_HOUSE_VENDOR.contains { v.contains($0) }
    }

    private static let PHONE_HOUSE_VENDOR = ["apple", "google", "samsung electronics", "microsoft"]
}
