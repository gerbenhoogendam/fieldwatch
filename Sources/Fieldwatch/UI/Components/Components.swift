import SwiftUI
import FieldwatchCore

// Ports of ui/component/*.kt and ui/ClassGlyphs.kt, NestedTabChrome.kt.

// MARK: - Class glyphs

enum ClassGlyphs {
    static let unmatched = "questionmark"

    /// SF Symbol for a signature class (Material icon equivalents).
    static func of(_ kind: SignatureClass?) -> String {
        guard let kind else { return unmatched }
        switch kind {
        case .finder: return "tag"
        case .beacon: return "dot.radiowaves.left.and.right"
        case .signage: return "storefront"
        case .wearable, .bodyworn: return "applewatch"
        case .surveillance: return "video"
        case .drone: return "airplane"
        case .hacking: return "ladybug"
        case .lawEnforcement: return "shield.lefthalf.filled"
        case .vehicle: return "car"
        case .glasses: return "eyeglasses"
        case .audio: return "headphones"
        case .camera: return "camera"
        case .thermostat: return "thermometer.medium"
        case .lock: return "lock"
        case .health: return "cross.case"
        case .home: return "house"
        case .isp: return "wifi.router"
        case .mesh: return "point.3.connected.trianglepath.dotted"
        case .phone: return "iphone"
        case .other: return "square.grid.2x2"
        }
    }
}

/// Class glyph in a tinted circle.
struct RadioClassBadge: View {
    var classKind: SignatureClass?
    var accent: Color
    var compact: Bool = false

    var body: some View {
        let d: CGFloat = compact ? 26 : 28
        ZStack {
            Circle().fill(accent.opacity(0.18))
            Image(systemName: ClassGlyphs.of(classKind))
                .font(.system(size: compact ? 12 : 13, weight: .medium))
                .foregroundStyle(accent)
        }
        .frame(width: d, height: d)
        .accessibilityLabel(classKind?.label() ?? "Unmatched")
    }
}

/// The Bluetooth rune (SF Symbols has none).
struct BluetoothShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        let x0 = r.minX + w * 0.28, x1 = r.minX + w * 0.5, x2 = r.minX + w * 0.74
        let top = r.minY + h * 0.06, bot = r.minY + h * 0.94
        let y1 = r.minY + h * 0.30, y2 = r.minY + h * 0.70
        p.move(to: CGPoint(x: x0, y: y1))
        p.addLine(to: CGPoint(x: x2, y: y2))
        p.addLine(to: CGPoint(x: x1, y: bot))
        p.addLine(to: CGPoint(x: x1, y: top))
        p.addLine(to: CGPoint(x: x2, y: y1))
        p.addLine(to: CGPoint(x: x0, y: y2))
        return p
    }
}

struct BluetoothGlyph: View {
    var size: CGFloat = 12
    var body: some View {
        BluetoothShape()
            .stroke(style: StrokeStyle(lineWidth: max(1.1, size / 9), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

/// Small Wi-Fi or Bluetooth mark at the start of a row's second line.
struct RadioKindMark: View {
    @Environment(\.fw) var fw
    var kind: RadioKind
    var size: CGFloat = 12
    var tint: Color? = nil

    var body: some View {
        Group {
            if kind == .wifi {
                Image(systemName: "wifi").font(.system(size: size * 0.85, weight: .semibold))
            } else {
                BluetoothGlyph(size: size)
            }
        }
        .foregroundStyle(tint ?? fw.onSurfaceVariant)
        .frame(width: size, height: size)
        .accessibilityLabel(kind == .wifi ? "Wi-Fi access point" : "BLE advertiser")
    }
}

/// Pointy hexagon — hex bytes in a packet. Decode-map mark on Live / detail.
struct DecodeGlyph: View {
    var tint: Color
    var size: CGFloat = 12

    var body: some View {
        Canvas { ctx, s in
            let r = min(s.width, s.height) / 2 - 0.8
            let c = CGPoint(x: s.width / 2, y: s.height / 2)
            var hex = Path()
            for i in 0...5 {
                let a = -Double.pi / 2 + Double(i) * Double.pi / 3
                let pt = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                if i == 0 { hex.move(to: pt) } else { hex.addLine(to: pt) }
            }
            hex.closeSubpath()
            ctx.stroke(hex, with: .color(tint), style: StrokeStyle(lineWidth: 1.35, lineCap: .round))
            let d = r * 0.44
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)), with: .color(tint))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Decode fields")
    }
}

// MARK: - Buttons, chips, switches, fields

/// Action button: section-tile green, darkened; gray outline, off-white label.
struct FieldwatchActionButtonStyle: ButtonStyle {
    @Environment(\.fw) var fw
    @Environment(\.isEnabled) var enabled
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(enabled ? (prominent ? fw.primary : fw.onSurface) : fw.onSurface.opacity(0.38))
            .background(
                RoundedRectangle(cornerRadius: 999)
                    .fill(configuration.isPressed ? fw.sectionFill : fw.tileFill.opacity(enabled ? 1 : 0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 999)
                    .stroke(prominent ? fw.active : fw.tileEdge.opacity(enabled ? 1 : 0.4), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 999))
    }
}

struct FieldwatchActionButton<Label: View>: View {
    var enabled = true
    var prominent = false
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    init(enabled: Bool = true, prominent: Bool = false, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.enabled = enabled; self.prominent = prominent; self.action = action; self.label = label
    }

    var body: some View {
        Button(action: action) { HStack(spacing: 6) { label() } }
            .buttonStyle(FieldwatchActionButtonStyle(prominent: prominent))
            .disabled(!enabled)
    }
}

extension FieldwatchActionButton where Label == Text {
    init(_ title: String, enabled: Bool = true, prominent: Bool = false, action: @escaping () -> Void) {
        self.init(enabled: enabled, prominent: prominent, action: action) { Text(title) }
    }
}

/// Toggle chip. Unselected: dark fill + gray outline. Selected: section fill + phosphor outline.
struct FieldwatchFilterChip<Leading: View>: View {
    @Environment(\.fw) var fw
    var selected: Bool
    var enabled = true
    var action: () -> Void
    var label: String
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(fw.active)
                }
                leading()
                Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .foregroundStyle(fw.onSurface.opacity(enabled ? 1 : 0.38))
            .background(RoundedRectangle(cornerRadius: 8).fill((selected ? fw.sectionFill : fw.tileFill).opacity(enabled ? 1 : 0.4)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke((selected ? fw.active : fw.tileEdge).opacity(enabled ? 1 : 0.4), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

extension FieldwatchFilterChip where Leading == EmptyView {
    init(selected: Bool, enabled: Bool = true, label: String, action: @escaping () -> Void) {
        self.init(selected: selected, enabled: enabled, action: action, label: label) { EmptyView() }
    }
}

/// Phosphor-track switch.
struct FieldwatchToggleStyle: ToggleStyle {
    @Environment(\.fw) var fw
    @Environment(\.isEnabled) var enabled

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? fw.active.opacity(enabled ? 1 : 0.38) : fw.tileFill.opacity(enabled ? 1 : 0.4))
                    .overlay(Capsule().stroke(fw.tileEdge.opacity(enabled ? 1 : 0.4), lineWidth: 1))
                    .frame(width: 34, height: 20)
                Circle()
                    .fill(configuration.isOn ? fw.onPrimary : fw.onSurfaceVariant)
                    .frame(width: configuration.isOn ? 14 : 11, height: configuration.isOn ? 14 : 11)
                    .padding(.horizontal, configuration.isOn ? 3 : 4.5)
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isOn)
            .contentShape(Capsule())
            .onTapGesture { if enabled { configuration.isOn.toggle() } }
        }
    }
}

/// Labelled switch row (Kotlin rows of Text + FieldwatchSwitch).
struct FieldwatchSwitch: View {
    @Environment(\.fw) var fw
    var title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(fw.onSurface.opacity(enabled ? 1 : 0.5))
                if let subtitle, subtitle.isNotEmpty {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(FieldwatchToggleStyle())
        .disabled(!enabled)
    }
}

extension FieldwatchSwitch {
    /// Value + callback form, like Compose `checked` / `onCheckedChange`.
    init(_ title: String, subtitle: String? = nil, checked: Bool, enabled: Bool = true, onChange: @escaping (Bool) -> Void) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = Binding(get: { checked }, set: { onChange($0) })
        self.enabled = enabled
    }
}

/// Outlined text field with a small label above.
struct FieldwatchOutlinedField: View {
    @Environment(\.fw) var fw
    var label: String
    @Binding var text: String
    var placeholder: String? = nil
    var supportingText: String? = nil
    var singleLine = true
    var minLines = 1
    var enabled = true
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant)
            Group {
                if singleLine {
                    TextField(placeholder ?? "", text: $text)
                } else {
                    TextField(placeholder ?? "", text: $text, axis: .vertical)
                        .lineLimit(max(minLines, 2)...12)
                }
            }
            .textFieldStyle(.plain)
            .font(monospaced ? FW.mono(12) : .system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).fill(fw.background.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(fw.outline.opacity(1), lineWidth: 1))
            .disabled(!enabled)
            if let supportingText {
                Text(supportingText).font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant)
            }
        }
    }
}

/// Labelled dropdown (Compose ExposedDropdownMenuBox + FieldwatchDropdownField).
struct FieldwatchDropdownField<T: Hashable>: View {
    @Environment(\.fw) var fw
    var label: String
    var options: [T]
    var selection: T
    var title: (T) -> String
    var onSelect: (T) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant)
            Menu {
                ForEach(options, id: \.self) { opt in
                    Button {
                        onSelect(opt)
                    } label: {
                        if opt == selection { Label(title(opt), systemImage: "checkmark") } else { Text(title(opt)) }
                    }
                }
            } label: {
                HStack {
                    Text(title(selection)).font(.system(size: 12)).foregroundStyle(fw.onSurface)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(fw.onSurfaceVariant)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(fw.background.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(fw.outline, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
    }
}

/// Phosphor slider.
struct FieldwatchSlider: View {
    @Environment(\.fw) var fw
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double? = nil
    var enabled = true
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        Group {
            if let step {
                Slider(value: $value, in: range, step: step, onEditingChanged: onEditingChanged)
            } else {
                Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
            }
        }
        .tint(fw.active)
        .disabled(!enabled)
    }
}

/// Grouped settings/filter block. Same surface bar as Signatures class headers.
struct SectionCard<Content: View>: View {
    @Environment(\.fw) var fw
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(fw.onSurface)
            if let subtitle {
                Text(subtitle).font(.system(size: 11)).foregroundStyle(fw.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(fw.sectionFill))
    }
}

/// Inner page header (Kotlin NestedTopBar).
struct NestedTopBar<Actions: View>: View {
    @Environment(\.fw) var fw
    var title: String
    var onBack: (() -> Void)? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 8) {
            if let onBack {
                Button(action: onBack) { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .foregroundStyle(fw.onSurface)
                    .keyboardShortcut(.cancelAction)
            }
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            actions()
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }
}

extension NestedTopBar where Actions == EmptyView {
    init(title: String, onBack: (() -> Void)? = nil) {
        self.init(title: title, onBack: onBack) { EmptyView() }
    }
}

/// Small rounded label used for signature names on rows.
struct SignatureChip: View {
    var text: String
    var color: Color
    var emphasis = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(emphasis ? Color.black.opacity(0.85) : color)
            .background(RoundedRectangle(cornerRadius: 4).fill(emphasis ? color : color.opacity(0.16)))
    }
}

/// A row of wrapping content (Compose FlowRow).
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { y += lineH + lineSpacing; x = 0; lineH = 0 }
            x += s.width + spacing
            lineH = max(lineH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += lineH + lineSpacing; x = bounds.minX; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}
