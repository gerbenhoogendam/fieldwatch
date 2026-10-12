import Foundation

// Port of data/ConfigStore.kt.
// Android `filesDir/config.json` → `FieldwatchPaths.root/config.json`. Suspend funcs are synchronous here.
// Writes are atomic (`Data.write(to:options:.atomic)`), standing in for Android's config.tmp + rename.
// Threading: one recursive lock serialises load / update / imports (Kotlin Mutex). `config` observers fire
// on the writer's thread while that lock is held — hop to your own queue (async) before doing UI work.

public final class ConfigStore: @unchecked Sendable {
    private let file: URL
    private let mutex = NSRecursiveLock()
    private let _config: MutableStateFlow<PersistedConfig>
    public var config: StateFlow<PersistedConfig> { _config }

    public var fleets: [Fleet] { _config.value.fleets }
    public var filter: FilterState { _config.value.filter }
    public var settings: AppSettings { _config.value.settings }
    public var presets: [FilterPreset] { _config.value.presets }
    public var watchlist: [WatchTarget] { _config.value.watchlist }

    public init() {
        file = FieldwatchPaths.file("config.json")
        _config = MutableStateFlow(ConfigStore.seed())
    }

    public func load() {
        mutex.lock(); defer { mutex.unlock() }
        if !FileManager.default.fileExists(atPath: file.path) {
            let seeded = ConfigStore.seed()
            write(seeded)
            _config.value = seeded
            return
        }
        if let data = try? Data(contentsOf: file),
           let loaded = try? JSONDecoder().decode(PersistedConfig.self, from: data) {
            if loaded.fleets.isEmpty {
                let seeded = ConfigStore.seed()
                write(seeded)
                _config.value = seeded
            } else {
                let patched = ConfigStore.patchBuiltIn(cfg: loaded)
                _config.value = patched
                if patched != loaded {
                    write(patched)
                }
            }
        } else {
            let seeded = ConfigStore.seed()
            write(seeded)
            _config.value = seeded
        }
    }

    public func update(transform: (PersistedConfig) -> PersistedConfig) {
        mutex.lock(); defer { mutex.unlock() }
        let next = transform(_config.value)
        _config.value = next
        write(next)
    }

    public func restoreDefaults() {
        let accepted = _config.value.settings.disclaimerAccepted
        let rev = _config.value.settings.disclaimerRev
        update { _ in
            var fresh = ConfigStore.seed()
            fresh.settings.disclaimerAccepted = accepted
            fresh.settings.disclaimerRev = rev
            return fresh
        }
    }

    public func importFleets(incoming: [Fleet]) -> SignatureImportResult {
        mutex.lock(); defer { mutex.unlock() }
        let (merged, result) = SignatureExchange.merge(existing: _config.value.fleets, incoming: incoming)
        if result.error != nil || (result.added == 0 && result.merged == 0) {
            return result
        }
        var next = _config.value
        next.fleets = merged
        _config.value = next
        write(next)
        return result
    }

    public func importSettings(pack: SettingsPack) -> SettingsImportResult {
        var result = SettingsImportResult()
        update { local in
            let (next, applied) = SettingsExchange.apply(local: local, pack: pack)
            result = applied
            return applied.error != nil ? local : next
        }
        return result
    }

    public func overlayStockCatalog(pack: SignaturePack) -> StockCatalogUpdateResult {
        mutex.lock(); defer { mutex.unlock() }
        if pack.catalogVersion <= 0 {
            return StockCatalogUpdateResult(error: "This pack has no catalog version.")
        }
        let local = _config.value
        if pack.catalogVersion <= local.version {
            return StockCatalogUpdateResult(alreadyLatest: true, catalogVersion: local.version)
        }
        let (fleets, overlay) = SignatureExchange.overlayStock(existing: local.fleets, incoming: pack.fleets)
        if let error = overlay.error {
            return StockCatalogUpdateResult(error: error)
        }
        var next = local
        next.fleets = fleets
        next.version = pack.catalogVersion
        _config.value = next
        write(next)
        var out = overlay
        out.catalogVersion = pack.catalogVersion
        return out
    }

    // MARK: - File IO

    private func write(_ cfg: PersistedConfig) {
        let enc = JSONEncoder()
        // .sortedKeys: JSONEncoder writes object keys (and dictionary keys like `enum`) in per-launch hash
        // order otherwise. Kotlin wrote a fixed order; sorted keeps the file the same every run.
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        guard let data = try? enc.encode(cfg) else { return }
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - Catalog migrations

    static func ruleKey(_ rule: MatchRule) -> String {
        [rule.kind.rawValue, rule.text.uppercased(), String(rule.companyId), rule.dataPrefixHex.uppercased(), rule.radio?.rawValue ?? ""]
            .joined(separator: "|")
    }

    /// Kotlin `patchBuiltIn`. Applies every catalog migration from the saved version up to CATALOG_VERSION.
    static func patchBuiltIn(cfg: PersistedConfig) -> PersistedConfig {
        let catalog = DefaultCatalog.fleets().associateBy { $0.id }
        let engine = FilterEngine()
        var stockWatchCache: [WatchTarget]?
        func defaultWatchlist() -> [WatchTarget] {
            if let c = stockWatchCache { return c }
            let w = DefaultCatalog.defaultWatchlist()
            stockWatchCache = w
            return w
        }

        let patchedRows = cfg.fleets.map { fleet -> Fleet in
            guard let stock = catalog[fleet.id] else { return fleet }
            if !fleet.builtIn { return fleet }
            let have = Set(fleet.rules.map { ruleKey($0) })
            let missing = stock.rules.filter { !have.contains(ruleKey($0)) }
            let renamed: String
            if fleet.id == "fleet-unknown" && fleet.name == "Unknown Fleet" {
                renamed = stock.name
            } else if fleet.id == "fleet-seos" && fleet.name == "Seos" {
                renamed = stock.name
            } else if fleet.id == "fleet-target-atrius" && fleet.name == "Target Atrius basket" {
                renamed = stock.name
            } else {
                renamed = fleet.name
            }
            let notes: String
            if fleet.id == "fleet-target-atrius" &&
                fleet.notes == "Target shopping-basket tag. Dual-labels with generic iBeacon; this row is the store basket." {
                notes = stock.notes
            } else {
                notes = fleet.notes
            }
            if missing.isEmpty && renamed == fleet.name && notes == fleet.notes { return fleet }
            var f = fleet
            f.name = renamed
            f.notes = notes
            f.rules = fleet.rules + missing
            return f
        }
        var presets = cfg.presets.map { preset -> FilterPreset in
            if preset.id == "named" && preset.name == "Named only" {
                var p = preset
                p.name = "Signatures only"
                return p
            }
            return preset
        }
        var fleets = patchedRows
        var version = cfg.version
        var filter = cfg.filter
        let hiddenPresetIds = cfg.hiddenPresetIds
        var watchlist = cfg.watchlist
        var settings = cfg.settings

        // Shared migration steps.
        func byName(_ list: [Fleet]) -> [Fleet] { list.sortedBy { $0.name.lowercased() } }
        func missingStock(_ ids: [String]) -> [Fleet] {
            let have = Set(fleets.map { $0.id })
            return ids.compactMap { catalog[$0] }.filter { !have.contains($0.id) }
        }
        /// Append stock rows not yet present, unsorted.
        func addAppend(_ ids: [String]) {
            let extras = missingStock(ids)
            if extras.isNotEmpty { fleets = fleets + extras }
        }
        /// Append stock rows and always re-sort by name.
        func addSorted(_ ids: [String]) {
            fleets = byName(fleets + missingStock(ids))
        }
        /// Append stock rows; re-sort only when something was added.
        func addSortedIfAny(_ ids: [String]) {
            let extras = missingStock(ids)
            if extras.isNotEmpty { fleets = byName(fleets + extras) }
        }
        func refreshPresets() {
            let stockPresets = engine.defaultPresets(fleets: fleets)
            let custom = presets.filter { !$0.isBuiltIn() }
            presets = stockPresets + custom
        }
        func addDefaultWatches() {
            let watched = Set(watchlist.compactMap { $0.fleetId })
            let watchExtras = defaultWatchlist().filter { w in w.fleetId.map { !watched.contains($0) } ?? true }
            if watchExtras.isNotEmpty { watchlist = watchlist + watchExtras }
        }
        func copyStockKind() {
            fleets = fleets.map { fleet -> Fleet in
                guard let stock = catalog[fleet.id] else { return fleet }
                if !fleet.builtIn { return fleet }
                var f = fleet
                f.kind = stock.kind
                return f
            }
        }
        func extraStockRules(_ fleet: Fleet, _ stock: Fleet) -> [MatchRule] {
            let keys = Set(fleet.rules.map { ruleKey($0) })
            return stock.rules.filter { !keys.contains(ruleKey($0)) }
        }
        /// Built-in rows in `ids`: decode + notes from stock.
        func refreshDecodeNotes(_ ids: Set<String>) {
            fleets = fleets.map { fleet -> Fleet in
                if !ids.contains(fleet.id) || !fleet.builtIn { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                var f = fleet
                f.decode = stock.decode
                f.notes = stock.notes
                return f
            }
        }

        if version < 2 {
            addAppend(ADDED_IN_V2)
            version = 2
        }
        if version < 3 {
            addAppend(ADDED_IN_V3)
            version = 3
        }
        if version < 4 {
            let s = cfg.settings
            fleets = fleets.map { fleet -> Fleet in
                if !POLICY_FLEET_IDS.contains(fleet.id) { return fleet }
                var f = fleet
                f.rules = fleet.rules.map { rule -> MatchRule in
                    let on: Bool
                    switch rule.kind {
                    case .nameContains, .nameGlob: on = s.detectSsidKeywords
                    case .oui, .macPrefix: on = s.detectKnownOuis
                    case .vendorIeOui: on = s.detectVendorIes
                    case .serviceUuid, .serviceData, .manufacturerId, .manufacturerData:
                        on = fleet.id == "fleet-raven" ? s.detectBleRaven : true
                    default: on = true
                    }
                    if rule.enabled == on { return rule }
                    var r = rule
                    r.enabled = on
                    return r
                }
                return f
            }
            version = 4
        }
        if version < 5 {
            if cfg.settings.arrivalsOnly && !filter.arrivalsOnly {
                filter.arrivalsOnly = true
            }
            version = 5
        }
        if version < 6 {
            addAppend(ADDED_IN_V6)
            version = 6
        }
        if version < 7 {
            fleets = fleets.map { fleet -> Fleet in
                if fleet.id == "fleet-hobby-ble" && fleet.builtIn && !fleet.enabled {
                    var f = fleet
                    f.enabled = true
                    return f
                }
                return fleet
            }
            version = 7
        }
        if version < 8 {
            fleets = fleets.map { fleet -> Fleet in
                guard let stock = catalog[fleet.id] else { return fleet }
                if !fleet.builtIn { return fleet }
                let enable = fleet.id == "fleet-axon" ? true : fleet.enabled
                let note = (fleet.attentionNote.isBlank && stock.attentionNote.isNotBlank) ? stock.attentionNote : fleet.attentionNote
                if enable == fleet.enabled && note == fleet.attentionNote { return fleet }
                var f = fleet
                f.enabled = enable
                f.attentionNote = note
                return f
            }
            addAppend(ADDED_IN_V8)
            version = 8
        }
        if version < 9 {
            addAppend(ADDED_IN_V9)
            version = 9
        }
        if version < 10 {
            addAppend(ADDED_IN_V10)
            version = 10
        }
        if version < 11 {
            fleets = fleets.map { fleet -> Fleet in
                guard let stock = catalog[fleet.id] else { return fleet }
                if !fleet.builtIn { return fleet }
                if fleet.colorIndex == stock.colorIndex { return fleet }
                var f = fleet
                f.colorIndex = stock.colorIndex
                return f
            }
            version = 11
        }
        if version < 12 {
            fleets = fleets.map { fleet -> Fleet in
                let stock = catalog[fleet.id]
                if fleet.id == "fleet-unknown" && fleet.builtIn, let stock {
                    var f = fleet
                    f.enabled = false
                    f.minPeers = 0
                    f.clusterByOui = false
                    f.sequentialMac = false
                    f.notes = stock.notes
                    f.rules = stock.rules
                    return f
                }
                if fleet.id == "fleet-airtag" && fleet.builtIn {
                    var f = fleet
                    f.rules = fleet.rules.filter { rule in
                        !(rule.kind == .manufacturerData &&
                            rule.companyId == 0x004C &&
                            rule.dataPrefixHex.filterAlnum().equals("07", ignoreCase: true))
                    }
                    f.notes = stock?.notes ?? fleet.notes
                    return f
                }
                return fleet
            }
            addAppend(ADDED_IN_V12)
            version = 12
        }
        if version < 13 {
            fleets = byName(fleets)
            version = 13
        }
        if version < 14 {
            addSorted(ADDED_IN_V14)
            version = 14
        }
        if version < 15 {
            addSorted(ADDED_IN_V15)
            version = 15
        }
        if version < 16 {
            addSorted(ADDED_IN_V16)
            version = 16
        }
        if version < 17 {
            fleets = fleets.map { fleet -> Fleet in
                if fleet.builtIn && !fleet.enabled {
                    var f = fleet
                    f.enabled = true
                    return f
                }
                return fleet
            }
            version = 17
        }
        if version < 18 {
            addDefaultWatches()
            version = 18
        }
        if version < 19 {
            if !settings.tagLocation { settings.tagLocation = true }
            version = 19
        }
        if version < 20 {
            if !settings.keepScreenOn || !settings.onlineLookup {
                settings.keepScreenOn = true
                settings.onlineLookup = true
            }
            version = 20
        }
        if version < 21 {
            addSorted(ADDED_IN_V21)
            version = 21
        }
        if version < 22 {
            addSorted(ADDED_IN_V22)
            version = 22
        }
        if version < 23 {
            addSorted(ADDED_IN_V23)
            version = 23
        }
        if version < 24 {
            addSorted(ADDED_IN_V24)
            version = 24
        }
        if version < 25 {
            addSorted(ADDED_IN_V25)
            version = 25
        }
        if version < 26 {
            copyStockKind()
            refreshPresets()
            version = 26
        }
        if version < 27 {
            refreshPresets()
            if filter.classIncludeActive() && filter.namedOnly {
                filter.namedOnly = false
            }
            version = 27
        }
        if version < 28 {
            copyStockKind()
            addSorted(ADDED_IN_V28)
            refreshPresets()
            version = 28
        }
        if version < 29 {
            copyStockKind()
            refreshPresets()
            version = 29
        }
        if version < 30 {
            fleets = fleets.map { fleet -> Fleet in
                if fleet.enabled { return fleet }
                var f = fleet
                f.enabled = true
                return f
            }
            if filter.useFleetFilter && !filter.excludeSignatures && filter.fleetIds.isNotEmpty {
                filter.includeSignatures = true
                filter.includeFleetIds = filter.fleetIds
                filter.useFleetFilter = false
                filter.fleetIds = []
            }
            version = 30
        }
        if version < 31 {
            addSorted(ADDED_IN_V31)
            refreshPresets()
            addDefaultWatches()
            version = 31
        }
        if version < 32 {
            addSorted(ADDED_IN_V32)
            refreshPresets()
            version = 32
        }
        if version < 33 {
            addSorted(ADDED_IN_V33)
            refreshPresets()
            version = 33
        }
        if version < 34 {
            copyStockKind()
            refreshPresets()
            version = 34
        }
        if version < 35 {
            addSorted(ADDED_IN_V35)
            refreshPresets()
            version = 35
        }
        if version < 36 {
            addSorted(ADDED_IN_V36)
            refreshPresets()
            version = 36
        }
        if version < 37 {
            addSorted(ADDED_IN_V37)
            refreshPresets()
            version = 37
        }
        if version < 38 {
            addSorted(ADDED_IN_V38)
            fleets = fleets.map { fleet -> Fleet in
                guard let stock = catalog[fleet.id] else { return fleet }
                if !fleet.builtIn { return fleet }
                let note = (fleet.attentionNote.isBlank && stock.attentionNote.isNotBlank) ? stock.attentionNote : fleet.attentionNote
                if note == fleet.attentionNote { return fleet }
                var f = fleet
                f.attentionNote = note
                return f
            }
            refreshPresets()
            addDefaultWatches()
            version = 38
        }
        if version < 39 {
            addSorted(ADDED_IN_V39)
            version = 39
        }
        if version < 40 {
            addSorted(ADDED_IN_V40)
            let refresh: Set<String> = ["fleet-tesla", "fleet-mbux", "fleet-audi-mmi", "fleet-gm-hotspot"]
            fleets = fleets.map { fleet -> Fleet in
                if !refresh.contains(fleet.id) || !fleet.builtIn { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                var f = fleet
                f.rules = fleet.rules + extraStockRules(fleet, stock)
                f.notes = stock.notes
                return f
            }
            refreshPresets()
            version = 40
        }
        if version < 41 {
            fleets = fleets.map { fleet -> Fleet in
                if fleet.id != "fleet-tesla" && fleet.id != "fleet-ibeacon" { return fleet }
                if !fleet.builtIn { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                var f = fleet
                f.rules = fleet.rules + extraStockRules(fleet, stock)
                f.notes = stock.notes
                return f
            }
            version = 41
        }
        if version < 42 {
            fleets = fleets.map { fleet -> Fleet in
                guard let stock = catalog[fleet.id] else { return fleet }
                if !fleet.builtIn { return fleet }
                let color = fleet.id == "fleet-gopro" ? stock.colorIndex : fleet.colorIndex
                var f = fleet
                f.kind = stock.kind
                f.colorIndex = color
                return f
            }
            refreshPresets()
            version = 42
        }
        if version < 43 {
            addSorted(ADDED_IN_V43)
            fleets = fleets.map { fleet -> Fleet in
                if fleet.id != "fleet-dji" || !fleet.builtIn { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                var f = fleet
                f.notes = stock.notes
                return f
            }
            refreshPresets()
            version = 43
        }
        if version < 44 {
            refreshPresets()
            version = 44
        }
        if version < 45 {
            fleets = fleets.map { fleet -> Fleet in
                if !fleet.builtIn { return fleet }
                if fleet.id != "fleet-airtag" && fleet.id != "fleet-apple-device" { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                var f = fleet
                f.notes = stock.notes
                return f
            }
            version = 45
        }
        if version < 46 {
            fleets = fleets.map { fleet -> Fleet in
                if !fleet.builtIn { return fleet }
                if fleet.id != "fleet-unifi-ap" && fleet.id != "fleet-unifi" { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                var f = fleet
                f.kind = stock.kind
                f.colorIndex = stock.colorIndex
                f.notes = stock.notes
                return f
            }
            version = 46
        }
        if version < 47 {
            refreshPresets()
            version = 47
        }
        if version < 48 {
            let leIds: Set<String> = [
                "fleet-axon", "fleet-watchguard", "fleet-cradlepoint", "fleet-airlink",
                "fleet-compex", "fleet-novatel", "fleet-utility-inc",
            ]
            fleets = fleets.map { fleet -> Fleet in
                if !fleet.builtIn || !leIds.contains(fleet.id) { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                var f = fleet
                f.kind = stock.kind
                f.colorIndex = stock.colorIndex
                return f
            }
            if filter.classes.contains(.bodyworn) {
                filter.classes.insert(.lawEnforcement)
            }
            version = 48
        }
        if version < 49 {
            let campusApIds: Set<String> = [
                "fleet-meraki", "fleet-cisco", "fleet-aruba", "fleet-ruckus", "fleet-fortinet", "fleet-mist",
                "fleet-sophos", "fleet-extreme", "fleet-edgecore", "fleet-watchguard-ap", "fleet-mojo",
            ]
            fleets = fleets.map { fleet -> Fleet in
                if !fleet.builtIn || !campusApIds.contains(fleet.id) { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                var f = fleet
                f.kind = stock.kind
                f.colorIndex = stock.colorIndex
                f.notes = stock.notes
                return f
            }
            version = 49
        }
        if version < 50 {
            addSorted(ADDED_IN_V50)
            let mergeIds: Set<String> = [
                "fleet-glinet", "fleet-toyota", "fleet-volkswagen", "fleet-porsche", "fleet-motive", "fleet-hp", "fleet-att",
            ]
            fleets = fleets.map { fleet -> Fleet in
                if !fleet.builtIn || !mergeIds.contains(fleet.id) { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                var f = fleet
                f.rules = fleet.rules + extraStockRules(fleet, stock)
                f.notes = stock.notes
                return f
            }
            version = 50
        }
        if version < 51 {
            addSorted(ADDED_IN_V51)
            version = 51
        }
        if version < 52 {
            addSorted(ADDED_IN_V52)
            version = 52
        }
        if version < 53 {
            addSorted(ADDED_IN_V53)
            version = 53
        }
        if version < 54 {
            addSorted(ADDED_IN_V54)
            version = 54
        }
        if version < 55 {
            addSorted(ADDED_IN_V55)
            version = 55
        }
        if version < 56 {
            fleets = fleets.map { fleet -> Fleet in
                guard let stock = catalog[fleet.id] else { return fleet }
                if !fleet.builtIn { return fleet }
                if stock.decode != nil && fleet.decode == nil {
                    var f = fleet
                    f.decode = stock.decode
                    f.notes = stock.notes
                    return f
                }
                return fleet
            }
            version = 56
        }
        if version < 57 {
            fleets = fleets.map { fleet -> Fleet in
                guard let stock = catalog[fleet.id] else { return fleet }
                if !fleet.builtIn || stock.decode == nil { return fleet }
                var f = fleet
                f.decode = stock.decode
                f.notes = stock.notes
                return f
            }
            version = 57
        }
        if version < 58 {
            fleets = fleets.map { fleet -> Fleet in
                if fleet.kind != .bodyworn { return fleet }
                var f = fleet
                f.kind = .wearable
                return f
            }
            func foldBodyworn(_ state: FilterState) -> FilterState {
                if !state.classes.contains(.bodyworn) { return state }
                var s = state
                s.classes.remove(.bodyworn)
                s.classes.insert(.wearable)
                return s
            }
            filter = foldBodyworn(filter)
            presets = presets.map { preset -> FilterPreset in
                let next = foldBodyworn(preset.filter)
                if next == preset.filter { return preset }
                var p = preset
                p.filter = next
                return p
            }
            version = 58
        }
        if version < 59 {
            addSorted(ADDED_IN_V59)
            version = 59
        }
        if version < 60 {
            addSorted(ADDED_IN_V60)
            version = 60
        }
        if version < 61 {
            refreshDecodeNotes(["fleet-govee"])
            version = 61
        }
        if version < 62 {
            refreshDecodeNotes(["fleet-nest-weave"])
            version = 62
        }
        if version < 63 {
            fleets = fleets.map { fleet -> Fleet in
                if !fleet.builtIn { return fleet }
                if fleet.id != "fleet-fs-ext-battery" && fleet.id != "fleet-flock-cameras" { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                let note = (fleet.attentionNote.isBlank && stock.attentionNote.isNotBlank) ? stock.attentionNote : fleet.attentionNote
                var f = fleet
                f.kind = stock.kind
                f.colorIndex = stock.colorIndex
                f.notes = stock.notes
                f.attentionNote = note
                return f
            }
            addDefaultWatches()
            version = 63
        }
        if version < 64 {
            fleets = fleets.map { fleet -> Fleet in
                if !fleet.builtIn { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                if stock.attentionNote.isBlank { return fleet }
                let note = fleet.attentionNote.isBlank ? stock.attentionNote : fleet.attentionNote
                if note == fleet.attentionNote { return fleet }
                var f = fleet
                f.attentionNote = note
                return f
            }
            addDefaultWatches()
            version = 64
        }
        if version < 65 {
            fleets = fleets.map { fleet -> Fleet in
                if fleet.builtIn { return fleet }
                let rules = fleet.rules.map { rule -> MatchRule in
                    if !rule.enabled { return rule }
                    if rule.kind != .nameGlob && rule.kind != .nameContains { return rule }
                    if SignatureCandidates.isOverbroadCreateName(text: rule.text) {
                        var r = rule
                        r.enabled = false
                        return r
                    }
                    return rule
                }
                if rules == fleet.rules { return fleet }
                var f = fleet
                f.rules = rules
                return f
            }
            version = 65
        }
        if version < 66 {
            fleets = fleets.map { fleet -> Fleet in
                if fleet.builtIn { return fleet }
                let rules = fleet.rules.map { rule -> MatchRule in
                    if !rule.enabled || rule.kind != .serviceUuid { return rule }
                    let hex = rule.text.filterAlnum().uppercased()
                    if GENERIC_GATT_UUIDS.contains(hex) {
                        var r = rule
                        r.enabled = false
                        return r
                    }
                    return rule
                }
                if rules == fleet.rules { return fleet }
                var f = fleet
                f.rules = rules
                return f
            }
            version = 66
        }
        if version < 67 {
            fleets = fleets.map { fleet -> Fleet in
                if !fleet.builtIn { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                if stock.notes == fleet.notes { return fleet }
                var f = fleet
                f.notes = stock.notes
                return f
            }
            version = 67
        }
        if version < 68 {
            fleets = fleets.map { fleet -> Fleet in
                if !fleet.builtIn { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                if stock.notes == fleet.notes { return fleet }
                var f = fleet
                f.notes = stock.notes
                return f
            }
            version = 68
        }
        if version < 69 {
            addSorted(ADDED_IN_V69)
            version = 69
        }
        if version < 70 {
            addSorted(ADDED_IN_V70)
            addDefaultWatches()
            version = 70
        }
        if version < 71 {
            addDefaultWatches()
            version = 71
        }
        if version < 72 {
            let accessControl: Set<String> = ["fleet-seos", "fleet-salto", "fleet-dormakaba", "fleet-paxton"]
            fleets = fleets.map { fleet -> Fleet in
                if !fleet.builtIn || !accessControl.contains(fleet.id) { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                var f = fleet
                f.kind = stock.kind
                f.colorIndex = stock.colorIndex
                return f
            }
            version = 72
        }
        if version < 73 {
            fleets = fleets.filter { !($0.builtIn && $0.id == "fleet-unknown") }
            watchlist = watchlist.filter { $0.fleetId != "fleet-unknown" }
            version = 73
        }
        if version < 74 {
            addSorted(ADDED_IN_V74)
            addDefaultWatches()
            version = 74
        }
        if version < 75 {
            let stockPresets = engine.defaultPresets(fleets: fleets)
            let stockNames = Set(stockPresets.map { $0.name.lowercased() })
            let stockFilters = Set(stockPresets.map { $0.filter })
            let custom = presets.filter { !$0.isBuiltIn() }.filter { saved in
                !(stockNames.contains(saved.name.lowercased()) || stockFilters.contains(saved.filter))
            }
            presets = stockPresets + custom
            version = 75
        }
        if version < 76 {
            addSorted(ADDED_IN_V76)
            refreshDecodeNotes(TPMS_V76_REFRESH)
            version = 76
        }
        if version < 77 {
            addSorted(ADDED_IN_V77)
            fleets = fleets.map { fleet -> Fleet in
                if !fleet.builtIn || !CATALOG_V77_REFRESH.contains(fleet.id) { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                var f = fleet
                f.decode = stock.decode
                f.notes = stock.notes
                f.attentionNote = stock.attentionNote
                f.rules = stock.rules
                return f
            }
            // Kotlin keeps nulls in this set (map, not mapNotNull).
            let watched = Set(watchlist.map { $0.fleetId })
            let watchExtras = defaultWatchlist().filter { !watched.contains($0.fleetId) }
            if watchExtras.isNotEmpty { watchlist = watchlist + watchExtras }
            version = 77
        }
        if version < 78 {
            addSorted(ADDED_IN_V78)
            version = 78
        }
        if version < 79 {
            fleets = fleets.map { fleet -> Fleet in
                if !fleet.builtIn || fleet.id != "fleet-remote-id" { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                var f = fleet
                f.decode = stock.decode
                return f
            }
            version = 79
        }
        if version < 80 {
            let ids: Set<String> = ["fleet-raven", "fleet-penguin"]
            fleets = fleets.map { fleet -> Fleet in
                if !fleet.builtIn || !ids.contains(fleet.id) { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                var f = fleet
                f.rules = stock.rules
                f.notes = stock.notes
                f.attentionNote = stock.attentionNote
                return f
            }
            version = 80
        }
        if version < 81 {
            fleets = fleets.map { fleet -> Fleet in
                if !fleet.builtIn || fleet.id != "fleet-axon" { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                var f = fleet
                f.rules = stock.rules
                return f
            }
            version = 81
        }
        if version < 82 {
            fleets = fleets.map { fleet -> Fleet in
                if !fleet.builtIn || fleet.id != "fleet-flock-cameras" { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                var f = fleet
                f.rules = stock.rules
                f.notes = stock.notes
                f.attentionNote = stock.attentionNote
                return f
            }
            addSortedIfAny(ADDED_IN_V82)
            version = 82
        }
        if version < 83 {
            refreshDecodeNotes(["fleet-penguin"])
            version = 83
        }
        if version < 84 {
            addSortedIfAny(ADDED_IN_V84)
            version = 84
        }
        if version < 85 {
            refreshDecodeNotes(["fleet-dult"])
            version = 85
        }
        if version < 86 {
            refreshDecodeNotes(["fleet-dult"])
            version = 86
        }
        if version < 87 {
            refreshDecodeNotes(["fleet-find-hub"])
            version = 87
        }
        if version < 88 {
            refreshDecodeNotes(["fleet-remote-id"])
            version = 88
        }
        if version < 89 {
            addSortedIfAny(ADDED_IN_V89)
            fleets = fleets.map { fleet -> Fleet in
                if !fleet.builtIn { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                switch fleet.id {
                case "fleet-even-g1":
                    let extraRules = extraStockRules(fleet, stock)
                    var f = fleet
                    f.rules = extraRules.isEmpty ? fleet.rules : fleet.rules + extraRules
                    f.notes = stock.notes
                    f.attentionNote = stock.attentionNote
                    return f
                case "fleet-liteon-camera-radio":
                    let extraRules = extraStockRules(fleet, stock)
                    if extraRules.isEmpty { return fleet }
                    var f = fleet
                    f.rules = fleet.rules + extraRules
                    return f
                default:
                    return fleet
                }
            }
            if watchlist.none({ $0.fleetId == "fleet-rayneo" }) {
                if let row = defaultWatchlist().first(where: { $0.fleetId == "fleet-rayneo" }) {
                    watchlist = watchlist + [row]
                }
            }
            version = 89
        }
        if version < 90 {
            addSortedIfAny(ADDED_IN_V90)
            fleets = fleets.map { fleet -> Fleet in
                if !fleet.builtIn { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                switch fleet.id {
                case "fleet-remote-id", "fleet-parrot":
                    let extraRules = extraStockRules(fleet, stock)
                    var f = fleet
                    f.rules = extraRules.isEmpty ? fleet.rules : fleet.rules + extraRules
                    f.notes = stock.notes
                    return f
                default:
                    return fleet
                }
            }
            let watched = Set(watchlist.compactMap { $0.fleetId })
            let addWatch = defaultWatchlist().filter { w in
                guard let id = w.fleetId else { return false }
                return ADDED_IN_V90.contains(id) && !watched.contains(id)
            }
            if addWatch.isNotEmpty { watchlist = watchlist + addWatch }
            version = 90
        }
        if version < 91 {
            addSortedIfAny(ADDED_IN_V91)
            refreshDecodeNotes(["fleet-dji", "fleet-osmo"])
            version = 91
        }
        if version < 92 {
            fleets = fleets.map { fleet -> Fleet in
                if !fleet.builtIn { return fleet }
                guard let stock = catalog[fleet.id] else { return fleet }
                switch fleet.id {
                case "fleet-liteon-camera-radio":
                    var f = fleet
                    f.rules = fleet.rules.filter { rule in
                        !(rule.kind == .oui &&
                            (rule.text.equals("48:27:EA", ignoreCase: true) || rule.text.equals("82:6B:F2", ignoreCase: true)))
                    }
                    return f
                case "fleet-meta-glasses":
                    let extraRules = extraStockRules(fleet, stock)
                    var f = fleet
                    f.rules = extraRules.isEmpty ? fleet.rules : fleet.rules + extraRules
                    f.notes = stock.notes
                    f.attentionNote = stock.attentionNote
                    return f
                case "fleet-axon":
                    var f = fleet
                    f.notes = stock.notes
                    f.attentionNote = stock.attentionNote
                    return f
                default:
                    return fleet
                }
            }
            version = 92
        }
        if version < 93 {
            fleets = fleets.map { fleet -> Fleet in
                guard let stock = catalog[fleet.id] else { return fleet }
                return catalog93Fleet(fleet: fleet, stock: stock)
            }
            version = 93
        }
        if version < CATALOG_VERSION {
            addSortedIfAny(ADDED_IN_V94)
            version = CATALOG_VERSION
        }
        if !settings.darkTheme { settings.darkTheme = true }
        if settings.scanControlsExpanded { settings.scanControlsExpanded = false }
        presets = presets.filter { !($0.isBuiltIn() && hiddenPresetIds.contains($0.id)) }
            .distinctBy { $0.id }
        let fleetsChanged = fleets != cfg.fleets
        let presetsChanged = presets != cfg.presets
        let versionChanged = version != cfg.version
        let filterChanged = filter != cfg.filter
        let watchChanged = watchlist != cfg.watchlist
        let settingsChanged = settings != cfg.settings
        let hiddenChanged = hiddenPresetIds != cfg.hiddenPresetIds
        if !fleetsChanged && !presetsChanged && !versionChanged && !filterChanged &&
            !watchChanged && !settingsChanged && !hiddenChanged {
            return cfg
        }
        var out = cfg
        out.version = version
        out.fleets = fleets
        out.presets = presets
        out.filter = filter
        out.watchlist = watchlist
        out.settings = settings
        out.hiddenPresetIds = hiddenPresetIds
        return out
    }

    private static func seed() -> PersistedConfig {
        let fleets = DefaultCatalog.fleets()
        var c = PersistedConfig()
        c.version = CATALOG_VERSION
        c.fleets = fleets
        c.filter = FilterState()
        c.presets = FilterEngine().defaultPresets(fleets: fleets)
        c.watchlist = DefaultCatalog.defaultWatchlist()
        c.settings = AppSettings()
        return c
    }

    /// Stock catalog generation. Settings footer and the GitHub pack use this.
    public static let CATALOG_VERSION = 94

    private static let GENERIC_GATT_UUIDS: Set<String> = ["180A", "180D", "180F"]
    private static let POLICY_FLEET_IDS: Set<String> = [
        "fleet-flock-cameras", "fleet-liteon-camera-radio", "fleet-raven",
        "fleet-fs-ext-battery", "fleet-penguin", "fleet-pigvision",
    ]
    private static let ADDED_IN_V2 = [
        "fleet-chipolo", "fleet-pebblebee", "fleet-verkada", "fleet-vigilant", "fleet-eufy", "fleet-wyze",
        "fleet-ring", "fleet-arlo", "fleet-nest", "fleet-tapo", "fleet-reolink", "fleet-hikvision", "fleet-dahua",
    ]
    private static let ADDED_IN_V3 = [
        "fleet-meshtastic", "fleet-helium", "fleet-genetec", "fleet-rekor", "fleet-axon", "fleet-avigilon",
        "fleet-axis", "fleet-unifi",
    ]
    private static let ADDED_IN_V6 = ["fleet-hobby-ble"]
    private static let ADDED_IN_V8 = ["fleet-watchguard", "fleet-meta-glasses", "fleet-snap-spectacles"]
    private static let ADDED_IN_V9 = ["fleet-hak5-pineapple", "fleet-flipper", "fleet-pwnagotchi", "fleet-marauder"]
    private static let ADDED_IN_V10 = ["fleet-porkchop"]
    private static let ADDED_IN_V12 = ["fleet-apple-device", "fleet-apple-audio", "fleet-microsoft"]
    private static let ADDED_IN_V14 = [
        "fleet-tesla", "fleet-google", "fleet-sony", "fleet-bose", "fleet-garmin", "fleet-amazon", "fleet-fitbit",
        "fleet-oura", "fleet-logitech", "fleet-jbl", "fleet-sonos", "fleet-gopro", "fleet-dji",
    ]
    private static let ADDED_IN_V15 = [
        "fleet-netgear", "fleet-tplink", "fleet-asus", "fleet-linksys", "fleet-eero", "fleet-google-wifi",
        "fleet-dlink", "fleet-belkin", "fleet-xfinity", "fleet-spectrum", "fleet-att", "fleet-verizon",
        "fleet-starlink", "fleet-meraki", "fleet-glinet",
    ]
    private static let ADDED_IN_V16 = ["fleet-unifi-ap"]
    private static let ADDED_IN_V21 = ["fleet-nest-thermostat", "fleet-ecobee", "fleet-sensi", "fleet-honeywell-home"]
    private static let ADDED_IN_V22 = ["fleet-nest-weave"]
    private static let ADDED_IN_V23 = [
        "fleet-haiku", "fleet-tuya", "fleet-seos", "fleet-myq", "fleet-chevrolet", "fleet-rivian", "fleet-govee",
        "fleet-hp", "fleet-mbux", "fleet-motive",
    ]
    private static let ADDED_IN_V24 = [
        "fleet-august", "fleet-schlage", "fleet-nuki", "fleet-salto", "fleet-dormakaba", "fleet-lockly", "fleet-kevo",
        "fleet-master-lock", "fleet-igloohome", "fleet-tedee", "fleet-paxton", "fleet-kwikset",
    ]
    private static let ADDED_IN_V25 = ["fleet-ibeacon", "fleet-minew", "fleet-estimote", "fleet-kontakt"]
    private static let ADDED_IN_V28 = [
        "fleet-goodyear", "fleet-schrader", "fleet-pacific-tpms", "fleet-huf", "fleet-fobo", "fleet-ruuvi",
        "fleet-bluemaestro", "fleet-sensorpush", "fleet-samsara",
    ]
    private static let ADDED_IN_V31 = [
        "fleet-pokemon-go-plus", "fleet-hatch", "fleet-bhyve", "fleet-fieldy", "fleet-plaud", "fleet-retail-led-sign",
        "fleet-esl",
    ]
    private static let ADDED_IN_V32 = [
        "fleet-unifi-protect", "fleet-tesla-tstpms", "fleet-radiacode", "fleet-lg-webos", "fleet-nespresso",
        "fleet-epson", "fleet-shokz",
    ]
    private static let ADDED_IN_V33 = [
        "fleet-remote-id", "fleet-skydio", "fleet-autel", "fleet-parrot", "fleet-hoverair", "fleet-cradlepoint",
        "fleet-airlink",
    ]
    private static let ADDED_IN_V35 = [
        "fleet-cisco", "fleet-aruba", "fleet-ruckus", "fleet-fortinet", "fleet-mikrotik", "fleet-engenius",
        "fleet-zyxel", "fleet-peplink", "fleet-openwrt", "fleet-arris",
    ]
    private static let ADDED_IN_V36 = [
        "fleet-mist", "fleet-tmobile", "fleet-humax", "fleet-sagemcom", "fleet-arcadyan", "fleet-askey",
        "fleet-calix", "fleet-nokia", "fleet-airties", "fleet-tenda", "fleet-sercomm", "fleet-luxul", "fleet-sophos",
        "fleet-aumovio", "fleet-centurylink", "fleet-gm-hotspot", "fleet-audi-mmi",
    ]
    private static let ADDED_IN_V37 = [
        "fleet-extreme", "fleet-adtran", "fleet-cambium", "fleet-trendnet", "fleet-cudy", "fleet-snapav",
        "fleet-vantiva", "fleet-hitron", "fleet-actiontec", "fleet-buffalo", "fleet-grandstream", "fleet-edgecore",
        "fleet-watchguard-ap", "fleet-mojo", "fleet-winegard", "fleet-inseego", "fleet-synology",
    ]
    private static let ADDED_IN_V38 = ["fleet-compex", "fleet-novatel", "fleet-utility-inc"]
    private static let ADDED_IN_V39 = ["fleet-fast-pair"]
    private static let ADDED_IN_V40 = [
        "fleet-ford", "fleet-honda", "fleet-hyundai", "fleet-toyota", "fleet-nissan", "fleet-subaru", "fleet-bmw",
        "fleet-volkswagen", "fleet-porsche", "fleet-jlr", "fleet-byd",
    ]
    private static let ADDED_IN_V43 = ["fleet-osmo", "fleet-insta360"]
    private static let ADDED_IN_V50 = [
        "fleet-ruijie", "fleet-dwnet", "fleet-wavlink", "fleet-peoplenet", "fleet-uconnect", "fleet-carplay",
    ]
    private static let ADDED_IN_V51 = ["fleet-roku"]
    private static let ADDED_IN_V52 = ["fleet-franklin"]
    private static let ADDED_IN_V53 = ["fleet-samsung-appliance", "fleet-ecowater"]
    private static let ADDED_IN_V54 = ["fleet-carlink"]
    private static let ADDED_IN_V55 = ["fleet-target-atrius"]
    private static let ADDED_IN_V59 = ["fleet-phone-hotspot", "fleet-huawei", "fleet-plume"]
    private static let ADDED_IN_V60 = ["fleet-honeywell-xenon-hc", "fleet-omron", "fleet-withings", "fleet-dexcom"]
    private static let ADDED_IN_V69 = ["fleet-bluetoad"]
    private static let ADDED_IN_V70 = [
        "fleet-bliptrack", "fleet-hanwha-wisenet", "fleet-uniview", "fleet-rhombus", "fleet-meshcore",
        "fleet-gotenna", "fleet-sensecap", "fleet-rak-wisgate", "fleet-ghostesp", "fleet-bruce",
    ]
    private static let ADDED_IN_V74 = [
        "fleet-digital-ally", "fleet-reveal-media", "fleet-wolfcom", "fleet-panasonic-ipro", "fleet-limitless",
        "fleet-bee", "fleet-omi", "fleet-friend-pendant", "fleet-brilliant-frame", "fleet-even-g1",
        "fleet-hayden-ai", "fleet-miovision", "fleet-tattile", "fleet-lvt",
    ]
    private static let ADDED_IN_V76 = ["fleet-tpms-ble", "fleet-sytpms", "fleet-tirecheck", "fleet-tpms-service"]
    private static let TPMS_V76_REFRESH: Set<String> = [
        "fleet-goodyear", "fleet-schrader", "fleet-pacific-tpms", "fleet-huf", "fleet-fobo", "fleet-tesla-tstpms",
    ]
    private static let ADDED_IN_V77 = ["fleet-vuzix"]
    private static let CATALOG_V77_REFRESH: Set<String> = [
        "fleet-flock-cameras", "fleet-fs-ext-battery", "fleet-penguin", "fleet-raven", "fleet-remote-id",
        "fleet-meta-glasses", "fleet-snap-spectacles", "fleet-axon",
    ]
    private static let ADDED_IN_V82 = ["fleet-liteon-camera-radio"]
    private static let ADDED_IN_V78 = ["fleet-find-hub"]
    private static let ADDED_IN_V84 = ["fleet-dult"]
    private static let ADDED_IN_V89 = ["fleet-rayneo"]
    private static let ADDED_IN_V90 = [
        "fleet-tello", "fleet-potensic", "fleet-holystone", "fleet-hubsan", "fleet-yuneec", "fleet-swellpro",
        "fleet-crazyflie",
    ]
    private static let ADDED_IN_V91 = ["fleet-dji-power"]
    private static let ADDED_IN_V94 = ["fleet-polar"]
}

/// Catalog 93 drops loose Flock and Penguin names, Silicon Labs prefixes on FS Ext Battery, and the
/// unassigned LiteOn prefix. A rule the operator added with different text stays. Stock notes are copied
/// so the editor matches.
func catalog93Fleet(fleet: Fleet, stock: Fleet) -> Fleet {
    if !fleet.builtIn || fleet.id != stock.id { return fleet }
    let rules = fleet.rules.filter { rule in
        let drop: Bool
        switch fleet.id {
        case "fleet-flock-cameras":
            drop = (rule.kind == .nameContains && FLOCK_LOOSE_NAMES.contains(rule.text.uppercased())) ||
                (rule.kind == .nameGlob && rule.text == "Flock-??????")
        case "fleet-penguin":
            drop = (rule.kind == .nameContains && rule.text.equals("Penguin", ignoreCase: true)) ||
                (rule.kind == .nameGlob && rule.text.equals("Penguin*", ignoreCase: true))
        case "fleet-fs-ext-battery":
            drop = (rule.kind == .oui && FS_EXT_SILABS_OUIS.contains(rule.text.uppercased())) ||
                (rule.kind == .nameGlob && rule.text.equals("FS_*", ignoreCase: true))
        case "fleet-liteon-camera-radio":
            drop = rule.kind == .oui && rule.text.equals("B8:35:32", ignoreCase: true)
        default:
            drop = false
        }
        return !drop
    }
    switch fleet.id {
    case "fleet-flock-cameras", "fleet-penguin", "fleet-fs-ext-battery", "fleet-liteon-camera-radio":
        var f = fleet
        f.rules = rules
        f.notes = stock.notes
        f.attentionNote = stock.attentionNote
        return f
    default:
        return fleet
    }
}

private let FS_EXT_SILABS_OUIS: Set<String> = [
    "04:0D:84", "1C:34:F1", "38:5B:44", "94:34:69", "B4:E3:F9", "F0:82:C0",
]

private let FLOCK_LOOSE_NAMES: Set<String> = ["FLOCK", "FLCK", "CONDOR", "FALCON", "SPARROW"]
