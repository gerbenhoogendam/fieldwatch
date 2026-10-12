import Foundation
import Testing
@testable import FieldwatchCore

// Port of FilterEngineTest.kt.

private func edited<T>(_ value: T, _ edit: (inout T) -> Void) -> T {
    var v = value
    edit(&v)
    return v
}

/// Kotlin `FilterState(a = …, b = …)`; the Swift FilterState only has `init()`.
private func filterState(_ edit: (inout FilterState) -> Void = { _ in }) -> FilterState {
    edited(FilterState(), edit)
}

private func ble(_ key: String) -> Sighting {
    Sighting(
        key: key,
        kind: .ble,
        mac: key.substringAfter(":"),
        name: "",
        rssi: -50,
        rssiMin: -50,
        rssiMax: -50,
        channel: 0,
        frequencyMhz: 0,
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
        fleetIds: [],
        rssiHistory: [],
        presence: []
    )
}

@Suite struct FilterEngineTest {
    private let engine = FilterEngine()
    private let labeled = ble("BLE:AA:BB:CC:DD:EE:FF")
    private let other = ble("BLE:11:22:33:44:55:66")
    private var signed: Sighting { edited(labeled) { $0.fleetIds = ["fleet-airtag"] } }

    @Test func stockPresetsMatchShortSetWithWatchedOnly() throws {
        let presets = engine.defaultPresets()
        #expect(presets.map { $0.id } == ["all", "wifi", "ble", "strong", "with-you", "watched"])
        let watched = try #require(presets.first { $0.id == "watched" })
        #expect(presets.count { $0.id == "watched" } == 1)
        #expect(watched.name == "Watched only")
        #expect(watched.filter.watchedOnly)
        #expect(watched.filter.showWifi)
        #expect(watched.filter.showBle)
        #expect(watched.filter.rssiMin == -100)
        #expect(watched.isBuiltIn())
        #expect(FilterPreset(id: "trackers", name: "Trackers", filter: FilterState()).isBuiltIn())
    }

    @Test func customNamesOnlyKeepsLabeledKeys() {
        let filter = filterState { $0.customNamesOnly = true }
        let keys: Set<String> = [labeled.key]
        #expect(engine.pass(device: labeled, filter: filter, namedRadioKeys: keys))
        #expect(!engine.pass(device: other, filter: filter, namedRadioKeys: keys))
        #expect(!engine.pass(device: labeled, filter: filter, namedRadioKeys: []))
    }

    @Test func customNamesOnlyOffDoesNotHide() {
        #expect(engine.pass(device: other, filter: FilterState(), namedRadioKeys: [labeled.key]))
    }

    @Test func hideFastPairAccountKeyDropsPlazaChipsKeepsPairingAndDual() {
        let hide = filterState { $0.hideFastPairAccountKey = true }
        let account = edited(labeled) { $0.fleetIds = ["fleet-fast-pair"]; $0.fastPairPairing = false }
        let pairing = edited(labeled) { $0.fleetIds = ["fleet-fast-pair"]; $0.fastPairPairing = true }
        let dual = edited(labeled) {
            $0.fleetIds = ["fleet-fast-pair", "fleet-google"]
            $0.fastPairPairing = false
        }
        #expect(!engine.pass(device: account, filter: hide))
        #expect(engine.pass(device: pairing, filter: hide))
        #expect(engine.pass(device: dual, filter: hide))
        #expect(engine.pass(device: account, filter: FilterState()))
    }

    @Test func watchedOnlyKeepsBookmarkedSignature() {
        let filter = filterState { $0.watchedOnly = true }
        #expect(engine.pass(device: signed, filter: filter, watchedFleetIds: ["fleet-airtag"]))
        #expect(!engine.pass(device: signed, filter: filter, watchedFleetIds: []))
        #expect(!engine.pass(device: other, filter: filter, watchedFleetIds: ["fleet-airtag"]))
    }

    @Test func watchedOnlyKeepsAlertNamedRadioNotLabelOnly() {
        let filter = filterState { $0.watchedOnly = true }
        #expect(engine.pass(device: labeled, filter: filter, alertDeviceKeys: [labeled.key]))
        #expect(!engine.pass(device: labeled, filter: filter, namedRadioKeys: [labeled.key]))
    }

    @Test func watchedOnlyAndHideSurveillanceStillHidesCameras() {
        let filter = filterState {
            $0.watchedOnly = true
            $0.useClassFilter = true
            $0.excludeClasses = true
            $0.classes = [.surveillance]
        }
        let flock = edited(signed) { $0.fleetIds = ["fleet-flock"] }
        let axon = edited(other) { $0.fleetIds = ["fleet-axon"] }
        let byClass: [String: SignatureClass] = [
            "fleet-flock": .surveillance,
            "fleet-axon": .lawEnforcement,
        ]
        let watched: Set<String> = ["fleet-flock", "fleet-axon"]
        #expect(!engine.pass(device: flock, filter: filter, classByFleetId: byClass, watchedFleetIds: watched))
        #expect(engine.pass(device: axon, filter: filter, classByFleetId: byClass, watchedFleetIds: watched))
    }

    @Test func watchedOnlyStaysAndInOrLogic() {
        let filter = filterState {
            $0.watchedOnly = true
            $0.logic = .or
            $0.nameQuery = "anything"
        }
        let namedUnwatched = edited(labeled) { $0.name = "anything" }
        #expect(!engine.pass(device: namedUnwatched, filter: filter, watchedFleetIds: ["fleet-airtag"]))
        #expect(engine.pass(device: edited(signed) { $0.name = "anything" }, filter: filter, watchedFleetIds: ["fleet-airtag"]))
    }

    @Test func hideMineDropsMarkedKeysAndKeepsTheRest() {
        let filter = filterState { $0.hideMine = true }
        let mine: Set<String> = [labeled.key]
        #expect(!engine.pass(device: labeled, filter: filter, mineKeys: mine))
        #expect(engine.pass(device: other, filter: filter, mineKeys: mine))
        #expect(engine.pass(device: labeled, filter: FilterState(), mineKeys: mine))
    }

    @Test func hideMineStaysAndInOrLogic() {
        let filter = filterState {
            $0.hideMine = true
            $0.logic = .or
            $0.nameQuery = "anything"
        }
        let named = edited(labeled) { $0.name = "anything" }
        #expect(!engine.pass(device: named, filter: filter, mineKeys: [labeled.key]))
        #expect(engine.pass(device: edited(other) { $0.name = "anything" }, filter: filter, mineKeys: [labeled.key]))
    }

    @Test func signaturesOnlyAndCustomNamesStack() {
        let both = filterState { $0.namedOnly = true; $0.customNamesOnly = true }
        let keys: Set<String> = [labeled.key, other.key]
        #expect(engine.pass(device: signed, filter: both, namedRadioKeys: keys))
        #expect(!engine.pass(device: labeled, filter: both, namedRadioKeys: keys))
        #expect(!engine.pass(device: edited(signed) { $0.key = other.key }, filter: both, namedRadioKeys: [labeled.key]))
    }
}
