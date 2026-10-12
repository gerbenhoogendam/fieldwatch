import Foundation

// Port of domain/SignatureCandidates.kt.

public struct SignatureCandidate: Hashable, Identifiable, Sendable {
    public var id: String
    public var proposedName: String
    public var kind: SignatureClass
    public var radioKind: RadioKind
    public var distinctRadios: Int
    public var rules: [MatchRule]
    public var why: String
    public var examples: [String]
    public var extraCount: Int
    public var notes: String
    public var colorIndex: Int

    public init(
        id: String, proposedName: String, kind: SignatureClass, radioKind: RadioKind, distinctRadios: Int,
        rules: [MatchRule], why: String, examples: [String], extraCount: Int, notes: String, colorIndex: Int
    ) {
        self.id = id; self.proposedName = proposedName; self.kind = kind; self.radioKind = radioKind
        self.distinctRadios = distinctRadios; self.rules = rules; self.why = why; self.examples = examples
        self.extraCount = extraCount; self.notes = notes; self.colorIndex = colorIndex
    }

    public var ruleLabel: String { rules.map { ruleShortLabel($0) }.joined(separator: "  ·  ") }
}

public struct CandidateReport: Hashable, Sendable {
    public var families: [SignatureCandidate]
    public var uniqueRadios: Int
    public var unmatchedRadios: Int
    public var skippedRandomized: Int
    public var skippedHouseLike: Int
    public var skippedOther: Int
    public var sourceLabel: String

    public init(
        families: [SignatureCandidate], uniqueRadios: Int, unmatchedRadios: Int, skippedRandomized: Int,
        skippedHouseLike: Int, skippedOther: Int, sourceLabel: String = "Rotating log"
    ) {
        self.families = families; self.uniqueRadios = uniqueRadios; self.unmatchedRadios = unmatchedRadios
        self.skippedRandomized = skippedRandomized; self.skippedHouseLike = skippedHouseLike
        self.skippedOther = skippedOther; self.sourceLabel = sourceLabel
    }
}

public enum FamilyVerdict: String, CaseIterable, Sendable {
    case strong = "STRONG", possible = "POSSIBLE", single = "SINGLE", tagged = "TAGGED"
}

public struct SignatureFamilyHint: Hashable, Sendable {
    public var verdict: FamilyVerdict
    public var title: String
    public var body: String
    public var logCount: Int
    public var liveCount: Int
    public var displayCount: Int
    public var ruleLabel: String?
    public var radioKind: RadioKind

    public init(
        verdict: FamilyVerdict, title: String, body: String, logCount: Int, liveCount: Int, displayCount: Int,
        ruleLabel: String?, radioKind: RadioKind
    ) {
        self.verdict = verdict; self.title = title; self.body = body; self.logCount = logCount
        self.liveCount = liveCount; self.displayCount = displayCount; self.ruleLabel = ruleLabel
        self.radioKind = radioKind
    }
}

func ruleShortLabel(_ rule: MatchRule) -> String {
    switch rule.kind {
    case .nameGlob, .nameContains: return rule.text
    case .vendorIeOui: return "vendor IE \(rule.text)"
    case .oui, .macPrefix: return "OUI \(rule.text)"
    case .serviceUuid: return "UUID \(rule.text)"
    case .serviceData:
        return rule.text.isBlank ? "svc contains \(rule.dataPrefixHex)" : "UUID \(rule.text) \(rule.dataPrefixHex)"
    case .manufacturerData: return "mfg 0x\(hex4(rule.companyId)) \(rule.dataPrefixHex)"
    case .manufacturerId: return "mfg 0x\(hex4(rule.companyId))"
    default: return rule.kind.rawValue
    }
}

/// "%04X" of a Kotlin Int (32-bit two's complement when negative).
private func hex4(_ v: Int) -> String {
    v < 0 ? String(UInt32(truncatingIfNeeded: v), radix: 16, uppercase: true) : hexN(v, 4)
}

/// Cluster unmatched log radios by a shared unique on-air ID.
/// Frequency is distinct MACs, not packet count. Not every unknown radio.
public enum SignatureCandidates {
    public static let MAX_FAMILIES = 20
    public static let MIN_RADIOS = 2
    public static let STRONG_MIN_RADIOS = 8

    public static func analyze(
        radios: [LogRadio],
        fleets: [Fleet],
        engine: SignatureEngine = SignatureEngine(),
        sourceLabel: String = "Rotating log"
    ) -> CandidateReport {
        let sightings = radios.map { toSighting($0) }
        let hits = sightings.isEmpty ? [:] : engine.match(devices: sightings, fleets: fleets)
        let unmatched = radios.filter { radio in (hits[radio.key] ?? []).isEmpty }
        var skippedRandomized = 0
        var skippedHouseLike = 0
        var skippedOther = 0
        var usable: [LogRadio] = []
        usable.reserveCapacity(unmatched.count)
        for radio in unmatched {
            if hasStructuredId(radio) { usable.append(radio) }
            else if radio.randomized { skippedRandomized += 1 }
            else if isHouseLikeName(name: radio.name) { skippedHouseLike += 1 }
            else { skippedOther += 1 }
        }
        let clusters = buildClusters(usable)
        let merged = mergeOverlapping(clusters)
        let viable = merged.filter { $0.members.count >= MIN_RADIOS }
        let clusteredKeys = Set(viable.flatMap { $0.members })
        skippedOther += usable.count { !clusteredKeys.contains($0.key) }
        let families = viable
            .sortedWithComparator { a, b in
                if a.members.count != b.members.count { return a.members.count > b.members.count ? -1 : 1 }
                let r = compareValues(kindRank(a.primary.kind), kindRank(b.primary.kind))
                if r != 0 { return r }
                return compareValues(a.proposedName.lowercased(), b.proposedName.lowercased())
            }
            .take(MAX_FAMILIES)
            .map { toCandidate($0) }
        return CandidateReport(
            families: families,
            uniqueRadios: radios.count,
            unmatchedRadios: unmatched.count,
            skippedRandomized: skippedRandomized,
            skippedHouseLike: skippedHouseLike,
            skippedOther: skippedOther,
            sourceLabel: sourceLabel
        )
    }

    /// For one radio on detail: is its best on-air ID a catalog family?
    /// Same ID quality as `analyze`. Distinct MACs, not packets.
    public static func assessFamily(
        device: Sighting,
        live: [Sighting],
        log: [LogRadio],
        fleets: [Fleet]
    ) -> SignatureFamilyHint {
        let tagged = fleets.filter { device.fleetIds.contains($0.id) }.map { $0.name.trim() }.filter { $0.isNotEmpty }
        if device.fleetIds.isNotEmpty {
            let names = tagged.ifEmpty(["a catalog signature"])
            return SignatureFamilyHint(
                verdict: .tagged,
                title: "Already tagged",
                body: "Matched \(names.joined(separator: ", ")). A second signature can still dual-label this radio (store UUID, product OUI).",
                logCount: 0,
                liveCount: 0,
                displayCount: 0,
                ruleLabel: nil,
                radioKind: device.kind
            )
        }
        let selfProbe = toProbe(device)
        let prints = fingerprintsOf(selfProbe)
        let noId = SignatureFamilyHint(
            verdict: .single,
            title: "This radio only",
            body: "No unique on-air ID to cluster on. Randomized addresses, house-like names, and generic chips are skipped.",
            logCount: 0,
            liveCount: 0,
            displayCount: 0,
            ruleLabel: nil,
            radioKind: device.kind
        )
        if prints.isEmpty { return noId }
        let logRadios = log.distinctBy { $0.key }
        let liveRadios = live.map { toProbe($0) }.distinctBy { $0.key }
        var logKeys: [String: Set<String>] = [:]
        for r in logRadios { logKeys[r.key] = Set(fingerprintsOf(r).map { $0.key }) }
        var liveKeys: [String: Set<String>] = [:]
        for r in liveRadios { liveKeys[r.key] = Set(fingerprintsOf(r).map { $0.key }) }
        let scored: [(Fingerprint, Int, Int)] = prints.compactMap { fp in
            let logHit = logRadios.filter { logKeys[$0.key]?.contains(fp.key) == true }
            let liveHit = liveRadios.filter { liveKeys[$0.key]?.contains(fp.key) == true }
            if !idViable(fp, logHit, liveHit) { return nil }
            return (fp, logHit.count, liveHit.count)
        }
        // Kotlin maxWithOrNull: first of equal maxima wins.
        var best: (Fingerprint, Int, Int)?
        for s in scored {
            guard let b = best else { best = s; continue }
            let ka = max(b.1, b.2), kb = max(s.1, s.2)
            var c = compareValues(ka, kb)
            if c == 0 { c = compareValues(kindRank(s.0.rule.kind), kindRank(b.0.rule.kind)) }
            if c < 0 { best = s }
        }
        guard let best else { return noId }
        let fp = best.0
        let logN = best.1
        let liveN = best.2
        let familyN = max(logN, liveN)
        let kindLabel = idKindLabel(fp.rule)
        let clause = countClause(device.kind, logN, liveN)
        let ruleText = ruleShortLabel(fp.rule)
        if familyN < MIN_RADIOS {
            return SignatureFamilyHint(
                verdict: .single,
                title: "This radio only",
                body: "No other MAC in the log or on the air shares this \(kindLabel). A signature from here will mostly tag this address.",
                logCount: logN,
                liveCount: liveN,
                displayCount: 0,
                ruleLabel: ruleText,
                radioKind: device.kind
            )
        }
        let strong = familyN >= STRONG_MIN_RADIOS
        return SignatureFamilyHint(
            verdict: strong ? .strong : .possible,
            title: strong ? "Strong family" : "Possible family",
            body: strong
                ? "Same \(kindLabel) on \(clause). That is a catalog pattern, not this MAC."
                : "Same \(kindLabel) on \(clause). Thin sample — a possible catalog family.",
            logCount: logN,
            liveCount: liveN,
            displayCount: logN > 0 ? logN : liveN,
            ruleLabel: ruleText,
            radioKind: device.kind
        )
    }

    public static func suggestFleet(candidate: SignatureCandidate) -> Fleet {
        Fleet(
            id: UUID().uuidString.lowercased(),
            name: candidate.proposedName,
            enabled: true,
            matchAny: true,
            colorIndex: candidate.colorIndex,
            rules: candidate.rules,
            notes: candidate.notes,
            builtIn: false,
            kind: candidate.kind
        )
    }

    static func nameGlobOf(name: String) -> String? {
        let n = name.trim()
        if n.isBlank || n.hasPrefix("<") || isHouseLikeName(name: n) { return nil }
        if BRACKET_NAME.matches(n), let bracket = BRACKET_NAME.find(n) {
            let token = bracket.groupValues[1]
            if token.count >= 3 && !isSkippedPrefix(token) { return "[\(token)]*" }
        }
        let chars = Array(n)
        let sepAt = chars.indexOfFirst { $0 == "-" || $0 == "_" }
        if sepAt < 3 { return nil }
        let prefix = n.take(sepAt)
        if isSkippedPrefix(prefix) || isHouseLikeName(name: prefix) { return nil }
        if prefix.count < 3 { return nil }
        let sep = chars[sepAt]
        let suffix = String(chars.drop(sepAt + 1).prefix { $0 != " " })
        let hex = suffix.filterAlnum()
        let hexOnlySuffix = hex.isNotEmpty && hex.count == suffix.count &&
            hex.allSatisfy { ch in
                let l = ch.lowercased()
                return isDigitK(ch) || (l.count == 1 && ("a"..."f").contains(l.first!))
            }
        if hexOnlySuffix && hex.count >= 6 {
            return "\(prefix)\(sep)\(String(repeating: "?", count: hex.count))"
        }
        return "\(prefix)*"
    }

    /// Create-from-device used to emit DIRECT* / ANDROID* globs. Those are every Direct AP.
    static func isOverbroadCreateName(text: String) -> Bool {
        let t = trimEndChar(trimEndChar(trimEndChar(text.trim().uppercased(), "*"), "-"), "_")
        return t.isNotEmpty && SKIP_PREFIX.contains(t)
    }

    static func isHouseLikeName(name: String) -> Bool {
        let n = name.trim()
        if n.isEmpty { return true }
        let tokens = KRegex("[\\s\\-_]+").split(n.lowercased()).filter { $0.isNotEmpty }
        guard let first = tokens.first else { return true }
        if HOUSE_WORDS.contains(where: { $0 == first || first.hasPrefix($0) }) { return true }
        if tokens.contains(where: { $0 == "guest" || $0.hasPrefix("guest") }) {
            let product = first.contains(where: { isDigitK($0) }) || (first == first.uppercased() && first.count >= 4)
            if !product { return true }
        }
        let token = String(n.prefix { $0 != " " })
        let noSep = !token.contains("-") && !token.contains("_")
        let letters = token.allSatisfy { $0.isLetter }
        let titleOrLower = token != token.uppercased()
        return noSep && letters && titleOrLower && (3...18).contains(token.count) && !token.contains(where: { isDigitK($0) })
    }

    static func isChipModuleVendor(vendor: String?) -> Bool {
        guard let v = vendor?.lowercased() else { return false }
        return CHIP_VENDOR.contains { v.contains($0) }
    }

    static func isProtocolIe(oui: String) -> Bool {
        let hex = oui.filterAlnum().uppercased()
        return PROTOCOL_IE.contains(hex.take(6))
    }

    private static func buildClusters(_ radios: [LogRadio]) -> [Cluster] {
        var order: [String] = []
        var buckets: [String: (Fingerprint, [LogRadio])] = [:]
        for radio in radios {
            for fp in fingerprintsOf(radio) {
                if buckets[fp.key] == nil {
                    order.append(fp.key)
                    buckets[fp.key] = (fp, [])
                }
                buckets[fp.key]!.1.append(radio)
            }
        }
        var out: [Cluster] = []
        for key in order {
            let (fp, members) = buckets[key]!
            if let c = clusterOf(fp, distinctRadios(members)) { out.append(c) }
        }
        return out
    }

    private static func clusterOf(_ fp: Fingerprint, _ distinct: [LogRadio]) -> Cluster? {
        if distinct.count < MIN_RADIOS { return nil }
        let members = Set(distinct.map { $0.key })
        switch fp.rule.kind {
        case .nameGlob, .nameContains:
            let glob = fp.rule.text
            let kind = distinct[0].kind
            return Cluster(
                key: fp.key,
                primary: fp.rule,
                radioKind: kind,
                members: members,
                radios: distinct,
                proposedName: String(glob.prefix { $0 != "*" && $0 != "?" && $0 != "-" && $0 != "_" })
                    .ifBlank(trimEndChar(glob, "*")),
                why: "Same name glob on \(distinct.count) \(radioWord(kind, distinct.count)) — not a house SSID."
            )
        case .vendorIeOui:
            let oui = fp.rule.text
            let hex = oui.filterAlnum().uppercased()
            let vendor = RadioDb.vendorForOui24(oui: hex)
            return Cluster(
                key: fp.key,
                primary: fp.rule,
                radioKind: .wifi,
                members: members,
                radios: distinct,
                proposedName: vendor?.take(22) ?? "Vendor IE \(oui)",
                why: "Same vendor IE on \(distinct.count) BSSIDs. Not WPS / P2P."
            )
        case .serviceUuid:
            let short = fp.rule.text
            let named = RadioDb.serviceUuid(uuid: short)
            return Cluster(
                key: fp.key,
                primary: fp.rule,
                radioKind: .ble,
                members: members,
                radios: distinct,
                proposedName: named?.take(22) ?? "UUID \(short)",
                why: "Same service UUID on \(distinct.count) BLE advertisers."
            )
        case .manufacturerData, .manufacturerId:
            let company = fp.rule.companyId
            let named = RadioDb.company(id: company)
            return Cluster(
                key: fp.key,
                primary: fp.rule,
                radioKind: .ble,
                members: members,
                radios: distinct,
                proposedName: named?.take(22) ?? "Company 0x\(hex4(company))",
                why: "Same manufacturer data prefix on \(distinct.count) BLE advertisers."
            )
        case .oui, .macPrefix:
            if !ouiViable(distinct) { return nil }
            let oui = fp.rule.text
            let vendor = distinct.lazy.compactMap { $0.vendor }.first ?? RadioDb.vendorForOui24(oui: oui)
            return Cluster(
                key: fp.key,
                primary: fp.rule,
                radioKind: .wifi,
                members: members,
                radios: distinct,
                proposedName: vendor?.take(22) ?? oui,
                why: "Same IEEE OUI on \(distinct.count) stable BSSIDs. Not a chip-module prefix."
            )
        default:
            return nil
        }
    }

    private static func fingerprintsOf(_ radio: LogRadio) -> [Fingerprint] {
        var out: [Fingerprint] = []
        if let glob = nameGlobOf(name: radio.name), !isHouseLikeName(name: radio.name) {
            out.append(Fingerprint(
                key: "glob:\(glob)",
                rule: MatchRule(kind: .nameGlob, text: glob, radio: radio.kind)
            ))
        }
        for ie in radio.vendorIeOuis {
            let hex = ie.filterAlnum().uppercased().take(6)
            if hex.count == 6 && !PROTOCOL_IE.contains(hex) {
                let oui = hex.chunked(2).joined(separator: ":")
                out.append(Fingerprint(
                    key: "ie:\(hex)",
                    rule: MatchRule(kind: .vendorIeOui, text: oui, radio: .wifi)
                ))
            }
        }
        if radio.kind == .ble {
            for uuid in radio.serviceUuids {
                if let short = uuidShort(uuid), !GENERIC_UUID.contains(short) {
                    out.append(Fingerprint(
                        key: "uuid:\(short)",
                        rule: MatchRule(kind: .serviceUuid, text: short, radio: .ble)
                    ))
                }
            }
            let prefix = radio.manufacturerDataHex.filterAlnum().uppercased().take(2)
            if let mfg = radio.manufacturerId, !BROAD_COMPANY.contains(mfg), prefix.count == 2 {
                out.append(Fingerprint(
                    key: "mfg:\(hex4(mfg)):\(prefix)",
                    rule: MatchRule(kind: .manufacturerData, companyId: mfg, dataPrefixHex: prefix, radio: .ble)
                ))
            }
        }
        if !radio.randomized && !isChipModuleVendor(vendor: radio.vendor) && !isSkippedOuiVendor(radio.vendor) {
            let oui = MacUtil.prefixBytes(mac: radio.mac, n: 3)
            if oui.count >= 8 {
                out.append(Fingerprint(
                    key: "oui:\(oui)",
                    rule: MatchRule(kind: .oui, text: oui, radio: .wifi)
                ))
            }
        }
        return out
    }

    private static func idViable(_ fp: Fingerprint, _ logHit: [LogRadio], _ liveHit: [LogRadio]) -> Bool {
        if fp.rule.kind != .oui && fp.rule.kind != .macPrefix { return true }
        return ouiViable(logHit) || ouiViable(liveHit)
    }

    private static func ouiViable(_ members: [LogRadio]) -> Bool {
        if members.count < MIN_RADIOS { return false }
        let names = members.map { $0.name.trim() }.filter { $0.isNotEmpty && !isHouseLikeName(name: $0) }.distinct()
        return members.count >= 3 || names.count >= 2
    }

    private static func idKindLabel(_ rule: MatchRule) -> String {
        switch rule.kind {
        case .nameGlob, .nameContains: return "name glob"
        case .vendorIeOui: return "vendor IE"
        case .serviceUuid: return "service UUID"
        case .manufacturerData, .manufacturerId: return "manufacturer data prefix"
        case .oui, .macPrefix: return "IEEE OUI"
        default: return "on-air ID"
        }
    }

    private static func countClause(_ kind: RadioKind, _ logN: Int, _ liveN: Int) -> String {
        let logWord = radioWord(kind, logN)
        let liveWord = radioWord(kind, liveN)
        if logN > 0 && liveN > 0 { return "\(logN) \(logWord) in the log (\(liveN) on the air now)" }
        if logN > 0 { return "\(logN) \(logWord) in the log" }
        if liveN > 0 { return "\(liveN) \(liveWord) on the air now" }
        return "1 \(radioWord(kind, 1))"
    }

    private static func toProbe(_ s: Sighting) -> LogRadio {
        LogRadio(
            kind: s.kind,
            mac: s.mac,
            name: s.name,
            vendor: s.vendor,
            manufacturerId: s.manufacturerId,
            manufacturerDataHex: s.manufacturerDataHex,
            serviceUuids: s.serviceUuids,
            vendorIeOuis: s.vendorIeOuis,
            randomized: s.randomized,
            hiddenSsid: s.hiddenSsid,
            rssi: s.rssi,
            firstSeen: s.firstSeen,
            lastSeen: s.lastSeen,
            hits: s.hitCount
        )
    }

    private static func mergeOverlapping(_ clusters: [Cluster]) -> [Cluster] {
        if clusters.count <= 1 { return clusters }
        var ranked = clusters.sortedBy { kindRank($0.primary.kind) }
        var i = 0
        while i < ranked.count {
            let keep = ranked[i]
            var j = i + 1
            while j < ranked.count {
                let other = ranked[j]
                let n = min(keep.members.count, other.members.count)
                let overlap = keep.members.intersection(other.members).count
                if n > 0 && overlap * 10 >= n * 6 {
                    keep.extra.append(other.primary)
                    keep.members.formUnion(other.members)
                    keep.radios = distinctRadios(keep.radios + other.radios)
                    ranked.remove(at: j)
                } else {
                    j += 1
                }
            }
            i += 1
        }
        return ranked
    }

    private struct RuleKey: Hashable {
        let kind: RuleKind
        let text: String
        let companyId: Int
        let dataPrefixHex: String
    }

    private static func toCandidate(_ c: Cluster) -> SignatureCandidate {
        let rules = ([c.primary] + c.extra).distinctBy {
            RuleKey(kind: $0.kind, text: $0.text, companyId: $0.companyId, dataPrefixHex: $0.dataPrefixHex)
        }
        let examples = c.radios
            .map { exampleLabel($0) }
            .filter { $0.isNotBlank }
            .distinct()
        let shown = examples.take(2)
        let extraN = (examples.count - shown.count).coerceAtLeast(0)
        let kind = guessClass(c.radioKind, c.primary)
        let word = radioWord(c.radioKind, c.members.count)
        return SignatureCandidate(
            id: c.key,
            proposedName: KRegex("[^A-Za-z0-9 _.-\\[\\]]").replace(c.proposedName, "").take(22)
                .ifBlank(c.proposedName.take(22)),
            kind: kind,
            radioKind: c.radioKind,
            distinctRadios: c.members.count,
            rules: rules,
            why: c.why,
            examples: shown,
            extraCount: extraN,
            notes: "\(c.members.count) \(word) in the log matched \(ruleShortLabel(c.primary)). Shared on-air ID, not a one-radio MAC. Change the name or class, then Save.",
            colorIndex: colorFor(kind)
        )
    }

    private static func guessClass(_ radioKind: RadioKind, _ rule: MatchRule) -> SignatureClass {
        if radioKind == .ble { return .other }
        if rule.kind == .oui { return .isp }
        return .home
    }

    private static func colorFor(_ kind: SignatureClass) -> Int {
        switch kind {
        case .mesh: return 0
        case .surveillance, .drone: return 1
        case .hacking: return 2
        case .wearable, .bodyworn, .beacon, .finder: return 3
        case .phone: return 4
        case .glasses, .audio: return 5
        case .camera, .home, .isp, .signage, .thermostat, .lock, .other: return 6
        case .lawEnforcement, .vehicle: return 7
        case .health: return 8
        }
    }

    private static func kindRank(_ kind: RuleKind) -> Int {
        switch kind {
        case .nameGlob, .nameContains: return 0
        case .vendorIeOui: return 1
        case .serviceUuid: return 2
        case .manufacturerData, .manufacturerId: return 3
        case .oui, .macPrefix: return 4
        default: return 5
        }
    }

    private static func distinctRadios(_ members: [LogRadio]) -> [LogRadio] { members.distinctBy { $0.key } }

    private static func uuidShort(_ raw: String) -> String? {
        let hex = raw.filterAlnum().uppercased()
        if hex.count == 4 { return hex }
        if hex.count >= 8 { return hex.substring(4, 8) }
        return nil
    }

    private static func isSkippedPrefix(_ prefix: String) -> Bool {
        var p = prefix.trim().uppercased()
        if p.hasPrefix("[") { p.removeFirst() }
        if p.hasSuffix("]") { p.removeLast() }
        return SKIP_PREFIX.contains(p) || p.count < 3
    }

    private static func isSkippedOuiVendor(_ vendor: String?) -> Bool {
        guard let v = vendor?.lowercased() else { return false }
        return SKIP_OUI_VENDOR.contains { v.contains($0) }
    }

    private static func hasStructuredId(_ r: LogRadio) -> Bool {
        if nameGlobOf(name: r.name) != nil && !isHouseLikeName(name: r.name) { return true }
        if r.vendorIeOuis.contains(where: { !isProtocolIe(oui: $0) }) { return true }
        if r.kind == .ble && r.serviceUuids.contains(where: { u in
            let s = uuidShort(u)
            return s != nil && !GENERIC_UUID.contains(s!)
        }) { return true }
        if r.kind == .ble, let m = r.manufacturerId, !BROAD_COMPANY.contains(m) { return true }
        if !r.randomized && !isChipModuleVendor(vendor: r.vendor) && !isSkippedOuiVendor(r.vendor) { return true }
        return false
    }

    private static func toSighting(_ r: LogRadio) -> Sighting {
        Sighting(
            key: r.key,
            kind: r.kind,
            mac: r.mac,
            name: r.name,
            rssi: r.rssi,
            rssiMin: r.rssi,
            rssiMax: r.rssi,
            channel: 0,
            frequencyMhz: 0,
            vendor: r.vendor,
            randomized: r.randomized,
            hiddenSsid: r.hiddenSsid,
            serviceUuids: r.serviceUuids,
            manufacturerId: r.manufacturerId,
            manufacturerDataHex: r.manufacturerDataHex,
            rawHex: r.manufacturerDataHex,
            extras: "",
            firstSeen: r.firstSeen,
            lastSeen: r.lastSeen,
            hitCount: r.hits,
            fleetIds: [],
            rssiHistory: [],
            presence: [],
            vendorIeOuis: r.vendorIeOuis,
            facts: RadioFacts(
                mfgRecords: r.manufacturerId.map { [MfgRecord(companyId: $0, dataHex: r.manufacturerDataHex)] } ?? [],
                vendorIes: r.vendorIeOuis.map { VendorIeRecord(oui: $0, type: -1, dataHex: "") }
            )
        )
    }

    private static func exampleLabel(_ r: LogRadio) -> String {
        let n = r.name.trim()
        if n.isNotEmpty && !n.equals(r.mac, ignoreCase: true) && !r.hiddenSsid { return n }
        return r.mac
    }

    private static func radioWord(_ kind: RadioKind, _ n: Int) -> String {
        if kind == .wifi && n == 1 { return "AP" }
        if kind == .wifi { return "APs" }
        if n == 1 { return "advertiser" }
        return "advertisers"
    }

    private struct Fingerprint {
        let key: String
        let rule: MatchRule
    }

    /// Reference type: `mergeOverlapping` grows the kept cluster in place, like the Kotlin mutable data class.
    private final class Cluster {
        let key: String
        let primary: MatchRule
        var extra: [MatchRule]
        let radioKind: RadioKind
        var members: Set<String>
        var radios: [LogRadio]
        let proposedName: String
        let why: String
        var id: String { key }

        init(key: String, primary: MatchRule, extra: [MatchRule] = [], radioKind: RadioKind, members: Set<String>,
             radios: [LogRadio], proposedName: String, why: String) {
            self.key = key; self.primary = primary; self.extra = extra; self.radioKind = radioKind
            self.members = members; self.radios = radios; self.proposedName = proposedName; self.why = why
        }
    }

    private static let BRACKET_NAME = KRegex("\\[([A-Za-z][A-Za-z0-9 ]{2,20})\\].*")

    private static let HOUSE_WORDS = [
        "guest", "xfinity", "xfinitywifi", "hilton", "toast", "attwifi",
        "androidap", "iphone", "ipad", "myspectrum",
    ]

    private static let SKIP_PREFIX: Set<String> = [
        "DIRECT", "GUEST", "HOME", "WIFI", "WIRELESS", "SETUP", "NETGEAR", "LINKSYS",
        "DLINK", "TP-LINK", "TPLINK", "ATT", "XFINITY", "HILTON", "TOAST", "IPHONE",
        "IPAD", "ANDROID", "MYWIFI", "DEFAULT", "TY",
    ]

    private static let CHIP_VENDOR = [
        "espressif", "mediatek", "ampak", "qualcomm", "universal global scientific",
        "realtek",
    ]

    private static let SKIP_OUI_VENDOR = ["google", "apple", "samsung electronics", "microsoft"]

    private static let PROTOCOL_IE: Set<String> = ["0050F2", "000FAC", "506F9A", "8CFDF0"]

    /// Company IDs that are a whole OS / vendor, not a product.
    private static let BROAD_COMPANY: Set<Int> = [
        0x004C, // Apple
        0x00E0, // Google
        0x0075, // Samsung
        0x0006, // Microsoft
        0x0001, // Nokia (TPMS clones)
        0x00D2, // Google (alt)
    ]

    private static let GENERIC_UUID: Set<String> = [
        "FEF3", "FCF1", "FCB2", "FFF0", "FEAA", "FFF2",
        "FD5A", "FEED", "FEDD", "FD44",
        "1800", "1801", "180A", "180F", "1812", "181A", "FE2C",
    ]
}

/// Kotlin `Char.isDigit()` (Unicode decimal digit).
private func isDigitK(_ c: Character) -> Bool {
    c.unicodeScalars.count == 1 && c.unicodeScalars.first!.properties.generalCategory == .decimalNumber
}

/// Kotlin `trimEnd(ch)`.
private func trimEndChar(_ s: String, _ ch: Character) -> String {
    var out = s
    while out.last == ch { out.removeLast() }
    return out
}
