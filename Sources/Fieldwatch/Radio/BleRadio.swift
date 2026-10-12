import CoreBluetooth
import FieldwatchCore
import Foundation

/// CoreBluetooth port of radio/BleRadio.kt. Passive: scans only, never connects.
///
/// macOS gives no MAC and no raw advertisement bytes. `RadioObservation.mac` is the per-Mac peripheral UUID
/// (uppercase 8-4-4-4-12, see `MacUtil.isOpaqueId`), and the AD byte string is rebuilt from the
/// advertisement dictionary with `BleAdParser.buildAdvertisement` so `BleAdParser.parse` / `rawHex` keep working.
///
/// ScanIntensity → duplicates are always on (every advertisement reaches us); Fieldwatch thins them per peripheral:
/// performance = every advertisement, balanced = at most one per peripheral per ~1 s, saver = one per ~5 s.
public final class BleRadio: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private let onObservation: (RadioObservation) -> Void
    private let onError: (String) -> Void

    private let queue = DispatchQueue(label: "app.fieldwatch.ble", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var central: CBCentralManager?

    // Guarded by `lock` (read from the scan loop, written on the BLE queue).
    private let lock = NSLock()
    private var running = false
    private var wantScan = false
    private var lastIntensity: ScanIntensity = .performance
    private var startedAt = 0
    private var lastCallbackAt = 0
    private var everHeard = false
    private var nextRetryAt = 0
    private var failStreak = 0
    private var lastError: String?
    private var restMs = 2_500
    private var hint = ""
    private var state: CBManagerState = .unknown

    private let hitLock = NSLock()
    private var hitAt: [Int] = []
    private var hitHead = 0

    /// BLE queue only.
    private var lastEmitAt: [UUID: Int] = [:]
    private var lastEmitPruneAt = 0

    public init(onObservation: @escaping (RadioObservation) -> Void, onError: @escaping (String) -> Void) {
        self.onObservation = onObservation
        self.onError = onError
        super.init()
        queue.setSpecific(key: queueKey, value: true)
    }

    // MARK: Control (Kotlin names)

    /// Start (or restart) the scan with this intensity. The first call creates the central manager, which shows
    /// the Bluetooth permission prompt if it was never answered; scanning then begins from `centralManagerDidUpdateState`.
    public func start(intensity: ScanIntensity) {
        onQueue { self.startLocked(intensity: intensity) }
    }

    public func stop() {
        onQueue {
            self.lock.lock()
            self.wantScan = false
            let wasRunning = self.running
            self.running = false
            self.lock.unlock()
            if wasRunning || self.central?.isScanning == true { self.central?.stopScan() }
            self.lastEmitAt.removeAll(keepingCapacity: true)
        }
    }

    public func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Bluetooth controller powered on (Android `adapter.isEnabled`).
    public func radioOn() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state == .poweredOn
    }

    /// Last CoreBluetooth manager state (for Diagnostics).
    public func managerState() -> CBManagerState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public func lastErrorText() -> String? {
        lock.lock(); defer { lock.unlock() }
        return lastError
    }

    public func hitsLastMinute(now: Int) -> Int {
        hitLock.lock(); defer { hitLock.unlock() }
        pruneHits(now: now)
        return hitAt.count - hitHead
    }

    public func holding() -> Bool { !isRunning() }

    public func statusHint() -> String {
        lock.lock(); defer { lock.unlock() }
        return hint
    }

    public func restartBackoffMs() -> Int {
        lock.lock(); defer { lock.unlock() }
        return restMs
    }

    /// Kotlin health check. Not running → restart (after retry backoff). Running but silent for 18 s after
    /// advertisers were heard → "BLE parked · restarting". No periodic recycling: CoreBluetooth does not park a
    /// long scan the way Samsung did.
    public func needsRestart() -> Bool {
        let now = nowMs()
        lock.lock(); defer { lock.unlock() }
        if now < nextRetryAt { return false }
        if !running {
            restMs = failStreak > 0 ? 6_000 : 2_500
            return true
        }
        let runFor = now - startedAt
        let heardAt = lastCallbackAt
        let quietFor = heardAt == 0 ? runFor : now - heardAt
        if everHeard && runFor > 12_000 && quietFor > 18_000 {
            restMs = 2_500
            hint = "BLE parked · restarting"
            return true
        }
        return false
    }

    // MARK: Start

    private func startLocked(intensity: ScanIntensity) {
        let now = nowMs()
        lock.lock()
        if now < nextRetryAt { lock.unlock(); return }
        lastIntensity = intensity
        wantScan = true
        lock.unlock()

        guard let central = ensureCentral() else { return }
        let st = central.state
        lock.lock(); state = st; lock.unlock()
        switch st {
        case .poweredOn:
            break
        case .unknown, .resetting:
            // Waiting for the first state callback; centralManagerDidUpdateState starts the scan.
            return
        case .poweredOff:
            fail(now: now, error: "Bluetooth is off", hint: "Bluetooth is off")
            return
        case .unauthorized:
            fail(now: now, error: "Bluetooth permission needed", hint: "Bluetooth permission needed")
            return
        case .unsupported:
            fail(now: now, error: "BLE scanner unavailable", hint: "BLE unavailable")
            return
        @unknown default:
            fail(now: now, error: "BLE scanner unavailable", hint: "BLE unavailable")
            return
        }
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        if wasRunning || central.isScanning { central.stopScan() }
        startWith(central)
    }

    private func startWith(_ central: CBCentralManager) {
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        lock.lock()
        startedAt = nowMs()
        lastCallbackAt = 0
        running = true
        lastError = nil
        hint = ""
        lock.unlock()
    }

    /// Not-poweredOn states. Kotlin retried these every 8 s.
    private func fail(now: Int, error: String, hint h: String) {
        lock.lock()
        running = false
        lastError = error
        hint = h
        nextRetryAt = now + 8_000
        lock.unlock()
        onError(error)
    }

    private func ensureCentral() -> CBCentralManager? {
        if let c = central { return c }
        let c = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        central = c
        return c
    }

    // MARK: CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let st = central.state
        lock.lock()
        state = st
        let want = wantScan
        let intensity = lastIntensity
        if st != .poweredOn { running = false }
        if st == .poweredOn { nextRetryAt = 0; failStreak = 0 }
        lock.unlock()
        switch st {
        case .poweredOn:
            if want { startLocked(intensity: intensity) }
        case .poweredOff:
            fail(now: nowMs(), error: "Bluetooth is off", hint: "Bluetooth is off")
        case .unauthorized:
            fail(now: nowMs(), error: "Bluetooth permission needed", hint: "Bluetooth permission needed")
        case .unsupported:
            fail(now: nowMs(), error: "BLE scanner unavailable", hint: "BLE unavailable")
        default:
            break
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let now = nowMs()
        recordHit(now: now)
        lock.lock()
        lastCallbackAt = now
        everHeard = true
        failStreak = 0
        lastError = nil
        hint = ""
        let intensity = lastIntensity
        lock.unlock()

        let rssi = RSSI.intValue
        // 127 = RSSI not available on this report.
        if rssi >= 127 { return }
        if !admit(peripheral.identifier, now: now, intensity: intensity) { return }
        emit(peripheral: peripheral, adv: advertisementData, rssi: rssi, now: now)
    }

    // MARK: Thinning

    private func admit(_ id: UUID, now: Int, intensity: ScanIntensity) -> Bool {
        let gap: Int
        switch intensity {
        case .performance: gap = 0
        case .balanced: gap = 1_000
        case .saver: gap = 5_000
        }
        if now - lastEmitPruneAt > 60_000 {
            lastEmitPruneAt = now
            lastEmitAt = lastEmitAt.filter { now - $0.value < 60_000 }
        }
        if gap == 0 { return true }
        if let last = lastEmitAt[id], now - last < gap { return false }
        lastEmitAt[id] = now
        return true
    }

    private func recordHit(now: Int) {
        hitLock.lock(); defer { hitLock.unlock() }
        hitAt.append(now)
        pruneHits(now: now)
        if hitAt.count - hitHead > 4_000 { hitHead = hitAt.count - 4_000 }
        if hitHead > 2_048 {
            hitAt.removeFirst(hitHead)
            hitHead = 0
        }
    }

    /// hitLock held.
    private func pruneHits(now: Int) {
        let cut = now - 60_000
        while hitHead < hitAt.count && hitAt[hitHead] < cut { hitHead += 1 }
    }

    // MARK: RadioObservation

    private func emit(peripheral: CBPeripheral, adv: [String: Any], rssi: Int, now: Int) {
        let obs = BleRadio.toObservation(id: peripheral.identifier, adv: adv, rssi: rssi, now: now)
        onObservation(obs)
    }

    /// Kotlin `toObservation(ScanResult)`. Name is the advertised local name only — `peripheral.name` is the
    /// Mac's cached GAP name, not what is on the air.
    static func toObservation(id: UUID, adv: [String: Any], rssi: Int, now: Int) -> RadioObservation {
        let localName = adv[CBAdvertisementDataLocalNameKey] as? String
        let mfgData = (adv[CBAdvertisementDataManufacturerDataKey] as? Data).map { [UInt8]($0) }
        let serviceUuids = (adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let serviceDataMap = (adv[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]) ?? [:]
        let txPower = (adv[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue
        let connectable = (adv[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        let solicited = (adv[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID]) ?? []
        let overflow = (adv[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []

        // Stable order so the rebuilt bytes (rawHex) do not shuffle between hears.
        let serviceData: [(uuid: String, data: [UInt8])] = serviceDataMap
            .map { (uuid: $0.key.uuidString.uppercased(), data: [UInt8]($0.value)) }
            .sorted { $0.uuid < $1.uuid }

        let bytes = BleAdParser.buildAdvertisement(
            localName: localName,
            manufacturerData: mfgData,
            serviceUuids: serviceUuids.map { $0.uuidString.uppercased() },
            serviceData: serviceData,
            txPower: txPower,
            solicitedUuids: solicited.map { $0.uuidString.uppercased() },
            overflowUuids: overflow.map { $0.uuidString.uppercased() }
        )
        let parsed = BleAdParser.parse(bytes: bytes)
        let name = [parsed.localName, localName]
            .compactMap { $0?.trim().trim("\"").nonBlank }
            .first ?? ""
        // Android ParcelUuid.toString() is always the 128-bit form; parsed.uuids carries the short forms.
        let uuids = (serviceUuids + serviceDataMap.keys.sorted { $0.uuidString < $1.uuidString })
            .map { full128($0.uuidString) }
            + parsed.uuids
        let facts = BleAdParser.facts(parsed: parsed, connectable: connectable, txPowerFromScan: nil)
        let mfg = facts.mfgRecords.first
        return RadioObservation(
            kind: .ble,
            mac: id.uuidString.uppercased(),
            name: name,
            rssi: rssi,
            channel: 0,
            frequencyMhz: 2402,
            hiddenSsid: false,
            serviceUuids: uuids.distinct(),
            manufacturerId: mfg?.companyId,
            manufacturerDataHex: mfg?.dataHex ?? "",
            rawHex: bytes.toHexUpper().take(1024),
            extras: "",
            at: now,
            facts: facts
        )
    }

    /// CBUUID short strings ("FEAA", "0000FEAA") → Bluetooth base 128-bit, upper case.
    static func full128(_ raw: String) -> String {
        let u = raw.uppercased()
        switch u.count {
        case 4: return "0000\(u)-0000-1000-8000-00805F9B34FB"
        case 8: return "\(u)-0000-1000-8000-00805F9B34FB"
        default: return u
        }
    }

    // MARK: Queue

    private func onQueue(_ f: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true { f() } else { queue.sync(execute: f) }
    }
}
