import FieldwatchCore
import Foundation
import Network

/// Network.framework UDP for the Core `TakPublisher` (socket side of radio/TakPublisher.kt).
///
/// One cached `NWConnection` per address:port. Multicast destinations (per `TakPublisher.isMulticast(address:)`)
/// go out with hop limit 1, like Android's `MulticastSocket.timeToLive = 1`. Sends are synchronous with a short
/// timeout because `TakPublisher.publish` expects a yes/no per datagram; it runs on the scan service's publish
/// queue, never the main thread.
public final class NetworkTakTransport: TakTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.fieldwatch.tak", qos: .utility)
    private let lock = NSLock()
    private var connections: [String: NWConnection] = [:]
    private var resolved: [String: (address: String?, at: Int)] = [:]

    private static let READY_WAIT_S = 1.5
    private static let SEND_WAIT_S = 1.0
    private static let RESOLVE_TTL_MS = 30_000

    public init() {}

    // MARK: TakTransport

    /// Numeric address for `host` (IPv4 preferred), or nil. Literals return themselves. Cached 30 s.
    public func resolve(host: String) -> String? {
        let h = host.trim()
        if h.isEmpty { return nil }
        if IPv4Address(h) != nil || IPv6Address(h) != nil { return h }
        let now = nowMs()
        lock.lock()
        if let hit = resolved[h], now - hit.at < NetworkTakTransport.RESOLVE_TTL_MS {
            lock.unlock()
            return hit.address
        }
        lock.unlock()
        let addr = NetworkTakTransport.getaddrinfoNumeric(h)
        lock.lock()
        resolved[h] = (addr, now)
        lock.unlock()
        return addr
    }

    public func send(address: String, port: Int, bytes: [UInt8]) -> Bool {
        guard let conn = connection(address: address, port: port) else { return false }
        let done = DispatchSemaphore(value: 0)
        var ok = false
        conn.send(content: Data(bytes), completion: .contentProcessed { err in
            ok = err == nil
            done.signal()
        })
        if done.wait(timeout: .now() + NetworkTakTransport.SEND_WAIT_S) == .timedOut { return false }
        if !ok { drop(key: key(address, port)) }
        return ok
    }

    public func close() {
        lock.lock()
        let all = Array(connections.values)
        connections.removeAll()
        resolved.removeAll()
        lock.unlock()
        all.forEach { $0.cancel() }
    }

    // MARK: Connections

    private func key(_ address: String, _ port: Int) -> String { "\(address):\(port)" }

    private func connection(address: String, port: Int) -> NWConnection? {
        let k = key(address, port)
        lock.lock()
        if let open = connections[k] {
            switch open.state {
            case .ready:
                lock.unlock()
                return open
            case .failed, .cancelled:
                connections[k] = nil
                open.cancel()
            default:
                lock.unlock()
                return waitReady(open) ? open : nil
            }
        }
        lock.unlock()

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port.coerceIn(1, 65_535))) else { return nil }
        let params = NWParameters.udp
        if TakPublisher.isMulticast(address: address),
           let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.hopLimit = 1
        }
        let conn = NWConnection(host: NWEndpoint.Host(address), port: nwPort, using: params)
        lock.lock()
        connections[k] = conn
        lock.unlock()
        conn.start(queue: queue)
        if waitReady(conn) { return conn }
        drop(key: k)
        return nil
    }

    private func waitReady(_ conn: NWConnection) -> Bool {
        if case .ready = conn.state { return true }
        let sem = DispatchSemaphore(value: 0)
        let prior = conn.stateUpdateHandler
        conn.stateUpdateHandler = { state in
            prior?(state)
            switch state {
            case .ready, .failed, .cancelled, .waiting: sem.signal()
            default: break
            }
        }
        // The state may have moved before the handler was installed.
        if case .ready = conn.state { return true }
        _ = sem.wait(timeout: .now() + NetworkTakTransport.READY_WAIT_S)
        if case .ready = conn.state { return true }
        return false
    }

    private func drop(key k: String) {
        lock.lock()
        let c = connections.removeValue(forKey: k)
        lock.unlock()
        c?.cancel()
    }

    // MARK: DNS

    private static func getaddrinfoNumeric(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(first) }
        var v4: String?
        var v6: String?
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(cString: buf)
                if ai.pointee.ai_family == AF_INET, v4 == nil { v4 = s }
                if ai.pointee.ai_family == AF_INET6, v6 == nil { v6 = s }
            }
            p = ai.pointee.ai_next
        }
        return v4 ?? v6
    }
}
