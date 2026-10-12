import SwiftUI
import FieldwatchCore

// Port of ui/theme/Theme.kt + NightColor.kt. The UI is always dark; Night mode is the red field display.

extension Color {
    /// 0xAARRGGBB, the format the Kotlin palette uses.
    init(argb: Int) {
        let a = Double((argb >> 24) & 0xFF) / 255
        let r = Double((argb >> 16) & 0xFF) / 255
        let g = Double((argb >> 8) & 0xFF) / 255
        let b = Double(argb & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// 0xRRGGBB, opaque.
    init(hex: Int) { self.init(argb: 0xFF00_0000 | hex) }

    var argb: Int {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let a = Int((ns.alphaComponent * 255).rounded())
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return (a << 24) | (r << 16) | (g << 8) | b
    }

    /// Kotlin `nightIf(night)`: identity off, red luminance ramp on.
    func nightIf(_ night: Bool) -> Color { night ? Color(argb: nightForegroundArgb(argb)) : self }

    /// Kotlin `lerp(a, b, t)`.
    static func lerp(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let x = NSColor(a).usingColorSpace(.sRGB) ?? .black
        let y = NSColor(b).usingColorSpace(.sRGB) ?? .black
        func m(_ p: CGFloat, _ q: CGFloat) -> Double { Double(p) + (Double(q) - Double(p)) * t }
        return Color(.sRGB, red: m(x.redComponent, y.redComponent), green: m(x.greenComponent, y.greenComponent),
                     blue: m(x.blueComponent, y.blueComponent), opacity: m(x.alphaComponent, y.alphaComponent))
    }
}

/// Map any sRGB color to a red luminance ramp. Relative brightness is kept so class chips stay distinguishable.
func nightForegroundArgb(_ argb: Int) -> Int {
    let a = (argb >> 24) & 0xFF
    let r = Double((argb >> 16) & 0xFF)
    let g = Double((argb >> 8) & 0xFF)
    let b = Double(argb & 0xFF)
    let y = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
    let nr = (0.40 + 0.60 * y).coerceIn(0, 1)
    let ng = (0.05 + 0.16 * y).coerceIn(0, 1)
    let nb = (0.05 + 0.10 * y).coerceIn(0, 1)
    return (a << 24) | ((Int(nr * 255) & 0xFF) << 16) | ((Int(ng * 255) & 0xFF) << 8) | (Int(nb * 255) & 0xFF)
}

enum FW {
    static let phosphor = Color(hex: 0x3DFF9A)
    /// Checked switch / slider fill — same hue as Phosphor, less neon.
    static let phosphorActive = Color(hex: 0x35D683)
    static let amber = Color(hex: 0xFFB020)
    static let signalRed = Color(hex: 0xFF3D5A)
    static let cyan = Color(hex: 0x4FC3F7)
    static let night = Color(hex: 0x0B0F14)
    static let panel = Color(hex: 0x141A22)
    static let panel2 = Color(hex: 0x1B232D)

    /// Kotlin `Mono` text style.
    static func mono(_ size: CGFloat = 12, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Material color scheme roles used by the Compose screens.
struct FWScheme: Equatable {
    var night: Bool
    var primary: Color
    var onPrimary: Color
    var primaryContainer: Color
    var onPrimaryContainer: Color
    var secondary: Color
    var tertiary: Color
    var background: Color
    var onBackground: Color
    var surface: Color
    var onSurface: Color
    var surfaceVariant: Color
    var onSurfaceVariant: Color
    var outline: Color
    var error: Color

    static let dark = FWScheme(
        night: false,
        primary: FW.phosphor, onPrimary: Color(hex: 0x003820),
        primaryContainer: Color(hex: 0x163326), onPrimaryContainer: FW.phosphor,
        secondary: FW.amber, tertiary: FW.cyan,
        background: FW.night, onBackground: Color(hex: 0xD5DCE3),
        surface: FW.panel, onSurface: Color(hex: 0xD5DCE3),
        surfaceVariant: FW.panel2, onSurfaceVariant: Color(hex: 0x9AA6B2),
        outline: Color(hex: 0x2A3340), error: FW.signalRed
    )

    /// Red-on-black field display. Background stays dark; chrome and accents are red ramps.
    static let nightMode = FWScheme(
        night: true,
        primary: Color(hex: 0xFF5A5A), onPrimary: Color(hex: 0x2A0808),
        primaryContainer: Color(hex: 0x3A1212), onPrimaryContainer: Color(hex: 0xFF8A8A),
        secondary: Color(hex: 0xE07070), tertiary: Color(hex: 0xCC6666),
        background: Color(hex: 0x0B0808), onBackground: Color(hex: 0xFFC9C9),
        surface: Color(hex: 0x161010), onSurface: Color(hex: 0xFFC9C9),
        surfaceVariant: Color(hex: 0x1E1414), onSurfaceVariant: Color(hex: 0xC48A8A),
        outline: Color(hex: 0x5A3030), error: Color(hex: 0xFF7A7A)
    )

    /// Material `surfaceColorAtElevation(1.dp)`: surface tinted 5% toward primary.
    var sectionFill: Color { Color.lerp(surface, primary, 0.05) }
    /// Section-tile green, darkened. Shared by action buttons and switch tracks.
    var tileFill: Color { Color.lerp(.black, sectionFill, 0.78) }
    /// Gray outline shared by action buttons and switches.
    var tileEdge: Color { Color.lerp(outline, onSurfaceVariant, 0.32) }
    var active: Color { FW.phosphorActive.nightIf(night) }

    /// Any data color (class accent, RSSI ramp) through the night filter.
    func tint(_ c: Color) -> Color { c.nightIf(night) }
}

private struct FWSchemeKey: EnvironmentKey { static let defaultValue = FWScheme.dark }

extension EnvironmentValues {
    var fw: FWScheme {
        get { self[FWSchemeKey.self] }
        set { self[FWSchemeKey.self] = newValue }
    }
}

extension View {
    /// Kotlin `FieldwatchTheme(nightMode:)`.
    func fieldwatchTheme(nightMode: Bool) -> some View {
        let scheme = nightMode ? FWScheme.nightMode : FWScheme.dark
        return self
            .environment(\.fw, scheme)
            .tint(scheme.primary)
            .foregroundStyle(scheme.onSurface)
            .preferredColorScheme(.dark)
    }
}

/// Palette slot for a signature color index.
func fleetColor(_ index: Int) -> Color { Color(argb: Palette.color(index: index)) }
