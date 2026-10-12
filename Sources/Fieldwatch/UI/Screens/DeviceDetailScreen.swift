import SwiftUI
import FieldwatchCore

// Port of ui/screen/DeviceDetailScreen.kt (+ ui/component/DetailStickyHeight.kt as a private helper).
// On the Mac this is the trailing inspector next to the Live list (~420 pt wide). The Kotlin back arrow is
// a close button; it still calls `onBack`. Snackbars are a small transient banner at the bottom.

struct DeviceDetailScreen: View {
    var device: Sighting
    var vm: FieldwatchViewModel
    var watched: Bool
    var onBack: () -> Void
    var onCreateFleet: () -> Void
    var onHunt: () -> Void
    var demoMode: Bool = false

    @Environment(\.fw) var fw

    // Kotlin `remember(device.key) { ... }` state. Reloaded whenever the key changes.
    @State var loadedKey: String = ""
    @State var nameDraft: String = ""
    @State var lastSaved: String = ""
    @State var editingName: Bool = false
    @State var notesDraft: String = ""
    @State var lastSavedNotes: String = ""
    @State var editingNotes: Bool = false
    @State var mineOn: Bool = false
    @State var banner: DetailBanner? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(fw.outline)
            ScrollView {
                content
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(fw.background)
        .overlay(alignment: .bottom) { bannerView }
        .onChange(of: device.key, initial: true) { loadDrafts() }
    }

    // MARK: Header (Kotlin TopAppBar)

    private var signatureNames: [String] { device.fleetIds.map { vm.fleetName(id: $0) } }

    private var headerTitle: String {
        let custom = lastSaved.isNotBlank ? lastSaved : (vm.watchLabelFor(deviceKey: device.key) ?? "")
        let title = custom.isNotBlank ? custom : device.listTitle(signatureNames: signatureNames)
        return MacUtil.redactMacIn(text: title, mac: device.mac, demo: demoMode)
    }

    private var header: some View {
        HStack(spacing: 8) {
            RadioKindMark(kind: device.kind, size: 13, tint: accent)
            Text(headerTitle)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(headerTitle)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button { vm.toggleWatchDevice(device: device) } label: {
                Image(systemName: watched ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 14))
                    .foregroundStyle(watched ? fw.primary : fw.onSurface)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(watched ? "Watching — alerts when this radio returns. Click to stop." : "Watch this radio (alert when it returns)")
            .accessibilityLabel("Watch")
            Button(action: onBack) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(fw.onSurfaceVariant)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close detail")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(fw.surface)
    }

    private var accent: Color {
        let base: Color = device.fleetIds.first.map { fleetColor(vm.fleetColor(id: $0)) } ?? rssiColor(device.rssi)
        return fw.tint(base)
    }

    // MARK: Body column

    @ViewBuilder private var content: some View {
        let facts = device.facts
        let canName = RadioBookmarks.canSetCustomName(device: device)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(MacUtil.screenMac(mac: device.mac, demo: demoMode))
                    .font(FW.mono(15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .textSelection(.enabled)
                DetailCopyButton(help: device.kind == .wifi ? "Copy BSSID" : "Copy identifier") {
                    vm.copyToClipboard(text: MacUtil.screenMac(mac: device.mac, demo: demoMode))
                }
            }
            if device.gone {
                Text("Not on the air. This is the last detail we heard.")
                    .font(.system(size: 12)).foregroundStyle(fw.onSurfaceVariant)
            }

            nameBlock(canName: canName)
            if canName || lastSavedNotes.isNotBlank {
                observerNotesCard(canName: canName)
            }
            if canName { mineCard }

            let guess = DeviceExplain.guess(device: device, signatureNames: signatureNames)
            DetailStickyHeight(latchKey: device.key + "/guess") { DetailGuessCard(guess: guess) }
            let attention = vm.attentionNotesFor(device: device)
            if attention.isNotEmpty {
                DetailStickyHeight(latchKey: device.key + "/attention") { DetailAttentionCard(notes: attention) }
            }
            let notes = vm.signatureNotesFor(device: device)
            if notes.isNotEmpty {
                DetailStickyHeight(latchKey: device.key + "/notes") { DetailSignatureNotesCard(notes: notes) }
            }

            DetailStickyHeight(latchKey: device.key + "/identity") { identitySection }
            DetailStickyHeight(latchKey: device.key + "/signal") { signalSection(facts) }
            if device.kind == .ble {
                DetailStickyHeight(latchKey: device.key + "/ble") { bleSection(facts) }
            }
            if device.kind == .wifi {
                DetailStickyHeight(latchKey: device.key + "/wifi") { wifiSection(facts) }
            }
            if device.serviceUuids.isNotEmpty || facts.serviceData.isNotEmpty {
                DetailStickyHeight(latchKey: device.key + "/services") { servicesSection(facts) }
            }
            if device.kind == .ble || device.kind == .wifi {
                payloadSection
                decodedSection
            }
            let mfg = mfgRecords(facts)
            if mfg.isNotEmpty {
                DetailStickyHeight(latchKey: device.key + "/mfg") { mfgSection(mfg) }
            }
            if facts.vendorIes.isNotEmpty || device.vendorIeOuis.isNotEmpty {
                DetailStickyHeight(latchKey: device.key + "/ies") { vendorIeSection(facts) }
            }
            DetailStickyHeight(latchKey: device.key + "/session") { sessionSection }

            trendBlock
            actionsBlock
        }
    }

    // MARK: Custom name

    @ViewBuilder private func nameBlock(canName: Bool) -> some View {
        let draftLabel = RadioBookmarks.clip(name: nameDraft)
        let nameIsSaved = lastSaved.isNotBlank && draftLabel == lastSaved
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                if lastSaved.isNotBlank {
                    DetailMetaLabel("Custom name")
                    Text(lastSaved).font(.system(size: 19)).textSelection(.enabled)
                    DetailMetaLabel("Advertised").padding(.top, 6)
                    Text(device.name.ifBlank("No advertised name"))
                        .font(.system(size: 12)).foregroundStyle(fw.onSurfaceVariant)
                        .textSelection(.enabled)
                } else if device.name.isNotBlank {
                    DetailMetaLabel("Advertised name")
                    Text(device.name).font(.system(size: 13)).textSelection(.enabled)
                } else {
                    DetailMetaLabel("Name")
                    Text("No advertised name").font(.system(size: 13)).foregroundStyle(fw.onSurfaceVariant)
                }
            }
            Spacer(minLength: 0)
            let copyName = lastSaved.isNotBlank ? lastSaved : device.name
            if copyName.isNotBlank {
                DetailCopyButton(help: "Copy name") { vm.copyToClipboard(text: copyName) }
            }
            if canName {
                Button { editingName.toggle() } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 14))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(editingName ? fw.primary : fw.onSurface)
                .help(editingName ? "Hide custom name" : "Custom name")
            }
        }
        if editingName && canName {
            FieldwatchOutlinedField(
                label: "Custom name",
                text: Binding(get: { nameDraft }, set: { nameDraft = $0.take(RadioBookmarks.MAX_NAME) }),
                supportingText: RadioBookmarks.customNameHint(device: device)
            )
            .onSubmit { if nameDraft.isNotBlank && !nameIsSaved { saveName() } }
            FieldwatchActionButton(enabled: nameDraft.isNotBlank && !nameIsSaved, action: saveName) {
                Spacer(minLength: 0)
                if nameIsSaved {
                    Image(systemName: "checkmark")
                    Text("Saved")
                } else {
                    Text("Save name")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func saveName() {
        let draftLabel = RadioBookmarks.clip(name: nameDraft)
        vm.saveRadioName(device: device, name: nameDraft)
        nameDraft = draftLabel
        lastSaved = draftLabel
        showBanner("Saved as \(draftLabel)")
    }

    // MARK: Observer notes

    @ViewBuilder private func observerNotesCard(canName: Bool) -> some View {
        let draftNotes = RadioBookmarks.clipNotes(text: notesDraft)
        let notesIsSaved = draftNotes == lastSavedNotes
        DetailObserverNotesCard(
            notes: lastSavedNotes,
            canEdit: canName,
            editing: editingNotes && canName,
            draft: Binding(get: { notesDraft }, set: { notesDraft = $0.take(RadioBookmarks.MAX_NOTES) }),
            onToggleEdit: { editingNotes.toggle() },
            onSave: saveNotes,
            saveEnabled: !notesIsSaved,
            saved: notesIsSaved && lastSavedNotes.isNotBlank
        )
    }

    private func saveNotes() {
        let draftNotes = RadioBookmarks.clipNotes(text: notesDraft)
        vm.saveRadioNotes(device: device, notes: notesDraft)
        notesDraft = draftNotes
        lastSavedNotes = draftNotes
        if lastSaved.isBlank && draftNotes.isNotBlank {
            let suggest = RadioBookmarks.suggestLabel(device: device, signatureNames: signatureNames)
            lastSaved = suggest
            nameDraft = suggest
        }
        editingNotes = false
        showBanner(draftNotes.isBlank ? "Observer notes cleared" : "Observer notes saved")
    }

    // MARK: Mine

    private var mineCard: some View {
        FieldwatchSwitch(
            "Mine",
            subtitle: "While on, this radio stays listed and does not beep.",
            checked: mineOn,
            onChange: { on in
                vm.setRadioMine(device: device, on: on)
                mineOn = on
                if on && lastSaved.isBlank {
                    let suggest = RadioBookmarks.suggestLabel(device: device, signatureNames: signatureNames)
                    lastSaved = suggest
                    nameDraft = suggest
                }
                if on { showBanner("Marked as yours. No beep while this is on. Still listed.") }
            }
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(fw.sectionFill))
    }

    // MARK: Sections

    @ViewBuilder private var identitySection: some View {
        DetailSection("Identity")
        DetailMeta(
            label: "Radio",
            value: device.kind == .wifi ? "Wi-Fi access point (beaconing a network)" : "Bluetooth Low Energy advertiser"
        )
        DetailMeta(label: "Address", value: DeviceExplain.addressExplain(device: device))
        if let vendor = detailVendorLine(device) {
            DetailMeta(label: "Who made it", value: vendor)
        } else if MacUtil.isOpaqueId(device.mac) {
            DetailMeta(label: "OUI (vendor prefix)", value: "None — macOS hides Bluetooth addresses, so there is no prefix to look up")
        } else {
            DetailMeta(label: "OUI (vendor prefix)", value: "\(device.oui) — no IEEE match; randomized addresses usually have none")
        }
        if device.hiddenSsid {
            DetailMeta(label: "Network name (SSID)", value: "Hidden — the AP is beaconing but not publishing a name")
        }
    }

    @ViewBuilder private func signalSection(_ facts: RadioFacts) -> some View {
        DetailSection("Signal")
        if device.gone {
            DetailMeta(label: "How loud here (RSSI)", value: "Not available")
            let lastDbm = Rssi.lastMeasured(rssi: device.rssi, history: device.rssiHistory).map { " at \($0) dBm" } ?? ""
            DetailMeta(label: "Last heard", value: formatMs(device.lastSeen, "HH:mm:ss") + lastDbm)
        } else {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                DetailMeta(label: "How loud here (RSSI)", value: DeviceExplain.rssiExplain(rssi: device.rssi))
                TrendMark(trend: device.rssiTrend())
                    .help("Recent trend: > louder, < quieter, = steady")
            }
            Text("Closer to 0 dBm is louder here, not a distance.")
                .font(.system(size: 12)).foregroundStyle(fw.onSurfaceVariant)
        }
        DetailMeta(
            label: "Heard range this session",
            value: Rssi.sessionRange(min: device.rssiMin, max: device.rssiMax, history: device.rssiHistory)
        )
        if let tx = facts.txPowerDbm {
            DetailMeta(label: "Claimed transmit power", value: "\(tx) dBm — how loud it says it transmits, not a distance")
        }
        if device.channel != 0 || device.frequencyMhz != 0 {
            DetailMeta(label: "Channel / frequency", value: channelLine(facts))
        }
        if let std = facts.wifiStandard { DetailMeta(label: "Wi-Fi generation", value: std) }
        if facts.centerFreq0 != nil || facts.centerFreq1 != nil {
            DetailMeta(
                label: "Center frequencies",
                value: [facts.centerFreq0, facts.centerFreq1].compactMap { $0.map { "\($0) MHz" } }.joined(separator: "  ·  ")
            )
        }
    }

    private func channelLine(_ facts: RadioFacts) -> String {
        var s = ""
        if device.channel != 0 { s += "channel \(device.channel)" }
        if device.frequencyMhz != 0 {
            if s.isNotEmpty { s += "  ·  " }
            s += "\(device.frequencyMhz) MHz"
        }
        if let w = facts.channelWidth { s += "  ·  \(w) wide" }
        return s
    }

    @ViewBuilder private func bleSection(_ facts: RadioFacts) -> some View {
        DetailSection("Bluetooth advertisement")
        if let primary = facts.primaryPhy {
            let phys = [primary, facts.secondaryPhy].compactMap { $0 }.distinct()
            DetailMeta(label: "Radio PHY", value: phys.map { DeviceExplain.phyExplain(label: $0) }.joined(separator: " / "))
        }
        if let c = facts.connectable {
            DetailMeta(
                label: "Connectable",
                value: c ? "Yes — a phone or Mac could open a BLE connection"
                    : "No — broadcast-only (you can hear it, not join it from this scan)"
            )
        }
        if let iv = facts.advertisingIntervalMs {
            DetailMeta(label: "How often it advertises", value: "\(fmt(iv, 0)) ms between bursts (smaller = chattier on the air)")
        }
        if let p = facts.periodicIntervalMs {
            DetailMeta(label: "Periodic advertising", value: "\(fmt(p, 0)) ms")
        }
        if let flags = facts.advFlags {
            DetailMeta(label: "Discoverability", value: DeviceExplain.flagsExplain(flags: flags))
            DetailMeta(label: "Flags (raw)", value: "0x" + hex2(flags), mono: true)
        }
        if let value = facts.appearance {
            let name = RadioDb.appearance(value: value)
            DetailMeta(
                label: "What it says it is (Appearance)",
                value: name.map { "\($0)\nThe device publishes this GAP Appearance code to describe itself." }
                    ?? "Unlisted Appearance 0x\(hexN(value, 4))"
            )
            DetailMeta(label: "Appearance code", value: "0x" + hexN(value, 4), mono: true)
        }
        if let cod = CodDecoder.decodeOrNull(cod: facts.deviceClass) {
            DetailMeta(label: "Classic Bluetooth class", value: codLine(cod))
        }
    }

    private func codLine(_ cod: CodDecoder.Decoded) -> String {
        var s = cod.major
        if cod.minor.isNotBlank { s += " / " + cod.minor }
        s += "\nThis is the Class of Device bitfield used by classic Bluetooth."
        if cod.services.isNotEmpty { s += "\nAlso offers: " + cod.services.joined(separator: ", ") }
        return s
    }

    @ViewBuilder private func wifiSection(_ facts: RadioFacts) -> some View {
        DetailSection("Wi-Fi access point")
        if let sec = facts.security {
            DetailMeta(label: "Encryption / login", value: DeviceExplain.wifiSecurityExplain(raw: sec))
            if sec.isNotBlank { DetailMeta(label: "Security string", value: sec, mono: true) }
        }
        if let rates = facts.supportedRates {
            DetailMeta(label: "Supported rates", value: "\(rates) Mbps  (* = required basic rate)")
        }
        if let caps = facts.capabilities, caps.isNotBlank, caps != facts.security {
            DetailMeta(label: "Capability string", value: caps, mono: true)
        }
    }

    @ViewBuilder private func servicesSection(_ facts: RadioFacts) -> some View {
        if device.serviceUuids.isNotEmpty {
            DetailSection("Services it offers")
            DetailMeta(
                label: "Service IDs",
                value: device.serviceUuids.map { uuid in
                    DeviceExplain.uuidGloss(uuid: uuid).map { "\(uuid)  ·  \($0)" } ?? uuid
                }.joined(separator: "\n"),
                mono: true
            )
        }
        ForEach(Array(facts.serviceData.enumerated()), id: \.offset) { _, sd in
            ForEach(Array(AdvPayloadDecoder.decodeService(record: sd).enumerated()), id: \.offset) { _, field in
                DetailMeta(label: field.label, value: field.value)
            }
            DetailMeta(label: detailServiceDataHeading(sd), value: sd.dataHex.hexSpaced().ifBlank("(empty)"), mono: true,
                 copy: sd.dataHex.isNotBlank ? sd.dataHex : nil, onCopy: copy)
        }
    }

    /// Advertised position (Remote ID or any decode map with LAT / LON). Not the Mac's own location.
    @ViewBuilder private var payloadSection: some View {
        let aircraft = (device.payloadAircraft ?? "").trim()
        if aircraft.isNotEmpty { DetailMeta(label: "Aircraft", value: aircraft) }
        let loc = PayloadLocation.fromSighting(device: device)
        if let pin = loc.pin() {
            let coord = Geo.screenCoord(lat: pin.0, lon: pin.1, demo: demoMode) ?? ""
            let alt = loc.alt.map { "  ·  \(fmt($0, 0)) m" } ?? ""
            DetailMeta(
                label: "Advertised position",
                value: coord + alt + "\nFrom the radio's own payload, not this Mac's location."
            )
        }
        if PayloadLocation.validCoord(lat: loc.opLat, lon: loc.opLon),
           let op = Geo.screenCoord(lat: loc.opLat, lon: loc.opLon, demo: demoMode) {
            DetailMeta(label: "Pilot / operator position", value: op)
        }
        let motion = [
            loc.headingDeg.map { "heading \(fmt($0, 0))°" },
            loc.speedMps.map { "\(fmt($0, 1)) m/s" },
            loc.vspeedMps.map { "climb \(fmt($0, 1)) m/s" },
        ].compactMap { $0 }
        if loc.pin() != nil && motion.isNotEmpty {
            DetailMeta(label: "Advertised motion", value: motion.joined(separator: "  ·  "))
        }
    }

    @ViewBuilder private var decodedSection: some View {
        let fleets = vm.ui.fleets
        let decoded = SignatureFieldDecoder.decodeSighting(device: device, fleets: fleets)
        let mapped = device.fleetIds.compactMap { id in fleets.first { $0.id == id && $0.decode != nil } }
        let hasPayload = device.facts.mfgRecords.isNotEmpty || device.manufacturerDataHex.isNotBlank
            || device.facts.serviceData.isNotEmpty
        if decoded.isNotEmpty {
            HStack(spacing: 6) {
                DecodeGlyph(tint: fw.primary, size: 16)
                Text("Decoded fields").font(.system(size: 13, weight: .semibold)).foregroundStyle(fw.primary)
            }
            .padding(.top, 6)
            let multi = decoded.map { $0.fleetId }.distinct().count > 1
            ForEach(Array(decoded.enumerated()), id: \.offset) { _, row in
                DetailMeta(label: multi ? "\(row.fleetName) · \(row.label)" : row.label, value: row.display)
                if row.note.isNotBlank {
                    Text(row.note).font(.system(size: 12)).foregroundStyle(fw.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if mapped.isNotEmpty {
            let govee = mapped.contains { $0.id == "fleet-govee" }
            Text(decodeMissText(hasPayload: hasPayload, govee: govee))
                .font(.system(size: 12)).foregroundStyle(fw.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func decodeMissText(hasPayload: Bool, govee: Bool) -> String {
        switch (hasPayload, govee) {
        case (true, true):
            return "Decode fields did not apply to this advertisement (short payload, a different company ID, or a different layout). Govee lights usually only send a name; hygrometers are H5074/H5075/H510x. Raw bytes are below."
        case (true, false):
            return "Decode fields did not apply to this advertisement (short payload, a different company ID, or a different layout). Raw bytes are below."
        case (false, true):
            return "This signature has a decode map, but this advertisement has no manufacturer or service payload to parse. Many Govee lights only broadcast a name."
        case (false, false):
            return "This signature has a decode map, but this advertisement has no manufacturer or service payload to parse."
        }
    }

    private func mfgRecords(_ facts: RadioFacts) -> [MfgRecord] {
        if facts.mfgRecords.isNotEmpty { return facts.mfgRecords }
        if let id = device.manufacturerId { return [MfgRecord(companyId: id, dataHex: device.manufacturerDataHex)] }
        return []
    }

    @ViewBuilder private func mfgSection(_ mfg: [MfgRecord]) -> some View {
        DetailSection("Maker data inside the ad")
        ForEach(Array(mfg.enumerated()), id: \.offset) { _, rec in
            let company = RadioDb.company(id: rec.companyId) ?? "Not in the Bluetooth company list"
            DetailMeta(
                label: "Bluetooth company 0x\(hexN(rec.companyId, 4))",
                value: "\(company)\nThis ID is assigned by the Bluetooth SIG and is carried in manufacturer-specific data."
            )
            ForEach(Array(BleAdParser.mfgDecodedFields(record: rec).enumerated()), id: \.offset) { _, kv in
                DetailMeta(label: kv.0, value: kv.1)
            }
            if rec.dataHex.isNotBlank {
                DetailMeta(label: "Raw payload (\(rec.dataHex.count / 2) bytes)", value: rec.dataHex.hexSpaced(), mono: true,
                     copy: rec.dataHex, onCopy: copy)
            }
        }
    }

    @ViewBuilder private func vendorIeSection(_ facts: RadioFacts) -> some View {
        DetailSection("Wi-Fi vendor tags")
        let rows = facts.vendorIes.isNotEmpty ? facts.vendorIes
            : device.vendorIeOuis.map { VendorIeRecord(oui: $0, type: -1, dataHex: "") }
        ForEach(Array(rows.enumerated()), id: \.offset) { _, ie in
            let org = RadioDb.vendorForOui24(oui: ie.oui)
            let type = ie.type >= 0 ? " type \(ie.type)" : ""
            DetailMeta(
                label: "Vendor OUI \(ie.oui)\(type)",
                value: (org ?? "Unknown IEEE OUI") + " — extra AP information element, not the SSID."
                    + (ie.dataHex.isNotBlank ? "\n" + ie.dataHex.hexSpaced() : "")
            )
        }
    }

    @ViewBuilder private var sessionSection: some View {
        DetailSection("Session")
        DetailMeta(label: "First seen", value: formatMs(device.firstSeen, "HH:mm:ss"))
        DetailMeta(label: "Last seen", value: formatMs(device.lastSeen, "HH:mm:ss"))
        DetailMeta(label: "Hits", value: "\(device.hitCount)")
        if let fix = Geo.screenCoord(lat: device.latitude, lon: device.longitude, demo: demoMode) {
            DetailMeta(label: "Last fix", value: fix)
        }
        if device.fleetIds.isNotEmpty {
            DetailMeta(
                label: "Matched signatures",
                value: device.fleetIds.map { id in
                    let name = vm.fleetName(id: id)
                    return vm.fleetHasDecode(id: id) ? "\(name)  ⬡" : name
                }.joined(separator: "\n")
            )
        }
        if device.rawHex.isNotBlank && device.kind == .ble {
            DetailMeta(label: "Raw advertisement", value: device.rawHex.hexSpaced(), mono: true, copy: device.rawHex, onCopy: copy)
        }
    }

    // MARK: Trend, presence, actions

    @ViewBuilder private var trendBlock: some View {
        HStack(spacing: 8) {
            Text("Signal trend").font(.system(size: 13, weight: .semibold))
            TrendMark(trend: device.rssiTrend())
        }
        Sparkline(samples: device.rssiHistory, color: accent, height: 56)
        Text("Presence (15 min)").font(.system(size: 13, weight: .semibold))
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            PresenceTrack(
                device: device,
                now: Int(ctx.date.timeIntervalSince1970 * 1000),
                windowMs: 15 * 60 * 1000,
                color: accent
            )
        }
    }

    @ViewBuilder private var actionsBlock: some View {
        if device.kind == .ble {
            DetailWideButton(title: "Hunt", systemImage: "location.north.line", action: onHunt)
        } else {
            Text("Hunt is BLE only. Wi-Fi access points update too slowly on macOS to walk toward.")
                .font(.system(size: 12)).foregroundStyle(fw.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let hint = vm.familyHint {
            DetailStickyHeight(latchKey: device.key + "/family") { DetailFamilyCard(hint: hint) }
        }
        DetailWideButton(title: "Create signature from device", systemImage: "person.2.badge.plus", action: onCreateFleet)
        DetailWideButton(title: "Share as text", systemImage: "square.and.arrow.up") {
            vm.startDeviceDetailShare(device: device)
        }
        DetailWideButton(title: "AI Export", systemImage: "sparkles") {
            vm.startDeviceDetailAiExport(device: device)
        }
        Text("Opens a paste-ready prompt for a chat: decode this radio, look up OUI/company/UUIDs, and say what it most likely is. Same experimental disclaimer as Settings → AI Export. One device only — not identity.")
            .font(.system(size: 12)).foregroundStyle(fw.onSurfaceVariant)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: State helpers

    private func loadDrafts() {
        guard loadedKey != device.key else { return }
        loadedKey = device.key
        let label = vm.watchLabelFor(deviceKey: device.key) ?? ""
        nameDraft = label
        lastSaved = label
        editingName = false
        let notes = vm.watchObserverNoteFor(deviceKey: device.key) ?? ""
        notesDraft = notes
        lastSavedNotes = notes
        editingNotes = false
        mineOn = vm.isMine(deviceKey: device.key)
    }

    private func copy(_ text: String) { vm.copyToClipboard(text: text); showBanner("Copied") }

    private func showBanner(_ text: String) { banner = DetailBanner(text: text) }

    @ViewBuilder private var bannerView: some View {
        if let banner {
            Text(banner.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(fw.onSurface)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(fw.surfaceVariant))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(fw.outline, lineWidth: 1))
                .padding(.bottom, 12)
                .padding(.horizontal, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: banner.id) {
                    try? await Task.sleep(nanoseconds: 2_600_000_000)
                    if self.banner?.id == banner.id { withAnimation { self.banner = nil } }
                }
        }
    }
}

struct DetailBanner: Identifiable, Equatable {
    let id = UUID()
    var text: String
}

// MARK: - Private building blocks

/// Kotlin DetailStickyHeight: keeps the tallest height a block has reached for this key, so a shorter frame
/// (or a shorter guess) does not yank Hunt and the share buttons. Resets on a new key or a width change.
private struct DetailStickyHeight<Content: View>: View {
    var latchKey: String
    @ViewBuilder var content: () -> Content
    @State private var minHeight: CGFloat = 0
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { g in Color.clear.preference(key: DetailStickySizeKey.self, value: g.size) }
            )
            .onPreferenceChange(DetailStickySizeKey.self) { size in
                if abs(size.width - width) > 0.5 {
                    width = size.width
                    minHeight = size.height
                } else if size.height > minHeight {
                    minHeight = size.height
                }
            }
            .frame(minHeight: minHeight, alignment: .top)
            .onChange(of: latchKey) { minHeight = 0 }
    }
}

private struct DetailStickySizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct DetailMetaLabel: View {
    @Environment(\.fw) var fw
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant)
    }
}

private struct DetailSection: View {
    @Environment(\.fw) var fw
    var title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(fw.primary)
            .padding(.top, 6)
    }
}

/// Label over value. Values are selectable; raw hex rows get a copy button.
private struct DetailMeta: View {
    @Environment(\.fw) var fw
    var label: String
    var value: String
    var mono: Bool = false
    var copy: String? = nil
    var onCopy: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                DetailMetaLabel(label)
                if let copy, let onCopy {
                    DetailCopyButton(help: "Copy hex") { onCopy(copy) }
                }
            }
            Text(value)
                .font(mono ? FW.mono(12.5, weight: .regular) : .system(size: 13))
                .foregroundStyle(fw.onSurface)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetailCopyButton: View {
    @Environment(\.fw) var fw
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(fw.onSurfaceVariant)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct DetailWideButton: View {
    var title: String
    var systemImage: String
    var action: () -> Void

    var body: some View {
        FieldwatchActionButton(action: action) {
            Spacer(minLength: 0)
            Image(systemName: systemImage)
            Text(title)
            Spacer(minLength: 0)
        }
    }
}

private struct DetailGuessCard: View {
    @Environment(\.fw) var fw
    var guess: DeviceExplain.Guess

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DetailMetaLabel("What this looks like")
            Text(guess.headline).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
            Text(guess.because).font(.system(size: 12)).foregroundStyle(fw.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(fw.surfaceVariant.opacity(0.55)))
    }
}

private struct DetailAttentionCard: View {
    @Environment(\.fw) var fw
    var notes: [(String, String)]

    var body: some View {
        let warn = fw.tint(FW.amber)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(warn)
                Text("Extra attention").font(.system(size: 13, weight: .semibold)).foregroundStyle(warn)
            }
            ForEach(Array(notes.enumerated()), id: \.offset) { _, n in
                Text(n.0).font(.system(size: 15, weight: .semibold)).foregroundStyle(fw.onSurface)
                Text(n.1).font(.system(size: 13)).foregroundStyle(fw.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text("Pattern match, not identity. Not a safety finding.")
                .font(.system(size: 12)).foregroundStyle(fw.onSurfaceVariant)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(warn.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(warn, lineWidth: 1.5))
    }
}

private struct DetailSignatureNotesCard: View {
    @Environment(\.fw) var fw
    var notes: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailMetaLabel("Notes")
            ForEach(Array(notes.enumerated()), id: \.offset) { _, n in
                Text(n.0).font(.system(size: 15, weight: .semibold))
                Text(n.1).font(.system(size: 13)).foregroundStyle(fw.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(fw.surfaceVariant.opacity(0.55)))
    }
}

private struct DetailObserverNotesCard: View {
    @Environment(\.fw) var fw
    var notes: String
    var canEdit: Bool
    var editing: Bool
    @Binding var draft: String
    var onToggleEdit: () -> Void
    var onSave: () -> Void
    var saveEnabled: Bool
    var saved: Bool

    var body: some View {
        let ink = fw.tint(FW.cyan)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Observer notes").font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
                Spacer()
                if canEdit {
                    Button(action: onToggleEdit) {
                        Image(systemName: "pencil")
                            .font(.system(size: 14))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(editing ? ink : fw.onSurface)
                    .help(editing ? "Hide observer notes" : "Observer notes")
                }
            }
            if !editing {
                if notes.isNotBlank {
                    Text(notes).font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    Text("No observer notes").font(.system(size: 12)).foregroundStyle(fw.onSurfaceVariant)
                }
            } else {
                FieldwatchOutlinedField(
                    label: "Observer notes",
                    text: $draft,
                    supportingText: "\(draft.trim().count)/\(RadioBookmarks.MAX_NOTES). \(RadioBookmarks.observerNotesHint())",
                    singleLine: false,
                    minLines: 3
                )
                FieldwatchActionButton(enabled: saveEnabled, action: onSave) {
                    Spacer(minLength: 0)
                    if saved {
                        Image(systemName: "checkmark")
                        Text("Saved")
                    } else {
                        Text("Save notes")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(ink.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ink, lineWidth: 1.5))
    }
}

private struct DetailFamilyCard: View {
    @Environment(\.fw) var fw
    var hint: SignatureFamilyHint

    var body: some View {
        let container: Color = {
            switch hint.verdict {
            case .strong: return fw.primaryContainer
            case .possible: return fw.tint(FW.amber).opacity(0.22)
            case .single, .tagged: return fw.surfaceVariant.opacity(0.55)
            }
        }()
        let onContainer = hint.verdict == .strong ? fw.onPrimaryContainer : fw.onSurface
        let muted = onContainer.opacity(0.78)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Signature family").font(.system(size: 11)).foregroundStyle(muted)
                    Text(hint.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(onContainer)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if hint.displayCount > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(hint.displayCount)").font(FW.mono(15, weight: .bold)).foregroundStyle(onContainer)
                        RadioKindMark(kind: hint.radioKind, size: 13)
                    }
                }
            }
            if let rule = hint.ruleLabel {
                Text(rule).font(FW.mono(13, weight: .regular)).foregroundStyle(fw.primary)
                    .padding(.top, 2)
                    .textSelection(.enabled)
            }
            Text(hint.body).font(.system(size: 12)).foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(container))
    }
}

// MARK: - Text helpers (private funcs at the bottom of the Kotlin file)

private func detailVendorLine(_ device: Sighting) -> String? {
    var parts: [String] = []
    if let v = device.vendor {
        parts.append("IEEE board/chip vendor: \(v) (\(device.oui)). This is who owns the MAC prefix, not always the product brand.")
    }
    if let mfgId = device.facts.mfgRecords.first?.companyId ?? device.manufacturerId {
        let company = RadioDb.company(id: mfgId)
        parts.append("Bluetooth company in the ad: \(company ?? "unlisted") (0x\(hexN(mfgId, 4))).")
    }
    let s = parts.joined(separator: "\n")
    return s.isBlank ? nil : s
}

private func detailUuidShort(_ uuid: String) -> String {
    let hex = uuid.filterAlnum().uppercased()
    return hex.count >= 8 && hex.hasPrefix("0000") ? hex.substring(4, 8) : uuid.take(8)
}

private func detailServiceDataHeading(_ sd: ServiceDataRecord) -> String {
    let named = RadioDb.serviceUuid(uuid: sd.uuid).map { " (\($0))" } ?? ""
    let frame = detailEddystoneFrameTag(sd).map { " · \($0)" } ?? ""
    return "Service data \(detailUuidShort(sd.uuid))\(named)\(frame)"
}

private func detailEddystoneFrameTag(_ sd: ServiceDataRecord) -> String? {
    let hex = sd.uuid.filterAlnum().uppercased()
    let short: String
    if hex.count == 4 {
        short = hex
    } else if hex.count >= 8 && hex.hasPrefix("0000") {
        short = hex.substring(4, 8)
    } else {
        return nil
    }
    if short != "FEAA" { return nil }
    switch sd.dataHex.filterAlnum().uppercased().take(2) {
    case "00": return "UID"
    case "10": return "URL"
    case "20": return "TLM"
    case "30": return "EID"
    default: return nil
    }
}
