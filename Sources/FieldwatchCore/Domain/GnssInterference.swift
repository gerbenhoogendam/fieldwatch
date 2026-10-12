import Foundation

// Port of domain/GnssInterference.kt.
// Phone GNSS interference and spoofing hints. Pure logic, one epoch at a time.
// macOS has no GNSS receiver, so the monitor does not run on a Mac. The types and the
// detector are kept so sits, reports and TAK compile and the check can light up later.
//
// GnssSensitivity and GnssAlertFloor live in Models.swift (AppSettings needs them).
//
// This notices a change. A hit already present at the start does not fire.
// A Wi-Fi router can look like interference. Nothing here names a source,
// a distance, or a direction.

public enum GnssConfidence: String, CaseIterable, Comparable, Sendable {
    case low = "LOW", medium = "MEDIUM", high = "HIGH"

    public var ordinal: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    public static func < (a: GnssConfidence, b: GnssConfidence) -> Bool { a.ordinal < b.ordinal }

    public func label() -> String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    public func meets(floor: GnssConfidence) -> Bool { ordinal >= floor.ordinal }

    public func lower() -> GnssConfidence? {
        switch self {
        case .high: return .medium
        case .medium: return .low
        case .low: return nil
        }
    }
}

public enum GnssKind: String, CaseIterable, Sendable {
    case interference = "INTERFERENCE", spoofing = "SPOOFING", mock = "MOCK"
}

public extension GnssAlertFloor {
    func toConfidence() -> GnssConfidence {
        switch self {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }
}

public enum GnssBand: String, CaseIterable, Sendable {
    case l1 = "L1", b1i = "B1I", g1 = "G1", l2 = "L2", l5 = "L5", e5b = "E5B", e6 = "E6", unknown = "UNKNOWN"

    public var ordinal: Int { GnssBand.allCases.firstIndex(of: self)! }
}

/// Android GnssStatus constellation ints. Kept as ints so this file stays platform-free.
public enum GnssConstellation {
    public static let UNKNOWN = 0
    public static let GPS = 1
    public static let SBAS = 2
    public static let GLONASS = 3
    public static let QZSS = 4
    public static let BEIDOU = 5
    public static let GALILEO = 6
    public static let IRNSS = 7
}

public struct BandKey: Hashable, Sendable {
    public var constellation: Int
    public var band: GnssBand
    public init(constellation: Int, band: GnssBand) { self.constellation = constellation; self.band = band }
}

/// Stable order for iterating an epoch's band map (Kotlin used a LinkedHashMap).
private func bandKeyLess(_ a: BandKey, _ b: BandKey) -> Bool {
    a.constellation != b.constellation ? a.constellation < b.constellation : a.band.ordinal < b.band.ordinal
}

public struct BandEpoch: Hashable, Sendable {
    public var agcDb: Double?
    public var agcFromEventLevel: Bool
    public var cn0Top3: Double?
    public var svTracked: Int
    public var cn0BySv: [Int: Double]

    public init(agcDb: Double?, agcFromEventLevel: Bool, cn0Top3: Double?, svTracked: Int, cn0BySv: [Int: Double] = [:]) {
        self.agcDb = agcDb; self.agcFromEventLevel = agcFromEventLevel; self.cn0Top3 = cn0Top3
        self.svTracked = svTracked; self.cn0BySv = cn0BySv
    }
}

public struct GnssEpoch: Hashable, Sendable {
    public var elapsedMs: Int
    public var wallMs: Int
    public var clockDiscontinuity: Int
    /// Iterated in (constellation, band) order by the detector.
    public var bands: [BandKey: BandEpoch]

    public init(elapsedMs: Int, wallMs: Int, clockDiscontinuity: Int, bands: [BandKey: BandEpoch]) {
        self.elapsedMs = elapsedMs; self.wallMs = wallMs; self.clockDiscontinuity = clockDiscontinuity; self.bands = bands
    }
}

/// Side checks the monitor already decided. No coordinates.
public struct GnssSide: Hashable, Sendable {
    public var timeDisagree: Bool
    public var positionDisagree: Bool
    public var impossibleHop: Bool
    public var mock: Bool
    public var fixLost: Bool
    /// GnssStatus reported the receiver stopped. Not a drop in the signals.
    public var engineStopped: Bool

    public init(timeDisagree: Bool = false, positionDisagree: Bool = false, impossibleHop: Bool = false,
                mock: Bool = false, fixLost: Bool = false, engineStopped: Bool = false) {
        self.timeDisagree = timeDisagree; self.positionDisagree = positionDisagree; self.impossibleHop = impossibleHop
        self.mock = mock; self.fixLost = fixLost; self.engineStopped = engineStopped
    }
}

/// GPS fix against the network fix.
/// A network accuracy of 100 m or worse cannot vote. The centers have to sit
/// clearly past both accuracy circles, and the mismatch has to hold.
public enum GnssPositionWitness {
    public static let MAX_AGE_MS = 10_000
    public static let COARSE_ACC_M = 100.0
    public static let CLEAR_M = 100.0
    public static let HOLD_MS = 15_000

    public struct Hold: Hashable, Sendable {
        public var sinceMs: Int
        public var on: Bool
        public init(sinceMs: Int, on: Bool) { self.sinceMs = sinceMs; self.on = on }
    }

    public static func rawDisagree(gpsAccM: Double, netAccM: Double, apartM: Double, gpsAgeMs: Int, netAgeMs: Int) -> Bool {
        if gpsAgeMs < 0 || netAgeMs < 0 { return false }
        if gpsAgeMs > MAX_AGE_MS || netAgeMs > MAX_AGE_MS { return false }
        if !(gpsAccM > 0.0) || !(netAccM > 0.0) || netAccM >= COARSE_ACC_M { return false }
        if !apartM.isFinite { return false }
        return apartM > gpsAccM + netAccM + CLEAR_M
    }

    /// sinceMs is 0 while the raw check is clear.
    public static func hold(raw: Bool, sinceMs: Int, nowMs: Int) -> Hold {
        if !raw || nowMs < sinceMs { return Hold(sinceMs: 0, on: false) }
        let since = sinceMs == 0 ? nowMs : sinceMs
        return Hold(sinceMs: since, on: nowMs - since >= HOLD_MS)
    }
}

public struct GnssConfig: Hashable, Sendable {
    public var sensitivity: GnssSensitivity
    public var spoofChecks: Bool
    public var correlation: Bool
    public var invertAgc: Bool
    /// From this Mac's calibration. 0 keeps the sensitivity bars.
    public var agcFloorDb: Double
    public var cn0FloorDb: Double
    /// Kept so an older profile still loads. A hard gap is a pause on every receiver,
    /// including one graded Good, so this no longer changes the check.
    public var ignoreStopped: Bool
    /// Readings in this span after the check starts are not stored as the baseline.
    public var settleMs: Int

    public init(sensitivity: GnssSensitivity = .medium, spoofChecks: Bool = false, correlation: Bool = false,
                invertAgc: Bool = false, agcFloorDb: Double = 0.0, cn0FloorDb: Double = 0.0,
                ignoreStopped: Bool = false, settleMs: Int = 60_000) {
        self.sensitivity = sensitivity; self.spoofChecks = spoofChecks; self.correlation = correlation
        self.invertAgc = invertAgc; self.agcFloorDb = agcFloorDb; self.cn0FloorDb = cn0FloorDb
        self.ignoreStopped = ignoreStopped; self.settleMs = settleMs
    }
}

public struct GnssThresholds: Hashable, Sendable {
    public var agcDropDb: Double
    public var cn0DropDb: Double
    public var cn0OnlyDropDb: Double
    public init(agcDropDb: Double, cn0DropDb: Double, cn0OnlyDropDb: Double) {
        self.agcDropDb = agcDropDb; self.cn0DropDb = cn0DropDb; self.cn0OnlyDropDb = cn0OnlyDropDb
    }
}

public extension GnssSensitivity {
    func thresholds() -> GnssThresholds {
        switch self {
        case .low: return GnssThresholds(agcDropDb: 8.0, cn0DropDb: 5.0, cn0OnlyDropDb: 8.0)
        case .medium: return GnssThresholds(agcDropDb: 5.0, cn0DropDb: 3.0, cn0OnlyDropDb: 6.0)
        case .high: return GnssThresholds(agcDropDb: 3.0, cn0DropDb: 2.0, cn0OnlyDropDb: 4.0)
        }
    }
}

public extension GnssThresholds {
    /// A calibrated receiver raises a bar that sits inside its own quiet wander. It never lowers one.
    func floored(agcFloorDb: Double, cn0FloorDb: Double) -> GnssThresholds {
        let agc = agcFloorDb.coerceAtLeast(0.0)
        let cn = cn0FloorDb.coerceAtLeast(0.0)
        var c = self
        c.agcDropDb = Swift.max(agcDropDb, agc)
        c.cn0DropDb = Swift.max(cn0DropDb, cn)
        c.cn0OnlyDropDb = Swift.max(cn0OnlyDropDb, cn)
        return c
    }
}

public struct GnssLive: Hashable, Sendable {
    public var kind: GnssKind
    public var confidence: GnssConfidence
    public var startedWall: Int
    public var detail: String
    public var adapted: Bool
    public var rose: Bool
    /// Plain reason for the popup. Empty on older callers.
    public var why: String
    /// Band numbers for the popup, after the reason.
    public var numbers: String

    public init(kind: GnssKind, confidence: GnssConfidence, startedWall: Int, detail: String, adapted: Bool,
                rose: Bool, why: String = "", numbers: String = "") {
        self.kind = kind; self.confidence = confidence; self.startedWall = startedWall; self.detail = detail
        self.adapted = adapted; self.rose = rose; self.why = why; self.numbers = numbers
    }
}

public struct GnssSnapshot: Hashable, Sendable {
    public var statusLine: String
    public var bandLines: [String]
    public var lives: [GnssLive]
    public var marks: [GnssMark]
    public var agcSeen: Bool
    public var armed: Bool
    public var learned: Int

    public init(statusLine: String, bandLines: [String], lives: [GnssLive], marks: [GnssMark], agcSeen: Bool, armed: Bool, learned: Int) {
        self.statusLine = statusLine; self.bandLines = bandLines; self.lives = lives; self.marks = marks
        self.agcSeen = agcSeen; self.armed = armed; self.learned = learned
    }
}

public struct GnssMark: Codable, Hashable, Sendable {
    public var at: Int
    public var endedAt: Int
    public var kind: String
    public var confidence: String
    public var detail: String

    public init(at: Int, endedAt: Int = 0, kind: String, confidence: String, detail: String) {
        self.at = at; self.endedAt = endedAt; self.kind = kind; self.confidence = confidence; self.detail = detail
    }

    enum CodingKeys: String, CodingKey { case at, endedAt, kind, confidence, detail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decode(Int.self, forKey: .at)
        endedAt = try c.decode(.endedAt, default: 0)
        kind = try c.decode(String.self, forKey: .kind)
        confidence = try c.decode(String.self, forKey: .confidence)
        detail = try c.decode(String.self, forKey: .detail)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(at, forKey: .at)
        try c.encode(endedAt, forKey: .endedAt)
        try c.encode(kind, forKey: .kind)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(detail, forKey: .detail)
    }

    public func reportLine() -> String {
        let head: String
        switch kind {
        case "spoofing": head = "Possible GNSS spoofing"
        case "mock": head = "Mock location app"
        default: head = "Possible GNSS interference"
        }
        let end = endedAt > 0 ? " Ended \(GnssCopy.utcHm(ms: endedAt)) UTC." : ""
        return "\(GnssCopy.utcHm(ms: at)) UTC. \(head). \(confidence). \(detail).\(end)"
    }
}

public struct GnssNotice: Hashable, Sendable {
    public var showDialog: Bool
    public var title: String
    public var body: String
    public var line: String
    /// True for the red line after the hit has cleared.
    public var ended: Bool
    /// Receiver numbers. The popup shows these after the plain reason.
    public var details: String

    public init(showDialog: Bool, title: String, body: String, line: String, ended: Bool = false, details: String = "") {
        self.showDialog = showDialog; self.title = title; self.body = body; self.line = line
        self.ended = ended; self.details = details
    }
}

public struct GnssCue: Hashable, Sendable {
    public var title: String
    public var text: String
    public var phrase: String
    public init(title: String, text: String, phrase: String) { self.title = title; self.text = text; self.phrase = phrase }
}

public struct GnssPresentation: Hashable, Sendable {
    public var notice: GnssNotice?
    public var cue: GnssCue?
    public init(notice: GnssNotice?, cue: GnssCue?) { self.notice = notice; self.cue = cue }
}

public enum GnssBands {
    public static func ofHz(hz: Double?) -> GnssBand {
        guard let hz, hz > 0.0 else { return .l1 }
        let mhz = hz / 1_000_000.0
        let centers: [(Double, GnssBand)] = [
            (1575.42, .l1),
            (1561.098, .b1i),
            (1227.60, .l2),
            (1176.45, .l5),
            (1207.14, .e5b),
            (1268.52, .e6),
            (1278.75, .e6),
        ]
        if let nearest = centers.minByOrNull({ abs($0.0 - mhz) }), abs(nearest.0 - mhz) <= 10.0 { return nearest.1 }
        if (1588.0...1616.0).contains(mhz) { return .g1 }
        return .unknown
    }

    public static func label(key: BandKey) -> String {
        let constellation: String
        switch key.constellation {
        case GnssConstellation.GPS: constellation = "GPS"
        case GnssConstellation.SBAS: constellation = "SBAS"
        case GnssConstellation.GLONASS: constellation = "GLONASS"
        case GnssConstellation.QZSS: constellation = "QZSS"
        case GnssConstellation.BEIDOU: constellation = "BeiDou"
        case GnssConstellation.GALILEO: constellation = "Galileo"
        case GnssConstellation.IRNSS: constellation = "IRNSS"
        default: constellation = "GNSS"
        }
        let band: String
        switch key.band {
        case .l1: band = key.constellation == GnssConstellation.GALILEO ? "E1" : "L1"
        case .b1i: band = "B1I"
        case .g1: band = "G1"
        case .l2: band = "L2"
        case .l5: band = "L5"
        case .e5b: band = "E5b"
        case .e6: band = "E6"
        case .unknown: band = "band"
        }
        return "\(constellation) \(band)"
    }
}

public enum GnssCopy {
    public static let INTRO =
        "Fieldwatch watches this Mac's GPS receiver and notices a change. If this was already happening when the check started, it can be missed."
    public static let ROUTER =
        "A Wi-Fi router or other electronics next to the Mac can cause this. Fieldwatch cannot tell where it comes from or how far away it is."
    public static let SPOOF_LIMIT =
        "Spoofing checks are partial. A careful spoofer can avoid them. A wrong position can also be a side effect of interference."
    public static let MOCK =
        "A mock location app is on. That is software reporting a made-up location, not a radio spoofer."
    public static let PAUSED = "GNSS paused by the Mac"

    public static func utcHm(ms: Int) -> String { stamp(ms, utc: true) }

    public static func localHm(ms: Int) -> String { stamp(ms, utc: false) }

    public static func title(kinds: Set<GnssKind>, confidence: GnssConfidence) -> String {
        "\(head(kinds)) (\(confidence.label()))"
    }

    public static func banner(kinds: Set<GnssKind>, confidence: GnssConfidence) -> String {
        "\(head(kinds)) · \(confidence.label())"
    }

    public static func ended(kinds: Set<GnssKind>, wall: Int) -> String {
        "\(head(kinds)) ended \(localHm(ms: wall))"
    }

    public static func body(detail: String, kinds: Set<GnssKind>, adapted: Bool) -> String {
        var s = detail.trim()
        if adapted {
            s += "\n\nThe receiver may have adapted. The condition may still be present."
        }
        s += "\n\n"
        s += INTRO
        s += "\n\n"
        s += ROUTER
        if kinds.contains(.spoofing) {
            s += "\n\n"
            s += SPOOF_LIMIT
        }
        if kinds.contains(.mock) {
            s += "\n\n"
            s += MOCK
        }
        return s.trim()
    }

    /// Dialog title. GPS, not GNSS, so the popup does not open on a jargon word.
    public static func popupTitle(kinds: Set<GnssKind>, confidence: GnssConfidence) -> String {
        if kinds.contains(.mock) && kinds.count == 1 { return "Mock location app" }
        return "\(head(kinds).replace("GNSS", "GPS")) (\(confidence.label()))"
    }

    /// Plain popup. The reason comes first. Numbers stay in `details` on the notice.
    /// A hand-built live with no reason keeps `body`.
    public static func popup(lives: [GnssLive], kinds: Set<GnssKind>, adapted: Bool) -> (String, String)? {
        let reasons = lives.map { $0.why.trim() }.filter { $0.isNotEmpty }
        if reasons.isEmpty { return nil }
        var s = ""
        if lives.count == 1 {
            s += reasons.single { _ in true }
        } else {
            for live in lives {
                if live.why.isBlank { continue }
                if s.isNotEmpty { s += "\n\n" }
                s += head([live.kind]).replace("GNSS", "GPS")
                s += ". "
                s += live.why.trim()
            }
        }
        if adapted {
            s += "\n\nThe receiver may have adjusted. The condition may still be there."
        }
        let note = popupNote(kinds)
        if note.isNotEmpty {
            s += "\n\n"
            s += note
        }
        let text = s.trim()
        let numbers = lives.map { $0.numbers.trim() }.firstOrNull { $0.isNotEmpty } ?? ""
        return (text, numbers)
    }

    public static func interferenceWhy(bothDropped: Bool, twoSystems: Bool, lostSatellites: Bool, signalOnly: Bool) -> String {
        if lostSatellites {
            return "The receiver turned its gain down and lost satellites."
        }
        if twoSystems && bothDropped {
            return "This Mac's GPS got weaker on more than one satellite system. The receiver turned its gain down and the signals dropped."
        }
        if bothDropped {
            return "This Mac's GPS got weaker. The receiver turned its gain down and the satellite signals dropped."
        }
        if signalOnly {
            return "The satellite signals got weaker. This Mac is not reporting receiver gain, so this hint is lighter."
        }
        return "The receiver turned its gain down more than usual. The satellite signals did not drop as much."
    }

    public static func spoofWhy(gain: Bool, clock: Bool, position: Bool, jumped: Bool, faded: Bool, fromInterference: Bool) -> String {
        var parts: [String] = []
        if gain { parts.append("The receiver turned its gain down, and the satellite signals stayed up.") }
        if clock { parts.append("The GPS clock does not match network time.") }
        if position { parts.append("The GPS position does not match the network position.") }
        if jumped { parts.append("The GPS position jumped faster than this Mac could have moved.") }
        if faded && !gain {
            parts.append("Several satellite signals faded at the same time. A hand, a roof, or a pocket can do that too.")
        }
        if faded && gain { parts.append("Several satellite signals also faded together.") }
        if fromInterference { parts.append("The interference on this Mac can cause that too.") }
        return parts.joined(separator: " ")
    }

    private static func popupNote(_ kinds: Set<GnssKind>) -> String {
        if kinds.contains(.mock) && kinds.count == 1 { return "" }
        if kinds.contains(.spoofing) && kinds.contains(.interference) {
            return "A router, a charger, or a phone against this Mac can do the same thing. A wrong position can come from that too. Fieldwatch cannot tell the source or how far away it is."
        }
        if kinds.contains(.spoofing) {
            return "This is a hint. A careful fake GPS signal can get past these checks. Fieldwatch cannot tell the source or how far away it is."
        }
        return "A router, a charger, or a phone against this Mac can do the same thing. Fieldwatch cannot tell the source or how far away it is."
    }

    public static func phrase(kinds: Set<GnssKind>) -> String {
        if kinds.contains(.mock) && kinds.count == 1 { return "Mock location app is on" }
        if kinds.contains(.spoofing) && !kinds.contains(.interference) {
            return "Possible G P S spoofing. Position may be wrong."
        }
        return "Possible G P S interference"
    }

    private static func head(_ kinds: Set<GnssKind>) -> String {
        if kinds.contains(.mock) && !kinds.contains(.interference) && !kinds.contains(.spoofing) {
            return "Mock location app"
        }
        if kinds.contains(.interference) && kinds.contains(.spoofing) {
            return "Possible GNSS interference and spoofing"
        }
        if kinds.contains(.spoofing) { return "Possible GNSS spoofing" }
        return "Possible GNSS interference"
    }

    private static func stamp(_ ms: Int, utc: Bool) -> String { formatMs(ms, "HH:mm", utc: utc) }
}

/// Popup and red line. The alert floor gates the popup, the line, the beep, and voice.
/// A weaker hit still stays on the sit. Mock location always alerts.
public final class GnssAlerts {
    private var showDialog = false
    private var popped: [String: GnssConfidence] = [:]
    private var lastTitle = ""
    private var lastLine = ""
    private var lastKinds: Set<GnssKind> = [.interference]
    private var endedLine: String?
    private var endedUntil = 0

    private static let ENDED_MS = 10 * 60_000

    public init() {}

    public func dismiss() {
        showDialog = false
    }

    public func reset() {
        showDialog = false
        popped.removeAll()
        endedLine = nil
        endedUntil = 0
    }

    public func onLives(lives: [GnssLive], floor: GnssConfidence, nowWall: Int) -> GnssPresentation {
        let hot = lives.filter { $0.kind == .mock || $0.confidence.meets(floor: floor) }
        if hot.isEmpty {
            let had = popped.isNotEmpty
            popped.removeAll()
            showDialog = false
            if had && endedLine == nil {
                endedLine = GnssCopy.ended(kinds: lastKinds, wall: nowWall)
                endedUntil = nowWall + GnssAlerts.ENDED_MS
            }
            let line = nowWall <= endedUntil ? endedLine : nil
            if line == nil { endedLine = nil }
            let notice = line.map {
                GnssNotice(showDialog: false, title: lastTitle, body: "", line: $0, ended: true)
            }
            return GnssPresentation(notice: notice, cue: nil)
        }
        endedLine = nil
        let kinds = Set(hot.map { $0.kind })
        let confidence = hot.map { $0.confidence }.max()!
        let detail = hot.map { $0.detail }.joined(separator: "\n\n")
        let adapted = hot.any { $0.adapted }
        let line = GnssCopy.banner(kinds: kinds, confidence: confidence)
        let plain = GnssCopy.popup(lives: hot, kinds: kinds, adapted: adapted)
        let title = plain != nil ? GnssCopy.popupTitle(kinds: kinds, confidence: confidence) : GnssCopy.title(kinds: kinds, confidence: confidence)
        let body = plain?.0 ?? GnssCopy.body(detail: detail, kinds: kinds, adapted: adapted)
        let details = plain?.1 ?? ""
        lastTitle = title
        lastLine = line
        lastKinds = kinds
        var cue: GnssCue?
        var open = false
        for live in hot {
            let key = "\(live.kind.rawValue):\(live.startedWall)"
            let prev = popped[key]
            if prev == nil || live.confidence > prev! || live.rose {
                popped[key] = Swift.max(live.confidence, prev ?? live.confidence)
                open = true
            }
        }
        let keep = Set(hot.map { "\($0.kind.rawValue):\($0.startedWall)" })
        popped = popped.filter { keep.contains($0.key) }
        if open {
            showDialog = true
            let shade = details.isBlank ? body : body + "\n\n" + details
            cue = GnssCue(title: title, text: shade.take(700), phrase: GnssCopy.phrase(kinds: kinds))
        }
        return GnssPresentation(
            notice: GnssNotice(showDialog: showDialog, title: title, body: body, line: line, details: details),
            cue: cue
        )
    }
}

public final class GnssDetector {
    public var config: GnssConfig

    public init(config: GnssConfig = GnssConfig()) { self.config = config }

    // Kotlin LinkedHashMap: bandOrder keeps first-seen order.
    private var bandOrder: [BandKey] = []
    private var bands: [BandKey: Track] = [:]
    private var marks: [GnssMark] = []
    private var svHist: [Int: [Double]] = [:]
    private var lastClock = Int.min
    private var agcSeen = false
    private var interference: Episode?
    private var spoofing: Episode?
    private var mockEp: Episode?
    private var interferenceEndedElapsed = 0
    private var s1Since = 0
    private var corrStreak = 0
    private var recover = 0
    private var settleStart = Int.min
    /// True after a locked satellite or a usable signal has been seen.
    private var sawLock = false
    /// Receiver stopped, or every measurement disappeared. The baseline stays put.
    private var inGap = false
    private var resumeLeft = 0

    private static let ARM = 60
    private static let RECENT = 10
    private static let HOLD_MS = 60_000
    private static let RECOVER = 20
    private static let ADAPT_MS = 15 * 60_000
    private static let DEMOTE_MS = 120_000
    private static let S1_HIGH_MS = 10_000
    private static let S1_MED_MS = 30_000
    private static let CORR_WIN = 20
    /// Clean epochs kept out of the baseline after the receiver comes back.
    private static let RESUME_EPOCHS = 5

    public func reset() {
        bands.removeAll()
        bandOrder.removeAll()
        marks.removeAll()
        svHist.removeAll()
        lastClock = Int.min
        agcSeen = false
        interference = nil
        spoofing = nil
        mockEp = nil
        interferenceEndedElapsed = 0
        s1Since = 0
        corrStreak = 0
        recover = 0
        settleStart = Int.min
        sawLock = false
        inGap = false
        resumeLeft = 0
    }

    public func onEpoch(epoch: GnssEpoch, side: GnssSide = GnssSide()) -> GnssSnapshot {
        let ARM = GnssDetector.ARM
        let present = hasMeasurements(epoch)
        if side.engineStopped || (!present && (sawLock || inGap)) {
            inGap = true
            resumeLeft = GnssDetector.RESUME_EPOCHS
            return pauseSnapshot()
        }
        if inGap && present {
            if resumeLeft > 0 {
                resumeLeft -= 1
                return pauseSnapshot()
            }
            inGap = false
        }
        if present { sawLock = true }
        if config.settleMs > 0 {
            if settleStart == Int.min || epoch.elapsedMs < settleStart {
                settleStart = epoch.elapsedMs
            }
            let waited = epoch.elapsedMs - settleStart
            if waited < config.settleMs {
                let left = ((config.settleMs - waited + 999) / 1000).coerceAtLeast(1)
                return GnssSnapshot(
                    statusLine: "settling \(left)s",
                    bandLines: [],
                    lives: [],
                    marks: marks,
                    agcSeen: agcSeen,
                    armed: false,
                    learned: 0
                )
            }
        }
        if epoch.clockDiscontinuity != lastClock {
            if lastClock != Int.min {
                svHist.removeAll()
                corrStreak = 0
            }
            lastClock = epoch.clockDiscontinuity
        }
        var seen = Set<BandKey>()
        for key in epoch.bands.keys.sorted(by: bandKeyLess) {
            let raw = epoch.bands[key]!
            let agc = cleanAgc(raw.agcDb)
            if agc != nil { agcSeen = true }
            let cn0: Double? = raw.cn0Top3.flatMap { $0.isFinite && $0 > 0.0 ? $0 : nil }
            let track: Track
            if let t = bands[key] {
                track = t
            } else {
                track = Track()
                bands[key] = track
                bandOrder.append(key)
            }
            track.push(Sample(agc: agc, cn0: cn0, sv: raw.svTracked.coerceAtLeast(0), eventAgc: raw.agcFromEventLevel && agc != nil))
            track.missing = 0
            seen.insert(key)
        }
        for key in bandOrder where !seen.contains(key) {
            bands[key]!.missing += 1
        }
        pushSv(epoch)
        var metrics: [BandKey: Metrics] = [:]
        for key in bandOrder { metrics[key] = bands[key]!.metrics(invert: config.invertAgc) }
        let learned = bandOrder.map { bands[$0]!.samples.count }.max() ?? 0
        let armed = learned >= ARM
        let groups = self.groups()
        let limits = config.sensitivity.thresholds().floored(agcFloorDb: config.agcFloorDb, cn0FloorDb: config.cn0FloorDb)
        var anyJ1 = false
        var anyJ1J2 = false
        var j3 = false
        var j12Groups = Set<BandKey>()
        for key in bandOrder {
            let track = bands[key]!
            guard let m = metrics[key] else { continue }
            let measured = m.sv > 0 || m.cn0 != nil
            let j1Now = measured && m.dAgc != nil && m.dAgc! <= -limits.agcDropDb
            let j2Now = measured && m.dCn0 != nil && m.dCn0! <= -limits.cn0DropDb
            let j1 = Track.flag(&track.j1, j1Now)
            let j2 = Track.flag(&track.j2, j2Now)
            if j1 { anyJ1 = true }
            if j1 && j2 {
                anyJ1J2 = true
                j12Groups.insert(groups[key] ?? key)
            }
            let baseSv = m.baseSv
            let lostSv = m.sv == 0 || (baseSv != nil && baseSv! > 0.0 && Double(m.sv) <= baseSv! * 0.25)
            if j1 && m.eventAgc && (lostSv || side.fixLost) { j3 = true }
        }
        let j4Groups = j12Groups.count
        let cn0Only = self.cn0Only(metrics, limits, armed)
        let eventLevel = bandOrder.any { bands[$0]!.samples.last?.eventAgc == true }
        let interferenceLevel: GnssConfidence?
        if !agcSeen && cn0Only {
            interferenceLevel = .low
        } else if agcSeen && ((anyJ1J2 && j4Groups >= 2) || (eventLevel && anyJ1J2 && j3)) {
            interferenceLevel = .high
        } else if agcSeen && anyJ1J2 {
            interferenceLevel = .medium
        } else if agcSeen && (anyJ1 || cn0Only) {
            interferenceLevel = .low
        } else {
            interferenceLevel = nil
        }
        let bandBits = self.bandBits(metrics)
        let bandDetail = bandBits.joined(separator: " ")
        let bandNumbers = bandBits.joined(separator: "\n")
        let holding = interference != nil
        if interferenceLevel != nil { recover = 0 } else if holding { recover += 1 }
        let interferenceWhy = interferenceLevel == nil ? "" : GnssCopy.interferenceWhy(
            bothDropped: anyJ1J2,
            twoSystems: j4Groups >= 2,
            lostSatellites: j3 && anyJ1J2,
            signalOnly: cn0Only && !anyJ1
        )
        interference = updateEpisode(
            interference,
            interferenceLevel,
            bandDetail.ifBlank("Signal changed."),
            epoch,
            adapted: false,
            why: interferenceWhy,
            numbers: bandNumbers
        ).map { ep in
            if interferenceLevel == nil { var e = ep; e.rose = false; return e }
            return ep
        }
        if var cur = interference, epoch.elapsedMs - cur.startedElapsed > GnssDetector.ADAPT_MS, interferenceLevel != nil {
            cur.endedWall = epoch.wallMs
            cur.adapted = true
            interferenceEndedElapsed = epoch.elapsedMs
            upsert(cur, "interference")
            interference = nil
            recover = 0
            clearFreeze()
        } else if let cur = interference, interferenceLevel == nil {
            let age = epoch.elapsedMs - cur.startedElapsed
            let canClear = age >= GnssDetector.HOLD_MS && recover >= GnssDetector.RECOVER
            let adapted = age >= GnssDetector.ADAPT_MS
            if canClear || adapted {
                var ep = cur
                ep.endedWall = epoch.wallMs
                ep.adapted = adapted
                interferenceEndedElapsed = epoch.elapsedMs
                upsert(ep, "interference")
                interference = nil
                recover = 0
                clearFreeze()
            }
        }
        if let cur = interference {
            freeze(metrics)
            var shown = cur
            shown.detail = bandDetail.isNotBlank ? bandDetail : cur.detail
            shown.numbers = bandNumbers.isNotBlank ? bandNumbers : cur.numbers
            upsert(shown, "interference")
            if bandDetail.isNotBlank {
                var next = cur
                next.detail = bandDetail
                next.numbers = bandNumbers
                interference = next
            }
        }
        spoofing = spoofEpisode(epoch, side, metrics, limits, bandDetail, bandNumbers)
        if let s = spoofing { upsert(s, "spoofing") }
        mockEp = mockEpisode(epoch, side)
        if let m = mockEp { upsert(m, "mock") }
        let lives = openLives()
        let status: String
        if !armed {
            status = "learning \(learned)/\(ARM) s"
        } else if lives.isNotEmpty {
            let top = lives.maxByOrNull { $0.confidence }!
            let name: String
            switch top.kind {
            case .spoofing: name = "spoofing"
            case .mock: name = "mock location"
            case .interference: name = "interference"
            }
            status = "ALERT: \(name) (\(top.confidence.label()))"
        } else if !agcSeen {
            status = "AGC not available on this Mac. Signal-strength only, low confidence."
        } else {
            status = "armed"
        }
        return GnssSnapshot(
            statusLine: status,
            bandLines: bandLines(metrics),
            lives: lives,
            marks: marks,
            agcSeen: agcSeen,
            armed: armed,
            learned: learned
        )
    }

    private func spoofEpisode(
        _ epoch: GnssEpoch,
        _ side: GnssSide,
        _ metrics: [BandKey: Metrics],
        _ limits: GnssThresholds,
        _ bandDetail: String,
        _ bandNumbers: String
    ) -> Episode? {
        if !config.spoofChecks {
            s1Since = 0
            return endSpoof(epoch, spoofing)
        }
        let s1 = metrics.values.any { m in
            m.dAgc != nil && m.dAgc! <= -limits.agcDropDb && m.dCn0 != nil && m.dCn0! >= -1.0
        }
        if s1 {
            if s1Since == 0 { s1Since = epoch.elapsedMs }
        } else {
            s1Since = 0
        }
        let s1Hold = s1Since > 0 ? epoch.elapsedMs - s1Since : 0
        let s6 = config.correlation && correlated()
        let demote = interference != nil ||
            (interferenceEndedElapsed > 0 && epoch.elapsedMs - interferenceEndedElapsed < GnssDetector.DEMOTE_MS)
        let s2 = side.timeDisagree
        let s3 = side.positionDisagree
        let s4 = side.impossibleHop
        let sideCount = [s2, s3, s4].count { $0 }
        // A clock, a position, or a hop is a witness. It does not open an episode alone.
        var level: GnssConfidence?
        if s1 && s1Hold >= GnssDetector.S1_HIGH_MS && (s2 || s3) {
            level = .high
        } else if (s1 && s6) || sideCount >= 2 || (s1 && s1Hold >= GnssDetector.S1_MED_MS) {
            level = .medium
        } else if s1 || s6 {
            level = .low
        } else {
            level = nil
        }
        let sideNote = demote && (s2 || s3 || s4)
        if sideNote, let l = level { level = l.lower() }
        guard let finalLevel = level else { return endSpoof(epoch, spoofing) }
        var notes: [String] = []
        if bandDetail.isNotBlank { notes.append(bandDetail) }
        if s1 { notes.append("Gain is down and the signal is not.") }
        if s2 { notes.append("GPS time and network time disagree.") }
        if s3 { notes.append("GPS position and network position disagree.") }
        if s4 { notes.append("The GPS position jumped faster than travel.") }
        if s6 { notes.append("Satellite signals are fading together.") }
        if sideNote { notes.append("This may be a side effect of interference.") }
        let detail = notes.joined(separator: " ")
        let why = GnssCopy.spoofWhy(gain: s1, clock: s2, position: s3, jumped: s4, faded: s6, fromInterference: sideNote)
        return updateEpisode(spoofing, finalLevel, detail, epoch, adapted: false, why: why, numbers: bandNumbers)!
    }

    private func endSpoof(_ epoch: GnssEpoch, _ current: Episode?) -> Episode? {
        guard let current else { return nil }
        let age = epoch.elapsedMs - current.startedElapsed
        if age < GnssDetector.HOLD_MS {
            if current.rose { var c = current; c.rose = false; return c }
            return current
        }
        var ended = current
        ended.endedWall = epoch.wallMs
        upsert(ended, "spoofing")
        return nil
    }

    private func mockEpisode(_ epoch: GnssEpoch, _ side: GnssSide) -> Episode? {
        if !side.mock {
            if var m = mockEp {
                m.endedWall = epoch.wallMs
                upsert(m, "mock")
            }
            return nil
        }
        return updateEpisode(mockEp, .low, GnssCopy.MOCK, epoch, adapted: false, why: GnssCopy.MOCK)
    }

    private func updateEpisode(
        _ current: Episode?,
        _ level: GnssConfidence?,
        _ detail: String,
        _ epoch: GnssEpoch,
        adapted: Bool,
        why: String = "",
        numbers: String = ""
    ) -> Episode? {
        guard let level else { return current }
        guard var c = current else {
            return Episode(
                startedElapsed: epoch.elapsedMs,
                startedWall: epoch.wallMs,
                confidence: level,
                detail: detail,
                adapted: adapted,
                rose: true,
                why: why,
                numbers: numbers
            )
        }
        let rose = level > c.confidence
        c.confidence = level > c.confidence ? level : c.confidence
        c.detail = detail.ifBlank(c.detail)
        c.adapted = c.adapted || adapted
        c.rose = rose
        c.why = why.ifBlank(c.why)
        c.numbers = numbers.ifBlank(c.numbers)
        return c
    }

    private func cn0Only(_ metrics: [BandKey: Metrics], _ limits: GnssThresholds, _ armed: Bool) -> Bool {
        if agcSeen || !armed { return false }
        // Band order (Kotlin LinkedHashMap) so the Double sum below is the same every run.
        let rows = bandOrder.compactMap { metrics[$0] }.filter { $0.dCn0 != nil }
        if rows.isEmpty { return false }
        if rows.any({ $0.dCn0! > -limits.cn0OnlyDropDb }) { return false }
        let sv = rows.sumOf { $0.sv }
        let base = rows.compactMap { $0.baseSv }.sum()
        return base > 0.0 && Double(sv) <= base * 0.5
    }

    private func correlated() -> Bool {
        let full = svHist.filter { $0.value.count >= GnssDetector.CORR_WIN }
        if full.count < 4 {
            corrStreak = 0
            return false
        }
        let series = full.keys.sorted().map { diffs(full[$0]!) }
        var sum = 0.0
        var n = 0
        for i in series.indices {
            for j in (i + 1)..<series.count {
                sum += pearson(series[i], series[j])
                n += 1
            }
        }
        let mean = n == 0 ? 0.0 : sum / Double(n)
        if mean >= 0.5 { corrStreak += 1 } else { corrStreak = 0 }
        return corrStreak >= 3
    }

    private func pushSv(_ epoch: GnssEpoch) {
        var seen = Set<Int>()
        for key in epoch.bands.keys.sorted(by: bandKeyLess) {
            let band = epoch.bands[key]!
            for svid in band.cn0BySv.keys.sorted() {
                let cn0 = band.cn0BySv[svid]!
                if cn0 <= 0.0 || !cn0.isFinite { continue }
                let id = key.constellation * 1000 + svid
                seen.insert(id)
                var q = svHist[id] ?? []
                q.append(cn0)
                while q.count > GnssDetector.CORR_WIN { q.removeFirst() }
                svHist[id] = q
            }
        }
        svHist = svHist.filter { seen.contains($0.key) }
    }

    private func groups() -> [BandKey: BandKey] {
        let keys = bandOrder
        var parent: [BandKey: BandKey] = [:]
        for k in keys { parent[k] = k }
        func find(_ k: BandKey) -> BandKey {
            var c = k
            while parent[c] != c { c = parent[c] ?? c }
            return c
        }
        for i in keys.indices {
            for j in (i + 1)..<keys.count {
                if !shared(keys[i], keys[j]) { continue }
                parent[find(keys[j])] = find(keys[i])
            }
        }
        var out: [BandKey: BandKey] = [:]
        for k in keys { out[k] = find(k) }
        return out
    }

    private func shared(_ a: BandKey, _ b: BandKey) -> Bool {
        guard let left = bands[a]?.samples.takeLast(30) else { return false }
        guard let right = bands[b]?.samples.takeLast(30) else { return false }
        if left.count < 30 || right.count < 30 { return false }
        for i in left.indices {
            guard let x = left[i].agc, let y = right[i].agc, abs(x - y) <= 0.5 else { return false }
        }
        return true
    }

    private func freeze(_ metrics: [BandKey: Metrics]) {
        for key in bandOrder {
            let track = bands[key]!
            if track.freezeSet { continue }
            guard let m = metrics[key] else { continue }
            track.frozenAgc = m.baseAgc
            track.frozenCn0 = m.baseCn0
            track.frozenSv = m.baseSv
            track.freezeSet = true
        }
    }

    private func clearFreeze() {
        for track in bands.values {
            track.freezeSet = false
            track.frozenAgc = nil
            track.frozenCn0 = nil
            track.frozenSv = nil
        }
    }

    private func bandBits(_ metrics: [BandKey: Metrics]) -> [String] {
        bandOrder.compactMap { k in metrics[k].map { (k, $0) } }
            .filter { $0.1.dAgc != nil || $0.1.dCn0 != nil }
            .sortedBy { $0.1.dAgc ?? 0.0 }
            .take(3)
            .map { bandText($0.0, $0.1) }
    }

    private func bandLines(_ metrics: [BandKey: Metrics]) -> [String] {
        bandOrder.compactMap { key in
            guard let m = metrics[key] else { return nil }
            let name = GnssBands.label(key: key)
            let agc = m.agc.map { format("%.1f dB", $0) } ?? "n/a"
            let cn = m.cn0.map { format("%.1f", $0) } ?? "n/a"
            return "\(name): AGC \(agc), signal \(cn), \(m.sv) satellites"
        }
    }

    private func bandText(_ key: BandKey, _ m: Metrics) -> String {
        let agc = m.dAgc.map { format("%+.1f dB", $0) } ?? "n/a"
        let cn = m.dCn0.map { format("%+.1f dB", $0) } ?? "n/a"
        let base = m.baseSv.map { String($0.toIntTruncating()) } ?? "n/a"
        return "\(GnssBands.label(key: key)): AGC \(agc), signal \(cn), \(m.sv) satellites (baseline \(base))"
    }

    private func upsert(_ ep: Episode, _ kind: String) {
        let mark = GnssMark(
            at: ep.startedWall,
            endedAt: ep.endedWall ?? 0,
            kind: kind,
            confidence: ep.confidence.label(),
            detail: ep.detail.take(400)
        )
        let index = marks.indexOfFirst { $0.at == mark.at && $0.kind == mark.kind }
        if index < 0 { marks.append(mark) } else { marks[index] = mark }
        while marks.count > 40 { marks.removeFirst() }
    }

    private func cleanAgc(_ v: Double?) -> Double? {
        guard let v, v.isFinite, v >= -80.0 else { return nil }
        return v
    }

    private struct Sample {
        var agc: Double?
        var cn0: Double?
        var sv: Int
        var eventAgc: Bool
    }

    private struct Metrics {
        var dAgc: Double?
        var dCn0: Double?
        var baseAgc: Double?
        var baseCn0: Double?
        var baseSv: Double?
        var agc: Double?
        var cn0: Double?
        var sv: Int
        var eventAgc: Bool
    }

    private final class Track {
        var samples: [Sample] = []
        var j1: [Bool] = []
        var j2: [Bool] = []
        var missing = 0
        var freezeSet = false
        var frozenAgc: Double?
        var frozenCn0: Double?
        var frozenSv: Double?

        func push(_ sample: Sample) {
            samples.append(sample)
            while samples.count > GnssDetector.ARM { samples.removeFirst() }
        }

        static func flag(_ buf: inout [Bool], _ now: Bool) -> Bool {
            buf.append(now)
            while buf.count > 7 { buf.removeFirst() }
            return buf.count { $0 } >= 5
        }

        func metrics(invert: Bool) -> Metrics {
            let list = samples
            guard list.count >= GnssDetector.ARM, let last = list.last else {
                let last = list.last
                return Metrics(dAgc: nil, dCn0: nil, baseAgc: nil, baseCn0: nil, baseSv: nil,
                               agc: last?.agc, cn0: last?.cn0, sv: last?.sv ?? 0, eventAgc: last?.eventAgc == true)
            }
            let recent = list.takeLast(GnssDetector.RECENT)
            let base = list.dropLastN(GnssDetector.RECENT)
            let baseAgc = frozenAgc ?? meanOf(base.map { $0.agc })
            let baseCn0 = frozenCn0 ?? meanOf(base.map { $0.cn0 })
            let baseSv = frozenSv ?? meanOf(base.map { Double($0.sv) })
            let recentAgc = meanOf(recent.map { $0.agc })
            let recentCn0 = meanOf(recent.map { $0.cn0 })
            let rawAgc: Double? = (baseAgc != nil && recentAgc != nil) ? recentAgc! - baseAgc! : nil
            let dAgc: Double? = (invert && rawAgc != nil) ? -rawAgc! : rawAgc
            let dCn0: Double? = (baseCn0 != nil && recentCn0 != nil) ? recentCn0! - baseCn0! : nil
            return Metrics(dAgc: dAgc, dCn0: dCn0, baseAgc: baseAgc, baseCn0: baseCn0, baseSv: baseSv,
                           agc: last.agc, cn0: last.cn0, sv: last.sv, eventAgc: last.eventAgc)
        }
    }

    private struct Episode {
        var startedElapsed: Int
        var startedWall: Int
        var confidence: GnssConfidence
        var detail: String
        var adapted: Bool
        var rose: Bool
        var endedWall: Int? = nil
        var why: String = ""
        var numbers: String = ""

        func toLive(_ kind: GnssKind) -> GnssLive {
            GnssLive(kind: kind, confidence: confidence, startedWall: startedWall, detail: detail,
                     adapted: adapted, rose: rose, why: why, numbers: numbers)
        }
    }

    private func diffs(_ values: [Double]) -> [Double] {
        if values.count < 2 { return [] }
        return (1..<values.count).map { values[$0] - values[$0 - 1] }
    }

    private func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let n = Swift.min(a.count, b.count)
        if n < 4 { return 0.0 }
        var ma = 0.0
        var mb = 0.0
        for i in 0..<n {
            ma += a[i]
            mb += b[i]
        }
        ma /= Double(n)
        mb /= Double(n)
        var num = 0.0
        var da = 0.0
        var db = 0.0
        for i in 0..<n {
            let xa = a[i] - ma
            let xb = b[i] - mb
            num += xa * xb
            da += xa * xa
            db += xb * xb
        }
        if da <= 1e-9 || db <= 1e-9 { return 0.0 }
        return num / (da * db).squareRoot()
    }

    private func hasMeasurements(_ epoch: GnssEpoch) -> Bool {
        for band in epoch.bands.values {
            if band.svTracked > 0 { return true }
            if let cn = band.cn0Top3, cn.isFinite, cn > 0.0 { return true }
        }
        return false
    }

    /// No new hit, and the samples already learned stay where they are.
    private func pauseSnapshot() -> GnssSnapshot {
        let learned = bands.values.map { $0.samples.count }.max() ?? 0
        return GnssSnapshot(
            statusLine: GnssCopy.PAUSED,
            bandLines: [],
            lives: openLives(),
            marks: marks,
            agcSeen: agcSeen,
            armed: learned >= GnssDetector.ARM,
            learned: learned
        )
    }

    private func openLives() -> [GnssLive] {
        var lives: [GnssLive] = []
        if let i = interference { lives.append(i.toLive(.interference)) }
        if let s = spoofing { lives.append(s.toLive(.spoofing)) }
        if let m = mockEp { lives.append(m.toLive(.mock)) }
        return lives
    }
}

private func meanOf(_ values: [Double?]) -> Double? {
    var sum = 0.0
    var n = 0
    for v in values {
        guard let v, v.isFinite else { continue }
        sum += v
        n += 1
    }
    return n == 0 ? nil : sum / Double(n)
}
