import Foundation

// Port of domain/GnssCalibration.kt.
// One quiet minute of this receiver's own GPS, saved until the next run.
// The interference check stays off until a run is saved. Export settings does not include it.
// (macOS has no GNSS receiver; kept so a saved profile and the grading logic stay available.)

public enum GnssCalGrade: String, Codable, CaseIterable, Sendable {
    case good = "GOOD", fair = "FAIR", poor = "POOR"

    public func label() -> String {
        switch self {
        case .good: return "Good"
        case .fair: return "Fair"
        case .poor: return "Poor"
        }
    }
}

public struct GnssPhoneProfile: Codable, Hashable, Sendable {
    public var at: Int
    public var grade: GnssCalGrade
    public var cn0Mean: Double
    public var cn0WanderDb: Double
    public var agcWanderDb: Double
    public var agcStepDb: Double
    public var svMean: Double
    public var gapFraction: Double
    public var agcSeen: Bool
    /// Drop the check must clear, under the user's Low / Medium / High. 0 keeps today's bars.
    public var cn0FloorDb: Double
    public var agcFloorDb: Double
    /// Brief measurement gaps are normal here. They do not raise a Medium alert.
    public var ignoreStopped: Bool
    /// Popup, red line, beep, and voice stay off. The fix for a path still works.
    public var suppressAlerts: Bool

    public init(
        at: Int, grade: GnssCalGrade, cn0Mean: Double, cn0WanderDb: Double, agcWanderDb: Double,
        agcStepDb: Double, svMean: Double, gapFraction: Double, agcSeen: Bool, cn0FloorDb: Double = 0.0,
        agcFloorDb: Double = 0.0, ignoreStopped: Bool = false, suppressAlerts: Bool = false
    ) {
        self.at = at; self.grade = grade; self.cn0Mean = cn0Mean; self.cn0WanderDb = cn0WanderDb
        self.agcWanderDb = agcWanderDb; self.agcStepDb = agcStepDb; self.svMean = svMean
        self.gapFraction = gapFraction; self.agcSeen = agcSeen; self.cn0FloorDb = cn0FloorDb
        self.agcFloorDb = agcFloorDb; self.ignoreStopped = ignoreStopped; self.suppressAlerts = suppressAlerts
    }

    enum CodingKeys: String, CodingKey {
        case at, grade, cn0Mean, cn0WanderDb, agcWanderDb, agcStepDb, svMean, gapFraction, agcSeen
        case cn0FloorDb, agcFloorDb, ignoreStopped, suppressAlerts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decode(Int.self, forKey: .at)
        grade = try c.decode(GnssCalGrade.self, forKey: .grade)
        cn0Mean = try c.decode(Double.self, forKey: .cn0Mean)
        cn0WanderDb = try c.decode(Double.self, forKey: .cn0WanderDb)
        agcWanderDb = try c.decode(Double.self, forKey: .agcWanderDb)
        agcStepDb = try c.decode(Double.self, forKey: .agcStepDb)
        svMean = try c.decode(Double.self, forKey: .svMean)
        gapFraction = try c.decode(Double.self, forKey: .gapFraction)
        agcSeen = try c.decode(Bool.self, forKey: .agcSeen)
        cn0FloorDb = try c.decode(.cn0FloorDb, default: 0.0)
        agcFloorDb = try c.decode(.agcFloorDb, default: 0.0)
        ignoreStopped = try c.decode(.ignoreStopped, default: false)
        suppressAlerts = try c.decode(.suppressAlerts, default: false)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(at, forKey: .at)
        try c.encode(grade, forKey: .grade)
        try c.encode(cn0Mean, forKey: .cn0Mean)
        try c.encode(cn0WanderDb, forKey: .cn0WanderDb)
        try c.encode(agcWanderDb, forKey: .agcWanderDb)
        try c.encode(agcStepDb, forKey: .agcStepDb)
        try c.encode(svMean, forKey: .svMean)
        try c.encode(gapFraction, forKey: .gapFraction)
        try c.encode(agcSeen, forKey: .agcSeen)
        try c.encode(cn0FloorDb, forKey: .cn0FloorDb)
        try c.encode(agcFloorDb, forKey: .agcFloorDb)
        try c.encode(ignoreStopped, forKey: .ignoreStopped)
        try c.encode(suppressAlerts, forKey: .suppressAlerts)
    }

    public func summary() -> String {
        switch grade {
        case .good:
            return "Calibration complete. This Mac is Good. " +
                "It should work with a steady view of the sky, away from other electronics."
        case .fair:
            return "Calibration complete. This Mac is Fair. Usable. " +
                "Small drops will be hard to separate from this Mac's own GPS. " +
                "Medium or Low will be steadier than High."
        case .poor:
            return "Calibration complete. This Mac is Poor. " +
                "This Mac's GPS is too coarse for an interference alert. " +
                "It can still tag a path. The popup stays off."
        }
    }

    public func calibratedLabel() -> String { formatMs(at, "d MMM HH:mm") }
}

/// One GPS fix during a calibration minute. Coordinates stay in this attempt and are not saved.
public struct GnssCalFix: Hashable, Sendable {
    public var elapsedMs: Int
    public var accM: Double
    public var speedMps: Double
    public var lat: Double
    public var lon: Double

    public init(elapsedMs: Int, accM: Double, speedMps: Double, lat: Double, lon: Double) {
        self.elapsedMs = elapsedMs; self.accM = accM; self.speedMps = speedMps; self.lat = lat; self.lon = lon
    }
}

public struct GnssCalAttempt: Hashable, Sendable {
    public var epochs: [GnssEpoch]
    public var fixes: [GnssCalFix]
    public var startedElapsedMs: Int
    public var endedElapsedMs: Int

    public init(epochs: [GnssEpoch], fixes: [GnssCalFix], startedElapsedMs: Int, endedElapsedMs: Int) {
        self.epochs = epochs; self.fixes = fixes; self.startedElapsedMs = startedElapsedMs; self.endedElapsedMs = endedElapsedMs
    }
}

/// Kotlin sealed class GnssCalOutcome { Saved(profile), Rejected(reason) }.
public enum GnssCalOutcome: Hashable, Sendable {
    case saved(profile: GnssPhoneProfile)
    case rejected(reason: String)
}

/// What Settings shows while a calibration minute is running or after it is refused.
public struct GnssCalUi: Hashable, Sendable {
    public var running: Bool
    public var leftSec: Int
    public var rejection: String

    public init(running: Bool = false, leftSec: Int = 0, rejection: String = "") {
        self.running = running; self.leftSec = leftSec; self.rejection = rejection
    }
}

public enum GnssCalibration {
    public static let DURATION_MS = 60_000

    public static func grade(attempt: GnssCalAttempt, nowWall: Int) -> GnssCalOutcome {
        let window = attempt.endedElapsedMs - attempt.startedElapsedMs
        let epochs = attempt.epochs.sortedBy { $0.elapsedMs }
        if window < MIN_WINDOW_MS || epochs.count < MIN_EPOCHS {
            return reject(FEW_READINGS)
        }
        let span = epochs.last!.elapsedMs - epochs.first!.elapsedMs
        if span < MIN_SPAN_MS { return reject(FEW_READINGS) }

        let goodFixes = attempt.fixes.filter { (0.0...MAX_ACC_M).contains($0.accM) && $0.lat.isFinite && $0.lon.isFinite }
        if goodFixes.count < MIN_FIXES { return reject(NO_FIX) }
        let first = goodFixes.first!
        let last = goodFixes.last!
        let moved = Geo.meters(lat1: first.lat, lon1: first.lon, lat2: last.lat, lon2: last.lon)
        let fast = goodFixes.count { $0.speedMps >= WALK_MPS }
        if moved > MAX_MOVE_M || fast >= FAST_FIXES { return reject(MOVING) }

        let cn0 = epochs.compactMap { epochCn0($0) }
        let agc = epochs.compactMap { epochAgc($0) }
        let sv = epochs.map { Double(epochSv($0)) }
        if cn0.count < MIN_EPOCHS / 2 { return reject(WEAK) }
        let cn0Mean = cn0.average()
        let svMean = sv.average()
        if svMean < MIN_SV { return reject(FEW_SV) }
        if cn0Mean < MIN_CN0 { return reject(WEAK) }

        let cn0Wander = stdev(cn0)
        let agcWander = stdev(agc)
        let step = agcStep(agc)
        let gaps = gapFraction(epochs.map { $0.elapsedMs })
        let agcSeen = agc.isNotEmpty
        let weakPhone = cn0Mean < GOOD_CN0 || svMean < GOOD_SV
        let noisy = cn0Wander >= NOISY_DB || agcWander >= NOISY_DB || step >= COARSE_STEP_DB
        let veryNoisy = cn0Wander >= WILD_DB || agcWander >= WILD_DB || step >= WILD_STEP_DB || gaps >= WILD_GAPS
        let gappy = gaps >= FAIR_GAPS
        let grade: GnssCalGrade
        if veryNoisy || (weakPhone && noisy) {
            grade = .poor
        } else if agcSeen && !weakPhone && !gappy &&
            cn0Wander <= QUIET_DB && agcWander <= QUIET_DB && step <= QUIET_STEP_DB &&
            cn0Mean >= GOOD_CN0 && svMean >= GOOD_SV {
            grade = .good
        } else {
            grade = .fair
        }
        let cn0Floor = grade == .good ? 0.0 : (cn0Wander * FLOOR_SCALE).coerceIn(0.0, FLOOR_CAP)
        let agcExtra = Swift.max(agcWander * FLOOR_SCALE, step >= QUIET_STEP_DB ? step + 0.5 : 0.0)
        let agcFloor = grade == .good ? 0.0 : agcExtra.coerceIn(0.0, FLOOR_CAP)
        return .saved(profile: GnssPhoneProfile(
            at: nowWall,
            grade: grade,
            cn0Mean: round1(cn0Mean),
            cn0WanderDb: round1(cn0Wander),
            agcWanderDb: round1(agcWander),
            agcStepDb: round1(step),
            svMean: round1(svMean),
            gapFraction: round1(gaps),
            agcSeen: agcSeen,
            cn0FloorDb: round1(cn0Floor),
            agcFloorDb: round1(agcFloor),
            ignoreStopped: grade != .good,
            suppressAlerts: grade == .poor
        ))
    }

    public static func diagRows(profile: GnssPhoneProfile?) -> [(String, String)] {
        guard let profile else { return [("GNSS calibration", "not run")] }
        let gain = profile.agcSeen ? "\(num(profile.agcWanderDb)) dB" : "not reported"
        return [
            ("GNSS calibration", profile.grade.label()),
            ("Calibrated", profile.calibratedLabel()),
            ("GPS signal at calibration", "\(num(profile.cn0Mean)) dB-Hz, wander \(num(profile.cn0WanderDb)) dB"),
            ("Gain wander", gain),
        ]
    }

    private static func reject(_ reason: String) -> GnssCalOutcome { .rejected(reason: reason) }

    private static func epochCn0(_ epoch: GnssEpoch) -> Double? {
        epoch.bands.values.compactMap { band in
            band.cn0Top3.flatMap { $0.isFinite && $0 > 0.0 ? $0 : nil }
        }.max()
    }

    private static func epochAgc(_ epoch: GnssEpoch) -> Double? {
        let vals = epoch.bands.values.compactMap { band in
            band.agcDb.flatMap { $0.isFinite && $0 >= -80.0 ? $0 : nil }
        }
        if vals.isEmpty { return nil }
        return vals.sorted()[vals.count / 2]
    }

    private static func epochSv(_ epoch: GnssEpoch) -> Int {
        epoch.bands.values.sumOf { $0.svTracked.coerceAtLeast(0) }
    }

    private static func stdev(_ values: [Double]) -> Double {
        if values.count < 2 { return 0.0 }
        let mean = values.average()
        var acc = 0.0
        for v in values {
            let d = v - mean
            acc += d * d
        }
        return (acc / Double(values.count - 1)).squareRoot()
    }

    /// Typical jump between distinct gain readings. 0 when gain sits on one value.
    private static func agcStep(_ values: [Double]) -> Double {
        let uniq = values.map { Double(($0 * 2.0).roundToInt()) / 2.0 }.distinct().sorted()
        if uniq.count < 2 { return 0.0 }
        let diffs = uniq.zipWithNext().map { $0.1 - $0.0 }.filter { $0 > 0.05 }.sorted()
        if diffs.isEmpty { return 0.0 }
        return diffs[diffs.count / 2]
    }

    private static func gapFraction(_ times: [Int]) -> Double {
        if times.count < 3 { return 1.0 }
        let dts = times.zipWithNext().map { $0.1 - $0.0 }.filter { $0 > 0 }
        if dts.isEmpty { return 1.0 }
        let med = dts.sorted()[dts.count / 2].coerceAtLeast(1)
        let limit = Swift.max(med * 5 / 2, 2_500)
        return Double(dts.count { $0 > limit }) / Double(dts.count)
    }

    private static func round1(_ v: Double) -> Double { Double((v * 10.0).roundToInt()) / 10.0 }

    private static func num(_ v: Double) -> String { fmt(v, 1) }

    private static let MIN_WINDOW_MS = 50_000
    private static let MIN_SPAN_MS = 45_000
    private static let MIN_EPOCHS = 20
    private static let MIN_FIXES = 8
    private static let MAX_ACC_M = 25.0
    private static let MAX_MOVE_M = 40.0
    private static let WALK_MPS = 2.5
    private static let FAST_FIXES = 4
    private static let MIN_SV = 8.0
    private static let MIN_CN0 = 18.0
    private static let GOOD_CN0 = 32.0
    private static let GOOD_SV = 18.0
    private static let QUIET_DB = 1.2
    private static let QUIET_STEP_DB = 1.5
    private static let NOISY_DB = 2.0
    private static let COARSE_STEP_DB = 3.0
    private static let WILD_DB = 3.5
    private static let WILD_STEP_DB = 6.0
    private static let FAIR_GAPS = 0.08
    private static let WILD_GAPS = 0.20
    private static let FLOOR_SCALE = 2.5
    private static let FLOOR_CAP = 8.0

    public static let FEW_READINGS = "Not enough GPS readings. Stay outside, hold still, and try again."
    public static let NO_FIX = "No GPS fix. Stand outside, hold still, and try again."
    public static let MOVING = "The Mac was moving. Stand still and try again."
    public static let FEW_SV = "Too few satellites. Stand in the open, away from a roof and a router, and try again."
    public static let WEAK = "The GPS signal was too weak for a calibration. Stand in the open and try again."
}
