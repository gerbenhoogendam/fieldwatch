import Foundation
import Testing
@testable import FieldwatchCore

struct AdvPayloadDecoderTest {
    private func bleSighting(_ mfgHex: String) -> Sighting {
        Sighting(
            key: "BLE:AA:BB:CC:DD:EE:99", kind: .ble, mac: "AA:BB:CC:DD:EE:99", name: "",
            rssi: -50, rssiMin: -50, rssiMax: -50, channel: 0, frequencyMhz: 0, vendor: nil,
            randomized: false, hiddenSsid: false, serviceUuids: [], manufacturerId: 0x004C,
            manufacturerDataHex: mfgHex, rawHex: "", extras: "", firstSeen: 1, lastSeen: 1, hitCount: 1,
            fleetIds: [], rssiHistory: [], presence: [],
            facts: RadioFacts(mfgRecords: [MfgRecord(companyId: 0x004C, dataHex: mfgHex)])
        )
    }

    private func byLabel(_ fields: [AdvPayloadDecoder.Field]) -> [String: String] {
        var out: [String: String] = [:]
        for f in fields { out[f.label] = f.value }
        return out
    }

    @Test func appleIBeaconDecodesUuidMajorMinorTx() {
        // TLV 02/15 + 16-byte UUID + major + minor + calibrated TX.
        let mfg = "0215" + "E2C56DB5DFFB48D2B060D0F5A71096E0" + "0001" + "0002" + "C5"
        let m = byLabel(AdvPayloadDecoder.decodeManufacturer(record: MfgRecord(companyId: 0x004C, dataHex: mfg)))
        #expect(m["Apple Continuity type"] == "0x02 · iBeacon")
        #expect(m["iBeacon UUID"] == "e2c56db5-dffb-48d2-b060-d0f5a71096e0")
        #expect(m["iBeacon major / minor"] == "1 / 2")
        #expect(m["iBeacon calibrated TX"]?.hasPrefix("-59") == true)
    }

    @Test func appleProximityPairingNamesAirPods() {
        // TLV 07, prefix 01, model 0F20 (AirPods 2nd gen), status 51, batt 98, case byte 11.
        let mfg = "07" + "07" + "010F2051" + "98" + "11" + "00"
        let m = byLabel(AdvPayloadDecoder.decodeManufacturer(record: MfgRecord(companyId: 0x004C, dataHex: mfg)))
        #expect(m["Product"] == "AirPods (2nd generation)")
        #expect(m["Battery (left / right)"] == "80% / 90%")
        #expect(m["Case battery"] == "10%")
        #expect(m["Charging"] == "case")
    }

    @Test func appleFindMyLabelsOfflineFinding() {
        let mfg = "12" + "0A" + String(repeating: "00", count: 10)
        let fields = AdvPayloadDecoder.decodeManufacturer(record: MfgRecord(companyId: 0x004C, dataHex: mfg))
        #expect(fields.contains { $0.label == "Find My / Offline Finding" })
    }

    @Test func unknownCompanyYieldsNoFields() {
        #expect(AdvPayloadDecoder.decodeManufacturer(record: MfgRecord(companyId: 0x9999, dataHex: "AABB")).isEmpty)
        #expect(AdvPayloadDecoder.decodeManufacturer(record: MfgRecord(companyId: 0x004C, dataHex: "XYZ")).isEmpty)
    }

    @Test func fastPairThreeByteModelIdIsPairing() {
        let m = byLabel(AdvPayloadDecoder.decodeService(record: ServiceDataRecord(uuid: "FE2C", dataHex: "000006")))
        #expect(m["Google Fast Pair"]?.contains("pairing mode") == true)
        #expect(m["Model ID"] == "Google Pixel Buds  (0x000006)")
    }

    @Test func fastPairLongerPayloadIsAccountKeyBloom() {
        let fields = AdvPayloadDecoder.decodeService(record: ServiceDataRecord(uuid: "FE2C", dataHex: "01020304050607"))
        #expect(fields.count == 1)
        #expect(fields.first?.value.contains("Already paired") == true)
    }

    @Test func eddystoneUidSplitsNamespaceAndInstance() {
        let bytes = "00" + "C5" + "00112233445566778899" + "AABBCCDDEEFF" + "0000"
        let m = byLabel(AdvPayloadDecoder.decodeService(record: ServiceDataRecord(uuid: "FEAA", dataHex: bytes)))
        #expect(m["Eddystone-UID namespace"] == "00112233445566778899")
        #expect(m["Eddystone-UID instance"] == "AABBCCDDEEFF")
    }

    @Test func findHubFrameIsNotEddystone() {
        let eid = String(repeating: "11", count: 20)
        let fields = AdvPayloadDecoder.decodeService(record: ServiceDataRecord(uuid: "FEAA", dataHex: "41\(eid)" + "00"))
        #expect(fields.first { $0.label == "Find Hub" }?.value == "separated (unwanted-tracking mode)")
        #expect(!fields.contains { $0.label.hasPrefix("Eddystone") })
    }

    @Test func eddystoneUrlExpandsSchemeAndSuffix() {
        // frame 10, tx C5, scheme 01 (https://www.), "example", 07 (.com)
        let bytes = "10" + "C5" + "01" + Array("example".utf8).toHexUpper() + "07"
        let fields = AdvPayloadDecoder.decodeService(record: ServiceDataRecord(uuid: "FEAA", dataHex: bytes))
        #expect(fields.count == 1)
        #expect(fields.first?.value == "https://www.example.com")
    }

    @Test func microsoftCdpNamesDeviceType() {
        let fields = AdvPayloadDecoder.decodeManufacturer(record: MfgRecord(companyId: 0x0006, dataHex: "0109"))
        #expect(fields.count == 1)
        #expect(fields.first?.value.contains("Windows desktop") == true)
    }

    @Test func roleHintsFlagIBeaconAndTeslaKey() {
        let ibeacon = "0215" + "E2C56DB5DFFB48D2B060D0F5A71096E0" + "00010002" + "C5"
        let hints = AdvPayloadDecoder.roleHints(device: bleSighting(ibeacon))
        #expect(hints.contains { $0.label == "an iBeacon" })

        // Tesla prefix carries the "0215" TLV header; the body still needs
        // major/minor/tx (5 bytes) to reach the declared iBeacon length.
        let tesla = bleSighting(DefaultCatalog.TESLA_IBEACON_MFG_PREFIX + "00010002C5")
        #expect(AdvPayloadDecoder.roleHints(device: tesla).contains { $0.label.contains("Tesla") })
    }
}
