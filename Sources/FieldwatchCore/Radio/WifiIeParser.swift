import Foundation

/// 802.11 information-element parsing. macOS CoreWLAN hands over the raw IE blob
/// (`CWNetwork.informationElementData`: repeated [id, len, data...]) instead of an Android ScanResult,
/// so everything here is byte-based. Android's `capabilities` string, Wi-Fi standard and channel width
/// are derived from the IEs.
public enum WifiIeParser {
    public struct Parsed: Hashable, Sendable {
        public var rates: String?
        public var security: String?
        public var vendorIes: [VendorIeRecord]
        public var channelFromDs: Int?
        /// macOS addition: the elements this was parsed from (for capabilitiesString / standard / width).
        public var elements: [Ie]

        public init(rates: String? = nil, security: String? = nil, vendorIes: [VendorIeRecord] = [],
                    channelFromDs: Int? = nil, elements: [Ie] = []) {
            self.rates = rates; self.security = security; self.vendorIes = vendorIes
            self.channelFromDs = channelFromDs; self.elements = elements
        }
    }

    /// One raw information element: element id + payload bytes.
    public struct Ie: Hashable, Sendable {
        public var id: Int
        public var bytes: [UInt8]
        public init(id: Int, bytes: [UInt8]) { self.id = id; self.bytes = bytes }
    }

    /// Split a raw IE blob. A truncated trailing element is dropped.
    public static func elements(ies: [UInt8]) -> [Ie] {
        var out: [Ie] = []
        var i = 0
        while i + 2 <= ies.count {
            let id = Int(ies[i])
            let len = Int(ies[i + 1])
            if i + 2 + len > ies.count { break }
            out.append(Ie(id: id, bytes: ies.copyOfRange(i + 2, i + 2 + len)))
            i += 2 + len
        }
        return out
    }

    /// macOS entry point (Android `parse(ScanResult)`). With no RSN/WPA IE the security falls back to the
    /// Android-style capability string built from the same IEs (e.g. "[ESS]" for an open network).
    public static func parse(ies: [UInt8]) -> Parsed {
        let els = elements(ies: ies)
        if els.isEmpty { return Parsed() }
        var p = parseIes(ies: els, capabilities: capabilitiesString(parsed: Parsed(elements: els)))
        p.elements = els
        return p
    }

    /// Pure decode of a captured IE set — unit tests feed frames directly.
    public static func parseIes(ies: [Ie], capabilities: String?) -> Parsed {
        var rates: [String] = []
        var vendor: [VendorIeRecord] = []
        var sec: [String] = []
        var ds: Int?
        for ie in ies {
            let bytes = ie.bytes
            switch ie.id {
            case 1, 50: rates += decodeRates(bytes)
            case 3: if bytes.isNotEmpty { ds = Int(bytes[0]) }
            case 48: if let s = rsnSummary(bytes) { sec.append(s) }
            case 221:
                if bytes.count >= 3 {
                    let oui = ouiString(bytes)
                    let type = bytes.count > 3 ? Int(bytes[3]) : 0
                    let payload = bytes.count > 4 ? bytes.copyOfRange(4, bytes.count.coerceAtMost(4 + 200)) : []
                    vendor.append(VendorIeRecord(oui: oui, type: type, dataHex: payload.toHexUpper()))
                    if oui == "00:50:F2" && type == 1, let s = wpaSummary(bytes) { sec.append(s) }
                }
            default: break
            }
        }
        let cap = capabilities ?? ""
        if sec.isEmpty && cap.isNotBlank { sec.append(cap) }
        return Parsed(
            rates: rates.distinct().joined(separator: " ").nonBlank,
            security: sec.distinct().joined(separator: " · ").nonBlank ?? cap.nonBlank,
            vendorIes: Array(vendor.distinctBy { "\($0.oui)|\($0.type)" }.take(12)),
            channelFromDs: ds,
            elements: ies
        )
    }

    /// Distinct vendor-specific IE (221) OUIs in order, "AA:BB:CC".
    public static func vendorIeOuis(ies: [UInt8]) -> [String] {
        elements(ies: ies).filter { $0.id == 221 && $0.bytes.count >= 3 }.map { ouiString($0.bytes) }.distinct()
    }

    // MARK: - Channel / frequency (Android WifiRadio.channelOf + inverse)

    /// MHz → channel number. 0 when unknown. (Kotlin tested 2412..2484 first, which made 2484 channel 15;
    /// 2484 is checked first here so it is channel 14.)
    public static func channelOf(freq: Int) -> Int {
        if freq == 2484 { return 14 }
        if (2412...2484).contains(freq) { return (freq - 2407) / 5 }
        if (5000...5895).contains(freq) { return (freq - 5000) / 5 }
        if (5955...7115).contains(freq) { return (freq - 5955) / 5 + 1 }
        return 0
    }

    /// Channel number + band (2 = 2.4 GHz, 5, 6) → center MHz. 0 when unknown. CoreWLAN reports channels, not MHz.
    public static func frequencyOf(channel: Int, band: Int) -> Int {
        switch band {
        case 2:
            if channel == 14 { return 2484 }
            return (1...13).contains(channel) ? 2407 + 5 * channel : 0
        case 5:
            return (1...196).contains(channel) ? 5000 + 5 * channel : 0
        case 6:
            if channel == 2 { return 5935 }
            return (1...233).contains(channel) ? 5950 + 5 * channel : 0
        default:
            return 0
        }
    }

    // MARK: - Standard / width from HT, VHT, HE, EHT elements

    /// Android `ScanResult.wifiStandard` label from capability/operation IEs. Nil when there are no IEs.
    /// VHT only counts on 5 GHz (some 2.4 GHz APs advertise vendor VHT), like Android.
    public static func wifiStandardLabel(ies: [UInt8], band: Int? = nil) -> String? {
        let els = elements(ies: ies)
        if els.isEmpty { return nil }
        if hasExt(els, 106) || hasExt(els, 108) { return "802.11be" }
        if hasExt(els, 35) || hasExt(els, 36) { return "802.11ax" }
        if els.any({ $0.id == 191 || $0.id == 192 }) && band != 2 && band != 6 { return "802.11ac" }
        if els.any({ $0.id == 45 || $0.id == 61 }) { return "802.11n" }
        return "802.11a/b/g"
    }

    /// Android `ScanResult.channelWidth` label ("20 MHz" … "320 MHz", "80+80 MHz") from operation IEs.
    /// `channel` is accepted for API symmetry (the IEs carry the segment centers). Nil when there are no IEs.
    public static func channelWidthLabel(ies: [UInt8], channel: Int? = nil, band: Int? = nil) -> String? {
        let els = elements(ies: ies)
        if els.isEmpty { return nil }
        // EHT Operation: params(1) + basic MCS/NSS(4) + [control, ccfs0, ccfs1] when bit 0 set.
        if let eht = ext(els, 106), eht.count >= 1, eht[0] & 0x01 != 0, eht.count >= 1 + 4 + 3 {
            switch Int(eht[5]) & 0x07 {
            case 0: return "20 MHz"
            case 1: return "40 MHz"
            case 2: return "80 MHz"
            case 3: return "160 MHz"
            case 4: return "320 MHz"
            default: break
            }
        }
        // HE Operation: params(3) + BSS color(1) + basic MCS(2) + [VHT op info 3] + [co-hosted 1] + [6 GHz info 5].
        if let he = ext(els, 36), he.count >= 6 {
            let params = Int(he[0]) | (Int(he[1]) << 8) | (Int(he[2]) << 16)
            var o = 6
            var heVht: [UInt8]?
            if params & (1 << 14) != 0 {
                if o + 3 <= he.count { heVht = he.copyOfRange(o, o + 3) }
                o += 3
            }
            if params & (1 << 15) != 0 { o += 1 }
            if params & (1 << 17) != 0, o + 5 <= he.count {
                let control = Int(he[o + 1]) & 0x03
                let c0 = Int(he[o + 2]), c1 = Int(he[o + 3])
                switch control {
                case 0: return "20 MHz"
                case 1: return "40 MHz"
                case 2: return "80 MHz"
                default: return (c1 != 0 && abs(c1 - c0) != 8) ? "80+80 MHz" : "160 MHz"
                }
            }
            if band != 2, let v = heVht, let w = vhtWidth(v) { return w }
        }
        if band != 2, let vht = els.first(where: { $0.id == 192 })?.bytes, vht.count >= 3, let w = vhtWidth(vht) {
            return w
        }
        if let ht = els.first(where: { $0.id == 61 })?.bytes, ht.count >= 2 {
            let offset = Int(ht[1]) & 0x03
            let any = Int(ht[1]) & 0x04 != 0
            return (any && (offset == 1 || offset == 3)) ? "40 MHz" : "20 MHz"
        }
        return "20 MHz"
    }

    /// VHT Operation Information [width, ccfs0, ccfs1]. Width 0 means 20/40 (defer to HT).
    private static func vhtWidth(_ v: [UInt8]) -> String? {
        let width = Int(v[0]), c0 = Int(v[1]), c1 = Int(v[2])
        switch width {
        case 1:
            if c1 == 0 { return "80 MHz" }
            return abs(c1 - c0) == 8 ? "160 MHz" : "80+80 MHz"
        case 2: return "160 MHz"
        case 3: return "80+80 MHz"
        default: return nil
        }
    }

    private static func ext(_ els: [Ie], _ extId: Int) -> [UInt8]? {
        guard let e = els.first(where: { $0.id == 255 && $0.bytes.isNotEmpty && Int($0.bytes[0]) == extId }) else { return nil }
        return Array(e.bytes.dropFirst())
    }

    private static func hasExt(_ els: [Ie], _ extId: Int) -> Bool { ext(els, extId) != nil }

    // MARK: - Android-style capabilities string

    /// Android `ScanResult.capabilities` equivalent, e.g. "[WPA2-PSK-CCMP][RSN-PSK-CCMP][ESS][WPS]".
    /// The ESS/IBSS and privacy bits live in the beacon's fixed fields, not the IEs: pass `ibss`
    /// (CoreWLAN `ibss`) and `privacy` (WEP when no RSN/WPA) when known. Mesh comes from the Mesh ID IE.
    public static func capabilitiesString(parsed: Parsed, ibss: Bool = false, privacy: Bool = false) -> String {
        var s = ""
        var anyKey = false
        for ie in parsed.elements {
            if ie.id == 221, ie.bytes.count >= 4, ouiString(ie.bytes) == "00:50:F2", ie.bytes[3] == 1,
               let w = suites(ie.bytes, start: 4, rsn: false) {
                s += "[WPA-\(w.akm)-\(w.ciphers)]"
                anyKey = true
            }
        }
        if let rsn = parsed.elements.first(where: { $0.id == 48 }), let r = suites(rsn.bytes, start: 0, rsn: true) {
            s += "[WPA2-\(r.akm)-\(r.ciphers)][RSN-\(r.akm)-\(r.ciphers)]"
            anyKey = true
        }
        if !anyKey && privacy { s += "[WEP]" }
        if parsed.elements.contains(where: { $0.id == 114 }) { s += "[MESH]" }
        s += ibss ? "[IBSS]" : "[ESS]"
        let wps = parsed.elements.contains { $0.id == 221 && $0.bytes.count >= 4 && ouiString($0.bytes) == "00:50:F2" && $0.bytes[3] == 4 }
        if wps { s += "[WPS]" }
        return s
    }

    /// AKM and pairwise names Android-style ("PSK+SAE", "CCMP+TKIP"). Nil on a truncated header.
    private static func suites(_ b: [UInt8], start: Int, rsn: Bool) -> (akm: String, ciphers: String)? {
        var o = start
        if o + 2 > b.count { return nil }
        let ver = u16(b, o); o += 2
        if ver != 1 { return nil }
        if o + 4 > b.count { return nil }
        let group = androidCipher(b, o); o += 4
        var pairwise: [String] = []
        if o + 2 <= b.count {
            let pc = u16(b, o); o += 2
            for _ in 0..<pc where o + 4 <= b.count {
                pairwise.append(androidCipher(b, o)); o += 4
            }
        }
        var akms: [String] = []
        if o + 2 <= b.count {
            let ac = u16(b, o); o += 2
            for _ in 0..<ac where o + 4 <= b.count {
                akms.append(androidAkm(b, o, rsn: rsn)); o += 4
            }
        }
        let akm = akms.isEmpty ? "EAP" : akms.distinct().joined(separator: "+")
        let ciphers = pairwise.isEmpty ? group : pairwise.distinct().joined(separator: "+")
        return (akm, ciphers)
    }

    private static func androidCipher(_ b: [UInt8], _ o: Int) -> String {
        guard let (oui, type) = ouiType(b, o), oui == "000FAC" || oui == "0050F2" else { return "?" }
        switch type {
        case 1, 5: return "WEP"
        case 2: return "TKIP"
        case 4: return "CCMP"
        case 8: return "GCMP"
        case 9: return "GCMP-256"
        case 10: return "CCMP-256"
        default: return "?"
        }
    }

    private static func androidAkm(_ b: [UInt8], _ o: Int, rsn: Bool) -> String {
        guard let (oui, type) = ouiType(b, o) else { return "?" }
        if !rsn {
            if oui == "0050F2" { return type == 2 ? "PSK" : "EAP" }
            return "?"
        }
        guard oui == "000FAC" else { return "?" }
        switch type {
        case 1: return "EAP"
        case 2: return "PSK"
        case 3: return "FT/EAP"
        case 4: return "FT/PSK"
        case 5: return "EAP-SHA256"
        case 6: return "PSK-SHA256"
        case 8: return "SAE"
        case 9: return "FT/SAE"
        case 11: return "EAP_SUITE_B"
        case 12: return "EAP_SUITE_B_192"
        case 18: return "OWE"
        default: return "?"
        }
    }

    // MARK: - Ported Kotlin decoders

    private static func decodeRates(_ bytes: [UInt8]) -> [String] {
        bytes.map { b in
            let raw = Int(b)
            let basic = raw & 0x80 != 0
            let mbps = Double(raw & 0x7F) / 2.0
            let label = mbps == Double(Int(mbps)) ? "\(Int(mbps))" : "\(mbps)"
            return basic ? "\(label)*" : label
        }
    }

    private static func rsnSummary(_ bytes: [UInt8]) -> String? {
        if bytes.count < 8 { return nil }
        var o = 0
        let ver = u16(bytes, o); o += 2
        if ver != 1 { return "RSN v\(ver)" }
        let group = cipherSuite(bytes, o); o += 4
        if o + 2 > bytes.count { return "RSN \(group)" }
        let pc = u16(bytes, o); o += 2
        var pairwise: [String] = []
        // Kotlin `return@repeat` skips the round; o does not move, so later rounds skip too.
        for _ in 0..<pc where o + 4 <= bytes.count {
            pairwise.append(cipherSuite(bytes, o)); o += 4
        }
        if o + 2 > bytes.count { return "RSN \(group) / \(pairwise.joined(separator: ","))" }
        let ac = u16(bytes, o); o += 2
        var akm: [String] = []
        for _ in 0..<ac where o + 4 <= bytes.count {
            akm.append(akmSuite(bytes, o)); o += 4
        }
        var s = "RSN "
        s += akm.joined(separator: "/").ifBlank("AKM?")
        s += " "
        s += pairwise.joined(separator: "/").ifBlank(group)
        if group.isNotBlank { s += " (group \(group))" }
        return s
    }

    private static func wpaSummary(_ bytes: [UInt8]) -> String? {
        if bytes.count < 10 { return "WPA" }
        var o = 4
        let ver = u16(bytes, o); o += 2
        if ver != 1 { return "WPA v\(ver)" }
        let group = cipherSuite(bytes, o); o += 4
        if o + 2 > bytes.count { return "WPA \(group)" }
        let pc = u16(bytes, o); o += 2
        var pairwise: [String] = []
        for _ in 0..<pc where o + 4 <= bytes.count {
            pairwise.append(cipherSuite(bytes, o)); o += 4
        }
        return "WPA \(pairwise.joined(separator: "/").ifBlank(group))"
    }

    private static func cipherSuite(_ bytes: [UInt8], _ offset: Int) -> String {
        guard let (oui, type) = ouiType(bytes, offset) else { return "?" }
        if oui == "000FAC" || oui == "0050F2" {
            switch type {
            case 0: return "Group"
            case 1: return "WEP-40"
            case 2: return "TKIP"
            case 4: return "CCMP"
            case 5: return "WEP-104"
            case 6: return "BIP"
            case 8: return "GCMP"
            case 9: return "GCMP-256"
            case 10: return "CCMP-256"
            default: return "cipher \(type)"
            }
        }
        return "\(oui)/\(type)"
    }

    private static func akmSuite(_ bytes: [UInt8], _ offset: Int) -> String {
        guard let (oui, type) = ouiType(bytes, offset) else { return "?" }
        if oui == "000FAC" {
            switch type {
            case 1: return "802.1X"
            case 2: return "PSK"
            case 3: return "FT-802.1X"
            case 4: return "FT-PSK"
            case 5: return "802.1X-SHA256"
            case 6: return "PSK-SHA256"
            case 8: return "SAE"
            case 9: return "FT-SAE"
            case 11: return "SUITE-B"
            case 12: return "SUITE-B-192"
            case 18: return "OWE"
            default: return "AKM \(type)"
            }
        }
        return "\(oui)/\(type)"
    }

    private static func ouiType(_ bytes: [UInt8], _ offset: Int) -> (String, Int)? {
        if offset + 4 > bytes.count { return nil }
        let oui = hex2(Int(bytes[offset])) + hex2(Int(bytes[offset + 1])) + hex2(Int(bytes[offset + 2]))
        return (oui, Int(bytes[offset + 3]))
    }

    private static func ouiString(_ b: [UInt8]) -> String {
        "\(hex2(Int(b[0]))):\(hex2(Int(b[1]))):\(hex2(Int(b[2])))"
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> Int {
        if offset + 1 >= bytes.count { return 0 }
        return Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }
}
