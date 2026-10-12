import Foundation

// Port of domain/DefaultCatalog.kt.
//
// The Kotlin file holds ~4,700 lines of fleet literals (plus ApVendorOuis.kt / CatalogDecodes.kt).
// The Android build exports them to Resources/fieldwatch-signatures-v2.json (catalog version 94),
// which this file decodes once. The JSON is already in Kotlin's `sortedBy { name.lowercase() }` order.

public enum DefaultCatalog {
    /// Tesla phone-as-key uses Apple iBeacon layout (0x004C type 0x02 length 0x15)
    /// so iOS can find the car in the background. That is the Tesla row, not iBeacon.
    public static let TESLA_IBEACON_MFG_PREFIX = "021574278BDAB64445208F0C720EAF059935"

    /// Atrius cart tags advertise Apple iBeacon layout (0x004C type 0x02
    /// length 0x15) with this UUID, plus service 0xB1BB. Not Acuity company 0x0346
    /// on the hundreds of cart radios (Florida stores, 2026-09-02; a Walmart, 2026-10-04).
    /// The advertisement does not name the store.
    public static let TARGET_ATRIUS_IBEACON_MFG_PREFIX = "02155993A94C7D974DF79ABFE493BFD5D000"

    /// DJI company 0x08AA manufacturer-data model id (u16 LE). Osmo cameras sit
    /// in 0x0006–0x0022. Aircraft (Mavic 3 0x0070, Neo 2 0x007e, …) do not.
    /// Power 2000 advertised 0x1194 (4500) once (Power2000-1006HZ, 2026-10-04).
    /// That id is a decode label only. The DJI Power row matches the name.
    /// Do not put bare mfg(0x08AA) on the Osmo or DJI Power row — that is every DJI radio.
    public static let OSMO_CAMERA_MFG_PREFIXES: [String] = [
        "0600", // Osmo Action 1
        "1000", // Osmo Action 2
        "1200", // Osmo Action 3
        "1400", // Osmo Action 4
        "1500", // Osmo Action 5 Pro / Xtra Edge Pro
        "1700", // Osmo 360
        "1800", // Osmo Action 6
        "1900", // Osmo Nano
        "2000", // Osmo Pocket 3
        "2100", // Osmo Pocket 4
        "2200", // Osmo Pocket 4 Pro
    ]

    /// Bookmark these on first launch / Restore so they beep (and speak, with Voice on).
    /// Extra attention rows: body-cam / public-safety APs, camera glasses,
    /// recording wearables, pentest kit, and roadside / public camera + ALPR.
    /// Plus every built-in Drone-class row. Not Tesla, not headphones, not
    /// UniFi Protect, not BlueTOAD Spectra, not BlipTrack, not access-control locks.
    public static func defaultWatchlist() -> [WatchTarget] {
        fleets()
            .filter { $0.builtIn && ($0.attentionNote.isNotBlank || $0.kind == .drone) }
            .sortedBy { $0.name.lowercased() }
            .map { fleet in
                WatchTarget(id: "watch-\(fleet.id)", fleetId: fleet.id, label: fleet.name)
            }
    }

    /// The stock catalog. Decoded once; every call returns the same array (so
    /// `SignatureEngine`'s compiled cache hits without a deep compare).
    public static func fleets() -> [Fleet] { stock }

    public static func newBlankFleet() -> Fleet {
        Fleet(
            id: UUID().uuidString.lowercased(),
            name: "New Signature",
            enabled: true,
            matchAny: true,
            colorIndex: 0,
            rules: [],
            kind: .other
        )
    }

    private struct StockPack: Decodable {
        let fleets: [Fleet]
    }

    private static let stock: [Fleet] = {
        guard let url = Bundle.module.url(forResource: "fieldwatch-signatures-v2", withExtension: "json") else {
            fatalError("Fieldwatch: fieldwatch-signatures-v2.json missing from the FieldwatchCore bundle")
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(StockPack.self, from: data).fleets
        } catch {
            fatalError("Fieldwatch: stock catalog failed to decode: \(error)")
        }
    }()
}
