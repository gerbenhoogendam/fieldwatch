import Foundation
import Testing
@testable import FieldwatchCore

// Port of SitExportTest.kt.

private func with<T>(_ v: T, _ f: (inout T) -> Void) -> T {
    var c = v
    f(&c)
    return c
}

struct SitExportTest {
    private let wifi = SitExportTest.radio(
        key: "WIFI:AA:BB:CC:DD:EE:01",
        kind: .wifi,
        name: "CafeWiFi",
        rssi: -50,
        channel: 6,
        gps: GpsSample(at: 1_700_000_000_000, lat: 37.4419, lon: -122.1430, rssi: -48)
    )
    private let ble = SitExportTest.radio(
        key: "BLE:11:22:33:44:55:66",
        kind: .ble,
        name: "Tag",
        rssi: -70
    )
    private var extra: Set<String> { [wifi.key] }
    private let fleets = [
        Fleet(id: "fleet-flock-cameras", name: "Flock Safety Cameras", attentionNote: "ALPR"),
        Fleet(id: "fleet-ring", name: "Ring"),
    ]

    @Test func csvOneRowPerRadioWithCustomNameAndNote() {
        let csv = SitExport.csv(
            devices: [wifi, ble],
            radios: .both,
            customNames: [wifi.key: "porch AP"],
            observerNotes: [wifi.key: "lot B"],
            extraKeys: extra,
            fleets: fleets
        )
        #expect(csv.hasPrefix(SitExport.CSV_HEADER))
        #expect(csv.contains("porch AP"))
        #expect(csv.contains("lot B"))
        #expect(csv.contains("37.441900"))
        #expect(csv.contains("true"))
        #expect(csv.contains("Tag"))
        #expect(csv.contains("Flock Safety Cameras; Ring"))
        #expect(csv.contains("Flock Safety Cameras"))
        let data = csv.lines().filter { $0.isNotBlank }.drop(1)
        #expect(data.count == 2)
        let wifiLine = data.first { $0.contains("CafeWiFi") }!
        #expect(wifiLine.contains("Flock Safety Cameras; Ring"), "\(wifiLine)")
        let bleLine = data.first { $0.contains("Tag") }!
        #expect(bleLine.hasSuffix(",false"))
        #expect(SitExport.CSV_HEADER.hasSuffix(",mine"))
        let marked = SitExport.csv(
            devices: [wifi],
            radios: .both,
            customNames: [:],
            observerNotes: [:],
            extraKeys: extra,
            fleets: fleets,
            mineKeys: [wifi.key]
        )
        #expect(marked.lines().first { $0.contains("CafeWiFi") }!.hasSuffix(",true"))
    }

    @Test func wifiOnlyDropsBle() {
        let csv = SitExport.csv(devices: [wifi, ble], radios: .wifi, customNames: [:], observerNotes: [:], extraKeys: [])
        #expect(csv.contains("CafeWiFi"))
        #expect(!csv.contains("Tag"))
    }

    @Test func jsonlIncludesNullLatWhenNoGps() {
        let jsonl = SitExport.jsonl(devices: [ble], radios: .both, customNames: [:], observerNotes: [:], extraKeys: [])
        #expect(jsonl.contains("\"mac\":\"11:22:33:44:55:66\""))
        #expect(jsonl.contains("\"lat\":null"))
        #expect(jsonl.contains("\"lon\":null"))
        #expect(jsonl.contains("\"signatures\":\"\""))
        #expect(jsonl.contains("\"extra_attention_families\":\"\""))
    }

    @Test func csvAndJsonlListSignaturesAndAttentionFamilies() {
        let jsonl = SitExport.jsonl(
            devices: [wifi],
            radios: .both,
            customNames: [:],
            observerNotes: [:],
            extraKeys: extra,
            fleets: fleets
        )
        #expect(jsonl.contains("\"signatures\":\"Flock Safety Cameras; Ring\""))
        #expect(jsonl.contains("\"extra_attention_families\":\"Flock Safety Cameras\""))
        #expect(jsonl.contains("\"extra_attention\":true"))
    }

    @Test func mapRadiosUseLoudestTrailAndSkipUntagged() {
        let pins = SitExport.mapRadios(devices: [wifi, ble], radios: .both)
        #expect(pins.count == 1)
        #expect(abs(pins.single { _ in true }.latitude! - 37.4419) <= 0.00001)
        #expect(abs(pins.single { _ in true }.longitude! - -122.1430) <= 0.00001)
    }

    @Test func csvPrefixesFormulaTextAndLeavesNumbers() {
        let hostile = with(wifi) { $0.name = "=HYPERLINK(\"http://example\")" }
        let negative = with(wifi) { $0.name = "-122.143000" }
        let csv = SitExport.csv(
            devices: [hostile, negative],
            radios: .both,
            customNames: [hostile.key: "+cmd"],
            observerNotes: [hostile.key: "lot, B"],
            extraKeys: []
        )
        #expect(csv.contains("\"'=HYPERLINK(\"\"http://example\"\")\""))
        #expect(csv.contains("-122.143000"))
        #expect(!csv.contains("'-122.143000"))
        #expect(csv.contains("'+cmd"))
        #expect(csv.contains("\"lot, B\""))
        #expect(csv.contains("-122.143000,-122.143000") || csv.contains(",-122.143000,"))
    }

    @Test func suggestedNameSlugsSitTitle() {
        let name = SitExport.suggestedName(kind: .gpx, sitName: "Drive through Target!", stamp: "20260925-120000")
        #expect(name == "fieldwatch-sit-drive-through-target-20260925-120000.gpx")
    }

    private static func radio(
        key: String,
        kind: RadioKind,
        name: String,
        rssi: Int,
        channel: Int = 0,
        gps: GpsSample? = nil
    ) -> Sighting {
        Sighting(
            key: key,
            kind: kind,
            mac: key.substringAfter(":"),
            name: name,
            rssi: rssi,
            rssiMin: rssi,
            rssiMax: rssi,
            channel: channel,
            frequencyMhz: kind == .wifi ? 2437 : 2402,
            vendor: nil,
            randomized: kind == .ble,
            hiddenSsid: false,
            serviceUuids: [],
            manufacturerId: nil,
            manufacturerDataHex: "",
            rawHex: "",
            extras: "",
            firstSeen: 1_700_000_000_000,
            lastSeen: 1_700_000_000_000,
            hitCount: 4,
            fleetIds: key.hasPrefix("WIFI") ? ["fleet-ring", "fleet-flock-cameras"] : [],
            rssiHistory: [],
            presence: [],
            gpsTrail: [gps].compactMap { $0 }
        )
    }
}
