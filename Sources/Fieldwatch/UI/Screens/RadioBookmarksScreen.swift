import SwiftUI
import AppKit
import FieldwatchCore

// Port of ui/screen/RadioBookmarksScreen.kt. The rename/notes AlertDialog is a sheet; Clear all is an alert.
// Rows also get a context menu (Copy MAC, Copy name, Edit, Remove).

struct RadioBookmarksScreen: View {
    var state: FieldwatchUi
    var vm: FieldwatchViewModel
    var onBack: () -> Void
    var onOpen: (String) -> Void
    @Environment(\.fw) var fw
    @State var clearAll = false
    @State var renameId: String? = nil

    var body: some View {
        let radios = RadioBookmarks.radios(watchlist: state.watchlist)
        let liveKeys = Set(state.devices.filter { !$0.gone }.map { $0.key })
        let demoMode = state.settings.demoMode
        let renameTarget = radios.first { $0.id == renameId }

        VStack(spacing: 0) {
            NestedTopBar(title: "Named radios (\(radios.count))", onBack: onBack)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text(
                        "One MAC each. Custom name shows on Live. Mine marks it as yours: no beep while on, still listed. " +
                            "Observer notes show on detail and reports. Alert is optional (pip / voice / flash). " +
                            "Filters → Named radios only hides everything else. Signature watches stay on Signatures."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(fw.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)

                    if radios.isEmpty {
                        Text("No named radios. Set a custom name on detail, or bookmark a radio (top-right) to watch it.")
                            .font(.system(size: 13))
                            .foregroundStyle(fw.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)
                    } else {
                        ForEach(radios) { row in
                            let parsed = row.deviceKey.flatMap { RadioBookmarks.parseKey(key: $0) }
                            let kind = parsed?.0 ?? .ble
                            let rawMac = parsed?.1 ?? (row.deviceKey ?? "")
                            let onAir = row.deviceKey.map { liveKeys.contains($0) } ?? false
                            BookmarkCard(
                                row: row,
                                kind: kind,
                                mac: MacUtil.screenMac(mac: rawMac, demo: demoMode),
                                onAir: onAir,
                                onOpen: {
                                    guard let key = row.deviceKey, onAir else { return }
                                    onOpen(key)
                                },
                                onAlert: { on in vm.setRadioAlert(id: row.id, on: on) },
                                onMine: { on in vm.setNamedRadioMine(id: row.id, on: on) },
                                onRename: { renameId = row.id },
                                onRemove: { vm.removeRadioBookmark(id: row.id) }
                            )
                        }
                        FieldwatchActionButton("Clear all \(radios.count) named radios…") { clearAll = true }
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(fw.background)
        .alert("Clear named radios?", isPresented: $clearAll) {
            Button("Clear", role: .destructive) { vm.clearRadioBookmarks() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove \(radios.count) named radios. Signature watches stay.")
        }
        .sheet(
            isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameId = nil } })
        ) {
            if let target = renameTarget {
                NamedRadioEditor(
                    target: target,
                    onSave: { name, notes in
                        vm.updateNamedRadio(id: target.id, name: name, notes: notes)
                        renameId = nil
                    },
                    onCancel: { renameId = nil }
                )
                .fieldwatchTheme(nightMode: fw.night)
            }
        }
    }
}

private struct NamedRadioEditor: View {
    @Environment(\.fw) var fw
    var target: WatchTarget
    var onSave: (String, String) -> Void
    var onCancel: () -> Void
    @State private var draft: String
    @State private var notesDraft: String

    init(target: WatchTarget, onSave: @escaping (String, String) -> Void, onCancel: @escaping () -> Void) {
        self.target = target
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: target.label)
        _notesDraft = State(initialValue: target.observerNotes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Named radio").font(.system(size: 15, weight: .semibold))
            FieldwatchOutlinedField(
                label: "Custom name",
                text: Binding(get: { draft }, set: { draft = $0.take(RadioBookmarks.MAX_NAME) })
            )
            FieldwatchOutlinedField(
                label: "Observer notes",
                text: Binding(get: { notesDraft }, set: { notesDraft = $0.take(RadioBookmarks.MAX_NOTES) }),
                supportingText: "\(notesDraft.trim().count)/\(RadioBookmarks.MAX_NOTES)",
                singleLine: false,
                minLines: 3
            )
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft, notesDraft) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
        .background(fw.surface)
    }
}

private struct BookmarkCard: View {
    @Environment(\.fw) var fw
    var row: WatchTarget
    var kind: RadioKind
    var mac: String
    var onAir: Bool
    var onOpen: () -> Void
    var onAlert: (Bool) -> Void
    var onMine: (Bool) -> Void
    var onRename: () -> Void
    var onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                RadioKindMark(kind: kind, size: 14)
                Text(row.label.ifBlank(mac))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                iconButton("pencil", help: "Edit", action: onRename)
                iconButton("trash", help: "Remove", action: onRemove)
            }
            Group {
                if row.label.isNotBlank {
                    Text(mac)
                        .font(FW.mono(11))
                        .foregroundStyle(fw.onSurfaceVariant)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                Text(onAir ? "On the air — click to open detail" : "Not this session")
                    .font(.system(size: 11))
                    .foregroundStyle(fw.onSurfaceVariant)
                    .lineLimit(1)
                let obs = row.observerNotes.trim()
                if obs.isNotEmpty {
                    Text(obs)
                        .font(.system(size: 11))
                        .foregroundStyle(fw.tertiary)
                        .lineLimit(2)
                }
                HStack(spacing: 16) {
                    miniSwitch("Mine", isOn: row.mine, onChange: onMine)
                    miniSwitch("Alert", isOn: row.alert, onChange: onAlert)
                }
                .padding(.top, 4)
            }
            .padding(.leading, 22)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(onAir && hovering ? fw.sectionFill : fw.surface)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .onTapGesture { if onAir { onOpen() } }
        .contextMenu {
            Button("Copy MAC") { copy(mac) }
            if row.label.isNotBlank { Button("Copy name") { copy(row.label) } }
            if onAir { Button("Open detail", action: onOpen) }
            Divider()
            Button("Edit…", action: onRename)
            Button("Remove", role: .destructive, action: onRemove)
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(fw.onSurfaceVariant)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func miniSwitch(_ title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { onChange($0) })) {
            Text(title).font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant)
        }
        .toggleStyle(FieldwatchToggleStyle())
        .fixedSize()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
