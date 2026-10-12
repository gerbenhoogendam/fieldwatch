import Foundation

// Port of data/DeviceStore.kt — the live sighting aggregator. Hot path: called for every advertisement.
// Thread-safe: one NSLock guards the live map and match stamps (Kotlin synchronized + ConcurrentHashMap).
// `devices` / `stats` are published after the lock is released, so observers may call back into the store.

public final class DeviceStore: @unchecked Sendable {
    private let engine: SignatureEngine
    private var live: [String: Sighting] = [:]

    /// Live rows in a stable order (first heard, then key). Swift dictionaries iterate in a per-launch
    /// random order; Kotlin's map order leaked into tie-breaks on Live, alert voice and eviction.
    private func orderedLive() -> [Sighting] {
        live.values.sorted { $0.firstSeen != $1.firstSeen ? $0.firstSeen < $1.firstSeen : $0.key < $1.key }
    }
    private let _devices = MutableStateFlow<[Sighting]>([])
    public var devices: StateFlow<[Sighting]> { _devices }

    private let _stats = MutableStateFlow(ScanStats())
    public var stats: StateFlow<ScanStats> { _stats }

    private let historyLimit = 40
    private let evictAfterMs = 15 * 60 * 1000
    private let evictAnonMs = 3 * 60 * 1000
    /// Steady-state list size. Fresh radios inside brief hold/stale may exceed this.
    private let maxLive = 400
    /// Absolute ceiling so a plaza of rotating BLE MACs cannot grow without bound.
    private let hardLive = 900
    private var lastWifiBatchAt = 0
    private var wifiHold = false
    private var bleHold = false
    private let lock = NSLock()
    /// Identity fingerprint → skip signature search while name / IEs / UUIDs / mfg stay the same.
    private var matchStamp: [String: String] = Dictionary(minimumCapacity: 512)
    /// Kotlin compared list identity. Swift Array `==` short-circuits on a shared buffer, so an unchanged
    /// catalog costs nothing; an equal copy keeps the stamps (same matches either way).
    private var catalogRef: [Fleet]?
    private var catalogCluster = false

    public init(engine: SignatureEngine = SignatureEngine()) {
        self.engine = engine
    }

    public func keyOf(kind: RadioKind, mac: String) -> String {
        "\(kind.rawValue):\(MacUtil.normalize(raw: mac))"
    }

    @discardableResult
    public func ingest(observation: RadioObservation, fleets: [Fleet], staleSec: Int) -> Sighting {
        ingestBatch(observations: [observation], fleets: fleets, staleSec: staleSec)[0]
    }

    @discardableResult
    public func ingestBatch(observations: [RadioObservation], fleets: [Fleet], staleSec: Int) -> [Sighting] {
        lock.lock(); defer { lock.unlock() }
        if observations.isEmpty { return [] }
        var out: [Sighting] = []
        out.reserveCapacity(observations.count)
        for observation in observations {
            out.append(upsert(observation))
        }
        relabel(touched: out, fleets: fleets)
        for i in out.indices {
            out[i] = live[out[i].key] ?? out[i]
        }
        return out
    }

    private func upsert(_ observation: RadioObservation) -> Sighting {
        let mac = MacUtil.normalize(raw: observation.mac)
        let key = keyOf(kind: observation.kind, mac: mac)
        let now = observation.at > 0 ? observation.at : nowMs()
        let existing = live[key]
        if observation.kind == .wifi && !observation.fresh, var next = existing {
            next.name = observation.name.ifBlank(next.name)
            if Rssi.measured(rssi: observation.rssi) { next.rssi = observation.rssi }
            next.vendorIeOuis = mergeIes(next.vendorIeOuis, observation.vendorIeOuis)
            next.facts = next.facts.merge(newer: observation.facts)
            next.fastPairPairing = next.fastPairPairing || FastPair.pairingAdvertised(facts: observation.facts)
            live[key] = next
            return next
        }
        let measured = Rssi.measured(rssi: observation.rssi)
        let sample: RssiSample? = measured ? RssiSample(at: now, rssi: observation.rssi) : nil
        let merged: Sighting
        if let existing {
            var d = existing
            if let sample {
                if d.rssiHistory.count >= historyLimit {
                    d.rssiHistory = Array(d.rssiHistory.dropFirst(d.rssiHistory.count - historyLimit + 1))
                }
                d.rssiHistory.append(sample)
            }
            if let last = d.presence.last {
                if last.end != nil { d.presence.append(PresenceSpan(start: now, end: nil)) }
            } else {
                d.presence.append(PresenceSpan(start: now, end: nil))
            }
            if observation.serviceUuids.isNotEmpty {
                d.serviceUuids = (d.serviceUuids + observation.serviceUuids).distinct()
            }
            d.name = observation.name.ifBlank(existing.name)
            if measured { d.rssi = observation.rssi }
            if d.vendor == nil { d.vendor = OuiLookup.vendor(mac: mac) }
            if measured {
                d.rssiMin = Rssi.measured(rssi: existing.rssiMin) ? min(existing.rssiMin, observation.rssi) : observation.rssi
                d.rssiMax = Rssi.measured(rssi: existing.rssiMax) ? max(existing.rssiMax, observation.rssi) : observation.rssi
            }
            if observation.channel != 0 { d.channel = observation.channel }
            if observation.frequencyMhz != 0 { d.frequencyMhz = observation.frequencyMhz }
            d.hiddenSsid = existing.hiddenSsid || observation.hiddenSsid
            d.manufacturerId = existing.manufacturerId ?? observation.manufacturerId
            d.manufacturerDataHex = mergeMfgHex(existing.manufacturerDataHex, observation.manufacturerDataHex)
            if observation.rawHex.count >= existing.rawHex.count { d.rawHex = observation.rawHex.take(1024) }
            d.lastSeen = now
            d.hitCount = existing.hitCount + 1
            d.latitude = observation.latitude ?? existing.latitude
            d.longitude = observation.longitude ?? existing.longitude
            d.gpsTrail = gpsAppend(existing.gpsTrail, observation)
            d.gone = false
            d.vendorIeOuis = mergeIes(existing.vendorIeOuis, observation.vendorIeOuis)
            d.facts = existing.facts.merge(newer: observation.facts)
            d.fastPairPairing = existing.fastPairPairing || FastPair.pairingAdvertised(facts: observation.facts)
            merged = d
        } else {
            merged = Sighting(
                key: key,
                kind: observation.kind,
                mac: mac,
                name: observation.name,
                rssi: observation.rssi,
                rssiMin: observation.rssi,
                rssiMax: observation.rssi,
                channel: observation.channel,
                frequencyMhz: observation.frequencyMhz,
                vendor: OuiLookup.vendor(mac: mac),
                randomized: MacUtil.isRandomized(mac: mac),
                hiddenSsid: observation.hiddenSsid,
                serviceUuids: observation.serviceUuids,
                manufacturerId: observation.manufacturerId,
                manufacturerDataHex: observation.manufacturerDataHex.take(512),
                rawHex: observation.rawHex.take(1024),
                extras: observation.extras.take(160),
                firstSeen: now,
                lastSeen: now,
                hitCount: 1,
                fleetIds: [],
                rssiHistory: sample.map { [$0] } ?? [],
                presence: [PresenceSpan(start: now, end: nil)],
                latitude: observation.latitude,
                longitude: observation.longitude,
                vendorIeOuis: observation.vendorIeOuis,
                facts: observation.facts,
                gpsTrail: gpsStart(observation),
                fastPairPairing: FastPair.pairingAdvertised(facts: observation.facts)
            )
        }
        live[key] = merged
        if observation.kind == .wifi && observation.fresh {
            lastWifiBatchAt = nowMs()
        }
        return merged
    }

    /// Caller holds `lock`.
    private func relabel(touched: [Sighting], fleets: [Fleet]) {
        if catalogRef == nil || catalogRef! != fleets {
            catalogRef = fleets
            catalogCluster = fleets.contains { $0.minPeers > 0 || $0.clusterByOui || $0.sequentialMac }
            matchStamp.removeAll(keepingCapacity: true)
        }
        let cluster = catalogCluster
        let dirty: [Sighting]
        if cluster || matchStamp.isEmpty {
            dirty = orderedLive()
        } else {
            var out: [Sighting] = []
            out.reserveCapacity(touched.count)
            for d in touched {
                let cur = live[d.key] ?? d
                if matchStamp[cur.key] != matchIdentity(cur) { out.append(cur) }
            }
            dirty = out
        }
        if dirty.isEmpty { return }
        // cluster → dirty already holds every live row, so pool and update are the same list.
        let matches = engine.match(devices: dirty, fleets: fleets)
        for d in dirty {
            guard let cur = live[d.key] else { continue }
            let ids = DeviceStore.orderedIds(matches[cur.key])
            var labeled = cur
            if ids != cur.fleetIds { labeled.fleetIds = ids }
            let next = PayloadLocation.applySticky(device: labeled, fleets: fleets).withLiveDecode(fleets: fleets)
            live[cur.key] = next
            matchStamp[cur.key] = matchIdentity(next)
        }
    }

    // SignatureEngine.match keeps per-device hits in match order. Accept either an ordered array or a Set.
    private static func orderedIds(_ ids: [String]?) -> [String] { ids?.distinct() ?? [] }
    private static func orderedIds(_ ids: Set<String>?) -> [String] { ids.map { $0.sorted() } ?? [] }

    /// Name, vendor IEs, UUIDs, manufacturer payloads — not RSSI / GPS / gone.
    private func matchIdentity(_ device: Sighting) -> String {
        var s = ""
        s.reserveCapacity(64 + device.name.utf8.count + device.vendorIeOuis.count * 10)
        s += device.name
        s += "\u{1}"
        s += device.hiddenSsid ? "H" : "-"
        s += "\u{1}"
        for ie in device.vendorIeOuis { s += ie; s += "," }
        s += "\u{1}"
        for u in device.serviceUuids { s += u; s += "," }
        s += "\u{1}"
        s += String(device.manufacturerId ?? -1)
        s += "\u{1}"
        s += device.manufacturerDataHex
        s += "\u{1}"
        for m in device.facts.mfgRecords { s += String(m.companyId); s += "="; s += m.dataHex; s += "," }
        s += "\u{1}"
        for sd in device.facts.serviceData { s += sd.uuid; s += "="; s += sd.dataHex; s += "," }
        return s
    }

    /// GPS-trailed radios still being heard stay through a plaza flood.
    private func crowdPinned(_ device: Sighting, _ now: Int, _ lingerMs: Int) -> Bool {
        now - device.lastSeen <= lingerMs && device.gpsTrail.count >= 2
    }

    /// Drop unnamed past linger first. Fresh hold-window radios stay until `hardLive`. Caller holds `lock`.
    private func evictOverflow(now: Int, lingerMs: Int) {
        if live.count <= maxLive { return }
        func drop(_ rows: [Sighting], _ count: Int) {
            if count <= 0 { return }
            for d in rows.take(count) {
                live.removeValue(forKey: d.key)
                matchStamp.removeValue(forKey: d.key)
            }
        }
        let unnamed = live.values.filter { $0.fleetIds.isEmpty }
        let expired = unnamed.filter { now - $0.lastSeen > lingerMs }.sortedBy { $0.lastSeen }
        drop(expired, live.count - maxLive)
        if live.count <= maxLive { return }
        if live.count <= hardLive { return }
        let stillUnnamed = live.values.filter { $0.fleetIds.isEmpty && !crowdPinned($0, now, lingerMs) }.sortedBy { $0.lastSeen }
        drop(stillUnnamed, live.count - hardLive)
        if live.count <= hardLive { return }
        let unpinned = live.values.filter { !crowdPinned($0, now, lingerMs) }.sortedBy { $0.lastSeen }
        drop(unpinned, live.count - hardLive)
        if live.count <= hardLive { return }
        drop(orderedLive().sortedBy { $0.lastSeen }, live.count - hardLive)
    }

    public func refresh(
        fleets: [Fleet],
        staleSec: Int,
        tick: RadioObservation? = nil,
        policy: DetectionPolicy = DetectionPolicy(),
        decaySec: Int = 0
    ) {
        lock.lock()
        let snap = refreshLocked(fleets: fleets, staleSec: staleSec, tick: tick, policy: policy, decaySec: decaySec)
        lock.unlock()
        _devices.value = snap.published
        let now = snap.now, staleMs = snap.staleMs, wifiScanFresh = snap.wifiScanFresh
        let wifiHold = snap.wifiHold, bleHold = snap.bleHold, lastWifiBatchAt = snap.lastWifiBatchAt
        let published = snap.published
        _stats.update { prev in
            var s = prev
            s.wifiFrames = prev.wifiFrames + (tick?.kind == .wifi ? 1 : 0)
            s.bleAdvs = prev.bleAdvs + (tick?.kind == .ble ? 1 : 0)
            s.devicesSeen = published.count
            s.namedNow = published.count { !$0.gone && $0.fleetIds.isNotEmpty }
            s.wifiNow = published.count {
                $0.kind == .wifi && (now - $0.lastSeen <= staleMs || !wifiScanFresh || wifiHold)
            }
            s.bleNow = published.count { $0.kind == .ble && (!$0.gone || bleHold) }
            if lastWifiBatchAt > 0 {
                s.lastWifiScanAt = lastWifiBatchAt
            } else if let tick, tick.kind == .wifi, tick.fresh {
                s.lastWifiScanAt = now
            } else {
                s.lastWifiScanAt = prev.lastWifiScanAt
            }
            return s
        }
    }

    private struct RefreshSnapshot {
        var published: [Sighting]
        var now: Int
        var staleMs: Int
        var wifiScanFresh: Bool
        var wifiHold: Bool
        var bleHold: Bool
        var lastWifiBatchAt: Int
    }

    private func refreshLocked(
        fleets: [Fleet],
        staleSec: Int,
        tick: RadioObservation?,
        policy: DetectionPolicy,
        decaySec: Int
    ) -> RefreshSnapshot {
        let now = nowMs()
        let staleMs = staleSec.coerceAtLeast(15) * 1000
        let lingerMs = max(staleMs, decaySec.coerceAtLeast(0) * 1000)
        let wifiScanFresh = lastWifiBatchAt != 0 && now - lastWifiBatchAt <= lingerMs
        let wifiHold = self.wifiHold, bleHold = self.bleHold
        live = live.mapValues { device in
            let gone = !DeviceStore.stillHeard(
                kind: device.kind,
                lastSeen: device.lastSeen,
                alreadyGone: device.gone,
                now: now,
                lingerMs: lingerMs,
                wifiScanFresh: wifiScanFresh,
                wifiHold: wifiHold,
                bleHold: bleHold
            )
            // Kotlin mutates the last span in place (PresenceSpan.end is a var).
            var next = device
            if let li = device.presence.indices.last {
                let last = device.presence[li]
                if gone && last.end == nil {
                    next.presence[li].end = device.lastSeen
                } else if !gone && last.end != nil {
                    next.presence[li].end = nil
                }
            }
            if device.gone != gone { next.gone = gone }
            return next
        }
        relabel(touched: orderedLive(), fleets: fleets)
        let expired = live.values.filter { device in
            let cut = device.fleetIds.isEmpty ? evictAnonMs : evictAfterMs
            return device.lastSeen < now - cut
        }
        for d in expired {
            live.removeValue(forKey: d.key)
            matchStamp.removeValue(forKey: d.key)
        }
        evictOverflow(now: now, lingerMs: lingerMs)
        return RefreshSnapshot(
            published: orderedLive(), now: now, staleMs: staleMs, wifiScanFresh: wifiScanFresh,
            wifiHold: wifiHold, bleHold: bleHold, lastWifiBatchAt: lastWifiBatchAt
        )
    }

    public func setScanning(on: Bool, throttleHint: String = "") {
        _stats.update { var s = $0; s.scanning = on; s.throttleHint = throttleHint; return s }
    }

    public func setScanRadio(
        wifiOn: Bool,
        wifiWaiting: Bool,
        bleOn: Bool,
        bleRunning: Bool,
        bleParked: Bool,
        bleRetrying: Bool,
        bleStarting: Bool,
        bleHitsLastMin: Int
    ) {
        _stats.update {
            var s = $0
            s.wifiRadioOn = wifiOn
            s.wifiWaitingOnOs = wifiWaiting
            s.bleRadioOn = bleOn
            s.bleRunning = bleRunning
            s.bleParked = bleParked
            s.bleRetrying = bleRetrying
            s.bleStarting = bleStarting
            s.bleHitsLastMin = bleHitsLastMin
            return s
        }
    }

    /// Kotlin defaults each flag to its current value; here nil keeps the current value.
    public func setRadioHold(wifi: Bool? = nil, ble: Bool? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let wifi { wifiHold = wifi }
        if let ble { bleHold = ble }
    }

    public func bumpLogs(lines: Int) {
        _stats.update { var s = $0; s.logLines = lines; return s }
    }

    public func clearGpsTrails() {
        lock.lock()
        live = live.mapValues { device in
            if device.gpsTrail.isEmpty && device.latitude == nil && device.longitude == nil { return device }
            var d = device
            d.gpsTrail = []
            d.latitude = nil
            d.longitude = nil
            return d
        }
        let published = orderedLive()
        lock.unlock()
        _devices.value = published
    }

    public func find(key: String) -> Sighting? {
        lock.lock(); defer { lock.unlock() }
        return live[key]
    }

    private func gpsStart(_ observation: RadioObservation) -> [GpsSample] {
        guard let lat = observation.latitude, let lon = observation.longitude else { return [] }
        let rssi = Rssi.measured(rssi: observation.rssi) ? observation.rssi : 0
        return [GpsSample(at: observation.at, lat: lat, lon: lon, rssi: rssi)]
    }

    private func gpsAppend(_ trail: [GpsSample], _ observation: RadioObservation) -> [GpsSample] {
        guard let lat = observation.latitude, let lon = observation.longitude else { return trail }
        let rssi = Rssi.measured(rssi: observation.rssi) ? observation.rssi : 0
        return Geo.append(trail: trail, at: observation.at, lat: lat, lon: lon, rssi: rssi)
    }

    private func mergeMfgHex(_ old: String, _ extra: String) -> String {
        if extra.isBlank { return old }
        if old.isBlank { return extra.take(512) }
        if extra.take(2).equals(old.take(2), ignoreCase: true) && extra.count >= old.count {
            return extra.take(512)
        }
        return old
    }

    private func mergeIes(_ old: [String], _ extra: [String]) -> [String] {
        if extra.isEmpty { return old }
        if old.isEmpty { return extra }
        return (old + extra).distinct()
    }

    /// A late Wi-Fi scan or a BLE restart must not un-gone radios that already aged out.
    /// Hold only keeps currently-live rows from flipping gone.
    public static func stillHeard(
        kind: RadioKind,
        lastSeen: Int,
        alreadyGone: Bool,
        now: Int,
        lingerMs: Int,
        wifiScanFresh: Bool,
        wifiHold: Bool,
        bleHold: Bool
    ) -> Bool {
        if now - lastSeen <= lingerMs { return true }
        switch kind {
        case .wifi: return (wifiHold || !wifiScanFresh) ? !alreadyGone : false
        case .ble: return bleHold ? !alreadyGone : false
        }
    }
}
