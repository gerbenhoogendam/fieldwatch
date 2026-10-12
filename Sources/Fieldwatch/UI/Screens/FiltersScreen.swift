import SwiftUI
import FieldwatchCore

// Port of ui/screen/FiltersScreen.kt.
//
// Mac: the cards sit in one column, or two columns once the content column is wide enough.
// Preset long-press → right-click (context menu) → Delete preset….

struct FiltersScreen: View {
    @Environment(\.fw) var fw
    var state: FieldwatchUi
    var vm: FieldwatchViewModel

    @State var presetName: String = ""
    @State var pendingDelete: FilterPreset? = nil
    @State var confirmReset: Bool = false
    @State var rssiDrag: Int = -100
    @State var rssiEditing: Bool = false

    private var filter: FilterState { state.filter }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                Group {
                    if geo.size.width >= 900 {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(spacing: 12) {
                                presetsCard
                                radiosCard
                                movingCard
                                arrivalsCard
                                whoStaysCard
                            }
                            .frame(maxWidth: .infinity, alignment: .top)
                            VStack(spacing: 12) {
                                classesCard
                                signaturesCard
                                fineFilterCard
                            }
                            .frame(maxWidth: .infinity, alignment: .top)
                        }
                    } else {
                        VStack(spacing: 12) {
                            presetsCard
                            radiosCard
                            movingCard
                            arrivalsCard
                            whoStaysCard
                            classesCard
                            signaturesCard
                            fineFilterCard
                        }
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(fw.background)
        .navigationTitle("Filters")
        .alert("Reset filter?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                vm.updateFilter { _ in FilterState() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears the radios, classes, selected signatures, signal strength, and name and vendor fields. Presets you saved stay. Live shows the radios again. This cannot be undone.")
        }
        .alert("Delete preset?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { preset in
            Button("Delete", role: .destructive) {
                vm.deletePreset(id: preset.id)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { preset in
            if preset.isBuiltIn() {
                Text("Remove “\(preset.name)” from this list? A catalog update will not put it back. Settings → Restore default signatures & presets brings the stock presets back. Live keeps this filter until you pick another preset or click Reset filter.")
            } else {
                Text("Delete “\(preset.name)”? This cannot be undone. Live keeps this filter until you pick another preset or click Reset filter.")
            }
        }
    }

    // MARK: - Small pieces

    private func caption(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12))
            .foregroundStyle(fw.onSurfaceVariant)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func switchRow(_ title: String, checked: Bool, enabled: Bool = true, dim: Bool = false,
                           onChange: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { checked }, set: { onChange($0) })) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(dim ? fw.onSurfaceVariant : fw.onSurface)
        }
        .toggleStyle(FieldwatchToggleStyle())
        .disabled(!enabled)
    }

    private func update(_ change: @escaping (inout FilterState) -> Void) {
        vm.updateFilter { current in
            var next = current
            change(&next)
            return next
        }
    }

    private var gridColumns: [GridItem] { [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)] }

    // MARK: - Cards

    private var presetsCard: some View {
        SectionCard(title: "Presets") {
            caption("Click a preset to replace the whole filter. Right-click one to delete it. Save current as… keeps the filter you have now. Settings → Restore default signatures & presets brings deleted stock presets back.")
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 4) {
                ForEach(state.presets) { preset in
                    PresetChip(
                        name: preset.name,
                        selected: preset.filter == filter,
                        onApply: { vm.applyPreset(preset: preset) },
                        onLongPress: { pendingDelete = preset }
                    )
                }
            }
            HStack(alignment: .center, spacing: 8) {
                TextField("Save current as…", text: $presetName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(fw.background.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(fw.outline, lineWidth: 1))
                    .onSubmit(savePreset)
                Button("Save", action: savePreset)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(presetName.isNotBlank ? fw.primary : fw.onSurfaceVariant)
                    .disabled(presetName.isBlank)
            }
        }
    }

    private func savePreset() {
        if presetName.isNotBlank {
            vm.savePreset(name: presetName.trim())
            presetName = ""
        }
    }

    private var radiosCard: some View {
        SectionCard(title: "Radios") {
            caption(filter.movingWithYou
                    ? "Moving with you uses BLE only. Both and Wi-Fi only stay unavailable until you turn that switch off."
                    : "Pick which radios Live shows. One radio is Wi-Fi or BLE, not both.")
            HStack(spacing: 8) {
                FieldwatchFilterChip(
                    selected: !filter.movingWithYou && filter.showWifi && filter.showBle,
                    enabled: !filter.movingWithYou,
                    label: "Both"
                ) { update { $0.showWifi = true; $0.showBle = true } }
                FieldwatchFilterChip(
                    selected: !filter.movingWithYou && filter.showWifi && !filter.showBle,
                    enabled: !filter.movingWithYou,
                    label: "Wi-Fi only"
                ) { update { $0.showWifi = true; $0.showBle = false } }
                FieldwatchFilterChip(
                    selected: filter.movingWithYou || (filter.showBle && !filter.showWifi),
                    label: "BLE only"
                ) { update { $0.showWifi = false; $0.showBle = true } }
            }
        }
    }

    private var movingCard: some View {
        SectionCard(title: "Moving with you") {
            switchRow("Moving with you", checked: filter.movingWithYou) { on in
                vm.updateFilter { current in
                    var next = current
                    if !on {
                        next.movingWithYou = false
                        return next
                    }
                    // Follow test is BLE. Leftover Trackers / Show only hides
                    // unmatched rows; AirTags rotate, so Live looks empty.
                    let hiding = current.useClassFilter && current.excludeClasses
                    next.movingWithYou = true
                    next.showWifi = false
                    next.showBle = true
                    next.namedOnly = false
                    next.customNamesOnly = false
                    next.watchedOnly = false
                    next.useClassFilter = hiding
                    next.excludeClasses = hiding
                    next.classes = hiding ? current.classes : []
                    next.includeSignatures = false
                    return next
                }
            }
            caption(movingHint)
        }
    }

    private var movingHint: String {
        let span = Int(state.operatorSpanM)
        let hideMine = filter.hideMine ? " Hide my radios is on, so those stay off this list." : ""
        if !state.settings.tagLocation {
            return "Turn on Tag detections with GPS, then walk or drive. " +
                "This shows loud Bluetooth radios that stay with you. Wi-Fi access points stay off. " +
                "Turning this on clears the other “only” filters, except Hide these."
        }
        if state.operatorSpanM < 45.0 {
            let other: String
            if filter.customNamesOnly {
                other = " Named radios only is also on, so unlabeled radios stay hidden."
            } else if filter.watchedOnly {
                other = " Watched only is also on, so unwatched radios stay hidden."
            } else if filter.namedOnly || filter.namedOnlyImplied() {
                other = " Signatures only or Show only is also on, so unmatched radios stay hidden."
            } else {
                other = ""
            }
            return "Location path so far \(span) m. Keep moving until about 50 m. " +
                "If this stays at 0 while you move, check that Location Services is on for Fieldwatch. " +
                "A phone that keeps changing its Bluetooth address will not match." + other + hideMine
        }
        if filter.customNamesOnly || filter.watchedOnly || filter.namedOnly || filter.namedOnlyImplied() {
            return "Location path \(span) m. Another “only” filter is on, so only those radios can match. " +
                "A tag in a bag or a car should show. Wi-Fi stays hidden." + hideMine
        }
        return "Location path \(span) m. Loud Bluetooth heard along that path at a steady level. " +
            (filter.hideMine ? "Hide my radios is on, so those stay off this list. " : "A tag in a bag or a car should show. ") +
            "Wi-Fi stays hidden, because a strong access point can look like it is traveling with you. " +
            "A phone that keeps changing its Bluetooth address will not show as one follower. " +
            "Live → Start over clears the path so you can test again."
    }

    private var arrivalsCard: some View {
        SectionCard(title: "New detections") {
            switchRow(state.arrivalsLearning ? "New detections only  ·  learning" : "New detections only",
                      checked: filter.arrivalsOnly) { on in update { $0.arrivalsOnly = on } }
            caption(arrivalsHint)
        }
    }

    private var arrivalsHint: String {
        if filter.arrivalsOnly {
            let tail: String
            if state.arrivalsLearning {
                tail = "Learning the Wi-Fi that is already here."
            } else if state.hiddenKnown > 0 {
                tail = "\(state.hiddenKnown) already-seen radios are hidden."
            } else {
                tail = "Nothing is marked seen yet."
            }
            return "Mark seen and Reset seen are on Live, above the list. " + tail
        }
        return "Hides radios already here so Live shows only new ones. " +
            "Mark seen and Reset seen appear on Live while this is on. " +
            "Brief hold still sets how long a new radio stays after the last packet. " +
            "A Bluetooth radio that changes its address looks new."
    }

    private var whoStaysCard: some View {
        let namedImplied = filter.namedOnlyImplied()
        return SectionCard(title: "Who stays") {
            switchRow("Signatures only (hide unmatched)", checked: filter.namedOnly || namedImplied,
                      enabled: !namedImplied, dim: namedImplied) { on in
                if !namedImplied { update { $0.namedOnly = on } }
            }
            if namedImplied {
                caption("Show only is already hiding unmatched radios. Turn Show only off to use this switch.")
            }

            switchRow("Watched only", checked: filter.watchedOnly) { on in update { $0.watchedOnly = on } }
            caption("Live shows bookmarked signatures, and named radios with Alert on. Hide these still applies. A name with no bookmark stays under Named radios only.")

            switchRow("Named radios only", checked: filter.customNamesOnly) { on in update { $0.customNamesOnly = on } }
            caption("Live shows radios you named. Alert can be off. A radio that changes its address will not keep that name.")

            switchRow("Hide my radios", checked: filter.hideMine) { on in update { $0.hideMine = on } }
            caption("Radios marked Mine stay off Live. The sit and Debrief still have them. Moving with you leaves this on.")

            switchRow("Hide Fast Pair account-key", checked: filter.hideFastPairAccountKey) { on in
                update { $0.hideFastPairAccountKey = on }
            }
            caption("Hides already-paired Fast Pair radios that match no other signature. Radios still in pairing mode stay. Hide selected signatures can hide those too.")
        }
    }

    private var classesCard: some View {
        SectionCard(title: "Signature classes") {
            caption("Live only. Signatures still label, log, and can beep. Pick Show only or Hide these, then the classes. Show only with nothing picked leaves Live unchanged. Save current as… keeps this as a preset.")
            HStack(spacing: 8) {
                FieldwatchFilterChip(selected: filter.useClassFilter && !filter.excludeClasses, label: "Show only") {
                    update { f in
                        let on = !(f.useClassFilter && !f.excludeClasses)
                        f.useClassFilter = on
                        f.excludeClasses = false
                    }
                }
                FieldwatchFilterChip(selected: filter.useClassFilter && filter.excludeClasses, label: "Hide these") {
                    update { f in
                        let on = !(f.useClassFilter && f.excludeClasses)
                        f.useClassFilter = on
                        f.excludeClasses = on
                    }
                }
            }
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 4) {
                ForEach(SignatureClass.visible.sortedBy { $0.label().lowercase() }, id: \.self) { kind in
                    let on = filter.classes.contains(kind)
                    GridChip(selected: on, label: kind.label(), glyph: ClassGlyphs.of(kind)) {
                        update { f in
                            if on { f.classes.remove(kind) } else { f.classes.insert(kind) }
                        }
                    }
                }
            }
        }
    }

    private var signaturesCard: some View {
        SectionCard(title: "Selected signatures") {
            switchRow("Show only selected signatures", checked: filter.includeSignatures) { on in
                update { $0.includeSignatures = on }
            }
            if filter.includeSignatures {
                SignaturePickList(
                    fleets: state.fleets,
                    selected: filter.includeFleetIds,
                    help: "Click a class to open it. Live keeps radios that match a signature you turn on. An empty list leaves Live unchanged. Your picks stay if you turn this off and back on.",
                    onToggle: { id, checked in
                        update { f in
                            if checked { f.includeFleetIds.insert(id) } else { f.includeFleetIds.remove(id) }
                        }
                    }
                )
            }

            switchRow("Hide selected signatures", checked: filter.excludeSignatures) { on in
                update { $0.excludeSignatures = on }
            }
            if filter.excludeSignatures {
                SignaturePickList(
                    fleets: state.fleets,
                    selected: filter.fleetIds,
                    help: "Click a class to open it. Radios that match a signature you turn on stay off Live. Your picks stay if you turn this off and back on.",
                    onToggle: { id, checked in
                        update { f in
                            if checked { f.fleetIds.insert(id) } else { f.fleetIds.remove(id) }
                        }
                    }
                )
            }
        }
    }

    private var rssiShown: Int { rssiEditing ? rssiDrag : filter.rssiMin }

    private var fineFilterCard: some View {
        SectionCard(title: "Fine filter") {
            Text("Minimum RSSI  \(rssiShown) dBm").font(.system(size: 13, weight: .medium))
            FieldwatchSlider(
                value: Binding(
                    get: { Double(rssiShown) },
                    set: { v in
                        let n = Int(v.rounded())
                        if rssiEditing {
                            rssiDrag = n
                        } else if n != filter.rssiMin {
                            // Keyboard / accessibility change outside a drag: commit at once.
                            update { $0.rssiMin = n }
                        }
                    }
                ),
                range: -100 ... -30,
                step: 1,
                onEditingChanged: { editing in
                    if editing {
                        rssiDrag = filter.rssiMin
                        rssiEditing = true
                    } else {
                        let v = rssiDrag
                        rssiEditing = false
                        update { $0.rssiMin = v }
                    }
                }
            )

            FieldwatchOutlinedField(
                label: "Name / MAC contains",
                text: Binding(get: { filter.nameQuery }, set: { v in update { $0.nameQuery = v } })
            )
            FieldwatchOutlinedField(
                label: "Vendor contains",
                text: Binding(get: { filter.ouiQuery }, set: { v in update { $0.ouiQuery = v } })
            )

            Text("Name, vendor, signal, and class").font(.system(size: 13, weight: .medium))
            caption("AND means all of these match. OR means any one of them. This does not change the radio type, the “only” switches, Hide my radios, Hide Fast Pair, or a hide list.")
            HStack(spacing: 8) {
                FieldwatchFilterChip(selected: filter.logic == .and, label: "AND") { update { $0.logic = .and } }
                FieldwatchFilterChip(selected: filter.logic == .or, label: "OR") { update { $0.logic = .or } }
            }

            FieldwatchActionButton("Reset filter") { confirmReset = true }
        }
    }
}

// MARK: - Signature pick list

private struct SignaturePickList: View {
    @Environment(\.fw) var fw
    let fleets: [Fleet]
    let selected: Set<String>
    let help: String
    let onToggle: (String, Bool) -> Void
    @State private var open: Set<String>

    init(fleets: [Fleet], selected: Set<String>, help: String, onToggle: @escaping (String, Bool) -> Void) {
        self.fleets = fleets
        self.selected = selected
        self.help = help
        self.onToggle = onToggle
        let groups = SignaturePickList.groups(fleets)
        _open = State(initialValue: Set(groups.filter { $0.1.any { selected.contains($0.id) } }.map { $0.0.rawValue }))
    }

    static func groups(_ fleets: [Fleet]) -> [(SignatureClass, [Fleet])] {
        fleets.groupByOrdered { $0.kind.folded() }
            .sortedBy { $0.0.label().lowercase() }
            .map { ($0.0, $0.1.sortedBy { $0.name.lowercase() }) }
    }

    var body: some View {
        let groups = SignaturePickList.groups(fleets)
        VStack(alignment: .leading, spacing: 4) {
            Text(help)
                .font(.system(size: 12))
                .foregroundStyle(fw.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(groups, id: \.0) { kind, rows in
                let classId = kind.rawValue
                let expanded = open.contains(classId)
                let picked = rows.count { selected.contains($0.id) }
                Button {
                    if expanded { open.remove(classId) } else { open.insert(classId) }
                } label: {
                    HStack(spacing: 0) {
                        Image(systemName: ClassGlyphs.of(kind))
                            .font(.system(size: 13))
                            .foregroundStyle(fw.onSurfaceVariant)
                            .frame(width: 16, height: 16)
                        Spacer().frame(width: 8)
                        Text(kind.label())
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text((expanded ? "▾  " : "▸  ") + (picked > 0 ? "\(picked)/" : "") + "\(rows.count)")
                            .font(.system(size: 12))
                            .foregroundStyle(picked > 0 ? fw.primary : fw.onSurfaceVariant)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    ForEach(rows) { fleet in
                        let on = selected.contains(fleet.id)
                        Toggle(isOn: Binding(get: { on }, set: { onToggle(fleet.id, $0) })) {
                            Text(fleet.name).font(.system(size: 13))
                        }
                        .toggleStyle(FieldwatchToggleStyle())
                        .padding(.leading, 24)
                    }
                }
            }
        }
        .padding(.leading, 24)
    }
}

// MARK: - Chips

/// Kotlin PresetChip: a full-cell chip; click applies, long-press (right-click here) deletes.
private struct PresetChip: View {
    @Environment(\.fw) var fw
    var name: String
    var selected: Bool = false
    var onApply: () -> Void
    var onLongPress: () -> Void

    var body: some View {
        Button(action: onApply) {
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .foregroundStyle(fw.onSurface)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? fw.sectionFill : fw.tileFill))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? fw.active : fw.tileEdge, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(name)
        .contextMenu {
            Button("Apply preset", action: onApply)
            Button("Delete preset…", role: .destructive, action: onLongPress)
        }
    }
}

/// Class chip that fills its grid cell (Kotlin FieldwatchFilterChip with weight(1f)).
private struct GridChip: View {
    @Environment(\.fw) var fw
    var selected: Bool
    var label: String
    var glyph: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(fw.active)
                }
                Image(systemName: glyph).font(.system(size: 12)).frame(width: 14, height: 14)
                Text(label).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 32, alignment: .leading)
            .foregroundStyle(fw.onSurface)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? fw.sectionFill : fw.tileFill))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? fw.active : fw.tileEdge, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
