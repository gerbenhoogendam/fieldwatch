import SwiftUI
import FieldwatchCore

// Port of ui/screen/HuntScreen.kt. On the Mac this is presented as a sheet from device detail.
// `onBack` closes it (the caller also calls vm.stopHunt(), as Kotlin's nav did).
// The Vibrate switch is Android-only and is not shown; `huntVibrate` is kept for the call shape and
// passed through to vm.huntTick (a no-op on macOS).

struct HuntScreen: View {
    var vm: FieldwatchViewModel
    var onBack: () -> Void
    var demoMode: Bool = false
    var huntBeep: Bool = false
    var huntVibrate: Bool = false

    @Environment(\.fw) var fw

    var body: some View {
        let hunt = vm.hunt
        VStack(spacing: 0) {
            topBar(hunt)
            Divider().overlay(fw.outline)
            readout(hunt)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            bottomBar(hunt)
        }
        .frame(minWidth: 380, idealWidth: 440, minHeight: 600, idealHeight: 700)
        .background(fw.background)
        // Kotlin LaunchedEffect(hunt.active, huntBeep, huntVibrate): geiger tick loop.
        .task(id: HuntTickKey(active: hunt.active, beep: huntBeep, vibrate: huntVibrate)) {
            await tickLoop()
        }
    }

    // MARK: Pieces

    private func topBar(_ hunt: HuntUi) -> some View {
        let shown = hunt.device.map { MacUtil.redactMacIn(text: hunt.title, mac: $0.mac, demo: demoMode) } ?? hunt.title
        return HStack(spacing: 8) {
            Text(shown.ifBlank("Hunt"))
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(shown)
            Spacer(minLength: 4)
            Button(action: onBack) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(fw.onSurfaceVariant)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Stop hunt")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(fw.surface)
    }

    private func readout(_ hunt: HuntUi) -> some View {
        let rssi = hunt.device?.rssi
        let accent = accentColor(hunt)
        let cue = cueColor(hunt.cue)
        return VStack(spacing: 0) {
            Text(Hunt.label(cue: hunt.cue))
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(cue)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
            Text(Hunt.hint(cue: hunt.cue))
                .font(.system(size: 13))
                .foregroundStyle(fw.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(height: 56, alignment: .top)
            Spacer().frame(height: 8)
            Text(rssi.map { "\($0)" } ?? "—")
                .font(FW.mono(72, weight: .bold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            Text(rssi.map { DeviceExplain.rssiExplain(rssi: $0) } ?? "no live RSSI")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(fw.onSurfaceVariant)
            Text(hunt.peakRssi > -127 ? "Loudest this hunt  \(hunt.peakRssi) dBm" : "Loudest this hunt  —")
                .font(FW.mono(13, weight: .regular))
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(heardAgoText(lastSeen: hunt.lastSeen, now: Int(ctx.date.timeIntervalSince1970 * 1000)))
                    .font(FW.mono(11, weight: .regular))
                    .foregroundStyle(fw.onSurfaceVariant)
            }
            Spacer().frame(height: 8)
            HuntNeedle(cue: hunt.cue, color: cue)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Spacer().frame(height: 8)
            Sparkline(samples: hunt.samples, color: accent, height: 72)
        }
    }

    private func bottomBar(_ hunt: HuntUi) -> some View {
        VStack(spacing: 8) {
            FieldwatchActionButton(enabled: hunt.active, action: { vm.resetHunt() }) {
                Spacer(minLength: 0)
                Text("Reset this hunt")
                Spacer(minLength: 0)
            }
            FieldwatchActionButton(action: onBack) {
                Spacer(minLength: 0)
                Text("Back to detail")
                Spacer(minLength: 0)
            }
            .keyboardShortcut(.cancelAction)
            FieldwatchSwitch(
                "Beep",
                subtitle: "Geiger tick on last-heard RSSI — faster when louder, silent when Quiet or Gone.",
                checked: huntBeep,
                onChange: { on in
                    vm.updateSettings { s in
                        var s = s
                        s.huntBeep = on
                        return s
                    }
                    if on { vm.huntTick(beepOn: true, vibrateOn: huntVibrate) }
                }
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Colors / text

    private func accentColor(_ hunt: HuntUi) -> Color {
        if let id = hunt.device?.fleetIds.first { return fw.tint(fleetColor(vm.fleetColor(id: id))) }
        if let rssi = hunt.device?.rssi { return fw.tint(rssiColor(rssi)) }
        return fw.primary
    }

    private func cueColor(_ cue: HuntCue) -> Color {
        switch cue {
        case .veryClose: return fw.tint(Color(hex: 0x7CFF3D))
        case .closer: return fw.tint(Color(hex: 0x3DFF9A))
        case .further: return fw.tint(Color(hex: 0xFF3D5A))
        case .same: return fw.onSurface
        case .waiting: return fw.onSurfaceVariant
        case .quiet: return fw.tint(Color(hex: 0xFFB020))
        case .gone: return fw.tint(Color(hex: 0xFF3D5A))
        }
    }

    private func heardAgoText(lastSeen: Int, now: Int) -> String {
        guard lastSeen > 0 else { return "last heard  —" }
        let ago = ((now - lastSeen) / 1000).coerceAtLeast(0)
        return ago < 60 ? "last heard \(ago)s ago" : "last heard \(ago / 60)m ago"
    }

    // MARK: Geiger tick

    @MainActor private func tickLoop() async {
        guard vm.hunt.active, huntBeep || huntVibrate else { return }
        var lastTick = 0
        while !Task.isCancelled {
            let live = vm.hunt
            guard let interval = Hunt.tickIntervalMs(rssi: live.device?.rssi, cue: live.cue) else {
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            let wait = interval - (nowMs() - lastTick)
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait.coerceAtMost(80)) * 1_000_000)
                continue
            }
            vm.huntTick(beepOn: huntBeep, vibrateOn: huntVibrate)
            lastTick = nowMs()
        }
    }
}

private struct HuntTickKey: Hashable {
    var active: Bool
    var beep: Bool
    var vibrate: Bool
}

/// Rings around YOU: contract on Closer / Very Close, expand on Further.
private struct HuntNeedle: View {
    @Environment(\.fw) var fw
    var cue: HuntCue
    var color: Color

    private var periodMs: Double {
        switch cue {
        case .veryClose: return 700
        case .closer: return 900
        case .further: return 1100
        case .same: return 2200
        case .waiting: return 1800
        case .quiet, .gone: return 2400
        }
    }

    var body: some View {
        TimelineView(.animation) { ctx in
            let ms = ctx.date.timeIntervalSinceReferenceDate * 1000
            let t = CGFloat(ms.truncatingRemainder(dividingBy: periodMs) / periodMs)
            Canvas { g, size in
                draw(g, size: size, t: t)
            }
        }
        .accessibilityLabel(Hunt.label(cue: cue))
    }

    private func draw(_ g: GraphicsContext, size: CGSize, t: CGFloat) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxR = min(size.width, size.height) * 0.42
        if maxR < 8 { return }
        func circle(_ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
        let ringIdle = fw.outline.opacity(0.35)
        for i in 1...3 {
            g.stroke(circle(maxR * CGFloat(i) / 3), with: .color(ringIdle), lineWidth: 1.4)
        }
        func pulse(_ frac: CGFloat, _ alpha: CGFloat, _ width: CGFloat) {
            let r = max(maxR * frac, 2)
            g.stroke(circle(r), with: .color(color.opacity(Double(alpha.coerceIn(0, 1)))), lineWidth: width)
        }
        func wrap(_ x: CGFloat) -> CGFloat { let m = x.truncatingRemainder(dividingBy: 1); return m < 0 ? m + 1 : m }
        switch cue {
        case .closer, .veryClose:
            for i in 0..<3 {
                let frac = wrap((1 - t) + CGFloat(i) / 3)
                pulse(frac, (1 - frac) * 0.85, cue == .veryClose ? 5.5 : 4)
            }
            if cue == .veryClose {
                g.fill(circle(maxR * 0.22), with: .color(color.opacity(Double(0.22 + 0.18 * (1 - t)))))
            }
        case .further:
            for i in 0..<3 {
                let frac = wrap(t + CGFloat(i) / 3)
                pulse(frac, (1 - frac) * 0.85, 4)
            }
        case .same: pulse(0.55, 0.55, 3.2)
        case .waiting: pulse(0.4 + 0.2 * t, 0.35, 2.6)
        case .quiet: pulse(0.72, 0.4, 2.8)
        case .gone: pulse(0.88, 0.28, 2.2)
        }
        g.fill(circle(5.5), with: .color(color.opacity(0.95)))
        let you = g.resolve(Text("YOU").font(FW.mono(11, weight: .bold)).foregroundColor(fw.onSurface))
        g.draw(you, at: CGPoint(x: c.x, y: c.y + 10), anchor: .top)
    }
}
