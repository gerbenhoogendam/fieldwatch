import SwiftUI
import FieldwatchCore

// Port of the Classic radar in ui/screen/LiveScreens.kt (RadarView, drawRadarSweep, drawRadarContact,
// radarAngle, sweepBehindDegrees, sweepPaint). Radius from Core `RadarPlot`. Three layers: static rings
// (redrawn on refresh), an animated layer (sweep, blips, alert pings; per frame) and static labels + YOU.
// Kotlin drew in Android px; `RadarGeom.k` maps those to points.

/// Kotlin `String.hashCode()` (UTF-16, Int32 wrap) — the blip seat must match Android.
func liveJavaHash(_ s: String) -> Int32 {
    var h: Int32 = 0
    for u in s.utf16 { h = h &* 31 &+ Int32(u) }
    return h
}

/// Kotlin `(mac.hashCode() ushr 1) % 360`.
private func blipDegrees(_ mac: String) -> Double {
    Double((UInt32(bitPattern: liveJavaHash(mac)) >> 1) % 360)
}

private func sweepBehindDegrees(sweepDeg: Double, blipDeg: Double) -> Double {
    var beam = (270 + sweepDeg).truncatingRemainder(dividingBy: 360)
    if beam < 0 { beam += 360 }
    var behind = beam - blipDeg
    while behind < 0 { behind += 360 }
    return behind
}

/// 1 at the beam, falling off through the trail, dim between paints.
private func sweepPaint(behindDeg: Double) -> Double {
    if behindDeg <= 8 { return 1 }
    if behindDeg < 120 {
        let u = (behindDeg - 8) / 112
        return (1 - u) * (1 - u)
    }
    return 0.20
}

private enum RadarGeom {
    /// Android px → points.
    static let k: CGFloat = 0.55
    static func center(_ size: CGSize) -> CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
    static func maxR(_ size: CGSize) -> CGFloat { min(size.width, size.height) / 2 - 18 * k }
    static func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
    static func radius(_ rssi: Int, _ maxR: CGFloat, _ zoom: Double) -> CGFloat {
        CGFloat(RadarPlot.radius(rssi: rssi, maxR: Double(maxR), zoom: zoom))
    }
    static func point(_ blip: RadarBlip, _ c: CGPoint, _ maxR: CGFloat, _ zoom: Double) -> CGPoint {
        let a = blip.blipDeg * Double.pi / 180
        let d = Double(radius(blip.plotRssi, maxR, zoom))
        return CGPoint(x: c.x + CGFloat(cos(a) * d), y: c.y + CGFloat(sin(a) * d))
    }
}

/// One plotted radio, resolved once per refresh (not per frame).
private struct RadarBlip {
    var device: Sighting
    var key: String
    var plotRssi: Int
    var blipDeg: Double
    var color: Color
    var named: Bool
    var gone: Bool
    var label: String?
    var flashing: Bool
    var alerted: Bool
}

/// Kotlin `RadarView`. Click a blip for detail; pinch (trackpad) to zoom, double-click to reset.
struct RadarView: View {
    @Environment(\.fw) var fw
    var devices: [Sighting]
    var vm: FieldwatchViewModel
    var sort: StrengthSort
    var windowMs: Int
    var onOpen: (Sighting) -> Void
    var emptyHint: String? = nil
    var showFleet: Bool = true
    var demoMode: Bool = false
    var flashKeys: Set<String> = []
    var alertedKeys: Set<String> = []
    var lookup: LiveLookup? = nil
    @State var zoom: Double = RadarPlot.MIN_ZOOM
    @State var pinchBase: Double? = nil
    @State var flashAt: [String: Int] = [:]

    var body: some View {
        let blips = makeBlips()
        let onAir = devices.count { !$0.gone }
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RadarBackdrop(zoom: zoom, ring: fw.outline, label: fw.onSurfaceVariant)
                SwiftUI.TimelineView(.animation) { tl in
                    RadarScope(blips: blips, zoom: zoom, flashAt: flashAt, date: tl.date,
                               beam: fw.primary, night: fw.night, phosphor: fw.active)
                }
                RadarLabels(blips: blips, zoom: zoom, nameColor: fw.onBackground, youColor: fw.primary)
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { _ in zoom = RadarPlot.MIN_ZOOM }
                    .exclusively(before: SpatialTapGesture(count: 1).onEnded { tap in
                        if let hit = hitBlip(blips, tap.location, size) { onOpen(hit) }
                    })
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        let base = pinchBase ?? zoom
                        if pinchBase == nil { pinchBase = zoom }
                        zoom = RadarPlot.clampZoom(zoom: base * Double(v.magnification))
                    }
                    .onEnded { _ in pinchBase = nil }
            )
        }
        .padding(8)
        .overlay(alignment: .bottomLeading) {
            Text(hintText(onAir: onAir))
                .font(FW.mono(11, weight: .regular))
                .foregroundStyle(fw.onSurfaceVariant)
                .padding(12)
                .allowsHitTesting(false)
        }
        .onChange(of: flashKeys, initial: true) { _, keys in
            let t = nowMs()
            var next = flashAt.filter { keys.contains($0.key) }
            for key in keys where next[key] == nil { next[key] = t }
            if next != flashAt { flashAt = next }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Classic radar")
        .accessibilityValue(hintText(onAir: onAir))
    }

    private func hintText(onAir: Int) -> String {
        if devices.isEmpty { return emptyHint ?? LIVE_RADAR_EMPTY }
        let zoomBit = zoom > 1.04 ? " · ×\(fmt(zoom, 1)) · double-click reset" : " · pinch to zoom"
        return "\(onAir) on-air · \(devices.count) in filter · dim = gone · click a blip\(zoomBit)"
    }

    private func makeBlips() -> [RadarBlip] {
        let lk = lookup ?? LiveLookup(vm: vm)
        let now = nowMs()
        let many = devices.count > 24
        return devices.map { device in
            let plot = Int(device.sortRssi(sort: sort, windowMs: windowMs, now: now))
            let named = device.fleetIds.isNotEmpty
            let base = device.fleetIds.first.map { lk.fleetPaletteColor($0) } ?? rssiColor(plot)
            let label: String?
            if showFleet && named {
                label = device.fleetIds.first.map { lk.fleetName($0).take(14) }
                    ?? MacUtil.redactMacIn(text: lk.rowTitle(device), mac: device.mac, demo: demoMode).take(14)
            } else if named {
                label = MacUtil.redactMacIn(text: lk.rowTitle(device), mac: device.mac, demo: demoMode).take(14)
            } else if !many {
                label = MacUtil.redactMacIn(text: lk.rowTitle(device), mac: device.mac, demo: demoMode).take(12)
            } else {
                label = nil
            }
            return RadarBlip(
                device: device, key: device.key, plotRssi: plot, blipDeg: blipDegrees(device.mac),
                color: fw.tint(base), named: named, gone: device.gone, label: label,
                flashing: flashKeys.contains(device.key), alerted: alertedKeys.contains(device.key)
            )
        }
    }

    private func hitBlip(_ blips: [RadarBlip], _ tap: CGPoint, _ size: CGSize) -> Sighting? {
        let c = RadarGeom.center(size)
        let maxR = RadarGeom.maxR(size)
        var best: (Sighting, CGFloat)? = nil
        for b in blips where RadarPlot.onDisc(rssi: b.plotRssi, maxR: Double(maxR), zoom: zoom) {
            let p = RadarGeom.point(b, c, maxR, zoom)
            let d = hypot(p.x - tap.x, p.y - tap.y)
            if best == nil || d < best!.1 { best = (b.device, d) }
        }
        guard let best, best.1 < 48 * RadarGeom.k else { return nil }
        return best.0
    }
}

// MARK: - Layers

/// Disc, dBm rings with labels, cross axes.
private struct RadarBackdrop: View {
    var zoom: Double
    var ring: Color
    var label: Color

    var body: some View {
        Canvas { ctx, size in
            let k = RadarGeom.k
            let c = RadarGeom.center(size)
            let maxR = RadarGeom.maxR(size)
            guard maxR > 4 else { return }
            ctx.fill(RadarGeom.circle(c, maxR), with: .color(.black.opacity(0.18)))
            for dbm in [-40, -60, -80, -100] {
                let rr = RadarGeom.radius(dbm, maxR, zoom)
                if rr > maxR + 0.5 { continue }
                ctx.stroke(RadarGeom.circle(c, rr), with: .color(ring.opacity(0.55)), lineWidth: 2.2 * k)
                let t = Text("\(dbm)").font(.system(size: 10, design: .monospaced)).foregroundColor(label)
                ctx.draw(t, at: CGPoint(x: c.x + 6 * k, y: c.y - rr), anchor: .bottomLeading)
            }
            var axes = Path()
            axes.move(to: CGPoint(x: c.x - maxR, y: c.y)); axes.addLine(to: CGPoint(x: c.x + maxR, y: c.y))
            axes.move(to: CGPoint(x: c.x, y: c.y - maxR)); axes.addLine(to: CGPoint(x: c.x, y: c.y + maxR))
            ctx.stroke(axes, with: .color(ring.opacity(0.4)), lineWidth: 2 * k)
        }
    }
}

/// Sweep (4.2 s period), contacts lit by the beam, alerted rings, flash pings.
private struct RadarScope: View {
    var blips: [RadarBlip]
    var zoom: Double
    var flashAt: [String: Int]
    var date: Date
    var beam: Color
    var night: Bool
    var phosphor: Color

    var body: some View {
        Canvas { ctx, size in
            let c = RadarGeom.center(size)
            let maxR = RadarGeom.maxR(size)
            guard maxR > 4 else { return }
            let nowMs = Int(date.timeIntervalSince1970 * 1000)
            let periodMs = 4200.0
            let sweep = (date.timeIntervalSinceReferenceDate * 1000).truncatingRemainder(dividingBy: periodMs) / periodMs * 360
            drawSweep(&ctx, c, maxR, sweep)

            func onDisc(_ b: RadarBlip) -> Bool { RadarPlot.onDisc(rssi: b.plotRssi, maxR: Double(maxR), zoom: zoom) }
            // Plain contacts, lit by the sweep.
            for b in blips where !b.flashing && !b.alerted && onDisc(b) {
                let paint = sweepPaint(behindDeg: sweepBehindDegrees(sweepDeg: sweep, blipDeg: b.blipDeg))
                let alpha = (b.gone ? 0.45 : 1) * (0.35 + 0.65 * paint)
                drawContact(&ctx, RadarGeom.point(b, c, maxR, zoom), b.color, alpha, b.named, b.gone, nil, nil)
            }
            // Alerted this session: phosphor ring, drawn on top.
            for b in blips where !b.flashing && b.alerted && onDisc(b) {
                let alpha = b.gone ? 0.45 : 1.0
                drawContact(&ctx, RadarGeom.point(b, c, maxR, zoom), b.color, alpha, b.named, b.gone, nil,
                            phosphor.opacity(alpha))
            }
            // Watchlist hit: two expanding rings and a bright core.
            for b in blips where b.flashing && onDisc(b) {
                let started = flashAt[b.key] ?? nowMs
                drawContact(&ctx, RadarGeom.point(b, c, maxR, zoom), b.color, b.gone ? 0.45 : 1, b.named, b.gone,
                            nowMs - started, nil)
            }
        }
    }

    private func drawSweep(_ ctx: inout GraphicsContext, _ c: CGPoint, _ maxR: CGFloat, _ sweep: Double) {
        let k = RadarGeom.k
        let trailDeg = 58.0
        let steps = 24
        let slice = trailDeg / Double(steps)
        let beamDeg = -90 + sweep
        func pt(_ deg: Double) -> CGPoint {
            let a = deg * Double.pi / 180
            return CGPoint(x: c.x + maxR * CGFloat(cos(a)), y: c.y + maxR * CGFloat(sin(a)))
        }
        for i in 0..<steps {
            let t = Double(i) / max(Double(steps - 1), 1)
            let fade = 1 - t
            let start = beamDeg - Double(i) * slice
            let end = start - (slice + 1.1)
            var wedge = Path()
            wedge.move(to: c)
            wedge.addLine(to: pt(start))
            wedge.addLine(to: pt((start + end) / 2))
            wedge.addLine(to: pt(end))
            wedge.closeSubpath()
            ctx.fill(wedge, with: .color(beam.opacity(0.32 * fade * fade * fade)))
        }
        var line = Path()
        line.move(to: c)
        line.addLine(to: pt(beamDeg))
        ctx.stroke(line, with: .color(beam.opacity(0.16)), lineWidth: 15 * k)
        ctx.stroke(line, with: .color(beam.opacity(0.42)), lineWidth: 7 * k)
        ctx.stroke(line, with: .color(beam.opacity(night ? 0.95 : 0.88)), lineWidth: 2.2 * k)
    }

    private func drawContact(
        _ ctx: inout GraphicsContext, _ pos: CGPoint, _ color: Color, _ alpha: Double,
        _ named: Bool, _ gone: Bool, _ flashElapsedMs: Int?, _ alertedRing: Color?
    ) {
        let k = RadarGeom.k
        let rad = (named ? 11 : 7) * k
        if named && !gone { ctx.fill(RadarGeom.circle(pos, 20 * k), with: .color(color.opacity(0.28))) }
        guard let flashElapsedMs else {
            ctx.fill(RadarGeom.circle(pos, rad), with: .color(color.opacity(alpha)))
            ctx.stroke(RadarGeom.circle(pos, rad), with: .color(.black.opacity(0.35)), lineWidth: 1.4 * k)
            if let alertedRing {
                ctx.stroke(RadarGeom.circle(pos, rad + 3.8 * k), with: .color(alertedRing), lineWidth: 2.3 * k)
            }
            return
        }
        let elapsed = Double(flashElapsedMs.coerceAtLeast(0))
        func ping(_ delayMs: Double, _ travel: CGFloat) {
            let age = elapsed - delayMs
            if age < 0 { return }
            let u = (age / 720).coerceIn(0, 1)
            let ringR = rad + 6 * k + CGFloat(u) * travel * k
            let a = (1 - u) * 0.92
            ctx.stroke(RadarGeom.circle(pos, ringR), with: .color(color.opacity(a)),
                       lineWidth: (3.8 * (1 - 0.55 * CGFloat(u))).coerceAtLeast(1.2) * k)
        }
        ping(0, 56)
        ping(220, 42)
        let beat = (0.5 + 0.5 * sin(elapsed / 1000 * 4 * Double.pi)).coerceIn(0, 1)
        let b = CGFloat(beat)
        ctx.fill(RadarGeom.circle(pos, rad + (16 + 10 * b) * k), with: .color(.white.opacity(0.18 + 0.32 * beat)))
        ctx.fill(RadarGeom.circle(pos, rad + (8 + 6 * b) * k), with: .color(color.opacity(0.40 + 0.25 * beat)))
        ctx.fill(RadarGeom.circle(pos, rad + (2.5 + 2.5 * b) * k), with: .color(.white.opacity(0.80)))
        ctx.fill(RadarGeom.circle(pos, rad + 1.2 * k), with: .color(color.opacity(alpha)))
        ctx.fill(RadarGeom.circle(pos, 3.4 * k), with: .color(.white.opacity(0.70)))
        ctx.stroke(RadarGeom.circle(pos, rad + 1.2 * k), with: .color(.black.opacity(0.35)), lineWidth: 1.4 * k)
    }
}

/// Short blip labels (signature name or type guess, not Title/Subtitle) and YOU at the center.
private struct RadarLabels: View {
    var blips: [RadarBlip]
    var zoom: Double
    var nameColor: Color
    var youColor: Color

    var body: some View {
        Canvas { ctx, size in
            let k = RadarGeom.k
            let c = RadarGeom.center(size)
            let maxR = RadarGeom.maxR(size)
            guard maxR > 4 else { return }
            for b in blips {
                guard let label = b.label, RadarPlot.onDisc(rssi: b.plotRssi, maxR: Double(maxR), zoom: zoom) else { continue }
                let pos = RadarGeom.point(b, c, maxR, zoom)
                let rad = (b.named ? 11 : 7) * k
                let text = ctx.resolve(
                    Text(label).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(nameColor)
                )
                let ts = text.measure(in: size)
                let x = (pos.x - ts.width / 2).coerceIn(0, max(size.width - ts.width, 0))
                let y = (pos.y + rad + 4 * k).coerceAtMost(size.height - ts.height)
                ctx.draw(text, at: CGPoint(x: x, y: y), anchor: .topLeading)
            }
            ctx.fill(RadarGeom.circle(c, 7 * k), with: .color(youColor))
            ctx.fill(RadarGeom.circle(c, 16 * k), with: .color(youColor.opacity(0.2)))
            let you = Text("YOU").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(youColor)
            ctx.draw(you, at: CGPoint(x: c.x, y: c.y + 12 * k), anchor: .top)
        }
        .allowsHitTesting(false)
    }
}
