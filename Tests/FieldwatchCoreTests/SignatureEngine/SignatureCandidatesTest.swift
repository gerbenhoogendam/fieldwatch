import Foundation
import Testing
@testable import FieldwatchCore

// Port of SignatureCandidatesTest.kt.

private func edited<T>(_ value: T, _ edit: (inout T) -> Void) -> T {
    var v = value
    edit(&v)
    return v
}

private func wifi(
    _ mac: String,
    _ name: String,
    vendor: String? = "Acme",
    ies: [String] = []
) -> LogRadio {
    LogRadio(
        kind: .wifi,
        mac: MacUtil.normalize(raw: mac),
        name: name,
        vendor: vendor,
        manufacturerId: nil,
        manufacturerDataHex: "",
        serviceUuids: [],
        vendorIeOuis: ies,
        randomized: MacUtil.isRandomized(mac: mac),
        hiddenSsid: name.isEmpty,
        rssi: -40,
        firstSeen: 1,
        lastSeen: 1,
        hits: 3
    )
}

private func ble(_ mac: String, _ name: String) -> LogRadio {
    LogRadio(
        kind: .ble,
        mac: MacUtil.normalize(raw: mac),
        name: name,
        vendor: nil,
        manufacturerId: nil,
        manufacturerDataHex: "",
        serviceUuids: [],
        vendorIeOuis: [],
        randomized: MacUtil.isRandomized(mac: mac),
        hiddenSsid: false,
        rssi: -50,
        firstSeen: 1,
        lastSeen: 1,
        hits: 2
    )
}

private extension LogRadio {
    func toSighting() -> Sighting {
        Sighting(
            key: key,
            kind: kind,
            mac: mac,
            name: name,
            rssi: rssi,
            rssiMin: rssi,
            rssiMax: rssi,
            channel: 1,
            frequencyMhz: 2412,
            vendor: vendor,
            randomized: randomized,
            hiddenSsid: hiddenSsid,
            serviceUuids: serviceUuids,
            manufacturerId: manufacturerId,
            manufacturerDataHex: manufacturerDataHex,
            rawHex: manufacturerDataHex,
            extras: "",
            firstSeen: firstSeen,
            lastSeen: lastSeen,
            hitCount: hits,
            fleetIds: [],
            rssiHistory: [],
            presence: [],
            vendorIeOuis: vendorIeOuis
        )
    }
}

/// "00:11:22:33:44:%02X" and "H2O-%012x" rows used by the family-hint tests.
private func h2oRow(_ i: Int) -> LogRadio {
    wifi("00:11:22:33:44:" + hex2(i), "H2O-" + format("%012lx", i))
}

@Suite struct SignatureCandidatesTest {
    private let engine = SignatureEngine()

    @Test func nameGlobHexRunBecomesQuestionMarks() {
        #expect(SignatureCandidates.nameGlobOf(name: "H2O-047bcbd11400") == "H2O-????????????")
        #expect(SignatureCandidates.nameGlobOf(name: "H2O-0a1c8e22b400") == "H2O-????????????")
        #expect(SignatureCandidates.nameGlobOf(name: "RG3100-7A21") == "RG3100*")
        #expect(SignatureCandidates.nameGlobOf(name: "RG3100-8434 guest") == "RG3100*")
        #expect(SignatureCandidates.nameGlobOf(name: "[fridge]_E30AJT5133207Z SJIT") == "[fridge]*")
        #expect(SignatureCandidates.nameGlobOf(name: "IonCannon") == nil)
        #expect(SignatureCandidates.nameGlobOf(name: "Jameson") == nil)
        #expect(SignatureCandidates.nameGlobOf(name: "DIRECT-roku-living") == nil)
        #expect(SignatureCandidates.nameGlobOf(name: "LOB_Guest_wifi") == nil)
    }

    @Test func houseLikeNames() {
        #expect(SignatureCandidates.isHouseLikeName(name: "IonCannon"))
        #expect(SignatureCandidates.isHouseLikeName(name: "Jameson"))
        #expect(SignatureCandidates.isHouseLikeName(name: "LOB_Guest"))
        #expect(SignatureCandidates.isHouseLikeName(name: "ATT-GUEST-lobby"))
        #expect(!SignatureCandidates.isHouseLikeName(name: "H2O-047bcbd11400"))
        #expect(!SignatureCandidates.isHouseLikeName(name: "RG3100-7A21"))
        #expect(!SignatureCandidates.isHouseLikeName(name: "[fridge]_E30AJT5133207Z"))
    }

    @Test func hexNameGlobClusterOnTwoStableAps() throws {
        let a = wifi("00:11:22:33:44:55", "H2O-047bcbd11400")
        let b = wifi("00:11:22:33:44:66", "H2O-0a1c8e22b400")
        let report = SignatureCandidates.analyze(radios: [a, b], fleets: [], engine: engine)
        #expect(report.families.count == 1)
        let hit = try #require(report.families.first)
        #expect(hit.proposedName == "H2O")
        #expect(hit.distinctRadios == 2)
        #expect(hit.rules.first?.kind == .nameGlob)
        #expect(hit.rules.first?.text == "H2O-????????????")
        #expect(hit.rules.first?.radio == .wifi)
        #expect(!hit.rules.contains { $0.kind == .macPrefix })
        #expect(hit.why.contains("not a house", ignoreCase: true))
    }

    @Test func singleRadioIsNotAFamily() {
        let a = wifi("00:11:22:33:44:55", "H2O-047bcbd11400")
        let report = SignatureCandidates.analyze(radios: [a], fleets: [], engine: engine)
        #expect(report.families.isEmpty)
        #expect(report.skippedOther == 1)
    }

    @Test func houseNamesAndRandomizedWithoutIdAreSkipped() {
        let house = wifi("9C:4F:5F:11:22:33", "Jameson")
        let guest = wifi("00:11:22:33:44:01", "LOB_Guest")
        let rand = edited(wifi("CE:BE:8F:24:DC:E3", "IonCannon")) { $0.randomized = true }
        let unnamed = edited(ble("F2:11:22:33:44:55", "")) { $0.randomized = true }
        let report = SignatureCandidates.analyze(radios: [house, guest, rand, unnamed], fleets: [], engine: engine)
        #expect(report.families.isEmpty)
        #expect(report.skippedRandomized + report.skippedHouseLike + report.skippedOther >= 3)
    }

    @Test func vendorIeClusterIgnoresProtocolIes() throws {
        let a = edited(wifi("F2:11:22:33:44:01", "", ies: ["00:50:F2", "C8:3A:6B"])) { $0.randomized = true }
        let b = edited(wifi("F2:11:22:33:44:02", "", ies: ["00:0F:AC", "C8:3A:6B"])) { $0.randomized = true }
        let proto = wifi("00:11:22:33:44:10", "Cafe", ies: ["00:50:F2", "00:0F:AC"])
        let proto2 = wifi("00:11:22:33:44:11", "Shop", ies: ["00:50:F2"])
        let report = SignatureCandidates.analyze(radios: [a, b, proto, proto2], fleets: [], engine: engine)
        #expect(report.families.count == 1)
        let hit = try #require(report.families.first)
        #expect(hit.rules.first?.kind == .vendorIeOui)
        #expect(hit.rules.first?.text.contains("C8:3A:6B", ignoreCase: true) == true)
        #expect(hit.distinctRadios == 2)
    }

    @Test func chipModuleOuiIsNotAFamily() {
        let a = wifi("3C:71:BF:11:22:33", "setup1", vendor: "Espressif Inc.")
        let b = wifi("3C:71:BF:11:22:44", "setup2", vendor: "Espressif Inc.")
        let report = SignatureCandidates.analyze(radios: [a, b], fleets: [], engine: engine)
        #expect(report.families.allSatisfy { !$0.rules.contains { r in r.kind == .oui } })
    }

    @Test func stockCatalogMatchDropsAlreadyTaggedRadios() throws {
        let h2o = wifi("00:11:22:33:44:55", "H2O-047bcbd11400")
        let h2o2 = wifi("00:11:22:33:44:66", "H2O-0a1c8e22b400")
        let novelA = wifi("00:AA:BB:11:22:33", "XYZMODEM-1111")
        let novelB = wifi("00:AA:BB:11:22:44", "XYZMODEM-2222")
        let stock = DefaultCatalog.fleets()
        let report = SignatureCandidates.analyze(radios: [h2o, h2o2, novelA, novelB], fleets: stock, engine: engine)
        #expect(report.families.allSatisfy { !$0.rules.contains { r in r.text.hasPrefix("H2O") } })
        #expect(report.families.count == 1)
        let novel = try #require(report.families.first)
        #expect(novel.rules.contains { $0.kind == .nameGlob && $0.text == "XYZMODEM*" })
    }

    @Test func familyHintStrongOnManyNameGlobs() {
        let radios = (0..<10).map { h2oRow($0) }
        let device = radios[0].toSighting()
        let hint = SignatureCandidates.assessFamily(device: device, live: [device], log: radios, fleets: [])
        #expect(hint.verdict == .strong)
        #expect(hint.logCount == 10)
        #expect(hint.liveCount == 1)
        #expect(hint.displayCount == 10)
        #expect(hint.title == "Strong family")
        #expect(hint.body.contains("catalog pattern"))
        #expect(hint.ruleLabel?.hasPrefix("H2O-") == true)
    }

    @Test func familyHintPossibleOnTwo() {
        let a = wifi("00:11:22:33:44:55", "H2O-047bcbd11400")
        let b = wifi("00:11:22:33:44:66", "H2O-0a1c8e22b400")
        let device = a.toSighting()
        let hint = SignatureCandidates.assessFamily(device: device, live: [device], log: [a, b], fleets: [])
        #expect(hint.verdict == .possible)
        #expect(hint.logCount == 2)
        #expect(hint.title == "Possible family")
    }

    @Test func familyHintSingleWhenAlone() {
        let a = wifi("00:11:22:33:44:55", "H2O-047bcbd11400")
        let device = a.toSighting()
        let hint = SignatureCandidates.assessFamily(device: device, live: [device], log: [a], fleets: [])
        #expect(hint.verdict == .single)
        #expect(hint.title == "This radio only")
        #expect(hint.displayCount == 0)
        #expect(hint.body.contains("this address", ignoreCase: true))
    }

    @Test func familyHintTaggedSkipsSiblingCount() throws {
        let radios = (0..<10).map { h2oRow($0) }
        let fleet = try #require(DefaultCatalog.fleets().first)
        let device = edited(radios[0].toSighting()) { $0.fleetIds = [fleet.id] }
        let hint = SignatureCandidates.assessFamily(device: device, live: [device], log: radios, fleets: [fleet])
        #expect(hint.verdict == .tagged)
        #expect(hint.displayCount == 0)
        #expect(hint.body.contains(fleet.name))
        #expect(hint.body.contains("second signature", ignoreCase: true))
    }

    @Test func familyHintIgnoresBroadCompanyCrowd() {
        let radios = (0..<12).map { i in
            edited(ble("F2:11:22:33:44:" + hex2(i), "")) {
                $0.manufacturerId = 0x004C
                $0.manufacturerDataHex = "10AB"
                $0.randomized = true
            }
        }
        let device = radios[0].toSighting()
        let hint = SignatureCandidates.assessFamily(device: device, live: [device], log: radios, fleets: [])
        #expect(hint.verdict == .single)
        #expect(hint.ruleLabel == nil)
    }

    @Test func familyHintIgnoresChipOuiCrowd() {
        let radios = (0..<12).map { i in
            wifi("3C:71:BF:11:22:" + hex2(i), "setup\(i)", vendor: "Espressif Inc.")
        }
        let device = radios[0].toSighting()
        let hint = SignatureCandidates.assessFamily(device: device, live: [device], log: radios, fleets: [])
        #expect(hint.verdict == .single)
    }

    @Test func familyHintCountsLiveWhenLogEmpty() {
        let live = (0..<8).map { h2oRow($0).toSighting() }
        let hint = SignatureCandidates.assessFamily(device: live[0], live: live, log: [], fleets: [])
        #expect(hint.verdict == .strong)
        #expect(hint.logCount == 0)
        #expect(hint.liveCount == 8)
        #expect(hint.displayCount == 8)
        #expect(hint.body.contains("on the air now"))
    }

    @Test func suggestFleetHasNoMacRule() throws {
        let a = wifi("00:11:22:33:44:55", "H2O-047bcbd11400")
        let b = wifi("00:11:22:33:44:66", "H2O-0a1c8e22b400")
        let cand = try #require(SignatureCandidates.analyze(radios: [a, b], fleets: [], engine: engine).families.first)
        let fleet = SignatureCandidates.suggestFleet(candidate: cand)
        #expect(!fleet.rules.contains { $0.kind == .macPrefix })
        #expect(!fleet.builtIn)
        #expect(fleet.kind == .home)
        #expect(engine.match(devices: [a.toSighting(), b.toSighting()], fleets: [fleet]).values.allSatisfy {
            cand.proposedName.contains("H2O") || $0.contains(fleet.id)
        })
        let hits = engine.match(devices: [a.toSighting(), b.toSighting()], fleets: [fleet])
        #expect(hits[a.key]?.contains(fleet.id) == true)
        #expect(hits[b.key]?.contains(fleet.id) == true)
    }

    @Test func logReplayParsesOldAndNewCsv() throws {
        let old = """
            timestamp,iso,kind,mac,name,rssi,channel,freq,oui,vendor,fleets,mfg,uuids,flags,raw,lat,lon
            1,2026-08-31T12:00:00.000Z,WIFI,00:11:22:33:44:55,H2O-047bcbd11400,-50,1,2412,00:11:22,Acme,, ,,,,-40.0,-80.0
            """
        let oldRadios = LogReplay.parse(text: old)
        #expect(oldRadios.count == 1)
        let oldOne = try #require(oldRadios.first)
        #expect(oldOne.name == "H2O-047bcbd11400")
        #expect(oldOne.vendorIeOuis.isEmpty)

        let header = [
            "timestamp", "iso", "kind", "mac", "name", "rssi", "channel", "freq",
            "oui", "vendor", "fleets", "mfg", "uuids", "flags", "raw", "lat", "lon", "vendor_ie",
        ]
        let newRow = [
            "1", "2026-08-31T12:00:00.000Z", "WIFI", "F2:11:22:33:44:01", "Roku-living",
            "-40", "1", "2412", "F2:11:22", "", "", "", "", "RAND", "", "40.0", "-80.0",
            "C8:3A:6B|00:50:F2",
        ]
        let new = header.joined(separator: ",") + "\n" + newRow.joined(separator: ",")
        let newRadios = LogReplay.parse(text: new)
        #expect(newRadios.count == 1)
        let newOne = try #require(newRadios.first)
        #expect(newOne.randomized)
        #expect(
            newOne.vendorIeOuis.contains { $0.contains("C8:3A:6B", ignoreCase: true) },
            "ies=\(newOne.vendorIeOuis) rand=\(newOne.randomized) flags-name=\(newOne.name)"
        )
    }

    @Test func logReplayAggregatesHitsAndMergesIes() throws {
        let csv = """
            timestamp,iso,kind,mac,name,rssi,channel,freq,oui,vendor,fleets,mfg,uuids,flags,raw,lat,lon,vendor_ie
            1,t,WIFI,00:11:22:33:44:55,H2O-047bcbd11400,-60,1,2412,00:11:22,,,,,,,,
            2,t,WIFI,00:11:22:33:44:55,H2O-047bcbd11400,-50,1,2412,00:11:22,,,,,,,,,C8:3A:6B
            """
        let radios = LogReplay.parse(text: csv)
        #expect(radios.count == 1)
        let one = try #require(radios.first)
        #expect(one.hits == 2)
        #expect(one.rssi == -50)
        #expect(one.vendorIeOuis.contains { $0.contains("C8:3A:6B", ignoreCase: true) })
    }
}
