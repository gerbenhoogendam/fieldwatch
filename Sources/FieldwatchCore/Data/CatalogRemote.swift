import Foundation

// Port of data/CatalogRemote.kt (HttpURLConnection → URLSession).
// `fetch` is synchronous like the Kotlin original: it blocks the calling thread until the download
// finishes, so never call it on the main thread. `fetchAsync` is the non-blocking variant; its
// completion runs on a URLSession delegate queue (not main).

/// HTTPS GET of the stock signature pack on GitHub. No account. Fails to the caller.
public enum CatalogRemote {
    public static let STOCK_PACK_URL =
        "https://raw.githubusercontent.com/OffGridPete/Fieldwatch/main/dist/fieldwatch-signatures-v2.json"

    /// Kotlin `error("…")` → this error; `localizedDescription` is the same message.
    public struct FetchError: LocalizedError, Sendable {
        public let message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// Blocking GET. Throws `FetchError` on a non-2xx status, or the URLSession error.
    public static func fetch(
        url: String = STOCK_PACK_URL,
        connectTimeoutMs: Int = 10_000,
        readTimeoutMs: Int = 15_000,
        userAgent: String = "Fieldwatch"
    ) throws -> String {
        let done = DispatchSemaphore(value: 0)
        var result: Result<String, Error> = .failure(FetchError(message: "No response"))
        fetchAsync(url: url, connectTimeoutMs: connectTimeoutMs, readTimeoutMs: readTimeoutMs, userAgent: userAgent) {
            result = $0
            done.signal()
        }
        done.wait()
        return try result.get()
    }

    /// Non-blocking GET; `completion` is called exactly once.
    public static func fetchAsync(
        url: String = STOCK_PACK_URL,
        connectTimeoutMs: Int = 10_000,
        readTimeoutMs: Int = 15_000,
        userAgent: String = "Fieldwatch",
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let target = URL(string: url) else {
            completion(.failure(FetchError(message: "Bad URL: \(url)")))
            return
        }
        // URLSession has no separate connect timeout: the request idle timeout covers connect and each read,
        // the resource timeout caps the whole transfer at connect + read.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Double(max(connectTimeoutMs, readTimeoutMs)) / 1000.0
        config.timeoutIntervalForResource = Double(connectTimeoutMs + readTimeoutMs) / 1000.0
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        var request = URLRequest(url: target)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Redirects are followed by default (Kotlin instanceFollowRedirects = true).
        let task = session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            if let error {
                completion(.failure(error))
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200...299).contains(code) {
                completion(.failure(FetchError(message: "GitHub returned HTTP \(code)")))
                return
            }
            completion(.success(String(decoding: data ?? Data(), as: UTF8.self)))
        }
        task.resume()
    }
}
