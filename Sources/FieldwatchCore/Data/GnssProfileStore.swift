import Foundation

// Port of data/GnssProfileStore.kt. File: `FieldwatchPaths.root/gnss-phone.json` (Android name kept so
// files copied between devices line up). A Mac has no GNSS receiver, so nothing writes this in practice;
// the store is kept so the type and settings plumbing compile.

/// This Mac's GNSS calibration. Not part of the settings pack.
public final class GnssProfileStore: @unchecked Sendable {
    private let file: URL
    private let _profile: MutableStateFlow<GnssPhoneProfile?>
    public var profile: StateFlow<GnssPhoneProfile?> { _profile }

    public init() {
        file = FieldwatchPaths.file("gnss-phone.json")
        _profile = MutableStateFlow(GnssProfileStore.read(file))
    }

    public func save(profile: GnssPhoneProfile) {
        let enc = JSONEncoder()
        // .sortedKeys: JSONEncoder writes object keys (and dictionary keys like `enum`) in per-launch hash
        // order otherwise. Kotlin wrote a fixed order; sorted keeps the file the same every run.
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        if let data = try? enc.encode(profile) {
            try? data.write(to: file, options: .atomic)
        }
        _profile.value = profile
    }

    private static func read(_ file: URL) -> GnssPhoneProfile? {
        guard FileManager.default.fileExists(atPath: file.path), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(GnssPhoneProfile.self, from: data)
    }
}
