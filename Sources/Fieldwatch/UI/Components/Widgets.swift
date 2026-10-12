import SwiftUI
import FieldwatchCore

// Port of ui/component/Widgets.kt.

func rssiColor(_ rssi: Int) -> Color {
    if rssi >= -55 { return Color(hex: 0x3DFF9A) }
    if rssi >= -70 { return Color(hex: 0xFFB020) }
    if rssi >= -85 { return Color(hex: 0xFF8A4C) }
    return Color(hex: 0xFF3D5A)
}

extension RssiTrend {
    func mark() -> String {
        switch self {
        case .upFast: return ">>"
        case .up: return ">"
        case .flat: return "="
        case .down: return "<"
        case .downFast: return "<<"
        case .unknown: return ""
        }
    }

    func tint() -> Color {
        switch self {
        case .upFast, .up: return Color(hex: 0x3DFF9A)
        case .down, .downFast: return Color(hex: 0xFF3D5A)
        case .flat: return Color(hex: 0x8A93A0)
        case .unknown: return .clear
        }
    }
}

struct TrendMark: View {
    @Environment(\.fw) var fw
    var trend: RssiTrend

    var body: some View {
        let label = trend.mark()
        if label.isNotEmpty {
            Text(label).font(FW.mono(12, weight: .bold)).foregroundStyle(fw.tint(trend.tint()))
        }
    }
}

/// Track plus fill from last-heard strength.
struct RssiBar: View {
    @Environment(\.fw) var fw
    var rssi: Int
    var color: Color

    var body: some View {
        let fraction = Double((rssi + 100).coerceIn(0, 70)) / 70
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .leading) {
                Capsule().fill(fw.outline.opacity(0.38))
                let minFill = fraction > 0 ? h : 0
                Capsule().fill(color)
                    .frame(width: (geo.size.width * fraction).coerceAtLeast(minFill).coerceAtMost(geo.size.width))
            }
        }
        .frame(height: 8)
        .animation(.easeOut(duration: 0.35), value: fraction)
    }
}

/// RSSI history with a dBm scale.
struct Sparkline: View {
    @Environment(\.fw) var fw
    var samples: [RssiSample]
    var color: Color
    var height: CGFloat = 56

    var body: some View {
        Canvas { ctx, size in
            let major = fw.outline.opacity(0.94)
            let minor = fw.outline.opacity(0.64)
            let axis = fw.outline.opacity(0.90)
            let labelColor = fw.onSurfaceVariant.opacity(0.78)
            let ticks = [-30, -40, -50, -60, -70, -80, -90, -100]
            let labeled: Set<Int> = [-30, -50, -70, -100]
            func label(_ s: String) -> Text { Text(s).font(.system(size: 8, design: .monospaced)).foregroundColor(labelColor) }
            let gutter = ctx.resolve(label("-100")).measure(in: size).width + 6
            let left = gutter, right = size.width
            let plotW = max(right - left, 1)
            func yOf(_ rssi: Int) -> CGFloat { size.height * (1 - CGFloat((rssi + 100).coerceIn(0, 70)) / 70) }
            func xOf(_ i: Int, _ last: Int) -> CGFloat { last <= 0 ? right : left + plotW * CGFloat(i) / CGFloat(last) }

            for dbm in labeled.sorted() {
                let t = ctx.resolve(label("\(dbm)"))
                let ts = t.measure(in: size)
                let y = (yOf(dbm) - ts.height / 2).coerceIn(0, max(size.height - ts.height, 0))
                ctx.draw(t, at: CGPoint(x: 0, y: y), anchor: .topLeading)
            }
            for dbm in ticks {
                let y = yOf(dbm)
                let isLabeled = labeled.contains(dbm)
                let startX = isLabeled ? ctx.resolve(label("\(dbm)")).measure(in: size).width + 5 : left
                var p = Path(); p.move(to: CGPoint(x: startX, y: y)); p.addLine(to: CGPoint(x: right, y: y))
                ctx.stroke(p, with: .color(isLabeled ? major : minor),
                           style: StrokeStyle(lineWidth: isLabeled ? 0.9 : 0.6, dash: isLabeled ? [] : [2.5, 2.5]))
            }
            var ax = Path(); ax.move(to: CGPoint(x: left, y: yOf(-30))); ax.addLine(to: CGPoint(x: left, y: yOf(-100)))
            ctx.stroke(ax, with: .color(axis), lineWidth: 0.9)
            for c in 1..<4 {
                let x = left + plotW * CGFloat(c) / 4
                var p = Path(); p.move(to: CGPoint(x: x, y: yOf(-30))); p.addLine(to: CGPoint(x: x, y: yOf(-100)))
                ctx.stroke(p, with: .color(minor), style: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
            }
            let series = samples.filter { Rssi.measured(rssi: $0.rssi) }
            if series.isEmpty { return }
            if series.count == 1 {
                let c = CGPoint(x: right, y: yOf(series[0].rssi))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)), with: .color(color))
                return
            }
            var path = Path()
            for (i, s) in series.enumerated() {
                let pt = CGPoint(x: xOf(i, series.count - 1), y: yOf(s.rssi))
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            let end = CGPoint(x: right, y: yOf(series.last!.rssi))
            ctx.fill(Path(ellipseIn: CGRect(x: end.x - 2.3, y: end.y - 2.3, width: 4.6, height: 4.6)), with: .color(color))
        }
        .frame(height: height)
    }
}

/// Heard / not-heard spans over a time window (Timeline view).
struct PresenceTrack: View {
    var device: Sighting
    var now: Int
    var windowMs: Int
    var color: Color

    var body: some View {
        Canvas { ctx, size in
            let start = now - windowMs
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.08)))
            let last = device.presence.count - 1
            for (i, span) in device.presence.enumerated() {
                let open = span.end == nil || (!device.gone && i == last)
                let a = max(span.start, start)
                let b = min(open ? now : (span.end ?? now), now)
                if b <= a { continue }
                let x1 = CGFloat(a - start) / CGFloat(windowMs) * size.width
                let x2 = CGFloat(b - start) / CGFloat(windowMs) * size.width
                ctx.fill(Path(CGRect(x: x1, y: size.height * 0.25, width: max(abs(x2 - x1), 2), height: size.height * 0.5)),
                         with: .color(color.opacity(0.85)))
            }
        }
        .frame(height: 18)
    }
}
