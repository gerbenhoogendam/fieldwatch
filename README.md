# Fieldwatch for macOS

**Unofficial macOS port of [Fieldwatch](https://github.com/OffGridPete/Fieldwatch) by Off Grid Pete LLC.**
This port is not made or reviewed by Off Grid Pete LLC; the official (Android) builds are the releases in
[OffGridPete/Fieldwatch](https://github.com/OffGridPete/Fieldwatch). Please report problems with this Mac
version here, not upstream.

Fieldwatch is a passive, offline observer of publicly broadcast Wi-Fi access points and Bluetooth LE
advertisements, with a signature catalog, live views (radar, strength list, timeline, hybrid, by class),
watchlist alerts, sits, debrief reports, exports and a TAK / Cursor-on-Target feed.

Receive-only. No account, no server, no telemetry. **Experimental — use at your own risk, not for
safety-critical use.** Read the disclaimer the app shows on first launch. MIT licensed (see `LICENSE`, `NOTICE`).

## Install

Download `Fieldwatch-<version>.dmg` from [Releases](https://github.com/gerbenhoogendam/fieldwatch/releases),
open it and drag Fieldwatch to Applications. macOS 14 or later, Apple silicon or Intel. The app is signed with a
Developer ID and notarized by Apple.

On first launch allow **Bluetooth** (BLE advertisements) and **Location** (macOS only reveals Wi-Fi network
names and BSSIDs to apps with Location access). Both can be changed later in System Settings → Privacy & Security.

## Mac-only additions

- **Map** — estimated radio positions from how loud each radio was at the places this Mac has been
  (walk around with a MacBook to sharpen them). Remote ID drones appear at their broadcast position.
- **Room** — sketch a room to scale (zoom to millimetres, exact wall lengths), place radios where they are,
  identify them by a true distance to calibrate, and follow them relative to this Mac. Measuring from three
  spots places followed radios in 2D. Distances always come with an uncertainty band.
- **Connected** — Bluetooth devices connected to this Mac (they stop advertising, so Live cannot hear them),
  with their real address, type, signal and battery over the existing connection.
- **Names for any radio**, including Bluetooth identifiers, connected devices and room radios.

## Build from source

Requirements: macOS 14 or later, Xcode 16+ (Swift 6 toolchain).

```bash
scripts/build-app.sh
```

```bash
open build/Fieldwatch.app
```

`scripts/build-app.sh` builds a release binary, assembles `build/Fieldwatch.app` (Info.plist, icon, resources) and
signs it with your Apple Development certificate if you have one (ad-hoc otherwise). Options:
`UNIVERSAL=1` for arm64 + x86_64, `CONFIG=debug`. `scripts/release.sh` builds the signed, notarized and stapled
DMG (see the comment at its top for the one-time notarization setup).

Signing with a stable certificate matters: macOS ties Bluetooth and Location grants to the signature, so an
ad-hoc build asks again after every rebuild.

On first launch, allow **Bluetooth** (BLE advertisements) and **Location** (macOS only reveals Wi-Fi network
names and BSSIDs to apps with Location access). Both can be changed later in System Settings → Privacy & Security.

Tests (the Android JUnit suite ported to Swift Testing, plus tests for the Mac additions):

```bash
swift test
```

The package also opens directly in Xcode (`open Package.swift`).

## What differs from the Android app

| | Android | macOS |
|---|---|---|
| Wi-Fi | AP scan results, throttled by Android | CoreWLAN on-demand scans: ~10 s (Performance), ~20 s (Balanced), ~45 s (Saver). Full beacon information elements are available. Needs Location for SSID/BSSID. |
| BLE | Address + raw advertisement bytes | **No MAC address**: macOS gives each advertiser a per-Mac UUID, which Fieldwatch uses as the radio's ID. Advertisement bytes are rebuilt from CoreBluetooth's fields (name, manufacturer data, service UUIDs/data, TX power). OUI / MAC-prefix rules therefore only match Wi-Fi; manufacturer, service, name and payload rules work as on Android. No PHY, flags, appearance or address type. |
| Location | GPS | CoreLocation (usually Wi-Fi positioning — coarser than GPS). |
| GNSS interference check | Yes | Not available (Macs have no GNSS receiver). The settings stay in packs. |
| Alerts | Beep, voice, vibrate, shade card | Tone, voice, optional notification banner. |
| Keep screen on / battery | Wake lock, battery exemptions | Keeps the display awake while Live is shown; App Nap is suspended while scanning. |
| Layout | Bottom tabs, full-screen detail | Sidebar, toolbar header, Display (Tune) popover, device detail in an inspector, Hunt as a sheet. |
| Map | — | **Mac-only addition.** Estimated radio positions on a map. Fieldwatch keeps, per radio, how loud it was at each ~10 m spot this Mac has been, and fits a position from that (log-distance model). Walk around with a MacBook to place radios; a Mac that stays put can only say "within ~N m of here" (one marker, direction unknown). Remote ID drones that broadcast their own GPS are shown at that position. Hidden while Privacy mode is on. |

Signature packs and settings packs are the same JSON as on Android, so you can export on one platform and import on
the other. Logs, sit exports (CSV / JSON lines / GPX / KML / WiGLE), Debrief text and PDF, and AI Export match the
Android formats. Data lives in `~/Library/Application Support/Fieldwatch/`.

The bundled user manual (Help → Fieldwatch User Manual) is the Android manual; everything except the differences above applies.

## Layout

```
Sources/FieldwatchCore/   platform-independent port of the Android domain/ and data/ packages
  Compat/                 Kotlin-style helpers used by the port
  Domain/                 signatures, decoders, filters, sits, reports, flood detection, TAK CoT
  Data/                   config / device / log / sit stores, Debrief PDF, map tiles, place lookup
  Radio/                  BLE AD-structure and Wi-Fi IE byte parsers, TAK publisher core
  Resources/              radiodb.bin (IEEE / Bluetooth SIG tables), stock signature catalog (v94)
Sources/Fieldwatch/       the SwiftUI app
  App/                    @main, runtime (port of FieldwatchApp.kt), view model
  Radio/                  CoreBluetooth, CoreWLAN, CoreLocation, scan loop, TAK UDP transport, permissions
  Alert/                  tones, voice, notifications
  UI/                     theme, components, screens
Tests/FieldwatchCoreTests Swift Testing ports of the Android unit tests
Support/                  Info.plist, entitlements, icon, manual
scripts/                  build-app.sh, make_icon.swift
```

`docs/porting-conventions.md` and `docs/porting-app-layer.md` describe the Kotlin → Swift conventions used, for anyone tracking upstream changes.
