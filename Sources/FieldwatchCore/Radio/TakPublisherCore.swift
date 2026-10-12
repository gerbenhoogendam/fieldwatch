import Foundation

// Port of radio/TakPublisher.kt without the socket IO.
//
// Everything the Android class decided (who to send, when, what XML, holds, tombstones, GNSS marks,
// feed status) is here. The datagram IO is behind `TakTransport`.
//
// STILL NEEDED IN THE APP LAYER (Sources/Fieldwatch): a `TakTransport` built on Network.framework:
//  - `resolve(host:)`: name or literal to a numeric address (e.g. getaddrinfo, or NWEndpoint.Host).
//    Return nil when it does not resolve.
//  - `send(address:port:bytes:)`: one UDP datagram. When `TakPublisher.isMulticast(address:)` is true,
//    send with multicast TTL 1 (Android set `timeToLive = 1`), e.g. an NWConnectionGroup /
//    NWMulticastGroup or an NWConnection with `NWParameters.udp` and the IP option `ipOptions.hopLimit = 1`.
//    Unicast: a cached NWConnection per address:port. Return true once the datagram is handed off.
//  - `close()`: cancel cached connections.
// The app calls `publish(...)` from its scan tick (Android did it from the scan coroutine) and `close()`
// when the feed is torn down.

/// UDP datagram sender used by `TakPublisher`.
public protocol TakTransport: AnyObject {
    /// Numeric address for `host`, or nil when it does not resolve (Kotlin `InetAddress.getByName`).
    func resolve(host: String) -> String?
    /// Send one datagram. True when it went out.
    func send(address: String, port: Int, bytes: [UInt8]) -> Bool
    /// Drop sockets / connections.
    func close()
}

public struct TakDestination: Hashable, Sendable {
    public var address: String
    public var port: Int
    public init(address: String, port: Int) { self.address = address; self.port = port }
    public var label: String { "\(address):\(port)" }
}

/// Insertion-ordered map. Kotlin used ConcurrentHashMap (hash order) and LinkedHashMap.
private struct TakOrderedMap<Value> {
    private(set) var keys: [String] = []
    private var dict: [String: Value] = [:]

    var isEmpty: Bool { keys.isEmpty }
    var count: Int { keys.count }
    var values: [Value] { keys.map { dict[$0]! } }

    subscript(key: String) -> Value? {
        get { dict[key] }
        set {
            if let newValue {
                if dict.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if dict.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    mutating func remove(_ key: String) { self[key] = nil }
    mutating func removeAll() { keys.removeAll(); dict.removeAll() }
}

/// Sends Cursor-on-Target UDP to ATAK SA multicast or a unicast host:port.
/// ATAK on the same device often ignores multicast loopback, so unicast also hits
/// 127.0.0.1 on the same port. Privacy mode skips the feed.
public final class TakPublisher: @unchecked Sendable {
    private let transport: TakTransport
    private let lock = NSRecursiveLock()
    private var last = TakOrderedMap<TakSent>()
    /// Radios that left the feed and were resent once with the spot hold.
    private var parked = TakOrderedMap<TakSent>()
    private var gnssMarks = TakOrderedMap<TakGnssTrack>()
    private let _status = MutableStateFlow(TakFeedStatus())
    public var status: StateFlow<TakFeedStatus> { _status }
    /// Android `Log.i` / `Log.w` lines. Nil = silent.
    public var log: ((String) -> Void)?

    public init(transport: TakTransport) { self.transport = transport }

    public func publish(
        devices: [Sighting],
        fleets: [Fleet],
        settings: AppSettings,
        watchlist: [WatchTarget],
        now: Int = nowMs(),
        selfFix: (Double, Double)? = nil,
        gnssRemark: String? = nil,
        gnssNotice: GnssNotice? = nil,
        gnssLives: [GnssLive] = []
    ) {
        lock.lock(); defer { lock.unlock() }
        if !settings.takEnabled || settings.demoMode {
            retractRadios(settings, now)
            if last.isEmpty && parked.isEmpty { gnssMarks.removeAll() }
            _status.value = !settings.takEnabled
                ? TakFeedStatus(detail: "Off")
                : TakFeedStatus(paused: true, detail: "Privacy mode — feed paused")
            return
        }
        let host = settings.takHost.trim().ifBlank(TakDefaults.HOST)
        let port = settings.takPort.coerceIn(1, 65_535)
        let dests = destinations(host: host, port: port)
        if dests.isEmpty {
            log?("TAK host \(host) did not resolve")
            _status.value = TakFeedStatus(at: now, dest: "\(host):\(port)", error: "Host \(host) did not resolve")
            return
        }
        let destLabel = dests.map { $0.label }.joined(separator: ", ")
        let selfOk = selfFix != nil && PayloadLocation.validCoord(lat: selfFix!.0, lon: selfFix!.1)
        var sent = 0
        var gone = 0
        var lastErr: String?

        if selfOk, let selfFix {
            let prev = last[TakPublisher.SELF_UID]
            let gnssLine = gnssRemark?.trim() ?? ""
            let noteChanged = (prev?.note ?? "") != gnssLine
            if noteChanged || TakPublish.shouldEmit(lastAt: prev?.at, lastLat: prev?.lat, lastLon: prev?.lon, now: now,
                                                     lat: selfFix.0, lon: selfFix.1) {
                let xml = CotEvent.selfXml(lat: selfFix.0, lon: selfFix.1, now: now, remarksExtra: gnssLine.nonBlank)
                if sendAll(dests, xml) {
                    last[TakPublisher.SELF_UID] = TakSent(
                        uid: TakPublisher.SELF_UID, deviceKey: TakPublisher.SELF_UID, at: now,
                        lat: selfFix.0, lon: selfFix.1, note: gnssLine
                    )
                    sent += 1
                } else {
                    lastErr = "send failed"
                }
            }
        }

        let gnssFix = selfOk ? selfFix : nil
        let gnssPlan = TakGnss.plan(
            open: gnssMarks.values.first { $0.open },
            mode: settings.takGnss,
            notice: gnssNotice,
            lives: gnssLives,
            lat: gnssFix?.0,
            lon: gnssFix?.1,
            now: now,
            hold: settings.takGnssHold,
            hasMarks: !gnssMarks.isEmpty
        )
        if gnssPlan.clearAll {
            for mark in gnssMarks.values {
                let xml = CotEvent.tombstoneXml(
                    uid: mark.uid,
                    lat: mark.startLat,
                    lon: mark.startLon,
                    now: now,
                    callsign: TakGnss.CALLOUT,
                    remarks: "Where this Mac was. Not the source."
                )
                if sendAll(dests, xml) { gone += 1 } else { lastErr = "send failed" }
            }
            if lastErr == nil { gnssMarks.removeAll() }
        } else {
            var gnssOk = true
            if gnssPlan.send, let drawn = gnssPlan.plot, let gnssUid = gnssPlan.track?.uid {
                let xml = drawn.pin
                    ? CotEvent.gnssPinXml(uid: gnssUid, lat: drawn.lat, lon: drawn.lon, now: now,
                                          staleMs: gnssPlan.staleMs, remarks: gnssPlan.remarks)
                    : CotEvent.gnssOvalXml(uid: gnssUid, lat: drawn.lat, lon: drawn.lon,
                                           semiMajorM: drawn.semiMajorM, semiMinorM: drawn.semiMinorM,
                                           angleDeg: drawn.angleDeg, now: now, staleMs: gnssPlan.staleMs,
                                           remarks: gnssPlan.remarks)
                if sendAll(dests, xml) {
                    sent += 1
                } else {
                    gnssOk = false
                    lastErr = "send failed"
                }
            }
            if gnssOk, let track = gnssPlan.track { gnssMarks[track.uid] = track }
        }

        let chosen = devices
            .filter { TakPublish.eligible(device: $0, settings: settings, fleets: fleets, watchlist: watchlist) }
            .sortedWithComparator { a, b in
                let ra = TakPublish.rank(device: a, fleets: fleets, watchlist: watchlist)
                let rb = TakPublish.rank(device: b, fleets: fleets, watchlist: watchlist)
                if ra != rb { return compareValues(rb, ra) }
                return compareValues(b.rssi, a.rssi)
            }
        var emitted = sent
        for device in chosen {
            if emitted >= TakDefaults.MAX_PER_TICK { break }
            let marks = TakPublish.markers(device: device, settings: settings, fleets: fleets, watchlist: watchlist)
            for mark in marks {
                if emitted >= TakDefaults.MAX_PER_TICK { break }
                let prev = last[mark.uid]
                let lat: Double
                let lon: Double
                let peakRssi: Int
                if mark.advertised || mark.pilot {
                    if !TakPublish.shouldEmit(lastAt: prev?.at, lastLat: prev?.lat, lastLon: prev?.lon, now: now,
                                              lat: mark.lat, lon: mark.lon) {
                        continue
                    }
                    lat = mark.lat
                    lon = mark.lon
                    peakRssi = mark.device.rssi
                } else {
                    switch TakPublish.heardHereAction(lastAt: prev?.at, lastRssi: prev?.rssi, now: now, rssi: mark.device.rssi) {
                    case .skip:
                        continue
                    case .move:
                        lat = mark.lat
                        lon = mark.lon
                        peakRssi = mark.device.rssi
                    case .refresh:
                        guard let held = prev else { continue }
                        lat = held.lat
                        lon = held.lon
                        peakRssi = held.rssi
                    }
                }
                let face = CotEvent.face(device: mark.device, fleets: fleets, watchlist: watchlist,
                                         advertised: mark.advertised, pilot: mark.pilot)
                let xml = CotEvent.render(uid: mark.uid, face: face, lat: lat, lon: lon, now: now, staleMs: TakDefaults.STALE_MS)
                if !sendAll(dests, xml) {
                    lastErr = "send failed"
                    continue
                }
                last[mark.uid] = TakSent(uid: mark.uid, deviceKey: mark.deviceKey, at: now, lat: lat, lon: lon,
                                         rssi: peakRssi, face: face, staleMs: TakDefaults.STALE_MS)
                parked.remove(mark.uid)
                sent += 1
                emitted += 1
            }
        }

        let keep = TakPublish.keepUids(
            devices: devices,
            settings: settings,
            fleets: fleets,
            watchlist: watchlist,
            previous: last.values,
            selfUid: TakPublisher.SELF_UID,
            selfOk: selfOk
        )
        let holdMs = settings.takRadioHold.staleMs()
        var holdBudget = TakDefaults.MAX_PER_TICK
        for uid in last.keys.filter({ !keep.contains($0) }) {
            guard let prev = last[uid] else { continue }
            guard uid != TakPublisher.SELF_UID, let face = prev.face else {
                last.remove(uid)
                continue
            }
            if holdBudget <= 0 { break }
            let xml = CotEvent.render(uid: uid, face: face, lat: prev.lat, lon: prev.lon, now: now, staleMs: holdMs)
            if sendAll(dests, xml) {
                last.remove(uid)
                var held = prev
                held.at = now
                held.staleMs = holdMs
                parked[uid] = held
                sent += 1
                holdBudget -= 1
            } else {
                lastErr = "send failed"
                break
            }
        }
        for spot in parked.values {
            if keep.contains(spot.uid) || spot.staleMs == holdMs { continue }
            guard let face = spot.face else {
                parked.remove(spot.uid)
                continue
            }
            if holdBudget <= 0 { break }
            let xml = CotEvent.render(uid: spot.uid, face: face, lat: spot.lat, lon: spot.lon, now: now, staleMs: holdMs)
            if sendAll(dests, xml) {
                var held = spot
                held.at = now
                held.staleMs = holdMs
                parked[spot.uid] = held
                sent += 1
                holdBudget -= 1
            } else {
                lastErr = "send failed"
                break
            }
        }

        let idle = sent == 0 && gone == 0 && chosen.isEmpty && !selfOk
        if idle && lastErr == nil {
            log?("TAK on, 0 eligible radios (need Extra attention / payload latlon / GPS stamp)")
        }
        if sent > 0 || gone > 0 {
            log?("TAK sent \(sent) marker(s), \(gone) gone to \(destLabel)")
        }
        let detail: String
        if let lastErr { detail = lastErr }
        else if idle { detail = "0 eligible radios (need Extra attention / payload latlon / GPS stamp)" }
        else { detail = "" }
        _status.value = TakFeedStatus(
            at: now,
            sent: sent,
            gone: gone,
            onFeed: last.count,
            dest: destLabel,
            error: lastErr,
            detail: detail
        )
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        transport.close()
        last.removeAll()
        parked.removeAll()
        gnssMarks.removeAll()
        _status.value = TakFeedStatus(detail: "Off")
    }

    /// Feed off or Privacy. Drop radio spots under their own names. GNSS marks are left for ATAK.
    private func retractRadios(_ settings: AppSettings, _ now: Int) {
        if last.isEmpty && parked.isEmpty { return }
        let host = settings.takHost.trim().ifBlank(TakDefaults.HOST)
        let port = settings.takPort.coerceIn(1, 65_535)
        let dests = destinations(host: host, port: port)
        if dests.isEmpty { return }
        var spots = TakOrderedMap<TakSent>()
        for uid in last.keys { spots[uid] = last[uid] }
        for uid in parked.keys where spots[uid] == nil { spots[uid] = parked[uid] }
        for uid in spots.keys {
            let spot = spots[uid]!
            let xml: String
            if let face = spot.face {
                xml = CotEvent.tombstoneXml(uid: uid, lat: spot.lat, lon: spot.lon, now: now,
                                            callsign: face.callsign, remarks: face.remarks)
            } else {
                xml = CotEvent.tombstoneXml(uid: uid, lat: spot.lat, lon: spot.lon, now: now)
            }
            if !sendAll(dests, xml) { return }
            last.remove(uid)
            parked.remove(uid)
        }
    }

    /// Primary destination, plus 127.0.0.1 on the same port when the primary is not loopback.
    public func destinations(host: String, port: Int) -> [TakDestination] {
        TakPublisher.destinations(host: host, port: port, resolve: { [transport] in transport.resolve(host: $0) })
    }

    public static func destinations(host: String, port: Int, resolve: (String) -> String?) -> [TakDestination] {
        guard let primary = resolve(host) else { return [] }
        var out: [TakDestination] = []
        func add(_ addr: String, _ p: Int) {
            let d = TakDestination(address: addr, port: p)
            if !out.contains(d) { out.append(d) }
        }
        add(primary, port)
        if !isLoopback(address: primary), let lo = resolve("127.0.0.1") { add(lo, port) }
        return out
    }

    /// 127.0.0.0/8, ::1, or an IPv4-mapped loopback.
    public static func isLoopback(address: String) -> Bool {
        let a = address.lowercased()
        if a == "::1" || a == "0:0:0:0:0:0:0:1" { return true }
        let v4 = a.hasPrefix("::ffff:") ? String(a.dropFirst(7)) : a
        return v4.split(".").first == "127" && v4.split(".").count == 4
    }

    /// IPv4 224.0.0.0/4 or IPv6 ff00::/8.
    public static func isMulticast(address: String) -> Bool {
        let a = address.lowercased()
        if a.hasPrefix("ff") && a.contains(":") { return true }
        let parts = a.split(".")
        guard parts.count == 4, let first = Int(parts[0]) else { return false }
        return (224...239).contains(first)
    }

    private func sendAll(_ dests: [TakDestination], _ xml: String) -> Bool {
        let bytes = Array(xml.utf8)
        var ok = false
        for d in dests {
            if transport.send(address: d.address, port: d.port, bytes: bytes) {
                ok = true
            } else {
                log?("TAK send \(d.label) failed")
            }
        }
        return ok
    }

    private static let SELF_UID = "FIELDWATCH-SELF"
}
