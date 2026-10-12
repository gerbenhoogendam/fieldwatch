import Foundation
import Testing
@testable import FieldwatchCore

@Suite struct PositionFieldTests {
    let lat0 = 51.4779
    let lon0 = -0.0015
    var mLat: Double { 111_320.0 }
    var mLon: Double { 111_320.0 * cos(lat0 * .pi / 180) }

    func point(_ x: Double, _ y: Double) -> (Double, Double) { (lat0 + y / mLat, lon0 + x / mLon) }

    func metersBetween(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        Geo.meters(lat1: a.0, lon1: a.1, lat2: b.0, lon2: b.1)
    }

    /// Deterministic ±amp noise so the test never flakes.
    func noise(_ i: Int, amp: Double) -> Double { sin(Double(i) * 12.9898) * amp }

    func device(kind: RadioKind = .wifi, key: String = "WIFI:AA:BB:CC:00:11:22") -> Sighting {
        Sighting(
            key: key, kind: kind, mac: "AA:BB:CC:00:11:22", name: "test", rssi: -60, rssiMin: -80, rssiMax: -50,
            channel: 6, frequencyMhz: 2437, vendor: nil, randomized: false, hiddenSsid: false, serviceUuids: [],
            manufacturerId: nil, manufacturerDataHex: "", rawHex: "", extras: "", firstSeen: 0, lastSeen: 0,
            hitCount: 1, fleetIds: [], rssiHistory: [], presence: []
        )
    }

    @Test func distanceModelIsMonotoneAndClamped() {
        let at1m = PositionEstimator.rssiAt1m(kind: .wifi, txPowerDbm: nil)
        #expect(PositionEstimator.distanceM(rssi: at1m, at1m: at1m) == 1)
        #expect(PositionEstimator.distanceM(rssi: -60, at1m: at1m) < PositionEstimator.distanceM(rssi: -75, at1m: at1m))
        #expect(PositionEstimator.distanceM(rssi: -200, at1m: at1m) == PositionEstimator.MAX_RANGE_M)
        #expect(PositionEstimator.rssiAt1m(kind: .ble, txPowerDbm: 4) == -37)
        #expect(PositionEstimator.rssiAt1m(kind: .ble, txPowerDbm: nil) == -59)
    }

    @Test func fieldAveragesWithinACellAndSplitsDistantSpots() {
        let field = PositionField()
        // Two hears at one spot average; a spot 60 m away is its own cell. (Points 1–2 m apart can sit on
        // either side of a 10 m cell boundary, so the test does not rely on that.)
        let a = point(0, 0), b = a, far = point(60, 0)
        field.record(key: "k", lat: a.0, lon: a.1, rssi: -60, at: 1)
        field.record(key: "k", lat: b.0, lon: b.1, rssi: -70, at: 2)
        field.record(key: "k", lat: far.0, lon: far.1, rssi: -80, at: 3)
        field.record(key: "k", lat: 0, lon: 0, rssi: -50, at: 4)   // null island is ignored
        field.record(key: "k", lat: a.0, lon: a.1, rssi: 127, at: 5) // "not available" is ignored
        let s = field.samples(key: "k")
        #expect(s.count == 2)
        let near = s.first { $0.count == 2 }!
        #expect(near.rssi == -65)
        #expect(s.contains { $0.count == 1 && $0.rssi == -80 })
        field.clear()
        #expect(field.samples(key: "k").isEmpty)
    }

    @Test func walkingAroundATransmitterLocatesIt() throws {
        // Transmitter 25 m east, 10 m north of the start; operator walks a 45 m-radius loop around it.
        let tx = (25.0, 10.0)
        let at1m = PositionEstimator.rssiAt1m(kind: .wifi, txPowerDbm: nil)
        let field = PositionField()
        for i in 0..<24 {
            let a = Double(i) / 24 * 2 * .pi
            let x = tx.0 + 45 * cos(a), y = tx.1 + 45 * sin(a)
            let d = hypot(x - tx.0, y - tx.1)
            let rssi = at1m - 10 * PositionEstimator.PATH_LOSS_N * log10(d) + noise(i, amp: 3)
            let p = point(x, y)
            field.record(key: "k", lat: p.0, lon: p.1, rssi: Int(rssi.rounded()), at: i * 1000)
        }
        let est = try #require(PositionEstimator.estimate(device: device(key: "k"), samples: field.samples(key: "k")))
        #expect(est.quality == .located)
        let err = metersBetween((est.lat, est.lon), point(tx.0, tx.1))
        #expect(err < 15, "error \(err) m")
        #expect(est.radiusM >= PositionEstimator.FIX_ERROR_M)
        #expect(est.spots >= 20)
    }

    @Test func passingByOnOneSideStillPullsTowardTheLoudSide() throws {
        // Straight 80 m walk along y = 0; transmitter 20 m north of the middle.
        let tx = (40.0, 20.0)
        let at1m = PositionEstimator.rssiAt1m(kind: .ble, txPowerDbm: nil)
        let field = PositionField()
        for i in 0...16 {
            let x = Double(i) * 5
            let d = hypot(x - tx.0, tx.1)
            let rssi = at1m - 10 * PositionEstimator.PATH_LOSS_N * log10(d) + noise(i, amp: 2)
            let p = point(x, 0)
            field.record(key: "k", lat: p.0, lon: p.1, rssi: Int(rssi.rounded()), at: i * 1000)
        }
        let est = try #require(PositionEstimator.estimate(device: device(kind: .ble, key: "k"), samples: field.samples(key: "k")))
        #expect(est.quality == .located)
        // A line walk cannot tell north from south; the along-track position must still be right.
        let east = (est.lon - lon0) * mLon
        #expect(abs(east - tx.0) < 12, "east \(east)")
        #expect(metersBetween((est.lat, est.lon), point(tx.0, tx.1)) <= max(est.radiusM * 2.5, 45))
    }

    @Test func standingStillIsRoughAroundTheMac() throws {
        let field = PositionField()
        let p = point(0, 0)
        for i in 0..<30 { field.record(key: "k", lat: p.0, lon: p.1, rssi: -70, at: i) }
        let est = try #require(PositionEstimator.estimate(device: device(key: "k"), samples: field.samples(key: "k")))
        #expect(est.quality == .rough)
        #expect(metersBetween((est.lat, est.lon), p) < 1)
        let implied = PositionEstimator.distanceM(rssi: -70, at1m: PositionEstimator.rssiAt1m(kind: .wifi, txPowerDbm: nil))
        #expect(est.radiusM >= implied)
        // Upper bound: a strong AP in free space at −70 dBm reaches ~126 m.
        #expect(abs(est.radiusM - PositionEstimator.distanceM(rssi: -70, at1m: -28, n: 2)) < 1, "radius \(est.radiusM)")
    }

    @Test func advertisedPositionWins() throws {
        var d = device(kind: .ble, key: "k")
        d.payloadLat = 52.37
        d.payloadLon = 4.94
        let est = try #require(PositionEstimator.estimate(device: d, samples: []))
        #expect(est.quality == .advertised)
        #expect(est.lat == 52.37 && est.lon == 4.94)
    }

    @Test func noSamplesNoEstimate() {
        #expect(PositionEstimator.estimate(device: device(), samples: []) == nil)
    }
}
