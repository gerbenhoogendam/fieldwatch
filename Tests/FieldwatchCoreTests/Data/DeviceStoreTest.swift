import Foundation
import Testing
@testable import FieldwatchCore

// Port of test/java/app/fieldwatch/data/DeviceStoreTest.kt. No files touched.

@Suite struct DeviceStoreTest {
    private let fleets = DefaultCatalog.fleets()

    @Test func ciscoOuiLabelsOnIngestAndSurvivesRssiOnly() throws {
        let store = DeviceStore()
        let mac = "00:00:0C:11:22:33"
        store.ingestBatch(observations: [wifi(mac, name: "Campus", rssi: -60)], fleets: fleets, staleSec: 30)
        let first = try #require(store.find(key: "WIFI:\(mac)"))
        #expect(first.fleetIds.contains("fleet-cisco"), "Cisco OUI")

        store.ingestBatch(observations: [wifi(mac, name: "Campus", rssi: -42)], fleets: fleets, staleSec: 30)
        let again = try #require(store.find(key: "WIFI:\(mac)"))
        #expect(again.fleetIds.contains("fleet-cisco"), "RSSI-only keeps Cisco")
        #expect(again.rssi == -42)
    }

    @Test func unifiVirtualBssidLabelsWhenVendorIeArrives() throws {
        let store = DeviceStore()
        let mac = "82:F9:2C:00:00:01"
        store.ingestBatch(observations: [wifi(mac, name: "Deep Learning")], fleets: fleets, staleSec: 30)
        let before = try #require(store.find(key: "WIFI:\(mac)"))
        #expect(!before.fleetIds.contains("fleet-unifi-ap"), "no Ubiquiti OUI on randomized BSSID")

        store.ingestBatch(observations: [wifi(mac, name: "Deep Learning", rssi: -55)], fleets: fleets, staleSec: 30)
        #expect(!(try #require(store.find(key: "WIFI:\(mac)"))).fleetIds.contains("fleet-unifi-ap"), "RSSI-only does not invent UniFi")

        store.ingestBatch(
            observations: [wifi(mac, name: "Deep Learning", ies: ["00:50:F2", "00:0F:AC", "AC:8B:A9"])],
            fleets: fleets,
            staleSec: 30
        )
        #expect(
            (try #require(store.find(key: "WIFI:\(mac)"))).fleetIds.contains("fleet-unifi-ap"),
            "Ubiquiti vendor IE labels virtual BSS"
        )
    }

    @Test func nameAppearingLaterCanLabel() throws {
        let store = DeviceStore()
        let mac = "DE:AD:00:11:22:33"
        store.ingestBatch(observations: [wifi(mac, name: "")], fleets: fleets, staleSec: 30)
        #expect(!(try #require(store.find(key: "WIFI:\(mac)"))).fleetIds.contains("fleet-netgear"))

        store.ingestBatch(observations: [wifi(mac, name: "NETGEAR-12AB")], fleets: fleets, staleSec: 30)
        #expect((try #require(store.find(key: "WIFI:\(mac)"))).fleetIds.contains("fleet-netgear"))
    }

    @Test func bleCiscoOuiDoesNotTakeWifiSignature() throws {
        let store = DeviceStore()
        let mac = "00:00:0C:11:22:33"
        store.ingestBatch(observations: [ble(mac, name: "Campus")], fleets: fleets, staleSec: 30)
        #expect(!(try #require(store.find(key: "BLE:\(mac)"))).fleetIds.contains("fleet-cisco"))
    }

    @Test func fastPairPairingSticksAfterAccountKeyPayload() throws {
        let store = DeviceStore()
        let mac = "AA:BB:CC:DD:EE:01"
        store.ingestBatch(
            observations: [ble(mac, name: "", facts: RadioFacts(serviceData: [ServiceDataRecord(uuid: "FE2C", dataHex: "2A4139")]))],
            fleets: fleets,
            staleSec: 30
        )
        #expect((try #require(store.find(key: "BLE:\(mac)"))).fastPairPairing)
        store.ingestBatch(
            observations: [
                ble(mac, name: "", facts: RadioFacts(serviceData: [ServiceDataRecord(uuid: "FE2C", dataHex: "00112233445566778899AABBCCDDEEFF")])),
            ],
            fleets: fleets,
            staleSec: 30
        )
        let again = try #require(store.find(key: "BLE:\(mac)"))
        #expect(again.fastPairPairing, "pairing-mode stays this session")
        #expect(again.fleetIds.contains("fleet-fast-pair"))
    }

    @Test func remoteIdLocationSticksAfterBasicIdPacket() throws {
        let store = DeviceStore()
        let mac = "AA:BB:CC:DD:EE:02"
        let location = "0D0012200000000084D717007FE4D3000098083408000000000000"
        let basic = "0D000212" + "5445535453455249414C31323334353637383930" + "000000"
        store.ingestBatch(observations: [ble(mac, name: "", facts: ridFacts(location))], fleets: fleets, staleSec: 30)
        let first = try #require(store.find(key: "BLE:\(mac)"))
        #expect(first.fleetIds.contains("fleet-remote-id"))
        #expect(close(try #require(first.payloadLat), 40.0))
        #expect(close(try #require(first.payloadLon), -74.0))
        #expect(close(try #require(first.payloadAlt), 100.0))

        store.ingestBatch(observations: [ble(mac, name: "", facts: ridFacts(basic))], fleets: fleets, staleSec: 30)
        let again = try #require(store.find(key: "BLE:\(mac)"))
        #expect(again.fleetIds.contains("fleet-remote-id"))
        #expect(close(try #require(again.payloadLat), 40.0), "Basic ID packet keeps last Location pin")
        #expect(close(try #require(again.payloadLon), -74.0))
        #expect(close(try #require(again.payloadAlt), 100.0))
        #expect(again.payloadUasId == "TESTSERIAL1234567890")
        #expect(again.payloadAircraft == nil)
    }

    @Test func remoteIdUasIdSticksAfterLocationPacket() throws {
        let store = DeviceStore()
        let mac = "AA:BB:CC:DD:EE:03"
        let location = "0D0012200000000084D717007FE4D3000098083408000000000000"
        let basic = "0D000212" + "5445535453455249414C31323334353637383930" + "000000"
        store.ingestBatch(observations: [ble(mac, name: "", facts: ridFacts(basic))], fleets: fleets, staleSec: 30)
        let first = try #require(store.find(key: "BLE:\(mac)"))
        #expect(first.payloadUasId == "TESTSERIAL1234567890")
        store.ingestBatch(observations: [ble(mac, name: "", facts: ridFacts(location))], fleets: fleets, staleSec: 30)
        let again = try #require(store.find(key: "BLE:\(mac)"))
        #expect(again.payloadUasId == "TESTSERIAL1234567890", "Location packet keeps Basic ID")
        #expect(again.payloadAircraft == nil)
        #expect(close(try #require(again.payloadLat), 40.0))
        #expect(close(try #require(again.payloadLon), -74.0))
    }

    @Test func remoteIdSerialPrefixSticksAndClears() throws {
        let store = DeviceStore()
        let mac = "AA:BB:CC:DD:EE:12"
        let location = "0D0012200000000084D717007FE4D3000098083408000000000000"
        let basic = basicIdService(1, "18179132000209")
        store.ingestBatch(observations: [ble(mac, name: "", facts: ridFacts(basic))], fleets: fleets, staleSec: 30)
        let named = try #require(store.find(key: "BLE:\(mac)"))
        #expect(named.payloadUasId == "18179132000209")
        #expect(named.payloadAircraft == "Freefly Alta X Gen2")
        #expect(named.liveDecode.isEmpty)

        store.ingestBatch(observations: [ble(mac, name: "", facts: ridFacts(location))], fleets: fleets, staleSec: 30)
        let held = try #require(store.find(key: "BLE:\(mac)"))
        #expect(held.payloadAircraft == "Freefly Alta X Gen2")
        #expect(held.payloadUasId == "18179132000209")
        #expect(close(try #require(held.payloadLat), 40.0))
        #expect(close(try #require(held.payloadLon), -74.0))
        #expect(held.liveDecode.none { $0.text.contains("Freefly") })

        let session = basicIdService(4, "SESSIONID123456789")
        store.ingestBatch(observations: [ble(mac, name: "", facts: ridFacts(session))], fleets: fleets, staleSec: 30)
        let cleared = try #require(store.find(key: "BLE:\(mac)"))
        #expect(cleared.payloadUasId == "SESSIONID123456789")
        #expect(cleared.payloadAircraft == nil)
        #expect(close(try #require(cleared.payloadLat), 40.0))

        let caaMac = "AA:BB:CC:DD:EE:13"
        store.ingestBatch(observations: [ble(caaMac, name: "", facts: ridFacts(basicIdService(2, "18179132000209")))], fleets: fleets, staleSec: 30)
        let caa = try #require(store.find(key: "BLE:\(caaMac)"))
        #expect(caa.payloadUasId == "18179132000209")
        #expect(caa.payloadAircraft == nil)

        let dronetag = "AA:BB:CC:DD:EE:14"
        store.ingestBatch(observations: [ble(dronetag, name: "", facts: ridFacts(basicIdService(1, "1596F330000000000001")))], fleets: fleets, staleSec: 30)
        let module = try #require(store.find(key: "BLE:\(dronetag)"))
        #expect(module.payloadUasId == "1596F330000000000001")
        #expect(module.payloadAircraft == nil)

        let packMac = "AA:BB:CC:DD:EE:15"
        let pack = "0D00" + removePrefix(basicIdService(1, "1914CL2D230001"), "0D00") + removePrefix(location, "0D00")
        store.ingestBatch(observations: [ble(packMac, name: "", facts: ridFacts(pack))], fleets: fleets, staleSec: 30)
        let packed = try #require(store.find(key: "BLE:\(packMac)"))
        #expect(packed.payloadAircraft == "BRINC Lemur 2")
        #expect(close(try #require(packed.payloadLat), 40.0))
        #expect(packed.liveDecode.none { $0.text.contains("BRINC") })

        let tealMac = "AA:BB:CC:DD:EE:16"
        let teal = "00" + removePrefix(basicIdService(1, "1839FTD50200000001"), "0D00")
        var tealObs = wifi(tealMac, name: "RID-WIFI", ies: ["FA:0B:BC"])
        tealObs.facts = RadioFacts(vendorIes: [VendorIeRecord(oui: "FA:0B:BC", type: 0x0D, dataHex: teal)])
        store.ingestBatch(observations: [tealObs], fleets: fleets, staleSec: 30)
        #expect((try #require(store.find(key: "WIFI:\(tealMac)"))).payloadAircraft == "Teal 2")

        let french = "AA:BB:CC:DD:EE:17"
        var frObs = wifi(french, name: "RID-FR", ies: ["6A:5C:35"])
        frObs.facts = RadioFacts(vendorIes: [VendorIeRecord(oui: "6A:5C:35", type: 0x01, dataHex: teal)])
        store.ingestBatch(observations: [frObs], fleets: fleets, staleSec: 30)
        let plate = try #require(store.find(key: "WIFI:\(french)"))
        #expect(plate.fleetIds.contains("fleet-remote-id"))
        #expect(plate.payloadAircraft == nil)
        #expect(plate.payloadUasId == nil)
    }

    @Test func wifiRemoteIdVendorIeSetsPayloadPin() throws {
        let store = DeviceStore()
        let mac = "AA:BB:CC:DD:EE:04"
        let msg = locationWifiPayload()
        var obs = wifi(mac, name: "RID-WIFI", ies: ["FA:0B:BC"])
        obs.facts = RadioFacts(vendorIes: [VendorIeRecord(oui: "FA:0B:BC", type: 0x0D, dataHex: msg)])
        store.ingestBatch(observations: [obs], fleets: fleets, staleSec: 30)
        let device = try #require(store.find(key: "WIFI:\(mac)"))
        #expect(device.fleetIds.contains("fleet-remote-id"))
        #expect(close(try #require(device.payloadLat), 40.0))
        #expect(close(try #require(device.payloadLon), -74.0))
        #expect(close(try #require(device.payloadHeading), 90.0))
        #expect(close(try #require(device.payloadSpeed), 10.0))
    }

    @Test func remoteIdWestHeadingAndHorizontalSpeed() throws {
        let store = DeviceStore()
        let mac = "AA:BB:CC:DD:EE:05"
        let flags = 0x20 | 0x02
        let msg: [UInt8] = [0x12, UInt8(flags), 90, 40, 4] + le32(400_000_000) + le32(-740_000_000) + le16(0) +
            le16(2200) + le16(2100) + [UInt8](repeating: 0, count: 6)
        let location = "0D00" + msg.toHexUpper()
        store.ingestBatch(observations: [ble(mac, name: "", facts: ridFacts(location))], fleets: fleets, staleSec: 30)
        let device = try #require(store.find(key: "BLE:\(mac)"))
        #expect(close(try #require(device.payloadHeading), 270.0))
        #expect(close(try #require(device.payloadSpeed), 10.0))
    }

    @Test func radioHoldDoesNotResurrectAlreadyGone() {
        let now = 1_000_000
        let linger = 15_000
        let lastSeen = now - 120_000
        #expect(
            !DeviceStore.stillHeard(kind: .wifi, lastSeen: lastSeen, alreadyGone: true, now: now, lingerMs: linger,
                                    wifiScanFresh: false, wifiHold: true, bleHold: false),
            "late Wi-Fi scan must not un-gone an aged AP"
        )
        #expect(
            DeviceStore.stillHeard(kind: .wifi, lastSeen: lastSeen, alreadyGone: false, now: now, lingerMs: linger,
                                   wifiScanFresh: false, wifiHold: false, bleHold: false),
            "a live AP still waits for the next Wi-Fi scan"
        )
        #expect(
            !DeviceStore.stillHeard(kind: .ble, lastSeen: lastSeen, alreadyGone: true, now: now, lingerMs: linger,
                                    wifiScanFresh: true, wifiHold: false, bleHold: true),
            "BLE restart must not un-gone an aged advertiser"
        )
        #expect(
            DeviceStore.stillHeard(kind: .ble, lastSeen: now - 1_000, alreadyGone: false, now: now, lingerMs: linger,
                                   wifiScanFresh: true, wifiHold: false, bleHold: false),
            "heard inside linger stays"
        )
    }

    @Test func rssi127DoesNotBecomeMaxOrHistory() throws {
        let store = DeviceStore()
        let mac = "E0:9D:13:6E:71:03"
        store.ingestBatch(observations: [ble(mac, name: "SmartTag", rssi: -92)], fleets: fleets, staleSec: 30)
        store.ingestBatch(observations: [ble(mac, name: "SmartTag", rssi: 127)], fleets: fleets, staleSec: 30)
        let device = try #require(store.find(key: "BLE:\(mac)"))
        #expect(device.rssi == -92)
        #expect(device.rssiMin == -92)
        #expect(device.rssiMax == -92)
        #expect(device.rssiHistory.none { $0.rssi == 127 })
        store.ingestBatch(observations: [ble(mac, name: "SmartTag", rssi: -86)], fleets: fleets, staleSec: 30)
        let louder = try #require(store.find(key: "BLE:\(mac)"))
        #expect(louder.rssi == -86)
        #expect(louder.rssiMin == -92)
        #expect(louder.rssiMax == -86)
    }

    @Test func freshWifiBatchSetsTheScanClockWithoutATick() {
        let store = DeviceStore()
        let before = nowMs()
        store.ingestBatch(observations: [wifi("00:11:22:33:44:55", name: "Cafe")], fleets: fleets, staleSec: 30)
        store.refresh(fleets: fleets, staleSec: 30)
        let at = store.stats.value.lastWifiScanAt
        #expect(at >= before)
        var stale = wifi("00:11:22:33:44:55", name: "Cafe")
        stale.fresh = false
        stale.rssi = -40
        store.ingestBatch(observations: [stale], fleets: fleets, staleSec: 30)
        store.refresh(fleets: fleets, staleSec: 30)
        #expect(store.stats.value.lastWifiScanAt == at)
    }

    @Test func refreshEmitsWithoutDroppingTags() throws {
        let store = DeviceStore()
        let mac = "00:00:0C:11:22:33"
        store.ingestBatch(observations: [wifi(mac, name: "Campus")], fleets: fleets, staleSec: 30)
        store.refresh(fleets: fleets, staleSec: 30)
        let published = try #require(store.devices.value.first { $0.mac == mac })
        #expect(published.fleetIds.contains("fleet-cisco"))
    }

    // MARK: - Helpers

    private func close(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) <= eps }

    private func ridFacts(_ hex: String) -> RadioFacts {
        RadioFacts(serviceData: [ServiceDataRecord(uuid: "FFFA", dataHex: hex)])
    }

    private func removePrefix(_ s: String, _ p: String) -> String { s.hasPrefix(p) ? String(s.dropFirst(p.count)) : s }

    private func wifi(_ mac: String, name: String = "", rssi: Int = -50, ies: [String] = []) -> RadioObservation {
        RadioObservation(
            kind: .wifi, mac: mac, name: name, rssi: rssi, channel: 1, frequencyMhz: 2412, hiddenSsid: false,
            serviceUuids: [], manufacturerId: nil, manufacturerDataHex: "", rawHex: "", extras: "",
            at: nowMs(), vendorIeOuis: ies
        )
    }

    private func ble(_ mac: String, name: String, facts: RadioFacts = .Empty, rssi: Int = -50) -> RadioObservation {
        RadioObservation(
            kind: .ble, mac: mac, name: name, rssi: rssi, channel: 0, frequencyMhz: 0, hiddenSsid: false,
            serviceUuids: facts.serviceData.isEmpty ? [] : facts.serviceData.map { $0.uuid },
            manufacturerId: nil, manufacturerDataHex: "", rawHex: "", extras: "",
            at: nowMs(), facts: facts
        )
    }

    private func locationWifiPayload() -> String {
        let flags = 0x20
        let msg: [UInt8] = [0x12, UInt8(flags), 90, 40, 4] + le32(400_000_000) + le32(-740_000_000) + le16(0) +
            le16(2200) + le16(2100) + [UInt8](repeating: 0, count: 6)
        return "00" + msg.toHexUpper()
    }

    private func basicIdService(_ idType: Int, _ serial: String) -> String {
        var msg = [UInt8](repeating: 0, count: 25)
        msg[0] = 0x02
        msg[1] = UInt8((((idType & 0x0F) << 4) | 0x02) & 0xFF)
        let bytes = Array(serial.utf8)
        for i in 0..<min(bytes.count, 20) { msg[2 + i] = bytes[i] }
        return "0D00" + msg.toHexUpper()
    }

    private func le32(_ n: Int) -> [UInt8] {
        [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)]
    }

    private func le16(_ n: Int) -> [UInt8] { [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF)] }
}
