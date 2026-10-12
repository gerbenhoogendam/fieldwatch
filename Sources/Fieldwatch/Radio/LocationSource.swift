import CoreLocation
import FieldwatchCore
import Foundation

/// CoreLocation stand-in for the Android GPS + network `LocationListener`s in FieldwatchApp.kt.
/// Mac fixes are Wi-Fi based (no GNSS receiver); the accuracy / age gates live in `FieldwatchApp.acceptFix`.
///
/// CLLocationManager is created and driven on the main thread (it needs a run loop). Fixes and authorization
/// changes are forwarded to `onFix` / `onAuthorizationChange` on the main thread.
public final class LocationSource: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    /// What the UI needs to say about Location. Mirrors the Android "Location off / permission" states.
    public enum Access: String, CaseIterable, Sendable {
        /// System Location Services are switched off for the whole Mac.
        case servicesOff = "SERVICES_OFF"
        /// Never asked yet.
        case notDetermined = "NOT_DETERMINED"
        /// The operator said no (or MDM restricts it).
        case denied = "DENIED"
        case authorized = "AUTHORIZED"

        public func label() -> String {
            switch self {
            case .servicesOff: return "Location off"
            case .notDetermined: return "Location not allowed yet"
            case .denied: return "Location denied"
            case .authorized: return "Location on"
            }
        }
    }

    /// Current access, kept fresh from the delegate. Observe it for the Diagnostics / permission rows.
    public let access = MutableStateFlow<Access>(.notDetermined)

    public var onFix: ((CLLocation) -> Void)?
    public var onAuthorizationChange: ((Access) -> Void)?

    private var manager: CLLocationManager!
    private let lock = NSLock()
    private var wanted = false
    private var updating = false
    private var servicesOn = true
    private var status: CLAuthorizationStatus = .notDetermined
    private var lastLocation: CLLocation?

    public override init() {
        super.init()
        onMain {
            let m = CLLocationManager()
            m.desiredAccuracy = kCLLocationAccuracyBest
            m.distanceFilter = 8
            m.activityType = .other
            m.delegate = self
            self.manager = m
            self.lock.lock()
            self.status = m.authorizationStatus
            self.lastLocation = m.location
            self.lock.unlock()
        }
        refreshServicesEnabled()
    }

    // MARK: State

    public func authorizationStatus() -> CLAuthorizationStatus {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    /// Location permission for this app (Android ACCESS_FINE_LOCATION).
    public func isAuthorized() -> Bool {
        LocationSource.granted(authorizationStatus())
    }

    /// System-wide Location Services switch (Android `LocationManager.isLocationEnabled`). Cached: the
    /// CoreLocation call blocks and must not run on the main thread.
    public func servicesEnabled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return servicesOn
    }

    public func currentAccess() -> Access {
        if !servicesEnabled() { return .servicesOff }
        switch authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        default: return LocationSource.granted(authorizationStatus()) ? .authorized : .denied
        }
    }

    /// Short status for the header / Diagnostics. Empty when Location is fine.
    public func statusText() -> String {
        let a = currentAccess()
        return a == .authorized ? "" : a.label()
    }

    /// The newest fix CoreLocation handed us (Android `getLastKnownLocation`).
    public func lastKnown() -> CLLocation? {
        lock.lock(); defer { lock.unlock() }
        return lastLocation
    }

    public func isUpdating() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return updating
    }

    // MARK: Control

    /// Show the macOS Location prompt if it was never answered.
    public func requestAuthorization() {
        onMain {
            guard let m = self.manager else { return }
            if m.authorizationStatus == .notDetermined { m.requestWhenInUseAuthorization() }
        }
    }

    public func start() {
        lock.lock(); wanted = true; lock.unlock()
        onMain {
            guard let m = self.manager else { return }
            let s = m.authorizationStatus
            if s == .notDetermined {
                m.requestWhenInUseAuthorization()
                return
            }
            guard LocationSource.granted(s) else { return }
            m.startUpdatingLocation()
            self.lock.lock(); self.updating = true; self.lock.unlock()
        }
    }

    public func stop() {
        lock.lock(); wanted = false; lock.unlock()
        onMain {
            self.manager?.stopUpdatingLocation()
            self.lock.lock(); self.updating = false; self.lock.unlock()
        }
    }

    /// Ask CoreLocation for a one-shot fix (Android refresh of last-known). Cheap if updates already run.
    public func requestOneShot() {
        onMain {
            guard let m = self.manager, self.isAuthorized() else { return }
            m.requestLocation()
        }
    }

    // MARK: CLLocationManagerDelegate

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        lock.lock()
        status = manager.authorizationStatus
        let resume = wanted && LocationSource.granted(status)
        let halt = status == .denied || status == .restricted
        if halt { updating = false }
        lock.unlock()
        if resume {
            manager.startUpdatingLocation()
            lock.lock(); updating = true; lock.unlock()
        }
        refreshServicesEnabled()
        publishAccess()
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        lock.lock(); lastLocation = loc; lock.unlock()
        onFix?(loc)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient; denied arrives through the authorization callback.
        if let e = error as? CLError, e.code == .denied {
            lock.lock(); updating = false; lock.unlock()
            refreshServicesEnabled()
            publishAccess()
        }
    }

    // MARK: Helpers

    /// authorizedAlways (3) or authorizedWhenInUse (4). macOS normally reports Always for a granted app.
    public static func granted(_ s: CLAuthorizationStatus) -> Bool { s.rawValue == 3 || s.rawValue == 4 }

    private func refreshServicesEnabled() {
        DispatchQueue.global(qos: .utility).async {
            let on = CLLocationManager.locationServicesEnabled()
            self.lock.lock()
            let changed = self.servicesOn != on
            self.servicesOn = on
            self.lock.unlock()
            if changed { DispatchQueue.main.async { self.publishAccess() } }
        }
    }

    private func publishAccess() {
        let a = currentAccess()
        if access.value != a { access.value = a }
        onAuthorizationChange?(a)
    }

    private func onMain(_ f: @escaping () -> Void) {
        if Thread.isMainThread { f() } else { DispatchQueue.main.async(execute: f) }
    }
}
