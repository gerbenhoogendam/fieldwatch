import SwiftUI
import AppKit
import FieldwatchCore

// Port of ui/screen/LiveScreens.kt (the Live display) plus the Display panel (`ViewPicker`) from
// ui/FieldwatchAppUi.kt. Rows and the list/timeline views: LiveRows.swift. Classic radar: RadarView.swift.
// By class outline: ClassOutlineView.swift.
//
// macOS: the GNSS interference notice/dialog is dropped (no receiver). The Location-off banner opens
// System Settings → Privacy → Location Services. Flood and rename dialogs are `.alert`s.

// MARK: - Live root

/// Kotlin `LivePane(state, vm, onOpen)`. `onHunt` is a macOS addition for the row context menu's Hunt item;
/// when nil the menu starts the hunt on the view model and opens the row (detail shows Hunt).
struct LivePane: View {
    var state: FieldwatchUi
    var vm: FieldwatchViewModel
    var onOpen: (Sighting) -> Void
    var onHunt: ((Sighting) -> Void)? = nil
    @State var renameSit = false
    @State var renameDraft = ""
    @Environment(\.fw) var fw

    var body: some View {
        let s = state.settings
        let lookup = LiveLookup(state: state, vm: vm)
        let rows = LiveRowOptions(
            sort: s.strengthSort,
            windowMs: s.averageWindowSec.coerceIn(10, 180) * 1000,
            showBar: s.showRssiBar,
            showNewAge: state.filter.arrivalsOnly,
            showFleet: s.showFleetName,
            showFrequency: s.showFrequency,
            showSeenTimes: s.showSeenTimes,
            titleLine: s.listTitleLine,
            subtitleLine: s.listSubtitleLine,
            demoMode: s.demoMode,
            flashKeys: vm.flashKeys,
            alertedKeys: vm.alertedKeys,
            selectedKey: state.selected?.key,
            lookup: lookup,
            onHunt: onHunt
        )
        VStack(alignment: .leading, spacing: 0) {
            banners
            content(rows: rows)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(fw.background)
        .onAppear { vm.refreshLocation() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            vm.refreshLocation()
        }
        .alert(
            vm.floodNotice?.title() ?? "",
            isPresented: Binding(
                get: { vm.floodNotice?.showDialog == true },
                set: { _ in }
            ),
            presenting: vm.floodNotice
        ) { _ in
            Button("Hide these") { vm.hidePairingFlood() }
            Button("Continue", role: .cancel) { vm.dismissPairingFlood() }
        } message: { notice in
            Text(notice.body())
        }
        .alert("Rename sit", isPresented: $renameSit) {
            TextField("Name", text: $renameDraft)
            Button("Save") {
                if let open = state.sit.open { vm.renameSit(id: open.id, name: renameDraft) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: renameDraft) { _, v in
            if v.count > Sit.NAME_MAX { renameDraft = v.take(Sit.NAME_MAX) }
        }
    }

    @ViewBuilder
    private func content(rows: LiveRowOptions) -> some View {
        let live = state.filtered
        let pinEnd = state.settings.listSort == .arrival
        switch state.settings.viewMode {
        case .radar:
            RadarView(
                devices: live, vm: vm, sort: rows.sort, windowMs: rows.windowMs, onOpen: onOpen,
                emptyHint: liveEmpty(state: state, fallback: LIVE_RADAR_EMPTY),
                showFleet: rows.showFleet, demoMode: rows.demoMode,
                flashKeys: rows.flashKeys, alertedKeys: rows.alertedKeys,
                lookup: rows.lookup
            )
        case .list, .hybrid:
            RankedList(
                devices: live, vm: vm, onOpen: onOpen,
                sparklines: state.settings.viewMode == .hybrid,
                pinEnd: pinEnd,
                layoutEpoch: state.settings.scanControlsExpanded,
                emptyHint: liveEmpty(state: state, fallback: LIVE_LIST_EMPTY),
                rows: rows
            )
        case .timeline:
            PresenceTimelineView(devices: live, vm: vm, onOpen: onOpen, rows: rows)
        case .byClass:
            ClassOutlineView(
                devices: live, vm: vm, state: state, onOpen: onOpen,
                emptyHint: liveEmpty(state: state, fallback: LIVE_CLASS_EMPTY),
                rows: rows
            )
        }
    }

    @ViewBuilder
    private var banners: some View {
        if !state.locationOn {
            LocationOffBanner()
        }
        if let notice = vm.floodNotice, !notice.showDialog {
            hint(notice.line(), color: fw.error)
            FieldwatchSwitch("Hide this burst", checked: vm.floodHide.episodeOn) { vm.setHideBurst(on: $0) }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
        }
        if vm.floodHide.keys.isNotEmpty && !vm.floodHide.episodeOn {
            let n = vm.floodHide.keys.count
            FieldwatchSwitch(n == 1 ? "Hiding 1 flood radio" : "Hiding \(n) flood radios", checked: true) { on in
                if !on { vm.clearHiddenFlood() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        if state.displayPaused {
            hint("Display paused · radios still scanning and logging. Filters still apply when you run again. Press Run (Space) to run the list again.")
        }
        if state.filter.arrivalsOnly {
            hint(
                state.arrivalsLearning ? "New only · learning sitting Wi-Fi"
                    : state.hiddenKnown > 0 ? "New only · \(state.hiddenKnown) hidden" : "New only"
            )
        }
        if state.filter.movingWithYou {
            hint("Follow · path \(Int(state.operatorSpanM)) m · Start over clears the path")
        }
        if state.filter.watchedOnly {
            hint("Watched only")
        }
        if state.filter.customNamesOnly {
            hint("Named radios only")
        }
        if let openSit = state.sit.open {
            let dur = Sit.fmtDuration(ms: openSit.durationMs(now: nowMs()))
            let cap = state.sit.memoryTight ? " · memory cap" : state.sit.atCap ? " · \(Sit.RADIO_CAP) cap" : ""
            Button {
                renameDraft = openSit.name
                renameSit = true
            } label: {
                Text("Sit · \(openSit.name) · \(dur) · \(state.sit.radioCount) radios\(cap)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(fw.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Rename sit")
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private func hint(_ text: String, color: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color ?? fw.onSurfaceVariant)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }
}

/// Kotlin `LocationOffBanner`. macOS: CoreWLAN hides SSIDs / BSSIDs without Location access.
struct LocationOffBanner: View {
    @Environment(\.fw) var fw

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Location is off. macOS will not return Wi-Fi names or BSSIDs to Fieldwatch.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(fw.error)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(fw.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

// MARK: - Empty states

private func arrivalsEmpty(state: FieldwatchUi) -> String? {
    let f = state.filter
    if f.movingWithYou {
        if !state.settings.tagLocation {
            return "Moving with you needs Settings → Tag detections with GPS, then a walk or drive."
        }
        if state.operatorSpanM < 45.0 {
            return "GPS path \(Int(state.operatorSpanM)) m — too short. Keep moving. " +
                "If this stays 0, Location is not updating."
        }
        if f.customNamesOnly || f.watchedOnly || f.namedOnly || f.namedOnlyImplied() {
            return "No loud BLE has stayed with you among the radios still allowed. " +
                "Click the Moving with you preset to test BLE, or turn off Signatures only / Show only / Named radios only / Watched only."
        }
        if f.hideMine {
            return "No loud BLE has stayed with you along this path. Wi-Fi access points stay hidden. Radios marked Mine stay off this list."
        }
        return "No loud BLE has stayed with you along this path. Wi-Fi access points stay hidden. A tag in your bag or car should show. Find My MAC rotation will not stitch."
    }
    if f.arrivalsOnly {
        if state.arrivalsLearning {
            return "Hiding sitting access points until the next Wi-Fi scan. New Bluetooth still shows right away."
        }
        if state.hiddenKnown > 0 {
            return "\(state.hiddenKnown) already seen are hidden. A new radio stays while we hear it, then at least as long as Brief hold after the last packet."
        }
        return "Waiting for a new Wi-Fi or BLE radio. It stays while we hear it, then at least as long as Brief hold after the last packet."
    }
    if f.watchedOnly {
        return "No watched radios on the air. Bookmark a signature, turn Alert on a Named radio, or turn off Filters → Watched only."
    }
    if f.customNamesOnly {
        return "No named radios on the air. Set a custom name on detail, or turn off Filters → Named radios only."
    }
    return nil
}

let LIVE_LIST_EMPTY =
    "No live emitters match the current filter. If this just emptied, the OS may be between scan windows — the last set is held and should return without a burst. Use Timeline for recent disappearances."

let LIVE_CLASS_EMPTY =
    "No live emitters match the current filter. If this just emptied, the OS may be between scan windows — the last set is held and should return without a burst."

let LIVE_RADAR_EMPTY = "No devices match the current filter"

/// Keeps the filter sentence. Adds the Diagnostics pointer only while a scan is blocked.
func liveEmpty(state: FieldwatchUi, fallback: String) -> String {
    let base = arrivalsEmpty(state: state) ?? fallback
    return state.scanBlocked ? "\(base) \(ScanStatus.EMPTY_POINTER)" : base
}

// MARK: - Per-refresh lookups and row options

/// Built once per Live refresh from `FieldwatchUi.fleets` / `.watchlist` so rows do not scan the catalog.
/// Same answers as vm.fleetName / fleetKind / fleetColor / fleetHasDecode / hasAttention / watchLabelFor /
/// hasObserverNote / isMine / isWatched (first catalog match by id; first bookmark by device key).
@MainActor
struct LiveLookup {
    struct FleetInfo {
        var name: String
        var kind: SignatureClass
        var colorIndex: Int
        var hasDecode: Bool
        var attention: Bool
    }

    var vm: FieldwatchViewModel
    private var complete = false
    private var fleets: [String: FleetInfo] = [:]
    private var labels: [String: String] = [:]
    private var notes: Set<String> = []
    private var mine: Set<String> = []
    private var watched: Set<String> = []

    /// Fallback: every answer goes through the view model.
    init(vm: FieldwatchViewModel) { self.vm = vm }

    init(state: FieldwatchUi, vm: FieldwatchViewModel) {
        self.vm = vm
        complete = true
        for f in state.fleets where fleets[f.id] == nil {
            fleets[f.id] = FleetInfo(
                name: f.name, kind: f.kind, colorIndex: f.colorIndex,
                hasDecode: f.decode != nil, attention: f.attentionNote.isNotBlank
            )
        }
        var seen = Set<String>()
        for w in state.watchlist {
            guard let key = w.deviceKey else { continue }
            if seen.insert(key).inserted {
                let label = w.label.trim()
                if label.isNotEmpty { labels[key] = label }
                if w.observerNotes.trim().isNotEmpty { notes.insert(key) }
            }
            if w.mine { mine.insert(key) }
            if w.alert { watched.insert(key) }
        }
    }

    func fleetName(_ id: String) -> String {
        if let f = fleets[id] { return f.name }
        return complete ? id : vm.fleetName(id: id)
    }

    func fleetKind(_ id: String) -> SignatureClass? {
        if let f = fleets[id] { return f.kind }
        return complete ? nil : vm.fleetKind(id: id)
    }

    func fleetColorIndex(_ id: String) -> Int {
        if let f = fleets[id] { return f.colorIndex }
        return complete ? 0 : vm.fleetColor(id: id)
    }

    /// Kotlin `Color(Palette.color(vm.fleetColor(id)))` (not yet night-filtered).
    func fleetPaletteColor(_ id: String) -> Color { fleetColor(fleetColorIndex(id)) }

    func fleetHasDecode(_ id: String) -> Bool {
        if let f = fleets[id] { return f.hasDecode }
        return complete ? false : vm.fleetHasDecode(id: id)
    }

    func hasAttention(_ device: Sighting) -> Bool {
        if !complete { return vm.hasAttention(device: device) }
        return device.fleetIds.contains { fleets[$0]?.attention == true }
    }

    func watchLabelFor(_ key: String) -> String? { complete ? labels[key] : vm.watchLabelFor(deviceKey: key) }
    func hasObserverNote(_ device: Sighting) -> Bool { complete ? notes.contains(device.key) : vm.hasObserverNote(device: device) }
    func isMine(_ key: String) -> Bool { complete ? mine.contains(key) : vm.isMine(deviceKey: key) }
    func isWatched(_ key: String) -> Bool { complete ? watched.contains(key) : vm.isWatched(deviceKey: key) }

    func names(_ device: Sighting) -> [String] { device.fleetIds.map { fleetName($0) } }

    /// Kotlin `Sighting.rowTitle(vm)`.
    func rowTitle(_ device: Sighting) -> String {
        if let watch = watchLabelFor(device.key), watch.isNotBlank { return watch }
        return device.listTitle(signatureNames: names(device))
    }
}

/// Display settings shared by every Live view, resolved once per refresh in `LivePane`.
struct LiveRowOptions {
    var sort: StrengthSort
    var windowMs: Int
    var showBar: Bool
    var showNewAge: Bool
    var showFleet: Bool
    var showFrequency: Bool
    var showSeenTimes: Bool
    var titleLine: ListLine
    var subtitleLine: ListLine
    var demoMode: Bool
    var flashKeys: Set<String>
    var alertedKeys: Set<String>
    var selectedKey: String?
    var lookup: LiveLookup
    var onHunt: ((Sighting) -> Void)?
}

// MARK: - Shared text helpers

func liveListSubtitle(device: Sighting, subtitleLine: ListLine, names: [String], demoMode: Bool, watchName: String? = nil) -> String {
    let raw = MacUtil.redactMacIn(text: device.listLineText(line: subtitleLine, signatureNames: names, watchName: watchName),
                                  mac: device.mac, demo: demoMode)
    let body = raw.equals("unnamed LE", ignoreCase: true) ? "unnamed" : raw
    let crumbs = device.statusCrumbs()
    var out = ""
    if body.isNotEmpty { out += body }
    if crumbs.isNotEmpty {
        if out.isNotEmpty { out += "  " }
        out += crumbs
    }
    return out
}

/// Title line, with rand / pair / gone moved onto it when the subtitle is None.
func liveRowTitle(device: Sighting, titleLine: ListLine, subtitleLine: ListLine, names: [String], watch: String?, demoMode: Bool) -> String {
    let crumbs = device.statusCrumbs()
    let core = MacUtil.redactMacIn(text: device.listLineText(line: titleLine, signatureNames: names, watchName: watch),
                                   mac: device.mac, demo: demoMode)
    if subtitleLine == ListLine.none && crumbs.isNotEmpty {
        return core.isNotEmpty ? "\(core)  \(crumbs)" : crumbs
    }
    return core
}

func liveRadioFactLine(device: Sighting) -> String? {
    var parts: [String] = []
    if device.channel != 0 { parts.append("ch\(device.channel)") }
    if device.frequencyMhz != 0 { parts.append("\(device.frequencyMhz)MHz") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

func liveSeenTimesLabel(device: Sighting, now: Int) -> String {
    let first = liveFormatAge(ms: now - device.firstSeen)
    let lastMs = now - device.lastSeen
    let last = lastMs < 1_000 ? "now" : liveFormatAge(ms: lastMs)
    return "first \(first)  ·  last \(last)"
}

func liveFormatAge(ms: Int) -> String {
    let sec = (ms / 1000).coerceAtLeast(0)
    if sec < 60 { return "\(sec)s" }
    if sec < 3600 {
        let m = sec / 60, s = sec % 60
        return s == 0 ? "\(m)m" : "\(m)m \(s)s"
    }
    let h = sec / 3600, m = (sec % 3600) / 60
    return m == 0 ? "\(h)h" : "\(h)h \(m)m"
}

// MARK: - Display panel

/// Kotlin `ViewPicker` (FieldwatchAppUi.kt): the Display panel. On macOS it is the content of the
/// Live toolbar Tune popover. `maxHeight` caps the panel; it scrolls when the window is short.
struct ViewPicker: View {
    @Environment(\.fw) var fw
    var maxHeight: CGFloat
    var mode: ViewMode
    var sort: StrengthSort
    var listSort: ListSort
    var windowSec: Int
    var decaySec: Int
    var showBar: Bool
    var showFleet: Bool
    var showFrequency: Bool
    var showSeenTimes: Bool
    var titleLine: ListLine
    var subtitleLine: ListLine
    var onChangeView: (ViewMode) -> Void
    var onChangeSort: (StrengthSort, Int?) -> Void
    var onChangeListSort: (ListSort) -> Void
    var onChangeDecay: (Int) -> Void
    var onToggleBar: () -> Void
    var onToggleFleet: () -> Void
    var onToggleFrequency: () -> Void
    var onToggleSeenTimes: () -> Void
    var onChangeTitleLine: (ListLine) -> Void
    var onChangeSubtitleLine: (ListLine) -> Void

    /// Measured panel height; the popover is as tall as the panel up to `maxHeight`, then scrolls.
    @State var contentHeight: CGFloat = 430

    var body: some View {
        let cap = (maxHeight - 8).coerceAtLeast(140)
        ScrollView {
            panel.background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { contentHeight = g.size.height }
                        .onChange(of: g.size.height) { _, h in contentHeight = h }
                }
            )
        }
        .scrollDisabled(contentHeight <= cap)
        .frame(width: 300, height: min(contentHeight, cap))
        .background(fw.surface)
    }

    private var sortLabel: String {
        switch listSort {
        case .strength: return sort == .average ? "Strongest · avg \(windowSec)s" : "Strongest"
        case .newest: return "Newest heard"
        case .newestAlert: return "Newest alert"
        case .firstSeen: return "Newest arrival"
        case .arrival: return "New at bottom"
        case .name: return "Name A–Z"
        case .signatures: return "Signatures first"
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Display")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(fw.onSurfaceVariant)
            FieldwatchDropdownField(
                label: "View", options: ViewMode.allCases, selection: mode,
                title: { $0.label() }, onSelect: onChangeView
            )
            PanelMenuField(label: "Sort", value: sortLabel) {
                menuItem("Strongest signal", checked: listSort == .strength && sort == .instant) { onChangeSort(.instant, nil) }
                menuItem("Strongest (avg 30s)", checked: listSort == .strength && sort == .average) { onChangeSort(.average, 30) }
                menuItem("Newest heard", checked: listSort == .newest) { onChangeListSort(.newest) }
                menuItem("Newest alert", checked: listSort == .newestAlert) { onChangeListSort(.newestAlert) }
                menuItem("Newest arrival", checked: listSort == .firstSeen) { onChangeListSort(.firstSeen) }
                menuItem("New at bottom", checked: listSort == .arrival) { onChangeListSort(.arrival) }
                menuItem("Name A–Z", checked: listSort == .name) { onChangeListSort(.name) }
                menuItem("Signatures first", checked: listSort == .signatures) { onChangeListSort(.signatures) }
            }
            PanelMenuField(label: "Brief hold", value: decaySec <= 0 ? "Off" : "Hold \(decaySec)s") {
                menuItem("Off — Stale after only", checked: decaySec <= 0) { onChangeDecay(0) }
                ForEach([10, 30, 60], id: \.self) { sec in
                    menuItem("Hold \(sec)s after last packet", checked: decaySec == sec) { onChangeDecay(sec) }
                }
            }
            FieldwatchDropdownField(
                label: "Title line", options: [ListLine.advertisedName, .nameAndType, .mac], selection: titleLine,
                title: { listLineLabel($0) }, onSelect: onChangeTitleLine
            )
            FieldwatchDropdownField(
                label: "Subtitle line", options: [ListLine.advertisedName, .nameAndType, .mac, ListLine.none],
                selection: subtitleLine, title: { listLineLabel($0) }, onSelect: onChangeSubtitleLine
            )
            VStack(spacing: 10) {
                FieldwatchSwitch("RSSI bars", checked: showBar) { _ in onToggleBar() }
                FieldwatchSwitch("Signature names", checked: showFleet) { _ in onToggleFleet() }
                FieldwatchSwitch("Frequency", checked: showFrequency) { _ in onToggleFrequency() }
                FieldwatchSwitch("First / last seen", checked: showSeenTimes) { _ in onToggleSeenTimes() }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func menuItem(_ title: String, checked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

extension ViewPicker {
    /// Convenience wiring, same as the Kotlin call site in FieldwatchAppUi.
    init(state: FieldwatchUi, vm: FieldwatchViewModel, maxHeight: CGFloat = 640) {
        let s = state.settings
        self.init(
            maxHeight: maxHeight,
            mode: s.viewMode, sort: s.strengthSort, listSort: s.listSort,
            windowSec: s.averageWindowSec, decaySec: s.decaySec,
            showBar: s.showRssiBar, showFleet: s.showFleetName,
            showFrequency: s.showFrequency, showSeenTimes: s.showSeenTimes,
            titleLine: s.listTitleLine, subtitleLine: s.listSubtitleLine,
            onChangeView: { vm.setViewMode(mode: $0) },
            onChangeSort: { vm.setStrengthSort(sort: $0, windowSec: $1) },
            onChangeListSort: { vm.setListSort(sort: $0) },
            onChangeDecay: { vm.setDecaySec(sec: $0) },
            onToggleBar: { vm.toggleRssiBar() },
            onToggleFleet: { vm.toggleFleetName() },
            onToggleFrequency: { vm.toggleFrequency() },
            onToggleSeenTimes: { vm.toggleSeenTimes() },
            onChangeTitleLine: { vm.setListTitleLine(line: $0) },
            onChangeSubtitleLine: { vm.setListSubtitleLine(line: $0) }
        )
    }
}

private func listLineLabel(_ line: ListLine) -> String {
    switch line {
    case .advertisedName: return "Advertised name"
    case .nameAndType: return "Name + type"
    case .mac: return "MAC address"
    case ListLine.none: return "None"
    }
}

/// Dropdown whose field text differs from its menu items (Sort, Brief hold). Same look as FieldwatchDropdownField.
private struct PanelMenuField<Content: View>: View {
    @Environment(\.fw) var fw
    var label: String
    var value: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant)
            Menu {
                content()
            } label: {
                HStack {
                    Text(value).font(.system(size: 12)).foregroundStyle(fw.onSurface)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(fw.onSurfaceVariant)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(fw.background.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(fw.outline, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
    }
}
