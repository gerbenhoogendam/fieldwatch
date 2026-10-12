import Foundation

/// Thread-safe stand-in for kotlinx `MutableStateFlow` / `StateFlow`.
/// Read/write `value`; `observe` gets every new value (on the writer's thread).
public final class MutableStateFlow<T>: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var current: T
    private var observers: [Int: (T) -> Void] = [:]
    private var nextId = 0

    public init(_ initial: T) { current = initial }

    public var value: T {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set {
            lock.lock()
            current = newValue
            let obs = Array(observers.values)
            lock.unlock()
            obs.forEach { $0(newValue) }
        }
    }

    /// Kotlin `MutableStateFlow.update { }` — atomic read-modify-write.
    public func update(_ f: (T) -> T) {
        lock.lock()
        let next = f(current)
        current = next
        let obs = Array(observers.values)
        lock.unlock()
        obs.forEach { $0(next) }
    }

    /// Kotlin `asStateFlow()`.
    public func asStateFlow() -> StateFlow<T> { self }

    /// Subscribe. Keep the token; dropping it (or calling cancel) unsubscribes.
    @discardableResult
    public func observe(_ f: @escaping (T) -> Void) -> FlowToken {
        lock.lock()
        let id = nextId
        nextId += 1
        observers[id] = f
        lock.unlock()
        return FlowToken { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.observers[id] = nil; self.lock.unlock()
        }
    }
}

public typealias StateFlow<T> = MutableStateFlow<T>

public final class FlowToken: @unchecked Sendable {
    private var onCancel: (() -> Void)?
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() { onCancel?(); onCancel = nil }
    deinit { onCancel?() }
}

/// Where Fieldwatch keeps its files on the Mac (Android `context.filesDir`).
/// Tests point `root` at a temp folder.
public enum FieldwatchPaths {
    nonisolated(unsafe) public static var root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Fieldwatch", isDirectory: true)
    }()

    /// `root/<name>` directory, created on demand.
    public static func dir(_ name: String) -> URL {
        let u = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// `root/<name>` file URL; parent directory created on demand.
    public static func file(_ name: String) -> URL {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(name)
    }
}
