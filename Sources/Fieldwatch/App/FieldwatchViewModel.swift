import AppKit
import Foundation
import Observation
import SwiftUI
import FieldwatchCore

// Port of ui/FieldwatchViewModel.kt.
//
// Kotlin StateFlows become `private(set) var` properties kept current on the main actor:
// - Core / runtime MutableStateFlows are observed (`observe { }` runs on the writer's thread) and every
//   change hops to the main queue, coalesced per source (StateFlow conflation).
// - The heavy live pass (filter + sort of every radio, the `liveUi` combine) runs on a background queue
//   from main-actor snapshots, at most every LIVE_MIN_INTERVAL_S (Kotlin re-ran it per device batch plus a
//   1 s clock). Local edits (select, settings, filters) schedule it immediately.
// - `ui` (Kotlin combine(liveUi, displayPaused, selectedKey, heldSelected, sits.ui)) is recomputed on the
//   main actor; while displayPaused, `ui.devices` / `ui.filtered` stay frozen exactly as in Kotlin.
//
// Android → macOS: Intent shares → `ShareItem` in `export.share`; Uri → URL; Application → FieldwatchApp.shared.
// GNSS has no receiver on a Mac: gnss members keep their names with constant "unavailable" values.

/// A finished export for the share sheet. `urls` are files under the export folder; `text` is the
/// Android EXTRA_TEXT body for text shares (the same text is also written to a .txt in `urls`).
struct ShareItem: Identifiable { let id = UUID(); var urls: [URL]; var text: String?; var title: String }

struct CandidatesUi {
    var loading: Bool = false
    var report: CandidateReport? = nil
    var error: String? = nil
}

private struct FamilyLogSnap {
    var radios: [LogRadio] = []
    var loaded: Bool = false
}

struct PendingSettingsImport {
    var pack: SettingsPack
    var message: String
}

struct ExportUi {
    var active: Bool = false
    var progress: Double = 0
    /// True: spinning wait (Debrief / AI Export). False: determinate bar (log).
    var spinner: Bool = false
    var message: String = ""
    var share: ShareItem? = nil
    var shareTitle: String = "Export Fieldwatch logs"
    var error: String? = nil
    var errorTitle: String? = nil
    var cleared: Bool = false
    var saved: Bool = false
    var noticeTitle: String? = nil
    var noticeMessage: String? = nil
    /// Shown after the user dismisses `noticeTitle`. Catalog import skip-decode only.
    var followUpTitle: String? = nil
    var followUpMessage: String? = nil
}

struct FieldwatchUi {
    var devices: [Sighting] = []
    var filtered: [Sighting] = []
    var fleets: [Fleet] = []
    var filter: FilterState = FilterState()
    var presets: [FilterPreset] = []
    var watchlist: [WatchTarget] = []
    var settings: AppSettings = AppSettings()
    var selected: Sighting? = nil
    var draftFleet: Fleet? = nil
    var permissionsOk: Bool = false
    var scanning: Bool = false
    var wifiNow: Int = 0
    var bleNow: Int = 0
    var namedNow: Int = 0
    var logLines: Int = 0
    var throttleHint: String = ""
    var scanRadio: ScanRadioFacts = ScanRadioFacts()
    var scanBlocked: Bool = false
    /// System Location services. Live uses this for the banner, separate from a blocked scan.
    var locationOn: Bool = true
    var hiddenKnown: Int = 0
    var arrivalsLearning: Bool = false
    var displayPaused: Bool = false
    var operatorSpanM: Double = 0.0
    var takStatus: TakFeedStatus = TakFeedStatus()
    var sit: SitUi = SitUi()
    var catalogVersion: Int = 0
}

struct BeepSnap: Equatable {
    var seq: Int = 0
    var key: String = ""
}

struct HuntUi: Equatable {
    var active: Bool = false
    var device: Sighting? = nil
    var title: String = ""
    var cue: HuntCue = .waiting
    var peakRssi: Int = -127
    var samples: [RssiSample] = []
    var lastSeen: Int = 0
}

/// Kotlin `error("...")` / IllegalStateException with a user-facing message.
private struct VmError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Lock-protected "hop already queued" flag: coalesces bursts of flow emissions into one main-queue hop.
private final class HopGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    func arm() -> Bool { lock.lock(); defer { lock.unlock() }; if armed { return false }; armed = true; return true }
    func disarm() { lock.lock(); armed = false; lock.unlock() }
}

/// Main-actor snapshot fed to the background live pass.
private struct LiveSnap {
    var devices: [Sighting]
    var stats: ScanStats
    var config: PersistedConfig
    var sel: String?
    var draft: Fleet?
    var arr: ArrivalsState
    var now: Int
    var alerts: [String: Int]
    var takStatus: TakFeedStatus
    var hide: PairingFlood.FloodHide
    var permissionsOk: Bool
    var locationOn: Bool
    var hasFineLocation: Bool
    /// Only when Moving with you is on (Kotlin built CoTravel.Ctx from operatorPathCopy then).
    var operatorPath: [GpsSample]?
    var operatorPathLengthM: Double
    var held: Sighting?
    var familyLog: FamilyLogSnap
}

private struct LiveOut {
    var ui: FieldwatchUi
    var familyHint: SignatureFamilyHint?
}

/// Inputs for the Reports → Path model, captured on the main actor.
private struct SitPathSnap {
    var now: Int
    var sits: SitStore
    var watchlist: [WatchTarget]
    var fleets: [Fleet]
    var tagging: Bool
    var onlineLookup: Bool
    var liveDevices: [Sighting]
    var operatorPath: [GpsSample]
    var sitOpen: Bool
}

private struct SitExportWindow {
    var name: String
    var devices: [Sighting]
    var path: [GpsSample]
}

@MainActor
@Observable
final class FieldwatchViewModel {
    let app: FieldwatchApp
    @ObservationIgnored private let filters = FilterEngine()
    @ObservationIgnored private let signatures = SignatureEngine()

    // MARK: Kotlin private flows (inputs)

    @ObservationIgnored private var selectedKey: String?
    @ObservationIgnored private var draft: Fleet?
    @ObservationIgnored private var draftFromCandidates = false
    @ObservationIgnored private var pathRadios: [Sighting] = []
    @ObservationIgnored private var flashUntil: [String: Int] = [:]
    @ObservationIgnored private var lastAlertAt: [String: Int] = [:]
    @ObservationIgnored private var clock: Int = nowMs()
    @ObservationIgnored private var locationEpoch = 0
    @ObservationIgnored private var displayPaused = false
    @ObservationIgnored private var heldSelected: Sighting?
    @ObservationIgnored private var familyLog = FamilyLogSnap()
    @ObservationIgnored private var huntKey: String?
    @ObservationIgnored private var huntStartedAt = 0
    @ObservationIgnored private var huntPeakRssi = -127
    @ObservationIgnored private var huntSamples: [RssiSample] = []
    @ObservationIgnored private var frozenUi: FieldwatchUi?
    @ObservationIgnored private var liveUi: FieldwatchUi

    // MARK: Plumbing

    @ObservationIgnored private var tokens: [FlowToken] = []
    @ObservationIgnored private var clockTimer: DispatchSourceTimer?
    @ObservationIgnored private let liveQueue = DispatchQueue(label: "app.fieldwatch.vm.live", qos: .userInitiated)
    @ObservationIgnored private let pathQueue = DispatchQueue(label: "app.fieldwatch.vm.path", qos: .utility)
    @ObservationIgnored private var liveWork: DispatchWorkItem?
    @ObservationIgnored private var liveRunning = false
    @ObservationIgnored private var liveAgain = false
    @ObservationIgnored private var liveAgainUrgent = false
    @ObservationIgnored private var lastLiveAt: TimeInterval = 0
    @ObservationIgnored private var pathRunning = false
    @ObservationIgnored private var pathAgain = false
    @ObservationIgnored private var lastSitKey = ""
    @ObservationIgnored private var sitPathScheduled = false
    @ObservationIgnored private var lastSitPathAt: TimeInterval = 0
    /// Sit-driven path rebuilds (sits.ui ticks on every ingest) run at most this often.
    private static let SIT_PATH_MIN_INTERVAL_S: TimeInterval = 2

    private static let FLASH_MS = 1_000
    /// Live list refresh cap: 4 passes per second.
    private static let LIVE_MIN_INTERVAL_S: TimeInterval = 0.25

    // MARK: Public state (Kotlin StateFlows)

    private(set) var export = ExportUi()
    private(set) var pendingSettingsImport: PendingSettingsImport? = nil
    private(set) var candidates = CandidatesUi()
    private(set) var logExportKind: LogExportKind = .logCsv
    private(set) var logExportRadios: LogExportRadios = .both
    private(set) var sitExportKind: LogExportKind = .logCsv
    private(set) var sitExportRadios: LogExportRadios = .both
    private(set) var sitPath: SitPathPlot.Model? = nil
    private(set) var pathTiles: [PathTiles.Tile] = []
    private(set) var pathAircraftTiles: [[PathTiles.Tile]] = []
    private(set) var liveFocus = 0
    private(set) var flashKeys: Set<String> = []
    private(set) var beepSnap = BeepSnap()
    private(set) var alertedKeys: Set<String> = []
    private(set) var familyHint: SignatureFamilyHint? = nil
    private(set) var outlineOpenClasses: Set<String> = []
    private(set) var outlineOpenSigs: Set<String> = []
    private(set) var catalogOpenClasses: Set<String> = []
    /// No GNSS receiver on a Mac: always nil.
    private(set) var gnssNotice: GnssNotice? = nil
    /// No GNSS receiver on a Mac.
    private(set) var gnssStatus: String = "GNSS check is not available on Mac"
    /// Kotlin `app.gnssProfile.profile`. A Mac never calibrates, so this stays nil in practice.
    private(set) var gnssProfile: GnssPhoneProfile? = nil
    private(set) var gnssCalibration = GnssCalUi()
    private(set) var floodNotice: PairingFlood.Notice? = nil
    private(set) var floodHide = PairingFlood.FloodHide()
    private(set) var ui: FieldwatchUi
    private(set) var hunt = HuntUi()

    /// Kotlin `FieldwatchViewModel(application)`. Android Application → FieldwatchApp (default `.shared`).
    init(application: FieldwatchApp? = nil) {
        let app = application ?? FieldwatchApp.shared
        self.app = app
        let settings = app.config.settings
        liveUi = FieldwatchUi(settings: settings, catalogVersion: app.config.config.value.version)
        ui = FieldwatchUi(settings: settings)
        floodNotice = app.pairingFlood.notice.value ?? app.wifiFlood.notice.value
        floodHide = Self.mergeHide(ble: app.pairingFlood.hide.value, wifi: app.wifiFlood.hide.value)
        gnssProfile = app.gnssProfile.profile.value
        start()
    }

    // MARK: - Wiring

    private func start() {
        watch(app.devices.devices) { $0.onDevicesChanged() }
        watch(app.devices.stats) { $0.scheduleLive() }
        watch(app.config.config) { $0.scheduleLive(urgent: true) }
        watch(app.arrivals) { $0.scheduleLive(urgent: true) }
        watch(app.tak.status) { $0.scheduleLive() }
        watch(app.pairingFlood.notice) { $0.onFloodChanged() }
        watch(app.pairingFlood.hide) { $0.onFloodChanged() }
        watch(app.wifiFlood.notice) { $0.onFloodChanged() }
        watch(app.wifiFlood.hide) { $0.onFloodChanged() }
        watch(app.sits.ui) { $0.onSitsChanged() }
        // Runtime bumps this when Location services / authorization change (Android MODE_CHANGED receiver).
        watch(app.locationEpoch) { $0.scheduleLive(urgent: true) }
        watch(app.gnssProfile.profile) { vm in vm.gnssProfile = vm.app.gnssProfile.profile.value }
        // Alerter flashes are events (Kotlin SharedFlow): hop every key, never coalesce.
        tokens.append(app.alerter.flashes.observe { [weak self] (key: String?) in
            guard let key, key.isNotEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onFlash(key: key) } }
        })

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.onClockTick() } }
        timer.resume()
        clockTimer = timer

        // Kotlin collectors see the current value on subscribe.
        onSitsChanged()
        scheduleLive(urgent: true)
    }

    /// Observe a Core / runtime flow; coalesced hop to the main actor, then `onMain` reads current values.
    private func watch<T>(_ flow: MutableStateFlow<T>, _ onMain: @escaping @MainActor (FieldwatchViewModel) -> Void) {
        let gate = HopGate()
        tokens.append(flow.observe { [weak self] _ in
            guard gate.arm() else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    gate.disarm()
                    if let self { onMain(self) }
                }
            }
        })
    }

    private func onDevicesChanged() {
        let devices = app.devices.devices.value
        // combine(selectedKey, devices): keep the last live copy of the selected radio.
        if let key = selectedKey, let device = devices.first(where: { $0.key == key }) {
            heldSelected = device
        }
        sampleHunt(devices: devices)
        recomputeHunt()
        scheduleLive()
    }

    private func onFloodChanged() {
        let notice = app.pairingFlood.notice.value ?? app.wifiFlood.notice.value
        if notice != floodNotice { floodNotice = notice }
        let hide = Self.mergeHide(ble: app.pairingFlood.hide.value, wifi: app.wifiFlood.hide.value)
        if hide != floodHide {
            floodHide = hide
            scheduleLive()
        }
    }

    private static func mergeHide(ble: PairingFlood.FloodHide, wifi: PairingFlood.FloodHide) -> PairingFlood.FloodHide {
        PairingFlood.FloodHide(
            episodeOn: ble.episodeOn || wifi.episodeOn,
            keys: wifi.keys.isEmpty ? ble.keys : (ble.keys.isEmpty ? wifi.keys : ble.keys.union(wifi.keys))
        )
    }

    private func onSitsChanged() {
        let sit = app.sits.ui.value
        let open = sit.open != nil
        app.pairingFlood.setSitOpen(open: open)
        app.wifiFlood.setSitOpen(open: open)
        scheduleSitPath()
        // Open / close / pick / notice show at once; a radio-count tick waits for the live cadence.
        let key = Self.sitKey(sit)
        if key != lastSitKey {
            lastSitKey = key
            recomputeUi()
        } else {
            scheduleLive()
        }
    }

    private static func sitKey(_ sit: SitUi) -> String {
        let open = sit.open.map { "\($0.id)|\($0.name)" } ?? "-"
        let closed = sit.closed.map { "\($0.id)|\($0.name)" }.joined(separator: ",")
        return "\(open)#\(closed)#\(sit.selectedId ?? "-")#\(sit.compareId ?? "-")#\(sit.notice ?? "-")#\(sit.atCap)#\(sit.memoryTight)"
    }

    private func onClockTick() {
        let now = nowMs()
        clock = now
        let liveKeys = Set(app.devices.devices.value.map { $0.key })
        app.pairingFlood.tick(now: now, speedMps: app.floodSpeed(now: now))
        app.pairingFlood.prune(liveKeys: liveKeys)
        app.wifiFlood.prune(liveKeys: liveKeys)
        app.sits.noteFloods(incoming: app.pairingFlood.bursts())
        app.sits.noteFloods(incoming: app.wifiFlood.bursts())
        // app.sits.noteGnss(app.gnss.marks()): no GNSS receiver on a Mac.
        recomputeHunt()
        scheduleLive()
    }

    private func onFlash(key: String) {
        revealOutlineFor(deviceKey: key)
        let now = nowMs()
        lastAlertAt[key] = now
        if !alertedKeys.contains(key) { alertedKeys.insert(key) }
        let end = now + Self.FLASH_MS
        flashUntil[key] = end
        flashKeys = Set(flashUntil.keys)
        if app.config.settings.snapToBeep {
            beepSnap = BeepSnap(seq: beepSnap.seq + 1, key: key)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(Self.FLASH_MS) / 1000.0) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.flashUntil[key] == end else { return }
                self.flashUntil[key] = nil
                self.flashKeys = Set(self.flashUntil.keys)
            }
        }
        scheduleLive()
    }

    // MARK: - Live pass (Kotlin liveUi) and ui

    private func scheduleLive(urgent: Bool = false) {
        if liveRunning {
            liveAgain = true
            if urgent { liveAgainUrgent = true }
            return
        }
        if let pending = liveWork {
            if !urgent { return }
            pending.cancel()
        }
        let since = ProcessInfo.processInfo.systemUptime - lastLiveAt
        let wait = urgent ? 0 : max(0, Self.LIVE_MIN_INTERVAL_S - since)
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.runLive() } }
        liveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func runLive() {
        liveWork = nil
        liveRunning = true
        lastLiveAt = ProcessInfo.processInfo.systemUptime
        let config = app.config.config.value
        let snap = LiveSnap(
            devices: app.devices.devices.value,
            stats: app.devices.stats.value,
            config: config,
            sel: selectedKey,
            draft: draft,
            arr: app.arrivals.value,
            now: clock,
            alerts: lastAlertAt,
            takStatus: app.tak.status.value,
            hide: floodHide,
            permissionsOk: permissionsGranted(),
            locationOn: app.systemLocationOn(),
            hasFineLocation: app.hasFineLocation(),
            operatorPath: config.filter.movingWithYou ? app.operatorPathCopy() : nil,
            operatorPathLengthM: app.operatorPathLengthM(),
            held: heldSelected,
            familyLog: familyLog
        )
        let filters = self.filters
        liveQueue.async { [weak self] in
            let out = Self.computeLive(snap: snap, filters: filters)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishLive(out: out) } }
        }
    }

    private func finishLive(out: LiveOut) {
        liveRunning = false
        liveUi = out.ui
        if !Self.sameHint(familyHint, out.familyHint) { familyHint = out.familyHint }
        recomputeUi()
        if liveAgain {
            let urgent = liveAgainUrgent
            liveAgain = false
            liveAgainUrgent = false
            scheduleLive(urgent: urgent)
        }
    }

    private static func sameHint(_ a: SignatureFamilyHint?, _ b: SignatureFamilyHint?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return x == y
        default: return false
        }
    }

    /// Kotlin `liveUi` combine body. Pure; runs on `liveQueue`.
    nonisolated private static func computeLive(snap: LiveSnap, filters: FilterEngine) -> LiveOut {
        let devices = snap.devices
        let stats = snap.stats
        let config = snap.config
        let settings = config.settings
        let arr = snap.arr
        let now = snap.now
        let labeled = devices
        var fleetNames: [String: String] = [:]
        for f in config.fleets { fleetNames[f.id] = f.name }
        var watchNames: [String: String] = [:]
        for row in config.watchlist {
            guard let key = row.deviceKey else { continue }
            let label = row.label.trim()
            if label.isEmpty { continue }
            watchNames[key] = label
        }
        let windowMs = settings.averageWindowSec.coerceIn(10, 180) * 1000
        let persistMs = max(settings.staleSec.coerceAtLeast(15) * 1000, settings.decaySec.coerceAtLeast(0) * 1000)
        let arrivalsOn = config.filter.arrivalsOnly && arr.active
        let learning = arrivalsOn && now <= arr.learningUntil
        var hiddenKnown = 0
        let moveCtx = config.filter.movingWithYou ? CoTravel.Ctx.of(path: snap.operatorPath ?? []) : CoTravel.Ctx.None
        var classById: [String: SignatureClass] = [:]
        for f in config.fleets { classById[f.id] = f.kind }
        let hiddenFlood = snap.hide.keys
        let namedKeys = Set(watchNames.keys)
        let watchedFleets = RadioBookmarks.watchedFleetIds(watchlist: config.watchlist)
        let alertKeys = RadioBookmarks.alertDeviceKeys(watchlist: config.watchlist)
        let mineKeys = RadioBookmarks.mineKeys(watchlist: config.watchlist)

        var kept: [Sighting] = []
        kept.reserveCapacity(labeled.count)
        for device in labeled {
            if hiddenFlood.isNotEmpty && hiddenFlood.contains(device.key) { continue }
            if !filters.pass(
                device: device, filter: config.filter, travel: moveCtx, now: now, classByFleetId: classById,
                namedRadioKeys: namedKeys, watchedFleetIds: watchedFleets, alertDeviceKeys: alertKeys, mineKeys: mineKeys
            ) { continue }
            let heardAgo = now - device.lastSeen
            let inWindow: Bool
            switch settings.viewMode {
            case .timeline: inWindow = heardAgo <= 15 * 60_000
            default: inWindow = heardAgo <= persistMs || !device.gone
            }
            if !inWindow { continue }
            if !arrivalsOn { kept.append(device); continue }
            let absorbed = arr.knownKeys.contains(device.key) || (learning && device.kind == .wifi)
            if absorbed {
                hiddenKnown += 1
                continue
            }
            if heardAgo <= persistMs || !device.gone { kept.append(device) }
        }

        func rssiKeys() -> [String: Double] {
            var m: [String: Double] = [:]
            for d in kept { m[d.key] = d.sortRssi(sort: settings.strengthSort, windowMs: windowMs, now: now) }
            return m
        }
        func desc<T: Comparable>(_ a: T, _ b: T) -> Int { a > b ? -1 : (a < b ? 1 : 0) }
        func asc<T: Comparable>(_ a: T, _ b: T) -> Int { a < b ? -1 : (a > b ? 1 : 0) }
        let filtered: [Sighting]
        switch settings.listSort {
        case .strength:
            let r = rssiKeys()
            filtered = kept.sortedWithComparator { desc(r[$0.key] ?? 0, r[$1.key] ?? 0) }
        case .newest:
            let r = rssiKeys()
            filtered = kept.sortedWithComparator { a, b in
                let c = desc(a.lastSeen, b.lastSeen)
                return c != 0 ? c : desc(r[a.key] ?? 0, r[b.key] ?? 0)
            }
        case .newestAlert:
            filtered = kept.sortedWithComparator { a, b in
                let c = desc(snap.alerts[a.key] ?? 0, snap.alerts[b.key] ?? 0)
                return c != 0 ? c : desc(a.lastSeen, b.lastSeen)
            }
        case .firstSeen:
            filtered = kept.sortedWithComparator { a, b in
                let c = desc(a.firstSeen, b.firstSeen)
                return c != 0 ? c : desc(a.lastSeen, b.lastSeen)
            }
        case .arrival:
            filtered = kept.sortedWithComparator { a, b in
                let c = asc(a.firstSeen, b.firstSeen)
                return c != 0 ? c : asc(a.mac, b.mac)
            }
        case .name:
            var titles: [String: String] = [:]
            for d in kept {
                let names = d.fleetIds.map { fleetNames[$0] ?? $0 }
                titles[d.key] = d.listLineText(line: settings.listTitleLine, signatureNames: names, watchName: watchNames[d.key]).lowercased()
            }
            filtered = kept.sortedWithComparator { a, b in
                let c = asc(titles[a.key] ?? "", titles[b.key] ?? "")
                return c != 0 ? c : asc(a.mac, b.mac)
            }
        case .signatures:
            let r = rssiKeys()
            filtered = kept.sortedWithComparator { a, b in
                let c = desc(a.fleetIds.isNotEmpty ? 1 : 0, b.fleetIds.isNotEmpty ? 1 : 0)
                return c != 0 ? c : desc(r[a.key] ?? 0, r[b.key] ?? 0)
            }
        }

        let scanRadio = ScanRadioFacts(
            scanning: stats.scanning,
            wifiOn: stats.wifiRadioOn,
            wifiWaitingOnOs: stats.wifiWaitingOnOs,
            lastWifiScanAt: stats.lastWifiScanAt,
            bleOn: stats.bleRadioOn,
            bleRunning: stats.bleRunning,
            bleParked: stats.bleParked,
            bleRetrying: stats.bleRetrying,
            bleStarting: stats.bleStarting,
            bleHitsLastMin: stats.bleHitsLastMin
        )
        let ui = FieldwatchUi(
            devices: labeled,
            filtered: filtered,
            fleets: config.fleets,
            filter: config.filter,
            presets: config.presets,
            watchlist: config.watchlist,
            settings: settings,
            selected: snap.sel.flatMap { k in labeled.first { $0.key == k } },
            draftFleet: snap.draft,
            permissionsOk: snap.permissionsOk,
            scanning: stats.scanning,
            wifiNow: stats.wifiNow,
            bleNow: stats.bleNow,
            namedNow: stats.namedNow,
            logLines: stats.logLines,
            throttleHint: stats.throttleHint,
            scanRadio: scanRadio,
            scanBlocked: ScanStatus.isBlocked(radio: scanRadio, locationOn: snap.locationOn, locationPermission: snap.hasFineLocation),
            locationOn: snap.locationOn,
            hiddenKnown: hiddenKnown,
            arrivalsLearning: learning,
            operatorSpanM: (moveCtx.ready || config.filter.movingWithYou) ? moveCtx.pathLengthM : snap.operatorPathLengthM,
            takStatus: snap.takStatus,
            catalogVersion: config.version
        )

        // Kotlin familyHint combine(selectedKey, heldSelected, devices, familyLog, config).
        var hint: SignatureFamilyHint? = nil
        if let key = snap.sel {
            let device = devices.first { $0.key == key } ?? (snap.held?.key == key ? snap.held : nil)
            if let device {
                let h = SignatureCandidates.assessFamily(device: device, live: devices, log: snap.familyLog.radios, fleets: config.fleets)
                hint = (!snap.familyLog.loaded && h.verdict == .single) ? nil : h
            }
        }
        return LiveOut(ui: ui, familyHint: hint)
    }

    /// Kotlin `ui` combine(liveUi, displayPaused, selectedKey, heldSelected, sits.ui).
    private func recomputeUi() {
        let live = liveUi
        let sit = app.sits.ui.value
        var out = live
        if !displayPaused {
            frozenUi = nil
            var selected = selectedKey.flatMap { k in live.devices.first { $0.key == k } }
            if selected == nil, let key = selectedKey, let held = heldSelected, held.key == key {
                var snap = held
                if !snap.gone { snap.gone = true }
                selected = snap
            }
            out.displayPaused = false
            out.selected = selected
        } else {
            let hold = frozenUi ?? live
            frozenUi = hold
            var selected: Sighting? = nil
            if let held = heldSelected, selectedKey == nil || held.key == selectedKey {
                selected = held
            } else if let key = selectedKey {
                selected = hold.filtered.first { $0.key == key } ?? hold.devices.first { $0.key == key }
            }
            out.displayPaused = true
            out.devices = hold.devices
            out.filtered = hold.filtered
            out.selected = selected
        }
        out.sit = sit
        // The live pass carries the draft too; read it fresh so the editor opens without waiting a pass.
        out.draftFleet = draft
        ui = out
    }

    private func setDraft(_ fleet: Fleet?) {
        draft = fleet
        recomputeUi()
        scheduleLive(urgent: true)
    }

    private func setSelectedKey(_ key: String?) {
        let changed = key != selectedKey
        selectedKey = key
        // combine(selectedKey, devices) → heldSelected.
        if key == nil {
            heldSelected = nil
        } else if let device = app.devices.devices.value.first(where: { $0.key == key }) {
            heldSelected = device
        }
        if changed, key != nil { loadFamilyLog() }
        recomputeUi()
        scheduleLive(urgent: true)
    }

    /// Kotlin selectedKey.collect → app.logs.readRadios() → familyLog.
    private func loadFamilyLog() {
        let logs = app.logs
        Task { @MainActor [weak self] in
            do {
                let radios = try await Self.off { try Self.readRadios(logs: logs) }
                self?.familyLog = FamilyLogSnap(radios: radios, loaded: true)
            } catch {
                self?.familyLog.loaded = true
            }
            self?.scheduleLive(urgent: true)
        }
    }

    // MARK: - Hunt

    private func sampleHunt(devices: [Sighting]) {
        guard let key = huntKey, let device = devices.first(where: { $0.key == key }) else { return }
        if let last = huntSamples.last, device.lastSeen <= last.at { return }
        huntSamples = (huntSamples + [RssiSample(at: device.lastSeen, rssi: device.rssi)]).takeLast(120)
        if device.rssi > huntPeakRssi { huntPeakRssi = device.rssi }
    }

    private func recomputeHunt() {
        let next: HuntUi
        if let key = huntKey {
            let device = app.devices.devices.value.first { $0.key == key }
            next = HuntUi(
                active: true,
                device: device,
                title: device?.listTitle() ?? "Hunt",
                cue: Hunt.cue(samples: huntSamples, now: clock, lastSeen: device?.lastSeen, missing: device == nil && huntStartedAt > 0),
                peakRssi: huntPeakRssi,
                samples: huntSamples,
                lastSeen: device?.lastSeen ?? 0
            )
        } else {
            next = HuntUi()
        }
        if next != hunt { hunt = next }
    }

    // MARK: - GNSS (no receiver on a Mac)

    func dismissGnss() {}

    func startGnssCalibration() {}

    func stopGnssCalibration() {}

    // MARK: - Scan / permissions / chrome

    /// Re-read system Location. Live calls this when the screen resumes.
    func refreshLocation() {
        locationEpoch += 1
        scheduleLive(urgent: true)
    }

    private func permissionsGranted() -> Bool { RadioPermissions.granted(context: app) }

    func refreshPermissions() {
        app.config.update { $0 }
        scheduleLive(urgent: true)
    }

    func startScan() {
        if !app.config.settings.disclaimerOk() { return }
        if permissionsGranted() { app.startScanning() }
    }

    func acceptDisclaimer() {
        app.config.update { cfg in
            var c = cfg
            c.settings.disclaimerAccepted = true
            c.settings.disclaimerRev = DISCLAIMER_REV
            return c
        }
        startScan()
    }

    func dismissPairingFlood() {
        if app.pairingFlood.notice.value != nil { app.pairingFlood.dismiss() } else { app.wifiFlood.dismiss() }
    }

    func setHideBurst(on: Bool) {
        if app.pairingFlood.notice.value != nil { app.pairingFlood.setHideBurst(on: on) } else { app.wifiFlood.setHideBurst(on: on) }
    }

    func hidePairingFlood() {
        if app.pairingFlood.notice.value != nil {
            app.pairingFlood.setHideBurst(on: true)
            app.pairingFlood.dismiss()
        } else {
            app.wifiFlood.setHideBurst(on: true)
            app.wifiFlood.dismiss()
        }
    }

    func clearHiddenFlood() {
        app.pairingFlood.clearHidden()
        app.wifiFlood.clearHidden()
    }

    func dismissLiveTour() {
        updateSettingsField { $0.liveTourDone = true }
    }

    func showLiveTour(then: @escaping () -> Void = {}) {
        updateSettingsField { $0.liveTourDone = false }
        then()
    }

    func stopScan() { app.stopScanning() }

    func select(key: String?) {
        setSelectedKey(key)
    }

    func select(device: Sighting) {
        heldSelected = device
        setSelectedKey(device.key)
    }

    func startHunt(device: Sighting) {
        let now = nowMs()
        huntKey = device.key
        huntStartedAt = now
        huntPeakRssi = device.rssi
        huntSamples = [RssiSample(at: now, rssi: device.rssi)]
        sampleHunt(devices: app.devices.devices.value)
        recomputeHunt()
    }

    func resetHunt() {
        guard let key = huntKey, let live = app.devices.devices.value.first(where: { $0.key == key }) else { return }
        startHunt(device: live)
    }

    func stopHunt() {
        huntKey = nil
        huntSamples = []
        huntPeakRssi = -127
        huntStartedAt = 0
        recomputeHunt()
    }

    func huntTick(beepOn: Bool, vibrateOn: Bool) {
        if !beepOn && !vibrateOn { return }
        app.alerter.huntTick(beepOn: beepOn, vibrateOn: vibrateOn)
    }

    // MARK: - Display settings

    private func updateSettingsField(_ change: (inout AppSettings) -> Void) {
        app.config.update { cfg in
            var c = cfg
            change(&c.settings)
            return c
        }
    }

    func setViewMode(mode: ViewMode) {
        updateSettingsField { $0.viewMode = mode }
    }

    func toggleOutlineClass(id: String) {
        let open = outlineOpenClasses
        if open.contains(id) {
            outlineOpenSigs = outlineOpenSigs.filter { !$0.hasPrefix("\(id)/") }
            outlineOpenClasses = open.subtracting([id])
        } else {
            outlineOpenClasses = open.union([id])
        }
    }

    func toggleOutlineSignature(id: String) {
        let open = outlineOpenSigs
        outlineOpenSigs = open.contains(id) ? open.subtracting([id]) : open.union([id])
    }

    func toggleCatalogClass(id: String) {
        let open = catalogOpenClasses
        catalogOpenClasses = open.contains(id) ? open.subtracting([id]) : open.union([id])
    }

    private func revealOutlineFor(deviceKey: String) {
        guard let device = app.devices.devices.value.first(where: { $0.key == deviceKey }) else { return }
        var classBy: [String: SignatureClass] = [:]
        for f in app.config.fleets { classBy[f.id] = f.kind }
        let reveal = ClassOutline.reveal(device: device, classByFleetId: classBy)
        if !reveal.classIds.isSubset(of: outlineOpenClasses) { outlineOpenClasses.formUnion(reveal.classIds) }
        if !reveal.sigKeys.isSubset(of: outlineOpenSigs) { outlineOpenSigs.formUnion(reveal.sigKeys) }
    }

    func setStrengthSort(sort: StrengthSort, windowSec: Int? = nil) {
        updateSettingsField { s in
            s.listSort = .strength
            s.strengthSort = sort
            s.averageWindowSec = windowSec ?? s.averageWindowSec
        }
    }

    func setListSort(sort: ListSort) {
        updateSettingsField { $0.listSort = sort }
    }

    func setSignatureListSort(sort: SignatureListSort) {
        updateSettingsField { $0.signatureListSort = sort }
    }

    func setDecaySec(sec: Int) {
        updateSettingsField { $0.decaySec = sec.coerceIn(0, 60) }
    }

    func setShowRssiBar(show: Bool) {
        updateSettingsField { $0.showRssiBar = show }
    }

    func toggleRssiBar() {
        updateSettingsField { $0.showRssiBar.toggle() }
    }

    func toggleFleetName() {
        updateSettingsField { $0.showFleetName.toggle() }
    }

    func toggleFrequency() {
        updateSettingsField { $0.showFrequency.toggle() }
    }

    func toggleSeenTimes() {
        updateSettingsField { $0.showSeenTimes.toggle() }
    }

    func setListTitleLine(line: ListLine) {
        if line == ListLine.none { return }
        updateSettingsField { $0.listTitleLine = line }
    }

    func setListSubtitleLine(line: ListLine) {
        updateSettingsField { $0.listSubtitleLine = line }
    }

    func markArrivalsSeen() {
        let keys = displayPaused ? frozenUi?.filtered.map { $0.key } : nil
        app.markArrivalsSeen(keys: keys)
    }

    func resetArrivalsSeen() {
        app.resetSeenBuffer()
    }

    func resetFollowSession() {
        app.resetFollowSession()
    }

    func setScanControlsExpanded(expanded: Bool) {
        updateSettingsField { $0.scanControlsExpanded = expanded }
    }

    func focusLiveList() {
        liveFocus += 1
    }

    func toggleLiveDisplay() {
        displayPaused.toggle()
        recomputeUi()
    }

    // MARK: - Sits

    func defaultSitName() -> String { Sit.defaultName(at: nowMs()) }

    func startSit(name: String) {
        let heard = app.devices.devices.value.filter { !$0.gone }
        _ = app.sits.start(name: name, heard: heard, fleets: app.config.fleets, watchlist: app.config.watchlist)
        publishSitNotice()
    }

    func endSit() {
        _ = app.sits.end(fleets: app.config.fleets)
        publishSitNotice()
    }

    func renameSit(id: String, name: String) {
        _ = app.sits.rename(id: id, raw: name)
    }

    func deleteSit(id: String) {
        app.sits.delete(id: id)
    }

    func deleteAllSits() {
        app.sits.deleteAllClosed()
    }

    func selectSit(id: String?) {
        app.sits.select(id: id)
    }

    func selectCompareSit(id: String?) {
        app.sits.selectCompare(id: id)
    }

    func startSitCompare() {
        if export.active { return }
        Task { @MainActor in
            publishExport(progress: 0.08, message: "Writing sit compare…")
            do {
                let doc = try await sitCompareDoc()
                publishExport(progress: 0.85, message: "Writing sit compare…")
                let subject = compareSubject(doc: doc)
                let text = doc.toPlainText()
                let item = try await Self.off { try Self.textShare(text: text, subject: subject, fileBase: "fieldwatch-sit-compare") }
                export = ExportUi(active: false, progress: 1, share: item, shareTitle: "Sit compare")
            } catch {
                export = ExportUi(error: Self.messageOf(error) ?? "Could not write sit compare")
            }
        }
    }

    func startSitComparePdf() {
        if export.active { return }
        Task { @MainActor in
            publishExport(progress: 0.06, message: "Writing sit compare PDF…")
            do {
                let doc = try await sitCompareDoc()
                publishExport(progress: 0.35, message: "Laying out sit compare PDF…")
                let file = Self.exportDir().appendingPathComponent("fieldwatch-sit-compare-\(Self.stamp()).pdf")
                publishExport(progress: 0.32, message: "Loading map tiles…")
                let online = app.config.settings.onlineLookup
                let progress = backgroundProgress()
                try await Self.off {
                    let tiles = Self.pathTilesForFigure(figure: doc.pathFigure, onlineLookup: online)
                    let extraTiles = doc.extraFigures.map { Self.pathTilesForFigure(figure: $0, onlineLookup: online) }
                    try DebriefPdf.write(doc: doc, file: file, tiles: tiles, extraTiles: extraTiles) { p in
                        progress(0.38 + 0.55 * Double(p), "Writing sit compare PDF…")
                    }
                }
                let item = ShareItem(urls: [file], text: nil, title: compareSubject(doc: doc))
                export = ExportUi(active: false, progress: 1, share: item, shareTitle: "Sit compare PDF")
            } catch {
                export = ExportUi(error: Self.messageOf(error) ?? "Could not write sit compare PDF")
            }
        }
    }

    private func compareSubject(doc: DebriefDoc) -> String {
        doc.windowLine.isNotBlank ? "Fieldwatch sit compare — \(doc.windowLine)" : "Fieldwatch sit compare"
    }

    func startSitCompareAiExport() {
        if export.active { return }
        Task { @MainActor in
            publishExport(progress: 0.08, message: "Building compare AI export…")
            do {
                let (thisSide, second) = try await compareSides()
                publishExport(progress: 0.45, message: "Building compare AI export…")
                let demo = app.config.settings.demoMode
                let subject = "Fieldwatch sit compare AI export — \(thisSide.name) vs \(second.name)"
                let item = try await Self.off {
                    let text = SitDiffPrompt.build(thisSit: thisSide, second: second, demoMode: demo)
                    return try Self.textShare(text: text, subject: subject, fileBase: "fieldwatch-sit-compare-ai")
                }
                export = ExportUi(active: false, progress: 1, share: item, shareTitle: "Sit compare AI Export")
            } catch {
                export = ExportUi(error: Self.messageOf(error) ?? "Could not write compare AI export")
            }
        }
    }

    private func sitCompareDoc() async throws -> DebriefDoc {
        let (thisSide, second) = try await compareSides()
        let watched = RadioBookmarks.watchedFleetIds(watchlist: app.config.watchlist)
        let settings = app.config.settings
        return try await Self.off {
            let radios = thisSide.radios + second.radios
            return SitDiff.document(thisSit: thisSide, second: second, watchedFleetIds: watched, showAllRadios: settings.debriefShowAllRadios)
                .withDemoMacs(macs: radios.map { $0.mac }, demo: settings.demoMode, uasIds: radios.map { $0.payloadUasId })
        }
    }

    private func compareSides() async throws -> (SitDiff.Side, SitDiff.Side) {
        let sit = app.sits.ui.value
        guard let otherId = sit.compareId else { throw VmError("Pick a second sit.") }
        let sits = app.sits
        let fleets = app.config.fleets
        let watchlist = app.config.watchlist
        let customNames = RadioBookmarks.labels(watchlist: watchlist)
        let observerNotes = RadioBookmarks.notes(watchlist: watchlist)
        let bookmarkedKeys = RadioBookmarks.alertDeviceKeys(watchlist: watchlist)
        let mineKeys = RadioBookmarks.mineKeys(watchlist: watchlist)
        let liveDevices = app.devices.devices.value
        let opPath = app.operatorPathCopy()
        let floods = app.floodBursts()
        return try await Self.off {
            guard let otherFile = sits.sitFile(id: otherId) else { throw VmError("Could not read that sit.") }
            let thisSide = try Self.compareThisSide(
                sit: sit, sits: sits, fleets: fleets, customNames: customNames, observerNotes: observerNotes,
                bookmarkedKeys: bookmarkedKeys, mineKeys: mineKeys, liveDevices: liveDevices, operatorPath: opPath, floods: floods
            )
            let second = SitDiff.Side(
                name: otherFile.summary.name,
                ram: false,
                radios: otherFile.radios.map {
                    SitDiff.fromSitRadio(row: $0, fleets: fleets, customNames: customNames, observerNotes: observerNotes, bookmarkedKeys: bookmarkedKeys, mineKeys: mineKeys)
                },
                path: otherFile.operatorPath,
                floods: otherFile.floods,
                gnss: otherFile.gnss
            )
            return (thisSide, second)
        }
    }

    nonisolated private static func compareThisSide(
        sit: SitUi, sits: SitStore, fleets: [Fleet], customNames: [String: String], observerNotes: [String: String],
        bookmarkedKeys: Set<String>, mineKeys: Set<String>, liveDevices: [Sighting], operatorPath: [GpsSample], floods: [FloodBurst]
    ) throws -> SitDiff.Side {
        if let open = sit.open {
            let source = sits.debriefSource()
            return SitDiff.Side(
                name: open.name,
                ram: false,
                radios: (source?.devices ?? []).map {
                    SitDiff.fromSighting(device: $0, fleets: fleets, customNames: customNames, observerNotes: observerNotes, bookmarkedKeys: bookmarkedKeys, mineKeys: mineKeys)
                },
                path: source?.operatorPath ?? [],
                floods: source?.floods ?? [],
                gnss: source?.gnss ?? []
            )
        }
        if let selected = sit.closed.first(where: { $0.id == sit.selectedId }) {
            guard let file = sits.sitFile(id: selected.id) else { throw VmError("Could not read this sit.") }
            return SitDiff.Side(
                name: selected.name,
                ram: false,
                radios: file.radios.map {
                    SitDiff.fromSitRadio(row: $0, fleets: fleets, customNames: customNames, observerNotes: observerNotes, bookmarkedKeys: bookmarkedKeys, mineKeys: mineKeys)
                },
                path: file.operatorPath,
                floods: file.floods,
                gnss: file.gnss
            )
        }
        let since = nowMs() - DebriefPrompt.WINDOW_MS
        return SitDiff.Side(
            name: "Last 15 minutes",
            ram: true,
            radios: liveDevices.map {
                SitDiff.fromSighting(device: $0, fleets: fleets, customNames: customNames, observerNotes: observerNotes, bookmarkedKeys: bookmarkedKeys, mineKeys: mineKeys)
            },
            path: operatorPath.filter { $0.at >= since },
            floods: floods.filter { $0.at >= since },
            gnss: [] // app.gnss.marks(): no GNSS receiver on a Mac.
        )
    }

    private func publishSitNotice() {
        guard let notice = app.sits.ui.value.notice else { return }
        export = ExportUi(noticeTitle: "Sits", noticeMessage: notice)
        app.sits.consumeNotice()
    }

    // MARK: - Filters / presets

    func updateFilter(transform: (FilterState) -> FilterState) {
        var nextOn = app.config.filter.arrivalsOnly
        app.config.update { cfg in
            var c = cfg
            let next = transform(c.filter)
            nextOn = next.arrivalsOnly
            c.filter = next
            return c
        }
        app.syncArrivals(on: nextOn)
    }

    func applyPreset(preset: FilterPreset) {
        app.config.update { cfg in
            var c = cfg
            c.filter = preset.filter
            return c
        }
        app.syncArrivals(on: preset.filter.arrivalsOnly)
    }

    func savePreset(name: String) {
        app.config.update { cfg in
            var c = cfg
            c.presets.append(FilterPreset(id: UUID().uuidString.lowercased(), name: name, filter: cfg.filter))
            return c
        }
    }

    func deletePreset(id: String) {
        app.config.update { cfg in
            var c = cfg
            let removing = cfg.presets.first { $0.id == id }
            if removing?.isBuiltIn() == true { c.hiddenPresetIds.insert(id) }
            c.presets = cfg.presets.filter { $0.id != id }
            return c
        }
    }

    // MARK: - Signatures

    private func refreshDevices(settings: AppSettings? = nil) {
        let s = settings ?? app.config.settings
        app.devices.refresh(fleets: app.config.fleets, staleSec: s.staleSec, policy: s.detectionPolicy(), decaySec: s.decaySec)
    }

    private func putFleet(_ fleet: Fleet) {
        app.config.update { cfg in
            var c = cfg
            if let i = c.fleets.firstIndex(where: { $0.id == fleet.id }) { c.fleets[i] = fleet } else { c.fleets.append(fleet) }
            return c
        }
    }

    func upsertFleet(fleet: Fleet, after: (() -> Void)? = nil) {
        putFleet(fleet)
        setDraft(nil)
        refreshDevices()
        after?()
    }

    func deleteFleet(id: String) {
        app.config.update { cfg in
            var c = cfg
            c.fleets = cfg.fleets.filter { $0.id != id }
            c.watchlist = cfg.watchlist.filter { $0.fleetId != id }
            c.filter.fleetIds.remove(id)
            c.filter.includeFleetIds.remove(id)
            return c
        }
        setDraft(nil)
        refreshDevices()
    }

    func beginCreateFrom(device: Sighting) {
        draftFromCandidates = false
        setDraft(signatures.suggestFleet(device: device))
    }

    func beginCreateFromCandidate(candidate: SignatureCandidate) {
        draftFromCandidates = true
        setDraft(SignatureCandidates.suggestFleet(candidate: candidate))
    }

    func takeDraftFromCandidates() -> Bool {
        let hit = draftFromCandidates
        draftFromCandidates = false
        return hit
    }

    func startSignatureCandidates() {
        if candidates.loading { return }
        candidates = CandidatesUi(loading: true)
        let logs = app.logs
        let fleets = app.config.fleets
        Task { @MainActor in
            do {
                let report = try await Self.off {
                    let radios = try Self.readRadios(logs: logs)
                    return SignatureCandidates.analyze(radios: radios, fleets: fleets)
                }
                candidates = CandidatesUi(report: report)
            } catch {
                candidates = CandidatesUi(error: Self.messageOf(error) ?? "Could not read the log")
            }
        }
    }

    func beginNewFleet() {
        draftFromCandidates = false
        setDraft(DefaultCatalog.newBlankFleet())
    }

    func editFleet(fleet: Fleet) {
        draftFromCandidates = false
        setDraft(fleet)
    }

    func saveFleetKeepDraft(fleet: Fleet) {
        putFleet(fleet)
        setDraft(fleet)
    }

    func cancelDraft() {
        setDraft(nil)
    }

    // MARK: - Settings

    func updateSettings(transform: (AppSettings) -> AppSettings) {
        let prev = app.config.settings
        let noProfile = app.gnssProfile.profile.value == nil
        app.config.update { cfg in
            var c = cfg
            var next = transform(cfg.settings)
            if noProfile { next.gnssMonitor = false }
            c.settings = next
            return c
        }
        applySettingsSideEffects(prev: prev, refreshAlways: false)
    }

    /// Shared tail of updateSettings / finishSettingsImport.
    private func applySettingsSideEffects(prev: AppSettings, refreshAlways: Bool) {
        let next = app.config.settings
        app.logs.configure(format: next.logFormat, rotateKb: next.logRotateKb, loggingOn: next.loggingEnabled)
        if prev.tagLocation != next.tagLocation { app.syncLocationUpdates() }
        // app.syncGnss(): no GNSS receiver on a Mac.
        if prev.intensity != next.intensity && app.devices.stats.value.scanning {
            app.startScanning()
        }
        if refreshAlways || prev.detectionPolicy() != next.detectionPolicy() {
            refreshDevices(settings: next)
        }
        if next.alertVoice || next.gnssVoice { app.alerter.prepareVoice() }
    }

    // MARK: - Bookmarks / named radios

    func toggleWatchDevice(device: Sighting) {
        app.config.update { cfg in
            var c = cfg
            let names = device.fleetIds.compactMap { id in cfg.fleets.first { $0.id == id }?.name }
            c.watchlist = RadioBookmarks.toggleAlert(
                watchlist: cfg.watchlist,
                deviceKey: device.key,
                suggest: RadioBookmarks.suggestLabel(device: device, signatureNames: names)
            )
            return c
        }
    }

    private func updateWatchlist(_ f: ([WatchTarget]) -> [WatchTarget]) {
        app.config.update { cfg in
            var c = cfg
            c.watchlist = f(cfg.watchlist)
            return c
        }
    }

    func saveRadioName(device: Sighting, name: String) {
        updateWatchlist { RadioBookmarks.upsertName(watchlist: $0, deviceKey: device.key, name: name) }
    }

    func setRadioAlert(id: String, on: Bool) {
        updateWatchlist { RadioBookmarks.setAlert(watchlist: $0, id: id, on: on) }
    }

    func isMine(deviceKey: String) -> Bool {
        app.config.watchlist.contains { $0.deviceKey == deviceKey && $0.mine }
    }

    func setRadioMine(device: Sighting, on: Bool) {
        let suggest = RadioBookmarks.suggestLabel(device: device, signatureNames: device.fleetIds.map { fleetName(id: $0) })
        updateWatchlist { RadioBookmarks.setMine(watchlist: $0, deviceKey: device.key, on: on, suggestLabel: suggest) }
    }

    func setNamedRadioMine(id: String, on: Bool) {
        updateWatchlist { RadioBookmarks.setMineOnRow(watchlist: $0, id: id, on: on) }
    }

    func renameRadioBookmark(id: String, name: String) {
        updateWatchlist { RadioBookmarks.rename(watchlist: $0, id: id, name: name) }
    }

    func updateNamedRadio(id: String, name: String, notes: String) {
        updateWatchlist { RadioBookmarks.updateNamedRadio(watchlist: $0, id: id, name: name, notes: notes) }
    }

    func removeRadioBookmark(id: String) {
        updateWatchlist { RadioBookmarks.remove(watchlist: $0, id: id) }
    }

    func clearRadioBookmarks() {
        updateWatchlist { RadioBookmarks.withoutRadios(watchlist: $0) }
    }

    func watchLabelFor(deviceKey: String) -> String? {
        app.config.watchlist.first { $0.deviceKey == deviceKey }?.label.trim().nonEmpty
    }

    func watchObserverNoteFor(deviceKey: String) -> String? {
        app.config.watchlist.first { $0.deviceKey == deviceKey }?.observerNotes.trim().nonEmpty
    }

    func saveRadioNotes(device: Sighting, notes: String) {
        let suggest = RadioBookmarks.suggestLabel(device: device, signatureNames: device.fleetIds.map { fleetName(id: $0) })
        updateWatchlist { RadioBookmarks.upsertNotes(watchlist: $0, deviceKey: device.key, notes: notes, suggestLabel: suggest) }
    }

    func toggleWatchFleet(fleet: Fleet) {
        updateWatchlist { list in
            if list.contains(where: { $0.fleetId == fleet.id }) {
                return list.filter { $0.fleetId != fleet.id }
            }
            return list + [WatchTarget(id: UUID().uuidString.lowercased(), fleetId: fleet.id, label: fleet.name)]
        }
    }

    func restoreDefaults() {
        app.config.restoreDefaults()
        app.syncLocationUpdates()
        app.syncArrivals(on: false)
        refreshDevices()
    }

    // MARK: - Signature / settings packs

    func suggestedSignaturesName() -> String { "fieldwatch-signatures-\(formatMs(nowMs(), "yyyyMMdd")).json" }

    private func signaturePackJson() -> String {
        let cfg = app.config.config.value
        return SignatureExchange.encode(
            pack: SignatureExchange.pack(fleets: cfg.fleets, catalogVersion: cfg.version, appVersion: Self.appVersionName(), exportedAt: isoUtcMs(nowMs()))
        )
    }

    func startSignatureShare() {
        let json = signaturePackJson()
        let file = Self.exportDir().appendingPathComponent(suggestedSignaturesName())
        Task { @MainActor in
            do {
                try await Self.off { try Self.writeText(json, to: file) }
                export = ExportUi(share: ShareItem(urls: [file], text: nil, title: "Fieldwatch signatures"), shareTitle: "Fieldwatch signatures")
            } catch {
                export = ExportUi(error: Self.messageOf(error) ?? "Could not export signatures", errorTitle: "Could not export signatures")
            }
        }
    }

    func saveSignaturesToUri(uri: URL) {
        let json = signaturePackJson()
        Task { @MainActor in
            do {
                try await Self.off { try Self.writeText(json, to: uri) }
                export = ExportUi(
                    noticeTitle: "Signatures saved",
                    noticeMessage: "The pack was written to the folder you picked. Share it with another Fieldwatch or keep it as a backup before Restore defaults."
                )
            } catch {
                export = ExportUi(error: Self.messageOf(error) ?? "Could not save signatures", errorTitle: "Could not save signatures")
            }
        }
    }

    func updateStockCatalogFromGitHub() {
        if export.active { return }
        let userAgent = "Fieldwatch/\(Self.appVersionName())"
        Task { @MainActor in
            let online = (try? await Self.off { PlaceLookup.online() }) ?? false
            if !online {
                export = ExportUi(error: "No internet. Use Import signatures from a file.", errorTitle: "No internet")
                return
            }
            export = ExportUi(active: true, spinner: true, message: "Updating stock catalog…")
            do {
                let parsed = try await Self.off {
                    let text = try CatalogRemote.fetch(userAgent: userAgent)
                    return try SignatureExchange.parsePack(text: text)
                }
                var result = app.config.overlayStockCatalog(pack: parsed.pack)
                result.skippedDecode = parsed.skippedDecode
                if let err = result.error { throw VmError(err) }
                if !result.alreadyLatest { refreshDevices() }
                if result.alreadyLatest {
                    export = ExportUi(
                        noticeTitle: "Already on the latest catalog",
                        noticeMessage: "Already on catalog \(result.catalogVersion). Nothing to update."
                    )
                } else {
                    var bits: [String] = []
                    if result.updated > 0 { bits.append("updated \(result.updated)") }
                    if result.added > 0 { bits.append("added \(result.added)") }
                    let change = bits.isEmpty ? "No stock rows changed." : bits.joined(separator: " · ").capitalizedFirst() + "."
                    let skip = result.skippedDecode > 0
                    export = ExportUi(
                        noticeTitle: "Catalog updated",
                        noticeMessage: "Stock catalog is now \(result.catalogVersion). \(change) Bookmarks and Settings were not changed.",
                        followUpTitle: skip ? "Signature decoding skipped" : nil,
                        followUpMessage: skip
                            ? "Some signature field maps in this catalog need a newer Fieldwatch. Signatures still match. Install a newer Fieldwatch to decode those fields."
                            : nil
                    )
                }
            } catch {
                let msg = Self.messageOf(error) ?? ""
                let access = error is URLError ||
                    msg.contains("HTTP", ignoreCase: true) ||
                    msg.contains("Unable to resolve", ignoreCase: true) ||
                    msg.contains("failed to connect", ignoreCase: true) ||
                    msg.contains("timeout", ignoreCase: true) ||
                    msg.contains("timed out", ignoreCase: true) ||
                    msg.contains("GitHub", ignoreCase: true)
                if access {
                    export = ExportUi(
                        error: "Could not reach the catalog on GitHub. Try again later, or use Import signatures from a file.",
                        errorTitle: "Could not reach GitHub"
                    )
                } else {
                    export = ExportUi(error: msg.ifEmpty("Could not import catalog."), errorTitle: "Could not import catalog")
                }
            }
        }
    }

    func importSignaturesFromUri(uri: URL) {
        Task { @MainActor in
            do {
                let pack = try await Self.off { try SignatureExchange.parse(text: try Self.readText(uri)) }
                let result = app.config.importFleets(incoming: pack.fleets)
                if let err = result.error { throw VmError(err) }
                refreshDevices()
                export = ExportUi(noticeTitle: "Signatures imported", noticeMessage: result.summary())
            } catch {
                export = ExportUi(error: Self.messageOf(error) ?? "Could not import signatures", errorTitle: "Could not import signatures")
            }
        }
    }

    func suggestedSettingsName() -> String { "fieldwatch-settings-\(formatMs(nowMs(), "yyyyMMdd")).json" }

    private func settingsPackJson() -> String {
        let cfg = app.config.config.value
        return SettingsExchange.encode(
            pack: SettingsExchange.pack(
                settings: cfg.settings,
                filter: cfg.filter,
                presets: cfg.presets,
                watchlist: cfg.watchlist,
                hiddenPresetIds: cfg.hiddenPresetIds,
                appVersion: Self.appVersionName(),
                exportedAt: isoUtcMs(nowMs())
            )
        )
    }

    func startSettingsShare() {
        let json = settingsPackJson()
        let file = Self.exportDir().appendingPathComponent(suggestedSettingsName())
        Task { @MainActor in
            do {
                try await Self.off { try Self.writeText(json, to: file) }
                export = ExportUi(share: ShareItem(urls: [file], text: nil, title: "Fieldwatch settings"), shareTitle: "Fieldwatch settings")
            } catch {
                export = ExportUi(error: Self.messageOf(error) ?? "Could not export settings", errorTitle: "Could not export settings")
            }
        }
    }

    func saveSettingsToUri(uri: URL) {
        let json = settingsPackJson()
        Task { @MainActor in
            do {
                try await Self.off { try Self.writeText(json, to: uri) }
                export = ExportUi(
                    noticeTitle: "Settings saved",
                    noticeMessage: "The pack was written to the folder you picked. Keep it for a reinstall or a new Mac. Import settings on the new install. Signatures are a separate pack."
                )
            } catch {
                export = ExportUi(error: Self.messageOf(error) ?? "Could not save settings", errorTitle: "Could not save settings")
            }
        }
    }

    func importSettingsFromUri(uri: URL) {
        Task { @MainActor in
            do {
                let pack = try await Self.off { try SettingsExchange.parse(text: try Self.readText(uri)) }
                if let warning = SettingsExchange.takImportWarning(local: app.config.settings, incoming: pack.settings) {
                    pendingSettingsImport = PendingSettingsImport(pack: pack, message: warning)
                } else {
                    try finishSettingsImport(pack: pack)
                }
            } catch {
                export = ExportUi(error: Self.messageOf(error) ?? "Could not import settings", errorTitle: "Could not import settings")
            }
        }
    }

    func confirmPendingSettingsImport() {
        guard let pending = pendingSettingsImport else { return }
        pendingSettingsImport = nil
        do {
            try finishSettingsImport(pack: pending.pack)
        } catch {
            export = ExportUi(error: Self.messageOf(error) ?? "Could not import settings", errorTitle: "Could not import settings")
        }
    }

    func dismissPendingSettingsImport() {
        pendingSettingsImport = nil
    }

    private func finishSettingsImport(pack: SettingsPack) throws {
        let prev = app.config.settings
        let result = app.config.importSettings(pack: pack)
        if let err = result.error { throw VmError(err) }
        if app.gnssProfile.profile.value == nil && app.config.settings.gnssMonitor {
            updateSettingsField { $0.gnssMonitor = false }
        }
        applySettingsSideEffects(prev: prev, refreshAlways: true)
        export = ExportUi(noticeTitle: "Settings imported", noticeMessage: result.summary())
    }

    // MARK: - Export pickers

    func setLogExportKind(kind: LogExportKind) {
        logExportKind = kind
    }

    func setLogExportRadios(radios: LogExportRadios) {
        logExportRadios = radios
    }

    func setSitExportKind(kind: LogExportKind) {
        sitExportKind = kind
    }

    func setSitExportRadios(radios: LogExportRadios) {
        sitExportRadios = radios
    }

    // MARK: - Reports → Path

    nonisolated private static func pathTilesForFigure(figure: SitPathPlot.Figure?, onlineLookup: Bool) -> [PathTiles.Tile] {
        guard let figure, figure.drawable else { return [] }
        let phone = figure.tracks.filter { !$0.aircraft }.flatMap { $0.samples }
        let craft = figure.tracks.filter { $0.aircraft }.flatMap { $0.samples }
        let despiked = Geo.despikePath(samples: phone)
        let samples = (despiked.count >= 2 ? despiked : phone) + craft
        if samples.isEmpty { return [] }
        return PathTiles.load(samples: samples, onlineLookup: onlineLookup)
    }

    private func scheduleSitPath() {
        if sitPathScheduled { return }
        sitPathScheduled = true
        let since = ProcessInfo.processInfo.systemUptime - lastSitPathAt
        let wait = max(0, Self.SIT_PATH_MIN_INTERVAL_S - since)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                self?.sitPathScheduled = false
                self?.refreshSitPath()
            }
        }
    }

    func refreshSitPath() {
        lastSitPathAt = ProcessInfo.processInfo.systemUptime
        if pathRunning {
            pathAgain = true
            return
        }
        pathRunning = true
        let settings = app.config.settings
        let snap = SitPathSnap(
            now: nowMs(),
            sits: app.sits,
            watchlist: app.config.watchlist,
            fleets: app.config.fleets,
            tagging: settings.tagLocation,
            onlineLookup: settings.onlineLookup,
            liveDevices: app.devices.devices.value,
            operatorPath: app.operatorPathCopy(),
            sitOpen: app.sits.ui.value.open != nil
        )
        pathQueue.async { [weak self] in
            let (model, radios) = Self.buildSitPath(snap: snap)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.sitPath = model
                    self?.pathRadios = radios
                }
            }
            var tiles: [PathTiles.Tile] = []
            var aircraft: [[PathTiles.Tile]] = []
            if snap.onlineLookup {
                let despiked = Geo.despikePath(samples: model.samples)
                let phone = despiked.count >= 2 ? despiked : model.samples
                let walk = phone + model.craft.flatMap { $0.samples }
                tiles = walk.isEmpty ? [] : PathTiles.load(samples: walk, onlineLookup: true)
                aircraft = model.aircraftCards.map { card in
                    let samples = card.craft.flatMap { $0.samples }
                    return samples.count < 2 ? [] : PathTiles.load(samples: samples, onlineLookup: true)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pathTiles = tiles
                    self.pathAircraftTiles = aircraft
                    self.pathRunning = false
                    if self.pathAgain {
                        self.pathAgain = false
                        self.refreshSitPath()
                    }
                }
            }
        }
    }

    nonisolated private static func buildSitPath(snap: SitPathSnap) -> (SitPathPlot.Model, [Sighting]) {
        let now = snap.now
        let source = snap.sits.debriefSource(now: now)
        let customNames = RadioBookmarks.labels(watchlist: snap.watchlist)
        let namedKeys = Set(customNames.keys)
        let observerNotes = RadioBookmarks.notes(watchlist: snap.watchlist)
        let bookmarkedKeys = RadioBookmarks.alertDeviceKeys(watchlist: snap.watchlist)
        let watchedFleets = RadioBookmarks.watchedFleetIds(watchlist: snap.watchlist)
        let mineKeys = RadioBookmarks.mineKeys(watchlist: snap.watchlist)
        let fleets = snap.fleets
        let tagging = snap.tagging
        func aircraftTitle(_ device: Sighting) -> String {
            (device.payloadUasId?.trim() ?? "").ifBlank(device.reportName(customNames: customNames))
        }
        if let source {
            let raw = source.operatorPath
            let samples = Geo.despikePath(samples: raw)
            let plot = SitPathPlot.dotsFrom(
                devices: source.devices, fleets: fleets, namedKeys: namedKeys, customNames: customNames,
                observerNotes: observerNotes, bookmarkedKeys: bookmarkedKeys, watchedFleetIds: watchedFleets,
                alertsOnly: true, mineKeys: mineKeys
            )
            let empty: String?
            if !tagging { empty = "Turn on Tag detections with GPS to record a path." }
            else if samples.isEmpty { empty = "Walk with that on. The path needs a GPS fix." }
            else { empty = nil }
            let pictures = AircraftTrail.pictures(
                sources: source.devices.compactMap { AircraftTrail.source(device: $0, title: aircraftTitle($0)) },
                path: empty == nil ? raw : []
            )
            let model = AircraftTrail.overlay(
                model: SitPathPlot.Model(
                    samples: samples,
                    dots: samples.isNotEmpty ? plot.points : [],
                    lengthM: Geo.pathLengthM(samples: samples),
                    spanM: Geo.spanM(samples: samples),
                    title: source.name,
                    emptyHint: empty,
                    live: snap.sitOpen,
                    gnss: samples.isNotEmpty ? SitPathPlot.gnssPins(marks: source.gnss, path: samples) : []
                ),
                pictures: pictures
            )
            return (model, source.devices)
        }
        let start = now - DebriefPrompt.WINDOW_MS
        let windowPath = snap.operatorPath.filter { $0.at >= start }
        let samples = Geo.despikePath(samples: windowPath)
        let devices = snap.liveDevices.filter { $0.lastSeen >= start || $0.firstSeen >= start }
        let empty: String?
        if !tagging { empty = "Turn on Tag detections with GPS to record a path." }
        else if samples.isEmpty { empty = "Last 15 minutes. Walk with Tag detections with GPS on, or start a sit to keep a longer path." }
        else { empty = nil }
        let plot = samples.isNotEmpty
            ? SitPathPlot.dotsFrom(
                devices: devices, fleets: fleets, namedKeys: namedKeys, customNames: customNames,
                observerNotes: observerNotes, bookmarkedKeys: bookmarkedKeys, watchedFleetIds: watchedFleets,
                alertsOnly: true, mineKeys: mineKeys
            )
            : SitPathPlot.PlotRadios(points: [])
        // app.gnss.marks(): no GNSS receiver on a Mac.
        let model = AircraftTrail.overlay(
            model: SitPathPlot.Model(
                samples: samples,
                dots: plot.points,
                lengthM: Geo.pathLengthM(samples: samples),
                spanM: Geo.spanM(samples: samples),
                title: "Last 15 minutes",
                emptyHint: empty,
                live: true,
                gnss: []
            ),
            pictures: AircraftTrail.pictures(
                sources: devices.compactMap { AircraftTrail.source(device: $0, title: aircraftTitle($0)) },
                path: empty == nil ? windowPath : []
            )
        )
        return (model, devices)
    }

    func openPathRadio(key: String) -> Bool {
        guard let device = pathRadios.first(where: { $0.key == key }) else { return false }
        select(device: device)
        return true
    }

    // MARK: - Debrief / AI export

    func suggestedExportName() -> String {
        let stamp = Self.stamp()
        switch logExportKind {
        case .logCsv: return app.logs.suggestedExportName(asJsonl: false)
        case .logJsonl: return app.logs.suggestedExportName(asJsonl: true)
        case .gpx, .kml, .wigle: return GeoExport.suggestedName(format: GeoExport.formatOf(kind: logExportKind)!, stamp: stamp)
        }
    }

    func exportMime() -> String {
        switch logExportKind {
        case .logCsv: return app.logs.exportMime(asJsonl: false)
        case .logJsonl: return app.logs.exportMime(asJsonl: true)
        case .gpx, .kml, .wigle: return GeoExport.formatOf(kind: logExportKind)!.mime
        }
    }

    func startFieldDebriefPdf() {
        if export.active { return }
        Task { @MainActor in
            publishExport(progress: 0.05, message: "Writing debrief PDF…")
            do {
                let doc = try await fieldDebriefDoc()
                publishExport(progress: 0.4, message: "Laying out debrief PDF…")
                let file = Self.exportDir().appendingPathComponent("fieldwatch-debrief-\(Self.stamp()).pdf")
                publishExport(progress: 0.32, message: "Loading map tiles…")
                let online = app.config.settings.onlineLookup
                let progress = backgroundProgress()
                try await Self.off {
                    let tiles = Self.pathTilesForFigure(figure: doc.pathFigure, onlineLookup: online)
                    let extraTiles = doc.extraFigures.map { Self.pathTilesForFigure(figure: $0, onlineLookup: online) }
                    try DebriefPdf.write(doc: doc, file: file, tiles: tiles, extraTiles: extraTiles) { p in
                        progress(0.4 + 0.55 * Double(p), "Writing debrief PDF…")
                    }
                }
                export = ExportUi(active: false, progress: 1, share: ShareItem(urls: [file], text: nil, title: debriefSubject(doc: doc)), shareTitle: "Debrief PDF")
            } catch {
                export = ExportUi(error: Self.messageOf(error) ?? "Could not write debrief PDF")
            }
        }
    }

    func startFieldDebrief() {
        if export.active { return }
        Task { @MainActor in
            publishExport(progress: 0.08, message: "Writing debrief…")
            do {
                let doc = try await fieldDebriefDoc()
                publishExport(progress: 0.9, message: "Writing debrief…")
                let subject = debriefSubject(doc: doc)
                let text = doc.toPlainText()
                let item = try await Self.off { try Self.textShare(text: text, subject: subject, fileBase: "fieldwatch-debrief") }
                export = ExportUi(active: false, progress: 1, share: item, shareTitle: "Debrief")
            } catch {
                export = ExportUi(error: Self.messageOf(error) ?? "Could not write debrief")
            }
        }
    }

    private func debriefSubject(doc: DebriefDoc) -> String {
        doc.heading.hasPrefix("FIELDWATCH SIT") ? doc.heading : "Fieldwatch field debrief — last 15 minutes"
    }

    /// Everything Debrief / AI Export read from the runtime, captured on the main actor.
    private struct DebriefInputs {
        var settings: AppSettings
        var fleets: [Fleet]
        var watchlist: [WatchTarget]
        var now: Int
        var sits: SitStore
        var liveDevices: [Sighting]
        var operatorPath: [GpsSample]
        var floods: [FloodBurst]
    }

    private func debriefInputs() -> DebriefInputs {
        DebriefInputs(
            settings: app.config.settings, fleets: app.config.fleets, watchlist: app.config.watchlist, now: nowMs(),
            sits: app.sits, liveDevices: app.devices.devices.value, operatorPath: app.operatorPathCopy(), floods: app.floodBursts()
        )
    }

    private func fieldDebriefDoc() async throws -> DebriefDoc {
        publishExport(progress: 0.08, message: "Gathering sit…")
        let input = debriefInputs()
        let progress = backgroundProgress()
        return try await Self.off {
            let settings = input.settings
            let now = input.now
            let source = input.sits.debriefSource(now: now)
            let devices = source?.devices ?? input.liveDevices
            let path = source?.operatorPath ?? input.operatorPath
            let window = source.map { DebriefWindow(startAt: $0.startAt, endAt: $0.endAt, sitName: $0.name) }
            let places: DebriefPlaces
            if settings.demoMode {
                places = DebriefPlaces.Off
            } else if settings.onlineLookup {
                progress(0.14, "Looking up place names…")
                places = PlaceLookup.lookup(path: path, devices: devices, now: now, onProgress: { msg in progress(0.18, msg) })
            } else {
                places = DebriefPlaces.Off
            }
            progress(0.32, "Building debrief…")
            let w = input.watchlist
            return DebriefReport.document(
                devices: devices,
                fleets: input.fleets,
                settings: settings,
                operatorPath: path,
                now: now,
                places: places,
                window: window,
                customNames: RadioBookmarks.labels(watchlist: w),
                observerNotes: RadioBookmarks.notes(watchlist: w),
                bookmarkedKeys: RadioBookmarks.alertDeviceKeys(watchlist: w),
                watchedFleetIds: RadioBookmarks.watchedFleetIds(watchlist: w),
                mineKeys: RadioBookmarks.mineKeys(watchlist: w),
                floods: source?.floods ?? input.floods,
                gnss: source?.gnss ?? []
            ).withDemoMacs(macs: devices.map { $0.mac }, demo: settings.demoMode, uasIds: devices.compactMap { $0.payloadUasId })
        }
    }

    nonisolated private static let PRIVACY_PREFIX =
        "Privacy mode: MAC tails are **:**:**. UAS ids and GPS coordinates are masked. Logs on this Mac are unchanged.\n\n"

    func startAiExport() {
        if export.active { return }
        Task { @MainActor in
            publishExport(progress: 0.06, message: "Building AI export prompt…")
            let input = debriefInputs()
            let progress = backgroundProgress()
            do {
                let item = try await Self.off {
                    let settings = input.settings
                    let now = input.now
                    let source = input.sits.debriefSource(now: now)
                    let devices = source?.devices ?? input.liveDevices
                    let path = source?.operatorPath ?? input.operatorPath
                    let window = source.map { DebriefWindow(startAt: $0.startAt, endAt: $0.endAt, sitName: $0.name) }
                    let places: DebriefPlaces
                    if settings.demoMode {
                        places = DebriefPlaces.Off
                    } else if settings.onlineLookup {
                        progress(0.12, "Looking up place names…")
                        places = PlaceLookup.lookup(path: path, devices: devices, now: now, onProgress: { msg in progress(0.16, msg) })
                        progress(0.35, "Building AI export prompt…")
                    } else {
                        places = DebriefPlaces.Off
                    }
                    progress(0.4, "Building AI export prompt…")
                    let w = input.watchlist
                    let raw = DebriefPrompt.build(
                        devices: devices,
                        fleets: input.fleets,
                        settings: settings,
                        now: now,
                        operatorPath: path,
                        places: places,
                        window: window,
                        customNames: RadioBookmarks.labels(watchlist: w),
                        observerNotes: RadioBookmarks.notes(watchlist: w),
                        bookmarkedKeys: RadioBookmarks.alertDeviceKeys(watchlist: w),
                        mineKeys: RadioBookmarks.mineKeys(watchlist: w),
                        floods: source?.floods ?? input.floods,
                        gnss: source?.gnss ?? []
                    )
                    let masked = MacUtil.redactPrivateText(
                        text: raw, macs: devices.map { $0.mac }, uasIds: devices.compactMap { $0.payloadUasId }, demo: settings.demoMode
                    )
                    let text = settings.demoMode ? Self.PRIVACY_PREFIX + masked : masked
                    let subject = window.map { "Fieldwatch AI export — sit \($0.sitName ?? "")" } ?? "Fieldwatch AI export — last 15 minutes"
                    return try Self.textShare(text: text, subject: subject, fileBase: "fieldwatch-ai-export")
                }
                export = ExportUi(active: false, progress: 1, share: item, shareTitle: "AI Export")
            } catch {
                export = ExportUi(error: Self.messageOf(error) ?? "Could not build AI export")
            }
        }
    }

    func startDeviceDetailAiExport(device: Sighting) {
        if export.active { return }
        Task { @MainActor in
            publishExport(progress: 0.08, message: "Building AI export prompt…")
            let settings = app.config.settings
            let names = device.fleetIds.map { fleetName(id: $0) }
            let attention = attentionNotesFor(device: device)
            let notes = signatureNotesFor(device: device)
            let fleets = app.config.fleets
            let mine = isMine(deviceKey: device.key)
            let opPath = app.operatorPathCopy()
            let progress = backgroundProgress()
            do {
                let item = try await Self.off {
                    let places: DebriefPlaces
                    if settings.demoMode {
                        places = DebriefPlaces.Off
                    } else if settings.onlineLookup && (settings.tagLocation || device.latitude != nil) {
                        progress(0.15, "Looking up place names…")
                        places = PlaceLookup.lookup(path: opPath, devices: [device], now: nowMs(), onProgress: { msg in progress(0.2, msg) })
                        progress(0.4, "Building AI export prompt…")
                    } else {
                        places = DebriefPlaces.Off
                    }
                    progress(0.45, "Building AI export prompt…")
                    let raw = DeviceDetailPrompt.build(
                        device: device, signatureNames: names, settings: settings, places: places,
                        attentionNotes: attention, signatureNotes: notes, fleets: fleets, mine: mine
                    )
                    let text = Self.maskDevice(raw, device: device, demo: settings.demoMode, prefix: true)
                    let title = Self.maskDevice(device.listTitle(signatureNames: names), device: device, demo: settings.demoMode, prefix: false)
                    return try Self.textShare(text: text, subject: "Fieldwatch AI export — \(title)", fileBase: "fieldwatch-ai-export")
                }
                export = ExportUi(active: false, progress: 1, share: item, shareTitle: "AI Export")
            } catch {
                export = ExportUi(error: Self.messageOf(error) ?? "Could not build AI export")
            }
        }
    }

    func startDeviceDetailShare(device: Sighting) {
        if export.active { return }
        let settings = app.config.settings
        let names = device.fleetIds.map { fleetName(id: $0) }
        let attention = attentionNotesFor(device: device)
        let notes = signatureNotesFor(device: device)
        let fleets = app.config.fleets
        let mine = isMine(deviceKey: device.key)
        Task { @MainActor in
            do {
                let item = try await Self.off {
                    let raw = DeviceDetailText.build(
                        device: device, signatureNames: names, attentionNotes: attention, signatureNotes: notes, fleets: fleets, mine: mine
                    )
                    let text = Self.maskDevice(raw, device: device, demo: settings.demoMode, prefix: true)
                    let title = Self.maskDevice(device.listTitle(signatureNames: names), device: device, demo: settings.demoMode, prefix: false)
                    return try Self.textShare(text: text, subject: "Fieldwatch device detail — \(title)", fileBase: "fieldwatch-device-detail")
                }
                export = ExportUi(share: item, shareTitle: "Device detail")
            } catch {
                export = ExportUi(error: Self.messageOf(error) ?? "Could not share device detail")
            }
        }
    }

    nonisolated private static func maskDevice(_ text: String, device: Sighting, demo: Bool, prefix: Bool) -> String {
        let masked = MacUtil.redactPrivateText(text: text, macs: [device.mac], uasIds: [device.payloadUasId].compactMap { $0 }, demo: demo)
        return (prefix && demo) ? PRIVACY_PREFIX + masked : masked
    }

    // MARK: - Sit export

    func suggestedSitExportName() -> String {
        SitExport.suggestedName(kind: sitExportKind, sitName: sitExportWindow().name, stamp: Self.stamp())
    }

    func sitExportMime() -> String { SitExport.mime(kind: sitExportKind) }

    func startSitExport() {
        if export.active { return }
        Task { @MainActor in
            let item: ShareItem? = await runExport(startMessage: "Preparing sit export…") {
                let kind = sitExportKind
                let (file, sitName) = try await writeSitExport(kind: kind)
                return ShareItem(urls: [file], text: nil, title: SitExport.subject(kind: kind, sitName: sitName))
            }
            if let item { export = ExportUi(active: false, progress: 1, share: item, shareTitle: "Sit export") }
        }
    }

    func startSitSaveToUri(uri: URL) {
        if export.active { return }
        Task { @MainActor in
            let ok: Bool? = await runExport(startMessage: "Saving sit export…") {
                let text = try await sitExportText(kind: sitExportKind)
                try await Self.off { try Self.writeText(text, to: uri) }
                return true
            }
            if ok != nil { export = ExportUi(active: false, progress: 1, saved: true) }
        }
    }

    private func sitExportWindow(now: Int = nowMs()) -> SitExportWindow {
        if let source = app.sits.debriefSource(now: now) {
            return SitExportWindow(name: source.name, devices: source.devices, path: source.operatorPath)
        }
        let start = now - DebriefPrompt.WINDOW_MS
        return SitExportWindow(
            name: "Last 15 minutes",
            devices: app.devices.devices.value.filter { $0.lastSeen >= start || $0.firstSeen >= start },
            path: app.operatorPathCopy().filter { $0.at >= start }
        )
    }

    private func writeSitExport(kind: LogExportKind) async throws -> (URL, String) {
        let text = try await sitExportText(kind: kind)
        let win = sitExportWindow()
        let file = Self.exportDir().appendingPathComponent(SitExport.suggestedName(kind: kind, sitName: win.name, stamp: Self.stamp()))
        try await Self.off { try Self.writeText(text, to: file) }
        return (file, win.name)
    }

    private func sitExportText(kind: LogExportKind) async throws -> String {
        publishExport(progress: 0.08, message: "Gathering sit…")
        let win = sitExportWindow()
        let radios = sitExportRadios
        let watchlist = app.config.watchlist
        let custom = RadioBookmarks.labels(watchlist: watchlist)
        let notes = RadioBookmarks.notes(watchlist: watchlist)
        let mine = RadioBookmarks.mineKeys(watchlist: watchlist)
        let fleets = app.config.fleets
        let extra = Set(win.devices.filter { $0.attentionNotes(fleets: fleets).isNotEmpty }.map { $0.key })
        let rows = SitExport.rows(devices: win.devices, radios: radios)
        if kind == .logCsv || kind == .logJsonl {
            if rows.isEmpty { throw VmError(SitExport.emptyHint(kind: kind, radios: radios)) }
            publishExport(progress: 0.4, message: "Writing \(kind.label) · \(rows.count) radios")
            return try await Self.off {
                kind == .logCsv
                    ? SitExport.csv(devices: win.devices, radios: radios, customNames: custom, observerNotes: notes, extraKeys: extra, fleets: fleets, mineKeys: mine)
                    : SitExport.jsonl(devices: win.devices, radios: radios, customNames: custom, observerNotes: notes, extraKeys: extra, fleets: fleets, mineKeys: mine)
            }
        }
        let pins = SitExport.mapRadios(devices: win.devices, radios: radios)
        if pins.isEmpty { throw VmError(SitExport.emptyHint(kind: kind, radios: radios)) }
        guard let fmt = GeoExport.formatOf(kind: kind) else { throw VmError("Pick a map format.") }
        let info = Self.deviceInfo(full: false)
        publishExport(progress: 0.45, message: "Writing \(kind.label) · \(pins.count) pins")
        let progress = backgroundProgress()
        let version = Self.appVersionName()
        return try await Self.off {
            GeoExport.render(
                format: fmt, radios: pins, names: [:], appVersion: version, deviceInfo: info,
                onProgress: { done, total in
                    if total <= 0 { return }
                    if done == total || done % 250 == 0 {
                        progress(0.50 + 0.45 * Double(done) / Double(total), "Writing \(kind.label) · \(done) of \(total)")
                    }
                },
                customNames: custom,
                observerNotes: notes,
                track: win.path
            )
        }
    }

    // MARK: - Log export

    func startExport() {
        if export.active { return }
        Task { @MainActor in
            let item: ShareItem? = await runExport(startMessage: "Logging paused · preparing file…") {
                let kind = logExportKind
                let radios = logExportRadios
                let logs = app.logs
                let progress = backgroundProgress()
                let file: URL
                switch kind {
                case .logCsv, .logJsonl:
                    let jsonl = kind == .logJsonl
                    file = try await Self.off {
                        try Self.exportBundle(logs: logs, asJsonl: jsonl, radios: radios) { copied, total in Self.reportCopy(progress, copied, total) }
                    }
                case .gpx, .kml, .wigle:
                    file = try await writeMapExport(kind: kind, radios: radios)
                }
                return ShareItem(urls: [file], text: nil, title: Self.exportSubject(kind: kind))
            }
            if let item { export = ExportUi(active: false, progress: 1, share: item) }
        }
    }

    func startSaveToUri(uri: URL) {
        if export.active { return }
        Task { @MainActor in
            let ok: Bool? = await runExport(startMessage: "Logging paused · saving to the location you picked…") {
                let kind = logExportKind
                let radios = logExportRadios
                let logs = app.logs
                let progress = backgroundProgress()
                switch kind {
                case .logCsv, .logJsonl:
                    let jsonl = kind == .logJsonl
                    try await Self.off {
                        try Self.exportToUri(logs: logs, uri: uri, asJsonl: jsonl, radios: radios) { copied, total in Self.reportCopy(progress, copied, total) }
                    }
                case .gpx, .kml, .wigle:
                    let text = try await mapExportText(kind: kind, radios: radios)
                    try await Self.off { try Self.writeText(text, to: uri) }
                }
                return true
            }
            if ok != nil { export = ExportUi(active: false, progress: 1, saved: true) }
        }
    }

    nonisolated private static func exportSubject(kind: LogExportKind) -> String {
        switch kind {
        case .logCsv: return "Fieldwatch log (CSV)"
        case .logJsonl: return "Fieldwatch log (JSON lines)"
        case .gpx: return "Fieldwatch GPX"
        case .kml: return "Fieldwatch KML"
        case .wigle: return "Fieldwatch WiGLE CSV"
        }
    }

    private func writeMapExport(kind: LogExportKind, radios: LogExportRadios) async throws -> URL {
        let text = try await mapExportText(kind: kind, radios: radios)
        guard let fmt = GeoExport.formatOf(kind: kind) else { throw VmError("Pick a map format.") }
        let file = Self.exportDir().appendingPathComponent(GeoExport.suggestedName(format: fmt, stamp: Self.stamp()))
        try await Self.off { try Self.writeText(text, to: file) }
        return file
    }

    private func mapExportText(kind: LogExportKind, radios: LogExportRadios) async throws -> String {
        guard let fmt = GeoExport.formatOf(kind: kind) else { throw VmError("Pick a map format.") }
        publishExport(progress: 0.02, message: "Reading log…")
        let logs = app.logs
        let progress = backgroundProgress()
        let custom = RadioBookmarks.labels(watchlist: app.config.watchlist)
        let info = Self.deviceInfo(full: true)
        let version = Self.appVersionName()
        return try await Self.off {
            let pins = try Self.readRadios(logs: logs) { copied, total in
                let pct = 0.05 + 0.40 * Double(copied) / max(Double(total), 1)
                progress(pct, "Reading log · \(copied / 1024) KB of \(total / 1024) KB")
            }.filter { $0.hasPosition && radios.matches(kind: $0.kind) }
            if pins.isEmpty {
                let which: String
                switch radios {
                case .both: which = "radios"
                case .wifi: which = "Wi-Fi radios"
                case .ble: which = "BLE radios"
                }
                throw VmError("No GPS-tagged \(which). Settings → Tag detections with GPS, logging on, then sit.")
            }
            progress(0.48, "Writing \(kind.label) · \(pins.count) pins")
            return GeoExport.render(
                format: fmt, radios: pins, names: [:], appVersion: version, deviceInfo: info,
                onProgress: { done, total in
                    if total <= 0 { return }
                    if done == total || done % 250 == 0 {
                        progress(0.50 + 0.45 * Double(done) / Double(total), "Writing \(kind.label) · \(done) of \(total)")
                    }
                },
                customNames: custom
            )
        }
    }

    func clearLogs() {
        if export.active { return }
        export = ExportUi(active: true, progress: 0, message: "Clearing log…")
        let logs = app.logs
        Task { @MainActor in
            do {
                let count = try await Self.off { try Self.clearLog(logs: logs) }
                app.devices.bumpLogs(lines: count)
                export = ExportUi(message: "Log cleared", cleared: true)
            } catch {
                export = ExportUi(error: Self.messageOf(error) ?? "Could not clear log")
            }
        }
    }

    func consumeShare() {
        export.share = nil
    }

    func consumeExportNotice() {
        let cur = export
        if cur.followUpTitle != nil {
            export = ExportUi(noticeTitle: cur.followUpTitle, noticeMessage: cur.followUpMessage)
        } else {
            export = ExportUi()
        }
    }

    nonisolated private static func reportCopy(_ progress: (Double, String) -> Void, _ copied: Int, _ total: Int) {
        let pct = (Double(copied) / Double(max(total, 1))).coerceIn(0.0, 1.0)
        progress(pct, "Writing \(copied / 1024) KB of \(total / 1024) KB")
    }

    /// Kotlin publishExport: an active progress state on the main actor.
    private func publishExport(progress: Double, message: String) {
        export = ExportUi(active: true, progress: progress.coerceIn(0.0, 1.0), message: message)
    }

    /// Progress callback for background work. Late ticks after the export finished are dropped.
    private func backgroundProgress() -> (Double, String) -> Void {
        { [weak self] p, msg in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.export.active else { return }
                    self.publishExport(progress: p, message: msg)
                }
            }
        }
    }

    private func runExport<T>(startMessage: String, _ block: () async throws -> T) async -> T? {
        export = ExportUi(active: true, progress: 0, message: startMessage)
        do {
            return try await block()
        } catch {
            export = ExportUi(active: false, error: Self.messageOf(error) ?? "Export failed")
            return nil
        }
    }

    // MARK: - Lookups

    func logBytes() -> Int { app.logs.totalBytes() }

    func fleetName(id: String) -> String { app.config.fleets.first { $0.id == id }?.name ?? id }

    func fleetKind(id: String) -> SignatureClass? { app.config.fleets.first { $0.id == id }?.kind }

    func fleetColor(id: String) -> Int { app.config.fleets.first { $0.id == id }?.colorIndex ?? 0 }

    func fleetAttentionNote(id: String) -> String { app.config.fleets.first { $0.id == id }?.attentionNote ?? "" }

    func hasAttention(device: Sighting) -> Bool { device.fleetIds.contains { fleetAttentionNote(id: $0).isNotBlank } }

    func hasObserverNote(device: Sighting) -> Bool { watchObserverNoteFor(deviceKey: device.key) != nil }

    func fleetHasDecode(id: String) -> Bool { app.config.fleets.first { $0.id == id }?.decode != nil }

    func attentionNotesFor(device: Sighting) -> [(String, String)] { device.attentionNotes(fleets: app.config.fleets) }

    func signatureNotesFor(device: Sighting) -> [(String, String)] { device.signatureNotes(fleets: app.config.fleets) }

    func isWatched(deviceKey: String) -> Bool { app.config.watchlist.contains { $0.deviceKey == deviceKey && $0.alert } }

    func isFleetWatched(id: String) -> Bool { app.config.watchlist.contains { $0.fleetId == id } }

    func testWatchBeep() {
        let settings = app.config.settings
        app.alerter.playTestBeep(beepOn: settings.alertBeep, speakClass: settings.alertVoice, voiceWhat: settings.alertVoiceWhat)
    }

    /// macOS addition: Copy actions (MAC, name, report text).
    func copyToClipboard(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Helpers (off the main actor)

    /// Run blocking work on a global queue (Kotlin withContext(Dispatchers.IO / Default)).
    nonisolated private static func off<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try work()) } catch { cont.resume(throwing: error) }
            }
        }
    }

    // LogStore calls wrapped with `try` so they compile whether or not the Core port marks them throwing.
    nonisolated private static func readRadios(logs: LogStore, onProgress: @escaping (Int, Int) -> Void = { _, _ in }) throws -> [LogRadio] {
        try logs.readRadios(onProgress: onProgress)
    }

    nonisolated private static func exportBundle(logs: LogStore, asJsonl: Bool, radios: LogExportRadios, onProgress: @escaping (Int, Int) -> Void) throws -> URL {
        try logs.exportBundle(asJsonl: asJsonl, radios: radios, onProgress: onProgress)
    }

    nonisolated private static func exportToUri(logs: LogStore, uri: URL, asJsonl: Bool, radios: LogExportRadios, onProgress: @escaping (Int, Int) -> Void) throws {
        try logs.exportToUri(uri: uri, asJsonl: asJsonl, radios: radios, onProgress: onProgress)
    }

    nonisolated private static func clearLog(logs: LogStore) throws -> Int {
        try logs.clear()
    }

    /// `FileManager.default.temporaryDirectory/Fieldwatch-exports` (Android cacheDir/export|debrief|settings|signatures).
    nonisolated private static func exportDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Fieldwatch-exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated private static func stamp() -> String { formatMs(nowMs(), "yyyyMMdd-HHmmss") }

    nonisolated private static func writeText(_ text: String, to url: URL) throws {
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw VmError("Could not write to the location you picked.")
        }
    }

    nonisolated private static func readText(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else { throw VmError("Could not read that file.") }
        return String(decoding: data, as: UTF8.self)
    }

    /// Android text share (EXTRA_SUBJECT + EXTRA_TEXT) → ShareItem with the text and a .txt copy for Save / Reveal.
    nonisolated private static func textShare(text: String, subject: String, fileBase: String) throws -> ShareItem {
        let file = exportDir().appendingPathComponent("\(fileBase)-\(stamp()).txt")
        try writeText(text, to: file)
        return ShareItem(urls: [file], text: text, title: subject)
    }

    /// Android BuildConfig.VERSION_NAME.
    nonisolated private static func appVersionName() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?.nonBlank ?? "1.1.25"
    }

    /// Android `Build.MODEL / VERSION.RELEASE / DEVICE ...` for WiGLE headers.
    nonisolated private static func deviceInfo(full: Bool) -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = "Mac"
        if size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 { model = String(cString: buf) }
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let release = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        var parts = ["model=\(model)", "release=macOS \(release)", "device=Mac"]
        if full {
            parts += ["display=\(ProcessInfo.processInfo.operatingSystemVersionString)", "board=\(model)", "brand=Apple"]
        }
        return parts.joined(separator: ",")
    }

    /// Kotlin `err.message`: nil when the error carries no user-facing text.
    nonisolated private static func messageOf(_ error: Error) -> String? {
        if let e = error as? LocalizedError, let d = e.errorDescription, d.isNotBlank { return d }
        let ns = error as NSError
        if [NSCocoaErrorDomain, NSURLErrorDomain, NSPOSIXErrorDomain].contains(ns.domain) { return ns.localizedDescription }
        return nil
    }
}
