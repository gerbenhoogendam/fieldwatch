import Foundation

// Port of domain/PairingFlood.kt.

/// One burst that crossed the flood line. Saved on the sit when it happens.
public struct FloodBurst: Codable, Hashable, Sendable {
    public var at: Int
    public var popupCount: Int
    public var nameCount: Int
    public var families: [String]
    public var medianRssi: Int?
    /// Device keys counted in this burst. Empty on a sit saved before keys were stored.
    public var keys: [String]
    /// Wi-Fi beacon flood. A Bluetooth burst leaves this false.
    public var wifi: Bool

    public init(at: Int, popupCount: Int, nameCount: Int, families: [String] = [], medianRssi: Int? = nil,
                keys: [String] = [], wifi: Bool = false) {
        self.at = at; self.popupCount = popupCount; self.nameCount = nameCount; self.families = families
        self.medianRssi = medianRssi; self.keys = keys; self.wifi = wifi
    }

    enum CodingKeys: String, CodingKey { case at, popupCount, nameCount, families, medianRssi, keys, wifi }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decode(Int.self, forKey: .at)
        popupCount = try c.decode(Int.self, forKey: .popupCount)
        nameCount = try c.decode(Int.self, forKey: .nameCount)
        families = try c.decode(.families, default: [])
        medianRssi = try c.opt(.medianRssi)
        keys = try c.decode(.keys, default: [])
        wifi = try c.decode(.wifi, default: false)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(at, forKey: .at)
        try c.encode(popupCount, forKey: .popupCount)
        try c.encode(nameCount, forKey: .nameCount)
        try c.encode(families, forKey: .families)
        try c.encode(medianRssi, forKey: .medianRssi)
        try c.encode(keys, forKey: .keys)
        try c.encode(wifi, forKey: .wifi)
    }

    public func reportLine(clock: String) -> String {
        // Families are stored only when the live pairing line was crossed, so an older sit keeps that label.
        let pairing = !wifi && (families.isNotEmpty || popupCount >= PairingFlood.POPUP_MIN)
        let head = wifi ? "Wi-Fi beacon flood" : (pairing ? "Pairing flood" : "Name flood")
        let count = (wifi || pairing) ? popupCount : nameCount
        let unit = wifi ? "new names" : "new addresses"
        let fam = (pairing && families.isNotEmpty) ? ": \(families.joined(separator: ", "))" : ""
        let extra = (pairing && nameCount >= PairingFlood.NAME_MIN) ? " · \(nameCount) named" : ""
        let loud = medianRssi != nil ? " · about \(medianRssi!) dBm" : ""
        let aside: String
        switch keys.count {
        case 0: aside = ""
        case 1: aside = " 1 address from this burst is left out of the counts and lists below."
        default: aside = " \(keys.count) addresses from this burst are left out of the counts and lists below."
        }
        return "\(clock) UTC. \(head). \(count) \(unit)\(fam)\(extra)\(loud).\(aside)"
    }

    public static let INTRO =
        "A burst of new Bluetooth addresses in a few seconds. A handheld can do this by advertising a pairing request or a new name and changing the address every packet. A name flood counts randomized addresses. A factory address with a stable name stays out of that count. The advertisement does not name the tool."

    public static let WIFI_INTRO =
        "A burst of new Wi-Fi names in one scan, about the same loudness, gone by the next scan. A repeated name, a mesh, an extender, or a guest network is not counted. The advertisement does not name the tool."

    /// Device keys counted in these bursts. A burst with no keys contributes nothing.
    public static func keysOf(floods: [FloodBurst]) -> Set<String> {
        if floods.isEmpty { return [] }
        var out = Set<String>()
        for burst in floods where burst.keys.isNotEmpty { out.formUnion(burst.keys) }
        return out
    }

    /// Bluetooth sentence when any burst is Bluetooth, Wi-Fi sentence when any burst is Wi-Fi.
    public static func intro(floods: [FloodBurst]) -> String {
        var s = ""
        if floods.contains(where: { !$0.wifi }) { s += INTRO }
        if floods.contains(where: { $0.wifi }) {
            if s.isNotEmpty { s += "\n\n" }
            s += WIFI_INTRO
        }
        return s
    }

    /// Keys whose burst started inside the report window.
    public static func keysOf(floods: [FloodBurst], start: Int, end: Int) -> Set<String> {
        if floods.isEmpty { return [] }
        var out = Set<String>()
        for burst in floods {
            if burst.keys.isEmpty || !(start...end).contains(burst.at) { continue }
            out.formUnion(burst.keys)
        }
        return out
    }

    public static func clock(ms: Int) -> String { formatMs(ms, "HH:mm", utc: true) }
}

/// Insertion-ordered string set (Kotlin LinkedHashSet) shared by the two flood detectors.
struct FloodOrderedKeys {
    private(set) var order: [String] = []
    private var members = Set<String>()

    var isEmpty: Bool { order.isEmpty }
    var count: Int { order.count }
    func contains(_ k: String) -> Bool { members.contains(k) }
    func toList() -> [String] { order }
    func toSet() -> Set<String> { members }

    @discardableResult
    mutating func add(_ k: String) -> Bool {
        guard members.insert(k).inserted else { return false }
        order.append(k)
        return true
    }

    mutating func addAll(_ ks: FloodOrderedKeys) { for k in ks.order { add(k) } }

    mutating func removeOldest() {
        guard let first = order.first else { return }
        order.removeFirst()
        members.remove(first)
    }

    /// True when anything was removed.
    @discardableResult
    mutating func removeAll(_ ks: Set<String>) -> Bool {
        let before = order.count
        order.removeAll { ks.contains($0) }
        members.subtract(ks)
        return order.count != before
    }

    mutating func clear() { order.removeAll(); members.removeAll() }
}

/// Counts brand-new Bluetooth addresses over about ten seconds.
/// Pairing popups share one counter: Apple proximity pairing (Continuity 0x07),
/// Nearby Action (0x0F), a 3-byte Fast Pair model, a Swift Pair beacon,
/// Samsung Easy Setup buds or watch, and a LoveSpouse advertisement
/// (company 0x00FF plus its fixed prefix).
/// The Windows background beacon (company 0x0006 starting with 0x01) stays out.
/// Find My (0x12) stays out, including a later 0x07 in that same payload.
/// A separate counter is a new randomized address that only advertises a name.
/// A factory address with a stable name stays out of that count.
/// Pairing popups still count every address.
/// Similar loudness keeps a spread-out crowd from tripping it.
/// The advertisement does not name the tool.
///
/// macOS note: CoreBluetooth gives opaque peripheral UUIDs, which MacUtil treats as randomized,
/// so every named BLE radio on a Mac counts toward the name flood.
public final class PairingFlood: @unchecked Sendable {
    public struct Notice: Hashable, Sendable {
        public var showDialog: Bool
        public var popupCount: Int
        public var nameCount: Int
        public var families: [String]
        public var medianRssi: Int?
        public var wifi: Bool
        /// A sit is open, so Continue and Hide these hold until that sit ends.
        public var duringSit: Bool

        public init(showDialog: Bool, popupCount: Int, nameCount: Int, families: [String], medianRssi: Int?,
                    wifi: Bool = false, duringSit: Bool = false) {
            self.showDialog = showDialog; self.popupCount = popupCount; self.nameCount = nameCount
            self.families = families; self.medianRssi = medianRssi; self.wifi = wifi; self.duringSit = duringSit
        }

        public func title() -> String {
            if wifi { return "Wi-Fi beacon flood" }
            return popupCount >= POPUP_MIN ? "Pairing flood" : "Name flood"
        }

        public func line() -> String {
            if wifi {
                let loud = medianRssi != nil ? " · about \(medianRssi!) dBm" : ""
                return "Wi-Fi beacon flood · \(popupCount) new names\(loud)"
            }
            let popupHot = popupCount >= POPUP_MIN
            let nameHot = nameCount >= NAME_MIN
            let head = popupHot ? "Pairing flood" : "Name flood"
            let count = popupHot ? popupCount : nameCount
            let extra = (popupHot && nameHot) ? " · \(nameCount) named" : ""
            let loud = medianRssi != nil ? " · about \(medianRssi!) dBm" : ""
            return "\(head) · \(count) new addresses\(extra)\(loud)"
        }

        public func body() -> String {
            let choice = duringSit
                ? "Continue leaves them on Live for the rest of this sit. Hide these takes this burst, and later bursts in this sit, off Live. The sit and the log still keep them."
                : "Continue leaves them on Live for about the next 15 minutes. Hide these takes this burst, and later bursts in that time, off Live. The sit and the log still keep them."
            if wifi {
                let loud = medianRssi != nil ? ", about the same loudness, about \(medianRssi!) dBm," : ""
                let what = "\(popupCount) new Wi-Fi names showed up in one scan\(loud) and they were gone on the next scan. " +
                    "A repeated name, a mesh, an extender, or a guest network is not counted."
                let how = "A handheld such as a Flipper Zero, or an ESP32 running Marauder or Bruce, does this by advertising many network names. The advertisement does not name the tool."
                return what + "\n\n" + how + "\n\n" + choice
            }
            let popupHot = popupCount >= POPUP_MIN
            let nameHot = nameCount >= NAME_MIN
            var what = ""
            if popupHot {
                what += "\(popupCount) new addresses sent pairing advertisements in the last few seconds"
                if families.isNotEmpty {
                    what += ": " + families.joined(separator: ", ")
                }
                what += "."
                if nameHot {
                    what += " \(nameCount) more each advertised a Bluetooth name."
                }
            } else {
                what += "\(nameCount) new addresses each advertised a Bluetooth name in the last few seconds."
            }
            if let medianRssi {
                what += " They are about the same loudness, about \(medianRssi) dBm."
            }
            let how = popupHot
                ? "This can be many radios already advertising pairing, such as in a store, or one radio changing its address on every packet. A Flipper Zero, or an ESP32 running Marauder or Bruce, can do the second. The advertisement does not name the tool.\n\n\(choice)"
                : "This can be many radios already advertising a name, such as tags in a store, or one radio changing its name and address on every packet. A Flipper Zero, or an ESP32 running Marauder or Bruce, can do the second. The advertisement does not name the tool.\n\n\(choice)"
            return what + "\n\n" + how
        }
    }

    /// Addresses from bursts the operator chose to hide, still on the live map.
    public struct FloodHide: Hashable, Sendable {
        public var episodeOn: Bool
        public var keys: Set<String>
        public init(episodeOn: Bool = false, keys: Set<String> = []) { self.episodeOn = episodeOn; self.keys = keys }
    }

    // Kotlin `synchronized` is reentrant; a recursive lock keeps flow observers that call back in safe.
    private let lock = NSRecursiveLock()
    private var window: [Hit] = []
    private var macs = Set<String>()
    private var burstList: [FloodBurst] = []
    private var episodeKeys = FloodOrderedKeys()
    /// Every address this episode counted, including ones past the live-hide cap.
    private var reportKeys = FloodOrderedKeys()
    private var hiddenKeys = FloodOrderedKeys()
    private var sawLive = Set<String>()
    private var episode = false
    private var hidingEpisode = false
    private var acknowledged = false
    /// Open sit. Continue and Hide these then hold until the sit ends.
    private var sitOpen = false
    private var sitHold: SitHold?
    /// Clock time when a no-sit hold ends. A sit hold uses Int.max.
    private var holdUntil = 0
    private var lastNow = 0
    /// Latest GPS speed from the scan loop. Nil when the fix has no speed.
    private var speedMps: Double?
    private let _notice = MutableStateFlow<Notice?>(nil)
    public var notice: StateFlow<Notice?> { _notice }
    private let _hide = MutableStateFlow(FloodHide())
    public var hide: StateFlow<FloodHide> { _hide }

    public init() {}

    public func bursts() -> [FloodBurst] {
        lock.lock(); defer { lock.unlock() }
        return burstList
    }

    /// First sighting of an address. Repeat advertisements are not passed in.
    /// `speedMps` is this Mac's GPS speed, or nil when it is unknown.
    /// A weak burst while driving does not warn. Nil does not hide one.
    public func consider(obs: RadioObservation, now: Int, speedMps: Double? = nil) {
        if obs.kind != .ble { return }
        guard let kind = classify(obs) else { return }
        lock.lock(); defer { lock.unlock() }
        self.speedMps = speedMps
        lastNow = now
        expireHold(now)
        let dropped = evict(now)
        let mac = MacUtil.normalize(raw: obs.mac)
        if mac.isBlank || !macs.insert(mac).inserted {
            if dropped { publish(now) }
            return
        }
        window.append(Hit(mac: mac, at: now, rssi: obs.rssi, popup: kind.popup, families: kind.families))
        while window.count > PairingFlood.CAP { macs.remove(window.removeFirst().mac) }
        publish(now)
    }

    /// Drops addresses that have left the window. Cheap when the window is empty.
    public func tick(now: Int, speedMps: Double? = nil) {
        lock.lock(); defer { lock.unlock() }
        let wasDriving = PairingFlood.driving(self.speedMps)
        self.speedMps = speedMps
        lastNow = now
        expireHold(now)
        if window.isEmpty {
            finishEpisode()
            return
        }
        let dropped = evict(now)
        if !dropped && wasDriving == PairingFlood.driving(self.speedMps) { return }
        publish(now)
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
        holdUntil = sitOpen ? Int.max : lastNow + PairingFlood.HOLD_MS
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

    /// A weak cluster while this Mac is driving is a pass-by, not a warning.
    private func warnsAtThisSpeed(_ median: Int?) -> Bool {
        if !PairingFlood.driving(speedMps) { return true }
        guard let rssi = median else { return true }
        return rssi > PairingFlood.DRIVE_WEAK_DBM
    }

    private func evict(_ now: Int) -> Bool {
        var dropped = false
        while let first = window.first, now - first.at > PairingFlood.WINDOW_MS {
            macs.remove(window.removeFirst().mac)
            dropped = true
        }
        return dropped
    }

    private func publish(_ now: Int) {
        var popups: [Hit] = []
        var names: [Hit] = []
        for hit in window {
            if hit.popup { popups.append(hit) } else { names.append(hit) }
        }
        let pop = band(popups)
        let nam = band(names)
        let popupHot = pop.count >= PairingFlood.POPUP_MIN && warnsAtThisSpeed(pop.median)
        let nameHot = nam.count >= PairingFlood.NAME_MIN && warnsAtThisSpeed(nam.median)
        if !popupHot && !nameHot {
            finishEpisode()
            return
        }
        let families = popupHot ? labels(pop.hits) : []
        let median: Int?
        if popupHot && pop.median != nil { median = pop.median }
        else if nameHot && nam.median != nil { median = nam.median }
        else { median = nil }
        let starting = !episode || burstList.isEmpty
        if starting {
            episodeKeys.clear()
            reportKeys.clear()
            hidingEpisode = sitHold == .hide
        }
        var grew = false
        if popupHot { grew = remember(pop.hits) || grew }
        if nameHot { grew = remember(nam.hits) || grew }
        let next = FloodBurst(at: now, popupCount: pop.count, nameCount: nam.count, families: families,
                              medianRssi: median, keys: reportKeys.toList())
        if starting {
            burstList.append(next)
            episode = true
            while burstList.count > PairingFlood.BURST_CAP { burstList.removeFirst() }
        } else {
            burstList[burstList.count - 1] = peak(burstList[burstList.count - 1], next)
        }
        if grew && hidingEpisode { publishHide() }
        _notice.value = Notice(
            showDialog: sitHold == nil && !acknowledged,
            popupCount: pop.count,
            nameCount: nam.count,
            families: families,
            medianRssi: median,
            duringSit: sitOpen
        )
    }

    private func remember(_ hits: [Hit]) -> Bool {
        var grew = false
        for hit in hits {
            let key = "BLE:\(hit.mac)"
            if reportKeys.add(key) {
                while reportKeys.count > Sit.RADIO_CAP { reportKeys.removeOldest() }
            }
            if !episodeKeys.add(key) { continue }
            grew = true
            if hidingEpisode { hiddenKeys.add(key) }
            while episodeKeys.count > PairingFlood.EPISODE_CAP { episodeKeys.removeOldest() }
        }
        return grew
    }

    private func expireHold(_ now: Int) {
        if sitHold != nil && now >= holdUntil {
            sitHold = nil
            holdUntil = 0
        }
    }

    private func finishEpisode() {
        let wasOn = hidingEpisode
        episode = false
        hidingEpisode = false
        episodeKeys.clear()
        reportKeys.clear()
        acknowledged = false
        if _notice.value != nil { _notice.value = nil }
        if wasOn { publishHide() }
    }

    private func publishHide() {
        _hide.value = FloodHide(episodeOn: hidingEpisode, keys: hiddenKeys.toSet())
    }

    /// Keep the first time and the high-water counts for this burst.
    private func peak(_ prev: FloodBurst, _ next: FloodBurst) -> FloodBurst {
        let louder = next.popupCount > prev.popupCount ||
            (next.popupCount == prev.popupCount && next.nameCount > prev.nameCount)
        var out = prev
        out.popupCount = max(prev.popupCount, next.popupCount)
        out.nameCount = max(prev.nameCount, next.nameCount)
        out.families = (prev.families + next.families).distinct()
        out.medianRssi = louder ? (next.medianRssi ?? prev.medianRssi) : (prev.medianRssi ?? next.medianRssi)
        out.keys = next.keys
        return out
    }

    private func band(_ hits: [Hit]) -> Band {
        if hits.isEmpty { return Band(count: 0, median: nil, hits: []) }
        let measured = hits.filter { Rssi.measured(rssi: $0.rssi) }
        if measured.count * 2 <= hits.count { return Band(count: hits.count, median: nil, hits: hits) }
        let values = measured.map { $0.rssi }.sorted()
        let median = values[values.count / 2]
        let kept = measured.filter { abs($0.rssi - median) <= PairingFlood.RSSI_BAND_DB }
        return Band(count: kept.count, median: median, hits: kept)
    }

    private func labels(_ hits: [Hit]) -> [String] {
        var bits = 0
        for hit in hits { bits |= hit.families }
        var out: [String] = []
        if bits & PairingFlood.BIT_PROX != 0 { out.append("Apple proximity pairing") }
        if bits & PairingFlood.BIT_ACTION != 0 { out.append("Apple Nearby Action") }
        if bits & PairingFlood.BIT_FAST != 0 { out.append("Fast Pair") }
        if bits & PairingFlood.BIT_SWIFT != 0 { out.append("Swift Pair") }
        if bits & PairingFlood.BIT_EASY != 0 { out.append("Samsung Easy Setup") }
        if bits & PairingFlood.BIT_LOVE != 0 { out.append("LoveSpouse") }
        return out
    }

    private func classify(_ obs: RadioObservation) -> Kind? {
        var bits = 0
        for rec in mfgOf(obs) {
            switch rec.companyId {
            case 0x004C: bits |= appleBits(rec.dataHex)
            case 0x0006: if swiftPair(rec.dataHex) { bits |= PairingFlood.BIT_SWIFT }
            case 0x0075: if easySetup(rec.dataHex) { bits |= PairingFlood.BIT_EASY }
            case 0x00FF: if loveSpouse(rec.dataHex) { bits |= PairingFlood.BIT_LOVE }
            default: break
            }
        }
        if FastPair.pairingAdvertised(facts: obs.facts) { bits |= PairingFlood.BIT_FAST }
        if bits != 0 { return Kind(popup: true, families: bits) }
        if obs.name.isNotBlank && MacUtil.isRandomized(mac: obs.mac) {
            return Kind(popup: false, families: 0)
        }
        return nil
    }

    private func mfgOf(_ obs: RadioObservation) -> [MfgRecord] {
        if obs.facts.mfgRecords.isNotEmpty { return obs.facts.mfgRecords }
        guard let id = obs.manufacturerId else { return [] }
        if obs.manufacturerDataHex.isBlank { return [] }
        return [MfgRecord(companyId: id, dataHex: obs.manufacturerDataHex)]
    }

    /// Apple Continuity TLVs. Nearby Info (0x10) and Find My (0x12) are not popups.
    /// A 0x07 after a Find My TLV is part of that advertisement. A 0x07 that comes
    /// first is still proximity pairing. Nearby Action (0x0F) still counts.
    private func appleBits(_ hex: String) -> Int {
        guard let bytes = hexBytes(hex) else { return 0 }
        var i = 0
        var bits = 0
        var sawFindMy = false
        while i + 2 <= bytes.count {
            let type = Int(bytes[i])
            let len = Int(bytes[i + 1])
            if len <= 0 || i + 2 + len > bytes.count { break }
            switch type {
            case 0x07: if !sawFindMy { bits |= PairingFlood.BIT_PROX }
            case 0x0F: bits |= PairingFlood.BIT_ACTION
            case 0x12: sawFindMy = true
            default: break
            }
            i += 2 + len
        }
        return bits
    }

    /// Swift Pair beacon: id 0x03, sub-scenario 0x00–0x02, reserved byte 0x80.
    /// The Windows background beacon starts with 0x01 and stays out.
    private func swiftPair(_ hex: String) -> Bool {
        guard let bytes = hexBytes(hex) else { return false }
        if bytes.count < 3 || bytes[0] != 0x03 { return false }
        return bytes[1] <= 0x02 && bytes[2] == 0x80
    }

    /// Samsung Easy Setup buds or watch. Other 0x0075 payloads, including a SmartTag, stay out.
    private func easySetup(_ hex: String) -> Bool {
        guard let bytes = hexBytes(hex) else { return false }
        return startsWith(bytes, PairingFlood.EASY_BUDS) || startsWith(bytes, PairingFlood.EASY_WATCH)
    }

    /// LoveSpouse prefix under company 0x00FF. A shorter blob stays out.
    private func loveSpouse(_ hex: String) -> Bool {
        guard let bytes = hexBytes(hex) else { return false }
        return startsWith(bytes, PairingFlood.LOVE_SPOUSE)
    }

    private func startsWith(_ bytes: [UInt8], _ prefix: [UInt8]) -> Bool {
        if bytes.count < prefix.count { return false }
        for i in prefix.indices where bytes[i] != prefix[i] { return false }
        return true
    }

    private func hexBytes(_ hex: String) -> [UInt8]? {
        var n = 0
        for c in hex.unicodeScalars where nibble(c) >= 0 { n += 1 }
        if n == 0 || n % 2 != 0 { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(n / 2)
        var hi = -1
        for c in hex.unicodeScalars {
            let v = nibble(c)
            if v < 0 { continue }
            if hi < 0 {
                hi = v
            } else {
                out.append(UInt8((hi << 4) | v))
                hi = -1
            }
        }
        return out
    }

    private func nibble(_ c: Unicode.Scalar) -> Int {
        switch c.value {
        case 0x30...0x39: return Int(c.value) - 0x30
        case 0x61...0x66: return Int(c.value) - 0x61 + 10
        case 0x41...0x46: return Int(c.value) - 0x41 + 10
        default: return -1
        }
    }

    private struct Hit {
        let mac: String
        let at: Int
        let rssi: Int
        let popup: Bool
        let families: Int
    }

    private struct Kind {
        let popup: Bool
        let families: Int
    }

    private struct Band {
        let count: Int
        let median: Int?
        let hits: [Hit]
    }

    /// What Continue or Hide these means for the rest of an open sit.
    private enum SitHold { case leave, hide }

    public static let WINDOW_MS = 10_000
    /// Same length as the last-15-minutes path. Starts at the answer and does not slide.
    public static let HOLD_MS = 15 * 60_000
    public static let POPUP_MIN = 10
    public static let NAME_MIN = 15
    public static let RSSI_BAND_DB = 12
    /// Above a walk. About 11 mph. A store aisle stays under this.
    public static let DRIVE_MPS = 5.0
    /// At or below this, a burst while driving stays quiet. Louder still warns.
    public static let DRIVE_WEAK_DBM = -80

    private static func driving(_ speed: Double?) -> Bool { speed != nil && speed! >= DRIVE_MPS }
    private static let CAP = 96
    private static let BURST_CAP = 40
    private static let EPISODE_CAP = 900
    private static let BIT_PROX = 1
    private static let BIT_ACTION = 2
    private static let BIT_FAST = 4
    private static let BIT_SWIFT = 8
    private static let BIT_EASY = 16
    private static let BIT_LOVE = 32
    private static let LOVE_SPOUSE: [UInt8] = [0x6D, 0xB6, 0x43, 0xCE, 0x97, 0xFE, 0x42, 0x7C]
    private static let EASY_BUDS: [UInt8] = [0x42, 0x09, 0x81, 0x02, 0x14, 0x15, 0x03, 0x21, 0x01, 0x09]
    private static let EASY_WATCH: [UInt8] = [0x01, 0x00, 0x02, 0x00, 0x01, 0x01, 0xFF, 0x00, 0x00, 0x43]
}
