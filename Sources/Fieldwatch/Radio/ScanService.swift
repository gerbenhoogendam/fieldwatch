import FieldwatchCore
import Foundation

/// Port of radio/ScanService.kt without the Android foreground-service plumbing (no notification).
/// `FieldwatchApp.startScanning()` / `stopScanning()` create, start and stop it.
///
/// Threads (nothing runs on the main thread):
/// - `loopQueue`: the 2 s tick (DispatchSourceTimer), radio restarts.
/// - `ingestQueue`: drains the inbound observation buffer in batches of up to 80 (Kotlin `drainInbound`).
/// - `publishQueue`: `publishNow` (DeviceStore refresh, alerts, TAK), at most every `PUBLISH_MS`.
/// Radios call back on their own queues and only append to the bounded inbound buffer.
public final class ScanService: @unchecked Sendable {
    private let app: FieldwatchApp
    private var wifi: WifiRadio!
    private var ble: BleRadio!

    private let loopQueue = DispatchQueue(label: "app.fieldwatch.scan.loop", qos: .userInitiated)
    private let ingestQueue = DispatchQueue(label: "app.fieldwatch.scan.ingest", qos: .userInitiated)
    private let publishQueue = DispatchQueue(label: "app.fieldwatch.scan.publish", qos: .userInitiated)
    private var loop: DispatchSourceTimer?

    private let stateLock = NSLock()
    private var running = false
    private var lastIntensity: ScanIntensity?
    /// Staggered first BLE start, or the rest between a BLE stop and restart.
    private var bleStartScheduled = false
    private var bleResting = false
    private var activity: NSObjectProtocol?

    private let inboundLock = NSLock()
    private var inbound: [RadioObservation] = []
    private var inboundHead = 0
    private var draining = false

    private let publishGate = NSLock()
    private var lastPublishAt = 0
    private var publishScheduled = false
    private var wifiBatchPending = false

    public init(app: FieldwatchApp) {
        self.app = app
        wifi = WifiRadio(
            onObservation: { [weak self] in self?.offer(observation: $0) },
            onScanFinished: { _, _ in },
            onFreshScan: { [weak self] batch in
                guard let self else { return }
                let now = nowMs()
                self.app.wifiFlood.scan(observations: batch, now: now)
                self.app.sits.noteFloods(incoming: self.app.wifiFlood.bursts())
            }
        )
        ble = BleRadio(
            onObservation: { [weak self] in self?.offer(observation: $0) },
            onError: { [weak self] msg in
                guard let self else { return }
                self.app.devices.setRadioHold(wifi: self.wifi.waitingOnOs(), ble: true)
                self.app.devices.setScanning(on: true, throttleHint: msg)
            }
        )
    }

    public func isRunning() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    /// Kotlin `onCreate`: radios on, tick loop and ingest pump running.
    public func start() {
        stateLock.lock()
        if running { stateLock.unlock(); return }
        running = true
        stateLock.unlock()

        // App Nap would stretch the tick and CoreBluetooth callbacks while the window is hidden.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Fieldwatch passive Wi-Fi and BLE scan"
        )
        app.devices.setScanning(on: true, throttleHint: wifi.throttleHint())
        loopQueue.async {
            self.publishScanRadio()
            self.restartRadios()
        }
        DispatchQueue.main.async { self.app.syncLocationUpdates() }

        let t = DispatchSource.makeTimerSource(queue: loopQueue)
        t.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(ScanService.TICK_MS), leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        loop = t
        t.resume()
    }

    /// Kotlin `onDestroy`.
    public func stop() {
        stateLock.lock()
        if !running { stateLock.unlock(); return }
        running = false
        bleStartScheduled = false
        bleResting = false
        stateLock.unlock()

        loop?.cancel()
        loop = nil
        inboundLock.lock()
        inbound.removeAll()
        inboundHead = 0
        inboundLock.unlock()
        wifi.stop()
        ble.stop()
        app.tak.close()
        app.devices.setScanning(on: false)
        DispatchQueue.main.async { self.app.stopLocationUpdates() }
        if let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    // MARK: Tick

    private func tick() {
        guard isRunning() else { return }
        let settings = app.config.settings
        stateLock.lock()
        let intensityChanged = lastIntensity != settings.intensity
        stateLock.unlock()
        if intensityChanged { restartRadios() }

        wifi.requestScan(minIntervalMs: WifiRadio.intervalMs(intensity: settings.intensity), unthrottled: !WifiRadio.osScanThrottled())
        if !bleStartPending() && !isBleResting() && ble.needsRestart() {
            app.devices.setRadioHold(wifi: wifi.waitingOnOs(), ble: true)
            if ble.isRunning() {
                ble.stop()
                let rest = ble.restartBackoffMs()
                stateLock.lock(); bleResting = true; stateLock.unlock()
                loopQueue.asyncAfter(deadline: .now() + .milliseconds(rest)) { [weak self] in
                    guard let self else { return }
                    self.stateLock.lock(); self.bleResting = false; let on = self.running; self.stateLock.unlock()
                    if on { self.ble.start(intensity: self.app.config.settings.intensity) }
                }
            } else {
                ble.start(intensity: settings.intensity)
            }
        }
        app.devices.setRadioHold(wifi: wifi.waitingOnOs(), ble: ble.holding())
        let hint = [wifi.throttleHint(), ble.statusHint()]
            .filter { $0.isNotBlank }
            .joined(separator: " · ")
        app.devices.setScanning(on: true, throttleHint: hint)
        publishScanRadio()
        app.pairingFlood.tick(now: nowMs(), speedMps: app.floodSpeed())
        app.sits.noteFloods(incoming: app.pairingFlood.bursts())
        app.sits.noteFloods(incoming: app.wifiFlood.bursts())
        // GNSS interference check: no GNSS receiver on a Mac (Android called app.syncGnss / sits.noteGnss here).
        publishQueue.async { self.publishNow() }
    }

    /// loopQueue.
    private func restartRadios() {
        let intensity = app.config.settings.intensity
        stateLock.lock()
        lastIntensity = intensity
        stateLock.unlock()
        wifi.start()
        if ble.isRunning() {
            ble.start(intensity: intensity)
            return
        }
        stateLock.lock()
        if bleStartScheduled { stateLock.unlock(); return }
        bleStartScheduled = true
        stateLock.unlock()
        // Kotlin staggered BLE after the first Wi-Fi scan; kept so both prompts / radios do not start on one frame.
        loopQueue.asyncAfter(deadline: .now() + .milliseconds(ScanService.BLE_START_STAGGER_MS)) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let on = self.running
            self.stateLock.unlock()
            if on { self.ble.start(intensity: self.app.config.settings.intensity) }
            self.stateLock.lock(); self.bleStartScheduled = false; self.stateLock.unlock()
        }
    }

    private func bleStartPending() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return bleStartScheduled && !ble.isRunning()
    }

    private func isBleResting() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return bleResting
    }

    private func publishScanRadio() {
        let bleHint = ble.statusHint()
        app.devices.setScanRadio(
            wifiOn: wifi.radioOn(),
            wifiWaiting: wifi.waitingOnOs(),
            bleOn: ble.radioOn(),
            bleRunning: ble.isRunning(),
            bleParked: bleHint == "BLE parked · restarting",
            bleRetrying: bleHint == "BLE retrying" || bleHint == "BLE unavailable",
            bleStarting: bleStartPending() && !ble.isRunning(),
            bleHitsLastMin: ble.hitsLastMinute(now: nowMs())
        )
    }

    // MARK: Inbound

    private func offer(observation: RadioObservation) {
        if observation.mac.isBlank { return }
        inboundLock.lock()
        guard isRunningUnlockedInbound() else { inboundLock.unlock(); return }
        inbound.append(observation)
        // Drop-oldest at 512 (Kotlin Channel(512, DROP_OLDEST)).
        if inbound.count - inboundHead > ScanService.INBOUND_CAP { inboundHead = inbound.count - ScanService.INBOUND_CAP }
        let kick = !draining
        draining = true
        inboundLock.unlock()
        if kick { ingestQueue.async { self.drainInbound() } }
    }

    private func isRunningUnlockedInbound() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    private func takeBatch() -> [RadioObservation] {
        inboundLock.lock(); defer { inboundLock.unlock() }
        let n = min(ScanService.BATCH_MAX, inbound.count - inboundHead)
        if n <= 0 {
            inbound.removeAll(keepingCapacity: true)
            inboundHead = 0
            draining = false
            return []
        }
        let out = Array(inbound[inboundHead..<(inboundHead + n)])
        inboundHead += n
        if inboundHead >= 1_024 || inboundHead == inbound.count {
            inbound.removeFirst(inboundHead)
            inboundHead = 0
        }
        return out
    }

    /// ingestQueue.
    private func drainInbound() {
        while true {
            let batch = takeBatch()
            if batch.isEmpty { return }
            ingest(batch: batch)
        }
    }

    private func ingest(batch: [RadioObservation]) {
        let settings = app.config.settings
        if settings.tagLocation { app.refreshFix() }
        let fix = settings.tagLocation ? app.lastFix : nil
        let tagged: [RadioObservation]
        if let fix {
            tagged = batch.map { o in
                var c = o
                c.latitude = fix.0
                c.longitude = fix.1
                return c
            }
        } else {
            tagged = batch
        }
        let fleets = app.config.fleets
        let seen = app.devices.ingestBatch(observations: tagged, fleets: fleets, staleSec: settings.staleSec)
        if let fix {
            // Map view: loudness heard at this Mac's position, per radio.
            for i in seen.indices where i < tagged.count {
                app.positions.record(key: seen[i].key, lat: fix.0, lon: fix.1, rssi: tagged[i].rssi, at: tagged[i].at)
            }
        }
        for i in seen.indices where i < tagged.count {
            let row = seen[i]
            if row.kind != .ble || row.hitCount != 1 { continue }
            app.pairingFlood.consider(obs: tagged[i], now: row.lastSeen, speedMps: app.floodSpeed())
        }
        app.sits.noteFloods(incoming: app.pairingFlood.bursts())
        app.sits.ingest(seen: seen, fleets: fleets, watchlist: app.config.watchlist)
        if settings.loggingEnabled {
            let toLog = seen.filter { $0.hitCount <= 1 || $0.hitCount % 25 == 0 }.take(16)
            for row in toLog { _ = app.logs.append(device: row, fleets: fleets) }
            if toLog.isNotEmpty { app.devices.bumpLogs(lines: app.logs.lineCount) }
        }
        if tagged.any({ $0.kind == .wifi && $0.fresh }) {
            publishGate.lock(); wifiBatchPending = true; publishGate.unlock()
        }
        schedulePublish()
    }

    // MARK: Publish

    private static func uptimeMs() -> Int { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

    private func schedulePublish() {
        let now = ScanService.uptimeMs()
        publishGate.lock()
        if lastPublishAt == 0 || now - lastPublishAt >= ScanService.PUBLISH_MS {
            lastPublishAt = now
            publishGate.unlock()
            publishQueue.async { self.publishNow() }
            return
        }
        if publishScheduled { publishGate.unlock(); return }
        publishScheduled = true
        let wait = max(0, ScanService.PUBLISH_MS - (now - lastPublishAt))
        publishGate.unlock()
        publishQueue.asyncAfter(deadline: .now() + .milliseconds(wait)) {
            self.publishGate.lock()
            self.lastPublishAt = ScanService.uptimeMs()
            self.publishScheduled = false
            self.publishGate.unlock()
            self.publishNow()
        }
    }

    /// publishQueue.
    private func publishNow() {
        guard isRunning() else { return }
        let fleets = app.config.fleets
        let settings = app.config.settings
        app.devices.refresh(fleets: fleets, staleSec: settings.staleSec, policy: settings.detectionPolicy(), decaySec: settings.decaySec)
        publishGate.lock()
        let freshWifi = wifiBatchPending
        wifiBatchPending = false
        publishGate.unlock()
        if freshWifi { app.onFreshWifiBatch() }
        let live = app.devices.devices.value
        let liveKeys = Set(live.map { $0.key })
        app.pairingFlood.prune(liveKeys: liveKeys)
        app.wifiFlood.prune(liveKeys: liveKeys)
        let watchlist = app.config.watchlist
        if settings.alertsEnabled && watchlist.isNotEmpty {
            let a = app
            app.alerter.checkLive(
                devices: live,
                fleets: fleets,
                watchlist: watchlist,
                alertsOn: true,
                beepOn: settings.alertBeep,
                voiceOn: settings.alertVoice,
                voiceWhat: settings.alertVoiceWhat,
                shadeOn: settings.alertShade,
                visibleOnLive: { a.wouldShowOnLive(device: $0) },
                arrivalsOnly: app.config.filter.arrivalsOnly,
                demoMode: settings.demoMode
            )
        }
        // No GNSS receiver: notice/lives are always empty on the Mac; the flood line still rides the self marker.
        let floodNotice = app.pairingFlood.notice.value ?? app.wifiFlood.notice.value
        let phoneNote = [
            TakGnss.line(mode: settings.takGnss, notice: nil, lives: []),
            TakFlood.line(mode: settings.takFlood, notice: floodNotice),
        ].compactMap { $0 }.joined(separator: "\n").nonBlank
        app.tak.publish(
            devices: live,
            fleets: fleets,
            settings: settings,
            watchlist: watchlist,
            selfFix: app.lastFix,
            gnssRemark: phoneNote,
            gnssNotice: nil,
            gnssLives: []
        )
    }

    // MARK: Companion

    public static let PUBLISH_MS = 200
    public static let BLE_START_STAGGER_MS = 500
    public static let TICK_MS = 2_000
    private static let INBOUND_CAP = 512
    private static let BATCH_MAX = 80
}
