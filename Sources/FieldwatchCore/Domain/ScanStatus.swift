import Foundation

// Port of domain/ScanStatus.kt.
// Settings → Diagnostics. Mac and scan facts only. No network names, MACs, or coordinates.
// The decision logic is the Android logic unchanged. User-facing text is rewritten for macOS:
// macOS scans Wi-Fi on demand (roughly every 10–30 s), needs Location permission to reveal
// network names and addresses, and needs the Bluetooth privacy permission for BLE.
// ScanPhoneFacts keeps its Kotlin field names; on a Mac the app fills them as documented below.

public enum HeaderTone: String, CaseIterable, Sendable {
    case off = "OFF", idle = "IDLE", healthy = "HEALTHY", problem = "PROBLEM"
}

/// Wi-Fi icon in the list header. Green is healthy, including the wait between scans.
public func wifiHeader(scanning: Bool, locationOn: Bool, radio: ScanRadioFacts) -> (HeaderTone, String) {
    if !radio.wifiOn { return (.off, "Wi-Fi off") }
    if !scanning { return (.idle, "Wi-Fi idle") }
    if !locationOn { return (.problem, "Wi-Fi, Location is off") }
    if radio.wifiWaitingOnOs { return (.problem, "Wi-Fi waiting on macOS") }
    return (.healthy, "Wi-Fi on")
}

/// GPS icon in the list header. Nil when the check is off (always, on a Mac).
/// Green is armed and quiet. A hit is red. A pause, a Poor receiver, and the warmup stay muted.
public func gpsHeader(
    monitorOn: Bool,
    suppressAlerts: Bool,
    scanning: Bool,
    statusLine: String,
    alertShowing: Bool
) -> (HeaderTone, String)? {
    if !monitorOn { return nil }
    if alertShowing { return (.problem, "GPS alert") }
    if statusLine == GnssCopy.PAUSED { return (.idle, "GPS paused") }
    if !scanning || suppressAlerts { return (.idle, "GPS on") }
    let ready = statusLine == "armed" || statusLine.startsWith("AGC not available")
    return ready ? (.healthy, "GPS on") : (.idle, "GPS on")
}

/// Bluetooth icon in the list header. A planned rest stays healthy.
public func bleHeader(scanning: Bool, locationOn: Bool, radio: ScanRadioFacts) -> (HeaderTone, String) {
    if !radio.bleOn { return (.off, "Bluetooth off") }
    if !scanning { return (.idle, "Bluetooth idle") }
    // macOS: Bluetooth LE scanning does not depend on Location (Android withheld BLE results without it).
    let stuck = !radio.bleRunning && !radio.bleParked && !radio.bleRetrying && !radio.bleStarting
    if radio.bleRetrying || stuck { return (.problem, "Bluetooth waiting on macOS") }
    return (.healthy, "Bluetooth on")
}

public struct ScanRadioFacts: Hashable, Sendable {
    public var scanning: Bool
    public var wifiOn: Bool
    public var wifiWaitingOnOs: Bool
    public var lastWifiScanAt: Int
    public var bleOn: Bool
    public var bleRunning: Bool
    public var bleParked: Bool
    public var bleRetrying: Bool
    public var bleStarting: Bool
    public var bleHitsLastMin: Int

    public init(
        scanning: Bool = false, wifiOn: Bool = false, wifiWaitingOnOs: Bool = false, lastWifiScanAt: Int = 0,
        bleOn: Bool = false, bleRunning: Bool = false, bleParked: Bool = false, bleRetrying: Bool = false,
        bleStarting: Bool = false, bleHitsLastMin: Int = 0
    ) {
        self.scanning = scanning; self.wifiOn = wifiOn; self.wifiWaitingOnOs = wifiWaitingOnOs
        self.lastWifiScanAt = lastWifiScanAt; self.bleOn = bleOn; self.bleRunning = bleRunning
        self.bleParked = bleParked; self.bleRetrying = bleRetrying; self.bleStarting = bleStarting
        self.bleHitsLastMin = bleHitsLastMin
    }
}

/// Kotlin field names kept. On macOS: `manufacturer` "Apple", `model` the hardware model
/// (e.g. "MacBookPro18,3"), `androidRelease` the macOS version ("15.1"), `sdkInt` the Darwin
/// major version, `fingerprint` the OS build string, `gpsFixAgeMs` the age of the last
/// CoreLocation fix, `wifiOsThrottled` true when macOS refused or slowed an on-demand scan,
/// `backgroundUsage` scanning continues while Fieldwatch is in the background,
/// `unrestrictedBattery` the App Nap exemption is held.
public struct ScanPhoneFacts: Hashable, Sendable {
    public var versionName: String
    public var versionCode: Int
    public var catalogVersion: Int
    public var manufacturer: String
    public var model: String
    public var androidRelease: String
    public var sdkInt: Int
    public var fingerprint: String
    public var locationOn: Bool
    public var locationPermission: Bool
    /// Milliseconds since the last location fix. Nil when this Mac has none.
    public var gpsFixAgeMs: Int?
    public var arrivalsOnly: Bool
    public var watchedOnly: Bool
    public var customNamesOnly: Bool
    public var showOnly: Bool
    public var movingWithYou: Bool
    public var showWifi: Bool
    public var showBle: Bool
    public var nameFilter: Bool
    public var ouiFilter: Bool
    /// Settings switch (Android only; kept for settings-pack compatibility).
    public var wifiFastScan: Bool
    public var wifiOsThrottled: Bool
    public var backgroundUsage: Bool
    public var unrestrictedBattery: Bool

    public init(
        versionName: String, versionCode: Int, catalogVersion: Int, manufacturer: String, model: String,
        androidRelease: String, sdkInt: Int, fingerprint: String, locationOn: Bool, locationPermission: Bool,
        gpsFixAgeMs: Int?, arrivalsOnly: Bool = false, watchedOnly: Bool = false, customNamesOnly: Bool = false,
        showOnly: Bool = false, movingWithYou: Bool = false, showWifi: Bool = true, showBle: Bool = true,
        nameFilter: Bool = false, ouiFilter: Bool = false, wifiFastScan: Bool = false, wifiOsThrottled: Bool = false,
        backgroundUsage: Bool = false, unrestrictedBattery: Bool = false
    ) {
        self.versionName = versionName; self.versionCode = versionCode; self.catalogVersion = catalogVersion
        self.manufacturer = manufacturer; self.model = model; self.androidRelease = androidRelease
        self.sdkInt = sdkInt; self.fingerprint = fingerprint; self.locationOn = locationOn
        self.locationPermission = locationPermission; self.gpsFixAgeMs = gpsFixAgeMs
        self.arrivalsOnly = arrivalsOnly; self.watchedOnly = watchedOnly; self.customNamesOnly = customNamesOnly
        self.showOnly = showOnly; self.movingWithYou = movingWithYou; self.showWifi = showWifi
        self.showBle = showBle; self.nameFilter = nameFilter; self.ouiFilter = ouiFilter
        self.wifiFastScan = wifiFastScan; self.wifiOsThrottled = wifiOsThrottled
        self.backgroundUsage = backgroundUsage; self.unrestrictedBattery = unrestrictedBattery
    }
}

public struct ScanStatusReport {
    public var rows: [(String, String)]
    public var verdict: String
    /// Plain steps for the person at the Mac. Empty never happens.
    public var checks: [String]
    public var text: String
    public var blocked: Bool

    public init(rows: [(String, String)], verdict: String, checks: [String], text: String, blocked: Bool) {
        self.rows = rows; self.verdict = verdict; self.checks = checks; self.text = text; self.blocked = blocked
    }
}

public enum ScanStatus {
    public static func report(
        radio: ScanRadioFacts,
        phone: ScanPhoneFacts,
        now: Int,
        radiosOnAir: Int = 0,
        gnssRows: [(String, String)] = []
    ) -> ScanStatusReport {
        let rows: [(String, String)] = [
            ("App", "\(phone.versionName) (\(phone.versionCode))"),
            ("Catalog", String(phone.catalogVersion)),
            ("Mac", "\(phone.manufacturer) \(phone.model)".trim()),
            ("macOS", "\(phone.androidRelease) (Darwin \(phone.sdkInt))"),
            ("OS build", phone.fingerprint),
            ("Wi-Fi", radio.wifiOn ? "on" : "off"),
            ("Last Wi-Fi scan", lastWifi(radio, now)),
            ("Bluetooth", radio.bleOn ? "on" : "off"),
            ("BLE", bleState(radio)),
            ("BLE results last minute", String(radio.bleHitsLastMin.coerceAtLeast(0))),
            ("Wi-Fi scan pacing", fasterWifi(phone)),
            ("Scan in background", onOff(phone.backgroundUsage)),
            ("App Nap exemption", onOff(phone.unrestrictedBattery)),
            ("Location", phone.locationOn ? "on" : "off"),
            ("Location permission", phone.locationPermission ? "granted" : "missing"),
            ("Location fix", ageLabel(phone.gpsFixAgeMs)),
            ("Filters", filtersLabel(phone)),
        ] + gnssRows
        let verdict = self.verdict(radio, phone, radiosOnAir)
        let checks = self.checks(radio, phone, radiosOnAir)
        let blocked = isBlocked(radio: radio, locationOn: phone.locationOn, locationPermission: phone.locationPermission)
        var text = ""
        for (k, v) in rows { text += "\(k): \(v)\n" }
        text += "Verdict: \(verdict)\n"
        text += "Check:\n"
        for c in checks { text += "- \(c)\n" }
        return ScanStatusReport(rows: rows, verdict: verdict, checks: checks, text: text, blocked: blocked)
    }

    public static func isBlocked(radio: ScanRadioFacts, locationOn: Bool, locationPermission: Bool) -> Bool {
        if !radio.scanning { return true }
        if radio.bleStarting && !radio.bleRunning { return false }
        // macOS: without Location only Wi-Fi goes dark (names and BSSIDs hidden); BLE still works.
        let wifi = wifiUsable(radio) && locationOn && locationPermission
        return !wifi && !bleUsable(radio)
    }

    /// Appended to an empty Live list while a scan is blocked.
    public static let EMPTY_POINTER = "Settings → Diagnostics."

    private static func wifiUsable(_ radio: ScanRadioFacts) -> Bool {
        radio.wifiOn && !radio.wifiWaitingOnOs
    }

    private static func bleUsable(_ radio: ScanRadioFacts) -> Bool {
        radio.bleOn && radio.bleRunning && !radio.bleParked && !radio.bleRetrying
    }

    private static func verdict(_ radio: ScanRadioFacts, _ phone: ScanPhoneFacts, _ radiosOnAir: Int) -> String {
        let wifiOk = wifiUsable(radio)
        let bleOk = bleUsable(radio)
        if !radio.scanning { return "Scanning is not running." }
        if !phone.locationOn { return "Location is off. macOS will not reveal Wi-Fi network names or addresses." }
        if !phone.locationPermission { return "Location permission is off." }
        if !radio.wifiOn && !radio.bleOn { return "Wi-Fi and Bluetooth are off." }
        if radio.bleStarting && !radio.bleRunning && !radio.wifiWaitingOnOs { return "Scanning is starting." }
        if !wifiOk && !bleOk && radio.wifiWaitingOnOs && radio.bleParked {
            return "Wi-Fi scan refused. BLE scan is parked. Both radios are on."
        }
        if !wifiOk && !bleOk && radio.bleParked { return "BLE scan is parked. Bluetooth is on." }
        if !wifiOk && !bleOk && radio.bleRetrying { return "BLE scan is retrying." }
        if !wifiOk && !bleOk && radio.wifiWaitingOnOs { return "Wi-Fi scan refused. Wi-Fi is on." }
        if !wifiOk && !bleOk { return "Wi-Fi and Bluetooth scans are not running." }
        if radio.wifiWaitingOnOs && bleOk { return "Wi-Fi scan refused. BLE is running." }
        if radio.bleParked && wifiOk { return "BLE scan is parked. Wi-Fi is running." }
        if !radio.wifiOn && bleOk { return "Wi-Fi is off. BLE is running." }
        if !radio.bleOn && wifiOk { return "Bluetooth is off. Wi-Fi is running." }
        if filterHiding(phone) { return "Scans are running. A filter is hiding the list." }
        if radiosOnAir > 0 { return "Scans are running." }
        return "Scans are running. Nothing is on the air."
    }

    /// What to turn on, in the order a person can fix it.
    /// A radio that is off is named only when the other radio is still hearing.
    /// Background scanning, the App Nap exemption, and a location fix are not required
    /// while Fieldwatch is open, so they stay in the fact rows.
    private static func checks(_ radio: ScanRadioFacts, _ phone: ScanPhoneFacts, _ radiosOnAir: Int) -> [String] {
        var lines: [String] = []
        if !radio.scanning {
            lines.append("Scanning is not running. Open Live. If Fieldwatch asks for permission, allow Location and Bluetooth.")
        }
        if !phone.locationOn {
            lines.append("Turn Location on. macOS hides Wi-Fi network names and addresses while Location Services is off. System Settings, Privacy & Security, Location Services.")
        }
        if !phone.locationPermission {
            lines.append("Allow location for Fieldwatch. System Settings, Privacy & Security, Location Services, Fieldwatch.")
        }
        let wifiOk = wifiUsable(radio)
        let bleOk = bleUsable(radio)
        let locationReady = phone.locationOn && phone.locationPermission
        if !radio.wifiOn && !radio.bleOn {
            lines.append("Turn Wi-Fi or Bluetooth on. Fieldwatch hears access points and Bluetooth advertisements.")
        } else {
            if !radio.wifiOn && bleOk {
                lines.append("Wi-Fi is off, so access points will not appear. Bluetooth is running.")
            }
            if !radio.bleOn && wifiOk {
                lines.append("Bluetooth is off, so Bluetooth radios will not appear. Wi-Fi is running.")
            }
            if locationReady && radio.wifiOn && radio.wifiWaitingOnOs {
                lines.append("Wi-Fi scans are being refused. The Wi-Fi radio is on. macOS allows an on-demand scan about every 10 to 30 seconds. If this lasts, toggle Wi-Fi off and on, then reopen Fieldwatch.")
            }
            if locationReady && radio.bleOn && radio.bleParked {
                lines.append("Bluetooth scans are parked. The Bluetooth radio is on. Fieldwatch will try again.")
            }
            if radio.bleOn && radio.bleRetrying {
                lines.append("Bluetooth scan is retrying. Toggle Bluetooth off and on, then reopen Fieldwatch.")
            }
            if radio.bleOn && radio.bleStarting && !radio.bleRunning {
                lines.append("Bluetooth is still starting. Wait a few seconds.")
            }
            if radio.bleOn && !radio.bleRunning && !radio.bleParked && !radio.bleRetrying && !radio.bleStarting {
                lines.append("Bluetooth is on, and the scan is not running. Allow Bluetooth for Fieldwatch in System Settings, Privacy & Security, Bluetooth. Then toggle Bluetooth off and on, and reopen Fieldwatch.")
            }
        }
        if filterHiding(phone) {
            lines.append("A filter is hiding radios. Filters is \(filtersLabel(phone)). Set Filters to All Traffic to see everything the Mac hears.")
        }
        if lines.isEmpty {
            lines.append(radiosOnAir > 0
                ? "Nothing that needs to be on is off. Scans are running."
                : "Nothing that needs to be on is off. Scans are running. Nothing is on the air right now.")
        }
        return lines
    }

    private static func filterHiding(_ phone: ScanPhoneFacts) -> Bool {
        phone.arrivalsOnly || phone.watchedOnly || phone.customNamesOnly || phone.showOnly ||
            phone.movingWithYou || !phone.showWifi || !phone.showBle || phone.nameFilter || phone.ouiFilter
    }

    private static func filtersLabel(_ phone: ScanPhoneFacts) -> String {
        var parts: [String] = []
        if phone.arrivalsOnly { parts.append("Arrivals only") }
        if phone.watchedOnly { parts.append("Watched only") }
        if phone.customNamesOnly { parts.append("Named radios only") }
        if phone.showOnly { parts.append("Show only") }
        if phone.movingWithYou { parts.append("Moving with you") }
        if !phone.showWifi { parts.append("Wi-Fi hidden") }
        if !phone.showBle { parts.append("BLE hidden") }
        if phone.nameFilter { parts.append("Name filter on") }
        if phone.ouiFilter { parts.append("OUI filter on") }
        return parts.isEmpty ? "All Traffic" : parts.joined(separator: ", ")
    }

    private static func onOff(_ on: Bool) -> String { on ? "on" : "off" }

    private static func fasterWifi(_ phone: ScanPhoneFacts) -> String {
        phone.wifiOsThrottled ? "slowed by macOS" : "on demand"
    }

    private static func lastWifi(_ radio: ScanRadioFacts, _ now: Int) -> String {
        let age = ageLabel(radio.lastWifiScanAt > 0 ? now - radio.lastWifiScanAt : nil)
        if radio.wifiWaitingOnOs && radio.lastWifiScanAt > 0 { return "waiting on OS (\(age))" }
        if radio.wifiWaitingOnOs { return "waiting on OS" }
        return age
    }

    private static func bleState(_ radio: ScanRadioFacts) -> String {
        if !radio.bleOn { return "off" }
        if radio.bleParked { return "parked" }
        if radio.bleRetrying { return "retrying" }
        if radio.bleStarting && !radio.bleRunning { return "starting" }
        if radio.bleRunning { return "running" }
        return "not running"
    }

    private static func ageLabel(_ ageMs: Int?) -> String {
        guard let ageMs, ageMs >= 0 else { return "none" }
        let sec = ageMs / 1000
        return sec < 60 ? "\(sec)s ago" : "\(sec / 60) min ago"
    }
}
