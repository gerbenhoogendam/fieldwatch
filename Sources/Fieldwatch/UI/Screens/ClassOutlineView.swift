import SwiftUI
import FieldwatchCore

// Port of ClassOutlineView / OutlineGroupRow / outlineRadioRow / ClassSlice.accent from
// ui/screen/LiveScreens.kt. Class headers → signatures → radios; open state lives on the view model
// (outlineOpenClasses / outlineOpenSigs, toggled with toggleOutlineClass / toggleOutlineSignature).

private enum OutlineEntry: Identifiable {
    case mode
    case empty(String)
    case summary(String)
    case classHeader(ClassSlice, subtitle: String?, accent: Color, expanded: Bool)
    case signatureHeader(sigKey: String, fleetId: String, count: Int, accent: Color, expanded: Bool, mapped: Bool)
    case radio(id: String, device: Sighting, indent: CGFloat)

    var id: String {
        switch self {
        case .mode: return "outline-mode"
        case .empty: return "outline-empty"
        case .summary: return "outline-summary"
        case let .classHeader(slice, _, _, _): return "class-\(slice.id)"
        case let .signatureHeader(sigKey, _, _, _, _, _): return "sig-\(sigKey)"
        case let .radio(id, _, _): return id
        }
    }
}

/// Kotlin `ClassOutlineView`. Display settings come in the shared `LiveRowOptions` bundle.
struct ClassOutlineView: View {
    @Environment(\.fw) var fw
    var devices: [Sighting]
    var vm: FieldwatchViewModel
    var state: FieldwatchUi
    var onOpen: (Sighting) -> Void
    var emptyHint: String? = nil
    var rows: LiveRowOptions
    @State var now: Int = nowMs()

    var body: some View {
        let model = outline()
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.entries) { entry in
                        entryView(entry)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    now = nowMs()
                }
            }
            .onChange(of: vm.liveFocus) { _, focus in
                guard focus > 0 else { return }
                withAnimation(.linear(duration: 0.14)) { proxy.scrollTo("outline-mode", anchor: .top) }
            }
            .onChange(of: vm.beepSnap.seq) {
                let snap = vm.beepSnap
                guard snap.seq > 0, snap.key.isNotBlank else { return }
                // The view model opens the class / signature with the beep; wait one pass for those rows.
                DispatchQueue.main.async {
                    let fresh = outline()
                    guard let target = ClassOutline.outlineSnap(
                        slices: fresh.visible, openClasses: vm.outlineOpenClasses, openSigs: vm.outlineOpenSigs,
                        deviceKey: snap.key, leadingItems: 2
                    ) else { return }
                    scrollOutlineToRadio(proxy, fresh.entries, target)
                }
            }
        }
    }

    /// Kotlin `scrollOutlineToRadio`: pin the class header (then the signature header) when the radio
    /// still fits under it; far-down radios fall back to the row itself. Without per-row geometry the
    /// "fits" test is a row-count budget.
    private func scrollOutlineToRadio(_ proxy: ScrollViewProxy, _ entries: [OutlineEntry], _ snap: OutlineSnap) {
        let fits = 6
        func id(_ i: Int) -> String? { entries.getOrNull(i)?.id }
        if snap.radioIndex - snap.classIndex <= fits, let cid = id(snap.classIndex) {
            proxy.scrollTo(cid, anchor: .top)
        } else if let sig = snap.signatureIndex, snap.radioIndex - sig <= fits, let sid = id(sig) {
            proxy.scrollTo(sid, anchor: .top)
        } else if let rid = id(snap.radioIndex) {
            proxy.scrollTo(rid, anchor: .top)
        }
    }

    private struct Model {
        var visible: [ClassSlice]
        var entries: [OutlineEntry]
    }

    /// One pass per refresh: slices, the summary line and the flat row list (same indices as Kotlin's LazyColumn).
    private func outline() -> Model {
        let lk = rows.lookup
        var classById: [String: SignatureClass] = [:]
        var nameById: [String: String] = [:]
        for f in state.fleets {
            classById[f.id] = f.kind
            nameById[f.id] = f.name
        }
        let slices = ClassOutline.of(devices: devices, classByFleetId: classById, nameByFleetId: nameById)
        let hideEmpty = state.settings.outlineHideEmpty
        let visible = hideEmpty ? slices.filter { $0.radios.isNotEmpty } : slices
        var entries: [OutlineEntry] = [.mode]
        if devices.isEmpty {
            entries.append(.empty(emptyHint ?? LIVE_CLASS_EMPTY))
            return Model(visible: visible, entries: entries)
        }
        let multi = ClassOutline.multiClassCount(devices: devices, classByFleetId: classById)
        let unmatched = slices.first { $0.kind == nil }?.radios.count ?? 0
        let hidden = slices.count { $0.radios.isEmpty }
        var summary = "\(devices.count) radios"
        if unmatched > 0 { summary += " · \(unmatched) unmatched" }
        if multi > 0 { summary += " · \(multi) in more than one class" }
        if hideEmpty && hidden > 0 { summary += " · \(hidden) empty hidden" }
        entries.append(.summary(summary))

        let openClasses = vm.outlineOpenClasses
        let openSigs = vm.outlineOpenSigs
        for slice in visible {
            let subtitle: String?
            if slice.radios.isEmpty {
                subtitle = nil
            } else if slice.kind == nil {
                subtitle = "no signature"
            } else if slice.signatures.count == 1 {
                subtitle = lk.fleetName(slice.signatures[0].fleetId)
            } else {
                subtitle = "\(slice.signatures.count) signatures"
            }
            let expanded = openClasses.contains(slice.id)
            entries.append(.classHeader(slice, subtitle: subtitle, accent: fw.tint(accent(slice, lk)), expanded: expanded))
            if !expanded { continue }
            if slice.kind == nil {
                for d in slice.radios { entries.append(.radio(id: "u-\(d.key)", device: d, indent: 16)) }
            } else {
                for sig in slice.signatures {
                    let sigKey = "\(slice.id)/\(sig.fleetId)"
                    let sigOpen = openSigs.contains(sigKey)
                    entries.append(.signatureHeader(
                        sigKey: sigKey, fleetId: sig.fleetId, count: sig.radios.count,
                        accent: fw.tint(lk.fleetPaletteColor(sig.fleetId)), expanded: sigOpen,
                        mapped: lk.fleetHasDecode(sig.fleetId)
                    ))
                    if sigOpen {
                        for d in sig.radios { entries.append(.radio(id: "r-\(sigKey)-\(d.key)", device: d, indent: 28)) }
                    }
                }
            }
        }
        return Model(visible: visible, entries: entries)
    }

    /// Kotlin `ClassSlice.accent(vm)`.
    private func accent(_ slice: ClassSlice, _ lk: LiveLookup) -> Color {
        let id = slice.signatures.first?.fleetId ?? slice.radios.first?.fleetIds.first
        if let id { return lk.fleetPaletteColor(id) }
        return rssiColor(-80)
    }

    @ViewBuilder
    private func entryView(_ entry: OutlineEntry) -> some View {
        switch entry {
        case .mode:
            let hideEmpty = state.settings.outlineHideEmpty
            HStack(spacing: 8) {
                FieldwatchFilterChip(selected: !hideEmpty, label: "Show all") {
                    vm.updateSettings { s in var s = s; s.outlineHideEmpty = false; return s }
                }
                FieldwatchFilterChip(selected: hideEmpty, label: "Collapse empty") {
                    vm.updateSettings { s in var s = s; s.outlineHideEmpty = true; return s }
                }
            }
        case let .empty(text):
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(fw.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
                .padding(24)
        case let .summary(text):
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(fw.onSurfaceVariant)
        case let .classHeader(slice, subtitle, accent, expanded):
            OutlineGroupRow(
                title: slice.label(), count: slice.radios.count, subtitle: subtitle, accent: accent,
                expanded: expanded, empty: slice.radios.isEmpty, glyph: ClassGlyphs.of(slice.kind),
                onToggle: { vm.toggleOutlineClass(id: slice.id) }
            )
        case let .signatureHeader(sigKey, fleetId, count, accent, expanded, mapped):
            OutlineGroupRow(
                title: rows.lookup.fleetName(fleetId), count: count, subtitle: nil, accent: accent,
                expanded: expanded, indent: true, mapped: mapped,
                onToggle: { vm.toggleOutlineSignature(id: sigKey) }
            )
        case let .radio(_, device, indent):
            outlineRadioRow(device: device)
                .padding(.leading, indent)
        }
    }

    /// Kotlin `outlineRadioRow`.
    private func outlineRadioRow(device: Sighting) -> some View {
        DeviceRow(
            device: device, vm: vm, sparklines: false, compact: false, onOpen: onOpen,
            sort: rows.sort, windowMs: rows.windowMs, showBar: rows.showBar, showNewAge: rows.showNewAge,
            showFleet: rows.showFleet, showFrequency: rows.showFrequency, showSeenTimes: rows.showSeenTimes,
            now: now, highlighted: rows.flashKeys.contains(device.key),
            titleLine: rows.titleLine, subtitleLine: rows.subtitleLine, demoMode: rows.demoMode,
            alerted: rows.alertedKeys.contains(device.key),
            lookup: rows.lookup, selected: rows.selectedKey == device.key, onHunt: rows.onHunt
        )
    }
}

/// Kotlin `OutlineGroupRow`: class header (glyph in a circle) or indented signature header (dot).
struct OutlineGroupRow: View {
    @Environment(\.fw) var fw
    var title: String
    var count: Int
    var subtitle: String?
    var accent: Color
    var expanded: Bool
    var indent: Bool = false
    var empty: Bool = false
    /// SF Symbol name (Kotlin ImageVector).
    var glyph: String? = nil
    var mapped: Bool = false
    var onToggle: () -> Void
    @State var hovered = false

    var body: some View {
        let mute = fw.onSurfaceVariant
        let mark = empty ? mute : accent
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 10) {
            if let glyph {
                ZStack {
                    Circle().fill(mark.opacity(empty ? 0.12 : 0.18))
                    Image(systemName: glyph)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(mark.opacity(empty ? 0.55 : 1))
                }
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            } else {
                Circle().fill(mark.opacity(empty ? 0.12 : 0.22)).frame(width: 10, height: 10)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(empty ? mute : fw.onSurface)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if mapped {
                        DecodeGlyph(tint: empty ? mute : accent, size: 13)
                    }
                }
                if let subtitle, subtitle.isNotBlank {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(mute)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(expanded ? "▾  \(count)" : "▸  \(count)")
                .font(FW.mono(13, weight: .bold))
                .foregroundStyle(empty ? mute : accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(shape.fill(indent ? fw.surface : fw.sectionFill))
        .overlay(shape.fill(fw.onSurface.opacity(hovered ? 0.05 : 0)).allowsHitTesting(false))
        .contentShape(shape)
        .onTapGesture(perform: onToggle)
        .onHover { hovered = $0 }
        .padding(.leading, indent ? 16 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(expanded ? "expanded" : "collapsed")
        .accessibilityAction { onToggle() }
    }
}
