import Foundation

/// BLE advertisement (AD structure) parsing. macOS gives no raw advertisement bytes, so the
/// scanner rebuilds them from CoreBluetooth's dictionary with `buildAdvertisement` and then
/// everything downstream (rawHex, `parse`, signatures) works on the same byte layout as Android.
public enum BleAdParser {
    public struct Parsed: Hashable, Sendable {
        public var flags: Int?
        public var txPower: Int?
        public var appearance: Int?
        public var advertisingIntervalMs: Double?
        public var deviceClass: Int?
        public var localName: String?
        public var mfg: [MfgRecord]
        public var serviceData: [ServiceDataRecord]
        public var uuids: [String]

        public init(
            flags: Int? = nil, txPower: Int? = nil, appearance: Int? = nil, advertisingIntervalMs: Double? = nil,
            deviceClass: Int? = nil, localName: String? = nil, mfg: [MfgRecord] = [],
            serviceData: [ServiceDataRecord] = [], uuids: [String] = []
        ) {
            self.flags = flags; self.txPower = txPower; self.appearance = appearance
            self.advertisingIntervalMs = advertisingIntervalMs; self.deviceClass = deviceClass
            self.localName = localName; self.mfg = mfg; self.serviceData = serviceData; self.uuids = uuids
        }
    }

    /// macOS replacement for Android `facts(ScanResult)`. CoreBluetooth reports connectable and
    /// (sometimes) TX power outside the AD bytes; there is no address type, PHY or periodic interval.
    /// Same precedence as Android: scan-reported TX power beats the advertised one.
    public static func facts(parsed: Parsed, connectable: Bool?, txPowerFromScan: Int?) -> RadioFacts {
        RadioFacts(
            txPowerDbm: txPowerFromScan ?? parsed.txPower,
            advFlags: parsed.flags,
            appearance: parsed.appearance,
            addressType: nil,
            advertisingIntervalMs: parsed.advertisingIntervalMs,
            periodicIntervalMs: nil,
            connectable: connectable,
            primaryPhy: nil,
            secondaryPhy: nil,
            deviceClass: parsed.deviceClass,
            mfgRecords: parsed.mfg,
            serviceData: parsed.serviceData
        )
    }

    public static func parse(bytes: [UInt8]?) -> Parsed {
        guard let bytes, bytes.isNotEmpty else { return Parsed() }
        var flags: Int?
        var txPower: Int?
        var appearance: Int?
        var interval: Double?
        var deviceClass: Int?
        var localName: String?
        var mfg: [MfgRecord] = []
        var serviceData: [ServiceDataRecord] = []
        var uuids: [String] = []
        var i = 0
        while i < bytes.count {
            let len = Int(bytes[i])
            if len == 0 { break }
            if i + len >= bytes.count { break }
            let type = Int(bytes[i + 1])
            let start = i + 2
            let end = i + 1 + len
            let data = bytes.copyOfRange(start, end)
            switch type {
            case 0x01: if data.isNotEmpty { flags = Int(data[0]) }
            case 0x02, 0x03, 0x14: uuids += uuid16List(data)
            case 0x04, 0x05, 0x1F: uuids += uuid32List(data)
            case 0x06, 0x07, 0x15: uuids += uuid128List(data)
            case 0x08, 0x09:
                let n = utf8Name(data)
                if n.isNotEmpty && (type == 0x09 || localName == nil) { localName = n }
            case 0x0A: if data.isNotEmpty { txPower = data.s8(0) }
            case 0x0D:
                if data.count >= 3 { deviceClass = Int(data[0]) | (Int(data[1]) << 8) | (Int(data[2]) << 16) }
            case 0x16:
                if data.count >= 2 {
                    let uuid = hex2(Int(data[1])) + hex2(Int(data[0]))
                    serviceData.append(ServiceDataRecord(uuid: uuid, dataHex: data.copyOfRange(2, data.count).toHexUpper()))
                }
            case 0x19:
                if data.count >= 2 { appearance = Int(data[0]) | (Int(data[1]) << 8) }
            case 0x1A:
                if data.count >= 2 {
                    let units = Int(data[0]) | (Int(data[1]) << 8)
                    interval = Double(units) * 0.625
                }
            case 0x20:
                if data.count >= 4 {
                    let uuid = hex2(Int(data[3])) + hex2(Int(data[2])) + hex2(Int(data[1])) + hex2(Int(data[0]))
                    serviceData.append(ServiceDataRecord(uuid: uuid, dataHex: data.copyOfRange(4, data.count).toHexUpper()))
                }
            case 0x21:
                if data.count >= 16 {
                    let uuid = uuidFromLe(data.copyOfRange(0, 16))
                    serviceData.append(ServiceDataRecord(uuid: uuid, dataHex: data.copyOfRange(16, data.count).toHexUpper()))
                }
            case 0xFF:
                if data.count >= 2 {
                    let id = Int(data[0]) | (Int(data[1]) << 8)
                    mfg.append(MfgRecord(companyId: id, dataHex: data.copyOfRange(2, data.count).toHexUpper()))
                }
            default: break
            }
            i += len + 1
        }
        return Parsed(flags: flags, txPower: txPower, appearance: appearance, advertisingIntervalMs: interval,
                      deviceClass: deviceClass, localName: localName, mfg: mfg, serviceData: serviceData,
                      uuids: uuids.distinct())
    }

    /// Rebuild standard AD structures from what CoreBluetooth reports, so `parse` and rawHex keep working.
    /// - manufacturerData: CoreBluetooth bytes, first two already the little-endian company id.
    /// - UUID strings as CBUUID prints them ("FEAA", "6E400001-B5A3-F393-E0A9-E50E24DCCA9E").
    ///   Bluetooth SIG base UUIDs collapse to 16-bit (or 32-bit); anything unparseable is skipped.
    /// - overflowUuids (iOS background overflow area) go into the "incomplete" UUID lists.
    /// Each AD structure is capped at 255 bytes; longer content is truncated (whole UUIDs, whole characters).
    public static func buildAdvertisement(
        localName: String?,
        manufacturerData: [UInt8]?,
        serviceUuids: [String],
        serviceData: [(uuid: String, data: [UInt8])],
        txPower: Int?,
        solicitedUuids: [String] = [],
        overflowUuids: [String] = []
    ) -> [UInt8] {
        var out: [UInt8] = []
        func ad(_ type: UInt8, _ data: [UInt8]) {
            let body = data.take(maxAdData)
            out.append(UInt8(body.count + 1))
            out.append(type)
            out += body
        }
        func uuidList(_ uuids: [String], _ t16: UInt8, _ t32: UInt8, _ t128: UInt8) {
            var w16: [[UInt8]] = [], w32: [[UInt8]] = [], w128: [[UInt8]] = []
            for u in uuids.compactMap({ uuidLeBytes($0) }).distinct() {
                switch u.count {
                case 2: w16.append(u)
                case 4: w32.append(u)
                default: w128.append(u)
                }
            }
            for (list, type, size) in [(w16, t16, 2), (w32, t32, 4), (w128, t128, 16)] where list.isNotEmpty {
                ad(type, Array(list.take(maxAdData / size).joined()))
            }
        }

        if let name = localName, name.isNotEmpty {
            // Truncate on a character boundary so parse never sees half a UTF-8 sequence.
            var bytes: [UInt8] = []
            for ch in name {
                let b = Array(String(ch).utf8)
                if bytes.count + b.count > maxAdData { break }
                bytes += b
            }
            if bytes.isNotEmpty { ad(0x09, bytes) }
        }
        if let m = manufacturerData, m.isNotEmpty { ad(0xFF, m) }
        uuidList(serviceUuids, 0x03, 0x05, 0x07)
        uuidList(overflowUuids, 0x02, 0x04, 0x06)
        for sd in serviceData {
            guard let u = uuidLeBytes(sd.uuid) else { continue }
            let type: UInt8 = u.count == 2 ? 0x16 : (u.count == 4 ? 0x20 : 0x21)
            ad(type, u + sd.data)
        }
        if let tx = txPower { ad(0x0A, [UInt8(bitPattern: Int8(clamping: tx))]) }
        uuidList(solicitedUuids, 0x14, 0x1F, 0x15)
        return out
    }

    /// AD structure length byte covers type + data, so data is at most 254 bytes.
    private static let maxAdData = 254

    /// Little-endian on-air bytes for a UUID string: 2 (16-bit), 4 (32-bit) or 16 bytes. Nil if not a UUID.
    private static func uuidLeBytes(_ raw: String) -> [UInt8]? {
        var hex = raw.filterHex().uppercased()
        let sigSuffix = "00001000800000805F9B34FB"
        if hex.count == 32 && hex.hasSuffix(sigSuffix) {
            hex = hex.hasPrefix("0000") ? hex.substring(4, 8) : hex.substring(0, 8)
        }
        guard [4, 8, 32].contains(hex.count), let be = hex.hexToBytes() else { return nil }
        return be.reversed()
    }

    public static func flagsLabel(flags: Int) -> String {
        var out: [String] = []
        if flags & 0x01 != 0 { out.append("LE Limited Discoverable") }
        if flags & 0x02 != 0 { out.append("LE General Discoverable") }
        if flags & 0x04 != 0 { out.append("BR/EDR not supported") }
        if flags & 0x08 != 0 { out.append("Simultaneous LE + BR/EDR (Controller)") }
        if flags & 0x10 != 0 { out.append("Simultaneous LE + BR/EDR (Host)") }
        if out.isEmpty { out.append("0x\(hex2(flags))") }
        return out.joined(separator: ", ")
    }

    public static func mfgDecodedFields(record: MfgRecord) -> [(String, String)] {
        AdvPayloadDecoder.decodeManufacturer(record: record).map { ($0.label, $0.value) }
    }

    private static func utf8Name(_ data: [UInt8]) -> String {
        if data.isEmpty { return "" }
        let decoded = String(decoding: data, as: UTF8.self).trim().trim("\u{0}")
        // Map control characters per scalar (Kotlin works per UTF-16 char; "\r\n" must become two spaces).
        var scalars = String.UnicodeScalarView()
        for u in decoded.unicodeScalars {
            let v = u.value
            scalars.append((v <= 0x1F || (v >= 0x7F && v <= 0x9F)) ? " " : u)
        }
        return String(scalars).trim().take(48)
    }

    private static func uuid16List(_ data: [UInt8]) -> [String] {
        data.chunked(2).compactMap { p in p.count < 2 ? nil : hex2(Int(p[1])) + hex2(Int(p[0])) }
    }

    private static func uuid32List(_ data: [UInt8]) -> [String] {
        data.chunked(4).compactMap { p in
            p.count < 4 ? nil : hex2(Int(p[3])) + hex2(Int(p[2])) + hex2(Int(p[1])) + hex2(Int(p[0]))
        }
    }

    private static func uuid128List(_ data: [UInt8]) -> [String] {
        data.chunked(16).compactMap { p in p.count < 16 ? nil : uuidFromLe(p) }
    }

    private static func uuidFromLe(_ le: [UInt8]) -> String {
        let h = Array(le.reversed()).toHexUpper()
        return "\(h.substring(0, 8))-\(h.substring(8, 12))-\(h.substring(12, 16))-\(h.substring(16, 20))-\(h.substring(20, 32))"
    }
}
