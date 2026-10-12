import Foundation

/// Relative-loudness hunt for one BLE advertiser. RSSI is not distance
/// and not a bearing. Quiet / gone is as important as closer / further.
public enum HuntCue: String, CaseIterable, Sendable {
    case veryClose = "VERY_CLOSE"
    case closer = "CLOSER"
    case further = "FURTHER"
    case same = "SAME"
    case waiting = "WAITING"
    case quiet = "QUIET"
    case gone = "GONE"
}

public enum Hunt {
    public static let RECENT_MS = 2_000
    public static let EARLIER_FROM_MS = 8_000
    public static let EARLIER_TO_MS = 3_500
    public static let STEP_DB = 3.0
    public static let QUIET_MS = 8_000
    /// Same floor as DeviceExplain "very strong." Pocket / in-hand / same bag, not meters.
    public static let VERY_CLOSE_DBM = -45.0
    /// Geiger tick: last-heard RSSI mapped to interval. Loud end is faster than Very Close.
    public static let TICK_LOUD_DBM = -40
    public static let TICK_QUIET_DBM = -90
    public static let TICK_FAST_MS = 90
    public static let TICK_SLOW_MS = 1_400

    public static func cue(samples: [RssiSample], now: Int, lastSeen: Int?, missing: Bool) -> HuntCue {
        if missing { return .gone }
        guard let lastSeen else { return .waiting }
        if now - lastSeen > QUIET_MS { return .quiet }
        let usable = samples.filter { Rssi.measured(rssi: $0.rssi) }
        let recent = usable.filter { $0.at >= now - RECENT_MS }
        let loud: Double? = recent.isNotEmpty
            ? recent.map { $0.rssi }.average()
            : usable.last(where: { now - $0.at <= QUIET_MS }).map { Double($0.rssi) }
        if let loud, loud >= VERY_CLOSE_DBM { return .veryClose }
        let earlier = usable.filter { ((now - EARLIER_FROM_MS)...(now - EARLIER_TO_MS)).contains($0.at) }
        if recent.count < 2 || earlier.count < 2 { return .waiting }
        let delta = recent.map { $0.rssi }.average() - earlier.map { $0.rssi }.average()
        if delta >= STEP_DB { return .closer }
        if delta <= -STEP_DB { return .further }
        return .same
    }

    public static func label(cue: HuntCue) -> String {
        switch cue {
        case .veryClose: return "Very Close"
        case .closer: return "Closer"
        case .further: return "Further"
        case .same: return "About the same"
        case .waiting: return "Listening…"
        case .quiet: return "Quiet"
        case .gone: return "Gone"
        }
    }

    public static func hint(cue: HuntCue) -> String {
        switch cue {
        case .veryClose: return "Screaming loud here. Look around — usually in-hand, pocket, or the same bag. Not meters."
        case .closer: return "Louder than a few seconds ago. Keep walking that way."
        case .further: return "Quieter than a few seconds ago. Turn or back up."
        case .same: return "No clear change yet. Slow down; hold the Mac still."
        case .waiting: return "Need a few seconds of packets to compare."
        case .quiet: return "No packet for a few seconds. Silent, or behind a wall."
        case .gone: return "Left the live set. Randomized BLE often vanishes mid-hunt."
        }
    }

    /// Interval between Hunt ticks, or nil to stay silent.
    /// Quiet / Gone (and no live RSSI) do not tick. Waiting still ticks if a packet is on the screen.
    public static func tickIntervalMs(rssi: Int?, cue: HuntCue) -> Int? {
        if cue == .quiet || cue == .gone { return nil }
        guard let r = rssi else { return nil }
        let span = Double(TICK_LOUD_DBM - TICK_QUIET_DBM)
        let t = (Double(r - TICK_QUIET_DBM) / span).coerceIn(0.0, 1.0)
        return Int(Double(TICK_SLOW_MS) + Double(TICK_FAST_MS - TICK_SLOW_MS) * t)
    }
}
