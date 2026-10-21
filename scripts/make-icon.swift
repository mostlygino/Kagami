// Renders the Kagami app icon (and its four alternates) and writes the icon set.
//
//   swiftc -O scripts/make-icon.swift -o /tmp/kagami-icon
//   /tmp/kagami-icon <AppIcon.iconset|AppIcon.appiconset> [--variant <name>] [--brand <folder>]
//
// 鏡 (kagami), a mirror. Kagami shows you the wire as it is. The icon is the
// back of a Japanese bronze mirror (鏡背, kyōhai) on a hinoki board, cast like
// the sankakuen mirrors from the kofun: a knob with a silk cord through it, a
// lotus seat, a carrier wave, three tracks of packets, a comb band that is a
// bit ruler (every eighth tooth a byte), a sawtooth ring and a rim of
// triangular section. Hands have rubbed the rim and knob back to gold;
// verdigris crusts everything they never reach.
//
// Not drawn with gradients: a small renderer, the same one Shīru uses. Every
// surface is a height field lit by one window high to the left. Normals come
// from the heights, shadows are marched toward the window, and metal, lacquer
// and water reflect an analytic room (the window, a dim wall, a paper lamp low
// on the right), so reflections bend with the surface by themselves. Run it
// optimised: it does real work.
//
//   --variant  kyohai (default), yata, mizu, urushi, tekagami
//   --brand    also write every variant, the brand sheet, the alternates sheet
//              and the lockups as PNG
//
// No SF Symbols: their licence does not allow use in app icons. 鏡 comes from
// Hiragino Mincho as an outline and is rasterised; no font is embedded or shipped.

import AppKit

// MARK: Tokens

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let sumi = rgb(0x121011)         // lacquer black, dark surface
let paper = rgb(0xF7F4EE)        // light surface
let surface = rgb(0xF0EDE8)      // brand sheet ground
let rokushoCG = rgb(0x2F8F7A)    // 緑青, verdigris: the product colour

/// How much a size can carry: no packet rows below 128, no chips or grain below 256.
enum Detail: Int, Comparable {
    case glyph = 0, mark, full
    init(pixels: CGFloat) { self = pixels <= 64 ? .glyph : pixels <= 160 ? .mark : .full }
    static func < (a: Detail, b: Detail) -> Bool { a.rawValue < b.rawValue }
}

// MARK: Vectors

struct V3 {
    var x: Float, y: Float, z: Float
    static func + (a: V3, b: V3) -> V3 { V3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func * (a: V3, s: Float) -> V3 { V3(x: a.x * s, y: a.y * s, z: a.z * s) }
    static func * (a: V3, b: V3) -> V3 { V3(x: a.x * b.x, y: a.y * b.y, z: a.z * b.z) }
    func dot(_ b: V3) -> Float { x * b.x + y * b.y + z * b.z }
    var normalised: V3 { self * (1 / dot(self).squareRoot()) }
}

func mix(_ a: V3, _ b: V3, _ t: Float) -> V3 { a * (1 - t) + b * t }
func clamp01(_ v: Float) -> Float { min(max(v, 0), 1) }
func smoothstep(_ a: Float, _ b: Float, _ v: Float) -> Float {
    let t = clamp01((v - a) / (b - a))
    return t * t * (3 - 2 * t)
}
func colour(_ hex: UInt32) -> V3 {
    V3(x: Float(hex >> 16 & 0xFF) / 255, y: Float(hex >> 8 & 0xFF) / 255, z: Float(hex & 0xFF) / 255)
}

let white = V3(x: 1, y: 0.97, z: 0.92)
let hakudo = V3(x: 0.93, y: 0.92, z: 0.89)    // 白銅, white bronze: the mirror face
let bronze = colour(0xA87A45)
let bronzeDark = colour(0x7A5532)
let bronzeWorn = colour(0xE0AE6C)
let verdigris = colour(0x4E9A82)
let lacquerBase = colour(0x110D0B)
let rokusho = colour(0x2F8F7A)
/// Wireshark-style protocol colours, the same code the app uses: TCP, TLS, DNS, UDP.
let protocolColours = [colour(0x5AC8FA), colour(0xFF9F0A), colour(0x30D158), colour(0xBF5AF2)]

/// The window. Buffer space: x right, y down, z out of the screen.
let light = V3(x: -0.5, y: -0.62, z: 0.6).normalised
let halfway = (light + V3(x: 0, y: 0, z: 1)).normalised
/// Where shadows fall: away from the window, down and to the right.
let away: (x: Float, y: Float) = {
    let l = (light.x * light.x + light.y * light.y).squareRoot()
    return (-light.x / l, -light.y / l)
}()

// MARK: Fields

/// A square grid of floats, row 0 at the top (as CGBitmapContext stores it).
struct Field {
    let n: Int
    var v: [Float]
    init(_ n: Int, _ fill: Float = 0) { self.n = n; v = [Float](repeating: fill, count: n * n) }
    init(_ n: Int, _ v: [Float]) { self.n = n; self.v = v }
    subscript(x: Int, y: Int) -> Float { v[min(max(y, 0), n - 1) * n + min(max(x, 0), n - 1)] }
    func map(_ f: (Float) -> Float) -> Field { Field(n, v.map(f)) }
}

/// Rasterises a drawing in 1024-unit, y-up coordinates into an n×n coverage field.
func coverage(_ n: Int, _ draw: (CGContext) -> Void) -> Field {
    var bytes = [UInt8](repeating: 0, count: n * n)
    bytes.withUnsafeMutableBytes { p in
        let ctx = CGContext(data: p.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.scaleBy(x: CGFloat(n) / 1024, y: CGFloat(n) / 1024)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setStrokeColor(gray: 1, alpha: 1)
        draw(ctx)
    }
    return Field(n, bytes.map { Float($0) / 255 })
}

/// Three box passes each way, close to a gaussian of the given radius in pixels.
func blur(_ f: Field, _ radius: Float) -> Field {
    let k = Int((radius / 1.7).rounded())
    guard k >= 1 else { return f }
    let n = f.n, norm = 1 / Float(2 * k + 1)
    var a = f.v, b = f.v
    for _ in 0..<3 {
        for stride in [1, n] {
            a.withUnsafeBufferPointer { s in
                b.withUnsafeMutableBufferPointer { d in
                    for line in 0..<n {
                        let base = stride == 1 ? line * n : line
                        func at(_ i: Int) -> Float { s[base + min(max(i, 0), n - 1) * stride] }
                        var sum: Float = 0
                        for i in -k...k { sum += at(i) }
                        for i in 0..<n {
                            d[base + i * stride] = sum * norm
                            sum += at(i + k + 1) - at(i - k)
                        }
                    }
                }
            }
            swap(&a, &b)
        }
    }
    return Field(n, a)
}

/// Moves a field by whole pixels (right and down positive), edges clamped.
func shifted(_ f: Field, _ dx: Float, _ dy: Float) -> Field {
    let n = f.n, ox = Int(dx.rounded()), oy = Int(dy.rounded())
    var out = Field(n)
    for y in 0..<n { for x in 0..<n { out.v[y * n + x] = f[x - ox, y - oy] } }
    return out
}

/// The shadow an object casts on the ground, and the tight contact shadow at its foot.
func shadows(_ cover: Field, _ u: Float, distance: Float = 24, softness: Float = 32) -> (cast: Field, contact: Field) {
    (blur(shifted(cover, away.x * distance * u, away.y * distance * u), softness * u),
     blur(shifted(cover, away.x * 4 * u, away.y * 4 * u), 5 * u))
}

// MARK: Noise, deterministic so every run draws the same icon

struct Random {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 33) / CGFloat(1 << 31)
    }
    mutating func range(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { lo + (hi - lo) * next() }
}

func hash(_ x: Int, _ y: Int, _ seed: Int) -> Float {
    var h = UInt64(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263 &+ seed &* 2147483647)
    h = (h ^ (h >> 13)) &* 1274126177
    h ^= h >> 16
    return Float(h & 0xFFFF) / 65535 * 2 - 1
}

/// Smooth value noise, -1...1, summed over octaves. `cell` is the coarsest feature in pixels.
func fbm(_ n: Int, cell: Float, octaves: Int, seed: Int) -> Field {
    var out = Field(n)
    var amp: Float = 1, size = max(cell, 1), total: Float = 0
    for o in 0..<octaves {
        let s = seed &+ o &* 101
        for y in 0..<n {
            let fy = Float(y) / size, iy = Int(fy.rounded(.down)), ty = smoothstep(0, 1, fy - Float(iy))
            for x in 0..<n {
                let fx = Float(x) / size, ix = Int(fx.rounded(.down)), tx = smoothstep(0, 1, fx - Float(ix))
                let top = hash(ix, iy, s) * (1 - tx) + hash(ix + 1, iy, s) * tx
                let bottom = hash(ix, iy + 1, s) * (1 - tx) + hash(ix + 1, iy + 1, s) * tx
                out.v[y * n + x] += amp * (top * (1 - ty) + bottom * ty)
            }
        }
        total += amp
        amp *= 0.5
        size = max(size / 2, 1)
    }
    return out.map { $0 / total }
}

// MARK: Shapes (1024 units, y up)

/// A character as an outline, centred on the origin, `height` tall.
func kanjiPath(_ character: String, height: CGFloat) -> CGPath {
    let font = CTFontCreateWithName("HiraMinProN-W6" as CFString, height * 1.18, nil)
    var chars = Array(character.utf16), glyphs = [CGGlyph](repeating: 0, count: 1)
    guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1), let glyph = CTFontCreatePathForGlyph(font, glyphs[0], nil)
    else { fatalError("Hiragino Mincho ProN W6 with \(character) is needed to draw the icon") }
    let box = glyph.boundingBoxOfPath
    var move = CGAffineTransform(translationX: -box.midX, y: -box.midY)
    return glyph.copy(using: &move)!
}

func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
}

func polar(_ c: CGPoint, _ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r) }

/// The tile, on the macOS grid: 824 in 1024, corner radius about 185.
let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)

// MARK: The room every surface reflects

/// Coordinates are canvas fractions, y down. A flat mirror shows the room where
/// it stands (a planar reflection); a tilted surface looks further across it.
struct Room {
    var window: (x0: Float, y0: Float, x1: Float, y1: Float)
    var detail: Detail
    var night = false
    var top = colour(0xDAD8D4), bottom = colour(0x24211F)
    var rows: Int { detail == .full ? 8 : 5 }

    var glow: V3 { night ? colour(0xFFC27A) * 1.9 : V3(x: 1.45, y: 1.41, z: 1.32) }

    func wall(_ ey: Float) -> V3 { mix(top, bottom, smoothstep(-0.15, 1.05, ey)) }

    /// The andon, a paper lamp low on the right: a warm point in the metal.
    func lamp(_ ex: Float, _ ey: Float) -> V3 {
        let dx = ex - 0.95, dy = ey - 0.9
        return colour(0xFFB467) * (1.1 * exp(-(dx * dx + dy * dy) / 0.0006))
    }

    /// What a polished surface sees.
    func sharp(_ ex: Float, _ ey: Float) -> V3 {
        let c = wall(ey) + lamp(ex, ey)
        let w = window, e: Float = 0.004
        let ix = smoothstep(w.x0 - e, w.x0 + e, ex) * smoothstep(w.x1 + e, w.x1 - e, ex)
        let iy = smoothstep(w.y0 - e, w.y0 + e, ey) * smoothstep(w.y1 + e, w.y1 - e, ey)
        let inside = ix * iy
        guard inside > 0 else { return c }
        return mix(c, pane((ex - w.x0) / (w.x1 - w.x0), (ey - w.y0) / (w.y1 - w.y0)), inside)
    }

    /// What a worn or rough surface sees: the window as a broad glow.
    func soft(_ ex: Float, _ ey: Float) -> V3 {
        let w = window
        let dx = (ex - (w.x0 + w.x1) / 2) / ((w.x1 - w.x0) * 0.85)
        let dy = (ey - (w.y0 + w.y1) / 2) / ((w.y1 - w.y0) * 0.85)
        let g = 0.7 * exp(-(dx * dx + dy * dy))
        let lx = ex - 0.95, ly = ey - 0.9
        let lampGlow = colour(0xFFB467) * (0.25 * exp(-(lx * lx + ly * ly) / 0.03))
        return wall(ey) + (night ? colour(0xFFCB85) : white) * g + lampGlow
    }

    /// The shoji, its panes a packet list: ink on lit paper, kumiko between the
    /// rows, one row selected in rokushō, a protocol chip at the start of each row.
    func pane(_ u: Float, _ v: Float) -> V3 {
        let wood = colour(0x2B2019)
        let f: Float = 0.045
        let fu = smoothstep(f - 0.01, f, u) * smoothstep(1 - f + 0.01, 1 - f, u)
        let fv = smoothstep(f - 0.01, f, v) * smoothstep(1 - f + 0.01, 1 - f, v)
        guard detail != .glyph else {
            let bar = max(smoothstep(0.035, 0.015, abs(u - 0.5)), smoothstep(0.035, 0.015, abs(v - 0.5)))
            return mix(wood, mix(glow, wood, bar), fu * fv)
        }
        let uu = (u - f) / (1 - 2 * f), vv = clamp01((v - f) / (1 - 2 * f))
        let rowF = vv * Float(rows), row = min(rows - 1, Int(rowF)), local = rowF - Float(row)
        var c = row == 2 ? glow * V3(x: 0.52, y: 1.0, z: 0.9) : glow
        let band = smoothstep(0.3, 0.37, local) * smoothstep(0.7, 0.63, local)
        let r1 = (hash(row, 1, 5) + 1) / 2, r2 = (hash(row, 2, 5) + 1) / 2, r3 = (hash(row, 3, 5) + 1) / 2
        let columns: [(Float, Float)] = [(0.1, 0.16), (0.21, 0.31 + 0.08 * r1), (0.44, 0.53 + 0.07 * r2), (0.66, 0.73 + 0.23 * r3)]
        var ink: Float = 0
        for (a, b) in columns {
            ink = max(ink, smoothstep(a - 0.005, a + 0.005, uu) * smoothstep(b + 0.005, b - 0.005, uu))
        }
        c = mix(c, c * 0.5, ink * band)
        if detail == .full {
            let chip = smoothstep(0.022, 0.03, uu) * smoothstep(0.072, 0.064, uu) * band
            c = mix(c, protocolColours[[0, 1, 0, 2, 0, 3, 1, 0][row % 8]] * 1.15, chip)
        }
        let kumiko = smoothstep(0.06, 0.025, min(local, 1 - local))
        return mix(wood, mix(c, wood, kumiko), fu * fv)
    }
}

/// Where a surface at (fx, fy) with this normal looks, for a viewer straight in front.
func reflected(_ n: V3, _ fx: Float, _ fy: Float, reach: Float) -> (Float, Float) {
    let rz = max(0.08, 2 * n.z * n.z - 1)
    return (fx + 2 * n.z * n.x / rz * reach, fy + 2 * n.z * n.y / rz * reach)
}

func normal(_ h: Field, _ x: Int, _ y: Int) -> V3 {
    let gx = (h[x + 1, y] - h[x - 1, y]) * 0.5, gy = (h[x, y + 1] - h[x, y - 1]) * 0.5
    return V3(x: -gx, y: -gy, z: 1).normalised
}

// MARK: Materials

/// Polished or worn metal: the room, tinted by the metal, plus a highlight from the window.
func metal(_ nrm: V3, _ fx: Float, _ fy: Float, _ room: Room, tint: V3, rough: Float, reach: Float) -> V3 {
    let (ex, ey) = reflected(nrm, fx, fy, reach: reach)
    var env = room.sharp(ex, ey)
    if rough > 0.01 { env = mix(env, room.soft(ex, ey), rough) }
    let nh = max(0, nrm.dot(halfway))
    let spec = (1 - rough) * 0.35 * pow(nh, 140) + rough * 0.22 * pow(nh, 18)
    let fill = tint * (0.05 + 0.1 * max(0, nrm.dot(light)))
    return tint * env + white * spec + fill
}

/// Urushi: near-black, deep, and it reflects the window faintly.
func lacquer(_ nrm: V3, _ fx: Float, _ fy: Float, _ room: Room, shade: Float, base: V3 = lacquerBase) -> V3 {
    let lit = clamp01(nrm.dot(light))
    let diffuse = base * (0.5 + 0.7 * lit) * (1 - 0.75 * shade)
    let (ex, ey) = reflected(nrm, fx, fy, reach: 0.5)
    let f = 0.06 + 0.94 * pow(1 - max(0, nrm.z), 5)
    let nh = max(0, nrm.dot(halfway))
    let env = room.soft(ex, ey) * 0.8 + room.sharp(ex, ey) * 0.2
    return diffuse + env * (f * (1 - 0.6 * shade)) + white * (0.3 * pow(nh, 300))
}

// MARK: The mirror

/// A wakyō seen from the front: the white-bronze face is slightly convex, like
/// the real ones (a convex mirror shows the whole face in a small disc), inside
/// a raised cast rim with a bead where they meet. Heights in 1024 units.
struct MirrorSample { var height: Float; var disc: Float; var face: Float; var q: Float }

func mirror(_ X: Float, _ Y: Float, radius R: Float, unit u: Float) -> MirrorSample {
    let r = (X * X + Y * Y).squareRoot(), faceR = R * 0.83
    let disc = clamp01((R - r) * u + 0.5), face = clamp01((faceR - r) * u + 0.5)
    var h: Float
    if r < faceR {
        let q = r / faceR
        let q2 = q * q
        h = 10 + 22 * (1 - q2) + 40 * (1 - q2 * q2)
        let b = (faceR - r) / 7
        if b < 1 { h += 3 * sin(.pi * b) }
    } else {
        let t = min(1, (r - faceR) / (R - faceR))
        h = 6 * (1 - t) + 32 * pow(sin(.pi * t), 0.7)
    }
    return MirrorSample(height: h * disc, disc: disc, face: face, q: r / faceR)
}

func shadeMirror(_ s: MirrorSample, _ nrm: V3, _ fx: Float, _ fy: Float, _ room: Room,
                 cavity: Float, patina: Float, tarnish: Float) -> V3 {
    // Polished to the edge, with a little haze where hands have not reached.
    let haze = 0.02 + 0.14 * smoothstep(0.82, 1, s.q)
    let face = metal(nrm, fx, fy, room, tint: hakudo * (1 - 0.05 * tarnish), rough: haze, reach: 0.7)
    var rim = metal(nrm, fx, fy, room, tint: bronze, rough: 0.68, reach: 0.6) * (1 - 0.45 * cavity)
    let green = clamp01(cavity * 1.6 + (patina - 0.42) * 2.2)
    rim = mix(rim, verdigris * (0.32 + 0.6 * clamp01(nrm.dot(light))), green * 0.85)
    return mix(rim, face, s.face)
}

// MARK: Painting

/// Rolls bright values off softly instead of clipping them, so the window keeps its rows.
func tone(_ v: Float) -> Float { v <= 0.82 ? max(0, v) : 0.82 + 0.18 * (1 - exp(-(v - 0.82) / 0.18)) }

func image(_ n: Int, _ shade: (Int, Int) -> (V3, Float)) -> CGImage {
    var rgba = [UInt8](repeating: 0, count: n * n * 4)
    for y in 0..<n {
        for x in 0..<n {
            let (c, a) = shade(x, y), i = (y * n + x) * 4
            rgba[i + 0] = UInt8(tone(c.x) * a * 255)
            rgba[i + 1] = UInt8(tone(c.y) * a * 255)
            rgba[i + 2] = UInt8(tone(c.z) * a * 255)
            rgba[i + 3] = UInt8(clamp01(a) * 255)
        }
    }
    let provider = CGDataProvider(data: Data(rgba) as CFData)!
    return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}

/// Pixel centre in canvas fractions, y down.
func frac(_ x: Int, _ y: Int, _ n: Int) -> (Float, Float) { ((Float(x) + 0.5) / Float(n), (Float(y) + 0.5) / Float(n)) }

// MARK: Yata, the hero: 八咫鏡, a bronze mirror on black lacquer

func renderYata(_ d: Detail, n: Int) -> CGImage {
    let u = Float(n) / 1024
    let room = Room(window: (-0.06, -0.04, 0.64, 0.56), detail: d)
    let cx: Float = 512, cy: Float = 506, R: Float = d == .glyph ? 372 : 350
    var samples = [MirrorSample](), h = Field(n), disc = Field(n)
    samples.reserveCapacity(n * n)
    for y in 0..<n {
        for x in 0..<n {
            let s = mirror((Float(x) + 0.5) / u - cx, (Float(y) + 0.5) / u - cy, radius: R, unit: u)
            samples.append(s)
            h.v[y * n + x] = s.height * u
            disc.v[y * n + x] = s.disc
        }
    }
    // Urushi is mirror-flat, but not quite: a long, slow wave in the reflections.
    let ground = d == .full ? fbm(n, cell: 260 * u, octaves: 2, seed: 9) : Field(n)
    for i in 0..<n * n { h.v[i] += ground.v[i] * 0.9 * u * (1 - disc.v[i]) }
    let (cast, contact) = shadows(disc, u)
    let cavity = blur(h, 6 * u)
    let patina = d >= .mark ? fbm(n, cell: 34 * u, octaves: 3, seed: 5) : Field(n)
    let tarnish = fbm(n, cell: 120 * u, octaves: 3, seed: 21)
    return image(n) { x, y in
        let i = y * n + x, (fx, fy) = frac(x, y, n), nrm = normal(h, x, y)
        let shade = clamp01(0.55 * cast.v[i] + 0.45 * contact.v[i])
        var out = lacquer(nrm, fx, fy, room, shade: shade)
        let s = samples[i]
        if s.disc > 0 {
            let cav = clamp01((cavity.v[i] - h.v[i]) / (3 * u))
            out = mix(out, shadeMirror(s, nrm, fx, fy, room, cavity: cav, patina: patina.v[i], tarnish: tarnish.v[i]), s.disc)
        }
        return (out, 1)
    }
}

// MARK: Kyōhai: 鏡背, the cast back of a bronze mirror on hinoki

// The back is where bronze mirrors carry their decoration. This one follows the
// sankakuen mirrors from Japanese kofun: a knob with a silk cord through it, a
// lotus seat, bands of relief, a sawtooth ring and a rim of triangular section.
// The bands are the wire: a carrier wave, three tracks of packets cast as
// cartouches, and a comb band that is a bit ruler, every eighth tooth longer.
// Hands have polished the high relief back to gold; verdigris crusts the low.

/// A raised line of half-round section: 1 on its crest, 0 at `half` units away.
func bead(_ d: Float, _ half: Float) -> Float {
    let q = d / half
    return q >= 1 ? 0 : (1 - q * q).squareRoot()
}

/// Smooth value noise at a point, -1...1.
func vnoise(_ x: Float, _ y: Float, _ seed: Int) -> Float {
    let ix = Int(x.rounded(.down)), iy = Int(y.rounded(.down))
    let tx = smoothstep(0, 1, x - Float(ix)), ty = smoothstep(0, 1, y - Float(iy))
    let a = hash(ix, iy, seed) * (1 - tx) + hash(ix + 1, iy, seed) * tx
    let b = hash(ix, iy + 1, seed) * (1 - tx) + hash(ix + 1, iy + 1, seed) * tx
    return a * (1 - ty) + b * ty
}

/// Shadows from the window, by marching toward it across a height field in pixels.
func sunShadow(_ h: Field, steps: Int, stride: Float, soft: Float) -> Field {
    let n = h.n, l = (light.x * light.x + light.y * light.y).squareRoot()
    let dx = light.x / l, dy = light.y / l, rise = light.z / l
    var out = Field(n)
    for y in 0..<n {
        for x in 0..<n {
            let h0 = h.v[y * n + x]
            var s: Float = 0
            for k in 1...steps {
                let t = Float(k) * stride
                let over = h[Int(Float(x) + dx * t + 0.5), Int(Float(y) + dy * t + 0.5)] - h0 - t * rise
                if over > 0 { s = max(s, min(1, over / soft)) }
            }
            out.v[y * n + x] = s
        }
    }
    return out
}

/// Edge-grain hinoki (masame): straight growth lines at uneven spacing, a slow
/// drift, fibres along the grain, and the seam where two boards meet.
func hinoki(_ X: Float, _ Y: Float, _ d: Detail) -> (colour: V3, height: Float) {
    let seam: Float = 776, right = X > seam
    let spacing: Float = d == .full ? 7.4 : d == .mark ? 15 : 34
    let xx = X + 9 * vnoise(Y / 260, right ? 4.5 : 0.5, 51) + (right ? 37 : 0)
    let ring = xx / spacing + 1.8 * vnoise(xx / (spacing * 5), right ? 3.5 : 0.5, 53)
    let index = Int(ring.rounded(.down)), g = ring - Float(index)
    let width = 0.12 + 0.2 * (hash(index, right ? 2 : 1, 71) + 1) / 2
    let depth = 0.35 + 0.65 * (hash(index, right ? 4 : 3, 73) + 1) / 2
    let late = smoothstep(0, 0.05, g) * smoothstep(width + 0.08, width, g) * depth * (d == .glyph ? 0.4 : 1)
    let fibre = d == .full ? vnoise(X / 2.2, Y / 60, 57) : 0
    let tone = 1 + 0.04 * vnoise(X / 90, Y / 400, right ? 61 : 59)
    var c = mix(colour(0xF3E0C1), colour(0xCFA372), late * 0.75) * (1 + 0.018 * fibre) * tone * (right ? 0.965 : 1)
    let sd = abs(X - seam), groove = d >= .mark ? max(0, 1 - sd / 1.8) : 0
    c = c * (1 - 0.35 * groove)
    return (c, late * 0.4 + fibre * 0.05 - groove * 1.1)
}

struct Track { let radius: Float; let segments: [(Float, Float)] }

/// Packets of varying length round three tracks, like a stream laid in a ring.
func packetTracks(_ d: Detail) -> [Track] {
    let radii: [Float] = d == .full ? [0.505, 0.58, 0.655] : [0.53, 0.64]
    return radii.enumerated().map { k, radius in
        var rnd = Random(state: UInt64(40 + k * 7))
        let start = Float(rnd.range(0, 2 * .pi))
        var segments: [(Float, Float)] = [], a = start
        while a < start + 2 * .pi - 0.14 {
            let end = min(a + Float(rnd.range(0.07, 0.4)), start + 2 * .pi - 0.1)
            segments.append((a, end))
            a = end + Float(d == .full ? rnd.range(0.05, 0.09) : rnd.range(0.09, 0.14))
        }
        return Track(radius: radius, segments: segments)
    }
}

/// The himo: a loop of cord through the knob, out of one side and back into the other.
func cordPath(kr: Float) -> [(Float, Float)] {
    func cubic(_ p: [(Float, Float)], _ t: Float) -> (Float, Float) {
        let m = 1 - t, a = m * m * m, b = 3 * m * m * t, c = 3 * m * t * t, e = t * t * t
        return (a * p[0].0 + b * p[1].0 + c * p[2].0 + e * p[3].0, a * p[0].1 + b * p[1].1 + c * p[2].1 + e * p[3].1)
    }
    let k = kr
    let first = [(-0.86 * k, 0.05 * k), (-2.0 * k, 0.3 * k), (-2.1 * k, 3.6 * k), (0.55 * k, 4.3 * k)]
    let second = [(0.55 * k, 4.3 * k), (2.6 * k, 4.8 * k), (2.3 * k, 0.4 * k), (0.86 * k, 0.05 * k)]
    return (0...200).map { cubic(first, Float($0) / 200) } + (1...200).map { cubic(second, Float($0) / 200) }
}

func renderKyohai(_ d: Detail, n: Int) -> CGImage {
    let u = Float(n) / 1024
    // Plain panes: on a knob this small the packet rows would only be a glitch.
    let room = Room(window: (0.04, 0.03, 0.6, 0.5), detail: .glyph)
    let cx: Float = 500, cy: Float = 492
    let R: Float = d == .glyph ? 372 : 352
    let T: Float = 16, thick: Float = d == .glyph ? 10 : 14
    let kr = R * (d == .glyph ? 0.18 : 0.125)
    let tracks = d >= .mark ? packetTracks(d) : []
    let trackHalf = R * (d == .full ? 0.026 : 0.042)
    let rimIn: Float = d == .glyph ? 0.85 : 0.885
    let lines: [Float] = d == .full ? [0.31, 0.445, 0.7, 0.795] : d == .mark ? [0.445, 0.72, 0.795] : []
    let teeth: Float = d == .full ? 72 : 40
    let petals = d == .full ? 16 : d == .mark ? 8 : 0

    // Pass 1: the casting, the wall below its edge, and the board.
    var h = Field(n), top = Field(n), side = Field(n), hole = Field(n), rub = Field(n)
    for y in 0..<n {
        for x in 0..<n {
            let i = y * n + x
            let X = (Float(x) + 0.5) / u - cx, Y = (Float(y) + 0.5) / u - cy
            let r = (X * X + Y * Y).squareRoot()
            let cover = clamp01((R - r) * u + 0.5)
            let wood = hinoki(X + cx, Y + cy, d).height
            if cover <= 0 {
                // Seen a touch from above, the edge of the casting shows as a band of wall.
                var wall: Float = 0, wallH: Float = 0
                if abs(X) < R && Y > 0 {
                    let k = Y - (R * R - X * X).squareRoot()
                    if k >= 0 { wall = clamp01((thick - k) * u + 0.5); wallH = T * max(0, 1 - k / thick) }
                }
                side.v[i] = wall
                h.v[i] = (wall * wallH + (1 - wall) * wood) * u
                continue
            }
            let q = r / R
            var theta = atan2(Y, X)
            if theta < 0 { theta += 2 * .pi }
            var e: Float = 0

            // The rim, triangular in section, its ridge where hands hold it.
            if q > rimIn {
                let t = (q - rimIn) / (1 - rimIn), a = t - 0.55
                e = max(e, 24 * max(0, 1 - ((a * a + 0.0016).squareRoot() - 0.04) / (a < 0 ? 0.51 : 0.41)))
                rub.v[i] = exp(-(a / 0.2) * (a / 0.2))
            }
            // Sawtooth ring (kyoshimon), points inward.
            if d >= .mark && q > 0.8 && q < 0.875 {
                let f = theta * teeth / (2 * .pi), w = (q - 0.8) / 0.075, dA = abs(f - f.rounded(.down) - 0.5) * 2
                if dA < w {
                    let edge = min((w - dA) * .pi * r / teeth, (0.875 - q) * R)
                    e = max(e, 7 * min(1, edge / 3))
                }
            }
            // Comb band (kushimemon) as a bit ruler: 128 teeth, every eighth a byte.
            if d == .full && q > 0.712 && q < 0.79 {
                let f = theta * 128 / (2 * .pi), index = Int(f), local = f - Float(index)
                let byte = index % 8 == 0
                let r0: Float = byte ? 0.716 : 0.728, r1: Float = byte ? 0.786 : 0.774
                if q > r0 && q < r1 {
                    let arc = abs(local - 0.5) * 2 * .pi * r / 128
                    e = max(e, 5 * bead(arc, byte ? 2.1 : 1.5) * min(1, min(q - r0, r1 - q) * R / 2))
                }
            }
            // Carrier wave: two lines in step (fukusen hamon).
            if d == .full && q > 0.33 && q < 0.43 {
                for offset: Float in [-0.014, 0.014] {
                    let rw = R * (0.38 + offset + 0.016 * sin(theta * 30))
                    e = max(e, 5 * bead(abs(r - rw), 2))
                }
            }
            for l in lines { e = max(e, 5.5 * bead(abs(r - l * R), 2.2)) }
            if d == .glyph { e = max(e, 8 * bead(abs(r - 0.6 * R), 0.075 * R)) }
            // Packets: cartouches with a softly domed face.
            for track in tracks {
                let dr = r - track.radius * R
                guard abs(dr) < trackHalf else { continue }
                for (a0, a1) in track.segments {
                    for th in [theta, theta + 2 * .pi] {
                        let over = max(0, max(a0 - th, th - a1)) * r
                        let dist = (dr * dr + over * over).squareRoot() / trackHalf
                        if dist < 1 { e = max(e, 8 * pow(1 - dist * dist, 0.35)) }
                    }
                }
            }
            // Lotus seat: eight petals, eight smaller between them, a midrib in each.
            if petals > 0 && q > 0.15 && q < 0.3 {
                for k in 0..<petals {
                    let big = d == .mark || k % 2 == 0
                    let phi = Float(k) * 2 * .pi / Float(petals) + .pi / 8
                    let p = X * cos(phi) + Y * sin(phi), s = -X * sin(phi) + Y * cos(phi)
                    let p0 = 0.152 * R, p1 = (big ? 0.305 : 0.25) * R, W = (big ? 0.056 : 0.034) * R
                    let t = (p - p0) / (p1 - p0)
                    guard t > 0 && t < 1 else { continue }
                    let half = W * 1.25 * pow(sin(.pi * t), 0.6) * (1.2 - 0.9 * t)
                    guard abs(s) < half else { continue }
                    let hp = (big ? 7.5 : 5.5) * (1 - (s / half) * (s / half)).squareRoot() * pow(sin(.pi * t), 0.55)
                    e = max(e, hp)
                }
            }
            // The knob on its seat, with the cord hole through it.
            let kq = r / kr
            if kq < 1.22 { e = max(e, 4 * smoothstep(1.22, 1.15, kq)) }
            if kq < 1 {
                e = max(e, 4 + 36 * (1 - kq * kq).squareRoot())
                rub.v[i] = max(rub.v[i], smoothstep(0.75, 0.2, kq))
                let hx = (abs(X) / kr - 0.86) / 0.17, hy = Y / (kr * 0.3), o = hx * hx + hy * hy
                if o < 1 { hole.v[i] = smoothstep(1, 0.55, o); e -= 8 * (1 - o) }
            }
            top.v[i] = cover
            h.v[i] = (cover * (T + e) + (1 - cover) * wood) * u
        }
    }

    // The cord: kumihimo silk, braided in chevrons, lying over the relief.
    var cordT = Field(n, 2), cordS = Field(n)
    var cord = Field(n), braid = Field(n)
    if d == .full {
        let points = cordPath(kr: kr), half: Float = 9.5
        var travelled: Float = 0
        var lengths: [Float] = [0]
        for j in 1..<points.count {
            let dx = points[j].0 - points[j - 1].0, dy = points[j].1 - points[j - 1].1
            travelled += (dx * dx + dy * dy).squareRoot()
            lengths.append(travelled)
        }
        for j in 1..<points.count {
            let ax = (cx + points[j - 1].0) * u, ay = (cy + points[j - 1].1) * u
            let bx = (cx + points[j].0) * u, by = (cy + points[j].1) * u
            let vx = bx - ax, vy = by - ay, len2 = max(vx * vx + vy * vy, 1e-6)
            let pad = half * u + 2
            for py in max(0, Int(min(ay, by) - pad))...min(n - 1, Int(max(ay, by) + pad)) {
                for px in max(0, Int(min(ax, bx) - pad))...min(n - 1, Int(max(ax, bx) + pad)) {
                    let i = py * n + px, fx = Float(px) + 0.5, fy = Float(py) + 0.5
                    let t = clamp01(((fx - ax) * vx + (fy - ay) * vy) / len2)
                    let qx = ax + vx * t - fx, qy = ay + vy * t - fy
                    let dist = (qx * qx + qy * qy).squareRoot() / u / half
                    if dist < 1 && dist < abs(cordT.v[i]) {
                        cordT.v[i] = (vx * (fy - ay) - vy * (fx - ax)) > 0 ? dist : -dist
                        cordS.v[i] = lengths[j - 1] + t * (lengths[j] - lengths[j - 1])
                    }
                }
            }
        }
        let holeHeight = T + 13
        for i in 0..<n * n where abs(cordT.v[i]) < 1 {
            let t = cordT.v[i], s = cordS.v[i]
            let base = T + 9 + (holeHeight - T - 9) * smoothstep(18, 0, min(s, travelled - s))
            let round = (1 - t * t).squareRoot()
            let b = 0.5 + 0.5 * cos(2 * .pi * (s / 6 + abs(t) * 1.5))
            let ch = (base + 9 * round + 1.2 * b * round) * u
            if ch > h.v[i] {
                let cover = clamp01((1 - abs(t)) * half * u + 0.5)
                h.v[i] = h.v[i] * (1 - cover) + ch * cover
                cord.v[i] = cover
                braid.v[i] = b
            }
        }
    }

    // Patina: verdigris grows where the relief shelters it and crusts over;
    // whatever stands proud has been rubbed back to bright bronze.
    let near = blur(h, 4 * u), wide = blur(h, 16 * u)
    let patch = fbm(n, cell: (d == .glyph ? 80 : 38) * u, octaves: 4, seed: 13)
    let patch2 = fbm(n, cell: 22 * u, octaves: 3, seed: 29)
    let grit = d == .full ? fbm(n, cell: 1.7 * u, octaves: 2, seed: 37) : Field(n)
    var verdi = Field(n), worn = Field(n)
    for i in 0..<n * n {
        let bronzeHere = max(top.v[i], side.v[i] * 0.6) * (1 - cord.v[i])
        guard bronzeHere > 0 else { continue }
        let cav = clamp01((near.v[i] - h.v[i]) / (1.6 * u)), deep = clamp01((wide.v[i] - h.v[i]) / (4 * u))
        let proud = clamp01((h.v[i] - near.v[i]) / (1.2 * u)) * 0.35 + clamp01((h.v[i] - wide.v[i]) / (7 * u)) * 0.8
        worn.v[i] = max(smoothstep(0.28, 0.8, proud) * (0.6 + 0.4 * clamp01(0.5 - patch2.v[i])), rub.v[i] * (0.75 + 0.25 * patch2.v[i]))
        let grow = cav * 1.2 + deep * 0.5 + (patch.v[i] - (d == .glyph ? 0.05 : 0.15)) * 1.7
        verdi.v[i] = clamp01(grow) * (1 - 0.9 * worn.v[i]) * (1 - 0.8 * rub.v[i]) * bronzeHere
        h.v[i] += verdi.v[i] * (0.5 + 0.6 * grit.v[i]) * 1.3 * u
    }

    let shadow = blur(sunShadow(h, steps: 26, stride: 2.6 * u, soft: 1.6 * u), 1.3 * u)
    let aoNear = blur(h, 3 * u), aoWide = blur(h, 14 * u)
    return image(n) { x, y in
        let i = y * n + x, (fx, fy) = frac(x, y, n), nrm = normal(h, x, y)
        let lit = clamp01(nrm.dot(light)), sh = shadow.v[i]
        let occl = 1 - 0.45 * clamp01((aoNear.v[i] - h.v[i]) / (2 * u)) - 0.3 * clamp01((aoWide.v[i] - h.v[i]) / (6 * u))
        let nh = max(0, nrm.dot(halfway))
        let falloff = 1.06 - 0.12 * (fx * 0.45 + fy * 0.55)
        let wood = hinoki(fx * 1024, fy * 1024, d).colour
        var out = wood * (0.72 + 0.4 * lit) * falloff * (1 - 0.62 * sh) * occl + white * (0.05 * pow(nh, 30) * (1 - sh))

        let b = max(top.v[i], side.v[i])
        if b > 0 {
            let envShade = 1 - 0.5 * sh
            let aged = mix(colour(0x6A4E36), colour(0x575238), clamp01(0.5 + patch.v[i]))
            var col = metal(nrm, fx, fy, room, tint: aged, rough: 0.6, reach: 0.5) * envShade
                + colour(0x2B1E14) * ((0.4 + 0.6 * lit) * (1 - 0.6 * sh))
            let polished = metal(nrm, fx, fy, room, tint: colour(0xE4B270), rough: 0.45, reach: 0.5) * envShade
            col = mix(col, polished, worn.v[i] * (1 - verdi.v[i]))
            // Malachite greens, the odd blue of azurite, a rim of red cuprite.
            let v = verdi.v[i], p2 = patch2.v[i]
            var green = mix(colour(0x3F8C72), colour(0x93CBB4), clamp01(0.5 + 0.4 * p2 + 0.2 * grit.v[i]))
            green = mix(green, colour(0x46779C), smoothstep(0.45, 0.75, p2) * 0.5)
            col = mix(col, green * ((0.3 + 0.78 * lit) * (1 - 0.55 * sh)), smoothstep(0.08, 0.6, v))
            let fringe = smoothstep(0.05, 0.25, v) * smoothstep(0.55, 0.3, v)
            col = mix(col, colour(0x7C3F24) * (0.35 + 0.6 * lit), fringe * 0.3)
            out = mix(out, col * occl * (1 - 0.88 * hole.v[i]), b)
        }
        if cord.v[i] > 0 {
            let br = braid.v[i]
            let silk = colour(0x4E2D63) * ((0.24 + 0.95 * lit) * (0.8 + 0.2 * br) * (1 - 0.6 * sh) * occl)
                + colour(0xE8D0F0) * (0.22 * pow(nh, 14) * (0.6 + 0.4 * br) * (1 - sh))
            out = mix(out, silk, cord.v[i])
        }
        return (out, 1)
    }
}

// MARK: Mizukagami: 水鏡, still water used as a mirror

/// The oldest mirror: still water. A drop lands and sends rings out, wave
/// packets in the literal sense, and they break the lit window into its rows.
func renderMizu(_ d: Detail, n: Int) -> CGImage {
    let u = Float(n) / 1024
    var room = Room(window: (0.2, 0.17, 0.8, 0.6), detail: d, night: true)
    room.top = colour(0x24304A); room.bottom = colour(0x04060A)
    let cx: Float = 512, cy: Float = 680
    let packets: [(r: Float, a: Float)] = d == .full ? [(110, 0.75), (235, 0.36), (370, 0.17)]
        : d == .mark ? [(150, 1.0), (320, 0.7)] : [(230, 1.6)]
    let wavelength: Float = d == .full ? 30 : d == .mark ? 44 : 70
    var h = Field(n)
    for y in 0..<n {
        for x in 0..<n {
            let X = (Float(x) + 0.5) / u - cx, Y = (Float(y) + 0.5) / u - cy
            let r = (X * X + Y * Y).squareRoot()
            var z: Float = 3 * exp(-(r / 16) * (r / 16))
            for p in packets {
                let t = (r - p.r) / (wavelength * 1.15)
                z += p.a * cos(2 * .pi * (r - p.r) / wavelength) * exp(-t * t)
            }
            h.v[y * n + x] = z * u
        }
    }
    return image(n) { x, y in
        let (fx, fy) = frac(x, y, n), nrm = normal(h, x, y)
        let lit = clamp01(nrm.dot(light))
        let slope = 1 - nrm.z
        // Still water at night is mostly mirror; what is left is deep indigo.
        let f = 0.55 + 0.45 * pow(slope, 5)
        let (ex, ey) = reflected(nrm, fx, fy, reach: 0.45)
        let deep = colour(0x07111D) * (0.7 + 0.5 * lit) + rokusho * (0.25 * clamp01(slope * 6))
        let nh = max(0, nrm.dot(halfway))
        let env = room.sharp(ex, ey) + room.soft(ex, ey) * 0.35
        let out = deep * (1 - f) + env * f + white * (0.35 * pow(nh, 160))
        return (out, 1)
    }
}

// MARK: Urushi: 漆, 鏡 inlaid in white bronze on black lacquer

func renderUrushi(_ d: Detail, n: Int) -> CGImage {
    let u = Float(n) / 1024
    var room = Room(window: (0.06, 0.04, 0.64, 0.54), detail: d)
    room.bottom = colour(0x3A332D)
    // 鏡 has sixteen strokes; below 128 px they close up, so the inlay becomes a disc.
    let inlay = coverage(n) { ctx in
        if d == .glyph {
            ctx.addPath(circle(CGPoint(x: 512, y: 512), 260))
        } else {
            var place = CGAffineTransform(translationX: 512, y: 508)
            ctx.addPath(kanjiPath("鏡", height: 540).copy(using: &place)!)
        }
        ctx.fillPath()
    }
    let bevel = blur(inlay, (d == .glyph ? 14 : 4.5) * u)
    let ground = d == .full ? fbm(n, cell: 260 * u, octaves: 2, seed: 9) : Field(n)
    var h = Field(n)
    for i in 0..<n * n {
        let b = smoothstep(0, 1, bevel.v[i])
        h.v[i] = (b * (d == .glyph ? 22 : 10) + ground.v[i] * 0.9 * (1 - inlay.v[i])) * u
    }
    let (cast, contact) = shadows(inlay, u, distance: d == .glyph ? 16 : 7, softness: d == .glyph ? 22 : 9)
    let tarnish = fbm(n, cell: 90 * u, octaves: 3, seed: 23)
    return image(n) { x, y in
        let i = y * n + x, (fx, fy) = frac(x, y, n), nrm = normal(h, x, y)
        let shade = clamp01(0.5 * cast.v[i] + 0.45 * contact.v[i]) * (1 - inlay.v[i])
        var out = lacquer(nrm, fx, fy, room, shade: shade)
        if inlay.v[i] > 0 {
            let silver = metal(nrm, fx, fy, room, tint: hakudo * (1 - 0.06 * tarnish.v[i]), rough: 0.06, reach: 0.8)
            out = mix(out, silver, inlay.v[i])
        }
        return (out, 1)
    }
}

// MARK: Tekagami: 手鏡, an Edo hand mirror on indigo cloth

func renderTekagami(_ d: Detail, n: Int) -> CGImage {
    let u = Float(n) / 1024
    let room = Room(window: (0.02, 0.0, 0.56, 0.46), detail: d)
    // Upright, handle down: held up to look into, so it never reads as a magnifier.
    let R: Float = d == .glyph ? 290 : 262
    let cx: Float = 512, cy: Float = d == .glyph ? 420 : 400
    let dir: (x: Float, y: Float) = (0, 1)
    let t1: Float = d == .glyph ? 500 : 530, hw: Float = d == .glyph ? 56 : 44
    var samples = [MirrorSample](), h = Field(n), cover = Field(n), part = [UInt8](repeating: 0, count: n * n)
    var cord = Field(n)
    samples.reserveCapacity(n * n)
    for y in 0..<n {
        for x in 0..<n {
            let i = y * n + x
            let X = (Float(x) + 0.5) / u - cx, Y = (Float(y) + 0.5) / u - cy
            let s = mirror(X, Y, radius: R, unit: u)
            samples.append(s)
            // The handle: a lacquered core under a silk cord wrap, bronze collar and cap.
            let t = X * dir.x + Y * dir.y, side = -X * dir.y + Y * dir.x
            let across = abs(side), endT = t1 - hw
            let dEnd = t > endT ? ((t - endT) * (t - endT) + side * side).squareRoot() : across
            var hh: Float = 0, hc: Float = 0
            if t > R * 0.7 {
                hc = clamp01((hw - dEnd) * u + 0.5)
                let q = min(1, dEnd / hw)
                hh = 26 * (1 - q * q).squareRoot()
                let collar = R + 36, wrapEnd = t1 - 64
                if t < collar {
                    part[i] = 1
                    hh += 4 * pow(sin((t - R) / 12 * .pi), 2)
                } else if t < wrapEnd {
                    part[i] = 2
                    if d >= .mark {
                        let phase = (t + side * 0.9) / (d == .full ? 13 : 22)
                        let c = 0.5 + 0.5 * cos(2 * .pi * phase)
                        cord.v[i] = c
                        hh += 3.5 * c
                    }
                } else {
                    part[i] = 3
                }
            }
            cover.v[i] = max(s.disc, hc)
            h.v[i] = (s.disc * s.height + (1 - s.disc) * hh * hc) * u
        }
    }
    // Aizome: indigo cotton, a fine plain weave and uneven dye.
    let mottle = fbm(n, cell: 150 * u, octaves: 4, seed: 41)
    let weave = d == .full ? Float(1) : 0
    for y in 0..<n {
        for x in 0..<n {
            let i = y * n + x, X = (Float(x) + 0.5) / u, Y = (Float(y) + 0.5) / u
            let w = sin(X * .pi / 3.2) * sin(Y * .pi / 3.2)
            h.v[i] += (w * 0.5 * weave + mottle.v[i] * 0.6) * u * (1 - cover.v[i])
        }
    }
    let (cast, contact) = shadows(cover, u, distance: 26, softness: 30)
    let cavity = blur(h, 6 * u)
    let patina = d >= .mark ? fbm(n, cell: 34 * u, octaves: 3, seed: 5) : Field(n)
    let tarnish = fbm(n, cell: 120 * u, octaves: 3, seed: 21)
    return image(n) { x, y in
        let i = y * n + x, (fx, fy) = frac(x, y, n), nrm = normal(h, x, y)
        let lit = clamp01(nrm.dot(light))
        let falloff = 1.05 - 0.12 * (fx * 0.45 + fy * 0.55)
        let shade = clamp01(0.55 * cast.v[i] + 0.45 * contact.v[i])
        let cloth = colour(0x1D2D49) * (1 + 0.08 * mottle.v[i])
        var out = cloth * (0.55 + 0.6 * lit) * falloff * (1 - 0.6 * shade)
        let s = samples[i], c = cover.v[i]
        guard c > 0 else { return (out, 1) }
        let cav = clamp01((cavity.v[i] - h.v[i]) / (3 * u))
        var obj: V3
        switch part[i] {
        case 2:
            // Silk cord: rokushō, with the sheen running along the twist.
            let nh = max(0, nrm.dot(halfway))
            obj = rokusho * (0.3 + 0.8 * lit) * (0.82 + 0.18 * cord.v[i]) + white * (0.18 * pow(nh, 10))
        case 1, 3:
            obj = metal(nrm, fx, fy, room, tint: bronze, rough: 0.6, reach: 0.6) * (1 - 0.45 * cav)
        default:
            obj = out
        }
        if s.disc > 0 {
            obj = mix(obj, shadeMirror(s, nrm, fx, fy, room, cavity: cav, patina: patina.v[i], tarnish: tarnish.v[i]), s.disc)
        }
        out = mix(out, obj, c)
        return (out, 1)
    }
}

// MARK: Variants

struct Variant {
    let id: String, name: String, kanji: String, line: String
    let render: (Detail, Int) -> CGImage
    var story = ""
    var swatches: [(String, UInt32)] = []
}

let variants = [
    Variant(id: "kyohai", name: "Kyōhai", kanji: "鏡背", line: "The cast back: the wire in bronze", render: renderKyohai,
            story: """
            The back of a Japanese bronze mirror on a hinoki board, cast like
            the sankakuen mirrors from the kofun. Its bands are the wire: a
            carrier wave, three tracks of packets, a comb band that is a bit
            ruler with every eighth tooth a byte. Hands have rubbed the rim and
            knob back to gold; verdigris crusts the rest. A silk cord runs
            through the knob, as it always did.
            """,
            swatches: [("bronze", 0xC8955A), ("rokushō", 0x2F8F7A), ("hinoki", 0xF3E0C1), ("murasaki", 0x4E2D63)]),
    Variant(id: "yata", name: "Yata", kanji: "八咫鏡", line: "The mirror, reflecting the packet list", render: renderYata,
            story: """
            A wakyō, a Japanese bronze mirror, on black lacquer. What it reflects is
            a shoji window, and the window's panes are a packet list: ink on lit
            paper, one row selected, a protocol chip at the start of each. Kagami
            shows you the wire as it is: reflected, clear, undistorted.
            """,
            swatches: [("hakudō", 0xEDEBE3), ("bronze", 0xA87A45), ("rokushō", 0x2F8F7A), ("urushi", 0x121011)]),
    Variant(id: "mizu", name: "Mizukagami", kanji: "水鏡", line: "Water mirror: wave packets", render: renderMizu),
    Variant(id: "urushi", name: "Urushi", kanji: "漆", line: "鏡 in white bronze on lacquer", render: renderUrushi),
    Variant(id: "tekagami", name: "Tekagami", kanji: "手鏡", line: "An Edo hand mirror, held up", render: renderTekagami),
]

/// Rendered at twice the slot size (at least 256) and scaled down, so small
/// sizes are smooth; the detail follows the slot, not the render.
func renderSize(_ size: CGFloat) -> Int { min(2048, max(256, Int(size) * 2)) }

/// The tile with the macOS drop shadow, filled edge to edge with the scene.
func drawIcon(_ ctx: CGContext, size: CGFloat, variant: Variant) {
    let image = variant.render(Detail(pixels: size), renderSize(size))
    let k = size / 1024
    ctx.saveGState()
    ctx.scaleBy(x: k, y: k)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 28 * k, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(tile)
    ctx.setFillColor(sumi)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(tile)
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    ctx.restoreGState()
}

// MARK: Bitmaps

func bitmap(width: Int, height: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to url: URL) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: Brand sheets and lockups

func text(_ string: String, font: NSFont, color: CGColor, kern: CGFloat = 0) -> NSAttributedString {
    NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!, .kern: kern])
}

func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
func mono(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
func mincho(_ size: CGFloat) -> NSFont { NSFont(name: "HiraMinProN-W6", size: size) ?? sans(size, .semibold) }

/// Each size drawn natively, as the icon set ships it, so the sheet shows what the Dock shows.
func drawSizes(_ ctx: CGContext, variant: Variant, sizes: [CGFloat], x: CGFloat, y: CGFloat, gap: CGFloat, label: CGColor?) {
    var x = x
    let tallest = sizes.max() ?? 0
    for size in sizes {
        let icon = bitmap(width: Int(size), height: Int(size)) { drawIcon($0, size: size, variant: variant) }
        ctx.draw(icon.cgImage!, in: CGRect(x: x, y: y + (tallest - size) / 2, width: size, height: size))
        if let label {
            let t = text("\(Int(size))", font: mono(16), color: label)
            t.draw(at: CGPoint(x: x + (size - t.size().width) / 2, y: y - 34))
        }
        x += size + gap
    }
}

func drawSheet(_ ctx: CGContext, width: CGFloat, height: CGFloat, hero: Variant) {
    ctx.setFillColor(surface)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let side: CGFloat = 1120
    ctx.saveGState()
    ctx.translateBy(x: 80, y: (height - side) / 2)
    ctx.scaleBy(x: side / 1024, y: side / 1024)
    drawIcon(ctx, size: 1024, variant: hero)
    ctx.restoreGState()

    let left: CGFloat = 1300
    text("Kagami", font: sans(132, .semibold), color: sumi, kern: -2).draw(at: CGPoint(x: left, y: 1150))
    text("鏡  ·  かがみ  ·  mirror", font: mincho(46), color: rokushoCG, kern: 5).draw(at: CGPoint(x: left + 6, y: 1078))
    let story = hero.story
    let para = NSMutableParagraphStyle()
    para.lineSpacing = 10
    NSAttributedString(string: story, attributes: [.font: sans(28), .foregroundColor: NSColor(cgColor: sumi.copy(alpha: 0.72)!)!,
                                                   .paragraphStyle: para])
        .draw(in: CGRect(x: left, y: 800, width: 1020, height: 262))

    let swatches = hero.swatches
    for (i, s) in swatches.enumerated() {
        let x = left + CGFloat(i) * 250, y: CGFloat = 728
        ctx.setFillColor(rgb(s.1))
        ctx.fillEllipse(in: CGRect(x: x, y: y, width: 44, height: 44))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: CGRect(x: x, y: y, width: 44, height: 44))
        text(s.0, font: sans(20, .medium), color: sumi).draw(at: CGPoint(x: x + 58, y: y + 22))
        text(String(format: "#%06X", s.1), font: mono(17), color: sumi.copy(alpha: 0.55)!).draw(at: CGPoint(x: x + 58, y: y))
    }

    for row in 0..<2 {
        let y: CGFloat = row == 0 ? 430 : 100
        let strip = CGRect(x: left - 30, y: y - 50, width: 1020, height: 320)
        ctx.addPath(CGPath(roundedRect: strip, cornerWidth: 26, cornerHeight: 26, transform: nil))
        ctx.setFillColor(row == 0 ? paper : sumi)
        ctx.fillPath()
        drawSizes(ctx, variant: hero, sizes: [256, 128, 64, 32, 16], x: left, y: y, gap: 56,
                  label: (row == 0 ? sumi : paper).copy(alpha: 0.5)!)
    }
}

/// The showreel: all five side by side, each with its Dock sizes on light and dark.
func drawAlternates(_ ctx: CGContext, width: CGFloat, height: CGFloat) {
    ctx.setFillColor(surface)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    text("Kagami  ·  鏡", font: sans(56, .semibold), color: sumi, kern: -0.5).draw(at: CGPoint(x: 90, y: height - 130))
    text("One hero and four alternates. Same renderer, same window, five mirrors.",
         font: sans(24), color: sumi.copy(alpha: 0.6)!).draw(at: CGPoint(x: 92, y: height - 178))
    let column = (width - 180) / CGFloat(variants.count)
    for (i, v) in variants.enumerated() {
        let x0 = 90 + CGFloat(i) * column, iconSide = column - 60
        ctx.saveGState()
        ctx.translateBy(x: x0, y: height - 250 - iconSide)
        ctx.scaleBy(x: iconSide / 1024, y: iconSide / 1024)
        drawIcon(ctx, size: 1024, variant: v)
        ctx.restoreGState()
        let top = height - 270 - iconSide
        let title = text(v.name + (i == 0 ? "  ·  hero" : ""), font: sans(30, .semibold), color: i == 0 ? rokushoCG : sumi)
        title.draw(at: CGPoint(x: x0 + 20, y: top - 40))
        text(v.kanji, font: mincho(24), color: sumi.copy(alpha: 0.7)!, kern: 3).draw(at: CGPoint(x: x0 + 20, y: top - 78))
        text(v.line, font: sans(19), color: sumi.copy(alpha: 0.6)!).draw(at: CGPoint(x: x0 + 20, y: top - 110))
        for row in 0..<2 {
            let y = top - 300 + CGFloat(1 - row) * 0 - CGFloat(row) * 170
            let strip = CGRect(x: x0 + 10, y: y - 20, width: iconSide - 20, height: 150)
            ctx.addPath(CGPath(roundedRect: strip, cornerWidth: 20, cornerHeight: 20, transform: nil))
            ctx.setFillColor(row == 0 ? paper : sumi)
            ctx.fillPath()
            drawSizes(ctx, variant: v, sizes: [110, 64, 32, 16], x: x0 + 30, y: y, gap: 22, label: nil)
        }
    }
}

func drawLockup(_ ctx: CGContext, width: CGFloat, height: CGFloat, dark: Bool, variant: Variant) {
    let fg = dark ? paper : sumi
    ctx.setFillColor(dark ? sumi : paper)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let side = height * 0.78
    ctx.saveGState()
    ctx.translateBy(x: height * 0.11, y: height * 0.11)
    ctx.scaleBy(x: side / 1024, y: side / 1024)
    drawIcon(ctx, size: 1024, variant: variant)
    ctx.restoreGState()
    let x = height * 0.11 + side + height * 0.04
    text("Kagami", font: sans(height * 0.3, .semibold), color: fg, kern: -height * 0.006)
        .draw(at: CGPoint(x: x, y: height * 0.42))
    text("鏡  ·  mirror", font: mincho(height * 0.1), color: fg.copy(alpha: 0.55)!, kern: height * 0.008)
        .draw(at: CGPoint(x: x + height * 0.012, y: height * 0.27))
}

// MARK: Main

let args = Array(CommandLine.arguments.dropFirst())
guard let outPath = args.first, !outPath.hasPrefix("--") else {
    print("usage: make-icon <AppIcon.iconset|AppIcon.appiconset> [--variant kyohai|yata|mizu|urushi|tekagami] [--brand <folder>]")
    exit(1)
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let chosenID = option("--variant") ?? "kyohai"
guard let chosen = variants.first(where: { $0.id == chosenID }) else {
    print("unknown variant \(chosenID); one of: \(variants.map(\.id).joined(separator: ", "))")
    exit(1)
}
let outDir = URL(fileURLWithPath: outPath)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

struct Slot { let size: Int; let scale: Int }
let slots = [16, 32, 128, 256, 512].flatMap { [Slot(size: $0, scale: 1), Slot(size: $0, scale: 2)] }
var images: [[String: String]] = []
for slot in slots {
    let pixels = slot.size * slot.scale
    let name = "icon_\(slot.size)x\(slot.size)\(slot.scale == 2 ? "@2x" : "").png"
    try write(bitmap(width: pixels, height: pixels) { drawIcon($0, size: CGFloat(pixels), variant: chosen) },
              to: outDir.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(slot.size)x\(slot.size)", "scale": "\(slot.scale)x", "filename": name])
}
// iconutil wants only the PNGs; an asset catalogue wants Contents.json too.
if outDir.pathExtension == "appiconset" {
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: outDir.appendingPathComponent("Contents.json"))
}
print("Wrote \(slots.count) \(chosen.id) icon sizes to \(outDir.path)")

if let brandPath = option("--brand") {
    let brand = URL(fileURLWithPath: brandPath)
    try FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)
    for v in variants {
        try write(bitmap(width: 1024, height: 1024) { drawIcon($0, size: 1024, variant: v) },
                  to: brand.appendingPathComponent("kagami-icon-\(v.id).png"))
    }
    try write(bitmap(width: 1040, height: 480) { drawLockup($0, width: 1040, height: 480, dark: false, variant: chosen) },
              to: brand.appendingPathComponent("kagami-lockup.png"))
    try write(bitmap(width: 1040, height: 480) { drawLockup($0, width: 1040, height: 480, dark: true, variant: chosen) },
              to: brand.appendingPathComponent("kagami-lockup-dark.png"))
    try write(bitmap(width: 2400, height: 1400) { drawSheet($0, width: 2400, height: 1400, hero: chosen) },
              to: brand.appendingPathComponent("kagami-brand-sheet.png"))
    try write(bitmap(width: 2800, height: 1240) { drawAlternates($0, width: 2800, height: 1240) },
              to: brand.appendingPathComponent("kagami-alternates.png"))
    print("Wrote brand assets to \(brand.path)")
}
