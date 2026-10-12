import Foundation
import Testing
@testable import FieldwatchCore

// Port of GnssCalibrationTest.kt.
struct GnssCalibrationTest {
    @Test func steadyOpenSkyIsGoodAndKeepsTodaysBars() throws {
        let profile = try #require(saved(grade(steady(cn0: 40.0, sv: 20))))
        #expect(profile.grade == .good)
        #expect(abs(profile.cn0FloorDb - 0.0) < 0.01)
        #expect(abs(profile.agcFloorDb - 0.0) < 0.01)
        #expect(!profile.ignoreStopped)
        #expect(!profile.suppressAlerts)
        #expect(profile.summary() ==
            "Calibration complete. This Mac is Good. " +
            "It should work with a steady view of the sky, away from other electronics.")
        let rows = GnssCalibration.diagRows(profile: profile).map { $0.0 + " " + $0.1 }.joined(separator: " ")
        #expect(!rows.contains("latitude", ignoreCase: true))
        #expect(!rows.contains("longitude", ignoreCase: true))
        #expect(rows.contains("Good"))
    }

    @Test func weakerSteadyPhoneIsFairAndIgnoresMeasurementGaps() throws {
        let profile = try #require(saved(grade(steady(cn0: 27.0, sv: 16))))
        #expect(profile.grade == .fair)
        #expect(profile.ignoreStopped)
        #expect(!profile.suppressAlerts)
        #expect(profile.summary() ==
            "Calibration complete. This Mac is Fair. Usable. " +
            "Small drops will be hard to separate from this Mac's own GPS. " +
            "Medium or Low will be steadier than High.")
        let raised = GnssSensitivity.medium.thresholds().floored(agcFloorDb: profile.agcFloorDb, cn0FloorDb: profile.cn0FloorDb)
        #expect(abs(raised.agcDropDb - 5.0) < 0.01)
        #expect(abs(raised.cn0DropDb - 3.0) < 0.01)
    }

    @Test func wildSignalIsPoorAndSuppressesThePopup() throws {
        let epochs = (0..<55).map { i in
            epoch(i * 1_000, cn0: i % 2 == 0 ? 30.0 : 40.0, sv: 20)
        }
        let profile = try #require(saved(grade(attempt(epochs))))
        #expect(profile.grade == .poor)
        #expect(profile.suppressAlerts)
        #expect(profile.ignoreStopped)
        #expect(abs(profile.cn0FloorDb - 8.0) < 0.01)
        #expect(profile.summary() ==
            "Calibration complete. This Mac is Poor. " +
            "This Mac's GPS is too coarse for an interference alert. " +
            "It can still tag a path. The popup stays off.")
    }

    @Test func movingPhoneIsNotSaved() {
        let fixes = stillFixes().enumerated().map { i, fix -> GnssCalFix in
            if i < 8 { return fix }
            var moved = fix
            moved.lat = fix.lat + 0.002
            return moved
        }
        let outcome = grade(attempt(steadyEpochs(40.0, 20), fixes))
        #expect(rejected(outcome) == GnssCalibration.MOVING)
    }

    @Test func shortRunAndWeakSkyAreRejected() {
        let short = grade(attempt((0..<10).map { epoch($0 * 1_000, cn0: 40.0, sv: 20) }))
        #expect(rejected(short) == GnssCalibration.FEW_READINGS)
        let indoor = grade(steady(cn0: 40.0, sv: 4))
        #expect(rejected(indoor) == GnssCalibration.FEW_SV)
        let weak = grade(steady(cn0: 12.0, sv: 20))
        #expect(rejected(weak) == GnssCalibration.WEAK)
        let noFix = grade(attempt(steadyEpochs(40.0, 20), []))
        #expect(rejected(noFix) == GnssCalibration.NO_FIX)
    }

    @Test func diagnosticsSaysNotRunUntilAProfileExists() {
        let rows = GnssCalibration.diagRows(profile: nil)
        #expect(rows.count == 1)
        #expect(rows.first?.1 == "not run")
    }

    @Test func settingsExportLeavesThePhoneProfileOut() throws {
        var settings = AppSettings()
        settings.gnssMonitor = true
        let encoded = try SettingsExchange.encode(
            pack: SettingsExchange.pack(
                settings: settings,
                filter: FilterState(),
                presets: [],
                watchlist: [],
                hiddenPresetIds: [],
                appVersion: "1.1.22",
                exportedAt: "2026-10-08T00:00:00Z"
            )
        )
        #expect(!encoded.contains("calibration"))
        #expect(!encoded.contains("suppressAlerts"))
        #expect(!encoded.contains("cn0FloorDb"))
    }

    private func saved(_ outcome: GnssCalOutcome) -> GnssPhoneProfile? {
        if case .saved(let profile) = outcome { return profile }
        return nil
    }

    private func rejected(_ outcome: GnssCalOutcome) -> String? {
        if case .rejected(let reason) = outcome { return reason }
        return nil
    }

    private func grade(_ attempt: GnssCalAttempt) -> GnssCalOutcome {
        GnssCalibration.grade(attempt: attempt, nowWall: 1_700_000_000_000)
    }

    private func steady(cn0: Double, sv: Int) -> GnssCalAttempt {
        attempt(steadyEpochs(cn0, sv), stillFixes())
    }

    private func steadyEpochs(_ cn0: Double, _ sv: Int) -> [GnssEpoch] {
        (0..<55).map { epoch($0 * 1_000, cn0: cn0, sv: sv) }
    }

    private func attempt(_ epochs: [GnssEpoch], _ fixes: [GnssCalFix]? = nil) -> GnssCalAttempt {
        GnssCalAttempt(epochs: epochs, fixes: fixes ?? stillFixes(), startedElapsedMs: 0, endedElapsedMs: 60_000)
    }

    private func epoch(_ t: Int, cn0: Double, sv: Int) -> GnssEpoch {
        GnssEpoch(
            elapsedMs: t,
            wallMs: t,
            clockDiscontinuity: 0,
            bands: [
                BandKey(constellation: GnssConstellation.GPS, band: .l1): BandEpoch(
                    agcDb: 2.0,
                    agcFromEventLevel: true,
                    cn0Top3: cn0,
                    svTracked: sv
                ),
            ]
        )
    }

    private func stillFixes() -> [GnssCalFix] {
        (0..<20).map { i in
            GnssCalFix(elapsedMs: i * 3_000, accM: 5.0, speedMps: 0.0, lat: 28.78723, lon: -81.37300)
        }
    }
}
