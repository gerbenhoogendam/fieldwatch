import Foundation
import Testing
@testable import FieldwatchCore

@Suite struct RoomPlanTests {
    func ble(_ key: String = "BLE:X", at pos: RoomPoint, mode: RoomDevice.Mode = .follow) -> RoomDevice {
        RoomDevice(key: key, label: key, kind: .ble, pos: pos, mode: mode)
    }

    /// RSSI a radio with this model would produce at `d` meters.
    func rssi(at d: Double, at1m: Double, n: Double) -> Double { at1m - 10 * n * log10(d) }

    @Test func oneCalibrationMakesThatDistanceExact() {
        var dev = ble(at: RoomPoint(x: 1.8, y: 0))
        dev.calibrations = [RoomCalibration(distanceM: 1.8, rssi: -63.5, at: 0, spotId: "s")]
        let m = RoomModel.of(device: dev, roomN: 2.2)
        #expect(m.calibrated && !m.fittedN)
        #expect(abs(m.distance(rssi: -63.5) - 1.8) < 1e-9)
        // Further away is quieter.
        #expect(m.distance(rssi: -70) > 1.8)
    }

    @Test func twoCalibrationsFitTheExponent() {
        let at1m = -52.0, n = 2.8
        var dev = ble(at: .zero)
        dev.calibrations = [
            RoomCalibration(distanceM: 1.0, rssi: rssi(at: 1.0, at1m: at1m, n: n), at: 0, spotId: "s"),
            RoomCalibration(distanceM: 4.5, rssi: rssi(at: 4.5, at1m: at1m, n: n), at: 1, spotId: "s"),
        ]
        let m = RoomModel.of(device: dev, roomN: 2.2)
        #expect(m.fittedN)
        #expect(abs(m.n - n) < 1e-6)
        #expect(abs(m.at1m - at1m) < 1e-6)
        #expect(abs(m.distance(rssi: rssi(at: 20, at1m: at1m, n: n)) - 20) < 1e-6)
    }

    @Test func uncalibratedBandIsWider() {
        var dev = ble(at: .zero)
        let raw = RoomModel.of(device: dev, roomN: 2.2)
        dev.calibrations = [RoomCalibration(distanceM: 2, rssi: -65, at: 0, spotId: "s")]
        let cal = RoomModel.of(device: dev, roomN: 2.2)
        let a = raw.band(rssi: -65, spread: 2), b = cal.band(rssi: -65, spread: 2)
        #expect(a.high / a.low > b.high / b.low)
        #expect(b.low < 2 && b.high > 2)
    }

    @Test func smoothingIgnoresOutliersAndOldSamples() throws {
        let now = 100_000
        var h = (0..<20).map { RssiSample(at: now - 5_000 + $0 * 200, rssi: -60 + ($0 % 3) - 1) }
        h.append(RssiSample(at: now - 1_000, rssi: -30))            // one reflection spike
        h.append(RssiSample(at: now - 60_000, rssi: -90))           // too old
        h.append(RssiSample(at: now - 500, rssi: 127))              // "not available"
        let s = try #require(RoomTracker.smoothed(history: h, now: now, windowMs: 8_000))
        #expect(s.rssi == -60)
        #expect(s.spread >= 1 && s.spread < 3)
        #expect(s.count == 21)
    }

    @Test func followKeepsBearingAndMovesToMeasuredDistance() throws {
        var plan = RoomPlan(now: 0)
        var dev = ble(at: RoomPoint(x: 3, y: 4))   // bearing 3-4-5 from the Mac at the origin
        dev.calibrations = [RoomCalibration(distanceM: 5, rssi: -70, at: 0, spotId: plan.spotId)]
        plan.devices = [dev]
        let model = RoomModel.of(device: dev, roomN: plan.pathLossN)
        let quieter = rssi(at: 10, at1m: model.at1m, n: model.n)
        let t = try #require(RoomTracker.track(device: dev, plan: plan, live: (quieter, 1, 20), txPowerDbm: nil, now: 1))
        #expect(abs(t.distanceM - 10) < 1e-6)
        #expect(abs(t.pos.x - 6) < 1e-6 && abs(t.pos.y - 8) < 1e-6)
        #expect(!t.trilaterated)
    }

    @Test func pinnedStaysAndFlagsAMove() throws {
        let plan = RoomPlan(now: 0)
        var dev = ble(at: RoomPoint(x: 1.8, y: 0), mode: .pinned)
        dev.calibrations = [RoomCalibration(distanceM: 1.8, rssi: -60, at: 0, spotId: plan.spotId)]
        dev.referenceDistanceM = 1.8
        dev.referenceSpotId = plan.spotId
        let model = RoomModel.of(device: dev, roomN: plan.pathLossN)
        let still = try #require(RoomTracker.track(device: dev, plan: plan, live: (-60, 1.5, 20), txPowerDbm: nil, now: 1))
        #expect(!still.moved)
        #expect(still.pos == dev.pos)
        let far = rssi(at: 6, at1m: model.at1m, n: model.n)
        let moved = try #require(RoomTracker.track(device: dev, plan: plan, live: (far, 1.5, 20), txPowerDbm: nil, now: 2))
        #expect(moved.moved)
        #expect(moved.pos == dev.pos)
    }

    @Test func threeSpotsTrilaterate() throws {
        var plan = RoomPlan(now: 0)
        let truth = RoomPoint(x: 2.5, y: 1.7)
        plan.moveLaptop(to: RoomPoint(x: 4, y: 0), now: 1)
        plan.moveLaptop(to: RoomPoint(x: 0, y: 3.5), now: 2)
        #expect(plan.spots.count == 3)
        var dev = ble(at: RoomPoint(x: 1, y: 1))
        dev.calibrations = [RoomCalibration(distanceM: 1, rssi: -55, at: 0, spotId: plan.spots[0].id)]
        let model = RoomModel.of(device: dev, roomN: plan.pathLossN)
        dev.readings = plan.spots.map { s in
            RoomReading(spotId: s.id, rssi: rssi(at: truth.distance(to: s.pos), at1m: model.at1m, n: model.n), spread: 1, count: 10, at: 3)
        }
        plan.devices = [dev]
        let t = try #require(RoomTracker.track(device: dev, plan: plan, live: nil, txPowerDbm: nil, now: 4))
        #expect(t.trilaterated)
        #expect(t.pos.distance(to: truth) < 0.05, "off by \(t.pos.distance(to: truth)) m")
    }

    @Test func wallLengthStretchesARectangle() throws {
        var plan = RoomPlan(now: 0)
        let a = RoomPoint(x: 0, y: 0), b = RoomPoint(x: 10, y: 0), c = RoomPoint(x: 10, y: 8.2), d = RoomPoint(x: 0, y: 8.2)
        plan.walls = [RoomWall(id: "top", a: a, b: b), RoomWall(id: "right", a: b, b: c),
                      RoomWall(id: "bottom", a: c, b: d), RoomWall(id: "left", a: d, b: a)]
        plan.setWallLength(id: "top", meters: 12.35)
        let byId = Dictionary(uniqueKeysWithValues: plan.walls.map { ($0.id, $0) })
        #expect(abs(try #require(byId["top"]).length - 12.35) < 1e-9)
        #expect(abs(try #require(byId["bottom"]).length - 12.35) < 1e-9)
        #expect(abs(try #require(byId["right"]).length - 8.2) < 1e-9)
        #expect(abs(try #require(byId["left"]).length - 8.2) < 1e-9)
        #expect(try #require(byId["right"]).a == RoomPoint(x: 12.35, y: 0))
        // Shrinking the side wall moves the bottom wall up.
        plan.setWallLength(id: "right", meters: 4.5)
        let after = Dictionary(uniqueKeysWithValues: plan.walls.map { ($0.id, $0) })
        #expect(abs(try #require(after["left"]).length - 4.5) < 1e-9)
        #expect(abs(try #require(after["bottom"]).a.y - 4.5) < 1e-9)
    }

    @Test func moveLaptopReusesNearbySpot() {
        var plan = RoomPlan(now: 0)
        let first = plan.spotId
        plan.moveLaptop(to: RoomPoint(x: 0.3, y: 0.2))
        #expect(plan.spotId == first && plan.spots.count == 1)
        plan.moveLaptop(to: RoomPoint(x: 2, y: 0))
        #expect(plan.spotId != first && plan.spots.count == 2)
    }

    @Test func recordSmoothsTowardNewReadings() {
        var dev = ble(at: .zero)
        RoomTracker.record(device: &dev, spotId: "a", rssi: -60, spread: 2, count: 5, now: 1)
        RoomTracker.record(device: &dev, spotId: "a", rssi: -70, spread: 2, count: 5, now: 2)
        #expect(dev.readings.count == 1)
        #expect(dev.readings[0].rssi < -60 && dev.readings[0].rssi > -70)
        RoomTracker.record(device: &dev, spotId: "b", rssi: -50, spread: 1, count: 1, now: 3)
        #expect(dev.readings.count == 2)
    }

    @Test func storeRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fw-rooms-\(UUID().uuidString)")
        let store = RoomStore(url: dir.appendingPathComponent("rooms.json"))
        var file = store.load()
        #expect(file.rooms.count == 1)
        file.rooms[0].walls = [RoomWall(a: .zero, b: RoomPoint(x: 4.2, y: 0))]
        file.rooms[0].devices = [ble(at: RoomPoint(x: 1, y: 2))]
        store.save(file)
        let back = RoomStore(url: dir.appendingPathComponent("rooms.json")).load()
        #expect(back.rooms == file.rooms)
        #expect(back.selectedId == file.selectedId)
        try? FileManager.default.removeItem(at: dir)
    }
}
