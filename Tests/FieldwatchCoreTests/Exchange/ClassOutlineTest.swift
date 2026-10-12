import Foundation
import Testing
@testable import FieldwatchCore

// Port of ClassOutlineTest.kt.

@Suite struct ClassOutlineTest {
    private let classBy: [String: SignatureClass] = [
        "fleet-gopro": .camera,
        "fleet-osmo": .camera,
        "fleet-dji": .drone,
        "fleet-tapo": .camera,
        "fleet-tplink": .isp,
    ]

    @Test func unmatchedSitsLastAndClassCountsAreUniqueRadios() throws {
        let goproA = radio("a", "fleet-gopro")
        let goproB = radio("b", "fleet-gopro")
        let osmo = radio("c", "fleet-osmo")
        let drone = radio("d", "fleet-dji")
        let unnamed = radio("u")
        let slices = ClassOutline.of(devices: [goproA, goproB, osmo, drone, unnamed], classByFleetId: classBy)
        #expect(slices.count == SignatureClass.visible.count + 1)
        let expected: [SignatureClass?] = SignatureClass.visible.sortedBy { $0.label().lowercased() } + [nil]
        #expect(slices.map { $0.kind } == expected)
        let cameras = try slice(slices, .camera)
        let drones = try slice(slices, .drone)
        #expect(cameras.radios.count == 3)
        #expect(cameras.signatures.count == 2)
        #expect(cameras.signatures.first { $0.fleetId == "fleet-gopro" }?.radios.count == 2)
        #expect(drones.radios.count == 1)
        #expect(try slice(slices, .finder).radios.count == 0)
        #expect(slices.last?.label() == "Unmatched")
        #expect(slices.last?.radios.count == 1)
        #expect(slices.last?.signatures.isEmpty == true)
    }

    @Test func dualChipRadioCountsInEachClassOnce() throws {
        let dual = radio("x", "fleet-tapo", "fleet-tplink")
        let slices = ClassOutline.of(devices: [dual], classByFleetId: classBy)
        #expect(slices.count == SignatureClass.visible.count + 1)
        #expect(try slice(slices, .camera).radios.count == 1)
        #expect(try slice(slices, .isp).radios.count == 1)
        #expect(ClassOutline.multiClassCount(devices: [dual], classByFleetId: classBy) == 1)
        #expect(slices.sumOf { $0.radios.count } == 2)
        #expect(slices.flatMap { $0.radios }.distinctBy { $0.key }.count == 1)
    }

    @Test func emptyAndAllUnmatchedKeepEveryClass() {
        let empty = ClassOutline.of(devices: [], classByFleetId: classBy)
        #expect(empty.count == SignatureClass.visible.count + 1)
        #expect(empty.dropLast().allSatisfy { $0.radios.isEmpty })
        #expect(empty.last != nil && empty.last!.kind == nil)
        let only = radio("u")
        let slices = ClassOutline.of(devices: [only], classByFleetId: classBy)
        #expect(slices.count == SignatureClass.visible.count + 1)
        #expect(slices.last?.radios.count == 1)
        #expect(ClassOutline.multiClassCount(devices: [only], classByFleetId: classBy) == 0)
    }

    @Test func preservesLiveOrderInsideBuckets() throws {
        let loud = radio("z", "fleet-gopro")
        let quiet = radio("a", "fleet-gopro")
        let slices = ClassOutline.of(devices: [loud, quiet], classByFleetId: classBy)
        let cameras = try slice(slices, .camera)
        #expect(cameras.radios.map { $0.key } == ["z", "a"])
        #expect(cameras.signatures.count == 1)
        #expect(cameras.signatures.first?.radios.map { $0.key } == ["z", "a"])
    }

    @Test func signaturesAreAlphabeticalByNameNotCount() throws {
        let names = [
            "fleet-gopro": "Zed",
            "fleet-osmo": "Alpha",
            "fleet-tapo": "Mike",
        ]
        let slices = ClassOutline.of(
            devices: [
                radio("1", "fleet-gopro"),
                radio("2", "fleet-gopro"),
                radio("3", "fleet-gopro"),
                radio("4", "fleet-osmo"),
                radio("5", "fleet-tapo"),
            ],
            classByFleetId: classBy,
            nameByFleetId: names
        )
        let cameras = try slice(slices, .camera)
        #expect(cameras.signatures.map { $0.fleetId } == ["fleet-osmo", "fleet-tapo", "fleet-gopro"])
    }

    @Test func classesAreAlphabeticalByLabelUnmatchedLast() {
        let slices = ClassOutline.of(devices: [], classByFleetId: classBy)
        let labels = slices.dropLast().map { $0.label() }
        #expect(labels.sortedBy { $0.lowercased() } == labels)
        #expect(labels.first == "Access control")
        #expect(labels.last == "Wearables")
        #expect(slices.last?.label() == "Unmatched")
        #expect(labels.none { $0 == "Body-worn" })
    }

    @Test func bodywornRadiosSitInWearables() throws {
        let classBy: [String: SignatureClass] = ["fleet-old": .bodyworn]
        let slices = ClassOutline.of(devices: [radio("w", "fleet-old")], classByFleetId: classBy)
        #expect(slices.none { $0.kind == .bodyworn })
        let wear = try slice(slices, .wearable)
        #expect(wear.radios.count == 1)
        let reveal = ClassOutline.reveal(device: radio("w", "fleet-old"), classByFleetId: classBy)
        #expect(reveal.classIds == ["WEARABLE"])
    }

    @Test func viewModeLabelExists() {
        #expect(ViewMode.byClass.label() == "By class")
        #expect(ViewMode.allCases.count == 5)
    }

    @Test func revealOpensClassAndSignature() {
        let r = ClassOutline.reveal(device: radio("a", "fleet-gopro"), classByFleetId: classBy)
        #expect(r.classIds == ["CAMERA"])
        #expect(r.sigKeys == ["CAMERA/fleet-gopro"])
    }

    @Test func revealUnmatchedOpensUnmatchedOnly() {
        let r = ClassOutline.reveal(device: radio("u"), classByFleetId: classBy)
        #expect(r.classIds == ["unmatched"])
        #expect(r.sigKeys.isEmpty)
    }

    @Test func revealDualChipOpensEachClass() {
        let r = ClassOutline.reveal(device: radio("x", "fleet-tapo", "fleet-tplink"), classByFleetId: classBy)
        #expect(r.classIds == ["CAMERA", "ISP"])
        #expect(r.sigKeys == ["CAMERA/fleet-tapo", "ISP/fleet-tplink"])
    }

    @Test func radioItemIndexNullWhenBranchClosed() {
        let gopro = radio("z", "fleet-gopro")
        let slices = ClassOutline.of(devices: [gopro], classByFleetId: classBy, nameByFleetId: ["fleet-gopro": "GoPro"])
        #expect(ClassOutline.radioItemIndex(slices: slices, openClasses: [], openSigs: [], deviceKey: "z") == nil)
        #expect(ClassOutline.radioItemIndex(slices: slices, openClasses: ["CAMERA"], openSigs: [], deviceKey: "z") == nil)
    }

    @Test func radioItemIndexFindsOpenedMatchedRow() throws {
        let gopro = radio("z", "fleet-gopro")
        let slices = ClassOutline.of(devices: [gopro], classByFleetId: classBy, nameByFleetId: ["fleet-gopro": "GoPro"])
        let beforeCameras = SignatureClass.visible.count { $0.label().lowercased() < "cameras" }
        // summary + closed class headers before Cameras + Cameras header + signature header + radio
        let expected = 1 + beforeCameras + 1 + 1
        #expect(
            ClassOutline.radioItemIndex(
                slices: slices,
                openClasses: ["CAMERA"],
                openSigs: ["CAMERA/fleet-gopro"],
                deviceKey: "z"
            ) == expected
        )
        let snap = try #require(ClassOutline.outlineSnap(
            slices: slices,
            openClasses: ["CAMERA"],
            openSigs: ["CAMERA/fleet-gopro"],
            deviceKey: "z"
        ))
        #expect(snap.classIndex == 1 + beforeCameras)
        #expect(snap.signatureIndex == 1 + beforeCameras + 1)
        #expect(snap.radioIndex == expected)
    }

    @Test func radioItemIndexFindsOpenedUnmatchedRow() throws {
        let unnamed = radio("u")
        let slices = ClassOutline.of(devices: [unnamed], classByFleetId: classBy)
        let expected = 1 + SignatureClass.visible.count + 1
        #expect(ClassOutline.radioItemIndex(slices: slices, openClasses: ["unmatched"], openSigs: [], deviceKey: "u") == expected)
        let snap = try #require(ClassOutline.outlineSnap(slices: slices, openClasses: ["unmatched"], openSigs: [], deviceKey: "u"))
        #expect(snap.classIndex == 1 + SignatureClass.visible.count)
        #expect(snap.signatureIndex == nil)
        #expect(snap.radioIndex == expected)
    }

    @Test func outlineSnapLeadingItemsSkipsEmptyWhenFiltered() throws {
        let gopro = radio("z", "fleet-gopro")
        let slices = ClassOutline.of(devices: [gopro], classByFleetId: classBy, nameByFleetId: ["fleet-gopro": "GoPro"])
        let visible = slices.filter { $0.radios.isNotEmpty }
        let snap = try #require(ClassOutline.outlineSnap(
            slices: visible,
            openClasses: ["CAMERA"],
            openSigs: ["CAMERA/fleet-gopro"],
            deviceKey: "z",
            leadingItems: 2
        ))
        #expect(snap.classIndex == 2)
        #expect(snap.signatureIndex == 3)
        #expect(snap.radioIndex == 4)
    }

    @Test func outlineSnapNullWhenBranchClosed() {
        let gopro = radio("z", "fleet-gopro")
        let slices = ClassOutline.of(devices: [gopro], classByFleetId: classBy, nameByFleetId: ["fleet-gopro": "GoPro"])
        #expect(ClassOutline.outlineSnap(slices: slices, openClasses: [], openSigs: [], deviceKey: "z") == nil)
        #expect(ClassOutline.outlineSnap(slices: slices, openClasses: ["CAMERA"], openSigs: [], deviceKey: "z") == nil)
    }

    // MARK: - Helpers

    private func slice(_ slices: [ClassSlice], _ kind: SignatureClass) throws -> ClassSlice {
        try #require(slices.first { $0.kind == kind }, "no slice for \(kind.rawValue)")
    }

    private func radio(_ key: String, _ fleets: String...) -> Sighting {
        Sighting(
            key: key, kind: .ble, mac: "AA:BB:CC:DD:EE:\(key.take(2).uppercased().padStart(2, "0"))", name: key,
            rssi: -40, rssiMin: -40, rssiMax: -40, channel: 0, frequencyMhz: 0, vendor: nil,
            randomized: false, hiddenSsid: false, serviceUuids: [], manufacturerId: nil, manufacturerDataHex: "",
            rawHex: "", extras: "", firstSeen: 1, lastSeen: 1, hitCount: 1, fleetIds: fleets,
            rssiHistory: [], presence: []
        )
    }
}
