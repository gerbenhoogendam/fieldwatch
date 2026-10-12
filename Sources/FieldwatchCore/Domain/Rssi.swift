import Foundation

/// BLE/Wi-Fi RSSI as received (dBm). Bluetooth uses 127 for "not available".
public enum Rssi {
    public static func measured(rssi: Int) -> Bool { (-127...126).contains(rssi) }

    public static func sessionRange(min: Int, max: Int, history: [RssiSample] = []) -> String {
        var vals: [Int] = []
        if measured(rssi: min) { vals.append(min) }
        if measured(rssi: max) { vals.append(max) }
        for s in history where measured(rssi: s.rssi) { vals.append(s.rssi) }
        guard let lo = vals.min(), let hi = vals.max() else { return "Not available" }
        return lo == hi ? "\(lo) dBm" : "\(lo) to \(hi) dBm"
    }

    public static func lastMeasured(rssi: Int, history: [RssiSample]) -> Int? {
        if measured(rssi: rssi) { return rssi }
        return history.reversed().first { measured(rssi: $0.rssi) }?.rssi
    }
}
