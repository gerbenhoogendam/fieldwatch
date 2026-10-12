import Foundation
import Testing
@testable import FieldwatchCore

// Port of SitDiffTest.kt.

private func with<T>(_ v: T, _ f: (inout T) -> Void) -> T {
    var c = v
    f(&c)
    return c
}

struct SitDiffTest {
    private let axon = Fleet(
        id: "fleet-axon",
        name: "Axon",
        attentionNote: "Body-worn, in-car, dock, or TASER.",
        kind: .lawEnforcement
    )
    private var fleets: [Fleet] { [axon] }

    @Test func secondSitSkipsThisSavedAndDefaultsToNewestOther() {
        let a = SitSummary(id: "a", name: "plaza today", startAt: 30)
        let b = SitSummary(id: "b", name: "plaza last week", startAt: 20)
        let c = SitSummary(id: "c", name: "lot", startAt: 10)
        let closed = [a, b, c]
        #expect(SitDiff.secondSitChoices(closed: closed, thisSavedId: "a") == [b, c])
        #expect(SitDiff.defaultSecondSitId(closed: closed, thisSavedId: "a") == "b")
        #expect(SitDiff.defaultSecondSitId(closed: closed, thisSavedId: nil) == "a")
        #expect(SitDiff.defaultSecondSitId(closed: [], thisSavedId: nil) == nil)
        #expect(SitDiff.thisSavedId(open: SitSummary(id: "open", name: "now", startAt: 1), selectedId: "a") == nil)
        #expect(SitDiff.thisSavedId(open: nil, selectedId: "a") == "a")
    }

    @Test func presenceSplitsOnlyThisOnlySecondAndBoth() {
        let thisSit = SitDiff.Side(
            name: "today",
            ram: false,
            radios: [
                radio("WIFI:AA:AA:AA:AA:AA:01", "cam", extra: true),
                radio("WIFI:AA:AA:AA:AA:AA:02", "ap"),
                radio("WIFI:AA:AA:AA:AA:AA:03", "van", named: true),
            ]
        )
        let second = SitDiff.Side(
            name: "last week",
            ram: false,
            radios: [
                radio("WIFI:AA:AA:AA:AA:AA:02", "ap"),
                radio("WIFI:AA:AA:AA:AA:AA:03", "van", named: true),
                radio("WIFI:AA:AA:AA:AA:AA:04", "new"),
            ]
        )
        let text = SitDiff.report(thisSit: thisSit, second: second, demoMode: false)
        #expect(text.contains("ONLY IN THIS SIT (1)"))
        #expect(text.contains("AA:AA:AA:AA:AA:01"))
        #expect(text.contains("cam"))
        #expect(text.contains("Extra attention"))
        #expect(text.contains("ONLY IN SECOND SIT (1)"))
        #expect(text.contains("Unmatched  1"))
        #expect(!text.contains("AA:AA:AA:AA:AA:04"))
        let full = SitDiff.report(thisSit: thisSit, second: second, demoMode: false, showAllRadios: true)
        #expect(full.contains("AA:AA:AA:AA:AA:04"))
        #expect(text.contains("IN BOTH (2)"))
        #expect(text.contains("van"))
        #expect(text.contains("This sit: today"))
        #expect(text.contains("Second sit: last week"))
        #expect(!text.contains("Last 15 minutes is the Live RAM set"))
        #expect(!text.contains("marked mine"))
    }

    @Test func observerNotesPrintOnExclusiveLine() {
        let thisSit = SitDiff.Side(
            name: "today",
            ram: false,
            radios: [
                radio("WIFI:AA:AA:AA:AA:AA:01", "van", named: true, observer: "fleet van, lot B"),
            ]
        )
        let second = SitDiff.Side(name: "week", ram: false, radios: [])
        let text = SitDiff.report(thisSit: thisSit, second: second, demoMode: false)
        #expect(text.contains("OBSERVER NOTES"))
        #expect(text.contains("van"))
        #expect(text.contains("fleet van, lot B"))
        #expect(text.contains("this sit"))
        #expect(!text.contains("Observer: fleet van, lot B"))
    }

    @Test func markedMineNamesTheWindowAndTheLines() {
        let thisSit = SitDiff.Side(
            name: "today",
            ram: false,
            radios: [
                radio("WIFI:AA:AA:AA:AA:AA:01", "van", extra: true, mine: true),
                radio("WIFI:AA:AA:AA:AA:AA:02", "ap"),
            ]
        )
        let second = SitDiff.Side(
            name: "week",
            ram: false,
            radios: [
                radio("WIFI:AA:AA:AA:AA:AA:01", "van", extra: true, mine: true),
                radio("WIFI:AA:AA:AA:AA:AA:03", "new", mine: true),
            ]
        )
        let doc = SitDiff.document(thisSit: thisSit, second: second)
        let titles = doc.sections.map { $0.title }
        let mineAt = titles.indexOfFirst { $0 == "Marked mine" }
        #expect(mineAt > titles.indexOfFirst { $0 == "Windows" })
        #expect(titles.indexOfFirst { $0 == "Extra attention" } == -1 || mineAt < titles.indexOfFirst { $0 == "Extra attention" })
        let section = doc.sections.single { $0.title == "Marked mine" }
        #expect(!section.alert)
        #expect(section.body.contains("AA:AA:AA:AA:AA:01"))
        #expect(section.body.contains("van"))
        #expect(section.body.contains("both"))
        #expect(section.body.contains("AA:AA:AA:AA:AA:03"))
        #expect(section.body.contains("second sit"))
        let text = doc.toPlainText()
        #expect(text.contains("van  Marked mine"))
        #expect(text.contains("new  Marked mine"))
        #expect(doc.takeaway.hasSuffix("· 2 marked mine."))
        let onlySecond = doc.sections.single { $0.title.hasPrefix("Only in second") }
        #expect(onlySecond.after.contains("Marked mine"))
    }

    @Test func ramCapNoteWhenThisSitIsLastFifteen() {
        let thisSit = SitDiff.Side(
            name: "Last 15 minutes",
            ram: true,
            radios: [radio("BLE:AA:AA:AA:AA:AA:01", "")]
        )
        let second = SitDiff.Side(
            name: "plaza",
            ram: false,
            radios: []
        )
        let text = SitDiff.report(thisSit: thisSit, second: second, demoMode: false)
        #expect(text.contains("Last 15 minutes is the Live RAM set"))
        #expect(text.contains("\(Sit.RADIO_CAP)"))
        #expect(text.contains("ONLY IN THIS SIT (1)"))
        #expect(text.contains("ONLY IN SECOND SIT (0)"))
        #expect(text.contains("(none)"))
    }

    @Test func privacyModeMasksMacTails() {
        let thisSit = SitDiff.Side(
            name: "today",
            ram: false,
            radios: [radio("WIFI:AA:BB:CC:11:22:33", "Cafe")]
        )
        let second = SitDiff.Side(name: "week", ram: false, radios: [])
        let text = SitDiff.report(thisSit: thisSit, second: second, demoMode: true, showAllRadios: true)
        #expect(text.contains("Privacy"))
        #expect(text.contains("AA:BB:CC:**:**:**"))
        #expect(!text.contains("11:22:33"))
        #expect(text.contains("FIELDWATCH SIT COMPARE"))
    }

    @Test func extraAttentionFromFleetNote() {
        let device = Sighting(
            key: "BLE:AA:BB:CC:DD:EE:01",
            kind: .ble,
            mac: "AA:BB:CC:DD:EE:01",
            name: "dock",
            rssi: -50,
            rssiMin: -50,
            rssiMax: -50,
            channel: 0,
            frequencyMhz: 2402,
            vendor: nil,
            randomized: true,
            hiddenSsid: false,
            serviceUuids: [],
            manufacturerId: nil,
            manufacturerDataHex: "",
            rawHex: "",
            extras: "",
            firstSeen: 1,
            lastSeen: 1,
            hitCount: 1,
            fleetIds: ["fleet-axon"],
            rssiHistory: [],
            presence: []
        )
        let row = SitDiff.fromSighting(device: device, fleets: fleets, customNames: [:])
        #expect(row.extraAttention)
        #expect(row.fleetNames == ["Axon"])
        #expect(!row.named)
        #expect(row.randomized)
    }

    @Test func aiExportIsAddendumNotASecondRoster() {
        let thisSit = SitDiff.Side(
            name: "today",
            ram: true,
            radios: [
                radio("WIFI:AA:AA:AA:AA:AA:01", "cam", extra: true),
                radio("BLE:BB:BB:BB:BB:BB:02", "tag", named: true, ble: true, rand: true),
                radio("WIFI:AA:AA:AA:AA:AA:02", "ap"),
            ]
        )
        let second = SitDiff.Side(
            name: "last week",
            ram: false,
            radios: [
                radio("WIFI:AA:AA:AA:AA:AA:02", "ap"),
                radio("WIFI:AA:AA:AA:AA:AA:04", "new"),
            ]
        )
        let text = SitDiffPrompt.build(thisSit: thisSit, second: second, demoMode: false)
        #expect(text.contains("Do not rewrite that report"))
        #expect(text.contains("Overlap:"))
        #expect(text.contains("Exclusive Extra attention:"))
        #expect(text.contains("cam"))
        #expect(text.contains("Exclusive Named radios:"))
        #expect(text.contains("tag"))
        #expect(text.contains("RAND BLE"))
        #expect(text.contains("Cap note:"))
        #expect(text.contains("Takeaway:"))
        #expect(text.contains("decoded live value"))
        #expect(text.contains("A flood note is a burst of new addresses, not a follower."))
        #expect(text.contains("Flood if any"))
        #expect(text.contains("FIELDWATCH SIT COMPARE"))
        #expect(!text.contains("Full Wi-Fi inventory"))
    }

    @Test func compareNamesTheSitThatHadTheFlood() {
        let burst = FloodBurst(
            at: 1_700_000_000_000,
            popupCount: 6,
            nameCount: 0,
            families: ["Fast Pair"],
            medianRssi: -40
        )
        let morning = SitDiff.Side(name: "morning", ram: false, radios: [], floods: [burst])
        let stall = SitDiff.Side(name: "stall", ram: false, radios: [])
        let doc = SitDiff.document(thisSit: morning, second: stall)
        let section = doc.sections.single { $0.title == "Flood" }
        #expect(section.body.contains(FloodBurst.INTRO))
        #expect(section.body.contains("morning"))
        #expect(section.body.contains("Pairing flood"))
        #expect(section.body.contains("6 new addresses: Fast Pair"))
        #expect(!section.body.contains("stall"))
        #expect(!section.alert)
        #expect(!doc.trackingAlert)
        let titles = doc.sections.map { $0.title }
        #expect(titles.indexOfFirst { $0 == "Flood" } < titles.indexOfFirst { $0 == "Only in this sit (0)" })
        #expect(!doc.takeaway.contains("marked mine"))
        let text = SitDiff.report(thisSit: morning, second: stall, demoMode: false)
        #expect(text.contains("FLOOD"))
        #expect(text.contains("morning"))
    }

    @Test func compareUsesTheWifiFloodIntro() {
        let burst = FloodBurst(
            at: 1_700_000_000_000,
            popupCount: 15,
            nameCount: 0,
            medianRssi: -34,
            keys: ["WIFI:02:00:00:00:00:02"],
            wifi: true
        )
        let morning = SitDiff.Side(name: "morning", ram: false, radios: [], floods: [burst])
        let stall = SitDiff.Side(name: "stall", ram: false, radios: [])
        let section = SitDiff.document(thisSit: morning, second: stall).sections.single { $0.title == "Flood" }
        #expect(section.body.contains(FloodBurst.WIFI_INTRO))
        #expect(!section.body.contains("new Bluetooth addresses"))
        #expect(section.body.contains("Wi-Fi beacon flood"))
        #expect(section.body.contains("15 new names"))
    }

    @Test func compareLeavesFloodAddressesOutOfPresence() {
        let kept = "WIFI:AA:AA:AA:AA:AA:01"
        let floodA = "BLE:02:00:00:00:00:0A"
        let floodB = "BLE:02:00:00:00:00:0B"
        let burst = FloodBurst(
            at: 1_700_000_000_000,
            popupCount: 6,
            nameCount: 0,
            families: ["Fast Pair"],
            keys: [floodA, floodB]
        )
        let morning = SitDiff.Side(
            name: "morning",
            ram: false,
            radios: [
                radio(kept, "ap"),
                radio(floodA, "spam", ble: true, rand: true),
                radio(floodB, "spam", ble: true, rand: true),
            ],
            floods: [burst]
        )
        let stall = SitDiff.Side(
            name: "stall",
            ram: false,
            radios: [radio(kept, "ap")]
        )
        let doc = SitDiff.document(thisSit: morning, second: stall, showAllRadios: true)
        #expect(doc.meta.first { $0.0 == "This radios" }!.1 == "1")
        #expect(doc.meta.first { $0.0 == "Second radios" }!.1 == "1")
        #expect(doc.sections.contains { $0.title == "Only in this sit (0)" })
        #expect(doc.sections.contains { $0.title == "In both (1)" })
        let text = doc.toPlainText()
        #expect(text.contains("2 addresses from this burst are left out of the counts and lists below."))
        #expect(text.contains("AA:AA:AA:AA:AA:01"))
        #expect(!text.contains("02:00:00:00:00:0A"))
        #expect(!text.contains("02:00:00:00:00:0B"))
        let prompt = SitDiffPrompt.build(thisSit: morning, second: stall, demoMode: false)
        #expect(prompt.contains("Only in this sit: 0"))
        #expect(prompt.contains("In both: 1"))
    }

    @Test func aiExportPrivacyMasksExclusiveMacs() {
        let thisSit = SitDiff.Side(
            name: "today",
            ram: false,
            radios: [radio("WIFI:AA:BB:CC:11:22:33", "Cafe", extra: true)]
        )
        let second = SitDiff.Side(name: "week", ram: false, radios: [])
        let text = SitDiffPrompt.build(thisSit: thisSit, second: second, demoMode: true)
        #expect(text.contains("Privacy mode"))
        #expect(text.contains("AA:BB:CC:**:**:**"))
        #expect(!text.contains("11:22:33"))
    }

    @Test func bothStatesDecodedValueChangeAndQuotesAMatchingNoteOnce() {
        let day = "Separated from its owner. The address can hold still for about a day."
        let separated = LiveDecodeChip(text: "separated", emphasis: true, note: day)
        let near = LiveDecodeChip(text: "near owner", emphasis: false, note: "Near its owner.")
        let changedA = with(radio("BLE:AA:AA:AA:AA:AA:01", "tag", ble: true)) { $0.liveDecode = [separated] }
        let changedB = with(radio("BLE:AA:AA:AA:AA:AA:01", "tag", ble: true)) { $0.liveDecode = [near] }
        let held = with(radio("BLE:BB:BB:BB:BB:BB:02", "held", ble: true)) { $0.liveDecode = [separated] }
        let text = SitDiff.report(
            thisSit: SitDiff.Side(name: "today", ram: false, radios: [changedA, held]),
            second: SitDiff.Side(name: "week", ram: false, radios: [changedB, held]),
            demoMode: false
        )
        let change = text.lines().first { $0.contains("decoded value changed") }!
        #expect(change.contains("Separated → Near owner"))
        #expect(!change.contains("about a day"))
        let full = SitDiff.report(
            thisSit: SitDiff.Side(name: "today", ram: false, radios: [changedA, held]),
            second: SitDiff.Side(name: "week", ram: false, radios: [changedB, held]),
            demoMode: false,
            showAllRadios: true
        )
        let heldLine = full.lines().first { $0.contains("BB:BB:BB:BB:BB:02") && $0.contains("Separated") }!
        #expect(heldLine.components(separatedBy: "about a day").count - 1 == 1)
    }

    private func radio(
        _ key: String,
        _ name: String,
        extra: Bool = false,
        named: Bool = false,
        ble: Bool = false,
        rand: Bool = false,
        observer: String = "",
        mine: Bool = false
    ) -> SitDiff.Radio {
        SitDiff.Radio(
            key: key,
            kind: ble ? .ble : .wifi,
            mac: key.substringAfter(":"),
            name: name,
            extraAttention: extra,
            named: named,
            fleetNames: extra ? ["Axon"] : [],
            randomized: rand,
            observerNotes: observer,
            mine: mine
        )
    }
}
