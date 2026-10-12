import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FieldwatchCore

// Port of ui/FieldwatchAppUi.kt.
//
// Android: one Activity, a header bar, five bottom tabs, a NavHost with full-page detail / hunt routes, and
// AlertDialogs for export progress and notices. macOS: one window with a NavigationSplitView. The sidebar holds
// the five tabs, the window toolbar carries the FIELDWATCH header (counts + hint words + · SIT / · PAUSED), and
// on Live a Pause/Run button and the Tune button that opens Display as a popover. Device detail is a trailing
// inspector; Hunt is a sheet; Candidates / Named radios / Diagnostics push inside a NavigationStack.

// Navigation types (FieldwatchTab, FieldwatchRoute, FieldwatchNav) live in FieldwatchNav.swift.

// MARK: - Root

/// Kotlin `FieldwatchRoot(vm, onRequestPermissions)`. On macOS the permission request lives in the gate itself.
struct FieldwatchRoot: View {
    var vm: FieldwatchViewModel
    var nav: FieldwatchNav
    /// The gate was shown and answered once. A permission still undecided brings it back.
    @AppStorage("fieldwatch.permissionGateAcknowledged") var gateAcknowledged = false
    @State var gateSkipped = false
    @State var bluetooth: PrivacyPermission = .bluetooth()
    @State var location: PrivacyPermission = .location()

    var body: some View {
        let state = vm.ui
        Group {
            if !state.settings.disclaimerOk() {
                DisclaimerGate(onAccept: { vm.acceptDisclaimer() })
            } else if showPermissionGate(state) {
                PermissionGate(
                    bluetooth: bluetooth,
                    location: location,
                    onRefresh: refreshPermissions,
                    onContinue: {
                        gateAcknowledged = true
                        gateSkipped = true
                        vm.refreshPermissions()
                        vm.startScan()
                    }
                )
            } else {
                FieldwatchShell(state: state, vm: vm, nav: nav)
            }
        }
        .modifier(FWWindowBackground())
        .fieldwatchTheme(nightMode: state.settings.nightMode)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
            vm.refreshLocation()
        }
    }

    private func showPermissionGate(_ state: FieldwatchUi) -> Bool {
        if gateSkipped { return false }
        let undecided = bluetooth == .notDetermined || location == .notDetermined
        let allGranted = bluetooth == .granted && location == .granted
        return undecided || (!allGranted && !gateAcknowledged)
    }

    private func refreshPermissions() {
        let bt = PrivacyPermission.bluetooth()
        let loc = PrivacyPermission.location()
        guard bt != bluetooth || loc != location else { return }
        bluetooth = bt
        location = loc
        vm.refreshPermissions()
    }
}

private struct FWWindowBackground: ViewModifier {
    @Environment(\.fw) var fw
    func body(content: Content) -> some View {
        content.background(fw.background.ignoresSafeArea())
    }
}

// MARK: - Disclaimer gate

private struct DisclaimerGate: View {
    @Environment(\.fw) var fw
    var onAccept: () -> Void
    @State var agreed = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Disclaimer and license")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Disclaimer")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.top, 20)
                    Text(FieldwatchDisclaimer.firstRunDisclaimer)
                        .font(.system(size: 13))
                        .padding(.top, 8)
                    Text(FieldwatchDisclaimer.LICENSE_TITLE)
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.top, 24)
                    Text(FieldwatchDisclaimer.LICENSE_BODY)
                        .font(.system(size: 13))
                        .padding(.top, 8)
                    Text(FieldwatchDisclaimer.ACCEPT)
                        .font(.system(size: 13))
                        .padding(.top, 20)
                }
                .foregroundStyle(fw.onSurface)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            Rectangle().fill(fw.outline).frame(height: 1)
            HStack(spacing: 12) {
                Toggle(isOn: $agreed) {
                    Text("I have read this and I agree").font(.system(size: 13)).foregroundStyle(fw.onSurface)
                }
                .toggleStyle(.checkbox)
                Spacer()
                FieldwatchActionButton("Quit") { NSApp.terminate(nil) }
                FieldwatchActionButton("Continue", enabled: agreed, prominent: true, action: onAccept)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(fw.surface)
        }
    }
}

// MARK: - Permission gate

/// Bluetooth / Location status for the gate and Diagnostics, read from the runtime's `RadioPermissions`.
enum PrivacyPermission: Equatable {
    case notDetermined, granted, denied
    /// Location Services are switched off for the whole Mac.
    case servicesOff

    static func bluetooth() -> PrivacyPermission {
        if RadioPermissions.bluetoothGranted() { return .granted }
        if RadioPermissions.bluetoothNotDetermined() { return .notDetermined }
        return .denied
    }

    static func location() -> PrivacyPermission {
        switch RadioPermissions.locationAccess() {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .servicesOff: return .servicesOff
        }
    }

    var label: String {
        switch self {
        case .notDetermined: return "not asked yet"
        case .granted: return "granted"
        case .denied: return "denied"
        case .servicesOff: return "Location Services off"
        }
    }

    /// Shows the macOS prompts that were never answered (both radios at once, like the Android launcher).
    static func request() { RadioPermissions.request() }
}

/// macOS stand-in for the Android "Fieldwatch needs the radios" screen. Scanning still waits for the disclaimer;
/// a denied permission only narrows what is heard, so Continue is always available.
private struct PermissionGate: View {
    @Environment(\.fw) var fw
    var bluetooth: PrivacyPermission
    var location: PrivacyPermission
    var onRefresh: () -> Void
    var onContinue: () -> Void

    var body: some View {
        let allGranted = bluetooth == .granted && location == .granted
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 14) {
                Text("Fieldwatch needs the radios")
                    .font(.system(size: 22, weight: .semibold))
                Text("Bluetooth and Location let Fieldwatch passively watch advertised Wi-Fi networks and BLE devices. Nothing is transmitted.")
                    .font(.system(size: 13))
                    .foregroundStyle(fw.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                PermissionRow(
                    title: "Bluetooth",
                    status: bluetooth,
                    why: "Lets Fieldwatch hear BLE advertisers. If you deny it, BLE stays off and Wi-Fi still scans.",
                    onGrant: { PrivacyPermission.request(); onRefresh() },
                    onSettings: { RadioPermissions.openBluetoothSettings() }
                )
                PermissionRow(
                    title: "Location",
                    status: location,
                    why: "macOS reveals Wi-Fi network names (SSIDs) and access-point addresses (BSSIDs) only to apps with Location. If you deny it, Wi-Fi rows show signal, channel, and security without a name or address, and detections carry no position. BLE still scans.",
                    onGrant: { PrivacyPermission.request(); onRefresh() },
                    onSettings: { RadioPermissions.openLocationSettings() }
                )
                HStack {
                    Text(allGranted ? "Both permissions are granted." : "You can change these later in System Settings, Privacy & Security.")
                        .font(.system(size: 11))
                        .foregroundStyle(fw.onSurfaceVariant)
                    Spacer()
                    FieldwatchActionButton(allGranted ? "Continue" : "Continue with what is allowed", prominent: true, action: onContinue)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(28)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Authorization changes arrive asynchronously after the system prompt.
            while !Task.isCancelled {
                onRefresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

private struct PermissionRow: View {
    @Environment(\.fw) var fw
    var title: String
    var status: PrivacyPermission
    var why: String
    var onGrant: () -> Void
    var onSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(status.label).font(FW.mono(11)).foregroundStyle(tint)
                }
                Text(why)
                    .font(.system(size: 12))
                    .foregroundStyle(fw.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch status {
            case .notDetermined:
                FieldwatchActionButton("Grant", prominent: true, action: onGrant)
            case .denied, .servicesOff:
                FieldwatchActionButton("Open System Settings", action: onSettings)
            case .granted:
                EmptyView()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(fw.sectionFill))
    }

    private var icon: String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .denied, .servicesOff: return "xmark.circle"
        case .notDetermined: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch status {
        case .granted: return fw.tint(FW.phosphor)
        case .denied, .servicesOff: return fw.error
        case .notDetermined: return fw.onSurfaceVariant
        }
    }
}

// MARK: - Shell

private struct FieldwatchShell: View {
    @Environment(\.fw) var fw
    var state: FieldwatchUi
    var vm: FieldwatchViewModel
    @Bindable var nav: FieldwatchNav
    @State var tourSpot: LiveTourSpot? = nil
    @State var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        let export = vm.export
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
        } detail: {
            detail
                .toolbar { toolbarContent }
                .inspector(isPresented: detailBinding) {
                    inspector
                        .inspectorColumnWidth(min: 360, ideal: 420, max: 600)
                }
                .sheet(isPresented: huntBinding, onDismiss: { vm.stopHunt() }) {
                    HuntScreen(
                        vm: vm,
                        onBack: { nav.huntOpen = false },
                        demoMode: state.settings.demoMode,
                        huntBeep: state.settings.huntBeep,
                        huntVibrate: state.settings.huntVibrate
                    )
                    .frame(minWidth: 520, idealWidth: 560, minHeight: 620, idealHeight: 700)
                    .modifier(FWWindowBackground())
                    .fieldwatchTheme(nightMode: state.settings.nightMode)
                }
        }
        .overlay {
            if export.active {
                ExportProgressOverlay(export: export)
            }
        }
        .sheet(item: shareBinding(export)) { item in
            ShareSheet(item: item, onDismiss: { vm.consumeShare() })
                .modifier(FWWindowBackground())
                .fieldwatchTheme(nightMode: state.settings.nightMode)
        }
        .modifier(ExportNoticeAlert(export: export, vm: vm))
        // LivePane shows the flood dialog on Live; the shell covers the other tabs.
        .modifier(FloodAlert(notice: nav.tab == .live ? nil : vm.floodNotice, vm: vm))
        .background(SpaceKeyMonitor(enabled: nav.tab == .live) { vm.toggleLiveDisplay() })
        .task {
            // MainActivity.onCreate / onResume: start once the gates are behind us.
            vm.refreshPermissions()
            vm.startScan()
        }
        .onChange(of: keepAwake, initial: true) { _, on in
            DisplayAwake.shared.held = on
        }
        .onDisappear { DisplayAwake.shared.held = false }
        .onChange(of: showTour, initial: true) { _, show in
            if show {
                if state.settings.scanControlsExpanded { vm.setScanControlsExpanded(expanded: false) }
                columns = .all
                Task { @MainActor in
                    // Let the toolbar and sidebar lay out before anchoring popovers to them.
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    if !vm.ui.settings.liveTourDone && nav.tab == .live && tourSpot == nil { tourSpot = .tune }
                }
            } else {
                tourSpot = nil
            }
        }
    }

    // Kotlin: keepScreenOn || route == "hunt". On the Mac the setting only applies while Live is on screen.
    private var keepAwake: Bool {
        (state.settings.keepScreenOn && nav.tab == .live) || nav.huntOpen
    }

    private var showTour: Bool { !state.settings.liveTourDone && nav.tab == .live }

    private func dismissTour() {
        tourSpot = nil
        vm.dismissLiveTour()
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: tabSelection) {
            ForEach(FieldwatchTab.allCases) { tab in
                sidebarRow(tab)
                    .tag(tab)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func sidebarRow(_ tab: FieldwatchTab) -> some View {
        let row = HStack(spacing: 6) {
            Label(tab.title, systemImage: tab.symbol)
            Spacer(minLength: 4)
            if tab == .live && state.displayPaused {
                Text("PAUSED").font(FW.mono(9, weight: .bold)).foregroundStyle(fw.onSurfaceVariant)
            }
        }
        switch tab {
        case .live, .map, .room, .connected: row
        case .filters: row.modifier(LiveTourAnchor(spot: .filters, current: $tourSpot, onDismiss: dismissTour))
        case .fleets: row.modifier(LiveTourAnchor(spot: .signatures, current: $tourSpot, onDismiss: dismissTour))
        case .reports: row.modifier(LiveTourAnchor(spot: .reports, current: $tourSpot, onDismiss: dismissTour))
        case .settings: row.modifier(LiveTourAnchor(spot: .settings, current: $tourSpot, onDismiss: dismissTour))
        }
    }

    private var tabSelection: Binding<FieldwatchTab?> {
        Binding(get: { nav.tab }, set: { if let t = $0 { nav.tab = t } })
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            FieldwatchHeader(state: state)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    nav.tab = .live
                    vm.focusLiveList()
                }
                .help("Double-click to jump to the top of Live")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if nav.tab == .live {
                Button {
                    vm.toggleLiveDisplay()
                } label: {
                    Label(state.displayPaused ? "Run" : "Pause",
                          systemImage: state.displayPaused ? "play.fill" : "pause.fill")
                }
                .help(state.displayPaused ? "Run the Live display (Space)" : "Pause the Live display (Space)")
                .background(Color.clear.modifier(LiveTourAnchor(spot: .pause, current: $tourSpot, onDismiss: dismissTour)))

                Button {
                    vm.setScanControlsExpanded(expanded: !state.settings.scanControlsExpanded)
                } label: {
                    Label("Display", systemImage: "slider.horizontal.3")
                }
                .help(state.settings.scanControlsExpanded ? "Hide display options" : "Show display options")
                .popover(isPresented: displayBinding, arrowEdge: .bottom) {
                    displayPanel
                }
                .background(Color.clear.modifier(LiveTourAnchor(spot: .tune, current: $tourSpot, onDismiss: dismissTour)))
            }
        }
    }

    private var displayBinding: Binding<Bool> {
        Binding(
            get: { state.settings.scanControlsExpanded && tourSpot == nil },
            set: { on in if on != state.settings.scanControlsExpanded { vm.setScanControlsExpanded(expanded: on) } }
        )
    }

    /// Kotlin `ViewPicker` (ported by the Live screens, LiveScreens.swift) as the Tune popover.
    private var displayPanel: some View {
        ViewPicker(state: state, vm: vm, maxHeight: 620)
            .environment(\.fw, fw)
            .tint(fw.primary)
            .foregroundStyle(fw.onSurface)
    }

    // MARK: Content column

    @ViewBuilder
    private var detail: some View {
        Group {
            switch nav.tab {
            case .live:
                liveTab
            case .map:
                MapScreen(
                    state: state,
                    vm: vm,
                    onOpen: { device in
                        vm.select(device: device)
                        nav.detailOpen = true
                    }
                )
            case .room:
                RoomScreen(
                    vm: vm,
                    onOpen: { device in
                        vm.select(device: device)
                        nav.detailOpen = true
                    }
                )
            case .connected:
                ConnectedScreen(vm: vm, onAddToRoom: { nav.tab = .room })
            case .filters:
                FiltersScreen(state: state, vm: vm)
            case .fleets:
                FleetsScreen(
                    state: state,
                    vm: vm,
                    onCandidateDraftClosed: { nav.openCandidates() }
                )
            case .reports:
                NavigationStack(path: $nav.reportsPath) {
                    ReportsScreen(
                        state: state,
                        vm: vm,
                        exporting: vm.export.active,
                        onSaveToStorage: { FieldwatchSavePanels.saveLog(vm: vm) },
                        onSaveSitToStorage: { FieldwatchSavePanels.saveSit(vm: vm) },
                        onSignatureCandidates: {
                            vm.startSignatureCandidates()
                            nav.reportsPath.append(.candidates)
                        },
                        onOpenPathRadio: { key in
                            if vm.openPathRadio(key: key) { nav.detailOpen = true }
                        }
                    )
                    .navigationDestination(for: FieldwatchRoute.self) { route in
                        routeView(route)
                    }
                }
            case .settings:
                NavigationStack(path: $nav.settingsPath) {
                    SettingsScreen(
                        state: state,
                        vm: vm,
                        onRadioBookmarks: { nav.settingsPath.append(.radioBookmarks) },
                        onScanStatus: { nav.settingsPath.append(.scanStatus) },
                        onShowLiveTour: {
                            vm.showLiveTour(then: { nav.tab = .live })
                        }
                    )
                    .navigationDestination(for: FieldwatchRoute.self) { route in
                        routeView(route)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(fw.background)
    }

    @ViewBuilder
    private func routeView(_ route: FieldwatchRoute) -> some View {
        Group {
            switch route {
            case .candidates:
                CandidatesScreen(
                    vm: vm,
                    demoMode: state.settings.demoMode,
                    onBack: { pop(route) },
                    onCreate: { candidate in
                        vm.beginCreateFromCandidate(candidate: candidate)
                        nav.tab = .fleets
                    }
                )
            case .scanStatus:
                ScanStatusScreen(state: state, onBack: { pop(route) })
            case .radioBookmarks:
                RadioBookmarksScreen(
                    state: state,
                    vm: vm,
                    onBack: { pop(route) },
                    onOpen: { key in
                        vm.select(key: key)
                        nav.detailOpen = true
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(fw.background)
        .navigationBarBackButtonHidden(true)
    }

    private func pop(_ route: FieldwatchRoute) {
        switch route {
        case .candidates:
            if nav.reportsPath.isNotEmpty { nav.reportsPath.removeLast() }
        case .scanStatus, .radioBookmarks:
            if nav.settingsPath.isNotEmpty { nav.settingsPath.removeLast() }
        }
    }

    private var liveTab: some View {
        LivePane(
            state: state,
            vm: vm,
            onOpen: { device in
                vm.select(device: device)
                nav.detailOpen = true
            },
            onHunt: { device in
                vm.select(device: device)
                vm.startHunt(device: device)
                nav.huntOpen = true
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if state.filter.arrivalsOnly || state.filter.movingWithYou {
                LiveSessionBar(
                    arrivalsOnly: state.filter.arrivalsOnly,
                    movingWithYou: state.filter.movingWithYou,
                    onMarkSeen: { vm.markArrivalsSeen() },
                    onResetSeen: { vm.resetArrivalsSeen() },
                    onStartOverFollow: { vm.resetFollowSession() }
                )
            }
        }
        .overlay {
            if tourSpot != nil {
                Color.black.opacity(0.35).allowsHitTesting(false)
            }
        }
    }

    // MARK: Inspector (Kotlin route "detail")

    private var detailBinding: Binding<Bool> {
        Binding(get: { nav.detailOpen }, set: { open in if !open { closeDetail() } else { nav.detailOpen = true } })
    }

    private func closeDetail() {
        nav.detailOpen = false
        vm.select(key: nil)
    }

    @ViewBuilder
    private var inspector: some View {
        Group {
            if let device = state.selected {
                DeviceDetailScreen(
                    device: device,
                    vm: vm,
                    watched: vm.isWatched(deviceKey: device.key),
                    onBack: closeDetail,
                    onCreateFleet: {
                        vm.beginCreateFrom(device: device)
                        nav.tab = .fleets
                    },
                    onHunt: {
                        vm.startHunt(device: device)
                        nav.huntOpen = true
                    },
                    demoMode: state.settings.demoMode
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    NestedTopBar(title: "Detail", onBack: closeDetail)
                    Text("No radio selected.")
                        .font(.system(size: 13))
                        .foregroundStyle(fw.onSurfaceVariant)
                        .padding(24)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(fw.background)
    }

    private var huntBinding: Binding<Bool> {
        Binding(get: { nav.huntOpen }, set: { nav.huntOpen = $0 })
    }

    private func shareBinding(_ export: ExportUi) -> Binding<ShareItem?> {
        Binding(
            get: { export.active ? nil : export.share },
            set: { if $0 == nil { vm.consumeShare() } }
        )
    }
}

// MARK: - Header

private enum HeaderIcon { case wifi, ble, hub }

/// FIELDWATCH title + live counts. Kotlin TopAppBar title column.
private struct FieldwatchHeader: View {
    @Environment(\.fw) var fw
    var state: FieldwatchUi

    var body: some View {
        let muted = fw.onSurfaceVariant
        let wifiHead = wifiHeader(scanning: state.scanning, locationOn: state.locationOn, radio: state.scanRadio)
        let bleHead = bleHeader(scanning: state.scanning, locationOn: state.locationOn, radio: state.scanRadio)
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .tracking(2)
                .lineLimit(1)
                .foregroundStyle(fw.onSurface)
            HStack(spacing: 10) {
                HeaderCount(n: state.wifiNow, icon: .wifi, desc: wifiHead.1, tint: headerTint(wifiHead.0, muted))
                HeaderCount(n: state.bleNow, icon: .ble, desc: bleHead.1, tint: headerTint(bleHead.0, muted))
                HeaderCount(
                    n: state.namedNow,
                    icon: .hub,
                    desc: state.scanning ? "signatures" : "signatures idle",
                    tint: headerTint(state.scanning ? .healthy : .idle, muted)
                )
                // GPS mark: the GNSS interference check has no receiver on a Mac, so gpsHeader is always nil.
                if state.throttleHint.isNotBlank {
                    Text("·  \(state.throttleHint)")
                        .font(FW.mono(10))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(minWidth: 200, maxWidth: 560, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if state.sit.open != nil && state.displayPaused { return "FIELDWATCH  ·  SIT  ·  PAUSED" }
        if state.sit.open != nil { return "FIELDWATCH  ·  SIT" }
        if state.displayPaused { return "FIELDWATCH  ·  PAUSED" }
        return "FIELDWATCH"
    }

    /// Kotlin `headerTint`: green healthy, red problem, dim gray off, gray idle; through the night filter.
    private func headerTint(_ tone: HeaderTone, _ muted: Color) -> Color {
        let c: Color
        switch tone {
        case .healthy: c = FW.phosphor
        case .problem: c = fw.error
        case .off: c = muted.opacity(0.38)
        case .idle: c = muted
        }
        return c.nightIf(fw.night)
    }
}

private struct HeaderCount: View {
    var n: Int
    var icon: HeaderIcon
    var desc: String
    var tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Group {
                switch icon {
                case .wifi: Image(systemName: "wifi").font(.system(size: 10, weight: .semibold))
                case .ble: BluetoothGlyph(size: 11)
                case .hub: Image(systemName: "point.3.filled.connected.trianglepath.dotted").font(.system(size: 10, weight: .semibold))
                }
            }
            .frame(width: 13, height: 13)
            Text(String(n))
                .font(FW.mono(11))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(tint)
        .help(desc)
        .accessibilityLabel("\(desc), \(n)")
    }
}

// MARK: - Live session bar

/// Kotlin `LiveSessionBar`: Mark seen / Reset seen while New only is on, Start over while Moving with you is on.
private struct LiveSessionBar: View {
    @Environment(\.fw) var fw
    var arrivalsOnly: Bool
    var movingWithYou: Bool
    var onMarkSeen: () -> Void
    var onResetSeen: () -> Void
    var onStartOverFollow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(fw.outline).frame(height: 1)
            HStack(spacing: 8) {
                if arrivalsOnly {
                    FieldwatchActionButton("Mark seen", action: onMarkSeen)
                        .help("Hide every radio on the list now; only later arrivals show")
                    FieldwatchActionButton("Reset seen", action: onResetSeen)
                        .help("Forget the seen set and start learning again")
                }
                if movingWithYou {
                    FieldwatchActionButton("Start over", action: onStartOverFollow)
                        .help("Clear the follow path")
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(fw.surface)
    }
}

// MARK: - Export progress overlay and notices

/// Kotlin export AlertDialog with a progress bar. Not dismissable; it closes when the export ends.
private struct ExportProgressOverlay: View {
    @Environment(\.fw) var fw
    var export: ExportUi

    var body: some View {
        let m = export.message.lowercase()
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}
            VStack(alignment: .leading, spacing: 12) {
                Text(title(m)).font(.system(size: 15, weight: .semibold))
                Text(export.message.ifBlank("Please wait…"))
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                if !m.contains("debrief") && !m.contains("ai export") && !m.contains("sit compare") {
                    Text("Live logging is paused until this finishes. Scanning continues.")
                        .font(.system(size: 12))
                        .foregroundStyle(fw.onSurfaceVariant)
                }
                if export.spinner {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    ProgressView(value: Double(export.progress).coerceIn(0, 1))
                        .progressViewStyle(.linear)
                    Text("\(Int(Double(export.progress) * 100))%")
                        .font(FW.mono(11))
                }
            }
            .tint(fw.active)
            .padding(20)
            .frame(width: 380, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(fw.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(fw.outline, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        }
        .transition(.opacity)
    }

    private func title(_ m: String) -> String {
        if m.contains("sit compare") && m.contains("pdf") { return "Sit compare PDF" }
        if m.contains("sit compare") && m.contains("ai") { return "Sit compare AI Export" }
        if m.contains("sit compare") { return "Sit compare" }
        if m.contains("ai export") { return "AI Export" }
        if m.contains("pdf") { return "Debrief PDF" }
        if m.contains("debrief") { return "Debrief" }
        return "Export"
    }
}

private struct ExportNotice: Equatable {
    var title: String
    var message: String
}

/// Kotlin error / Log saved / Log cleared / notice AlertDialogs, one at a time.
private struct ExportNoticeAlert: ViewModifier {
    var export: ExportUi
    var vm: FieldwatchViewModel

    func body(content: Content) -> some View {
        let notice = Self.notice(export)
        content.alert(
            notice?.title ?? "",
            isPresented: Binding(
                get: { notice != nil && !export.active },
                set: { shown in
                    // Defer so a follow-up notice can present after this alert has gone.
                    if !shown { Task { @MainActor in vm.consumeExportNotice() } }
                }
            ),
            presenting: notice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { n in
            Text(n.message)
        }
    }

    static func notice(_ e: ExportUi) -> ExportNotice? {
        if let err = e.error { return ExportNotice(title: e.errorTitle ?? "Could not export", message: err) }
        if e.saved {
            return ExportNotice(title: "Log saved", message: "The file was written to the location you picked.")
        }
        if e.cleared {
            return ExportNotice(title: "Log cleared", message: "Rotated files were deleted. New detections will start a fresh log.")
        }
        if let t = e.noticeTitle { return ExportNotice(title: t, message: e.noticeMessage ?? "") }
        return nil
    }
}

/// Pairing flood / name flood / Wi-Fi beacon flood dialog (Kotlin LivePane AlertDialog) while another tab is up.
private struct FloodAlert: ViewModifier {
    var notice: PairingFlood.Notice?
    var vm: FieldwatchViewModel

    func body(content: Content) -> some View {
        let shown = notice?.showDialog == true ? notice : nil
        content.alert(
            shown?.title() ?? "",
            isPresented: Binding(get: { shown != nil }, set: { _ in }),
            presenting: shown
        ) { _ in
            Button("Hide these") { vm.hidePairingFlood() }
            Button("Continue", role: .cancel) { vm.dismissPairingFlood() }
        } message: { n in
            Text(n.body())
        }
    }
}

// MARK: - Save panels (Kotlin CreateDocument launchers)

@MainActor
enum FieldwatchSavePanels {
    /// Reports → Save log to storage.
    static func saveLog(vm: FieldwatchViewModel) {
        run(name: vm.suggestedExportName(), mime: vm.exportMime()) { vm.startSaveToUri(uri: $0) }
    }

    /// Reports → Save sit export.
    static func saveSit(vm: FieldwatchViewModel) {
        run(name: vm.suggestedSitExportName(), mime: vm.sitExportMime()) { vm.startSitSaveToUri(uri: $0) }
    }

    static func run(name: String, mime: String, then: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let type = UTType(mimeType: mime) {
            panel.allowedContentTypes = [type]
            panel.allowsOtherFileTypes = true
        }
        let done: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { then(url) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: done)
        } else {
            panel.begin(completionHandler: done)
        }
    }
}

// MARK: - Share sheet (Kotlin Intent.createChooser)

/// Presents a finished export. NSSharingServicePicker anchored to the Share button, plus Reveal in Finder,
/// Save As…, and Copy text. `onDismiss` is `vm.consumeShare()` at the shell.
struct ShareSheet: View {
    @Environment(\.fw) var fw
    var item: ShareItem
    var onDismiss: () -> Void = {}
    @State var shareTrigger = 0
    @State var status: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.title.ifBlank("Share"))
                .font(.system(size: 15, weight: .semibold))
            if item.urls.isNotEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(item.urls, id: \.self) { url in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 20, height: 20)
                            Text(url.lastPathComponent)
                                .font(FW.mono(12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(sizeLabel(url))
                                .font(FW.mono(11))
                                .foregroundStyle(fw.onSurfaceVariant)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(fw.sectionFill))
            }
            if let text = item.text, text.isNotEmpty {
                ScrollView {
                    Text(text)
                        .font(FW.mono(11))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: item.urls.isEmpty ? 320 : 140)
                .background(RoundedRectangle(cornerRadius: 10).fill(fw.sectionFill))
            }
            if let status {
                Text(status).font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant)
            }
            HStack(spacing: 8) {
                FieldwatchActionButton(prominent: true, action: { shareTrigger += 1 }) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Share…")
                }
                .background(SharePickerAnchor(items: shareItems, trigger: shareTrigger))
                if item.urls.isNotEmpty {
                    FieldwatchActionButton("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(item.urls)
                    }
                }
                FieldwatchActionButton("Save As…") { saveAs() }
                if let text = item.text, text.isNotEmpty {
                    FieldwatchActionButton("Copy text") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        status = "Copied."
                    }
                }
                Spacer()
                FieldwatchActionButton("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 720)
    }

    private var shareItems: [Any] {
        if item.urls.isNotEmpty { return item.urls.map { $0 as NSURL } }
        if let text = item.text { return [text as NSString] }
        return []
    }

    private func sizeLabel(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        guard let bytes else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func saveAs() {
        let urls = item.urls
        if urls.count > 1 {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Save Here"
            panel.message = "Choose a folder for \(urls.count) files."
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            var failed = 0
            for src in urls where !copy(src, to: dir.appendingPathComponent(src.lastPathComponent)) { failed += 1 }
            status = failed == 0 ? "Saved \(urls.count) files." : "Could not save \(failed) of \(urls.count) files."
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let src = urls.first {
            panel.nameFieldStringValue = src.lastPathComponent
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            status = copy(src, to: dest) ? "Saved." : "Could not save the file."
        } else if let text = item.text {
            panel.nameFieldStringValue = "\(item.title.ifBlank("Fieldwatch")).txt"
            panel.allowedContentTypes = [.plainText]
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            let ok = (try? text.write(to: dest, atomically: true, encoding: .utf8)) != nil
            status = ok ? "Saved." : "Could not save the file."
        }
    }

    private func copy(_ src: URL, to dest: URL) -> Bool {
        let fm = FileManager.default
        if src.standardizedFileURL == dest.standardizedFileURL { return true }
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
            return true
        } catch {
            return false
        }
    }
}

/// Zero-size AppKit anchor behind the Share button. Each trigger bump opens NSSharingServicePicker on it.
private struct SharePickerAnchor: NSViewRepresentable {
    var items: [Any]
    var trigger: Int

    final class Coordinator { var lastTrigger = 0 }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard trigger != context.coordinator.lastTrigger else { return }
        context.coordinator.lastTrigger = trigger
        guard items.isNotEmpty else { return }
        let picker = NSSharingServicePicker(items: items)
        DispatchQueue.main.async {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }
}

// MARK: - Space bar = Pause / Run on Live

/// The Android Live tab doubles as Pause. On the Mac, Space pauses and runs the Live display while the main
/// window is key and no text field has focus.
private struct SpaceKeyMonitor: NSViewRepresentable {
    var enabled: Bool
    var action: () -> Void

    final class Coordinator {
        var monitor: Any?
        var enabled = false
        var action: () -> Void = {}
        weak var view: NSView?

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.enabled, let window = self.view?.window else { return event }
                guard event.keyCode == 49, !event.isARepeat, event.window === window, window.attachedSheet == nil else {
                    return event
                }
                let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
                guard mods.isEmpty else { return event }
                if window.firstResponder is NSText { return event }
                self.action()
                return nil
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.view = v
        context.coordinator.install()
        return v
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.view = view
        context.coordinator.enabled = enabled
        context.coordinator.action = action
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
        coordinator.monitor = nil
    }
}
