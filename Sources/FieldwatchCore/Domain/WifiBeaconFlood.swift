import Foundation

// Port of domain/WifiBeaconFlood.kt.

/// Many brand-new Wi-Fi names in one full scan, about the same loudness, on one channel,
/// then gone on the next full scan while some other already-heard network is still there.
/// The first full scan of this process stays quiet. A repeated name, a mesh, an extender,
/// or a guest network is not counted. A partial or cached scan is not a scan.
/// The advertisement does not name the tool.
public final class WifiBeaconFlood: @unchecked Sendable {
    // Kotlin `synchronized` is reentrant; a recursive lock keeps flow observers that call back in safe.
    private let lock = NSRecursiveLock()
    private var seenMacs = Set<String>()
    private var seenNames = Set<String>()
    private var burstList: [FloodBurst] = []
    private var episodeKeys = FloodOrderedKeys()
    private var reportKeys = FloodOrderedKeys()
    private var hiddenKeys = FloodOrderedKeys()
    private var sawLive = Set<String>()
    private var pending: Pending?
    private var primed = false
    private var lastAcceptedAt = 0
    private var episode = false
    private var episodeAt = 0
    private var hidingEpisode = false
    private var acknowledged = false
    /// Open sit. Continue and Hide these then hold until the sit ends.
    private var sitOpen = false
    private var sitHold: SitHold?
    /// Clock time when a no-sit hold ends. A sit hold uses Int.max.
    private var holdUntil = 0
    private var lastNow = 0
    private var medianRssi: Int?
    private let _notice = MutableStateFlow<PairingFlood.Notice?>(nil)
    public var notice: StateFlow<PairingFlood.Notice?> { _notice }
    private let _hide = MutableStateFlow(PairingFlood.FloodHide())
    public var hide: StateFlow<PairingFlood.FloodHide> { _hide }

    public init() {}

    public func bursts() -> [FloodBurst] {
        lock.lock(); defer { lock.unlock() }
        return burstList
    }

    /// One full fresh scan. Empty, cached, and back-to-back callbacks do nothing.
    public func scan(observations: [RadioObservation], now: Int) {
        let rows = parse(observations)
        if rows.isEmpty { return }
        lock.lock(); defer { lock.unlock() }
        if lastAcceptedAt != 0 && now - lastAcceptedAt < WifiBeaconFlood.SCAN_GAP_MS { return }
        lastAcceptedAt = now
        lastNow = now
        expireHold(now)
        if !primed {
            absorb(rows)
            primed = true
            return
        }
        let open = pending
        var confirmed = false
        if let open {
            var here = Set<String>()
            for row in rows { here.insert(row.mac) }
            let anchor = rows.contains { seenMacs.contains($0.mac) && !open.macs.contains($0.mac) }
            if !anchor {
                replaceBaseline(rows)
                pending = nil
                finishEpisode()
                return
            }
            let stayed = open.macs.contains { here.contains($0) }
            pending = nil
            if !stayed {
                confirm(open)
                confirmed = true
            }
        }
        if let next = cluster(rows) {
            pending = next
        } else if !confirmed {
            finishEpisode()
        }
        absorb(rows)
    }

    /// An open sit keeps the answer until setSitOpen goes off.
    /// A running 15-minute answer carries into a sit that starts while it still holds.
    /// With no sit, the answer holds for HOLD_MS from the tap and does not slide.
    /// The burst already on screen stays quiet when that time ends. The next one asks.
    public func setSitOpen(open: Bool) {
        lock.lock(); defer { lock.unlock() }
        if sitOpen == open { return }
        if open { expireHold(lastNow) }
        sitOpen = open
        if open {
            if sitHold != nil { holdUntil = Int.max }
        } else {
            sitHold = nil
            holdUntil = 0
        }
    }

    public func dismiss() {
        lock.lock(); defer { lock.unlock() }
        guard var cur = _notice.value else { return }
        acknowledged = true
        sitHold = hidingEpisode ? .hide : .leave
        holdUntil = sitOpen ? Int.max : lastNow + WifiBeaconFlood.HOLD_MS
        if cur.showDialog {
            cur.showDialog = false
            _notice.value = cur
        }
    }

    /// Hide the addresses counted in the open burst. Off brings those addresses back.
    public func setHideBurst(on: Bool) {
        lock.lock(); defer { lock.unlock() }
        if on {
            if episodeKeys.isEmpty { return }
            hidingEpisode = true
            hiddenKeys.addAll(episodeKeys)
        } else if episode {
            hidingEpisode = false
            hiddenKeys.removeAll(episodeKeys.toSet())
            if sitHold == .hide { sitHold = .leave }
        } else {
            hidingEpisode = false
            hiddenKeys.clear()
            if sitHold == .hide { sitHold = .leave }
        }
        publishHide()
    }

    /// Bring every hidden flood address back. The open burst's switch goes off too.
    public func clearHidden() {
        lock.lock(); defer { lock.unlock() }
        hidingEpisode = false
        if sitHold == .hide { sitHold = .leave }
        if hiddenKeys.isEmpty && _hide.value.keys.isEmpty && !_hide.value.episodeOn { return }
        hiddenKeys.clear()
        publishHide()
    }

    /// Drop hidden addresses that were on the live map and have since left it.
    /// A key that has not been published yet stays, so a burst can still be hidden
    /// in the moment before the list refreshes.
    public func prune(liveKeys: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        if episodeKeys.isEmpty && hiddenKeys.isEmpty {
            sawLive = liveKeys
            return
        }
        var gone = Set<String>()
        for key in episodeKeys.order where sawLive.contains(key) && !liveKeys.contains(key) { gone.insert(key) }
        for key in hiddenKeys.order where sawLive.contains(key) && !liveKeys.contains(key) { gone.insert(key) }
        sawLive = liveKeys
        if gone.isEmpty { return }
        episodeKeys.removeAll(gone)
        let hiddenChanged = hiddenKeys.removeAll(gone)
        let wasOn = hidingEpisode
        if episodeKeys.isEmpty { hidingEpisode = false }
        if hiddenChanged || wasOn != hidingEpisode { publishHide() }
    }

    private func expireHold(_ now: Int) {
        if sitHold != nil && now >= holdUntil {
            sitHold = nil
            holdUntil = 0
        }
    }

    private func confirm(_ open: Pending) {
        let starting = !episode || burstList.isEmpty
        if starting {
            episodeKeys.clear()
            reportKeys.clear()
            hidingEpisode = sitHold == .hide
            episodeAt = lastAcceptedAt
            medianRssi = open.median
        }
        let grew = remember(open.keys)
        if open.median != nil && (starting || reportKeys.count > (burstList.last?.popupCount ?? 0)) {
            medianRssi = open.median
        }
        let next = FloodBurst(
            at: episodeAt,
            popupCount: reportKeys.count,
            nameCount: 0,
            medianRssi: medianRssi,
            keys: reportKeys.toList(),
            wifi: true
        )
        if starting {
            burstList.append(next)
            episode = true
            while burstList.count > WifiBeaconFlood.BURST_CAP { burstList.removeFirst() }
        } else {
            burstList[burstList.count - 1] = next
        }
        if grew && hidingEpisode { publishHide() }
        _notice.value = PairingFlood.Notice(
            showDialog: sitHold == nil && !acknowledged,
            popupCount: reportKeys.count,
            nameCount: 0,
            families: [],
            medianRssi: medianRssi,
            wifi: true,
            duringSit: sitOpen
        )
    }

    private func remember(_ keys: [String]) -> Bool {
        var grew = false
        for key in keys {
            if reportKeys.add(key) {
                while reportKeys.count > Sit.RADIO_CAP { reportKeys.removeOldest() }
            }
            if !episodeKeys.add(key) { continue }
            grew = true
            if hidingEpisode { hiddenKeys.add(key) }
            while episodeKeys.count > WifiBeaconFlood.EPISODE_CAP { episodeKeys.removeOldest() }
        }
        return grew
    }

    private func finishEpisode() {
        let wasOn = hidingEpisode
        episode = false
        hidingEpisode = false
        episodeKeys.clear()
        reportKeys.clear()
        acknowledged = false
        medianRssi = nil
        pending = nil
        if _notice.value != nil { _notice.value = nil }
        if wasOn { publishHide() }
    }

    private func publishHide() {
        _hide.value = PairingFlood.FloodHide(episodeOn: hidingEpisode, keys: hiddenKeys.toSet())
    }

    /// Largest single-channel group of brand-new names, kept within RSSI_BAND_DB.
    /// Groups keep first-seen order (Kotlin used HashMap order; only key order inside a burst differs).
    private func cluster(_ rows: [Row]) -> Pending? {
        var fresh: [Row] = []
        for row in rows {
            if seenMacs.contains(row.mac) { continue }
            if row.base.isEmpty || seenNames.contains(row.base) { continue }
            if row.channel <= 0 || !Rssi.measured(rssi: row.rssi) { continue }
            fresh.append(row)
        }
        if fresh.count < WifiBeaconFlood.MIN_NAMES { return nil }
        let byBase = fresh.groupByOrdered { $0.base }
        var singles: [Row] = []
        for (_, group) in byBase where group.count == 1 { singles.append(group[0]) }
        if singles.count < WifiBeaconFlood.MIN_NAMES { return nil }
        var best: [Row]?
        var bestChannel = Int.max
        for (channel, group) in singles.groupByOrdered({ $0.channel }) {
            let bigger = best == nil || group.count > best!.count ||
                (group.count == best!.count && channel < bestChannel)
            if bigger {
                best = group
                bestChannel = channel
            }
        }
        guard let group = best else { return nil }
        let values = group.map { $0.rssi }.sorted()
        let median = values[values.count / 2]
        let kept = group.filter { abs($0.rssi - median) <= WifiBeaconFlood.RSSI_BAND_DB }
        if kept.count < WifiBeaconFlood.MIN_NAMES { return nil }
        var macs = Set<String>()
        var keys: [String] = []
        for row in kept {
            macs.insert(row.mac)
            keys.append("WIFI:\(row.mac)")
        }
        return Pending(macs: macs, keys: keys, median: median)
    }

    private func absorb(_ rows: [Row]) {
        for row in rows {
            seenMacs.insert(row.mac)
            if row.base.isNotEmpty { seenNames.insert(row.base) }
        }
    }

    private func replaceBaseline(_ rows: [Row]) {
        seenMacs.removeAll()
        seenNames.removeAll()
        absorb(rows)
    }

    private func parse(_ observations: [RadioObservation]) -> [Row] {
        if observations.isEmpty { return [] }
        var order: [String] = []
        var byMac: [String: Row] = [:]
        for obs in observations {
            if obs.kind != .wifi || !obs.fresh { continue }
            let mac = MacUtil.normalize(raw: obs.mac)
            if mac.isBlank || !mac.contains(":") { continue }
            let row = Row(mac: mac, base: baseName(obs.name), rssi: obs.rssi, channel: obs.channel)
            if let prev = byMac[mac] {
                if prefer(row, prev) { byMac[mac] = row }
            } else {
                order.append(mac)
                byMac[mac] = row
            }
        }
        return order.map { byMac[$0]! }
    }

    private func prefer(_ next: Row, _ prev: Row) -> Bool {
        let nextOk = Rssi.measured(rssi: next.rssi)
        let prevOk = Rssi.measured(rssi: prev.rssi)
        if nextOk != prevOk { return nextOk }
        return next.rssi > prev.rssi
    }

    /// One trailing guest, extender, or band suffix. The whole name is kept when that is all it is.
    private func baseName(_ raw: String) -> String {
        let lower = raw.trim().lowercased()
        if lower.isEmpty || lower == "<unknown ssid>" { return "" }
        let chars = Array(lower)
        var cut = -1
        for (i, ch) in chars.enumerated() where ch == "-" || ch == "_" || ch == " " { cut = i }
        if cut <= 0 || cut >= chars.count - 1 { return lower }
        let head = String(chars[0..<cut]).trim()
        let tail = String(chars[(cut + 1)...]).trim()
        if head.isNotEmpty && WifiBeaconFlood.SUFFIXES.contains(tail) { return head }
        return lower
    }

    private struct Row {
        let mac: String
        let base: String
        let rssi: Int
        let channel: Int
    }

    private struct Pending {
        let macs: Set<String>
        let keys: [String]
        let median: Int?
    }

    public static let MIN_NAMES = 15
    public static let RSSI_BAND_DB = 6
    public static let SCAN_GAP_MS = 3_000
    /// Same length as the last-15-minutes path. Starts at the answer and does not slide.
    public static let HOLD_MS = 15 * 60_000

    /// What Continue or Hide these means for the rest of an open sit.
    private enum SitHold { case leave, hide }
    private static let BURST_CAP = 40
    private static let EPISODE_CAP = 900
    private static let SUFFIXES: Set<String> = [
        "guest", "guests", "extender", "ext",
        "2.4ghz", "5ghz", "6ghz",
        "2.4g", "5g", "6g",
        "2.4",
    ]
}
