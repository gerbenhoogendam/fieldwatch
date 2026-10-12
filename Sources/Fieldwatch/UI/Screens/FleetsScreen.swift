import SwiftUI
import FieldwatchCore

// Port of ui/screen/FleetsScreen.kt — Signatures catalog and the signature editor.
// macOS: the editor and Decode fields push inside a NavigationStack in the content column.

struct FleetsScreen: View {
    var state: FieldwatchUi
    var vm: FieldwatchViewModel
    var onCandidateDraftClosed: () -> Void = {}

    @Environment(\.fw) var fw
    /// Kotlin `working`: the editor's fleet as of opening Decode fields (keyed by draft id).
    @State var working: Fleet? = nil
    @State var editingDecode = false
    /// Mac nicety: filter the catalog by name.
    @State var query = ""
    @FocusState var searchFocused: Bool

    var body: some View {
        NavigationStack {
            catalog
                .navigationDestination(isPresented: draftShown) { editorPage }
        }
        .onChange(of: state.draftFleet?.id) { _, _ in
            working = nil
            editingDecode = false
        }
    }

    // MARK: Navigation

    private var draftShown: Binding<Bool> {
        Binding(
            get: { state.draftFleet != nil },
            set: { shown in
                if !shown && state.draftFleet != nil { cancelEditor() }
            }
        )
    }

    private func cancelEditor() {
        let bounce = vm.takeDraftFromCandidates()
        vm.cancelDraft()
        if bounce { onCandidateDraftClosed() }
    }

    @ViewBuilder private var editorPage: some View {
        if let draft = state.draftFleet {
            let isNew = state.fleets.none { $0.id == draft.id }
            let base = (working?.id == draft.id ? working : nil) ?? draft
            FleetEditor(
                initial: base,
                isNew: isNew,
                onSave: { fleet in
                    let bounce = vm.takeDraftFromCandidates()
                    vm.upsertFleet(fleet: fleet) {
                        if bounce {
                            vm.startSignatureCandidates()
                            onCandidateDraftClosed()
                        }
                    }
                },
                onCancel: { cancelEditor() },
                onDelete: isNew ? nil : { vm.deleteFleet(id: draft.id) },
                onOpenDecode: { current in
                    working = current
                    editingDecode = true
                }
            )
            .id(draft.id)
            .environment(\.editorShortcutsActive, !editingDecode)
            .navigationBarBackButtonHidden(true)
            .navigationDestination(isPresented: $editingDecode) { decodePage }
        }
    }

    @ViewBuilder private var decodePage: some View {
        if let w = working {
            let matching = state.devices.filter { $0.fleetIds.contains(w.id) }
            let preview = matching.first ?? state.selected.flatMap { $0.fleetIds.contains(w.id) ? $0 : nil }
            DecodeFieldsScreen(
                fleet: w,
                previewDevice: preview,
                onSave: { decode in
                    var next = w
                    next.decode = decode
                    working = next
                    vm.saveFleetKeepDraft(fleet: next)
                    editingDecode = false
                },
                onBack: { editingDecode = false },
                previewChoices: matching
            )
            .environment(\.editorShortcutsActive, true)
            .navigationBarBackButtonHidden(true)
        }
    }

    // MARK: Catalog

    private var catalog: some View {
        let sort = state.settings.signatureListSort
        let q = query.trim()
        let shown = q.isEmpty ? state.fleets : state.fleets.filter { $0.name.contains(q, ignoreCase: true) }
        let live = liveHitCounts()
        let open = vm.catalogOpenClasses
        return VStack(spacing: 0) {
            NestedTopBar(title: "Signatures (\(state.fleets.count))") {
                searchField
                Button { vm.beginNewFleet() } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(fw.primaryContainer))
                        .foregroundStyle(fw.onPrimaryContainer)
                }
                .buttonStyle(.plain)
                .help("New signature")
                .accessibilityLabel("New signature")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    Text(sort == .class
                         ? "Click a class to open its signatures. Bookmark = beep. Hide a family on Filters, not here."
                         : "Click to edit. Bookmark = beep when that family appears. Hide a family on Filters, not here.")
                        .font(.system(size: 12))
                        .foregroundStyle(fw.onSurfaceVariant)
                        .padding(.bottom, 4)
                    HStack(spacing: 8) {
                        FieldwatchFilterChip(selected: sort == .name, label: "Name A–Z") {
                            vm.setSignatureListSort(sort: .name)
                        }
                        FieldwatchFilterChip(selected: sort == .class, label: "Class A–Z") {
                            vm.setSignatureListSort(sort: .class)
                        }
                    }
                    .padding(.bottom, 4)

                    if shown.isEmpty && q.isNotEmpty {
                        Text("No signatures match “\(q)”.")
                            .font(.system(size: 13))
                            .foregroundStyle(fw.onSurfaceVariant)
                            .padding(.top, 8)
                    } else if sort == .class {
                        ForEach(shown.groupedByClass().map { CatalogGroup(kind: $0.0, rows: $0.1) }) { group in
                            let classId = group.kind.rawValue
                            let expanded = open.contains(classId) || q.isNotEmpty
                            SignatureClassHeader(
                                kind: group.kind,
                                count: group.rows.count,
                                colorIndex: group.rows.first?.colorIndex ?? 0,
                                expanded: expanded,
                                onToggle: { vm.toggleCatalogClass(id: classId) }
                            )
                            if expanded {
                                ForEach(group.rows) { fleet in
                                    row(fleet, live: live).padding(.leading, 16)
                                }
                            }
                        }
                    } else {
                        ForEach(shown.sortedForCatalog(sort: sort)) { fleet in
                            row(fleet, live: live)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
        .background(fw.background)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant)
            TextField("Search signatures", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onExitCommand { query = ""; searchFocused = false }
            if query.isNotEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 210)
        .background(RoundedRectangle(cornerRadius: 6).fill(fw.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(fw.outline, lineWidth: 1))
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut(state.draftFleet == nil ? KeyboardShortcut("f", modifiers: .command) : nil)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }

    private func row(_ fleet: Fleet, live: [String: Int]) -> some View {
        SignatureRow(
            fleet: fleet,
            liveHits: live[fleet.id] ?? 0,
            watched: vm.isFleetWatched(id: fleet.id),
            onOpen: { vm.editFleet(fleet: fleet) },
            onToggleWatch: { vm.toggleWatchFleet(fleet: fleet) }
        )
    }

    /// Radios on the air (not gone) per signature id. One pass instead of a count per row.
    private func liveHitCounts() -> [String: Int] {
        var out: [String: Int] = [:]
        for d in state.devices where !d.gone {
            for id in d.fleetIds { out[id, default: 0] += 1 }
        }
        return out
    }
}

private struct CatalogGroup: Identifiable {
    var kind: SignatureClass
    var rows: [Fleet]
    var id: String { kind.rawValue }
}

private struct SignatureClassHeader: View {
    @Environment(\.fw) var fw
    var kind: SignatureClass
    var count: Int
    var colorIndex: Int
    var expanded: Bool
    var onToggle: () -> Void
    @State private var hover = false

    var body: some View {
        let accent = fw.tint(fleetColor(colorIndex))
        Button(action: onToggle) {
            HStack(spacing: 10) {
                RadioClassBadge(classKind: kind, accent: accent)
                Text(kind.label())
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(fw.onSurface)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(expanded ? "▾  \(count)" : "▸  \(count)")
                    .font(FW.mono(13, weight: .bold))
                    .foregroundStyle(accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(hover ? fw.surfaceVariant : fw.sectionFill))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("\(kind.label()), \(count) signatures, \(expanded ? "expanded" : "collapsed")")
    }
}

private struct SignatureRow: View {
    @Environment(\.fw) var fw
    var fleet: Fleet
    var liveHits: Int
    var watched: Bool
    var onOpen: () -> Void
    var onToggleWatch: () -> Void
    @State private var hover = false

    var body: some View {
        let color = fw.tint(fleetColor(fleet.colorIndex))
        HStack(spacing: 8) {
            RadioClassBadge(classKind: fleet.kind, accent: color)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(fleet.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(fw.onSurface)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if fleet.decode != nil {
                        DecodeGlyph(tint: color, size: 14)
                    }
                }
                Text("\(fleet.kind.label()) · \(fleet.rules.count) rules · \(liveHits) live · \(fleet.matchAny ? "OR" : "AND")")
                    .font(.system(size: 11))
                    .foregroundStyle(fw.onSurfaceVariant)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onToggleWatch) {
                Image(systemName: watched ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 14))
                    .foregroundStyle(watched ? fw.primary : fw.onSurfaceVariant)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Beep when this signature appears")
            .accessibilityLabel(watched ? "Bookmarked. Beep when this signature appears" : "Beep when this signature appears")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? fw.surfaceVariant : fw.sectionFill))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: onOpen)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Edit signature", action: onOpen)
            Button(watched ? "Remove bookmark" : "Bookmark (beep when it appears)", action: onToggleWatch)
            Divider()
            Button("Copy name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fleet.name, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Edit", onOpen)
    }
}

// MARK: - Editor

struct FleetEditor: View {
    var initial: Fleet
    var isNew: Bool = false
    var onSave: (Fleet) -> Void
    var onCancel: () -> Void
    var onDelete: (() -> Void)? = nil
    var onOpenDecode: (Fleet) -> Void = { _ in }

    @Environment(\.fw) var fw
    @State var fleet: Fleet
    @State var confirmDelete = false

    init(
        initial: Fleet,
        isNew: Bool = false,
        onSave: @escaping (Fleet) -> Void,
        onCancel: @escaping () -> Void,
        onDelete: (() -> Void)? = nil,
        onOpenDecode: @escaping (Fleet) -> Void = { _ in }
    ) {
        self.initial = initial
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
        self.onOpenDecode = onOpenDecode
        self._fleet = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorTopBar(
                title: isNew ? "New signature" : "Edit signature",
                cancelTitle: "Cancel",
                onCancel: onCancel,
                onSave: { onSave(fleet) }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    identity
                    matching
                    colorSection
                    rulesSection
                    if fleet.canHaveBleDecode() { decodeSection }
                    if onDelete != nil {
                        FieldwatchActionButton(action: { confirmDelete = true }) {
                            Image(systemName: "trash")
                            Text("Delete signature")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
            }
        }
        .background(fw.background)
        .onChange(of: initial.decode) { _, decode in fleet.decode = decode }
        .alert("Delete this signature?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { onDelete?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(initial.builtIn
                 ? "“\(fleet.name)” is a built-in signature. Deleting it removes matching, its bookmark, and filter chips. Restore default signatures in Settings will bring the stock set back."
                 : "“\(fleet.name)” will be removed. Matching, its bookmark, and filter chips go with it. This cannot be undone.")
        }
    }

    private var identity: some View {
        SectionCard(title: "Identity") {
            FieldwatchOutlinedField(label: "Name", text: $fleet.name)
            FieldwatchOutlinedField(
                label: "Notes",
                text: $fleet.notes,
                supportingText: "Shows on radio detail for matching radios, and in Share / AI Export. Not Extra attention — no Live “!” and not the amber card.",
                singleLine: false,
                minLines: 2
            )
            FieldwatchOutlinedField(
                label: "Extra attention",
                text: $fleet.attentionNote,
                supportingText: "Optional. If this is not empty, matching radios get a “!” on Live, this amber card on detail, and a line in Debrief. Separate from Notes above.",
                singleLine: false,
                minLines: 3
            )
        }
    }

    private var matching: some View {
        SectionCard(title: "Matching") {
            FieldwatchDropdownField(
                label: "Class",
                options: SignatureClass.visible.sortedBy { $0.label().lowercased() },
                selection: fleet.kind,
                title: { $0.label() },
                onSelect: { fleet.kind = $0 }
            )
            .frame(maxWidth: 320)
            Text("Filters → Show only / Hide these. Class sits (Finder tags, Cameras, …) are those chips — Save current as… if you want a preset.")
                .font(.system(size: 12))
                .foregroundStyle(fw.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            FieldwatchSwitch(title: "Match any rule (OR)", isOn: $fleet.matchAny)
            FieldwatchSwitch(title: "Cluster by OUI", isOn: $fleet.clusterByOui)
            FieldwatchSwitch(title: "Sequential MACs", isOn: $fleet.sequentialMac)
            HStack(alignment: .top, spacing: 12) {
                FleetDraftField(label: "Min peers (0 = off)", value: "\(fleet.minPeers)") {
                    fleet.minPeers = $0.trim().toIntOrNull() ?? 0
                }
                FleetDraftField(label: "Peer window (seconds)", value: "\(fleet.peerWindowSec)") {
                    fleet.peerWindowSec = $0.trim().toIntOrNull() ?? 60
                }
            }
            .frame(maxWidth: 420)
        }
    }

    private var colorSection: some View {
        SectionCard(title: "Color") {
            FleetColorPicker(selected: fleet.colorIndex) { fleet.colorIndex = $0 }
            Text("Stock colors are by class (red pentest, amber cameras/ALPR, purple phones/tags, cyan wearables, green mesh, orange audio/glasses, teal in-car/vehicle). Change any row.")
                .font(.system(size: 12))
                .foregroundStyle(fw.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rulesSection: some View {
        SectionCard(title: "Rules") {
            Text("Each rule has its own switch. Off keeps the rule but it does not match. Use that to mute noisy OUIs or names on one signature without deleting them.")
                .font(.system(size: 12))
                .foregroundStyle(fw.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(fleet.rules.indices), id: \.self) { index in
                RuleEditor(
                    rule: fleet.rules[index],
                    onChange: { next in
                        if index < fleet.rules.count { fleet.rules[index] = next }
                    },
                    onDelete: {
                        if index < fleet.rules.count { fleet.rules.remove(at: index) }
                    }
                )
            }
            FieldwatchActionButton(action: { fleet.rules.append(MatchRule(kind: .oui, text: "")) }) {
                Image(systemName: "plus")
                Text("Add rule")
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var decodeSection: some View {
        let decodeCount = fleet.decode?.fields.count ?? 0
        return SectionCard(title: "Decode fields") {
            Button { onOpenDecode(fleet) } label: {
                HStack {
                    if decodeCount > 0 { DecodeGlyph(tint: fw.tint(fleetColor(fleet.colorIndex)), size: 14) }
                    Text(decodeCount == 0 ? "None" : "\(decodeCount) fields")
                        .font(.system(size: 14))
                        .foregroundStyle(fw.onSurface)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(fw.onSurfaceVariant)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(decodeCount == 0 ? "Decode fields: none" : "Decode fields: \(decodeCount) fields")
            Text("Optional. After this signature matches, map cleartext BLE bytes to labels. Encrypted payloads stay hex.")
                .font(.system(size: 12))
                .foregroundStyle(fw.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct EditorShortcutsActiveKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// False on the signature editor while Decode fields is pushed over it, so Esc / ⌘S reach the top page only.
    var editorShortcutsActive: Bool {
        get { self[EditorShortcutsActiveKey.self] }
        set { self[EditorShortcutsActiveKey.self] = newValue }
    }
}

/// Cancel / title / Save bar shared by the signature editor and Decode fields.
struct EditorTopBar: View {
    @Environment(\.fw) var fw
    @Environment(\.editorShortcutsActive) var shortcutsActive
    var title: String
    var subtitle: String? = nil
    var cancelTitle: String
    var onCancel: () -> Void
    var onSave: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(cancelTitle, action: onCancel)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(fw.primary)
                .keyboardShortcut(shortcutsActive ? .cancelAction : nil)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(fw.onSurface)
                if let subtitle, subtitle.isNotEmpty {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant).lineLimit(1)
                }
            }
            Spacer()
            Button("Save", action: onSave)
                .buttonStyle(FieldwatchActionButtonStyle(prominent: true))
                .keyboardShortcut(shortcutsActive ? KeyboardShortcut("s", modifiers: .command) : nil)
                .help("Save (⌘S)")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }
}

private struct FleetColorPicker: View {
    @Environment(\.fw) var fw
    var selected: Int
    var onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(Palette.fleet.enumerated()), id: \.offset) { index, argb in
                let on = index == selected
                let fill = fw.tint(Color(argb: argb))
                Button { onSelect(index) } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(fill)
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(on ? fw.primary : fw.outline, lineWidth: on ? 2 : 1)
                        if on {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(relativeLuminance(fill) > 0.45 ? Color(hex: 0x12171C) : .white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(on ? "Color \(index + 1), selected" : "Color \(index + 1)")
            }
        }
    }
}

/// Compose `Color.luminance()` (relative luminance, linear sRGB).
private func relativeLuminance(_ c: Color) -> Double {
    let argb = c.argb
    func lin(_ v: Int) -> Double {
        let s = Double(v) / 255
        return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * lin((argb >> 16) & 0xFF) + 0.7152 * lin((argb >> 8) & 0xFF) + 0.0722 * lin(argb & 0xFF)
}

// MARK: - Rule editor

private struct RuleEditor: View {
    @Environment(\.fw) var fw
    var rule: MatchRule
    var onChange: (MatchRule) -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                Toggle(isOn: Binding(get: { rule.enabled }, set: { v in var r = rule; r.enabled = v; onChange(r) })) {
                    EmptyView()
                }
                .toggleStyle(FieldwatchToggleStyle())
                .fixedSize()
                .padding(.bottom, 5)
                .help(rule.enabled ? "Rule on" : "Rule off — kept, but it does not match")
                .accessibilityLabel("Rule enabled")
                FieldwatchDropdownField(
                    label: "Kind",
                    options: RuleKind.allCases,
                    selection: rule.kind,
                    title: ruleKindLabel,
                    onSelect: { k in var r = rule; r.kind = k; onChange(r) }
                )
                .frame(width: 170)
                kindFields
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(rule.enabled ? 1 : 0.6)
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(fw.onSurfaceVariant)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete rule")
                .accessibilityLabel("Delete rule")
            }
            if let note = macNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(fw.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 44)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(fw.tileFill))
    }

    @ViewBuilder private var kindFields: some View {
        switch rule.kind {
        case .oui, .macPrefix, .nameContains, .nameGlob:
            HStack(alignment: .bottom, spacing: 8) {
                FleetDraftField(label: "Value", value: rule.text, monospaced: rule.kind == .oui || rule.kind == .macPrefix) {
                    var r = rule; r.text = $0; onChange(r)
                }
                radioScope.frame(width: 130)
            }
        case .serviceUuid, .vendorIeOui:
            FleetDraftField(label: "Value", value: rule.text, monospaced: true) { var r = rule; r.text = $0; onChange(r) }
        case .manufacturerId:
            FleetDraftField(label: "Company ID hex", value: companyText, placeholder: "0x004C", monospaced: true) {
                var r = rule; r.companyId = parseRuleCompanyId($0); onChange(r)
            }
            .frame(maxWidth: 200)
        case .manufacturerData:
            HStack(alignment: .bottom, spacing: 8) {
                FleetDraftField(label: "Company ID hex", value: companyText, placeholder: "0x004C", monospaced: true) {
                    var r = rule; r.companyId = parseRuleCompanyId($0); onChange(r)
                }
                .frame(width: 140)
                FleetDraftField(label: "Data prefix hex", value: rule.dataPrefixHex, monospaced: true) {
                    var r = rule; r.dataPrefixHex = $0; onChange(r)
                }
            }
        case .serviceData:
            HStack(alignment: .bottom, spacing: 8) {
                FleetDraftField(label: "Service UUID (empty = any, contains)", value: rule.text, monospaced: true) {
                    var r = rule; r.text = $0; onChange(r)
                }
                FleetDraftField(label: rule.text.isBlank ? "Contains hex" : "Data prefix hex", value: rule.dataPrefixHex, monospaced: true) {
                    var r = rule; r.dataPrefixHex = $0; onChange(r)
                }
            }
        case .radioKind:
            VStack(alignment: .leading, spacing: 3) {
                Text("Radio").font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant)
                HStack(spacing: 8) {
                    // Kotlin: Wi-Fi switch on unless radio == BLE.
                    FieldwatchFilterChip(selected: rule.radio != .ble, label: "Wi-Fi") {
                        var r = rule; r.radio = .wifi; onChange(r)
                    }
                    FieldwatchFilterChip(selected: rule.radio == .ble, label: "BLE") {
                        var r = rule; r.radio = .ble; onChange(r)
                    }
                }
            }
        case .hiddenSsid:
            Text("Matches hidden SSIDs")
                .font(.system(size: 12))
                .foregroundStyle(fw.onSurfaceVariant)
                .padding(.bottom, 7)
        }
    }

    /// `MatchRule.radio` scopes address and name rules to one radio (stock rows use it). Nil = either.
    private var radioScope: some View {
        FieldwatchDropdownField(
            label: "Radio",
            options: [RadioScopeChoice.either, .wifi, .ble],
            selection: RadioScopeChoice(rule.radio),
            title: { $0.title },
            onSelect: { c in var r = rule; r.radio = c.radio; onChange(r) }
        )
    }

    private var companyText: String {
        rule.companyId == 0 ? "" : format("0x%04X", rule.companyId)
    }

    /// macOS has no BLE MAC: address rules only reach Wi-Fi BSSIDs here.
    private var macNote: String? {
        guard rule.kind == .oui || rule.kind == .macPrefix, rule.radio != .wifi else { return nil }
        return "On a Mac, BLE radios have no MAC address (Core Bluetooth gives a per-Mac id), so this rule only hits Wi-Fi BSSIDs here."
    }
}

private enum RadioScopeChoice: Hashable {
    case either, wifi, ble

    init(_ radio: RadioKind?) {
        switch radio {
        case .none: self = .either
        case .some(.wifi): self = .wifi
        case .some(.ble): self = .ble
        }
    }

    var radio: RadioKind? {
        switch self {
        case .either: return nil
        case .wifi: return .wifi
        case .ble: return .ble
        }
    }

    var title: String {
        switch self {
        case .either: return "Either radio"
        case .wifi: return "Wi-Fi only"
        case .ble: return "BLE only"
        }
    }
}

private func parseRuleCompanyId(_ text: String) -> Int {
    let t = text.trim()
    var hex = t
    if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = hex.drop(2) }
    return hex.toIntOrNull(16) ?? 0
}

private func ruleKindLabel(_ kind: RuleKind) -> String {
    switch kind {
    case .oui: return "OUI"
    case .macPrefix: return "MAC prefix"
    case .nameContains: return "Name contains"
    case .nameGlob: return "Name glob"
    case .serviceUuid: return "Service UUID"
    case .serviceData: return "Service data"
    case .manufacturerId: return "Manufacturer ID"
    case .manufacturerData: return "Manufacturer data"
    case .radioKind: return "Radio kind"
    case .hiddenSsid: return "Hidden SSID"
    case .vendorIeOui: return "Vendor IE OUI"
    }
}

// MARK: - Draft text field

/// Outlined field (FieldwatchOutlinedField look) for values that are parsed on every keystroke
/// (numbers, hex company ids). Keeps the typed text while focused; shows the parsed value again on blur
/// or when the value changes from outside. Shared with DecodeFieldsScreen.
struct FleetDraftField: View {
    @Environment(\.fw) var fw
    var label: String
    var value: String
    var placeholder: String
    var monospaced: Bool
    var onChange: (String) -> Void
    @State var text: String
    @FocusState var focused: Bool

    init(label: String, value: String, placeholder: String = "", monospaced: Bool = false, onChange: @escaping (String) -> Void) {
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.monospaced = monospaced
        self.onChange = onChange
        self._text = State(initialValue: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant).lineLimit(1)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(monospaced ? FW.mono(12) : .system(size: 12))
                .focused($focused)
                .onSubmit { text = value }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(fw.background.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? fw.active : fw.outline, lineWidth: 1))
        }
        .onChange(of: text) { _, t in
            if t != value { onChange(t) }
        }
        .onChange(of: value) { _, v in
            if !focused && v != text { text = v }
        }
        .onChange(of: focused) { _, f in
            if !f && text != value { text = value }
        }
    }
}
