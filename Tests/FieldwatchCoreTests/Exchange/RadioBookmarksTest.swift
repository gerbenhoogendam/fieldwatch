import Foundation
import Testing
@testable import FieldwatchCore

// Port of RadioBookmarksTest.kt.

@Suite struct RadioBookmarksTest {
    private let radio = WatchTarget(id: "r1", deviceKey: "BLE:AA:BB:CC:DD:EE:FF", label: "van tag")
    private let fleet = WatchTarget(id: "f1", fleetId: "fleet-airtag", label: "Apple AirTags")

    @Test func radiosOnlyDropsSignatureWatches() {
        let list = [fleet, radio]
        #expect(RadioBookmarks.radios(watchlist: list) == [radio])
        #expect(RadioBookmarks.withoutRadios(watchlist: list) == [fleet])
    }

    @Test func clearRadiosKeepsSignatures() {
        #expect(RadioBookmarks.withoutRadios(watchlist: [fleet, radio]) == [fleet])
    }

    @Test func renameOnlyTouchesThatRadio() throws {
        let next = RadioBookmarks.rename(watchlist: [fleet, radio], id: "r1", name: "  porch cam  ")
        #expect(try only(next.filter { $0.id == "r1" }).label == "porch cam")
        #expect(try only(next.filter { $0.id == "f1" }).label == "Apple AirTags")
    }

    @Test func removeOneLeavesSignatures() {
        let next = RadioBookmarks.remove(watchlist: [fleet, radio], id: "r1")
        #expect(next == [fleet])
    }

    @Test func upsertNameWithoutAlertThenToggleKeepsName() throws {
        let named = RadioBookmarks.upsertName(watchlist: [fleet], deviceKey: "BLE:AA:BB:CC:DD:EE:FF", name: "Peter's Mesh Node")
        let row = try only(named.filter { $0.deviceKey != nil })
        #expect(row.label == "Peter's Mesh Node")
        #expect(row.alert == false)
        let key = try #require(row.deviceKey)
        let watched = RadioBookmarks.toggleAlert(watchlist: named, deviceKey: key, suggest: "ignored")
        #expect(try only(watched.filter { $0.deviceKey != nil }).alert == true)
        #expect(try only(watched.filter { $0.deviceKey != nil }).label == "Peter's Mesh Node")
        let quiet = RadioBookmarks.toggleAlert(watchlist: watched, deviceKey: key, suggest: "ignored")
        #expect(try only(quiet.filter { $0.deviceKey != nil }).alert == false)
        #expect(try only(quiet.filter { $0.deviceKey != nil }).label == "Peter's Mesh Node")
        #expect(RadioBookmarks.radios(watchlist: quiet).count == 1)
        #expect(try only(quiet.filter { $0.fleetId != nil }) == fleet)
    }

    @Test func labelsMapsDeviceKeyToCustomName() {
        let named = with(radio) { $0.label = "porch cam" }
        let blank = with(radio) {
            $0.id = "r2"
            $0.deviceKey = "WIFI:00:11:22:33:44:55"
            $0.label = "  "
        }
        let map = RadioBookmarks.labels(watchlist: [fleet, named, blank])
        #expect(map["BLE:AA:BB:CC:DD:EE:FF"] == "porch cam")
        #expect(map["WIFI:00:11:22:33:44:55"] == nil)
        let device = ble(name: "Meshtastic_3480")
        #expect(device.reportName(customNames: map) == "porch cam")
        #expect(device.reportName(customNames: [:]) == "Meshtastic_3480")
    }

    @Test func namedKeysSkipsSignaturesAndBlankLabels() {
        let blank = with(radio) {
            $0.id = "r2"
            $0.deviceKey = "WIFI:00:11:22:33:44:55"
            $0.label = "  "
        }
        #expect(RadioBookmarks.namedKeys(watchlist: [fleet, radio, blank]) == ["BLE:AA:BB:CC:DD:EE:FF"])
    }

    @Test func watchedOnlySetsAreBookmarksAndAlertRadios() {
        let quiet = with(radio) { $0.alert = false }
        let alerted = with(radio) {
            $0.id = "r2"
            $0.deviceKey = "BLE:11:22:33:44:55:66"
            $0.alert = true
        }
        let list = [fleet, quiet, alerted]
        #expect(RadioBookmarks.watchedFleetIds(watchlist: list) == ["fleet-airtag"])
        #expect(RadioBookmarks.alertDeviceKeys(watchlist: list) == ["BLE:11:22:33:44:55:66"])
    }

    @Test func parseKey() throws {
        let b = try #require(RadioBookmarks.parseKey(key: "BLE:AA:BB:CC:DD:EE:FF"))
        #expect(b.0 == .ble && b.1 == "AA:BB:CC:DD:EE:FF")
        let w = try #require(RadioBookmarks.parseKey(key: "WIFI:00:11:22:33:44:55"))
        #expect(w.0 == .wifi && w.1 == "00:11:22:33:44:55")
        #expect(RadioBookmarks.parseKey(key: "nope") == nil)
    }

    @Test func listLineUsesWatchNameForNameLines() {
        let named = ble(name: "Meshtastic_3480")
        #expect(named.listLineText(line: .nameAndType, watchName: "Peter's Mesh Node") == "Peter's Mesh Node")
        #expect(named.listLineText(line: .advertisedName, watchName: "Peter's Mesh Node") == "Peter's Mesh Node")
        #expect(named.listLineText(line: .mac, watchName: "Peter's Mesh Node") == named.mac)
        #expect(named.listLineText(line: .nameAndType) == "Meshtastic_3480")
    }

    @Test func suggestLabelPrefersAdvertisedName() {
        let named = ble(name: "Tile")
        #expect(RadioBookmarks.suggestLabel(device: named) == "Tile")
        let unnamed = ble(name: "")
        #expect(RadioBookmarks.suggestLabel(device: unnamed) == "unnamed LE")
    }

    @Test func upsertNotesCreatesQuietNamedRadioAndClips() throws {
        #expect(RadioBookmarks.clipNotes(text: "a".repeated(300)) == "a".repeated(280))
        #expect(RadioBookmarks.clipNotes(text: "  lot B  ") == "lot B")
        #expect(RadioBookmarks.upsertNotes(watchlist: [fleet], deviceKey: "WIFI:00:11:22:33:44:55", notes: "  ", suggestLabel: "van") == [fleet])
        let created = RadioBookmarks.upsertNotes(
            watchlist: [fleet],
            deviceKey: "WIFI:00:11:22:33:44:55",
            notes: "  fleet van  ",
            suggestLabel: "PS-CRADLEPOINT"
        )
        let row = try only(created.filter { $0.deviceKey != nil })
        #expect(row.observerNotes == "fleet van")
        #expect(row.label == "PS-CRADLEPOINT")
        #expect(row.alert == false)
        #expect(RadioBookmarks.notes(watchlist: created)["WIFI:00:11:22:33:44:55"] == "fleet van")
        let named = RadioBookmarks.upsertName(watchlist: [fleet], deviceKey: "WIFI:00:11:22:33:44:55", name: "van")
        let noted = RadioBookmarks.upsertNotes(watchlist: named, deviceKey: "WIFI:00:11:22:33:44:55", notes: "lot B", suggestLabel: "ignored")
        let kept = try only(noted.filter { $0.deviceKey != nil })
        #expect(kept.label == "van")
        #expect(kept.observerNotes == "lot B")
        #expect(kept.alert == false)
        let edited = RadioBookmarks.updateNamedRadio(watchlist: [radio], id: "r1", name: "porch", notes: "north lot")
        #expect(try only(edited.filter { $0.id == "r1" }).label == "porch")
        #expect(try only(edited.filter { $0.id == "r1" }).observerNotes == "north lot")
        #expect(try only(RadioBookmarks.updateNamedRadio(watchlist: [fleet], id: "f1", name: "x", notes: "y")).label == "Apple AirTags")
    }

    @Test func setMineFillsABlankNameAndLeavesAlert() throws {
        let created = RadioBookmarks.setMine(watchlist: [fleet], deviceKey: "WIFI:00:11:22:33:44:55", on: true, suggestLabel: "PS-CRADLEPOINT")
        let row = try only(created.filter { $0.deviceKey != nil })
        #expect(row.label == "PS-CRADLEPOINT")
        #expect(row.alert == false)
        #expect(row.mine)
        #expect(RadioBookmarks.mineKeys(watchlist: created) == ["WIFI:00:11:22:33:44:55"])
        let radioKey = try #require(radio.deviceKey)
        let kept = RadioBookmarks.setMine(watchlist: [with(radio) { $0.alert = true }], deviceKey: radioKey, on: true, suggestLabel: "ignored")
        let named = try only(kept.filter { $0.deviceKey != nil })
        #expect(named.label == "van tag")
        #expect(named.alert)
        #expect(named.mine)
        let blank = with(radio) {
            $0.id = "r2"
            $0.deviceKey = "BLE:11:22:33:44:55:66"
            $0.label = "  "
            $0.alert = true
        }
        let blankKey = try #require(blank.deviceKey)
        let filled = RadioBookmarks.setMine(watchlist: [blank], deviceKey: blankKey, on: true, suggestLabel: "Tile")
        #expect(try only(filled).label == "Tile")
        #expect(try only(filled).alert)
        let off = RadioBookmarks.setMine(watchlist: filled, deviceKey: blankKey, on: false, suggestLabel: "ignored")
        #expect(try only(off).label == "Tile")
        #expect(try !only(off).mine)
        #expect(RadioBookmarks.mineKeys(watchlist: off).isEmpty)
        #expect(RadioBookmarks.setMine(watchlist: [fleet], deviceKey: "WIFI:00:11:22:33:44:55", on: false, suggestLabel: "van") == [fleet])
    }

    @Test func pathNoteDoesNotInventADot() {
        #expect(RadioBookmarks.pathNote(bookmarked: false, observerNotes: "lot B", mine: false) == "")
        #expect(RadioBookmarks.pathNote(bookmarked: true, observerNotes: "lot B", mine: false) == "lot B")
        #expect(RadioBookmarks.pathNote(bookmarked: false, observerNotes: "lot B", mine: true) == "Marked mine")
        #expect(RadioBookmarks.pathNote(bookmarked: true, observerNotes: "lot B", mine: true) == "lot B\nMarked mine")
    }

    @Test func wifiLocalBitBssidCanTakeACustomName() {
        let ap = wifi(mac: "02:0A:F5:86:56:DD", randomized: true)
        #expect(RadioBookmarks.canSetCustomName(device: ap))
        #expect(RadioBookmarks.customNameHint(device: ap).contains("BSSID"))
        let burned = wifi(mac: "00:0A:F5:86:56:DD", randomized: false)
        #expect(RadioBookmarks.canSetCustomName(device: burned))
        let rotatingBle = ble(name: "tag")
        #expect(!RadioBookmarks.canSetCustomName(device: rotatingBle))
    }

    // MARK: - Helpers

    private func only<T>(_ items: [T]) throws -> T {
        try #require(items.count == 1, "expected one element, got \(items.count)")
        return items[0]
    }

    private func with<T>(_ value: T, _ change: (inout T) -> Void) -> T {
        var copy = value
        change(&copy)
        return copy
    }

    private func wifi(mac: String, randomized: Bool) -> Sighting {
        Sighting(
            key: "WIFI:\(mac)", kind: .wifi, mac: mac, name: "PS-CRADLEPOINT", rssi: -50, rssiMin: -50, rssiMax: -50,
            channel: 1, frequencyMhz: 2412, vendor: nil, randomized: randomized, hiddenSsid: false,
            serviceUuids: [], manufacturerId: nil, manufacturerDataHex: "", rawHex: "", extras: "",
            firstSeen: 1, lastSeen: 1, hitCount: 1, fleetIds: [], rssiHistory: [], presence: []
        )
    }

    private func ble(name: String) -> Sighting {
        Sighting(
            key: "BLE:AA:BB:CC:DD:EE:FF", kind: .ble, mac: "AA:BB:CC:DD:EE:FF", name: name, rssi: -50, rssiMin: -50, rssiMax: -50,
            channel: 0, frequencyMhz: 0, vendor: nil, randomized: true, hiddenSsid: false,
            serviceUuids: [], manufacturerId: nil, manufacturerDataHex: "", rawHex: "", extras: "",
            firstSeen: 1, lastSeen: 1, hitCount: 1, fleetIds: [], rssiHistory: [], presence: []
        )
    }

    @Test func macBleIdentifiersCanBeNamed() {
        let d = Sighting(
            key: "BLE:EF34E465-135B-0D44-3994-075F8D871462", kind: .ble, mac: "EF34E465-135B-0D44-3994-075F8D871462",
            name: "", rssi: -60, rssiMin: -60, rssiMax: -60, channel: 0, frequencyMhz: 2402, vendor: nil,
            randomized: true, hiddenSsid: false, serviceUuids: [], manufacturerId: nil, manufacturerDataHex: "",
            rawHex: "", extras: "", firstSeen: 0, lastSeen: 0, hitCount: 1, fleetIds: [], rssiHistory: [], presence: []
        )
        #expect(RadioBookmarks.canSetCustomName(device: d))
        #expect(RadioBookmarks.customNameHint(device: d).contains("identifier macOS gives this radio"))
    }
}
