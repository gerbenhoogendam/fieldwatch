import Foundation
import Testing
@testable import FieldwatchCore

// Port of test/java/app/fieldwatch/domain/TakPublishTest.kt.
// macOS wording: "Where this phone was" / "(this phone)" are "Where this Mac was" / "(this Mac)".

struct TakPublishTest {
    private let remote = Fleet(id: "fleet-remote-id", name: "Remote ID", attentionNote: "", kind: .drone)
    private let axon = Fleet(id: "fleet-axon", name: "Axon", attentionNote: "Body-worn, in-car, dock, or TASER.", kind: .lawEnforcement)
    private let ruuvi = Fleet(id: "fleet-ruuvi", name: "Ruuvi", kind: .beacon)
    private var fleets: [Fleet] { [remote, axon, ruuvi] }
    private var on: AppSettings { settings { $0.takEnabled = true; $0.tagLocation = true } }

    @Test func payloadLocationRejectsZeroZeroAndOutOfRange() {
        #expect(!PayloadLocation.validCoord(lat: 0.0, lon: 0.0))
        #expect(!PayloadLocation.validCoord(lat: nil, lon: -74.0))
        #expect(!PayloadLocation.validCoord(lat: 40.0, lon: nil))
        #expect(!PayloadLocation.validCoord(lat: Double.nan, lon: -74.0))
        #expect(!PayloadLocation.validCoord(lat: 91.0, lon: 0.1))
        #expect(!PayloadLocation.validCoord(lat: 1.0, lon: 181.0))
        #expect(PayloadLocation.validCoord(lat: 40.0, lon: -74.0))
        #expect(PayloadLocation.validCoord(lat: -33.9, lon: 151.2))
    }

    @Test func fromDecodedUsesLatitudeLongitudeNotOperator() throws {
        let loc = PayloadLocation.fromDecoded(fields: [
            field("latitude", 40.0),
            field("longitude", -74.0),
            field("alt_geo", 100.0),
            field("op_lat", 40.1),
            field("op_lon", -74.1),
        ])
        #expect(loc.lat == 40.0)
        #expect(loc.lon == -74.0)
        #expect(loc.alt == 100.0)
        #expect(loc.opLat == 40.1)
        #expect(loc.opLon == -74.1)
        let pin = try #require(loc.pin())
        #expect(pin == (40.0, -74.0))
    }

    @Test func stickyKeepsLatWhenNextPacketHasNone() {
        let location = PayloadLocation(lat: 40.0, lon: -74.0, alt: 100.0)
        let basicId = PayloadLocation()
        let kept = basicId.mergeSticky(prev: location)
        #expect(kept.lat == 40.0)
        #expect(kept.lon == -74.0)
        #expect(kept.alt == 100.0)
    }

    @Test func stickyZeroZeroDoesNotClobber() {
        let good = PayloadLocation(lat: 40.0, lon: -74.0)
        let unset = PayloadLocation(lat: 0.0, lon: 0.0)
        let kept = unset.mergeSticky(prev: good)
        #expect(kept.lat == 40.0)
        #expect(kept.lon == -74.0)
    }

    @Test func remoteIdPinsWithoutExtraAttentionWhenPayloadChipOn() throws {
        let drone = radio(fleetIds: ["fleet-remote-id"], payloadLat: 40.0, payloadLon: -74.0)
        #expect(TakPublish.selected(device: drone, settings: on, fleets: fleets, watchlist: []))
        let pin = try #require(TakPublish.pin(device: drone, settings: on))
        #expect(pin == (40.0, -74.0))
        #expect(TakPublish.advertisedPin(device: drone))
        #expect(TakPublish.eligible(device: drone, settings: on, fleets: fleets, watchlist: []))
    }

    @Test func extraAttentionUsesOperatorGpsWhenNoPayload() throws {
        let cam = radio(fleetIds: ["fleet-axon"], lat: 37.5, lon: -122.2)
        #expect(TakPublish.selected(device: cam, settings: on, fleets: fleets, watchlist: []))
        let pin = try #require(TakPublish.pin(device: cam, settings: on))
        #expect(pin == (37.5, -122.2))
        #expect(!TakPublish.advertisedPin(device: cam))
    }

    @Test func gpsOffAndNoPayloadIsNotEligible() {
        let cam = radio(fleetIds: ["fleet-axon"], lat: 37.5, lon: -122.2)
        let s = settings(from: on) { $0.tagLocation = false }
        #expect(TakPublish.selected(device: cam, settings: s, fleets: fleets, watchlist: []))
        #expect(TakPublish.pin(device: cam, settings: s) == nil)
        #expect(!TakPublish.eligible(device: cam, settings: s, fleets: fleets, watchlist: []))
    }

    @Test func gpsOffStillPublishesAdvertisedPayload() throws {
        let drone = radio(fleetIds: ["fleet-remote-id"], payloadLat: 40.0, payloadLon: -74.0, lat: 37.5, lon: -122.2)
        let s = settings(from: on) { $0.tagLocation = false }
        let pin = try #require(TakPublish.pin(device: drone, settings: s))
        #expect(pin == (40.0, -74.0))
        #expect(TakPublish.eligible(device: drone, settings: s, fleets: fleets, watchlist: []))
    }

    @Test func privacyModeNeverSelected() {
        let drone = radio(fleetIds: ["fleet-remote-id"], payloadLat: 40.0, payloadLon: -74.0)
        #expect(!TakPublish.selected(device: drone, settings: settings(from: on) { $0.demoMode = true }, fleets: fleets, watchlist: []))
    }

    @Test func masterOffNeverSelected() {
        let drone = radio(fleetIds: ["fleet-remote-id"], payloadLat: 40.0, payloadLon: -74.0)
        #expect(!TakPublish.selected(device: drone, settings: AppSettings(), fleets: fleets, watchlist: []))
    }

    @Test func ruuviWithoutPayloadChipIsSkipped() {
        let tag = radio(fleetIds: ["fleet-ruuvi"], lat: 1.0, lon: 2.0)
        #expect(!TakPublish.selected(device: tag, settings: on, fleets: fleets, watchlist: []))
        let all = settings(from: on) { $0.takAllSignatures = true }
        #expect(TakPublish.selected(device: tag, settings: all, fleets: fleets, watchlist: []))
    }

    @Test func watchlistNamedRadioNeedsAlertOn() {
        let unmatched = radio(fleetIds: [], lat: 1.0, lon: 2.0)
        let quiet = WatchTarget(id: "n1", deviceKey: unmatched.key, label: "van", alert: false)
        var loud = quiet
        loud.alert = true
        let s = settings(from: on) { $0.takWatchlist = true; $0.takAttention = false; $0.takPayloadFix = false }
        #expect(!TakPublish.selected(device: unmatched, settings: s, fleets: fleets, watchlist: [quiet]))
        #expect(TakPublish.selected(device: unmatched, settings: s, fleets: fleets, watchlist: [loud]))
    }

    @Test func shouldEmitFirstThenIntervalThenMove() {
        #expect(TakPublish.shouldEmit(lastAt: nil, lastLat: nil, lastLon: nil, now: 1_000, lat: 40.0, lon: -74.0))
        #expect(!TakPublish.shouldEmit(lastAt: 1_000, lastLat: 40.0, lastLon: -74.0, now: 5_000, lat: 40.0, lon: -74.0))
        #expect(TakPublish.shouldEmit(lastAt: 1_000, lastLat: 40.0, lastLon: -74.0, now: 12_000, lat: 40.0, lon: -74.0))
        #expect(TakPublish.shouldEmit(lastAt: 1_000, lastLat: 40.0, lastLon: -74.0, now: 2_000, lat: 40.001, lon: -74.0))
    }

    @Test func heardHereMovesOnFirstAndLouderKeepsPeakOnRefresh() {
        #expect(TakPublish.heardHereAction(lastAt: nil, lastRssi: nil, now: 1_000, rssi: -80) == .move)
        #expect(TakPublish.heardHereAction(lastAt: 1_000, lastRssi: Int.min, now: 1_100, rssi: -80) == .move)
        #expect(TakPublish.heardHereAction(lastAt: 1_000, lastRssi: -60, now: 5_000, rssi: -70) == .skip)
        #expect(TakPublish.heardHereAction(lastAt: 1_000, lastRssi: -60, now: 5_000, rssi: -60) == .skip)
        #expect(TakPublish.heardHereAction(lastAt: 1_000, lastRssi: -60, now: 2_000, rssi: -50) == .move)
        #expect(TakPublish.heardHereAction(lastAt: 1_000, lastRssi: -60, now: 12_000, rssi: -90) == .refresh)
        #expect(TakPublish.heardHereAction(lastAt: 1_000, lastRssi: -60, now: 12_000, rssi: -60) == .refresh)
        #expect(TakPublish.heardHereAction(lastAt: 1_000, lastRssi: -60, now: 12_000, rssi: -40) == .move)
    }

    @Test func extraAttentionMarkerIsHeardHereNotAdvertised() {
        let cam = radio(fleetIds: ["fleet-axon"], lat: 37.5, lon: -122.2)
        let marks = TakPublish.markers(device: cam, settings: on, fleets: fleets, watchlist: [])
        #expect(marks.count == 1)
        #expect(!marks[0].advertised)
        #expect(!marks[0].pilot)
    }

    @Test func watchlistHeardHereIsNotAdvertised() {
        let unmatched = radio(fleetIds: [], lat: 1.0, lon: 2.0)
        let loud = WatchTarget(id: "n1", deviceKey: unmatched.key, label: "van", alert: true)
        let s = settings(from: on) { $0.takWatchlist = true; $0.takAttention = false; $0.takPayloadFix = false }
        let marks = TakPublish.markers(device: unmatched, settings: s, fleets: fleets, watchlist: [loud])
        #expect(marks.count == 1)
        #expect(!marks[0].advertised)
        #expect(!marks[0].pilot)
    }

    @Test func cotXmlUsesAdvertisedDroneTypeAndEscapes() {
        let drone = radio(fleetIds: ["fleet-remote-id"], payloadLat: 40.0, payloadLon: -74.0, payloadAlt: 100.0, name: "RID <test>")
        let xml = CotEvent.xml(device: drone, fleets: fleets, watchlist: [], lat: 40.0, lon: -74.0, advertised: true, now: 0)
        #expect(xml.contains("uid=\"FIELDWATCH-BLE-AABBCCDDEE01\""))
        #expect(xml.contains("type=\"a-u-A-M-H-Q\""))
        #expect(xml.contains("lat=\"40\""))
        #expect(xml.contains("lon=\"-74\""))
        #expect(xml.contains("hae=\"100\""))
        #expect(xml.contains("callsign=\"Remote ID\""))
        #expect(xml.contains("advertised position"))
        #expect(xml.contains("__group name=\"Yellow\""))
        #expect(xml.contains("stale="))
        #expect(!xml.contains(" (here)"))
    }

    @Test func cotXmlAddsTrackForAdvertisedAircraft() {
        let drone = radio(fleetIds: ["fleet-remote-id"], payloadLat: 40.0, payloadLon: -74.0, payloadAlt: 100.0,
                          payloadHeading: 270.0, payloadSpeed: 12.5)
        let xml = CotEvent.xml(device: drone, fleets: fleets, watchlist: [], lat: 40.0, lon: -74.0, advertised: true, now: 0)
        #expect(xml.contains("<track course=\"270\" speed=\"12.5\"/>"))
        var moved = drone
        moved.payloadHeading = 90.0
        moved.payloadSpeed = 5.0
        let here = CotEvent.xml(device: moved, fleets: fleets, watchlist: [], lat: 1.0, lon: 2.0, advertised: false, now: 0)
        #expect(!here.contains("<track"))
    }

    @Test func xmlEscapeAmpersandAndTags() {
        #expect(CotEvent.xmlEscape(raw: "A & <B> \"c\"") == "A &amp; &lt;B&gt; &quot;c&quot;")
        #expect(CotEvent.xmlEscape(raw: "a\nb") == "a&#10;b")
    }

    @Test func remarksAreAReadableCard() {
        let cam = radio(fleetIds: ["fleet-axon"], lat: 37.5, lon: -122.2)
        let text = CotEvent.remarks(device: cam, fleets: fleets, advertised: false)
        let lines = text.split("\n")
        #expect(lines[0] == "Axon (here)")
        #expect(lines[1] == "BLE  AA:BB:CC:DD:EE:01  -60 dBm")
        #expect(lines[2] == "heard here (operator GPS)")
        #expect(text.contains("Extra attention: "))
        #expect(text.contains("Body-worn"))
        #expect(!text.contains("Extra attention (Axon)"))
        let xml = CotEvent.xml(device: cam, fleets: fleets, watchlist: [], lat: 37.5, lon: -122.2, advertised: false, now: 0)
        #expect(xml.contains("&#10;"))
        #expect(xml.contains("Axon (here)&#10;BLE  AA:BB:CC:DD:EE:01  -60 dBm"))
        #expect(!xml.contains("Fieldwatch · "))
    }

    @Test func advertisedRemarksKeepPayloadAndSkipRepeatName() {
        let drone = radio(fleetIds: ["fleet-remote-id"], payloadLat: 40.0, payloadLon: -74.0,
                          payloadUasId: "TESTSERIAL1234567890", payloadSelfId: "N12345")
        let text = CotEvent.remarks(device: drone, fleets: fleets, advertised: true)
        let lines = text.split("\n")
        #expect(lines[0] == "N12345")
        #expect(lines[1] == "BLE  AA:BB:CC:DD:EE:01  -60 dBm")
        #expect(lines[2].hasPrefix("advertised position"))
        #expect(lines[2].contains("UAS ID TESTSERIAL1234567890"))
        #expect(text.contains("Remote ID"))
        let pilot = CotEvent.remarks(device: drone, fleets: fleets, advertised: true, pilot: true)
        #expect(pilot.lines().first == "Pilot · TESTSERIAL1234567890")
        #expect(pilot.contains("operator (pilot) position"))
    }

    @Test func cotHeardHereIsGroundUnknown() {
        let cam = radio(fleetIds: ["fleet-axon"], lat: 37.5, lon: -122.2)
        let xml = CotEvent.xml(device: cam, fleets: fleets, watchlist: [], lat: 37.5, lon: -122.2, advertised: false, now: 0)
        #expect(xml.contains("type=\"a-u-G\""))
        #expect(xml.contains("heard here (operator GPS)"))
        #expect(xml.contains("callsign=\"Axon (here)\""))
        #expect(xml.contains("__group name=\"Maroon\""))
        #expect(xml.contains("Extra attention"))
    }

    @Test func uidUsesStickyUasIdNotMac() {
        let drone = radio(fleetIds: ["fleet-remote-id"], payloadLat: 40.0, payloadLon: -74.0, payloadUasId: "TESTSERIAL1234567890")
        #expect(CotEvent.uid(device: drone) == "FIELDWATCH-RID-TESTSERIAL1234567890")
        #expect(CotEvent.pilotUid(device: drone) == "FIELDWATCH-PILOT-TESTSERIAL1234567890")
        let xml = CotEvent.xml(device: drone, fleets: fleets, watchlist: [], lat: 40.0, lon: -74.0, advertised: true, now: 0)
        #expect(xml.contains("uid=\"FIELDWATCH-RID-TESTSERIAL1234567890\""))
        #expect(xml.contains("callsign=\"TESTSERIAL1234567890\""))
        #expect(!xml.contains("FIELDWATCH-BLE-"))
    }

    @Test func uidFallsBackToMacWithoutUasId() {
        let drone = radio(fleetIds: ["fleet-remote-id"], payloadLat: 40.0, payloadLon: -74.0)
        #expect(CotEvent.uid(device: drone) == "FIELDWATCH-BLE-AABBCCDDEE01")
    }

    @Test func selfIdBeatsUasIdForCallsign() {
        let drone = radio(fleetIds: ["fleet-remote-id"], payloadLat: 40.0, payloadLon: -74.0,
                          payloadUasId: "TESTSERIAL1234567890", payloadSelfId: "N12345")
        #expect(TakPublish.callsign(device: drone, fleets: fleets, watchlist: []) == "N12345")
    }

    @Test func pilotMarkerAndLink() {
        let drone = radio(fleetIds: ["fleet-remote-id"], payloadLat: 40.0, payloadLon: -74.0,
                          payloadOpLat: 40.1, payloadOpLon: -74.1, payloadUasId: "TESTSERIAL1234567890")
        let marks = TakPublish.markers(device: drone, settings: on, fleets: fleets, watchlist: [])
        #expect(marks.count == 2)
        #expect(marks[0].uid == "FIELDWATCH-RID-TESTSERIAL1234567890")
        #expect(marks[1].uid == "FIELDWATCH-PILOT-TESTSERIAL1234567890")
        #expect(marks[1].lat == 40.1)
        let air = CotEvent.xml(device: drone, fleets: fleets, watchlist: [], lat: 40.0, lon: -74.0, advertised: true, now: 0)
        #expect(air.contains("link uid=\"FIELDWATCH-PILOT-TESTSERIAL1234567890\""))
        let pilot = CotEvent.xml(device: drone, fleets: fleets, watchlist: [], lat: 40.1, lon: -74.1, advertised: true, now: 0, pilot: true)
        #expect(pilot.contains("uid=\"FIELDWATCH-PILOT-TESTSERIAL1234567890\""))
        #expect(pilot.contains("callsign=\"Pilot · TESTSERIAL1234567890\""))
        #expect(pilot.contains("__group name=\"Orange\""))
        #expect(pilot.contains("operator (pilot) position"))
        #expect(pilot.contains("link uid=\"FIELDWATCH-RID-TESTSERIAL1234567890\""))
        #expect(!pilot.contains(" (here)"))
    }

    @Test func keepUidsHoldsGpsBlipAndDropsGone() {
        let cam = radio(fleetIds: ["fleet-axon"], lat: 37.5, lon: -122.2)
        let uid = CotEvent.uid(device: cam)
        let prev = [TakSent(uid: uid, deviceKey: cam.key, at: 1, lat: 37.5, lon: -122.2)]
        var blip = cam
        blip.latitude = nil
        blip.longitude = nil
        let keepBlip = TakPublish.keepUids(devices: [blip], settings: on, fleets: fleets, watchlist: [], previous: prev)
        #expect(keepBlip.contains(uid))
        let taggingOff = settings(from: on) { $0.tagLocation = false }
        let keepOff = TakPublish.keepUids(devices: [blip], settings: taggingOff, fleets: fleets, watchlist: [], previous: prev)
        #expect(!keepOff.contains(uid))
        var gone = cam
        gone.gone = true
        let keepGone = TakPublish.keepUids(devices: [gone], settings: on, fleets: fleets, watchlist: [], previous: prev)
        #expect(!keepGone.contains(uid))
    }

    @Test func keepUidsDoesNotDropUnsentEligibleWhenCapped() {
        let cam = radio(fleetIds: ["fleet-axon"], lat: 37.5, lon: -122.2)
        let uid = CotEvent.uid(device: cam)
        let keep = TakPublish.keepUids(devices: [cam], settings: on, fleets: fleets, watchlist: [], previous: [])
        #expect(keep.contains(uid))
    }

    @Test func uasIdChangeTombstonesMacUid() {
        let macKeyed = radio(fleetIds: ["fleet-remote-id"], payloadLat: 40.0, payloadLon: -74.0)
        var stable = macKeyed
        stable.payloadUasId = "TESTSERIAL1234567890"
        let oldUid = CotEvent.uid(device: macKeyed)
        let newUid = CotEvent.uid(device: stable)
        #expect(oldUid == "FIELDWATCH-BLE-AABBCCDDEE01")
        #expect(newUid == "FIELDWATCH-RID-TESTSERIAL1234567890")
        let prev = [TakSent(uid: oldUid, deviceKey: macKeyed.key, at: 1, lat: 40.0, lon: -74.0)]
        let keep = TakPublish.keepUids(devices: [stable], settings: on, fleets: fleets, watchlist: [], previous: prev)
        #expect(keep.contains(newUid))
        #expect(!keep.contains(oldUid))
    }

    @Test func gnssLineFollowsTheChosenWindow() {
        let active = GnssNotice(showDialog: false, title: "Possible GNSS interference (Medium)", body: "",
                                line: "Possible GNSS interference · Medium")
        var ended = active
        ended.line = "Possible GNSS interference ended 15:04"
        ended.ended = true
        let low = GnssLive(kind: .interference, confidence: .low, startedWall: 1, detail: "GPS L1", adapted: false, rose: false)
        #expect(TakGnss.line(mode: .off, notice: active, lives: [low]) == nil)
        #expect(TakGnss.line(mode: .alert, notice: active, lives: []) == active.line)
        #expect(TakGnss.line(mode: .alert, notice: ended, lives: []) == nil)
        #expect(TakGnss.line(mode: .redLine, notice: ended, lives: []) == ended.line)
        #expect(TakGnss.line(mode: .any, notice: ended, lives: []) == nil)
        #expect(TakGnss.line(mode: .any, notice: nil, lives: [low]) == "Possible GNSS interference · Low")
        #expect(AppSettings().takGnss == .off)
        #expect(AppSettings().takGnssHold == .hour)
        #expect(AppSettings().takRadioHold == .hour)
    }

    @Test func gnssMarkIsAPinThenAnOvalHalfAsWide() {
        let startLat = 40.0
        let startLon = -74.0
        let pin = TakGnss.plot(startLat: startLat, startLon: startLon, endLat: startLat, endLon: -74.0004)
        #expect(Geo.meters(lat1: startLat, lon1: startLon, lat2: startLat, lon2: -74.0004) < TakGnss.SPAN_PIN_M)
        #expect(pin.pin)
        #expect(abs(pin.lat - startLat) <= 1e-9)
        #expect(abs(pin.lon - startLon) <= 1e-9)

        let endLon = -73.998
        let span = Geo.meters(lat1: startLat, lon1: startLon, lat2: startLat, lon2: endLon)
        let oval = TakGnss.plot(startLat: startLat, startLon: startLon, endLat: startLat, endLon: endLon)
        #expect(span >= TakGnss.SPAN_PIN_M)
        #expect(!oval.pin)
        #expect(abs(oval.semiMajorM - span / 2.0) <= 0.01)
        #expect(abs(oval.semiMinorM - span / 4.0) <= 0.01)
        #expect(abs(oval.semiMajorM - oval.semiMinorM * 2.0) <= 0.01)
        #expect(abs(oval.angleDeg - Geo.bearingDegrees(lat1: startLat, lon1: startLon, lat2: startLat, lon2: endLon)) <= 0.05)
        let (midLat, midLon) = Geo.midpoint(lat1: startLat, lon1: startLon, lat2: startLat, lon2: endLon)
        #expect(abs(oval.lat - midLat) <= 1e-6)
        #expect(abs(oval.lon - midLon) <= 1e-6)
    }

    @Test func gnssMarkFreezesWhenTheHitEndsAndClearsWhenOff() throws {
        let live = GnssLive(kind: .interference, confidence: .medium, startedWall: 50, detail: "GPS L1", adapted: false, rose: false)
        let active = GnssNotice(showDialog: false, title: "Possible GNSS interference (Medium)", body: "",
                                line: "Possible GNSS interference · Medium")
        let opened = TakGnss.plan(open: nil, mode: .alert, notice: active, lives: [live], lat: 40.0, lon: -74.0,
                                  now: 1_000, hold: .hour)
        #expect(opened.send)
        #expect(try #require(opened.plot).pin)
        #expect(try #require(opened.track).uid == "FIELDWATCH-GNSS-50")
        #expect(opened.remarks.contains("Where this Mac was"))
        #expect(!opened.remarks.contains("40.0"))

        let quiet = TakGnss.plan(open: opened.track, mode: .alert, notice: active, lives: [live], lat: 40.0, lon: -74.0,
                                 now: 2_000, hold: .hour)
        #expect(!quiet.send)

        let stretched = TakGnss.plan(open: opened.track, mode: .alert, notice: active, lives: [live], lat: 40.0,
                                     lon: -73.998, now: 2_000, hold: .hours6)
        #expect(stretched.send)
        #expect(!(try #require(stretched.plot)).pin)
        #expect(stretched.staleMs == TakGnssHold.hours6.staleMs())

        var ended = active
        ended.line = "Possible GNSS interference ended 15:04"
        ended.ended = true
        let frozen = TakGnss.plan(open: stretched.track, mode: .redLine, notice: ended, lives: [], lat: 40.01,
                                  lon: -73.99, now: 30_000, hold: .hour)
        #expect(frozen.send)
        #expect(!(try #require(frozen.track)).open)
        #expect(abs(try #require(stretched.plot).semiMajorM - (try #require(frozen.plot)).semiMajorM) <= 0.01)
        #expect(abs(try #require(frozen.plot).lat - 40.0) <= 1e-4)
        #expect(frozen.staleMs == TakGnssHold.hour.staleMs())

        let off = TakGnss.plan(open: nil, mode: .off, notice: nil, lives: [], lat: 40.0, lon: -74.0, now: 40_000,
                               hold: .untilDeleted, hasMarks: true)
        #expect(off.clearAll)
        #expect(!TakGnss.growing(mode: .alert, notice: ended, lives: []))
    }

    @Test func floodNoteStartsWhenTheFloodIsDetected() throws {
        let asking = PairingFlood.Notice(showDialog: true, popupCount: 12, nameCount: 0, families: ["Fast Pair"], medianRssi: -40)
        let wifi = PairingFlood.Notice(showDialog: false, popupCount: 8, nameCount: 0, families: [], medianRssi: -55, wifi: true)
        #expect(TakFlood.line(mode: .off, notice: asking) == nil)
        #expect(TakFlood.line(mode: .on, notice: asking) == "Pairing flood · 12 new addresses · about -40 dBm")
        #expect(TakFlood.line(mode: .on, notice: wifi) == "Wi-Fi beacon flood · 8 new names · about -55 dBm")
        #expect(AppSettings().takFlood == .off)
        #expect(TakFloodSend.on.label() == "On")
        // Kotlin decoded a bare "RED_LINE" string; wrapped in an array here so the decoder sees a container.
        let saved = try JSONDecoder().decode([TakFloodSend].self, from: Data("[\"RED_LINE\"]".utf8))
        #expect(saved == [.on])
        let xml = CotEvent.selfXml(lat: 40.0, lon: -74.0, now: 0, remarksExtra: TakFlood.line(mode: .on, notice: asking))
        #expect(xml.contains("Pairing flood"))
        #expect(!xml.contains("Flipper"))
        #expect(!xml.contains("latitude"))
    }

    @Test func selfMarkerCarriesTheGnssLineAndNoCoordinatesInRemarks() {
        let plain = CotEvent.selfXml(lat: 40.0, lon: -74.0, now: 0)
        #expect(plain.contains("Fieldwatch TAK heartbeat (this Mac)"))
        #expect(!plain.contains("GNSS"))
        let xml = CotEvent.selfXml(lat: 40.0, lon: -74.0, now: 0, remarksExtra: "Possible GNSS interference · Medium")
        #expect(xml.contains("Possible GNSS interference · Medium"))
        #expect(xml.contains("&#10;"))
        #expect(!xml.contains("latitude"))
        #expect(!xml.contains("longitude"))
        #expect(xml.contains("lat=\"40\""))
    }

    @Test func tombstoneStaleEqualsNow() {
        let xml = CotEvent.tombstoneXml(uid: "FIELDWATCH-BLE-AABBCCDDEE01", lat: 37.5, lon: -122.2, now: 0)
        #expect(xml.contains("uid=\"FIELDWATCH-BLE-AABBCCDDEE01\""))
        #expect(xml.contains("stale=\"1970-01-01T00:00:00.000Z\""))
        #expect(xml.contains("gone"))
        let named = CotEvent.tombstoneXml(uid: "FIELDWATCH-BLE-AABBCCDDEE01", lat: 37.5, lon: -122.2, now: 0,
                                          callsign: "Axon (here)", remarks: "Axon (here)\nBLE")
        #expect(named.contains("callsign=\"Axon (here)\""))
        #expect(!named.contains("Fieldwatch"))
    }

    @Test func departedRadioKeepsItsNameForTheHold() {
        let cam = radio(fleetIds: ["fleet-axon"], lat: 37.5, lon: -122.2)
        let xml = CotEvent.xml(device: cam, fleets: fleets, watchlist: [], lat: 37.5, lon: -122.2, advertised: false,
                               now: 0, staleMs: TakGnssHold.hour.staleMs())
        #expect(xml.contains("callsign=\"Axon (here)\""))
        #expect(xml.contains("stale=\"1970-01-01T01:00:00.000Z\""))
        #expect(!xml.contains("Fieldwatch"))
        let face = CotEvent.face(device: cam, fleets: fleets, watchlist: [], advertised: false)
        let again = CotEvent.render(uid: CotEvent.uid(device: cam), face: face, lat: 37.5, lon: -122.2, now: 0,
                                    staleMs: TakGnssHold.hours6.staleMs())
        #expect(again.contains("callsign=\"Axon (here)\""))
        #expect(again.contains("stale=\"1970-01-01T06:00:00.000Z\""))
    }

    @Test func udpPresets() {
        #expect(TakPublish.udpPreset(host: "127.0.0.1", port: 10011) == .thisPhone)
        #expect(TakPublish.udpPreset(host: "239.2.3.1", port: 6969) == .lanMulticast)
        #expect(TakPublish.udpPreset(host: "239.2.3.1", port: 10011) == .custom)
        #expect(TakPublish.udpPreset(host: "192.168.0.9", port: 10011) == .custom)
        #expect(TakPublish.applyPreset(preset: .thisPhone) == ("127.0.0.1", 10011))
        #expect(TakPublish.applyPreset(preset: .lanMulticast) == ("239.2.3.1", 6969))
    }

    @Test func stickyUasIdSurvivesLocationOnlyPacket() {
        let basic = PayloadLocation.fromDecoded(fields: [textField("uas_id", "TESTSERIAL1234567890")])
        #expect(basic.uasId == "TESTSERIAL1234567890")
        let location = PayloadLocation.fromDecoded(fields: [field("latitude", 40.0), field("longitude", -74.0)])
        let kept = location.mergeSticky(prev: basic)
        #expect(kept.uasId == "TESTSERIAL1234567890")
        #expect(kept.lat == 40.0)
    }

    // MARK: - Helpers

    private func settings(from base: AppSettings = AppSettings(), _ change: (inout AppSettings) -> Void) -> AppSettings {
        var s = base
        change(&s)
        return s
    }

    private func field(_ id: String, _ n: Double) -> DecodedFieldValue {
        DecodedFieldValue(fleetId: "f", fleetName: "F", id: id, label: id, display: "\(n)", offset: 0, length: 4, number: n)
    }

    private func textField(_ id: String, _ text: String) -> DecodedFieldValue {
        DecodedFieldValue(fleetId: "f", fleetName: "F", id: id, label: id, display: text, offset: 0, length: text.count)
    }

    private func radio(
        fleetIds: [String],
        payloadLat: Double? = nil,
        payloadLon: Double? = nil,
        payloadAlt: Double? = nil,
        payloadOpLat: Double? = nil,
        payloadOpLon: Double? = nil,
        payloadUasId: String? = nil,
        payloadSelfId: String? = nil,
        payloadHeading: Double? = nil,
        payloadSpeed: Double? = nil,
        lat: Double? = nil,
        lon: Double? = nil,
        name: String = ""
    ) -> Sighting {
        Sighting(
            key: "BLE:AA:BB:CC:DD:EE:01",
            kind: .ble,
            mac: "AA:BB:CC:DD:EE:01",
            name: name,
            rssi: -60,
            rssiMin: -60,
            rssiMax: -60,
            channel: 0,
            frequencyMhz: 2402,
            vendor: nil,
            randomized: true,
            hiddenSsid: false,
            serviceUuids: [],
            manufacturerId: nil,
            manufacturerDataHex: "",
            rawHex: "",
            extras: "",
            firstSeen: 1,
            lastSeen: 1,
            hitCount: 1,
            fleetIds: fleetIds,
            rssiHistory: [],
            presence: [],
            latitude: lat,
            longitude: lon,
            payloadLat: payloadLat,
            payloadLon: payloadLon,
            payloadAlt: payloadAlt,
            payloadOpLat: payloadOpLat,
            payloadOpLon: payloadOpLon,
            payloadUasId: payloadUasId,
            payloadSelfId: payloadSelfId,
            payloadHeading: payloadHeading,
            payloadSpeed: payloadSpeed
        )
    }
}
