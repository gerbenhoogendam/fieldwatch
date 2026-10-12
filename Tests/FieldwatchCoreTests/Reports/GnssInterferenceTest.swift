import Foundation
import Testing
@testable import FieldwatchCore

// Port of GnssInterferenceTest.kt. "this phone" copy reads "this Mac".
struct GnssInterferenceTest {
    @Test func theQuietMinuteIsNotTheBaseline() {
        let det = GnssDetector()
        let wild = feed(det, 60, 0, agc: 20.0, cn0: 15.0, sv: 3)
        #expect(!wild.armed)
        #expect(wild.lives.isEmpty)
        #expect(wild.statusLine.startsWith("settling"))
        let learned = feed(det, 60, 60_000, agc: 2.0, cn0: 40.0, sv: 11)
        #expect(learned.armed)
        #expect(learned.lives.isEmpty)
        let snap = feed(det, 30, 120_000, agc: -8.0, cn0: 32.0, sv: 11)
        let hit = only(snap.lives, .interference)
        #expect(hit?.confidence == .medium)
    }

    @Test func aDropDuringTheQuietMinuteStaysQuiet() {
        let det = GnssDetector()
        feed(det, 30, 0, agc: 2.0, cn0: 40.0, sv: 11)
        let snap = feed(det, 20, 30_000, agc: -20.0, cn0: 10.0, sv: 0)
        #expect(!snap.armed)
        #expect(snap.lives.isEmpty)
        #expect(snap.marks.isEmpty)
    }

    @Test func cleanRunStaysQuiet() {
        let snap = feed(quiet(), 80, 0, agc: 2.0, cn0: 40.0, sv: 11)
        #expect(snap.lives.isEmpty)
        #expect(snap.marks.isEmpty)
        #expect(snap.armed)
    }

    @Test func agcAndSignalDropIsMediumInterference() throws {
        let det = quiet()
        feed(det, 60, 0, agc: 2.0, cn0: 40.0, sv: 11)
        let snap = feed(det, 30, 60_000, agc: -8.0, cn0: 32.0, sv: 11)
        let hit = try #require(only(snap.lives, .interference))
        #expect(hit.confidence == .medium)
        #expect(hit.detail.contains("GPS L1"))
        #expect(!hit.detail.contains("jammer", ignoreCase: true))
    }

    @Test func lossOfSatellitesOnEventAgcIsHigh() {
        let det = quiet()
        feed(det, 60, 0, agc: 2.0, cn0: 40.0, sv: 11)
        let snap = feed(det, 30, 60_000, agc: -10.0, cn0: 30.0, sv: 0)
        #expect(only(snap.lives, .interference)?.confidence == .high)
    }

    @Test func sharedAgcCountsOnce() {
        let det = quiet()
        feed(det, 60, 0, agc: 2.0, cn0: 40.0, sv: 11, galAgc: 2.0)
        let snap = feed(det, 30, 60_000, agc: -8.0, cn0: 32.0, sv: 11, galAgc: -8.0)
        #expect(only(snap.lives, .interference)?.confidence == .medium)
    }

    @Test func twoIndependentBandsAreHigh() {
        let det = quiet()
        feed(det, 60, 0, agc: 2.0, cn0: 40.0, sv: 11, galAgc: 12.0, galCn0: 40.0)
        let snap = feed(det, 30, 60_000, agc: -8.0, cn0: 32.0, sv: 11, galAgc: 2.0, galCn0: 32.0)
        #expect(only(snap.lives, .interference)?.confidence == .high)
    }

    @Test func aSuddenLossOfMeasurementsIsAPause() {
        let det = quiet()
        feed(det, 70, 0, agc: 2.0, cn0: 40.0, sv: 11)
        let paused = det.onEpoch(epoch: GnssEpoch(elapsedMs: 70_000, wallMs: 70_000, clockDiscontinuity: 0, bands: [:]))
        #expect(paused.statusLine == GnssCopy.PAUSED)
        #expect(paused.lives.isEmpty)
        #expect(paused.marks.isEmpty)
        let back = feed(det, 20, 80_000, agc: 2.0, cn0: 40.0, sv: 11)
        #expect(back.lives.isEmpty)
        #expect(back.statusLine.startsWith("armed"))
    }

    @Test func engineStoppedDoesNotAlertAndDoesNotMoveTheBaseline() {
        let det = quiet()
        feed(det, 70, 0, agc: 2.0, cn0: 40.0, sv: 11)
        let stopped = feed(det, 3, 70_000, agc: -30.0, cn0: 8.0, sv: 11, side: GnssSide(engineStopped: true))
        #expect(stopped.statusLine == GnssCopy.PAUSED)
        #expect(stopped.lives.isEmpty)
        #expect(stopped.marks.isEmpty)
        let warming = feed(det, 5, 73_000, agc: -12.0, cn0: 30.0, sv: 11)
        #expect(warming.statusLine == GnssCopy.PAUSED)
        #expect(warming.lives.isEmpty)
        let hit = feed(det, 20, 78_000, agc: -12.0, cn0: 30.0, sv: 11)
        #expect(only(hit.lives, .interference)?.confidence == .medium)
    }

    @Test func missingAgcIsNotAveragedAsZero() {
        let det = quiet()
        feed(det, 70, 0, agc: 2.0, cn0: 40.0, sv: 11)
        let snap = feed(det, 20, 70_000, agc: nil, cn0: 40.0, sv: 11)
        #expect(snap.lives.none { $0.kind == .interference })
        #expect(snap.statusLine != GnssCopy.PAUSED)
    }

    @Test func signalDropWithoutAgcDropStaysQuiet() {
        let det = quiet()
        feed(det, 60, 0, agc: 2.0, cn0: 40.0, sv: 11)
        let snap = feed(det, 30, 60_000, agc: 2.0, cn0: 28.0, sv: 4)
        #expect(snap.lives.none { $0.kind == .interference })
    }

    @Test func nonsenseAgcIsIgnored() {
        let det = quiet()
        feed(det, 60, 0, agc: 2.0, cn0: 40.0, sv: 11)
        let snap = feed(det, 30, 60_000, agc: -90.0, cn0: 32.0, sv: 11)
        #expect(snap.lives.none { $0.kind == .interference })
    }

    @Test func alreadyPresentDoesNotAlert() {
        let snap = feed(quiet(), 90, 0, agc: -12.0, cn0: 28.0, sv: 4)
        #expect(snap.lives.isEmpty)
    }

    @Test func calibrationFloorHoldsAMediumDropThatTheUserBarWouldAllow() {
        let open = quiet(GnssConfig(sensitivity: .medium))
        feed(open, 60, 0, agc: 2.0, cn0: 40.0, sv: 11)
        let hit = feed(open, 30, 60_000, agc: -8.0, cn0: 32.0, sv: 11)
        #expect(only(hit.lives, .interference)?.confidence == .medium)

        let floored = quiet(GnssConfig(sensitivity: .medium, agcFloorDb: 12.0))
        feed(floored, 60, 0, agc: 2.0, cn0: 40.0, sv: 11)
        let still = feed(floored, 30, 60_000, agc: -8.0, cn0: 32.0, sv: 11)
        #expect(still.lives.none { $0.kind == .interference })
    }

    @Test func moreSensitiveFiresOnASmallerDrop() {
        let normal = quiet(GnssConfig(sensitivity: .medium))
        feed(normal, 60, 0, agc: 2.0, cn0: 40.0, sv: 11)
        let still = feed(normal, 30, 60_000, agc: -2.0, cn0: 36.0, sv: 11)
        #expect(still.lives.none { $0.kind == .interference })

        let more = quiet(GnssConfig(sensitivity: .high))
        feed(more, 60, 0, agc: 2.0, cn0: 40.0, sv: 11)
        let hit = feed(more, 30, 60_000, agc: -2.0, cn0: 36.0, sv: 11)
        #expect(only(hit.lives, .interference)?.confidence == .medium)
    }

    @Test func invertedAgcTreatsARiseAsADrop() {
        let det = quiet(GnssConfig(invertAgc: true))
        feed(det, 60, 0, agc: 2.0, cn0: 40.0, sv: 11)
        let snap = feed(det, 30, 60_000, agc: 12.0, cn0: 32.0, sv: 11)
        #expect(only(snap.lives, .interference)?.confidence == .medium)
    }

    @Test func gainDownSignalUpIsSpoofing() throws {
        let det = quiet(GnssConfig(spoofChecks: true))
        feed(det, 60, 0, agc: 2.0, cn0: 40.0, sv: 11)
        let snap = feed(det, 50, 60_000, agc: -8.0, cn0: 42.0, sv: 11)
        let spoof = try #require(only(snap.lives, .spoofing))
        #expect(spoof.confidence >= .medium)
        #expect(spoof.detail.contains("Gain is down"))
    }

    @Test func oneMismatchDoesNotWarn() {
        for side in [
            GnssSide(timeDisagree: true),
            GnssSide(positionDisagree: true),
            GnssSide(impossibleHop: true),
        ] {
            let det = quiet(GnssConfig(spoofChecks: true))
            feed(det, 60, 0, agc: 2.0, cn0: 40.0, sv: 11)
            let snap = feed(det, 30, 60_000, agc: 2.0, cn0: 40.0, sv: 11, side: side)
            #expect(snap.lives.none { $0.kind == .spoofing })
            #expect(snap.marks.none { $0.kind == "spoofing" })
        }
    }

    @Test func twoMismatchesWarnWithoutAGainDrop() throws {
        let det = quiet(GnssConfig(spoofChecks: true))
        feed(det, 60, 0, agc: 2.0, cn0: 40.0, sv: 11)
        let snap = feed(det, 5, 60_000, agc: 2.0, cn0: 40.0, sv: 11,
                        side: GnssSide(timeDisagree: true, positionDisagree: true))
        let spoof = try #require(only(snap.lives, .spoofing))
        #expect(spoof.confidence == .medium)
        #expect(spoof.detail.contains("GPS time and network time disagree."))
        #expect(spoof.detail.contains("GPS position and network position disagree."))
        #expect(!spoof.detail.contains("Gain is down"))
    }

    @Test func positionMismatchRaisesTheGainPattern() throws {
        let det = quiet(GnssConfig(spoofChecks: true))
        feed(det, 60, 0, agc: 2.0, cn0: 40.0, sv: 11)
        let snap = feed(det, 20, 60_000, agc: -8.0, cn0: 40.0, sv: 11, side: GnssSide(positionDisagree: true))
        let spoof = try #require(only(snap.lives, .spoofing))
        #expect(spoof.confidence >= .medium)
        #expect(spoof.detail.contains("GPS position and network position disagree."))
    }

    @Test func coarseOrBriefNetworkFixDoesNotCount() {
        #expect(!GnssPositionWitness.rawDisagree(gpsAccM: 1.5, netAccM: 100.0, apartM: 500.0, gpsAgeMs: 1_000, netAgeMs: 1_000))
        #expect(!GnssPositionWitness.rawDisagree(gpsAccM: 1.5, netAccM: 40.0, apartM: 140.0, gpsAgeMs: 1_000, netAgeMs: 1_000))
        #expect(GnssPositionWitness.rawDisagree(gpsAccM: 1.5, netAccM: 40.0, apartM: 142.0, gpsAgeMs: 1_000, netAgeMs: 1_000))
        #expect(!GnssPositionWitness.rawDisagree(gpsAccM: 1.5, netAccM: 40.0, apartM: 500.0, gpsAgeMs: 11_000, netAgeMs: 1_000))
        #expect(!GnssPositionWitness.rawDisagree(gpsAccM: 0.0, netAccM: 40.0, apartM: 500.0, gpsAgeMs: 1_000, netAgeMs: 1_000))
        let started = GnssPositionWitness.hold(raw: true, sinceMs: 0, nowMs: 1_000)
        #expect(!started.on)
        #expect(!GnssPositionWitness.hold(raw: true, sinceMs: started.sinceMs, nowMs: 1_000 + 14_000).on)
        #expect(GnssPositionWitness.hold(raw: true, sinceMs: started.sinceMs, nowMs: 1_000 + 15_000).on)
        #expect(GnssPositionWitness.hold(raw: false, sinceMs: started.sinceMs, nowMs: 2_000).sinceMs == 0)
    }

    @Test func timeCheckWithGainDropReachesHighThenDemotesWhileInterferenceIsUp() throws {
        let det = quiet(GnssConfig(spoofChecks: true))
        feed(det, 60, 0, agc: 2.0, cn0: 40.0, sv: 11)
        feed(det, 20, 60_000, agc: -8.0, cn0: 42.0, sv: 11)
        let snap = feed(det, 15, 80_000, agc: -8.0, cn0: 42.0, sv: 11, side: GnssSide(timeDisagree: true))
        let spoof = try #require(only(snap.lives, .spoofing))
        #expect(spoof.confidence == .medium)
        #expect(spoof.detail.contains("side effect"))
    }

    @Test func mockLocationIsItsOwnMessage() throws {
        let det = quiet()
        let snap = feed(det, 5, 0, agc: 2.0, cn0: 40.0, sv: 11, side: GnssSide(mock: true))
        let mock = try #require(only(snap.lives, .mock))
        #expect(mock.detail.contains("mock location"))
        #expect(snap.lives.none { $0.kind == .spoofing })
    }

    @Test func noAgcFallsBackToLowOnly() throws {
        let det = quiet()
        feed(det, 60, 0, agc: nil, cn0: 40.0, sv: 10)
        let snap = feed(det, 30, 60_000, agc: nil, cn0: 30.0, sv: 4)
        let hit = try #require(only(snap.lives, .interference))
        #expect(hit.confidence == .low)
        #expect(snap.statusLine.contains("low confidence") || hit.confidence == .low)
    }

    @Test func recoveryEndsTheEpisode() {
        let det = quiet()
        feed(det, 60, 0, agc: 2.0, cn0: 40.0, sv: 11)
        feed(det, 30, 60_000, agc: -10.0, cn0: 30.0, sv: 11)
        let snap = feed(det, 100, 90_000, agc: 2.0, cn0: 40.0, sv: 11)
        #expect(snap.lives.none { $0.kind == .interference })
        #expect(snap.marks.any { $0.kind == "interference" && $0.endedAt > 0 })
    }

    @Test func popupSaysWhyBeforeTheNumbers() throws {
        let det = quiet()
        feed(det, 60, 0, agc: 2.0, cn0: 40.0, sv: 11)
        let snap = feed(det, 30, 60_000, agc: -8.0, cn0: 32.0, sv: 11)
        let open = try #require(GnssAlerts().onLives(lives: snap.lives, floor: .low, nowWall: 1).notice)
        #expect(open.showDialog)
        #expect(open.title == "Possible GPS interference (Medium)")
        #expect(open.body.startsWith("This Mac's GPS got weaker."))
        #expect(open.body.contains("turned its gain down"))
        #expect(!open.body.contains("AGC"))
        #expect(open.details.contains("AGC"))
        #expect(open.body.contains("router"))
        #expect(!open.body.contains("jammer", ignoreCase: true))
        #expect(!open.body.contains("spoofer", ignoreCase: true))
        #expect(open.line.contains("GNSS"))
    }

    @Test func spoofPopupNamesThePatternBeforeTheNumbers() throws {
        let det = quiet(GnssConfig(spoofChecks: true))
        feed(det, 60, 0, agc: 2.0, cn0: 40.0, sv: 11)
        let snap = feed(det, 20, 60_000, agc: -8.0, cn0: 40.0, sv: 11, side: GnssSide(positionDisagree: true))
        let spoof = try #require(only(snap.lives, .spoofing))
        let open = try #require(GnssAlerts().onLives(lives: [spoof], floor: .low, nowWall: 1).notice)
        #expect(open.title.startsWith("Possible GPS spoofing"))
        #expect(open.body.startsWith("The receiver turned its gain down, and the satellite signals stayed up."))
        #expect(open.body.contains("GPS position does not match the network position."))
        #expect(!open.body.contains("AGC"))
        #expect(open.details.contains("AGC"))
        #expect(!open.body.contains("spoofer", ignoreCase: true))
    }

    @Test func popupFollowsTheFloorAndDismissLeavesTheLine() throws {
        let alerts = GnssAlerts()
        let live = GnssLive(
            kind: .interference,
            confidence: .medium,
            startedWall: 1_000,
            detail: "GPS L1: AGC -6.0 dB, signal -4.0 dB, 11 satellites (baseline 11)",
            adapted: false,
            rose: true
        )
        #expect(alerts.onLives(lives: [live], floor: .high, nowWall: 2_000).notice == nil)
        var quietLive = live
        quietLive.rose = false
        let open = alerts.onLives(lives: [quietLive], floor: .medium, nowWall: 3_000)
        let notice = try #require(open.notice)
        #expect(notice.showDialog)
        #expect(notice.body.contains("Wi-Fi router"))
        #expect(!notice.body.contains("jammer", ignoreCase: true))
        #expect(open.cue?.phrase == "Possible G P S interference")
        alerts.dismiss()
        let held = alerts.onLives(lives: [quietLive], floor: .medium, nowWall: 4_000)
        let heldNotice = try #require(held.notice)
        #expect(!heldNotice.showDialog)
        #expect(heldNotice.line.contains("Medium"))
        #expect(held.cue == nil)
        let ended = alerts.onLives(lives: [], floor: .medium, nowWall: 5_000)
        #expect(ended.notice?.line.contains("ended") == true)
    }

    @Test func debriefIncludesTheHitAndLeavesCoordinatesOut() throws {
        let now = 1_700_000_000_000
        let mark = GnssMark(
            at: now - 60_000,
            kind: "interference",
            confidence: "Medium",
            detail: "GPS L1: AGC -9.0 dB, signal -7.0 dB, 8 satellites (baseline 12)"
        )
        var settings = AppSettings()
        settings.tagLocation = false
        let doc = DebriefReport.document(
            devices: [],
            fleets: [],
            settings: settings,
            operatorPath: [],
            now: now,
            window: DebriefWindow(startAt: now - 15 * 60_000, endAt: now, sitName: "lot"),
            gnss: [mark]
        )
        let sections = doc.sections.filter { $0.title == "GNSS" }
        #expect(sections.count == 1)
        let section = try #require(sections.first)
        #expect(section.body.contains("Possible GNSS interference"))
        #expect(section.body.contains("Wi-Fi router"))
        #expect(!section.body.contains("latitude", ignoreCase: true))
        #expect(!section.body.contains("longitude", ignoreCase: true))
        #expect(section.alert)
        #expect(doc.pathFigure == nil)
        #expect(!section.body.contains("path map"))
    }

    @Test func debriefMarksThePathWithoutCoordinates() throws {
        let now = 1_700_000_000_000
        let mark = GnssMark(
            at: now - 60_000,
            endedAt: now - 30_000,
            kind: "interference",
            confidence: "High",
            detail: "GPS L1: AGC -8.0 dB, signal -6.0 dB, 7 satellites (baseline 11)"
        )
        let path = [
            GpsSample(at: now - 90_000, lat: 28.7800, lon: -81.3700),
            GpsSample(at: now - 50_000, lat: 28.7810, lon: -81.3710),
        ]
        var settings = AppSettings()
        settings.tagLocation = true
        let doc = DebriefReport.document(
            devices: [],
            fleets: [],
            settings: settings,
            operatorPath: path,
            now: now,
            window: DebriefWindow(startAt: now - 15 * 60_000, endAt: now, sitName: "lot"),
            gnss: [mark]
        )
        let sections = doc.sections.filter { $0.title == "GNSS" }
        #expect(sections.count == 1)
        let section = try #require(sections.first)
        #expect(section.body.contains("Possible GNSS interference"))
        #expect(section.body.contains("path map marks where this Mac was"))
        #expect(!section.body.contains("28.78"))
        #expect(!section.body.contains("jammer", ignoreCase: true))
        let figure = try #require(doc.pathFigure)
        #expect(figure.gnss.count == 1)
        let pin = try #require(figure.gnss.first)
        #expect(abs(pin.lat - 28.7810) < 0.00001)
        #expect(pin.keyLine().contains("High"))
        #expect(pin.keyLine().contains("AGC -8.0 dB"))
        #expect(!pin.keyLine().contains("28.781"))
        #expect(figure.caption.contains("red diamond"))
        #expect(!figure.caption.contains("28.781"))
    }

    // MARK: - helpers

    private func only(_ lives: [GnssLive], _ kind: GnssKind) -> GnssLive? {
        let hits = lives.filter { $0.kind == kind }
        return hits.count == 1 ? hits[0] : nil
    }

    private func quiet(_ config: GnssConfig = GnssConfig()) -> GnssDetector {
        var c = config
        c.settleMs = 0
        return GnssDetector(config: c)
    }

    @discardableResult
    private func feed(
        _ det: GnssDetector,
        _ n: Int,
        _ start: Int,
        agc: Double?,
        cn0: Double,
        sv: Int,
        galAgc: Double? = nil,
        galCn0: Double? = nil,
        side: GnssSide = GnssSide()
    ) -> GnssSnapshot {
        var last: GnssSnapshot?
        for i in 0..<n {
            last = det.onEpoch(epoch: epoch(start + i * 1_000, agc, cn0, sv, galAgc, galCn0), side: side)
        }
        return last!
    }

    private func epoch(_ t: Int, _ agc: Double?, _ cn0: Double, _ sv: Int, _ galAgc: Double?, _ galCn0: Double?) -> GnssEpoch {
        var bands: [BandKey: BandEpoch] = [:]
        bands[BandKey(constellation: GnssConstellation.GPS, band: .l1)] = BandEpoch(
            agcDb: agc,
            agcFromEventLevel: agc != nil,
            cn0Top3: cn0,
            svTracked: sv
        )
        if galAgc != nil || galCn0 != nil {
            bands[BandKey(constellation: GnssConstellation.GALILEO, band: .l1)] = BandEpoch(
                agcDb: galAgc,
                agcFromEventLevel: galAgc != nil,
                cn0Top3: galCn0 ?? cn0,
                svTracked: sv
            )
        }
        return GnssEpoch(elapsedMs: t, wallMs: t, clockDiscontinuity: 0, bands: bands)
    }
}
