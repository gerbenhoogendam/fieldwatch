import Foundation
import Testing
@testable import FieldwatchCore

// Port of DebriefPromptTest.kt.
struct DebriefPromptTest {
    private let axon = Fleet(
        id: "fleet-axon",
        name: "Axon",
        attentionNote: "Body-worn, in-car, dock, or TASER.",
        kind: .lawEnforcement
    )

    @Test func addendumOmitsFullInventoriesAndKeepsRates() {
        let now = 15 * 60_000
        let cam = promptRadio("WIFI:AA:AA:AA:AA:AA:01", "cam", now, fleetIds: ["fleet-axon"])
        let ble = promptRadio("BLE:BB:BB:BB:BB:BB:02", "tag", now, kind: .ble, rand: true)
        let text = DebriefPrompt.build(
            devices: [cam, ble],
            fleets: [axon],
            settings: AppSettings(),
            now: now
        )
        #expect(text.contains("Do not rewrite that report"))
        #expect(text.contains("RAND BLE"))
        #expect(text.contains("5 min:"))
        #expect(text.contains("15 min:"))
        #expect(text.contains("Extra attention:"))
        #expect(text.contains("Observer notes:"))
        #expect(text.contains("Axon"))
        #expect(text.contains("Takeaway:"))
        #expect(text.contains("decoded live value"))
        #expect(text.contains("A flood note is a burst of new addresses, not a follower."))
        #expect(text.contains("Flood if any"))
        #expect(!text.contains("Full Wi-Fi inventory"))
        #expect(!text.contains("## Persistence (15 min)"))
        #expect(!text.contains("## Channel utilization"))
    }

    @Test func onboardPasteIncludesAFloodLine() {
        let now = 15 * 60_000
        let text = DebriefPrompt.build(
            devices: [],
            fleets: [],
            settings: AppSettings(),
            now: now,
            floods: [
                FloodBurst(
                    at: now - 60_000,
                    popupCount: 8,
                    nameCount: 0,
                    families: ["Apple proximity pairing"],
                    medianRssi: -48
                ),
            ]
        )
        #expect(text.contains("FLOOD"))
        #expect(text.contains(FloodBurst.INTRO))
        #expect(text.contains("8 new addresses"))
    }

    @Test func workingCountsLeaveOutFloodAddresses() {
        let now = 15 * 60_000
        let real = promptRadio("BLE:AC:23:3F:11:22:33", "Checkout beacon", now, kind: .ble)
        let flood = promptRadio("BLE:02:00:00:00:00:01", "spam", now, kind: .ble, rand: true)
        let text = DebriefPrompt.build(
            devices: [real, flood],
            fleets: [],
            settings: AppSettings(),
            now: now,
            floods: [
                FloodBurst(
                    at: now - 60_000,
                    popupCount: 6,
                    nameCount: 0,
                    keys: [flood.key]
                ),
            ]
        )
        #expect(text.contains("15 min: Wi-Fi 0  BLE 1"))
        #expect(text.contains("1 address from this burst is left out of the counts and lists below."))
        #expect(!text.contains("02:00:00:00:00:01"))
    }
}

private func promptRadio(
    _ key: String,
    _ name: String,
    _ now: Int,
    kind: RadioKind = .wifi,
    fleetIds: [String] = [],
    rand: Bool = false
) -> Sighting {
    Sighting(
        key: key,
        kind: kind,
        mac: key.substringAfter(":"),
        name: name,
        rssi: -60,
        rssiMin: -70,
        rssiMax: -50,
        channel: 6,
        frequencyMhz: 2437,
        vendor: nil,
        randomized: rand,
        hiddenSsid: false,
        serviceUuids: [],
        manufacturerId: nil,
        manufacturerDataHex: "",
        rawHex: "",
        extras: "",
        firstSeen: now - 60_000,
        lastSeen: now,
        hitCount: 4,
        fleetIds: fleetIds,
        rssiHistory: [],
        presence: []
    )
}
