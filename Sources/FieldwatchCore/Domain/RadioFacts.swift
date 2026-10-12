import Foundation

// Port of domain/RadioFacts.kt.

public struct MfgRecord: Hashable, Sendable {
    public var companyId: Int
    public var dataHex: String
    public init(companyId: Int, dataHex: String) { self.companyId = companyId; self.dataHex = dataHex }
}

public struct VendorIeRecord: Hashable, Sendable {
    public var oui: String
    public var type: Int
    public var dataHex: String
    public init(oui: String, type: Int, dataHex: String) { self.oui = oui; self.type = type; self.dataHex = dataHex }
}

public struct ServiceDataRecord: Hashable, Sendable {
    public var uuid: String
    public var dataHex: String
    public init(uuid: String, dataHex: String) { self.uuid = uuid; self.dataHex = dataHex }
}

public struct RadioFacts: Hashable, Sendable {
    public var txPowerDbm: Int?
    public var advFlags: Int?
    public var appearance: Int?
    public var addressType: String?
    public var advertisingIntervalMs: Double?
    public var periodicIntervalMs: Double?
    public var connectable: Bool?
    public var primaryPhy: String?
    public var secondaryPhy: String?
    public var deviceClass: Int?
    public var wifiStandard: String?
    public var channelWidth: String?
    public var centerFreq0: Int?
    public var centerFreq1: Int?
    public var capabilities: String?
    public var supportedRates: String?
    public var security: String?
    public var mfgRecords: [MfgRecord]
    public var vendorIes: [VendorIeRecord]
    public var serviceData: [ServiceDataRecord]

    public init(
        txPowerDbm: Int? = nil, advFlags: Int? = nil, appearance: Int? = nil, addressType: String? = nil,
        advertisingIntervalMs: Double? = nil, periodicIntervalMs: Double? = nil, connectable: Bool? = nil,
        primaryPhy: String? = nil, secondaryPhy: String? = nil, deviceClass: Int? = nil,
        wifiStandard: String? = nil, channelWidth: String? = nil, centerFreq0: Int? = nil, centerFreq1: Int? = nil,
        capabilities: String? = nil, supportedRates: String? = nil, security: String? = nil,
        mfgRecords: [MfgRecord] = [], vendorIes: [VendorIeRecord] = [], serviceData: [ServiceDataRecord] = []
    ) {
        self.txPowerDbm = txPowerDbm; self.advFlags = advFlags; self.appearance = appearance
        self.addressType = addressType; self.advertisingIntervalMs = advertisingIntervalMs
        self.periodicIntervalMs = periodicIntervalMs; self.connectable = connectable; self.primaryPhy = primaryPhy
        self.secondaryPhy = secondaryPhy; self.deviceClass = deviceClass; self.wifiStandard = wifiStandard
        self.channelWidth = channelWidth; self.centerFreq0 = centerFreq0; self.centerFreq1 = centerFreq1
        self.capabilities = capabilities; self.supportedRates = supportedRates; self.security = security
        self.mfgRecords = mfgRecords; self.vendorIes = vendorIes; self.serviceData = serviceData
    }

    public static let Empty = RadioFacts()

    public func merge(newer: RadioFacts) -> RadioFacts {
        var c = self
        c.txPowerDbm = newer.txPowerDbm ?? txPowerDbm
        c.advFlags = newer.advFlags ?? advFlags
        c.appearance = newer.appearance ?? appearance
        c.addressType = newer.addressType ?? addressType
        c.advertisingIntervalMs = newer.advertisingIntervalMs ?? advertisingIntervalMs
        c.periodicIntervalMs = newer.periodicIntervalMs ?? periodicIntervalMs
        // Scan responses report not connectable; keep Yes once any ad was.
        c.connectable = (connectable == true || newer.connectable == true) ? true : (newer.connectable ?? connectable)
        c.primaryPhy = newer.primaryPhy ?? primaryPhy
        c.secondaryPhy = newer.secondaryPhy ?? secondaryPhy
        c.deviceClass = newer.deviceClass ?? deviceClass
        c.wifiStandard = newer.wifiStandard ?? wifiStandard
        c.channelWidth = newer.channelWidth ?? channelWidth
        c.centerFreq0 = newer.centerFreq0 ?? centerFreq0
        c.centerFreq1 = newer.centerFreq1 ?? centerFreq1
        c.capabilities = newer.capabilities?.nonBlank ?? capabilities
        c.supportedRates = newer.supportedRates?.nonBlank ?? supportedRates
        c.security = newer.security?.nonBlank ?? security
        c.mfgRecords = mergeMfg(mfgRecords, newer.mfgRecords)
        c.vendorIes = mergeVendorIes(vendorIes, newer.vendorIes)
        c.serviceData = mergeServiceData(serviceData, newer.serviceData)
        return c
    }
}

private func mergeMfg(_ old: [MfgRecord], _ extra: [MfgRecord]) -> [MfgRecord] {
    if extra.isEmpty { return old }
    if old.isEmpty { return extra }
    var out = old
    for next in extra {
        let prefix = next.dataHex.take(2).uppercased()
        let idx = out.indexOfFirst { $0.companyId == next.companyId && $0.dataHex.take(2).uppercased() == prefix }
        if idx < 0 {
            out.append(next)
        } else if next.dataHex.count >= out[idx].dataHex.count {
            out[idx] = next
        }
    }
    return out.count <= 8 ? out : out.take(8)
}

private func mergeVendorIes(_ old: [VendorIeRecord], _ extra: [VendorIeRecord]) -> [VendorIeRecord] {
    if extra.isEmpty { return old }
    return (old + extra).distinctBy { "\($0.oui)|\($0.type)|\($0.dataHex.take(16))" }.take(12)
}

private func mergeServiceData(_ old: [ServiceDataRecord], _ extra: [ServiceDataRecord]) -> [ServiceDataRecord] {
    if extra.isEmpty { return old }
    var order: [String] = []
    var by: [String: ServiceDataRecord] = [:]
    func put(_ rec: ServiceDataRecord, replaceShorter: Bool) {
        let key = serviceDataMergeKey(rec)
        if let prev = by[key] {
            if !replaceShorter || rec.dataHex.count >= prev.dataHex.count { by[key] = rec }
        } else {
            order.append(key)
            by[key] = rec
        }
    }
    old.forEach { put($0, replaceShorter: false) }
    extra.forEach { put($0, replaceShorter: true) }
    return order.map { by[$0]! }
}

/// Eddystone FEAA rotates UID / URL / TLM; keep one slot per frame type.
private func serviceDataMergeKey(_ rec: ServiceDataRecord) -> String {
    let uuidHex = rec.uuid.filterAlnum().uppercased()
    let short: String
    if uuidHex.count == 4 { short = uuidHex }
    else if uuidHex.count == 32 && uuidHex.hasPrefix("0000") { short = uuidHex.substring(4, 8) }
    else { short = uuidHex }
    if short == "FEAA" {
        let frame = rec.dataHex.filterAlnum().uppercased().take(2)
        if frame.count == 2 { return "FEAA:\(frame)" }
    }
    return uuidHex.ifBlank(rec.uuid)
}
