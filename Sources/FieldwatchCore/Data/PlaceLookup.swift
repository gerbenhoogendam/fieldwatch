import CoreLocation
import Foundation
import Network

/// Optional Debrief enrichment: system reverse-geocoder only (no API key, no
/// cloud account). Never throws to the caller; offline or missing geocoder
/// becomes a note in the report.
///
/// Port of data/PlaceLookup.kt. Android `Geocoder` → CoreLocation `CLGeocoder`; Android `Context` is dropped;
/// `suspend` → blocking. Each reverse lookup waits at most 8 s like Kotlin's `withTimeoutOrNull(8_000)`.
/// `CLGeocoder` delivers on the main queue, so when called on the main thread the wait spins the main run loop
/// instead of blocking it. Prefer calling from a background queue.
public enum PlaceLookup {
    public struct Fix: Hashable, Sendable {
        public var label: String
        public var lat: Double
        public var lon: Double

        public init(label: String, lat: Double, lon: Double) { self.label = label; self.lat = lat; self.lon = lon }
    }

    /// Kotlin `online(context)`: an active network with internet capability.
    public static func online() -> Bool {
        let monitor = NWPathMonitor()
        let sem = DispatchSemaphore(value: 0)
        let box = Box<Bool>(false)
        monitor.pathUpdateHandler = { path in
            if !box.done {
                box.value = path.status == .satisfied
                box.done = true
                sem.signal()
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.fieldwatch.online"))
        _ = sem.wait(timeout: .now() + 1.5)
        monitor.cancel()
        return box.value
    }

    public static func lookup(
        path: [GpsSample],
        devices: [Sighting],
        now: Int = nowMs(),
        onProgress: ((String) -> Void)? = nil
    ) -> DebriefPlaces {
        lookupInner(path: path, devices: devices, now: now, onProgress: onProgress)
    }

    private static func lookupInner(
        path: [GpsSample],
        devices: [Sighting],
        now: Int,
        onProgress: ((String) -> Void)?
    ) -> DebriefPlaces {
        if !online() {
            return DebriefPlaces(
                attempted: true,
                available: false,
                note: "Online lookup skipped: no working internet. Coordinates only."
            )
        }
        // Android checks Geocoder.isPresent(); CLGeocoder is always present on macOS.
        let fixes = collect(path: path, devices: devices, now: now)
        if fixes.isEmpty {
            return DebriefPlaces(
                attempted: true,
                available: true,
                note: "Online lookup on, but this sit had no GPS stamps to name."
            )
        }
        let geocoder = CLGeocoder()
        // LinkedHashMap: keep insertion order.
        var cacheOrder: [String] = []
        var cache: [String: String] = [:]
        var lines: [String] = []
        lines.reserveCapacity(fixes.count)
        for (i, fix) in fixes.enumerated() {
            onProgress?("Looking up place names (\(i + 1) of \(fixes.count))…")
            let key = Geo.cellKey(lat: fix.lat, lon: fix.lon)
            var name = cache[key]
            if name == nil, let found = reverse(geocoder: geocoder, lat: fix.lat, lon: fix.lon) {
                cache[key] = found
                cacheOrder.append(key)
                name = found
            }
            let coord = "\(fmt(fix.lat, 5)), \(fmt(fix.lon, 5))"
            if name.isNullOrBlank {
                lines.append("  · \(fix.label)  \(coord)  (no name returned)")
            } else {
                lines.append("  · \(fix.label)  \(name!)  (\(coord))")
            }
        }
        let named = cacheOrder.count
        return DebriefPlaces(
            attempted: true,
            available: named > 0,
            note: named > 0
                ? "Online lookup: system geocoder named \(named) distinct GPS cell(s). Street names are from the Mac’s network geocoder, not a Fieldwatch cloud. Approximate."
                : "Online lookup ran, but the system geocoder returned no street names. Coordinates only.",
            lines: lines,
            namesByCell: cache,
            cellOrder: cacheOrder
        )
    }

    public static func collect(path: [GpsSample], devices: [Sighting], now: Int = nowMs()) -> [Fix] {
        var out: [Fix] = []
        var seen = Set<String>()
        func add(_ label: String, _ lat: Double, _ lon: Double) {
            if lat == 0.0 && lon == 0.0 { return }
            let key = Geo.cellKey(lat: lat, lon: lon)
            if !seen.insert(key).inserted { return }
            out.append(Fix(label: label, lat: lat, lon: lon))
        }
        let legs = Geo.legs(samples: path, now: now)
        var stayN = 0
        for leg in legs {
            if leg.stay {
                stayN += 1
                add("Stay \(stayN)", leg.lat, leg.lon)
            } else {
                add("Transit from", leg.lat, leg.lon)
                add("Transit to", leg.endLat, leg.endLon)
            }
        }
        if out.isEmpty && path.isNotEmpty {
            add("Path start", path.first!.lat, path.first!.lon)
            if path.count > 1 { add("Path end", path.last!.lat, path.last!.lon) }
        }
        if out.count < 8 {
            devices.filter { $0.gpsTrail.isNotEmpty && $0.rssi >= -70 }
                .sortedByDescending { $0.rssi }
                .take(4)
                .forEach { d in
                    let p = d.gpsTrail.last!
                    add(d.listTitle().take(28), p.lat, p.lon)
                }
        }
        return out.take(8)
    }

    /// Blocking reverse geocode with an 8 s cap. Nil on error, timeout, or no usable placemark.
    public static func reverse(geocoder: CLGeocoder, lat: Double, lon: Double, timeoutSec: Double = 8.0) -> String? {
        let box = Box<String?>(nil)
        let location = CLLocation(latitude: lat, longitude: lon)
        geocoder.reverseGeocodeLocation(location, preferredLocale: Locale.current) { placemarks, _ in
            box.value = format(placemarks?.first)
            box.done = true
            box.sem.signal()
        }
        let deadline = Date().addingTimeInterval(timeoutSec)
        if Thread.isMainThread {
            // Completion runs on the main queue; keep it serviced while we wait.
            while !box.done && Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05)))
            }
        } else {
            _ = box.sem.wait(timeout: .now() + timeoutSec)
        }
        if !box.done {
            geocoder.cancelGeocode()
            return nil
        }
        return box.value?.nonBlank
    }

    /// Android `getAddressLine(0)` has no CLPlacemark twin; this is Kotlin's fallback join.
    private static func format(_ addr: CLPlacemark?) -> String? {
        guard let addr else { return nil }
        let street = [addr.subThoroughfare, addr.thoroughfare].compactMap { $0 }.joined(separator: " ").nonBlank
        let parts = [street, addr.locality, addr.administrativeArea, addr.postalCode].compactMap { $0 }
        if parts.isEmpty, let name = addr.name?.trim(), name.isNotEmpty { return name }
        return parts.joined(separator: ", ").nonBlank
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        var done = false
        let sem = DispatchSemaphore(value: 0)
        init(_ v: T) { value = v }
    }
}
