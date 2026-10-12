import Foundation

// Port of data/LogStore.kt. Rotating JSON-lines log under `FieldwatchPaths.root/logs`
// (fieldwatch-000.jsonl … fieldwatch-011.jsonl), exported as CSV or JSONL.
// Android shared files through a FileProvider; on macOS the store exposes plain file URLs
// (`currentFile()`, `logParts()`, `exportBundle(...)`) for Reveal in Finder or a share sheet.
// Suspend funcs are synchronous: call them off the main thread. `mutex` serialises file IO (Kotlin Mutex).

public final class LogStore: @unchecked Sendable {
    private let dir: URL
    private let mutex = NSLock()
    /// Guards generation / paused / enabled / logFormat / rotateBytes / lines (Kotlin atomics and @Volatile).
    private let state = NSLock()
    private var generation = 0
    private var paused = false
    private var writer: FileHandle?
    private var writerPath: String?
    /// Bytes waiting in our 32 KB buffer (Kotlin BufferedWriter).
    private var buffer = Data()
    /// Bytes on disk for the open part (Kotlin `file.length()` — excludes `buffer`).
    private var writerDiskBytes = 0
    private var unflushed = 0
    private var index = 0
    private var logFormat: LogFormat = .csv
    private var rotateBytes = 1024 * 1024
    private var lines = 0
    private var enabled = true
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    public init() {
        dir = FieldwatchPaths.dir("logs")
    }

    public var lineCount: Int { state.lock(); defer { state.unlock() }; return lines }
    public var isPaused: Bool { state.lock(); defer { state.unlock() }; return paused }

    /// The format argument is ignored: the live log is always JSON lines (CSV is an export choice).
    public func configure(format: LogFormat, rotateKb: Int, loggingOn: Bool? = nil) {
        state.lock(); defer { state.unlock() }
        self.logFormat = .json
        self.rotateBytes = rotateKb.coerceAtLeast(64) * 1024
        if let loggingOn { enabled = loggingOn }
    }

    @discardableResult
    public func append(device: Sighting, fleets: [Fleet]) -> Int {
        state.lock()
        let skip = !enabled || paused
        let gen = generation
        state.unlock()
        if skip { return lineCount }
        let names = fleets.filter { device.fleetIds.contains($0.id) }.map { $0.name }.joined(separator: "+")
        let row = jsonLine(device, names)
        mutex.lock(); defer { mutex.unlock() }
        state.lock()
        let stale = paused || generation != gen
        state.unlock()
        if stale { return lineCount }
        guard ensureWriter() else { return lineCount }
        buffer.append(contentsOf: Array(row.utf8))
        if buffer.count >= 32 * 1024 { writeBuffer() }
        unflushed += 1
        if unflushed >= 16 {
            writeBuffer()
            unflushed = 0
        }
        state.lock()
        lines += 1
        let n = lines
        state.unlock()
        rotateIfNeeded()
        return n
    }

    public func currentFile() -> URL { dir.appendingPathComponent("fieldwatch-\(format("%03d", index)).jsonl") }

    public func logParts() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return items.filter { url in
            let name = url.lastPathComponent
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            return isFile && name.hasPrefix("fieldwatch-") && !name.contains("export")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func allFiles() -> [URL] { logParts() }

    public func totalBytes() -> Int { logParts().sumOf { LogStore.fileLength($0) } }

    /// Unique radios from every rotating part. Re-match; ignore write-time fleets.
    public func readRadios(onProgress: (_ copied: Int, _ total: Int) -> Void = { _, _ in }) -> [LogRadio] {
        mutex.lock(); defer { mutex.unlock() }
        flushWriter()
        let parts = logParts()
        let total = parts.sumOf { LogStore.fileLength($0) }.coerceAtLeast(1)
        var copied = 0
        var lastEmit = 0
        // Kotlin used a LinkedHashMap; keep first-seen order next to the dictionary.
        var acc: [String: LogRadio] = [:]
        var order: [String] = []
        var known = Set<String>()
        onProgress(0, total)
        for file in parts {
            guard LogStore.fileLength(file) > 0, let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let name = file.lastPathComponent
            let json = name.hasSuffix(".jsonl") || name.hasSuffix(".json")
            for line in text.lines() {
                copied += line.utf8.count + 1
                LogReplay.ingest(lines: [line], json: json, acc: &acc)
                if acc.count > known.count {
                    for k in acc.keys where !known.contains(k) {
                        known.insert(k)
                        order.append(k)
                    }
                }
                if copied - lastEmit >= 48 * 1024 {
                    lastEmit = copied
                    onProgress(copied.coerceAtMost(total), total)
                }
            }
        }
        onProgress(total, total)
        return order.compactMap { acc[$0] }
    }

    public func exportExtension(asJsonl: Bool = false) -> String { asJsonl ? "jsonl" : "csv" }

    public func exportMime(asJsonl: Bool = false) -> String { asJsonl ? "application/json" : "text/csv" }

    public func suggestedExportName(asJsonl: Bool = false) -> String {
        let stamp = formatMs(nowMs(), "yyyyMMdd-HHmmss")
        return "fieldwatch-log-\(stamp).\(exportExtension(asJsonl: asJsonl))"
    }

    /// Writes an export next to the logs and returns its URL (Kotlin returned the File for FileProvider).
    public func exportBundle(
        asJsonl: Bool = false,
        radios: LogExportRadios = .both,
        onProgress: (_ copied: Int, _ total: Int) -> Void = { _, _ in }
    ) throws -> URL {
        try withLoggingPaused {
            mutex.lock(); defer { mutex.unlock() }
            flushWriter()
            let out = dir.appendingPathComponent("fieldwatch-export-\(nowMs()).\(exportExtension(asJsonl: asJsonl))")
            try writeExport(to: out, asJsonl: asJsonl, radios: radios, onProgress: onProgress)
            return out
        }
    }

    /// Android `exportToUri(resolver, uri, …)`: on macOS the destination is a file URL (e.g. from NSSavePanel).
    public func exportToUri(
        uri: URL,
        asJsonl: Bool = false,
        radios: LogExportRadios = .both,
        onProgress: (_ copied: Int, _ total: Int) -> Void = { _, _ in }
    ) throws {
        try withLoggingPaused {
            mutex.lock(); defer { mutex.unlock() }
            flushWriter()
            try writeExport(to: uri, asJsonl: asJsonl, radios: radios, onProgress: onProgress)
        }
    }

    private func withLoggingPaused<T>(_ block: () throws -> T) rethrows -> T {
        state.lock(); paused = true; state.unlock()
        defer { state.lock(); paused = false; state.unlock() }
        return try block()
    }

    private func writeExport(
        to dest: URL,
        asJsonl: Bool,
        radios: LogExportRadios,
        onProgress: (_ copied: Int, _ total: Int) -> Void
    ) throws {
        let parts = logParts()
        let total = parts.sumOf { LogStore.fileLength($0) }.coerceAtLeast(1)
        var copied = 0
        var lastEmit = 0
        func emit(force: Bool = false) {
            if force || copied - lastEmit >= 48 * 1024 {
                lastEmit = copied
                onProgress(copied.coerceAtMost(total), total)
            }
        }
        onProgress(0, total)
        if !FileManager.default.createFile(atPath: dest.path, contents: nil) {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: dest.path])
        }
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }
        var pending = Data()
        func put(_ s: String) throws {
            pending.append(contentsOf: Array(s.utf8))
            if pending.count >= 64 * 1024 {
                try handle.write(contentsOf: pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
        if !asJsonl { try put(LogStore.CSV_HEADER) }
        for src in parts {
            guard LogStore.fileLength(src) > 0, let text = try? String(contentsOf: src, encoding: .utf8) else { continue }
            let name = src.lastPathComponent
            let fromJson = name.hasSuffix(".jsonl") || name.hasSuffix(".json")
            var header = LogReplay.DEFAULT_CSV_HEADER
            for raw in text.lines() {
                let line = raw  // lines() already split on \r (Kotlin trimEnd('\r'))
                if line.isBlank { continue }
                copied += line.utf8.count + 1
                emit()
                if !fromJson && line.hasPrefix("timestamp") {
                    header = line.split(",")
                    continue
                }
                guard let kind = LogReplay.lineKind(line: line, json: fromJson, header: header), radios.matches(kind: kind) else { continue }
                let out: String
                if asJsonl && fromJson {
                    out = line
                } else if asJsonl && !fromJson {
                    guard let j = LogReplay.csvRowToJson(line: line, header: header) else { continue }
                    out = j
                } else if !asJsonl && fromJson {
                    guard let c = LogReplay.jsonRowToCsv(line: line) else { continue }
                    out = c
                } else {
                    out = line
                }
                try put(out)
                try put("\n")
            }
        }
        if !pending.isEmpty { try handle.write(contentsOf: pending) }
        emit(force: true)
        onProgress(total, total)
    }

    @discardableResult
    public func clear() -> Int {
        state.lock(); generation += 1; state.unlock()
        mutex.lock(); defer { mutex.unlock() }
        closeWriter()
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for u in items { try? FileManager.default.removeItem(at: u) }
        index = 0
        state.lock(); lines = 0; generation += 1; state.unlock()
        return 0
    }

    // MARK: - Writer (caller holds `mutex`)

    /// Opens the current part for appending. False if the file cannot be opened (the line is dropped).
    private func ensureWriter() -> Bool {
        let file = currentFile()
        let path = file.path
        if writer != nil && writerPath == path { return true }
        closeWriter()
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: file) else { return false }
        let end = (try? h.seekToEnd()).map { Int($0) } ?? 0
        writer = h
        writerPath = path
        writerDiskBytes = end
        return true
    }

    private func writeBuffer() {
        guard let w = writer, !buffer.isEmpty else { return }
        if (try? w.write(contentsOf: buffer)) != nil { writerDiskBytes += buffer.count }
        buffer.removeAll(keepingCapacity: true)
    }

    private func flushWriter() {
        writeBuffer()
        unflushed = 0
    }

    private func closeWriter() {
        writeBuffer()
        try? writer?.close()
        writer = nil
        writerPath = nil
        buffer.removeAll(keepingCapacity: true)
        unflushed = 0
    }

    private func rotateIfNeeded() {
        let rotate: Int
        state.lock(); rotate = rotateBytes; state.unlock()
        let diskLength = writer != nil && writerPath == currentFile().path ? writerDiskBytes : LogStore.fileLength(currentFile())
        if diskLength < rotate { return }
        closeWriter()
        index = (index + 1) % 12
        let next = currentFile()
        if FileManager.default.fileExists(atPath: next.path) { try? FileManager.default.removeItem(at: next) }
    }

    private static func fileLength(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    // MARK: - Rows

    /// CSV row with the export header's columns. Kept for parity; the live log writes JSON lines.
    private func csvLine(_ device: Sighting, _ names: String) -> String {
        func esc(_ v: String) -> String { CsvCells.plain(s: v) }
        var flags = ""
        if device.randomized { flags += "RAND " }
        if device.hiddenSsid { flags += "HIDDEN " }
        return [
            String(device.lastSeen),
            LogStore.isoFormatter.string(from: Date(timeIntervalSince1970: Double(device.lastSeen) / 1000.0)),
            device.kind.rawValue,
            device.mac,
            esc(device.name),
            String(device.rssi),
            String(device.channel),
            String(device.frequencyMhz),
            device.oui,
            esc(device.vendor ?? ""),
            esc(names),
            device.manufacturerId.map { String($0, radix: 16).uppercased() } ?? "",
            device.serviceUuids.joined(separator: "|"),
            flags.trim(),
            device.manufacturerDataHex.ifBlank(device.rawHex).take(80),
            device.latitude.map { fmt($0, 6) } ?? "",
            device.longitude.map { fmt($0, 6) } ?? "",
            device.vendorIeOuis.take(8).map { MacUtil.normalize(raw: $0) }.joined(separator: "|"),
        ].joined(separator: ",") + "\n"
    }

    /// One JSON object per line, keys in Android org.json insertion order. Null vendor / mfg are omitted
    /// (JSONObject.put(name, null) removes the key); lat / lon write an explicit null.
    private func jsonLine(_ device: Sighting, _ names: String) -> String {
        var s = "{"
        var first = true
        func key(_ k: String) {
            if !first { s += "," }
            first = false
            s += "\"\(k)\":"
        }
        func str(_ k: String, _ v: String) { key(k); s += LogStore.jsonQuote(v) }
        func int(_ k: String, _ v: Int) { key(k); s += String(v) }
        func bool(_ k: String, _ v: Bool) { key(k); s += v ? "true" : "false" }
        func dbl(_ k: String, _ v: Double?) { key(k); s += v.map { LogStore.jsonNumber($0) } ?? "null" }
        int("ts", device.lastSeen)
        str("iso", LogStore.isoFormatter.string(from: Date(timeIntervalSince1970: Double(device.lastSeen) / 1000.0)))
        str("kind", device.kind.rawValue)
        str("mac", device.mac)
        str("name", device.name)
        int("rssi", device.rssi)
        int("channel", device.channel)
        int("freq", device.frequencyMhz)
        str("oui", device.oui)
        if let v = device.vendor { str("vendor", v) }
        str("fleets", names)
        if let m = device.manufacturerId { int("mfg", m) }
        str("uuids", device.serviceUuids.joined(separator: ","))
        str("raw", device.manufacturerDataHex.ifBlank(device.rawHex).take(160))
        str("vendor_ie", device.vendorIeOuis.take(8).map { MacUtil.normalize(raw: $0) }.joined(separator: "|"))
        bool("rand", device.randomized)
        bool("hidden", device.hiddenSsid)
        dbl("lat", device.latitude)
        dbl("lon", device.longitude)
        s += "}\n"
        return s
    }

    /// Android JSONStringer escaping (also escapes '/').
    private static func jsonQuote(_ v: String) -> String {
        var out = "\""
        for u in v.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "/": out += "\\/"
            case "\t": out += "\\t"
            case "\u{8}": out += "\\b"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\u{C}": out += "\\f"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if u.value <= 0x1F {
                    out += "\\u" + String(u.value, radix: 16).padStart(4, "0")
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
        return out
    }

    /// org.json number style: integral doubles print without a fraction.
    private static func jsonNumber(_ d: Double) -> String {
        if !d.isFinite { return "null" }
        if d == d.rounded(.towardZero) && abs(d) < 9.0e15 { return String(Int(d)) }
        return "\(d)"
    }

    private static let CSV_HEADER =
        "timestamp,iso,kind,mac,name,rssi,channel,freq,oui,vendor,fleets,mfg,uuids,flags,raw,lat,lon,vendor_ie\n"
}
