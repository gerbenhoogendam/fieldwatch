import Foundation
import Testing
@testable import FieldwatchCore

// Port of SignatureListSortTest.kt.

@Suite struct SignatureListSortTest {
    private let fleets = [
        SignatureListSortTest.fleet("fleet-axon", "Axon", .lawEnforcement),
        SignatureListSortTest.fleet("fleet-tesla", "Tesla", .vehicle),
        SignatureListSortTest.fleet("fleet-airlink", "AirLink", .lawEnforcement),
        SignatureListSortTest.fleet("fleet-amazon", "Amazon", .home),
    ]

    @Test func nameSortIsAlphabetical() {
        #expect(fleets.sortedForCatalog(sort: .name).map { $0.name } == ["AirLink", "Amazon", "Axon", "Tesla"])
    }

    @Test func classSortGroupsByClassLabelThenName() {
        #expect(fleets.sortedForCatalog(sort: .class).map { $0.name } == ["Amazon", "AirLink", "Axon", "Tesla"])
        let groups = fleets.groupedByClass()
        #expect(groups.map { $0.0.label() } == ["Home IoT", "Public safety", "Vehicle"])
        #expect(groups[1].1.map { $0.name } == ["AirLink", "Axon"])
    }

    @Test func labels() {
        #expect(SignatureListSort.name.label() == "Name A–Z")
        #expect(SignatureListSort.class.label() == "Class A–Z")
    }

    @Test func speechLabelIsShortAndSpeaksSlashes() {
        #expect(SignatureClass.finder.speechLabel() == "finder tags")
        #expect(SignatureClass.audio.speechLabel() == "audio")
        #expect(SignatureClass.lawEnforcement.speechLabel() == "public safety")
        #expect(SignatureClass.isp.speechLabel() == "I S P routers")
        #expect(SignatureClass.phone.speechLabel() == "phones")
        #expect(SignatureClass.health.speechLabel() == "health")
        #expect(SignatureClass.health.label() == "Health")
    }

    @Test func spokenWatchClassUsesFirstMatch() {
        let axon = SignatureListSortTest.fleet("fleet-axon", "Axon", .lawEnforcement)
        let device = sampleDevice(["fleet-axon"])
        #expect(spokenWatchClass(device: device, fleets: [axon]) == "public safety")
        #expect(spokenWatchClass(device: with(device) { $0.fleetIds = [] }, fleets: [axon]) == "unmatched")
    }

    @Test func spokenWatchPhraseClassSignatureOrBoth() {
        let air = SignatureListSortTest.fleet("fleet-airtag", "Apple AirTags", .finder)
        let device = sampleDevice(["fleet-airtag"])
        let fleets = [air]
        #expect(spokenWatchPhrase(device: device, fleets: fleets, what: .class) == "finder tags")
        #expect(spokenWatchPhrase(device: device, fleets: fleets, what: .signature) == "Apple AirTags")
        #expect(spokenWatchPhrase(device: device, fleets: fleets, what: .both) == "finder tags, Apple AirTags")
        #expect(spokenWatchPhrase(device: with(device) { $0.fleetIds = [] }, fleets: fleets, what: .both) == "unmatched")
    }

    @Test func spokenWatchPhrasePrefersWatchedSignatureOnDualChip() {
        let axon = SignatureListSortTest.fleet("fleet-axon", "Axon", .lawEnforcement)
        let air = SignatureListSortTest.fleet("fleet-airtag", "Apple AirTags", .finder)
        let device = sampleDevice(["fleet-axon", "fleet-airtag"])
        let target = WatchTarget(id: "w-air", fleetId: "fleet-airtag", label: "Apple AirTags")
        let fleets = [axon, air]
        #expect(spokenWatchPhrase(device: device, fleets: fleets, what: .class, target: target) == "finder tags")
        #expect(spokenWatchPhrase(device: device, fleets: fleets, what: .signature, target: target) == "Apple AirTags")
        #expect(spokenWatchPhrase(device: device, fleets: fleets, what: .both) == "public safety, Axon")
    }

    @Test func spokenWatchPhraseUsesRadioBookmarkName() {
        let air = SignatureListSortTest.fleet("fleet-airtag", "Apple AirTags", .finder)
        let device = sampleDevice(["fleet-airtag"])
        let radio = WatchTarget(id: "w-radio", deviceKey: device.key, label: "Peter's Mesh Node")
        #expect(spokenWatchPhrase(device: device, fleets: [air], what: .both, target: radio) == "Peter's Mesh Node")
        let unmatched = with(device) { $0.fleetIds = [] }
        #expect(spokenWatchPhrase(device: unmatched, fleets: [air], what: .class, target: radio) == "Peter's Mesh Node")
    }

    @Test func speakableWatchNameStripsSlashes() {
        #expect(speakableWatchName(name: "Ray-Ban / Meta glasses") == "Ray-Ban Meta glasses")
        #expect(speakableWatchName(name: "Marauder / Deauther") == "Marauder Deauther")
    }

    @Test func testWatchPhraseMatchesFinderExample() {
        #expect(testWatchPhrase(what: .class) == "finder tags")
        #expect(testWatchPhrase(what: .signature) == "Apple AirTags")
        #expect(testWatchPhrase(what: .both) == "finder tags, Apple AirTags")
    }

    // MARK: - Helpers

    private func with<T>(_ value: T, _ change: (inout T) -> Void) -> T {
        var copy = value
        change(&copy)
        return copy
    }

    private func sampleDevice(_ fleetIds: [String]) -> Sighting {
        Sighting(
            key: "BLE:AA:BB:CC:DD:EE:01", kind: .ble, mac: "AA:BB:CC:DD:EE:01", name: "Axon",
            rssi: -40, rssiMin: -40, rssiMax: -40, channel: 0, frequencyMhz: 0, vendor: nil,
            randomized: false, hiddenSsid: false, serviceUuids: [], manufacturerId: nil, manufacturerDataHex: "",
            rawHex: "", extras: "", firstSeen: 1, lastSeen: 1, hitCount: 1, fleetIds: fleetIds,
            rssiHistory: [], presence: []
        )
    }

    private static func fleet(_ id: String, _ name: String, _ kind: SignatureClass) -> Fleet {
        Fleet(id: id, name: name, kind: kind)
    }
}
