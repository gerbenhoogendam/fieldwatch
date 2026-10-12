import SwiftUI
import AppKit
import CoreBluetooth
import CoreLocation
import UniformTypeIdentifiers
import FieldwatchCore

// Port of ui/screen/SettingsScreen.kt.
//
// macOS changes:
// - Dropped (Android only): GNSS interference check + calibration, Faster Wi-Fi AP scans (Developer options),
//   Allow background usage / Unrestricted battery, TAK GNSS chips + GNSS mark hold. Settings stay in packs.
// - Keep screen on -> Keep display awake (the runtime holds an IOPMAssertion while Live is visible).
// - System notification (shade card) -> Notification banner. Media volume -> system volume.
// - Scan intensity captions describe the Mac radios (BLE duplicate filtering, CoreWLAN scan cadence).
// - Stale after moved from Logging to Scanning. Logging gained file format (CSV / JSON lines) and Clear log.
// - Debrief options are shown here as well as on Reports.
// - Permissions: Bluetooth / Location status with Open System Settings buttons.
// - File pickers: NSSavePanel for Save, .fileImporter for Import. Share goes through ExportUi.share.

/// Settings tab with its own NavigationStack: Named radios and Diagnostics push inside it.
/// `onOpenDevice` is called when a Named radios row that is on the air is clicked (after `vm.select(key:)`);
/// the window should switch to Live so the detail inspector shows.
struct SettingsNavigationStack: View {
    var vm: FieldwatchViewModel
    var onShowLiveTour: () -> Void = {}
    var onOpenDevice: ((String) -> Void)? = nil
    @State var path: [SettingsRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            SettingsScreen(
                state: vm.ui,
                vm: vm,
                onRadioBookmarks: { path.append(.radioBookmarks) },
                onScanStatus: { path.append(.scanStatus) },
                onShowLiveTour: onShowLiveTour
            )
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .radioBookmarks:
                    RadioBookmarksScreen(
                        state: vm.ui,
                        vm: vm,
                        onBack: { if !path.isEmpty { path.removeLast() } },
                        onOpen: { key in
                            vm.select(key: key)
                            onOpenDevice?(key)
                        }
                    )
                    .navigationBarBackButtonHidden(true)
                case .scanStatus:
                    ScanStatusScreen(state: vm.ui, onBack: { if !path.isEmpty { path.removeLast() } })
                        .navigationBarBackButtonHidden(true)
                }
            }
        }
    }
}

enum SettingsRoute: Hashable {
    case radioBookmarks
    case scanStatus
}

struct SettingsScreen: View {
    var state: FieldwatchUi
    var vm: FieldwatchViewModel
    var onRadioBookmarks: () -> Void
    var onScanStatus: () -> Void
    var onShowLiveTour: () -> Void = {}
    @Environment(\.fw) var fw
    @State var confirmRestore = false
    @State var confirmClearLog = false
    @State var importTarget: SettingsImportTarget? = nil

    var body: some View {
        let settings = state.settings
        VStack(spacing: 0) {
            NestedTopBar(title: "Settings")
            GeometryReader { geo in
                ScrollView {
                    Group {
                        if geo.size.width >= 860 {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(spacing: 12) { leftColumn(settings) }
                                VStack(spacing: 12) { rightColumn(settings) }
                            }
                        } else {
                            VStack(spacing: 12) {
                                leftColumn(settings)
                                rightColumn(settings)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    SettingsFooter(catalogVersion: state.catalogVersion)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 16)
                }
            }
        }
        .background(fw.background)
        .alert(
            "Import settings?",
            isPresented: Binding(
                get: { vm.pendingSettingsImport != nil },
                set: { if !$0 { vm.dismissPendingSettingsImport() } }
            ),
            presenting: vm.pendingSettingsImport
        ) { _ in
            Button("Import") { vm.confirmPendingSettingsImport() }
            Button("Cancel", role: .cancel) { vm.dismissPendingSettingsImport() }
        } message: { pending in
            Text(pending.message)
        }
        .alert("Restore defaults?", isPresented: $confirmRestore) {
            Button("Restore", role: .destructive) { vm.restoreDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Replaces the stock catalog, colors, stock bookmarks, stock filters, and the default switches. " +
                    "Signatures and filters you added are deleted. Export those first if you want a backup. " +
                    "This cannot be undone."
            )
        }
        .alert("Clear log?", isPresented: $confirmClearLog) {
            Button("Clear", role: .destructive) { vm.clearLogs() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes the detection log on this Mac. Sits, signatures, and settings stay. This cannot be undone.")
        }
        .fileImporter(
            isPresented: Binding(get: { importTarget != nil }, set: { if !$0 { importTarget = nil } }),
            allowedContentTypes: [.json, .plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            let target = importTarget
            importTarget = nil
            guard case .success(let urls) = result, let url = urls.first, let target else { return }
            // Kept open for the life of the process; the view model may read off the main thread.
            _ = url.startAccessingSecurityScopedResource()
            switch target {
            case .signatures: vm.importSignaturesFromUri(uri: url)
            case .settings: vm.importSettingsFromUri(uri: url)
            }
        }
    }

    @ViewBuilder
    private func leftColumn(_ settings: AppSettings) -> some View {
        AppearanceSection(settings: settings, vm: vm)
        ScanningSection(settings: settings, vm: vm, throttleHint: state.throttleHint)
        LocationSection(settings: settings, vm: vm)
        WatchlistSection(
            settings: settings,
            vm: vm,
            namedRadios: state.watchlist.count { $0.deviceKey != nil },
            onRadioBookmarks: onRadioBookmarks
        )
        LoggingSection(
            settings: settings,
            vm: vm,
            logLines: state.logLines,
            onClear: { confirmClearLog = true }
        )
        DebriefSection(settings: settings, vm: vm)
    }

    @ViewBuilder
    private func rightColumn(_ settings: AppSettings) -> some View {
        SectionCard(title: "TAK / CoT") {
            FieldwatchSwitch(
                "TAK / CoT feed",
                subtitle: "Sends map markers to ATAK, WinTAK, or iTAK. " +
                    "Radios you hear are pinned at this Mac’s location, at the loudest point, and labeled (here). " +
                    "Moving away does not move the pin. A louder detection does. " +
                    "Remote ID aircraft use the coordinates in the advertisement, and a pilot location is a second pin. " +
                    "A radio that leaves keeps its name for How long a spot stays. Click a marker for the name, MAC, and signal. " +
                    "This is not direction finding. Privacy mode pauses the feed.",
                checked: settings.takEnabled,
                onChange: { on in edit(vm) { $0.takEnabled = on } }
            )
            if settings.takEnabled && settings.demoMode {
                Caption("Privacy mode is on, so the feed is paused. Turn Privacy mode off to send markers.", color: fw.primary)
            }
            if settings.takEnabled {
                TakFeedSettings(settings: settings, vm: vm, status: state.takStatus)
            }
        }
        SignaturesSection(
            vm: vm,
            onImport: { importTarget = .signatures },
            onRestore: { confirmRestore = true }
        )
        SettingsBackupSection(vm: vm, onImport: { importTarget = .settings })
        PermissionsSection(locationOn: state.locationOn)
        SectionCard(title: "Help") {
            FieldwatchActionButton("Show Live tour", action: onShowLiveTour)
                .frame(maxWidth: .infinity, alignment: .leading)
            Caption("Shows the Live tour again: display, pause, filters, signatures, reports, and settings.")
            FieldwatchActionButton("Diagnostics", action: onScanStatus)
            Caption(
                "This Mac, the macOS version, the scan switches, and whether Wi-Fi, Bluetooth, and Location are on. " +
                    "Copy puts that on the clipboard for an issue. Network names and coordinates are left out."
            )
        }
    }
}

enum SettingsImportTarget: Hashable {
    case signatures
    case settings
}

// MARK: - Helpers

/// `vm.updateSettings { it.copy(...) }` with an inout edit.
@MainActor
private func edit(_ vm: FieldwatchViewModel, _ change: @escaping (inout AppSettings) -> Void) {
    vm.updateSettings { s in
        var s = s
        change(&s)
        return s
    }
}

/// bodySmall caption in onSurfaceVariant (or a given colour).
private struct Caption: View {
    @Environment(\.fw) var fw
    var text: String
    var color: Color? = nil

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color ?? fw.onSurfaceVariant)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Kotlin StableCaption: keeps the tallest of the variants so toggles do not shove the page.
private struct StableCaption: View {
    @Environment(\.fw) var fw
    var text: String
    var variants: [String]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(Set(variants + [text])).sorted(), id: \.self) { sample in
                Text(sample).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true).hidden()
            }
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(fw.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// labelLarge heading above a chip row.
private struct ChipHeading: View {
    @Environment(\.fw) var fw
    var text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(fw.onSurface)
    }
}

/// Integer slider that previews while dragging and commits on release (Kotlin onValueChangeFinished).
private struct CommitSlider: View {
    @Environment(\.fw) var fw
    var title: (Int) -> String
    var value: Int
    var range: ClosedRange<Int>
    var step: Int? = nil
    var enabled = true
    var onCommit: (Int) -> Void
    @State private var drag: Double? = nil
    @State private var editing = false

    var body: some View {
        let shown = Int((drag ?? Double(value)).rounded()).coerceIn(range.lowerBound, range.upperBound)
        VStack(alignment: .leading, spacing: 4) {
            Text(title(shown)).font(.system(size: 13)).foregroundStyle(fw.onSurface.opacity(enabled ? 1 : 0.5))
            FieldwatchSlider(
                value: Binding(
                    get: { drag ?? Double(value) },
                    set: { v in
                        drag = v
                        if !editing { commit() }
                    }
                ),
                range: Double(range.lowerBound)...Double(range.upperBound),
                step: step.map { Double($0) },
                enabled: enabled,
                onEditingChanged: { e in
                    editing = e
                    if !e { commit() }
                }
            )
        }
    }

    private func commit() {
        guard let d = drag else { return }
        drag = nil
        let n = Int(d.rounded()).coerceIn(range.lowerBound, range.upperBound)
        if n != value { onCommit(n) }
    }
}

// MARK: - Sections

private struct AppearanceSection: View {
    var settings: AppSettings
    var vm: FieldwatchViewModel

    var body: some View {
        SectionCard(title: "Appearance") {
            FieldwatchSwitch(
                "Night mode",
                subtitle: "Red on black so a dark sit stays dim. Display brightness does not change.",
                checked: settings.nightMode,
                onChange: { on in edit(vm) { $0.nightMode = on } }
            )
            FieldwatchSwitch(
                "Keep display awake",
                subtitle: "The display does not sleep while Live is showing, so you can keep an eye on the list. " +
                    "Scanning keeps running when the window is in the background either way. " +
                    "Turn this off to let the display sleep as usual.",
                checked: settings.keepScreenOn,
                onChange: { on in edit(vm) { $0.keepScreenOn = on } }
            )
            FieldwatchSwitch(
                "Privacy mode",
                subtitle: "Hides the last half of each MAC on screen and in sit reports. Coordinates show as masked, and street names are left out. " +
                    "The vendor prefix stays. Logs, matching, and Hunt still use the real address and position. " +
                    "The TAK feed pauses so those are not sent. The Path map still loads if Online place names and maps is on. " +
                    "Turn this off when you need the full address on screen.",
                checked: settings.demoMode,
                onChange: { on in edit(vm) { $0.demoMode = on } }
            )
        }
    }
}

private struct ScanningSection: View {
    var settings: AppSettings
    var vm: FieldwatchViewModel
    var throttleHint: String

    private static func label(_ i: ScanIntensity) -> String {
        switch i {
        case .saver: return "Battery saver"
        case .balanced: return "Balanced"
        case .performance: return "High performance"
        }
    }

    private static func detail(_ i: ScanIntensity) -> String {
        switch i {
        case .saver:
            return "Wi-Fi scans about every 45 s. Bluetooth filters duplicates, so each radio reports about once per scan window and its strength updates less often. Lowest CPU and battery."
        case .balanced:
            return "Wi-Fi scans about every 20 s. Bluetooth reports every advertisement it hears."
        case .performance:
            return "Wi-Fi scans about every 10 s. Bluetooth reports every advertisement it hears. Most CPU and battery."
        }
    }

    var body: some View {
        let order = ScanIntensity.allCases
        SectionCard(title: "Scanning") {
            CommitSlider(
                title: { i in "Scan intensity  ·  \(Self.label(order[i.coerceIn(0, order.count - 1)]))" },
                value: order.firstIndex(of: settings.intensity) ?? 2,
                range: 0...(order.count - 1),
                step: 1,
                onCommit: { i in
                    let next = order[i.coerceIn(0, order.count - 1)]
                    edit(vm) { $0.intensity = next }
                }
            )
            StableCaption(text: Self.detail(settings.intensity), variants: order.map { Self.detail($0) })
            Caption(
                "Wi-Fi reads every access point at once, then waits for the next scan. " +
                    "Bluetooth keeps listening between those scans."
            )
            StableCaption(
                text: throttleHint.ifBlank(" "),
                variants: ["Wi-Fi waiting on OS", "Wi-Fi scanning", "Wi-Fi next 99s", " "]
            )
            CommitSlider(
                title: { "Stale after \($0)s" },
                value: settings.staleSec,
                range: 15...180,
                onCommit: { n in edit(vm) { $0.staleSec = n } }
            )
            Caption(
                "A radio not heard for this long is marked gone. On-screen linger is the longer of this and Brief hold on Live → Display. " +
                    "Raise it if slow advertisers flicker to gone, especially on Battery saver."
            )
        }
    }
}

private struct LocationSection: View {
    var settings: AppSettings
    var vm: FieldwatchViewModel

    var body: some View {
        SectionCard(title: "Location") {
            FieldwatchSwitch(
                "Tag detections with location",
                subtitle: "Stamps this Mac’s position on each detection: Live detail, Moving with you, Debrief, and new log rows. " +
                    "That is where you were, not a location from the other radio. " +
                    "A Mac usually locates itself from nearby Wi-Fi, so the fix is coarse and the path may stay short. " +
                    "Heard-here TAK pins need this. Remote ID uses the coordinates in the advertisement. " +
                    "Turn this off to keep your position out of the logs.",
                checked: settings.tagLocation,
                onChange: { on in edit(vm) { $0.tagLocation = on } }
            )
            FieldwatchSwitch(
                "Online place names and maps",
                subtitle: "With internet, Debrief turns coordinates into a street and city, and Reports → Path loads a map under the trace. " +
                    "Nothing is sent to a Fieldwatch server. " +
                    "Offline, Debrief keeps the coordinates and Path stays a plain trace. " +
                    "Turn this off to leave streets and the map out.",
                checked: settings.onlineLookup,
                onChange: { on in edit(vm) { $0.onlineLookup = on } }
            )
        }
    }
}

private struct WatchlistSection: View {
    @Environment(\.fw) var fw
    var settings: AppSettings
    var vm: FieldwatchViewModel
    var namedRadios: Int
    var onRadioBookmarks: () -> Void

    var body: some View {
        let cueOn = settings.alertsEnabled && (settings.alertBeep || settings.alertVoice)
        SectionCard(title: "Watchlist") {
            FieldwatchSwitch(
                "Watchlist alerts",
                subtitle: "Beep, voice, flash, and the jump when a bookmarked signature or named radio appears. " +
                    "If this is off, bookmarks stay, and Fieldwatch stays quiet.",
                checked: settings.alertsEnabled,
                onChange: { on in edit(vm) { $0.alertsEnabled = on } }
            )
            FieldwatchActionButton(action: onRadioBookmarks) {
                Text("Named radios (\(namedRadios))")
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            Caption(
                "A name for one MAC. Alert is optional. Filters → Named radios shows them on Live. " +
                    "Signature watches stay on the Signatures tab."
            )
            FieldwatchSwitch(
                "Beep on watched signature",
                subtitle: "A double pip on the system volume when a watched radio first appears, or comes back after leaving. " +
                    "It does not repeat while that radio stays in view. You can use the beep, the voice, or both. " +
                    "Turn the volume up if you hear nothing, then click Test alert.",
                checked: settings.alertBeep,
                enabled: settings.alertsEnabled,
                onChange: { on in edit(vm) { $0.alertBeep = on } }
            )
            FieldwatchSwitch(
                "Voice on watched signature",
                subtitle: "Speaks the watch on the same volume as the beep. You can use the beep, the voice, or both. " +
                    "A second hit is skipped if Fieldwatch is already speaking.",
                checked: settings.alertVoice,
                enabled: settings.alertsEnabled,
                onChange: { on in edit(vm) { $0.alertVoice = on } }
            )
            ChipHeading(text: "What to say")
            FlowRow(spacing: 8) {
                ForEach(AlertVoiceWhat.allCases, id: \.self) { item in
                    FieldwatchFilterChip(
                        selected: settings.alertVoiceWhat == item,
                        enabled: settings.alertsEnabled && settings.alertVoice,
                        label: item.label(),
                        action: { edit(vm) { $0.alertVoiceWhat = item } }
                    )
                }
            }
            Caption(
                "Class is the group on Live, such as finder tags or audio. Signature is the catalog name, such as Apple AirTags. " +
                    "Class + signature says both. A named radio with Alert on always says the name you gave it."
            )
            FieldwatchActionButton("Test alert", enabled: cueOn, action: { vm.testWatchBeep() })
            FieldwatchSwitch(
                "Jump to new watched detection",
                subtitle: "Live scrolls to a new watched radio so you can see the flash. Turn this off if you do not want the list to move.",
                checked: settings.snapToBeep,
                enabled: cueOn,
                onChange: { on in edit(vm) { $0.snapToBeep = on } }
            )
            FieldwatchSwitch(
                "Notification banner",
                subtitle: "A silent macOS notification when a watched radio appears. The beep and the flash are enough for most sits. " +
                    "If no banner shows, allow Fieldwatch in System Settings → Notifications.",
                checked: settings.alertShade,
                enabled: settings.alertsEnabled,
                onChange: { on in edit(vm) { $0.alertShade = on } }
            )
        }
    }
}

private struct LoggingSection: View {
    @Environment(\.fw) var fw
    var settings: AppSettings
    var vm: FieldwatchViewModel
    var logLines: Int
    var onClear: () -> Void

    var body: some View {
        SectionCard(title: "Logging") {
            FieldwatchSwitch(
                "Write detections to disk",
                checked: settings.loggingEnabled,
                onChange: { on in edit(vm) { $0.loggingEnabled = on } }
            )
            StableCaption(
                text: settings.loggingEnabled
                    ? "Logging is on. New detections are added to the file."
                    : "Logging is off. Scanning still runs. Nothing new is written until you turn this on.",
                variants: [
                    "Logging is on. New detections are added to the file.",
                    "Logging is off. Scanning still runs. Nothing new is written until you turn this on.",
                ]
            )
            ChipHeading(text: "File format")
            FlowRow(spacing: 8) {
                ForEach(LogFormat.allCases, id: \.self) { item in
                    FieldwatchFilterChip(
                        selected: settings.logFormat == item,
                        label: item == .csv ? "CSV" : "JSON lines",
                        action: { edit(vm) { $0.logFormat = item } }
                    )
                }
            }
            Caption(
                "The file on disk is one detection per line. Reports → Log can share or save CSV, JSON, GPX, KML, or WiGLE."
            )
            CommitSlider(
                title: { "Rotate at \($0) KB" },
                value: settings.logRotateKb,
                range: 128...4096,
                onCommit: { n in edit(vm) { $0.logRotateKb = n } }
            )
            Text("\(logLines) lines this session  ·  \(vm.logBytes() / 1024) KB on disk.")
                .font(FW.mono(11))
                .foregroundStyle(fw.onSurface)
            FieldwatchActionButton("Clear log…", enabled: !vm.export.active, action: onClear)
            Caption("Share, Save, and Reset / clear log are also on the Reports tab.")
        }
    }
}

private struct DebriefSection: View {
    var settings: AppSettings
    var vm: FieldwatchViewModel

    var body: some View {
        SectionCard(title: "Debrief") {
            FieldwatchSwitch(
                "Show unmatched rotating BLE",
                subtitle: "Leaves unmatched Bluetooth radios that keep changing address out of the Debrief lists. The counts still include them. " +
                    "Extra attention, named signatures, bookmarks, and radios that sent a position stay. Sit export still has every radio.",
                checked: settings.debriefShowUnmatchedRandomBle,
                onChange: { on in edit(vm) { $0.debriefShowUnmatchedRandomBle = on } }
            )
            FieldwatchSwitch(
                "Show all radios",
                subtitle: "Debrief and Compare open with counts. A radio is listed when it is Extra attention, has a custom name, is marked Mine, or is bookmarked. " +
                    "Compare also lists a decoded value that changed. Turn this on for the full list. " +
                    "The PDF draws the counts as bars. Sit export still has every radio.",
                checked: settings.debriefShowAllRadios,
                onChange: { on in edit(vm) { $0.debriefShowAllRadios = on } }
            )
        }
    }
}

private struct SignaturesSection: View {
    var vm: FieldwatchViewModel
    var onImport: () -> Void
    var onRestore: () -> Void

    var body: some View {
        let busy = vm.export.active
        SectionCard(title: "Signatures") {
            Caption(
                "Export shares the catalog, including signatures you added. Import adds rows and does not delete any. " +
                    "Update from GitHub refreshes the stock signatures and leaves yours, your bookmarks, and your settings. " +
                    "It needs internet. Restore defaults deletes the signatures you added."
            )
            FlowRow(spacing: 8, lineSpacing: 8) {
                FieldwatchActionButton("Export signatures…", enabled: !busy, action: { vm.startSignatureShare() })
                FieldwatchActionButton("Save signatures to file…", enabled: !busy) {
                    presentSavePanel(name: vm.suggestedSignaturesName()) { url in vm.saveSignaturesToUri(uri: url) }
                }
                FieldwatchActionButton("Import signatures…", enabled: !busy, action: onImport)
            }
            FieldwatchActionButton("Update stock catalog from GitHub", enabled: !busy, action: { vm.updateStockCatalogFromGitHub() })
            FieldwatchActionButton("Restore default signatures & presets…", action: onRestore)
        }
    }
}

private struct SettingsBackupSection: View {
    var vm: FieldwatchViewModel
    var onImport: () -> Void

    var body: some View {
        let busy = vm.export.active
        SectionCard(title: "Settings backup") {
            Caption(
                "Saves switches, filters, presets, named radios, and signature watches. Not the catalog, and not logs. " +
                    "The catalog is Export signatures, above. Import replaces those items on this Mac and leaves the catalog. " +
                    "Fieldwatch asks before a file turns the TAK feed on or changes where it sends."
            )
            FlowRow(spacing: 8, lineSpacing: 8) {
                FieldwatchActionButton("Export settings…", enabled: !busy, action: { vm.startSettingsShare() })
                FieldwatchActionButton("Save settings to file…", enabled: !busy) {
                    presentSavePanel(name: vm.suggestedSettingsName()) { url in vm.saveSettingsToUri(uri: url) }
                }
                FieldwatchActionButton("Import settings…", enabled: !busy, action: onImport)
            }
        }
    }
}

/// Kotlin CreateDocument("application/json") launcher.
@MainActor
private func presentSavePanel(name: String, onPick: @escaping @MainActor (URL) -> Void) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = name
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    let done: (NSApplication.ModalResponse) -> Void = { resp in
        guard resp == .OK, let url = panel.url else { return }
        Task { @MainActor in onPick(url) }
    }
    if let window = NSApp.keyWindow {
        panel.beginSheetModal(for: window, completionHandler: done)
    } else {
        panel.begin(completionHandler: done)
    }
}

// MARK: - Permissions

private struct PermissionsSection: View {
    @Environment(\.fw) var fw
    @Environment(\.openURL) var openURL
    var locationOn: Bool
    @State private var bluetooth = ""
    @State private var location = ""

    var body: some View {
        SectionCard(title: "Permissions") {
            Caption(
                "macOS asks once for Bluetooth and Location. If you said no, turn Fieldwatch on in " +
                    "System Settings → Privacy & Security, then come back. Location is only needed for tagging and heard-here TAK pins."
            )
            row("Bluetooth", bluetooth, url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
            row("Location", location, url: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onChange(of: locationOn) { refresh() }
    }

    private func row(_ title: String, _ status: String, url: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(fw.onSurface)
                Text(status).font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant)
            }
            Spacer(minLength: 8)
            FieldwatchActionButton("Open System Settings") {
                if let u = URL(string: url) { openURL(u) }
            }
        }
    }

    private func refresh() {
        switch CBManager.authorization {
        case .allowedAlways: bluetooth = "Allowed"
        case .denied: bluetooth = "Not allowed. Scanning cannot hear BLE."
        case .restricted: bluetooth = "Restricted on this Mac"
        case .notDetermined: bluetooth = "Not asked yet. macOS asks when scanning starts."
        @unknown default: bluetooth = "Unknown"
        }
        let base: String
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways, .authorized: base = "Allowed"
        case .denied: base = "Not allowed. Detections are not tagged."
        case .restricted: base = "Restricted on this Mac"
        case .notDetermined: base = "Not asked yet"
        @unknown default: base = "Unknown"
        }
        location = locationOn ? base : "\(base)  ·  Location Services are off"
    }
}

// MARK: - Footer

private struct SettingsFooter: View {
    @Environment(\.fw) var fw
    @Environment(\.openURL) var openURL
    var catalogVersion: Int
    @State private var ipv4: [String] = []

    var body: some View {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        VStack(alignment: .leading, spacing: 8) {
            Caption("Fieldwatch \(version)  ·  Catalog \(catalogVersion)")
            Caption(
                "Wi-Fi and Bluetooth only. macOS does not show devices that are only connected to an access point. " +
                    "Fieldwatch sees access points and Bluetooth advertisers."
            )
            Caption(ipv4.isEmpty ? "This Mac’s IPv4  ·  none" : "This Mac’s IPv4  ·  \(ipv4.joined(separator: "  ·  "))")
                .textSelection(.enabled)
            Divider().overlay(fw.outline.opacity(0.45)).padding(.top, 16)
            VStack(spacing: 8) {
                Text("Copyright (c) 2026 Off Grid Pete LLC. All rights reserved.")
                    .font(.system(size: 10))
                    .foregroundStyle(fw.onSurfaceVariant)
                HStack(spacing: 10) {
                    socialChip("@OffGridPete", url: "https://instagram.com/OffGridPete")
                    socialChip("@OGridPete", url: "https://x.com/OGridPete")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        }
        .onAppear { ipv4 = localIpv4Addresses() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            ipv4 = localIpv4Addresses()
        }
    }

    private func socialChip(_ label: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { openURL(u) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "at").font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(fw.onSurfaceVariant)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(fw.surfaceVariant.opacity(0.65)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Up, non-loopback, non-link-local IPv4 addresses (Kotlin localIpv4Addresses).
private func localIpv4Addresses() -> [String] {
    var found: [String] = []
    var head: UnsafeMutablePointer<ifaddrs>? = nil
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let p = cursor {
        defer { cursor = p.pointee.ifa_next }
        let flags = Int32(p.pointee.ifa_flags)
        guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        if flags & IFF_UP == 0 || flags & IFF_LOOPBACK != 0 { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) != 0 { continue }
        let ip = String(cString: host)
        if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") { continue }
        if !found.contains(ip) { found.append(ip) }
    }
    return found
}

// MARK: - TAK

private struct TakFeedSettings: View {
    @Environment(\.fw) var fw
    var settings: AppSettings
    var vm: FieldwatchViewModel
    var status: TakFeedStatus
    @State private var hostText: String? = nil
    @State private var portText: String? = nil

    var body: some View {
        let preset = TakPublish.udpPreset(host: settings.takHost, port: settings.takPort)
        let off = settings.demoMode
        VStack(alignment: .leading, spacing: 10) {
            ChipHeading(text: "Destination")
            FlowRow(spacing: 8) {
                presetChip("This Mac", .thisPhone, current: preset, enabled: !off)
                presetChip("LAN multicast", .lanMulticast, current: preset, enabled: !off)
                presetChip("Custom", .custom, current: preset, enabled: !off)
            }
            Caption(
                "This Mac is a TAK client on this Mac, at \(TakDefaults.LOOPBACK):\(TakDefaults.PORT). " +
                    "LAN multicast is \(TakDefaults.SA_HOST):\(TakDefaults.SA_PORT), for TAK apps on other devices on this network. " +
                    "Custom is one address. UDP only. A TAK server on TCP 8087 is not this feed. " +
                    "To reach one device, use Custom with its IPv4 address and port \(TakDefaults.PORT)."
            )
            FieldwatchOutlinedField(
                label: "Host",
                text: Binding(
                    get: { hostText ?? settings.takHost },
                    set: { value in
                        hostText = value
                        let trimmed = value.trim()
                        if trimmed.isNotEmpty { edit(vm) { $0.takHost = trimmed } }
                    }
                ),
                placeholder: TakDefaults.HOST,
                enabled: !off,
                monospaced: true
            )
            FieldwatchOutlinedField(
                label: "Port",
                text: Binding(
                    get: { portText ?? String(settings.takPort) },
                    set: { value in
                        let filtered = String(value.filter { $0.isASCII && $0.isNumber }.prefix(5))
                        portText = filtered
                        if let n = Int(filtered), (1...65_535).contains(n) { edit(vm) { $0.takPort = n } }
                    }
                ),
                placeholder: String(TakDefaults.PORT),
                supportingText: "UDP. This Mac uses \(TakDefaults.PORT). LAN multicast uses \(TakDefaults.SA_PORT). Not TCP 8087.",
                enabled: !off,
                monospaced: true
            )
            Text(takStatusLine(status))
                .font(.system(size: 11))
                .foregroundStyle(fw.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            ChipHeading(text: "What to send")
            FlowRow(spacing: 8) {
                FieldwatchFilterChip(selected: settings.takAttention, enabled: !off, label: "Extra attention",
                                     action: { edit(vm) { $0.takAttention.toggle() } })
                FieldwatchFilterChip(selected: settings.takPayloadFix, enabled: !off, label: "Payload location",
                                     action: { edit(vm) { $0.takPayloadFix.toggle() } })
                FieldwatchFilterChip(selected: settings.takWatchlist, enabled: !off, label: "Watchlist",
                                     action: { edit(vm) { $0.takWatchlist.toggle() } })
                FieldwatchFilterChip(selected: settings.takAllSignatures, enabled: !off, label: "All signatures",
                                     action: { edit(vm) { $0.takAllSignatures.toggle() } })
            }
            Caption(
                "Turn on any combination. Extra attention sends body cameras, glasses, recorders, pentest gear, and public-safety access points. " +
                    "Payload location sends Remote ID and any radio that advertises its own coordinates. " +
                    "Watchlist sends bookmarked signatures and named radios with Alert on. " +
                    "All signatures sends every labeled radio, which is noisy in a crowd. " +
                    "Unmatched radios are never sent. A pin needs coordinates, from the advertisement or from Tag detections with location."
            )
            ChipHeading(text: "How long a spot stays")
            FlowRow(spacing: 8) {
                ForEach(TakGnssHold.allCases, id: \.self) { item in
                    FieldwatchFilterChip(selected: settings.takRadioHold == item, enabled: !off, label: item.label(),
                                         action: { edit(vm) { $0.takRadioHold = item } })
                }
            }
            Caption(
                "After a radio leaves, the spot keeps its name for this long. The time starts when it leaves. " +
                    "Until deleted stays until the feed is turned off. " +
                    "This Mac’s Fieldwatch marker stays for about 2 minutes."
            )
            ChipHeading(text: "Floods")
            FlowRow(spacing: 8) {
                ForEach(TakFloodSend.allCases, id: \.self) { item in
                    FieldwatchFilterChip(selected: settings.takFlood == item, enabled: !off, label: item.label(),
                                         action: { edit(vm) { $0.takFlood = item } })
                }
            }
            Caption(
                "Adds a note to this Mac’s Fieldwatch marker when a flood is detected, until the flood ends. Not its own pin. " +
                    "This does not change the red line on Live. A store full of radios advertising pairing can cause this. " +
                    "The note does not say it was one radio, and it does not name a tool. This Mac needs a location fix."
            )
        }
        .onChange(of: settings.takHost) { _, new in hostText = new }
        .onChange(of: settings.takPort) { _, new in portText = String(new) }
    }

    private func presetChip(_ title: String, _ p: TakUdpPreset, current: TakUdpPreset, enabled: Bool) -> some View {
        FieldwatchFilterChip(selected: current == p, enabled: enabled, label: title) {
            if p == .custom && current == .custom { return }
            let (host, port) = TakPublish.applyPreset(preset: p)
            edit(vm) { s in
                s.takHost = host
                s.takPort = port
            }
        }
    }
}

private func takStatusLine(_ status: TakFeedStatus) -> String {
    if status.paused { return "Feed status  ·  paused (Privacy mode)" }
    if let error = status.error {
        let whenAt = takStatusWhen(status.at)
        return "Feed status  ·  error: \(error)" + (whenAt.isNotEmpty ? "  ·  \(whenAt)" : "")
    }
    if status.at <= 0 { return "Feed status  ·  no send yet this session" }
    var bits: [String] = []
    bits.append("on the feed \(status.onFeed)")
    bits.append("sent \(status.sent)")
    if status.gone > 0 { bits.append(status.gone == 1 ? "1 gone" : "\(status.gone) gone") }
    if status.dest.isNotBlank { bits.append(status.dest) }
    let whenAt = takStatusWhen(status.at)
    if whenAt.isNotEmpty { bits.append(whenAt) }
    let head = "Feed status  ·  \(bits.joined(separator: "  ·  "))"
    if status.detail.isNotBlank && status.sent == 0 && status.gone == 0 {
        return "\(head)  ·  \(status.detail)"
    }
    return head
}

private func takStatusWhen(_ at: Int) -> String {
    at <= 0 ? "" : formatMs(at, "HH:mm:ss")
}
