import Foundation
import Testing
@testable import FieldwatchCore

// Port of StockCatalogFileTest.kt. The Android dist/fieldwatch-signatures-v2.json is bundled as a
// FieldwatchCore resource (SignatureExchange.stockPackURL()). Not ported: the WRITE_STOCK_CATALOG
// regenerate switch, and legacyPackStaysOnCatalog77 (the legacy v1 pack is not bundled on macOS).

@Suite struct StockCatalogFileTest {
    @Test func distPackMatchesDefaultCatalog() throws {
        let pack = try SignatureExchange.parse(text: distPackText())
        #expect(pack.format == "fieldwatch-signatures")
        #expect(pack.catalogVersion == ConfigStore.CATALOG_VERSION)
        let stock = DefaultCatalog.fleets().associateBy { $0.id }
        #expect(Set(stock.keys) == Set(pack.fleets.map { $0.id }))
        for row in pack.fleets {
            let expect = try #require(stock[row.id], "\(row.id)")
            #expect(row.name == expect.name, "\(row.id)")
            #expect(row.kind == expect.kind, "\(row.id)")
            #expect(row.attentionNote == expect.attentionNote, "\(row.id)")
            #expect(row.notes == expect.notes, "\(row.id)")
            #expect(row.matchAny == expect.matchAny, "\(row.id)")
            #expect(row.builtIn, "\(row.id)")
        }
        let ray = try fleet(pack, "fleet-rayneo")
        #expect(!ray.matchAny)
        #expect(try only(ray.rules.filter { $0.kind == .manufacturerId }).companyId == 0x0BC6)
        #expect(try only(ray.rules.filter { $0.kind == .nameGlob }).text == "RayNeo*")
        #expect(ray.rules.count == 2)
        let even = try fleet(pack, "fleet-even-g1")
        #expect(even.rules.contains { $0.kind == .manufacturerId && $0.companyId == 0x10F9 })
        let lite = try fleet(pack, "fleet-liteon-camera-radio")
        let ouis = Set(lite.rules.filter { $0.kind == .oui }.map { $0.text.uppercased() })
        #expect(ouis.contains("E0:0A:F6"))
        #expect(ouis.contains("14:B5:CD"))
        #expect(ouis.contains("F8:A2:D6"))
        #expect(!ouis.contains("48:27:EA"))
        #expect(!ouis.contains("82:6B:F2"))
        #expect(lite.attentionNote.isBlank)
        let meta = try fleet(pack, "fleet-meta-glasses")
        #expect(meta.rules.contains { $0.kind == .nameGlob && $0.text == "Meta RB Display*" })
        #expect(!meta.rules.contains { $0.text.equals("FD5F", ignoreCase: true) })
        #expect(try fleet(pack, "fleet-axon").notes.contains("fixed ALPR"))
        let remote = try fleet(pack, "fleet-remote-id")
        #expect(remote.rules.contains { $0.kind == .vendorIeOui && $0.text.equals("6A:5C:35", ignoreCase: true) })
        #expect(remote.rules.contains { $0.kind == .vendorIeOui && $0.text.equals("FA:0B:BC", ignoreCase: true) })
        let tello = try fleet(pack, "fleet-tello")
        #expect(Set(tello.rules.map { $0.text }) == ["TELLO*", "RMTT*"])
        let crazy = try fleet(pack, "fleet-crazyflie")
        #expect(!crazy.rules.contains { $0.kind == .manufacturerId })
        #expect(try fleet(pack, "fleet-parrot").rules.contains { $0.kind == .nameGlob && $0.text == "Skycontroller*" })
    }

    @Test func remoteIdPinFieldsMatchWhenLiveKeysAreDropped() throws {
        let raw = try distPackText()
        let full = try fleet(try SignatureExchange.parse(text: raw), "fleet-remote-id")
        let older = try fleet(try SignatureExchange.parse(text: dropLiveKeys(raw)), "fleet-remote-id")
        let fullFields = try #require(full.decode).fields.map { f -> DecodeField in
            var c = f
            c.live = false
            c.liveEmphasis = []
            c.enumNotes = nil
            return c
        }
        let olderDecode = try #require(older.decode)
        #expect(fullFields == olderDecode.fields)
        let location = "0D0012200000000084D717007FE4D3000098083408000000000000"
        let ble = ridBle(location)
        let pinned = PayloadLocation.applySticky(device: with(ble) { $0.fleetIds = [full.id] }, fleets: [full])
        try near(pinned.payloadLat, 40.0)
        try near(pinned.payloadLon, -74.0)
        try near(pinned.payloadHeading, 0.0)
        try near(pinned.payloadSpeed, 0.0)
        let fullRows = SignatureFieldDecoder.decodeSighting(device: with(ble) { $0.fleetIds = [full.id] }, fleets: [full])
        let oldRows = SignatureFieldDecoder.decodeSighting(device: with(ble) { $0.fleetIds = [older.id] }, fleets: [older])
        for id in ["latitude", "longitude", "heading", "hspeed", "alt_geo", "status"] {
            #expect(try row(fullRows, id).display == row(oldRows, id).display, "\(id)")
            #expect(try row(fullRows, id).number == row(oldRows, id).number, "\(id)")
        }
        let pack = "D9F2190302123135383146335954444A3144303033315A353330000000" +
            "1220820A00864228110CFF80CF0000F508B2083A022E310A00" +
            "420176E42711B5FF81CF010000000000000005088B02900E00"
        let wifiPin = PayloadLocation.applySticky(device: with(ridWifi(pack)) { $0.fleetIds = [full.id] }, fleets: [full])
        #expect(wifiPin.payloadUasId == "1581F3YTDJ1D0031Z530")
        try near(wifiPin.payloadLat, 28.7851142)
        try near(wifiPin.payloadLon, -81.3629684)
        try near(wifiPin.payloadHeading, 130.0)
        try near(wifiPin.payloadSpeed, 2.5)
        try near(wifiPin.payloadOpLat, 28.7827062)
        try near(wifiPin.payloadOpLon, -81.3563979)
    }

    // MARK: - Helpers

    private func distPackText() throws -> String {
        let url = try #require(SignatureExchange.stockPackURL(), "Missing bundled fieldwatch-signatures-v2.json")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func fleet(_ pack: SignaturePack, _ id: String) throws -> Fleet {
        try only(pack.fleets.filter { $0.id == id })
    }

    private func row(_ rows: [DecodedFieldValue], _ id: String) throws -> DecodedFieldValue {
        try #require(rows.first { $0.id == id }, "no decoded row \(id)")
    }

    private func near(_ value: Double?, _ expected: Double, _ eps: Double = 1e-6) throws {
        let v = try #require(value)
        #expect(abs(v - expected) <= eps, "\(v) vs \(expected)")
    }

    private func only<T>(_ items: [T]) throws -> T {
        try #require(items.count == 1, "expected one element, got \(items.count)")
        return items[0]
    }

    private func with<T>(_ value: T, _ change: (inout T) -> Void) -> T {
        var copy = value
        change(&copy)
        return copy
    }

    /// Re-serialize the pack without `live`, `liveEmphasis` and `enumNotes` (an older pack shape).
    private func dropLiveKeys(_ raw: String) throws -> String {
        func strip(_ el: Any) -> Any {
            if let obj = el as? [String: Any] {
                var out: [String: Any] = [:]
                for (k, v) in obj where k != "live" && k != "liveEmphasis" && k != "enumNotes" { out[k] = strip(v) }
                return out
            }
            if let arr = el as? [Any] { return arr.map(strip) }
            return el
        }
        let parsed = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])
        let data = try JSONSerialization.data(withJSONObject: strip(parsed), options: [])
        return String(decoding: data, as: UTF8.self)
    }

    private func ridBle(_ dataHex: String) -> Sighting {
        Sighting(
            key: "BLE:AA:BB:CC:DD:EE:01", kind: .ble, mac: "AA:BB:CC:DD:EE:01", name: "",
            rssi: -50, rssiMin: -50, rssiMax: -50, channel: 0, frequencyMhz: 2402, vendor: nil,
            randomized: true, hiddenSsid: false, serviceUuids: ["FFFA"], manufacturerId: nil, manufacturerDataHex: "",
            rawHex: "", extras: "", firstSeen: 1, lastSeen: 1, hitCount: 1, fleetIds: ["fleet-remote-id"],
            rssiHistory: [], presence: [],
            facts: RadioFacts(serviceData: [ServiceDataRecord(uuid: "FFFA", dataHex: dataHex)])
        )
    }

    private func ridWifi(_ dataHex: String) -> Sighting {
        Sighting(
            key: "WIFI:60:60:1F:06:31:08", kind: .wifi, mac: "60:60:1F:06:31:08", name: "RID",
            rssi: -80, rssiMin: -80, rssiMax: -80, channel: 6, frequencyMhz: 2437, vendor: nil,
            randomized: false, hiddenSsid: false, serviceUuids: [], manufacturerId: nil, manufacturerDataHex: "",
            rawHex: "", extras: "", firstSeen: 1, lastSeen: 1, hitCount: 1, fleetIds: ["fleet-remote-id"],
            rssiHistory: [], presence: [],
            facts: RadioFacts(vendorIes: [VendorIeRecord(oui: "FA:0B:BC", type: 0x0D, dataHex: dataHex)])
        )
    }
}
