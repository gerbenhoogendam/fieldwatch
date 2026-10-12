import Foundation
import Testing
@testable import FieldwatchCore

struct DeviceExplainTest {
    @Test func ravenDirectSsidIsAcousticSensorNotPhoneOrTv() {
        let device = wifi("00:0A:F5:86:56:DD", "DIRECT-rR-Raven-607")
        let guess = DeviceExplain.guess(device: device, signatureNames: ["Raven / ShotSpotter", "Unknown Signature"])
        #expect(guess.headline.contains("Raven", ignoreCase: true), "\(guess.headline)")
        #expect(guess.headline.contains("ShotSpotter", ignoreCase: true), "\(guess.headline)")
        #expect(!guess.headline.contains("phone or TV", ignoreCase: true), "\(guess.headline)")
        #expect(guess.because.contains("Raven / ShotSpotter"), "\(guess.because)")
        #expect(guess.because.contains("DIRECT-"), "\(guess.because)")
    }

    @Test func genericDirectSsidWithoutProductFamilyStillLooksLikeWifiDirect() {
        let device = wifi("02:11:22:33:44:55", "DIRECT-xy-LivingRoom")
        let guess = DeviceExplain.guess(device: device, signatureNames: [])
        #expect(guess.headline.contains("Wi-Fi Direct", ignoreCase: true), "\(guess.headline)")
    }

    @Test func localBitWithGroupBitIsNotAFactoryAddress() {
        var device = wifi("5B:AF:C8:11:22:33", "")
        device.kind = .ble
        device.key = "BLE:5B:AF:C8:11:22:33"
        device.randomized = false
        device.vendor = nil
        device.facts = RadioFacts(addressType: "Public")
        let text = DeviceExplain.addressExplain(device: device)
        #expect(text.contains("local bit", ignoreCase: true), "\(text)")
        #expect(!text.contains("Public factory"), "\(text)")
        var universal = device
        universal.mac = "00:00:0C:11:22:33"
        universal.key = "BLE:00:00:0C:11:22:33"
        #expect(DeviceExplain.addressExplain(device: universal) == "Public factory address (stable, IEEE-assigned).")
    }

    @Test func wifiLocalBitBssidIsNotARotatingPrivacyMac() {
        var ap = wifi("02:0A:F5:86:56:DD", "PS-CRADLEPOINT")
        ap.randomized = true
        let text = DeviceExplain.addressExplain(device: ap)
        #expect(text.contains("Locally administered BSSID"), "\(text)")
        #expect(!text.contains("privacy", ignoreCase: true), "\(text)")
        #expect(!text.contains("can change", ignoreCase: true), "\(text)")
    }

    @Test func rssi127IsNotAvailableNotVeryStrong() {
        #expect(DeviceExplain.rssiExplain(rssi: 127) == "Not available")
        #expect(DeviceExplain.rssiBand(rssi: 127) == "not available")
        #expect(Rssi.sessionRange(min: -103, max: 127, history: [RssiSample(at: 1, rssi: -86), RssiSample(at: 2, rssi: 127)]) == "-103 to -86 dBm")
        #expect(Rssi.lastMeasured(rssi: 127, history: [RssiSample(at: 1, rssi: -99), RssiSample(at: 2, rssi: 127)]) == -99)
    }

    @Test func unknownSignatureNameIsNotAProductGuess() {
        let device = wifi("02:11:22:33:44:56", "DIRECT-ab-TV")
        let guess = DeviceExplain.guess(device: device, signatureNames: ["Unknown Signature"])
        #expect(!guess.headline.contains("Unknown", ignoreCase: true), "\(guess.headline)")
        #expect(guess.headline.contains("Wi-Fi Direct", ignoreCase: true), "\(guess.headline)")
    }

    // macOS: BLE radios are keyed by a CoreBluetooth peripheral UUID, not a MAC.
    @Test func macOpaqueBleIdIsExplainedAsPerMacIdentifier() {
        var device = wifi("00:00:00:00:00:00", "")
        device.kind = .ble
        device.mac = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
        device.key = "BLE:" + device.mac
        device.randomized = true
        device.vendor = nil
        let text = DeviceExplain.addressExplain(device: device)
        #expect(text.contains("per-Mac identifier"), "\(text)")
        #expect(!text.contains("IEEE"), "\(text)")
        #expect(DeviceExplain.listLabel(device: device) == nil)
    }

    private func wifi(_ mac: String, _ name: String) -> Sighting {
        Sighting(
            key: "WIFI:\(mac)", kind: .wifi, mac: mac, name: name, rssi: -86, rssiMin: -86, rssiMax: -76,
            channel: 1, frequencyMhz: 2412, vendor: "Airgo Networks, Inc.", randomized: false, hiddenSsid: false,
            serviceUuids: [], manufacturerId: nil, manufacturerDataHex: "", rawHex: "", extras: "",
            firstSeen: 1, lastSeen: 1, hitCount: 7, fleetIds: [], rssiHistory: [], presence: []
        )
    }
}
