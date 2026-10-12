import AppKit
import CoreBluetooth
import CoreLocation
import FieldwatchCore
import Foundation

/// macOS replacement for radio/Permissions.kt (`object RadioPermissions`).
///
/// Android asked for location + Bluetooth (+ nearby Wi-Fi, notifications) up front. On the Mac:
/// - Bluetooth: TCC prompt appears the first time a CBCentralManager is created (BleRadio does that on scan
///   start, or `request()` here). Without it there is no BLE at all.
/// - Location: needed for Wi-Fi BSSIDs/SSIDs (CoreWLAN hides them otherwise) and GPS tagging. BLE works without it.
/// - Notifications: only for the optional watchlist banner; asked lazily by `Alerter`.
///
/// `granted(context:)` answers "may scanning start": true unless Bluetooth was denied / restricted / unsupported.
/// A not-yet-answered Bluetooth prompt counts as OK — starting the scan shows it. Location is reported separately
/// (`FieldwatchApp.hasFineLocation()` / `systemLocationOn()`), like the Android VM's `scanBlocked` input.
public enum RadioPermissions {
    public static let BLUETOOTH = "Bluetooth"
    public static let LOCATION = "Location"

    /// Privacy panes (System Settings → Privacy & Security).
    public static let bluetoothSettingsUrl = "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
    public static let locationSettingsUrl = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
    public static let notificationSettingsUrl = "x-apple.systempreferences:com.apple.preference.notifications"

    /// What Fieldwatch asks for (names, for the permission card).
    public static func required() -> [String] { [BLUETOOTH, LOCATION] }

    /// Not yet granted, in `required()` order. Not-determined counts as missing here.
    public static func missing(context: FieldwatchApp? = nil) -> [String] {
        var out: [String] = []
        if !bluetoothGranted() { out.append(BLUETOOTH) }
        if !locationGranted(context: context) { out.append(LOCATION) }
        return out
    }

    /// Scanning may start (see type doc). Kotlin `RadioPermissions.granted(context)`.
    public static func granted(context: FieldwatchApp? = nil) -> Bool { !bluetoothBlocked() }

    /// Every permission answered yes.
    public static func allGranted(context: FieldwatchApp? = nil) -> Bool { missing(context: context).isEmpty }

    // MARK: Bluetooth

    public static func bluetoothAuthorization() -> CBManagerAuthorization { CBManager.authorization }

    public static func bluetoothGranted() -> Bool { CBManager.authorization == .allowedAlways }

    /// The operator said no, or MDM restricts Bluetooth for this app.
    public static func bluetoothBlocked() -> Bool {
        let a = CBManager.authorization
        return a == .denied || a == .restricted
    }

    public static func bluetoothNotDetermined() -> Bool { CBManager.authorization == .notDetermined }

    public static func bluetoothLabel() -> String {
        switch CBManager.authorization {
        case .allowedAlways: return "Bluetooth allowed"
        case .notDetermined: return "Bluetooth not allowed yet"
        case .restricted: return "Bluetooth restricted"
        case .denied: return "Bluetooth permission needed"
        @unknown default: return "Bluetooth permission needed"
        }
    }

    // MARK: Location

    public static func locationGranted(context: FieldwatchApp? = nil) -> Bool {
        (context ?? FieldwatchApp.shared).hasFineLocation()
    }

    public static func locationDenied(context: FieldwatchApp? = nil) -> Bool {
        (context ?? FieldwatchApp.shared).location.currentAccess() == .denied
    }

    public static func locationAccess(context: FieldwatchApp? = nil) -> LocationSource.Access {
        (context ?? FieldwatchApp.shared).location.currentAccess()
    }

    // MARK: Asking

    /// Android `permissionLauncher.launch(required())`. Shows the macOS prompts that were never answered.
    /// Denied ones cannot be re-asked; send the operator to System Settings instead.
    public static func request(context: FieldwatchApp? = nil) {
        let app = context ?? FieldwatchApp.shared
        if bluetoothNotDetermined() { promptBluetooth() }
        app.location.requestAuthorization()
    }

    private static let promptLock = NSLock()
    nonisolated(unsafe) private static var promptCentral: CBCentralManager?

    /// Creating a central manager is what triggers the Bluetooth TCC prompt.
    private static func promptBluetooth() {
        promptLock.lock(); defer { promptLock.unlock() }
        if promptCentral != nil { return }
        promptCentral = CBCentralManager(
            delegate: nil,
            queue: DispatchQueue(label: "app.fieldwatch.ble.prompt"),
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    // MARK: System Settings

    @discardableResult
    public static func openBluetoothSettings() -> Bool { open(bluetoothSettingsUrl) }

    @discardableResult
    public static func openLocationSettings() -> Bool { open(locationSettingsUrl) }

    @discardableResult
    public static func openNotificationSettings() -> Bool { open(notificationSettingsUrl) }

    @discardableResult
    private static func open(_ raw: String) -> Bool {
        guard let url = URL(string: raw) else { return false }
        return NSWorkspace.shared.open(url)
    }
}
