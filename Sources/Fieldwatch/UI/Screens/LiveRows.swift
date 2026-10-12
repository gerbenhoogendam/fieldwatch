import SwiftUI
import AppKit
import FieldwatchCore

// Port of the row views in ui/screen/LiveScreens.kt: RankedList (Strength list / Hybrid), DeviceRow,
// FleetNameChips, RadioKindSubtitle and TimelineView (here `PresenceTimelineView`, so SwiftUI's TimelineView
// is not shadowed). macOS additions: hover highlight, selected-row outline, context menu.

// MARK: - Strength list / Hybrid

private struct ListEdge: Equatable {
    var first: String?
    var last: String?
    var count: Int
}

private struct RowLayoutKey: Equatable {
    var showBar: Bool
    var showFleet: Bool
    var showFrequency: Bool
    var showSeenTimes: Bool
    var layoutEpoch: Bool
    var count: Int
}

/// Kotlin `RankedList`. Display settings come in one `LiveRowOptions` bundle instead of a dozen parameters.
struct RankedList: View {
    @Environment(\.fw) var fw
    var devices: [Sighting]
    var vm: FieldwatchViewModel
    var onOpen: (Sighting) -> Void
    var sparklines: Bool = false
    var compact: Bool = false
    var pinEnd: Bool = false
    var layoutEpoch: Bool = true
    var emptyHint: String? = nil
    var rows: LiveRowOptions
    @State var now: Int = nowMs()
    /// First row at the top edge (scrollPosition). Keeps a scrolled-away list anchored on its row.
    @State var anchorKey: String? = nil
    @State var stickToEnd = true

    static let topId = "live-list-top"
    static let endId = "live-list-end"

    private var atTop: Bool { anchorKey == nil || anchorKey == Self.topId || anchorKey == devices.first?.key }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 1).id(Self.topId)
                    if devices.isEmpty {
                        Text(emptyHint ?? LIVE_LIST_EMPTY)
                            .font(.system(size: 13))
                            .foregroundStyle(fw.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(24)
                    }
                    ForEach(devices) { device in
                        DeviceRow(
                            device: device, vm: vm, sparklines: sparklines, compact: compact, onOpen: onOpen,
                            sort: rows.sort, windowMs: rows.windowMs, showBar: rows.showBar,
                            showNewAge: rows.showNewAge, showFleet: rows.showFleet,
                            showFrequency: rows.showFrequency, showSeenTimes: rows.showSeenTimes, now: now,
                            highlighted: rows.flashKeys.contains(device.key),
                            titleLine: rows.titleLine, subtitleLine: rows.subtitleLine, demoMode: rows.demoMode,
                            alerted: rows.alertedKeys.contains(device.key),
                            lookup: rows.lookup, selected: rows.selectedKey == device.key, onHunt: rows.onHunt
                        )
                        .padding(.vertical, 3)
                    }
                    Color.clear.frame(height: 1).id(Self.endId)
                        .onAppear { stickToEnd = true }
                        .onDisappear { stickToEnd = false }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            .scrollPosition(id: $anchorKey, anchor: .top)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    now = nowMs()
                }
            }
            .onChange(of: pinEnd) { _, pin in
                if pin {
                    stickToEnd = true
                    proxy.scrollTo(Self.endId, anchor: .bottom)
                } else {
                    proxy.scrollTo(Self.topId, anchor: .top)
                }
            }
            .onChange(of: ListEdge(first: devices.first?.key, last: devices.last?.key, count: devices.count)) { old, _ in
                if devices.isEmpty { return }
                if pinEnd {
                    if stickToEnd { proxy.scrollTo(Self.endId, anchor: .bottom) }
                } else if anchorKey == nil || anchorKey == Self.topId || anchorKey == old.first {
                    // At the top: new stronger rows push in above, the list stays at the top.
                    proxy.scrollTo(Self.topId, anchor: .top)
                }
            }
            .onChange(of: RowLayoutKey(showBar: rows.showBar, showFleet: rows.showFleet, showFrequency: rows.showFrequency,
                                       showSeenTimes: rows.showSeenTimes, layoutEpoch: layoutEpoch, count: devices.count)) {
                if devices.isEmpty { return }
                if pinEnd {
                    if stickToEnd { proxy.scrollTo(Self.endId, anchor: .bottom) }
                } else if atTop {
                    proxy.scrollTo(Self.topId, anchor: .top)
                }
            }
            .onChange(of: vm.liveFocus) { _, focus in
                guard focus > 0 else { return }
                if devices.isNotEmpty {
                    withAnimation(.linear(duration: 0.14)) { proxy.scrollTo(Self.topId, anchor: .top) }
                }
                stickToEnd = false
            }
            .onChange(of: vm.beepSnap.seq) {
                let snap = vm.beepSnap
                guard snap.seq > 0, snap.key.isNotBlank, devices.contains(where: { $0.key == snap.key }) else { return }
                stickToEnd = false
                proxy.scrollTo(snap.key, anchor: .top)
            }
        }
    }
}

// MARK: - Device row

/// Kotlin `DeviceRow`. Parameters in Kotlin order; `lookup`, `selected` and `onHunt` are macOS additions
/// (nil lookup = answer through the view model).
struct DeviceRow: View {
    @Environment(\.fw) var fw
    var device: Sighting
    var vm: FieldwatchViewModel
    var sparklines: Bool
    var compact: Bool
    var onOpen: (Sighting) -> Void
    var sort: StrengthSort = .average
    var windowMs: Int = 30_000
    var showBar: Bool = true
    var showNewAge: Bool = false
    var showFleet: Bool = true
    var showFrequency: Bool = false
    var showSeenTimes: Bool = false
    var now: Int = nowMs()
    var highlighted: Bool = false
    var titleLine: ListLine = .mac
    var subtitleLine: ListLine = .nameAndType
    var demoMode: Bool = false
    var alerted: Bool = false
    var lookup: LiveLookup? = nil
    var selected: Bool = false
    var onHunt: ((Sighting) -> Void)? = nil

    var body: some View {
        let lk = lookup ?? LiveLookup(vm: vm)
        // heardRssi and sortRssi are the same value in Core; computed once.
        let rankRssi = Int(device.sortRssi(sort: sort, windowMs: windowMs, now: now))
        let heardRssi = rankRssi
        let accent = fw.tint(device.fleetIds.first.map { lk.fleetPaletteColor($0) } ?? rssiColor(heardRssi))
        let named = showFleet && device.fleetIds.isNotEmpty
        let roomy = showBar || sparklines || showSeenTimes
        let names = lk.names(device)
        let watch = lk.watchLabelFor(device.key)
        let title = liveRowTitle(device: device, titleLine: titleLine, subtitleLine: subtitleLine,
                                 names: names, watch: watch, demoMode: demoMode)
        let attention = lk.hasAttention(device)
        let observed = lk.hasObserverNote(device)
        let mine = lk.isMine(device.key)
        let aircraft = device.payloadAircraft?.trim() ?? ""
        let showChips = attention || observed || named || alerted || mine || device.liveDecode.isNotEmpty || aircraft.isNotEmpty

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                RadioClassBadge(classKind: device.fleetIds.first.flatMap { lk.fleetKind($0) }, accent: accent, compact: compact)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if showChips {
                        FleetNameChips(device: device, lookup: lk, attention: attention, showNames: named,
                                       alerted: alerted, observed: observed, mine: mine)
                    }
                    if subtitleLine != ListLine.none {
                        RadioKindSubtitle(kind: device.kind,
                                          text: liveListSubtitle(device: device, subtitleLine: subtitleLine, names: names,
                                                                 demoMode: demoMode, watchName: watch))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 4) {
                        TrendMark(trend: device.rssiTrend())
                        Text("\(device.rssi)")
                            .font(FW.mono(14, weight: .bold))
                            .foregroundStyle(accent)
                    }
                    if showFrequency, let fact = liveRadioFactLine(device: device) {
                        Text(fact).font(FW.mono(10, weight: .regular)).foregroundStyle(fw.onSurfaceVariant)
                    }
                    if showNewAge {
                        let ageSec = ((now - device.firstSeen) / 1000).coerceAtLeast(0)
                        Text(ageSec < 60 ? "new \(ageSec)s" : "new \(ageSec / 60)m")
                            .font(FW.mono(10, weight: .regular))
                            .foregroundStyle(fw.primary)
                    } else if sort == .average {
                        Text("avg \(rankRssi)")
                            .font(FW.mono(10, weight: .regular))
                            .foregroundStyle(fw.onSurfaceVariant)
                    }
                }
                .fixedSize()
            }
            if !compact && showBar {
                LiveRssiBar(rssi: heardRssi, color: accent).padding(.top, 5)
            }
            if !compact && sparklines {
                Sparkline(samples: device.rssiHistory, color: accent).padding(.top, 6)
            }
            if showSeenTimes {
                Text(liveSeenTimesLabel(device: device, now: now))
                    .font(FW.mono(10, weight: .regular))
                    .foregroundStyle(fw.onSurfaceVariant)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, roomy ? 7 : 5)
        .modifier(LiveRowChrome(
            device: device, vm: vm, lookup: lk, radius: roomy ? 12 : 8, fill: fw.sectionFill,
            highlighted: highlighted, selected: selected, onOpen: onOpen, onHunt: onHunt
        ))
    }
}

/// Card background, alert flash, hover, selection outline, click → open, context menu.
struct LiveRowChrome: ViewModifier {
    @Environment(\.fw) var fw
    var device: Sighting
    var vm: FieldwatchViewModel
    var lookup: LiveLookup
    var radius: CGFloat
    var fill: Color
    var highlighted: Bool
    var selected: Bool
    var onOpen: (Sighting) -> Void
    var onHunt: ((Sighting) -> Void)?
    @State var hovered = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(highlighted ? fw.primary.opacity(0.38) : fill))
            .overlay(shape.fill(fw.onSurface.opacity(hovered && !highlighted ? 0.05 : 0)).allowsHitTesting(false))
            .overlay(shape.strokeBorder(fw.primary.opacity(selected ? 1 : 0), lineWidth: 1.5).allowsHitTesting(false))
            .animation(.easeOut(duration: highlighted ? 0.09 : 0.28), value: highlighted)
            .contentShape(shape)
            .onTapGesture { onOpen(device) }
            .onHover { hovered = $0 }
            .contextMenu { LiveRowMenu(device: device, vm: vm, lookup: lookup, onOpen: onOpen, onHunt: onHunt) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { onOpen(device) }
    }
}

/// Row context menu: Copy MAC/BSSID, Copy name, Bookmark/Unbookmark, Hunt (BLE).
struct LiveRowMenu: View {
    var device: Sighting
    var vm: FieldwatchViewModel
    var lookup: LiveLookup
    var onOpen: (Sighting) -> Void
    var onHunt: ((Sighting) -> Void)?

    var body: some View {
        let idLabel = device.kind == .wifi ? "Copy BSSID" : (MacUtil.isOpaqueId(device.mac) ? "Copy Bluetooth ID" : "Copy MAC")
        Button(idLabel) { liveCopy(device.mac) }
        Button("Copy name") { liveCopy(lookup.rowTitle(device)) }
        Divider()
        Button(lookup.isWatched(device.key) ? "Unbookmark" : "Bookmark") { vm.toggleWatchDevice(device: device) }
        if device.kind == .ble {
            Button("Hunt") {
                if let onHunt {
                    onHunt(device)
                } else {
                    vm.startHunt(device: device)
                    onOpen(device)
                }
            }
        }
        Divider()
        Button("Open Detail") { onOpen(device) }
    }
}

func liveCopy(_ text: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
}

/// RSSI track + fill without a per-row GeometryReader (kit `RssiBar` uses one).
private struct LiveRssiBar: View {
    @Environment(\.fw) var fw
    var rssi: Int
    var color: Color

    var body: some View {
        let fraction = Double((rssi + 100).coerceIn(0, 70)) / 70
        ZStack(alignment: .leading) {
            Capsule().fill(fw.outline.opacity(0.38))
            BarFill(fraction: fraction).fill(color)
        }
        .frame(height: 8)
        .animation(.easeOut(duration: 0.35), value: fraction)
    }
}

private struct BarFill: Shape {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in r: CGRect) -> Path {
        let minFill = fraction > 0 ? r.height : 0
        let w = (r.width * fraction).coerceAtLeast(minFill).coerceAtMost(r.width)
        return Capsule().path(in: CGRect(x: r.minX, y: r.minY, width: w, height: r.height))
    }
}

// MARK: - Chips and subtitle

/// Kotlin `FleetNameChips`: "!" attention, Mine, observer notes (cyan), alerted bell (phosphor),
/// up to three signature names (+ decode hexagon), live decode values (heavier when emphasized), aircraft.
struct FleetNameChips: View {
    @Environment(\.fw) var fw
    var device: Sighting
    var lookup: LiveLookup
    var attention: Bool = false
    var showNames: Bool = true
    var alerted: Bool = false
    var observed: Bool = false
    var mine: Bool = false

    var body: some View {
        let firstColor = fw.tint(device.fleetIds.first.map { lookup.fleetPaletteColor($0) } ?? fw.primary)
        HStack(spacing: 4) {
            if attention {
                chip(fill: fw.error.opacity(0.22), h: 6) {
                    Text("!").font(.system(size: 11, weight: .bold)).foregroundStyle(fw.error)
                }
                .help("Extra attention")
            }
            if mine {
                chip(fill: fw.onSurface.opacity(0.12), h: 6) {
                    Text("Mine").font(.system(size: 10, weight: .semibold)).foregroundStyle(fw.onSurface)
                }
            }
            if observed {
                let ink = fw.tint(FW.cyan)
                chip(fill: ink.opacity(0.22), h: 5) {
                    Image(systemName: "note.text").font(.system(size: 9, weight: .semibold)).foregroundStyle(ink)
                }
                .help("Observer notes")
            }
            if alerted {
                chip(fill: fw.active.opacity(0.22), h: 5) {
                    Image(systemName: "bell").font(.system(size: 9, weight: .semibold)).foregroundStyle(fw.active)
                }
                .help("Alerted this session")
            }
            if showNames {
                ForEach(device.fleetIds.take(3), id: \.self) { id in
                    let color = fw.tint(lookup.fleetPaletteColor(id))
                    chip(fill: color.opacity(0.18), h: 5) {
                        HStack(spacing: 3) {
                            Text(id == FastPair.FLEET_ID ? FastPair.liveLabel(pairing: device.fastPairPairing) : lookup.fleetName(id))
                                .font(.system(size: 10))
                                .foregroundStyle(color)
                                .lineLimit(1)
                            if lookup.fleetHasDecode(id) {
                                DecodeGlyph(tint: color, size: 10)
                            }
                        }
                    }
                }
            }
            ForEach(Array(device.liveDecode.enumerated()), id: \.offset) { _, decoded in
                chip(fill: firstColor.opacity(decoded.emphasis ? 0.42 : 0.18), h: 5) {
                    Text(decoded.reportLabel())
                        .font(.system(size: 10, weight: decoded.emphasis ? .bold : .regular))
                        .foregroundStyle(firstColor)
                        .lineLimit(1)
                }
                .help(decoded.note)
            }
            if let aircraft = device.payloadAircraft?.trim(), aircraft.isNotEmpty {
                chip(fill: firstColor.opacity(0.18), h: 5) {
                    Text(aircraft).font(.system(size: 10)).foregroundStyle(firstColor).lineLimit(1)
                }
            }
        }
    }

    private func chip<C: View>(fill: Color, h: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.horizontal, h)
            .padding(.vertical, 1)
            .frame(minHeight: 14)
            .background(Capsule().fill(fill))
    }
}

/// Kotlin `RadioKindSubtitle`: Wi-Fi / Bluetooth mark, then the small monospace second line.
struct RadioKindSubtitle: View {
    @Environment(\.fw) var fw
    var kind: RadioKind
    var text: String

    var body: some View {
        HStack(spacing: 4) {
            RadioKindMark(kind: kind, size: 11)
            if text.isNotEmpty {
                Text(text)
                    .font(FW.mono(11, weight: .regular))
                    .foregroundStyle(fw.onSurfaceVariant)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

// MARK: - Timeline

/// Kotlin `TimelineView` (Live → Timeline): last 15 minutes, solid bars are on-air windows.
struct PresenceTimelineView: View {
    @Environment(\.fw) var fw
    var devices: [Sighting]
    var vm: FieldwatchViewModel
    var onOpen: (Sighting) -> Void
    var rows: LiveRowOptions
    @State var now: Int = nowMs()

    static let topId = "live-timeline-top"
    static let windowMs = 15 * 60 * 1000

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text("Last 15 minutes · solid bars are on-air windows")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(fw.onSurfaceVariant)
                        .id(Self.topId)
                    ForEach(devices) { device in
                        TimelineRow(device: device, vm: vm, onOpen: onOpen, rows: rows, now: now)
                    }
                }
                .padding(12)
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    now = nowMs()
                }
            }
            .onChange(of: vm.liveFocus) { _, focus in
                guard focus > 0 else { return }
                withAnimation(.linear(duration: 0.14)) { proxy.scrollTo(Self.topId, anchor: .top) }
            }
            .onChange(of: vm.beepSnap.seq) {
                let snap = vm.beepSnap
                guard snap.seq > 0, snap.key.isNotBlank, devices.contains(where: { $0.key == snap.key }) else { return }
                proxy.scrollTo(snap.key, anchor: .top)
            }
        }
    }
}

private struct TimelineRow: View {
    @Environment(\.fw) var fw
    var device: Sighting
    var vm: FieldwatchViewModel
    var onOpen: (Sighting) -> Void
    var rows: LiveRowOptions
    var now: Int

    var body: some View {
        let lk = rows.lookup
        let color = fw.tint(device.fleetIds.first.map { lk.fleetPaletteColor($0) } ?? rssiColor(device.rssi))
        let names = lk.names(device)
        let watch = lk.watchLabelFor(device.key)
        let title = liveRowTitle(device: device, titleLine: rows.titleLine, subtitleLine: rows.subtitleLine,
                                 names: names, watch: watch, demoMode: rows.demoMode)
        let attention = lk.hasAttention(device)
        let observed = lk.hasObserverNote(device)
        let showNames = rows.showFleet && device.fleetIds.isNotEmpty
        let alerted = rows.alertedKeys.contains(device.key)
        let mine = lk.isMine(device.key)
        let aircraft = device.payloadAircraft?.trim() ?? ""
        let showChips = attention || observed || showNames || alerted || mine || device.liveDecode.isNotEmpty || aircraft.isNotEmpty

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                RadioClassBadge(classKind: device.fleetIds.first.flatMap { lk.fleetKind($0) }, accent: color)
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TrendMark(trend: device.rssiTrend())
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(device.rssi) dBm").font(FW.mono(13)).foregroundStyle(color)
                    if rows.showFrequency, let fact = liveRadioFactLine(device: device) {
                        Text(fact).font(FW.mono(10, weight: .regular)).foregroundStyle(fw.onSurfaceVariant)
                    }
                }
                .fixedSize()
                .padding(.leading, 6)
            }
            if rows.subtitleLine != ListLine.none {
                RadioKindSubtitle(kind: device.kind,
                                  text: liveListSubtitle(device: device, subtitleLine: rows.subtitleLine, names: names,
                                                         demoMode: rows.demoMode, watchName: watch))
                    .padding(.top, 2)
            }
            if rows.showSeenTimes {
                Text(liveSeenTimesLabel(device: device, now: now))
                    .font(FW.mono(11, weight: .regular))
                    .foregroundStyle(fw.onSurfaceVariant)
                    .padding(.top, 2)
            }
            if showChips {
                FleetNameChips(device: device, lookup: lk, attention: attention, showNames: showNames,
                               alerted: alerted, observed: observed, mine: mine)
                    .padding(.top, 3)
            }
            PresenceTrack(device: device, now: now, windowMs: PresenceTimelineView.windowMs, color: color)
                .padding(.top, 6)
        }
        .padding(12)
        .modifier(LiveRowChrome(
            device: device, vm: vm, lookup: lk, radius: 14, fill: fw.surface,
            highlighted: rows.flashKeys.contains(device.key), selected: rows.selectedKey == device.key,
            onOpen: onOpen, onHunt: rows.onHunt
        ))
    }
}
