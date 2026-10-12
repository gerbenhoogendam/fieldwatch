import Foundation
import Testing
@testable import FieldwatchCore

// Port of SitTest.kt. Kotlin `x.copy(...)` → `with(x) { $0.field = ... }`.

private func with<T>(_ v: T, _ f: (inout T) -> Void) -> T {
    var c = v
    f(&c)
    return c
}

private func settings(tagLocation: Bool, debriefShowUnmatchedRandomBle: Bool = false, debriefShowAllRadios: Bool = false) -> AppSettings {
    var s = AppSettings()
    s.tagLocation = tagLocation
    s.debriefShowUnmatchedRandomBle = debriefShowUnmatchedRandomBle
    s.debriefShowAllRadios = debriefShowAllRadios
    return s
}

struct SitTest {
    private let axon = Fleet(
        id: "fleet-axon",
        name: "Axon",
        attentionNote: "Body-worn, in-car, dock, or TASER.",
        kind: .lawEnforcement
    )
    private let remote = Fleet(
        id: "fleet-remote-id",
        name: "Remote ID",
        kind: .drone
    )
    private var fleets: [Fleet] { [axon, remote] }

    @Test func blankNameBecomesTimestamp() {
        let name = Sit.resolveName(raw: "  ", at: 0, locale: Locale(identifier: "en_US"))
        #expect(name.isNotBlank)
        #expect(!name.isBlank)
        #expect(Sit.resolveName(raw: " parking lot ", at: 0) == "parking lot")
        #expect(Sit.clipName(raw: String(repeating: "x", count: 80)).count == Sit.NAME_MAX)
    }

    @Test func dropWarningNamesOldestWhenAtCap() throws {
        #expect(Sit.dropWarning(closed: []) == nil)
        let nine = (1...9).map { i in
            SitSummary(id: "\(i)", name: "s\(i)", startAt: i)
        }
        #expect(Sit.dropWarning(closed: nine) == nil)
        let ten = [SitSummary(id: "new", name: "newest", startAt: 20)] +
            nine +
            [SitSummary(id: "old", name: "oldest", startAt: 1)]
        let warn = try #require(Sit.dropWarning(closed: ten))
        #expect(warn.contains("oldest"))
        #expect(warn.contains("10"))
    }

    @Test func startCopiesCurrentlyHeardAndSkipsGone() {
        let cam = radio("BLE:AA:AA:AA:AA:AA:01", fleetIds: ["fleet-axon"], firstSeen: 1_000)
        let gone = radio("BLE:AA:AA:AA:AA:AA:02", lastSeen: 1_000, gone: true)
        let session = SitSession.start(
            name: "lot",
            now: 10_000,
            heard: [cam, gone],
            fleets: fleets,
            watchDeviceKeys: [],
            watchedFleetIds: []
        )
        #expect(session.summary.name == "lot")
        #expect(session.radioCount == 1)
        let row = session.sightings().single { _ in true }
        #expect(row.key == cam.key)
        #expect(row.firstSeen == 1_000)
        #expect(row.attentionNotes(fleets: fleets).isNotEmpty)
    }

    @Test func arrivedAfterStartVsAlreadyHere() {
        let here = radio("BLE:AA:AA:AA:AA:AA:01", firstSeen: 1_000, lastSeen: 10_000)
        let session = SitSession.start(
            name: "walk",
            now: 10_000,
            heard: [here],
            fleets: fleets,
            watchDeviceKeys: [],
            watchedFleetIds: []
        )
        let later = radio("BLE:BB:BB:BB:BB:BB:02", firstSeen: 11_000, lastSeen: 11_000)
        session.ingest(device: later, fleets: fleets, watchDeviceKeys: [], watchedFleetIds: [])
        let already = session.sightings().first { $0.key == here.key }!
        let arrived = session.sightings().first { $0.key == later.key }!
        #expect(already.firstSeen < session.summary.startAt)
        #expect(arrived.firstSeen >= session.summary.startAt)
    }

    @Test func unnamedBleEvictsBeforeExtraAttention() {
        let session = SitSession.start(
            name: "plaza",
            now: 1,
            heard: [],
            fleets: fleets,
            watchDeviceKeys: [],
            watchedFleetIds: []
        )
        let cam = radio("BLE:CC:CC:CC:CC:CC:01", fleetIds: ["fleet-axon"], lastSeen: 1)
        session.ingest(device: cam, fleets: fleets, watchDeviceKeys: [], watchedFleetIds: [])
        for i in 0..<Sit.RADIO_CAP {
            let mac = "AA:AA:AA:AA:\(hex2(i / 256)):\(hex2(i % 256))"
            session.ingest(
                device: radio("BLE:\(mac)", mac: mac, fleetIds: [], lastSeen: i + 2),
                fleets: fleets,
                watchDeviceKeys: [],
                watchedFleetIds: []
            )
        }
        #expect(session.radioCount <= Sit.RADIO_CAP)
        #expect(session.sightings().contains { $0.key == cam.key })
        #expect(session.atCap)
    }

    @Test func tightMemoryRefusesNewUnpinnedKeepsPinned() {
        let session = SitSession.start(
            name: "tight",
            now: 1,
            heard: [],
            fleets: fleets,
            watchDeviceKeys: [],
            watchedFleetIds: []
        )
        let clutter = radio("BLE:AA:AA:AA:AA:AA:01", lastSeen: 1)
        let later = radio("BLE:AA:AA:AA:AA:AA:01", firstSeen: 1, lastSeen: 5)
        let other = radio("BLE:BB:BB:BB:BB:BB:02", lastSeen: 2)
        let cam = radio("BLE:CC:CC:CC:CC:CC:03", fleetIds: ["fleet-axon"], lastSeen: 3)
        #expect(session.ingest(device: clutter, fleets: fleets, watchDeviceKeys: [], watchedFleetIds: [], tight: false))
        #expect(session.ingest(device: later, fleets: fleets, watchDeviceKeys: [], watchedFleetIds: [], tight: true))
        #expect(!session.ingest(device: other, fleets: fleets, watchDeviceKeys: [], watchedFleetIds: [], tight: true))
        #expect(session.ingest(device: cam, fleets: fleets, watchDeviceKeys: [], watchedFleetIds: [], tight: true))
        let keys = Set(session.sightings().map { $0.key })
        #expect(keys.contains(clutter.key))
        #expect(session.sightings().first { $0.key == clutter.key }!.lastSeen == 5)
        #expect(!keys.contains(other.key))
        #expect(keys.contains(cam.key))
    }

    @Test func payloadAndWatchlistArePinned() {
        let session = SitSession.start(
            name: "air",
            now: 1,
            heard: [],
            fleets: fleets,
            watchDeviceKeys: ["BLE:WATCH"],
            watchedFleetIds: []
        )
        let drone = radio(
            "BLE:DD:DD:DD:DD:DD:01",
            fleetIds: ["fleet-remote-id"],
            lastSeen: 1,
            payloadLat: 40.0,
            payloadLon: -74.0
        )
        let named = radio("BLE:WATCH", lastSeen: 1)
        session.ingest(device: drone, fleets: fleets, watchDeviceKeys: ["BLE:WATCH"], watchedFleetIds: [])
        session.ingest(device: named, fleets: fleets, watchDeviceKeys: ["BLE:WATCH"], watchedFleetIds: [])
        for i in 0..<Sit.RADIO_CAP {
            let mac = "BB:BB:BB:BB:\(hex2(i / 256)):\(hex2(i % 256))"
            session.ingest(
                device: radio("BLE:\(mac)", mac: mac, lastSeen: i + 2),
                fleets: fleets,
                watchDeviceKeys: ["BLE:WATCH"],
                watchedFleetIds: []
            )
        }
        let keys = Set(session.sightings().map { $0.key })
        #expect(keys.contains(drone.key))
        #expect(keys.contains(named.key))
    }

    @Test func debriefWindowUsesSitBounds() {
        let cam = radio("BLE:AA:AA:AA:AA:AA:01", fleetIds: ["fleet-axon"], firstSeen: 5_000, lastSeen: 20_000)
        let window = DebriefWindow(startAt: 10_000, endAt: 30_000, sitName: "lot")
        let doc = DebriefReport.document(
            devices: [cam],
            fleets: fleets,
            settings: settings(tagLocation: false),
            operatorPath: [],
            now: 40_000,
            window: window
        )
        #expect(doc.heading.contains("lot"))
        #expect(doc.windowLine.contains("sit lot"))
        #expect(doc.disclaimer.contains("named sit"))
        #expect(!doc.windowLine.contains("last 15 minutes"))
    }

    @Test func debriefListsObserverNotesSection() {
        let now = nowMs()
        let van = radio("WIFI:AA:AA:AA:AA:AA:01", firstSeen: now - 60_000, lastSeen: now)
        let other = radio("WIFI:AA:AA:AA:AA:AA:02", firstSeen: now - 60_000, lastSeen: now)
        let doc = DebriefReport.document(
            devices: [van, other],
            fleets: fleets,
            settings: settings(tagLocation: false),
            operatorPath: [],
            now: now,
            customNames: [van.key: "fleet van"],
            observerNotes: [van.key: "lot B north"]
        )
        let titles = doc.sections.map { $0.title }
        #expect(titles[1] == "Where you were")
        #expect(titles[2] == "Observer notes")
        let section = doc.sections.single { $0.title == "Observer notes" }
        #expect(section.body.contains("fleet van"))
        #expect(section.body.contains("lot B north"))
        #expect(section.body.contains("AA:AA:AA:AA:AA:01"))
        #expect(!section.body.contains("AA:AA:AA:AA:AA:02"))
        #expect(!doc.toPlainText().contains("Observer: lot B north"))
    }

    @Test func debriefNotesAFloodWithoutRaisingTracking() {
        let now = 1_700_000_000_000
        let burst = FloodBurst(
            at: now - 60_000,
            popupCount: 8,
            nameCount: 0,
            families: ["Apple proximity pairing"],
            medianRssi: -48
        )
        let outside = with(burst) { $0.at = now - 2 * 60 * 60_000; $0.popupCount = 99 }
        let doc = DebriefReport.document(
            devices: [],
            fleets: fleets,
            settings: settings(tagLocation: false),
            operatorPath: [],
            now: now,
            window: DebriefWindow(startAt: now - 15 * 60_000, endAt: now, sitName: "lot"),
            floods: [outside, burst]
        )
        let text = doc.toPlainText()
        let section = doc.sections.single { $0.title == "Flood" }
        #expect(text.contains("FLOOD"))
        #expect(section.body.contains(FloodBurst.INTRO))
        #expect(section.body.contains("Pairing flood"))
        #expect(section.body.contains("8 new addresses: Apple proximity pairing"))
        #expect(section.body.contains("about -48 dBm"))
        #expect(!section.body.contains("99 new"))
        #expect(!section.alert)
        #expect(!doc.trackingAlert)
        #expect(doc.sections.none { $0.title == "Possible trackers with you" })
        #expect(doc.sections.none { $0.title == "Possible tail" })
        let titles = doc.sections.map { $0.title }
        #expect(titles.indexOfFirst { $0 == "Flood" } > titles.indexOfFirst { $0 == "Anomalies" })
        #expect(titles.indexOfFirst { $0 == "Flood" } < titles.indexOfFirst { $0 == "Privacy" })
    }

    @Test func debriefUsesTheWifiFloodIntroAndLeavesThoseAddressesOut() {
        let now = 1_700_000_000_000
        let window = DebriefWindow(startAt: now - 15 * 60_000, endAt: now, sitName: "lobby")
        let real = radio(
            "WIFI:AC:23:3F:11:22:33",
            firstSeen: now - 60_000,
            lastSeen: now,
            randomized: false,
            name: "FrontDesk",
            kind: .wifi
        )
        let floodA = radio(
            "WIFI:02:00:00:00:00:11",
            firstSeen: now - 30_000,
            lastSeen: now - 30_000,
            name: "SpamOne",
            kind: .wifi
        )
        let burst = FloodBurst(
            at: now - 30_000,
            popupCount: 15,
            nameCount: 0,
            medianRssi: -34,
            keys: [floodA.key],
            wifi: true
        )
        let doc = DebriefReport.document(
            devices: [real, floodA],
            fleets: fleets,
            settings: settings(tagLocation: false),
            operatorPath: [],
            now: now,
            window: window,
            customNames: [real.key: "FrontDesk"],
            floods: [burst]
        )
        let section = doc.sections.single { $0.title == "Flood" }
        #expect(section.body.contains(FloodBurst.WIFI_INTRO))
        #expect(!section.body.contains(FloodBurst.INTRO))
        #expect(section.body.contains("Wi-Fi beacon flood"))
        #expect(section.body.contains("15 new names"))
        #expect(section.body.contains("1 address from this burst is left out of the counts and lists below."))
        #expect(doc.meta.first { $0.0 == "Radios" }!.1 == "1")
        #expect(!doc.toPlainText().contains("02:00:00:00:00:11"))
        #expect(doc.toPlainText().contains("FrontDesk"))
    }

    @Test func noteFloodsKeepsWifiBesideBluetoothAtTheSameTime() {
        let session = SitSession.start(
            name: "lot",
            now: 1_000,
            heard: [],
            fleets: fleets,
            watchDeviceKeys: [],
            watchedFleetIds: []
        )
        let ble = FloodBurst(at: 5_000, popupCount: 6, nameCount: 0)
        let wifi = FloodBurst(
            at: 5_000,
            popupCount: 15,
            nameCount: 0,
            keys: ["WIFI:02:00:00:00:00:01"],
            wifi: true
        )
        session.noteFloods(incoming: [ble, wifi])
        session.noteFloods(incoming: [with(wifi) { $0.popupCount = 20 }])
        let kept = session.snapshot().floods
        #expect(kept.count == 2)
        #expect(kept.single { !$0.wifi }.popupCount == 6)
        #expect(kept.single { $0.wifi }.popupCount == 20)
        #expect(kept.single { $0.wifi }.keys == ["WIFI:02:00:00:00:00:01"])
    }

    @Test func debriefLeavesCountedFloodAddressesOutOfTheCounts() {
        let now = 1_700_000_000_000
        let window = DebriefWindow(startAt: now - 15 * 60_000, endAt: now, sitName: "lot")
        let real = radio(
            "BLE:AC:23:3F:11:22:33",
            firstSeen: now - 60_000,
            lastSeen: now,
            randomized: false,
            name: "Checkout beacon"
        )
        let floodA = with(radio(
            "BLE:02:00:00:00:00:01",
            fleetIds: ["fleet-axon"],
            firstSeen: now - 30_000,
            lastSeen: now - 30_000
        )) { $0.facts = RadioFacts(serviceData: [ServiceDataRecord(uuid: "FE2C", dataHex: "AABBCC")]) }
        let floodB = with(radio(
            "BLE:02:00:00:00:00:02",
            fleetIds: ["fleet-axon"],
            firstSeen: now - 30_000,
            lastSeen: now - 30_000
        )) { $0.facts = RadioFacts(serviceData: [ServiceDataRecord(uuid: "FE2C", dataHex: "CCDDEE")]) }
        let burst = FloodBurst(
            at: now - 30_000,
            popupCount: 8,
            nameCount: 0,
            families: ["Fast Pair"],
            medianRssi: -47,
            keys: [floodA.key, floodB.key]
        )
        let earlier = FloodBurst(
            at: now - 2 * 60 * 60_000,
            popupCount: 6,
            nameCount: 0,
            keys: [real.key]
        )
        let doc = DebriefReport.document(
            devices: [real, floodA, floodB],
            fleets: fleets,
            settings: settings(tagLocation: false),
            operatorPath: [],
            now: now,
            window: window,
            customNames: [real.key: "Checkout beacon"],
            floods: [earlier, burst]
        )
        let text = doc.toPlainText()
        #expect(doc.meta.first { $0.0 == "Radios" }!.1 == "1")
        #expect(text.contains("Heard 1 advertiser(s)"))
        #expect(text.contains("First seen in this window: 1"))
        #expect(text.contains("Checkout beacon"))
        #expect(text.contains("2 addresses from this burst are left out of the counts and lists below."))
        #expect(doc.sections.single { $0.title == "Signature hits" }.body.contains("None in this window."))
        #expect(!text.contains("Google Fast Pair in pairing mode"))
        #expect(!text.contains("02:00:00:00:00:01"))
        #expect(!text.contains("02:00:00:00:00:02"))
        #expect(!text.contains("Axon"))
    }

    @Test func oldSitJsonWithoutFloodsDecodesEmptyAndANotedBurstRoundTrips() throws {
        let legacy = try JSONDecoder().decode(
            SitFile.self,
            from: Data(#"{"format":"fieldwatch-sit","formatVersion":1,"summary":{"id":"a","name":"lot","startAt":1000}}"#.utf8)
        )
        #expect(legacy.floods.isEmpty)
        let session = SitSession.start(
            name: "lot",
            now: 1_000,
            heard: [],
            fleets: fleets,
            watchDeviceKeys: [],
            watchedFleetIds: []
        )
        let before = FloodBurst(at: 500, popupCount: 6, nameCount: 0, families: ["Fast Pair"])
        let during = FloodBurst(
            at: 5_000,
            popupCount: 6,
            nameCount: 0,
            families: ["Apple proximity pairing"],
            medianRssi: -48,
            keys: ["BLE:02:00:00:00:00:01", "BLE:02:00:00:00:00:02"]
        )
        session.noteFloods(incoming: [before, during])
        let louder = with(during) { $0.popupCount = 9 }
        session.noteFloods(incoming: [louder])
        let kept = session.snapshot().floods
        #expect(kept.count == 1)
        #expect(kept.single { _ in true }.at == 5_000)
        #expect(kept.single { _ in true }.popupCount == 9)
        #expect(kept.single { _ in true }.keys == ["BLE:02:00:00:00:00:01", "BLE:02:00:00:00:00:02"])
        session.noteFloods(incoming: (1...41).map { FloodBurst(at: 1_000 + $0, popupCount: 6, nameCount: 0) })
        let capped = session.snapshot().floods
        #expect(capped.count == 40)
        #expect(capped.first!.at == 1_000 + 2)
        let back = try JSONDecoder().decode(SitFile.self, from: try JSONEncoder().encode(session.snapshot()))
        #expect(back.floods == capped)
        _ = session.end(now: 50_000, fleets: fleets)
        session.noteFloods(incoming: [FloodBurst(at: 60_000, popupCount: 6, nameCount: 0)])
        #expect(session.snapshot().floods.count == 40)
        #expect(session.snapshot().floods.none { $0.at == 60_000 })
    }

    @Test func debriefOmitsUnmatchedRandomBleFromListsKeepsCounts() {
        let now = nowMs()
        let rand = radio(
            "BLE:AA:AA:AA:11:22:33",
            firstSeen: now - 14 * 60_000,
            lastSeen: now,
            rssi: -40
        )
        let named = radio(
            "BLE:BB:BB:BB:11:22:33",
            fleetIds: ["fleet-axon"],
            firstSeen: now - 60_000,
            lastSeen: now,
            rssi: -55
        )
        let text = DebriefReport.document(
            devices: [rand, named],
            fleets: fleets,
            settings: settings(tagLocation: false),
            operatorPath: [],
            now: now
        ).toPlainText()
        #expect(text.contains("2 BLE advertisers"))
        #expect(text.contains("1 with randomized addresses") || text.contains("randomized"))
        #expect(text.contains("Unmatched rotating BLE omitted"))
        #expect(text.contains("Public safety  1"))
        #expect(text.contains("Unmatched  1"))
        #expect(!text.contains("Notable BLE:"))
        #expect(!text.contains("AA:AA:AA:11:22:33"))
        #expect(text.contains("BB:BB:BB:11:22:33"))
        let unmatchedOnly = DebriefReport.document(
            devices: [rand, named],
            fleets: fleets,
            settings: settings(tagLocation: false, debriefShowUnmatchedRandomBle: true),
            operatorPath: [],
            now: now
        ).toPlainText()
        #expect(!unmatchedOnly.contains("AA:AA:AA:11:22:33"))
        let shown = DebriefReport.document(
            devices: [rand, named],
            fleets: fleets,
            settings: settings(tagLocation: false, debriefShowUnmatchedRandomBle: true, debriefShowAllRadios: true),
            operatorPath: [],
            now: now
        ).toPlainText()
        #expect(shown.contains("Notable BLE:"))
        #expect(shown.contains("AA:AA:AA:11:22:33"))
    }

    @Test func rollingDebriefUnchangedWithoutSit() {
        let cam = radio("BLE:AA:AA:AA:AA:AA:01", firstSeen: 1, lastSeen: nowMs())
        let doc = DebriefReport.document(
            devices: [cam],
            fleets: fleets,
            settings: settings(tagLocation: false),
            operatorPath: []
        )
        #expect(doc.heading == "FIELDWATCH FIELD DEBRIEF")
        #expect(doc.windowLine.contains("last 15 minutes"))
    }

    @Test func sitKeepsLiveDecodeAndReplacesItWhenTheNextHearHasOne() {
        let separated = LiveDecodeChip(text: "separated", emphasis: true, note: "day")
        let near = LiveDecodeChip(text: "near owner", emphasis: false, note: "joined")
        let session = SitSession.start(
            name: "walk",
            now: 1_000,
            heard: [with(radio("BLE:AA:AA:AA:AA:AA:09")) { $0.liveDecode = [separated] }],
            fleets: fleets,
            watchDeviceKeys: [],
            watchedFleetIds: []
        )
        #expect(session.sightings().single { _ in true }.liveDecode.single { _ in true }.text == "separated")
        session.ingest(
            device: radio("BLE:AA:AA:AA:AA:AA:09", lastSeen: 2_000, rssi: -40),
            fleets: fleets,
            watchDeviceKeys: [],
            watchedFleetIds: []
        )
        #expect(session.sightings().single { _ in true }.liveDecode.single { _ in true }.note == "day")
        session.ingest(
            device: with(radio("BLE:AA:AA:AA:AA:AA:09", lastSeen: 3_000)) { $0.liveDecode = [near] },
            fleets: fleets,
            watchDeviceKeys: [],
            watchedFleetIds: []
        )
        let kept = session.sightings().single { _ in true }.liveDecode.single { _ in true }
        #expect(kept.text == "near owner")
        #expect(kept.note == "joined")
    }

    @Test func debriefQuotesCatalogSentenceAndKeepsRotationLineWithoutOne() {
        let now = 120_000
        let path = [
            GpsSample(at: 0, lat: 28.0, lon: -81.0, rssi: -50),
            GpsSample(at: 60_000, lat: 28.0012, lon: -81.0, rssi: -50),
        ]
        let dult = [Fleet(id: "fleet-dult", name: "DULT tracker", kind: .finder)]
        let day = "Separated from its owner. The address can hold still for about a day."
        let separated = with(radio(
            "BLE:11:22:33:44:55:66",
            fleetIds: ["fleet-dult"],
            firstSeen: 0,
            lastSeen: now,
            randomized: false,
            rssi: -50
        )) {
            $0.gpsTrail = path
            $0.liveDecode = [LiveDecodeChip(text: "separated", emphasis: true, note: day)]
        }
        let plain = with(radio(
            "BLE:11:22:33:44:55:77",
            fleetIds: ["fleet-dult"],
            firstSeen: 0,
            lastSeen: now,
            randomized: false,
            rssi: -50
        )) { $0.gpsTrail = path }
        let text = DebriefReport.document(
            devices: [separated, plain],
            fleets: dult,
            settings: settings(tagLocation: true),
            operatorPath: path,
            now: now,
            window: DebriefWindow(startAt: 0, endAt: now, sitName: "walk")
        ).toPlainText()
        #expect(text.contains("11:22:33:44:55:66 (Separated)"))
        #expect(text.contains("Account for it. \(day)"))
        #expect(text.contains("Account for it. Find My / iPhone addresses rotate; this MAC is this session."))
        #expect(!text.contains("\(day) Find My"))
    }

    @Test func markedMineLeavesTheUnmarkedTagInTheCallout() {
        let now = 120_000
        let path = [
            GpsSample(at: 0, lat: 28.0, lon: -81.0, rssi: -50),
            GpsSample(at: 60_000, lat: 28.0012, lon: -81.0, rssi: -50),
            GpsSample(at: now, lat: 28.0018, lon: -81.0, rssi: -50),
        ]
        let dult = [
            Fleet(
                id: "fleet-dult",
                name: "DULT tracker",
                attentionNote: "A separated tag.",
                kind: .finder
            ),
        ]
        func tag(_ mac: String) -> Sighting {
            with(radio(
                "BLE:\(mac)",
                fleetIds: ["fleet-dult"],
                firstSeen: 0,
                lastSeen: now,
                randomized: false,
                rssi: -50,
                name: "tag"
            )) { $0.gpsTrail = path }
        }
        let mineTag = tag("11:22:33:44:55:66")
        let other = tag("11:22:33:44:55:77")
        let quiet = radio(
            "BLE:AA:BB:CC:DD:EE:01",
            firstSeen: 0,
            lastSeen: now,
            randomized: false,
            rssi: -80
        )
        let doc = DebriefReport.document(
            devices: [mineTag, other, quiet],
            fleets: dult,
            settings: settings(tagLocation: true),
            operatorPath: path,
            now: now,
            window: DebriefWindow(startAt: 0, endAt: now, sitName: "walk"),
            customNames: [mineTag.key: "bag tag"],
            observerNotes: [quiet.key: "north lot"],
            mineKeys: [mineTag.key, quiet.key]
        )
        let titles = doc.sections.map { $0.title }
        #expect(titles[2] == "Observer notes")
        let mineAt = titles.indexOfFirst { $0 == "Marked mine" }
        #expect(mineAt > titles.indexOfFirst { $0 == "Observer notes" })
        #expect(mineAt < titles.indexOfFirst { $0 == "Tracking assessment" })
        let mine = doc.sections.single { $0.title == "Marked mine" }
        #expect(!mine.alert)
        #expect(mine.body.contains("11:22:33:44:55:66"))
        #expect(mine.body.contains("bag tag"))
        #expect(mine.body.contains("Marked mine. With you the whole sit."))
        #expect(mine.body.contains("AA:BB:CC:DD:EE:01"))
        #expect(mine.body.contains("\n    Marked mine."))
        #expect(!mine.body.contains("11:22:33:44:55:77"))
        let trackers = doc.sections.single { $0.title == "Possible trackers with you" }
        #expect(trackers.body.contains("11:22:33:44:55:77"))
        #expect(!trackers.body.contains("11:22:33:44:55:66"))
        #expect(doc.trackingAlert)
        #expect(doc.toPlainText().contains("Account for it."))
        let exec = doc.sections.single { $0.title == "Executive summary" }.body
        #expect(exec.contains("2 marked mine"))
        #expect(!exec.contains("11:22:33:44:55:66"))
        let extra = doc.sections.single { $0.title == "Extra attention" }.body
        #expect(extra.contains("11:22:33:44:55:66"))
        #expect(extra.contains("Marked mine"))
        #expect(extra.contains("A separated tag."))
        let hit = doc.extraAttention.single { $0.radioLabel.contains("11:22:33:44:55:66") }
        #expect(hit.radioLabel.contains("Marked mine"))
        #expect(hit.note == "A separated tag.")
    }

    @Test func markedMineAloneClearsTheTrackingBanner() {
        let now = 120_000
        let path = [
            GpsSample(at: 0, lat: 28.0, lon: -81.0, rssi: -50),
            GpsSample(at: 60_000, lat: 28.0012, lon: -81.0, rssi: -50),
            GpsSample(at: now, lat: 28.0018, lon: -81.0, rssi: -50),
        ]
        let dult = [Fleet(id: "fleet-dult", name: "DULT tracker", kind: .finder)]
        let mineTag = with(radio(
            "BLE:11:22:33:44:55:66",
            fleetIds: ["fleet-dult"],
            firstSeen: 0,
            lastSeen: now,
            randomized: false,
            rssi: -50
        )) { $0.gpsTrail = path }
        let doc = DebriefReport.document(
            devices: [mineTag],
            fleets: dult,
            settings: settings(tagLocation: true),
            operatorPath: path,
            now: now,
            window: DebriefWindow(startAt: 0, endAt: now, sitName: "walk"),
            customNames: [mineTag.key: "bag tag"],
            mineKeys: [mineTag.key]
        )
        #expect(!doc.trackingAlert)
        #expect(doc.sections.none { $0.title == "Possible trackers with you" })
        #expect(doc.sections.none { $0.title == "Possible tail" })
        #expect(!doc.takeaway.contains("11:22:33:44:55:66"))
        #expect(doc.sections.single { $0.title == "Marked mine" }.body.contains("With you the whole sit."))
        #expect(doc.sections.single { $0.title == "Executive summary" }.body.contains("1 marked mine"))
    }

    @Test func markedMineTailUsesTheArrivalLine() {
        let now = 120_000
        let path = [
            GpsSample(at: 0, lat: 28.0, lon: -81.0, rssi: -60),
            GpsSample(at: 40_000, lat: 28.0008, lon: -81.0, rssi: -60),
            GpsSample(at: 80_000, lat: 28.0016, lon: -81.0, rssi: -60),
            GpsSample(at: now, lat: 28.0024, lon: -81.0, rssi: -60),
        ]
        let dult = [Fleet(id: "fleet-dult", name: "DULT tracker", kind: .finder)]
        let tail = with(radio(
            "BLE:11:22:33:44:55:88",
            fleetIds: ["fleet-dult"],
            firstSeen: 20_000,
            lastSeen: now,
            randomized: false,
            rssi: -60
        )) { $0.gpsTrail = path.drop(1) }
        let doc = DebriefReport.document(
            devices: [tail],
            fleets: dult,
            settings: settings(tagLocation: true),
            operatorPath: path,
            now: now,
            window: DebriefWindow(startAt: 0, endAt: now, sitName: "walk"),
            mineKeys: [tail.key]
        )
        #expect(!doc.trackingAlert)
        #expect(doc.sections.none { $0.title == "Possible tail" })
        let body = doc.sections.single { $0.title == "Marked mine" }.body
        #expect(body.contains("First heard after the sit started and stayed with the path."))
    }

    @Test func endFreezesSummary() {
        let session = SitSession.start(
            name: "lot",
            now: 1_000,
            heard: [radio("BLE:AA:AA:AA:AA:AA:01")],
            fleets: fleets,
            watchDeviceKeys: [],
            watchedFleetIds: []
        )
        let file = session.end(now: 5_000, fleets: fleets)
        #expect(file.summary.endAt == 5_000)
        #expect(!file.summary.open)
        #expect(file.summary.radioCount == 1)
        #expect(!session.open)
    }

    @Test func pathSubsamplesShortMoves() {
        let session = SitSession.start(
            name: "walk",
            now: 1_000,
            heard: [],
            fleets: fleets,
            watchDeviceKeys: [],
            watchedFleetIds: []
        )
        session.recordPath(lat: 40.0, lon: -74.0, at: 1_000)
        session.recordPath(lat: 40.00001, lon: -74.0, at: 2_000)
        #expect(session.operatorPath.count == 1)
        session.recordPath(lat: 40.001, lon: -74.0, at: 8_000)
        #expect(session.operatorPath.count == 2)
    }

    /// Kotlin helper order: key, mac, fleetIds, firstSeen, lastSeen, gone, payloadLat, payloadLon,
    /// randomized, rssi, name, kind.
    private func radio(
        _ key: String,
        mac: String? = nil,
        fleetIds: [String] = [],
        firstSeen: Int = 1,
        lastSeen: Int = 1,
        gone: Bool = false,
        payloadLat: Double? = nil,
        payloadLon: Double? = nil,
        randomized: Bool = true,
        rssi: Int = -60,
        name: String = "",
        kind: RadioKind = .ble
    ) -> Sighting {
        Sighting(
            key: key,
            kind: kind,
            mac: mac ?? key.substringAfter(":"),
            name: name,
            rssi: rssi,
            rssiMin: rssi,
            rssiMax: rssi,
            channel: 0,
            frequencyMhz: 2402,
            vendor: nil,
            randomized: randomized,
            hiddenSsid: false,
            serviceUuids: [],
            manufacturerId: nil,
            manufacturerDataHex: "",
            rawHex: "",
            extras: "",
            firstSeen: firstSeen,
            lastSeen: lastSeen,
            hitCount: 1,
            fleetIds: fleetIds,
            rssiHistory: [],
            presence: [],
            gone: gone,
            payloadLat: payloadLat,
            payloadLon: payloadLon
        )
    }
}
