import Foundation

// Port of domain/SignatureEngine.kt.

public final class SignatureEngine {
    /// 802.11 WPA (Microsoft) and RSN (IEEE) vendor IE OUIs — not a product brand.
    fileprivate static let WIFI_PROTOCOL_IE_OUIS: Set<String> = ["0050F2", "000FAC"]

    /// Catalog OUI lists are thousands of 3-byte prefixes. Walking them with
    /// any() on every Live refresh is O(devices × rules). Index by hex OUI.
    /// Kotlin compared the list by identity; Swift `==` on arrays short-circuits on a shared buffer.
    private let cacheLock = NSLock()
    private var cachedFleets: [Fleet]?
    private var cached: Compiled?

    public init() {}

    /// Device key → matched signature ids in match order (Kotlin LinkedHashSet order).
    /// Values are ordered arrays so they can go straight into `Sighting.fleetIds`.
    public func match(
        devices: [Sighting],
        fleets: [Fleet],
        now: Int = nowMs(),
        policy: DetectionPolicy = DetectionPolicy()
    ) -> [String: [String]] {
        let compiled = compiled(fleets)
        var byKey: [String: [String]] = Dictionary(minimumCapacity: devices.count)
        for device in devices {
            var hits: [String] = []
            let ouiHit = compiled.ouiHits(device)
            for idx in compiled.plansFor(device.kind) {
                let plan = compiled.plans[idx]
                if !plan.cluster && fleetHits(device, plan, ouiHit[idx]) {
                    if !hits.contains(plan.id) { hits.append(plan.id) }
                }
            }
            dropProtocolIBeacon(&hits, compiled)
            dropDjiWhenSpecificRow(&hits)
            dropGoProWhenPolar(&hits)
            dropAirTagsWhenAppleDevice(&hits, device)
            dropCiscoWhenMeraki(&hits)
            byKey[device.key] = hits
        }
        applyClusters(devices, compiled, &byKey, now)
        return byKey
    }

    public func suggestFleet(device: Sighting) -> Fleet {
        var rules: [MatchRule] = []
        // Full address first so this radio is labeled even if it has no name.
        rules.append(MatchRule(kind: .macPrefix, text: device.mac))
        if device.name.isNotBlank && !device.hiddenSsid {
            if let glob = SignatureCandidates.nameGlobOf(name: device.name) {
                rules.append(MatchRule(kind: .nameGlob, text: glob))
            } else {
                // DIRECT- / ANDROID- / house SSIDs: pin this name, not the generic prefix.
                rules.append(MatchRule(kind: .nameContains, text: device.name.take(32)))
            }
        }
        for uuid in device.serviceUuids.take(3) {
            let hex = uuid.filterAlnum().uppercased()
            let short = hex.count >= 8 ? hex.substring(4, 8) : hex.take(4)
            if short.isNotBlank { rules.append(MatchRule(kind: .serviceUuid, text: short)) }
        }
        if let id = device.manufacturerId {
            let prefix = device.manufacturerDataHex.take(2)
            if prefix.isNotBlank {
                rules.append(MatchRule(kind: .manufacturerData, companyId: id, dataPrefixHex: prefix))
            } else {
                rules.append(MatchRule(kind: .manufacturerId, companyId: id))
            }
        }
        let hasIdentity = rules.contains { $0.kind != .macPrefix }
        if !hasIdentity {
            rules.append(MatchRule(kind: .oui, text: device.oui))
        }
        let suggested: String
        if device.name.isNotBlank && !device.hiddenSsid {
            suggested = KRegex("[^A-Za-z0-9 _.-]").replace(device.name, "").take(22).ifBlank("Signature \(device.oui)")
        } else if let vendor = device.vendor {
            suggested = "\(vendor) \(device.oui)"
        } else {
            suggested = "\(device.kind.label()) \(device.mac.takeLast(8))"
        }
        let rotateNote = device.randomized
            ? " Address is randomized and may change; prefer name / UUID / manufacturer rules."
            : ""
        return Fleet(
            id: UUID().uuidString.lowercased(),
            name: suggested,
            enabled: true,
            matchAny: true,
            colorIndex: device.kind == .ble ? 3 : 0,
            rules: rules,
            notes: "Created from \(device.kind.label()) \(device.mac).\(rotateNote) Keep the MAC rule to track this radio; keep name/UUID/mfg to match siblings."
        )
    }

    private func needsCluster(_ fleet: Fleet) -> Bool {
        fleet.minPeers > 0 || fleet.clusterByOui || fleet.sequentialMac
    }

    private func compiled(_ fleets: [Fleet]) -> Compiled {
        cacheLock.lock()
        if let hit = cached, let prev = cachedFleets, prev == fleets {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()
        let next = compile(fleets)
        cacheLock.lock()
        cached = next
        cachedFleets = fleets
        cacheLock.unlock()
        return next
    }

    private func compile(_ fleets: [Fleet]) -> Compiled {
        var plans: [FleetPlan] = []
        plans.reserveCapacity(fleets.count)
        var bssidWifi: [String: [Int]] = Dictionary(minimumCapacity: 4096)
        var bssidBle: [String: [Int]] = Dictionary(minimumCapacity: 256)
        var vendorIe: [String: [Int]] = Dictionary(minimumCapacity: 4096)
        var longOui: [LongOui] = []
        var wifiPlans: [Int] = []
        var blePlans: [Int] = []
        for (idx, fleet) in fleets.enumerated() {
            let active = fleet.rules.filter { $0.enabled }
            var other: [FastRule] = []
            for rule in active {
                switch rule.kind {
                case .oui:
                    indexOui(rule.text, rule.radio, idx, bssid: true, vendor: true, &bssidWifi, &bssidBle, &vendorIe, &longOui)
                case .macPrefix:
                    indexOui(rule.text, rule.radio, idx, bssid: true, vendor: false, &bssidWifi, &bssidBle, &vendorIe, &longOui)
                case .vendorIeOui:
                    indexOui(rule.text, rule.radio, idx, bssid: false, vendor: true, &bssidWifi, &bssidBle, &vendorIe, &longOui)
                default:
                    if let r = compileOther(rule) { other.append(r) }
                }
            }
            plans.append(FleetPlan(
                id: fleet.id,
                fleet: fleet,
                cluster: needsCluster(fleet),
                matchAny: fleet.matchAny,
                otherRules: other,
                rawRules: active
            ))
            switch radioScope(active) {
            case .wifi?: wifiPlans.append(idx)
            case .ble?: blePlans.append(idx)
            case nil:
                wifiPlans.append(idx)
                blePlans.append(idx)
            }
        }
        return Compiled(
            plans: plans,
            wifiPlans: wifiPlans,
            blePlans: blePlans,
            bssidWifi: bssidWifi,
            bssidBle: bssidBle,
            vendorIe: vendorIe,
            longOui: longOui
        )
    }

    private func indexOui(
        _ text: String,
        _ radio: RadioKind?,
        _ fleetIdx: Int,
        bssid: Bool,
        vendor: Bool,
        _ bssidWifi: inout [String: [Int]],
        _ bssidBle: inout [String: [Int]],
        _ vendorIe: inout [String: [Int]],
        _ longOui: inout [LongOui]
    ) {
        let hex = hexOnly(text)
        if hex.isEmpty { return }
        if hex.count != 6 {
            longOui.append(LongOui(hex: hex, radio: radio, bssid: bssid, vendor: vendor, fleetIdx: fleetIdx))
            return
        }
        if bssid {
            if radio != .ble { addIdx(&bssidWifi, hex, fleetIdx) }
            if radio != .wifi { addIdx(&bssidBle, hex, fleetIdx) }
        }
        if vendor && radio != .ble && !SignatureEngine.WIFI_PROTOCOL_IE_OUIS.contains(hex) {
            addIdx(&vendorIe, hex, fleetIdx)
        }
    }

    private func addIdx(_ map: inout [String: [Int]], _ key: String, _ idx: Int) {
        var list = map[key] ?? []
        if !list.contains(idx) { list.append(idx) }
        map[key] = list
    }

    /// WIFI = every rule is Wi-Fi-only (AP rows). BLE = every rule is BLE-only.
    /// nil = mixed or unscoped (Tesla, DJI, UniFi name, custom) — still searched on both.
    private func radioScope(_ rules: [MatchRule]) -> RadioKind? {
        var wifi = false
        var ble = false
        var both = false
        for rule in rules {
            switch ruleScope(rule) {
            case .wifi?: wifi = true
            case .ble?: ble = true
            case nil: both = true
            }
        }
        if both || (wifi && ble) { return nil }
        if wifi { return .wifi }
        if ble { return .ble }
        return nil
    }

    private func ruleScope(_ rule: MatchRule) -> RadioKind? {
        switch rule.kind {
        case .vendorIeOui, .hiddenSsid: return .wifi
        case .radioKind: return rule.radio
        case .serviceUuid, .serviceData, .manufacturerId, .manufacturerData: return rule.radio ?? .ble
        default: return rule.radio
        }
    }

    private func compileOther(_ rule: MatchRule) -> FastRule? {
        switch rule.kind {
        case .nameContains:
            return rule.text.isBlank ? nil : .contains(rule.text, rule.radio)
        case .nameGlob:
            return rule.text.isBlank ? nil : .glob(compileGlob(rule.text), rule.radio)
        case .serviceUuid:
            return rule.text.isBlank ? nil : .uuid(uuidAliases(raw: rule.text), rule.radio)
        case .manufacturerId:
            return .mfgId(rule.companyId, rule.radio)
        case .manufacturerData:
            let prefix = hexOnly(rule.dataPrefixHex)
            return prefix.isEmpty ? nil : .mfgData(rule.companyId, prefix, rule.radio)
        case .serviceData:
            let prefix = hexOnly(rule.dataPrefixHex)
            let aliases = uuidAliases(raw: rule.text).filter { $0.isNotBlank }
            if prefix.isEmpty && aliases.isEmpty { return nil }
            return .svcData(aliases: aliases, prefix: prefix, radio: rule.radio,
                            contains: rule.text.isBlank && prefix.isNotEmpty)
        case .radioKind: return .radio(rule.radio)
        case .hiddenSsid: return .hidden
        case .oui, .macPrefix, .vendorIeOui: return nil
        }
    }

    private func compileGlob(_ pattern: String) -> KRegex {
        var body = "^"
        for ch in pattern {
            switch ch {
            case "*": body += ".*"
            case "?": body += "."
            default: body += KRegex.escape(String(ch))
            }
        }
        body += "$"
        return KRegex(body, ignoreCase: true)
    }

    private func fleetHits(_ device: Sighting, _ plan: FleetPlan, _ ouiHit: Bool) -> Bool {
        if plan.id == "fleet-ibeacon" && isTeslaPhoneKeyIBeacon(device) { return false }
        if plan.rawRules.isEmpty { return false }
        if !plan.matchAny {
            return plan.rawRules.allSatisfy { ruleHits(device, $0) }
        }
        if ouiHit { return true }
        if plan.otherRules.isEmpty { return false }
        return plan.otherRules.contains { $0.hits(device) }
    }

    /// iBeacon is a payload layout, not a product. If a radio already matched a
    /// non-beacon signature (Sony TV, Tesla phone-key, …), drop the iBeacon chip.
    /// Minew / Estimote / Kontakt / Atrius cart tag stay dual-labeled — those rows are beacon class.
    private func dropProtocolIBeacon(_ hits: inout [String], _ compiled: Compiled) {
        if !hits.contains("fleet-ibeacon") { return }
        let otherProduct = hits.contains { id in
            if id == "fleet-ibeacon" { return false }
            return compiled.plans.contains { $0.id == id && $0.fleet.kind != .beacon }
        }
        if otherProduct { hits.removeAll { $0 == "fleet-ibeacon" } }
    }

    /// Osmo cameras and DJI Power stations share company 0x08AA. Prefer those rows over DJI.
    private func dropDjiWhenSpecificRow(_ hits: inout [String]) {
        if hits.contains("fleet-osmo") || hits.contains("fleet-dji-power") { hits.removeAll { $0 == "fleet-dji" } }
    }

    /// A Polar H10 advertises GoPro's heart-rate service FEA5. The strap stays Polar.
    private func dropGoProWhenPolar(_ hits: inout [String]) {
        if hits.contains("fleet-polar") { hits.removeAll { $0 == "fleet-gopro" } }
    }

    /// Meraki APs are Cisco-owned and typically include Cisco Systems vendor
    /// IE 00:00:0C (CCX / AP-name). The BSSID is Meraki; do not also chip Cisco.
    private func dropCiscoWhenMeraki(_ hits: inout [String]) {
        if hits.contains("fleet-meraki") { hits.removeAll { $0 == "fleet-cisco" } }
    }

    /// Offline Finding (0x12) is the Find My network protocol, not an AirTag
    /// identity. iPhones advertise it so the network can locate them. Drop
    /// AirTags when Continuity / Apple Device already labeled the radio,
    /// unless the advertised name is AirTag or UUID FD44 is present.
    private func dropAirTagsWhenAppleDevice(_ hits: inout [String], _ device: Sighting) {
        if !hits.contains("fleet-airtag") { return }
        if device.name.contains("AirTag", ignoreCase: true) { return }
        if hasFindMyAccessoryUuid(device) { return }
        let appleProduct = hits.contains("fleet-apple-device") || hits.contains("fleet-apple-audio")
        if appleProduct || TrackerMatch.isAppleContinuity(device: device) {
            hits.removeAll { $0 == "fleet-airtag" }
        }
    }

    private func hasFindMyAccessoryUuid(_ device: Sighting) -> Bool {
        let want = uuidAliases(raw: "FD44")
        let have = device.serviceUuids + device.facts.serviceData.map { $0.uuid }
        return have.contains { uuid in uuidAliases(raw: uuid).contains { want.contains($0) } }
    }

    /// Tesla phone-key ads use Apple iBeacon so iOS can find the car. Label Tesla, not iBeacon.
    private func isTeslaPhoneKeyIBeacon(_ device: Sighting) -> Bool {
        let prefix = DefaultCatalog.TESLA_IBEACON_MFG_PREFIX
        return mfgRecordsOf(device).contains { rec in
            rec.companyId == 0x004C && hexOnly(rec.dataHex).hasPrefix(prefix)
        }
    }

    private func ruleHits(_ device: Sighting, _ rule: MatchRule) -> Bool {
        if rule.kind != .radioKind, let radio = rule.radio, device.kind != radio {
            return false
        }
        switch rule.kind {
        case .oui, .macPrefix:
            return MacUtil.matchesPrefix(mac: device.mac, prefix: rule.text) ||
                (rule.kind == .oui && wifiVendorIeHitsOui(device, rule.text)) ||
                (rule.kind == .oui && recoveredWifiOuiHits(device, rule.text))
        case .nameContains:
            return device.name.isNotBlank && TextMatch.contains(hay: device.name, needle: rule.text)
        case .nameGlob:
            return device.name.isNotBlank && TextMatch.glob(text: device.name, pattern: rule.text)
        case .serviceUuid:
            let want = uuidAliases(raw: rule.text)
            let have = device.serviceUuids + device.facts.serviceData.map { $0.uuid }
            return have.contains { uuid in uuidAliases(raw: uuid).contains { want.contains($0) } }
        case .manufacturerId:
            return mfgRecordsOf(device).contains { $0.companyId == rule.companyId }
        case .manufacturerData:
            let prefix = hexOnly(rule.dataPrefixHex)
            return prefix.isNotEmpty && mfgRecordsOf(device).contains { rec in
                (rule.companyId == 0 || rec.companyId == rule.companyId) && hexOnly(rec.dataHex).hasPrefix(prefix)
            }
        case .serviceData:
            let prefix = hexOnly(rule.dataPrefixHex)
            let aliases = uuidAliases(raw: rule.text).filter { $0.isNotBlank }
            if prefix.isEmpty && aliases.isEmpty { return false }
            return serviceDataHits(device, aliases, prefix, contains: rule.text.isBlank && prefix.isNotEmpty)
        case .radioKind:
            return rule.radio == nil || device.kind == rule.radio
        case .hiddenSsid:
            return device.hiddenSsid
        case .vendorIeOui:
            return wifiVendorIeHitsOui(device, rule.text)
        }
    }

    /// Virtual BSSID: guest/mesh radios set the local bit on a burned-in 24-bit OUI.
    private func recoveredWifiOuiHits(_ device: Sighting, _ prefix: String) -> Bool {
        if device.kind != .wifi { return false }
        guard let univ = MacUtil.wifiOui24Universal(mac: device.mac) else { return false }
        let want = prefix.filterAlnum().uppercased()
        return want.count == 6 && univ == want
    }

    /// Wi-Fi vendor IEs (detail “Vendor OUI” list), not the BSSID.
    /// Skip WPA (00:50:F2) and RSN (00:0F:AC) — those are protocol tags, not the product.
    /// UniFi virtual BSSIDs also hit on the recovered universal OUI when that prefix is cataloged.
    private func wifiVendorIeHitsOui(_ device: Sighting, _ prefix: String) -> Bool {
        if device.kind != .wifi { return false }
        let want = hexOnly(prefix)
        if want.isEmpty || SignatureEngine.WIFI_PROTOCOL_IE_OUIS.contains(want.take(6)) { return false }
        return device.vendorIeOuis.contains { ie in
            let hex = hexOnly(ie)
            if SignatureEngine.WIFI_PROTOCOL_IE_OUIS.contains(hex.take(6)) { return false }
            return hex.hasPrefix(want)
        }
    }

    private func applyClusters(
        _ devices: [Sighting],
        _ compiled: Compiled,
        _ byKey: inout [String: [String]],
        _ now: Int
    ) {
        for (idx, plan) in compiled.plans.enumerated() {
            if !plan.cluster { continue }
            let fleet = plan.fleet
            let windowMs = (fleet.peerWindowSec <= 0 ? 60 : fleet.peerWindowSec) * 1000
            let live = devices.filter { now - $0.lastSeen <= windowMs }
            for a in live {
                let aOui = compiled.ouiHits(a)
                let aEligible: Bool
                if plan.rawRules.isEmpty { aEligible = true }
                else if fleetHits(a, plan, aOui[idx]) { aEligible = true }
                else if fleet.clusterByOui && (a.name.isBlank || a.randomized) { aEligible = true }
                else { aEligible = false }
                if !aEligible { continue }
                var peers = 1
                for b in live {
                    if b.key == a.key { continue }
                    if fleet.clusterByOui && a.oui != b.oui { continue }
                    if fleet.sequentialMac {
                        let diff = abs(MacUtil.last16(mac: a.mac) - MacUtil.last16(mac: b.mac))
                        if diff > 64 { continue }
                    }
                    if plan.rawRules.isNotEmpty && !fleet.clusterByOui {
                        let bOui = compiled.ouiHits(b)
                        if !fleetHits(b, plan, bOui[idx]) { continue }
                    }
                    peers += 1
                }
                let need = fleet.minPeers <= 0 ? 3 : fleet.minPeers
                if peers >= need {
                    var list = byKey[a.key] ?? []
                    if !list.contains(plan.id) { list.append(plan.id) }
                    byKey[a.key] = list
                }
            }
        }
    }

    private final class Compiled {
        let plans: [FleetPlan]
        let wifiPlans: [Int]
        let blePlans: [Int]
        let bssidWifi: [String: [Int]]
        let bssidBle: [String: [Int]]
        let vendorIe: [String: [Int]]
        let longOui: [LongOui]

        init(plans: [FleetPlan], wifiPlans: [Int], blePlans: [Int], bssidWifi: [String: [Int]],
             bssidBle: [String: [Int]], vendorIe: [String: [Int]], longOui: [LongOui]) {
            self.plans = plans; self.wifiPlans = wifiPlans; self.blePlans = blePlans
            self.bssidWifi = bssidWifi; self.bssidBle = bssidBle; self.vendorIe = vendorIe; self.longOui = longOui
        }

        func plansFor(_ kind: RadioKind) -> [Int] { kind == .wifi ? wifiPlans : blePlans }

        func ouiHits(_ device: Sighting) -> [Bool] {
            var hits = [Bool](repeating: false, count: plans.count)
            let macHex = hexOnly(device.mac)
            let oui6 = macHex.count >= 6 ? macHex.substring(0, 6) : macHex
            let bssidMap = device.kind == .wifi ? bssidWifi : bssidBle
            mark(&hits, bssidMap[oui6])
            if device.kind == .wifi {
                if let univ = MacUtil.wifiOui24Universal(mac: device.mac) {
                    mark(&hits, bssidMap[univ])
                }
                for ie in device.vendorIeOuis {
                    let hex = hexOnly(ie)
                    if hex.count < 6 { continue }
                    let ie6 = hex.substring(0, 6)
                    if SignatureEngine.WIFI_PROTOCOL_IE_OUIS.contains(ie6) { continue }
                    mark(&hits, vendorIe[ie6])
                }
            }
            if longOui.isNotEmpty && macHex.isNotEmpty {
                for rule in longOui {
                    if let r = rule.radio, r != device.kind { continue }
                    if rule.bssid && macHex.hasPrefix(rule.hex) {
                        hits[rule.fleetIdx] = true
                    }
                    if rule.vendor && device.kind == .wifi {
                        for ie in device.vendorIeOuis {
                            let hex = hexOnly(ie)
                            if SignatureEngine.WIFI_PROTOCOL_IE_OUIS.contains(hex.take(6)) { continue }
                            if hex.hasPrefix(rule.hex) { hits[rule.fleetIdx] = true }
                        }
                    }
                }
            }
            return hits
        }

        private func mark(_ hits: inout [Bool], _ idxs: [Int]?) {
            guard let idxs else { return }
            for i in idxs { hits[i] = true }
        }
    }

    private struct FleetPlan {
        let id: String
        let fleet: Fleet
        let cluster: Bool
        let matchAny: Bool
        let otherRules: [FastRule]
        let rawRules: [MatchRule]
    }

    private struct LongOui {
        let hex: String
        let radio: RadioKind?
        let bssid: Bool
        let vendor: Bool
        let fleetIdx: Int
    }

    /// Kotlin sealed class FastRule → enum with associated values.
    private enum FastRule {
        case contains(String, RadioKind?)
        case glob(KRegex, RadioKind?)
        case uuid(Set<String>, RadioKind?)
        case mfgId(Int, RadioKind?)
        case mfgData(Int, String, RadioKind?)
        case svcData(aliases: Set<String>, prefix: String, radio: RadioKind?, contains: Bool)
        case radio(RadioKind?)
        case hidden

        private static func radioOk(_ device: Sighting, _ radio: RadioKind?) -> Bool {
            radio == nil || device.kind == radio
        }

        func hits(_ device: Sighting) -> Bool {
            switch self {
            case let .contains(needle, radio):
                return FastRule.radioOk(device, radio) && device.name.isNotBlank &&
                    TextMatch.contains(hay: device.name, needle: needle)
            case let .glob(regex, radio):
                return FastRule.radioOk(device, radio) && device.name.isNotBlank && regex.matches(device.name)
            case let .uuid(aliases, radio):
                if !FastRule.radioOk(device, radio) { return false }
                let have = device.serviceUuids + device.facts.serviceData.map { $0.uuid }
                return have.contains { uuid in uuidAliases(raw: uuid).contains { aliases.contains($0) } }
            case let .mfgId(id, radio):
                return FastRule.radioOk(device, radio) && mfgRecordsOf(device).contains { $0.companyId == id }
            case let .mfgData(id, prefix, radio):
                if !FastRule.radioOk(device, radio) { return false }
                return mfgRecordsOf(device).contains { rec in
                    (id == 0 || rec.companyId == id) && hexOnly(rec.dataHex).hasPrefix(prefix)
                }
            case let .svcData(aliases, prefix, radio, contains):
                return FastRule.radioOk(device, radio) && serviceDataHits(device, aliases, prefix, contains: contains)
            case let .radio(kind):
                return kind == nil || device.kind == kind
            case .hidden:
                return device.hiddenSsid
            }
        }
    }
}

private func mfgRecordsOf(_ device: Sighting) -> [MfgRecord] {
    let fromFacts = device.facts.mfgRecords
    if fromFacts.isNotEmpty { return fromFacts }
    guard let id = device.manufacturerId else { return [] }
    return [MfgRecord(companyId: id, dataHex: device.manufacturerDataHex)]
}

private func serviceDataHits(
    _ device: Sighting,
    _ aliases: Set<String>,
    _ prefix: String,
    contains: Bool
) -> Bool {
    let needles: [String]
    if contains {
        let rev = reverseHexBytes(prefix)
        needles = (rev.isEmpty || rev == prefix) ? [prefix] : [prefix, rev]
    } else {
        needles = [prefix]
    }
    return device.facts.serviceData.contains { rec in
        if aliases.isNotEmpty && !uuidAliases(raw: rec.uuid).contains(where: { aliases.contains($0) }) { return false }
        let data = hexOnly(rec.dataHex)
        return contains ? needles.contains { data.contains($0) } : data.hasPrefix(prefix)
    }
}

private func reverseHexBytes(_ hex: String) -> String {
    let h = Array(hexOnly(hex))
    if h.count < 2 || h.count % 2 != 0 { return "" }
    var out = ""
    out.reserveCapacity(h.count)
    var i = h.count
    while i >= 2 {
        i -= 2
        out.append(h[i])
        out.append(h[i + 1])
    }
    return out
}

private func hexOnly(_ raw: String) -> String {
    if raw.isEmpty { return raw }
    var colon = false
    for ch in raw {
        if ch == ":" || ch == "-" { colon = true; break }
        if !ch.isLetterOrDigit { colon = true; break }
    }
    if !colon { return raw.uppercased() }
    var out = ""
    out.reserveCapacity(raw.count)
    for ch in raw where ch.isLetterOrDigit { out += ch.uppercased() }
    return out
}
