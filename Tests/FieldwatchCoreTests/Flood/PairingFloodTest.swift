import Foundation
import Testing
@testable import FieldwatchCore

// Port of test/java/app/fieldwatch/domain/PairingFloodTest.kt.

struct PairingFloodTest {
    @Test func ninePopupsStayQuiet() {
        let flood = PairingFlood()
        for i in 0..<9 { flood.consider(obs: proximity(i), now: 0) }
        #expect(flood.notice.value == nil)
    }

    @Test func tenClusteredPopupsOpenTheDialog() throws {
        let flood = PairingFlood()
        for i in 0..<10 { flood.consider(obs: proximity(i), now: 0) }
        let notice = try #require(flood.notice.value)
        #expect(notice.showDialog)
        #expect(notice.title() == "Pairing flood")
        #expect(notice.popupCount == 10)
        #expect(notice.nameCount == 0)
        #expect(notice.families == ["Apple proximity pairing"])
        #expect(notice.medianRssi == -48)
        #expect(notice.line() == "Pairing flood · 10 new addresses · about -48 dBm")
        #expect(notice.body().contains("10 new addresses sent pairing advertisements"))
        #expect(notice.body().contains("They are about the same loudness, about -48 dBm."))
        #expect(notice.body().contains("such as in a store, or one radio changing its address on every packet"))
        #expect(notice.body().contains("can do the second"))
        #expect(notice.body().contains("Continue leaves them on Live for about the next 15 minutes. Hide these takes this burst, and later bursts in that time, off Live."))
        #expect(!notice.body().contains("one nearby radio"))
        flood.consider(obs: proximity(10), now: 1_000)
        let more = try #require(flood.notice.value)
        #expect(more.showDialog)
        #expect(more.popupCount == 11)
    }

    @Test func mixedPopupFamiliesShareOneCounter() throws {
        let flood = PairingFlood()
        flood.consider(obs: proximity(0), now: 0)
        flood.consider(obs: proximity(1), now: 0)
        flood.consider(obs: nearbyAction(2), now: 0)
        flood.consider(obs: nearbyAction(3), now: 0)
        flood.consider(obs: fastPair(4), now: 0)
        for i in 0..<4 { flood.consider(obs: proximity(10 + i), now: 0) }
        #expect(flood.notice.value == nil)
        flood.consider(obs: swift(5), now: 0)
        let notice = try #require(flood.notice.value)
        #expect(notice.popupCount == 10)
        #expect(notice.nameCount == 0)
        #expect(notice.families == ["Apple proximity pairing", "Apple Nearby Action", "Fast Pair", "Swift Pair"])
    }

    @Test func theSameAddressIsCountedOnce() {
        let flood = PairingFlood()
        for i in 0..<8 { flood.consider(obs: proximity(1), now: i * 100) }
        #expect(flood.notice.value == nil)
    }

    @Test func entriesLeaveTheWindowAfterTenSeconds() throws {
        let flood = PairingFlood()
        for i in 0..<10 { flood.consider(obs: proximity(i), now: 0) }
        #expect(try #require(flood.notice.value).showDialog)
        flood.tick(now: PairingFlood.WINDOW_MS)
        #expect(try #require(flood.notice.value).showDialog)
        flood.tick(now: PairingFlood.WINDOW_MS + 1)
        #expect(flood.notice.value == nil)
    }

    @Test func nearbyInfoAndFindMyAreNotPopups() {
        let flood = PairingFlood()
        for i in 0..<12 { flood.consider(obs: apple(i, "100100"), now: 0) }
        for i in 0..<12 { flood.consider(obs: apple(20 + i, "120100"), now: 0) }
        for i in 0..<12 { flood.consider(obs: apple(40 + i, "020100"), now: 0) }
        #expect(flood.notice.value == nil)
    }

    @Test func findMyThatContainsAProximityShapeStaysQuiet() throws {
        let flood = PairingFlood()
        let findMy = "12026E0007110654D03727C0AFB609F0BD82E4C265C651"
        for i in 0..<12 { flood.consider(obs: apple(i, findMy), now: 0) }
        #expect(flood.notice.value == nil)
        for i in 0..<10 { flood.consider(obs: apple(40 + i, "120200000F0101"), now: 0) }
        let action = try #require(flood.notice.value)
        #expect(action.popupCount == 10)
        #expect(action.families == ["Apple Nearby Action"])
        let leading = PairingFlood()
        for i in 0..<10 { leading.consider(obs: apple(i, "07010012020000"), now: 0) }
        let notice = try #require(leading.notice.value)
        #expect(notice.popupCount == 10)
        #expect(notice.families == ["Apple proximity pairing"])
    }

    @Test func aLongFastPairPayloadIsNotThePairingFrame() {
        let flood = PairingFlood()
        for i in 0..<12 { flood.consider(obs: fastPair(i, payload: "01020304050607"), now: 0) }
        #expect(flood.notice.value == nil)
    }

    @Test func spreadOutRadiosDoNotTrip() {
        let flood = PairingFlood()
        let rssi = [-30, -50, -70, -90, -110, -40, -35, -55, -75, -95]
        for (i, dbm) in rssi.enumerated() { flood.consider(obs: proximity(i, rssi: dbm), now: 0) }
        #expect(flood.notice.value == nil)
    }

    @Test func aWeakPairingClusterStillOpens() throws {
        let flood = PairingFlood()
        for i in 0..<11 { flood.consider(obs: swift(i, rssi: -92), now: 0) }
        let notice = try #require(flood.notice.value)
        #expect(notice.title() == "Pairing flood")
        #expect(notice.popupCount == 11)
        #expect(notice.medianRssi == -92)
        #expect(notice.families == ["Swift Pair"])
        #expect(flood.bursts().count == 1)
    }

    @Test func aTightClusterStillCountsWhenAFewAreFar() throws {
        let flood = PairingFlood()
        let rssi = [-48, -50, -46, -52, -49, -47, -48, -49, -50, -47, -20, -90]
        for (i, dbm) in rssi.enumerated() { flood.consider(obs: proximity(i, rssi: dbm), now: 0) }
        let notice = try #require(flood.notice.value)
        #expect(notice.popupCount == 10)
        #expect(notice.medianRssi == -48)
    }

    @Test func fifteenNewNamesOpenTheDialog() throws {
        let flood = PairingFlood()
        for i in 0..<14 { flood.consider(obs: named(i), now: 0) }
        #expect(flood.notice.value == nil)
        flood.consider(obs: named(14), now: 0)
        let notice = try #require(flood.notice.value)
        #expect(notice.showDialog)
        #expect(notice.title() == "Name flood")
        #expect(notice.popupCount == 0)
        #expect(notice.nameCount == 15)
        #expect(notice.line() == "Name flood · 15 new addresses · about -55 dBm")
        #expect(notice.body().contains("15 new addresses each advertised a Bluetooth name"))
        #expect(notice.body().contains("such as tags in a store, or one radio changing its name and address on every packet"))
        #expect(notice.body().contains("Continue leaves them on Live for about the next 15 minutes."))
        #expect(!notice.body().contains("pairing advertisements"))
    }

    @Test func factoryNamedAddressesStayOutOfANameFlood() throws {
        let flood = PairingFlood()
        for i in 0..<20 {
            flood.consider(obs: named(i, mac: "88:0F:62:10:20:\(hex2(i))", name: "IL\(hexN(i, 3))"), now: 0)
        }
        #expect(flood.notice.value == nil)
        for i in 0..<14 { flood.consider(obs: named(100 + i), now: 0) }
        #expect(flood.notice.value == nil)
        flood.consider(obs: named(114), now: 0)
        let notice = try #require(flood.notice.value)
        #expect(notice.title() == "Name flood")
        #expect(notice.popupCount == 0)
        #expect(notice.nameCount == 15)
    }

    @Test func aFactoryAddressStillCountsAsAPairingPopup() throws {
        let flood = PairingFlood()
        for i in 0..<9 { flood.consider(obs: proximity(i, mac: "00:00:00:00:00:\(hex2(i))"), now: 0) }
        #expect(flood.notice.value == nil)
        flood.consider(obs: proximity(9, mac: "00:00:00:00:00:09"), now: 0)
        let notice = try #require(flood.notice.value)
        #expect(notice.title() == "Pairing flood")
        #expect(notice.popupCount == 10)
        #expect(notice.nameCount == 0)
    }

    @Test func popupAndNameBurstsBothShow() throws {
        let flood = PairingFlood()
        for i in 0..<10 { flood.consider(obs: proximity(i, rssi: -40), now: 0) }
        for i in 0..<15 { flood.consider(obs: named(50 + i, rssi: -70), now: 0) }
        let notice = try #require(flood.notice.value)
        #expect(notice.popupCount == 10)
        #expect(notice.nameCount == 15)
        #expect(notice.medianRssi == -40)
        #expect(notice.line() == "Pairing flood · 10 new addresses · 15 named · about -40 dBm")
        #expect(notice.body().contains("10 new addresses sent pairing advertisements"))
        #expect(notice.body().contains("15 more each advertised a Bluetooth name"))
    }

    @Test func aFewMeasuredPopupsDoNotBorrowUnmeasuredOnes() {
        let flood = PairingFlood()
        for i in 0..<9 { flood.consider(obs: proximity(i, rssi: -45), now: 0) }
        for i in 0..<4 { flood.consider(obs: proximity(20 + i, rssi: 127), now: 0) }
        #expect(flood.notice.value == nil)
    }

    @Test func aNamedPopupDoesNotAlsoCountAsAName() throws {
        let flood = PairingFlood()
        for i in 0..<10 { flood.consider(obs: proximity(i, name: "Buds \(i)"), now: 0) }
        let notice = try #require(flood.notice.value)
        #expect(notice.popupCount == 10)
        #expect(notice.nameCount == 0)
        #expect(!notice.body().contains("each advertised a Bluetooth name"))
    }

    @Test func dismissKeepsOneLineUntilTheBurstGoesQuiet() throws {
        let flood = PairingFlood()
        for i in 0..<10 { flood.consider(obs: proximity(i), now: 1_000) }
        #expect(try #require(flood.notice.value).showDialog)
        flood.dismiss()
        let line = try #require(flood.notice.value)
        #expect(!line.showDialog)
        #expect(line.line().hasPrefix("Pairing flood"))
        for i in 0..<10 { flood.consider(obs: proximity(100 + i), now: 5_000) }
        #expect(!(try #require(flood.notice.value)).showDialog)
        #expect(try #require(flood.notice.value).popupCount == 20)
        flood.tick(now: 1_000 + PairingFlood.WINDOW_MS + 1)
        let mid = try #require(flood.notice.value)
        #expect(!mid.showDialog)
        #expect(mid.popupCount == 10)
        flood.tick(now: 5_000 + PairingFlood.WINDOW_MS + 1)
        #expect(flood.notice.value == nil)
        for i in 0..<10 { flood.consider(obs: proximity(200 + i), now: 16_000) }
        let held = try #require(flood.notice.value)
        #expect(!held.showDialog)
        #expect(held.line().hasPrefix("Pairing flood"))
    }

    @Test func aFifteenMinuteHoldAsksAgainOnTheNextBurst() throws {
        let flood = PairingFlood()
        let answered = 1_000
        for i in 0..<10 { flood.consider(obs: proximity(i), now: answered) }
        flood.dismiss()
        flood.tick(now: answered + PairingFlood.WINDOW_MS + 1)
        #expect(flood.notice.value == nil)
        let stillHeld = answered + PairingFlood.HOLD_MS - 2_000
        for i in 0..<10 { flood.consider(obs: proximity(100 + i), now: stillHeld) }
        #expect(!(try #require(flood.notice.value)).showDialog)
        flood.tick(now: answered + PairingFlood.HOLD_MS)
        #expect(flood.notice.value != nil)
        #expect(!(try #require(flood.notice.value)).showDialog)
        flood.tick(now: stillHeld + PairingFlood.WINDOW_MS + 1)
        #expect(flood.notice.value == nil)
        for i in 0..<10 { flood.consider(obs: proximity(200 + i), now: stillHeld + PairingFlood.WINDOW_MS + 2) }
        #expect(try #require(flood.notice.value).showDialog)
    }

    @Test func aFifteenMinuteHoldCarriesIntoASit() throws {
        let flood = PairingFlood()
        for i in 0..<10 { flood.consider(obs: proximity(i), now: 1_000) }
        flood.dismiss()
        flood.tick(now: 1_000 + PairingFlood.WINDOW_MS + 1)
        flood.setSitOpen(open: true)
        for i in 0..<10 { flood.consider(obs: proximity(100 + i), now: 1_000 + PairingFlood.HOLD_MS + 1_000) }
        let carried = try #require(flood.notice.value)
        #expect(!carried.showDialog)
        #expect(carried.duringSit)
        #expect(carried.body().contains("for the rest of this sit"))
        flood.tick(now: 1_000 + PairingFlood.HOLD_MS + 1_000 + PairingFlood.WINDOW_MS + 1)
        flood.setSitOpen(open: false)
        for i in 0..<10 { flood.consider(obs: proximity(200 + i), now: 1_000 + PairingFlood.HOLD_MS + 20_000) }
        #expect(try #require(flood.notice.value).showDialog)
        #expect(!(try #require(flood.notice.value)).duringSit)
    }

    @Test func hideHoldsForFifteenMinutesThenAsksAgain() throws {
        let flood = PairingFlood()
        for i in 0..<10 { flood.consider(obs: proximity(i), now: 1_000) }
        flood.setHideBurst(on: true)
        flood.dismiss()
        flood.tick(now: 1_000 + PairingFlood.WINDOW_MS + 1)
        for i in 0..<10 { flood.consider(obs: proximity(100 + i), now: 20_000) }
        #expect(!(try #require(flood.notice.value)).showDialog)
        #expect(flood.hide.value.episodeOn)
        #expect(flood.hide.value.keys.count == 20)
        flood.tick(now: 20_000 + PairingFlood.WINDOW_MS + 1)
        for i in 0..<10 { flood.consider(obs: proximity(200 + i), now: 1_000 + PairingFlood.HOLD_MS) }
        #expect(try #require(flood.notice.value).showDialog)
        #expect(!flood.hide.value.keys.contains(burstKey(200)))
    }

    @Test func theDialogDoesNotNameTheTool() throws {
        let flood = PairingFlood()
        for i in 0..<10 { flood.consider(obs: proximity(i), now: 0) }
        let body = try #require(flood.notice.value).body()
        #expect(body.contains("does not name the tool"))
        #expect(body.contains("Flipper Zero"))
        #expect(body.contains("Marauder"))
        #expect(body.contains("Bruce"))
        #expect(body.contains("one radio changing its address on every packet"))
        #expect(body.contains("can do the second"))
        #expect(!body.contains("identified", ignoreCase: true))
    }

    @Test func missingRssiFallsBackToTheRawCount() throws {
        let flood = PairingFlood()
        for i in 0..<10 { flood.consider(obs: proximity(i, rssi: 127), now: 0) }
        let notice = try #require(flood.notice.value)
        #expect(notice.medianRssi == nil)
        #expect(!notice.line().contains("dBm"))
        #expect(!notice.body().contains("one nearby radio"))
        #expect(notice.popupCount == 10)
    }

    @Test func knownPopupLayoutsAndAFullWindow() throws {
        let layouts = PairingFlood()
        layouts.consider(obs: obs(0, mfgId: 0x004C, mfgHex: "070100", factsOn: false), now: 0)
        layouts.consider(obs: obs(1, serviceUuid: "0000fe2c-0000-1000-8000-00805f9b34fb", serviceHex: "AABBCC"), now: 0)
        layouts.consider(obs: obs(2, mfgId: 0x0006, mfgHex: "01"), now: 0)
        layouts.consider(obs: swift(3, payload: "0209"), now: 0)
        for i in 0..<7 { layouts.consider(obs: proximity(10 + i), now: 0) }
        #expect(layouts.notice.value == nil)
        layouts.consider(obs: proximity(20), now: 0)
        let notice = try #require(layouts.notice.value)
        #expect(notice.popupCount == 10)
        #expect(notice.families == ["Apple proximity pairing", "Fast Pair"])
        let flood = PairingFlood()
        for i in 0..<100 { flood.consider(obs: proximity(i), now: 0) }
        #expect(try #require(flood.notice.value).popupCount == 96)
    }

    @Test func aCrossingKeepsOneBurstUntilTheWindowClears() throws {
        let flood = PairingFlood()
        for i in 0..<10 { flood.consider(obs: proximity(i), now: 1_000) }
        let opened = try single(flood.bursts())
        #expect(opened.at == 1_000)
        #expect(opened.popupCount == 10)
        #expect(opened.families == ["Apple proximity pairing"])
        #expect(opened.medianRssi == -48)
        flood.consider(obs: proximity(10), now: 2_000)
        let peaked = try single(flood.bursts())
        #expect(peaked.at == 1_000)
        #expect(peaked.popupCount == 11)
        #expect(
            peaked.reportLine(clock: "12:00") ==
                "12:00 UTC. Pairing flood. 11 new addresses: Apple proximity pairing · about -48 dBm. " +
                "11 addresses from this burst are left out of the counts and lists below."
        )
        #expect(Set(peaked.keys) == Set((0...10).map { burstKey($0) }))
        flood.tick(now: 2_000 + PairingFlood.WINDOW_MS + 1)
        #expect(flood.notice.value == nil)
        #expect(try single(flood.bursts()).popupCount == 11)
        #expect(Set(try single(flood.bursts()).keys) == Set((0...10).map { burstKey($0) }))
        for i in 0..<10 { flood.consider(obs: proximity(100 + i), now: 20_000) }
        let bursts = flood.bursts()
        #expect(bursts.count == 2)
        #expect(bursts[0].at == 1_000)
        #expect(bursts[0].popupCount == 11)
        #expect(Set(bursts[0].keys) == Set((0...10).map { burstKey($0) }))
        #expect(bursts[1].at == 20_000)
        #expect(bursts[1].popupCount == 10)
        #expect(Set(bursts[1].keys) == Set((100...109).map { burstKey($0) }))
    }

    @Test func hideThisBurstDropsOnlyTheAddressesItCounted() throws {
        let flood = PairingFlood()
        for i in 0..<9 { flood.consider(obs: proximity(i), now: 1_000) }
        flood.setHideBurst(on: true)
        #expect(!flood.hide.value.episodeOn)
        #expect(flood.hide.value.keys.isEmpty)
        flood.consider(obs: proximity(9), now: 1_000)
        let counted = Set((0...9).map { burstKey($0) })
        #expect(!flood.hide.value.episodeOn)
        #expect(flood.hide.value.keys.isEmpty)
        flood.setHideBurst(on: true)
        #expect(flood.hide.value.episodeOn)
        #expect(flood.hide.value.keys == counted)
        flood.consider(obs: proximity(10), now: 2_000)
        #expect(flood.hide.value.keys.contains(burstKey(10)))
        flood.consider(obs: proximity(11, rssi: -100), now: 2_000)
        #expect(!flood.hide.value.keys.contains(burstKey(11)))
        #expect(Set(try single(flood.bursts()).keys) == Set((0...10).map { burstKey($0) }))
        flood.setHideBurst(on: false)
        #expect(!flood.hide.value.episodeOn)
        #expect(flood.hide.value.keys.isEmpty)
        flood.consider(obs: proximity(12), now: 2_500)
        #expect(!flood.hide.value.keys.contains(burstKey(12)))
    }

    @Test func aHiddenBurstOutlastsTheLineAndTheNextBurstStartsVisible() {
        let flood = PairingFlood()
        for i in 0..<10 { flood.consider(obs: proximity(i), now: 1_000) }
        flood.setHideBurst(on: true)
        let first = Set((0...9).map { burstKey($0) })
        flood.tick(now: 1_000 + PairingFlood.WINDOW_MS + 1)
        #expect(flood.notice.value == nil)
        #expect(!flood.hide.value.episodeOn)
        #expect(flood.hide.value.keys == first)
        for i in 0..<10 { flood.consider(obs: proximity(100 + i), now: 20_000) }
        #expect(!flood.hide.value.episodeOn)
        let second = Set((100...109).map { burstKey($0) })
        #expect(flood.hide.value.keys.allSatisfy { !second.contains($0) })
        #expect(flood.hide.value.keys == first)
        flood.setHideBurst(on: false)
        #expect(flood.hide.value.keys == first)
        flood.clearHidden()
        #expect(flood.hide.value.keys.isEmpty)
    }

    @Test func pruneDropsAHiddenAddressAfterItLeavesTheLiveMap() {
        let flood = PairingFlood()
        for i in 0..<10 { flood.consider(obs: proximity(i), now: 1_000) }
        flood.setHideBurst(on: true)
        let keys = Set((0...9).map { burstKey($0) })
        flood.prune(liveKeys: [])
        #expect(flood.hide.value.keys == keys)
        flood.prune(liveKeys: keys)
        #expect(flood.hide.value.keys == keys)
        let staying: Set<String> = [burstKey(0)]
        flood.prune(liveKeys: staying)
        #expect(flood.hide.value.keys == staying)
    }

    @Test func swiftPairBeaconCountsAndLooseMicrosoftDataDoesNot() throws {
        let flood = PairingFlood()
        let beacon = "0300804C6170746F70"
        for i in 0..<9 { flood.consider(obs: swift(i, payload: beacon), now: 0) }
        #expect(flood.notice.value == nil)
        flood.consider(obs: swift(9, payload: beacon), now: 0)
        let notice = try #require(flood.notice.value)
        #expect(notice.popupCount == 10)
        #expect(notice.nameCount == 0)
        #expect(notice.families == ["Swift Pair"])
        flood.setHideBurst(on: true)
        #expect(flood.hide.value.keys == Set((0...9).map { burstKey($0) }))

        let quiet = PairingFlood()
        let payloads = ["0300", "030000", "030380", "00", "0209", "0109", "01092022B0018CE2", "010F2022"]
        for (group, payload) in payloads.enumerated() {
            for i in 0..<12 { quiet.consider(obs: swift(group * 16 + i, payload: payload), now: 0) }
        }
        #expect(quiet.notice.value == nil)

        let dual = PairingFlood()
        for i in 0..<4 { dual.consider(obs: swift(i, payload: "030080"), now: 0) }
        for i in 0..<3 { dual.consider(obs: swift(10 + i, payload: "030180"), now: 0) }
        for i in 0..<2 { dual.consider(obs: swift(20 + i, payload: "030280"), now: 0) }
        #expect(dual.notice.value == nil)
        dual.consider(obs: swift(30, payload: "030080"), now: 0)
        let mixed = try #require(dual.notice.value)
        #expect(mixed.popupCount == 10)
        #expect(mixed.families == ["Swift Pair"])
    }

    @Test func samsungEasySetupCountsAndAFinderServiceDoesNot() throws {
        let flood = PairingFlood()
        let buds = "42098102141503210109EE7A01"
        let watch = "010002000101FF0000431A"
        for i in 0..<5 { flood.consider(obs: samsung(i, payload: buds), now: 0) }
        for i in 0..<4 { flood.consider(obs: samsung(10 + i, payload: watch), now: 0) }
        #expect(flood.notice.value == nil)
        flood.consider(obs: samsung(20, payload: watch), now: 0)
        let notice = try #require(flood.notice.value)
        #expect(notice.popupCount == 10)
        #expect(notice.nameCount == 0)
        #expect(notice.families == ["Samsung Easy Setup"])
        flood.setHideBurst(on: true)
        let keys = Set((0...4).map { burstKey($0) }).union((10...13).map { burstKey($0) }).union([burstKey(20)])
        #expect(flood.hide.value.keys == keys)

        let quiet = PairingFlood()
        for (group, payload) in ["420981021415032101", "010002000101FF0000", "00"].enumerated() {
            for i in 0..<12 { quiet.consider(obs: samsung(group * 16 + i, payload: payload), now: 0) }
        }
        for i in 0..<12 {
            quiet.consider(obs: obs(80 + i, serviceUuid: "FD5A", serviceHex: "01020304"), now: 0)
            quiet.consider(obs: obs(100 + i, serviceUuid: "FD59", serviceHex: "01020304"), now: 0)
        }
        #expect(quiet.notice.value == nil)
    }

    @Test func loveSpousePrefixCountsAndAShortCompanyBlobDoesNot() throws {
        let flood = PairingFlood()
        let packet = "6DB643CE97FE427C000100"
        let otherMode = "6DB643CE97FE427C010203"
        for i in 0..<5 { flood.consider(obs: typo(i, payload: packet), now: 0) }
        for i in 0..<4 { flood.consider(obs: typo(10 + i, payload: otherMode), now: 0) }
        #expect(flood.notice.value == nil)
        flood.consider(obs: typo(20, payload: "6DB643CE97FE427C"), now: 0)
        let notice = try #require(flood.notice.value)
        #expect(notice.popupCount == 10)
        #expect(notice.nameCount == 0)
        #expect(notice.families == ["LoveSpouse"])
        flood.setHideBurst(on: true)
        let keys = Set((0...4).map { burstKey($0) }).union((10...13).map { burstKey($0) }).union([burstKey(20)])
        #expect(flood.hide.value.keys == keys)

        let quiet = PairingFlood()
        for (group, payload) in ["6DB643CE97FE42", "00", "6DB643CE97FE427B000100"].enumerated() {
            for i in 0..<12 { quiet.consider(obs: typo(group * 16 + i, payload: payload), now: 0) }
        }
        for i in 0..<12 {
            quiet.consider(obs: obs(80 + i, serviceUuid: "AE8F", serviceHex: "01020304"), now: 0)
            quiet.consider(obs: obs(100 + i, mfgId: 0x00E0, mfgHex: packet), now: 0)
        }
        #expect(quiet.notice.value == nil)
    }

    @Test func aNameBurstLineOmitsPairingFamilies() {
        let line = FloodBurst(at: 0, popupCount: 0, nameCount: 16, medianRssi: -55).reportLine(clock: "09:15")
        #expect(line == "09:15 UTC. Name flood. 16 new addresses · about -55 dBm.")
        let below = FloodBurst(at: 0, popupCount: 9, nameCount: 16, medianRssi: -55).reportLine(clock: "09:15")
        #expect(below == "09:15 UTC. Name flood. 16 new addresses · about -55 dBm.")
        let kept = FloodBurst(at: 0, popupCount: 7, nameCount: 2, families: ["Swift Pair"], medianRssi: -92)
            .reportLine(clock: "10:41")
        #expect(kept == "10:41 UTC. Pairing flood. 7 new addresses: Swift Pair · about -92 dBm.")
    }

    @Test func continueDuringASitHoldsUntilTheSitEnds() throws {
        let flood = PairingFlood()
        flood.setSitOpen(open: true)
        for i in 0..<10 { flood.consider(obs: proximity(i), now: 1_000) }
        let first = try #require(flood.notice.value)
        #expect(first.showDialog)
        #expect(first.duringSit)
        #expect(first.body().contains("for the rest of this sit"))
        flood.dismiss()
        #expect(!(try #require(flood.notice.value)).showDialog)
        flood.tick(now: 1_000 + PairingFlood.WINDOW_MS + 1)
        #expect(flood.notice.value == nil)
        for i in 0..<10 { flood.consider(obs: proximity(100 + i), now: 16_000) }
        let later = try #require(flood.notice.value)
        #expect(!later.showDialog)
        #expect(later.line().hasPrefix("Pairing flood"))
        #expect(!flood.hide.value.episodeOn)
        #expect(flood.bursts().count == 2)
        flood.tick(now: 16_000 + PairingFlood.WINDOW_MS + 1)
        #expect(flood.notice.value == nil)
        for i in 0..<15 { flood.consider(obs: named(200 + i), now: 40_000) }
        let namedLater = try #require(flood.notice.value)
        #expect(!namedLater.showDialog)
        #expect(namedLater.title() == "Name flood")
        #expect(flood.bursts().count == 3)
        flood.tick(now: 40_000 + PairingFlood.WINDOW_MS + 1)
        flood.setSitOpen(open: false)
        for i in 0..<15 { flood.consider(obs: named(300 + i), now: 60_000) }
        let asked = try #require(flood.notice.value)
        #expect(asked.showDialog)
        #expect(asked.title() == "Name flood")
        #expect(!asked.duringSit)
    }

    @Test func hideDuringASitHidesLaterBurstsUntilTheSwitchGoesOff() throws {
        let flood = PairingFlood()
        flood.setSitOpen(open: true)
        for i in 0..<10 { flood.consider(obs: proximity(i), now: 1_000) }
        flood.setHideBurst(on: true)
        flood.dismiss()
        #expect(flood.hide.value.episodeOn)
        #expect(flood.hide.value.keys.count == 10)
        flood.tick(now: 1_000 + PairingFlood.WINDOW_MS + 1)
        #expect(flood.notice.value == nil)
        #expect(!flood.hide.value.episodeOn)
        #expect(flood.hide.value.keys.count == 10)
        for i in 0..<10 { flood.consider(obs: proximity(100 + i), now: 16_000) }
        #expect(!(try #require(flood.notice.value)).showDialog)
        #expect(flood.hide.value.episodeOn)
        #expect(flood.hide.value.keys.count == 20)
        #expect(flood.bursts().count == 2)
        flood.setHideBurst(on: false)
        #expect(!flood.hide.value.episodeOn)
        flood.tick(now: 16_000 + PairingFlood.WINDOW_MS + 1)
        for i in 0..<10 { flood.consider(obs: proximity(200 + i), now: 40_000) }
        #expect(!(try #require(flood.notice.value)).showDialog)
        #expect(!flood.hide.value.episodeOn)
        #expect(!flood.hide.value.keys.contains(burstKey(200)))
    }

    @Test func aWeakBurstWhileDrivingStaysQuiet() {
        let flood = PairingFlood()
        for i in 0..<16 { flood.consider(obs: named(i, rssi: -97), now: 0, speedMps: 20.0) }
        #expect(flood.notice.value == nil)
        #expect(flood.bursts().isEmpty)
        let pairing = PairingFlood()
        for i in 0..<12 { pairing.consider(obs: proximity(i, rssi: -96), now: 0, speedMps: 12.0) }
        #expect(pairing.notice.value == nil)
    }

    @Test func theSameWeakBurstWarnsOnFoot() throws {
        let flood = PairingFlood()
        for i in 0..<16 { flood.consider(obs: named(i, rssi: -97), now: 0, speedMps: 1.2) }
        #expect(try #require(flood.notice.value).title() == "Name flood")
        #expect(try #require(flood.notice.value).medianRssi == -97)
    }

    @Test func aLoudBurstWhileDrivingStillWarns() throws {
        let flood = PairingFlood()
        for i in 0..<10 { flood.consider(obs: proximity(i, rssi: -55), now: 0, speedMps: 20.0) }
        #expect(try #require(flood.notice.value).title() == "Pairing flood")
        #expect(try #require(flood.notice.value).medianRssi == -55)
    }

    @Test func unknownSpeedDoesNotHideAWeakBurst() throws {
        let flood = PairingFlood()
        for i in 0..<16 { flood.consider(obs: named(i, rssi: -97), now: 0, speedMps: nil) }
        #expect(try #require(flood.notice.value).title() == "Name flood")
    }

    @Test func slowingDownLetsAWeakBurstWarn() throws {
        let flood = PairingFlood()
        for i in 0..<16 { flood.consider(obs: named(i, rssi: -97), now: 1_000, speedMps: 20.0) }
        #expect(flood.notice.value == nil)
        flood.tick(now: 2_000, speedMps: 0.0)
        #expect(try #require(flood.notice.value).title() == "Name flood")
    }

    @Test func wifiNamesAreIgnored() {
        let flood = PairingFlood()
        for i in 0..<20 { flood.consider(obs: obs(i, name: "Radio \(i)", kind: .wifi), now: 0) }
        #expect(flood.notice.value == nil)
    }

    // MARK: - Helpers

    private func single(_ bursts: [FloodBurst]) throws -> FloodBurst {
        try #require(bursts.count == 1)
        return bursts[0]
    }

    private func burstKey(_ n: Int) -> String { "BLE:02:00:00:00:00:\(hex2(n))" }

    private func proximity(_ n: Int, rssi: Int = -48, name: String = "", mac: String? = nil) -> RadioObservation {
        apple(n, "070100", rssi: rssi, name: name, mac: mac)
    }

    private func nearbyAction(_ n: Int, rssi: Int = -48) -> RadioObservation { apple(n, "0F0100", rssi: rssi) }

    private func apple(_ n: Int, _ hex: String, rssi: Int = -48, name: String = "", mac: String? = nil) -> RadioObservation {
        obs(n, rssi: rssi, name: name, mfgId: 0x004C, mfgHex: hex, mac: mac)
    }

    private func fastPair(_ n: Int, rssi: Int = -48, payload: String = "000006") -> RadioObservation {
        obs(n, rssi: rssi, serviceUuid: "FE2C", serviceHex: payload)
    }

    private func swift(_ n: Int, rssi: Int = -48, payload: String = "030080") -> RadioObservation {
        obs(n, rssi: rssi, mfgId: 0x0006, mfgHex: payload)
    }

    private func samsung(_ n: Int, rssi: Int = -48, payload: String) -> RadioObservation {
        obs(n, rssi: rssi, mfgId: 0x0075, mfgHex: payload)
    }

    private func typo(_ n: Int, rssi: Int = -31, payload: String) -> RadioObservation {
        obs(n, rssi: rssi, mfgId: 0x00FF, mfgHex: payload)
    }

    private func named(_ n: Int, rssi: Int = -55, mac: String? = nil, name: String? = nil) -> RadioObservation {
        obs(n, rssi: rssi, name: name ?? "Radio \(n)", mac: mac)
    }

    private func obs(
        _ n: Int,
        rssi: Int = -48,
        name: String = "",
        kind: RadioKind = .ble,
        mfgId: Int? = nil,
        mfgHex: String = "",
        serviceUuid: String? = nil,
        serviceHex: String = "",
        factsOn: Bool = true,
        mac: String? = nil
    ) -> RadioObservation {
        let mfg = mfgId.map { [MfgRecord(companyId: $0, dataHex: mfgHex)] } ?? []
        let service = serviceUuid.map { [ServiceDataRecord(uuid: $0, dataHex: serviceHex)] } ?? []
        return RadioObservation(
            kind: kind,
            mac: mac ?? "02:00:00:00:00:\(hex2(n))",
            name: name,
            rssi: rssi,
            channel: 0,
            frequencyMhz: 0,
            hiddenSsid: false,
            serviceUuids: [],
            manufacturerId: mfgId,
            manufacturerDataHex: mfgHex,
            rawHex: "",
            extras: "",
            at: 0,
            facts: factsOn ? RadioFacts(mfgRecords: mfg, serviceData: service) : RadioFacts.Empty
        )
    }
}
