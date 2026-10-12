import SwiftUI
import MapKit
import FieldwatchCore

// macOS addition: estimated radio positions on a map. Not in the Android app.
// Estimates come from PositionEstimator (Core): loudness heard at the places this Mac has been.

struct MapScreen: View {
    var state: FieldwatchUi
    var vm: FieldwatchViewModel
    var onOpen: (Sighting) -> Void

    @Environment(\.fw) var fw
    @State var camera: MapCameraPosition = .automatic
    @State var fitted = false
    @State var estimates: [PositionEstimate] = []
    @State var path: [GpsSample] = []
    @State var selection: String?
    @State var confirmClear = false
    @State var revealInPrivacy = false
    /// Rough guesses heard from the same spot, listed in the panel after clicking their marker.
    @State var focusedSpot: RoughSpot?
    /// Name, colour and class per radio, rebuilt with the estimates (every 2 s), so the map and the panel
    /// never search the device list while drawing.
    @State var info: [String: MapPinInfo] = [:]
    @AppStorage("map.showRough") var showRough = true
    @AppStorage("map.showCircles") var showCircles = true
    @AppStorage("map.showPath") var showPath = true

    /// Advertised and estimated radios get their own pin.
    private var placed: [PositionEstimate] { estimates.filter { $0.quality != .rough } }

    /// Rough guesses all sit where this Mac stood; one marker per spot instead of a pile of pins.
    private var roughSpots: [RoughSpot] {
        guard showRough else { return [] }
        return RoughSpot.group(estimates.filter { $0.quality == .rough })
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if state.settings.demoMode && !revealInPrivacy {
                privacyCover
            } else {
                map
                MapSidePanel(
                    estimates: estimates,
                    pathLengthM: Geo.pathLengthM(samples: path),
                    tagLocation: state.settings.tagLocation,
                    locationOn: state.locationOn,
                    showRough: $showRough,
                    showCircles: $showCircles,
                    showPath: $showPath,
                    info: info,
                    onFocus: focus,
                    onFitAll: { withAnimation { fit() } },
                    onCenterMe: { withAnimation { centerOnMac() } },
                    onStartOver: { confirmClear = true },
                    focusedSpot: focusedSpot.flatMap { f in roughSpots.first { $0.id == f.id } ?? f },
                    onCloseSpot: { focusedSpot = nil; selection = nil },
                    onOpenKey: { key in if let d = vm.device(key: key) { onOpen(d) } }
                )
                .equatable()
                .padding(12)
            }
        }
        .background(fw.background)
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: selection) { _, key in
            guard let key else { return }
            select(key)
        }
        .alert("Start over?", isPresented: $confirmClear) {
            Button("Start over", role: .destructive) {
                vm.clearPositionField()
                refresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Forgets every loudness map behind the estimates. The log, sits and the Moving-with-you path are not changed.")
        }
        .navigationTitle("Map")
    }

    private var map: some View {
        let me = vm.macFix()
        let spots = roughSpots
        let macSpot = me.flatMap { m in spots.first { Geo.meters(lat1: $0.lat, lon1: $0.lon, lat2: m.lat, lon2: m.lon) < 15 } }
        return Map(position: $camera, selection: $selection) {
            // This Mac. Drawn by us (not UserAnnotation) so it never covers the radios heard at the same spot.
            if let me, macSpot == nil {
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: me.lat, longitude: me.lon)) {
                    MacMarker()
                }
            }
            if showPath, path.count >= 2 {
                MapPolyline(coordinates: path.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                    .stroke(fw.primary.opacity(0.75), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            if showCircles {
                ForEach(placed + (showRough ? (focusedSpot?.members ?? []) : [])) { e in
                    let c = info[e.key]?.color ?? fw.onSurfaceVariant
                    MapCircle(center: CLLocationCoordinate2D(latitude: e.lat, longitude: e.lon), radius: e.radiusM)
                        .foregroundStyle(c.opacity(e.quality == .rough ? 0.06 : 0.12))
                        .stroke(c.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: e.quality == .rough ? [4, 4] : []))
                }
            }
            ForEach(spots) { spot in
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: spot.lat, longitude: spot.lon)) {
                    RoughSpotPin(count: spot.members.count, atMac: spot.id == macSpot?.id, selected: selection == spot.id)
                        .onTapGesture { select(spot.id) }
                }
                .tag(spot.id)
            }
            ForEach(placed) { e in
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: e.lat, longitude: e.lon)) {
                    MapPin(
                        kind: info[e.key]?.kind,
                        color: info[e.key]?.color ?? fw.onSurfaceVariant,
                        quality: e.quality,
                        label: info[e.key]?.title ?? e.key,
                        selected: selection == e.key
                    )
                    .onTapGesture { select(e.key) }
                }
                .tag(e.key)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls {
            MapCompass()
            MapScaleView()
            MapZoomStepper()
        }
        .modifier(NightMapTint(night: fw.night))
    }

    private var privacyCover: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.slash").font(.system(size: 30)).foregroundStyle(fw.onSurfaceVariant)
            Text("Privacy mode is on").font(.system(size: 15, weight: .semibold))
            Text("The map shows where this Mac has been and where radios are estimated to be. It stays hidden while Privacy mode masks locations on screen.")
                .font(.system(size: 12)).foregroundStyle(fw.onSurfaceVariant)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            FieldwatchActionButton("Show the map anyway") { revealInPrivacy = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refresh() {
        estimates = vm.positionEstimates().sorted {
            $0.quality.order != $1.quality.order ? $0.quality.order < $1.quality.order : $0.radiusM < $1.radiusM
        }
        path = vm.operatorPath()
        var next: [String: MapPinInfo] = [:]
        let byKey = Dictionary(vm.ui.filtered.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for e in estimates {
            guard let d = byKey[e.key] else { continue }
            next[e.key] = MapPinInfo(title: title(for: d), color: color(for: d), kind: d.fleetIds.first.flatMap { vm.fleetKind(id: $0) })
        }
        info = next
        if !fitted, estimates.isNotEmpty || vm.macFix() != nil {
            fitted = true
            fit()
        }
    }

    /// Frame every pin, circle and the walked path; never tighter than 400 m (MapKit has no tiles below that
    /// when everything sits on one spot).
    private func fit() {
        var lats: [Double] = [], lons: [Double] = []
        let mLat = 111_320.0
        for e in estimates where showRough || e.quality != .rough {
            let r = e.quality == .rough ? 0 : e.radiusM
            let mLon = mLat * max(cos(e.lat * .pi / 180), 0.01)
            lats += [e.lat - r / mLat, e.lat + r / mLat]
            lons += [e.lon - r / mLon, e.lon + r / mLon]
        }
        if showPath { for p in path { lats.append(p.lat); lons.append(p.lon) } }
        if let me = vm.macFix() { lats.append(me.lat); lons.append(me.lon) }
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max() else {
            camera = .automatic
            return
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let mLon = mLat * max(cos(center.latitude * .pi / 180), 0.01)
        let spanNS = max((maxLat - minLat) * mLat * 1.3, 400)
        let spanEW = max((maxLon - minLon) * mLon * 1.3, 400)
        camera = .region(MKCoordinateRegion(center: center, latitudinalMeters: spanNS, longitudinalMeters: spanEW))
    }

    private func centerOnMac() {
        guard let me = vm.macFix() else { camera = .userLocation(fallback: .automatic); return }
        camera = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: me.lat, longitude: me.lon),
            latitudinalMeters: 600, longitudinalMeters: 600
        ))
    }

    /// A pin or spot marker was clicked.
    private func select(_ key: String) {
        if selection != key { selection = key }
        if let spot = roughSpots.first(where: { $0.id == key }) {
            focusedSpot = spot
            return
        }
        focusedSpot = nil
        if let device = vm.device(key: key) { onOpen(device) }
    }

    private func focus(_ e: PositionEstimate) {
        let span = max(e.radiusM * 4, 150)
        withAnimation {
            camera = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: e.lat, longitude: e.lon),
                latitudinalMeters: span, longitudinalMeters: span
            ))
        }
        selection = e.key
    }

    private func color(for d: Sighting) -> Color {
        guard let id = d.fleetIds.first else { return fw.onSurfaceVariant }
        return fw.tint(fleetColor(vm.fleetColor(id: id)))
    }

    private func title(for d: Sighting) -> String {
        if let custom = vm.watchLabelFor(deviceKey: d.key)?.trim(), custom.isNotEmpty { return custom }
        let names = d.fleetIds.map { vm.fleetName(id: $0) }
        let t = d.listTitle(signatureNames: names)
        return MacUtil.redactMacIn(text: t, mac: d.mac, demo: state.settings.demoMode)
    }
}

extension PositionEstimate.Quality {
    var order: Int {
        switch self {
        case .advertised: return 0
        case .located: return 1
        case .rough: return 2
        }
    }
}

/// Class glyph pin. Solid ring = advertised, plain = estimate, dashed = rough.
private struct MapPin: View {
    @Environment(\.fw) var fw
    var kind: SignatureClass?
    var color: Color
    var quality: PositionEstimate.Quality
    var label: String
    var selected: Bool

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().fill(fw.background.opacity(0.85))
                Circle().fill(color.opacity(0.22))
                Circle().stroke(
                    color,
                    style: StrokeStyle(lineWidth: quality == .advertised ? 2.5 : 1.2, dash: quality == .rough ? [3, 3] : [])
                )
                Image(systemName: ClassGlyphs.of(kind)).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            }
            .frame(width: 26, height: 26)
            .scaleEffect(selected ? 1.25 : 1)
            if selected {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(fw.surface.opacity(0.95)))
                    .foregroundStyle(fw.onSurface)
            }
        }
        .animation(.easeOut(duration: 0.15), value: selected)
        .help(label)
    }
}

/// Night mode: fold the map's colours into the red field display.
private struct NightMapTint: ViewModifier {
    var night: Bool
    func body(content: Content) -> some View {
        if night {
            content.saturation(0).colorMultiply(Color(red: 1, green: 0.32, blue: 0.3))
        } else {
            content
        }
    }
}

/// Legend, counts, switches and the list of placed radios.
struct MapPinInfo: Equatable {
    var title: String
    var color: Color
    var kind: SignatureClass?
}

private struct MapSidePanel: View, Equatable {
    @Environment(\.fw) var fw
    var estimates: [PositionEstimate]
    var pathLengthM: Double
    var tagLocation: Bool
    var locationOn: Bool
    @Binding var showRough: Bool
    @Binding var showCircles: Bool
    @Binding var showPath: Bool
    var info: [String: MapPinInfo]
    var onFocus: (PositionEstimate) -> Void
    var onFitAll: () -> Void
    var onCenterMe: () -> Void
    var onStartOver: () -> Void
    var focusedSpot: RoughSpot?
    var onCloseSpot: () -> Void
    var onOpenKey: (String) -> Void
    @State var expanded = true

    /// Redraw only when what is shown changes (the action closures never compare equal).
    static func == (a: MapSidePanel, b: MapSidePanel) -> Bool {
        a.estimates == b.estimates && a.info == b.info && Int(a.pathLengthM) == Int(b.pathLengthM)
            && a.tagLocation == b.tagLocation && a.locationOn == b.locationOn && a.showRough == b.showRough
            && a.showCircles == b.showCircles && a.showPath == b.showPath && a.focusedSpot == b.focusedSpot
    }

    private func title(_ e: PositionEstimate) -> String { info[e.key]?.title ?? e.key }
    private func color(_ e: PositionEstimate) -> Color { info[e.key]?.color ?? fw.onSurfaceVariant }

    private func count(_ q: PositionEstimate.Quality) -> Int { estimates.count { $0.quality == q } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Estimated positions").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain).foregroundStyle(fw.onSurfaceVariant)
            }
            if expanded {
                expandedBody
            } else {
                Text("\(count(.advertised) + count(.located)) placed · \(count(.rough)) rough")
                    .font(FW.mono(11)).foregroundStyle(fw.onSurfaceVariant)
            }
        }
        .padding(12)
        .frame(width: 290, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(fw.surface.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(fw.outline, lineWidth: 1))
    }

    @ViewBuilder
    private var expandedBody: some View {
        if !tagLocation || !locationOn {
            Label(
                !tagLocation ? "Tag detections with GPS is off in Settings, so nothing can be placed."
                    : "Location is off. Turn it on so this Mac knows where it hears each radio.",
                systemImage: "location.slash"
            )
            .font(.system(size: 11)).foregroundStyle(fw.error)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text("A radio's position is guessed from how loud it was at each place this Mac heard it. Walk around to sharpen the guesses. Circles show the uncertainty; walls and bodies make it larger than drawn.")
            .font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant)
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 4) {
            legendRow(dash: [], width: 2.5, "Advertised by the radio", count(.advertised))
            legendRow(dash: [], width: 1.2, "Estimated (heard from several spots)", count(.located))
            legendRow(dash: [3, 3], width: 1.2, "Rough (heard from one area)", count(.rough))
            Text("Path walked: \(Self.meters(pathLengthM))").font(FW.mono(11)).foregroundStyle(fw.onSurfaceVariant)
        }

        VStack(spacing: 6) {
            FieldwatchSwitch("Show rough guesses", checked: showRough) { showRough = $0 }
            FieldwatchSwitch("Uncertainty circles", checked: showCircles) { showCircles = $0 }
            FieldwatchSwitch("Path walked", checked: showPath) { showPath = $0 }
        }

        HStack(spacing: 6) {
            FieldwatchActionButton(action: onFitAll) { Image(systemName: "arrow.up.left.and.arrow.down.right"); Text("Fit") }
                .fixedSize().help("Show every placed radio")
            FieldwatchActionButton(action: onCenterMe) { Image(systemName: "location"); Text("Me") }
                .fixedSize().help("Center on this Mac")
            Spacer(minLength: 0)
            FieldwatchActionButton("Start over…", action: onStartOver).fixedSize()
        }

        if let spot = focusedSpot {
            Divider()
            HStack {
                Text("Heard here, direction unknown (\(spot.members.count))")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(fw.onSurfaceVariant)
                Spacer()
                Button(action: onCloseSpot) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(fw.onSurfaceVariant)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(spot.members.sorted { $0.radiusM < $1.radiusM }) { e in
                        Button { onOpenKey(e.key) } label: {
                            HStack(spacing: 6) {
                                Circle().fill(color(e)).frame(width: 7, height: 7)
                                Text(title(e)).font(.system(size: 11)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text("within ~\(Self.meters(e.radiusM))").font(FW.mono(10)).foregroundStyle(fw.onSurfaceVariant)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 220)
        }

        let placed = estimates.filter { $0.quality != .rough }
        if placed.isNotEmpty {
            Divider()
            Text("Placed radios").font(.system(size: 11, weight: .semibold)).foregroundStyle(fw.onSurfaceVariant)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(placed) { e in
                        Button { onFocus(e) } label: {
                            HStack(spacing: 6) {
                                Circle().fill(color(e)).frame(width: 7, height: 7)
                                Text(title(e)).font(.system(size: 11)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(e.quality == .advertised ? "exact" : "±\(Self.meters(e.radiusM))")
                                    .font(FW.mono(10)).foregroundStyle(fw.onSurfaceVariant)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    private func legendRow(dash: [CGFloat], width: CGFloat, _ text: String, _ n: Int) -> some View {
        HStack(spacing: 8) {
            Circle().stroke(fw.primary, style: StrokeStyle(lineWidth: width, dash: dash)).frame(width: 12, height: 12)
            Text(text).font(.system(size: 11))
            Spacer(minLength: 4)
            Text("\(n)").font(FW.mono(11)).foregroundStyle(fw.onSurfaceVariant)
        }
    }

    static func meters(_ m: Double) -> String {
        m >= 1000 ? "\(fmt(m / 1000, 1)) km" : "\(Int(m.rounded())) m"
    }
}

/// Rough guesses sharing one spot (within ~12 m), shown as a single marker.
struct RoughSpot: Identifiable, Hashable {
    var id: String
    var lat: Double
    var lon: Double
    var members: [PositionEstimate]

    static func group(_ rough: [PositionEstimate]) -> [RoughSpot] {
        var spots: [RoughSpot] = []
        for e in rough.sorted(by: { $0.key < $1.key }) {
            if let i = spots.firstIndex(where: { Geo.meters(lat1: $0.lat, lon1: $0.lon, lat2: e.lat, lon2: e.lon) < 12 }) {
                spots[i].members.append(e)
            } else {
                spots.append(RoughSpot(id: "spot:" + e.key, lat: e.lat, lon: e.lon, members: [e]))
            }
        }
        return spots
    }
}

/// Count badge for radios heard from one spot.
private struct RoughSpotPin: View {
    @Environment(\.fw) var fw
    var count: Int
    var atMac: Bool
    var selected: Bool

    var body: some View {
        HStack(spacing: 4) {
            if atMac { Image(systemName: "laptopcomputer").font(.system(size: 11, weight: .semibold)).foregroundStyle(fw.primary) }
            Text("\(count)").font(FW.mono(11, weight: .bold))
        }
            .foregroundStyle(fw.onSurface)
            .frame(minWidth: 26, minHeight: 26)
            .padding(.horizontal, atMac || count > 99 ? 7 : 0)
            .background(Capsule().fill(fw.surface.opacity(0.92)))
            .overlay(Capsule().stroke(fw.primary, style: StrokeStyle(lineWidth: 1.2, dash: [3, 3])))
            .scaleEffect(selected ? 1.2 : 1)
            .help(atMac
                ? "This Mac. \(count) radios heard only from here — direction unknown. Walk around to place them."
                : "\(count) radios heard from this spot only. Walk around to place them.")
    }
}

/// This Mac's position when no rough-guess marker sits on it.
private struct MacMarker: View {
    @Environment(\.fw) var fw
    var body: some View {
        Image(systemName: "laptopcomputer")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(fw.onPrimary)
            .frame(width: 28, height: 28)
            .background(Circle().fill(fw.primary))
            .overlay(Circle().stroke(fw.background, lineWidth: 2))
            .help("This Mac")
    }
}
