import Foundation

// Small Kotlin-flavoured helpers so the domain port reads close to the Android source.
// Shared by every file in FieldwatchCore. Add file-private helpers elsewhere; keep this file stable.

/// Wall clock in milliseconds since 1970 (Kotlin `System.currentTimeMillis()`).
public func nowMs() -> Int { Int((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

// MARK: - String

public extension String {
    /// Kotlin `take(n)`.
    func take(_ n: Int) -> String { n <= 0 ? "" : String(prefix(n)) }
    /// Kotlin `takeLast(n)`.
    func takeLast(_ n: Int) -> String { n <= 0 ? "" : String(suffix(n)) }
    /// Kotlin `drop(n)`.
    func drop(_ n: Int) -> String { n <= 0 ? self : String(dropFirst(n)) }
    /// Kotlin `dropLast(n)` on a String.
    func dropLastChars(_ n: Int) -> String { n <= 0 ? self : String(prefix(Swift.max(0, count - n))) }

    /// Kotlin `substring(start)` (Character offsets).
    func substring(_ start: Int) -> String {
        guard start < count else { return "" }
        return String(self[index(startIndex, offsetBy: max(0, start))...])
    }

    /// Kotlin `substring(start, end)` (Character offsets, end exclusive).
    func substring(_ start: Int, _ end: Int) -> String {
        let s = max(0, min(start, count)), e = max(s, min(end, count))
        return String(self[index(startIndex, offsetBy: s)..<index(startIndex, offsetBy: e)])
    }

    /// Character at an Int offset.
    func charAt(_ i: Int) -> Character { self[index(startIndex, offsetBy: i)] }

    /// Kotlin `trim()`.
    func trim() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Kotlin `trim(ch...)`.
    func trim(_ chars: Character...) -> String {
        let set = Set(chars)
        var s = Substring(self)
        while let f = s.first, set.contains(f) { s.removeFirst() }
        while let l = s.last, set.contains(l) { s.removeLast() }
        return String(s)
    }
    func trimStart() -> String { String(drop(while: { $0.isWhitespace })) }
    func trimEnd() -> String {
        var s = Substring(self)
        while let l = s.last, l.isWhitespace { s.removeLast() }
        return String(s)
    }

    func lowercase() -> String { lowercased() }
    func uppercase() -> String { uppercased() }

    /// Kotlin `isBlank()`.
    var isBlank: Bool { allSatisfy { $0.isWhitespace } }
    var isNotBlank: Bool { !isBlank }
    var isNotEmpty: Bool { !isEmpty }

    /// Kotlin `ifBlank { }` / `ifEmpty { }`.
    func ifBlank(_ alt: @autoclosure () -> String) -> String { isBlank ? alt() : self }
    func ifEmpty(_ alt: @autoclosure () -> String) -> String { isEmpty ? alt() : self }
    /// Kotlin `takeIf { it.isNotBlank() }` shortcut.
    var nonBlank: String? { isBlank ? nil : self }
    var nonEmpty: String? { isEmpty ? nil : self }

    func startsWith(_ p: String, ignoreCase: Bool = false) -> Bool {
        ignoreCase ? lowercased().hasPrefix(p.lowercased()) : hasPrefix(p)
    }
    func endsWith(_ p: String, ignoreCase: Bool = false) -> Bool {
        ignoreCase ? lowercased().hasSuffix(p.lowercased()) : hasSuffix(p)
    }
    func contains(_ other: String, ignoreCase: Bool) -> Bool {
        if other.isEmpty { return true }
        return ignoreCase ? range(of: other, options: .caseInsensitive) != nil : contains(other)
    }
    func equals(_ other: String?, ignoreCase: Bool) -> Bool {
        guard let other else { return false }
        return ignoreCase ? caseInsensitiveCompare(other) == .orderedSame : self == other
    }
    func replace(_ target: String, _ with: String, ignoreCase: Bool = false) -> String {
        if target.isEmpty { return self }
        return replacingOccurrences(of: target, with: with, options: ignoreCase ? .caseInsensitive : [])
    }
    func replace(_ target: Character, _ with: Character) -> String {
        String(map { $0 == target ? with : $0 })
    }
    func indexOf(_ s: String, ignoreCase: Bool = false) -> Int {
        guard let r = range(of: s, options: ignoreCase ? .caseInsensitive : []) else { return -1 }
        return distance(from: startIndex, to: r.lowerBound)
    }
    func lastIndexOf(_ s: String) -> Int {
        guard let r = range(of: s, options: .backwards) else { return -1 }
        return distance(from: startIndex, to: r.lowerBound)
    }

    func substringBefore(_ d: String, missing: String? = nil) -> String {
        guard let r = range(of: d) else { return missing ?? self }
        return String(self[..<r.lowerBound])
    }
    func substringAfter(_ d: String, missing: String? = nil) -> String {
        guard let r = range(of: d) else { return missing ?? self }
        return String(self[r.upperBound...])
    }
    func substringBeforeLast(_ d: String, missing: String? = nil) -> String {
        guard let r = range(of: d, options: .backwards) else { return missing ?? self }
        return String(self[..<r.lowerBound])
    }
    func substringAfterLast(_ d: String, missing: String? = nil) -> String {
        guard let r = range(of: d, options: .backwards) else { return missing ?? self }
        return String(self[r.upperBound...])
    }

    /// Kotlin `split(delim)` keeps empty pieces.
    func split(_ delimiter: String) -> [String] { components(separatedBy: delimiter) }

    /// Kotlin `lines()`.
    func lines() -> [String] {
        replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// Kotlin `chunked(n)`.
    func chunked(_ n: Int) -> [String] {
        guard n > 0, !isEmpty else { return [] }
        var out: [String] = []
        var i = startIndex
        while i < endIndex {
            let j = index(i, offsetBy: n, limitedBy: endIndex) ?? endIndex
            out.append(String(self[i..<j]))
            i = j
        }
        return out
    }

    func padStart(_ length: Int, _ pad: Character = " ") -> String {
        count >= length ? self : String(repeating: pad, count: length - count) + self
    }
    func padEnd(_ length: Int, _ pad: Character = " ") -> String {
        count >= length ? self : self + String(repeating: pad, count: length - count)
    }
    func repeated(_ n: Int) -> String { String(repeating: self, count: max(0, n)) }

    /// Kotlin `toIntOrNull(radix)`. Accepts an optional leading sign like Kotlin.
    func toIntOrNull(_ radix: Int = 10) -> Int? { Int(self, radix: radix) }
    func toLongOrNull(_ radix: Int = 10) -> Int? { Int(self, radix: radix) }
    func toDoubleOrNull() -> Double? {
        let t = trim()
        if t.isEmpty { return nil }
        return Double(t)
    }

    /// Kotlin `filter { it.isLetterOrDigit() }`.
    func filterAlnum() -> String { String(filter { $0.isLetter || $0.isNumber }) }
    /// Only 0-9A-Fa-f characters.
    func filterHex() -> String { String(filter { $0.isHexDigit }) }

    /// Kotlin `capitalize` / `replaceFirstChar { it.uppercase() }`.
    func capitalizedFirst() -> String {
        guard let f = first else { return self }
        return String(f).uppercased() + dropFirst()
    }

    /// Hex string (any separators) to bytes. Odd trailing nibble is dropped. Nil on non-hex content.
    func hexToBytes() -> [UInt8]? {
        let hex = filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(hex.count / 2)
        var it = hex.makeIterator()
        while let a = it.next(), let b = it.next() {
            guard let v = UInt8(String([a, b]), radix: 16) else { return nil }
            out.append(v)
        }
        return out
    }

    /// Kotlin `hexSpaced()` — "AABB" -> "AA BB".
    func hexSpaced() -> String { chunked(2).joined(separator: " ") }

    /// UTF-8 byte count.
    var utf8Count: Int { utf8.count }
}

public extension Character {
    var isLetterOrDigit: Bool { isLetter || isNumber }
    var isISOControl: Bool { unicodeScalars.allSatisfy { ($0.value <= 0x1F) || ($0.value >= 0x7F && $0.value <= 0x9F) } }
}

public extension Optional where Wrapped == String {
    var isNullOrBlank: Bool { self?.isBlank ?? true }
    var isNullOrEmpty: Bool { self?.isEmpty ?? true }
    var orEmpty: String { self ?? "" }
}

// MARK: - Bytes / hex

public extension Array where Element == UInt8 {
    /// Kotlin `toHexUpper()`.
    func toHexUpper() -> String {
        var s = ""
        s.reserveCapacity(count * 2)
        for b in self { s += hex2(Int(b)) }
        return s
    }
    /// Kotlin `copyOfRange(from, to)` with clamping.
    func copyOfRange(_ from: Int, _ to: Int) -> [UInt8] {
        let f = Swift.max(0, Swift.min(from, count)), t = Swift.max(f, Swift.min(to, count))
        return Array(self[f..<t])
    }
    /// Unsigned byte at i as Int (Kotlin `b[i].toInt() and 0xFF`).
    func u8(_ i: Int) -> Int { Int(self[i]) }
    /// Signed byte at i as Int (Kotlin `b[i].toInt()`).
    func s8(_ i: Int) -> Int { Int(Int8(bitPattern: self[i])) }
}

private let hexDigits: [Character] = Array("0123456789ABCDEF")

/// Two upper-case hex digits for the low byte of v ("%02X").
public func hex2(_ v: Int) -> String {
    let b = v & 0xFF
    return String([hexDigits[b >> 4], hexDigits[b & 0xF]])
}

/// Upper-case hex padded to `width` digits ("%0NX"). Negative values use their 64-bit pattern.
public func hexN(_ v: Int, _ width: Int) -> String {
    String(UInt(bitPattern: v), radix: 16, uppercase: true).padStart(width, "0")
}

/// Kotlin `"%.Nf".format(x)` with '.' decimal separator.
public func fmt(_ x: Double, _ decimals: Int) -> String {
    String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), x)
}

/// `String.format` for numeric patterns. Use `%d`/`%ld` with Int, `%f` with Double. Never `%s`.
public func format(_ pattern: String, _ args: CVarArg...) -> String {
    String(format: pattern, locale: Locale(identifier: "en_US_POSIX"), arguments: args)
}

// MARK: - Numbers

public extension Comparable {
    func coerceIn(_ lo: Self, _ hi: Self) -> Self { Swift.min(Swift.max(self, lo), hi) }
    func coerceAtLeast(_ lo: Self) -> Self { Swift.max(self, lo) }
    func coerceAtMost(_ hi: Self) -> Self { Swift.min(self, hi) }
}

public extension Int {
    /// Kotlin `mod` (always non-negative for positive m).
    func mod(_ m: Int) -> Int { let r = self % m; return r < 0 ? r + m : r }
    var d: Double { Double(self) }
}

public extension Double {
    var isFiniteNumber: Bool { isFinite }
    /// Kotlin `roundToInt()` (half away from zero... Kotlin uses Math.round: half up).
    func roundToInt() -> Int { Int((self + 0.5).rounded(.down)) }
    func roundToLong() -> Int { roundToInt() }
    func toIntTruncating() -> Int { isFinite ? Int(self) : 0 }
}

// MARK: - Collections

public extension Sequence {
    func firstOrNull(_ p: (Element) throws -> Bool) rethrows -> Element? { try first(where: p) }
    func mapNotNull<T>(_ f: (Element) throws -> T?) rethrows -> [T] { try compactMap(f) }
    func sumOf(_ f: (Element) throws -> Int) rethrows -> Int { try reduce(0) { $0 + (try f($1)) } }
    func sumOfDouble(_ f: (Element) throws -> Double) rethrows -> Double { try reduce(0) { $0 + (try f($1)) } }
    func count(_ p: (Element) throws -> Bool) rethrows -> Int { try reduce(0) { $0 + (try p($1) ? 1 : 0) } }
    func any(_ p: (Element) throws -> Bool) rethrows -> Bool { try contains(where: p) }
    func none(_ p: (Element) throws -> Bool) rethrows -> Bool { try !contains(where: p) }
    func all(_ p: (Element) throws -> Bool) rethrows -> Bool { try allSatisfy(p) }

    /// Kotlin `associateBy` — later elements win.
    func associateBy<K: Hashable>(_ key: (Element) throws -> K) rethrows -> [K: Element] {
        var out: [K: Element] = [:]
        for e in self { out[try key(e)] = e }
        return out
    }
    /// Kotlin `groupBy` keeping first-seen key order.
    func groupByOrdered<K: Hashable>(_ key: (Element) throws -> K) rethrows -> [(K, [Element])] {
        var order: [K] = []
        var map: [K: [Element]] = [:]
        for e in self {
            let k = try key(e)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(e)
        }
        return order.map { ($0, map[$0]!) }
    }
    /// Kotlin `distinctBy` keeping first occurrence order.
    func distinctBy<K: Hashable>(_ key: (Element) throws -> K) rethrows -> [Element] {
        var seen = Set<K>()
        var out: [Element] = []
        for e in self where seen.insert(try key(e)).inserted { out.append(e) }
        return out
    }
    func maxByOrNull<T: Comparable>(_ f: (Element) throws -> T) rethrows -> Element? {
        var best: Element?
        var bestK: T?
        for e in self {
            let k = try f(e)
            if bestK == nil || k > bestK! { best = e; bestK = k }
        }
        return best
    }
    func minByOrNull<T: Comparable>(_ f: (Element) throws -> T) rethrows -> Element? {
        var best: Element?
        var bestK: T?
        for e in self {
            let k = try f(e)
            if bestK == nil || k < bestK! { best = e; bestK = k }
        }
        return best
    }
    /// Kotlin `sortedBy` (stable).
    func sortedBy<T: Comparable>(_ f: (Element) throws -> T) rethrows -> [Element] {
        var rows: [(Int, Element, T)] = []
        for (i, e) in enumerated() { rows.append((i, e, try f(e))) }
        rows.sort { a, b in a.2 == b.2 ? a.0 < b.0 : a.2 < b.2 }
        return rows.map { $0.1 }
    }
    /// Kotlin `sortedByDescending` (stable).
    func sortedByDescending<T: Comparable>(_ f: (Element) throws -> T) rethrows -> [Element] {
        var rows: [(Int, Element, T)] = []
        for (i, e) in enumerated() { rows.append((i, e, try f(e))) }
        rows.sort { a, b in a.2 == b.2 ? a.0 < b.0 : a.2 > b.2 }
        return rows.map { $0.1 }
    }
    /// Stable sort with a Kotlin-style comparator returning <0, 0, >0.
    func sortedWithComparator(_ cmp: (Element, Element) -> Int) -> [Element] {
        enumerated().sorted { a, b in
            let c = cmp(a.element, b.element)
            return c == 0 ? a.offset < b.offset : c < 0
        }.map { $0.element }
    }
    func partitioned(_ p: (Element) throws -> Bool) rethrows -> ([Element], [Element]) {
        var a: [Element] = [], b: [Element] = []
        for e in self { if try p(e) { a.append(e) } else { b.append(e) } }
        return (a, b)
    }
}

/// Kotlin `compareValues` for building comparators.
public func compareValues<T: Comparable>(_ a: T?, _ b: T?) -> Int {
    switch (a, b) {
    case (nil, nil): return 0
    case (nil, _): return -1
    case (_, nil): return 1
    case let (x?, y?): return x < y ? -1 : (x > y ? 1 : 0)
    }
}

public extension Sequence where Element: Hashable {
    /// Kotlin `distinct()` keeping first occurrence order.
    func distinct() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

public extension Sequence where Element == Int {
    func average() -> Double {
        var n = 0, s = 0
        for v in self { n += 1; s += v }
        return n == 0 ? .nan : Double(s) / Double(n)
    }
    func sum() -> Int { reduce(0, +) }
}

public extension Sequence where Element == Double {
    func average() -> Double {
        var n = 0
        var s = 0.0
        for v in self { n += 1; s += v }
        return n == 0 ? .nan : s / Double(n)
    }
    func sum() -> Double { reduce(0, +) }
}

public extension Array {
    func getOrNull(_ i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
    var firstOrNil: Element? { first }
    var lastIndex: Int { count - 1 }
    func take(_ n: Int) -> [Element] { n <= 0 ? [] : Array(prefix(n)) }
    func takeLast(_ n: Int) -> [Element] { n <= 0 ? [] : Array(suffix(n)) }
    func drop(_ n: Int) -> [Element] { n <= 0 ? self : Array(dropFirst(n)) }
    func dropLastN(_ n: Int) -> [Element] { n <= 0 ? self : Array(dropLast(n)) }
    /// Kotlin `chunked(n)`.
    func chunked(_ n: Int) -> [[Element]] {
        guard n > 0 else { return [] }
        return stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) }
    }
    /// Kotlin `windowed(size, step, partial=false)`.
    func windowed(_ size: Int, step: Int = 1) -> [[Element]] {
        guard size > 0, count >= size else { return [] }
        return stride(from: 0, through: count - size, by: step).map { Array(self[$0..<$0 + size]) }
    }
    /// Kotlin `zipWithNext`.
    func zipWithNext() -> [(Element, Element)] {
        guard count >= 2 else { return [] }
        return (0..<(count - 1)).map { (self[$0], self[$0 + 1]) }
    }
    var isNotEmpty: Bool { !isEmpty }
    func ifEmpty(_ alt: @autoclosure () -> [Element]) -> [Element] { isEmpty ? alt() : self }
    func indexOfFirst(_ p: (Element) throws -> Bool) rethrows -> Int { try firstIndex(where: p) ?? -1 }
    func indexOfLast(_ p: (Element) throws -> Bool) rethrows -> Int { try lastIndex(where: p) ?? -1 }
    func lastOrNull(_ p: (Element) throws -> Bool) rethrows -> Element? { try last(where: p) }
    /// Kotlin `single { }` — crashes when not exactly one, like Kotlin throws.
    func single(_ p: (Element) throws -> Bool) rethrows -> Element {
        let m = try filter(p)
        precondition(m.count == 1, "single(): expected 1 match, got \(m.count)")
        return m[0]
    }
}

public extension Set {
    var isNotEmpty: Bool { !isEmpty }
}

public extension Dictionary {
    var isNotEmpty: Bool { !isEmpty }
    func getOrDefault(_ k: Key, _ d: Value) -> Value { self[k] ?? d }
}

// MARK: - Regex (Kotlin Regex over NSRegularExpression)

/// Minimal Kotlin `Regex`. Named `KRegex` to avoid clashing with Swift's `Regex`.
public struct KRegex: @unchecked Sendable {
    public let pattern: String
    let re: NSRegularExpression

    public init(_ pattern: String, ignoreCase: Bool = false) {
        self.pattern = pattern
        // Force-try mirrors Kotlin throwing on a bad pattern.
        re = try! NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
    }

    private func ns(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }

    /// Whole-string match (Kotlin `matches`).
    public func matches(_ s: String) -> Bool {
        guard let m = re.firstMatch(in: s, options: [.anchored], range: ns(s)) else { return false }
        return m.range.location == 0 && m.range.length == (s as NSString).length
    }
    /// Kotlin `containsMatchIn`.
    public func containsMatchIn(_ s: String) -> Bool { re.firstMatch(in: s, range: ns(s)) != nil }

    public struct Match {
        public let value: String
        /// groupValues[0] is the whole match; missing groups are "".
        public let groupValues: [String]
        public let range: Range<String.Index>
    }

    private func wrap(_ m: NSTextCheckingResult, in s: String) -> Match {
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            if r.location != NSNotFound, let rr = Range(r, in: s) { groups.append(String(s[rr])) } else { groups.append("") }
        }
        return Match(value: groups.first ?? "", groupValues: groups, range: Range(m.range, in: s)!)
    }

    /// Kotlin `find`.
    public func find(_ s: String) -> Match? {
        re.firstMatch(in: s, range: ns(s)).map { wrap($0, in: s) }
    }
    /// Kotlin `findAll`.
    public func findAll(_ s: String) -> [Match] {
        re.matches(in: s, range: ns(s)).map { wrap($0, in: s) }
    }
    /// Kotlin `replace(input, replacement)`; `$1` style group references work.
    public func replace(_ s: String, _ template: String) -> String {
        re.stringByReplacingMatches(in: s, range: ns(s), withTemplate: template)
    }
    /// Kotlin `replace(input) { transform }`.
    public func replace(_ s: String, _ transform: (Match) -> String) -> String {
        var out = ""
        var last = s.startIndex
        for m in findAll(s) {
            out += s[last..<m.range.lowerBound]
            out += transform(m)
            last = m.range.upperBound
        }
        out += s[last...]
        return out
    }
    /// Kotlin `split`.
    public func split(_ s: String) -> [String] {
        var out: [String] = []
        var last = s.startIndex
        for m in findAll(s) {
            out.append(String(s[last..<m.range.lowerBound]))
            last = m.range.upperBound
        }
        out.append(String(s[last...]))
        return out
    }
    /// Kotlin `Regex.escape`.
    public static func escape(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }
}

public extension String {
    func matches(_ re: KRegex) -> Bool { re.matches(self) }
    func replace(_ re: KRegex, _ template: String) -> String { re.replace(self, template) }
}

// MARK: - Dates

/// Format epoch-ms with a java.text.SimpleDateFormat-compatible pattern.
/// `utc` false uses the Mac's current time zone (Android `Locale.US` + default zone).
public func formatMs(_ ms: Int, _ pattern: String, utc: Bool = false) -> String {
    dateFormatter(pattern, utc: utc).string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
}

/// DateFormatter is costly to build and thread-safe to use, so keep one per pattern + zone.
/// Local-zone formatters follow the Mac's time zone if it changes.
private let formatterLock = NSLock()
nonisolated(unsafe) private var formatterCache: [String: DateFormatter] = [:]

private func dateFormatter(_ pattern: String, utc: Bool) -> DateFormatter {
    let zone = utc ? TimeZone(identifier: "UTC")! : TimeZone.current
    let key = "\(zone.identifier)|\(pattern)"
    formatterLock.lock()
    defer { formatterLock.unlock() }
    if let f = formatterCache[key] { return f }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = zone
    f.dateFormat = pattern
    formatterCache[key] = f
    return f
}

/// ISO-8601 UTC with milliseconds, e.g. 2026-10-12T14:03:22.123Z (java.time.Instant.toString-ish).
public func isoUtcMs(_ ms: Int) -> String { formatMs(ms, "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", utc: true) }

// MARK: - Codable helpers

public extension KeyedDecodingContainer {
    /// decodeIfPresent with a default — the kotlinx "missing key uses default" rule.
    func decode<T: Decodable>(_ key: Key, default d: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? d()
    }
    /// Lenient optional: absent, null → nil.
    func opt<T: Decodable>(_ key: Key) throws -> T? { try decodeIfPresent(T.self, forKey: key) }
}

/// Coding key that accepts any string, for hand-written Codable.
public struct AnyKey: CodingKey, Hashable {
    public var stringValue: String
    public var intValue: Int? { nil }
    public init(_ s: String) { stringValue = s }
    public init?(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { nil }
}
