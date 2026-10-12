import Foundation

// Port of domain/SettingsExchange.kt. Settings packs (fieldwatch-settings JSON) are shared with Android.

public struct SettingsPack: Codable, Hashable, Sendable {
    public var format: String
    public var formatVersion: Int
    public var exportedAt: String
    public var appVersion: String
    public var settings: AppSettings
    public var filter: FilterState
    public var presets: [FilterPreset]
    public var watchlist: [WatchTarget]
    public var hiddenPresetIds: Set<String>

    public static let FORMAT = "fieldwatch-settings"
    public static let FORMAT_VERSION = 1

    public init(
        format: String,
        formatVersion: Int = SettingsPack.FORMAT_VERSION,
        exportedAt: String = "",
        appVersion: String = "",
        settings: AppSettings = AppSettings(),
        filter: FilterState = FilterState(),
        presets: [FilterPreset] = [],
        watchlist: [WatchTarget] = [],
        hiddenPresetIds: Set<String> = []
    ) {
        self.format = format; self.formatVersion = formatVersion; self.exportedAt = exportedAt
        self.appVersion = appVersion; self.settings = settings; self.filter = filter; self.presets = presets
        self.watchlist = watchlist; self.hiddenPresetIds = hiddenPresetIds
    }

    enum CodingKeys: String, CodingKey {
        case format, formatVersion, exportedAt, appVersion, settings, filter, presets, watchlist, hiddenPresetIds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `format` has no default in Kotlin: missing key fails the parse.
        format = try c.decode(String.self, forKey: .format)
        formatVersion = try c.decode(.formatVersion, default: SettingsPack.FORMAT_VERSION)
        exportedAt = try c.decode(.exportedAt, default: "")
        appVersion = try c.decode(.appVersion, default: "")
        settings = try c.decode(.settings, default: AppSettings())
        filter = try c.decode(.filter, default: FilterState())
        presets = try c.decode(.presets, default: [])
        watchlist = try c.decode(.watchlist, default: [])
        hiddenPresetIds = try c.decode(.hiddenPresetIds, default: [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(exportedAt, forKey: .exportedAt)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(settings, forKey: .settings)
        try c.encode(filter, forKey: .filter)
        try c.encode(presets, forKey: .presets)
        try c.encode(watchlist, forKey: .watchlist)
        try c.encode(hiddenPresetIds.sorted(), forKey: .hiddenPresetIds)
    }
}

public struct SettingsImportResult: Hashable, Sendable {
    public var namedRadios: Int
    public var signatureWatches: Int
    public var presets: Int
    public var error: String?

    public init(namedRadios: Int = 0, signatureWatches: Int = 0, presets: Int = 0, error: String? = nil) {
        self.namedRadios = namedRadios; self.signatureWatches = signatureWatches; self.presets = presets; self.error = error
    }

    public func summary() -> String {
        if let error { return error }
        let presetWord = presets == 1 ? "preset" : "presets"
        let radioWord = namedRadios == 1 ? "named radio" : "named radios"
        let watchWord = signatureWatches == 1 ? "signature watch" : "signature watches"
        return "Restored Settings, the current filter, and \(presets) \(presetWord). " +
            "\(namedRadios) \(radioWord), \(signatureWatches) \(watchWord)."
    }
}

public enum SettingsExchange {
    /// Kotlin `json` (prettyPrint, encodeDefaults): encoder half.
    public static var jsonEncoder: JSONEncoder {
        let e = JSONEncoder()
        // .sortedKeys: JSONEncoder writes object keys (and dictionary keys like `enum`) in per-launch hash
        // order otherwise. Kotlin wrote a fixed order; sorted keeps the file the same every run.
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        return e
    }

    /// Kotlin `json` (ignoreUnknownKeys): decoder half.
    public static var jsonDecoder: JSONDecoder { JSONDecoder() }

    public static func pack(
        settings: AppSettings,
        filter: FilterState,
        presets: [FilterPreset],
        watchlist: [WatchTarget],
        hiddenPresetIds: Set<String>,
        appVersion: String,
        exportedAt: String
    ) -> SettingsPack {
        SettingsPack(
            format: SettingsPack.FORMAT,
            formatVersion: SettingsPack.FORMAT_VERSION,
            exportedAt: exportedAt,
            appVersion: appVersion,
            settings: settings,
            filter: filter,
            presets: presets,
            watchlist: watchlist,
            hiddenPresetIds: hiddenPresetIds
        )
    }

    public static func encode(pack: SettingsPack) -> String {
        guard let data = try? jsonEncoder.encode(pack) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func parse(text: String) throws -> SettingsPack {
        let trimmed = exchangeTrimmed(text)
        if trimmed.isEmpty {
            throw ExchangeError("This file is empty.")
        }
        let pack: SettingsPack
        do {
            pack = try jsonDecoder.decode(SettingsPack.self, from: Data(trimmed.utf8))
        } catch {
            throw ExchangeError("Not a Fieldwatch settings pack. Export from Settings → Export settings.")
        }
        if pack.format == SignaturePack.FORMAT || pack.format == SignaturePack.LEGACY_FORMAT {
            throw ExchangeError("That is a signature pack. Use Import signatures.")
        }
        if pack.format != SettingsPack.FORMAT {
            throw ExchangeError("Not a Fieldwatch settings pack (open a fieldwatch-settings JSON file).")
        }
        return pack
    }

    /// Replace Settings, the current filter, presets, and watchlist.
    /// Keep the catalog, logs, GPS, already-seen keys, the local disclaimer click-through,
    /// and whether this Mac already showed the Live tour.
    public static func apply(local: PersistedConfig, pack: SettingsPack) -> (PersistedConfig, SettingsImportResult) {
        var settings = pack.settings
        settings.disclaimerAccepted = local.settings.disclaimerAccepted
        settings.disclaimerRev = local.settings.disclaimerRev
        settings.liveTourDone = local.settings.liveTourDone
        settings.darkTheme = true
        settings.scanControlsExpanded = false
        var next = local
        next.settings = settings
        next.filter = pack.filter
        next.presets = pack.presets
        next.watchlist = pack.watchlist
        next.hiddenPresetIds = pack.hiddenPresetIds
        let result = SettingsImportResult(
            namedRadios: pack.watchlist.count { !$0.deviceKey.isNullOrBlank },
            signatureWatches: pack.watchlist.count { !$0.fleetId.isNullOrBlank },
            presets: pack.presets.count
        )
        return (next, result)
    }

    /// Nil when this import would not turn the TAK / CoT feed on and would not
    /// change its destination. The feed is plain UDP.
    public static func takImportWarning(local: AppSettings, incoming: AppSettings) -> String? {
        let turnsOn = incoming.takEnabled && !local.takEnabled
        let host = incoming.takHost.trim().ifBlank("(blank)")
        let localHost = local.takHost.trim()
        let destChanges = !incoming.takHost.trim().equals(localHost, ignoreCase: true) ||
            incoming.takPort != local.takPort
        if !turnsOn && !destChanges { return nil }
        let dest = "\(host):\(incoming.takPort)"
        if turnsOn && destChanges {
            return "This file turns the TAK / CoT feed on and sets the destination to \(dest). The feed is plain UDP."
        } else if turnsOn {
            return "This file turns the TAK / CoT feed on. It sends plain UDP to \(dest)."
        } else if incoming.takEnabled {
            return "This file changes the TAK / CoT destination to \(dest). The feed is plain UDP and stays on."
        } else {
            return "This file changes the TAK / CoT destination to \(dest). The feed stays off until you turn it on."
        }
    }
}
