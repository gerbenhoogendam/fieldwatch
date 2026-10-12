import CoreWLAN
import FieldwatchCore
import Foundation

/// CoreWLAN port of radio/WifiRadio.kt.
///
/// `scanForNetworks(withSSID: nil)` blocks for 1–4 s, so it runs on a private serial queue. Each completed scan
/// is one fresh batch (every observation `fresh = true`), handed to `onObservation` one by one and to
/// `onFreshScan` as a list, like Android's SCAN_RESULTS_AVAILABLE batch.
///
/// macOS has no 4-scans-per-2-minutes quota. Cadence comes from the caller (`intervalMs(intensity:)`:
/// performance ~10 s, balanced ~20 s, saver ~45 s). Without Location permission CoreWLAN returns networks with
/// nil BSSID/SSID; those are skipped and the hint says "Wi-Fi waiting on Location".
public final class WifiRadio: @unchecked Sendable {
    private let onObservation: (RadioObservation) -> Void
    private let onScanFinished: (Int, Bool) -> Void
    private let onFreshScan: ([RadioObservation]) -> Void

    private let scanQueue = DispatchQueue(label: "app.fieldwatch.wifi", qos: .utility)
    private let lock = NSLock()
    private var registered = false
    private var awaitingScan = false
    private var nextAllowedAt = 0
    private var failStreak = 0
    private var needsLocation = false
    private var poweredOff = false
    private var noInterface = false
    private var lastScanAt = 0
    private var lastError: String?
    private var generation = 0

    public init(
        onObservation: @escaping (RadioObservation) -> Void,
        onScanFinished: @escaping (Int, Bool) -> Void,
        onFreshScan: @escaping ([RadioObservation]) -> Void = { _ in }
    ) {
        self.onObservation = onObservation
        self.onScanFinished = onScanFinished
        self.onFreshScan = onFreshScan
    }

    public func start() {
        lock.lock()
        if registered { lock.unlock(); return }
        registered = true
        generation += 1
        lock.unlock()
        requestScan(minIntervalMs: 0, unthrottled: true)
    }

    public func stop() {
        lock.lock()
        registered = false
        awaitingScan = false
        generation += 1
        lock.unlock()
    }

    /// Ask for a scan unless one is running or the interval since the last start has not passed.
    /// Returns true when a scan was started. `unthrottled` is kept for the Kotlin signature; macOS has no OS quota.
    @discardableResult
    public func requestScan(minIntervalMs: Int = 30_000, unthrottled: Bool = false) -> Bool {
        let now = nowMs()
        lock.lock()
        if !registered || awaitingScan || now < nextAllowedAt {
            lock.unlock()
            return false
        }
        guard let iface = CWWiFiClient.shared().interface() else {
            noInterface = true
            poweredOff = false
            nextAllowedAt = now + 10_000
            lock.unlock()
            return false
        }
        noInterface = false
        if !iface.powerOn() {
            poweredOff = true
            nextAllowedAt = now + 5_000
            lock.unlock()
            return false
        }
        poweredOff = false
        awaitingScan = true
        lastScanAt = now
        let floor = unthrottled ? 2_000 : WifiRadio.FAST_INTERVAL_MS
        nextAllowedAt = now + max(minIntervalMs, floor)
        let gen = generation
        lock.unlock()

        scanQueue.async { [weak self] in self?.runScan(iface: iface, generation: gen) }
        return true
    }

    public func radioOn() -> Bool {
        guard let iface = CWWiFiClient.shared().interface() else { return false }
        return iface.powerOn()
    }

    /// Wi-Fi is up but unusable: scans failing, or BSSIDs hidden until Location is allowed.
    public func waitingOnOs() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return failStreak > 0 || needsLocation
    }

    /// CoreWLAN hid every BSSID on the last scan (Location not authorized for this app).
    public func waitingOnLocation() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return needsLocation
    }

    public func lastErrorText() -> String? {
        lock.lock(); defer { lock.unlock() }
        return lastError
    }

    public func throttleHint() -> String {
        let now = nowMs()
        lock.lock(); defer { lock.unlock() }
        if noInterface { return "Wi-Fi unavailable" }
        if poweredOff { return "Wi-Fi is off" }
        if needsLocation { return "Wi-Fi waiting on Location" }
        if failStreak > 0 { return "Wi-Fi waiting on OS" }
        if awaitingScan { return "Wi-Fi scanning" }
        if nextAllowedAt - now > 1_500 {
            let sec = max(1, (nextAllowedAt - now + 999) / 1000)
            return "Wi-Fi next \(sec)s"
        }
        return ""
    }

    // MARK: Scan

    private func runScan(iface: CWInterface, generation gen: Int) {
        let started = nowMs()
        var networks: Set<CWNetwork> = []
        var error: Error?
        do {
            networks = try iface.scanForNetworks(withSSID: nil)
        } catch let e {
            error = e
        }
        let nowWall = nowMs()

        lock.lock()
        guard gen == generation, registered else {
            awaitingScan = false
            lock.unlock()
            return
        }
        awaitingScan = false
        if let error {
            let streak = min(failStreak + 1, 4)
            failStreak = streak
            let backoff = min(8_000 * (1 << (streak - 1)), 45_000)
            nextAllowedAt = max(nextAllowedAt, nowWall + backoff)
            lastError = error.localizedDescription
            lock.unlock()
            onScanFinished(0, false)
            return
        }
        failStreak = 0
        lastError = nil
        let hidden = networks.filter { $0.bssid.isNullOrBlank }.count
        needsLocation = !networks.isEmpty && hidden == networks.count
        lock.unlock()

        // Empty lists are ignored: the last AP set stays on screen until a real batch arrives.
        if networks.isEmpty { return }

        let at = max(started, nowWall)
        var batch: [RadioObservation] = []
        batch.reserveCapacity(networks.count)
        // CoreWLAN returns an unordered Set; sort so each batch (and flood keys) has a stable order.
        for net in networks.sorted(by: { ($0.bssid ?? "") < ($1.bssid ?? "") }) {
            guard let obs = WifiRadio.toObservation(net, at: at) else { continue }
            batch.append(obs)
            onObservation(obs)
        }
        onScanFinished(batch.count, true)
        if batch.isNotEmpty { onFreshScan(batch) }
    }

    // MARK: RadioObservation

    static func toObservation(_ net: CWNetwork, at: Int) -> RadioObservation? {
        guard let rawBssid = net.bssid, rawBssid.isNotBlank else { return nil }
        let bssid = normalizeBssid(rawBssid)
        let ssid = cleanSsid(net)
        let hidden = ssid.isBlank
        let chan = net.wlanChannel
        let reported = chan?.channelNumber ?? 0
        let band = bandOf(chan)
        let ies = net.informationElementData.map { [UInt8]($0) } ?? []
        let parsed = WifiIeParser.parse(ies: ies)
        let channel = parsed.channelFromDs ?? reported
        let freq = WifiIeParser.frequencyOf(channel: reported > 0 ? reported : channel, band: band)
        let caps: String? = ies.isEmpty
            ? securityFallback(net)
            : WifiIeParser.capabilitiesString(parsed: parsed, ibss: net.ibss, privacy: net.supportsSecurity(.WEP)).nonBlank
                ?? securityFallback(net)
        let bandArg: Int? = band == 0 ? nil : band
        let facts = RadioFacts(
            wifiStandard: ies.isEmpty ? nil : WifiIeParser.wifiStandardLabel(ies: ies, band: bandArg),
            channelWidth: (ies.isEmpty ? nil : WifiIeParser.channelWidthLabel(ies: ies, channel: channel, band: bandArg))
                ?? widthLabel(chan),
            centerFreq0: nil,
            centerFreq1: nil,
            capabilities: caps?.nonBlank,
            supportedRates: parsed.rates,
            security: parsed.security ?? caps?.nonBlank,
            vendorIes: parsed.vendorIes
        )
        return RadioObservation(
            kind: .wifi,
            mac: bssid,
            name: ssid,
            rssi: net.rssiValue,
            channel: channel,
            frequencyMhz: freq,
            hiddenSsid: hidden,
            serviceUuids: [],
            manufacturerId: nil,
            manufacturerDataHex: "",
            rawHex: "",
            extras: "",
            at: at,
            fresh: true,
            vendorIeOuis: parsed.vendorIes.map { $0.oui }.distinct(),
            facts: facts
        )
    }

    /// CoreWLAN prints "a4:2b:b0:1:2:3" (no leading zeros, lower case). Fieldwatch keys are "A4:2B:B0:01:02:03".
    static func normalizeBssid(_ raw: String) -> String {
        let parts = raw.trim().split(":")
        if parts.count == 6 && parts.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy { $0.isHexDigit } }) {
            return parts.map { $0.uppercased().padStart(2, "0") }.joined(separator: ":")
        }
        return MacUtil.normalize(raw: raw)
    }

    static func cleanSsid(_ net: CWNetwork) -> String {
        let raw = net.ssid ?? net.ssidData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let s = raw.trim().trim("\"")
        return s == "<unknown ssid>" ? "" : s
    }

    /// 2 / 5 / 6 (GHz) for `WifiIeParser.frequencyOf`, 0 when unknown.
    static func bandOf(_ chan: CWChannel?) -> Int {
        guard let chan else { return 0 }
        switch chan.channelBand.rawValue {
        case 1: return 2
        case 2: return 5
        case 3: return 6
        default:
            let n = chan.channelNumber
            if n >= 1 && n <= 14 { return 2 }
            if n >= 32 && n <= 177 { return 5 }
            return 0
        }
    }

    static func widthLabel(_ chan: CWChannel?) -> String? {
        guard let chan else { return nil }
        switch chan.channelWidth {
        case .width20MHz: return "20 MHz"
        case .width40MHz: return "40 MHz"
        case .width80MHz: return "80 MHz"
        case .width160MHz: return "160 MHz"
        default: return nil
        }
    }

    /// Android-style capabilities when CoreWLAN gave no IEs, from `supportsSecurity`.
    static func securityFallback(_ net: CWNetwork) -> String? {
        let table: [(CWSecurity, String)] = [
            (.wpa3Enterprise, "WPA3-EAP"), (.wpa3Personal, "WPA3-SAE"), (.wpa3Transition, "WPA3-SAE+PSK"),
            (.wpa2Enterprise, "WPA2-EAP"), (.wpa2Personal, "WPA2-PSK"), (.wpaEnterprise, "WPA-EAP"),
            (.wpaPersonal, "WPA-PSK"), (.OWE, "OWE"), (.oweTransition, "OWE-TRANSITION"),
            (.dynamicWEP, "WEP-DYNAMIC"), (.WEP, "WEP"),
        ]
        let tags = table.filter { net.supportsSecurity($0.0) }.map { "[\($0.1)]" }
        if tags.isEmpty { return net.supportsSecurity(.none) ? "[ESS]" : nil }
        return tags.joined() + "[ESS]"
    }

    // MARK: Companion

    public static let FAST_INTERVAL_MS = 8_000

    /// Mac Wi-Fi scan cadence by intensity.
    public static func intervalMs(intensity: ScanIntensity) -> Int {
        switch intensity {
        case .performance: return 10_000
        case .balanced: return 20_000
        case .saver: return 45_000
        }
    }

    /// Android-only OS throttle. macOS never throttles CoreWLAN scans this way.
    public static func osScanThrottled() -> Bool { false }

    public static func channelOf(freq: Int) -> Int {
        if freq >= 2412 && freq <= 2484 { return freq == 2484 ? 14 : (freq - 2407) / 5 }
        if freq >= 5000 && freq <= 5895 { return (freq - 5000) / 5 }
        if freq >= 5955 && freq <= 7115 { return (freq - 5955) / 5 + 1 }
        return 0
    }
}
