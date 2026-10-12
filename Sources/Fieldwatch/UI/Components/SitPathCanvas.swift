import SwiftUI
import AppKit
import FieldwatchCore

// Port of ui/component/SitPathCanvas.kt.
//
// The Kotlin canvas draws in device pixels and Core's SitPathPlot constants (pad, cluster threshold,
// tap slop, marker radii) are pixel values. To keep the same proportions the plot is laid out and drawn
// in a pixel space of `PATH_PX` pixels per point, then scaled down to points.
//
// macOS additions (no Kotlin equivalent): pinch (MagnifyGesture) or ⌘/⌥-scroll zooms around the pointer,
// drag pans, double-click or the reset button returns to the full plot. Markers keep their size while the
// geography scales, and stacks are re-clustered at the zoomed positions so they split as you zoom in.

/// Pixels per point used for the Compose pixel constants.
private let PATH_PX: CGFloat = 2

/// Kotlin `internal val AircraftAmber` (aircraft card headings on Reports).
let AircraftAmber = Color(argb: 0xFFC4_7A00)

private let ClusterFill = Color(argb: 0xFF1A_2330)
private let ClusterInk = Color(argb: 0xFFF4_F7FB)
private let UnmatchedDisc = Color(argb: 0xFF8D_6E63)
private let GnssDiamond = Color(argb: 0xFFB9_1C1C)
private let PilotInk = Color(argb: 0xFF3D_4A55)
private let AircraftInk = Color.white

/// North-up plot of the operator path with radio dots, aircraft trails, map tiles and a scale bar.
struct SitPathCanvas: View {
    var model: SitPathPlot.Model
    var tiles: [PathTiles.Tile] = []
    var onOpenRadio: (String) -> Void = { _ in }

    var body: some View {
        SitPathCanvasBody(model: model, tiles: tiles, onOpenRadio: onOpenRadio)
    }
}

// MARK: - Zoomed view of a SitPathPlot.Layout

/// The Core layout with the Mac zoom / pan applied. Identity at zoom 1 and no pan.
private struct PathView {
    let lay: SitPathPlot.Layout
    let zoom: Double
    let panX: Double
    let panY: Double
    let cx: Double
    let cy: Double
    let path: [SitPathPlot.Pt]
    let dots: [(SitPathPlot.Dot, SitPathPlot.Pt)]
    let scaleBarM: Double
    let scaleBarFrac: Double

    init(lay: SitPathPlot.Layout, zoom: Double, pan: CGSize) {
        self.lay = lay
        self.zoom = zoom
        panX = Double(pan.width)
        panY = Double(pan.height)
        cx = (lay.plotLeft + lay.plotRight) / 2
        cy = (lay.plotTop + lay.plotBottom) / 2
        let identity = zoom == 1 && pan == .zero
        if identity {
            path = lay.path
            dots = lay.dots
            scaleBarM = lay.scaleBarM
            scaleBarFrac = lay.scaleBarFrac
        } else {
            let z = zoom, px = panX, py = panY, ccx = cx, ccy = cy
            func tf(_ p: SitPathPlot.Pt) -> SitPathPlot.Pt {
                SitPathPlot.Pt(x: ccx + (p.x - ccx) * z + px, y: ccy + (p.y - ccy) * z + py)
            }
            path = lay.path.map(tf)
            dots = lay.dots.map { ($0.0, tf($0.1)) }
            // Pixels per meter from the projection (110 540 m per degree of latitude), times the zoom.
            let ref = lay.samples.first ?? lay.dots.first.map { GpsSample(at: 0, lat: $0.0.lat, lon: $0.0.lon) }
            let innerW = lay.plotRight - lay.plotLeft
            if let ref, innerW > 0 {
                let a = lay.project(ref.lat, ref.lon)
                let b = lay.project(ref.lat + 0.001, ref.lon)
                let pxPerM = abs(b.y - a.y) / 110.54 * z
                if pxPerM > 0 {
                    let barM = SitPathPlot.niceMeters(raw: innerW / pxPerM * 0.28)
                    scaleBarM = barM
                    scaleBarFrac = (barM * pxPerM / innerW).coerceIn(0.08, 0.45)
                } else {
                    scaleBarM = lay.scaleBarM
                    scaleBarFrac = lay.scaleBarFrac
                }
            } else {
                scaleBarM = lay.scaleBarM
                scaleBarFrac = lay.scaleBarFrac
            }
        }
    }

    func project(_ lat: Double, _ lon: Double) -> SitPathPlot.Pt {
        let p = lay.project(lat, lon)
        if zoom == 1 && panX == 0 && panY == 0 { return p }
        return SitPathPlot.Pt(x: cx + (p.x - cx) * zoom + panX, y: cy + (p.y - cy) * zoom + panY)
    }
}

private func cg(_ p: SitPathPlot.Pt) -> CGPoint { CGPoint(x: p.x, y: p.y) }

private func hypotD(_ dx: Double, _ dy: Double) -> Double { (dx * dx + dy * dy).squareRoot() }

/// Kotlin `labelStyle` (10 sp) measured in pixel space, for hit markers outside the Canvas.
private func labelSizePx(_ s: String) -> CGSize {
    let font = NSFont.systemFont(ofSize: 10 * PATH_PX)
    let r = (s as NSString).size(withAttributes: [.font: font])
    return CGSize(width: ceil(r.width), height: ceil(r.height))
}

private func discColor(_ dot: SitPathPlot.Dot, _ night: Bool) -> Color {
    let raw = dot.accentArgb != 0 ? Color(argb: dot.accentArgb) : UnmatchedDisc
    return raw.nightIf(night)
}

private func pathMarkers(_ view: PathView?, live: Bool, width: Double) -> [SitPathPlot.HitMarker] {
    guard let view else { return [] }
    if view.path.count < 2 || width < 8 { return [] }
    let start = view.path.first!
    let end = view.path.last!
    let startText = labelSizePx("Start")
    let endText = labelSizePx(live ? "Now" : "End")
    return [
        hitMarker(start, 12, startText, width, dx: 8, dy: -6),
        hitMarker(end, 12, endText, width, dx: 10, dy: -(Double(endText.height) + 4)),
    ]
}

private func hitMarker(_ dot: SitPathPlot.Pt, _ radius: Double, _ text: CGSize, _ width: Double, dx: Double, dy: Double) -> SitPathPlot.HitMarker {
    let tw = Double(text.width), th = Double(text.height)
    let left = (dot.x + dx).coerceAtMost((width - tw).coerceAtLeast(0))
    let top = (dot.y + dy).coerceAtLeast(0)
    return SitPathPlot.HitMarker(
        x: dot.x, y: dot.y, radius: radius,
        labelLeft: left, labelTop: top, labelRight: left + tw, labelBottom: top + th
    )
}

private func gnssId(_ pin: SitPathPlot.GnssPin) -> String { "\(pin.at):\(pin.kind):\(pin.secondary)" }

private func gnssAt(_ pins: [SitPathPlot.GnssPin], _ view: PathView, _ x: Double, _ y: Double, slop: Double = 22) -> [SitPathPlot.GnssPin] {
    pins.filter { pin in
        let pt = view.project(pin.lat, pin.lon)
        return hypotD(pt.x - x, pt.y - y) <= slop
    }
}

private func scaleLabel(_ m: Double) -> String {
    m >= 1000 ? "\(Int(m / 1000)) km" : "\(Int(m)) m"
}

// MARK: - Body

private struct SitPathCanvasBody: View {
    @Environment(\.fw) var fw
    var model: SitPathPlot.Model
    var tiles: [PathTiles.Tile]
    var onOpenRadio: (String) -> Void

    @State private var boxSize: CGSize = .zero
    @State private var selectedId: String? = nil
    @State private var selectedGnss: String? = nil
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero          // pixels
    @State private var gestureBaseZoom: CGFloat? = nil
    @State private var gestureBasePan: CGSize = .zero
    @State private var dragBasePan: CGSize? = nil
    @State private var hover: CGPoint? = nil
    @State private var scrollMonitor: Any? = nil

    private static let maxZoom: CGFloat = 12
    private static let height: CGFloat = 300

    var body: some View {
        let night = fw.night
        let pxW = Double(boxSize.width * PATH_PX)
        let pxH = Double(boxSize.height * PATH_PX)
        let base: SitPathPlot.Layout? = (pxW < 8 || pxH < 8) ? nil : SitPathPlot.layout(model: model, width: pxW, height: pxH)
        let view = base.map { PathView(lay: $0, zoom: Double(zoom), pan: pan) }
        let modelDots = model.dots
        let clusters: [SitPathPlot.Cluster] = view.map { v in
            SitPathPlot.clusters(dots: v.dots, numberOf: { dot in
                if let i = modelDots.firstIndex(where: { $0.key == dot.key }) { return i + 1 }
                return 1
            })
        } ?? []
        let selected = clusters.first { $0.id == selectedId }
        let markers = pathMarkers(view, live: model.live, width: pxW)

        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                guard let view else { return }
                ctx.scaleBy(x: 1 / PATH_PX, y: 1 / PATH_PX)
                drawPlot(&ctx, view: view, clusters: clusters, selected: selected,
                         W: Double(size.width * PATH_PX), H: Double(size.height * PATH_PX), night: night)
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2).onEnded { _ in resetZoom() }
                    .exclusively(before: SpatialTapGesture().onEnded { v in
                        tap(at: v.location, view: view, clusters: clusters, markers: markers)
                    })
            )
            .simultaneousGesture(dragGesture())
            .simultaneousGesture(magnifyGesture())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = p
                case .ended: hover = nil
                }
            }
            .accessibilityLabel("Path plot")

            overlayCard(view: view, selected: selected, night: night)
            zoomControls(view: view)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .clipped()
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { boxSize = geo.size }
                .onChange(of: geo.size) { _, s in boxSize = s }
        })
        .help("Pinch or ⌘-scroll to zoom. Drag to pan. Double-click to reset.")
        .onAppear { installScrollMonitor() }
        .onDisappear {
            if let m = scrollMonitor { NSEvent.removeMonitor(m) }
            scrollMonitor = nil
        }
    }

    // MARK: Drawing (pixel space)

    private func text(_ s: String, size: CGFloat = 10, weight: Font.Weight = .regular, color: Color) -> Text {
        Text(s).font(.system(size: size * PATH_PX, weight: weight)).foregroundColor(color)
    }

    private func circle(_ c: CGPoint, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    private func line(_ a: CGPoint, _ b: CGPoint) -> Path {
        var p = Path(); p.move(to: a); p.addLine(to: b); return p
    }

    private func drawPlot(_ ctx: inout GraphicsContext, view: PathView, clusters: [SitPathPlot.Cluster],
                          selected: SitPathPlot.Cluster?, W: Double, H: Double, night: Bool) {
        let lay = view.lay
        let track = fw.onSurface
        let you = FW.cyan.nightIf(night)
        let muted = fw.onSurfaceVariant
        let outline = fw.outline
        let stayInk = fw.active
        let gnssInk = GnssDiamond.nightIf(night)

        // Map tiles under everything, clipped to the plot frame.
        if tiles.isNotEmpty {
            ctx.drawLayer { layer in
                layer.clip(to: Path(CGRect(x: lay.plotLeft, y: lay.plotTop,
                                           width: lay.plotRight - lay.plotLeft, height: lay.plotBottom - lay.plotTop)))
                layer.opacity = 0.55
                for tile in tiles {
                    let nw = view.project(tile.north, tile.west)
                    let se = view.project(tile.south, tile.east)
                    let left = nw.x.roundToInt()
                    let top = nw.y.roundToInt()
                    let w = (se.x - nw.x).roundToInt().coerceAtLeast(1)
                    let h = (se.y - nw.y).roundToInt().coerceAtLeast(1)
                    layer.draw(Image(decorative: tile.bitmap, scale: 1),
                               in: CGRect(x: left, y: top, width: w, height: h))
                }
            }
        }

        let pts = view.path
        if pts.count >= 2 {
            var path = Path()
            path.move(to: cg(pts[0]))
            for i in 1..<pts.count { path.addLine(to: cg(pts[i])) }
            ctx.stroke(path, with: .color(track.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
        if pts.count >= 2 {
            let trace = lay.samples.count >= 2 ? lay.samples : model.samples
            let stays = Geo.legs(samples: trace).filter { $0.stay }
            for i in 1..<pts.count {
                guard i < trace.count else { continue }
                let t = trace[i].at
                if stays.none({ t >= $0.startAt && t <= $0.endAt }) { continue }
                ctx.stroke(line(cg(pts[i - 1]), cg(pts[i])), with: .color(stayInk.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 9, lineCap: .round))
            }
            for stay in stays {
                let pt = view.project(stay.lat, stay.lon)
                ctx.fill(circle(cg(pt), 16), with: .color(stayInk.opacity(0.22)))
            }
            if let first = trace.first, let last = trace.last {
                let dur = (last.at - first.at).coerceAtLeast(1)
                for frac in [0.25, 0.5, 0.75] {
                    let want = first.at + Int(Double(dur) * frac)
                    guard let idx = trace.indices.min(by: { abs(trace[$0].at - want) < abs(trace[$1].at - want) }) else { continue }
                    if idx == 0 || idx == trace.count - 1 { continue }
                    guard idx < pts.count else { continue }
                    let pt = pts[idx]
                    let label = ctx.resolve(text(formatMs(trace[idx].at, "HH:mm"), color: muted))
                    let ms = label.measure(in: CGSize(width: CGFloat.infinity, height: .infinity))
                    ctx.fill(circle(cg(pt), 3), with: .color(muted))
                    ctx.draw(label, at: CGPoint(x: (pt.x + 6).coerceAtMost(W - Double(ms.width)),
                                                y: (pt.y - Double(ms.height) - 2).coerceAtLeast(0)),
                             anchor: .topLeading)
                }
            }
            let start = pts.first!
            let end = pts.last!
            drawStartDot(&ctx, cg(start))
            let startT = ctx.resolve(text("Start", color: muted))
            let sms = startT.measure(in: CGSize(width: CGFloat.infinity, height: .infinity))
            ctx.draw(startT, at: CGPoint(x: (start.x + 8).coerceAtMost(W - Double(sms.width)), y: start.y - 6), anchor: .topLeading)
            let endT = ctx.resolve(text(model.live ? "Now" : "End", color: muted))
            let ems = endT.measure(in: CGSize(width: CGFloat.infinity, height: .infinity))
            ctx.draw(endT, at: CGPoint(x: (end.x + 10).coerceAtMost(W - Double(ems.width)),
                                       y: (end.y - Double(ems.height) - 4).coerceAtLeast(0)),
                     anchor: .topLeading)
        }

        drawAdvertised(&ctx, view: view)

        for cluster in clusters {
            let pt = cg(cluster.center)
            if cluster.stacked {
                let hot = selected?.id == cluster.id
                drawCountBadge(&ctx, pt, cluster.members.count, hot ? 18 : 15)
            } else if let m = cluster.members.first {
                drawClassDisc(&ctx, pt, 12, discColor(m.dot, night), ClassGlyphs.of(m.dot.classKind))
            }
        }
        if let end = pts.last {
            ctx.fill(circle(cg(end), 6.2 + 2.2), with: .color(.white))
            ctx.fill(circle(cg(end), 6.2), with: .color(you))
        }
        for pin in model.gnss {
            drawGnssDiamond(&ctx, cg(view.project(pin.lat, pin.lon)), gnssInk)
        }
        if let selected {
            let insetOnRight = selected.center.x < W / 2
            let dest = CGPoint(x: insetOnRight ? W - 12 : 12, y: 28)
            ctx.stroke(line(cg(selected.center), dest), with: .color(outline), lineWidth: 2)
        }

        let barW = (W - 32) * view.scaleBarFrac
        let barLabel = ctx.resolve(text(scaleLabel(view.scaleBarM), color: muted))
        let bms = barLabel.measure(in: CGSize(width: CGFloat.infinity, height: .infinity))
        let groupW = barW + 8 + Double(bms.width)
        let barX = ((W - groupW) / 2).coerceAtLeast(8)
        let barY = H - 16
        let barStyle = StrokeStyle(lineWidth: 3)
        ctx.stroke(line(CGPoint(x: barX, y: barY), CGPoint(x: barX + barW, y: barY)), with: .color(muted), style: barStyle)
        ctx.stroke(line(CGPoint(x: barX, y: barY - 5), CGPoint(x: barX, y: barY + 5)), with: .color(muted), style: barStyle)
        ctx.stroke(line(CGPoint(x: barX + barW, y: barY - 5), CGPoint(x: barX + barW, y: barY + 5)), with: .color(muted), style: barStyle)
        ctx.draw(barLabel, at: CGPoint(x: barX + barW + 8, y: barY - Double(bms.height) / 2), anchor: .topLeading)
        let n = ctx.resolve(text("N", color: muted))
        let nms = n.measure(in: CGSize(width: CGFloat.infinity, height: .infinity))
        ctx.draw(n, at: CGPoint(x: W - Double(nms.width) - 10, y: 8), anchor: .topLeading)
    }

    private func diamond(_ c: CGPoint, _ r: Double) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addLine(to: CGPoint(x: c.x + r * 0.86, y: c.y))
        p.addLine(to: CGPoint(x: c.x, y: c.y + r))
        p.addLine(to: CGPoint(x: c.x - r * 0.86, y: c.y))
        p.closeSubpath()
        return p
    }

    private func drawGnssDiamond(_ ctx: inout GraphicsContext, _ c: CGPoint, _ color: Color) {
        ctx.fill(diamond(c, 9.2), with: .color(.white))
        ctx.fill(diamond(c, 7.2), with: .color(color))
    }

    private func drawStartDot(_ ctx: inout GraphicsContext, _ c: CGPoint) {
        ctx.fill(circle(c, 8.4), with: .color(.white))
        ctx.fill(circle(c, 6.2), with: .color(.black))
    }

    /// SF Symbol tinted and fitted into an `icon`-sized square around `c` (Compose painter draw).
    private func drawGlyph(_ ctx: inout GraphicsContext, _ symbol: String, _ c: CGPoint, _ icon: Double, _ tint: Color) {
        var img = ctx.resolve(Image(systemName: symbol))
        img.shading = .color(tint)
        let s = img.size
        let longest = Double(max(s.width, s.height))
        guard longest > 0 else { return }
        let f = icon / longest
        let w = Double(s.width) * f, h = Double(s.height) * f
        ctx.draw(img, in: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h))
    }

    private func drawClassDisc(_ ctx: inout GraphicsContext, _ c: CGPoint, _ radius: Double, _ fill: Color, _ symbol: String) {
        ctx.fill(circle(c, radius + 1.6), with: .color(.white))
        ctx.fill(circle(c, radius), with: .color(fill))
        drawGlyph(&ctx, symbol, c, radius * 1.25, .white)
    }

    private func drawCountBadge(_ ctx: inout GraphicsContext, _ c: CGPoint, _ count: Int, _ radius: Double) {
        ctx.fill(circle(c, radius + 2), with: .color(ClusterInk))
        ctx.fill(circle(c, radius), with: .color(ClusterFill))
        let t = ctx.resolve(text("\(count)", size: 12, weight: .bold, color: ClusterInk))
        ctx.draw(t, at: c, anchor: .center)
    }

    private func drawAdvertised(_ ctx: inout GraphicsContext, view: PathView) {
        let dotted = StrokeStyle(lineWidth: 4.2, lineCap: .round, lineJoin: .round, dash: [4, 9], dashPhase: 0)
        for track in model.craft {
            let samples = track.samples
            if samples.isEmpty { continue }
            let pts = samples.map { cg(view.project($0.lat, $0.lon)) }
            if pts.count >= 2 {
                var path = Path()
                path.move(to: pts[0])
                for i in 1..<pts.count { path.addLine(to: pts[i]) }
                ctx.stroke(path, with: .color(AircraftInk), style: dotted)
                let start = pts[0]
                ctx.fill(circle(start, 4.6), with: .color(.white))
                ctx.stroke(circle(start, 4.6), with: .color(AircraftInk), lineWidth: 1.8)
            }
            let end = pts[pts.count - 1]
            let covered = model.dots.any { SitPathPlot.sitsOnCraft(dot: $0, craft: [track]) }
            if !covered {
                ctx.fill(circle(end, 4.6), with: .color(.white))
                ctx.stroke(circle(end, 4.6), with: .color(AircraftInk), lineWidth: 1.8)
            }
        }
        for pilot in model.pilots {
            let c = cg(view.project(pilot.lat, pilot.lon))
            let radius = 11.0
            ctx.fill(circle(c, radius + 1.6), with: .color(.white))
            ctx.fill(circle(c, radius), with: .color(Color(argb: 0xFFF4_F7FB)))
            ctx.stroke(circle(c, radius), with: .color(PilotInk), lineWidth: 1.5)
            drawGlyph(&ctx, "person", c, radius * 1.35, PilotInk)
        }
    }

    // MARK: Taps

    private func tap(at loc: CGPoint, view: PathView?, clusters: [SitPathPlot.Cluster], markers: [SitPathPlot.HitMarker]) {
        let x = Double(loc.x * PATH_PX), y = Double(loc.y * PATH_PX)
        let gnssHit = view.map { gnssAt(model.gnss, $0, x, y) } ?? []
        let radio = SitPathPlot.clusterAt(clusters: clusters, x: x, y: y, markers: markers)
        let gnssD: Double? = view.flatMap { v in
            gnssHit.map { pin -> Double in
                let pt = v.project(pin.lat, pin.lon)
                return hypotD(pt.x - x, pt.y - y)
            }.min()
        }
        let radioD = radio.map { hypotD($0.center.x - x, $0.center.y - y) }
        let pickGnss = gnssHit.isNotEmpty && (radioD == nil || (gnssD ?? .infinity) <= radioD!)
        if pickGnss {
            let id = gnssHit.map(gnssId).joined(separator: "|")
            selectedGnss = selectedGnss == id ? nil : id
            selectedId = nil
        } else {
            selectedGnss = nil
            if let radio {
                selectedId = selectedId == radio.id ? nil : radio.id
            } else {
                selectedId = nil
            }
        }
    }

    // MARK: Zoom and pan

    /// Plot frame in pixels: SitPathPlot.layout defaults (pad 16, scale bar reserve 44).
    private func plotFrame() -> CGRect {
        let w = boxSize.width * PATH_PX, h = boxSize.height * PATH_PX
        return CGRect(x: 16, y: 16, width: max(w - 32, 1), height: max(h - 32 - 44, 1))
    }

    private func clampPan(_ p: CGSize, zoom z: CGFloat) -> CGSize {
        let f = plotFrame()
        let mx = f.width * 0.5 * z
        let my = f.height * 0.5 * z
        return CGSize(width: p.width.coerceIn(-mx, mx), height: p.height.coerceIn(-my, my))
    }

    /// Zoom to `z` keeping the plot point under `anchor` (points) fixed.
    private func setZoom(_ z: CGFloat, anchor: CGPoint?, baseZoom: CGFloat, basePan: CGSize) {
        let nz = z.coerceIn(1, Self.maxZoom)
        let f = plotFrame()
        let cx = f.midX, cy = f.midY
        let a = anchor.map { CGPoint(x: $0.x * PATH_PX, y: $0.y * PATH_PX) } ?? CGPoint(x: cx, y: cy)
        let k = nz / baseZoom
        let np = CGSize(width: (a.x - cx) - (a.x - cx - basePan.width) * k,
                        height: (a.y - cy) - (a.y - cy - basePan.height) * k)
        zoom = nz
        pan = nz == 1 ? .zero : clampPan(np, zoom: nz)
    }

    private func resetZoom() {
        withAnimation(.easeOut(duration: 0.18)) {
            zoom = 1
            pan = .zero
        }
    }

    private func dragGesture() -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                if zoom <= 1 { return }
                let base = dragBasePan ?? pan
                if dragBasePan == nil { dragBasePan = pan }
                pan = clampPan(CGSize(width: base.width + v.translation.width * PATH_PX,
                                      height: base.height + v.translation.height * PATH_PX), zoom: zoom)
            }
            .onEnded { _ in dragBasePan = nil }
    }

    private func magnifyGesture() -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if gestureBaseZoom == nil {
                    gestureBaseZoom = zoom
                    gestureBasePan = pan
                }
                let bz = gestureBaseZoom ?? 1
                setZoom(bz * v.magnification, anchor: v.startLocation, baseZoom: bz, basePan: gestureBasePan)
            }
            .onEnded { _ in gestureBaseZoom = nil }
    }

    /// ⌘- or ⌥-scroll over the plot zooms around the pointer. Plain scrolling still scrolls the page.
    private func installScrollMonitor() {
        if scrollMonitor != nil { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let at = hover else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods.contains(.command) || mods.contains(.option) else { return event }
            let dy = event.scrollingDeltaY
            if dy == 0 { return nil }
            let step = event.hasPreciseScrollingDeltas ? dy * 0.01 : dy * 0.12
            setZoom(zoom * CGFloat(exp(Double(step))), anchor: at, baseZoom: zoom, basePan: pan)
            return nil
        }
    }

    @ViewBuilder
    private func zoomControls(view: PathView?) -> some View {
        if view != nil {
            HStack(spacing: 4) {
                zoomButton("minus", enabled: zoom > 1) {
                    setZoom(zoom / 1.5, anchor: nil, baseZoom: zoom, basePan: pan)
                }
                zoomButton("plus", enabled: zoom < Self.maxZoom) {
                    setZoom(zoom * 1.5, anchor: nil, baseZoom: zoom, basePan: pan)
                }
                if zoom > 1 {
                    zoomButton("arrow.counterclockwise", enabled: true) { resetZoom() }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    private func zoomButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .foregroundStyle(fw.onSurface.opacity(enabled ? 0.9 : 0.35))
                .background(RoundedRectangle(cornerRadius: 5).fill(fw.surface.opacity(0.85)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(fw.outline, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Pop-up cards

    @ViewBuilder
    private func overlayCard(view: PathView?, selected: SitPathPlot.Cluster?, night: Bool) -> some View {
        let track = fw.onSurface
        let muted = fw.onSurfaceVariant
        let you = FW.cyan.nightIf(night)
        let ids = Set((selectedGnss ?? "").split("|"))
        let gnssCard = model.gnss.filter { ids.contains(gnssId($0)) }
        let halfPx = Double(boxSize.width * PATH_PX) / 2
        if let first = gnssCard.first {
            let anchor = view?.project(first.lat, first.lon)
            let onRight = (anchor?.x ?? 0) < halfPx
            card(onRight: onRight) {
                Text(gnssCard.count == 1 ? "GNSS detection" : "\(gnssCard.count) GNSS detections")
                    .font(.system(size: 11)).foregroundStyle(muted)
                ForEach(Array(gnssCard.enumerated()), id: \.offset) { _, pin in
                    Text("\(pin.title()) · \(pin.confidence)").font(.system(size: 12)).foregroundStyle(track)
                    Text(pin.whenLine()).font(.system(size: 11)).foregroundStyle(muted)
                    Text(pin.detail.trim().ifBlank("Signal changed.")).font(.system(size: 12)).foregroundStyle(track)
                }
            }
        } else if let selected {
            let onRight = selected.center.x < halfPx
            card(onRight: onRight) {
                Text(selected.members.count == 1 ? "1 alert here" : "\(selected.members.count) alerts here")
                    .font(.system(size: 11)).foregroundStyle(muted)
                ForEach(Array(selected.members.enumerated()), id: \.offset) { _, m in
                    let accent = discColor(m.dot, night)
                    let obs = m.dot.observerNotes.trim()
                    Button { onOpenRadio(m.dot.key) } label: {
                        HStack(alignment: .center, spacing: 0) {
                            Text("\(m.number)").font(.system(size: 11)).foregroundStyle(muted)
                                .frame(width: 16, alignment: .leading)
                            RadioClassBadge(classKind: m.dot.classKind, accent: accent, compact: true)
                            Spacer().frame(width: 6)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.dot.label).font(.system(size: 12)).foregroundStyle(track).lineLimit(2)
                                if obs.isNotEmpty {
                                    Text(obs).font(.system(size: 11)).foregroundStyle(you).lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func card<C: View>(onRight: Bool, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) { content() }
            .padding(8)
            .frame(maxWidth: 248, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 8).fill(fw.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(fw.outline, lineWidth: 1))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: onRight ? .topTrailing : .topLeading)
    }
}
