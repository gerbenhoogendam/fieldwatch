import SwiftUI
import FieldwatchCore

// macOS addition: Bluetooth devices connected to this Mac. See ConnectedDevices.

struct ConnectedScreen: View {
    var vm: FieldwatchViewModel
    var onAddToRoom: () -> Void

    @Environment(\.fw) var fw
    @State var devices = ConnectedDevices.shared
    @State var renaming: ConnectedRadio?
    @State var nameDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionCard(
                    title: "Connected to this Mac",
                    subtitle: "A connected Bluetooth device stops advertising, so Live never hears it. These come from macOS's own connections. Bluetooth addresses are shown here because macOS shares them for paired devices."
                ) {
                    FieldwatchSwitch(
                        "Read signal strength",
                        subtitle: "Reads signal and battery over the connection macOS already has. No new radio connection; turning this off never disconnects a device.",
                        checked: devices.readSignal
                    ) { devices.readSignal = $0 }
                }
                if devices.radios.isEmpty {
                    Text(devices.bluetoothReady ? "No Bluetooth devices are connected to this Mac." : "Waiting for Bluetooth…")
                        .font(.system(size: 13)).foregroundStyle(fw.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.top, 30)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12)], spacing: 12) {
                    ForEach(devices.radios) { r in card(r) }
                }
            }
            .padding(16)
        }
        .background(fw.background)
        .navigationTitle("Connected")
        .alert("Name this device", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Save") { if let r = renaming { devices.setName(key: r.id, name: nameDraft) }; renaming = nil }
            if let r = renaming, devices.customNames[r.id] != nil {
                Button("Use \(r.systemName)") { devices.setName(key: r.id, name: ""); renaming = nil }
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Shown here and in Room. macOS calls it \"\(renaming?.systemName ?? "")\".")
        }
        .onAppear { devices.start() }
    }

    private func card(_ r: ConnectedRadio) -> some View {
        let demo = vm.ui.settings.demoMode
        let room = RoomController.shared(vm: vm)
        let inRoom = room.plan.device(key: r.id) != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                RadioKindMark(kind: .ble, size: 13, tint: fw.primary)
                Text(r.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Button { nameDraft = devices.customNames[r.id] ?? ""; renaming = r } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain).foregroundStyle(fw.onSurfaceVariant).help("Give it a name")
                Spacer()
                if let b = r.battery {
                    Label("\(b)%", systemImage: b > 60 ? "battery.75percent" : b > 25 ? "battery.50percent" : "battery.25percent")
                        .font(FW.mono(11)).foregroundStyle(b > 25 ? fw.onSurfaceVariant : FW.amber)
                }
            }
            HStack(spacing: 8) {
                if r.name != r.systemName { Text(r.systemName + " ·") }
                Text(r.transport.rawValue)
                if let t = r.typeLabel { Text("· \(t)") }
            }
            .font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant)
            if let a = r.address {
                HStack(spacing: 6) {
                    Text(MacUtil.screenMac(mac: a, demo: demo)).font(FW.mono(12)).textSelection(.enabled)
                    Button { vm.copyToClipboard(text: MacUtil.screenMac(mac: a, demo: demo)) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).foregroundStyle(fw.onSurfaceVariant).help("Copy address")
                    if let v = RadioDb.vendorForMac(mac: a) {
                        Text(v).font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant).lineLimit(1)
                    }
                }
            }
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                if let rssi = r.rssi {
                    Text("\(rssi)").font(.system(size: 26, weight: .semibold, design: .monospaced)).foregroundStyle(fw.tint(rssiColor(rssi)))
                    Text("dBm").font(FW.mono(11)).foregroundStyle(fw.onSurfaceVariant)
                } else {
                    Text(devices.readSignal ? "Signal not reported by this connection" : "Signal reading is off")
                        .font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant)
                }
                Spacer()
                FieldwatchActionButton(inRoom ? "In Room" : "Add to Room", enabled: !inRoom) {
                    room.addConnected(r)
                    onAddToRoom()
                }
                .fixedSize()
            }
            let history = devices.history(key: r.id)
            if history.count >= 2 {
                Sparkline(samples: history, color: fw.tint(rssiColor(r.rssi ?? -80)), height: 48)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(fw.surface))
    }
}
