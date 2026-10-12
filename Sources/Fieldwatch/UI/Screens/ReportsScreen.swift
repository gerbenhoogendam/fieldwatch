import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FieldwatchCore

// Port of ui/screen/ReportsScreen.kt.
//
// Mac notes:
// - Kotlin's Save callbacks launched CreateDocument from FieldwatchAppUi. Here they are optional: when the
//   caller passes nil the screen runs an NSSavePanel itself and calls vm.startSaveToUri(uri:) /
//   vm.startSitSaveToUri(uri:).
// - onOpenPathRadio nil → vm.openPathRadio(key:) (selects the radio; the app shell shows its detail).
// - Wide windows lay the cards out in two columns (Sits + Path left, reports and exports right).
// - Export progress, errors, notices and the share sheet are the app shell's (FieldwatchAppUi), as in Kotlin.

struct ReportsScreen: View {
    @Environment(\.fw) var fw
    var state: FieldwatchUi
    var vm: FieldwatchViewModel
    var exporting: Bool
    var onSaveToStorage: (() -> Void)? = nil
    var onSaveSitToStorage: (() -> Void)? = nil
    var onSignatureCandidates: () -> Void
    var onOpenPathRadio: ((String) -> Void)? = nil

    @State var confirmClear: Bool = false
    @State var startSit: Bool = false
    @State var sitNameDraft: String = ""
    @State var renameSitId: String? = nil
    @State var renameDraft: String = ""
    @State var deleteSitId: String? = nil
    @State var confirmDeleteAll: Bool = false

    private var settings: AppSettings { state.settings }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if settings.demoMode {
                        Text("Privacy mode is on. Debrief, Compare, and AI Export hide the last half of each MAC, the coordinates, and a Remote ID id. The log and sit export still have the full addresses and coordinates.")
                            .font(.system(size: 12))
                            .foregroundStyle(fw.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if geo.size.width >= 1000 {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(spacing: 12) {
                                sitsCard
                                pathCard
                            }
                            .frame(maxWidth: .infinity, alignment: .top)
                            VStack(spacing: 12) {
                                sitReportCard
                                sitExportCard
                                compareCard
                                catalogCard
                                logExportCard
                            }
                            .frame(maxWidth: .infinity, alignment: .top)
                        }
                    } else {
                        VStack(spacing: 12) {
                            sitsCard
                            pathCard
                            sitReportCard
                            sitExportCard
                            compareCard
                            catalogCard
                            logExportCard
                        }
                        .frame(maxWidth: 820)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(fw.background)
        .navigationTitle("Reports")
        .task(id: "\(state.sit.selectedId ?? "")|\(state.sit.open?.id ?? "")") {
            while !Task.isCancelled {
                vm.refreshSitPath()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .alert("Start sit", isPresented: $startSit) {
            TextField("Name", text: $sitNameDraft)
            Button("Start") { vm.startSit(name: sitNameDraft.take(Sit.NAME_MAX)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            let warn = Sit.dropWarning(closed: state.sit.closed)
            Text("Debrief and AI Export use this window until you end it. The Live list is unchanged." + (warn.map { "\n\n" + $0 } ?? ""))
        }
        .alert("Rename sit", isPresented: Binding(
            get: { renameSitId != nil },
            set: { if !$0 { renameSitId = nil } }
        )) {
            TextField("Name", text: $renameDraft)
            Button("Save") {
                if let id = renameSitId { vm.renameSit(id: id, name: renameDraft.take(Sit.NAME_MAX)) }
                renameSitId = nil
            }
            Button("Cancel", role: .cancel) { renameSitId = nil }
        }
        .alert("Delete this sit?", isPresented: Binding(
            get: { deleteSitId != nil },
            set: { if !$0 { deleteSitId = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let id = deleteSitId { vm.deleteSit(id: id) }
                deleteSitId = nil
            }
            Button("Cancel", role: .cancel) { deleteSitId = nil }
        } message: {
            Text("Removes the saved sit from this Mac. The log is unchanged.")
        }
        .alert("Delete all sits?", isPresented: $confirmDeleteAll) {
            Button("Delete all", role: .destructive) { vm.deleteAllSits() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes saved sits from this Mac. An open sit is not deleted. The log is unchanged.")
        }
        .alert("Clear the log?", isPresented: $confirmClear) {
            Button("Clear log", role: .destructive) { vm.clearLogs() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes the log files on this Mac. This cannot be undone. Scanning starts a new empty log.")
        }
        .onChange(of: sitNameDraft) { _, v in if v.count > Sit.NAME_MAX { sitNameDraft = v.take(Sit.NAME_MAX) } }
        .onChange(of: renameDraft) { _, v in if v.count > Sit.NAME_MAX { renameDraft = v.take(Sit.NAME_MAX) } }
    }

    // MARK: - Helpers

    private func caption(_ s: String, color: Color? = nil) -> some View {
        Text(s)
            .font(.system(size: 12))
            .foregroundStyle(color ?? fw.onSurfaceVariant)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func body13(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 13))
            .foregroundStyle(fw.onSurface)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func wideButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        FieldwatchActionButton(enabled: enabled, action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private func switchRow(_ title: String, checked: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { checked }, set: { onChange($0) })) {
            Text(title).font(.system(size: 13))
        }
        .toggleStyle(FieldwatchToggleStyle())
    }

    private func openRadio(_ key: String) {
        if let onOpenPathRadio {
            onOpenPathRadio(key)
        } else {
            _ = vm.openPathRadio(key: key)
        }
    }

    // MARK: - Sits

    private var sitsCard: some View {
        let open = state.sit.open
        let closed = state.sit.closed
        return SectionCard(title: "Sits") {
            caption("A sit is the radios heard during a named stretch of time. Path, Debrief, and Compare use the open sit, a saved sit you pick, or the last 15 minutes.")
            if let open {
                let dur = Sit.fmtDuration(ms: open.durationMs())
                body13("This sit: \(open.name) · \(dur) · \(state.sit.radioCount) radios")
                wideButton("End sit", enabled: !exporting) { vm.endSit() }
            } else {
                wideButton("Start sit", enabled: !exporting) {
                    sitNameDraft = vm.defaultSitName()
                    startSit = true
                }
                caption(closed.isEmpty
                        ? "No sit is running. Path and Debrief use the last 15 minutes until you start one."
                        : "No sit is running. Path and Debrief use the sit you pick.")
            }
            if closed.isEmpty && open == nil {
                caption("No saved sits.")
            }
            if closed.isNotEmpty {
                let pickEnabled = open == nil && !exporting
                SitChoiceRow(
                    selected: state.sit.selectedId == nil,
                    enabled: pickEnabled,
                    title: "Last 15 minutes",
                    subtitle: "Uses what is still in memory, not a saved sit.",
                    onSelect: { vm.selectSit(id: nil) }
                )
                ForEach(closed, id: \.id) { row in
                    let dur = Sit.fmtDuration(ms: row.durationMs())
                    let extra = row.extraAttentionCount > 0 ? " · Extra attention \(row.extraAttentionCount)" : ""
                    SitChoiceRow(
                        selected: state.sit.selectedId == row.id,
                        enabled: pickEnabled,
                        title: row.name,
                        subtitle: "\(Sit.defaultName(at: row.startAt)) · \(dur) · \(row.radioCount) radios\(extra)",
                        onSelect: { vm.selectSit(id: row.id) }
                    )
                }
                if open != nil {
                    caption("End this sit to pick a saved one.")
                }
                let picked = closed.first { $0.id == state.sit.selectedId }
                HStack(spacing: 8) {
                    wideButton("Rename", enabled: !exporting && picked != nil) {
                        if let picked {
                            renameDraft = picked.name
                            renameSitId = picked.id
                        }
                    }
                    wideButton("Delete", enabled: !exporting && picked != nil) {
                        if let picked { deleteSitId = picked.id }
                    }
                }
                wideButton("Delete all sits", enabled: !exporting) { confirmDeleteAll = true }
            }
        }
    }

    // MARK: - Path

    private static let noPathHint = "Turn on Tag detections with GPS and walk, or pick a sit that recorded a path."

    private var pathCard: some View {
        let model = vm.sitPath
        let showWalk = model != nil && model?.emptyHint == nil
        let showAircraft = (model?.aircraftCards.isNotEmpty) ?? false
        return SectionCard(title: "Path") {
            caption("North is up. The line is this Mac, with times along it. Black is the start. Blue is you. One icon is one radio. A number is several radios in one spot. A thick green stretch is a stay. An advertised position is the last one that radio sent.")
            if let model, showWalk || showAircraft {
                pathContent(model: model, showWalk: showWalk)
            } else {
                caption(model?.emptyHint ?? Self.noPathHint)
            }
        }
    }

    @ViewBuilder
    private func pathContent(model: SitPathPlot.Model, showWalk: Bool) -> some View {
        let demo = settings.demoMode
        if !showWalk {
            caption(model.emptyHint ?? Self.noPathHint)
        }
        if showWalk {
            let stopN = model.dots.count
            let gnssN = model.gnss.count
            body13(
                "\(model.title) · \(Int(model.lengthM)) m path · \(Int(model.spanM)) m span"
                    + (stopN > 0 ? " · \(stopN) alert" + (stopN != 1 ? "s" : "") : "")
                    + (gnssN > 0 ? " · \(gnssN) GNSS" : "")
            )
            SitPathCanvas(model: model, tiles: vm.pathTiles, onOpenRadio: { openRadio($0) })
            caption("Click a number for the radios there. Click one icon for that radio. Click a row to open it. Click a red diamond for that detection. Pinch or ⌘-scroll to zoom, drag to pan, double-click to reset.")
            if model.craft.isNotEmpty || model.pilots.isNotEmpty || model.gnss.isNotEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if model.craft.isNotEmpty {
                        let multi = model.craft.any { $0.samples.count >= 2 }
                        HStack(spacing: 6) {
                            if multi { AdvertisedTrackSwatch() } else { AdvertisedRingSwatch() }
                            Text(multi ? "= advertised track within 2 km of this path" : "= one advertised position within 2 km of this path")
                                .font(.system(size: 12)).foregroundStyle(fw.onSurface)
                        }
                    }
                    if model.pilots.isNotEmpty {
                        HStack(spacing: 6) {
                            PilotSwatch()
                            Text("= pilot").font(.system(size: 12)).foregroundStyle(fw.onSurfaceVariant)
                        }
                    }
                    if model.gnss.isNotEmpty {
                        HStack(spacing: 6) {
                            GnssSwatch()
                            Text("= where this Mac was during a GNSS detection")
                                .font(.system(size: 12)).foregroundStyle(fw.onSurface)
                        }
                    }
                }
            }
            let alertsOnACard = model.aircraftCards.any { $0.dots.isNotEmpty }
            if model.dots.isEmpty && model.gnss.isEmpty && !alertsOnACard {
                caption("No alerts with a GPS stamp on this path.")
            } else if model.dots.isNotEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.dots.enumerated()), id: \.offset) { i, dot in
                        PathRadioRow(index: i + 1, dot: dot, demoMode: demo, onOpen: { openRadio(dot.key) })
                    }
                }
            }
            if model.gnss.isNotEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.gnss.enumerated()), id: \.offset) { _, pin in
                        GnssPathNote(pin: pin)
                    }
                }
            }
        }
        let aircraftTiles = vm.pathAircraftTiles
        ForEach(Array(model.aircraftCards.enumerated()), id: \.offset) { index, card in
            let fixes = card.craft.sumOf { $0.samples.count }
            Text(privacyAircraftHeading(title: card.title, demo: demo))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(fw.tint(AircraftAmber))
                .padding(.top, 12)
            body13((fixes == 1 ? "1 advertised fix" : "\(fixes) advertised fixes") + (card.lengthM >= 1.0 ? " · \(Int(card.lengthM)) m" : ""))
            if card.dots.isNotEmpty {
                caption(card.dots.count == 1 ? "1 alert" : "\(card.dots.count) alerts")
            }
            SitPathCanvas(model: card, tiles: index < aircraftTiles.count ? aircraftTiles[index] : [], onOpenRadio: { openRadio($0) })
            if card.dots.isNotEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(card.dots.enumerated()), id: \.offset) { i, dot in
                        PathRadioRow(index: i + 1, dot: dot, demoMode: demo, onOpen: { openRadio(dot.key) })
                    }
                }
            }
            if card.caption.isNotBlank {
                caption(privacyAircraftCaption(caption: card.caption, title: card.title, demo: demo))
            }
        }
        if model.looseAdvertised > 0 {
            caption(model.looseAdvertised == 1
                    ? "An advertised position with no UAS id is in the sit report."
                    : "Advertised positions with no UAS id are in the sit report.")
        }
    }

    // MARK: - Sit report

    private var sitReportCard: some View {
        SectionCard(title: "Sit report") {
            HStack(spacing: 8) {
                wideButton("Debrief (text)", enabled: !exporting) { vm.startFieldDebrief() }
                wideButton("Debrief (PDF)", enabled: !exporting) { vm.startFieldDebriefPdf() }
            }
            caption(sitReportCaption)
            switchRow("Show unmatched rotating BLE", checked: settings.debriefShowUnmatchedRandomBle) { on in
                vm.updateSettings { s in var s = s; s.debriefShowUnmatchedRandomBle = on; return s }
            }
            caption("Leaves unmatched Bluetooth radios that keep changing address out of the Debrief lists. The counts still include them. Extra attention, named signatures, bookmarks, and radios that sent a position stay. Sit export still has every radio.")
            switchRow("Show all radios", checked: settings.debriefShowAllRadios) { on in
                vm.updateSettings { s in var s = s; s.debriefShowAllRadios = on; return s }
            }
            caption("Debrief and Compare open with counts. A radio is listed when it is Extra attention, has a custom name, is marked Mine, or is bookmarked. Compare also lists a decoded value that changed. Turn this on for the full list. The PDF draws the counts as bars. Sit export still has every radio.")
            wideButton("AI Export", enabled: !exporting) { vm.startAiExport() }
            caption("A short note for pasting into a chat: rates, signal bands, Extra attention, and tracking ids. It does not repeat the Debrief lists. A one-radio export is on that radio’s page.")
        }
    }

    private var sitReportCaption: String {
        let open = state.sit.open
        let selected = state.sit.closed.first { $0.id == state.sit.selectedId }
        let window: String
        if let open {
            window = "This sit (\(open.name))"
        } else if let selected {
            window = "Sit: \(selected.name)"
        } else {
            window = "Last 15 minutes still in memory"
        }
        return "\(window). Same window as Path. Moving with you runs when Tag detections with GPS is on and you have moved. This is not a legal finding."
    }

    // MARK: - Sit export

    private var sitExportCard: some View {
        SectionCard(title: "Sit export") {
            ExportFormatBlock(
                kind: vm.sitExportKind,
                radios: vm.sitExportRadios,
                exporting: exporting,
                onKind: { vm.setSitExportKind(kind: $0) },
                onRadios: { vm.setSitExportRadios(radios: $0) },
                onShare: { vm.startSitExport() },
                onSave: { saveSit() },
                hint: "One row per radio in this sit, or the last 15 minutes. Not the log. CSV and JSON include the matched signatures. GPX and KML include this Mac’s path and a point for each detection. Fieldwatch does not upload the file. Privacy mode does not hide addresses in it."
            )
        }
    }

    // MARK: - Compare

    private var compareThisCaption: String {
        if let open = state.sit.open { return "This sit: \(open.name). Same window as Debrief." }
        if let selected = state.sit.closed.first(where: { $0.id == state.sit.selectedId }) {
            return "This sit: \(selected.name). Same window as Debrief."
        }
        return "This sit: the last 15 minutes still in memory, about 400 radios. Same window as Debrief."
    }

    private var compareCard: some View {
        let thisSaved = SitDiff.thisSavedId(open: state.sit.open, selectedId: state.sit.selectedId)
        let choices = SitDiff.secondSitChoices(closed: state.sit.closed, thisSavedId: thisSaved)
        let canCompare = !exporting && state.sit.compareId != nil
        return SectionCard(title: "Compare sits") {
            caption(compareThisCaption)
            if choices.isEmpty {
                caption("Save a second sit to compare. Start a sit, then end it. The last 15 minutes can be this sit.")
            } else {
                body13("Second sit")
                ForEach(choices, id: \.id) { row in
                    let dur = Sit.fmtDuration(ms: row.durationMs())
                    SitChoiceRow(
                        selected: state.sit.compareId == row.id,
                        enabled: !exporting,
                        title: row.name,
                        subtitle: "\(Sit.defaultName(at: row.startAt)) · \(dur) · \(row.radioCount) radios",
                        onSelect: { vm.selectCompareSit(id: row.id) }
                    )
                }
            }
            HStack(spacing: 8) {
                wideButton("Compare (text)", enabled: canCompare) { vm.startSitCompare() }
                wideButton("Compare (PDF)", enabled: canCompare) { vm.startSitComparePdf() }
            }
            caption("The same report as text or PDF. Radios only in this sit, only in the second, and in both. Extra attention and named radios are marked. These points are where this Mac was, not a location from the other radio.")
            wideButton("AI Export", enabled: canCompare) { vm.startSitCompareAiExport() }
            caption("A short note on what overlaps and what is only in one sit. It does not repeat the compare lists. The sit-report export stays on this window only.")
        }
    }

    // MARK: - Catalog

    private var catalogCard: some View {
        SectionCard(title: "Catalog") {
            wideButton("Signature candidates", enabled: !exporting) { onSignatureCandidates() }
            caption("Unmatched radios in the log that share an id. Not every unknown radio. Nothing is added until you save it.")
        }
    }

    // MARK: - Log export

    private var logExportCard: some View {
        SectionCard(title: "Log export") {
            Text("\(state.logLines) lines this session  ·  \(vm.logBytes() / 1024) KB on disk" + (settings.loggingEnabled ? "" : "  ·  logging off"))
                .font(.system(size: 12))
                .foregroundStyle(fw.onSurface)
            ExportFormatBlock(
                kind: vm.logExportKind,
                radios: vm.logExportRadios,
                exporting: exporting,
                onKind: { vm.setLogExportKind(kind: $0) },
                onRadios: { vm.setLogExportRadios(radios: $0) },
                onShare: { vm.startExport() },
                onSave: { saveLog() },
                hint: "The file on disk is one detection per line. CSV is those rows in a spreadsheet. GPX, KML, and WiGLE are points where this Mac was when it heard each radio, not a location from the other radio. Tag detections with GPS and logging both have to be on. Share opens the macOS share menu. Fieldwatch does not upload."
            )
            wideButton("Reset / clear log", enabled: !exporting) { confirmClear = true }
        }
    }

    // MARK: - Save As

    private func saveLog() {
        if let onSaveToStorage { onSaveToStorage(); return }
        runSavePanel(name: vm.suggestedExportName(), mime: vm.exportMime()) { url in
            vm.startSaveToUri(uri: url)
        }
    }

    private func saveSit() {
        if let onSaveSitToStorage { onSaveSitToStorage(); return }
        runSavePanel(name: vm.suggestedSitExportName(), mime: vm.sitExportMime()) { url in
            vm.startSitSaveToUri(uri: url)
        }
    }

    /// Kotlin `ActivityResultContracts.CreateDocument(mime)` → NSSavePanel.
    private func runSavePanel(name: String, mime: String, onPick: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let ext = (name as NSString).pathExtension
        if let type = UTType(mimeType: mime) ?? (ext.isEmpty ? nil : UTType(filenameExtension: ext)) {
            panel.allowedContentTypes = [type]
            panel.allowsOtherFileTypes = true
        }
        let done: (NSApplication.ModalResponse) -> Void = { resp in
            if resp == .OK, let url = panel.url { onPick(url) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(panel.runModal())
        }
    }
}

// MARK: - Rows and blocks

private struct SitChoiceRow: View {
    @Environment(\.fw) var fw
    var selected: Bool
    var enabled: Bool
    var title: String
    var subtitle: String
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 0) {
                RadioDot(selected: selected, enabled: enabled)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(selected && enabled ? fw.primary : fw.onSurface.opacity(enabled ? 1 : 0.5))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(fw.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Material RadioButton look.
private struct RadioDot: View {
    @Environment(\.fw) var fw
    var selected: Bool
    var enabled: Bool

    var body: some View {
        let ink = selected ? fw.primary : fw.onSurfaceVariant
        ZStack {
            Circle().stroke(ink.opacity(enabled ? 1 : 0.38), lineWidth: 1.6).frame(width: 16, height: 16)
            if selected {
                Circle().fill(ink.opacity(enabled ? 1 : 0.38)).frame(width: 8, height: 8)
            }
        }
        .frame(width: 22, height: 22)
    }
}

private struct ExportFormatBlock: View {
    @Environment(\.fw) var fw
    var kind: LogExportKind
    var radios: LogExportRadios
    var exporting: Bool
    var onKind: (LogExportKind) -> Void
    var onRadios: (LogExportRadios) -> Void
    var onShare: () -> Void
    var onSave: () -> Void
    var hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldwatchDropdownField(
                label: "Format",
                options: LogExportKind.allCases,
                selection: kind,
                title: { $0.label },
                onSelect: onKind
            )
            .padding(.vertical, 6)
            HStack(spacing: 4) {
                ForEach(LogExportRadios.allCases, id: \.self) { item in
                    Button { onRadios(item) } label: {
                        HStack(spacing: 2) {
                            RadioDot(selected: radios == item, enabled: !exporting)
                            Text(item.label).font(.system(size: 12)).foregroundStyle(fw.onSurface)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(exporting)
                }
            }
            HStack(spacing: 8) {
                FieldwatchActionButton(enabled: !exporting, action: onShare) {
                    Label("Share…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
                FieldwatchActionButton(enabled: !exporting, action: onSave) {
                    Label("Save As…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
            }
            Text(hint)
                .font(.system(size: 12))
                .foregroundStyle(fw.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AdvertisedTrackSwatch: View {
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            p.move(to: CGPoint(x: 0, y: size.height / 2))
            p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(p, with: .color(.white), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [3, 4.5]))
        }
        .frame(width: 28, height: 10)
    }
}

private struct AdvertisedRingSwatch: View {
    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2 - 1
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                       with: .color(.white), lineWidth: 1.6)
        }
        .frame(width: 12, height: 12)
    }
}

private struct GnssSwatch: View {
    @Environment(\.fw) var fw
    var body: some View {
        let ink = fw.tint(Color(argb: 0xFFB9_1C1C))
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2
            func diamond(_ rad: CGFloat) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: c.x, y: c.y - rad))
                p.addLine(to: CGPoint(x: c.x + rad * 0.86, y: c.y))
                p.addLine(to: CGPoint(x: c.x, y: c.y + rad))
                p.addLine(to: CGPoint(x: c.x - rad * 0.86, y: c.y))
                p.closeSubpath()
                return p
            }
            ctx.fill(diamond(r), with: .color(.white))
            ctx.fill(diamond(r * 0.72), with: .color(ink))
        }
        .frame(width: 14, height: 14)
    }
}

private struct PilotSwatch: View {
    var body: some View {
        let pilotInk = Color(argb: 0xFF3D_4A55)
        ZStack {
            Circle().fill(Color.white)
            Circle().fill(Color(argb: 0xFFF4_F7FB)).frame(width: 18 * 0.86, height: 18 * 0.86)
            Circle().stroke(pilotInk, lineWidth: 1.2).frame(width: 18 * 0.86, height: 18 * 0.86)
            Image(systemName: "person")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(pilotInk)
        }
        .frame(width: 18, height: 18)
    }
}

private struct GnssPathNote: View {
    @Environment(\.fw) var fw
    var pin: SitPathPlot.GnssPin

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(pin.title()) · \(pin.confidence)").font(.system(size: 13))
            Text(pin.whenLine()).font(.system(size: 12)).foregroundStyle(fw.onSurfaceVariant)
            Text(pin.detail.trim().ifBlank("Signal changed.")).font(.system(size: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A one-token serial is the UAS id. A name with a space stays. A MAC keeps its prefix.
private func privacyAircraftHeading(title: String, demo: Bool) -> String {
    if !demo || title.isBlank { return title }
    let serial = !title.contains(" ") && !title.contains(":") &&
        title.count >= 6 && title.any { $0.isNumber } && title.any { $0.isLetter }
    if serial { return "Aircraft" }
    return MacUtil.redactMacIn(text: title, mac: title, demo: true)
}

private func privacyAircraftCaption(caption: String, title: String, demo: Bool) -> String {
    if !demo || caption.isBlank { return caption }
    let stripped = title.isBlank ? caption : caption.replace(title, "masked", ignoreCase: true)
    return Geo.redactCoordsIn(text: MacUtil.redactMacIn(text: stripped, mac: title, demo: true), demo: true)
}

private struct PathRadioRow: View {
    @Environment(\.fw) var fw
    var index: Int
    var dot: SitPathPlot.Dot
    var demoMode: Bool
    var onOpen: () -> Void

    var body: some View {
        let mac = MacUtil.screenMac(mac: dot.mac, demo: demoMode)
        let named = dot.label.isNotBlank && !dot.label.equals(dot.mac, ignoreCase: true)
        let label = MacUtil.redactMacIn(text: dot.label, mac: dot.mac, demo: demoMode)
        let fleets = dot.fleetNames.joined(separator: " · ")
        let note = dot.observerNotes.trim()
        let accent = fw.tint(dot.accentArgb != 0 ? Color(argb: dot.accentArgb) : fw.onSurfaceVariant)
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 0) {
                Text("\(index)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(fw.onSurfaceVariant)
                    .frame(width: 22, alignment: .leading)
                RadioClassBadge(classKind: dot.classKind, accent: accent, compact: true)
                Spacer().frame(width: 8)
                VStack(alignment: .leading, spacing: 1) {
                    if named {
                        Text(label).font(.system(size: 13)).foregroundStyle(fw.onSurface).lineLimit(1)
                    }
                    if mac.isNotBlank {
                        HStack(spacing: 4) {
                            RadioKindMark(kind: dot.kind, size: 13)
                            Text(mac)
                                .font(FW.mono(12, weight: .regular))
                                .foregroundStyle(fw.onSurfaceVariant)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    if fleets.isNotEmpty {
                        Text(fleets).font(.system(size: 12)).foregroundStyle(accent).lineLimit(1)
                    }
                    if note.isNotEmpty {
                        Text(note).font(.system(size: 12)).foregroundStyle(fw.tint(FW.cyan))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if mac.isNotBlank {
                Button(dot.kind == .wifi ? "Copy BSSID" : "Copy address") { copy(demoMode ? mac : dot.mac) }
            }
            if named { Button("Copy name") { copy(label) } }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
