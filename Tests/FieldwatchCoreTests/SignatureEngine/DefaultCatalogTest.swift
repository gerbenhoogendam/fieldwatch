import Foundation
import Testing
@testable import FieldwatchCore

// Port of DefaultCatalogTest.kt.

private func edited<T>(_ value: T, _ edit: (inout T) -> Void) -> T {
    var v = value
    edit(&v)
    return v
}

/// Kotlin `getValue(key)`: the key must be present.
private func ids(_ hits: [String: [String]], _ radio: Sighting) -> [String] {
    #expect(hits[radio.key] != nil, "no match entry for \(radio.key)")
    return hits[radio.key] ?? []
}

private func ble(
    name: String = "",
    manufacturerId: Int? = nil,
    manufacturerDataHex: String = "",
    serviceUuids: [String] = []
) -> Sighting {
    Sighting(
        key: "BLE:AA:BB:CC:DD:EE:FF",
        kind: .ble,
        mac: "AA:BB:CC:DD:EE:FF",
        name: name,
        rssi: -50,
        rssiMin: -50,
        rssiMax: -50,
        channel: 0,
        frequencyMhz: 0,
        vendor: nil,
        randomized: true,
        hiddenSsid: false,
        serviceUuids: serviceUuids,
        manufacturerId: manufacturerId,
        manufacturerDataHex: manufacturerDataHex,
        rawHex: "",
        extras: "",
        firstSeen: 1,
        lastSeen: 1,
        hitCount: 1,
        fleetIds: [],
        rssiHistory: [],
        presence: [],
        facts: RadioFacts(
            mfgRecords: manufacturerId.map { [MfgRecord(companyId: $0, dataHex: manufacturerDataHex)] } ?? []
        )
    )
}

private func tagged(_ tail: String, _ name: String, _ manufacturerId: Int?) -> Sighting {
    edited(ble(name: name, manufacturerId: manufacturerId)) {
        $0.key = "BLE:\(tail)"
        $0.mac = "AA:BB:CC:DD:EE:\(tail)"
    }
}

private func wifi(_ mac: String, _ name: String = "Home", _ vendorIe: String? = nil) -> Sighting {
    edited(ble(name: name)) {
        $0.key = "WIFI:\(mac)"
        $0.kind = .wifi
        $0.mac = mac
        $0.randomized = false
        $0.vendorIeOuis = vendorIe.map { [$0] } ?? []
    }
}

private func stockFleet(_ id: String) -> Fleet { DefaultCatalog.fleets().single { $0.id == id } }

private func ouiSet(_ fleet: Fleet) -> Set<String> {
    Set(fleet.rules.filter { $0.kind == .oui }.map { $0.text.uppercased() })
}

private func watchedIds() -> Set<String> { Set(DefaultCatalog.defaultWatchlist().compactMap { $0.fleetId }) }

@Suite struct DefaultCatalogTest {
    @Test func stockCatalogDoesNotShipUnknownSignature() {
        #expect(!DefaultCatalog.fleets().contains { $0.id == "fleet-unknown" })
        #expect(!DefaultCatalog.fleets().contains { $0.name.equals("Unknown Signature", ignoreCase: true) })
    }

    @Test func stockNotesDoNotSayShipsOn() {
        for fleet in DefaultCatalog.fleets() {
            #expect(!fleet.notes.contains("Ships on", ignoreCase: true), "\(fleet.name) notes still mention Ships on: \(fleet.notes)")
        }
    }

    @Test func ibeaconNoteKeepsMallAdvice() {
        let note = stockFleet("fleet-ibeacon").notes
        #expect(note.contains("Mute in a dense mall."))
        #expect(!note.contains("Ships on"))
        #expect(note.contains("proximity beacon", ignoreCase: true))
    }

    @Test func stockNotesExplainTheFamilyNotTheMatcher() {
        for fleet in DefaultCatalog.fleets() {
            #expect(fleet.notes.isNotBlank, "\(fleet.name) has empty notes")
            #expect(!KRegex("0x[0-9A-Fa-f]{2,}").containsMatchIn(fleet.notes),
                    "\(fleet.name) notes still look like matcher copy: \(fleet.notes)")
        }
        let oura = stockFleet("fleet-oura").notes
        #expect(oura.contains("ring", ignoreCase: true), "\(oura)")
    }

    @Test func flockAndFsExtDropEspressifAndSilabsOuis() {
        let flock = stockFleet("fleet-flock-cameras")
        let fs = stockFleet("fleet-fs-ext-battery")
        let flockOuis = ouiSet(flock)
        let fsOuis = ouiSet(fs)
        #expect(!flockOuis.contains("A4:CF:12"))
        #expect(!flockOuis.contains("3C:71:BF"))
        #expect(!flockOuis.contains("E0:4F:43"))
        #expect(!flockOuis.contains("70:C9:4E"))
        #expect(flockOuis.contains("B4:1E:52"))
        let lite = stockFleet("fleet-liteon-camera-radio")
        let liteOuis = ouiSet(lite)
        #expect(liteOuis.contains("70:C9:4E"))
        #expect(!liteOuis.contains("E0:4F:43"))
        #expect(!liteOuis.contains("B4:1E:52"))
        #expect(lite.attentionNote.isBlank)
        #expect(lite.kind == .camera)
        #expect(!fsOuis.contains("90:35:EA"))
        #expect(!fsOuis.contains("58:8E:81"))
        #expect(!fsOuis.contains("EC:1B:BD"))
    }

    @Test func catalogV77AddsGlassesAndAxonUuids() {
        let axon = stockFleet("fleet-axon")
        let meta = stockFleet("fleet-meta-glasses")
        let snap = stockFleet("fleet-snap-spectacles")
        let vuzix = stockFleet("fleet-vuzix")
        let rid = stockFleet("fleet-remote-id")
        #expect(axon.rules.contains { $0.kind == .serviceUuid && $0.text.equals("FC81", ignoreCase: true) })
        #expect(axon.rules.contains { $0.kind == .manufacturerId && $0.companyId == 0x034D })
        #expect(meta.rules.contains { $0.kind == .serviceUuid && $0.text.equals("FEB7", ignoreCase: true) })
        #expect(snap.rules.contains { $0.kind == .serviceUuid && $0.text.equals("FE45", ignoreCase: true) })
        #expect(vuzix.rules.contains { $0.kind == .manufacturerId && $0.companyId == 0x060C })
        #expect(rid.rules.contains { $0.kind == .vendorIeOui && $0.text.equals("FA:0B:BC", ignoreCase: true) })
    }

    @Test func findHubMatchesSeparatedFrameNotEddystoneUid() {
        let stock = DefaultCatalog.fleets()
        let engine = SignatureEngine()
        let eid = "11".repeated(20)
        let hub = edited(ble(name: "", serviceUuids: ["FEAA"])) {
            $0.facts = RadioFacts(serviceData: [ServiceDataRecord(uuid: "FEAA", dataHex: "41\(eid)" + "00")])
        }
        let uid = edited(ble(name: "", serviceUuids: ["FEAA"])) {
            $0.facts = RadioFacts(serviceData: [ServiceDataRecord(uuid: "FEAA", dataHex: "00C5" + "11".repeated(10) + "22".repeated(6))])
        }
        #expect(ids(engine.match(devices: [hub], fleets: stock), hub).contains("fleet-find-hub"), "Find Hub")
        #expect(!ids(engine.match(devices: [uid], fleets: stock), uid).contains("fleet-find-hub"), "Eddystone-UID is not Find Hub")
    }

    @Test func dultMatchesFcb2ServiceDataNotUuidList() {
        let stock = DefaultCatalog.fleets()
        let engine = SignatureEngine()
        let taggedRadio = edited(ble(name: "", serviceUuids: ["FCB2"])) {
            $0.facts = RadioFacts(serviceData: [ServiceDataRecord(uuid: "FCB2", dataHex: "0100")])
        }
        let uuidOnly = ble(name: "", serviceUuids: ["FCB2"])
        let hub = edited(ble(name: "", serviceUuids: ["FEAA"])) {
            $0.facts = RadioFacts(serviceData: [ServiceDataRecord(uuid: "FEAA", dataHex: "41" + "11".repeated(20))])
        }
        #expect(ids(engine.match(devices: [taggedRadio], fleets: stock), taggedRadio).contains("fleet-dult"), "DULT")
        #expect(!ids(engine.match(devices: [uuidOnly], fleets: stock), uuidOnly).contains("fleet-dult"), "UUID list is not DULT")
        #expect(!ids(engine.match(devices: [hub], fleets: stock), hub).contains("fleet-dult"), "Find Hub is not DULT")
        #expect(ids(engine.match(devices: [hub], fleets: stock), hub).contains("fleet-find-hub"), "Find Hub still matches")
        let fleet = stock.single { $0.id == "fleet-dult" }
        #expect(fleet.kind == .finder)
        #expect(fleet.attentionNote.isBlank)
    }

    @Test func aftermarketTpmsMatchesPrefixAndNameNotBareNokia() {
        let stock = DefaultCatalog.fleets()
        let engine = SignatureEngine()
        let cap = ble(
            name: "TPMS1_A1B2",
            manufacturerId: 0x0001,
            manufacturerDataHex: "80EACA108A78E36D0000E60A00005B00",
            serviceUuids: ["FBB0"]
        )
        let hits = ids(engine.match(devices: [cap], fleets: stock), cap)
        #expect(hits.contains("fleet-tpms-ble"), "aftermarket TPMS")
        #expect(!hits.contains("fleet-tesla-tstpms"), "not Tesla tsTPMS")

        let nokia = ble(name: "", manufacturerId: 0x0001, manufacturerDataHex: "010103215D64")
        let nokiaHits = ids(engine.match(devices: [nokia], fleets: stock), nokia)
        #expect(!nokiaHits.contains("fleet-tpms-ble"), "bare Nokia 0x0001 is not aftermarket TPMS")

        let teslaTire = ble(name: "tsTPMS")
        let teslaHits = ids(engine.match(devices: [teslaTire], fleets: stock), teslaTire)
        #expect(teslaHits.contains("fleet-tesla-tstpms"), "Tesla tsTPMS")
        #expect(!teslaHits.contains("fleet-tpms-ble"), "tsTPMS is not Aftermarket TPMS")
    }

    @Test func sytpmsMatchesBrNameAndPressureUuidNotBrother() {
        let stock = DefaultCatalog.fleets()
        let engine = SignatureEngine()
        let sensor = ble(name: "BR", serviceUuids: ["27A5"])
        #expect(ids(engine.match(devices: [sensor], fleets: stock), sensor).contains("fleet-sytpms"), "SYTPMS")

        let printer = ble(name: "Brother Printer")
        #expect(!ids(engine.match(devices: [printer], fleets: stock), printer).contains("fleet-sytpms"), "BR contains is not used")
    }

    @Test func foboMatchesServiceUuid() {
        let stock = DefaultCatalog.fleets()
        let sensor = ble(name: "", serviceUuids: ["00EE"])
        #expect(ids(SignatureEngine().match(devices: [sensor], fleets: stock), sensor).contains("fleet-fobo"), "FOBO")
    }

    @Test func aftermarketTpmsDoesNotUseBareNokiaCompanyId() {
        let fleet = stockFleet("fleet-tpms-ble")
        #expect(!fleet.rules.contains { $0.kind == .manufacturerId && $0.companyId == 0x0001 })
        #expect(fleet.rules.contains { $0.kind == .manufacturerData && $0.companyId == 0x0001 })
        #expect(fleet.decode != nil)
    }

    @Test func signatureNotesAreSeparateFromExtraAttention() {
        let oura = stockFleet("fleet-oura")
        let axon = stockFleet("fleet-axon")
        let device = edited(ble()) { $0.fleetIds = [oura.id, axon.id] }
        let notes = device.signatureNotes(fleets: [oura, axon])
        let attention = device.attentionNotes(fleets: [oura, axon])
        #expect(oura.notes.isNotBlank)
        #expect(notes.contains { $0.0 == oura.name && $0.1 == oura.notes })
        #expect(notes.contains { $0.0 == axon.name && $0.1 == axon.notes })
        #expect(attention.map { $0.0 } == [axon.name])
        #expect(!attention.contains { $0.0 == oura.name })
        let dump = DeviceDetailText.build(
            device: device,
            signatureNames: [oura.name, axon.name],
            now: 1,
            attentionNotes: attention,
            signatureNotes: notes,
            fleets: [oura, axon]
        )
        #expect(dump.contains("## Notes"))
        #expect(dump.contains(oura.notes))
        #expect(dump.contains("EXTRA ATTENTION (\(axon.name))"))
        #expect(!dump.contains("EXTRA ATTENTION (\(oura.name))"))
    }

    @Test func catalog89RayNeoRequiresNameAndTclEvenOrsCompanyIdLiteOnStaysQuiet() {
        let stock = DefaultCatalog.fleets()
        let engine = SignatureEngine()
        let ray = stock.single { $0.id == "fleet-rayneo" }
        let even = stock.single { $0.id == "fleet-even-g1" }
        let lite = stock.single { $0.id == "fleet-liteon-camera-radio" }
        let flock = stock.single { $0.id == "fleet-flock-cameras" }

        #expect(!ray.matchAny)
        #expect(stock.filter { !$0.matchAny }.map { $0.id } == ["fleet-rayneo"])
        #expect(ray.kind == .glasses)
        #expect(ray.attentionNote.isNotBlank)
        #expect(ray.rules.single { $0.kind == .manufacturerId }.companyId == 0x0BC6)
        #expect(ray.rules.single { $0.kind == .nameGlob }.text == "RayNeo*")
        #expect(ray.rules.count == 2)
        #expect(even.matchAny)
        #expect(even.rules.contains { $0.kind == .manufacturerId && $0.companyId == 0x10F9 })
        #expect(even.rules.contains { $0.kind == .nameContains && $0.text == "Even G1" })
        #expect(!even.notes.contains("Name-only", ignoreCase: true))
        let liteOuis = ouiSet(lite)
        #expect(liteOuis.contains("E0:0A:F6"))
        #expect(liteOuis.contains("14:B5:CD"))
        #expect(liteOuis.contains("08:3A:88"))
        #expect(lite.attentionNote.isBlank)
        #expect(lite.kind == .camera)
        let watched = watchedIds()
        #expect(watched.contains("fleet-rayneo"))
        #expect(watched.contains("fleet-even-g1"))
        #expect(!watched.contains("fleet-liteon-camera-radio"))
        #expect(!stock.contains { fleet in
            fleet.rules.contains { rule in
                rule.kind == .manufacturerId && [0x07D7, 0x0BA7, 0xFD5F].contains(rule.companyId)
            }
        })
        #expect(!stock.contains { fleet in
            fleet.rules.contains { rule in
                rule.text.contains("FlockCam", ignoreCase: true) ||
                    rule.text.contains("RWLS", ignoreCase: true) ||
                    rule.text.contains("META_RB", ignoreCase: true) ||
                    rule.text.equals("Pico", ignoreCase: true)
            }
        })
        #expect(!flock.rules.contains { $0.kind == .nameContains && $0.text == "Flock" })
        #expect(flock.rules.contains { $0.kind == .nameGlob && $0.text == "Flock-*" })

        let both = tagged("01", "RayNeo Air 2", 0x0BC6)
        let bare = tagged("02", "RayNeo", 0x0BC6)
        let lower = tagged("03", "rayneo", 0x0BC6)
        let nameOnly = tagged("04", "RayNeo Air 2", nil)
        let tclOnly = tagged("05", "TCL 50", 0x0BC6)
        let midName = tagged("06", "My RayNeo", 0x0BC6)
        let qinheng = tagged("07", "RayNeo", 0x07D7)
        let hearx = tagged("08", "RayNeo", 0x0BA7)
        let evenId = tagged("09", "", 0x10F9)
        let evenName = tagged("0A", "Even G1", nil)
        let uart = edited(ble(name: "", serviceUuids: ["6E400001-B5A3-F393-E0A9-E50E24DCCA9E"])) {
            $0.key = "BLE:0B"
            $0.mac = "AA:BB:CC:DD:EE:0B"
        }
        let liteA = wifi("E0:0A:F6:11:22:33")
        let liteB = wifi("14:B5:CD:11:22:33")
        let flockCam = wifi("02:11:22:33:44:55", "FlockCam-9")
        let rwls = wifi("02:11:22:33:44:56", "RWLS-1")
        let hits = engine.match(
            devices: [
                both, bare, lower, nameOnly, tclOnly, midName, qinheng, hearx,
                evenId, evenName, uart, liteA, liteB, flockCam, rwls,
            ],
            fleets: stock
        )
        #expect(ids(hits, both).contains("fleet-rayneo"), "name and TCL id")
        #expect(ids(hits, bare).contains("fleet-rayneo"), "bare RayNeo")
        #expect(ids(hits, lower).contains("fleet-rayneo"), "lowercase rayneo")
        #expect(!ids(hits, nameOnly).contains("fleet-rayneo"), "name only")
        #expect(!ids(hits, tclOnly).contains("fleet-rayneo"), "TCL phone")
        #expect(!ids(hits, midName).contains("fleet-rayneo"), "name not at the start")
        #expect(!ids(hits, qinheng).contains("fleet-rayneo"), "Qinheng id")
        #expect(!ids(hits, hearx).contains("fleet-rayneo"), "hearX id")
        #expect(ids(hits, evenId).contains("fleet-even-g1"), "Even company id")
        #expect(!ids(hits, evenId).contains("fleet-rayneo"), "Even id is not RayNeo")
        #expect(ids(hits, evenName).contains("fleet-even-g1"), "Even name")
        #expect(!ids(hits, uart).contains("fleet-even-g1"), "Nordic UART")
        #expect(ids(hits, liteA).contains("fleet-liteon-camera-radio"), "E0:0A:F6")
        #expect(!ids(hits, liteA).contains("fleet-flock-cameras"), "E0:0A:F6 is not Flock")
        #expect(ids(hits, liteB).contains("fleet-liteon-camera-radio"), "14:B5:CD")
        #expect(!ids(hits, liteB).contains("fleet-flock-cameras"), "14:B5:CD is not Flock")
        #expect(!ids(hits, flockCam).contains("fleet-flock-cameras"), "FlockCam is not Flock-")
        #expect(!ids(hits, rwls).contains("fleet-flock-cameras"), "RWLS is not Flock")
        #expect(edited(liteA) { $0.fleetIds = ids(hits, liteA) }.attentionNotes(fleets: stock).isEmpty)
    }

    @Test func catalog90FrenchPlateAndNamedDronesStayNarrow() {
        let stock = DefaultCatalog.fleets()
        let engine = SignatureEngine()
        let added = [
            "fleet-tello", "fleet-potensic", "fleet-holystone", "fleet-hubsan",
            "fleet-yuneec", "fleet-swellpro", "fleet-crazyflie",
        ]
        let watched = watchedIds()
        for id in added {
            let fleet = stock.single { $0.id == id }
            #expect(fleet.kind == .drone, "\(id)")
            #expect(fleet.matchAny)
            #expect(fleet.attentionNote.isBlank)
            #expect(watched.contains(id))
        }
        let remote = stock.single { $0.id == "fleet-remote-id" }
        #expect(remote.rules.contains { $0.kind == .vendorIeOui && $0.text.equals("6A:5C:35", ignoreCase: true) })
        #expect(remote.rules.contains { $0.kind == .vendorIeOui && $0.text.equals("FA:0B:BC", ignoreCase: true) })
        let crazy = stock.single { $0.id == "fleet-crazyflie" }
        #expect(!crazy.rules.contains { $0.kind == .manufacturerId })
        #expect(stock.single { $0.id == "fleet-parrot" }.rules.contains {
            $0.kind == .nameGlob && $0.text == "Skycontroller*"
        })

        let french = wifi("02:00:00:00:00:01", "RID", "6A:5C:35")
        let astm = wifi("02:00:00:00:00:02", "RID", "FA:0B:BC")
        let nan = wifi("02:00:00:00:00:03", "RID", "50:6F:9A")
        let parrotOui = wifi("90:3A:E6:11:22:33", "Home")
        let tello = wifi("02:00:00:00:00:11", "TELLO-ABCDEF")
        let talent = wifi("02:00:00:00:00:12", "RMTT-9AFF2A")
        let telloMid = wifi("02:00:00:00:00:13", "my TELLO")
        let dji = wifi("02:00:00:00:00:14", "DJI-Mini")
        let potensic = wifi("02:00:00:00:00:21", "Potensic-ATOM-1")
        let atom = wifi("02:00:00:00:00:22", "ATOM-1")
        let holy = wifi("02:00:00:00:00:31", "HolyStoneFPV-1")
        let holySpaced = wifi("02:00:00:00:00:32", "Holy Stone HS720")
        let fpv = wifi("02:00:00:00:00:33", "FPV_WIFI")
        let hubsan = wifi("02:00:00:00:00:41", "HUBSAN-Zino")
        let exo = wifi("02:00:00:00:00:42", "EXO-1234")
        let yuneec = wifi("02:00:00:00:00:51", "Yuneec-H520")
        let typhoon = wifi("02:00:00:00:00:52", "Typhoon")
        let swell = wifi("02:00:00:00:00:61", "SwellPro-Splash")
        let crazyName = wifi("02:00:00:00:00:71", "Crazyflie")
        let bitcraze = tagged("81", "", 0x01C5)
        let sky = wifi("02:00:00:00:00:91", "Skycontroller 3")
        let autelSsid = wifi("02:00:00:00:00:A1", "default-ssid")
        let elrs = wifi("02:00:00:00:00:A2", "ExpressLRS")
        let radios = [
            french, astm, nan, parrotOui, tello, talent, telloMid, dji,
            potensic, atom, holy, holySpaced, fpv, hubsan, exo, yuneec, typhoon,
            swell, crazyName, bitcraze, sky, autelSsid, elrs,
        ]
        let hits = engine.match(devices: radios, fleets: stock)
        #expect(ids(hits, french).contains("fleet-remote-id"), "French plate")
        #expect(ids(hits, astm).contains("fleet-remote-id"), "ASTM plate")
        #expect(!ids(hits, nan).contains("fleet-remote-id"), "NAN is not Remote ID")
        #expect(!ids(hits, parrotOui).contains("fleet-parrot"), "Parrot OUI alone")
        #expect(ids(hits, tello).contains("fleet-tello"), "Tello")
        #expect(!ids(hits, tello).contains("fleet-dji"), "Tello is not DJI")
        #expect(ids(hits, talent).contains("fleet-tello"), "Tello Talent")
        #expect(!ids(hits, telloMid).contains("fleet-tello"), "TELLO in the middle")
        #expect(ids(hits, dji).contains("fleet-dji"), "DJI name")
        #expect(!ids(hits, dji).contains("fleet-tello"), "DJI name is not Tello")
        #expect(ids(hits, potensic).contains("fleet-potensic"), "Potensic")
        #expect(!ids(hits, atom).contains("fleet-potensic"), "bare ATOM")
        #expect(ids(hits, holy).contains("fleet-holystone"), "HolyStone")
        #expect(ids(hits, holySpaced).contains("fleet-holystone"), "Holy Stone")
        #expect(!ids(hits, fpv).contains("fleet-holystone"), "generic FPV")
        #expect(ids(hits, hubsan).contains("fleet-hubsan"), "Hubsan")
        #expect(!ids(hits, exo).contains("fleet-hubsan"), "bare EXO")
        #expect(ids(hits, yuneec).contains("fleet-yuneec"), "Yuneec")
        #expect(!ids(hits, typhoon).contains("fleet-yuneec"), "Typhoon")
        #expect(ids(hits, swell).contains("fleet-swellpro"), "SwellPro")
        #expect(ids(hits, crazyName).contains("fleet-crazyflie"), "Crazyflie name")
        #expect(!ids(hits, bitcraze).contains("fleet-crazyflie"), "Bitcraze company id")
        #expect(ids(hits, sky).contains("fleet-parrot"), "Skycontroller")
        #expect(!ids(hits, autelSsid).contains("fleet-autel"), "default-ssid")
        #expect(added.allSatisfy { !ids(hits, elrs).contains($0) })
        for id in added {
            let quiet = wifi("02:11:22:33:44:55", "Home")
            #expect(!ids(engine.match(devices: [quiet], fleets: stock), quiet).contains(id))
        }
    }

    @Test func catalog91DjiPowerIsHomeNotDrone() {
        let stock = DefaultCatalog.fleets()
        let engine = SignatureEngine()
        let power = stock.single { $0.id == "fleet-dji-power" }
        #expect(power.kind == .home)
        #expect(power.matchAny)
        #expect(power.attentionNote.isBlank)
        #expect(power.rules.count == 1)
        #expect(power.rules.first?.radio == .ble)
        #expect(power.rules.first?.text == "Power2000*")
        #expect(!DefaultCatalog.defaultWatchlist().compactMap { $0.fleetId }.contains("fleet-dji-power"),
                "DJI Power is not bookmarked")
        #expect(stock.single { $0.id == "fleet-dji" }.notes.contains("DJI Power"))

        let named = edited(tagged("01", "Power2000-1006HZ", 0x08AA)) { $0.manufacturerDataHex = "941110E4B063D0AA76" }
        let lower = edited(tagged("02", "power2000-1006hz", 0x08AA)) { $0.manufacturerDataHex = "9411" }
        let nameOnly = tagged("03", "Power2000", nil)
        let mid = edited(tagged("04", "my Power2000", 0x08AA)) { $0.manufacturerDataHex = "9411" }
        let bare = edited(tagged("05", "", 0x08AA)) { $0.manufacturerDataHex = "9411" }
        let djiName = edited(tagged("06", "DJI Mini 4", 0x08AA)) { $0.manufacturerDataHex = "7000" }
        let wifiPower = wifi("02:00:00:00:00:77", "Power2000-1006HZ")
        let hits = engine.match(devices: [named, lower, nameOnly, mid, bare, djiName, wifiPower], fleets: stock)
        #expect(ids(hits, named).contains("fleet-dji-power"), "named power")
        #expect(!ids(hits, named).contains("fleet-dji"), "named power is not the drone row")
        #expect(ids(hits, lower).contains("fleet-dji-power"), "lowercase name")
        #expect(!ids(hits, lower).contains("fleet-dji"), "lowercase name is not the drone row")
        #expect(ids(hits, nameOnly).contains("fleet-dji-power"), "name only")
        #expect(!ids(hits, nameOnly).contains("fleet-dji"), "name only is not the drone row")
        #expect(!ids(hits, mid).contains("fleet-dji-power"), "Power2000 in the middle")
        #expect(ids(hits, mid).contains("fleet-dji"), "middle name with company stays DJI")
        #expect(!ids(hits, bare).contains("fleet-dji-power"), "bare company is not Power")
        #expect(ids(hits, bare).contains("fleet-dji"), "bare company stays DJI")
        #expect(ids(hits, djiName).contains("fleet-dji"), "DJI name")
        #expect(!ids(hits, djiName).contains("fleet-dji-power"), "DJI name is not Power")
        #expect(!ids(hits, wifiPower).contains("fleet-dji-power"), "Wi-Fi Power2000")
        let guess = DeviceExplain.guess(device: named, signatureNames: ["DJI Power"])
        #expect(guess.headline.contains("Power station", ignoreCase: true), "\(guess.headline)")
        #expect(!guess.headline.contains("drone", ignoreCase: true), "\(guess.headline)")
    }

    @Test func catalog92DropsBadLiteOnOuisNamesMetaDisplayAndSoftensAxon() {
        let stock = DefaultCatalog.fleets()
        let engine = SignatureEngine()
        let lite = stock.single { $0.id == "fleet-liteon-camera-radio" }
        let meta = stock.single { $0.id == "fleet-meta-glasses" }
        let axon = stock.single { $0.id == "fleet-axon" }
        let liteOuis = ouiSet(lite)
        #expect(liteOuis.contains("F8:A2:D6"))
        #expect(liteOuis.contains("E0:0A:F6"))
        #expect(liteOuis.contains("14:B5:CD"))
        #expect(!liteOuis.contains("48:27:EA"))
        #expect(!liteOuis.contains("82:6B:F2"))
        #expect(lite.attentionNote.isBlank)
        #expect(lite.kind == .camera)
        #expect(!DefaultCatalog.defaultWatchlist().compactMap { $0.fleetId }.contains("fleet-liteon-camera-radio"))
        #expect(meta.rules.contains { $0.kind == .nameGlob && $0.text == "Meta RB Display*" && $0.radio == .ble })
        #expect(!meta.rules.contains { $0.kind == .serviceUuid && $0.text.equals("FD5F", ignoreCase: true) })
        #expect(meta.notes.contains("Meta Display"))
        #expect(axon.notes.contains("fixed ALPR"))
        #expect(axon.attentionNote.contains("fixed readers"))
        #expect(axon.attentionNote.contains("BWCDEVICE"))
        #expect(axon.rules.contains { $0.kind == .oui && $0.text.equals("00:25:DF", ignoreCase: true) })
        #expect(axon.rules.contains {
            $0.kind == .serviceData && $0.dataPrefixHex.equals("425743444556494345", ignoreCase: true)
        })
        #expect(!stock.contains { fleet in
            fleet.rules.contains { rule in
                (rule.kind == .manufacturerId && rule.companyId == 0xFD5F) ||
                    (rule.kind == .serviceUuid && rule.text.equals("FD5F", ignoreCase: true))
            }
        })

        let samsung = wifi("48:27:EA:11:22:33")
        let local = wifi("82:6B:F2:11:22:33")
        let kept = wifi("F8:A2:D6:11:22:33")
        let display = edited(ble(name: "Meta RB Display 0053")) { $0.key = "BLE:21"; $0.mac = "AA:BB:CC:DD:EE:21" }
        let short = edited(ble(name: "Meta RB")) { $0.key = "BLE:22"; $0.mac = "AA:BB:CC:DD:EE:22" }
        let mid = edited(ble(name: "my Meta RB Display")) { $0.key = "BLE:23"; $0.mac = "AA:BB:CC:DD:EE:23" }
        let fd5f = edited(ble(name: "", serviceUuids: ["0000FD5F-0000-1000-8000-00805F9B34FB"])) {
            $0.key = "BLE:24"; $0.mac = "AA:BB:CC:DD:EE:24"
        }
        let hits = engine.match(devices: [samsung, local, kept, display, short, mid, fd5f], fleets: stock)
        #expect(!ids(hits, samsung).contains("fleet-liteon-camera-radio"), "Samsung prefix")
        #expect(!ids(hits, local).contains("fleet-liteon-camera-radio"), "local prefix")
        #expect(ids(hits, kept).contains("fleet-liteon-camera-radio"), "LiteOn F8:A2:D6")
        #expect(ids(hits, display).contains("fleet-meta-glasses"), "Meta Display name")
        #expect(!ids(hits, short).contains("fleet-meta-glasses"), "short Meta RB")
        #expect(!ids(hits, mid).contains("fleet-meta-glasses"), "Display not at the start")
        #expect(!ids(hits, fd5f).contains("fleet-meta-glasses"), "FD5F alone")
    }

    @Test func catalog93TightensFlockPenguinFsExtAndLiteOn() {
        let stock = DefaultCatalog.fleets()
        let engine = SignatureEngine()
        let flock = stock.single { $0.id == "fleet-flock-cameras" }
        let penguin = stock.single { $0.id == "fleet-penguin" }
        let fs = stock.single { $0.id == "fleet-fs-ext-battery" }
        let lite = stock.single { $0.id == "fleet-liteon-camera-radio" }
        #expect(ouiSet(flock) == ["B4:1E:52"])
        #expect(flock.rules.filter { $0.kind == .nameGlob }.map { $0.text } == ["Flock-*"])
        #expect(!flock.rules.contains { $0.kind == .nameContains })
        #expect(penguin.rules.filter { $0.kind == .nameGlob }.map { $0.text } == ["Penguin-*"])
        #expect(!penguin.rules.contains { $0.kind == .nameContains })
        #expect(penguin.rules.contains { $0.kind == .manufacturerId && $0.companyId == 0x09C8 })
        #expect(fs.rules.allSatisfy { $0.kind != .oui })
        #expect(fs.rules.contains { $0.kind == .nameContains && $0.text == "FS Ext Battery" })
        #expect(fs.rules.filter { $0.kind == .nameGlob }.map { $0.text } == ["FS Ext*"])
        let liteOuis = ouiSet(lite)
        #expect(!liteOuis.contains("B8:35:32"))
        #expect(liteOuis.contains("08:3A:88"))
        #expect(liteOuis.contains("C0:35:32"))
        #expect(lite.notes.contains("Universal Global Scientific"))
        #expect(lite.attentionNote.isBlank)

        let pole = wifi("B4:1E:52:00:00:01", "Home")
        let flockName = wifi("02:11:22:33:44:70", "Flock-ABCDEF")
        let flockLong = wifi("02:11:22:33:44:71", "Flock-ABCDEFGH")
        let falcons = wifi("02:11:22:33:44:72", "Atlanta-Falcons")
        let flck = wifi("02:11:22:33:44:73", "FLCK-9")
        let flockCam = wifi("02:11:22:33:44:74", "FlockCam-9")
        let penguinOld = wifi("02:11:22:33:44:80", "Penguin")
        let penguinName = wifi("02:11:22:33:44:81", "Penguin-12345")
        let penguinMid = wifi("02:11:22:33:44:82", "my Penguin-1")
        let digits = wifi("02:11:22:33:44:83", "7202302200")
        let xuntong = tagged("91", "7202302200", 0x09C8)
        let pack = wifi("02:11:22:33:44:90", "FS Ext Battery")
        let packTail = wifi("02:11:22:33:44:91", "FS Ext 2")
        let fsStar = wifi("02:11:22:33:44:92", "FS_1234")
        let silabs = wifi("04:0D:84:11:22:33", "Home")
        let bogus = wifi("B8:35:32:11:22:33", "Home")
        let ugsi = wifi("08:3A:88:11:22:33", "Home")
        let hits = engine.match(
            devices: [
                pole, flockName, flockLong, falcons, flck, flockCam,
                penguinOld, penguinName, penguinMid, digits, xuntong,
                pack, packTail, fsStar, silabs, bogus, ugsi,
            ],
            fleets: stock
        )
        #expect(ids(hits, pole).contains("fleet-flock-cameras"), "Flock OUI")
        #expect(ids(hits, flockName).contains("fleet-flock-cameras"), "Flock- name")
        #expect(ids(hits, flockLong).contains("fleet-flock-cameras"), "longer Flock- name")
        #expect(!ids(hits, falcons).contains("fleet-flock-cameras"), "Atlanta-Falcons")
        #expect(!ids(hits, flck).contains("fleet-flock-cameras"), "FLCK")
        #expect(!ids(hits, flockCam).contains("fleet-flock-cameras"), "FlockCam")
        #expect(!ids(hits, penguinOld).contains("fleet-penguin"), "bare Penguin")
        #expect(ids(hits, penguinName).contains("fleet-penguin"), "Penguin- name")
        #expect(!ids(hits, penguinMid).contains("fleet-penguin"), "Penguin- in the middle")
        #expect(!ids(hits, digits).contains("fleet-penguin"), "10-digit name alone")
        #expect(ids(hits, xuntong).contains("fleet-penguin"), "XUNTONG id")
        #expect(ids(hits, pack).contains("fleet-fs-ext-battery"), "FS Ext Battery name")
        #expect(ids(hits, packTail).contains("fleet-fs-ext-battery"), "FS Ext prefix")
        #expect(!ids(hits, fsStar).contains("fleet-fs-ext-battery"), "FS_ wildcard")
        #expect(!ids(hits, silabs).contains("fleet-fs-ext-battery"), "Silicon Labs prefix")
        #expect(!ids(hits, bogus).contains("fleet-liteon-camera-radio"), "unassigned prefix")
        #expect(ids(hits, ugsi).contains("fleet-liteon-camera-radio"), "UGSI prefix stays on the module row")
        #expect(!ids(hits, ugsi).contains("fleet-flock-cameras"), "UGSI is not Flock")
    }

    @Test func catalog94AddsFlipperServiceTilePreactivationAndPolar() {
        let stock = DefaultCatalog.fleets()
        let engine = SignatureEngine()
        let flipper = stock.single { $0.id == "fleet-flipper" }
        let tile = stock.single { $0.id == "fleet-tile" }
        let polar = stock.single { $0.id == "fleet-polar" }
        #expect(polar.kind == .wearable)
        #expect(polar.attentionNote.isBlank)
        #expect(!DefaultCatalog.defaultWatchlist().compactMap { $0.fleetId }.contains("fleet-polar"))
        for uuid in ["3080", "3081", "3082", "3083"] {
            #expect(flipper.rules.contains { $0.kind == .serviceUuid && $0.text.equals(uuid, ignoreCase: true) }, "\(uuid)")
        }
        #expect(tile.rules.contains { $0.kind == .serviceUuid && $0.text.equals("FEEC", ignoreCase: true) })
        #expect(polar.rules.contains { $0.kind == .manufacturerId && $0.companyId == 0x006B })
        #expect(polar.rules.contains { $0.kind == .serviceUuid && $0.text.equals("FEEE", ignoreCase: true) })
        #expect(polar.rules.contains { $0.kind == .nameGlob && $0.text == "Polar*" && $0.radio == .ble })
        #expect(DeviceExplain.uuidGloss(uuid: "FEEC")?.contains("Tile") == true)
        #expect(DeviceExplain.uuidGloss(uuid: "FEEE")?.contains("Polar") == true)

        let renamed = edited(ble(name: "Widget", serviceUuids: ["00003082-0000-1000-8000-00805F9B34FB"])) {
            $0.key = "BLE:f1"; $0.mac = "AA:BB:CC:DD:EE:31"
        }
        let tileNew = edited(ble(name: "", serviceUuids: ["0000FEEC-0000-1000-8000-00805F9B34FB"])) {
            $0.key = "BLE:f2"; $0.mac = "AA:BB:CC:DD:EE:32"
        }
        let h10 = edited(ble(
            name: "Polar H10 E7BAC71A",
            manufacturerId: 0x006B,
            manufacturerDataHex: "37060000",
            serviceUuids: [
                "0000180D-0000-1000-8000-00805F9B34FB",
                "0000FEEE-0000-1000-8000-00805F9B34FB",
                "0000FEA5-0000-1000-8000-00805F9B34FB",
            ]
        )) { $0.key = "BLE:f3"; $0.mac = "AA:BB:CC:DD:EE:33" }
        let gopro = edited(ble(name: "GoPro 1234", serviceUuids: ["0000FEA5-0000-1000-8000-00805F9B34FB"])) {
            $0.key = "BLE:f4"; $0.mac = "AA:BB:CC:DD:EE:34"
        }
        let hrOnly = edited(ble(name: "", serviceUuids: ["0000180D-0000-1000-8000-00805F9B34FB"])) {
            $0.key = "BLE:f5"; $0.mac = "AA:BB:CC:DD:EE:35"
        }
        let hits = engine.match(devices: [renamed, tileNew, h10, gopro, hrOnly], fleets: stock)
        #expect(ids(hits, renamed).contains("fleet-flipper"), "renamed Flipper service")
        #expect(ids(hits, tileNew).contains("fleet-tile"), "Tile FEEC")
        #expect(ids(hits, h10).contains("fleet-polar"), "Polar H10")
        #expect(!ids(hits, h10).contains("fleet-gopro"), "Polar strap is not a camera")
        #expect(ids(hits, gopro).contains("fleet-gopro"), "GoPro still matches")
        #expect(!ids(hits, gopro).contains("fleet-polar"), "GoPro is not Polar")
        #expect(!ids(hits, hrOnly).contains("fleet-polar"), "heart rate alone")
        #expect(
            TrackerMatch.kind(device: edited(h10) { $0.fleetIds = ["fleet-polar"] }, names: ["fleet-polar": "Polar"])
                == .wearable
        )
    }
}
