import SwiftUI
import FieldwatchCore

// Port of ui/screen/DecodeFieldsScreen.kt — the signature decode map editor (manual §9.6).

/// One field card in the editor, with a stable identity so card state survives reorders and deletes.
struct DecodeFieldDraftRow: Identifiable, Hashable {
    let id = UUID()
    var field: DecodeField
}

struct DecodeFieldsScreen: View {
    var fleet: Fleet
    var previewDevice: Sighting?
    var onSave: (FleetDecode?) -> Void
    var onBack: () -> Void
    /// Mac addition: every on-air radio this signature matches, so Preview can pick one. Empty = previewDevice only.
    var previewChoices: [Sighting] = []

    @Environment(\.fw) var fw
    @State var source: DecodeSource
    @State var companyText: String
    @State var serviceUuid: String
    @State var rows: [DecodeFieldDraftRow]
    @State var confirmRemove = false
    @State var previewKey: String? = nil
    let includeCompanyId: Bool

    init(
        fleet: Fleet,
        previewDevice: Sighting?,
        onSave: @escaping (FleetDecode?) -> Void,
        onBack: @escaping () -> Void,
        previewChoices: [Sighting] = []
    ) {
        self.fleet = fleet
        self.previewDevice = previewDevice
        self.onSave = onSave
        self.onBack = onBack
        self.previewChoices = previewChoices
        let initial = fleet.decode
        _source = State(initialValue: initial?.source ?? .manufacturerData)
        let cid = initial?.companyId ?? 0
        _companyText = State(initialValue: cid != 0 ? format("0x%04X", cid) : "")
        _serviceUuid = State(initialValue: initial?.serviceUuid ?? "")
        _rows = State(initialValue: (initial?.fields ?? []).map { DecodeFieldDraftRow(field: $0) })
        includeCompanyId = initial?.includeCompanyId == true
    }

    private func currentDecode() -> FleetDecode? {
        let cleaned = rows.map(\.field).filter { $0.label.isNotBlank && $0.id.isNotBlank }.map { $0.normalized() }
        if cleaned.isEmpty { return nil }
        return FleetDecode(
            source: source,
            serviceUuid: serviceUuid.trim().nonBlank,
            companyId: parseCompanyId(companyText),
            includeCompanyId: includeCompanyId,
            fields: cleaned
        )
    }

    private var effectivePreview: Sighting? {
        if let key = previewKey, let hit = previewChoices.first(where: { $0.key == key }) { return hit }
        return previewDevice
    }

    var body: some View {
        let previewDecode = currentDecode()
        let device = effectivePreview
        let previewRows: [DecodedFieldValue] = {
            guard let previewDecode, let device else { return [] }
            var f = fleet
            f.decode = previewDecode
            return SignatureFieldDecoder.decodeFleet(fleet: f, decode: previewDecode, device: device)
        }()
        let previewHex: String? = {
            guard let previewDecode, let device else { return nil }
            return SignatureFieldDecoder.payloadHex(decode: previewDecode, device: device)
        }()

        VStack(spacing: 0) {
            EditorTopBar(
                title: "Decode fields",
                subtitle: fleet.name,
                cancelTitle: "Back",
                onCancel: onBack,
                onSave: { onSave(currentDecode()) }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    sourceSection
                    fieldsSection
                    SectionCard(title: "Preview") {
                        if previewChoices.count > 1 { previewPicker(selected: device) }
                        DecodePreviewBlock(previewDevice: device, previewHex: previewHex, previewRows: previewRows)
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
            }
        }
        .background(fw.background)
        .alert("Remove decode map?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { onSave(nil) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears all fields on this signature. Live no longer shows the code mark. Raw advertisements stay. This cannot be undone except by adding fields again.")
        }
    }

    private var sourceSection: some View {
        SectionCard(title: "Source") {
            Text("Map cleartext BLE bytes after this signature matches. Encrypted ads stay hex.")
                .font(.system(size: 12))
                .foregroundStyle(fw.onSurfaceVariant)
            HStack(spacing: 8) {
                FieldwatchFilterChip(selected: source == .manufacturerData, label: "Manufacturer") { source = .manufacturerData }
                FieldwatchFilterChip(selected: source == .serviceData, label: "Service data") { source = .serviceData }
            }
            if source == .manufacturerData {
                FleetDraftField(label: "Company ID", value: companyText, placeholder: "0x0499", monospaced: true) { companyText = $0 }
                    .frame(maxWidth: 260)
                Text("Optional. Byte 0 is the first byte after the company ID. Empty = any record.")
                    .font(.system(size: 12))
                    .foregroundStyle(fw.onSurfaceVariant)
            } else {
                FleetDraftField(label: "Service UUID", value: serviceUuid, placeholder: "FEAA", monospaced: true) { serviceUuid = $0 }
                    .frame(maxWidth: 420)
                Text("Required. 16-bit (FEAA) or full UUID.")
                    .font(.system(size: 12))
                    .foregroundStyle(fw.onSurfaceVariant)
            }
        }
    }

    private var fieldsSection: some View {
        SectionCard(title: "Fields") {
            ForEach($rows) { $row in
                DecodeFieldCard(
                    field: row.field,
                    onChange: { row.field = $0 },
                    onDelete: { rows.removeAll { $0.id == row.id } }
                )
            }
            FieldwatchActionButton(action: addField) {
                Image(systemName: "plus")
                Text("Add field")
            }
            .frame(maxWidth: .infinity)
            if fleet.decode != nil || rows.isNotEmpty {
                FieldwatchActionButton(action: { confirmRemove = true }) {
                    Image(systemName: "trash")
                    Text("Remove decode map")
                }
                .frame(maxWidth: .infinity)
                Text("Removes every field and the Live code mark. Save after adding fields still keeps the map.")
                    .font(.system(size: 12))
                    .foregroundStyle(fw.onSurfaceVariant)
            }
        }
    }

    private func addField() {
        let nextOffset = rows.last.map { $0.field.offset + $0.field.resolvedLength() } ?? 0
        let n = rows.count + 1
        rows.append(DecodeFieldDraftRow(field: DecodeField(id: "field_\(n)", label: "Field \(n)", offset: nextOffset, type: .u8)))
    }

    private func previewPicker(selected: Sighting?) -> some View {
        let choices = Array(previewChoices.prefix(40))
        return FieldwatchDropdownField(
            label: "Preview radio (\(previewChoices.count) matching)",
            options: choices.map(\.key),
            selection: selected?.key ?? choices.first?.key ?? "",
            title: { key in
                guard let d = choices.first(where: { $0.key == key }) else { return key }
                let name = d.name.isNotBlank ? d.name : d.mac
                return "\(name) · \(d.rssi) dBm\(d.gone ? " · gone" : "")"
            },
            onSelect: { previewKey = $0 }
        )
        .frame(maxWidth: 420)
    }
}

// MARK: - Preview

private struct DecodePreviewBlock: View {
    @Environment(\.fw) var fw
    var previewDevice: Sighting?
    var previewHex: String?
    var previewRows: [DecodedFieldValue]

    var body: some View {
        if previewDevice == nil {
            note("No matching radio on the air. Save anyway; detail will fill in when one is heard.")
        } else if previewHex.isNullOrBlank {
            note("A matching radio is on the air, but this advertisement has no bytes for the source above.")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text((previewHex ?? "").hexSpaced())
                    .font(FW.mono(12))
                    .foregroundStyle(fw.onSurfaceVariant)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if previewRows.isEmpty {
                    note("Nothing parsed. Check offset, length, and that byte 0 is after the company ID.")
                } else {
                    ForEach(Array(previewRows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.label)
                                .font(.system(size: 13))
                                .foregroundStyle(fw.onSurfaceVariant)
                                .padding(.trailing, 12)
                            Spacer(minLength: 8)
                            Text(row.display)
                                .font(.system(size: 13))
                                .foregroundStyle(fw.onSurface)
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(fw.onSurfaceVariant).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Field card

private struct DecodeFieldCard: View {
    @Environment(\.fw) var fw
    var field: DecodeField
    var onChange: (DecodeField) -> Void
    var onDelete: () -> Void
    @State private var more: Bool

    init(field: DecodeField, onChange: @escaping (DecodeField) -> Void, onDelete: @escaping () -> Void) {
        self.field = field
        self.onChange = onChange
        self.onDelete = onDelete
        _more = State(initialValue: !looksGeneratedId(id: field.id, label: field.label) || field.modulo != nil)
    }

    private var needsEndian: Bool { ![.u8, .i8, .utf8, .hex, .bool].contains(field.type) }
    private var numeric: Bool { [.u8, .i8, .u16, .i16, .u24, .u32, .i32, .f32, .bits].contains(field.type) }

    private func edit(_ f: (inout DecodeField) -> Void) {
        var next = field
        f(&next)
        onChange(next)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                FleetDraftField(label: "Label", value: field.label) { next in
                    edit { f in
                        if looksGeneratedId(id: f.id, label: f.label) { f.id = slugId(next) }
                        f.label = next
                    }
                }
                FieldwatchDropdownField(
                    label: "Type",
                    options: DecodeType.allCases,
                    selection: field.type,
                    title: { $0.rawValue },
                    onSelect: { t in edit { $0.type = t } }
                )
                .frame(width: 112)
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(fw.onSurfaceVariant)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete field")
                .accessibilityLabel("Delete field")
            }
            HStack(alignment: .bottom, spacing: 8) {
                FleetDraftField(label: "Offset", value: "\(field.offset)", monospaced: true) { s in
                    edit { $0.offset = s.trim().toIntOrNull() ?? 0 }
                }
                FleetDraftField(label: "Length", value: "\(field.length ?? field.type.defaultLength())", monospaced: true) { s in
                    edit { $0.length = s.trim().toIntOrNull()?.coerceAtLeast(1) }
                }
                FleetDraftField(label: "Unit", value: field.unit ?? "") { s in
                    edit { $0.unit = s.isBlank ? nil : s }
                }
                .frame(width: 72)
                if needsEndian {
                    FieldwatchDropdownField(
                        label: "Endian",
                        options: DecodeEndian.allCases,
                        selection: field.endian,
                        title: { $0 == .be ? "BE (big)" : "LE (little)" },
                        onSelect: { e in edit { $0.endian = e } }
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            if field.type == .bits || numeric {
                HStack(alignment: .bottom, spacing: 8) {
                    if field.type == .bits {
                        FleetDraftField(label: "Bit offset", value: "\(field.bitOffset ?? 0)", monospaced: true) { s in
                            edit { $0.bitOffset = s.trim().toIntOrNull() ?? 0 }
                        }
                        FleetDraftField(label: "Bit width", value: "\(field.bitWidth ?? 1)", monospaced: true) { s in
                            edit { $0.bitWidth = s.trim().toIntOrNull()?.coerceAtLeast(1) ?? 1 }
                        }
                    }
                    if numeric {
                        FleetDraftField(label: "Scale", value: field.scale.map { kotlinDouble($0) } ?? "", monospaced: true) { s in
                            edit { $0.scale = s.trim().toDoubleOrNull() }
                        }
                        FleetDraftField(label: "Add", value: field.offsetAdd.map { kotlinDouble($0) } ?? "", monospaced: true) { s in
                            edit { $0.offsetAdd = s.trim().toDoubleOrNull() }
                        }
                    }
                }
            }
            OnlyIfBlock(gate: field.gate, depth: 0, onChange: { g in edit { $0.gate = g } })
            FieldwatchSwitch(
                "Live row",
                subtitle: "Show this value next to the signature name. Strong values use a heavier chip.",
                checked: field.live,
                onChange: { v in edit { $0.live = v } }
            )
            NamedValuesBlock(field: field, onChange: onChange)
            if !more {
                TextAction(title: "More") { more = true }
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    FleetDraftField(label: "ID", value: field.id, monospaced: true) { s in
                        edit { $0.id = String(s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }) }
                    }
                    if numeric {
                        FleetDraftField(label: "Modulo", value: field.modulo.map { kotlinDouble($0) } ?? "", monospaced: true) { s in
                            edit { $0.modulo = s.trim().toDoubleOrNull() }
                        }
                    }
                }
                TextAction(title: "Hide extra") { more = false }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(fw.tileFill))
    }
}

/// Kotlin `Double.toString()` for whole numbers prints "1.0"; Swift prints "1.0" too, but small values
/// print as "1e-07" (Kotlin "1.0E-7"). Both parse back the same; keep Swift's form.
private func kotlinDouble(_ d: Double) -> String { "\(d)" }

// MARK: - Only if (gates, with nested `and`)

private struct OnlyIfBlock: View {
    @Environment(\.fw) var fw
    var gate: DecodeWhen?
    var depth: Int
    var onChange: (DecodeWhen?) -> Void

    var body: some View {
        if let gate {
            VStack(alignment: .leading, spacing: 8) {
                Text(depth == 0 ? "Only if" : "And also")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(fw.onSurface)
                if gate.op == .len {
                    HStack(alignment: .bottom, spacing: 8) {
                        WhenOpMenu(op: gate.op) { op in var g = gate; g.op = op; onChange(g) }
                        FleetDraftField(label: "Bytes", value: "\(gate.length)", monospaced: true) { s in
                            var g = gate; g.length = s.trim().toIntOrNull()?.coerceAtLeast(1) ?? 1; onChange(g)
                        }
                        .frame(width: 96)
                    }
                } else {
                    HStack(alignment: .bottom, spacing: 8) {
                        FleetDraftField(label: "Offset", value: "\(gate.offset)", monospaced: true) { s in
                            var g = gate; g.offset = s.trim().toIntOrNull() ?? 0; onChange(g)
                        }
                        .frame(width: 80)
                        FleetDraftField(label: "Length", value: "\(gate.length)", monospaced: true) { s in
                            var g = gate; g.length = s.trim().toIntOrNull()?.coerceAtLeast(1) ?? 1; onChange(g)
                        }
                        .frame(width: 80)
                        WhenOpMenu(op: gate.op) { op in var g = gate; g.op = op; onChange(g) }
                        FleetDraftField(label: "Hex", value: gate.valueHex, placeholder: "05", monospaced: true) { s in
                            var g = gate; g.valueHex = s; onChange(g)
                        }
                        .frame(width: 120)
                    }
                }
                HStack(spacing: 4) {
                    // Remove this condition; a nested `and` moves up in its place.
                    TextAction(title: "Remove") { onChange(gate.and) }
                    if gate.and == nil {
                        TextAction(title: "And also…") {
                            var g = gate
                            g.and = DecodeWhen(offset: 0, length: 1, op: .eq, valueHex: "")
                            onChange(g)
                        }
                    }
                }
                if let next = gate.and {
                    AnyView(
                        OnlyIfBlock(gate: next, depth: depth + 1, onChange: { child in
                            var g = gate; g.and = child; onChange(g)
                        })
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(fw.outline).frame(width: 2)
                        }
                    )
                }
            }
        } else if depth == 0 {
            TextAction(title: "Only if…") {
                onChange(DecodeWhen(offset: 0, length: 1, op: .eq, valueHex: ""))
            }
        }
    }
}

private struct WhenOpMenu: View {
    var op: DecodeWhenOp
    var onChange: (DecodeWhenOp) -> Void

    var body: some View {
        FieldwatchDropdownField(
            label: "When",
            options: [DecodeWhenOp.eq, .neq, .mask, .nmask, .len],
            selection: op,
            title: whenOpLabel,
            onSelect: onChange
        )
        .frame(minWidth: 130, maxWidth: 180)
    }
}

private func whenOpLabel(_ op: DecodeWhenOp) -> String {
    switch op {
    case .eq: return "equals"
    case .neq: return "not equals"
    case .mask: return "mask"
    case .nmask: return "none of bits"
    case .len: return "payload length"
    }
}

// MARK: - Named values

private struct NamedValueRow: Identifiable {
    let id = UUID()
    var raw: String
    var shown: String
}

private struct NamedValuesBlock: View {
    @Environment(\.fw) var fw
    var field: DecodeField
    var onChange: (DecodeField) -> Void
    @State private var rows: [NamedValueRow]
    @State private var open: Bool

    init(field: DecodeField, onChange: @escaping (DecodeField) -> Void) {
        self.field = field
        self.onChange = onChange
        // Swift dictionaries are unordered: show the table sorted by raw key (numeric-aware).
        let initial = (field.enumLabels ?? [:])
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { NamedValueRow(raw: $0.key, shown: $0.value) }
        _rows = State(initialValue: initial)
        _open = State(initialValue: initial.isNotEmpty)
    }

    private func publish(_ nextRows: [NamedValueRow], emphasis: [String]? = nil, notes: [String: String]?? = nil) {
        var f = field
        f.enumLabels = toEnumMap(nextRows)
        f.liveEmphasis = emphasis ?? field.liveEmphasis
        let n: [String: String]? = notes ?? field.enumNotes
        let kept = n?.filter { $0.value.isNotBlank }
        f.enumNotes = (kept?.isEmpty ?? true) ? nil : kept
        onChange(f)
    }

    var body: some View {
        if !open {
            TextAction(title: "Named values…") {
                open = true
                rows = [NamedValueRow(raw: "", shown: "")]
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Named values").font(.system(size: 13, weight: .semibold)).foregroundStyle(fw.onSurface)
                ForEach(rows) { row in
                    valueRow(row)
                }
                HStack(spacing: 4) {
                    TextAction(title: "Add value") { rows.append(NamedValueRow(raw: "", shown: "")) }
                    TextAction(title: "Remove") {
                        open = false
                        rows = []
                        var f = field
                        f.enumLabels = nil
                        f.liveEmphasis = []
                        f.enumNotes = nil
                        onChange(f)
                    }
                }
            }
        }
    }

    @ViewBuilder private func valueRow(_ row: NamedValueRow) -> some View {
        let raw = row.raw
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                FleetDraftField(label: "Raw", value: raw, monospaced: true) { next in
                    guard let i = rows.firstIndex(where: { $0.id == row.id }) else { return }
                    var nextRows = rows
                    nextRows[i].raw = next
                    rows = nextRows
                    let emphasis = field.liveEmphasis.map { $0 == raw ? next : $0 }
                    let notes: [String: String]? = field.enumNotes.map { m in
                        var out: [String: String] = [:]
                        for (k, v) in m { out[k == raw ? next : k] = v }
                        return out
                    }
                    publish(nextRows, emphasis: emphasis, notes: .some(notes))
                }
                .frame(width: 88)
                FleetDraftField(label: "Show as", value: row.shown) { next in
                    guard let i = rows.firstIndex(where: { $0.id == row.id }) else { return }
                    var nextRows = rows
                    nextRows[i].shown = next
                    rows = nextRows
                    publish(nextRows)
                }
                Button {
                    let nextRows = rows.filter { $0.id != row.id }
                    rows = nextRows
                    let emphasis = field.liveEmphasis.filter { $0 != raw }
                    let notes = field.enumNotes?.filter { $0.key != raw }
                    if nextRows.isEmpty {
                        open = false
                        var f = field
                        f.enumLabels = nil
                        f.liveEmphasis = emphasis
                        f.enumNotes = (notes?.isEmpty ?? true) ? nil : notes
                        onChange(f)
                    } else {
                        publish(nextRows, emphasis: emphasis, notes: .some(notes))
                    }
                } label: {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(fw.onSurfaceVariant)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete value")
                .accessibilityLabel("Delete value")
            }
            if field.live && raw.isNotBlank {
                let strong = field.liveEmphasis.contains(raw)
                HStack(alignment: .bottom, spacing: 8) {
                    FieldwatchFilterChip(selected: strong, label: "Strong") {
                        let emphasis = strong ? field.liveEmphasis.filter { $0 != raw } : field.liveEmphasis + [raw]
                        publish(rows, emphasis: emphasis)
                    }
                    .padding(.bottom, 2)
                    FleetDraftField(label: "Note", value: field.enumNotes?[raw] ?? "") { note in
                        var notes = field.enumNotes ?? [:]
                        if note.isBlank { notes.removeValue(forKey: raw) } else { notes[raw] = note }
                        publish(rows, notes: .some(notes))
                    }
                }
                .padding(.leading, 96)
            }
        }
    }
}

private func toEnumMap(_ rows: [NamedValueRow]) -> [String: String]? {
    var out: [String: String] = [:]
    for r in rows {
        let key = r.raw.trim()
        let label = r.shown.trim()
        if key.isEmpty || label.isEmpty { continue }
        out[key] = label
    }
    return out.isEmpty ? nil : out
}

// MARK: - Small pieces

/// Compose `TextButton`.
private struct TextAction: View {
    @Environment(\.fw) var fw
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(fw.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private func parseCompanyId(_ text: String) -> Int? {
    let t = text.trim()
    if t.isEmpty { return nil }
    var hex = t
    if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = hex.drop(2) }
    return hex.toIntOrNull(16) ?? t.toIntOrNull()
}

private func slugId(_ label: String) -> String {
    let slug = String(label.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }).trim("_")
    let clipped = slug.take(32).ifBlank("field")
    return clipped.first!.isLetter ? clipped : "f_\(clipped)"
}

private func looksGeneratedId(id: String, label: String) -> Bool {
    if id == slugId(label) { return true }
    guard id.hasPrefix("field_") else { return false }
    let digits = id.drop(6)
    return digits.isNotEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
}
