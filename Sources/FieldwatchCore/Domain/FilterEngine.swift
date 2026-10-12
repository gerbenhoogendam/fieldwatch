import Foundation

// Port of domain/FilterEngine.kt.

public final class FilterEngine {
    public init() {}

    public func pass(
        device: Sighting,
        filter: FilterState,
        travel: CoTravel.Ctx = CoTravel.Ctx.None,
        now: Int = nowMs(),
        classByFleetId: [String: SignatureClass] = [:],
        namedRadioKeys: Set<String> = [],
        watchedFleetIds: Set<String> = [],
        alertDeviceKeys: Set<String> = [],
        mineKeys: Set<String> = []
    ) -> Bool {
        let named = device.fleetIds.isNotEmpty
        let namedOk = filter.namedOnly ? named : true
        let customNamedOk = filter.customNamesOnly ? namedRadioKeys.contains(device.key) : true
        let watchedOk = !filter.watchedOnly ? true
            : (alertDeviceKeys.contains(device.key) || device.fleetIds.contains { watchedFleetIds.contains($0) })
        let typeOk: Bool
        switch device.kind {
        case .wifi: typeOk = filter.showWifi
        case .ble: typeOk = filter.showBle
        }
        let hideOk = (filter.excludeSignatures && filter.fleetIds.isNotEmpty)
            ? !device.fleetIds.contains { filter.fleetIds.contains($0) }
            : true
        let includeOk = (!filter.includeSignatures || filter.includeFleetIds.isEmpty)
            ? true
            : device.fleetIds.contains { filter.includeFleetIds.contains($0) }
        let deviceClasses = Set(device.fleetIds.compactMap { classByFleetId[$0] })
        let hideClassOk = (filter.excludeClasses && filter.classes.isNotEmpty)
            ? !deviceClasses.contains { filter.classes.contains($0) }
            : true
        let includeClassOk = (!filter.useClassFilter || filter.excludeClasses || filter.classes.isEmpty)
            ? true
            : deviceClasses.contains { filter.classes.contains($0) }
        let rssiOk = device.rssi >= filter.rssiMin
        let nameOk = filter.nameQuery.isBlank ||
            TextMatch.contains(hay: device.name, needle: filter.nameQuery) ||
            TextMatch.contains(hay: device.mac, needle: filter.nameQuery)
        let ouiOk = filter.ouiQuery.isBlank ||
            TextMatch.contains(hay: device.mac, needle: filter.ouiQuery) ||
            (device.vendor != nil && TextMatch.contains(hay: device.vendor!, needle: filter.ouiQuery))

        let gates: Bool
        if filter.logic == .and {
            gates = namedOk && customNamedOk && watchedOk && typeOk && hideOk && includeOk && hideClassOk &&
                includeClassOk && rssiOk && nameOk && ouiOk
        } else {
            var optional: [Bool] = []
            if filter.includeSignatures { optional.append(includeOk) }
            if filter.useClassFilter && !filter.excludeClasses { optional.append(includeClassOk) }
            if filter.nameQuery.isNotBlank { optional.append(nameOk) }
            if filter.ouiQuery.isNotBlank { optional.append(ouiOk) }
            if filter.rssiMin > -100 { optional.append(rssiOk) }
            let any = optional.isEmpty ? true : optional.contains(true)
            gates = namedOk && customNamedOk && watchedOk && typeOk && hideOk && hideClassOk && any
        }
        if !gates { return false }
        if filter.hideFastPairAccountKey && FastPair.isAccountKeyOnly(device: device) { return false }
        if filter.hideMine && mineKeys.contains(device.key) { return false }
        if !filter.movingWithYou { return true }
        return CoTravel.withYou(device: device, ctx: travel, now: now)
    }

    public func defaultPresets(fleets: [Fleet] = []) -> [FilterPreset] {
        // FilterState has no Kotlin-style named-arg init in Swift; build each from the defaults.
        func state(_ edit: (inout FilterState) -> Void) -> FilterState {
            var s = FilterState()
            edit(&s)
            return s
        }
        return [
            FilterPreset(id: "all", name: "All traffic", filter: FilterState()),
            FilterPreset(id: "wifi", name: "Wi-Fi only", filter: state { $0.showBle = false }),
            FilterPreset(id: "ble", name: "BLE only", filter: state { $0.showWifi = false }),
            FilterPreset(id: "strong", name: "Strong signal", filter: state { $0.rssiMin = -70 }),
            FilterPreset(
                id: "with-you",
                name: "Moving with you",
                filter: state { $0.movingWithYou = true; $0.showWifi = false }
            ),
            FilterPreset(
                id: "watched",
                name: "Watched only",
                filter: state { $0.watchedOnly = true }
            ),
        ]
    }
}
