import Foundation
import Testing
@testable import FieldwatchCore

// Port of test/java/app/fieldwatch/domain/WifiBeaconFloodTest.kt.

struct WifiBeaconFloodTest {
    @Test func firstScanStaysQuietWhenTheCrowdLeaves() {
        let flood = WifiBeaconFlood()
        let crowd = [anchor()] + spam(count: 20)
        flood.scan(observations: crowd, now: at(0))
        #expect(flood.notice.value == nil)
        flood.scan(observations: [anchor()], now: at(1))
        #expect(flood.notice.value == nil)
        #expect(flood.bursts().isEmpty)
    }

    @Test func meshExtenderGuestAndHiddenStayOut() {
        let flood = WifiBeaconFlood()
        let known = (1...15).map { ap(10 + $0, "Net\(format("%02d", $0))", rssi: -60, channel: 1) }
        flood.scan(observations: [anchor()] + known, now: at(0))
        let suffixes = [
            "Guest", "5G", "ext", "2.4", "5GHz", "extender", "guests",
            "6G", "2.4GHz", "6GHz", "guest", "5g", "EXT", "2.4g", "Guests",
        ]
        let guests = suffixes.enumerated().map { i, suffix in
            ap(200 + i, "Net\(format("%02d", i + 1))-\(suffix)")
        }
        flood.scan(observations: [anchor()] + guests, now: at(1))
        flood.scan(observations: [anchor()], now: at(2))
        #expect(flood.notice.value == nil)

        let mesh = WifiBeaconFlood()
        mesh.scan(observations: [anchor()], now: at(0))
        mesh.scan(observations: [anchor()] + (0..<20).map { ap(300 + $0, "BuildingMesh") }, now: at(1))
        mesh.scan(observations: [anchor()], now: at(2))
        #expect(mesh.notice.value == nil)

        let hidden = WifiBeaconFlood()
        hidden.scan(observations: [anchor()], now: at(0))
        hidden.scan(observations: [anchor()] + (0..<20).map { ap(400 + $0, "") }, now: at(1))
        hidden.scan(observations: [anchor()], now: at(2))
        #expect(hidden.notice.value == nil)
        #expect(hidden.bursts().isEmpty)
    }

    @Test func spreadRssiMixedChannelsAndAShortListStayOut() {
        let spread = WifiBeaconFlood()
        spread.scan(observations: [anchor()], now: at(0))
        let wide = (0..<15).map { ap(100 + $0, "Wide\($0)", rssi: -30 - $0 * 4) }
        spread.scan(observations: [anchor()] + wide, now: at(1))
        spread.scan(observations: [anchor()], now: at(2))
        #expect(spread.notice.value == nil)

        let mixed = WifiBeaconFlood()
        mixed.scan(observations: [anchor()], now: at(0))
        let bands = (0..<8).map { ap(100 + $0, "A\($0)", channel: 1) } +
            (0..<8).map { ap(200 + $0, "B\($0)", channel: 6) } +
            (0..<8).map { ap(300 + $0, "C\($0)", channel: 11) }
        mixed.scan(observations: [anchor()] + bands, now: at(1))
        mixed.scan(observations: [anchor()], now: at(2))
        #expect(mixed.notice.value == nil)

        let short = WifiBeaconFlood()
        short.scan(observations: [anchor()], now: at(0))
        short.scan(observations: [anchor()] + spam(count: 14), now: at(1))
        short.scan(observations: [anchor()], now: at(2))
        #expect(short.notice.value == nil)

        let unmeasured = WifiBeaconFlood()
        unmeasured.scan(observations: [anchor()], now: at(0))
        unmeasured.scan(observations: [anchor()] + (0..<20).map { ap(100 + $0, "Blank\($0)", rssi: 127) }, now: at(1))
        unmeasured.scan(observations: [anchor()], now: at(2))
        #expect(unmeasured.notice.value == nil)
        #expect(unmeasured.bursts().isEmpty)
    }

    @Test func aClusterThatStaysIsNotAFlood() {
        let flood = WifiBeaconFlood()
        let batch = [anchor()] + spam()
        flood.scan(observations: [anchor()], now: at(0))
        flood.scan(observations: batch, now: at(1))
        flood.scan(observations: batch, now: at(2))
        flood.scan(observations: batch, now: at(3))
        #expect(flood.notice.value == nil)
        #expect(flood.bursts().isEmpty)
    }

    @Test func oneSurvivorDropsThePendingSet() {
        let flood = WifiBeaconFlood()
        let names = spam()
        flood.scan(observations: [anchor()], now: at(0))
        flood.scan(observations: [anchor()] + names, now: at(1))
        flood.scan(observations: [anchor(), names[0]], now: at(2))
        flood.scan(observations: [anchor()], now: at(3))
        #expect(flood.notice.value == nil)
        #expect(flood.bursts().isEmpty)
    }

    @Test func aNewPlaceDoesNotConfirmThePreviousCluster() {
        let flood = WifiBeaconFlood()
        let home = anchor()
        flood.scan(observations: [home], now: at(0))
        flood.scan(observations: [home] + spam(), now: at(1))
        let office = (1...5).map { ap(500 + $0, "Office\($0)", rssi: -55, channel: 1) }
        flood.scan(observations: office, now: at(2))
        #expect(flood.notice.value == nil)
        flood.scan(observations: [home], now: at(3))
        #expect(flood.notice.value == nil)
        #expect(flood.bursts().isEmpty)
    }

    @Test func aCachedScanDoesNotCountOrClearAPendingSet() throws {
        let flood = WifiBeaconFlood()
        let crowd = [anchor()] + spam(count: 20)
        flood.scan(observations: crowd.map { cached($0) }, now: at(0))
        flood.scan(observations: crowd, now: at(1))
        flood.scan(observations: [anchor()], now: at(2))
        #expect(flood.notice.value == nil)

        let pending = WifiBeaconFlood()
        let names = spam()
        pending.scan(observations: [anchor()], now: at(0))
        pending.scan(observations: [anchor()] + names, now: at(1))
        pending.scan(observations: [anchor()].map { cached($0) }, now: at(2))
        #expect(pending.notice.value == nil)
        pending.scan(observations: [anchor()], now: at(3))
        #expect(try #require(pending.notice.value).popupCount == 15)
    }

    @Test func aSecondCallbackInsideThreeSecondsDoesNotConfirm() throws {
        let flood = WifiBeaconFlood()
        let spamAt = at(1)
        flood.scan(observations: [anchor()], now: at(0))
        flood.scan(observations: [anchor()] + spam(), now: spamAt)
        flood.scan(observations: [anchor()], now: spamAt + 1_000)
        #expect(flood.notice.value == nil)
        flood.scan(observations: [anchor()], now: spamAt + 30_000)
        #expect(try #require(flood.notice.value).popupCount == 15)
    }

    @Test func goneTogetherOnOneChannelOpensOneDialog() throws {
        let flood = WifiBeaconFlood()
        let names = spam()
        let edge = (0..<14).map { ap(100 + $0, "Edge\($0)", rssi: -40) } + [ap(114, "Edge14", rssi: -46)]
        let outlier = ap(180, "Louder", rssi: -70)
        let otherChannel = ap(181, "Printer", rssi: -40, channel: 11)
        flood.scan(observations: [anchor()], now: at(0))
        flood.scan(observations: [anchor(), otherChannel, outlier] + names, now: at(1))
        flood.scan(observations: [anchor(), otherChannel], now: at(2))
        let notice = try #require(flood.notice.value)
        #expect(notice.showDialog)
        #expect(notice.wifi)
        #expect(notice.title() == "Wi-Fi beacon flood")
        #expect(notice.popupCount == 15)
        #expect(notice.medianRssi == -34)
        #expect(notice.line() == "Wi-Fi beacon flood · 15 new names · about -34 dBm")
        #expect(notice.body().contains("15 new Wi-Fi names showed up in one scan, about the same loudness, about -34 dBm,"))
        #expect(notice.body().contains("A repeated name, a mesh, an extender, or a guest network is not counted."))
        #expect(notice.body().contains("The advertisement does not name the tool."))
        #expect(!notice.body().contains("Remote ID"))
        let bursts = flood.bursts()
        try #require(bursts.count == 1)
        let burst = bursts[0]
        #expect(burst.wifi)
        #expect(burst.popupCount == 15)
        #expect(Set(burst.keys) == Set(names.map { "WIFI:\(macOf($0))" }))
        #expect(!burst.keys.contains("WIFI:\(mac(1))"))
        #expect(!burst.keys.contains("WIFI:\(mac(180))"))
        #expect(!burst.keys.contains("WIFI:\(mac(181))"))
        #expect(
            burst.reportLine(clock: "12:04") ==
                "12:04 UTC. Wi-Fi beacon flood. 15 new names · about -34 dBm. 15 addresses from this burst are left out of the counts and lists below."
        )

        let band = WifiBeaconFlood()
        band.scan(observations: [anchor()], now: at(0))
        band.scan(observations: [anchor()] + edge, now: at(1))
        band.scan(observations: [anchor()], now: at(2))
        let bandBursts = band.bursts()
        try #require(bandBursts.count == 1)
        #expect(bandBursts[0].keys.count == 15)
        #expect(bandBursts[0].keys.contains("WIFI:\(mac(114))"))
    }

    @Test func aSecondRotatingBatchStaysOneEpisode() throws {
        let flood = WifiBeaconFlood()
        let first = spam(start: 100)
        let second = spam(start: 300)
        flood.scan(observations: [anchor()], now: at(0))
        flood.scan(observations: [anchor()] + first, now: at(1))
        flood.scan(observations: [anchor()] + second, now: at(2))
        let opened = try #require(flood.notice.value)
        try #require(flood.bursts().count == 1)
        let firstAt = flood.bursts()[0].at
        #expect(opened.showDialog)
        #expect(opened.popupCount == 15)
        flood.dismiss()
        flood.setHideBurst(on: true)
        #expect(!(try #require(flood.notice.value)).showDialog)
        #expect(flood.hide.value.keys.count == 15)
        flood.scan(observations: [anchor()], now: at(3))
        let grown = try #require(flood.notice.value)
        #expect(!grown.showDialog)
        #expect(grown.popupCount == 30)
        try #require(flood.bursts().count == 1)
        let burst = flood.bursts()[0]
        #expect(burst.at == firstAt)
        #expect(burst.keys.count == 30)
        #expect(flood.hide.value.keys.count == 30)
        #expect(flood.hide.value.episodeOn)
        flood.scan(observations: [anchor()], now: at(4))
        #expect(flood.notice.value == nil)
        #expect(!flood.hide.value.episodeOn)
        #expect(flood.hide.value.keys.count == 30)

        let again = spam(start: 500)
        flood.scan(observations: [anchor()] + again, now: at(5))
        flood.scan(observations: [anchor()], now: at(6))
        flood.setHideBurst(on: false)
        #expect(flood.bursts().count == 2)
        #expect(flood.hide.value.keys.count == 30)
        #expect(flood.hide.value.keys.contains("WIFI:\(mac(100))"))
        #expect(!flood.hide.value.keys.contains("WIFI:\(mac(500))"))
    }

    @Test func continueDuringASitDoesNotAskAgain() throws {
        let flood = WifiBeaconFlood()
        flood.setSitOpen(open: true)
        flood.scan(observations: [anchor()], now: at(0))
        flood.scan(observations: [anchor()] + spam(start: 100), now: at(1))
        flood.scan(observations: [anchor()], now: at(2))
        #expect(try #require(flood.notice.value).showDialog)
        #expect(try #require(flood.notice.value).duringSit)
        flood.dismiss()
        flood.scan(observations: [anchor()], now: at(3))
        #expect(flood.notice.value == nil)
        flood.scan(observations: [anchor()] + spam(start: 300), now: at(4))
        flood.scan(observations: [anchor()], now: at(5))
        #expect(!(try #require(flood.notice.value)).showDialog)
        #expect(flood.bursts().count == 2)
        #expect(!flood.hide.value.episodeOn)
        flood.setSitOpen(open: false)
        flood.scan(observations: [anchor()], now: at(6))
        flood.scan(observations: [anchor()] + spam(start: 500), now: at(7))
        flood.scan(observations: [anchor()], now: at(8))
        #expect(try #require(flood.notice.value).showDialog)
    }

    @Test func continueHoldsForFifteenMinutesThenAsksAgain() throws {
        let flood = WifiBeaconFlood()
        flood.scan(observations: [anchor()], now: 1_000)
        flood.scan(observations: [anchor()] + spam(start: 100), now: 10_000)
        flood.scan(observations: [anchor()], now: 20_000)
        #expect(try #require(flood.notice.value).showDialog)
        #expect(try #require(flood.notice.value).body().contains("for about the next 15 minutes"))
        flood.dismiss()
        flood.scan(observations: [anchor()], now: 30_000)
        #expect(flood.notice.value == nil)
        flood.scan(observations: [anchor()] + spam(start: 300), now: 40_000)
        flood.scan(observations: [anchor()], now: 50_000)
        #expect(!(try #require(flood.notice.value)).showDialog)
        #expect(try #require(flood.notice.value).line().hasPrefix("Wi-Fi beacon flood"))
        flood.scan(observations: [anchor()], now: 60_000)
        #expect(flood.notice.value == nil)
        let later = 20_000 + WifiBeaconFlood.HOLD_MS
        flood.scan(observations: [anchor()] + spam(start: 500), now: later)
        flood.scan(observations: [anchor()], now: later + 10_000)
        #expect(try #require(flood.notice.value).showDialog)
    }

    @Test func hideDuringASitHidesTheNextBurst() throws {
        let flood = WifiBeaconFlood()
        flood.setSitOpen(open: true)
        let first = spam(start: 100)
        flood.scan(observations: [anchor()], now: at(0))
        flood.scan(observations: [anchor()] + first, now: at(1))
        flood.scan(observations: [anchor()], now: at(2))
        flood.setHideBurst(on: true)
        flood.dismiss()
        #expect(flood.hide.value.keys.count == 15)
        flood.scan(observations: [anchor()], now: at(3))
        #expect(flood.notice.value == nil)
        let second = spam(start: 300)
        flood.scan(observations: [anchor()] + second, now: at(4))
        flood.scan(observations: [anchor()], now: at(5))
        #expect(!(try #require(flood.notice.value)).showDialog)
        #expect(flood.hide.value.episodeOn)
        #expect(flood.hide.value.keys.count == 30)
        #expect(flood.hide.value.keys.contains("WIFI:\(macOf(second[0]))"))
    }

    @Test func theLowerChannelWinsATie() throws {
        let flood = WifiBeaconFlood()
        let low = (0..<15).map { ap(100 + $0, "Low\($0)", channel: 1) }
        let high = (0..<15).map { ap(200 + $0, "High\($0)", channel: 11) }
        flood.scan(observations: [anchor()], now: at(0))
        flood.scan(observations: [anchor()] + low + high, now: at(1))
        flood.scan(observations: [anchor()], now: at(2))
        let bursts = flood.bursts()
        try #require(bursts.count == 1)
        let keys = Set(bursts[0].keys)
        #expect(keys == Set(low.map { "WIFI:\(macOf($0))" }))
        #expect(high.allSatisfy { !keys.contains("WIFI:\(macOf($0))") })
    }

    // MARK: - Helpers

    private func at(_ step: Int) -> Int { 1_000_000 + step * 30_000 }

    private func anchor() -> RadioObservation { ap(1, "FrontDesk", rssi: -50, channel: 11) }

    private func spam(start: Int = 100, count: Int = 15) -> [RadioObservation] {
        (0..<count).map { ap(start + $0, "Spam\(start + $0)") }
    }

    private func cached(_ o: RadioObservation) -> RadioObservation {
        var c = o
        c.fresh = false
        return c
    }

    private func macOf(_ obs: RadioObservation) -> String { MacUtil.normalize(raw: obs.mac) }

    private func mac(_ n: Int) -> String { macOf(ap(n, "x")) }

    private func ap(_ n: Int, _ name: String, rssi: Int = -34, channel: Int = 6, fresh: Bool = true) -> RadioObservation {
        RadioObservation(
            kind: .wifi,
            mac: [0x02, (n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF, 0x01].map { hex2($0) }.joined(separator: ":"),
            name: name,
            rssi: rssi,
            channel: channel,
            frequencyMhz: 2437,
            hiddenSsid: name.isBlank,
            serviceUuids: [],
            manufacturerId: nil,
            manufacturerDataHex: "",
            rawHex: "",
            extras: "",
            at: 0,
            fresh: fresh
        )
    }
}
