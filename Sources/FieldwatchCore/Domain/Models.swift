import Foundation

// Port of domain/Models.kt. JSON shape matches kotlinx (encodeDefaults = true, explicit nulls),
// so config / signature / settings packs move between Android and macOS.

public enum RadioKind: String, Codable, CaseIterable, Sendable {
    case wifi = "WIFI", ble = "BLE"

    public func label() -> String { self == .wifi ? "Wi-Fi" : "BLE" }
}

public enum ViewMode: String, Codable, CaseIterable, Sendable {
    case radar = "RADAR", list = "LIST", timeline = "TIMELINE", hybrid = "HYBRID", byClass = "BY_CLASS"

    public func label() -> String {
        switch self {
        case .radar: return "Classic radar"
        case .list: return "Strength list"
        case .timeline: return "Timeline"
        case .hybrid: return "Hybrid + sparklines"
        case .byClass: return "By class"
        }
    }
}

public enum ScanIntensity: String, Codable, CaseIterable, Sendable { case saver = "SAVER", balanced = "BALANCED", performance = "PERFORMANCE" }

public enum LogFormat: String, Codable, CaseIterable, Sendable { case csv = "CSV", json = "JSON" }

public enum FilterLogic: String, Codable, CaseIterable, Sendable { case and = "AND", or = "OR" }

/// Live filter / Signatures bulk on-off. Independent of `Fleet.colorIndex`.
public enum SignatureClass: String, Codable, CaseIterable, Sendable {
    case finder = "FINDER"
    case beacon = "BEACON"
    case signage = "SIGNAGE"
    case wearable = "WEARABLE"
    case surveillance = "SURVEILLANCE"
    case drone = "DRONE"
    case hacking = "HACKING"
    case bodyworn = "BODYWORN"
    case lawEnforcement = "LAW_ENFORCEMENT"
    case vehicle = "VEHICLE"
    case glasses = "GLASSES"
    case audio = "AUDIO"
    case camera = "CAMERA"
    case thermostat = "THERMOSTAT"
    case lock = "LOCK"
    case health = "HEALTH"
    case home = "HOME"
    case isp = "ISP"
    case mesh = "MESH"
    case phone = "PHONE"
    case other = "OTHER"

    public func label() -> String {
        switch self {
        case .finder: return "Finder tags"
        case .beacon: return "Retail beacons"
        case .signage: return "Signage"
        case .wearable: return "Wearables"
        case .surveillance: return "Surveillance"
        case .drone: return "Drones"
        case .hacking: return "Pentest"
        case .bodyworn: return "Body-worn"
        case .lawEnforcement: return "Public safety"
        case .vehicle: return "Vehicle"
        case .glasses: return "Glasses"
        case .audio: return "Audio"
        case .camera: return "Cameras"
        case .thermostat: return "Thermostats"
        case .lock: return "Access control"
        case .health: return "Health"
        case .home: return "Home IoT"
        case .isp: return "ISP / routers"
        case .mesh: return "Mesh"
        case .phone: return "Phones / PCs"
        case .other: return "Other"
        }
    }

    /// Short spoken form for watchlist voice.
    public func speechLabel() -> String {
        switch self {
        case .finder: return "finder tags"
        case .beacon: return "retail beacons"
        case .signage: return "signage"
        case .wearable: return "wearables"
        case .surveillance: return "surveillance"
        case .drone: return "drones"
        case .hacking: return "pentest"
        case .bodyworn: return "body worn"
        case .lawEnforcement: return "public safety"
        case .vehicle: return "vehicle"
        case .glasses: return "glasses"
        case .audio: return "audio"
        case .camera: return "cameras"
        case .thermostat: return "thermostats"
        case .lock: return "access control"
        case .health: return "health"
        case .home: return "home I O T"
        case .isp: return "I S P routers"
        case .mesh: return "mesh"
        case .phone: return "phones"
        case .other: return "other"
        }
    }

    /// Body-worn folds into Wearables. The case stays so old JSON still decodes.
    public func folded() -> SignatureClass { self == .bodyworn ? .wearable : self }

    public static var visible: [SignatureClass] { allCases.filter { $0 != .bodyworn } }

    /// Kotlin `ordinal`.
    public var ordinal: Int { SignatureClass.allCases.firstIndex(of: self)! }
}

/// What watchlist voice says. Class is the Live glyph bucket; signature is the catalog row.
public enum AlertVoiceWhat: String, Codable, CaseIterable, Sendable {
    case `class` = "CLASS", signature = "SIGNATURE", both = "BOTH"

    public func label() -> String {
        switch self {
        case .class: return "Class"
        case .signature: return "Signature"
        case .both: return "Class + signature"
        }
    }
}

public extension Fleet {
    func speechName() -> String { speakableWatchName(name: name) }
}

public func speakableWatchName(name: String) -> String {
    KRegex("\\s+").replace(name.replace("/", " ").replace("·", " "), " ").trim().ifBlank("unmatched")
}

public func spokenWatchClass(device: Sighting, fleets: [Fleet], target: WatchTarget? = nil) -> String {
    spokenWatchPhrase(device: device, fleets: fleets, what: .class, target: target)
}

public func spokenWatchPhrase(device: Sighting, fleets: [Fleet], what: AlertVoiceWhat, target: WatchTarget? = nil) -> String {
    if target?.deviceKey != nil {
        let label = target!.label.trim()
        let named: String
        if label.isNotEmpty && !label.equals(device.mac, ignoreCase: true) {
            named = label
        } else {
            let t = device.listTitle()
            named = (t.isNotBlank && !t.equals(device.mac, ignoreCase: true)) ? t : "radio"
        }
        return speakableWatchName(name: named)
    }
    let preferred = target?.fleetId.flatMap { device.fleetIds.contains($0) ? $0 : nil }
    guard let id = preferred ?? device.fleetIds.first else { return "unmatched" }
    guard let fleet = fleets.first(where: { $0.id == id }) else { return "unmatched" }
    let cls = fleet.kind.speechLabel()
    let sig = fleet.speechName()
    switch what {
    case .class: return cls
    case .signature: return sig
    case .both: return cls.equals(sig, ignoreCase: true) ? cls : "\(cls), \(sig)"
    }
}

/// Test alert uses a Finder-tags / AirTags example so you can hear the mix without a live hit.
public func testWatchPhrase(what: AlertVoiceWhat) -> String {
    switch what {
    case .class: return SignatureClass.finder.speechLabel()
    case .signature: return speakableWatchName(name: "Apple AirTags")
    case .both: return "\(SignatureClass.finder.speechLabel()), \(speakableWatchName(name: "Apple AirTags"))"
    }
}

public enum SignatureListSort: String, Codable, CaseIterable, Sendable {
    case name = "NAME", `class` = "CLASS"

    public func label() -> String { self == .name ? "Name A–Z" : "Class A–Z" }
}

public enum StrengthSort: String, Codable, CaseIterable, Sendable { case instant = "INSTANT", average = "AVERAGE" }

public enum ListSort: String, Codable, CaseIterable, Sendable {
    case strength = "STRENGTH", newest = "NEWEST", newestAlert = "NEWEST_ALERT", firstSeen = "FIRST_SEEN"
    case arrival = "ARRIVAL", name = "NAME", signatures = "SIGNATURES"
}

/// What the Live list title or subtitle shows. NONE is subtitle-only. Always write `ListLine.none`.
public enum ListLine: String, Codable, CaseIterable, Sendable {
    case advertisedName = "ADVERTISED_NAME", nameAndType = "NAME_AND_TYPE", mac = "MAC", none = "NONE"
}

public enum RssiTrend: String, CaseIterable, Sendable { case upFast, up, flat, down, downFast, unknown }

public enum RuleKind: String, Codable, CaseIterable, Sendable {
    case oui = "OUI"
    case macPrefix = "MAC_PREFIX"
    case nameContains = "NAME_CONTAINS"
    case nameGlob = "NAME_GLOB"
    case serviceUuid = "SERVICE_UUID"
    case serviceData = "SERVICE_DATA"
    case manufacturerId = "MANUFACTURER_ID"
    case manufacturerData = "MANUFACTURER_DATA"
    case radioKind = "RADIO_KIND"
    case hiddenSsid = "HIDDEN_SSID"
    case vendorIeOui = "VENDOR_IE_OUI"
}

public struct MatchRule: Codable, Hashable, Sendable {
    public var kind: RuleKind
    public var text: String
    public var companyId: Int
    public var dataPrefixHex: String
    public var radio: RadioKind?
    public var enabled: Bool

    public init(kind: RuleKind, text: String = "", companyId: Int = 0, dataPrefixHex: String = "", radio: RadioKind? = nil, enabled: Bool = true) {
        self.kind = kind; self.text = text; self.companyId = companyId
        self.dataPrefixHex = dataPrefixHex; self.radio = radio; self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey { case kind, text, companyId, dataPrefixHex, radio, enabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(RuleKind.self, forKey: .kind)
        text = try c.decode(.text, default: "")
        companyId = try c.decode(.companyId, default: 0)
        dataPrefixHex = try c.decode(.dataPrefixHex, default: "")
        radio = try c.opt(.radio)
        enabled = try c.decode(.enabled, default: true)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(text, forKey: .text)
        try c.encode(companyId, forKey: .companyId)
        try c.encode(dataPrefixHex, forKey: .dataPrefixHex)
        try c.encode(radio, forKey: .radio)
        try c.encode(enabled, forKey: .enabled)
    }

    public func couldMatchBle() -> Bool {
        switch kind {
        case .hiddenSsid, .vendorIeOui: return false
        case .serviceUuid, .serviceData, .manufacturerId, .manufacturerData: return true
        default: return radio != .wifi
        }
    }
}

public struct Fleet: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var matchAny: Bool
    public var colorIndex: Int
    public var rules: [MatchRule]
    public var minPeers: Int
    public var peerWindowSec: Int
    public var clusterByOui: Bool
    public var sequentialMac: Bool
    public var notes: String
    /// Operator-facing caution. Empty = no Live mark, no Extra attention card, no Debrief line.
    public var attentionNote: String
    public var builtIn: Bool
    public var kind: SignatureClass
    /// Optional BLE cleartext field map. Nil = no signature decode. Omitted from JSON when nil.
    public var decode: FleetDecode?

    public init(
        id: String, name: String, enabled: Bool = true, matchAny: Bool = true, colorIndex: Int = 0,
        rules: [MatchRule] = [], minPeers: Int = 0, peerWindowSec: Int = 60, clusterByOui: Bool = false,
        sequentialMac: Bool = false, notes: String = "", attentionNote: String = "", builtIn: Bool = false,
        kind: SignatureClass = .other, decode: FleetDecode? = nil
    ) {
        self.id = id; self.name = name; self.enabled = enabled; self.matchAny = matchAny
        self.colorIndex = colorIndex; self.rules = rules; self.minPeers = minPeers
        self.peerWindowSec = peerWindowSec; self.clusterByOui = clusterByOui; self.sequentialMac = sequentialMac
        self.notes = notes; self.attentionNote = attentionNote; self.builtIn = builtIn; self.kind = kind
        self.decode = decode
    }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, matchAny, colorIndex, rules, minPeers, peerWindowSec, clusterByOui
        case sequentialMac, notes, attentionNote, builtIn, kind, decode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decode(.enabled, default: true)
        matchAny = try c.decode(.matchAny, default: true)
        colorIndex = try c.decode(.colorIndex, default: 0)
        rules = try c.decode(.rules, default: [])
        minPeers = try c.decode(.minPeers, default: 0)
        peerWindowSec = try c.decode(.peerWindowSec, default: 60)
        clusterByOui = try c.decode(.clusterByOui, default: false)
        sequentialMac = try c.decode(.sequentialMac, default: false)
        notes = try c.decode(.notes, default: "")
        attentionNote = try c.decode(.attentionNote, default: "")
        builtIn = try c.decode(.builtIn, default: false)
        kind = try c.decode(.kind, default: .other)
        decode = try c.opt(.decode)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(matchAny, forKey: .matchAny)
        try c.encode(colorIndex, forKey: .colorIndex)
        try c.encode(rules, forKey: .rules)
        try c.encode(minPeers, forKey: .minPeers)
        try c.encode(peerWindowSec, forKey: .peerWindowSec)
        try c.encode(clusterByOui, forKey: .clusterByOui)
        try c.encode(sequentialMac, forKey: .sequentialMac)
        try c.encode(notes, forKey: .notes)
        try c.encode(attentionNote, forKey: .attentionNote)
        try c.encode(builtIn, forKey: .builtIn)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(decode, forKey: .decode)
    }

    /// Decode fields only apply to BLE ads. Hide the editor on Wi-Fi-only signatures.
    public func canHaveBleDecode() -> Bool {
        if rules.isEmpty { return true }
        return rules.contains { $0.couldMatchBle() }
    }
}

public enum DecodeSource: String, Codable, CaseIterable, Sendable {
    case manufacturerData, serviceData
    /// Pack named a source this build does not parse. Never written (encodes as manufacturerData).
    case unsupported

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = raw == "manufacturerData" ? .manufacturerData : (raw == "serviceData" ? .serviceData : .unsupported)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(self == .serviceData ? "serviceData" : "manufacturerData")
    }
}

public enum DecodeType: String, Codable, CaseIterable, Sendable {
    case u8, i8, u16, i16, u24, u32, i32, f32, bits, utf8, hex, mac, bool

    public func defaultLength() -> Int {
        switch self {
        case .u8, .i8, .bool: return 1
        case .u16, .i16: return 2
        case .u24: return 3
        case .u32, .i32, .f32: return 4
        case .mac: return 6
        case .bits, .utf8, .hex: return 1
        }
    }
}

public enum DecodeEndian: String, Codable, CaseIterable, Sendable { case le, be }

public enum DecodeWhenOp: String, Codable, CaseIterable, Sendable {
    case eq, neq, mask
    /// Inverse of mask: every 1-bit in Hex must be clear in the payload slice.
    case nmask
    /// Payload byte length equals `DecodeWhen.length`. offset/valueHex ignored.
    case len
}

public final class DecodeWhenBox: Hashable, @unchecked Sendable {
    public let value: DecodeWhen
    public init(_ v: DecodeWhen) { value = v }
    public static func == (a: DecodeWhenBox, b: DecodeWhenBox) -> Bool { a.value == b.value }
    public func hash(into h: inout Hasher) { h.combine(value) }
}

public struct DecodeWhen: Codable, Hashable, Sendable {
    public var offset: Int
    public var length: Int
    public var op: DecodeWhenOp
    public var valueHex: String
    /// Extra constraint; both must pass. Omitted from JSON when nil.
    public var and: DecodeWhen? {
        get { andBox?.value }
        set { andBox = newValue.map(DecodeWhenBox.init) }
    }
    private var andBox: DecodeWhenBox?

    public init(offset: Int, length: Int = 1, op: DecodeWhenOp, valueHex: String, and: DecodeWhen? = nil) {
        self.offset = offset; self.length = length; self.op = op; self.valueHex = valueHex
        self.andBox = and.map(DecodeWhenBox.init)
    }

    enum CodingKeys: String, CodingKey { case offset, length, op, valueHex, and }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        offset = try c.decode(Int.self, forKey: .offset)
        length = try c.decode(.length, default: 1)
        op = try c.decode(DecodeWhenOp.self, forKey: .op)
        valueHex = try c.decode(String.self, forKey: .valueHex)
        andBox = (try c.opt(.and) as DecodeWhen?).map(DecodeWhenBox.init)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(offset, forKey: .offset)
        try c.encode(length, forKey: .length)
        try c.encode(op, forKey: .op)
        try c.encode(valueHex, forKey: .valueHex)
        try c.encodeIfPresent(and, forKey: .and)
    }
}

public struct DecodeField: Codable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var offset: Int
    public var length: Int?
    public var type: DecodeType
    public var endian: DecodeEndian
    public var bitOffset: Int?
    public var bitWidth: Int?
    public var scale: Double?
    public var offsetAdd: Double?
    /// Remainder after the integer/float read, before scale. Govee packed humidity is `% 1000`.
    public var modulo: Double?
    public var unit: String?
    /// JSON key "enum".
    public var enumLabels: [String: String]?
    /// Show this field's decoded label on the live row. Omitted from JSON when false.
    public var live: Bool
    /// Raw enum keys whose label uses the stronger live chip. Omitted when empty.
    public var liveEmphasis: [String]
    /// Sentence for a named value, keyed like enumLabels. Omitted when nil.
    public var enumNotes: [String: String]?
    /// JSON key "when".
    public var gate: DecodeWhen?

    public init(
        id: String, label: String, offset: Int, length: Int? = nil, type: DecodeType, endian: DecodeEndian = .le,
        bitOffset: Int? = nil, bitWidth: Int? = nil, scale: Double? = nil, offsetAdd: Double? = nil,
        modulo: Double? = nil, unit: String? = nil, enumLabels: [String: String]? = nil, live: Bool = false,
        liveEmphasis: [String] = [], enumNotes: [String: String]? = nil, gate: DecodeWhen? = nil
    ) {
        self.id = id; self.label = label; self.offset = offset; self.length = length; self.type = type
        self.endian = endian; self.bitOffset = bitOffset; self.bitWidth = bitWidth; self.scale = scale
        self.offsetAdd = offsetAdd; self.modulo = modulo; self.unit = unit; self.enumLabels = enumLabels
        self.live = live; self.liveEmphasis = liveEmphasis; self.enumNotes = enumNotes; self.gate = gate
    }

    enum CodingKeys: String, CodingKey {
        case id, label, offset, length, type, endian, bitOffset, bitWidth, scale, offsetAdd, modulo, unit
        case enumLabels = "enum", live, liveEmphasis, enumNotes, gate = "when"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        offset = try c.decode(Int.self, forKey: .offset)
        length = try c.opt(.length)
        type = try c.decode(DecodeType.self, forKey: .type)
        endian = try c.decode(.endian, default: .le)
        bitOffset = try c.opt(.bitOffset)
        bitWidth = try c.opt(.bitWidth)
        scale = try c.opt(.scale)
        offsetAdd = try c.opt(.offsetAdd)
        modulo = try c.opt(.modulo)
        unit = try c.opt(.unit)
        enumLabels = try c.opt(.enumLabels)
        live = try c.decode(.live, default: false)
        liveEmphasis = try c.decode(.liveEmphasis, default: [])
        enumNotes = try c.opt(.enumNotes)
        gate = try c.opt(.gate)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(offset, forKey: .offset)
        try c.encode(length, forKey: .length)
        try c.encode(type, forKey: .type)
        try c.encode(endian, forKey: .endian)
        try c.encode(bitOffset, forKey: .bitOffset)
        try c.encode(bitWidth, forKey: .bitWidth)
        try c.encode(scale, forKey: .scale)
        try c.encode(offsetAdd, forKey: .offsetAdd)
        try c.encode(modulo, forKey: .modulo)
        try c.encode(unit, forKey: .unit)
        try c.encode(enumLabels, forKey: .enumLabels)
        if live { try c.encode(live, forKey: .live) }
        if liveEmphasis.isNotEmpty { try c.encode(liveEmphasis, forKey: .liveEmphasis) }
        try c.encodeIfPresent(enumNotes, forKey: .enumNotes)
        try c.encode(gate, forKey: .gate)
    }

    public func resolvedLength() -> Int {
        if let length, length > 0 { return length }
        if type == .bits {
            let start = bitOffset ?? 0
            let width = bitWidth ?? 1
            return ((start + width + 7) / 8).coerceAtLeast(1)
        }
        return type.defaultLength()
    }
}

public struct FleetDecode: Codable, Hashable, Sendable {
    public var source: DecodeSource
    public var serviceUuid: String?
    public var companyId: Int?
    /// Prepend the two-byte LE company ID to manufacturer data before the field map runs. Omitted when false.
    public var includeCompanyId: Bool
    public var fields: [DecodeField]

    public init(source: DecodeSource, serviceUuid: String? = nil, companyId: Int? = nil, includeCompanyId: Bool = false, fields: [DecodeField] = []) {
        self.source = source; self.serviceUuid = serviceUuid; self.companyId = companyId
        self.includeCompanyId = includeCompanyId; self.fields = fields
    }

    enum CodingKeys: String, CodingKey { case source, serviceUuid, companyId, includeCompanyId, fields }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(DecodeSource.self, forKey: .source)
        serviceUuid = try c.opt(.serviceUuid)
        companyId = try c.opt(.companyId)
        includeCompanyId = try c.decode(.includeCompanyId, default: false)
        fields = try c.decode(.fields, default: [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encode(serviceUuid, forKey: .serviceUuid)
        try c.encode(companyId, forKey: .companyId)
        if includeCompanyId { try c.encode(includeCompanyId, forKey: .includeCompanyId) }
        try c.encode(fields, forKey: .fields)
    }
}

public extension Array where Element == Fleet {
    func sortedForCatalog(sort: SignatureListSort) -> [Fleet] {
        switch sort {
        case .name: return sortedBy { $0.name.lowercased() }
        case .class:
            return sortedWithComparator { a, b in
                let c = compareValues(a.kind.label().lowercased(), b.kind.label().lowercased())
                return c != 0 ? c : compareValues(a.name.lowercased(), b.name.lowercased())
            }
        }
    }

    func groupedByClass() -> [(SignatureClass, [Fleet])] {
        groupByOrdered { $0.kind }
            .sortedBy { $0.0.label().lowercased() }
            .map { ($0.0, $0.1.sortedBy { $0.name.lowercased() }) }
    }
}

public extension Sighting {
    /// Signature name + Extra attention text for every matched signature on this radio that has one.
    func attentionNotes(fleets: [Fleet]) -> [(String, String)] {
        if fleetIds.isEmpty { return [] }
        let byId = fleets.associateBy { $0.id }
        return fleetIds.compactMap { id in
            guard let fleet = byId[id] else { return nil }
            let note = fleet.attentionNote.trim()
            return note.isEmpty ? nil : (fleet.name, note)
        }
    }

    /// Signature name + Notes for every matched signature on this radio that has notes. Not Extra attention.
    func signatureNotes(fleets: [Fleet]) -> [(String, String)] {
        if fleetIds.isEmpty { return [] }
        let byId = fleets.associateBy { $0.id }
        return fleetIds.compactMap { id in
            guard let fleet = byId[id] else { return nil }
            let note = fleet.notes.trim()
            return note.isEmpty ? nil : (fleet.name, note)
        }
    }
}

public struct FilterState: Codable, Hashable, Sendable {
    public var namedOnly = false
    /// Live include: only radios with a custom name (Settings → Named radios).
    public var customNamesOnly = false
    /// Live include: bookmarked signatures or Named radios with Alert on.
    public var watchedOnly = false
    public var useFleetFilter = false
    public var excludeSignatures = false
    public var fleetIds: Set<String> = []
    /// Live include: only radios matching these signature ids. Empty set = no extra include gate.
    public var includeSignatures = false
    public var includeFleetIds: Set<String> = []
    public var showWifi = true
    public var showBle = true
    public var rssiMin = -100
    public var nameQuery = ""
    public var ouiQuery = ""
    public var logic: FilterLogic = .and
    public var movingWithYou = false
    /// Hide already-seen radios; Mark seen / Reset seen live with this switch.
    public var arrivalsOnly = false
    /// Hide Fast Pair account-key-only radios (plaza noise).
    public var hideFastPairAccountKey = false
    /// Include or hide Live rows by Fleet.kind.
    public var useClassFilter = false
    public var excludeClasses = false
    public var classes: Set<SignatureClass> = []
    /// Live hide: radios marked Mine. The sit and Debrief still include them.
    public var hideMine = false

    public init(
        namedOnly: Bool = false,
        customNamesOnly: Bool = false,
        watchedOnly: Bool = false,
        useFleetFilter: Bool = false,
        excludeSignatures: Bool = false,
        fleetIds: Set<String> = [],
        includeSignatures: Bool = false,
        includeFleetIds: Set<String> = [],
        showWifi: Bool = true,
        showBle: Bool = true,
        rssiMin: Int = -100,
        nameQuery: String = "",
        ouiQuery: String = "",
        logic: FilterLogic = .and,
        movingWithYou: Bool = false,
        arrivalsOnly: Bool = false,
        hideFastPairAccountKey: Bool = false,
        useClassFilter: Bool = false,
        excludeClasses: Bool = false,
        classes: Set<SignatureClass> = [],
        hideMine: Bool = false
    ) {
        self.namedOnly = namedOnly
        self.customNamesOnly = customNamesOnly
        self.watchedOnly = watchedOnly
        self.useFleetFilter = useFleetFilter
        self.excludeSignatures = excludeSignatures
        self.fleetIds = fleetIds
        self.includeSignatures = includeSignatures
        self.includeFleetIds = includeFleetIds
        self.showWifi = showWifi
        self.showBle = showBle
        self.rssiMin = rssiMin
        self.nameQuery = nameQuery
        self.ouiQuery = ouiQuery
        self.logic = logic
        self.movingWithYou = movingWithYou
        self.arrivalsOnly = arrivalsOnly
        self.hideFastPairAccountKey = hideFastPairAccountKey
        self.useClassFilter = useClassFilter
        self.excludeClasses = excludeClasses
        self.classes = classes
        self.hideMine = hideMine
    }

    enum CodingKeys: String, CodingKey {
        case namedOnly, customNamesOnly, watchedOnly, useFleetFilter, excludeSignatures, fleetIds
        case includeSignatures, includeFleetIds, showWifi, showBle, rssiMin, nameQuery, ouiQuery, logic
        case movingWithYou, arrivalsOnly, hideFastPairAccountKey, useClassFilter, excludeClasses, classes, hideMine
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FilterState()
        namedOnly = try c.decode(.namedOnly, default: d.namedOnly)
        customNamesOnly = try c.decode(.customNamesOnly, default: d.customNamesOnly)
        watchedOnly = try c.decode(.watchedOnly, default: d.watchedOnly)
        useFleetFilter = try c.decode(.useFleetFilter, default: d.useFleetFilter)
        excludeSignatures = try c.decode(.excludeSignatures, default: d.excludeSignatures)
        fleetIds = try c.decode(.fleetIds, default: d.fleetIds)
        includeSignatures = try c.decode(.includeSignatures, default: d.includeSignatures)
        includeFleetIds = try c.decode(.includeFleetIds, default: d.includeFleetIds)
        showWifi = try c.decode(.showWifi, default: d.showWifi)
        showBle = try c.decode(.showBle, default: d.showBle)
        rssiMin = try c.decode(.rssiMin, default: d.rssiMin)
        nameQuery = try c.decode(.nameQuery, default: d.nameQuery)
        ouiQuery = try c.decode(.ouiQuery, default: d.ouiQuery)
        logic = try c.decode(.logic, default: d.logic)
        movingWithYou = try c.decode(.movingWithYou, default: d.movingWithYou)
        arrivalsOnly = try c.decode(.arrivalsOnly, default: d.arrivalsOnly)
        hideFastPairAccountKey = try c.decode(.hideFastPairAccountKey, default: d.hideFastPairAccountKey)
        useClassFilter = try c.decode(.useClassFilter, default: d.useClassFilter)
        excludeClasses = try c.decode(.excludeClasses, default: d.excludeClasses)
        classes = try c.decode(.classes, default: d.classes)
        hideMine = try c.decode(.hideMine, default: d.hideMine)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(namedOnly, forKey: .namedOnly)
        try c.encode(customNamesOnly, forKey: .customNamesOnly)
        try c.encode(watchedOnly, forKey: .watchedOnly)
        try c.encode(useFleetFilter, forKey: .useFleetFilter)
        try c.encode(excludeSignatures, forKey: .excludeSignatures)
        try c.encode(fleetIds.sorted(), forKey: .fleetIds)
        try c.encode(includeSignatures, forKey: .includeSignatures)
        try c.encode(includeFleetIds.sorted(), forKey: .includeFleetIds)
        try c.encode(showWifi, forKey: .showWifi)
        try c.encode(showBle, forKey: .showBle)
        try c.encode(rssiMin, forKey: .rssiMin)
        try c.encode(nameQuery, forKey: .nameQuery)
        try c.encode(ouiQuery, forKey: .ouiQuery)
        try c.encode(logic, forKey: .logic)
        try c.encode(movingWithYou, forKey: .movingWithYou)
        try c.encode(arrivalsOnly, forKey: .arrivalsOnly)
        try c.encode(hideFastPairAccountKey, forKey: .hideFastPairAccountKey)
        try c.encode(useClassFilter, forKey: .useClassFilter)
        try c.encode(excludeClasses, forKey: .excludeClasses)
        try c.encode(classes.sorted { $0.ordinal < $1.ordinal }, forKey: .classes)
        try c.encode(hideMine, forKey: .hideMine)
    }

    /// Show only is narrowing Live to at least one picked class.
    public func classIncludeActive() -> Bool { useClassFilter && !excludeClasses && classes.isNotEmpty }
    public func signatureIncludeActive() -> Bool { includeSignatures && includeFleetIds.isNotEmpty }
    public func namedOnlyImplied() -> Bool { classIncludeActive() || signatureIncludeActive() }
}

public struct FilterPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var filter: FilterState

    public init(id: String, name: String, filter: FilterState) { self.id = id; self.name = name; self.filter = filter }

    public func isBuiltIn() -> Bool { builtInPresetIds.contains(id) }
}

private let builtInPresetIds: Set<String> = [
    "all", "wifi", "ble", "strong", "with-you", "watched",
    // Retired stock chips. Kept so an upgrade does not treat them as custom.
    "trackers", "hide-trackers", "hide-phones", "named", "surveillance", "drones", "beacons", "signage",
    "wearables", "pentest", "locks", "bodyworn", "vehicle", "glasses", "audio", "cameras",
]

public struct WatchTarget: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var fleetId: String?
    public var deviceKey: String?
    public var label: String
    public var vibrate: Bool
    public var notify: Bool
    /// Device-key rows only. False = named radio, no pip/voice/flash. Missing JSON = on.
    public var alert: Bool
    /// Operator caption on this MAC. Empty = none.
    public var observerNotes: String
    /// This radio is the operator's. Missing JSON = off.
    public var mine: Bool

    public init(id: String, fleetId: String? = nil, deviceKey: String? = nil, label: String, vibrate: Bool = true,
                notify: Bool = true, alert: Bool = true, observerNotes: String = "", mine: Bool = false) {
        self.id = id; self.fleetId = fleetId; self.deviceKey = deviceKey; self.label = label; self.vibrate = vibrate
        self.notify = notify; self.alert = alert; self.observerNotes = observerNotes; self.mine = mine
    }

    enum CodingKeys: String, CodingKey { case id, fleetId, deviceKey, label, vibrate, notify, alert, observerNotes, mine }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        fleetId = try c.opt(.fleetId)
        deviceKey = try c.opt(.deviceKey)
        label = try c.decode(String.self, forKey: .label)
        vibrate = try c.decode(.vibrate, default: true)
        notify = try c.decode(.notify, default: true)
        alert = try c.decode(.alert, default: true)
        observerNotes = try c.decode(.observerNotes, default: "")
        mine = try c.decode(.mine, default: false)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(fleetId, forKey: .fleetId)
        try c.encode(deviceKey, forKey: .deviceKey)
        try c.encode(label, forKey: .label)
        try c.encode(vibrate, forKey: .vibrate)
        try c.encode(notify, forKey: .notify)
        try c.encode(alert, forKey: .alert)
        try c.encode(observerNotes, forKey: .observerNotes)
        try c.encode(mine, forKey: .mine)
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    /// Kept in settings packs. The UI is always dark; Night mode is the red overlay.
    public var darkTheme = true
    public var keepScreenOn = true
    public var intensity: ScanIntensity = .performance
    public var loggingEnabled = true
    public var logFormat: LogFormat = .csv
    public var logRotateKb = 1024
    public var staleSec = 45
    public var alertsEnabled = true
    public var alertBeep = true
    /// Speak after a watchlist alert. What to say is alertVoiceWhat.
    public var alertVoice = true
    public var alertVoiceWhat: AlertVoiceWhat = .both
    public var snapToBeep = true
    public var alertShade = false
    public var tagLocation = true
    /// Reverse-geocode GPS stamps in Debrief when online.
    public var onlineLookup = true
    public var viewMode: ViewMode = .byClass
    public var strengthSort: StrengthSort = .average
    public var averageWindowSec = 30
    public var listSort: ListSort = .strength
    public var showRssiBar = true
    public var showFleetName = true
    public var showFrequency = true
    public var showSeenTimes = true
    /// Live row first line. Default is MAC.
    public var listTitleLine: ListLine = .mac
    /// Live row second line. NONE hides the line.
    public var listSubtitleLine: ListLine = .nameAndType
    /// Brief hold seconds (0 = Off). Linger only; does not decay RSSI.
    public var decaySec = 10
    /// Live Tune / Display panel. Always starts collapsed.
    public var scanControlsExpanded = false
    /// Unused after catalog v5; kept so old JSON still decodes.
    public var arrivalsOnly = false
    public var arrivalHoldSec = 30
    public var detectSsidKeywords = true
    public var detectKnownOuis = true
    public var detectVendorIes = true
    public var detectBleRaven = true
    /// Privacy mode: on-screen and sit-report MAC tail and GPS mask. JSON key demoMode.
    public var demoMode = false
    /// When false, Debrief inventories omit unmatched rotating BLE.
    public var debriefShowUnmatchedRandomBle = false
    /// When false, Debrief and Compare print counts and only the notable radios.
    public var debriefShowAllRadios = false
    /// Android-only Wi-Fi throttle bypass. Kept for settings-pack compatibility.
    public var wifiFastScan = false
    /// Hunt-page geiger tick. Not the watchlist chirp.
    public var huntBeep = false
    public var huntVibrate = false
    /// UDP Cursor-on-Target markers for ATAK / WinTAK / iTAK. Privacy mode pauses the feed.
    public var takEnabled = false
    public var takHost = TakDefaults.HOST
    public var takPort = TakDefaults.PORT
    public var takAttention = true
    public var takPayloadFix = true
    public var takWatchlist = false
    public var takAllSignatures = false
    public var takGnss: TakGnssSend = .off
    public var takGnssHold: TakGnssHold = .hour
    public var takRadioHold: TakGnssHold = .hour
    public var takFlood: TakFloodSend = .off
    /// Red-on-black field display.
    public var nightMode = false
    /// First-run click-through. Scanning waits until disclaimerRev matches DISCLAIMER_REV.
    public var disclaimerAccepted = false
    public var disclaimerRev = 0
    public var liveTourDone = false
    public var signatureListSort: SignatureListSort = .name
    /// By class: hide class headers with 0 radios.
    public var outlineHideEmpty = false
    // GNSS settings: Android only (a Mac has no GNSS receiver). Kept for settings-pack compatibility.
    public var gnssMonitor = false
    public var gnssSensitivity: GnssSensitivity = .medium
    public var gnssAlertFloor: GnssAlertFloor = .medium
    public var gnssSpoofChecks = false
    public var gnssBeep = true
    public var gnssVoice = true
    public var gnssShade = false
    public var gnssFullTracking = false
    public var gnssCorrelation = false
    public var gnssInvertAgc = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let d = AppSettings()
        func v<T: Decodable>(_ k: String, _ def: T) throws -> T { try c.decodeIfPresent(T.self, forKey: AnyKey(k)) ?? def }
        darkTheme = try v("darkTheme", d.darkTheme)
        keepScreenOn = try v("keepScreenOn", d.keepScreenOn)
        intensity = try v("intensity", d.intensity)
        loggingEnabled = try v("loggingEnabled", d.loggingEnabled)
        logFormat = try v("logFormat", d.logFormat)
        logRotateKb = try v("logRotateKb", d.logRotateKb)
        staleSec = try v("staleSec", d.staleSec)
        alertsEnabled = try v("alertsEnabled", d.alertsEnabled)
        alertBeep = try v("alertBeep", d.alertBeep)
        alertVoice = try v("alertVoice", d.alertVoice)
        alertVoiceWhat = try v("alertVoiceWhat", d.alertVoiceWhat)
        snapToBeep = try v("snapToBeep", d.snapToBeep)
        alertShade = try v("alertShade", d.alertShade)
        tagLocation = try v("tagLocation", d.tagLocation)
        onlineLookup = try v("onlineLookup", d.onlineLookup)
        viewMode = try v("viewMode", d.viewMode)
        strengthSort = try v("strengthSort", d.strengthSort)
        averageWindowSec = try v("averageWindowSec", d.averageWindowSec)
        listSort = try v("listSort", d.listSort)
        showRssiBar = try v("showRssiBar", d.showRssiBar)
        showFleetName = try v("showFleetName", d.showFleetName)
        showFrequency = try v("showFrequency", d.showFrequency)
        showSeenTimes = try v("showSeenTimes", d.showSeenTimes)
        listTitleLine = try v("listTitleLine", d.listTitleLine)
        listSubtitleLine = try v("listSubtitleLine", d.listSubtitleLine)
        decaySec = try v("decaySec", d.decaySec)
        scanControlsExpanded = try v("scanControlsExpanded", d.scanControlsExpanded)
        arrivalsOnly = try v("arrivalsOnly", d.arrivalsOnly)
        arrivalHoldSec = try v("arrivalHoldSec", d.arrivalHoldSec)
        detectSsidKeywords = try v("detectSsidKeywords", d.detectSsidKeywords)
        detectKnownOuis = try v("detectKnownOuis", d.detectKnownOuis)
        detectVendorIes = try v("detectVendorIes", d.detectVendorIes)
        detectBleRaven = try v("detectBleRaven", d.detectBleRaven)
        demoMode = try v("demoMode", d.demoMode)
        debriefShowUnmatchedRandomBle = try v("debriefShowUnmatchedRandomBle", d.debriefShowUnmatchedRandomBle)
        debriefShowAllRadios = try v("debriefShowAllRadios", d.debriefShowAllRadios)
        wifiFastScan = try v("wifiFastScan", d.wifiFastScan)
        huntBeep = try v("huntBeep", d.huntBeep)
        huntVibrate = try v("huntVibrate", d.huntVibrate)
        takEnabled = try v("takEnabled", d.takEnabled)
        takHost = try v("takHost", d.takHost)
        takPort = try v("takPort", d.takPort)
        takAttention = try v("takAttention", d.takAttention)
        takPayloadFix = try v("takPayloadFix", d.takPayloadFix)
        takWatchlist = try v("takWatchlist", d.takWatchlist)
        takAllSignatures = try v("takAllSignatures", d.takAllSignatures)
        takGnss = try v("takGnss", d.takGnss)
        takGnssHold = try v("takGnssHold", d.takGnssHold)
        takRadioHold = try v("takRadioHold", d.takRadioHold)
        takFlood = try v("takFlood", d.takFlood)
        nightMode = try v("nightMode", d.nightMode)
        disclaimerAccepted = try v("disclaimerAccepted", d.disclaimerAccepted)
        disclaimerRev = try v("disclaimerRev", d.disclaimerRev)
        liveTourDone = try v("liveTourDone", d.liveTourDone)
        signatureListSort = try v("signatureListSort", d.signatureListSort)
        outlineHideEmpty = try v("outlineHideEmpty", d.outlineHideEmpty)
        gnssMonitor = try v("gnssMonitor", d.gnssMonitor)
        gnssSensitivity = try v("gnssSensitivity", d.gnssSensitivity)
        gnssAlertFloor = try v("gnssAlertFloor", d.gnssAlertFloor)
        gnssSpoofChecks = try v("gnssSpoofChecks", d.gnssSpoofChecks)
        gnssBeep = try v("gnssBeep", d.gnssBeep)
        gnssVoice = try v("gnssVoice", d.gnssVoice)
        gnssShade = try v("gnssShade", d.gnssShade)
        gnssFullTracking = try v("gnssFullTracking", d.gnssFullTracking)
        gnssCorrelation = try v("gnssCorrelation", d.gnssCorrelation)
        gnssInvertAgc = try v("gnssInvertAgc", d.gnssInvertAgc)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        func w<T: Encodable>(_ k: String, _ x: T) throws { try c.encode(x, forKey: AnyKey(k)) }
        try w("darkTheme", darkTheme); try w("keepScreenOn", keepScreenOn); try w("intensity", intensity)
        try w("loggingEnabled", loggingEnabled); try w("logFormat", logFormat); try w("logRotateKb", logRotateKb)
        try w("staleSec", staleSec); try w("alertsEnabled", alertsEnabled); try w("alertBeep", alertBeep)
        try w("alertVoice", alertVoice); try w("alertVoiceWhat", alertVoiceWhat); try w("snapToBeep", snapToBeep)
        try w("alertShade", alertShade); try w("tagLocation", tagLocation); try w("onlineLookup", onlineLookup)
        try w("viewMode", viewMode); try w("strengthSort", strengthSort); try w("averageWindowSec", averageWindowSec)
        try w("listSort", listSort); try w("showRssiBar", showRssiBar); try w("showFleetName", showFleetName)
        try w("showFrequency", showFrequency); try w("showSeenTimes", showSeenTimes)
        try w("listTitleLine", listTitleLine); try w("listSubtitleLine", listSubtitleLine); try w("decaySec", decaySec)
        try w("scanControlsExpanded", scanControlsExpanded); try w("arrivalsOnly", arrivalsOnly)
        try w("arrivalHoldSec", arrivalHoldSec); try w("detectSsidKeywords", detectSsidKeywords)
        try w("detectKnownOuis", detectKnownOuis); try w("detectVendorIes", detectVendorIes)
        try w("detectBleRaven", detectBleRaven); try w("demoMode", demoMode)
        try w("debriefShowUnmatchedRandomBle", debriefShowUnmatchedRandomBle)
        try w("debriefShowAllRadios", debriefShowAllRadios); try w("wifiFastScan", wifiFastScan)
        try w("huntBeep", huntBeep); try w("huntVibrate", huntVibrate); try w("takEnabled", takEnabled)
        try w("takHost", takHost); try w("takPort", takPort); try w("takAttention", takAttention)
        try w("takPayloadFix", takPayloadFix); try w("takWatchlist", takWatchlist)
        try w("takAllSignatures", takAllSignatures); try w("takGnss", takGnss); try w("takGnssHold", takGnssHold)
        try w("takRadioHold", takRadioHold); try w("takFlood", takFlood); try w("nightMode", nightMode)
        try w("disclaimerAccepted", disclaimerAccepted); try w("disclaimerRev", disclaimerRev)
        try w("liveTourDone", liveTourDone); try w("signatureListSort", signatureListSort)
        try w("outlineHideEmpty", outlineHideEmpty); try w("gnssMonitor", gnssMonitor)
        try w("gnssSensitivity", gnssSensitivity); try w("gnssAlertFloor", gnssAlertFloor)
        try w("gnssSpoofChecks", gnssSpoofChecks); try w("gnssBeep", gnssBeep); try w("gnssVoice", gnssVoice)
        try w("gnssShade", gnssShade); try w("gnssFullTracking", gnssFullTracking)
        try w("gnssCorrelation", gnssCorrelation); try w("gnssInvertAgc", gnssInvertAgc)
    }

    public func disclaimerOk() -> Bool { disclaimerRev >= DISCLAIMER_REV }

    /// Every GNSS setting, for change detection (Kotlin returns List<Any>).
    public func gnssSettings() -> [AnyHashable] {
        [gnssMonitor, gnssSensitivity, gnssAlertFloor, gnssSpoofChecks, gnssBeep, gnssVoice, gnssShade,
         gnssFullTracking, gnssCorrelation, gnssInvertAgc]
    }

    public func detectionPolicy() -> DetectionPolicy {
        DetectionPolicy(ssidKeywords: detectSsidKeywords, knownOuis: detectKnownOuis, vendorIes: detectVendorIes, bleRaven: detectBleRaven)
    }
}

public let DISCLAIMER_REV = 3

public struct DetectionPolicy: Hashable, Sendable {
    public var ssidKeywords = true
    public var knownOuis = true
    public var vendorIes = true
    public var bleRaven = true
    public init(ssidKeywords: Bool = true, knownOuis: Bool = true, vendorIes: Bool = true, bleRaven: Bool = true) {
        self.ssidKeywords = ssidKeywords; self.knownOuis = knownOuis; self.vendorIes = vendorIes; self.bleRaven = bleRaven
    }
}

public struct PersistedConfig: Codable, Hashable, Sendable {
    public var version = 1
    public var fleets: [Fleet] = []
    public var filter = FilterState()
    public var presets: [FilterPreset] = []
    public var watchlist: [WatchTarget] = []
    public var settings = AppSettings()
    /// Kotlin `Set<String>` (LinkedHashSet). Ordered and distinct here, oldest first: the app trims the
    /// oldest keys past its cap, so the saved order has to survive a relaunch.
    public var arrivalKnownKeys: [String] = []
    /// Stock filter-chip ids the operator removed. Catalog migrates do not put these back.
    public var hiddenPresetIds: Set<String> = []

    public init(
        version: Int = 1, fleets: [Fleet] = [], filter: FilterState = FilterState(), presets: [FilterPreset] = [],
        watchlist: [WatchTarget] = [], settings: AppSettings = AppSettings(), arrivalKnownKeys: [String] = [],
        hiddenPresetIds: Set<String> = []
    ) {
        self.version = version; self.fleets = fleets; self.filter = filter; self.presets = presets
        self.watchlist = watchlist; self.settings = settings; self.arrivalKnownKeys = arrivalKnownKeys.distinct()
        self.hiddenPresetIds = hiddenPresetIds
    }

    enum CodingKeys: String, CodingKey { case version, fleets, filter, presets, watchlist, settings, arrivalKnownKeys, hiddenPresetIds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(.version, default: 1)
        fleets = try c.decode(.fleets, default: [])
        filter = try c.decode(.filter, default: FilterState())
        presets = try c.decode(.presets, default: [])
        watchlist = try c.decode(.watchlist, default: [])
        settings = try c.decode(.settings, default: AppSettings())
        arrivalKnownKeys = (try c.decode(.arrivalKnownKeys, default: [String]())).distinct()
        hiddenPresetIds = try c.decode(.hiddenPresetIds, default: [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(fleets, forKey: .fleets)
        try c.encode(filter, forKey: .filter)
        try c.encode(presets, forKey: .presets)
        try c.encode(watchlist, forKey: .watchlist)
        try c.encode(settings, forKey: .settings)
        try c.encode(arrivalKnownKeys, forKey: .arrivalKnownKeys)
        try c.encode(hiddenPresetIds.sorted(), forKey: .hiddenPresetIds)
    }
}

public struct RssiSample: Hashable, Sendable {
    public var at: Int
    public var rssi: Int
    public init(at: Int, rssi: Int) { self.at = at; self.rssi = rssi }
}

public struct GpsSample: Codable, Hashable, Sendable {
    public var at: Int
    public var lat: Double
    public var lon: Double
    public var rssi: Int

    public init(at: Int, lat: Double, lon: Double, rssi: Int = 0) { self.at = at; self.lat = lat; self.lon = lon; self.rssi = rssi }

    enum CodingKeys: String, CodingKey { case at, lat, lon, rssi }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decode(Int.self, forKey: .at)
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        rssi = try c.decode(.rssi, default: 0)
    }
}

public struct PresenceSpan: Hashable, Sendable {
    public var start: Int
    public var end: Int?
    public init(start: Int, end: Int?) { self.start = start; self.end = end }
}

public struct Sighting: Hashable, Identifiable, Sendable {
    public var id: String { key }
    public var key: String
    public var kind: RadioKind
    /// Wi-Fi: BSSID. BLE on macOS: CoreBluetooth peripheral UUID (see MacUtil.isOpaqueId).
    public var mac: String
    public var name: String
    public var rssi: Int
    public var rssiMin: Int
    public var rssiMax: Int
    public var channel: Int
    public var frequencyMhz: Int
    public var vendor: String?
    public var randomized: Bool
    public var hiddenSsid: Bool
    public var serviceUuids: [String]
    public var manufacturerId: Int?
    public var manufacturerDataHex: String
    public var rawHex: String
    public var extras: String
    public var firstSeen: Int
    public var lastSeen: Int
    public var hitCount: Int
    /// Matched signature ids, distinct, in match order (Kotlin LinkedHashSet order).
    public var fleetIds: [String]
    public var rssiHistory: [RssiSample]
    public var presence: [PresenceSpan]
    public var latitude: Double?
    public var longitude: Double?
    public var gone: Bool
    public var vendorIeOuis: [String]
    public var facts: RadioFacts
    public var gpsTrail: [GpsSample]
    /// Fast Pair 3-byte model ID seen this session.
    public var fastPairPairing: Bool
    /// Sticky advertised WGS84 from decode field ids latitude/longitude.
    public var payloadLat: Double?
    public var payloadLon: Double?
    public var payloadAlt: Double?
    /// Remote ID System operator (pilot) location. Not the aircraft pin.
    public var payloadOpLat: Double?
    public var payloadOpLon: Double?
    /// Sticky Remote ID Basic ID / Self ID.
    public var payloadUasId: String?
    /// Maker from a CTA-2063 serial on this radio.
    public var payloadAircraft: String?
    public var payloadSelfId: String?
    public var payloadHeading: Double?
    public var payloadSpeed: Double?
    public var payloadVspeed: Double?
    /// Advertised fixes kept by the sit.
    public var payloadTrail: [PayloadFix]
    /// Decoded labels a signature asked to show on the live row.
    public var liveDecode: [LiveDecodeChip]

    public init(
        key: String, kind: RadioKind, mac: String, name: String, rssi: Int, rssiMin: Int, rssiMax: Int,
        channel: Int, frequencyMhz: Int, vendor: String?, randomized: Bool, hiddenSsid: Bool,
        serviceUuids: [String], manufacturerId: Int?, manufacturerDataHex: String, rawHex: String, extras: String,
        firstSeen: Int, lastSeen: Int, hitCount: Int, fleetIds: [String], rssiHistory: [RssiSample],
        presence: [PresenceSpan], latitude: Double? = nil, longitude: Double? = nil, gone: Bool = false,
        vendorIeOuis: [String] = [], facts: RadioFacts = .Empty, gpsTrail: [GpsSample] = [],
        fastPairPairing: Bool = false, payloadLat: Double? = nil, payloadLon: Double? = nil,
        payloadAlt: Double? = nil, payloadOpLat: Double? = nil, payloadOpLon: Double? = nil,
        payloadUasId: String? = nil, payloadAircraft: String? = nil, payloadSelfId: String? = nil,
        payloadHeading: Double? = nil, payloadSpeed: Double? = nil, payloadVspeed: Double? = nil,
        payloadTrail: [PayloadFix] = [], liveDecode: [LiveDecodeChip] = []
    ) {
        self.key = key; self.kind = kind; self.mac = mac; self.name = name; self.rssi = rssi
        self.rssiMin = rssiMin; self.rssiMax = rssiMax; self.channel = channel; self.frequencyMhz = frequencyMhz
        self.vendor = vendor; self.randomized = randomized; self.hiddenSsid = hiddenSsid
        self.serviceUuids = serviceUuids; self.manufacturerId = manufacturerId
        self.manufacturerDataHex = manufacturerDataHex; self.rawHex = rawHex; self.extras = extras
        self.firstSeen = firstSeen; self.lastSeen = lastSeen; self.hitCount = hitCount; self.fleetIds = fleetIds.distinct()
        self.rssiHistory = rssiHistory; self.presence = presence; self.latitude = latitude
        self.longitude = longitude; self.gone = gone; self.vendorIeOuis = vendorIeOuis; self.facts = facts
        self.gpsTrail = gpsTrail; self.fastPairPairing = fastPairPairing; self.payloadLat = payloadLat
        self.payloadLon = payloadLon; self.payloadAlt = payloadAlt; self.payloadOpLat = payloadOpLat
        self.payloadOpLon = payloadOpLon; self.payloadUasId = payloadUasId; self.payloadAircraft = payloadAircraft
        self.payloadSelfId = payloadSelfId; self.payloadHeading = payloadHeading; self.payloadSpeed = payloadSpeed
        self.payloadVspeed = payloadVspeed; self.payloadTrail = payloadTrail; self.liveDecode = liveDecode
    }

    public var displayName: String { name.ifBlank(hiddenSsid ? "<hidden>" : mac) }

    /// Custom name from Named radios, else advertised / hidden / MAC.
    public func reportName(customNames: [String: String]) -> String {
        if let custom = customNames[key]?.trim(), custom.isNotEmpty { return custom }
        return displayName
    }

    /// Live first-line title. Advertised name, else vendor · type guess, else unnamed LE.
    public func listTitle(signatureNames: [String] = []) -> String {
        let advertised = name.trim()
        if advertised.isNotEmpty && !advertised.equals(mac, ignoreCase: true) { return advertised }
        if kind == .wifi { return hiddenSsid ? "<hidden>" : mac }
        return DeviceExplain.listLabel(device: self, signatureNames: signatureNames) ?? "unnamed LE"
    }

    /// SSID or BLE local name; placeholders if blank.
    public func advertisedName() -> String {
        let advertised = name.trim()
        if advertised.isNotEmpty && !advertised.equals(mac, ignoreCase: true) { return advertised }
        if kind == .wifi { return hiddenSsid ? "<hidden>" : mac }
        return "unnamed LE"
    }

    public func listLineText(line: ListLine, signatureNames: [String] = [], watchName: String? = nil) -> String {
        let custom = watchName?.trim().nonEmpty
        switch line {
        case .advertisedName: return custom ?? advertisedName()
        case .nameAndType: return custom ?? listTitle(signatureNames: signatureNames)
        case .mac: return mac
        case ListLine.none: return ""
        }
    }

    public func radioKindTag() -> String { kind == .wifi ? "AP" : "LE" }

    public func statusCrumbs() -> String {
        var s = ""
        if randomized { s += "rand" }
        if fastPairPairing { if s.isNotEmpty { s += "  " }; s += "pair" }
        if gone { if s.isNotEmpty { s += "  " }; s += "gone" }
        return s
    }

    /// First three octets ("AA:BB:CC"). Empty for macOS BLE peripheral ids.
    public var oui: String { MacUtil.isOpaqueId(mac) ? "" : mac.take(8) }

    public func averageRssi(windowMs: Int, now: Int = nowMs(), floor: Int = -100) -> Double {
        let from = now - windowMs
        let heard = rssiHistory.filter { $0.at >= from && Rssi.measured(rssi: $0.rssi) }
        if heard.isNotEmpty { return heard.map { $0.rssi }.average() }
        return Double(Rssi.measured(rssi: rssi) ? rssi : floor)
    }

    public func rssiTrend(count: Int = 12) -> RssiTrend {
        let samples = rssiHistory.filter { Rssi.measured(rssi: $0.rssi) }.takeLast(count.coerceAtLeast(4))
        if samples.count < 4 { return .unknown }
        let mid = samples.count / 2
        let older = samples.take(mid).map { $0.rssi }.average()
        let newer = samples.drop(mid).map { $0.rssi }.average()
        let delta = newer - older
        if delta >= 8.0 { return .upFast }
        if delta >= 3.0 { return .up }
        if delta <= -8.0 { return .downFast }
        if delta <= -3.0 { return .down }
        return .flat
    }

    public func heardRssi(sort: StrengthSort, windowMs: Int, now: Int = nowMs()) -> Double {
        sort == .average ? averageRssi(windowMs: windowMs, now: now) : Double(rssi)
    }

    public func sortRssi(sort: StrengthSort, windowMs: Int, now: Int = nowMs()) -> Double {
        heardRssi(sort: sort, windowMs: windowMs, now: now)
    }
}

public struct RadioObservation: Hashable, Sendable {
    public var kind: RadioKind
    public var mac: String
    public var name: String
    public var rssi: Int
    public var channel: Int
    public var frequencyMhz: Int
    public var hiddenSsid: Bool
    public var serviceUuids: [String]
    public var manufacturerId: Int?
    public var manufacturerDataHex: String
    public var rawHex: String
    public var extras: String
    public var at: Int
    public var latitude: Double?
    public var longitude: Double?
    public var fresh: Bool
    public var vendorIeOuis: [String]
    public var facts: RadioFacts

    public init(
        kind: RadioKind, mac: String, name: String, rssi: Int, channel: Int, frequencyMhz: Int, hiddenSsid: Bool,
        serviceUuids: [String], manufacturerId: Int?, manufacturerDataHex: String, rawHex: String, extras: String,
        at: Int, latitude: Double? = nil, longitude: Double? = nil, fresh: Bool = true, vendorIeOuis: [String] = [],
        facts: RadioFacts = .Empty
    ) {
        self.kind = kind; self.mac = mac; self.name = name; self.rssi = rssi; self.channel = channel
        self.frequencyMhz = frequencyMhz; self.hiddenSsid = hiddenSsid; self.serviceUuids = serviceUuids
        self.manufacturerId = manufacturerId; self.manufacturerDataHex = manufacturerDataHex; self.rawHex = rawHex
        self.extras = extras; self.at = at; self.latitude = latitude; self.longitude = longitude; self.fresh = fresh
        self.vendorIeOuis = vendorIeOuis; self.facts = facts
    }
}

public struct ScanStats: Hashable, Sendable {
    public var wifiFrames = 0
    public var bleAdvs = 0
    public var devicesSeen = 0
    public var namedNow = 0
    public var wifiNow = 0
    public var bleNow = 0
    public var logLines = 0
    public var scanning = false
    public var lastWifiScanAt = 0
    public var throttleHint = ""
    public var wifiRadioOn = false
    public var wifiWaitingOnOs = false
    public var bleRadioOn = false
    public var bleRunning = false
    public var bleParked = false
    public var bleRetrying = false
    public var bleStarting = false
    public var bleHitsLastMin = 0
    public init() {}
}

public enum MacUtil {
    /// macOS CoreBluetooth hides BLE MAC addresses. Those radios are keyed by a per-Mac peripheral UUID
    /// (8-4-4-4-12). Such ids have no OUI, no vendor, and are treated as rotating.
    public static func isOpaqueId(_ s: String) -> Bool {
        s.count == 36 && s.charAt(8) == "-" && s.charAt(13) == "-" && UUID(uuidString: s) != nil
    }

    public static func normalize(raw: String) -> String {
        if isOpaqueId(raw) { return raw.uppercased() }
        let hex = raw.filterAlnum().uppercased()
        if hex.count < 2 { return raw.uppercased() }
        return hex.chunked(2).joined(separator: ":")
    }

    public static func prefixBytes(mac: String, n: Int = 3) -> String {
        if isOpaqueId(mac) { return "" }
        let parts = normalize(raw: mac).split(":")
        return parts.take(n.coerceAtMost(parts.count)).joined(separator: ":")
    }

    public static func isRandomized(mac: String) -> Bool {
        if isOpaqueId(mac) { return true }
        guard let first = normalize(raw: mac).substringBefore(":").toIntOrNull(16) else { return false }
        return (first & 0x02) != 0 && (first & 0x01) == 0
    }

    /// Local bit of the first octet.
    public static func isLocallyAdministered(mac: String) -> Bool {
        if isOpaqueId(mac) { return true }
        guard let first = normalize(raw: mac).substringBefore(":").toIntOrNull(16) else { return false }
        return (first & 0x02) != 0
    }

    /// 24-bit OUI with the locally-administered bit cleared. Nil if universal, multicast, short, or opaque.
    public static func wifiOui24Universal(mac: String) -> String? {
        if isOpaqueId(mac) { return nil }
        let hex = normalize(raw: mac).replace(":", "")
        if hex.count < 6 { return nil }
        guard let first = hex.substring(0, 2).toIntOrNull(16) else { return nil }
        if (first & 0x02) == 0 { return nil }
        if (first & 0x01) != 0 { return nil }
        return hex2(first & 0xFD) + hex.substring(2, 6)
    }

    public static func matchesPrefix(mac: String, prefix: String) -> Bool {
        if isOpaqueId(mac) { return false }
        let m = normalize(raw: mac).replace(":", "")
        let p = prefix.filterAlnum().uppercased()
        if p.isEmpty { return false }
        return m.hasPrefix(p)
    }

    public static func last16(mac: String) -> Int {
        if isOpaqueId(mac) { return 0 }
        let hex = normalize(raw: mac).replace(":", "")
        if hex.count < 4 { return 0 }
        return hex.takeLast(4).toIntOrNull(16) ?? 0
    }

    /// Last three octets as **:**:**. Opaque ids keep the first group only.
    public static func screenMac(mac: String, demo: Bool) -> String {
        if !demo || mac.isBlank { return mac }
        if isOpaqueId(mac) { return mac.take(8) + "-****-****-****-************" }
        let parts = normalize(raw: mac).split(":").filter { $0.isNotEmpty }
        if parts.count < 4 { return mac }
        let keep = parts.count - 3
        return parts.take(keep).joined(separator: ":") + ":**:**:**"
    }

    public static func redactMacIn(text: String, mac: String, demo: Bool) -> String {
        if !demo || text.isEmpty || mac.isBlank { return text }
        let masked = screenMac(mac: mac, demo: true)
        let n = normalize(raw: mac)
        var out = text
        if out.contains(mac, ignoreCase: true) { out = out.replace(mac, masked, ignoreCase: true) }
        if n != mac && out.contains(n, ignoreCase: true) { out = out.replace(n, masked, ignoreCase: true) }
        if !isOpaqueId(mac) {
            let compact = n.replace(":", "")
            if compact.count >= 12 {
                out = out.replace(compact, masked.replace(":", ""), ignoreCase: true)
            }
        }
        return out
    }

    public static func redactMacsIn(text: String, macs: [String], demo: Bool) -> String {
        if !demo || text.isEmpty { return text }
        var out = text
        for mac in macs.distinct() where mac.isNotBlank { out = redactMacIn(text: out, mac: mac, demo: true) }
        return out
    }

    /// Replace each known identifier with "masked". Whole token only, longest first.
    public static func redactTokensIn(text: String, tokens: [String]) -> String {
        if text.isEmpty { return text }
        let ids = tokens.map { $0.trim() }.filter { $0.count >= 4 }.distinct().sortedByDescending { $0.count }
        if ids.isEmpty { return text }
        var out = text
        for id in ids {
            let re = KRegex("(?<![A-Za-z0-9])\(KRegex.escape(id))(?![A-Za-z0-9])", ignoreCase: true)
            out = re.replace(out, "masked")
        }
        return out
    }

    /// Privacy-mode report text. MAC tails, known UAS ids, then coordinates.
    public static func redactPrivateText(text: String, macs: [String], uasIds: [String], demo: Bool) -> String {
        if !demo || text.isEmpty { return text }
        return Geo.redactCoordsIn(text: redactTokensIn(text: redactMacsIn(text: text, macs: macs, demo: true), tokens: uasIds), demo: true)
    }
}

public enum TextMatch {
    public static func contains(hay: String, needle: String) -> Bool {
        if needle.isBlank { return false }
        return hay.contains(needle, ignoreCase: true)
    }

    public static func glob(text: String, pattern: String) -> Bool {
        if pattern.isBlank { return false }
        var regex = "^"
        for ch in pattern {
            switch ch {
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += KRegex.escape(String(ch))
            }
        }
        regex += "$"
        return KRegex(regex, ignoreCase: true).matches(text)
    }
}

public enum Palette {
    /// ARGB ints, same as Android.
    public static let fleet: [Int] = [
        0xFF3DFF9A, 0xFFFFB020, 0xFFFF3D5A, 0xFF4FC3F7, 0xFFB388FF, 0xFFFF8A4C, 0xFFE8EEF2, 0xFF3D8B6E, 0xFF5BA3D9,
    ]

    public static func color(index: Int) -> Int { fleet[index.mod(fleet.count)] }
}

public func uuidShortOrFull(raw: String) -> String {
    let hex = raw.filterAlnum().uppercased()
    return hex.count == 4 ? "0000\(hex)-0000-1000-8000-00805F9B34FB" : raw.uppercased()
}

public func uuidAliases(raw: String) -> Set<String> {
    let hex = raw.filterAlnum().uppercased()
    var out: Set<String> = [raw.uppercased(), hex]
    if hex.count == 4 {
        out.insert("0x\(hex)")
        out.insert("0000\(hex)-0000-1000-8000-00805F9B34FB")
        out.insert("0000\(hex)00001000800000805F9B34FB")
        return out
    }
    // 16-bit alias only for Bluetooth SIG base UUIDs.
    if hex.count == 32 && hex.hasPrefix("0000") && hex.hasSuffix("00001000800000805F9B34FB") {
        let short = hex.substring(4, 8)
        out.insert(short)
        out.insert("0x\(short)")
        out.insert("0000\(short)-0000-1000-8000-00805F9B34FB")
    }
    return out
}

// MARK: - Shared enums owned by TakPublish.kt / GnssInterference.kt (declared here because AppSettings needs them)

/// ATAK CIV CoT input is the default port. SA multicast is 239.2.3.1:6969. UDP only.
public enum TakDefaults {
    public static let HOST = "239.2.3.1"
    public static let PORT = 10011
    public static let LOOPBACK = "127.0.0.1"
    public static let SA_HOST = "239.2.3.1"
    public static let SA_PORT = 6969
    public static let MIN_INTERVAL_MS = 10_000
    public static let MOVE_M = 30.0
    public static let STALE_MS = 120_000
    public static let MAX_PER_TICK = 24
    public static let REMARKS_MAX = 800
}

/// When a GNSS hit is written onto this phone's TAK marker.
public enum TakGnssSend: String, Codable, CaseIterable, Sendable {
    case off = "OFF", alert = "ALERT", redLine = "RED_LINE", any = "ANY"

    public func label() -> String {
        switch self {
        case .off: return "Off"
        case .alert: return "While alerting"
        case .redLine: return "Red line"
        case .any: return "Any hit"
        }
    }
}

/// How long a map mark stays after its last update.
public enum TakGnssHold: String, Codable, CaseIterable, Sendable {
    case hour = "HOUR", hours6 = "HOURS_6", hours24 = "HOURS_24", untilDeleted = "UNTIL_DELETED"

    public func label() -> String {
        switch self {
        case .hour: return "1 hour"
        case .hours6: return "6 hours"
        case .hours24: return "24 hours"
        case .untilDeleted: return "Until deleted"
        }
    }

    public func staleMs() -> Int {
        switch self {
        case .hour: return 3_600_000
        case .hours6: return 6 * 3_600_000
        case .hours24: return 24 * 3_600_000
        case .untilDeleted: return 10 * 365 * 24 * 3_600_000
        }
    }
}

/// When a flood line is written onto this phone's TAK marker. Reads legacy "RED_LINE" as on.
public enum TakFloodSend: String, Codable, CaseIterable, Sendable {
    case off = "OFF", on = "ON"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "OFF": self = .off
        case "ON", "RED_LINE": self = .on
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown TAK flood choice: \(raw)"))
        }
    }

    public func label() -> String { self == .off ? "Off" : "On" }
}

/// Reads legacy LESS / NORMAL / MORE.
public enum GnssSensitivity: String, Codable, CaseIterable, Sendable {
    case low = "LOW", medium = "MEDIUM", high = "HIGH"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "LOW", "LESS": self = .low
        case "MEDIUM", "NORMAL": self = .medium
        case "HIGH", "MORE": self = .high
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown GNSS sensitivity: \(raw)"))
        }
    }

    public func label() -> String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

public enum GnssAlertFloor: String, Codable, CaseIterable, Sendable {
    case low = "LOW", medium = "MEDIUM", high = "HIGH"

    public func label() -> String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}
