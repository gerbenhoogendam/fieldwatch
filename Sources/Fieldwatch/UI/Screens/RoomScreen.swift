import AppKit
import SwiftUI
import FieldwatchCore

// macOS addition: sketch a room, place radios in it, identify them by true distance, and follow them
// relative to this Mac. Not in the Android app. State lives in RoomController.

enum RoomTool: String, CaseIterable, Identifiable {
    case select, wall, rect, measure, erase
    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .wall: return "Wall"
        case .rect: return "Room"
        case .measure: return "Measure"
        case .erase: return "Erase"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .wall: return "line.diagonal"
        case .rect: return "rectangle"
        case .measure: return "ruler"
        case .erase: return "eraser"
        }
    }

    var hint: String {
        switch self {
        case .select: return "Drag radios to where they really are; drag the Mac when you carry it somewhere else. Drag empty space to pan."
        case .wall: return "Drag to draw a wall. Snaps to the grid and to wall ends; hold Shift for straight angles."
        case .rect: return "Drag a rectangle to outline a room."
        case .measure: return "Drag to measure. Nothing is saved."
        case .erase: return "Click a wall to remove it."
        }
    }
}

struct RoomScreen: View {
    var vm: FieldwatchViewModel
    var onOpen: (Sighting) -> Void

    @Environment(\.fw) var fw
    @State var tool: RoomTool = .select
    @State var view = RoomViewport()

    var body: some View {
        let room = RoomController.shared(vm: vm)
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                RoomToolbar(room: room, tool: $tool, view: $view)
                RoomCanvas(room: room, tool: tool, view: $view)
                    .overlay(alignment: .bottomLeading) {
                        Text(tool.hint)
                            .font(.system(size: 11))
                            .foregroundStyle(fw.onSurfaceVariant)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(fw.surface.opacity(0.9)))
                            .padding(10)
                    }
            }
            Divider()
            RoomSidePanel(room: room, onOpen: onOpen, onFocus: { pos in view.center = pos })
                .frame(width: 320)
        }
        .background(fw.background)
        .navigationTitle("Room")
        .onDisappear { room.flush() }
    }
}

/// Pan and zoom of the plan: `scale` pixels per meter around `center` (meters).
struct RoomViewport: Equatable {
    var center = RoomPoint(x: 0, y: 0)
    var scale: Double = 60
    var size: CGSize = .zero
    var fitted = false

    static let MIN_SCALE = 2.0      // ~250 m across a window
    static let MAX_SCALE = 4000.0   // 0.25 mm per pixel

    func screen(_ p: RoomPoint) -> CGPoint {
        CGPoint(x: size.width / 2 + (p.x - center.x) * scale, y: size.height / 2 + (p.y - center.y) * scale)
    }

    func world(_ s: CGPoint) -> RoomPoint {
        RoomPoint(x: center.x + (Double(s.x) - size.width / 2) / scale, y: center.y + (Double(s.y) - size.height / 2) / scale)
    }

    /// Zoom by `factor` keeping the world point under `anchor` fixed.
    mutating func zoom(by factor: Double, at anchor: CGPoint) {
        let before = world(anchor)
        scale = (scale * factor).coerceIn(RoomViewport.MIN_SCALE, RoomViewport.MAX_SCALE)
        let after = world(anchor)
        center = center + (before - after)
    }

    /// Grid step (m) so lines are at least ~14 px apart.
    var gridStep: Double {
        for step in [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 10, 50, 100] where step * scale >= 14 { return step }
        return 500
    }

    var snapStep: Double { max(gridStep / 2, 0.005) }

    mutating func fit(points: [RoomPoint]) {
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(), size.width > 0 else { return }
        center = RoomPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let w = max(maxX - minX, 2), h = max(maxY - minY, 2)
        scale = min((size.width - 80) / w, (size.height - 80) / h).coerceIn(RoomViewport.MIN_SCALE, RoomViewport.MAX_SCALE)
    }
}

// MARK: - Toolbar

private struct RoomToolbar: View {
    @Environment(\.fw) var fw
    var room: RoomController
    @Binding var tool: RoomTool
    @Binding var view: RoomViewport

    var body: some View {
        HStack(spacing: 8) {
            ForEach(RoomTool.allCases) { t in
                FieldwatchFilterChip(selected: tool == t, action: { tool = t }, label: t.title) {
                    Image(systemName: t.symbol).font(.system(size: 11))
                }
                .help(t.hint)
            }
            Spacer()
            Button { room.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!room.canUndo).keyboardShortcut("z", modifiers: .command).help("Undo")
            Button { room.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!room.canRedo).keyboardShortcut("z", modifiers: [.command, .shift]).help("Redo")
            Divider().frame(height: 18)
            Button { view.zoom(by: 1 / 1.5, at: CGPoint(x: view.size.width / 2, y: view.size.height / 2)) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command).help("Zoom out (⌘−)")
            Text(scaleLabel).font(FW.mono(10)).foregroundStyle(fw.onSurfaceVariant).frame(minWidth: 64)
            Button { view.zoom(by: 1.5, at: CGPoint(x: view.size.width / 2, y: view.size.height / 2)) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command).help("Zoom in (⌘+)")
            Button { fitAll() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .keyboardShortcut("0", modifiers: .command).help("Fit room (⌘0)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(fw.surface)
    }

    /// Grid step shown so the operator knows what one square is.
    private var scaleLabel: String {
        let s = view.gridStep
        if s < 0.01 { return "□ \(Int((s * 1000).rounded())) mm" }
        if s < 1 { return "□ \(Int((s * 100).rounded())) cm" }
        return "□ \(Int(s)) m"
    }

    private func fitAll() {
        let p = room.plan
        var pts = p.walls.flatMap { [$0.a, $0.b] } + [p.laptop] + p.spots.map(\.pos)
        pts += p.devices.map { room.tracks[$0.key]?.pos ?? $0.pos }
        view.fit(points: pts)
    }
}

// MARK: - Canvas

private struct RoomCanvas: View {
    @Environment(\.fw) var fw
    var room: RoomController
    var tool: RoomTool
    @Binding var view: RoomViewport

    enum Drag: Equatable {
        case none
        case pan(startCenter: RoomPoint)
        case device(key: String)
        case laptop
        case wallEnd(id: String, end: Int)
        case draw(from: RoomPoint)
    }

    @State var drag: Drag = .none
    @State var dragPoint: RoomPoint?
    /// Last ruler measurement; stays until the next one or another tool.
    @State var measureLine: [RoomPoint] = []
    @State var hover: CGPoint?
    @State var monitor = ScrollMonitor()

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                var v = view
                v.size = size
                draw(ctx: &ctx, v: v)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = p; monitor.inside = true
                case .ended: hover = nil; monitor.inside = false
                }
            }
            .onAppear {
                view.size = geo.size
                if !view.fitted {
                    view.fitted = true
                    let p = room.plan
                    let pts = p.walls.flatMap { [$0.a, $0.b] } + [p.laptop] + p.devices.map(\.pos)
                    if pts.count > 1 { view.fit(points: pts) } else { view.center = p.laptop }
                }
                monitor.onScroll = { dx, dy, precise in
                    if precise {
                        view.center = view.center - RoomPoint(x: dx / view.scale, y: dy / view.scale)
                    } else {
                        view.zoom(by: pow(1.15, dy / 3), at: hover ?? CGPoint(x: view.size.width / 2, y: view.size.height / 2))
                    }
                }
                monitor.onZoom = { factor, withMouse in
                    view.zoom(by: factor, at: withMouse ? (hover ?? CGPoint(x: view.size.width / 2, y: view.size.height / 2))
                                                        : CGPoint(x: view.size.width / 2, y: view.size.height / 2))
                }
                monitor.start()
            }
            .onDisappear { monitor.stop() }
            .onChange(of: geo.size) { _, s in view.size = s }
            .onKeyPress(.delete) { deleteSelection() }
            .onKeyPress(.deleteForward) { deleteSelection() }
            .onKeyPress(.escape) { drag = .none; dragPoint = nil; room.selectedKey = nil; room.selectedWallId = nil; return .handled }
            .focusable()
            .focusEffectDisabled()
        }
        .background(fw.background)
    }

    private func deleteSelection() -> KeyPress.Result {
        if let id = room.selectedWallId { room.removeWall(id: id); return .handled }
        return .ignored
    }

    // MARK: Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { g in
                var v = view
                if drag == .none { begin(at: g.startLocation) }
                switch drag {
                case .pan(let c0):
                    v.center = c0 - RoomPoint(x: Double(g.translation.width) / v.scale, y: Double(g.translation.height) / v.scale)
                    view = v
                case .device, .laptop:
                    dragPoint = snap(view.world(g.location), shift: false, from: nil)
                case .wallEnd(let id, let end):
                    let other = room.plan.walls.first { $0.id == id }.map { end == 0 ? $0.b : $0.a }
                    dragPoint = snap(view.world(g.location), shift: NSEvent.modifierFlags.contains(.shift), from: other)
                case .draw(let from):
                    dragPoint = snap(view.world(g.location), shift: NSEvent.modifierFlags.contains(.shift) && tool != .rect, from: from)
                case .none:
                    break
                }
            }
            .onEnded { g in
                let moved = hypot(g.translation.width, g.translation.height) >= 3
                switch drag {
                case .device(let key):
                    if moved, let p = dragPoint { room.moveDevice(key: key, to: p) }
                    room.selectedKey = key
                    room.selectedWallId = nil
                case .laptop:
                    if moved, let p = dragPoint { room.moveLaptop(to: p) }
                case .wallEnd(let id, let end):
                    if moved, let p = dragPoint { room.moveWallEnd(id: id, end: end, to: p) }
                case .draw(let from):
                    if let to = dragPoint, moved {
                        if tool == .wall { room.addWall(a: from, b: to) }
                        if tool == .rect { room.addRectangle(a: from, b: to) }
                        if tool == .measure { measureLine = [from, to] }
                    }
                case .pan:
                    if !moved { click(at: g.startLocation) }
                case .none:
                    break
                }
                dragPoint = nil
                drag = .none
            }
    }

    private func begin(at s: CGPoint) {
        let w = view.world(s)
        switch tool {
        case .select:
            if let key = hitDevice(s) {
                drag = .device(key: key)
                dragPoint = nil
            } else if hit(view.screen(room.plan.laptop), s, 16) {
                drag = .laptop
            } else if let (id, end) = hitWallEnd(s), room.selectedWallId == id {
                drag = .wallEnd(id: id, end: end)
            } else {
                drag = .pan(startCenter: view.center)
            }
        case .wall, .rect, .measure:
            let start = snap(w, shift: false, from: nil)
            drag = .draw(from: start)
            dragPoint = start
        case .erase:
            if let id = hitWall(s) { room.removeWall(id: id) }
            drag = .pan(startCenter: view.center)
        }
    }

    private func click(at s: CGPoint) {
        if let key = hitDevice(s) {
            room.selectedKey = key
            room.selectedWallId = nil
        } else if let id = hitWall(s) {
            room.selectedWallId = id
            room.selectedKey = nil
        } else {
            room.selectedKey = nil
            room.selectedWallId = nil
        }
    }

    private func hit(_ a: CGPoint, _ b: CGPoint, _ r: CGFloat) -> Bool { hypot(a.x - b.x, a.y - b.y) <= r }

    private func drawnPos(_ d: RoomDevice) -> RoomPoint { room.tracks[d.key]?.pos ?? d.pos }

    private func hitDevice(_ s: CGPoint) -> String? {
        room.plan.devices.reversed().first { hit(view.screen(drawnPos($0)), s, 14) }?.key
    }

    private func hitWall(_ s: CGPoint) -> String? {
        var best: (String, CGFloat)?
        for w in room.plan.walls {
            let d = segmentDistance(s, view.screen(w.a), view.screen(w.b))
            if d <= 7, best == nil || d < best!.1 { best = (w.id, d) }
        }
        return best?.0
    }

    private func hitWallEnd(_ s: CGPoint) -> (String, Int)? {
        for w in room.plan.walls {
            if hit(view.screen(w.a), s, 9) { return (w.id, 0) }
            if hit(view.screen(w.b), s, 9) { return (w.id, 1) }
        }
        return nil
    }

    private func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) : 0
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Snap to wall ends within 10 px, else to the grid; Shift keeps 0°/45°/90° from `from`.
    private func snap(_ p: RoomPoint, shift: Bool, from: RoomPoint?) -> RoomPoint {
        var q = p
        if shift, let f = from {
            let d = p - f
            let a = (atan2(d.y, d.x) / (.pi / 4)).rounded() * (.pi / 4)
            let len = d.length
            q = f + RoomPoint(x: cos(a), y: sin(a)) * len
        }
        let ends = room.plan.walls.flatMap { [$0.a, $0.b] } + [room.plan.laptop]
        if let e = ends.min(by: { $0.distance(to: q) < $1.distance(to: q) }), e.distance(to: q) * view.scale <= 10 {
            return e
        }
        let s = view.snapStep
        if shift, let f = from {
            // Snap the length, keep the angle.
            let d = q - f
            let len = (d.length / s).rounded() * s
            return d.length > 0 ? f + d * (len / d.length) : f
        }
        return RoomPoint(x: (q.x / s).rounded() * s, y: (q.y / s).rounded() * s)
    }

    // MARK: Drawing

    private func draw(ctx: inout GraphicsContext, v: RoomViewport) {
        drawGrid(ctx: &ctx, v: v)
        let plan = room.plan

        // Walls.
        for w in plan.walls {
            var path = Path()
            path.move(to: v.screen(w.a))
            path.addLine(to: v.screen(w.b))
            let selected = room.selectedWallId == w.id
            ctx.stroke(path, with: .color(selected ? fw.primary : fw.onSurface.opacity(0.85)),
                       style: StrokeStyle(lineWidth: max(2.5, min(0.12 * v.scale, 10)), lineCap: .round))
            if selected || v.scale >= 40 {
                label(ctx: &ctx, RoomFormat.length(w.length), at: mid(v.screen(w.a), v.screen(w.b)),
                      color: selected ? fw.primary : fw.onSurfaceVariant, small: true)
            }
            if selected {
                for e in [w.a, w.b] { dot(ctx: &ctx, v.screen(e), r: 5, fill: fw.primary) }
            }
        }

        // Wall / rectangle / ruler being drawn.
        if case .draw(let from) = drag, let to = dragPoint {
            let a = v.screen(from), b = v.screen(to)
            if tool == .rect {
                let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                ctx.stroke(Path(r), with: .color(fw.primary), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                label(ctx: &ctx, "\(RoomFormat.length(abs(to.x - from.x))) × \(RoomFormat.length(abs(to.y - from.y)))",
                      at: CGPoint(x: r.midX, y: r.midY), color: fw.primary, small: false)
            } else {
                var path = Path(); path.move(to: a); path.addLine(to: b)
                ctx.stroke(path, with: .color(fw.primary), style: StrokeStyle(lineWidth: 2, dash: tool == .measure ? [4, 3] : []))
                label(ctx: &ctx, RoomFormat.length(from.distance(to: to)), at: mid(a, b), color: fw.primary, small: false)
            }
        } else if tool == .measure, measureLine.count == 2 {
            let a = v.screen(measureLine[0]), b = v.screen(measureLine[1])
            var path = Path(); path.move(to: a); path.addLine(to: b)
            ctx.stroke(path, with: .color(fw.primary), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            label(ctx: &ctx, RoomFormat.length(measureLine[0].distance(to: measureLine[1])), at: mid(a, b), color: fw.primary, small: false)
        }

        // Earlier Mac spots.
        for s in plan.spots where s.id != plan.spotId {
            let p = v.screen(s.pos)
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(fw.onSurfaceVariant), lineWidth: 1)
        }

        let laptop = (drag == .laptop ? dragPoint : nil) ?? plan.laptop
        let lp = v.screen(laptop)

        // Selected radio: distance band around the Mac and the line to the radio.
        if let key = room.selectedKey, let t = room.tracks[key] {
            let lo = t.lowM * v.scale, hi = t.highM * v.scale
            var ring = Path(ellipseIn: CGRect(x: lp.x - hi, y: lp.y - hi, width: hi * 2, height: hi * 2))
            ring.addPath(Path(ellipseIn: CGRect(x: lp.x - lo, y: lp.y - lo, width: lo * 2, height: lo * 2)))
            ctx.fill(ring, with: .color(fw.primary.opacity(0.08)), style: FillStyle(eoFill: true))
            let r = t.distanceM * v.scale
            ctx.stroke(Path(ellipseIn: CGRect(x: lp.x - r, y: lp.y - r, width: r * 2, height: r * 2)),
                       with: .color(fw.primary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }

        // Radios: lines, labels and move ghosts first, then every dot on top so no label hides one.
        struct Placed { let d: RoomDevice; let p: CGPoint; let t: RoomTrack?; let c: Color; let selected: Bool; let dragged: Bool }
        let placed: [Placed] = plan.devices.map { d in
            let dragged: Bool = { if case .device(let k) = drag { return k == d.key } else { return false } }()
            let pos = dragged ? (dragPoint ?? drawnPos(d)) : drawnPos(d)
            return Placed(d: d, p: v.screen(pos), t: room.tracks[d.key], c: fw.tint(color(for: d)), selected: room.selectedKey == d.key, dragged: dragged)
        }
        for item in placed {
            let (d, p, t, c) = (item.d, item.p, item.t, item.c)
            if item.selected || item.dragged {
                var line = Path(); line.move(to: lp); line.addLine(to: p)
                ctx.stroke(line, with: .color(c.opacity(0.7)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                let pos = v.world(p)
                let text = item.dragged ? "drawn \(RoomFormat.meters(laptop.distance(to: pos)))" : (t.map { "≈ \(RoomFormat.band($0))" } ?? "")
                if text.isNotEmpty { label(ctx: &ctx, text, at: mid(lp, p), color: c, small: false) }
            }
            // A pinned radio measured elsewhere: show where the measurement puts it.
            if d.mode == .pinned, let t, t.moved {
                let dir = v.world(p) - laptop
                let unit = dir.length > 1e-6 ? dir * (1 / dir.length) : RoomPoint(x: 1, y: 0)
                let ghost = v.screen(laptop + unit * t.distanceM)
                ctx.stroke(Path(ellipseIn: CGRect(x: ghost.x - 9, y: ghost.y - 9, width: 18, height: 18)),
                           with: .color(FW.amber), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                var arrow = Path(); arrow.move(to: p); arrow.addLine(to: ghost)
                ctx.stroke(arrow, with: .color(FW.amber.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            let r: CGFloat = item.selected ? 11 : 9
            var caption = room.displayName(d)
            if let t { caption += "  \(RoomFormat.meters(t.distanceM))" }
            if t?.stale ?? true { caption += "  · not heard" }
            label(ctx: &ctx, caption, at: CGPoint(x: p.x, y: p.y + r + 11), color: t?.stale ?? true ? fw.onSurfaceVariant : fw.onSurface, small: true)
            if t?.moved == true {
                label(ctx: &ctx, "moved", at: CGPoint(x: p.x, y: p.y - r - 11), color: FW.amber, small: true)
            }
        }
        for item in placed {
            let (d, p, c) = (item.d, item.p, item.c)
            let r: CGFloat = item.selected ? 11 : 9
            let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            ctx.fill(circle, with: .color(fw.background))
            ctx.fill(circle, with: .color(c.opacity(0.3)))
            ctx.stroke(circle, with: .color(c), style: StrokeStyle(lineWidth: item.selected ? 2.5 : 1.5, dash: d.mode == .follow ? [] : [3, 2]))
            let glyph = Text(Image(systemName: d.kind == .wifi ? "wifi" : "dot.radiowaves.left.and.right"))
                .font(.system(size: 9, weight: .bold)).foregroundColor(c)
            ctx.draw(glyph, at: p)
        }

        // The Mac.
        ctx.fill(Path(ellipseIn: CGRect(x: lp.x - 14, y: lp.y - 14, width: 28, height: 28)), with: .color(fw.primary))
        ctx.draw(Text(Image(systemName: "laptopcomputer")).font(.system(size: 13, weight: .semibold)).foregroundColor(fw.onPrimary), at: lp)
        label(ctx: &ctx, "This Mac", at: CGPoint(x: lp.x, y: lp.y + 24), color: fw.primary, small: true)

        // Scale bar.
        drawScaleBar(ctx: &ctx, v: v)
    }

    private func color(for d: RoomDevice) -> Color {
        guard let s = room.sighting(key: d.key), let id = s.fleetIds.first else { return d.kind == .wifi ? FW.cyan : FW.phosphor }
        return fleetColor(room.fleetColor(id: id))
    }

    private func drawGrid(ctx: inout GraphicsContext, v: RoomViewport) {
        let step = v.gridStep
        let major = step * 10
        let tl = v.world(.zero), br = v.world(CGPoint(x: v.size.width, y: v.size.height))
        func lines(_ s: Double, _ color: Color, _ width: CGFloat) {
            var path = Path()
            var x = (tl.x / s).rounded(.down) * s
            while x <= br.x { let px = v.screen(RoomPoint(x: x, y: 0)).x; path.move(to: CGPoint(x: px, y: 0)); path.addLine(to: CGPoint(x: px, y: v.size.height)); x += s }
            var y = (tl.y / s).rounded(.down) * s
            while y <= br.y { let py = v.screen(RoomPoint(x: 0, y: y)).y; path.move(to: CGPoint(x: 0, y: py)); path.addLine(to: CGPoint(x: v.size.width, y: py)); y += s }
            ctx.stroke(path, with: .color(color), lineWidth: width)
        }
        lines(step, fw.outline.opacity(0.35), 0.5)
        lines(major, fw.outline.opacity(0.8), 1)
    }

    private func drawScaleBar(ctx: inout GraphicsContext, v: RoomViewport) {
        let target = 120.0 / v.scale
        let nice = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200].last { $0 <= target } ?? 0.001
        let w = nice * v.scale
        let x0 = v.size.width - w - 16, y = v.size.height - 18
        var bar = Path()
        bar.move(to: CGPoint(x: x0, y: y)); bar.addLine(to: CGPoint(x: x0 + w, y: y))
        bar.move(to: CGPoint(x: x0, y: y - 4)); bar.addLine(to: CGPoint(x: x0, y: y + 4))
        bar.move(to: CGPoint(x: x0 + w, y: y - 4)); bar.addLine(to: CGPoint(x: x0 + w, y: y + 4))
        ctx.stroke(bar, with: .color(fw.onSurface), lineWidth: 1.5)
        let text = nice < 0.01 ? "\(Int((nice * 1000).rounded())) mm" : nice < 1 ? "\(Int((nice * 100).rounded())) cm" : "\(Int(nice)) m"
        label(ctx: &ctx, text, at: CGPoint(x: x0 + w / 2, y: y - 11), color: fw.onSurface, small: true)
    }

    private func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

    private func dot(ctx: inout GraphicsContext, _ p: CGPoint, r: CGFloat, fill: Color) {
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(fill))
    }

    private func label(ctx: inout GraphicsContext, _ s: String, at p: CGPoint, color: Color, small: Bool) {
        let text = ctx.resolve(Text(s).font(small ? FW.mono(10) : FW.mono(11, weight: .semibold)).foregroundColor(color))
        let size = text.measure(in: CGSize(width: 400, height: 40))
        let box = CGRect(x: p.x - size.width / 2 - 4, y: p.y - size.height / 2 - 2, width: size.width + 8, height: size.height + 4)
        ctx.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(fw.background.opacity(0.85)))
        ctx.draw(text, at: p)
    }
}

/// Trackpad scroll pans, mouse wheel and pinch zoom — while the pointer is over the canvas.
@MainActor final class ScrollMonitor {
    var inside = false
    var onScroll: ((Double, Double, Bool) -> Void)?
    var onZoom: ((Double, Bool) -> Void)?
    private var token: Any?

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self, self.inside else { return event }
            switch event.type {
            case .magnify:
                self.onZoom?(1 + Double(event.magnification), true)
                return nil
            case .scrollWheel:
                if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
                    self.onZoom?(pow(1.01, Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 1 : 8)), true)
                } else {
                    self.onScroll?(Double(event.scrollingDeltaX), Double(event.scrollingDeltaY), event.hasPreciseScrollingDeltas)
                }
                return nil
            default:
                return event
            }
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

// MARK: - Side panel

private struct RoomSidePanel: View {
    @Environment(\.fw) var fw
    var room: RoomController
    var onOpen: (Sighting) -> Void
    var onFocus: (RoomPoint) -> Void

    @State var query = ""
    @State var distanceText = ""
    @State var wallText = ""
    @State var nameText = ""
    @State var wallMessage: String?
    @State var message: String?
    @State var renaming = false
    @State var nameDraft = ""
    @State var confirmDeleteRoom = false
    @State var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                roomHeader
                if let key = room.selectedKey, let dev = room.plan.device(key: key) {
                    selectedCard(dev)
                } else if let id = room.selectedWallId, let wall = room.plan.walls.first(where: { $0.id == id }) {
                    wallCard(wall)
                }
                inRoom
                addRadios
                settings
                Text("Distances come from loudness. Indoors it swings several dB with people, walls and antenna angle, so read the band, not just the decimal. Identify a radio at a known distance to calibrate it; carry the Mac to three spots at least 1 m apart (drag its icon each time) and Fieldwatch places followed radios by itself.")
                    .font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
        .background(fw.surface)
        .alert("Rename room", isPresented: $renaming) {
            TextField("Name", text: $nameDraft)
            Button("Rename") { room.renameRoom(nameDraft) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete \(room.plan.name)?", isPresented: $confirmDeleteRoom) {
            Button("Delete", role: .destructive) { room.deleteRoom() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Removes the sketch and the placed radios. Logs and sits are not changed.") }
        .alert("Clear readings?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { room.clearReadings() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Forgets loudness measured at earlier Mac spots. Calibrations, walls and placements stay.") }
    }

    private var roomHeader: some View {
        HStack {
            Menu {
                ForEach(room.file.rooms) { r in
                    Button { room.selectRoom(id: r.id) } label: {
                        if r.id == room.plan.id { Label(r.name, systemImage: "checkmark") } else { Text(r.name) }
                    }
                }
                Divider()
                Button("New room") { room.newRoom(name: "") }
                Button("Rename…") { nameDraft = room.plan.name; renaming = true }
                Button("Delete room…", role: .destructive) { confirmDeleteRoom = true }
            } label: {
                HStack(spacing: 4) {
                    Text(room.plan.name).font(.system(size: 15, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 10))
                }
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            Spacer()
            Text("\(room.plan.devices.count) radios · \(room.plan.walls.count) walls").font(FW.mono(10)).foregroundStyle(fw.onSurfaceVariant)
        }
    }

    private func selectedCard(_ dev: RoomDevice) -> some View {
        let t = room.tracks[dev.key]
        let model = RoomModel.of(device: dev, roomN: room.plan.pathLossN, txPowerDbm: room.sighting(key: dev.key)?.facts.txPowerDbm)
        let drawn = room.plan.laptop.distance(to: dev.pos)
        return SectionCard(title: room.displayName(dev)) {
            HStack(spacing: 6) {
                TextField("Give it a name, e.g. Living room printer", text: $nameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if nameText.isNotBlank { room.rename(key: dev.key, label: nameText); nameText = "" } }
                FieldwatchActionButton("Name") {
                    if nameText.isNotBlank { room.rename(key: dev.key, label: nameText); nameText = "" }
                }
                .fixedSize()
                .disabled(nameText.isBlank)
            }
            if let t {
                VStack(alignment: .leading, spacing: 2) {
                    Text("≈ \(RoomFormat.meters(t.distanceM))").font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .foregroundStyle(t.stale ? fw.onSurfaceVariant : fw.primary)
                    Text("likely \(RoomFormat.meters(t.lowM)) – \(RoomFormat.meters(t.highM)) · \(Int(t.rssi.rounded())) dBm ±\(fmt(t.spread, 1))")
                        .font(FW.mono(11)).foregroundStyle(fw.onSurfaceVariant)
                    if t.stale { Text("Not heard for a while").font(.system(size: 11)).foregroundStyle(FW.amber) }
                    if t.trilaterated { Text("Placed from \(dev.readings.count) Mac spots").font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant) }
                }
            } else {
                Text("Not heard yet").font(.system(size: 12)).foregroundStyle(fw.onSurfaceVariant)
            }
            Text(model.calibrated
                 ? (model.fittedN ? "Calibrated at \(dev.calibrations.count) distances · room loss \(fmt(model.n, 2))"
                                  : "Calibrated at \(RoomFormat.meters(dev.calibrations.last!.distanceM))")
                 : "Not identified yet — distance uses a generic radio, ± is wide")
                .font(.system(size: 11)).foregroundStyle(model.calibrated ? fw.onSurfaceVariant : FW.amber)
                .fixedSize(horizontal: false, vertical: true)

            if t?.moved == true {
                HStack {
                    Label("Measured away from where it was", systemImage: "arrow.left.and.right").font(.system(size: 11)).foregroundStyle(FW.amber)
                    Spacer()
                    FieldwatchActionButton("Accept") { room.acceptMove(key: dev.key) }.fixedSize()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Identify: true distance to this Mac").font(.system(size: 11, weight: .semibold)).foregroundStyle(fw.onSurfaceVariant)
                HStack(spacing: 6) {
                    TextField("e.g. 1,8", text: $distanceText)
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                        .onSubmit { identify(dev.key) }
                    Text("m").foregroundStyle(fw.onSurfaceVariant)
                    FieldwatchActionButton("Set", prominent: true) { identify(dev.key) }.fixedSize()
                }
                FieldwatchActionButton("Use drawn distance (\(RoomFormat.meters(drawn)))") {
                    distanceText = ""
                    report(room.identify(key: dev.key, meters: drawn), meters: drawn)
                }
                .fixedSize()
                .help("Place the radio where it really is on the sketch first; this takes that distance as true.")
                if let message { Text(message).font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant) }
                if dev.calibrations.isNotEmpty {
                    ForEach(Array(dev.calibrations.enumerated()), id: \.offset) { i, c in
                        HStack {
                            Text("\(RoomFormat.meters(c.distanceM)) at \(Int(c.rssi.rounded())) dBm").font(FW.mono(10)).foregroundStyle(fw.onSurfaceVariant)
                            Spacer()
                            Button { room.removeCalibration(key: dev.key, index: i) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.plain).foregroundStyle(fw.onSurfaceVariant).help("Remove this calibration")
                        }
                    }
                }
            }

            Picker("", selection: Binding(get: { dev.mode }, set: { room.setMode(key: dev.key, mode: $0) })) {
                Text("Follow").tag(RoomDevice.Mode.follow)
                Text("Pinned").tag(RoomDevice.Mode.pinned)
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(dev.mode == .follow
                 ? "Moves with its measured distance (and by itself once the Mac has measured from three spots)."
                 : "Stays where you put it; warns when it is measured elsewhere.")
                .font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant).fixedSize(horizontal: false, vertical: true)

            HStack {
                if let s = room.sighting(key: dev.key) { FieldwatchActionButton("Details") { onOpen(s) }.fixedSize() }
                FieldwatchActionButton("Center") { onFocus(t?.pos ?? dev.pos) }.fixedSize()
                Spacer()
                FieldwatchActionButton("Remove") { room.remove(key: dev.key) }.fixedSize()
            }
        }
    }

    private func wallCard(_ wall: RoomWall) -> some View {
        SectionCard(title: "Wall") {
            Text(RoomFormat.length(wall.length)).font(.system(size: 26, weight: .semibold, design: .monospaced)).foregroundStyle(fw.primary)
            Text("Length").font(.system(size: 11, weight: .semibold)).foregroundStyle(fw.onSurfaceVariant)
            HStack(spacing: 6) {
                TextField("e.g. 4,5", text: $wallText)
                    .textFieldStyle(.roundedBorder).frame(width: 80)
                    .onSubmit { setWall(wall.id) }
                Text("m").foregroundStyle(fw.onSurfaceVariant)
                FieldwatchActionButton("Set", prominent: true) { setWall(wall.id) }.fixedSize()
            }
            if let wallMessage { Text(wallMessage).font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant) }
            Text("The wall keeps its first end; walls attached beyond the other end move along, so a rectangle stays square. You can also drag the green ends (zoom in for 1 cm steps; Shift keeps the angle).")
                .font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                FieldwatchActionButton("Delete wall") { room.removeWall(id: wall.id) }.fixedSize()
            }
        }
        .onChange(of: wall.id) { _, _ in wallText = ""; wallMessage = nil }
    }

    private func setWall(_ id: String) {
        guard let m = RoomFormat.parseMeters(wallText), m >= 0.01 else { wallMessage = "Type a length like 4,5 or 120 cm."; return }
        room.setWallLength(id: id, meters: m)
        wallMessage = "Set to \(RoomFormat.length(m))."
        wallText = ""
    }

    private func identify(_ key: String) {
        guard let m = RoomFormat.parseMeters(distanceText) else { message = "Type a distance like 4,5 or 180 cm."; return }
        report(room.identify(key: key, meters: m), meters: m)
    }

    private func report(_ r: Result<Void, RoomController.CalibrationError>, meters: Double) {
        switch r {
        case .success:
            message = "Set to \(RoomFormat.meters(meters))."
            distanceText = ""
        case .failure(.notHeard):
            message = "Not heard in the last seconds — wait until it advertises, then try again."
        case .failure(.badDistance):
            message = "Use a distance between 0,1 and 300 m."
        }
    }

    private var inRoom: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("In this room").font(.system(size: 12, weight: .semibold))
            if room.plan.devices.isEmpty {
                Text("Add radios below, then drag them to where they are.").font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant)
            }
            ForEach(room.plan.devices) { d in
                let t = room.tracks[d.key]
                Button { room.selectedKey = d.key } label: {
                    HStack(spacing: 6) {
                        Image(systemName: d.mode == .pinned ? "pin" : "dot.radiowaves.right").font(.system(size: 10)).frame(width: 14)
                        Text(room.displayName(d)).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 4)
                        if t?.moved == true { Text("moved").font(FW.mono(10)).foregroundStyle(FW.amber) }
                        Text(t.map { RoomFormat.meters($0.distanceM) } ?? "—").font(FW.mono(11))
                            .foregroundStyle(t?.stale ?? true ? fw.onSurfaceVariant : fw.onSurface)
                    }
                    .padding(.vertical, 4).padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(room.selectedKey == d.key ? fw.sectionFill : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var addRadios: some View {
        VStack(alignment: .leading, spacing: 4) {
            let connected = ConnectedDevices.shared.radios.filter { room.plan.device(key: $0.id) == nil }
            if connected.isNotEmpty {
                Text("Connected to this Mac").font(.system(size: 12, weight: .semibold))
                ForEach(connected) { r in
                    Button { room.addConnected(r) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "link").font(.system(size: 10)).foregroundStyle(fw.onSurfaceVariant)
                            Text(r.name).font(.system(size: 11)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(r.rssi.map { "\($0) dBm" } ?? "—").font(FW.mono(10)).foregroundStyle(fw.onSurfaceVariant)
                            Image(systemName: "plus.circle").foregroundStyle(fw.primary)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Add a radio heard now").font(.system(size: 12, weight: .semibold))
            TextField("Search name or address", text: $query).textFieldStyle(.roundedBorder)
            let list = room.candidates(query: query).prefix(40)
            ForEach(Array(list), id: \.key) { s in
                Button { room.add(s) } label: {
                    HStack(spacing: 6) {
                        RadioKindMark(kind: s.kind, size: 11)
                        Text(room.label(for: s)).font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(s.rssi) dBm").font(FW.mono(10)).foregroundStyle(fw.onSurfaceVariant)
                        Image(systemName: "plus.circle").foregroundStyle(fw.primary)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Room").font(.system(size: 12, weight: .semibold))
            HStack {
                Text("Signal loss").font(.system(size: 11))
                Slider(value: Binding(get: { room.plan.pathLossN }, set: { room.setPathLossN($0) }), in: 1.6...3.6)
                Text(fmt(room.plan.pathLossN, 1)).font(FW.mono(10)).frame(width: 26)
            }
            Text("2 is open space; 3 or more for walls and furniture. Radios identified at two distances use their own value.")
                .font(.system(size: 10)).foregroundStyle(fw.onSurfaceVariant).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Mac spots: \(room.plan.spots.count)").font(FW.mono(10)).foregroundStyle(fw.onSurfaceVariant)
                Spacer()
                FieldwatchActionButton("Clear readings…") { confirmClear = true }.fixedSize()
            }
        }
    }
}
