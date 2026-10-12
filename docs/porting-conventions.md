# Porting Fieldwatch (Android/Kotlin) to macOS (Swift)

Kotlin source: the upstream source (https://github.com/OffGridPete/Fieldwatch, `app/src/main/java/app/fieldwatch/` and `app/src/test/`). Manual: `Support/Fieldwatch_User_Manual.pdf`.

The port was done file by file in parallel, so **the naming rules below were a contract**: Swift code mirrors the Kotlin names exactly, which keeps it easy to follow upstream changes.

## Layout

- `Sources/FieldwatchCore/` — library, pure Foundation (+ CoreGraphics/CoreText/AppKit only where noted). No UI.
  - `Compat/` — shared helpers. **Do not edit** (`KotlinCompat.swift`, `Flow.swift`). Read them first.
  - `Domain/` — ports of `domain/*.kt`. Already done: `Models.swift`, `RadioFacts.swift`, `Rssi.swift`.
  - `Data/` — ports of `data/*.kt`.
  - `Radio/` — byte parsers from `radio/` (no CoreBluetooth/CoreWLAN here).
  - `Resources/` — `radiodb.bin`, `fieldwatch-signatures-v2.json` (stock catalog, catalog version 94). Load with `Bundle.module`.
- `Sources/Fieldwatch/` — the SwiftUI app (radios, alerts, UI). Not part of the Core port.
- `Tests/FieldwatchCoreTests/` — Swift Testing ports of the JUnit tests.

One Kotlin file → one Swift file with the same base name (`SitDiff.kt` → `Domain/SitDiff.swift`).

## Language settings

Swift 6 toolchain, **Swift 5 language mode** (no strict concurrency). macOS 14+. `import Foundation`.
Everything other files might use is `public`. Swift Testing for tests (`import Testing`, `@testable import FieldwatchCore`, `@Test func ...`, `#expect(...)`, `#require(...)`).

## Naming contract

| Kotlin | Swift |
|---|---|
| type / function / property / parameter names | **identical** |
| `object Foo { fun bar() }` | `public enum Foo { public static func bar() }` (stateful → `static var` + `NSLock`, or a `final class` with `static let shared` only if Kotlin constructs instances) |
| `data class` | `public struct`, all properties `public var`, explicit `public init` with the **same parameter order and defaults** as Kotlin |
| `class` (stateful) | `public final class` |
| `enum class X { FOO_BAR }` | `public enum X: String, CaseIterable { case fooBar = "FOO_BAR" }` — UPPER_SNAKE → lowerCamel (`HOURS_6`→`hours6`, `U8`→`u8`, `LAW_ENFORCEMENT`→`lawEnforcement`). Keyword cases use backticks (`` `class` ``). `ListLine.none` must always be written qualified. `entries`→`allCases`, `.name`→`.rawValue`, `.ordinal`→add `var ordinal: Int` if you need it |
| `sealed class` | `enum` with associated values, or protocol + structs — your call, document it |
| extension fun `Foo.bar()` | `extension Foo { public func bar() }` |
| extension on `List<Fleet>` | `extension Array where Element == Fleet` |
| top-level fun / val / const | top-level `public func` / `public let` (keep the name, e.g. `DISCLAIMER_REV`) |
| `companion object { const val X }` | `public static let X` on the type |
| `Pair<A,B>` | tuple `(A, B)`; `.first`/`.second` → `.0`/`.1` |
| `Triple` | tuple |
| `Int`, `Long` | `Int` (64-bit). Timestamps are epoch **ms** in `Int`. |
| `Float` | `Double` unless bit-exact float matters |
| `ByteArray` | `[UInt8]` (`b[i].toInt() and 0xFF` → `Int(b[i])`, signed `b[i].toInt()` → `Int(Int8(bitPattern: b[i]))`) |
| `List<T>` / `MutableList` | `[T]` |
| `Set<T>` | `Set<T>` — **except `Sighting.fleetIds`, which is an ordered `[String]`** (Kotlin relied on LinkedHashSet order) |
| `Map<K,V>` | `[K: V]`. If Kotlin iterates a LinkedHashMap and order matters, keep an ordered array of keys |
| nullable `T?` | `T?` |
| `System.currentTimeMillis()` | `nowMs()` |
| `Regex` | `KRegex` (compat). Do not use Swift `Regex` |
| `"%.1f".format(x)` | `fmt(x, 1)`; `"%02X".format(b)` → `hex2(b)`; other numeric formats → `format("%d", n)`. Never `%s` — use interpolation |
| `SimpleDateFormat(pattern, Locale.US)` | `formatMs(ms, pattern)` (local zone) / `formatMs(ms, pattern, utc: true)` |
| `MutableStateFlow` / `StateFlow` | compat `MutableStateFlow<T>` (`.value`, `.update { }`, `.observe { }`) |
| `suspend fun` | plain synchronous `func` (file IO is fine to do inline). `Mutex` → `NSLock` |
| coroutine `launch` / delay loops | `DispatchQueue` / `DispatchSourceTimer` |
| Android `Context` / `filesDir` | `FieldwatchPaths.root` / `.dir(name)` / `.file(name)` (tests override `FieldwatchPaths.root`) |
| `kotlinx.serialization` | `Codable` + `JSONEncoder`/`JSONDecoder`. See JSON rules |
| `java.util.UUID.randomUUID()` | `UUID().uuidString.lowercased()` (Kotlin prints lowercase) |
| `require(x)` / `check(x)` | `precondition` |
| exceptions / `runCatching` | `throws` + `try?` / do-catch. Prefer returning nil like Kotlin `getOrNull()` |

### Function labels

Swift functions keep **every Kotlin parameter name as the argument label** — never `_` — in the Kotlin
declaration order, with the same defaults. Callers write `Foo.bar(device: d, filter: f)`. Kotlin call sites
that use positional or reordered named args must be rewritten in declaration order (look at the callee's
Kotlin declaration). Exception: trailing lambda params keep their name too but may be called with trailing
closure syntax. Operator-like helpers you keep `private` can use any labels.

Kotlin default args that reference other params or `System.currentTimeMillis()` → Swift default `nowMs()` works.

### Mutation

Kotlin `x.copy(a = 1)` → `var y = x; y.a = 1`. Small private helper funcs are fine.

### JSON (must stay compatible with Android export files)

kotlinx was configured `encodeDefaults = true`, `ignoreUnknownKeys = true`, explicit nulls on.
- Decode: missing key → Kotlin default (`try c.decode(.key, default: ...)` from compat), unknown keys ignored.
- Encode: write every property, including nulls (`try c.encode(optional, forKey:)`), except
  `@EncodeDefault(NEVER)` fields which are omitted when default.
- `@SerialName("x")` → `CodingKeys` raw value.
- Enum JSON values are the Kotlin names (the raw values above).
- `prettyPrint = true` → `JSONEncoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]`. Kotlin's
  pretty print indents 4 spaces; Swift uses 2 — that is fine, files are only parsed.
- Sets encode as arrays (sort them for stable output).

## macOS platform facts (affects some logic)

- **BLE has no MAC address on macOS.** CoreBluetooth gives a per-Mac peripheral UUID. The app stores it in
  `Sighting.mac` / `Observation.mac` as an uppercase 8-4-4-4-12 UUID. `MacUtil.isOpaqueId(mac)` is true for these.
  `MacUtil` already treats opaque ids as randomized, no OUI, no prefix match, no vendor. Code that parses MAC
  octets must go through `MacUtil` or check `isOpaqueId` first.
- BLE: no raw advertisement bytes either. The app rebuilds an AD-structure byte string from CoreBluetooth's
  dictionary (local name, manufacturer data, service UUIDs, service data, TX power) so `BleAdParser.parse`
  and `rawHex` keep working. No adv flags, appearance, interval, PHY or address type. Connectable is known.
- Wi-Fi: CoreWLAN gives SSID, BSSID, RSSI, noise, channel number/band/width, and the **raw information
  elements** (`informationElementData`). So IE parsing is byte-based (no Android ScanResult).
  No `capabilities` string — build an equivalent from the RSN/WPA IEs if Kotlin needs it.
- Location: CoreLocation (Wi-Fi based on most Macs, coarse). No GNSS receiver: the GNSS interference monitor
  does not run on macOS, but keep the GNSS *data types* and pure logic so sits, reports and TAK compile.
- No vibration, no notification shade. Haptics/vibrate settings are kept for JSON but unused.

## Late change: `Observation` → `RadioObservation`

Kotlin's `Observation` (one hear of one radio) is named `RadioObservation` in Swift — `Observation` collides
with Apple's Observation module and breaks `@Observable` in any file importing FieldwatchCore. Use
`RadioObservation` in new code; the integrator renames remaining uses.
