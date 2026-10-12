// Renders the Fieldwatch radar icon (macOS rounded-square style) at 1024 px.
// Usage: swift scripts/make_icon.swift <out.png>
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgb(_ hex: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Background squircle (Apple grid: 824 px body, 100 px margin, ~185 px radius).
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.45))
ctx.addPath(shape); ctx.setFillColor(rgb(0x1E2328)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x2A3036), rgb(0x15191D)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

let c = CGPoint(x: 512, y: 512)
let green = 0x3DFF9A
// Sweep wedge: from 45° to 70° (up-right), fading toward the centre.
let r: CGFloat = 330
ctx.saveGState()
let wedge = CGMutablePath()
wedge.move(to: c)
wedge.addArc(center: c, radius: r, startAngle: .pi * 0.25, endAngle: .pi * 0.40, clockwise: false)
wedge.closeSubpath()
ctx.addPath(wedge); ctx.clip()
let sweep = CGGradient(colorsSpace: cs, colors: [rgb(green, 0.05), rgb(green, 0.55)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(sweep, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
ctx.restoreGState()

// Crosshair and inner rings.
ctx.setStrokeColor(rgb(green, 0.22)); ctx.setLineWidth(4)
ctx.move(to: CGPoint(x: c.x - r, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + r, y: c.y))
ctx.move(to: CGPoint(x: c.x, y: c.y - r)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + r)); ctx.strokePath()
for (rr, a) in [(220.0, 0.35), (110.0, 0.28)] as [(CGFloat, CGFloat)] {
    ctx.setStrokeColor(rgb(green, a)); ctx.setLineWidth(5)
    ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
}
// Outer ring with glow.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 28, color: rgb(green, 0.55))
ctx.setStrokeColor(rgb(green, 0.95)); ctx.setLineWidth(14)
ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
ctx.restoreGState()

// Leading edge of the sweep.
ctx.setStrokeColor(rgb(green, 0.9)); ctx.setLineWidth(6)
ctx.move(to: c); ctx.addLine(to: CGPoint(x: c.x + r * cos(.pi * 0.40), y: c.y + r * sin(.pi * 0.40))); ctx.strokePath()

// Centre hexagon.
let hexR: CGFloat = 26
let hex = CGMutablePath()
for i in 0..<6 {
    let a = CGFloat.pi / 2 + CGFloat(i) * .pi / 3
    let p = CGPoint(x: c.x + hexR * cos(a), y: c.y + hexR * sin(a))
    if i == 0 { hex.move(to: p) } else { hex.addLine(to: p) }
}
hex.closeSubpath()
ctx.addPath(hex); ctx.setStrokeColor(rgb(0xD5DCE3, 0.9)); ctx.setLineWidth(6); ctx.strokePath()

// Amber blip with glow.
let blip = CGPoint(x: c.x + 250 * cos(.pi * 0.30), y: c.y + 250 * sin(.pi * 0.30))
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 50, color: rgb(0xFFB020, 0.95))
ctx.setFillColor(rgb(0xFFB020))
ctx.fillEllipse(in: CGRect(x: blip.x - 24, y: blip.y - 24, width: 48, height: 48))
ctx.restoreGState()
ctx.setFillColor(rgb(0xFFE3A0)); ctx.fillEllipse(in: CGRect(x: blip.x - 10, y: blip.y - 10, width: 20, height: 20))
ctx.restoreGState()

// Hairline edge.
ctx.addPath(shape); ctx.setStrokeColor(rgb(0xFFFFFF, 0.08)); ctx.setLineWidth(3); ctx.strokePath()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
