import CoreBluetooth
import Foundation
import IOBluetooth
import Observation
import FieldwatchCore

// macOS addition: Bluetooth devices connected to this Mac (keyboards, game controllers, headphones…).
//
// The rest of Fieldwatch only hears advertisements; a connected device stops advertising, so it never
// shows on Live. This reads what macOS already knows about its own connections:
//   - IOBluetooth: paired devices that are connected, with their real address, class of device and,
//     for links that report it, the signal strength of the existing connection.
//   - CoreBluetooth: connected Bluetooth LE devices (HID, battery, device information). Reading their
//     signal strength and battery level attaches to the link macOS already holds; no new radio
//     connection is made, and letting go never disconnects the device from macOS.
// Optional: "Read signal" can be turned off, leaving only the passive list.

struct ConnectedRadio: Identifiable, Hashable {
    enum Transport: String, Hashable {
        case classic = "Bluetooth Classic"
        case le = "Bluetooth LE"
        case unknown = "Bluetooth"
    }

    /// "CONN:<address>" or "CONN:<peripheral UUID>"; also the Room key.
    var id: String
    /// Your name for it if you gave one, else the name macOS reports.
    var name: String
    var systemName: String
    /// Real Bluetooth address (macOS only exposes it for paired devices).
    var address: String?
    var peripheralId: UUID?
    var transport: Transport
    var typeLabel: String?
    var rssi: Int?
    var battery: Int?
    var lastSeen: Int
}

@Observable final class ConnectedDevices: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = ConnectedDevices()

    static let KEY_PREFIX = "CONN:"
    private static let readSignalKey = "connected.readSignal"
    private static let namesKey = "connected.names"

    /// Names you gave connected devices, by key. Kept on this Mac.
    private(set) var customNames: [String: String] = UserDefaults.standard.dictionary(forKey: ConnectedDevices.namesKey) as? [String: String] ?? [:]

    func setName(key: String, name: String) {
        let n = name.trim()
        if n.isEmpty { customNames.removeValue(forKey: key) } else { customNames[key] = String(n.prefix(60)) }
        UserDefaults.standard.set(customNames, forKey: ConnectedDevices.namesKey)
        poll()
    }
    /// Services that identify connected LE accessories: HID, Battery, Device Information.
    private static let services = [CBUUID(string: "1812"), CBUUID(string: "180F"), CBUUID(string: "180A")]
    private static let batteryLevel = CBUUID(string: "2A19")

    private(set) var radios: [ConnectedRadio] = []
    private(set) var bluetoothReady = false

    /// Read signal strength (and battery) from the existing connections.
    var readSignal: Bool = UserDefaults.standard.object(forKey: ConnectedDevices.readSignalKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(readSignal, forKey: ConnectedDevices.readSignalKey)
            if !readSignal { releaseAll() }
            poll()
        }
    }

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var leRssi: [UUID: (rssi: Int, at: Int)] = [:]
    @ObservationIgnored private var leBattery: [UUID: Int] = [:]
    @ObservationIgnored private var attached: Set<UUID> = []
    @ObservationIgnored private var histories: [String: [RssiSample]] = [:]

    private override init() { super.init() }

    /// Start once; polls every second for the rest of the session (cheap: macOS's own lists).
    func start() {
        guard timer == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    /// Signal history for a connected radio (Room uses it like an advertiser's history).
    func history(key: String) -> [RssiSample] { histories[key] ?? [] }

    func radio(key: String) -> ConnectedRadio? { radios.first { $0.id == key } }

    // MARK: Poll

    private func poll() {
        let now = nowMs()
        var rows: [ConnectedRadio] = []

        // Classic and paired LE devices macOS reports as connected.
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        for dev in paired where dev.isConnected() {
            let address = (dev.addressString ?? "").replace("-", ":").uppercased()
            let raw = readSignal ? Int(dev.rawRSSI()) : 127
            let cod = Int(dev.classOfDevice)
            let type = cod != 0 ? CodDecoder.decodeOrNull(cod: cod).map { [$0.major, $0.minor].filter { $0.isNotEmpty }.joined(separator: " · ") } : nil
            let key = ConnectedDevices.KEY_PREFIX + (address.isEmpty ? (dev.nameOrAddress ?? "?") : address)
            let system = dev.nameOrAddress ?? address
            rows.append(ConnectedRadio(
                id: key,
                name: customNames[key] ?? system,
                systemName: system,
                address: address.nonEmpty,
                peripheralId: nil,
                transport: .unknown,
                typeLabel: type?.nonEmpty,
                rssi: Rssi.measured(rssi: raw) && raw != 0 ? raw : nil,
                battery: nil,
                lastSeen: now
            ))
        }

        // Connected LE accessories (no address from CoreBluetooth; matched to the paired list by name).
        if let central, central.state == .poweredOn {
            let connected = central.retrieveConnectedPeripherals(withServices: ConnectedDevices.services)
            for p in connected {
                peripherals[p.identifier] = p
                p.delegate = self
                if readSignal {
                    if p.state == .connected {
                        p.readRSSI()
                        if leBattery[p.identifier] == nil, p.services == nil { p.discoverServices([CBUUID(string: "180F")]) }
                    } else if p.state == .disconnected {
                        // Attach to the link macOS already holds; this does not open a second connection.
                        central.connect(p)
                        attached.insert(p.identifier)
                    }
                }
                let name = p.name ?? "Bluetooth LE device"
                let le = leRssi[p.identifier].flatMap { now - $0.at < 10_000 ? $0.rssi : nil }
                if let i = rows.firstIndex(where: { $0.peripheralId == nil && $0.systemName.equals(name, ignoreCase: true) }) {
                    rows[i].peripheralId = p.identifier
                    rows[i].transport = .le
                    rows[i].rssi = rows[i].rssi ?? le
                    rows[i].battery = leBattery[p.identifier]
                } else {
                    let key = ConnectedDevices.KEY_PREFIX + p.identifier.uuidString.uppercased()
                    rows.append(ConnectedRadio(
                        id: key,
                        name: customNames[key] ?? name, systemName: name, address: nil, peripheralId: p.identifier, transport: .le,
                        typeLabel: nil, rssi: le, battery: leBattery[p.identifier], lastSeen: now
                    ))
                }
            }
        }

        for r in rows {
            guard let rssi = r.rssi else { continue }
            var h = histories[r.id] ?? []
            h.append(RssiSample(at: now, rssi: rssi))
            if h.count > 180 { h.removeFirst(h.count - 180) }
            histories[r.id] = h
        }
        rows.sort { $0.name.lowercased() < $1.name.lowercased() }
        if rows != radios { radios = rows }
    }

    private func releaseAll() {
        guard let central else { return }
        // Only drops this app's claim; macOS keeps its own connection to the device.
        for id in attached { if let p = peripherals[id] { central.cancelPeripheralConnection(p) } }
        attached.removeAll()
        leRssi.removeAll()
    }

    // MARK: CoreBluetooth

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothReady = central.state == .poweredOn
        poll()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.readRSSI()
        peripheral.discoverServices([CBUUID(string: "180F")])
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        let v = RSSI.intValue
        if Rssi.measured(rssi: v), v != 0 { leRssi[peripheral.identifier] = (v, nowMs()) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] where s.uuid == CBUUID(string: "180F") {
            peripheral.discoverCharacteristics([ConnectedDevices.batteryLevel], for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] where c.uuid == ConnectedDevices.batteryLevel {
            peripheral.readValue(for: c)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == ConnectedDevices.batteryLevel, let b = characteristic.value?.first else { return }
        leBattery[peripheral.identifier] = Int(b)
    }
}
