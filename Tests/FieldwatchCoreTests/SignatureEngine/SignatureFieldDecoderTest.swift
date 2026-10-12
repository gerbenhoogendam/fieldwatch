import Foundation
import Testing
@testable import FieldwatchCore

// Port of SignatureFieldDecoderTest.kt.

private func edited<T>(_ value: T, _ edit: (inout T) -> Void) -> T {
    var v = value
    edit(&v)
    return v
}

private extension Array where Element == DecodedFieldValue {
    /// Kotlin `first { it.id == id }.display` — a missing id fails the test.
    func display(_ id: String) -> String {
        let row = first { $0.id == id }
        #expect(row != nil, "no decoded field \(id)")
        return row?.display ?? ""
    }

    func number(_ id: String) -> Double? {
        let row = first { $0.id == id }
        #expect(row != nil, "no decoded field \(id)")
        return row?.number
    }
}

private func near(_ a: Double?, _ b: Double, _ eps: Double = 1e-6) -> Bool {
    guard let a else { return false }
    return Swift.abs(a - b) <= eps
}

private func stock(_ id: String) -> Fleet { DefaultCatalog.fleets().single { $0.id == id } }

private func wifiRid(_ dataHex: String, _ fleetId: String) -> Sighting {
    Sighting(
        key: "WIFI:60:60:1F:06:31:08",
        kind: .wifi,
        mac: "60:60:1F:06:31:08",
        name: "RID-1581F3YTDJ1D0031Z530",
        rssi: -80,
        rssiMin: -80,
        rssiMax: -80,
        channel: 6,
        frequencyMhz: 2437,
        vendor: nil,
        randomized: false,
        hiddenSsid: false,
        serviceUuids: [],
        manufacturerId: nil,
        manufacturerDataHex: "",
        rawHex: "",
        extras: "",
        firstSeen: 1,
        lastSeen: 1,
        hitCount: 1,
        fleetIds: [fleetId],
        rssiHistory: [],
        presence: [],
        facts: RadioFacts(vendorIes: [VendorIeRecord(oui: "FA:0B:BC", type: 0x0D, dataHex: dataHex)])
    )
}

private func bleService(_ uuid: String, _ dataHex: String, _ fleetId: String) -> Sighting {
    Sighting(
        key: "BLE:AA:BB:CC:DD:EE:01",
        kind: .ble,
        mac: "AA:BB:CC:DD:EE:01",
        name: "",
        rssi: -50,
        rssiMin: -50,
        rssiMax: -50,
        channel: 0,
        frequencyMhz: 2402,
        vendor: nil,
        randomized: true,
        hiddenSsid: false,
        serviceUuids: [uuid],
        manufacturerId: nil,
        manufacturerDataHex: "",
        rawHex: "",
        extras: "",
        firstSeen: 1,
        lastSeen: 1,
        hitCount: 1,
        fleetIds: [fleetId],
        rssiHistory: [],
        presence: [],
        facts: RadioFacts(serviceData: [ServiceDataRecord(uuid: uuid, dataHex: dataHex)])
    )
}

private func ble(_ companyId: Int, _ dataHex: String, _ fleetId: String) -> Sighting {
    Sighting(
        key: "BLE:AA:BB:CC:DD:EE:01",
        kind: .ble,
        mac: "AA:BB:CC:DD:EE:01",
        name: "",
        rssi: -50,
        rssiMin: -50,
        rssiMax: -50,
        channel: 0,
        frequencyMhz: 2402,
        vendor: nil,
        randomized: true,
        hiddenSsid: false,
        serviceUuids: [],
        manufacturerId: companyId,
        manufacturerDataHex: dataHex,
        rawHex: "",
        extras: "",
        firstSeen: 1,
        lastSeen: 1,
        hitCount: 1,
        fleetIds: [fleetId],
        rssiHistory: [],
        presence: [],
        facts: RadioFacts(mfgRecords: [MfgRecord(companyId: companyId, dataHex: dataHex)])
    )
}

private func decode(_ device: Sighting, _ fleet: Fleet) -> [DecodedFieldValue] {
    SignatureFieldDecoder.decodeSighting(device: device, fleets: [fleet])
}

private func chips(_ device: Sighting, _ fleet: Fleet) -> [LiveDecodeChip] {
    SignatureFieldDecoder.liveChips(device: device, fleets: [fleet])
}

@Suite struct SignatureFieldDecoderTest {
    @Test func ruuviRawV2TemperatureHumidity() {
        // Data Format 5 after company ID 0x0499. Example from Ruuvi docs.
        let payload = "0512FC5394C37C0004FFFC040CAC364200CDCBB8334C884F"
        let fleet = Fleet(
            id: "fleet-ruuvi",
            name: "Ruuvi",
            decode: FleetDecode(
                source: .manufacturerData,
                companyId: 0x0499,
                fields: [
                    DecodeField(
                        id: "format",
                        label: "Format",
                        offset: 0,
                        type: .u8,
                        gate: DecodeWhen(offset: 0, op: .eq, valueHex: "05")
                    ),
                    DecodeField(
                        id: "temperature",
                        label: "Temperature",
                        offset: 1,
                        type: .i16,
                        endian: .be,
                        scale: 0.005,
                        unit: "°C"
                    ),
                    DecodeField(
                        id: "humidity",
                        label: "Humidity",
                        offset: 3,
                        type: .u16,
                        endian: .be,
                        scale: 0.0025,
                        unit: "%"
                    ),
                ]
            )
        )
        let rows = decode(ble(0x0499, payload, fleet.id), fleet)
        #expect(rows.display("format") == "5", "Format")
        #expect(rows.display("temperature") == "24.3 °C", "Temperature")
        #expect(rows.display("humidity") == "53.49 %", "Humidity")
    }

    @Test func scaleThenOffsetAdd() {
        let fleet = Fleet(
            id: "f",
            name: "P",
            decode: FleetDecode(
                source: .manufacturerData,
                fields: [
                    DecodeField(
                        id: "pressure",
                        label: "Pressure",
                        offset: 0,
                        type: .u16,
                        endian: .be,
                        scale: 1.0,
                        offsetAdd: 50000.0,
                        unit: "Pa"
                    ),
                ]
            )
        )
        let rows = decode(ble(1, "C37C", fleet.id), fleet)
        // 0xC37C = 50044; + 50000 = 100044
        #expect(rows.count == 1)
        #expect(rows.first?.display == "100044 Pa")
    }

    @Test func whenMismatchSkipsField() {
        let fleet = Fleet(
            id: "f",
            name: "P",
            decode: FleetDecode(
                source: .manufacturerData,
                fields: [
                    DecodeField(
                        id: "temp",
                        label: "Temperature",
                        offset: 1,
                        type: .u8,
                        gate: DecodeWhen(offset: 0, op: .eq, valueHex: "05")
                    ),
                ]
            )
        )
        #expect(decode(ble(1, "0312", fleet.id), fleet).isEmpty)
    }

    @Test func shortPayloadSkipsWithoutThrowing() {
        let fleet = Fleet(
            id: "f",
            name: "P",
            decode: FleetDecode(
                source: .manufacturerData,
                fields: [DecodeField(id: "wide", label: "Wide", offset: 0, type: .u32)]
            )
        )
        #expect(decode(ble(1, "01", fleet.id), fleet).isEmpty)
    }

    @Test func serviceDataUuidMatch() {
        let fleet = Fleet(
            id: "f",
            name: "S",
            decode: FleetDecode(
                source: .serviceData,
                serviceUuid: "FEAA",
                fields: [DecodeField(id: "frame", label: "Frame", offset: 0, type: .u8)]
            )
        )
        let device = Sighting(
            key: "BLE:AA:BB:CC:DD:EE:01",
            kind: .ble,
            mac: "AA:BB:CC:DD:EE:01",
            name: "",
            rssi: -50,
            rssiMin: -50,
            rssiMax: -50,
            channel: 0,
            frequencyMhz: 2402,
            vendor: nil,
            randomized: true,
            hiddenSsid: false,
            serviceUuids: ["FEAA"],
            manufacturerId: nil,
            manufacturerDataHex: "",
            rawHex: "",
            extras: "",
            firstSeen: 1,
            lastSeen: 1,
            hitCount: 1,
            fleetIds: [fleet.id],
            rssiHistory: [],
            presence: [],
            facts: RadioFacts(serviceData: [ServiceDataRecord(uuid: "FEAA", dataHex: "20AB")])
        )
        let rows = decode(device, fleet)
        #expect(rows.count == 1)
        #expect(rows.first?.display == "32")
    }

    @Test func wifiIsIgnored() {
        let fleet = Fleet(
            id: "f",
            name: "P",
            decode: FleetDecode(
                source: .manufacturerData,
                fields: [DecodeField(id: "x", label: "X", offset: 0, type: .u8)]
            )
        )
        let ap = edited(ble(1, "01", fleet.id)) { $0.kind = .wifi }
        #expect(decode(ap, fleet).isEmpty)
    }

    @Test func packRoundTripKeepsIncludeCompanyId() throws {
        let fleet = Fleet(
            id: "fleet-sytpms",
            name: "SYTPMS",
            decode: FleetDecode(
                source: .manufacturerData,
                includeCompanyId: true,
                fields: [DecodeField(id: "temp", label: "Temperature", offset: 2, type: .u8)]
            )
        )
        let json = SignatureExchange.encode(pack: SignatureExchange.pack(fleets: [fleet], catalogVersion: 0, appVersion: "test", exportedAt: "now"))
        let parsed = try SignatureExchange.parse(text: json).fleets
        #expect(parsed.count == 1)
        #expect(try #require(parsed.first?.decode).includeCompanyId)
    }

    @Test func packRoundTripKeepsDecode() throws {
        let fleet = Fleet(
            id: "fleet-ruuvi",
            name: "Ruuvi",
            rules: [MatchRule(kind: .manufacturerId, companyId: 0x0499)],
            decode: FleetDecode(
                source: .manufacturerData,
                companyId: 0x0499,
                fields: [
                    DecodeField(id: "temperature", label: "Temperature", offset: 1, type: .i16, endian: .be, scale: 0.005, unit: "°C"),
                ]
            )
        )
        let json = SignatureExchange.encode(pack: SignatureExchange.pack(fleets: [fleet], catalogVersion: 0, appVersion: "test", exportedAt: "now"))
        let parsed = try SignatureExchange.parse(text: json).fleets
        #expect(parsed.count == 1)
        let fields = try #require(parsed.first?.decode).fields
        #expect(fields.count == 1)
        #expect(fields.first?.id == "temperature")
        #expect(fields.first?.endian == .be)
        #expect(fields.first?.scale == 0.005)
    }

    @Test func importBackupAppliesIncomingDecodeOnSameId() throws {
        let stockRow = Fleet(
            id: "fleet-fitbit",
            name: "Fitbit",
            rules: [MatchRule(kind: .manufacturerId, companyId: 0x018E)]
        )
        let backup = edited(stockRow) {
            $0.decode = FleetDecode(
                source: .manufacturerData,
                companyId: 0x018E,
                fields: [DecodeField(id: "status", label: "Status", offset: 0, type: .u8)]
            )
        }
        let (_, result) = SignatureExchange.merge(existing: [stockRow], incoming: [backup])
        #expect(result.merged == 1)
        let merged = SignatureExchange.merge(existing: [stockRow], incoming: [backup]).0
        #expect(merged.count == 1)
        let fields = try #require(merged.first?.decode).fields
        #expect(fields.count == 1)
        #expect(fields.first?.id == "status")
    }

    @Test func wifiOnlySignatureHasNoDecodeEditor() {
        let ap = Fleet(
            id: "fleet-unifi",
            name: "UniFi AP",
            rules: [MatchRule(kind: .nameContains, text: "UniFi", radio: .wifi)]
        )
        #expect(!ap.canHaveBleDecode())
        let bleRow = Fleet(
            id: "fleet-fitbit",
            name: "Fitbit",
            rules: [MatchRule(kind: .manufacturerId, companyId: 0x018E)]
        )
        #expect(bleRow.canHaveBleDecode())
    }

    @Test func normalizeEnumKeysTreatHexAndDecimalAsSame() throws {
        #expect(normalizeEnumKey(raw: "0x05") == "5")
        #expect(normalizeEnumKey(raw: "05") == "5")
        #expect(normalizeEnumKey(raw: "5") == "5")
        #expect(normalizeEnumKey(raw: "10") == "10")
        let labels = try #require(normalizeEnumLabels(map: ["0x02": "Active", "1": "Idle"]))
        #expect(labels["2"] == "Active")
        #expect(labels["1"] == "Idle")
    }

    @Test func normalizedWhenKeepsEvenHex() throws {
        let gate = try #require(normalizeGate(gate: DecodeWhen(offset: 0, op: .eq, valueHex: "0x5")))
        #expect(gate.valueHex == "05")
        #expect(gate.length == 1)
    }

    @Test func normalizedWhenTwoByteHexSetsLength() throws {
        let gate = try #require(normalizeGate(gate: DecodeWhen(offset: 10, op: .eq, valueHex: "544E")))
        #expect(gate.valueHex == "544E")
        #expect(gate.length == 2)
        #expect(gate.offset == 10)
    }

    @Test func enumMapsRawValue() {
        let fleet = Fleet(
            id: "f",
            name: "P",
            decode: FleetDecode(
                source: .manufacturerData,
                fields: [
                    DecodeField(
                        id: "mode",
                        label: "Mode",
                        offset: 0,
                        type: .u8,
                        enumLabels: ["1": "idle", "2": "active"]
                    ),
                ]
            )
        )
        let rows = decode(ble(1, "02", fleet.id), fleet)
        #expect(rows.count == 1)
        #expect(rows.first?.display == "active")
    }

    @Test func catalogRuuviRawV2() {
        let fleet = stock("fleet-ruuvi")
        let rows = decode(ble(0x0499, "0512FC5394C37C0004FFFC040CAC364200CDCBB8334C884F", fleet.id), fleet)
        #expect(rows.display("format") == "5")
        #expect(rows.display("temperature") == "24.3 °C")
        #expect(rows.display("humidity") == "53.49 %")
        #expect(rows.display("pressure") == "1000.44 hPa")
        #expect(rows.display("acc_x") == "0.004 g")
        #expect(rows.display("acc_y") == "-0.004 g")
        #expect(rows.display("acc_z") == "1.036 g")
        #expect(rows.display("battery") == "2977 mV")
        #expect(rows.display("tx_power") == "4 dBm")
        #expect(rows.display("mac") == "CB:B8:33:4C:88:4F")
    }

    @Test func catalogRemoteIdBasicId() {
        let fleet = stock("fleet-remote-id")
        let payload = "0D000212" + "5445535453455249414C31323334353637383930" + "000000"
        let rows = decode(bleService("FFFA", payload, fleet.id), fleet)
        #expect(rows.display("app") == "Open Drone ID")
        #expect(rows.display("msg_type") == "Basic ID")
        #expect(rows.display("id_type") == "Serial (CTA-2063)")
        #expect(rows.display("ua_type") == "Helicopter / multirotor")
        #expect(rows.display("uas_id") == "TESTSERIAL1234567890")
    }

    @Test func catalogPenguinTnSerial() {
        let fleet = stock("fleet-penguin")
        // Ryan O'Horo SCAN_RSP payload after company 0x09C8.
        let payload = "D8A0D89F4A5E2030502A544E3732303233303232303030373731"
        let rows = decode(ble(0x09C8, payload, fleet.id), fleet)
        #expect(rows.display("adv_mac") == "D8:A0:D8:9F:4A:5E")
        #expect(rows.display("serial") == "TN72023022000771")
    }

    @Test func catalogPenguinWithoutTnSkipsDecode() {
        let fleet = stock("fleet-penguin")
        let payload = "D8A0D89F4A5E2030502A00003732303233303232303030373731"
        #expect(decode(ble(0x09C8, payload, fleet.id), fleet).isEmpty)
    }

    @Test func eqGateUsesHexByteLength() {
        let fleet = Fleet(
            id: "f",
            name: "P",
            decode: FleetDecode(
                source: .manufacturerData,
                fields: [
                    DecodeField(
                        id: "tag",
                        label: "Tag",
                        offset: 0,
                        length: 2,
                        type: .utf8,
                        gate: DecodeWhen(offset: 0, op: .eq, valueHex: "544E")
                    ),
                ]
            )
        )
        #expect(decode(ble(1, "544E3132", fleet.id), fleet).display("tag") == "TN")
    }

    @Test func catalogRemoteIdLocation() {
        let fleet = stock("fleet-remote-id")
        // 40° N, 74° W, HAE 100 m, height 50 m (OpenDroneID packed, proto v2).
        let payload = "0D0012200000000084D717007FE4D3000098083408000000000000"
        let rows = decode(bleService("FFFA", payload, fleet.id), fleet)
        #expect(rows.display("msg_type") == "Location")
        #expect(rows.display("status") == "Airborne")
        let airborne = chips(bleService("FFFA", payload, fleet.id), fleet)
        #expect(airborne.count == 1)
        #expect(airborne.first?.text == "Airborne")
        #expect(airborne.first?.emphasis == false)
        let emergency = "0D001230" + payload.drop(8)
        let strong = chips(bleService("FFFA", emergency, fleet.id), fleet)
        #expect(strong.count == 1)
        #expect(strong.first?.text == "Emergency")
        #expect(strong.first?.emphasis == true)
        let basicId = "0D000220" + payload.drop(8)
        #expect(chips(bleService("FFFA", basicId, fleet.id), fleet).isEmpty)
        #expect(rows.display("latitude") == "40 °")
        #expect(rows.display("longitude") == "-74 °")
        #expect(rows.display("alt_geo") == "100 m")
        #expect(rows.display("height") == "50 m")
        #expect(rows.display("heading") == "0 °")
        #expect(rows.display("hspeed") == "0 m/s")
        #expect(near(rows.number("latitude"), 40.0))
        #expect(near(rows.number("longitude"), -74.0))
        #expect(near(rows.number("alt_geo"), 100.0))
        #expect(near(rows.number("heading"), 0.0))
        #expect(near(rows.number("hspeed"), 0.0))
    }

    @Test func catalogRemoteIdWifiMessagePackUsesBleMap() {
        let fleet = stock("fleet-remote-id")
        let hex = "D9F2190302123135383146335954444A3144303033315A353330000000" +
            "1220820A00864228110CFF80CF0000F508B2083A022E310A00" +
            "420176E42711B5FF81CF010000000000000005088B02900E00"
        let rows = decode(wifiRid(hex, fleet.id), fleet)
        #expect(rows.display("uas_id") == "1581F3YTDJ1D0031Z530")
        #expect(rows.display("ua_type") == "Helicopter / multirotor")
        #expect(rows.display("status") == "Airborne")
        #expect(near(rows.number("latitude"), 28.7851142))
        #expect(near(rows.number("longitude"), -81.3629684))
        #expect(near(rows.number("heading"), 130.0))
        #expect(near(rows.number("hspeed"), 2.5))
        #expect(near(rows.number("op_lat"), 28.7827062))
        #expect(near(rows.number("op_lon"), -81.3563979))
    }

    @Test func catalogRemoteIdLocationWestHeadingAndSpeed() {
        let fleet = stock("fleet-remote-id")
        // Airborne, EWDirection, direction 90 → 270°. Speed 40 × 0.25 = 10 m/s.
        let payload = "0D0012225A28000084D717007FE4D3000098083408000000000000"
        let rows = decode(bleService("FFFA", payload, fleet.id), fleet)
        #expect(rows.display("msg_type") == "Location")
        #expect(rows.display("heading") == "270 °")
        #expect(rows.display("hspeed") == "10 m/s")
        #expect(near(rows.number("heading"), 270.0))
        #expect(near(rows.number("hspeed"), 10.0))
        #expect(rows.count { $0.id == "heading" } == 1)
        #expect(rows.count { $0.id == "hspeed" } == 1)
    }

    @Test func catalogRemoteIdLocationHighSpeedMultiplier() {
        let fleet = stock("fleet-remote-id")
        // SpeedMult set, SpeedHorizontal 4 → 4×0.75 + 255×0.25 = 66.75 m/s.
        let payload = "0D0012210004000084D717007FE4D3000098083408000000000000"
        let rows = decode(bleService("FFFA", payload, fleet.id), fleet)
        #expect(near(rows.number("hspeed"), 66.75))
        #expect(near(rows.number("heading"), 0.0))
    }

    @Test func catalogFindHubSeparatedMode() {
        let fleet = stock("fleet-find-hub")
        let eid = "11".repeated(20)
        let rows = decode(bleService("FEAA", "41\(eid)" + "00", fleet.id), fleet)
        #expect(rows.display("mode") == "separated")
        #expect(rows.display("eid") == "11 11 11 11 11 11 11 11 11 11 11 11 11 11 11 11 11 11 11 11")
        let strong = chips(bleService("FEAA", "41\(eid)" + "00", fleet.id), fleet)
        #expect(strong.count == 1)
        #expect(strong.first?.text == "separated")
        #expect(strong.first?.emphasis == true)
        #expect(strong.first?.note.contains("about a day") == true)
        let quiet = chips(bleService("FEAA", "40\(eid)" + "00", fleet.id), fleet)
        #expect(quiet.count == 1)
        #expect(quiet.first?.text == "nearby")
        #expect(quiet.first?.emphasis == false)
        #expect(quiet.first?.note.contains("own tag") == true)
        #expect(quiet.first?.note.contains("joined") == true)
    }

    @Test func catalogDultSeparatedAndNearOwner() {
        let fleet = stock("fleet-dult")
        let separated = decode(bleService("FCB2", "0100", fleet.id), fleet)
        #expect(separated.display("network_id") == "1")
        #expect(separated.display("mode") == "separated")
        let strong = chips(bleService("FCB2", "0100", fleet.id), fleet)
        #expect(strong.count == 1)
        #expect(strong.first?.text == "separated")
        #expect(strong.first?.emphasis == true)
        #expect(strong.first?.note.contains("about a day") == true)
        let nearOwner = decode(bleService("FCB2", "0201", fleet.id), fleet)
        #expect(nearOwner.display("network_id") == "2")
        #expect(nearOwner.display("mode") == "near owner")
        let quiet = chips(bleService("FCB2", "0201", fleet.id), fleet)
        #expect(quiet.count == 1)
        #expect(quiet.first?.text == "near owner")
        #expect(quiet.first?.emphasis == false)
        #expect(quiet.first?.note.contains("own tag") == true)
        #expect(quiet.first?.note.contains("joined") == true)
    }

    @Test func liveFlagRoundTripsAndOlderPacksOmitIt() throws {
        let fleet = stock("fleet-dult")
        let encoded = SignatureExchange.encode(
            pack: SignatureExchange.pack(fleets: [fleet], catalogVersion: 85, appVersion: "t", exportedAt: "")
        )
        let fields = try #require(SignatureExchange.parse(text: encoded).fleets.first?.decode).fields
        let mode = fields.single { $0.id == "mode" }
        #expect(mode.live)
        #expect(mode.liveEmphasis == ["0"])
        #expect(mode.enumNotes?["0"]?.contains("about a day") == true)
        #expect(mode.enumNotes?["1"]?.contains("own tag") == true)
        let older = """
            {"format":"fieldwatch-signatures","formatVersion":1,"catalogVersion":1,"fleets":[
              {"id":"fleet-x","name":"X","rules":[{"kind":"SERVICE_DATA","text":"FCB2"}],
               "decode":{"source":"serviceData","serviceUuid":"FCB2","fields":[
                 {"id":"mode","label":"Mode","offset":1,"type":"bits","bitOffset":0,"bitWidth":1,
                  "enum":{"0":"separated","1":"near owner"}}
               ]}}
            ]}
            """
        let parsedFields = try #require(SignatureExchange.parse(text: older).fleets.first?.decode).fields
        #expect(parsedFields.count == 1)
        let parsed = try #require(parsedFields.first)
        #expect(!parsed.live)
        #expect(parsed.liveEmphasis.isEmpty)
        #expect(parsed.enumNotes == nil)
    }

    @Test func catalogBlueMaestroV23() {
        let fleet = stock("fleet-bluemaestro")
        let rows = decode(ble(0x0133, "1764000A000100E001F4", fleet.id), fleet)
        #expect(rows.display("version") == "23")
        #expect(rows.display("battery") == "100 %")
        #expect(rows.display("temperature") == "22.4 °C")
        #expect(rows.display("humidity") == "50 %")
    }

    @Test func catalogGoproHero12() {
        let fleet = stock("fleet-gopro")
        let rows = decode(ble(0xF202, "02073E000000000000000001", fleet.id), fleet)
        #expect(rows.display("schema") == "2")
        #expect(rows.display("awake") == "awake")
        #expect(rows.display("wifi_ap") == "on")
        #expect(rows.display("pairing") == "yes")
        #expect(rows.display("model") == "HERO12 Black")
    }

    @Test func catalogOsmoAction3Model() {
        let fleet = stock("fleet-osmo")
        #expect(decode(ble(0x08AA, "1200", fleet.id), fleet).display("model") == "Osmo Action 3")
    }

    @Test func catalogDjiPower2000ModelLabel() {
        let fleet = stock("fleet-dji-power")
        #expect(decode(ble(0x08AA, "941110E4B063D0AA76", fleet.id), fleet).display("model") == "Power 2000")
    }

    @Test func catalogRuuviRawV1() {
        let fleet = stock("fleet-ruuvi")
        let rows = decode(ble(0x0499, "03291A1ECE1EFC18F94202CA0B53", fleet.id), fleet)
        #expect(rows.display("format") == "3")
        #expect(rows.display("humidity") == "20.5 %")
        #expect(rows.display("pressure") == "1027.66 hPa")
        #expect(rows.display("acc_x") == "-1 g")
        #expect(rows.display("battery") == "2899 mV")
    }

    @Test func catalogGoveeH5075Packed() {
        let fleet = stock("fleet-govee")
        let rows = decode(ble(0xEC88, "0003215D64", fleet.id), fleet)
        #expect(rows.display("temperature") == "20.5149 °C")
        #expect(rows.display("humidity") == "14.9 %")
        #expect(rows.display("battery") == "100 %")
    }

    @Test func catalogGoveeH5074() {
        checkGoveeH5074()
    }

    private func checkGoveeH5074() {
        let fleet = stock("fleet-govee")
        let rows = decode(ble(0xEC88, "00580AE6116402", fleet.id), fleet)
        #expect(rows.display("temperature") == "26.48 °C")
        #expect(rows.display("humidity") == "45.82 %")
        #expect(rows.display("battery") == "100 %")
    }

    /// Kotlin switched the JVM default locale to FRANCE. Swift has no settable default locale;
    /// formatting goes through `fmt` (en_US_POSIX), so this re-runs the same check.
    @Test func decodedFractionsStayPeriodOnFrenchLocale() {
        checkGoveeH5074()
    }

    @Test func catalogGoveeH5102Packed() {
        let fleet = stock("fleet-govee")
        let rows = decode(ble(0x0001, "010103215D64", fleet.id), fleet)
        #expect(rows.display("temperature") == "20.5149 °C")
        #expect(rows.display("humidity") == "14.9 %")
        #expect(rows.display("battery") == "100 %")
    }

    @Test func catalogGoveeH5102EightByte() {
        let fleet = stock("fleet-govee")
        let rows = decode(ble(0x0001, "010103215D640000", fleet.id), fleet)
        #expect(rows.display("temperature") == "20.5149 °C")
        #expect(rows.display("humidity") == "14.9 %")
        #expect(rows.display("battery") == "100 %")
    }

    @Test func catalogGoveeStripsIntelliRocksSuffix() {
        let fleet = stock("fleet-govee")
        let rocks = Array("INTELLI_ROCKS".utf8).toHexUpper()
        let rows = decode(ble(0xEC88, "0003215D64\(rocks)", fleet.id), fleet)
        #expect(rows.display("temperature") == "20.5149 °C")
        #expect(rows.display("battery") == "100 %")
    }

    @Test func catalogGoveeSkipsUnrelatedMakerRecord() {
        let fleet = stock("fleet-govee")
        #expect(decode(ble(0x004C, "0215AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA01020304C5", fleet.id), fleet).isEmpty)
    }

    @Test func catalogGoveePicksHygrometerAmongMakerRecords() {
        let fleet = stock("fleet-govee")
        let device = edited(ble(0x004C, "0215AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA01020304C5", fleet.id)) {
            $0.facts = RadioFacts(
                mfgRecords: [
                    MfgRecord(companyId: 0x004C, dataHex: "0215AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA01020304C5"),
                    MfgRecord(companyId: 0xEC88, dataHex: "0003215D64"),
                ]
            )
        }
        #expect(decode(device, fleet).display("temperature") == "20.5149 °C")
    }

    @Test func catalogKontaktLocation() {
        let fleet = stock("fleet-kontakt")
        let rows = decode(bleService("FE6A", "0764F4250A00", fleet.id), fleet)
        #expect(rows.display("kind") == "Location")
        #expect(rows.display("battery") == "100 %")
        #expect(rows.display("moving") == "still")
    }

    @Test func catalogNestWeaveProtect2() {
        let fleet = stock("fleet-nest-weave")
        #expect(decode(bleService("FEAF", "0900", fleet.id), fleet).display("product") == "Nest Protect (2nd gen)")
    }

    @Test func catalogNestWeaveIdentificationBlock() {
        let fleet = stock("fleet-nest-weave")
        // OpenWeave WeaveBLEDeviceIdentificationInfo: len 0x10, type 0x01,
        // v0.1, vendor 0x235A, product 0x0009 Protect 2nd gen, device id, paired.
        let payload = "100100015A230900010203040506070801"
        let rows = decode(bleService("FEAF", payload, fleet.id), fleet)
        #expect(rows.display("vendor") == "Nest Labs")
        #expect(rows.display("product") == "Nest Protect (2nd gen)")
        #expect(rows.display("device_id") == "01 02 03 04 05 06 07 08")
        #expect(rows.display("pairing") == "paired")
        #expect(!rows.contains { $0.id == "product" && $0.display.contains("272") })
    }

    @Test func catalogTuyaBound() {
        let fleet = stock("fleet-tuya")
        let rows = decode(ble(0x07D0, "8004", fleet.id), fleet)
        #expect(rows.display("bound") == "bound")
        #expect(rows.display("protocol") == "4")
    }

    @Test func catalogTilePrivateId() {
        let fleet = stock("fleet-tile")
        #expect(decode(bleService("FEED", "0102030405060708", fleet.id), fleet).display("private_id") == "01 02 03 04 05 06 07 08")
    }

    @Test func catalogEstimoteTelemetryFrame() {
        let fleet = stock("fleet-estimote")
        #expect(decode(ble(0x015D, "02ABCD", fleet.id), fleet).display("frame") == "Telemetry")
    }

    @Test func catalogHasDecodeOnPublishedLayoutsOnly() {
        let byId = DefaultCatalog.fleets().associateBy { $0.id }
        func has(_ id: String) -> Bool? { byId[id].map { $0.decode != nil } }
        #expect(has("fleet-ruuvi") == true)
        #expect(has("fleet-remote-id") == true)
        #expect(has("fleet-bluemaestro") == true)
        #expect(has("fleet-gopro") == true)
        #expect(has("fleet-osmo") == true)
        #expect(has("fleet-dji") == true)
        #expect(has("fleet-dji-power") == true)
        #expect(has("fleet-govee") == true)
        #expect(has("fleet-kontakt") == true)
        #expect(has("fleet-estimote") == true)
        #expect(has("fleet-nest-weave") == true)
        #expect(has("fleet-tuya") == true)
        #expect(has("fleet-tile") == true)
        #expect(has("fleet-fitbit") == false)
        #expect(has("fleet-airtag") == false)
        #expect(has("fleet-tpms-ble") == true)
        #expect(has("fleet-sytpms") == true)
        #expect(has("fleet-tesla-tstpms") == true)
        #expect(has("fleet-goodyear") == false)
        #expect(has("fleet-fobo") == false)
        #expect(has("fleet-tirecheck") == false)
    }

    @Test func catalogAftermarketTpmsPressureTempBattery() {
        let fleet = stock("fleet-tpms-ble")
        let rows = decode(ble(0x0001, "80EACA108A78E36D0000E60A00005B00", fleet.id), fleet)
        #expect(rows.display("wheel") == "1")
        #expect(rows.display("sensor_id") == "EA CA 10 8A 78")
        #expect(rows.display("pressure") == "28.131 kPa")
        #expect(rows.display("temperature") == "27.9 °C")
        #expect(rows.display("battery") == "91 %")
        #expect(rows.display("alarm") == "ok")
    }

    @Test func catalogSytpmsIncludesCompanyIdBytes() {
        let fleet = stock("fleet-sytpms")
        let rows = decode(ble(0x1E28, "1401558536", fleet.id), fleet)
        #expect(rows.display("alarm") == "ok")
        #expect(rows.display("rotating") == "no")
        #expect(rows.display("still") == "yes")
        #expect(rows.display("battery") == "3 V")
        #expect(rows.display("temperature") == "20 °C")
        #expect(rows.display("pressure") == "19.6 psi")
    }

    @Test func catalogTeslaTstpmsAwakePressure() {
        let fleet = stock("fleet-tesla-tstpms")
        let rows = decode(ble(0x022B, "0000058A0147B80B", fleet.id), fleet)
        #expect(rows.display("mode") == "5")
        #expect(rows.display("pressure") == "42 psi")
        #expect(rows.display("temperature") == "70 °F")
        #expect(rows.display("battery") == "3000 mV")
    }

    @Test func catalogTeslaTstpmsSleepSkipsSensors() {
        let fleet = stock("fleet-tesla-tstpms")
        let rows = decode(ble(0x022B, "0000008A0147B80B", fleet.id), fleet)
        #expect(rows.display("mode") == "sleep")
        #expect(!rows.contains { $0.id == "pressure" })
        #expect(!rows.contains { $0.id == "temperature" })
        #expect(!rows.contains { $0.id == "battery" })
    }
}
