import Foundation

// macOS addition: sketched rooms (RoomPlan) saved as rooms.json under FieldwatchPaths.root.

public struct RoomFile: Codable, Sendable {
    public var format: String = "fieldwatch-rooms"
    public var version: Int = 1
    public var selectedId: String?
    public var rooms: [RoomPlan] = []
    public init(selectedId: String? = nil, rooms: [RoomPlan] = []) { self.selectedId = selectedId; self.rooms = rooms }
}

public final class RoomStore: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL

    public init(url: URL = FieldwatchPaths.file("rooms.json")) { self.url = url }

    /// Saved rooms, or one empty room on first use / unreadable file.
    public func load() -> RoomFile {
        lock.lock(); defer { lock.unlock() }
        if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(RoomFile.self, from: data), !file.rooms.isEmpty {
            return file
        }
        let room = RoomPlan()
        return RoomFile(selectedId: room.id, rooms: [room])
    }

    public func save(_ file: RoomFile) {
        lock.lock(); defer { lock.unlock() }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
