import Foundation

/// Decode well-known BLE advertisement payloads: Apple Continuity / iBeacon,
/// Google Fast Pair, Eddystone, Microsoft CDP. After company ID / UUID the rest
/// is proprietary; only published or well-reverse-engineered layouts are named.
public enum AdvPayloadDecoder {
    public struct Field: Hashable, Sendable {
        public var label: String
        public var value: String
        public init(label: String, value: String) { self.label = label; self.value = value }
    }

    public struct RoleHint: Hashable, Sendable {
        public var bucket: String
        public var label: String
        public var reason: String
        public var weight: Int
        public init(bucket: String, label: String, reason: String, weight: Int) {
            self.bucket = bucket; self.label = label; self.reason = reason; self.weight = weight
        }
    }

    private static func F(_ label: String, _ value: String) -> Field { Field(label: label, value: value) }
    private static func H(_ bucket: String, _ label: String, _ reason: String, _ weight: Int) -> RoleHint {
        RoleHint(bucket: bucket, label: label, reason: reason, weight: weight)
    }

    public static func decodeManufacturer(record: MfgRecord) -> [Field] {
        guard let bytes = hexToBytes(record.dataHex) else { return [] }
        switch record.companyId {
        case 0x004C: return decodeApple(bytes)
        case 0x0006: return decodeMicrosoft(bytes)
        case 0x0157: return decodeAltBeacon(bytes)
        case 0x00E0: return [F("Google manufacturer data", "\(bytes.count) bytes")]
        default: return []
        }
    }

    public static func decodeService(record: ServiceDataRecord) -> [Field] {
        guard let bytes = hexToBytes(record.dataHex) else { return [] }
        guard let short = uuid16(record.uuid) else { return [] }
        switch short {
        case 0xFE2C: return decodeFastPair(bytes)
        case 0xFEAA: return decodeEddystone(bytes)
        default: return []
        }
    }

    public static func roleHints(device: Sighting) -> [RoleHint] {
        var out: [RoleHint] = []
        let mfg = device.facts.mfgRecords.ifEmpty(
            device.manufacturerId.map { [MfgRecord(companyId: $0, dataHex: device.manufacturerDataHex)] } ?? []
        )
        for rec in mfg {
            if rec.companyId != 0x004C { continue }
            guard let bytes = hexToBytes(rec.dataHex) else { continue }
            for tlv in appleTlvs(bytes) {
                switch tlv.type {
                case 0x02:
                    if tlv.data.count >= 20 {
                        let hex = tlv.data.toHexUpper()
                        let teslaPrefix = DefaultCatalog.TESLA_IBEACON_MFG_PREFIX
                        let targetPrefix = DefaultCatalog.TARGET_ATRIUS_IBEACON_MFG_PREFIX
                        if hex.hasPrefix(teslaPrefix) || hex.hasPrefix(teslaPrefix.drop(4)) {
                            out.append(H("vehicle", "a Tesla vehicle or phone-as-key",
                                         "Tesla phone-key iBeacon UUID (iOS background find).", 8))
                        } else if hex.hasPrefix(targetPrefix) || hex.hasPrefix(targetPrefix.drop(4)) {
                            out.append(H("beacon", "an Atrius cart tag",
                                         "Atrius cart-tag iBeacon. The advertisement does not name the store.", 8))
                        } else {
                            out.append(H("beacon", "an iBeacon", "Apple iBeacon payload.", 7))
                        }
                    }
                case 0x05: out.append(H("phone", "an iPhone or iPad offering AirDrop", "Apple AirDrop advertisement.", 5))
                case 0x07:
                    let model = airPodsModel(tlv.data)
                    out.append(H("audio-personal", model ?? "AirPods or Beats headphones",
                                 model != nil ? "Apple Proximity Pairing: \(model!)." : "Apple Proximity Pairing (AirPods / Beats).", 8))
                case 0x08: out.append(H("siri", "an Apple device that just heard “Hey Siri”", "Hey Siri advertisement.", 6))
                case 0x09: out.append(H("audio-speaker", "an AirPlay speaker or Apple TV", "AirPlay advertisement.", 5))
                case 0x0B: out.append(H("phone", "an Apple device doing Handoff", "Handoff advertisement.", 4))
                case 0x0C: out.append(H("phone", "an Apple device looking for Instant Hotspot", "Tethering-target advertisement.", 5))
                case 0x0D, 0x0E: out.append(H("hotspot", "an iPhone/iPad offering Instant Hotspot", "Tethering-source advertisement.", 6))
                case 0x0F: out.append(H("phone", "an Apple device (Nearby Action)", nearbyActionReason(tlv.data), 4))
                case 0x10: out.append(H("phone", "an iPhone / iPad / Mac (Nearby Info)", nearbyInfoReason(tlv.data), 5))
                case 0x12:
                    out.append(H("tag", "a Find My network radio",
                                 "Apple Offline Finding — AirTag, Find My accessory, or an Apple device locating itself.", 4))
                default: break
                }
            }
        }
        for sd in device.facts.serviceData {
            switch uuid16(sd.uuid) {
            case 0xFE2C:
                guard let bytes = hexToBytes(sd.dataHex) else { continue }
                if bytes.count == 3 {
                    let id = modelId24(bytes)
                    let name = FastPairModels.name(modelId: id)
                    out.append(H(
                        "audio-personal",
                        name ?? "a Fast Pair accessory (often earbuds or a speaker)",
                        name != nil ? "Google Fast Pair model \(name!) (0x\(hexN(id, 6))), in pairing mode."
                            : "Google Fast Pair model 0x\(hexN(id, 6)), in pairing mode.",
                        name != nil ? 8 : 6
                    ))
                } else {
                    out.append(H("audio-personal", "a Fast Pair accessory already paired to someone",
                                 "Google Fast Pair account-key broadcast (not in pairing mode).", 4))
                }
            case 0xFEAA:
                let frame = hexToBytes(sd.dataHex)?.first.map { Int($0) }
                switch frame {
                case 0x40, 0x41:
                    out.append(H("tag", "a Google Find Hub tag",
                                 frame == 0x41 ? "Find Hub separated (unwanted-tracking) frame." : "Find Hub nearby frame.", 8))
                default:
                    out.append(H("beacon", "an Eddystone beacon", "Eddystone service data.", 6))
                }
            default: break
            }
        }
        return out
    }

    private struct Tlv { let type: Int; let data: [UInt8] }

    private static func decodeApple(_ bytes: [UInt8]) -> [Field] {
        let tlvs = appleTlvs(bytes)
        if tlvs.isEmpty { return [F("Apple payload", "\(bytes.count) bytes (unparsed)")] }
        var out: [Field] = []
        for tlv in tlvs {
            out.append(F("Apple Continuity type", "0x\(hex2(tlv.type)) · \(appleTypeName(tlv.type))"))
            switch tlv.type {
            case 0x02: out += decodeIBeacon(tlv.data)
            case 0x05: out += decodeAirDrop(tlv.data)
            case 0x06: out.append(F("HomeKit", "\(tlv.data.count) bytes of HomeKit setup data"))
            case 0x07: out += decodeAirPods(tlv.data)
            case 0x08: out += decodeHeySiri(tlv.data)
            case 0x09: out.append(F("AirPlay", "This device is advertising as an AirPlay source or target."))
            case 0x0A: out.append(F("Magic Switch", "Apple Watch wrist / unlock related."))
            case 0x0B: out += decodeHandoff(tlv.data)
            case 0x0C: out += decodeHandoffOrTetherTarget(tlv.data)
            case 0x0D, 0x0E: out += decodeTetherSource(tlv.data)
            case 0x0F: out += decodeNearbyAction(tlv.data)
            case 0x10: out += decodeNearbyInfo(tlv.data)
            case 0x12: out += decodeFindMy(tlv.data)
            default: out.append(F("Payload", "\(tlv.data.count) bytes"))
            }
        }
        return out
    }

    private static func appleTlvs(_ bytes: [UInt8]) -> [Tlv] {
        var out: [Tlv] = []
        var i = 0
        while i + 2 <= bytes.count {
            let type = Int(bytes[i])
            let len = Int(bytes[i + 1])
            if len <= 0 || i + 2 + len > bytes.count { break }
            out.append(Tlv(type: type, data: bytes.copyOfRange(i + 2, i + 2 + len)))
            i += 2 + len
        }
        return out
    }

    private static func appleTypeName(_ type: Int) -> String {
        switch type {
        case 0x02: return "iBeacon"
        case 0x03: return "AirPrint"
        case 0x05: return "AirDrop"
        case 0x06: return "HomeKit"
        case 0x07: return "Proximity Pairing (AirPods / Beats)"
        case 0x08: return "Hey Siri"
        case 0x09: return "AirPlay"
        case 0x0A: return "Magic Switch (Watch)"
        case 0x0B: return "Handoff"
        case 0x0C: return "Handoff or Instant Hotspot (target)"
        case 0x0D: return "Instant Hotspot (source)"
        case 0x0E: return "Instant Hotspot (source)"
        case 0x0F: return "Nearby Action"
        case 0x10: return "Nearby Info"
        case 0x12: return "Find My / Offline Finding"
        case 0x13: return "Nearby Action (extended)"
        case 0x16: return "Nearby Info"
        default: return "unlisted"
        }
    }

    private static func decodeIBeacon(_ data: [UInt8]) -> [Field] {
        // TLV length byte already consumed; data is 0x15 + 21 bytes OR 21 bytes.
        let body: [UInt8]
        if data.count >= 22 && data[0] == 0x15 { body = data.copyOfRange(1, 22) }
        else if data.count >= 21 { body = data.copyOfRange(0, 21) }
        else { return [F("iBeacon", "truncated (\(data.count) bytes)")] }
        let uuid = uuidFromBe(body, 0)
        let major = u16be(body, 16)
        let minor = u16be(body, 18)
        let tx = body.s8(20)
        let teslaKey = uuid.filterAlnum().equals(DefaultCatalog.TESLA_IBEACON_MFG_PREFIX.drop(4), ignoreCase: true)
        return [
            F("iBeacon UUID", teslaKey ? "\(uuid) — Tesla phone-as-key (iOS background find). Not a mall beacon." : uuid),
            F("iBeacon major / minor", "\(major) / \(minor)"),
            F("iBeacon calibrated TX", "\(tx) dBm at 1 m (used to estimate range)"),
        ]
    }

    private static func decodeAirDrop(_ data: [UInt8]) -> [Field] {
        // 8 zeros, version, appleID hash(2), phone(2), email(2), email2(2), 0
        if data.count < 18 { return [F("AirDrop", "Someone nearby is offering AirDrop (\(data.count) bytes).")] }
        return [
            F("AirDrop", "Someone nearby has AirDrop receiving on. Hashes are truncated IDs, not names."),
            F("Apple ID hash (2 bytes)", data.copyOfRange(9, 11).toHexUpper()),
        ]
    }

    private static func decodeAirPods(_ data: [UInt8]) -> [Field] {
        // prefix 0x01, model u16be, status, batt nibble, charge+case, lid, color, 0x00, enc 16
        if data.count < 5 { return [F("AirPods", "Proximity Pairing, truncated.")] }
        let start = data[0] == 0x01 ? 1 : 0
        if data.count < start + 4 { return [F("AirPods", "Proximity Pairing.")] }
        let model = (Int(data[start]) << 8) | Int(data[start + 1])
        let status = Int(data[start + 2])
        let batt = Int(data[start + 3])
        let left = batt & 0x0F
        let right = (batt >> 4) & 0x0F
        var out: [Field] = []
        out.append(F("Product", airPodsModelName(model) ?? "Apple audio 0x\(hexN(model, 4))"))
        out.append(F("Pod position", airPodsStatus(status)))
        out.append(F("Battery (left / right)", "\(nibblePct(left)) / \(nibblePct(right))"))
        if data.count > start + 4 {
            let ch = Int(data[start + 4])
            let caseBatt = ch & 0x0F
            var charging: [String] = []
            if ch & 0x10 != 0 { charging.append("case") }
            if ch & 0x20 != 0 { charging.append("right") }
            if ch & 0x40 != 0 { charging.append("left") }
            out.append(F("Case battery", nibblePct(caseBatt)))
            if charging.isNotEmpty { out.append(F("Charging", charging.joined(separator: ", "))) }
        }
        if data.count > start + 6 {
            out.append(F("Color", airPodsColor(Int(data[start + 6]))))
        }
        return out
    }

    private static func airPodsModel(_ data: [UInt8]) -> String? {
        if data.count < 4 { return nil }
        let start = data[0] == 0x01 ? 1 : 0
        if data.count < start + 2 { return nil }
        let model = (Int(data[start]) << 8) | Int(data[start + 1])
        return airPodsModelName(model)
    }

    private static func airPodsModelName(_ id: Int) -> String? {
        switch id {
        case 0x0220: return "AirPods (1st generation)"
        case 0x0F20: return "AirPods (2nd generation)"
        case 0x1320: return "AirPods (3rd generation)"
        case 0x1920: return "AirPods (4th generation)"
        case 0x1C20: return "AirPods 4"
        case 0x0E20: return "AirPods Pro"
        case 0x1420: return "AirPods Pro (2nd generation)"
        case 0x2420: return "AirPods Pro 2 (USB-C)"
        case 0x1F20: return "AirPods Max"
        case 0x0A20: return "Beats Solo3"
        case 0x0B20: return "Powerbeats 3"
        case 0x0C20: return "Beats Studio Buds"
        case 0x0D20: return "Beats Fit Pro"
        case 0x1020: return "Powerbeats Pro"
        case 0x1120: return "Beats Studio Buds +"
        case 0x1220: return "Beats Solo Pro"
        case 0x1720: return "Beats Flex"
        case 0x1A20: return "Beats Studio Pro"
        case 0x1B20: return "Beats Fit Pro"
        case 0x0520: return "BeatsX"
        case 0x0920: return "Beats Studio³ Wireless"
        case 0x1620: return "Beats Studio Buds +"
        case 0x2520: return "Beats Solo 4"
        case 0x2620: return "Beats Solo Buds"
        case 0x2D20: return "AirPods Max 2"
        case 0x3820: return "Beats 360"
        case 0x038F: return "Beats Studio Buds"
        default: return nil
        }
    }

    private static func airPodsStatus(_ status: Int) -> String {
        switch status {
        case 0x01: return "One or both out of the case"
        case 0x02: return "Case open"
        case 0x03: return "Taken out / in-ear transition"
        case 0x05: return "One in ear"
        case 0x09: return "Both out, not in ear"
        case 0x0B: return "In-ear activity"
        case 0x11, 0x13: return "Both in ear"
        case 0x21: return "One in ear (sharing?)"
        case 0x51: return "Both in case, lid open"
        case 0x55: return "Both in case, lid closed"
        case 0x75: return "In case"
        default: return "Status 0x\(hex2(status))"
        }
    }

    private static func airPodsColor(_ v: Int) -> String {
        switch v {
        case 0x00: return "White"
        case 0x01: return "Black"
        case 0x02: return "Red"
        case 0x03: return "Blue"
        case 0x04: return "Pink"
        case 0x05: return "Gray"
        case 0x06: return "Silver"
        case 0x07: return "Gold"
        case 0x08: return "Rose gold"
        case 0x09: return "Space gray"
        case 0x0A: return "Dark blue"
        case 0x0B: return "Light blue"
        case 0x0C: return "Yellow"
        default: return "0x\(hex2(v))"
        }
    }

    private static func nibblePct(_ n: Int) -> String {
        switch n {
        case 0...9: return "\(n * 10)%"
        case 10...14: return "100%"
        case 15: return "unknown / not present"
        default: return "\(n)"
        }
    }

    private static func decodeHeySiri(_ data: [UInt8]) -> [Field] {
        if data.count < 6 { return [F("Hey Siri", "Siri was just triggered on a nearby Apple device.")] }
        let klass = u16be(data, 4)
        let device: String
        switch klass {
        case 0x0002: device = "iPhone"
        case 0x0003: device = "iPad"
        case 0x0007: device = "HomePod"
        case 0x0009: device = "Mac"
        case 0x000A: device = "Watch"
        default: device = "class 0x\(hexN(klass, 4))"
        }
        return [F("Hey Siri", "A \(device) just heard a Siri trigger. The packet carries a short voice hash, not the words.")]
    }

    private static func decodeHandoff(_ data: [UInt8]) -> [Field] {
        [F("Handoff", "Continuity Handoff: a task can be continued on another Apple device. Payload is encrypted.")]
    }

    private static func decodeHandoffOrTetherTarget(_ data: [UInt8]) -> [Field] {
        data.count >= 14 ? decodeHandoff(data)
            : [F("Instant Hotspot (looking)", "This Apple device is searching for a paired phone’s hotspot.")]
    }

    private static func decodeTetherSource(_ data: [UInt8]) -> [Field] {
        if data.count < 6 { return [F("Instant Hotspot", "An iPhone/iPad is offering a personal hotspot.")] }
        let batt = Int(data[2])
        let cell = data.count >= 5 ? u16be(data, 3) : -1
        let bars = data.count >= 6 ? Int(data[5]) : -1
        let cellName: String?
        switch cell {
        case 0, 6: cellName = "4G"
        case 1: cellName = "1xRTT"
        case 2: cellName = "GPRS"
        case 3: cellName = "EDGE"
        case 4, 5: cellName = "3G"
        case 7: cellName = "LTE"
        case 8: cellName = "5G"
        default: cellName = cell >= 0 ? "type \(cell)" : nil
        }
        var s = "Paired iPhone/iPad hotspot"
        if (0...100).contains(batt) { s += " · phone battery \(batt)%" }
        if let cellName { s += " · \(cellName)" }
        if (0...5).contains(bars) { s += " · \(bars)/5 bars" }
        return [F("Instant Hotspot (offering)", s)]
    }

    private static func decodeNearbyAction(_ data: [UInt8]) -> [Field] {
        if data.isEmpty { return [F("Nearby Action", "Apple Nearby Action")] }
        let action = data.count >= 2 ? Int(data[1]) : Int(data[0])
        return [F("Nearby Action", nearbyActionName(action))]
    }

    private static func nearbyActionReason(_ data: [UInt8]) -> String {
        guard data.count >= 2 else { return "Nearby Action advertisement." }
        return "Nearby Action: \(nearbyActionName(Int(data[1])))."
    }

    private static func nearbyActionName(_ action: Int) -> String {
        switch action {
        case 0x01: return "Apple TV setup"
        case 0x04: return "Mobile backup"
        case 0x05: return "Watch setup"
        case 0x06: return "Apple TV pair"
        case 0x08: return "Wi-Fi password sharing (prompting nearby iPhones)"
        case 0x09: return "iOS setup"
        case 0x0A: return "Repair"
        case 0x0B: return "Speaker setup"
        case 0x0C: return "Apple Pay"
        case 0x0D: return "Whole-home audio setup"
        case 0x0F: return "Answered a call"
        case 0x10: return "Ended a call"
        case 0x13: return "Remote AutoFill"
        case 0x14: return "Companion Link proximity"
        case 0x17: return "Remote display"
        default: return "action 0x\(hex2(action))"
        }
    }

    private static func decodeNearbyInfo(_ data: [UInt8]) -> [Field] {
        if data.isEmpty { return [F("Nearby Info", "Apple device usage state.")] }
        let status = Int(data[0])
        let action = status & 0x0F
        let flagsHi = (status >> 4) & 0x0F
        let dataFlags = data.count > 1 ? Int(data[1]) : 0
        let activity: String
        switch action {
        case 0x00: activity = "activity unknown"
        case 0x01: activity = "activity reporting off"
        case 0x03: activity = "idle (screen locked)"
        case 0x05: activity = "audio playing, screen locked"
        case 0x07: activity = "active (screen on)"
        case 0x09: activity = "screen on, video playing"
        case 0x0A: activity = "Watch on wrist and unlocked"
        case 0x0B: activity = "recent interaction"
        case 0x0D: activity = "user is driving"
        case 0x0E: activity = "phone or FaceTime call"
        default: activity = "activity 0x\(format("%X", action))"
        }
        var extras: [String] = []
        if flagsHi & 0x1 != 0 { extras.append("primary iCloud device") }
        if flagsHi & 0x4 != 0 { extras.append("AirDrop receiving on") }
        if dataFlags & 0x04 != 0 { extras.append("Wi-Fi on") }
        if dataFlags & 0x01 != 0 { extras.append("AirPods connected") }
        if dataFlags & 0x20 != 0 { extras.append("Watch locked") }
        var s = activity.capitalizedFirst()
        if extras.isNotEmpty {
            s += ". "
            s += extras.joined(separator: "; ")
        }
        s += "."
        return [F("What the Apple device is doing", s)]
    }

    private static func nearbyInfoReason(_ data: [UInt8]) -> String {
        if data.isEmpty { return "Nearby Info advertisement." }
        switch Int(data[0]) & 0x0F {
        case 0x03: return "Phone is idle / locked."
        case 0x05: return "Audio playing with the screen locked."
        case 0x07: return "Screen is on — someone is using it."
        case 0x0D: return "Device reports the user is driving."
        case 0x0E: return "In a phone or FaceTime call."
        default: return "Nearby Info advertisement."
        }
    }

    private static func decodeFindMy(_ data: [UInt8]) -> [Field] {
        if data.isEmpty { return [F("Find My", "Offline Finding advertisement.")] }
        let status = Int(data[0])
        let maintained = status & 0x04 != 0
        let batt = (status >> 6) & 0x3
        let battName: String
        switch batt {
        case 0: battName = "full"
        case 1: battName = "medium"
        case 2: battName = "low"
        default: battName = "critical"
        }
        let keyLen = (data.count - 1).coerceAtLeast(0)
        var s = "Broadcasting a public key so the Find My network can report a location. "
        s += "Used by AirTags, Find My accessories, and Apple devices locating themselves. "
        s += maintained ? "Owner seen recently. " : "Owner not seen in the current key window. "
        if maintained || (0...3).contains(batt) { s += "Battery \(battName). " }
        s += "(\(keyLen)-byte key fragment — not a serial number.)"
        return [F("Find My / Offline Finding", s)]
    }

    private static func decodeFastPair(_ bytes: [UInt8]) -> [Field] {
        if bytes.count == 3 {
            let id = modelId24(bytes)
            let name = FastPairModels.name(modelId: id)
            return [
                F("Google Fast Pair", "In pairing mode — Android will pop a tap-to-pair card."),
                F("Model ID", name != nil ? "\(name!)  (0x\(hexN(id, 6)))" : "0x\(hexN(id, 6)) (not in the local name list)"),
            ]
        }
        if bytes.isEmpty { return [] }
        let verFlags = Int(bytes[0])
        let version = (verFlags >> 4) & 0x0F
        let ui: String
        if bytes.count > 1 {
            let type = Int(bytes[1]) & 0x0F
            switch type {
            case 0x0: ui = "wants to show a pairing card"
            case 0x2: ui = "hiding the pairing card (e.g. buds back in the case)"
            default: ui = "filter type \(type)"
            }
        } else {
            ui = "account-key bloom filter"
        }
        return [F("Google Fast Pair", "Already paired to an account (not in pairing mode). \(ui). Version \(version).")]
    }

    private static func decodeEddystone(_ bytes: [UInt8]) -> [Field] {
        if bytes.isEmpty { return [] }
        switch Int(bytes[0]) {
        case 0x00:
            if bytes.count < 18 { return [F("Eddystone-UID", "truncated")] }
            return [
                F("Eddystone-UID namespace", bytes.copyOfRange(2, 12).toHexUpper()),
                F("Eddystone-UID instance", bytes.copyOfRange(12, 18).toHexUpper()),
            ]
        case 0x10: return [F("Eddystone-URL", eddystoneUrl(bytes) ?? "\(bytes.count) bytes")]
        case 0x20: return [F("Eddystone-TLM", "telemetry (battery / temperature / advert count)")]
        case 0x30: return [F("Eddystone-EID", "ephemeral ID (rotating)")]
        case 0x40, 0x41:
            let mode = bytes[0] == 0x41 ? "separated (unwanted-tracking mode)" : "nearby / with owner"
            let eidLen: Int
            if bytes.count >= 33 { eidLen = 32 }
            else if bytes.count >= 21 { eidLen = 20 }
            else { eidLen = (bytes.count - 1).coerceAtLeast(0) }
            let eid = eidLen > 0 ? bytes.copyOfRange(1, 1 + eidLen).toHexUpper() : ""
            return [F("Find Hub", mode), F("Find Hub EID", eid.ifBlank("\(bytes.count) bytes"))]
        default:
            return [F("Eddystone", "frame 0x\(hex2(Int(bytes[0])))")]
        }
    }

    private static func eddystoneUrl(_ bytes: [UInt8]) -> String? {
        if bytes.count < 3 { return nil }
        let scheme: String
        switch Int(bytes[2]) {
        case 0: scheme = "http://www."
        case 1: scheme = "https://www."
        case 2: scheme = "http://"
        case 3: scheme = "https://"
        default: return nil
        }
        let expansions = [
            ".com/", ".org/", ".edu/", ".net/", ".info/", ".biz/", ".gov/",
            ".com", ".org", ".edu", ".net", ".info", ".biz", ".gov",
        ]
        var sb = scheme
        for i in 3..<bytes.count {
            let b = Int(bytes[i])
            if b < expansions.count { sb += expansions[b] }
            else if (0x20...0x7E).contains(b) { sb.append(Character(UnicodeScalar(UInt8(b)))) }
        }
        return sb
    }

    private static func decodeMicrosoft(_ bytes: [UInt8]) -> [Field] {
        if bytes.isEmpty { return [] }
        if bytes[0] == 0x01 && bytes.count >= 2 {
            let type = Int(bytes[1]) & 0x1F
            let kind: String
            switch type {
            case 1: kind = "Xbox"
            case 6: kind = "iPhone"
            case 7: kind = "iPad"
            case 8: kind = "Android"
            case 9: kind = "Windows desktop"
            case 11: kind = "Windows phone"
            case 12: kind = "Linux"
            case 13: kind = "Windows IoT"
            case 14: kind = "Surface Hub"
            case 15: kind = "Windows laptop"
            case 16: kind = "Windows tablet"
            default: kind = "type \(type)"
            }
            return [F("Microsoft Nearby Sharing / Swift Pair", "A \(kind) is advertising for quick pairing or sharing.")]
        }
        return [F("Microsoft manufacturer data", "\(bytes.count) bytes")]
    }

    private static func decodeAltBeacon(_ bytes: [UInt8]) -> [Field] {
        if bytes.count >= 22 && bytes[0] == 0xBE && bytes[1] == 0xAC {
            return [
                F("AltBeacon UUID", uuidFromBe(bytes, 2)),
                F("AltBeacon major / minor", "\(u16be(bytes, 18)) / \(u16be(bytes, 20))"),
            ]
        }
        return []
    }

    private static func modelId24(_ bytes: [UInt8]) -> Int {
        (Int(bytes[0]) << 16) | (Int(bytes[1]) << 8) | Int(bytes[2])
    }

    private static func u16be(_ data: [UInt8], _ offset: Int) -> Int {
        (Int(data[offset]) << 8) | Int(data[offset + 1])
    }

    private static func uuidFromBe(_ data: [UInt8], _ offset: Int) -> String {
        func h(_ i: Int) -> String { hex2(Int(data[offset + i])).lowercased() }
        return "\(h(0))\(h(1))\(h(2))\(h(3))-\(h(4))\(h(5))-\(h(6))\(h(7))-\(h(8))\(h(9))-\(h(10))\(h(11))\(h(12))\(h(13))\(h(14))\(h(15))"
    }

    private static func uuid16(_ uuid: String) -> Int? {
        let hex = uuid.filterAlnum().uppercased()
        if hex.count == 4 { return hex.toIntOrNull(16) }
        if hex.count == 32 && hex.hasPrefix("0000") && hex.hasSuffix("00001000800000805F9B34FB") {
            return hex.substring(4, 8).toIntOrNull(16)
        }
        return nil
    }

    /// Kotlin threw on non-hex letters; here that returns nil (treated as no payload).
    private static func hexToBytes(_ hex: String) -> [UInt8]? {
        let h = hex.filterAlnum()
        if h.isEmpty || h.count % 2 != 0 { return nil }
        return h.hexToBytes()
    }
}
