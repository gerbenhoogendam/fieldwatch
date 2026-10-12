import Foundation
import Testing
@testable import FieldwatchCore

// Port of ScanStatusTest.kt. User-facing strings follow the macOS rewording in ScanStatus.swift.
struct ScanStatusTest {
    private let now = 1_700_000_000_000
    private let planted = "28.787120, -81.365491"

    private func radio(
        scanning: Bool = true,
        wifiOn: Bool = true,
        wifiWaitingOnOs: Bool = false,
        lastWifiScanAt: Int? = nil,
        bleOn: Bool = true,
        bleRunning: Bool = true,
        bleParked: Bool = false,
        bleRetrying: Bool = false,
        bleStarting: Bool = false,
        bleHitsLastMin: Int = 0
    ) -> ScanRadioFacts {
        ScanRadioFacts(
            scanning: scanning, wifiOn: wifiOn, wifiWaitingOnOs: wifiWaitingOnOs,
            lastWifiScanAt: lastWifiScanAt ?? (now - 12_000),
            bleOn: bleOn, bleRunning: bleRunning, bleParked: bleParked, bleRetrying: bleRetrying,
            bleStarting: bleStarting, bleHitsLastMin: bleHitsLastMin
        )
    }

    private func phone(
        locationOn: Bool = true,
        locationPermission: Bool = true,
        gpsFixAgeMs: Int? = 12_000,
        arrivalsOnly: Bool = false,
        watchedOnly: Bool = false,
        customNamesOnly: Bool = false,
        showOnly: Bool = false,
        movingWithYou: Bool = false,
        showWifi: Bool = true,
        showBle: Bool = true,
        nameFilter: Bool = false,
        ouiFilter: Bool = false
    ) -> ScanPhoneFacts {
        ScanPhoneFacts(
            versionName: "1.1.21",
            versionCode: 31,
            catalogVersion: 92,
            manufacturer: "Apple",
            model: "MacBookPro18,3",
            androidRelease: "15.1",
            sdkInt: 24,
            fingerprint: "Version 15.1 (Build 24B83)",
            locationOn: locationOn,
            locationPermission: locationPermission,
            gpsFixAgeMs: gpsFixAgeMs,
            arrivalsOnly: arrivalsOnly,
            watchedOnly: watchedOnly,
            customNamesOnly: customNamesOnly,
            showOnly: showOnly,
            movingWithYou: movingWithYou,
            showWifi: showWifi,
            showBle: showBle,
            nameFilter: nameFilter,
            ouiFilter: ouiFilter
        )
    }

    private func value(_ report: ScanStatusReport, _ key: String) -> String {
        report.rows.first { $0.0 == key }!.1
    }

    @Test func locationOffBlocksAndNamesTheSwitch() {
        let report = ScanStatus.report(radio: radio(), phone: phone(locationOn: false), now: now)
        #expect(report.verdict == "Location is off. macOS will not reveal Wi-Fi network names or addresses.")
        // macOS: BLE keeps working without Location, so the scan is not blocked while Bluetooth runs.
        #expect(!report.blocked)
        #expect(ScanStatus.isBlocked(radio: radio(bleRunning: false), locationOn: false, locationPermission: true))
        #expect(value(report, "Location") == "off")
        #expect(report.checks.any { $0.startsWith("Turn Location on.") })
        #expect(!report.checks.any { $0.contains("Location services") })
    }

    @Test func locationPermissionMissingBlocks() {
        let report = ScanStatus.report(radio: radio(), phone: phone(locationPermission: false), now: now)
        #expect(report.verdict == "Location permission is off.")
        #expect(!report.blocked)
        #expect(report.checks.any { $0.startsWith("Allow location for Fieldwatch.") })
    }

    @Test func wifiRefusedAndBleParkedWhenRadiosAreOn() {
        let report = ScanStatus.report(
            radio: radio(wifiWaitingOnOs: true, bleParked: true, bleHitsLastMin: 0),
            phone: phone(),
            now: now
        )
        #expect(report.verdict == "Wi-Fi scan refused. BLE scan is parked. Both radios are on.")
        #expect(report.blocked)
        #expect(value(report, "Last Wi-Fi scan") == "waiting on OS (12s ago)")
        #expect(value(report, "BLE") == "parked")
        #expect(value(report, "BLE results last minute") == "0")
        #expect(report.checks.any { $0.contains("The Wi-Fi radio is on.") })
        #expect(report.checks.any { $0.contains("The Bluetooth radio is on.") })
        #expect(!report.checks.any { $0.contains("Wi-Fi scanning") })
        #expect(!report.checks.any { $0.contains("Bluetooth scanning") })
    }

    @Test func quietAirIsNotAFailure() {
        let report = ScanStatus.report(radio: radio(lastWifiScanAt: now - 40_000, bleHitsLastMin: 0), phone: phone(), now: now)
        #expect(report.verdict == "Scans are running. Nothing is on the air.")
        #expect(report.checks == ["Nothing that needs to be on is off. Scans are running. Nothing is on the air right now."])
        #expect(!report.blocked)
        #expect(value(report, "Filters") == "All Traffic")
        #expect(value(report, "Last Wi-Fi scan") == "40s ago")
        #expect(value(report, "Location fix") == "12s ago")
    }

    @Test func headerColorsFollowTheRadio() {
        let on = radio()
        #expect(wifiHeader(scanning: true, locationOn: true, radio: on).0 == .healthy)
        #expect(wifiHeader(scanning: true, locationOn: true, radio: on).1 == "Wi-Fi on")
        #expect(bleHeader(scanning: true, locationOn: true, radio: on).0 == .healthy)
        #expect(wifiHeader(scanning: true, locationOn: true, radio: radio(wifiOn: false)).0 == .off)
        #expect(bleHeader(scanning: true, locationOn: true, radio: radio(bleOn: false)).0 == .off)
        #expect(wifiHeader(scanning: false, locationOn: true, radio: on).0 == .idle)
        #expect(wifiHeader(scanning: true, locationOn: true, radio: radio(wifiWaitingOnOs: true)).0 == .problem)
        #expect(wifiHeader(scanning: true, locationOn: false, radio: on).0 == .problem)
        #expect(bleHeader(scanning: true, locationOn: true, radio: radio(bleRunning: false, bleParked: true)).0 == .healthy)
        #expect(bleHeader(scanning: true, locationOn: true, radio: radio(bleRunning: false, bleRetrying: true)).0 == .problem)
        #expect(bleHeader(scanning: true, locationOn: true, radio: radio(bleRunning: false)).0 == .problem)
        #expect(gpsHeader(monitorOn: false, suppressAlerts: false, scanning: true, statusLine: "armed", alertShowing: false) == nil)
        #expect(gpsHeader(monitorOn: true, suppressAlerts: false, scanning: true, statusLine: "armed", alertShowing: false)?.0 == .healthy)
        #expect(gpsHeader(monitorOn: true, suppressAlerts: false, scanning: true, statusLine: "learning 4/60 s", alertShowing: false)?.0 == .idle)
        #expect(gpsHeader(monitorOn: true, suppressAlerts: false, scanning: true, statusLine: GnssCopy.PAUSED, alertShowing: false)?.0 == .idle)
        #expect(gpsHeader(monitorOn: true, suppressAlerts: true, scanning: true, statusLine: "armed", alertShowing: false)?.0 == .idle)
        #expect(gpsHeader(monitorOn: true, suppressAlerts: false, scanning: true, statusLine: "armed", alertShowing: true)?.0 == .problem)
        #expect(gpsHeader(monitorOn: true, suppressAlerts: false, scanning: true, statusLine: GnssCopy.PAUSED, alertShowing: false)?.1 == "GPS paused")
    }

    @Test func scanOptionsFollowTheSettingsSwitches() {
        var throttled = phone()
        throttled.wifiOsThrottled = true
        let off = ScanStatus.report(radio: radio(), phone: throttled, now: now)
        #expect(value(off, "Wi-Fi scan pacing") == "slowed by macOS")
        #expect(value(off, "Scan in background") == "off")
        #expect(value(off, "App Nap exemption") == "off")
        #expect(!off.checks.any { $0.contains("throttling") })
        var open = phone()
        open.wifiOsThrottled = false
        open.backgroundUsage = true
        open.unrestrictedBattery = true
        let on = ScanStatus.report(radio: radio(), phone: open, now: now)
        #expect(value(on, "Wi-Fi scan pacing") == "on demand")
        #expect(value(on, "Scan in background") == "on")
        #expect(value(on, "App Nap exemption") == "on")
    }

    @Test func radiosOnTheAirAreNotCalledQuiet() {
        let report = ScanStatus.report(radio: radio(), phone: phone(), now: now, radiosOnAir: 12)
        #expect(report.verdict == "Scans are running.")
        #expect(!report.verdict.contains("Nothing is on the air"))
        #expect(report.checks == ["Nothing that needs to be on is off. Scans are running."])
        #expect(!report.blocked)
    }

    @Test func aFilterHidesTheListWithoutBlocking() {
        let flags = [
            phone(arrivalsOnly: true),
            phone(watchedOnly: true),
            phone(customNamesOnly: true),
            phone(showOnly: true),
            phone(movingWithYou: true),
            phone(showWifi: false),
            phone(nameFilter: true),
            phone(ouiFilter: true),
        ]
        for facts in flags {
            let report = ScanStatus.report(radio: radio(), phone: facts, now: now)
            #expect(report.verdict == "Scans are running. A filter is hiding the list.")
            #expect(!report.blocked)
            let filters = value(report, "Filters")
            #expect(filters != "All Traffic")
            #expect(report.checks.count == 1)
            #expect(report.checks.first?.contains(filters) == true)
            #expect(report.checks.first?.contains("All Traffic") == true)
        }
    }

    @Test func bleStillStartingIsNotBlocked() {
        let facts = radio(
            wifiOn: false,
            lastWifiScanAt: 0,
            bleOn: true,
            bleRunning: false,
            bleStarting: true
        )
        let report = ScanStatus.report(radio: facts, phone: phone(), now: now)
        #expect(report.verdict == "Scanning is starting.")
        #expect(!report.blocked)
        #expect(!ScanStatus.isBlocked(radio: facts, locationOn: true, locationPermission: true))
        #expect(value(report, "BLE") == "starting")
        #expect(value(report, "Last Wi-Fi scan") == "none")
    }

    @Test func copyTextHasNoCoordinatesOrRadioNames() {
        let report = ScanStatus.report(radio: radio(), phone: phone(gpsFixAgeMs: nil), now: now)
        #expect(value(report, "Location fix") == "none")
        #expect(report.text.startsWith("App: 1.1.21 (31)\n"))
        #expect(report.text.contains("Verdict: \(report.verdict)\n"))
        #expect(report.text.contains("Check:\n- Nothing that needs to be on is off."))
        #expect(!report.text.contains(planted))
        #expect(!report.text.contains("latitude", ignoreCase: true))
        #expect(!report.text.contains("longitude", ignoreCase: true))
        #expect(!report.text.contains("SSID", ignoreCase: true))
        let labels = report.rows.map { $0.0 }
        #expect(labels == [
            "App", "Catalog", "Mac", "macOS", "OS build",
            "Wi-Fi", "Last Wi-Fi scan", "Bluetooth", "BLE", "BLE results last minute",
            "Wi-Fi scan pacing", "Scan in background", "App Nap exemption",
            "Location", "Location permission", "Location fix", "Filters",
        ])
        #expect(value(report, "Mac") == "Apple MacBookPro18,3")
        #expect(value(report, "macOS") == "15.1 (Darwin 24)")
    }

    @Test func waitingWithNoPriorScanOmitsTheAge() {
        let report = ScanStatus.report(
            radio: radio(wifiWaitingOnOs: true, lastWifiScanAt: 0, bleOn: false, bleRunning: false),
            phone: phone(),
            now: now
        )
        #expect(value(report, "Last Wi-Fi scan") == "waiting on OS")
        #expect(report.blocked)
    }

    @Test func scanningStoppedBlocksEvenWhenRadiosLookOn() {
        let report = ScanStatus.report(radio: radio(scanning: false), phone: phone(), now: now)
        #expect(report.verdict == "Scanning is not running.")
        #expect(report.blocked)
    }

    @Test func olderThanAMinuteReadsInMinutes() {
        let report = ScanStatus.report(
            radio: radio(lastWifiScanAt: now - 125_000),
            phone: phone(gpsFixAgeMs: 125_000),
            now: now
        )
        #expect(value(report, "Last Wi-Fi scan") == "2 min ago")
        #expect(value(report, "Location fix") == "2 min ago")
    }
}
