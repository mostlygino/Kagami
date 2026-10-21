// make-installer-art.swift <outdir> <version>
// Draws the DMG window background and the Installer side art, at 1x and 2x, in the Verdigris theme.
//
// The DMG ground sits at verdigris #4F7F78 where Finder writes the icon names: Finder draws them black in
// light mode and white in dark mode, and that one tone gives both 4.5:1. The edges fall away darker.
import AppKit

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "build/installer-art")
let version = args.count > 2 ? args[2] : "0.1.0"
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let icon = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

/// Renders `draw` into a PNG at `scale`, in points with a top-left origin.
func render(_ name: String, size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    draw(cg)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

func text(_ s: String, _ font: NSFont, _ color: NSColor, at p: CGPoint, align: NSTextAlignment = .center, width: CGFloat = 600, kern: CGFloat = 0) {
    let style = NSMutableParagraphStyle()
    style.alignment = align
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style, .kern: kern]
    let x = align == .center ? p.x - width / 2 : p.x
    NSAttributedString(string: s, attributes: attrs).draw(in: CGRect(x: x, y: p.y, width: width, height: font.pointSize * 1.6))
}

/// The RFC ruler: tens over units, one column per bit, as Kagami draws packet headers.
func ruler(_ cg: CGContext, x: CGFloat, y: CGFloat, width: CGFloat, color: NSColor, tens: NSColor) {
    let w = width / 32
    let small = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .regular)
    let strong = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .semibold)
    for bit in 0..<32 {
        let cx = x + CGFloat(bit) * w + w / 2
        if bit % 10 == 0 { text("\(bit / 10)", strong, tens, at: CGPoint(x: cx, y: y), width: 20) }
        text("\(bit % 10)", small, color, at: CGPoint(x: cx, y: y + 11), width: 20)
    }
    cg.setStrokeColor(color.withAlphaComponent(color.alphaComponent * 0.8).cgColor)
    cg.setLineWidth(0.5)
    cg.stroke(CGRect(x: x, y: y + 26, width: width, height: 14))
    for i in stride(from: 8, to: 32, by: 8) {
        let lx = x + CGFloat(i) * w
        cg.move(to: CGPoint(x: lx, y: y + 26)); cg.addLine(to: CGPoint(x: lx, y: y + 40))
    }
    cg.strokePath()
}

/// Fine speckle, like the crust on an old bronze mirror; seeded so every build draws the same.
func patina(_ cg: CGContext, in r: CGRect, count: Int, alpha: CGFloat) {
    var seed: UInt64 = 0x6B61_6761_6D69
    func next() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
    for _ in 0..<count {
        let p = CGPoint(x: r.minX + next() * r.width, y: r.minY + next() * r.height)
        let d = 0.6 + next() * 1.6
        cg.setFillColor((next() > 0.5 ? NSColor.white : hex(0x0E2420)).withAlphaComponent(alpha * next()).cgColor)
        cg.fillEllipse(in: CGRect(x: p.x, y: p.y, width: d, height: d))
    }
}

// MARK: DMG window, 660 × 420 points

let dmg = CGSize(width: 660, height: 420)
for (name, scale) in [("dmg-background.png", 1.0), ("dmg-background@2x.png", 2.0)] {
    render(name, size: dmg, scale: scale) { cg in
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        // Ground: label tone in the middle band, deeper verdigris at the edges.
        let ground = CGGradient(colorsSpace: space, colors: [hex(0x56877F).cgColor, hex(0x4F7F78).cgColor, hex(0x2B4E49).cgColor, hex(0x1A312E).cgColor] as CFArray,
                                locations: [0, 0.42, 0.82, 1])!
        cg.drawRadialGradient(ground, startCenter: CGPoint(x: 330, y: 215), startRadius: 0, endCenter: CGPoint(x: 330, y: 215), endRadius: 430,
                              options: [.drawsAfterEndLocation])
        patina(cg, in: CGRect(origin: .zero, size: dmg), count: 2600, alpha: 0.10)
        // Mirror sheen: one soft diagonal of light across the top.
        cg.saveGState()
        cg.clip(to: CGRect(origin: .zero, size: dmg))
        let sheen = CGGradient(colorsSpace: space, colors: [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.10).cgColor,
                                                            NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.5, 1])!
        cg.drawLinearGradient(sheen, start: CGPoint(x: 120, y: -40), end: CGPoint(x: 300, y: 150), options: [])
        cg.restoreGState()

        // Title.
        text("Kagami", .systemFont(ofSize: 26, weight: .semibold), .white, at: CGPoint(x: 330, y: 34), kern: 0.3)
        text("鏡  ·  See what is on the wire", .systemFont(ofSize: 12.5, weight: .medium), NSColor.white.withAlphaComponent(0.78), at: CGPoint(x: 330, y: 72))

        // The gesture: a bronze arc from the app to Applications, between the two icons Finder draws at y = 205.
        cg.setStrokeColor(hex(0xE2B576).cgColor)
        cg.setLineWidth(3)
        cg.setLineCap(.round)
        cg.setLineDash(phase: 0, lengths: [0.1, 8])
        cg.move(to: CGPoint(x: 258, y: 200))
        cg.addQuadCurve(to: CGPoint(x: 394, y: 200), control: CGPoint(x: 326, y: 168))
        cg.strokePath()
        cg.setLineDash(phase: 0, lengths: [])
        cg.setFillColor(hex(0xE2B576).cgColor)
        cg.move(to: CGPoint(x: 406, y: 204)); cg.addLine(to: CGPoint(x: 391, y: 192)); cg.addLine(to: CGPoint(x: 393, y: 208)); cg.closePath()
        cg.fillPath()
        text("Drag to Applications", .systemFont(ofSize: 12, weight: .semibold), NSColor.white.withAlphaComponent(0.92), at: CGPoint(x: 330, y: 222))

        // Footer: the RFC ruler, then the colophon; kept clear of the bottom 30 pt in case Finder's bounds include the title bar.
        ruler(cg, x: 70, y: 304, width: 520, color: NSColor.white.withAlphaComponent(0.30), tens: hex(0xE2B576, 0.8))
        text("Version \(version)   ·   AGPL-3.0   ·   mostlygino.com", .systemFont(ofSize: 10.5, weight: .regular),
             NSColor.white.withAlphaComponent(0.6), at: CGPoint(x: 330, y: 366))
    }
}

// MARK: Installer, 620 × 418 points; Installer pins it bottom-left behind the step list

let pkg = CGSize(width: 620, height: 418)
for dark in [false, true] {
    for scale in [1.0, 2.0] {
        let name = "installer-\(dark ? "dark" : "light")\(scale == 2 ? "@2x" : "").png"
        render(name, size: pkg, scale: scale) { cg in
            // Only the lower left carries art; the rest stays clear so Installer's own panel reads as usual.
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let tint = dark ? hex(0x3FB8A6) : hex(0x127F6E)
            let glow = CGGradient(colorsSpace: space, colors: [tint.withAlphaComponent(dark ? 0.22 : 0.16).cgColor, tint.withAlphaComponent(0).cgColor] as CFArray,
                                  locations: [0, 1])!
            cg.drawRadialGradient(glow, startCenter: CGPoint(x: 70, y: 360), startRadius: 0, endCenter: CGPoint(x: 70, y: 360), endRadius: 230, options: [])
            if let icon {
                icon.draw(in: CGRect(x: 26, y: 262, width: 104, height: 104), from: .zero, operation: .sourceOver, fraction: 1,
                          respectFlipped: true, hints: nil)
            }
            let ink = dark ? NSColor.white : hex(0x121719)
            text("Kagami", .systemFont(ofSize: 15, weight: .semibold), ink.withAlphaComponent(0.85), at: CGPoint(x: 26, y: 372), align: .left, width: 160)
            text("Version \(version)", .systemFont(ofSize: 10.5), ink.withAlphaComponent(0.55), at: CGPoint(x: 26, y: 392), align: .left, width: 160)
        }
    }
}
print("art in \(out.path)")
