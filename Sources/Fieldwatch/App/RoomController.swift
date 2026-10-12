import AppKit
import Foundation
import Observation
import FieldwatchCore

// macOS addition: state behind the Room screen (sketched room, radios placed relative to this Mac).
// Not in the Android app. Created on first use; keeps tracking once a second for the rest of the session.

@MainActor @Observable final class RoomController {
    private static var instance: RoomController?

    static func shared(vm: FieldwatchViewModel) -> RoomController {
        if let instance { return instance }
        let c = RoomController(vm: vm)
        instance = c
        return c
    }

    @ObservationIgnored private let vm: FieldwatchViewModel
    @ObservationIgnored private let store = RoomStore()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var dirtyAt: Int?
    @ObservationIgnored private var undoStack: [RoomPlan] = []
    @ObservationIgnored private var redoStack: [RoomPlan] = []

    private(set) var file: RoomFile
    /// Live distance and drawn position per radio key, refreshed every second.
    private(set) var tracks: [String: RoomTrack] = [:]
    /// Live smoothed loudness per radio in the room (nil when not heard in the window).
    private(set) var live: [String: (rssi: Double, spread: Double, count: Int)] = [:]
    var selectedKey: String?
    var selectedWallId: String?

    private init(vm: FieldwatchViewModel) {
        self.vm = vm
        file = store.load()
        if file.rooms.contains(where: { $0.devices.contains { $0.key.hasPrefix(ConnectedDevices.KEY_PREFIX) } }) {
            ConnectedDevices.shared.start()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    // MARK: Room

    var plan: RoomPlan {
        get { file.rooms.first { $0.id == file.selectedId } ?? file.rooms[0] }
        set {
            let id = newValue.id
            if let i = file.rooms.firstIndex(where: { $0.id == id }) { file.rooms[i] = newValue } else { file.rooms.append(newValue) }
            markDirty()
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Apply an edit the operator can undo.
    func edit(_ change: (inout RoomPlan) -> Void) {
        undoStack.append(plan)
        if undoStack.count > 80 { undoStack.removeFirst() }
        redoStack.removeAll()
        var p = plan
        change(&p)
        p.updatedAt = nowMs()
        plan = p
        recompute()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(plan)
        plan = prev
        recompute()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(plan)
        plan = next
        recompute()
    }

    func newRoom(name: String) {
        let room = RoomPlan(name: name.trim().ifBlank("Room \(file.rooms.count + 1)"))
        file.rooms.append(room)
        file.selectedId = room.id
        clearHistory()
        markDirty()
        recompute()
    }

    func selectRoom(id: String) {
        guard file.rooms.contains(where: { $0.id == id }) else { return }
        file.selectedId = id
        selectedKey = nil
        selectedWallId = nil
        clearHistory()
        markDirty()
        recompute()
    }

    func renameRoom(_ name: String) {
        let n = name.trim()
        guard n.isNotEmpty else { return }
        edit { $0.name = n }
    }

    func deleteRoom() {
        let id = plan.id
        file.rooms.removeAll { $0.id == id }
        if file.rooms.isEmpty { file.rooms = [RoomPlan()] }
        file.selectedId = file.rooms[0].id
        selectedKey = nil
        clearHistory()
        markDirty()
        recompute()
    }

    private func clearHistory() { undoStack.removeAll(); redoStack.removeAll() }

    // MARK: Sketch

    func addWall(a: RoomPoint, b: RoomPoint) {
        guard a.distance(to: b) >= 0.02 else { return }
        edit { $0.walls.append(RoomWall(a: a, b: b)) }
    }

    func addRectangle(a: RoomPoint, b: RoomPoint) {
        guard abs(a.x - b.x) >= 0.05, abs(a.y - b.y) >= 0.05 else { return }
        let c = RoomPoint(x: b.x, y: a.y), d = RoomPoint(x: a.x, y: b.y)
        edit { p in
            p.walls += [RoomWall(a: a, b: c), RoomWall(a: c, b: b), RoomWall(a: b, b: d), RoomWall(a: d, b: a)]
        }
    }

    func removeWall(id: String) {
        edit { $0.walls.removeAll { $0.id == id } }
        if selectedWallId == id { selectedWallId = nil }
    }

    /// Make a wall exactly `meters` long (see RoomPlan.setWallLength).
    func setWallLength(id: String, meters: Double) {
        guard meters >= 0.01, meters <= 1_000, plan.walls.contains(where: { $0.id == id }) else { return }
        edit { $0.setWallLength(id: id, meters: meters) }
    }

    func moveWallEnd(id: String, end: Int, to pos: RoomPoint) {
        edit { p in
            guard let i = p.walls.firstIndex(where: { $0.id == id }) else { return }
            if end == 0 { p.walls[i].a = pos } else { p.walls[i].b = pos }
        }
    }

    // MARK: Mac

    /// The operator carried the Mac to `pos` on the plan.
    func moveLaptop(to pos: RoomPoint) {
        edit { $0.moveLaptop(to: pos) }
    }

    func setPathLossN(_ n: Double) {
        var p = plan
        p.pathLossN = n.coerceIn(1.4, 4.5)
        plan = p
        recompute()
    }

    func clearReadings() {
        edit { p in
            let keep = p.spotId
            for i in p.devices.indices { p.devices[i].readings.removeAll() }
            p.spots = p.spots.filter { $0.id == keep }
        }
    }

    // MARK: Radios

    /// Radios heard now that are not in the room yet, loudest first.
    func candidates(query: String) -> [Sighting] {
        let inRoom = Set(plan.devices.map { $0.key })
        let q = query.trim().lowercased()
        return vm.ui.devices
            .filter { !$0.gone && !inRoom.contains($0.key) }
            .filter { q.isEmpty || label(for: $0).lowercased().contains(q) || $0.mac.lowercased().contains(q) }
            .sortedByDescending { $0.rssi }
    }

    func label(for d: Sighting) -> String {
        if let custom = vm.watchLabelFor(deviceKey: d.key)?.trim(), custom.isNotEmpty { return custom }
        return d.listTitle(signatureNames: d.fleetIds.map { vm.fleetName(id: $0) })
    }

    func sighting(key: String) -> Sighting? { vm.ui.devices.first { $0.key == key } }

    /// Palette index (not a colour) of a signature, as on Live.
    func fleetColor(id: String) -> Int { vm.fleetColor(id: id) }

    /// Put a radio in the room. It lands pinned at its rough distance on a free bearing; drag it to where it is.
    func add(_ d: Sighting) {
        guard plan.device(key: d.key) == nil else { selectedKey = d.key; return }
        let p = plan
        let n = Double(p.devices.count)
        let angle = n * 2.39996   // golden angle spreads new radios around the Mac
        var dev = RoomDevice(key: d.key, label: label(for: d), kind: d.kind, pos: p.laptop, mode: .pinned)
        let model = RoomModel.of(device: dev, roomN: p.pathLossN, txPowerDbm: d.facts.txPowerDbm)
        let s = RoomTracker.smoothed(history: d.rssiHistory, now: nowMs(), windowMs: RoomTracker.windowMs(kind: d.kind))
        let dist = s.map { model.distance(rssi: $0.rssi) }?.coerceIn(0.5, 30) ?? 3
        dev.pos = p.laptop + RoomPoint(x: cos(angle), y: sin(angle)) * dist
        edit { $0.devices.append(dev) }
        selectedKey = d.key
    }

    /// Put a radio connected to this Mac in the room (signal read over its connection).
    func addConnected(_ r: ConnectedRadio) {
        guard plan.device(key: r.id) == nil else { selectedKey = r.id; return }
        ConnectedDevices.shared.start()
        let p = plan
        let angle = Double(p.devices.count) * 2.39996
        var dev = RoomDevice(key: r.id, label: r.name, kind: .ble, pos: p.laptop, mode: .pinned)
        let model = RoomModel.of(device: dev, roomN: p.pathLossN)
        let dist = r.rssi.map { model.distance(rssi: Double($0)) }?.coerceIn(0.5, 30) ?? 2
        dev.pos = p.laptop + RoomPoint(x: cos(angle), y: sin(angle)) * dist
        edit { $0.devices.append(dev) }
        selectedKey = r.id
    }

    /// Signal history for a room radio: advertisements, or the connection for radios connected to this Mac.
    func history(key: String) -> (history: [RssiSample], kind: RadioKind)? {
        if key.hasPrefix(ConnectedDevices.KEY_PREFIX) { return (ConnectedDevices.shared.history(key: key), .ble) }
        guard let d = sighting(key: key) else { return nil }
        return (d.rssiHistory, d.kind)
    }

    func remove(key: String) {
        edit { $0.devices.removeAll { $0.key == key } }
        if selectedKey == key { selectedKey = nil }
    }

    func moveDevice(key: String, to pos: RoomPoint) {
        edit { p in
            guard let i = p.devices.firstIndex(where: { $0.key == key }) else { return }
            p.devices[i].pos = pos
        }
    }

    func setMode(key: String, mode: RoomDevice.Mode) {
        edit { p in
            guard let i = p.devices.firstIndex(where: { $0.key == key }) else { return }
            // Switching to pinned keeps the radio where it is drawn now.
            if mode == .pinned, let t = tracks[key] { p.devices[i].pos = t.pos }
            p.devices[i].mode = mode
        }
    }

    /// The name to show for a room radio: your name for it (Named radios / Connected), else what it advertised.
    func displayName(_ d: RoomDevice) -> String {
        if d.key.hasPrefix(ConnectedDevices.KEY_PREFIX) {
            return ConnectedDevices.shared.customNames[d.key] ?? ConnectedDevices.shared.radio(key: d.key)?.name ?? d.label
        }
        if let custom = vm.watchLabelFor(deviceKey: d.key)?.trim(), custom.isNotEmpty { return custom }
        return d.label
    }

    /// Give a radio a name. It becomes a Named radio, so Live, Map, Room and reports all use it.
    func rename(key: String, label: String) {
        let l = label.trim()
        guard l.isNotEmpty else { return }
        if key.hasPrefix(ConnectedDevices.KEY_PREFIX) {
            ConnectedDevices.shared.setName(key: key, name: l)
        } else if let s = sighting(key: key) {
            vm.saveRadioName(device: s, name: l)
        } else if vm.watchLabelFor(deviceKey: key) != nil,
                  let id = vm.ui.watchlist.first(where: { $0.deviceKey == key })?.id {
            vm.renameRadioBookmark(id: id, name: l)
        }
        edit { p in
            guard let i = p.devices.firstIndex(where: { $0.key == key }) else { return }
            p.devices[i].label = l
        }
    }

    enum CalibrationError: Error { case notHeard, badDistance }

    /// "This radio is `meters` from the Mac." Uses the loudness smoothed over the last seconds.
    @discardableResult
    func identify(key: String, meters: Double) -> Result<Void, CalibrationError> {
        guard meters >= 0.1, meters <= 300 else { return .failure(.badDistance) }
        guard let s = live[key] else { return .failure(.notHeard) }
        let p0 = plan
        edit { p in
            guard let i = p.devices.firstIndex(where: { $0.key == key }) else { return }
            p.devices[i].calibrations.append(RoomCalibration(distanceM: meters, rssi: s.rssi, at: nowMs(), spotId: p0.spotId))
            if p.devices[i].calibrations.count > 6 { p.devices[i].calibrations.removeFirst() }
            p.devices[i].referenceDistanceM = meters
            p.devices[i].referenceSpotId = p0.spotId
            // Keep the bearing, put the radio at the stated distance.
            let dir = p.devices[i].pos - p.laptop
            let unit = dir.length > 1e-6 ? dir * (1 / dir.length) : RoomPoint(x: 1, y: 0)
            p.devices[i].pos = p.laptop + unit * meters
        }
        return .success(())
    }

    func removeCalibration(key: String, index: Int) {
        edit { p in
            guard let i = p.devices.firstIndex(where: { $0.key == key }), p.devices[i].calibrations.indices.contains(index) else { return }
            p.devices[i].calibrations.remove(at: index)
            if p.devices[i].calibrations.isEmpty { p.devices[i].referenceDistanceM = nil }
        }
    }

    /// Accept the measured distance as the new normal (clears the moved warning).
    func acceptMove(key: String) {
        guard let t = tracks[key] else { return }
        let spot = plan.spotId
        edit { p in
            guard let i = p.devices.firstIndex(where: { $0.key == key }) else { return }
            p.devices[i].referenceDistanceM = t.distanceM
            p.devices[i].referenceSpotId = spot
            if p.devices[i].mode == .pinned { p.devices[i].pos = t.pos }
        }
    }

    func openDetail(key: String) -> Sighting? { sighting(key: key) }

    // MARK: Tick

    private func tick() {
        let now = nowMs()
        var p = plan
        var nextLive: [String: (rssi: Double, spread: Double, count: Int)] = [:]
        var changed = false
        for i in p.devices.indices {
            let key = p.devices[i].key
            guard let h = history(key: key),
                  let s = RoomTracker.smoothed(history: h.history, now: now, windowMs: RoomTracker.windowMs(kind: h.kind))
            else { continue }
            nextLive[key] = s
            RoomTracker.record(device: &p.devices[i], spotId: p.spotId, rssi: s.rssi, spread: s.spread, count: s.count, now: now)
            changed = true
        }
        live = nextLive
        if changed {
            // Readings are bookkeeping, not an edit: no undo entry; saved with the next debounce.
            let id = p.id
            if let i = file.rooms.firstIndex(where: { $0.id == id }) { file.rooms[i] = p }
            if dirtyAt == nil { dirtyAt = now }
        }
        recompute(now: now)
        if let at = dirtyAt, now - at >= 5_000 { flush() }
    }

    private func recompute(now: Int = nowMs()) {
        let p = plan
        var next: [String: RoomTrack] = [:]
        for dev in p.devices {
            let tx = sighting(key: dev.key)?.facts.txPowerDbm
            if let t = RoomTracker.track(device: dev, plan: p, live: live[dev.key], txPowerDbm: tx, now: now) {
                next[dev.key] = t
            }
        }
        tracks = next
    }

    private func markDirty() {
        if dirtyAt == nil { dirtyAt = nowMs() }
    }

    func flush() {
        dirtyAt = nil
        store.save(file)
    }
}

/// Distances in the operator's locale with one decimal (4,5 m in Dutch).
enum RoomFormat {
    static func meters(_ m: Double) -> String {
        if m >= 100 { return "\(Int(m.rounded())) m" }
        return m.formatted(.number.precision(.fractionLength(1))) + " m"
    }

    /// Drawn lengths (walls, ruler) are exact, so show centimeters: 6,35 m.
    static func length(_ m: Double) -> String {
        if m >= 100 { return m.formatted(.number.precision(.fractionLength(1))) + " m" }
        return m.formatted(.number.precision(.fractionLength(2))) + " m"
    }

    static func band(_ t: RoomTrack) -> String {
        "\(meters(t.distanceM)) (\(meters(t.lowM).replace(" m", ""))–\(meters(t.highM)))"
    }

    /// Parse "4,5", "4.5", "4,5 m", "45 cm".
    static func parseMeters(_ text: String) -> Double? {
        var t = text.trim().lowercased()
        var factor = 1.0
        if t.hasSuffix("cm") { factor = 0.01; t = String(t.dropLast(2)) }
        else if t.hasSuffix("m") { t = String(t.dropLast(1)) }
        t = t.trim().replace(",", ".")
        guard let v = Double(t), v.isFinite else { return nil }
        return v * factor
    }
}
