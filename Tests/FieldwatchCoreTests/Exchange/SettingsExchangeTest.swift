import Foundation
import Testing
@testable import FieldwatchCore

// Port of SettingsExchangeTest.kt.
// Swift's pretty JSON writes `"key" : value` (space before the colon), so string probes use that form.

@Suite struct SettingsExchangeTest {
    @Test func factorySettingsVoiceAndJump() {
        let stock = AppSettings()
        #expect(stock.alertVoice)
        #expect(stock.gnssVoice)
        #expect(stock.alertVoiceWhat == .both)
        #expect(stock.snapToBeep)
        #expect(stock.darkTheme)
        #expect(stock.keepScreenOn)
        #expect(stock.alertBeep)
        #expect(stock.viewMode == .byClass)
        #expect(stock.showRssiBar)
        #expect(stock.showFleetName)
        #expect(stock.showFrequency)
        #expect(stock.showSeenTimes)
    }

    private let stockFleets = DefaultCatalog.fleets()
    private var stockPresets: [FilterPreset] { FilterEngine().defaultPresets(fleets: stockFleets) }

    private func localConfig(
        settings: AppSettings? = nil,
        filter: FilterState = FilterState(),
        presets: [FilterPreset]? = nil,
        watchlist: [WatchTarget]? = nil,
        hiddenPresetIds: Set<String> = [],
        fleets: [Fleet]? = nil
    ) -> PersistedConfig {
        var c = PersistedConfig()
        c.version = 72
        c.fleets = fleets ?? stockFleets
        c.filter = filter
        c.presets = presets ?? stockPresets
        c.watchlist = watchlist ?? DefaultCatalog.defaultWatchlist()
        c.settings = settings ?? with(AppSettings()) {
            $0.disclaimerAccepted = true
            $0.disclaimerRev = DISCLAIMER_REV
            $0.nightMode = false
            $0.demoMode = false
        }
        c.arrivalKnownKeys = ["BLE:AA:BB:CC:DD:EE:FF"]
        c.hiddenPresetIds = hiddenPresetIds
        return c
    }

    private func samplePack() -> SettingsPack {
        SettingsExchange.pack(
            settings: with(AppSettings()) {
                $0.disclaimerAccepted = false
                $0.disclaimerRev = 0
                $0.nightMode = true
                $0.darkTheme = false
                $0.demoMode = true
                $0.keepScreenOn = false
                $0.takEnabled = true
                $0.takHost = "192.168.0.9"
            },
            filter: with(FilterState()) {
                $0.showWifi = false
                $0.showBle = true
            },
            presets: stockPresets + [FilterPreset(
                id: "custom-plaza",
                name: "plaza -80",
                filter: with(FilterState()) {
                    $0.rssiMin = -80
                    $0.showWifi = false
                    $0.showBle = true
                }
            )],
            watchlist: [
                WatchTarget(
                    id: "named-bag",
                    deviceKey: "BLE:C3:A6:A9:11:22:33",
                    label: "bag tag",
                    alert: true,
                    observerNotes: "in the bag",
                    mine: true
                ),
                WatchTarget(
                    id: "watch-airtag",
                    fleetId: "fleet-airtag",
                    label: "Apple AirTags"
                ),
            ],
            hiddenPresetIds: ["hide-phones"],
            appVersion: "1.0.1",
            exportedAt: "2026-09-16T00:00:00Z"
        )
    }

    @Test func roundTripKeepsNamedRadiosAndPresets() throws {
        let json = SettingsExchange.encode(pack: samplePack())
        #expect(json.contains("\"format\" : \"fieldwatch-settings\""))
        #expect(!json.contains("\"fleets\""))
        let pack = try SettingsExchange.parse(text: json)
        #expect(pack.format == SettingsPack.FORMAT)
        #expect(pack.watchlist.count { $0.deviceKey == "BLE:C3:A6:A9:11:22:33" } == 1)
        let named = try only(pack.watchlist.filter { $0.deviceKey != nil })
        #expect(named.observerNotes == "in the bag")
        #expect(named.mine)
        let legacy = try SettingsExchange.jsonDecoder.decode(
            WatchTarget.self,
            from: Data(#"{"id":"n","deviceKey":"BLE:AA:BB:CC:DD:EE:FF","label":"bag","observerNotes":"in the bag"}"#.utf8)
        )
        #expect(legacy.observerNotes == "in the bag")
        #expect(!legacy.mine)
        #expect(!pack.filter.hideMine)
        let oldFilter = try SettingsExchange.jsonDecoder.decode(
            FilterState.self,
            from: Data(#"{"showWifi":false,"showBle":true}"#.utf8)
        )
        #expect(!oldFilter.hideMine)
        #expect(!oldFilter.showWifi)
        #expect(pack.presets.last?.name == "plaza -80")
        #expect(pack.hiddenPresetIds == ["hide-phones"])
        #expect(pack.filter.showBle)
        #expect(!pack.filter.showWifi)
    }

    @Test func applyReplacesSetupButKeepsCatalogDisclaimerAndSeenKeys() throws {
        let customFleet = Fleet(
            id: "custom-keep-me",
            name: "Keep me",
            rules: [MatchRule(kind: .nameContains, text: "KeepMe")]
        )
        let local = localConfig(
            filter: with(FilterState()) {
                $0.showWifi = true
                $0.showBle = true
            },
            watchlist: DefaultCatalog.defaultWatchlist(),
            fleets: stockFleets + [customFleet]
        )
        let (next, result) = SettingsExchange.apply(local: local, pack: samplePack())
        #expect(result.error == nil)
        #expect(result.namedRadios == 1)
        #expect(result.signatureWatches == 1)
        #expect(result.presets == stockPresets.count + 1)
        #expect(result.summary().contains("1 named radio"))
        #expect(next.settings.nightMode)
        #expect(next.settings.darkTheme)
        #expect(next.settings.demoMode)
        #expect(next.settings.takHost == "192.168.0.9")
        #expect(next.settings.disclaimerAccepted)
        #expect(next.settings.disclaimerRev == DISCLAIMER_REV)
        #expect(!next.filter.showWifi)
        #expect(next.hiddenPresetIds == ["hide-phones"])
        #expect(next.presets.contains { $0.id == "custom-plaza" })
        let named = try only(next.watchlist.filter { $0.deviceKey != nil })
        #expect(named.label == "bag tag")
        #expect(named.mine)
        #expect(named.observerNotes == "in the bag")
        #expect(next.fleets.contains { $0.id == "custom-keep-me" })
        #expect(next.fleets.count == local.fleets.count)
        #expect(next.arrivalKnownKeys == ["BLE:AA:BB:CC:DD:EE:FF"])
    }

    @Test func applyTwiceIsIdempotent() {
        let local = localConfig()
        let (once, _) = SettingsExchange.apply(local: local, pack: samplePack())
        let (twice, result) = SettingsExchange.apply(local: once, pack: samplePack())
        #expect(once == twice)
        #expect(result.namedRadios == 1)
    }

    @Test func takImportWarningOnlyWhenFeedOrDestinationChanges() throws {
        let local = with(AppSettings()) {
            $0.takEnabled = false
            $0.takHost = "239.2.3.1"
            $0.takPort = 10011
        }
        #expect(SettingsExchange.takImportWarning(local: local, incoming: local) == nil)
        let on = with(local) {
            $0.takEnabled = true
            $0.takHost = "192.168.0.9"
            $0.takPort = 10011
        }
        let sameOn = SettingsExchange.takImportWarning(local: on, incoming: on)
        #expect(sameOn == nil)
        let turnsOn = try #require(SettingsExchange.takImportWarning(local: local, incoming: with(local) { $0.takEnabled = true }))
        #expect(turnsOn.contains("turns the TAK / CoT feed on"))
        #expect(turnsOn.contains("239.2.3.1:10011"))
        let newHost = try #require(SettingsExchange.takImportWarning(local: local, incoming: with(local) {
            $0.takHost = "10.0.0.8"
            $0.takPort = 4242
        }))
        #expect(newHost.contains("10.0.0.8:4242"))
        #expect(newHost.contains("stays off"))
        let caseOnly = SettingsExchange.takImportWarning(
            local: with(local) { $0.takHost = "ata.example" },
            incoming: with(local) { $0.takHost = "ATA.example" }
        )
        #expect(caseOnly == nil)
    }

    @Test func parseRejectsSignaturePackAndEmpty() {
        let signatures = SignatureExchange.encode(
            pack: SignatureExchange.pack(
                fleets: stockFleets.take(1),
                catalogVersion: 1,
                appVersion: "1.0.1",
                exportedAt: "2026-09-16T00:00:00Z"
            )
        )
        let sig = #expect(throws: ExchangeError.self) { try SettingsExchange.parse(text: signatures) }
        #expect(sig?.message.contains("signature pack") == true)
        let empty = #expect(throws: ExchangeError.self) { try SettingsExchange.parse(text: "") }
        #expect(empty?.message.contains("empty") == true)
        let config = #expect(throws: ExchangeError.self) { try SettingsExchange.parse(text: "{\"version\":68,\"fleets\":[]}") }
        #expect(config?.message.contains("Not a Fieldwatch settings pack") == true)
    }

    @Test func gnssSettingsRoundTripAndOldNamesStillLoad() throws {
        let tuned = with(AppSettings()) {
            $0.gnssMonitor = true
            $0.gnssSensitivity = .high
            $0.gnssAlertFloor = .low
            $0.gnssSpoofChecks = true
            $0.gnssBeep = false
            $0.gnssVoice = true
            $0.gnssShade = true
            $0.gnssFullTracking = true
            $0.gnssCorrelation = true
            $0.gnssInvertAgc = true
        }
        let encoded = SettingsExchange.encode(
            pack: SettingsExchange.pack(
                settings: tuned,
                filter: FilterState(),
                presets: [],
                watchlist: [],
                hiddenPresetIds: [],
                appVersion: "1.1.22",
                exportedAt: "2026-10-08T00:00:00Z"
            )
        )
        #expect(encoded.contains("\"gnssSensitivity\" : \"HIGH\""))
        #expect(encoded.contains("\"gnssMonitor\" : true"))
        let parsed = try SettingsExchange.parse(text: encoded)
        #expect(gnssSettings(tuned) == gnssSettings(parsed.settings))
        let (next, _) = SettingsExchange.apply(local: localConfig(), pack: parsed)
        #expect(gnssSettings(tuned) == gnssSettings(next.settings))

        let fromOld = try decodeSettings(#"{"gnssSensitivity":"NORMAL","gnssSpoofChecks":true}"#)
        #expect(fromOld.gnssSensitivity == .medium)
        #expect(fromOld.gnssSpoofChecks)
        let fromLess = try decodeSettings(#"{"gnssSensitivity":"LESS"}"#)
        #expect(fromLess.gnssSensitivity == .low)
        let fromMore = try decodeSettings(#"{"gnssSensitivity":"MORE"}"#)
        #expect(fromMore.gnssSensitivity == .high)
        let missing = try decodeSettings(#"{"keepScreenOn":true}"#)
        #expect(!missing.gnssMonitor)
        #expect(missing.gnssSensitivity == .medium)
        #expect(missing.takGnss == .off)
        #expect(missing.takGnssHold == .hour)
        #expect(missing.takRadioHold == .hour)
        #expect(missing.takFlood == .off)
        #expect(missing.gnssAlertFloor == .medium)
        #expect(missing.gnssBeep)
        #expect(missing.gnssVoice)
        #expect(!missing.gnssShade)
    }

    // MARK: - Helpers

    /// Kotlin `AppSettings.gnssSettings()` (not in Models.swift): the GNSS fields in order.
    private func gnssSettings(_ s: AppSettings) -> [AnyHashable] {
        [
            s.gnssMonitor, s.gnssSensitivity, s.gnssAlertFloor, s.gnssSpoofChecks, s.gnssBeep,
            s.gnssVoice, s.gnssShade, s.gnssFullTracking, s.gnssCorrelation, s.gnssInvertAgc,
        ]
    }

    private func decodeSettings(_ json: String) throws -> AppSettings {
        try SettingsExchange.jsonDecoder.decode(AppSettings.self, from: Data(json.utf8))
    }

    private func only<T>(_ items: [T]) throws -> T {
        try #require(items.count == 1, "expected one element, got \(items.count)")
        return items[0]
    }

    private func with<T>(_ value: T, _ change: (inout T) -> Void) -> T {
        var copy = value
        change(&copy)
        return copy
    }
}
