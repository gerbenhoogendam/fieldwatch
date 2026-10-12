import Foundation
import Testing
@testable import FieldwatchCore

// Port of GeoExportTest.kt. "Heard at this phone" is "Heard at this Mac" on macOS.

private func with<T>(_ v: T, _ f: (inout T) -> Void) -> T {
    var c = v
    f(&c)
    return c
}

struct GeoExportTest {
    private let cafe = LogRadio(
        kind: .wifi,
        mac: "AA:BB:CC:DD:EE:01",
        name: "CafeWiFi",
        vendor: "Acme",
        manufacturerId: nil,
        manufacturerDataHex: "",
        serviceUuids: [],
        vendorIeOuis: [],
        randomized: false,
        hiddenSsid: false,
        rssi: -60,
        firstSeen: 1_700_000_000_000,
        lastSeen: 1_700_000_000_000,
        hits: 3,
        channel: 6,
        frequencyMhz: 2437,
        latitude: 37.4419,
        longitude: -122.1430
    )
    private var tag: LogRadio {
        with(cafe) {
            $0.kind = .ble
            $0.mac = "11:22:33:44:55:66"
            $0.name = "Tag"
            $0.channel = 0
            $0.frequencyMhz = 2402
            $0.latitude = 37.4420
            $0.longitude = -122.1431
        }
    }
    private var noGps: LogRadio {
        with(cafe) { $0.mac = "00:00:00:00:00:99"; $0.latitude = nil; $0.longitude = nil }
    }

    @Test func gpxDropsUntaggedAndMarksMacHear() {
        let xml = GeoExport.render(
            format: .gpx,
            radios: [cafe, noGps, tag],
            names: [:],
            appVersion: "1.1.6",
            deviceInfo: ""
        )
        #expect(xml.contains("<gpx version=\"1.1\""))
        #expect(xml.contains("lat=\"37.441900\""))
        #expect(xml.contains("lon=\"-122.143000\""))
        #expect(xml.contains("<name>CafeWiFi</name>"))
        #expect(xml.contains("Heard at this Mac. Not a radio fix."))
        #expect(!xml.contains("00:00:00:00:00:99"))
        #expect(xml.components(separatedBy: "<wpt ").count - 1 == 2)
    }

    @Test func kmlUsesLonLatOrder() {
        let xml = GeoExport.render(
            format: .kml,
            radios: [cafe],
            names: [:],
            appVersion: "1.1.6",
            deviceInfo: ""
        )
        #expect(xml.contains("<coordinates>-122.143000,37.441900</coordinates>"))
        #expect(xml.contains("Heard at this Mac"))
    }

    @Test func wigleHeaderAndWifiBleTypes() {
        let csv = GeoExport.render(
            format: .wigle,
            radios: [cafe, tag],
            names: [:],
            appVersion: "1.1.6",
            deviceInfo: "model=A54,release=16"
        )
        let lines = csv.lines().filter { $0.isNotBlank }
        #expect(lines[0].hasPrefix("WigleWifi-1.4,appRelease=Fieldwatch 1.1.6,model=A54"))
        #expect(lines[1].hasPrefix("MAC,SSID,AuthMode,"))
        #expect(lines[2].hasPrefix("AA:BB:CC:DD:EE:01,CafeWiFi,[ESS],"))
        #expect(lines[2].hasSuffix(",WIFI"))
        #expect(lines.contains { $0.hasPrefix("11:22:33:44:55:66,Tag,,") && $0.hasSuffix(",BLE") })
    }

    @Test func wigleNameGuardsFormulaAndKeepsNumbers() {
        let hostile = with(cafe) { $0.mac = "AA:BB:CC:DD:EE:FF"; $0.name = "=cmd|' /c calc'!A0"; $0.rssi = -50 }
        let numeric = with(cafe) { $0.mac = "AA:BB:CC:DD:EE:10"; $0.name = "-50" }
        let sum = with(cafe) { $0.mac = "AA:BB:CC:DD:EE:11"; $0.name = "-1+1" }
        let at = with(tag) { $0.mac = "11:22:33:44:55:77"; $0.name = "@SUM(1+1)" }
        let spaced = with(cafe) { $0.mac = "AA:BB:CC:DD:EE:12"; $0.name = " =HYPERLINK(\"http://evil\")" }
        let comma = with(cafe) { $0.mac = "AA:BB:CC:DD:EE:13"; $0.name = "Cafe,WiFi" }
        let hidden = with(cafe) { $0.mac = "AA:BB:CC:DD:EE:14"; $0.name = "=hidden"; $0.hiddenSsid = true }
        let csv = GeoExport.render(
            format: .wigle,
            radios: [hostile, numeric, sum, at, spaced, comma, hidden],
            names: [:],
            appVersion: "1.1.20",
            deviceInfo: ""
        )
        let lines = csv.lines()
        #expect(lines[0].hasPrefix("WigleWifi-1.4,appRelease=Fieldwatch 1.1.20"))
        let formula = lines.first { $0.hasPrefix("AA:BB:CC:DD:EE:FF,") }!
        #expect(formula.hasPrefix("AA:BB:CC:DD:EE:FF,'=cmd|' /c calc'!A0,[ESS],"))
        #expect(!formula.contains(",=cmd|"))
        #expect(formula.contains(",-50,"))
        #expect(formula.contains(",-122.143000,"))
        #expect(lines.first { $0.hasPrefix("AA:BB:CC:DD:EE:10,") }!.hasPrefix("AA:BB:CC:DD:EE:10,-50,[ESS],"))
        #expect(lines.first { $0.hasPrefix("AA:BB:CC:DD:EE:11,") }!.hasPrefix("AA:BB:CC:DD:EE:11,'-1+1,[ESS],"))
        #expect(lines.first { $0.hasPrefix("11:22:33:44:55:77,") }!.hasPrefix("11:22:33:44:55:77,'@SUM(1+1),,"))
        #expect(lines.contains { $0.hasPrefix("AA:BB:CC:DD:EE:12,\"' =HYPERLINK(\"\"http://evil\"\")\",[ESS],") })
        #expect(lines.contains { $0.hasPrefix("AA:BB:CC:DD:EE:13,\"Cafe,WiFi\",[ESS],") })
        #expect(lines.first { $0.hasPrefix("AA:BB:CC:DD:EE:14,") }!.hasPrefix("AA:BB:CC:DD:EE:14,,[ESS],"))
    }

    @Test func gpxAndKmlIncludeOperatorTrack() {
        let path = [
            GpsSample(at: 1_700_000_000_000, lat: 37.4419, lon: -122.1430),
            GpsSample(at: 1_700_000_030_000, lat: 37.4425, lon: -122.1435),
        ]
        let gpx = GeoExport.render(
            format: .gpx, radios: [cafe], names: [:], appVersion: "1.1.7", deviceInfo: "",
            observerNotes: [cafe.key: "lot B"],
            track: path
        )
        #expect(gpx.contains("<trk>"))
        #expect(gpx.contains("Operator path"))
        #expect(gpx.contains("lat=\"37.442500\""))
        #expect(gpx.contains("Observer: lot B"))
        let kml = GeoExport.render(
            format: .kml, radios: [cafe], names: [:], appVersion: "1.1.7", deviceInfo: "",
            track: path
        )
        #expect(kml.contains("<LineString>"))
        #expect(kml.contains("-122.143500,37.442500"))
    }
}
