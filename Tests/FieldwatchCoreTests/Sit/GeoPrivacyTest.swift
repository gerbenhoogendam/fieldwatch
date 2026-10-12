import Foundation
import Testing
@testable import FieldwatchCore

// Port of GeoPrivacyTest.kt.

struct GeoPrivacyTest {
    @Test func screenCoordMasksWhenDemo() {
        #expect(Geo.screenCoord(lat: nil, lon: -122.41941, demo: false) == nil)
        #expect(Geo.screenCoord(lat: 37.77492, lon: nil, demo: true) == nil)
        #expect(Geo.screenCoord(lat: 37.77492, lon: -122.41941, demo: true) == "masked")
        #expect(Geo.screenCoord(lat: 37.77492, lon: -122.41941, demo: false) == "37.77492, -122.41941")
    }

    @Test func redactCoordsInReplacesSitReportPins() {
        let raw = "Stay  37.77492, -122.41941  (operator phone)\nTransit 37.7750,-122.4200"
        let masked = Geo.redactCoordsIn(text: raw, demo: true)
        #expect(masked.contains("masked"))
        #expect(!masked.contains("37.77492"))
        #expect(!masked.contains("-122.41941"))
        #expect(Geo.redactCoordsIn(text: raw, demo: false) == raw)
    }

    @Test func redactCoordsInLeavesPathMetersAlone() {
        let path = "GPS path so far 123 m. Keep moving (~50 m). Span 45 m."
        #expect(Geo.redactCoordsIn(text: path, demo: true) == path)
    }

    @Test func movingWithYouIgnoresWifiAccessPoints() {
        let now = 1_000_000
        let path = [
            GpsSample(at: now - 60_000, lat: 37.7700, lon: -122.4200),
            GpsSample(at: now - 30_000, lat: 37.7710, lon: -122.4200),
            GpsSample(at: now, lat: 37.7720, lon: -122.4200),
        ]
        let ctx = CoTravel.Ctx.of(path: path)
        #expect(ctx.ready)
        let trail = [
            GpsSample(at: now - 50_000, lat: 37.7702, lon: -122.4200, rssi: -60),
            GpsSample(at: now - 20_000, lat: 37.7712, lon: -122.4200, rssi: -58),
            GpsSample(at: now - 1_000, lat: 37.7719, lon: -122.4200, rssi: -55),
        ]
        let wifi = radio(.wifi, trail, now)
        let ble = radio(.ble, trail, now)
        #expect(!CoTravel.withYou(device: wifi, ctx: ctx, now: now))
        #expect(CoTravel.withYou(device: ble, ctx: ctx, now: now))
    }

    private func radio(_ kind: RadioKind, _ trail: [GpsSample], _ now: Int) -> Sighting {
        let last = trail.last!
        let s = Sighting(
            key: "\(kind.rawValue):AA:BB:CC:DD:EE:01",
            kind: kind,
            mac: "AA:BB:CC:DD:EE:01",
            name: kind == .wifi ? "House" : "Tag",
            rssi: last.rssi,
            rssiMin: -70,
            rssiMax: -50,
            channel: 0,
            frequencyMhz: 0,
            vendor: nil,
            randomized: false,
            hiddenSsid: false,
            serviceUuids: [],
            manufacturerId: nil,
            manufacturerDataHex: "",
            rawHex: "",
            extras: "",
            firstSeen: trail.first!.at,
            lastSeen: last.at,
            hitCount: trail.count,
            fleetIds: [],
            rssiHistory: [],
            presence: [],
            gpsTrail: trail
        )
        precondition(now - s.lastSeen < CoTravel.HEARD_MS)
        return s
    }
}
