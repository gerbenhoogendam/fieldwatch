import Foundation

// Port of data/SitStore.kt. Sit files live in `FieldwatchPaths.root/sits/<id>.json`.
// Android took a CoroutineScope for the flusher; here `startFlusher()` runs a DispatchSourceTimer
// every `Sit.FLUSH_MS` on a private utility queue. Suspend funcs are synchronous.
// Locks: `mutex` serialises file writes (Kotlin Mutex); `lock` guards in-memory state (Kotlin synchronized).
// `ui` observers fire while `lock` is held (it is recursive, so they may call select / consumeNotice).
// Android's ActivityManager low-memory check → a DispatchSource memory-pressure monitor (warning / critical).

public final class SitStore: @unchecked Sendable {
    private let dir: URL
    private var memoryTightFlag = false
    private let mutex = NSRecursiveLock()
    private let lock = NSRecursiveLock()
    private var open: SitSession?
    private var closed: [SitSummary] = []
    private var selectedId: String?
    private var compareId: String?
    private let _ui = MutableStateFlow(SitUi())
    public var ui: StateFlow<SitUi> { _ui }

    private let queue = DispatchQueue(label: "app.fieldwatch.sitstore", qos: .utility)
    private var flusher: DispatchSourceTimer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var systemTight = false

    public init() {
        dir = FieldwatchPaths.dir("sits")
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let ev = src.data
            self.lock.lock()
            self.systemTight = ev.contains(.warning) || ev.contains(.critical)
            self.lock.unlock()
        }
        src.resume()
        pressureSource = src
    }

    deinit {
        flusher?.cancel()
        pressureSource?.cancel()
    }

    /// Flush the open sit every `Sit.FLUSH_MS`. Calling again restarts the timer.
    public func startFlusher() {
        lock.lock(); defer { lock.unlock() }
        flusher?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let ms = Sit.FLUSH_MS
        t.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms))
        t.setEventHandler { [weak self] in self?.flushOpen() }
        t.resume()
        flusher = t
    }

    /// macOS addition: stop the periodic flush (Android cancelled the scope).
    public func stopFlusher() {
        lock.lock(); defer { lock.unlock() }
        flusher?.cancel()
        flusher = nil
    }

    public func load() {
        mutex.lock(); defer { mutex.unlock() }
        let files = sitFiles()
        var opened: [SitFile] = []
        var closedAcc: [SitSummary] = []
        let dec = JSONDecoder()
        for file in files {
            guard let data = try? Data(contentsOf: file), let parsed = try? dec.decode(SitFile.self, from: data) else { continue }
            if parsed.format != Sit.FORMAT && parsed.format.isNotBlank { continue }
            if parsed.summary.open { opened.append(parsed) } else { closedAcc.append(parsed.summary) }
        }
        let keepOpen = opened.maxByOrNull { $0.summary.startAt }
        for extra in opened where extra.summary.id != keepOpen?.summary.id {
            try? FileManager.default.removeItem(at: fileFor(id: extra.summary.id))
        }
        lock.lock(); defer { lock.unlock() }
        open = keepOpen.map {
            SitSession(summary: $0.summary, radios: $0.radios, path: $0.operatorPath, floods: $0.floods, gnss: $0.gnss)
        }
        closed = closedAcc.sortedByDescending { $0.startAt }
        _ = pruneClosedLocked()
        compareId = SitDiff.defaultSecondSitId(closed: closed, thisSavedId: SitDiff.thisSavedId(open: open?.summary, selectedId: selectedId))
        publishLocked()
    }

    public func ingest(seen: [Sighting], fleets: [Fleet], watchlist: [WatchTarget]) {
        if seen.isEmpty { return }
        lock.lock()
        let session = open
        lock.unlock()
        guard let session else { return }
        let watchKeys = Set(RadioBookmarks.radios(watchlist: watchlist).compactMap { $0.deviceKey })
        let watchedFleets = RadioBookmarks.watchedFleetIds(watchlist: watchlist)
        let tight = memoryTight()
        lock.lock(); defer { lock.unlock() }
        if open !== session { return }
        memoryTightFlag = tight
        for device in seen {
            _ = session.ingest(device: device, fleets: fleets, watchDeviceKeys: watchKeys, watchedFleetIds: watchedFleets, tight: tight)
        }
        publishLocked()
    }

    public func noteFloods(incoming: [FloodBurst]) {
        if incoming.isEmpty { return }
        lock.lock(); defer { lock.unlock() }
        open?.noteFloods(incoming: incoming)
    }

    public func noteGnss(incoming: [GnssMark]) {
        if incoming.isEmpty { return }
        lock.lock(); defer { lock.unlock() }
        open?.noteGnss(incoming: incoming)
    }

    public func recordPath(lat: Double, lon: Double, at: Int) {
        lock.lock(); defer { lock.unlock() }
        _ = open?.recordPath(lat: lat, lon: lon, at: at)
    }

    @discardableResult
    public func start(
        name: String,
        heard: [Sighting],
        fleets: [Fleet],
        watchlist: [WatchTarget],
        now: Int = nowMs()
    ) -> SitSummary? {
        mutex.lock(); defer { mutex.unlock() }
        lock.lock()
        let busy = open != nil
        lock.unlock()
        if busy { return nil }
        let watchKeys = Set(RadioBookmarks.radios(watchlist: watchlist).compactMap { $0.deviceKey })
        let watchedFleets = RadioBookmarks.watchedFleetIds(watchlist: watchlist)
        let session = SitSession.start(
            name: name,
            now: now,
            heard: heard,
            fleets: fleets,
            watchDeviceKeys: watchKeys,
            watchedFleetIds: watchedFleets
        )
        lock.lock()
        open = session
        selectedId = nil
        publishLocked()
        lock.unlock()
        writeSession(session, fleets: fleets)
        return session.summary
    }

    @discardableResult
    public func end(fleets: [Fleet], now: Int = nowMs()) -> SitSummary? {
        mutex.lock(); defer { mutex.unlock() }
        lock.lock()
        let current = open
        lock.unlock()
        guard let session = current else { return nil }
        let file = session.end(now: now, fleets: fleets)
        writeFile(file)
        lock.lock(); defer { lock.unlock() }
        open = nil
        closed = ([file.summary] + closed).sortedByDescending { $0.startAt }
        selectedId = file.summary.id
        let dropped = pruneClosedLocked()
        let notice = dropped.map { "Dropped oldest sit “\($0)” (keep \(Sit.CLOSED_CAP))." }
        publishLocked(notice: notice)
        return file.summary
    }

    @discardableResult
    public func rename(id: String, raw: String) -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        let next = Sit.clipName(raw: raw)
        if next.isEmpty { return false }
        lock.lock()
        let session = open
        lock.unlock()
        if let session, session.summary.id == id {
            if !session.rename(raw: raw) { return false }
            writeSession(session, fleets: [])
            lock.lock(); publishLocked(); lock.unlock()
            return true
        }
        lock.lock()
        let row = closed.first { $0.id == id }
        lock.unlock()
        guard let row else { return false }
        if row.name == next { return false }
        guard let file = readFileBlocking(id: id) else { return false }
        var updated = file
        updated.summary.name = next
        writeFile(updated)
        lock.lock(); defer { lock.unlock() }
        closed = closed.map { s in
            if s.id != id { return s }
            var c = s
            c.name = next
            return c
        }
        publishLocked()
        return true
    }

    public func delete(id: String) {
        mutex.lock(); defer { mutex.unlock() }
        lock.lock()
        let session = open
        lock.unlock()
        if let session, session.summary.id == id { return }
        try? FileManager.default.removeItem(at: fileFor(id: id))
        lock.lock(); defer { lock.unlock() }
        closed = closed.filter { $0.id != id }
        if selectedId == id { selectedId = nil }
        publishLocked()
    }

    public func deleteAllClosed() {
        mutex.lock(); defer { mutex.unlock() }
        lock.lock()
        let ids = closed.map { $0.id }
        lock.unlock()
        for id in ids { try? FileManager.default.removeItem(at: fileFor(id: id)) }
        lock.lock(); defer { lock.unlock() }
        closed = []
        if selectedId != nil && open?.summary.id != selectedId { selectedId = nil }
        publishLocked()
    }

    public func select(id: String?) {
        lock.lock(); defer { lock.unlock() }
        if id == nil {
            selectedId = nil
        } else if open?.summary.id == id {
            selectedId = id
        } else if closed.contains(where: { $0.id == id }) {
            selectedId = id
        } else {
            selectedId = nil
        }
        publishLocked()
    }

    public func selectCompare(id: String?) {
        lock.lock(); defer { lock.unlock() }
        let thisSaved = SitDiff.thisSavedId(open: open?.summary, selectedId: selectedId)
        let choices = SitDiff.secondSitChoices(closed: closed, thisSavedId: thisSaved)
        compareId = id.flatMap { picked in choices.contains { $0.id == picked } ? picked : nil }
        publishLocked()
    }

    public func sitFile(id: String) -> SitFile? { readFileBlocking(id: id) }

    public func consumeNotice() {
        lock.lock(); defer { lock.unlock() }
        publishLocked(notice: nil)
    }

    public func debriefSource(now: Int = nowMs()) -> SitDebrief? {
        lock.lock()
        if let session = open {
            let snap = session.snapshot()
            lock.unlock()
            return SitDebrief(
                name: snap.summary.name,
                startAt: snap.summary.startAt,
                endAt: now,
                devices: snap.radios.map { $0.toSighting() },
                operatorPath: snap.operatorPath,
                floods: snap.floods,
                gnss: snap.gnss
            )
        }
        let id = selectedId
        lock.unlock()
        guard let id, let file = readFileBlocking(id: id) else { return nil }
        let end = file.summary.endAt ?? now
        return SitDebrief(
            name: file.summary.name,
            startAt: file.summary.startAt,
            endAt: end,
            devices: file.radios.map { $0.toSighting() },
            operatorPath: file.operatorPath,
            floods: file.floods,
            gnss: file.gnss
        )
    }

    public func flushOpen() {
        mutex.lock(); defer { mutex.unlock() }
        lock.lock()
        let session = open
        lock.unlock()
        guard let session, session.dirty else { return }
        writeSession(session, fleets: [])
    }

    // MARK: - Files (caller holds `mutex`)

    private func writeSession(_ session: SitSession, fleets: [Fleet]) {
        lock.lock()
        let file = session.snapshot(fleets: fleets)
        lock.unlock()
        writeFile(file)
        lock.lock()
        session.markClean()
        lock.unlock()
    }

    private func writeFile(_ file: SitFile) {
        let enc = JSONEncoder()
        // .sortedKeys: JSONEncoder writes object keys (and dictionary keys like `enum`) in per-launch hash
        // order otherwise. Kotlin wrote a fixed order; sorted keeps the file the same every run.
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        guard let data = try? enc.encode(file) else { return }
        try? data.write(to: fileFor(id: file.summary.id), options: .atomic)
    }

    private func readFileBlocking(id: String) -> SitFile? {
        let dest = fileFor(id: id)
        guard FileManager.default.fileExists(atPath: dest.path), let data = try? Data(contentsOf: dest) else { return nil }
        return try? JSONDecoder().decode(SitFile.self, from: data)
    }

    private func fileFor(id: String) -> URL { dir.appendingPathComponent("\(id).json") }

    private func sitFiles() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return items.filter { url in
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            return isFile && url.lastPathComponent.hasSuffix(".json")
        }
    }

    // MARK: - State (caller holds `lock`)

    private func pruneClosedLocked() -> String? {
        if closed.count <= Sit.CLOSED_CAP { return nil }
        let drop = closed.drop(Sit.CLOSED_CAP)
        closed = closed.take(Sit.CLOSED_CAP)
        for row in drop {
            try? FileManager.default.removeItem(at: fileFor(id: row.id))
            if selectedId == row.id { selectedId = nil }
        }
        return drop.last?.name
    }

    /// Kotlin default `notice = _ui.value.notice` keeps the pending notice.
    private func publishLocked() { publishLocked(notice: _ui.value.notice) }

    private func publishLocked(notice: String?) {
        let session = open
        let thisSaved = SitDiff.thisSavedId(open: session?.summary, selectedId: selectedId)
        let choices = SitDiff.secondSitChoices(closed: closed, thisSavedId: thisSaved)
        if compareId == nil || choices.none({ $0.id == compareId }) {
            compareId = SitDiff.defaultSecondSitId(closed: closed, thisSavedId: thisSaved)
        }
        _ui.value = SitUi(
            open: session?.summary,
            radioCount: session?.radioCount ?? 0,
            atCap: session?.atCap ?? false,
            memoryTight: memoryTightFlag,
            closed: closed,
            selectedId: selectedId,
            compareId: compareId,
            notice: notice
        )
    }

    private func memoryTight() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return systemTight
    }
}
