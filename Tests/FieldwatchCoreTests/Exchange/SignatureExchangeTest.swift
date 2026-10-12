import Foundation
import Testing
@testable import FieldwatchCore

// Port of SignatureExchangeTest.kt.
// Swift's pretty JSON writes `"key" : value` (space before the colon), so string probes use that form.

@Suite struct SignatureExchangeTest {
    private let stock = DefaultCatalog.fleets()

    @Test func sonyPlusIBeaconLayoutIsSonyNotIBeacon() throws {
        let ibeacon = "0215E2C56DB5DFFB48D2B060D0F5A71096E000010002C5"
        let tv = Sighting(
            key: "BLE:AA:BB:CC:DD:EE:02", kind: .ble, mac: "AA:BB:CC:DD:EE:02", name: "Sony TV",
            rssi: -45, rssiMin: -45, rssiMax: -45, channel: 0, frequencyMhz: 0, vendor: nil,
            randomized: false, hiddenSsid: false, serviceUuids: [], manufacturerId: 0x012D,
            manufacturerDataHex: ibeacon, rawHex: "", extras: "", firstSeen: 1, lastSeen: 1, hitCount: 1,
            fleetIds: [], rssiHistory: [], presence: [],
            facts: RadioFacts(mfgRecords: [
                MfgRecord(companyId: 0x012D, dataHex: "0300"),
                MfgRecord(companyId: 0x004C, dataHex: ibeacon),
            ])
        )
        let hits = try hit(SignatureEngine().match(devices: [tv], fleets: stock), tv.key)
        #expect(hits.contains("fleet-sony"), "Sony")
        #expect(!hits.contains("fleet-ibeacon"), "iBeacon is protocol noise on a Sony TV")
    }

    @Test func teslaPhoneKeyIBeaconIsTeslaNotIBeacon() throws {
        let data = DefaultCatalog.TESLA_IBEACON_MFG_PREFIX + "00015D"
        let car = Sighting(
            key: "BLE:AA:BB:CC:DD:EE:01", kind: .ble, mac: "AA:BB:CC:DD:EE:01", name: "S1a87a5a75f3df858C",
            rssi: -40, rssiMin: -40, rssiMax: -40, channel: 0, frequencyMhz: 0, vendor: nil,
            randomized: false, hiddenSsid: false, serviceUuids: [], manufacturerId: 0x004C,
            manufacturerDataHex: data, rawHex: "", extras: "", firstSeen: 1, lastSeen: 1, hitCount: 1,
            fleetIds: [], rssiHistory: [], presence: [],
            facts: RadioFacts(mfgRecords: [MfgRecord(companyId: 0x004C, dataHex: data)])
        )
        let hits = try hit(SignatureEngine().match(devices: [car], fleets: stock), car.key)
        #expect(hits.contains("fleet-tesla"), "Tesla")
        #expect(!hits.contains("fleet-ibeacon"), "not a mall iBeacon")
        #expect(!hits.contains("fleet-target-atrius"), "not an Atrius cart tag")
    }

    @Test func targetAtriusIBeaconIsTargetAndIBeacon() throws {
        let data = DefaultCatalog.TARGET_ATRIUS_IBEACON_MFG_PREFIX + "6C42CC85C3"
        let tag = with(ble(name: "", manufacturerId: 0x004C, manufacturerDataHex: data)) {
            $0.serviceUuids = ["0000B1BB-0000-1000-8000-00805F9B34FB"]
        }
        let hits = try hit(SignatureEngine().match(devices: [tag], fleets: stock), tag.key)
        #expect(hits.contains("fleet-target-atrius"), "Atrius cart tag")
        #expect(hits.contains("fleet-ibeacon"), "still dual-labels iBeacon")
        let fleet = try #require(stock.first { $0.id == "fleet-target-atrius" })
        #expect(fleet.kind == .beacon)
        #expect(fleet.kind.label() == "Retail beacons")
    }

    @Test func targetAtriusB1bbOnlyStillMatches() throws {
        let tag = with(ble(name: "")) { $0.serviceUuids = ["B1BB"] }
        let hits = try hit(SignatureEngine().match(devices: [tag], fleets: stock), tag.key)
        #expect(hits.contains("fleet-target-atrius"), "B1BB hits Atrius cart tag")
    }

    @Test func genericIBeaconIsNotTargetAtrius() throws {
        let other = ble(name: "", manufacturerId: 0x004C, manufacturerDataHex: "0215E2C56DB5DFFB48D2B060D0F5A71096E000010002C5")
        let hits = try hit(SignatureEngine().match(devices: [other], fleets: stock), other.key)
        #expect(hits.contains("fleet-ibeacon"), "generic iBeacon")
        #expect(!hits.contains("fleet-target-atrius"), "not Target UUID")
    }

    @Test func iphoneOfflineFindingIsAppleDeviceNotAirTag() throws {
        let phone = with(ble(name: "", manufacturerId: 0x004C, manufacturerDataHex: "10AABBCCDDEE")) {
            $0.facts = RadioFacts(mfgRecords: [
                MfgRecord(companyId: 0x004C, dataHex: "10AABBCCDDEE"),
                MfgRecord(companyId: 0x004C, dataHex: "12" + "00".repeated(24)),
            ])
        }
        let hits = try hit(SignatureEngine().match(devices: [phone], fleets: stock), phone.key)
        #expect(hits.contains("fleet-apple-device"), "Apple Device")
        #expect(!hits.contains("fleet-airtag"), "OF on an iPhone is not an AirTag")
    }

    @Test func namedIphoneWithOnlyFindMyIsAppleDeviceNotAirTag() throws {
        let phone = ble(name: "iPhone", manufacturerId: 0x004C, manufacturerDataHex: "12" + "00".repeated(24))
        let hits = try hit(SignatureEngine().match(devices: [phone], fleets: stock), phone.key)
        #expect(hits.contains("fleet-apple-device"), "Apple Device")
        #expect(!hits.contains("fleet-airtag"), "named iPhone is not an AirTag")
    }

    @Test func airTagOfflineFindingStillAirTag() throws {
        let tag = ble(name: "", manufacturerId: 0x004C, manufacturerDataHex: "12" + "00".repeated(24))
        let hits = try hit(SignatureEngine().match(devices: [tag], fleets: stock), tag.key)
        #expect(hits.contains("fleet-airtag"), "AirTag OF")
        #expect(!hits.contains("fleet-apple-device"), "not Continuity")
    }

    @Test func airTagNameKeepsAirTagEvenWithContinuity() throws {
        let tag = with(ble(name: "AirTag", manufacturerId: 0x004C, manufacturerDataHex: "10AABBCCDDEE")) {
            $0.facts = RadioFacts(mfgRecords: [
                MfgRecord(companyId: 0x004C, dataHex: "10AABBCCDDEE"),
                MfgRecord(companyId: 0x004C, dataHex: "12" + "00".repeated(24)),
            ])
        }
        let hits = try hit(SignatureEngine().match(devices: [tag], fleets: stock), tag.key)
        #expect(hits.contains("fleet-airtag"), "name AirTag wins")
        #expect(hits.contains("fleet-apple-device"), "Continuity still labels Apple Device")
    }

    @Test func findMyUuidKeepsAirTagEvenWithContinuity() throws {
        let accessory = with(ble(name: "", manufacturerId: 0x004C, manufacturerDataHex: "10AABBCCDDEE")) {
            $0.serviceUuids = ["0000FD44-0000-1000-8000-00805F9B34FB"]
            $0.facts = RadioFacts(mfgRecords: [
                MfgRecord(companyId: 0x004C, dataHex: "10AABBCCDDEE"),
                MfgRecord(companyId: 0x004C, dataHex: "12" + "00".repeated(24)),
            ])
        }
        let hits = try hit(SignatureEngine().match(devices: [accessory], fleets: stock), accessory.key)
        #expect(hits.contains("fleet-airtag"), "FD44 is a Find My accessory")
        #expect(hits.contains("fleet-apple-device"), "Continuity still labels Apple Device")
    }

    @Test func continuityPlusFindMyIsNotFindMyPayloadAlone() {
        let phone = with(ble(name: "", manufacturerId: 0x004C, manufacturerDataHex: "10AABBCCDDEE")) {
            $0.facts = RadioFacts(mfgRecords: [
                MfgRecord(companyId: 0x004C, dataHex: "10AABBCCDDEE"),
                MfgRecord(companyId: 0x004C, dataHex: "12" + "00".repeated(24)),
            ])
        }
        #expect(TrackerMatch.isAppleContinuity(device: phone))
        #expect(!TrackerMatch.isFindMyPayload(device: phone))
        let tag = ble(name: "", manufacturerId: 0x004C, manufacturerDataHex: "12" + "00".repeated(24))
        #expect(!TrackerMatch.isAppleContinuity(device: tag))
        #expect(TrackerMatch.isFindMyPayload(device: tag))
    }

    @Test func teslaMatchesVinPhoneKeyAndCybertruck() throws {
        let tesla = try #require(stock.first { $0.id == "fleet-tesla" })
        #expect(tesla.rules.contains { $0.kind == .nameContains && $0.text.equals("Cybertruck", ignoreCase: true) })
        #expect(tesla.rules.contains { $0.kind == .nameGlob && $0.text == "S????????????????C" })
        #expect(TextMatch.glob(text: "S1a87a5a75f3df858C", pattern: "S????????????????C"))
        #expect(!TextMatch.glob(text: "Tesla", pattern: "S????????????????C"))
    }

    @Test func stockPresetIdsAreBuiltInAndUnique() throws {
        let presets = FilterEngine().defaultPresets()
        #expect(presets.map { $0.id } == presets.map { $0.id }.distinct())
        for preset in presets {
            #expect(preset.isBuiltIn(), "\(preset.id)")
        }
        #expect(presets.count == 6)
        #expect(presets.first { $0.name == "Watched only" }?.id == "watched")
        #expect(presets.none { $0.id == "cameras" })
        #expect(presets.none { $0.id == "trackers" })
    }

    @Test func consumerCamerasAreCameraClass() throws {
        let ids = stock.associateBy { $0.id }
        func row(_ id: String) throws -> Fleet { try #require(ids[id], "\(id)") }
        for id in [
            "fleet-gopro", "fleet-osmo", "fleet-insta360",
            "fleet-wyze", "fleet-ring", "fleet-arlo", "fleet-eufy",
            "fleet-liteon-camera-radio",
            "fleet-nest", "fleet-tapo", "fleet-reolink",
        ] {
            #expect(try row(id).kind == .camera, "\(id)")
        }
        #expect(try row("fleet-meta-glasses").kind == .glasses)
        #expect(try row("fleet-unifi-ap").kind == .isp)
        #expect(try row("fleet-unifi").kind == .isp)
        #expect(try row("fleet-unifi-protect").kind == .surveillance)
        for id in [
            "fleet-meraki", "fleet-cisco", "fleet-aruba", "fleet-ruckus",
            "fleet-fortinet", "fleet-mist", "fleet-sophos", "fleet-extreme",
            "fleet-edgecore", "fleet-watchguard-ap", "fleet-mojo",
        ] {
            #expect(try row(id).kind == .isp, "\(id)")
        }
        #expect(try row("fleet-flock-cameras").kind == .surveillance)
        #expect(try row("fleet-fs-ext-battery").kind == .surveillance)
        let publicCameras = [
            "fleet-flock-cameras", "fleet-fs-ext-battery", "fleet-penguin", "fleet-pigvision",
            "fleet-genetec", "fleet-rekor", "fleet-vigilant", "fleet-verkada",
            "fleet-avigilon", "fleet-axis", "fleet-hikvision", "fleet-dahua",
            "fleet-hanwha-wisenet", "fleet-uniview", "fleet-rhombus",
        ]
        for id in publicCameras {
            #expect(try row(id).attentionNote.isNotBlank, "\(id)")
        }
        #expect(try row("fleet-liteon-camera-radio").attentionNote.isBlank)
        #expect(try row("fleet-unifi-protect").attentionNote.isBlank)
        #expect(try row("fleet-salto").attentionNote.isBlank)
        #expect(SignatureClass.lock.label() == "Access control")
        for id in ["fleet-seos", "fleet-salto", "fleet-dormakaba", "fleet-paxton", "fleet-august"] {
            #expect(try row(id).kind == .lock, "\(id)")
        }
        #expect(try row("fleet-bluetoad").kind == .surveillance)
        #expect(try row("fleet-bluetoad").attentionNote.isBlank)
        let watched = Set(DefaultCatalog.defaultWatchlist().compactMap { $0.fleetId })
        for id in publicCameras {
            #expect(watched.contains(id), "\(id)")
        }
        #expect(!watched.contains("fleet-unifi-protect"))
        #expect(!watched.contains("fleet-bluetoad"))
        #expect(!watched.contains("fleet-bliptrack"))
        #expect(try row("fleet-bliptrack").kind == .surveillance)
        #expect(try row("fleet-bliptrack").attentionNote.isBlank)
        #expect(try row("fleet-meshcore").kind == .mesh)
        #expect(try row("fleet-gotenna").kind == .mesh)
        #expect(try row("fleet-sensecap").kind == .mesh)
        #expect(try row("fleet-rak-wisgate").kind == .mesh)
        #expect(try row("fleet-meshcore").attentionNote.isBlank)
        #expect(!watched.contains("fleet-meshcore"))
        #expect(!watched.contains("fleet-gotenna"))
        #expect(!watched.contains("fleet-sensecap"))
        #expect(!watched.contains("fleet-rak-wisgate"))
        #expect(try row("fleet-ghostesp").kind == .hacking)
        #expect(try row("fleet-bruce").kind == .hacking)
        #expect(try row("fleet-ghostesp").attentionNote.isNotBlank)
        #expect(try row("fleet-bruce").attentionNote.isNotBlank)
        #expect(watched.contains("fleet-ghostesp"))
        #expect(watched.contains("fleet-bruce"))
        let extraSurveillance = ids.values.filter {
            $0.builtIn && $0.kind == .surveillance && $0.attentionNote.isNotBlank
        }.map { $0.id }
        #expect(extraSurveillance.isNotEmpty)
        for id in extraSurveillance {
            #expect(watched.contains(id), "\(id)")
        }
        #expect(!watched.contains("fleet-raven"))
        let drones = ids.values.filter { $0.builtIn && $0.kind == .drone }.map { $0.id }
        #expect(drones.isNotEmpty)
        for id in drones {
            #expect(watched.contains(id), "\(id)")
        }
        #expect(watched.contains("fleet-dji"))
        #expect(watched.contains("fleet-remote-id"))
        #expect(watched.contains("fleet-skydio"))
        #expect(watched.contains("fleet-autel"))
        #expect(watched.contains("fleet-parrot"))
        #expect(watched.contains("fleet-hoverair"))
        #expect(!watched.contains("fleet-osmo"))
        #expect(try row("fleet-axon").kind == .lawEnforcement)
        #expect(try row("fleet-watchguard").kind == .lawEnforcement)
        #expect(try row("fleet-cradlepoint").kind == .lawEnforcement)
        #expect(try row("fleet-airlink").kind == .lawEnforcement)
        #expect(try row("fleet-compex").kind == .lawEnforcement)
        #expect(try row("fleet-novatel").kind == .lawEnforcement)
        #expect(try row("fleet-utility-inc").kind == .lawEnforcement)
        #expect(try row("fleet-tesla").kind == .vehicle)
        #expect(try row("fleet-ruijie").kind == .isp)
        #expect(try row("fleet-dwnet").kind == .isp)
        #expect(try row("fleet-wavlink").kind == .isp)
        #expect(try row("fleet-peoplenet").kind == .vehicle)
        #expect(try row("fleet-uconnect").kind == .vehicle)
        #expect(try row("fleet-carplay").kind == .vehicle)
        #expect(try row("fleet-roku").kind == .home)
        #expect(try row("fleet-franklin").kind == .isp)
        #expect(try row("fleet-huawei").kind == .isp)
        #expect(try row("fleet-plume").kind == .isp)
        #expect(try row("fleet-phone-hotspot").kind == .phone)
        #expect(try row("fleet-samsung-appliance").kind == .home)
        #expect(try row("fleet-ecowater").kind == .home)
        #expect(stock.none { $0.kind == .bodyworn })
        #expect(try row("fleet-nest-thermostat").kind == .thermostat)
        #expect(try row("fleet-dji").kind == .drone)
        #expect(try row("fleet-hoverair").kind == .drone)
        #expect(try row("fleet-honeywell-xenon-hc").kind == .health)
        #expect(try row("fleet-omron").kind == .health)
        #expect(try row("fleet-withings").kind == .health)
        #expect(try row("fleet-dexcom").kind == .health)
    }

    @Test func blueToadSpectraHitsNameAndIterisOuiButNotGenericWords() throws {
        let engine = SignatureEngine()
        let named = sighting(.wifi, "AA:BB:CC:00:00:10", "BlueTOAD-12AB")
        let velocity = sighting(.wifi, "AA:BB:CC:00:00:11", "Vantage Velocity 4")
        let oui = sighting(.wifi, "00:14:7B:11:22:33", "Cabinet")
        let generic = sighting(.wifi, "AA:BB:CC:00:00:12", "Spectra Audio")
        let vantage = sighting(.wifi, "AA:BB:CC:00:00:13", "Vantage Point")
        let hits = engine.match(devices: [named, velocity, oui, generic, vantage], fleets: stock)
        #expect(try hit(hits, named.key).contains("fleet-bluetoad"), "BlueTOAD SSID")
        #expect(try hit(hits, velocity.key).contains("fleet-bluetoad"), "Vantage Velocity name")
        #expect(try hit(hits, oui.key).contains("fleet-bluetoad"), "Iteris OUI 00:14:7B")
        #expect(try hit(hits, generic.key).isEmpty, "Spectra alone stays unmatched")
        #expect(try hit(hits, vantage.key).isEmpty, "Vantage alone stays unmatched")
    }

    @Test func catalogV70FamiliesHitUniqueIdsNotGenericWords() throws {
        let engine = SignatureEngine()
        let blip = sighting(.wifi, "00:0E:A5:11:22:33", "Cabinet")
        let wisenet = sighting(.wifi, "AA:BB:CC:00:00:20", "XNV-6080_0076_WISENET")
        let uniview = sighting(.wifi, "48:EA:63:11:22:33", "Yard")
        let rhombus = sighting(.wifi, "CC:47:BD:11:22:33", "Lobby")
        let mesh = ble(name: "MeshCore_A1B2", mac: "AA:BB:CC:DD:EE:10")
        let nordic = with(ble(name: "", mac: "AA:BB:CC:DD:EE:11")) {
            $0.serviceUuids = ["6E400001-B5A3-F393-E0A9-E50E24DCCA9E"]
        }
        let gotenna = with(ble(name: "", mac: "AA:BB:CC:DD:EE:12")) {
            $0.serviceUuids = ["1276aaee-df5e-11e6-bf01-fe55135034f3"]
        }
        let sense = sighting(.wifi, "AA:BB:CC:00:00:21", "SenseCAP_A1B2C3")
        let rak = sighting(.wifi, "AA:BB:CC:00:00:22", "RAK7268_A1B2")
        let ghost = sighting(.wifi, "AA:BB:CC:00:00:23", "GhostNet")
        let bruce = sighting(.wifi, "AA:BB:CC:00:00:24", "BruceNet")
        let genericGhost = sighting(.wifi, "AA:BB:CC:00:00:25", "Ghost")
        let genericBruce = sighting(.wifi, "AA:BB:CC:00:00:26", "Bruce")
        let hits = engine.match(
            devices: [
                blip, wisenet, uniview, rhombus, mesh, nordic, gotenna,
                sense, rak, ghost, bruce, genericGhost, genericBruce,
            ],
            fleets: stock
        )
        #expect(try hit(hits, blip.key).contains("fleet-bliptrack"), "BlipTrack OUI")
        #expect(try hit(hits, wisenet.key).contains("fleet-hanwha-wisenet"), "Wisenet setup SSID")
        #expect(try hit(hits, uniview.key).contains("fleet-uniview"), "Uniview OUI")
        #expect(try hit(hits, rhombus.key).contains("fleet-rhombus"), "Rhombus OUI")
        #expect(try hit(hits, mesh.key).contains("fleet-meshcore"), "MeshCore name")
        #expect(try !hit(hits, nordic.key).contains("fleet-meshcore"), "Nordic UART is not MeshCore")
        #expect(try hit(hits, gotenna.key).contains("fleet-gotenna"), "goTenna service UUID")
        #expect(try hit(hits, sense.key).contains("fleet-sensecap"), "SenseCAP setup AP")
        #expect(try hit(hits, rak.key).contains("fleet-rak-wisgate"), "RAK WisGate setup AP")
        #expect(try hit(hits, ghost.key).contains("fleet-ghostesp"), "GhostNet")
        #expect(try hit(hits, bruce.key).contains("fleet-bruce"), "BruceNet")
        #expect(try !hit(hits, genericGhost.key).contains("fleet-ghostesp"), "Ghost alone")
        #expect(try !hit(hits, genericBruce.key).contains("fleet-bruce"), "Bruce alone")
    }

    @Test func honeywellXenonHealthcareNameHits() throws {
        let scan = ble(name: "Xenon_CCB-U00-HC_SN_25139B493", mac: "C4:EF:DA:40:63:56")
        let hits = try hit(SignatureEngine().match(devices: [scan], fleets: stock), scan.key)
        #expect(hits.contains("fleet-honeywell-xenon-hc"), "Xenon CCB-U00-HC")
        let warehouse = ble(name: "Xenon_CCB-U00-G_SN_12345")
        let warehouseHits = try hit(SignatureEngine().match(devices: [warehouse], fleets: stock), warehouse.key)
        #expect(!warehouseHits.contains("fleet-honeywell-xenon-hc"), "general-purpose Xenon is not HC")
    }

    @Test func omronHealthcareCompanyHits() throws {
        let cuff = ble(name: "BLESmart_0000025828FFB232E019", manufacturerId: 0x020E)
        let hits = try hit(SignatureEngine().match(devices: [cuff], fleets: stock), cuff.key)
        #expect(hits.contains("fleet-omron"), "Omron 0x020E")
    }

    @Test func osmoActionIsCameraNotDji() throws {
        let cam = ble(name: "OsmoAction5Pro", manufacturerId: 0x08AA, manufacturerDataHex: "150000AABBCCDDEE03")
        let hits = try hit(SignatureEngine().match(devices: [cam], fleets: stock), cam.key)
        #expect(hits.contains("fleet-osmo"), "Osmo")
        #expect(!hits.contains("fleet-dji"), "Osmo must not dual-chip DJI")
    }

    @Test func osmoUnnamedModelIdIsCameraNotDji() throws {
        let cam = ble(name: "", manufacturerId: 0x08AA, manufacturerDataHex: "1200")
        let hits = try hit(SignatureEngine().match(devices: [cam], fleets: stock), cam.key)
        #expect(hits.contains("fleet-osmo"), "Osmo Action 3 model id")
        #expect(!hits.contains("fleet-dji"), "not DJI aircraft")
    }

    @Test func djiAircraftStaysDjiNotOsmo() throws {
        let drone = ble(name: "DJI Mini 4", manufacturerId: 0x08AA, manufacturerDataHex: "7000")
        let hits = try hit(SignatureEngine().match(devices: [drone], fleets: stock), drone.key)
        #expect(hits.contains("fleet-dji"), "DJI")
        #expect(!hits.contains("fleet-osmo"), "Mavic/Mini model id is not Osmo")
    }

    @Test func osmoMobileGimbalIsNotOsmoCamera() throws {
        let gimbal = ble(name: "Osmo Mobile 6")
        let hits = try hit(SignatureEngine().match(devices: [gimbal], fleets: stock), gimbal.key)
        #expect(!hits.contains("fleet-osmo"), "Osmo Mobile is a gimbal")
        #expect(!TextMatch.glob(text: "Osmo Mobile 6", pattern: "OsmoAction*"))
        #expect(!TextMatch.glob(text: "Osmo Mobile 6", pattern: "Osmo Pocket*"))
    }

    @Test func insta360NameAndCompanyIdAreCamera() throws {
        let named = ble(name: "X3 11WC1A")
        let company = ble(name: "", manufacturerId: 0x10D7, manufacturerDataHex: "0102")
        let ap = sighting(.wifi, "AA:BB:CC:11:22:33", "GO 3 AABB")
        let engine = SignatureEngine()
        let namedHits = try hit(engine.match(devices: [named], fleets: stock), named.key)
        let companyHits = try hit(engine.match(devices: [company], fleets: stock), company.key)
        let apHits = try hit(engine.match(devices: [ap], fleets: stock), ap.key)
        #expect(namedHits.contains("fleet-insta360"), "X3 serial name")
        #expect(companyHits.contains("fleet-insta360"), "Arashi 0x10D7")
        #expect(apHits.contains("fleet-insta360"), "GO 3 AP")
        #expect(!TextMatch.glob(text: "X300", pattern: "X3 *"))
        #expect(!TextMatch.glob(text: "Ace Hardware", pattern: "Ace Pro*"))
    }

    @Test func oemVehicleCompanyIdsAreStock() throws {
        let ids = stock.associateBy { $0.id }
        func companyId(_ id: String) throws -> Int {
            let fleet = try #require(ids[id])
            return try #require(fleet.rules.first { $0.kind == .manufacturerId }).companyId
        }
        #expect(try companyId("fleet-ford") == 0x0723)
        #expect(try companyId("fleet-honda") == 0x0915)
        #expect(try companyId("fleet-bmw") == 0x05EB)
    }

    @Test func fastPairIsStockOnFe2c() throws {
        let row = try #require(stock.first { $0.id == "fleet-fast-pair" })
        #expect(row.name == "Fast Pair")
        #expect(row.enabled)
        #expect(row.rules.contains { $0.kind == .serviceUuid && $0.text.equals("FE2C", ignoreCase: true) })
    }

    @Test func stockPackRoundTripsAndImportsAsNoOp() throws {
        let json = SignatureExchange.encode(
            pack: SignatureExchange.pack(
                fleets: stock,
                catalogVersion: 37,
                appVersion: "1.0.0",
                exportedAt: "2026-08-27T00:00:00Z"
            )
        )
        #expect(json.hasPrefix("{"))
        #expect(json.contains("\"format\" : \"fieldwatch-signatures\""))
        let pack = try SignatureExchange.parse(text: json)
        #expect(pack.fleets.count == stock.count)
        #expect(pack.format == "fieldwatch-signatures")
        #expect(pack.catalogVersion == 37)

        let (merged, result) = SignatureExchange.merge(existing: stock, incoming: pack.fleets)
        #expect(merged.count == stock.count)
        #expect(result.added == 0)
        #expect(result.merged == 0)
        #expect(result.skipped == stock.count)
        #expect(result.error == nil)
        #expect(result.summary() == "Nothing new. \(stock.count) already on this Mac.")
    }

    @Test func overlayStockReplacesAttentionAndClassKeepsMuteAndExtraRules() throws {
        let localGovee = try #require(stock.first { $0.id == "fleet-govee" })
        let muted = with(localGovee) { $0.enabled = false }
        let extra = MatchRule(kind: .nameContains, text: "MyGovee")
        let customized = with(muted) { $0.rules = muted.rules + [extra] }
        let custom = Fleet(
            id: "custom-bag",
            name: "Bag tag",
            rules: [MatchRule(kind: .nameContains, text: "Bag")],
            builtIn: false,
            kind: .finder
        )
        let incomingGovee = with(localGovee) {
            $0.attentionNote = "Govee Extra attention for test."
            $0.notes = "new notes"
            $0.kind = .home
        }
        let brandNew = Fleet(
            id: "fleet-new-stock",
            name: "New Stock",
            rules: [MatchRule(kind: .nameContains, text: "BrandNew")],
            attentionNote: "Look with your eyes.",
            builtIn: true,
            kind: .surveillance
        )
        let (next, result) = SignatureExchange.overlayStock(existing: [customized, custom], incoming: [incomingGovee, brandNew])
        #expect(result.error == nil)
        #expect(result.added == 1)
        #expect(result.updated == 1)
        let govee = try #require(next.first { $0.id == "fleet-govee" })
        #expect(!govee.enabled)
        #expect(govee.attentionNote == "Govee Extra attention for test.")
        #expect(govee.notes == "new notes")
        #expect(govee.rules.contains { $0.text == "MyGovee" })
        #expect(next.contains { $0.id == "custom-bag" })
        let added = try #require(next.first { $0.id == "fleet-new-stock" })
        #expect(added.attentionNote == "Look with your eyes.")
        #expect(added.builtIn)
    }

    @Test func parsePackDropsUnknownDecodeSourceKeepsSignature() throws {
        let fleet = try #require(stock.first { $0.id == "fleet-govee" })
        let json = SignatureExchange.encode(
            pack: SignatureExchange.pack(fleets: [fleet], catalogVersion: 90, appVersion: "test", exportedAt: "now")
        ).replace("\"source\" : \"manufacturerData\"", "\"source\" : \"vendorIe\"")
        let parsed = try SignatureExchange.parsePack(text: json)
        #expect(parsed.skippedDecode == 1)
        let row = try only(parsed.pack.fleets)
        #expect(row.id == "fleet-govee")
        #expect(row.rules.isNotEmpty)
        #expect(row.decode == nil)
    }

    @Test func overlayStockKeepsLocalDecodeWhenPackSkippedIt() throws {
        let local = try #require(stock.first { $0.id == "fleet-ruuvi" })
        #expect(local.decode != nil)
        let incoming = with(local) {
            $0.decode = nil
            $0.notes = "from pack"
        }
        let (next, result) = SignatureExchange.overlayStock(existing: [local], incoming: [incoming])
        #expect(result.error == nil)
        let row = try #require(next.first { $0.id == "fleet-ruuvi" })
        #expect(row.notes == "from pack")
        #expect(row.decode == local.decode)
    }

    @Test func overlayStockDoesNotClobberCustomWithSameId() throws {
        let stockRow = try #require(stock.first { $0.id == "fleet-govee" })
        let custom = with(stockRow) {
            $0.builtIn = false
            $0.name = "My Govee"
        }
        let incoming = with(stockRow) { $0.attentionNote = "stock attention" }
        let (next, result) = SignatureExchange.overlayStock(existing: [custom], incoming: [incoming])
        #expect(result.updated == 0)
        #expect(result.added == 0)
        #expect(try only(next).name == "My Govee")
        #expect(try only(next).attentionNote.isEmpty)
    }

    @Test func parseAcceptsLegacySpectreFormat() throws {
        let json = SignatureExchange.encode(
            pack: SignatureExchange.pack(
                fleets: stock.take(1),
                catalogVersion: 1,
                appVersion: "1.2.14",
                exportedAt: "2026-09-15T00:00:00Z"
            )
        ).replace("fieldwatch-signatures", "spectre-signatures")
        let pack = try SignatureExchange.parse(text: json)
        #expect(pack.format == "spectre-signatures")
        #expect(pack.fleets.count == 1)
    }

    @Test func customSignatureAddsAndNameCollisionRenames() {
        let custom = Fleet(
            id: "custom-pete-wifi",
            name: "Pete Test AP",
            rules: [MatchRule(kind: .nameGlob, text: "PeteTest*", radio: .wifi)]
        )
        let (added, addResult) = SignatureExchange.merge(existing: stock, incoming: [custom])
        #expect(addResult.added == 1)
        #expect(addResult.renamed == 0)
        #expect(added.contains { $0.id == custom.id && $0.name == "Pete Test AP" && !$0.builtIn })

        let cloneName = with(custom) {
            $0.id = "custom-pete-wifi-2"
            $0.name = "Cisco"
        }
        let (renamed, renameResult) = SignatureExchange.merge(existing: stock, incoming: [cloneName])
        #expect(renameResult.added == 1)
        #expect(renameResult.renamed == 1)
        #expect(renamed.contains { $0.id == "custom-pete-wifi-2" && $0.name == "Cisco (imported)" })
    }

    @Test func importedBodywornFoldsIntoWearables() throws {
        let custom = Fleet(
            id: "custom-old-bodyworn",
            name: "Old body cam",
            rules: [MatchRule(kind: .nameContains, text: "BodyCam")],
            kind: .bodyworn
        )
        let (added, result) = SignatureExchange.merge(existing: stock, incoming: [custom])
        #expect(result.added == 1)
        let row = try #require(added.first { $0.id == custom.id })
        #expect(row.kind == .wearable)
        #expect(added.none { $0.kind == .bodyworn })
    }

    @Test func extraRuleOnStockRowMerges() throws {
        let cisco = try #require(stock.first { $0.id == "fleet-cisco" })
        let extra = with(cisco) {
            $0.rules = cisco.rules + [MatchRule(kind: .nameGlob, text: "PeteCiscoLab*", radio: .wifi)]
        }
        let (merged, result) = SignatureExchange.merge(existing: stock, incoming: [extra])
        #expect(result.merged == 1)
        #expect(result.added == 0)
        let after = try #require(merged.first { $0.id == "fleet-cisco" })
        #expect(after.rules.count == cisco.rules.count + 1)
        #expect(after.rules.contains { $0.text == "PeteCiscoLab*" })
    }

    @Test func sameRulesDifferentIdAreSkipped() throws {
        let cisco = try #require(stock.first { $0.id == "fleet-cisco" })
        let clone = with(cisco) {
            $0.id = "not-cisco"
            $0.name = "Cisco clone"
        }
        let (_, result) = SignatureExchange.merge(existing: stock, incoming: [clone])
        #expect(result.added == 0)
        #expect(result.skipped == 1)
    }

    @Test func parseRejectsLogsAndEmpty() {
        let log = "timestamp,iso,kind,mac,name\n1,x,WIFI,AA:BB:CC:DD:EE:FF,test\n"
        let notPack = #expect(throws: ExchangeError.self) { try SignatureExchange.parse(text: log) }
        #expect(notPack?.message.contains("Not a Fieldwatch signature pack") == true)
        let empty = #expect(throws: ExchangeError.self) { try SignatureExchange.parse(text: "") }
        #expect(empty?.message.contains("empty") == true)
    }

    @Test func matcherStillHitsAfterImportAndRespectsRadio() throws {
        let custom = Fleet(
            id: "custom-pete-wifi",
            name: "Pete Test AP",
            matchAny: true,
            rules: [MatchRule(kind: .nameGlob, text: "PeteTest*", radio: .wifi)]
        )
        let (fleets, result) = SignatureExchange.merge(existing: stock, incoming: [custom])
        #expect(result.added == 1)

        let engine = SignatureEngine()
        let ciscoAp = sighting(.wifi, "00:00:0C:11:22:33", "Campus")
        let unifiVirtual = sighting(.wifi, "82:F9:2C:00:00:01", "Deep Learning", ies: ["00:50:F2", "00:0F:AC", "AC:8B:A9"])
        let peteAp = sighting(.wifi, "AA:BB:CC:11:22:33", "PeteTest-lab")
        let peteBle = sighting(.ble, "AA:BB:CC:11:22:33", "PeteTest-lab")
        let airTag = sighting(.ble, "F4:5C:89:00:00:01", "AirTag")
        let ciscoOnBle = sighting(.ble, "00:00:0C:11:22:33", "Campus")

        let hits = engine.match(devices: [ciscoAp, unifiVirtual, peteAp, peteBle, airTag, ciscoOnBle], fleets: fleets)
        #expect(try hit(hits, ciscoAp.key).contains("fleet-cisco"), "Cisco OUI on Wi-Fi")
        #expect(try hit(hits, unifiVirtual.key).contains("fleet-unifi-ap"), "UniFi vendor IE on virtual BSSID")
        #expect(try hit(hits, peteAp.key).contains("custom-pete-wifi"), "imported Wi-Fi glob")
        #expect(try !hit(hits, peteBle.key).contains("custom-pete-wifi"), "imported Wi-Fi glob must not hit BLE")
        #expect(try hit(hits, airTag.key).contains("fleet-airtag"), "AirTag name on BLE")
        #expect(try !hit(hits, ciscoOnBle.key).contains("fleet-cisco"), "Cisco must not label BLE")

        let again = engine.match(devices: [ciscoAp], fleets: fleets)
        #expect(try hit(again, ciscoAp.key).contains("fleet-cisco"))
    }

    @Test func fieldUnmatchedWifiGetsUniqueApAndVehicleRows() throws {
        let engine = SignatureEngine()
        let ruijie = sighting(.wifi, "F0:74:8D:11:22:33", "MAB Family")
        let reyee = sighting(.wifi, "AA:BB:CC:11:22:33", "@Reyee-s3F2D")
        let dwnet = sighting(.wifi, "2C:67:BE:11:22:33", "MorrellHouse")
        let wavlink = sighting(.wifi, "80:3F:5D:11:22:33", "WAVLINK-N")
        let glinet = sighting(.wifi, "94:83:C4:11:22:33", "Academy - 6805")
        let keepTruckin = sighting(.wifi, "00:25:CA:11:22:33", "KeepTruckin Hotspot - HB492085")
        let pnet = sighting(.wifi, "98:5D:46:11:22:33", "PNet20267513")
        let toyota = sighting(.wifi, "E0:2D:F0:11:22:33", "TOYOTA Sienna_3dabe4e96405")
        let carPlay = sighting(.wifi, "FC:98:16:11:22:33", "BMW 51919 CarPlay")
        let uconnect = sighting(.wifi, "AA:BB:CC:00:00:01", "Uconnect-4326653b")
        let hpPrint = sighting(.wifi, "F0:92:1C:11:22:33", "HP-Print-34-ENVY 4500 series")
        let house = sighting(.wifi, "9C:4F:5F:11:22:33", "Jameson")
        let hits = engine.match(
            devices: [
                ruijie, reyee, dwnet, wavlink, glinet, keepTruckin, pnet,
                toyota, carPlay, uconnect, hpPrint, house,
            ],
            fleets: stock
        )
        #expect(try hit(hits, ruijie.key).contains("fleet-ruijie"), "Ruijie OUI")
        #expect(try hit(hits, reyee.key).contains("fleet-ruijie"), "Reyee factory SSID")
        #expect(try hit(hits, dwnet.key).contains("fleet-dwnet"), "DWnet OUI")
        #expect(try hit(hits, wavlink.key).contains("fleet-wavlink"), "WAVLINK SSID")
        #expect(try hit(hits, glinet.key).contains("fleet-glinet"), "GL.iNet OUI")
        #expect(try hit(hits, keepTruckin.key).contains("fleet-motive"), "KeepTruckin is Motive")
        #expect(try hit(hits, pnet.key).contains("fleet-peoplenet"), "PeopleNet")
        #expect(try hit(hits, toyota.key).contains("fleet-toyota"), "Toyota factory SSID")
        #expect(try hit(hits, carPlay.key).contains("fleet-carplay"), "CarPlay in-car")
        #expect(try hit(hits, uconnect.key).contains("fleet-uconnect"), "Uconnect")
        #expect(try hit(hits, hpPrint.key).contains("fleet-hp"), "HP-Print")
        #expect(try hit(hits, house.key).isEmpty, "house SSID stays unmatched")
    }

    @Test func wifiOui24UniversalClearsLocalBitOnly() {
        #expect(MacUtil.wifiOui24Universal(mac: "02:09:5B:11:22:33") == "00095B")
        #expect(MacUtil.wifiOui24Universal(mac: "1E:3B:F3:AA:BB:CC") == "1C3BF3")
        #expect(MacUtil.wifiOui24Universal(mac: "00:09:5B:11:22:33") == nil)
        #expect(MacUtil.wifiOui24Universal(mac: "03:09:5B:11:22:33") == nil)
        #expect(MacUtil.isRandomized(mac: "02:09:5B:11:22:33"))
    }

    @Test func virtualBssidHitsCatalogOuiNotMacPinOrBle() throws {
        let engine = SignatureEngine()
        let netgearVirtual = sighting(.wifi, "02:09:5B:11:22:33", "Jameson")
        let tplinkVirtual = sighting(.wifi, "1E:3B:F3:AA:BB:CC", "SmithWifi")
        let netgearBle = sighting(.ble, "02:09:5B:11:22:33", "Jameson")
        let burned = sighting(.wifi, "00:09:5B:11:22:33", "Jameson")
        let pinFleet = Fleet(
            id: "custom-pin",
            name: "Pinned NETGEAR radio",
            matchAny: true,
            rules: [MatchRule(kind: .macPrefix, text: "00:09:5B:11:22:33", radio: .wifi)]
        )
        let hits = engine.match(devices: [netgearVirtual, tplinkVirtual, netgearBle, burned], fleets: stock + [pinFleet])
        #expect(try hit(hits, netgearVirtual.key).contains("fleet-netgear"), "NETGEAR virtual BSSID")
        #expect(try hit(hits, tplinkVirtual.key).contains("fleet-tplink"), "TP-Link virtual BSSID")
        #expect(try !hit(hits, netgearBle.key).contains("fleet-netgear"), "BLE must not recover Wi-Fi OUI")
        #expect(try hit(hits, burned.key).contains("fleet-netgear"), "universal NETGEAR still hits")
        #expect(try !hit(hits, netgearVirtual.key).contains("custom-pin"), "MAC pin does not follow virtual BSSID")
        #expect(try hit(hits, burned.key).contains("custom-pin"), "MAC pin still exact")
        #expect(netgearVirtual.randomized, "virtual still marked randomized")
    }

    @Test func phoneHotspotHuaweiAndPlumeCatchFactoryWifi() throws {
        let engine = SignatureEngine()
        let androidAp = sighting(.wifi, "C2:11:22:33:44:55", "AndroidAP_1234")
        let galaxy = sighting(.wifi, "C2:11:22:33:44:56", "Galaxy A54 5G")
        let galaxyDash = sighting(.wifi, "C2:11:22:33:44:57", "Galaxy-A54-XXXX")
        let pixel = sighting(.wifi, "C2:11:22:33:44:58", "Pixel 8")
        let iphone = sighting(.wifi, "C2:11:22:33:44:59", "Pete's iPhone")
        let custom = sighting(.wifi, "C2:11:22:33:44:5A", "PeteHotspot")
        let galaxyBle = sighting(.ble, "C2:11:22:33:44:5B", "Galaxy A54 5G")
        let huaweiName = sighting(.wifi, "C2:AA:BB:CC:DD:01", "HUAWEI-B535")
        let huaweiOui = sighting(.wifi, "00:18:82:11:22:33", "Jameson")
        let plumeOui = sighting(.wifi, "60:B4:F7:11:22:33", "SmithWifi")
        let superPod = sighting(.wifi, "C2:AA:BB:CC:DD:02", "SuperPod-setup")
        let hits = engine.match(
            devices: [
                androidAp, galaxy, galaxyDash, pixel, iphone, custom, galaxyBle,
                huaweiName, huaweiOui, plumeOui, superPod,
            ],
            fleets: stock
        )
        #expect(try hit(hits, androidAp.key).contains("fleet-phone-hotspot"), "AndroidAP")
        #expect(try hit(hits, galaxy.key).contains("fleet-phone-hotspot"), "Galaxy space")
        #expect(try hit(hits, galaxyDash.key).contains("fleet-phone-hotspot"), "Galaxy dash")
        #expect(try hit(hits, pixel.key).contains("fleet-phone-hotspot"), "Pixel")
        #expect(try hit(hits, iphone.key).contains("fleet-apple-device"), "iPhone stays Apple Device")
        #expect(try !hit(hits, iphone.key).contains("fleet-phone-hotspot"), "iPhone is not Phone hotspot")
        #expect(try hit(hits, custom.key).isEmpty, "custom hotspot unmatched")
        #expect(try !hit(hits, galaxyBle.key).contains("fleet-phone-hotspot"), "Galaxy BLE is not Phone hotspot")
        #expect(try hit(hits, huaweiName.key).contains("fleet-huawei"), "Huawei factory SSID")
        #expect(try hit(hits, huaweiOui.key).contains("fleet-huawei"), "Huawei OUI renamed")
        #expect(try hit(hits, plumeOui.key).contains("fleet-plume"), "Plume OUI renamed")
        #expect(try hit(hits, superPod.key).contains("fleet-plume"), "SuperPod name")
    }

    @Test func ringSsidOnUgsiOuiIsRingNotFlock() throws {
        let engine = SignatureEngine()
        let ring = sighting(.wifi, "E0:4F:43:DC:6C:94", "Ring-dc6c94")
        let module = sighting(.wifi, "70:C9:4E:11:22:33", "Home")
        let pole = sighting(.wifi, "B4:1E:52:00:00:01", "Flock-ABCDEF")
        let hits = engine.match(devices: [ring, module, pole], fleets: stock)
        let ringHits = try hit(hits, ring.key)
        let moduleHits = try hit(hits, module.key)
        let poleHits = try hit(hits, pole.key)
        #expect(ringHits.contains("fleet-ring"), "Ring glob")
        #expect(!ringHits.contains("fleet-flock-cameras"), "UGSI is not Flock")
        #expect(!ringHits.contains("fleet-liteon-camera-radio"), "UGSI is not LiteOn row")
        #expect(moduleHits.contains("fleet-liteon-camera-radio"), "LiteOn prefix labels module row")
        #expect(!moduleHits.contains("fleet-flock-cameras"), "LiteOn prefix is not Extra-attention Flock")
        #expect(poleHits.contains("fleet-flock-cameras"), "Flock IEEE + name")
        let ringDevice = with(ring) { $0.fleetIds = Array(ringHits) }
        let moduleDevice = with(module) { $0.fleetIds = Array(moduleHits) }
        let poleDevice = with(pole) { $0.fleetIds = Array(poleHits) }
        #expect(ringDevice.attentionNotes(fleets: stock).none { $0.0.contains("Flock") })
        #expect(moduleDevice.attentionNotes(fleets: stock).isEmpty)
        #expect(poleDevice.attentionNotes(fleets: stock).contains { $0.0 == "Flock Safety Cameras" })
        let ringGuess = DeviceExplain.guess(device: ringDevice, signatureNames: ["LiteOn camera radio", "Ring"])
        #expect(ringGuess.headline.contains("Ring", ignoreCase: true), "\(ringGuess.headline)")
    }

    @Test func xuntongMfgHitsPenguinNotRaven() throws {
        let engine = SignatureEngine()
        let pack = ble(name: "", manufacturerId: 0x09C8, mac: "AA:BB:CC:DD:EE:08")
        let ravenNamed = ble(name: "RAVEN-1", mac: "AA:BB:CC:DD:EE:09")
        let hits = engine.match(devices: [pack, ravenNamed], fleets: stock)
        #expect(try hit(hits, pack.key).contains("fleet-penguin"), "XUNTONG is Penguin battery")
        #expect(try !hit(hits, pack.key).contains("fleet-raven"), "XUNTONG is not Raven")
        #expect(try hit(hits, ravenNamed.key).contains("fleet-raven"), "RAVEN name stays Raven")
        #expect(try !hit(hits, ravenNamed.key).contains("fleet-penguin"), "RAVEN name is not Penguin")
    }

    @Test func axonBwcdeviceMatchesServiceDataNotName() throws {
        let engine = SignatureEngine()
        let tagged = with(ble(name: "", mac: "AA:BB:CC:11:22:33")) {
            $0.facts = RadioFacts(serviceData: [ServiceDataRecord(uuid: "FE6B", dataHex: "41584A414E5553425743444556494345")])
        }
        let reversed = with(ble(name: "", mac: "AA:BB:CC:11:22:34")) {
            $0.facts = RadioFacts(serviceData: [ServiceDataRecord(uuid: "FC81", dataHex: "454349564544435742")])
        }
        let namedOnly = ble(name: "BWCDEVICE", mac: "AA:BB:CC:11:22:35")
        let hits = engine.match(devices: [tagged, reversed, namedOnly], fleets: stock)
        #expect(try hit(hits, tagged.key).contains("fleet-axon"), "BWCDEVICE in service data")
        #expect(try hit(hits, reversed.key).contains("fleet-axon"), "byte-reversed BWCDEVICE")
        #expect(try !hit(hits, namedOnly.key).contains("fleet-axon"), "name-only BWCDEVICE is not Axon")
    }

    @Test func dultFcb2ServiceDataHitsNotUuidList() throws {
        let engine = SignatureEngine()
        let tagged = with(ble(name: "", mac: "AA:BB:CC:11:22:40")) {
            $0.facts = RadioFacts(serviceData: [ServiceDataRecord(uuid: "FCB2", dataHex: "0100")])
        }
        let uuidOnly = bleUuid("AA:BB:CC:11:22:41", "", "FCB2")
        let hits = engine.match(devices: [tagged, uuidOnly], fleets: stock)
        #expect(try hit(hits, tagged.key).contains("fleet-dult"), "FCB2 service data is DULT")
        #expect(try !hit(hits, uuidOnly.key).contains("fleet-dult"), "FCB2 UUID list is not DULT")
        #expect(try only(stock.filter { $0.id == "fleet-dult" }).attentionNote.isBlank)
    }

    @Test func ravenWifiDirectSsidHitsRavenOnly() throws {
        let engine = SignatureEngine()
        let raven = sighting(.wifi, "00:0A:F5:86:56:DD", "DIRECT-rR-Raven-607")
        let genericDirect = sighting(.wifi, "02:11:22:33:44:55", "DIRECT-xy-LivingRoom")
        let hits = engine.match(devices: [raven, genericDirect], fleets: stock)
        #expect(try hit(hits, raven.key).contains("fleet-raven"), "Raven SSID")
        #expect(try !hit(hits, raven.key).contains("fleet-unknown"), "Raven is not Unknown")
        #expect(try !hit(hits, genericDirect.key).contains("fleet-unknown"), "generic DIRECT- is unmatched")
        #expect(try hit(hits, genericDirect.key).isEmpty, "generic DIRECT- has no stock family")
    }

    @Test func digitalAllyOuiAndFirstVuNameHit() throws {
        let engine = SignatureEngine()
        let oui = sighting(.ble, "00:23:BD:11:22:33", "")
        let named = sighting(.wifi, "02:11:22:33:44:55", "FirstVu-PRO")
        let hits = engine.match(devices: [oui, named], fleets: stock)
        #expect(try hit(hits, oui.key).contains("fleet-digital-ally"), "Digital Ally OUI")
        #expect(try hit(hits, named.key).contains("fleet-digital-ally"), "FirstVu name")
    }

    @Test func pendantUuidsAndNamesHit() throws {
        let engine = SignatureEngine()
        let limitless = bleUuid("AA:BB:CC:DD:EE:01", "Limitless", "632DE001-604C-446B-A80F-7963E950F3FB")
        let bee = bleUuid("AA:BB:CC:DD:EE:02", "Bee Pioneer", "03D5D5C4-A86C-11EE-9D89-8F2089A49E7E")
        let friend = bleUuid("AA:BB:CC:DD:EE:03", "", "1A3FD0E7-B1F3-AC9E-2E49-B647B2C4F8DA")
        let omi = bleUuid("AA:BB:CC:DD:EE:04", "Omi", "")
        let naomi = bleUuid("AA:BB:CC:DD:EE:05", "Naomi", "")
        let arduino = bleUuid("AA:BB:CC:DD:EE:06", "ESP32", "19B10000-E8F2-537E-4F6C-D104768A1214")
        let hits = engine.match(devices: [limitless, bee, friend, omi, naomi, arduino], fleets: stock)
        #expect(try hit(hits, limitless.key).contains("fleet-limitless"), "Limitless UUID")
        #expect(try hit(hits, bee.key).contains("fleet-bee"), "Bee UUID")
        #expect(try hit(hits, friend.key).contains("fleet-friend-pendant"), "Friend UUID")
        #expect(try hit(hits, omi.key).contains("fleet-omi"), "Omi name")
        #expect(try !hit(hits, naomi.key).contains("fleet-omi"), "Naomi is not Omi")
        #expect(try !hit(hits, arduino.key).contains("fleet-omi"), "Arduino 19B10000 is not Omi")
    }

    @Test func overlayStockDropsRetiredUnknownSignature() {
        let unknown = Fleet(
            id: "fleet-unknown",
            name: "Unknown Signature",
            rules: [MatchRule(kind: .nameContains, text: "DIRECT-")],
            builtIn: true,
            kind: .other
        )
        let (next, _) = SignatureExchange.overlayStock(existing: [unknown] + stock.take(3), incoming: stock.take(3))
        #expect(!next.contains { $0.id == "fleet-unknown" })
    }

    @Test func carlinkAdapterHitsGlobAndPanasonicOuiNotAlpsAlone() throws {
        let engine = SignatureEngine()
        let named = sighting(.wifi, "CC:57:63:11:22:33", "CARLINK-7D0AF4")
        let randNamed = sighting(.wifi, "C2:11:22:33:44:55", "CARLINK-B6789A")
        let panasonicRenamed = sighting(.wifi, "CC:57:63:AA:BB:CC", "MyCar")
        let zhuolian = sighting(.wifi, "68:8F:C9:11:22:33", "CARLINK-ABCDEF")
        let toyotaAlps = sighting(.wifi, "E0:2D:F0:11:22:33", "TOYOTA Sienna_3dabe4e96405")
        let alpsHouse = sighting(.wifi, "E0:2D:F0:44:55:66", "Jameson")
        let hits = engine.match(devices: [named, randNamed, panasonicRenamed, zhuolian, toyotaAlps, alpsHouse], fleets: stock)
        #expect(try hit(hits, named.key).contains("fleet-carlink"), "Panasonic + glob")
        #expect(try hit(hits, randNamed.key).contains("fleet-carlink"), "randomized BSSID still hits glob")
        #expect(try hit(hits, panasonicRenamed.key).contains("fleet-carlink"), "Panasonic OUI renamed SSID")
        #expect(try hit(hits, zhuolian.key).contains("fleet-carlink"), "Zhuolian + glob")
        #expect(try !hit(hits, toyotaAlps.key).contains("fleet-carlink"), "Toyota on Alps Alpine is not CARLINK")
        #expect(try hit(hits, toyotaAlps.key).contains("fleet-toyota"), "Toyota factory SSID still Toyota")
        #expect(try !hit(hits, alpsHouse.key).contains("fleet-carlink"), "Alps Alpine house SSID is not CARLINK")
    }

    @Test func rokuHiddenWifiDirectHitsVendorIeNotWps() throws {
        let engine = SignatureEngine()
        let hidden = sighting(.wifi, "C2:D2:F3:E1:1D:02", "", ies: ["00:50:F2", "50:6F:9A", "C8:3A:6B"])
        let wpsOnly = sighting(.wifi, "C2:D2:F3:E1:1D:03", "", ies: ["00:50:F2", "50:6F:9A"])
        let factory = sighting(.wifi, "AA:BB:CC:00:00:02", "DIRECT-roku-abcd")
        let burned = sighting(.wifi, "C8:3A:6B:11:22:33", "")
        let onBle = sighting(.ble, "C8:3A:6B:11:22:33", "")
        let hits = engine.match(devices: [hidden, wpsOnly, factory, burned, onBle], fleets: stock)
        #expect(try hit(hits, hidden.key).contains("fleet-roku"), "Roku vendor IE on randomized BSSID")
        #expect(try !hit(hits, wpsOnly.key).contains("fleet-roku"), "WPS/P2P IEs are not Roku")
        #expect(try hit(hits, factory.key).contains("fleet-roku"), "DIRECT-roku factory SSID")
        #expect(try hit(hits, burned.key).contains("fleet-roku"), "Roku burned-in OUI")
        #expect(try !hit(hits, onBle.key).contains("fleet-roku"), "Roku must not label BLE")
    }

    @Test func franklinRg3100HitsOuiAndFactorySsidNotQualcommIe() throws {
        let engine = SignatureEngine()
        let burned = sighting(.wifi, "50:FB:FF:02:CA:C8", "RG3100-8434 guest", ies: ["00:50:F2", "8C:FD:F0"])
        let renamed = sighting(.wifi, "50:FB:FF:11:22:33", "HouseNet")
        let factoryOnly = sighting(.wifi, "AA:BB:CC:00:00:03", "RG3100-8434 guest")
        let qualcommOnly = sighting(.wifi, "AA:BB:CC:00:00:04", "HouseNet", ies: ["8C:FD:F0"])
        let electric = sighting(.wifi, "00:12:27:11:22:33", "Pump")
        let hits = engine.match(devices: [burned, renamed, factoryOnly, qualcommOnly, electric], fleets: stock)
        #expect(try hit(hits, burned.key).contains("fleet-franklin"), "Franklin OUI + RG3100 guest")
        #expect(try hit(hits, renamed.key).contains("fleet-franklin"), "Franklin OUI renamed SSID")
        #expect(try hit(hits, factoryOnly.key).contains("fleet-franklin"), "RG3100 factory SSID")
        #expect(try !hit(hits, qualcommOnly.key).contains("fleet-franklin"), "Qualcomm chip IE is not Franklin")
        #expect(try !hit(hits, electric.key).contains("fleet-franklin"), "Franklin Electric is not the gateway row")
    }

    @Test func samsungApplianceAndEcoWaterFactorySsids() throws {
        let engine = SignatureEngine()
        let fridge = sighting(.wifi, "1C:E8:9E:01:8F:92", "[fridge]_E30AJT5133207Z")
        let oven = sighting(.wifi, "34:FC:99:11:22:33", "[oven] Samsung")
        let h2o = sighting(.wifi, "04:7B:CB:D1:14:00", "H2O-047bcbd11400")
        let house = sighting(.wifi, "CE:BE:8F:24:DC:E3", "IonCannon")
        let guest = sighting(.wifi, "A2:53:22:C6:84:42", "LOB_Guest")
        let h2oBar = sighting(.wifi, "AA:BB:CC:00:00:05", "H2O-Lounge")
        let hits = engine.match(devices: [fridge, oven, h2o, house, guest, h2oBar], fleets: stock)
        #expect(try hit(hits, fridge.key).contains("fleet-samsung-appliance"), "[fridge] setup")
        #expect(try hit(hits, oven.key).contains("fleet-samsung-appliance"), "[oven] Samsung")
        #expect(try hit(hits, h2o.key).contains("fleet-ecowater"), "H2O- + 12")
        #expect(try hit(hits, house.key).isEmpty, "house SSID stays unmatched")
        #expect(try hit(hits, guest.key).isEmpty, "guest SSID stays unmatched")
        #expect(try hit(hits, h2oBar.key).isEmpty, "short H2O- is not EcoWater")
    }

    @Test func merakiApDoesNotDualChipCiscoVendorIe() throws {
        let meraki = sighting(.wifi, "00:18:0A:11:22:33", "Campus", ies: ["00:50:F2", "00:0F:AC", "00:00:0C"])
        let cisco = sighting(.wifi, "00:00:0C:11:22:33", "Campus", ies: ["00:00:0C"])
        let hits = SignatureEngine().match(devices: [meraki, cisco], fleets: stock)
        #expect(try hit(hits, meraki.key).contains("fleet-meraki"), "Meraki OUI")
        #expect(try !hit(hits, meraki.key).contains("fleet-cisco"), "Meraki must not dual-chip Cisco vendor IE")
        #expect(try hit(hits, cisco.key).contains("fleet-cisco"), "Cisco OUI still Cisco")
        #expect(try !hit(hits, cisco.key).contains("fleet-meraki"), "Cisco must not take Meraki")
    }

    @Test func createFromDeviceSkipsDirectGlob() throws {
        let printer = sighting(.wifi, "AC:F4:66:A4:BC:A8", "DIRECT-HP-DeskJet-A1B2")
        let fleet = SignatureEngine().suggestFleet(device: printer)
        #expect(fleet.rules.contains { $0.kind == .macPrefix && $0.text == printer.mac })
        #expect(
            !fleet.rules.contains { $0.kind == .nameGlob && $0.text.uppercased().hasPrefix("DIRECT") },
            "DIRECT- must not become DIRECT*"
        )
        let nameRule = try only(fleet.rules.filter { $0.kind == .nameContains })
        #expect(nameRule.text == "DIRECT-HP-DeskJet-A1B2")
        #expect(SignatureCandidates.isOverbroadCreateName(text: "DIRECT*"))
        #expect(SignatureCandidates.isOverbroadCreateName(text: "DIRECT-*"))
        #expect(!SignatureCandidates.isOverbroadCreateName(text: "DIRECT-HP-DeskJet-A1B2"))
        #expect(!SignatureCandidates.isOverbroadCreateName(text: "HP-Print*"))
    }

    @Test func custom128BitUuidDoesNotAliasTo0000() {
        let epson = "802A0000-4EF4-4E59-B573-2BED4A4AC159"
        let sensorPush = "EF090000-11D6-42BA-93B8-9DD7EC090AA9"
        #expect(!uuidAliases(raw: epson).contains { uuidAliases(raw: sensorPush).contains($0) })
        #expect(!uuidAliases(raw: epson).contains("0000"))
        #expect(!uuidAliases(raw: sensorPush).contains("0000"))
        #expect(uuidAliases(raw: "FD44").contains("FD44"))
        #expect(uuidAliases(raw: "0000FD44-0000-1000-8000-00805F9B34FB").contains("FD44"))
    }

    @Test func epsonEt4800BleIsNotSensorPush() throws {
        let radio = with(sighting(.ble, "5A:05:D9:2A:CE:B0", "ET-4800 Series")) {
            $0.serviceUuids = ["802A0000-4EF4-4E59-B573-2BED4A4AC159"]
        }
        let hits = try hit(SignatureEngine().match(devices: [radio], fleets: stock), radio.key)
        #expect(!hits.contains("fleet-sensorpush"), "Epson printer UUID is not SensorPush")
    }

    @Test func createFromDeviceKeepsProductGlob() {
        let radio = sighting(.wifi, "00:11:22:33:44:55", "RG3100-7A21")
        let fleet = SignatureEngine().suggestFleet(device: radio)
        #expect(fleet.rules.contains { $0.kind == .nameGlob && $0.text == "RG3100*" })
        #expect(!fleet.rules.contains { $0.kind == .nameContains })
    }

    // MARK: - Helpers

    /// Kotlin `Map.getValue` — the key must be present.
    private func hit<V>(_ hits: [String: V], _ key: String) throws -> V {
        try #require(hits[key], "no match entry for \(key)")
    }

    /// Kotlin `single()`.
    private func only<T>(_ items: [T]) throws -> T {
        try #require(items.count == 1, "expected one element, got \(items.count)")
        return items[0]
    }

    /// Kotlin `copy(...)`.
    private func with<T>(_ value: T, _ change: (inout T) -> Void) -> T {
        var copy = value
        change(&copy)
        return copy
    }

    private func ble(
        name: String,
        manufacturerId: Int? = nil,
        manufacturerDataHex: String = "",
        mac: String = "AA:BB:CC:DD:EE:01"
    ) -> Sighting {
        with(sighting(.ble, mac, name)) {
            $0.manufacturerId = manufacturerId
            $0.manufacturerDataHex = manufacturerDataHex
            $0.facts = manufacturerId == nil
                ? RadioFacts()
                : RadioFacts(mfgRecords: [MfgRecord(companyId: manufacturerId!, dataHex: manufacturerDataHex)])
        }
    }

    private func bleUuid(_ mac: String, _ name: String, _ uuid: String) -> Sighting {
        Sighting(
            key: "BLE:\(mac)", kind: .ble, mac: mac, name: name, rssi: -40, rssiMin: -40, rssiMax: -40,
            channel: 0, frequencyMhz: 0, vendor: nil, randomized: true, hiddenSsid: false,
            serviceUuids: uuid.isBlank ? [] : [uuid], manufacturerId: nil, manufacturerDataHex: "",
            rawHex: "", extras: "", firstSeen: 1, lastSeen: 1, hitCount: 1, fleetIds: [],
            rssiHistory: [], presence: []
        )
    }

    private func sighting(_ kind: RadioKind, _ mac: String, _ name: String = "", ies: [String] = []) -> Sighting {
        let firstOctet = Int(mac.take(2), radix: 16) ?? 0
        return Sighting(
            key: "\(kind.rawValue):\(mac)", kind: kind, mac: mac, name: name, rssi: -40, rssiMin: -40, rssiMax: -40,
            channel: 1, frequencyMhz: 2412, vendor: nil,
            randomized: kind == .ble || (firstOctet & 0x02) != 0,
            hiddenSsid: false, serviceUuids: [], manufacturerId: nil, manufacturerDataHex: "",
            rawHex: "", extras: "", firstSeen: 1, lastSeen: 1, hitCount: 1, fleetIds: [],
            rssiHistory: [], presence: [], vendorIeOuis: ies
        )
    }
}
