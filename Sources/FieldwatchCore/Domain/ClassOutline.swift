import Foundation

// Port of domain/ClassOutline.kt. The By class Live view: class → signature → radio.

public struct SignatureSlice: Hashable, Sendable {
    public var fleetId: String
    public var radios: [Sighting]

    public init(fleetId: String, radios: [Sighting]) { self.fleetId = fleetId; self.radios = radios }
}

public struct ClassSlice: Hashable, Sendable {
    public var kind: SignatureClass?
    public var radios: [Sighting]
    public var signatures: [SignatureSlice]

    public init(kind: SignatureClass?, radios: [Sighting], signatures: [SignatureSlice]) {
        self.kind = kind; self.radios = radios; self.signatures = signatures
    }

    public var id: String { kind?.rawValue ?? "unmatched" }
    public func label() -> String { kind?.label() ?? "Unmatched" }
}

public struct OutlineReveal: Hashable, Sendable {
    public var classIds: Set<String>
    public var sigKeys: Set<String>

    public init(classIds: Set<String>, sigKeys: Set<String>) { self.classIds = classIds; self.sigKeys = sigKeys }
}

/// List indices for a By class watchlist jump.
public struct OutlineSnap: Hashable, Sendable {
    public var classIndex: Int
    public var signatureIndex: Int?
    public var radioIndex: Int

    public init(classIndex: Int, signatureIndex: Int?, radioIndex: Int) {
        self.classIndex = classIndex; self.signatureIndex = signatureIndex; self.radioIndex = radioIndex
    }
}

/// Insertion-ordered set of strings (Kotlin LinkedHashSet).
private struct OrderedKeys {
    var order: [String] = []
    var seen: Set<String> = []
    mutating func add(_ k: String) { if seen.insert(k).inserted { order.append(k) } }
}

public enum ClassOutline {
    /// Group the current Live set by signature class, then signature.
    /// Every class is present, even at 0, so the list does not jump as radios
    /// appear and drop. Classes are A–Z by label. Signatures under a class
    /// are A–Z by name. Dual-chip radios sit in every class they matched.
    /// Unmatched is always last. Radio order inside a bucket follows
    /// `devices` (Live sort).
    public static func of(
        devices: [Sighting],
        classByFleetId: [String: SignatureClass],
        nameByFleetId: [String: String] = [:]
    ) -> [ClassSlice] {
        struct Acc {
            var keys = OrderedKeys()
            var fleetOrder: [String] = []
            var byFleet: [String: OrderedKeys] = [:]
        }
        var byClass: [SignatureClass: Acc] = [:]
        var unmatched: [Sighting] = []
        var byKey: [String: Sighting] = [:]
        for device in devices { byKey[device.key] = device }
        for device in devices {
            if device.fleetIds.isEmpty {
                unmatched.append(device)
                continue
            }
            for id in device.fleetIds {
                let kind = (classByFleetId[id] ?? .other).folded()
                var acc = byClass[kind] ?? Acc()
                acc.keys.add(device.key)
                if acc.byFleet[id] == nil {
                    acc.fleetOrder.append(id)
                    acc.byFleet[id] = OrderedKeys()
                }
                acc.byFleet[id]!.add(device.key)
                byClass[kind] = acc
            }
        }
        func radiosOf(_ keys: [String]) -> [Sighting] { keys.compactMap { byKey[$0] } }
        func slice(_ kind: SignatureClass, _ acc: Acc?) -> ClassSlice {
            guard let acc else { return ClassSlice(kind: kind, radios: [], signatures: []) }
            let sigs = acc.fleetOrder
                .sortedBy { (nameByFleetId[$0] ?? $0).lowercased() }
                .map { fleetId in SignatureSlice(fleetId: fleetId, radios: radiosOf(acc.byFleet[fleetId]!.order)) }
            return ClassSlice(kind: kind, radios: radiosOf(acc.keys.order), signatures: sigs)
        }
        return SignatureClass.visible
            .sortedBy { $0.label().lowercased() }
            .map { kind in slice(kind, byClass[kind]) } +
            [ClassSlice(kind: nil, radios: unmatched, signatures: [])]
    }

    public static func multiClassCount(devices: [Sighting], classByFleetId: [String: SignatureClass]) -> Int {
        devices.count { device in
            Set(device.fleetIds.compactMap { classByFleetId[$0] }).count > 1
        }
    }

    /// Class / signature ids to open so `device` is shown on By class.
    public static func reveal(device: Sighting, classByFleetId: [String: SignatureClass]) -> OutlineReveal {
        if device.fleetIds.isEmpty {
            return OutlineReveal(classIds: ["unmatched"], sigKeys: [])
        }
        var classIds = Set<String>()
        var sigKeys = Set<String>()
        for id in device.fleetIds {
            let kind = (classByFleetId[id] ?? .other).folded()
            classIds.insert(kind.rawValue)
            sigKeys.insert("\(kind.rawValue)/\(id)")
        }
        return OutlineReveal(classIds: classIds, sigKeys: sigKeys)
    }

    /// List index of the first radio row for `deviceKey`, or nil if that
    /// branch is closed. `leadingItems` is the count of rows before the first
    /// class header (chips + summary).
    public static func radioItemIndex(
        slices: [ClassSlice],
        openClasses: Set<String>,
        openSigs: Set<String>,
        deviceKey: String,
        leadingItems: Int = 1
    ) -> Int? {
        outlineSnap(slices: slices, openClasses: openClasses, openSigs: openSigs, deviceKey: deviceKey, leadingItems: leadingItems)?.radioIndex
    }

    /// Class header, signature header (nil for Unmatched), and radio row
    /// indices so a watchlist jump can keep the tree in view when it fits.
    public static func outlineSnap(
        slices: [ClassSlice],
        openClasses: Set<String>,
        openSigs: Set<String>,
        deviceKey: String,
        leadingItems: Int = 1
    ) -> OutlineSnap? {
        var idx = leadingItems.coerceAtLeast(0)
        for slice in slices {
            let classIndex = idx
            idx += 1
            if !openClasses.contains(slice.id) { continue }
            if slice.kind == nil {
                for radio in slice.radios {
                    if radio.key == deviceKey {
                        return OutlineSnap(classIndex: classIndex, signatureIndex: nil, radioIndex: idx)
                    }
                    idx += 1
                }
            } else {
                for sig in slice.signatures {
                    let sigKey = "\(slice.id)/\(sig.fleetId)"
                    let signatureIndex = idx
                    idx += 1
                    if !openSigs.contains(sigKey) { continue }
                    for radio in sig.radios {
                        if radio.key == deviceKey {
                            return OutlineSnap(classIndex: classIndex, signatureIndex: signatureIndex, radioIndex: idx)
                        }
                        idx += 1
                    }
                }
            }
        }
        return nil
    }
}
