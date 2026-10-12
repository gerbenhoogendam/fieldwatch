import Foundation

// macOS addition (not in the Android app): estimated positions for the Map view.
//
// A receive-only radio cannot tell where a transmitter is — only how loud it is where *this Mac* is.
// While the operator moves, each radio is heard from several places. `PositionField` keeps, per radio,
// a ~10 m grid of where this Mac was and the average loudness heard there. `PositionEstimator` turns
// that into a best guess plus an honest uncertainty radius:
//   - advertised: the radio broadcasts its own position (Remote ID drones) — not an estimate.
//   - located:    heard from several spots far enough apart to triangulate on loudness.
//   - rough:      heard from one area only — the radio is "somewhere around here".
// Loudness is a poor ruler (walls, bodies, antennas), and Mac positioning is Wi-Fi based, so even
// "located" is tens of meters at best.

public struct FieldSample: Hashable, Sendable {
    public var lat: Double
    public var lon: Double
    /// Mean RSSI (dBm) heard in this cell.
    public var rssi: Double
    public var count: Int
    public var lastAt: Int

    public init(lat: Double, lon: Double, rssi: Double, count: Int, lastAt: Int) {
        self.lat = lat; self.lon = lon; self.rssi = rssi; self.count = count; self.lastAt = lastAt
    }
}

/// Per-radio loudness map on a ~10 m grid of this Mac's positions. Thread-safe.
public final class PositionField: @unchecked Sendable {
    public static let CELL_M = 10.0
    public static let MAX_CELLS = 96
    public static let MAX_RADIOS = 4_000

    private struct Cell {
        var sumLat = 0.0
        var sumLon = 0.0
        var sumRssi = 0.0
        var count = 0
        var lastAt = 0
    }

    private struct Radio {
        var cells: [Int64: Cell] = [:]
        var lastAt = 0
    }

    private let lock = NSLock()
    private var radios: [String: Radio] = [:]

    public init() {}

    /// One hear of radio `key` while this Mac was at (lat, lon).
    public func record(key: String, lat: Double, lon: Double, rssi: Int, at: Int) {
        guard Rssi.measured(rssi: rssi), lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 else { return }
        if lat == 0 && lon == 0 { return }
        let id = PositionField.cellId(lat: lat, lon: lon)
        lock.lock()
        defer { lock.unlock() }
        var radio = radios[key] ?? Radio()
        var cell = radio.cells[id] ?? Cell()
        cell.sumLat += lat
        cell.sumLon += lon
        cell.sumRssi += Double(rssi)
        cell.count += 1
        cell.lastAt = at
        radio.cells[id] = cell
        radio.lastAt = at
        if radio.cells.count > PositionField.MAX_CELLS,
           let oldest = radio.cells.min(by: { $0.value.lastAt < $1.value.lastAt })?.key {
            radio.cells.removeValue(forKey: oldest)
        }
        radios[key] = radio
        if radios.count > PositionField.MAX_RADIOS { evictOldestLocked() }
    }

    /// Cells for one radio, oldest first.
    public func samples(key: String) -> [FieldSample] {
        lock.lock()
        defer { lock.unlock() }
        guard let radio = radios[key] else { return [] }
        return radio.cells.values
            .map { c in
                let n = Double(c.count)
                return FieldSample(lat: c.sumLat / n, lon: c.sumLon / n, rssi: c.sumRssi / n, count: c.count, lastAt: c.lastAt)
            }
            .sorted { $0.lastAt != $1.lastAt ? $0.lastAt < $1.lastAt : ($0.lat, $0.lon) < ($1.lat, $1.lon) }
    }

    public var radioCount: Int {
        lock.lock(); defer { lock.unlock() }
        return radios.count
    }

    /// Start over: forget every loudness map.
    public func clear() {
        lock.lock(); radios.removeAll(); lock.unlock()
    }

    private func evictOldestLocked() {
        let drop = radios.count - PositionField.MAX_RADIOS
        guard drop > 0 else { return }
        for (key, _) in radios.sorted(by: { $0.value.lastAt < $1.value.lastAt }).prefix(drop) {
            radios.removeValue(forKey: key)
        }
    }

    /// Grid cell of about CELL_M × CELL_M meters.
    static func cellId(lat: Double, lon: Double) -> Int64 {
        let dLat = CELL_M / 111_320.0
        let dLon = CELL_M / (111_320.0 * max(cos(lat * .pi / 180), 0.01))
        let row = Int64((lat / dLat).rounded(.down))
        let col = Int64((lon / dLon).rounded(.down))
        return row &* 4_000_000 &+ col
    }
}

public struct PositionEstimate: Hashable, Sendable, Identifiable {
    public enum Quality: String, Hashable, Sendable, CaseIterable {
        case advertised, located, rough

        public func label() -> String {
            switch self {
            case .advertised: return "Advertised position"
            case .located: return "Estimated"
            case .rough: return "Rough — heard from one area"
            }
        }
    }

    public var id: String { key }
    public var key: String
    public var lat: Double
    public var lon: Double
    /// About one standard deviation, meters.
    public var radiusM: Double
    public var quality: Quality
    /// Places (≈10 m cells) this Mac heard the radio from.
    public var spots: Int
    /// How far apart those places were, meters.
    public var spreadM: Double
    /// Loudest mean RSSI over all spots.
    public var peakRssi: Int

    public init(key: String, lat: Double, lon: Double, radiusM: Double, quality: Quality, spots: Int, spreadM: Double, peakRssi: Int) {
        self.key = key; self.lat = lat; self.lon = lon; self.radiusM = radiusM; self.quality = quality
        self.spots = spots; self.spreadM = spreadM; self.peakRssi = peakRssi
    }
}

public enum PositionEstimator {
    /// Path-loss exponent: 2 is free space; buildings and bodies push it up.
    public static let PATH_LOSS_N = 2.6
    /// Spots must spread at least this far before loudness can triangulate.
    public static let MIN_SPREAD_M = 15.0
    public static let MIN_SPOTS = 3
    /// Mac positioning error folded into every radius.
    public static let FIX_ERROR_M = 15.0
    public static let MAX_RANGE_M = 250.0

    /// RSSI expected at 1 m. BLE uses the advertised TX power when present (Bluetooth's −41 dB at 1 m).
    public static func rssiAt1m(kind: RadioKind, txPowerDbm: Int?) -> Double {
        if kind == .ble, let tx = txPowerDbm, (-40...20).contains(tx) { return Double(tx) - 41 }
        return kind == .wifi ? -38 : -59
    }

    /// Pessimistic RSSI at 1 m for an upper bound: a strong transmitter (phones and APs often send
    /// harder than a calibrated beacon).
    public static func rssiAt1mUpper(kind: RadioKind, txPowerDbm: Int?) -> Double {
        if kind == .ble, let tx = txPowerDbm, (-40...20).contains(tx) { return Double(tx) - 41 + 6 }
        return kind == .wifi ? -28 : -45
    }

    /// Distance implied by a loudness, meters (log-distance model), clamped to [1, MAX_RANGE_M].
    public static func distanceM(rssi: Double, at1m: Double, n: Double = PATH_LOSS_N) -> Double {
        pow(10, (at1m - rssi) / (10 * n)).coerceIn(1, MAX_RANGE_M)
    }

    /// Best guess for one radio, or nil when nothing places it.
    public static func estimate(device: Sighting, samples: [FieldSample]) -> PositionEstimate? {
        if let lat = device.payloadLat, let lon = device.payloadLon, PayloadLocation.validCoord(lat: lat, lon: lon) {
            return PositionEstimate(
                key: device.key, lat: lat, lon: lon, radiusM: 10, quality: .advertised,
                spots: samples.count, spreadM: 0, peakRssi: device.rssiMax
            )
        }
        return estimate(
            key: device.key, samples: samples,
            at1m: rssiAt1m(kind: device.kind, txPowerDbm: device.facts.txPowerDbm),
            at1mUpper: rssiAt1mUpper(kind: device.kind, txPowerDbm: device.facts.txPowerDbm)
        )
    }

    /// `at1mUpper` sizes the "rough" radius: an upper bound (strong transmitter, free space) because
    /// a rough guess says "within this distance of where this Mac stood".
    public static func estimate(key: String, samples: [FieldSample], at1m: Double, at1mUpper: Double? = nil) -> PositionEstimate? {
        guard let first = samples.first else { return nil }
        // Local flat frame in meters around the first spot (fine at these distances).
        let lat0 = first.lat, lon0 = first.lon
        let mLat = 111_320.0
        let mLon = 111_320.0 * max(cos(lat0 * .pi / 180), 0.01)
        let pts = samples.map { ((($0.lon - lon0) * mLon), (($0.lat - lat0) * mLat)) }
        let dist = samples.map { distanceM(rssi: $0.rssi, at1m: at1m) }
        // Louder and better-sampled spots count more.
        let w = zip(samples, dist).map { s, d in sqrt(Double(s.count)) / (d * d) }
        let wSum = w.reduce(0, +)
        var cx = 0.0, cy = 0.0
        for i in pts.indices { cx += w[i] * pts[i].0; cy += w[i] * pts[i].1 }
        cx /= wSum; cy /= wSum

        var spread = 0.0
        for i in pts.indices {
            for j in pts.indices where j > i {
                spread = max(spread, hypot(pts[i].0 - pts[j].0, pts[i].1 - pts[j].1))
            }
        }
        let peak = Int(samples.map { $0.rssi }.max()!.rounded())
        func toLatLon(_ x: Double, _ y: Double) -> (Double, Double) { (lat0 + y / mLat, lon0 + x / mLon) }

        guard samples.count >= MIN_SPOTS, spread >= MIN_SPREAD_M else {
            // One area: the radio is within reach of where this Mac stood. Bound the reach by the loudest
            // spot under the pessimistic model (strong transmitter, free space: n = 2).
            let loudest = samples.map { $0.rssi }.max()!
            let reach = distanceM(rssi: loudest, at1m: at1mUpper ?? at1m, n: 2.0)
            let (lat, lon) = toLatLon(cx, cy)
            let r = (max(reach, FIX_ERROR_M) + spread / 2).coerceIn(FIX_ERROR_M, MAX_RANGE_M * 2)
            return PositionEstimate(key: key, lat: lat, lon: lon, radiusM: r, quality: .rough,
                                    spots: samples.count, spreadM: spread, peakRssi: peak)
        }

        // Range fit: minimise Σ wᵢ (|x − pᵢ| − dᵢ)² from the weighted centroid (damped Gauss–Newton).
        var x = cx, y = cy
        let fw = zip(samples, dist).map { s, d in Double(s.count).squareRoot() / max(d, 1) }
        var lambda = 1.0
        func cost(_ x: Double, _ y: Double) -> Double {
            var c = 0.0
            for i in pts.indices {
                let r = hypot(x - pts[i].0, y - pts[i].1) - dist[i]
                c += fw[i] * r * r
            }
            return c
        }
        var current = cost(x, y)
        for _ in 0..<40 {
            var a11 = 0.0, a12 = 0.0, a22 = 0.0, b1 = 0.0, b2 = 0.0
            for i in pts.indices {
                let dx = x - pts[i].0, dy = y - pts[i].1
                let range = max(hypot(dx, dy), 0.5)
                let jx = dx / range, jy = dy / range
                let r = range - dist[i]
                a11 += fw[i] * jx * jx; a12 += fw[i] * jx * jy; a22 += fw[i] * jy * jy
                b1 += fw[i] * jx * r; b2 += fw[i] * jy * r
            }
            let m11 = a11 + lambda * (a11 + 1e-9), m22 = a22 + lambda * (a22 + 1e-9)
            let det = m11 * m22 - a12 * a12
            if abs(det) < 1e-12 { break }
            let sx = -(m22 * b1 - a12 * b2) / det
            let sy = -(m11 * b2 - a12 * b1) / det
            let next = cost(x + sx, y + sy)
            if next < current {
                x += sx; y += sy; current = next
                lambda = max(lambda / 3, 1e-4)
                if hypot(sx, sy) < 0.05 { break }
            } else {
                lambda *= 4
                if lambda > 1e6 { break }
            }
        }
        // A fit that wandered far from where the radio was heard is not trusted.
        if hypot(x - cx, y - cy) > spread + MAX_RANGE_M / 2 { x = cx; y = cy }

        var res = 0.0
        let fwSum = fw.reduce(0, +)
        for i in pts.indices {
            let r = hypot(x - pts[i].0, y - pts[i].1) - dist[i]
            res += fw[i] * r * r
        }
        res = (res / fwSum).squareRoot()
        var radius = (res * res + FIX_ERROR_M * FIX_ERROR_M).squareRoot()
        if samples.count < 5 { radius *= 1.5 }
        let (lat, lon) = toLatLon(x, y)
        return PositionEstimate(key: key, lat: lat, lon: lon, radiusM: radius.coerceIn(FIX_ERROR_M, MAX_RANGE_M * 2),
                                quality: .located, spots: samples.count, spreadM: spread, peakRssi: peak)
    }
}
