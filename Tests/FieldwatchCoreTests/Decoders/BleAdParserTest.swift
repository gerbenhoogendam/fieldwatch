import Foundation
import Testing
@testable import FieldwatchCore

struct BleAdParserTest {
    /// AD structure: [len][type][data]. len covers type + data.
    private func field(_ type: Int, _ data: Int...) -> [UInt8] {
        [UInt8(data.count + 1), UInt8(type)] + data.map { UInt8(truncatingIfNeeded: $0) }
    }

    private func nameField(_ type: Int, _ s: String) -> [UInt8] {
        let b = Array(s.utf8)
        return [UInt8(b.count + 1), UInt8(type)] + b
    }

    @Test func nullAndEmptyGiveEmptyParsed() {
        let none = BleAdParser.parse(bytes: nil)
        #expect(none.localName == nil)
        #expect(none.mfg.isEmpty)
        #expect(BleAdParser.parse(bytes: []).uuids.isEmpty)
    }

    @Test func flagsNameTxAppearanceInterval() throws {
        let bytes = field(0x01, 0x06) + nameField(0x09, "Pixel Buds") + field(0x0A, 0xF8) +
            field(0x19, 0x41, 0x03) + field(0x1A, 0xA0, 0x00)
        let p = BleAdParser.parse(bytes: bytes)
        #expect(p.flags == 0x06)
        #expect(p.localName == "Pixel Buds")
        #expect(p.txPower == -8)
        #expect(p.appearance == 0x0341)
        let iv = try #require(p.advertisingIntervalMs)
        #expect(abs(iv - 100.0) < 0.001)
    }

    @Test func completeNameBeatsShortenedEitherOrder() {
        let short = nameField(0x08, "FW")
        let full = nameField(0x09, "Fieldwatch")
        #expect(BleAdParser.parse(bytes: short + full).localName == "Fieldwatch")
        #expect(BleAdParser.parse(bytes: full + short).localName == "Fieldwatch")
        #expect(BleAdParser.parse(bytes: short).localName == "FW")
    }

    @Test func nameControlBytesBecomeSpaces() {
        // 0x07 (BEL) inside a local name must not inject control chars into the UI.
        let raw: [UInt8] = [4, 0x09, UInt8(ascii: "A"), 0x07, UInt8(ascii: "B")]
        #expect(BleAdParser.parse(bytes: raw).localName == "A B")
    }

    @Test func uuid16ListIsBigEndian() {
        // On-air order is little-endian; parsed form is the SIG-assigned hex.
        let p = BleAdParser.parse(bytes: field(0x03, 0xAA, 0xFE, 0x0D, 0x18))
        #expect(p.uuids == ["FEAA", "180D"])
    }

    @Test func uuid128IsByteReversed() {
        let le = (0x00...0x0F).map { UInt8($0) }
        let p = BleAdParser.parse(bytes: [17, 0x07] + le)
        #expect(p.uuids == ["0F0E0D0C-0B0A-0908-0706-050403020100"])
    }

    @Test func serviceData16AndManufacturerData() {
        let bytes = field(0x16, 0xAA, 0xFE, 0x01, 0x02) + field(0xFF, 0x4C, 0x00, 0x02, 0x15, 0xAB)
        let p = BleAdParser.parse(bytes: bytes)
        #expect(p.serviceData.count == 1)
        #expect(p.serviceData.first?.uuid == "FEAA")
        #expect(p.serviceData.first?.dataHex == "0102")
        #expect(p.mfg.count == 1)
        #expect(p.mfg.first?.companyId == 0x004C)
        #expect(p.mfg.first?.dataHex == "0215AB")
    }

    @Test func deviceClassIsLittleEndian24() {
        let p = BleAdParser.parse(bytes: field(0x0D, 0x0C, 0x05, 0x1F))
        #expect(p.deviceClass == 0x1F050C)
    }

    @Test func truncatedFieldStopsButKeepsEarlier() {
        let good = field(0x01, 0x06)
        let bad: [UInt8] = [0x40, 0x09, UInt8(ascii: "X")] // len says 64, only 2 bytes follow
        let p = BleAdParser.parse(bytes: good + bad)
        #expect(p.flags == 0x06)
        #expect(p.localName == nil)
    }

    @Test func zeroLengthFieldTerminates() {
        let p = BleAdParser.parse(bytes: field(0x01, 0x1E) + [0x00] + nameField(0x09, "late"))
        #expect(p.flags == 0x1E)
        #expect(p.localName == nil)
    }

    @Test func flagsLabelText() {
        #expect(BleAdParser.flagsLabel(flags: 0x06) == "LE General Discoverable, BR/EDR not supported")
        #expect(BleAdParser.flagsLabel(flags: 0x00) == "0x00")
    }

    // MARK: - macOS: buildAdvertisement round trip

    @Test func buildAdvertisementRoundTripsThroughParse() {
        let mfg: [UInt8] = [0x4C, 0x00, 0x02, 0x15, 0xAB]
        let bytes = BleAdParser.buildAdvertisement(
            localName: "Fieldwatch ✓",
            manufacturerData: mfg,
            serviceUuids: ["FEAA", "0000180D-0000-1000-8000-00805F9B34FB", "12345678", "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"],
            serviceData: [
                (uuid: "FEAA", data: [0x10, 0xC5, 0x01]),
                (uuid: "FD5A1234", data: [0x01]),
                (uuid: "6e400001-b5a3-f393-e0a9-e50e24dcca9e", data: [0xAA, 0xBB]),
            ],
            txPower: -8,
            solicitedUuids: ["1812"],
            overflowUuids: ["FE2C"]
        )
        let p = BleAdParser.parse(bytes: bytes)
        #expect(p.localName == "Fieldwatch ✓")
        #expect(p.mfg == [MfgRecord(companyId: 0x004C, dataHex: "0215AB")])
        #expect(p.txPower == -8)
        #expect(p.flags == nil)
        #expect(p.uuids == ["FEAA", "180D", "12345678", "6E400001-B5A3-F393-E0A9-E50E24DCCA9E", "FE2C", "1812"])
        #expect(p.serviceData == [
            ServiceDataRecord(uuid: "FEAA", dataHex: "10C501"),
            ServiceDataRecord(uuid: "FD5A1234", dataHex: "01"),
            ServiceDataRecord(uuid: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E", dataHex: "AABB"),
        ])
        // Byte layout: name first, as a complete local name.
        #expect(bytes[1] == 0x09)
        // Facts merge mirrors Android: scan TX beats advertised TX.
        let facts = BleAdParser.facts(parsed: p, connectable: true, txPowerFromScan: 4)
        #expect(facts.txPowerDbm == 4)
        #expect(facts.connectable == true)
        #expect(BleAdParser.facts(parsed: p, connectable: nil, txPowerFromScan: nil).txPowerDbm == -8)
    }

    @Test func buildAdvertisementEmptyInputIsEmpty() {
        let bytes = BleAdParser.buildAdvertisement(localName: nil, manufacturerData: nil, serviceUuids: [], serviceData: [], txPower: nil)
        #expect(bytes.isEmpty)
        #expect(BleAdParser.parse(bytes: bytes) == BleAdParser.Parsed())
    }

    @Test func buildAdvertisementSkipsJunkUuids() {
        let bytes = BleAdParser.buildAdvertisement(localName: nil, manufacturerData: nil, serviceUuids: ["not-a-uuid", "ABC"],
                                                   serviceData: [(uuid: "zz", data: [1])], txPower: nil)
        #expect(bytes.isEmpty)
    }

    @Test func buildAdvertisementTruncatesOversizedFields() {
        let longName = String(repeating: "é", count: 300) // 600 UTF-8 bytes
        let bigMfg = [UInt8](repeating: 0x11, count: 400)
        let manyUuids = (0..<200).map { hexN($0, 4) }
        let bytes = BleAdParser.buildAdvertisement(
            localName: longName, manufacturerData: bigMfg, serviceUuids: manyUuids,
            serviceData: [(uuid: "FEAA", data: [UInt8](repeating: 0x22, count: 300))], txPower: 500
        )
        // Walk the AD structures: every length byte fits and the walk lands exactly on the end.
        var i = 0
        var count = 0
        while i < bytes.count {
            let len = Int(bytes[i])
            #expect(len >= 1)
            i += len + 1
            count += 1
        }
        #expect(i == bytes.count)
        #expect(count == 5)
        let p = BleAdParser.parse(bytes: bytes)
        #expect(p.localName == String(repeating: "é", count: 48)) // parse keeps 48 characters
        #expect(p.mfg.first?.dataHex.count == 252 * 2)
        #expect(p.uuids.count == 127)
        #expect(p.serviceData.first?.dataHex.count == 252 * 2)
        #expect(p.txPower == 127)
    }
}
