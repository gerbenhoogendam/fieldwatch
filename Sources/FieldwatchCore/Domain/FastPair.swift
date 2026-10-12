import Foundation

// Port of domain/FastPair.kt.

/// Google Fast Pair (UUID FE2C) has two Live-relevant shapes:
/// 3-byte model ID = pairing mode; longer = account-key plaza noise.
public enum FastPair {
    public static let FLEET_ID = "fleet-fast-pair"

    public static func pairingAdvertised(facts: RadioFacts) -> Bool {
        facts.serviceData.contains { rec in
            isFastPairUuid(uuid: rec.uuid) && hexLen(rec.dataHex) == 6
        }
    }

    /// Account-key Fast Pair with no other signature — plaza chips. Pairing-mode stays.
    public static func isAccountKeyOnly(device: Sighting) -> Bool {
        if device.fastPairPairing { return false }
        if !device.fleetIds.contains(FLEET_ID) { return false }
        return device.fleetIds.count == 1
    }

    public static func liveLabel(pairing: Bool) -> String {
        pairing ? "Fast Pair pairing" : "Fast Pair"
    }

    public static func isFastPairUuid(uuid: String) -> Bool {
        let hex = uuid.filterAlnum().uppercased()
        return hex == "FE2C" || (hex.count >= 8 && hex.substring(4, 8) == "FE2C")
    }

    private static func hexLen(_ raw: String) -> Int { raw.count { $0.isLetterOrDigit } }
}
