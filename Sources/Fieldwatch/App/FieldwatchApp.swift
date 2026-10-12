import CoreLocation
import FieldwatchCore
import Foundation
import IOKit.pwr_mgt

/// Port of FieldwatchApp.kt (the Android `Application`): the process-wide runtime.
///
/// Owns the Core stores, the alerter, the TAK feed, the flood detectors, arrivals, the operator GPS path and
/// the Location source. Single instance `FieldwatchApp.shared`; first touch it from the main thread
/// (SwiftUI `App.init`) so CoreLocation gets the main run loop.
///
/// Android-only parts left out: `GnssMonitor` (no GNSS receiver on a Mac; `syncGnss()` is a no-op and there is no
/// `gnss` property), the foreground-service intent plumbing, `scope`.
public final class FieldwatchApp: @unchecked Sendable {
    public static let shared = FieldwatchApp()

    public let config: ConfigStore
    public let devices: DeviceStore
    public let logs: LogStore
    public let sits: SitStore
    public let alerter: Alerter
    public let tak: TakPublisher
    public let pairingFlood = PairingFlood()
    public let wifiFlood = WifiBeaconFlood()
    /// macOS addition: per-radio loudness by this Mac's position, for the Map view's estimates.
    public let positions = PositionField()
    /// Kept so settings packs and Diagnostics can read a saved profile; never filled on a Mac.
    public let gnssProfile: GnssProfileStore
    /// CoreLocation (replaces the Android GPS + network listeners).
    public let location: LocationSource
    /// Bumped whenever Location authorization / Location Services change (Android PROVIDERS_CHANGED broadcast).
    public let locationEpoch = MutableStateFlow(0)

    /// Bluetooth bursts, Wi-Fi bursts, or both in time order.
    public func floodBursts() -> [FloodBurst] {
        let ble = pairingFlood.bursts()
        let wifi = wifiFlood.bursts()
        if wifi.isEmpty { return ble }
        if ble.isEmpty { return wifi }
        return (ble + wifi).sortedBy { $0.at }
    }

    private let filters = FilterEngine()
    private let _arrivals = MutableStateFlow(ArrivalsState())
    public var arrivals: StateFlow<ArrivalsState> { _arrivals }
    private let arrivalsLock = NSLock()
    /// Insertion order of `ArrivalsState.knownKeys` (Kotlin LinkedHashSet order) for the trim.
    private var knownOrder: [String] = []
    private var wifiLearnPending = false
    private var persistArrivalsAt = 0
    private let persistQueue = DispatchQueue(label: "app.fieldwatch.persist", qos: .utility)

    private let fixLock = NSLock()
    private var _lastFix: (Double, Double)?
    private var _lastFixAt = 0
    private var speedMps: Double?
    private var speedAt = 0

    /// Latest accepted operator fix (lat, lon). Kotlin `Pair<Double, Double>?`.
    public var lastFix: (Double, Double)? {
        get { fixLock.lock(); defer { fixLock.unlock() }; return _lastFix }
        set { fixLock.lock(); _lastFix = newValue; fixLock.unlock() }
    }

    /// Epoch ms of `lastFix` (the fix's own time).
    public var lastFixAt: Int {
        get { fixLock.lock(); defer { fixLock.unlock() }; return _lastFixAt }
        set { fixLock.lock(); _lastFixAt = newValue; fixLock.unlock() }
    }

    private let pathLock = NSLock()
    private var operatorPath: [GpsSample] = []
    private var pathLengthM = 0.0
    private var locating = false

    private let serviceLock = NSLock()
    private var scanService: ScanService?

    private init() {
        config = ConfigStore()
        DispatchQueue.global(qos: .utility).async { RadioDb.initialize() }
        devices = DeviceStore()
        logs = LogStore()
        sits = SitStore()
        alerter = Alerter()
        tak = TakPublisher(transport: NetworkTakTransport())
        gnssProfile = GnssProfileStore()
        location = LocationSource()

        config.load()
        logs.configure(format: config.settings.logFormat, rotateKb: config.settings.logRotateKb, loggingOn: config.settings.loggingEnabled)
        sits.load()
        let sitOpen = sits.ui.value.open != nil
        pairingFlood.setSitOpen(open: sitOpen)
        wifiFlood.setSitOpen(open: sitOpen)
        sits.startFlusher()

        location.onFix = { [weak self] loc in self?.acceptFix(loc: loc) }
        location.onAuthorizationChange = { [weak self] _ in
            guard let self else { return }
            self.locationEpoch.update { $0 + 1 }
            self.syncLocationUpdates()
        }
        syncLocationUpdates()
        if config.settings.alertVoice || config.settings.gnssVoice { alerter.prepareVoice() }
        if config.filter.arrivalsOnly {
            beginArrivals(keepRemembered: true)
        }
    }

    // MARK: Arrivals

    public func beginArrivals(keepRemembered: Bool = false) {
        let remembered = keepRemembered ? config.config.value.arrivalKnownKeys : []
        let liveKeys = devices.devices.value.map { $0.key }
        let now = nowMs()
        arrivalsLock.lock()
        wifiLearnPending = true
        knownOrder = (remembered + liveKeys).distinct()
        let st = ArrivalsState(
            active: true,
            knownKeys: Set(knownOrder),
            learningUntil: now + 90_000,
            bufferStartedAt: now
        )
        let order = knownOrder
        arrivalsLock.unlock()
        _arrivals.value = st
        persistArrivalKeys(keys: order)
    }

    public func resetSeenBuffer() {
        arrivalsLock.lock()
        wifiLearnPending = false
        knownOrder = []
        arrivalsLock.unlock()
        alerter.forgetAnnounced()
        _arrivals.value = ArrivalsState(active: true, knownKeys: [], learningUntil: 0, bufferStartedAt: nowMs())
        persistArrivalKeys(keys: [])
    }

    public func clearArrivals() {
        arrivalsLock.lock()
        wifiLearnPending = false
        knownOrder = []
        arrivalsLock.unlock()
        _arrivals.value = ArrivalsState()
        persistArrivalKeys(keys: [])
    }

    public func markArrivalsSeen(keys: [String]? = nil) {
        if !_arrivals.value.active { return }
        rememberKeys(keys: keys ?? devices.devices.value.map { $0.key })
        arrivalsLock.lock(); wifiLearnPending = false; arrivalsLock.unlock()
        _arrivals.update { var s = $0; s.learningUntil = 0; return s }
    }

    public func onFreshWifiBatch() {
        arrivalsLock.lock()
        let pending = wifiLearnPending
        arrivalsLock.unlock()
        if !_arrivals.value.active || !pending { return }
        let wifiKeys = devices.devices.value.filter { $0.kind == .wifi }.map { $0.key }
        rememberKeys(keys: wifiKeys)
        arrivalsLock.lock(); wifiLearnPending = false; arrivalsLock.unlock()
        _arrivals.update { var s = $0; s.learningUntil = 0; return s }
    }

    private func rememberKeys(keys: [String]) {
        let st = _arrivals.value
        if !st.active || keys.isEmpty { return }
        arrivalsLock.lock()
        var added = false
        var have = st.knownKeys
        for k in keys where !have.contains(k) {
            have.insert(k)
            knownOrder.append(k)
            added = true
        }
        if !added { arrivalsLock.unlock(); return }
        if knownOrder.count > FieldwatchApp.MAX_ARRIVAL_KEYS {
            knownOrder = knownOrder.takeLast(FieldwatchApp.MAX_ARRIVAL_KEYS)
            have = Set(knownOrder)
        }
        let order = knownOrder
        arrivalsLock.unlock()
        var next = st
        next.knownKeys = have
        _arrivals.value = next
        persistArrivalKeys(keys: order)
    }

    /// `keys` oldest first (Kotlin persisted the LinkedHashSet in insertion order).
    private func persistArrivalKeys(keys: [String]) {
        let k = keys
        persistArrivalsAt = nowMs()
        persistQueue.async {
            self.config.update { c in
                var n = c
                n.arrivalKnownKeys = k
                return n
            }
        }
    }

    public func syncArrivals(on: Bool) {
        if on {
            if !_arrivals.value.active { beginArrivals(keepRemembered: false) }
        } else if _arrivals.value.active {
            clearArrivals()
        }
    }

    public func isHiddenByArrivals(device: Sighting) -> Bool {
        if !config.filter.arrivalsOnly { return false }
        let st = _arrivals.value
        if !st.active { return false }
        let learning = nowMs() <= st.learningUntil
        return st.knownKeys.contains(device.key) || (learning && device.kind == .wifi)
    }

    public func wouldShowOnLive(device: Sighting) -> Bool {
        if device.gone { return false }
        let bleHidden = pairingFlood.hide.value.keys
        let wifiHidden = wifiFlood.hide.value.keys
        if (bleHidden.isNotEmpty && bleHidden.contains(device.key)) ||
            (wifiHidden.isNotEmpty && wifiHidden.contains(device.key)) { return false }
        let filter = config.filter
        let travel = filter.movingWithYou ? CoTravel.Ctx.of(path: operatorPathCopy()) : CoTravel.Ctx.None
        var classById: [String: SignatureClass] = [:]
        for f in config.fleets { classById[f.id] = f.kind }
        let watchlist = config.watchlist
        if !filters.pass(
            device: device,
            filter: filter,
            travel: travel,
            classByFleetId: classById,
            namedRadioKeys: RadioBookmarks.namedKeys(watchlist: watchlist),
            watchedFleetIds: RadioBookmarks.watchedFleetIds(watchlist: watchlist),
            alertDeviceKeys: RadioBookmarks.alertDeviceKeys(watchlist: watchlist),
            mineKeys: RadioBookmarks.mineKeys(watchlist: watchlist)
        ) { return false }
        if isHiddenByArrivals(device: device) { return false }
        return true
    }

    // MARK: Scanning

    /// Kotlin `startForegroundService(ScanService)`. Idempotent.
    public func startScanning() {
        serviceLock.lock()
        let svc: ScanService
        if let s = scanService {
            svc = s
        } else {
            svc = ScanService(app: self)
            scanService = svc
        }
        serviceLock.unlock()
        svc.start()
    }

    public func stopScanning() {
        serviceLock.lock()
        let svc = scanService
        scanService = nil
        serviceLock.unlock()
        svc?.stop()
    }

    public func isScanning() -> Bool {
        serviceLock.lock(); defer { serviceLock.unlock() }
        return scanService?.isRunning() == true
    }

    // MARK: Location

    /// Location Services switched on for the Mac (Android `LocationManager.isLocationEnabled`).
    public func systemLocationOn() -> Bool { location.servicesEnabled() }

    public func gpsFixAgeMs(now: Int) -> Int? {
        let at = lastFixAt
        return at <= 0 ? nil : max(0, now - at)
    }

    /// Location permission for Fieldwatch (Android ACCESS_FINE_LOCATION).
    public func hasFineLocation() -> Bool { location.isAuthorized() }

    /// Tag detections with GPS on → run CoreLocation; off → stop. While scanning, an unanswered permission is asked.
    public func syncLocationUpdates() {
        if config.settings.tagLocation && hasFineLocation() {
            startLocationUpdates()
        } else {
            stopLocationUpdates()
            if config.settings.tagLocation && location.currentAccess() == .notDetermined && isScanning() {
                location.requestAuthorization()
            }
        }
    }

    public func startLocationUpdates() {
        pathLock.lock()
        if locating || !hasFineLocation() { pathLock.unlock(); return }
        locating = true
        pathLock.unlock()
        seedLastKnown()
        location.start()
    }

    public func stopLocationUpdates() {
        pathLock.lock()
        if !locating { pathLock.unlock(); return }
        locating = false
        pathLock.unlock()
        location.stop()
    }

    /// Android GNSS interference check. No GNSS receiver on a Mac.
    public func syncGnss() {}

    public func refreshFix() {
        if !hasFineLocation() { return }
        seedLastKnown()
    }

    private func seedLastKnown() {
        guard let loc = location.lastKnown() else { return }
        let now = nowMs()
        let t = FieldwatchApp.ms(loc.timestamp)
        if now - t >= 30_000 { return }
        if loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy > 75 { return }
        if t <= lastFixAt { return }
        acceptFix(loc: loc)
    }

    private func acceptFix(loc: CLLocation) {
        // horizontalAccuracy < 0 = invalid / no accuracy (Android !hasAccuracy()).
        if loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy > 75 { return }
        if loc.horizontalAccuracy < 0 && !CLLocationCoordinate2DIsValid(loc.coordinate) { return }
        let t = FieldwatchApp.ms(loc.timestamp)
        let age = nowMs() - t
        if age > 30_000 { return }
        let lat = loc.coordinate.latitude
        let lon = loc.coordinate.longitude
        fixLock.lock()
        _lastFix = (lat, lon)
        _lastFixAt = t
        if loc.speed >= 0 && loc.speed.isFinite {
            let loose = loc.speedAccuracy >= 0 && loc.speedAccuracy > 4
            if !loose {
                speedMps = loc.speed
                speedAt = nowMs()
            }
        }
        fixLock.unlock()
        recordOperatorFix(lat: lat, lon: lon, at: t)
    }

    /// GPS speed in m/s, or nil when the latest fix has no usable speed.
    public func floodSpeed(now: Int = nowMs()) -> Double? {
        fixLock.lock(); defer { fixLock.unlock() }
        guard let speed = speedMps else { return nil }
        if now - speedAt > 12_000 { return nil }
        return speed
    }

    public func recordOperatorFix(lat: Double, lon: Double, at: Int = nowMs()) {
        pathLock.lock()
        if let last = operatorPath.last {
            if !Geo.hopPlausible(from: last, lat: lat, lon: lon, at: at) {
                pathLock.unlock()
                return
            }
            if Geo.meters(lat1: last.lat, lon1: last.lon, lat2: lat, lon2: lon) < 15.0 {
                operatorPath[operatorPath.count - 1] = GpsSample(at: at, lat: lat, lon: lon)
            } else {
                pathLengthM += Geo.meters(lat1: last.lat, lon1: last.lon, lat2: lat, lon2: lon)
                appendPath(GpsSample(at: at, lat: lat, lon: lon))
            }
        } else {
            appendPath(GpsSample(at: at, lat: lat, lon: lon))
        }
        pathLock.unlock()
        sits.recordPath(lat: lat, lon: lon, at: at)
    }

    /// pathLock held.
    private func appendPath(_ s: GpsSample) {
        operatorPath.append(s)
        if operatorPath.count > 80 {
            operatorPath.removeFirst()
            pathLengthM = Geo.pathLengthM(samples: operatorPath)
        }
    }

    public func operatorPathCopy() -> [GpsSample] {
        pathLock.lock(); defer { pathLock.unlock() }
        return operatorPath
    }

    public func operatorPathLengthM() -> Double {
        pathLock.lock(); defer { pathLock.unlock() }
        return pathLengthM
    }

    public func resetFollowSession() {
        pathLock.lock()
        operatorPath.removeAll()
        pathLengthM = 0
        pathLock.unlock()
        devices.clearGpsTrails()
    }

    private static func ms(_ d: Date) -> Int { Int((d.timeIntervalSince1970 * 1000).rounded(.down)) }

    // MARK: Companion

    public static let MAX_ARRIVAL_KEYS = 2_500
}

public struct ArrivalsState: Hashable, Sendable {
    public var active: Bool
    public var knownKeys: Set<String>
    public var learningUntil: Int
    public var bufferStartedAt: Int

    public init(active: Bool = false, knownKeys: Set<String> = [], learningUntil: Int = 0, bufferStartedAt: Int = 0) {
        self.active = active; self.knownKeys = knownKeys; self.learningUntil = learningUntil; self.bufferStartedAt = bufferStartedAt
    }
}

/// Keep the display awake (Android Keep screen on / FLAG_KEEP_SCREEN_ON) with an IOPM
/// PreventUserIdleDisplaySleep assertion. The UI sets `DisplayAwake.shared.held` while Live or Hunt is visible
/// and `settings.keepScreenOn` is on. Safe from any thread.
public final class DisplayAwake: @unchecked Sendable {
    public static let shared = DisplayAwake()

    private let lock = NSLock()
    private var assertion: IOPMAssertionID = 0
    private var holding = false

    private init() {}

    /// True while the display-sleep assertion is held. Setting it creates or releases the assertion.
    public var held: Bool {
        get { lock.lock(); defer { lock.unlock() }; return holding }
        set { DisplayAwake.apply(self, on: newValue) }
    }

    /// Same as setting `shared.held`.
    public static func set(on: Bool) { shared.held = on }

    private static func apply(_ d: DisplayAwake, on: Bool) {
        d.lock.lock(); defer { d.lock.unlock() }
        if on == d.holding { return }
        if on {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Fieldwatch Live display" as CFString,
                &id
            )
            if r == kIOReturnSuccess {
                d.assertion = id
                d.holding = true
            }
        } else {
            IOPMAssertionRelease(d.assertion)
            d.assertion = 0
            d.holding = false
        }
    }
}
