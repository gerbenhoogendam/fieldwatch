import Foundation

// macOS addition (not in the Android app): a sketched room with radios placed relative to this Mac.
//
// Coordinates are meters on a flat plan: x to the right, y down (screen order). The Mac is the
// reference ("beacon") the operator moves around the plan. A receive-only radio measures loudness,
// not direction, so:
//   - the operator sketches walls and places each radio where it really is (that fixes the bearing);
//   - "identify" = tell Fieldwatch a true distance; that calibrates the radio's loudness at 1 m
//     (two distances also fit the room's path-loss exponent for that radio);
//   - while the Mac stays on one spot, a radio follows its measured distance along the line to the Mac;
//   - readings from three or more Mac spots trilaterate the radio in 2D.
// RSSI indoors swings several dB, so every distance carries a ± band. Decimals are shown, not promised.

public struct RoomPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }

    public static let zero = RoomPoint(x: 0, y: 0)

    public func distance(to o: RoomPoint) -> Double { hypot(x - o.x, y - o.y) }
    public static func + (a: RoomPoint, b: RoomPoint) -> RoomPoint { RoomPoint(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: RoomPoint, b: RoomPoint) -> RoomPoint { RoomPoint(x: a.x - b.x, y: a.y - b.y) }
    public static func * (a: RoomPoint, k: Double) -> RoomPoint { RoomPoint(x: a.x * k, y: a.y * k) }
    public var length: Double { hypot(x, y) }
}

public struct RoomWall: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var a: RoomPoint
    public var b: RoomPoint
    public init(id: String = UUID().uuidString.lowercased(), a: RoomPoint, b: RoomPoint) { self.id = id; self.a = a; self.b = b }
    public var length: Double { a.distance(to: b) }
}

/// A place the Mac stood. Readings are kept per spot so several spots can trilaterate.
public struct RoomSpot: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var pos: RoomPoint
    public var at: Int
    public init(id: String = UUID().uuidString.lowercased(), pos: RoomPoint, at: Int) { self.id = id; self.pos = pos; self.at = at }
}

/// "This radio is really `distanceM` from the Mac" while it heard `rssi` (smoothed).
public struct RoomCalibration: Codable, Hashable, Sendable {
    public var distanceM: Double
    public var rssi: Double
    public var at: Int
    public var spotId: String
    public init(distanceM: Double, rssi: Double, at: Int, spotId: String) {
        self.distanceM = distanceM; self.rssi = rssi; self.at = at; self.spotId = spotId
    }
}

/// Smoothed loudness of one radio heard from one Mac spot.
public struct RoomReading: Codable, Hashable, Sendable {
    public var spotId: String
    public var rssi: Double
    public var spread: Double
    public var count: Int
    public var at: Int
    public init(spotId: String, rssi: Double, spread: Double, count: Int, at: Int) {
        self.spotId = spotId; self.rssi = rssi; self.spread = spread; self.count = count; self.at = at
    }
}

public struct RoomDevice: Codable, Hashable, Sendable, Identifiable {
    public enum Mode: String, Codable, Hashable, Sendable, CaseIterable {
        /// Moves with its measured distance (and with trilateration when spots allow).
        case follow
        /// Stays where the operator put it; still shows the measured distance and a moved warning.
        case pinned
    }

    public var id: String { key }
    public var key: String
    public var label: String
    public var kind: RadioKind
    public var pos: RoomPoint
    public var mode: Mode
    public var calibrations: [RoomCalibration]
    public var readings: [RoomReading]
    /// Measured distance when last placed or calibrated; a big change means the radio moved.
    public var referenceDistanceM: Double?
    public var referenceSpotId: String?

    public init(key: String, label: String, kind: RadioKind, pos: RoomPoint, mode: Mode = .follow,
                calibrations: [RoomCalibration] = [], readings: [RoomReading] = [],
                referenceDistanceM: Double? = nil, referenceSpotId: String? = nil) {
        self.key = key; self.label = label; self.kind = kind; self.pos = pos; self.mode = mode
        self.calibrations = calibrations; self.readings = readings
        self.referenceDistanceM = referenceDistanceM; self.referenceSpotId = referenceSpotId
    }
}

public struct RoomPlan: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var walls: [RoomWall]
    /// Where the Mac is now.
    public var laptop: RoomPoint
    public var spotId: String
    public var spots: [RoomSpot]
    public var devices: [RoomDevice]
    /// Path-loss exponent for radios without their own two-point calibration.
    public var pathLossN: Double
    public var createdAt: Int
    public var updatedAt: Int

    public init(name: String = "Room", now: Int = nowMs()) {
        let spot = RoomSpot(pos: .zero, at: now)
        id = UUID().uuidString.lowercased()
        self.name = name
        walls = []
        laptop = .zero
        spotId = spot.id
        spots = [spot]
        devices = []
        pathLossN = RoomModel.DEFAULT_N
        createdAt = now
        updatedAt = now
    }

    public func device(key: String) -> RoomDevice? { devices.first { $0.key == key } }

    /// Make a wall exactly `meters` long. Its start stays; every wall end at or beyond its old end along
    /// the wall's direction shifts by the same amount (a CAD-style stretch), so a rectangle stays rectangular.
    public mutating func setWallLength(id: String, meters: Double) {
        guard let w = walls.first(where: { $0.id == id }), w.length > 1e-6, meters > 0 else { return }
        let dir = (w.b - w.a) * (1 / w.length)
        let delta = dir * (meters - w.length)
        let cut = w.length - 0.005
        for i in walls.indices {
            for end in 0...1 {
                let pt = end == 0 ? walls[i].a : walls[i].b
                let proj = (pt.x - w.a.x) * dir.x + (pt.y - w.a.y) * dir.y
                guard proj >= cut else { continue }
                if end == 0 { walls[i].a = pt + delta } else { walls[i].b = pt + delta }
            }
        }
    }

    /// The Mac moved to `pos`: reuse a spot within 0.5 m, else start a new one.
    public mutating func moveLaptop(to pos: RoomPoint, now: Int = nowMs()) {
        laptop = pos
        if let near = spots.first(where: { $0.pos.distance(to: pos) < 0.5 }) {
            spotId = near.id
        } else {
            let spot = RoomSpot(pos: pos, at: now)
            spots.append(spot)
            spotId = spot.id
        }
        updatedAt = now
    }
}

/// Loudness → distance for one radio.
public struct RoomModel: Hashable, Sendable {
    public static let DEFAULT_N = 2.2
    /// Extra dB of doubt for a radio that was never calibrated (unknown transmit power).
    public static let UNCALIBRATED_DB = 6.0
    /// Model error that remains after calibration (multipath, antenna angle).
    public static let MODEL_DB = 2.0

    public var at1m: Double
    public var n: Double
    public var calibrated: Bool
    /// True when two distances fitted `n` for this radio.
    public var fittedN: Bool

    public init(at1m: Double, n: Double, calibrated: Bool, fittedN: Bool) {
        self.at1m = at1m; self.n = n; self.calibrated = calibrated; self.fittedN = fittedN
    }

    public func distance(rssi: Double) -> Double {
        pow(10, (at1m - rssi) / (10 * n)).coerceIn(0.1, 500)
    }

    /// Distance band for a reading with this much spread (dB).
    public func band(rssi: Double, spread: Double) -> (low: Double, high: Double) {
        let doubt = (spread * spread + RoomModel.MODEL_DB * RoomModel.MODEL_DB).squareRoot()
            + (calibrated ? 0 : RoomModel.UNCALIBRATED_DB)
        return (distance(rssi: rssi + doubt), distance(rssi: rssi - doubt))
    }

    /// Model for a radio: its calibrations, else the generic loudness at 1 m for its kind.
    public static func of(device: RoomDevice, roomN: Double, txPowerDbm: Int? = nil) -> RoomModel {
        let cals = device.calibrations.filter { $0.distanceM > 0 }
        let distinct = Set(cals.map { ($0.distanceM * 10).rounded() })
        if cals.count >= 2, distinct.count >= 2 {
            // Least squares on rssi = at1m − 10·n·log10(d).
            let xs = cals.map { -10 * log10($0.distanceM) }
            let ys = cals.map { $0.rssi }
            let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
            var sxy = 0.0, sxx = 0.0
            for i in xs.indices { sxy += (xs[i] - mx) * (ys[i] - my); sxx += (xs[i] - mx) * (xs[i] - mx) }
            if sxx > 1e-9 {
                let n = (sxy / sxx).coerceIn(1.4, 4.5)
                return RoomModel(at1m: my - n * mx, n: n, calibrated: true, fittedN: true)
            }
        }
        if let last = cals.last {
            return RoomModel(at1m: last.rssi + 10 * roomN * log10(last.distanceM), n: roomN, calibrated: true, fittedN: false)
        }
        let at1m = PositionEstimator.rssiAt1m(kind: device.kind, txPowerDbm: txPowerDbm)
        return RoomModel(at1m: at1m, n: roomN, calibrated: false, fittedN: false)
    }
}

/// Live state of one radio in the room, recomputed each tick.
public struct RoomTrack: Hashable, Sendable {
    public var key: String
    public var rssi: Double
    public var spread: Double
    public var samples: Int
    public var distanceM: Double
    public var lowM: Double
    public var highM: Double
    /// Where the radio is drawn now.
    public var pos: RoomPoint
    public var trilaterated: Bool
    public var moved: Bool
    public var stale: Bool
}

public enum RoomTracker {
    /// Window for smoothing: BLE advertises often, Wi-Fi is scanned every 10–45 s.
    public static func windowMs(kind: RadioKind) -> Int { kind == .wifi ? 45_000 : 8_000 }

    /// Median loudness over the recent window and its spread (dB, from the median absolute deviation).
    public static func smoothed(history: [RssiSample], now: Int, windowMs: Int) -> (rssi: Double, spread: Double, count: Int)? {
        let vals = history.filter { $0.at >= now - windowMs && Rssi.measured(rssi: $0.rssi) }.map { Double($0.rssi) }.sorted()
        guard !vals.isEmpty else { return nil }
        let med = median(vals)
        let mad = median(vals.map { abs($0 - med) }.sorted())
        // 1.4826 · MAD ≈ σ for normal noise; at least 1 dB, more when only a sample or two.
        let spread = max(1.4826 * mad, vals.count < 3 ? 3 : 1)
        return (med, spread, vals.count)
    }

    static func median(_ sorted: [Double]) -> Double {
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    /// Merge a fresh smoothed reading into the device's reading for the current spot.
    public static func record(device: inout RoomDevice, spotId: String, rssi: Double, spread: Double, count: Int, now: Int) {
        if let i = device.readings.firstIndex(where: { $0.spotId == spotId }) {
            var r = device.readings[i]
            // Exponential smoothing keeps the reading steady but lets a moved radio show within ~10 s.
            let k = 0.3
            r.rssi = r.rssi + k * (rssi - r.rssi)
            r.spread = r.spread + k * (spread - r.spread)
            r.count += count
            r.at = now
            device.readings[i] = r
        } else {
            device.readings.append(RoomReading(spotId: spotId, rssi: rssi, spread: spread, count: count, at: now))
        }
    }

    /// Where to draw a radio given its readings.
    /// - Three or more spots ≥ 1 m apart: least-squares trilateration (bearing comes from geometry).
    /// - Otherwise: keep the operator's bearing from the Mac, move along it to the measured distance.
    /// Pinned radios never move; they only report `moved`.
    public static func track(device: RoomDevice, plan: RoomPlan, live: (rssi: Double, spread: Double, count: Int)?,
                             txPowerDbm: Int?, now: Int, staleMs: Int = 60_000) -> RoomTrack? {
        let model = RoomModel.of(device: device, roomN: plan.pathLossN, txPowerDbm: txPowerDbm)
        let current = device.readings.first { $0.spotId == plan.spotId }
        guard let reading = live.map({ (rssi: $0.rssi, spread: $0.spread, at: now) })
            ?? current.map({ (rssi: $0.rssi, spread: $0.spread, at: $0.at) }) else { return nil }
        let d = model.distance(rssi: reading.rssi)
        let band = model.band(rssi: reading.rssi, spread: reading.spread)
        var pos = device.pos
        var tri = false
        if device.mode == .follow {
            if let solved = trilaterate(device: device, plan: plan, model: model) {
                pos = solved
                tri = true
            } else {
                let dir = device.pos - plan.laptop
                let unit = dir.length > 1e-6 ? dir * (1 / dir.length) : RoomPoint(x: 1, y: 0)
                pos = plan.laptop + unit * d
            }
        }
        var moved = false
        if let ref = device.referenceDistanceM, device.referenceSpotId == plan.spotId {
            // Outside the band around the reference, by at least 30 cm.
            let refBand = (low: min(band.low, d - 0.3), high: max(band.high, d + 0.3))
            moved = ref < refBand.low || ref > refBand.high
        }
        return RoomTrack(
            key: device.key, rssi: reading.rssi, spread: reading.spread, samples: live?.count ?? 0,
            distanceM: d, lowM: band.low, highM: band.high, pos: pos, trilaterated: tri, moved: moved,
            stale: now - reading.at > staleMs
        )
    }

    /// Least-squares position from readings at three or more spots (Gauss–Newton from the current position).
    public static func trilaterate(device: RoomDevice, plan: RoomPlan, model: RoomModel) -> RoomPoint? {
        let spotsById = Dictionary(plan.spots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pairs: [(RoomPoint, Double, Double)] = device.readings.compactMap { r in
            guard let spot = spotsById[r.spotId] else { return nil }
            let d = model.distance(rssi: r.rssi)
            // Far, noisy readings count less.
            return (spot.pos, d, 1 / max(d * d, 0.25) / max(r.spread, 1))
        }
        guard pairs.count >= 3 else { return nil }
        var spread = 0.0
        for i in pairs.indices { for j in pairs.indices where j > i { spread = max(spread, pairs[i].0.distance(to: pairs[j].0)) } }
        guard spread >= 1.0 else { return nil }
        var x = device.pos.x, y = device.pos.y
        for _ in 0..<50 {
            var a11 = 0.0, a12 = 0.0, a22 = 0.0, b1 = 0.0, b2 = 0.0
            for (p, d, w) in pairs {
                let dx = x - p.x, dy = y - p.y
                let r = max(hypot(dx, dy), 0.05)
                let jx = dx / r, jy = dy / r, res = r - d
                a11 += w * jx * jx; a12 += w * jx * jy; a22 += w * jy * jy
                b1 += w * jx * res; b2 += w * jy * res
            }
            a11 *= 1.001; a22 *= 1.001
            let det = a11 * a22 - a12 * a12
            if abs(det) < 1e-12 { break }
            let sx = -(a22 * b1 - a12 * b2) / det, sy = -(a11 * b2 - a12 * b1) / det
            x += sx; y += sy
            if hypot(sx, sy) < 0.005 { break }
        }
        guard x.isFinite, y.isFinite else { return nil }
        return RoomPoint(x: x, y: y)
    }
}
