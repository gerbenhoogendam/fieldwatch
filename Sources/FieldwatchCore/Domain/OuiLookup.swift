import Foundation

// Port of domain/OuiLookup.kt.

public enum OuiLookup {
    public static func vendor(mac: String) -> String? { RadioDb.vendorForMac(mac: mac) }
}
