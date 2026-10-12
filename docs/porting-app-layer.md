# Porting the Fieldwatch app layer (Android UI + services) to macOS SwiftUI

Read `porting-conventions.md` first — the same naming contract applies (identical names, all argument labels kept,
enum cases lowerCamel, `Int` ms timestamps, compat helpers). This file adds the rules for
`Sources/Fieldwatch/` (the executable target, `import SwiftUI` / `import FieldwatchCore`).

The Core library (`Sources/FieldwatchCore`) mirrors the Kotlin `domain/` and `data/` packages name-for-name,
so app code reads like a translation of the Kotlin `ui/`, `radio/` and `alert/` packages.

## Target layout

```
Sources/Fieldwatch/
  App/            FieldwatchMain.swift (@main SwiftUI App), FieldwatchApp.swift (runtime, port of FieldwatchApp.kt),
                  FieldwatchViewModel.swift (+ split files if large)
  Radio/          BleRadio.swift (CoreBluetooth), WifiRadio.swift (CoreWLAN), LocationSource.swift (CoreLocation),
                  ScanService.swift, TakPublisher.swift (Network.framework UDP), Permissions.swift
  Alert/          Alerter.swift (NSSound/AVAudio tones, AVSpeechSynthesizer, UserNotifications)
  UI/Theme/       Theme.swift                       — DONE (read it)
  UI/Components/  Components.swift, Widgets.swift   — DONE (read them)
  UI/             FieldwatchAppUi.swift, LiveChromeTour.swift
  UI/Screens/     one file per Kotlin ui/screen/*.kt (LiveScreens.swift, DeviceDetailScreen.swift, ...)
  UI/Components/  SitPathCanvas.swift (port of ui/component/SitPathCanvas.kt)
```

## Runtime objects (names mirror Kotlin)

- `final class FieldwatchApp` — port of `FieldwatchApp.kt` (the Android `Application`): owns `config: ConfigStore`,
  `devices: DeviceStore`, `logs: LogStore`, `sits: SitStore`, `alerter: Alerter`, `tak: TakPublisher`,
  `pairingFlood`, `wifiFlood`, arrivals, operator GPS path, location. Single instance: `FieldwatchApp.shared`.
  The Android `gnss: GnssMonitor` does not exist on macOS (no GNSS receiver); keep `gnssProfile` only if Core
  has `GnssProfileStore`. Anything the screens read through `app.gnss...` becomes "unavailable" constants.
- `final class ScanService` — port of `radio/ScanService.kt` without the Android foreground-service plumbing:
  start/stop, the tick loop (DispatchSourceTimer on a background queue), feeding observations from
  `BleRadio`/`WifiRadio` into `DeviceStore`, logging, alerts, TAK. `FieldwatchApp.startScanning()/stopScanning()` drive it.
- `@MainActor @Observable final class FieldwatchViewModel` — port of `ui/FieldwatchViewModel.kt`.
  - Every Kotlin `val x: StateFlow<T>` becomes `private(set) var x: T` on the view model, kept current by
    observing the Core `MutableStateFlow`s and recomputing on the main actor (coalesce bursts: at most ~5 UI
    refreshes per second for the live list; Kotlin used `combine` + `sample`/`debounce` — mirror its cadence).
  - `FieldwatchUi`, `ExportUi`, `CandidatesUi`, `HuntUi`, `BeepSnap`, `PendingSettingsImport`, etc. are structs
    with the same fields.
  - Every Kotlin `fun` keeps its name and labels: views call `vm.updateFilter { f in var f = f; f.namedOnly = true; return f }`,
    `vm.select(key: id)`, `vm.startHunt(device: d)`, `vm.setViewMode(mode: .radar)`...
  - Android types: `Intent` (share) → `ShareItem` (below); `Uri` → `URL`; `Application` → `FieldwatchApp.shared`.
- `struct ShareItem: Identifiable { let id = UUID(); var urls: [URL]; var text: String?; var title: String }`
  — declared in `FieldwatchViewModel.swift`. `ExportUi.share: ShareItem?`. Screens present it with
  `ShareSheet(item:)` (declared in `FieldwatchAppUi.swift`: NSSharingServicePicker + "Reveal in Finder" +
  "Save As…" buttons) and call `vm.consumeShare()` on dismiss.
- File pickers: Kotlin `rememberLauncherForActivityResult(CreateDocument/OpenDocument)` → SwiftUI
  `.fileExporter` / `.fileImporter` (or NSSavePanel/NSOpenPanel) calling the same vm functions with a `URL`.

## macOS UI shape

The Android app is one screen with five bottom tabs (Live, Filters, Signatures, Reports, Settings), a header
with live counts, a Tune (Display) panel on Live, and full-screen detail pages. On the Mac:

- Window: `NavigationSplitView` — sidebar lists the five tabs (SF Symbols: `dot.radiowaves.left.and.right`,
  `line.3.horizontal.decrease.circle`, `point.3.filled.connected.trianglepath.dotted`, `doc.text`, `gearshape`).
  The window toolbar carries the FIELDWATCH header: counts (Wi-Fi / BLE / signatures icons with numbers and
  their green/gray/dim/red state colours), the status hint words, "· SIT" / "· PAUSED", a Pause/Run button
  (Space bar shortcut while on Live), and on Live the Tune button that opens the Display panel as a popover.
- Device detail: selecting a Live row shows `DeviceDetailScreen` in a trailing `.inspector` (width ~420),
  not a full-page push. Hunt opens from detail as a sheet. Signature editing (Signatures tab) uses a
  `NavigationStack` inside the content column (editor → Decode fields push). Reports / Settings sub-pages
  (Named radios, Candidates, Diagnostics) push inside a `NavigationStack` too.
- Android dialogs → `.alert` / `.confirmationDialog` / `.sheet`. Snackbars/toasts → a small transient banner
  at the bottom of the content column.
- Lists: `ScrollView { LazyVStack }` with the Compose row layouts (cards on `fw.surface`, 10–12 pt radius).
  Rows are clickable (single click selects/opens detail). Context menu on rows: Copy MAC/BSSID, Copy name,
  Bookmark, Hunt (BLE).
- Keep the visual language: dark `fw.background`, panels `fw.surface`, phosphor accents, monospaced data
  (`FW.mono(...)`). Read colours from `@Environment(\.fw) var fw`; pass any data colour (class accent, RSSI)
  through `fw.tint(...)` so Night mode works. Compose `MaterialTheme.colorScheme.X` → `fw.X`.
  Typography: Compose bodySmall ≈ 12 pt, bodyMedium ≈ 13 pt, titleSmall ≈ 13 pt semibold, titleMedium ≈ 15 pt
  semibold, labelSmall ≈ 10–11 pt.
- Compose → SwiftUI: `remember { mutableStateOf(x) }` → `@State`; `LaunchedEffect`/ticker → `.task` or
  `TimelineView(.periodic(from: .now, by: 1))`; `LazyColumn` → `ScrollView` + `LazyVStack`; `Canvas` → `Canvas`;
  `AlertDialog` → `.alert`/`.sheet`; `DropdownMenu`/`ExposedDropdownMenuBox` → `FieldwatchDropdownField`/`Menu`;
  `Switch` → `FieldwatchSwitch`; `FilterChip` → `FieldwatchFilterChip`; `OutlinedButton` → `FieldwatchActionButton`.
- Android-only affordances are dropped or replaced, never faked: vibration, notification shade card,
  battery-optimisation / "Allow background usage", Developer-options Wi-Fi throttle, Keep screen on
  (→ on macOS: keep the display awake with `IOPMAssertion` while Live is visible — the runtime owns it),
  GNSS interference (no receiver: hide its UI, keep settings in packs). Replace Android permission UI with
  macOS Bluetooth / Location permission status + "Open System Settings" buttons
  (`x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth` / `?Privacy_LocationServices`).
- User-facing "phone" referring to the device running Fieldwatch → "Mac".

## View construction rule

Each Kotlin `@Composable fun Name(params)` that another file calls becomes `struct Name: View` whose stored
properties are the Kotlin parameters, in order, with the same defaults (`var vm: FieldwatchViewModel`,
`var onBack: () -> Void`, `var compact: Bool = false`). Callers use the memberwise init:
`DeviceDetailScreen(vm: vm, device: d, onBack: { ... })`. Never mark stored properties (including
`@State`, `@Environment`) `private` in such a view — that makes the memberwise init private and breaks callers.
Use `@State var` / `@Environment(\.fw) var fw`. Private helper views inside your file may do what they like.
