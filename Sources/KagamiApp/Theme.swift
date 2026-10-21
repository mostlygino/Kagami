import AppKit
import KagamiCore
import SwiftUI

// Colour code: the dataviz reference categorical palette in its validated order
// (worst adjacent CVD ΔE 9.1 light / 8.4 dark). Families stack in this order everywhere,
// and every colour is always shown next to the family's name.
extension ProtoFamily {
    static let stackOrder: [ProtoFamily] = [.tcp, .tls, .dns, .http, .quic, .icmp, .udp, .arp, .other]

    var color: Color {
        switch self {
        case .tcp: .dynamic(light: 0x2A78D6, dark: 0x3987E5)
        case .tls: .dynamic(light: 0xEB6834, dark: 0xD95926)
        case .dns: .dynamic(light: 0x1BAF7A, dark: 0x199E70)
        case .http: .dynamic(light: 0xEDA100, dark: 0xC98500)
        case .quic: .dynamic(light: 0xE87BA4, dark: 0xD55181)
        case .icmp: .dynamic(light: 0x008300, dark: 0x008300)
        case .udp: .dynamic(light: 0x6250D6, dark: 0x9085E9)
        case .arp: .dynamic(light: 0xE34948, dark: 0xE66767)
        case .other: .dynamic(light: 0x8A8984, dark: 0x6F6E69)
        }
    }

    var nsColor: NSColor { NSColor(color) }

    var symbol: String {
        switch self {
        case .tcp: "arrow.left.arrow.right"
        case .tls: "lock"
        case .dns: "signpost.right"
        case .http: "globe"
        case .quic: "bolt"
        case .icmp: "dot.radiowaves.left.and.right"
        case .udp: "paperplane"
        case .arp: "point.3.connected.trianglepath.dotted"
        case .other: "circle.dashed"
        }
    }
}

// Verdigris: the theme, taken from the icon's oxidised bronze mirror.
//   verdigris (Color.kagami)  actions, links, focus, active filters, the brand
//   bronze                    whatever you have selected: a row, a field, a palette choice
//   ground / raised           slate surfaces with a trace of green, never pure grey
//   the protocol colour code  data only, unchanged
extension Color {
    /// Verdigris, the tint. Dark #3FB8A6 on the dark ground is 8:1; light #127F6E on white is 4.8:1.
    static let kagami = Color.dynamic(light: 0x127F6E, dark: 0x3FB8A6)
    /// Verdigris as a fill under white text (buttons, segmented thumbs): 4.9:1 in both appearances.
    static let kagamiFill = Color.dynamic(light: 0x127F6E, dark: 0x127F6E)
    /// Bronze, for selection.
    static let bronze = Color.dynamic(light: 0xA2672B, dark: 0xD6A35E)
    /// The content ground: slate with a trace of verdigris.
    static let ground = Color.dynamic(light: 0xF6F8F7, dark: 0x121719)
    /// Panels that sit above the ground: the inspector, cards.
    static let raised = Color.dynamic(light: 0xFFFFFF, dark: 0x171E21)
    /// Hairline rules on the ground.
    static let rule = Color.dynamic(light: 0xDDE3E1, dark: 0x263034)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil ? dark : light
            return NSColor(hex: dark)
        })
    }
}

/// The mirror's sheen: a one-pixel line of light under the toolbar, brightest left of centre.
struct Sheen: View {
    var body: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: Color.kagami.opacity(0.55), location: 0.32),
                               .init(color: Color.bronze.opacity(0.35), location: 0.62), .init(color: .clear, location: 1)],
                       startPoint: .leading, endPoint: .trailing)
            .frame(height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// "daeeff" style colours from sharkd.
    convenience init?(hexString: String) {
        guard let v = UInt32(hexString, radix: 16) else { return nil }
        self.init(hex: v)
    }
}

/// A protocol label with its colour mark beside it; the text stays in text colour.
struct ProtoChip: View {
    let proto: String
    let family: ProtoFamily

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(family.color)
                .frame(width: 8, height: 8)
            Text(proto)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

extension Int {
    /// Counts written the way engineers write them, in every locale: no separator below 10 000, then
    /// narrow-space groups ("209 482"). A count never reads as a decimal beside "1.9 MB".
    var grouped: String {
        let digits = String(abs(self))
        guard digits.count > 4 else { return String(self) }
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append("\u{202F}") }
            out.append(c)
        }
        return self < 0 ? "-" + out : out
    }
}

enum Format {
    /// "53.1 KB": decimal units with a dot in every locale, so sizes read like the times beside them.
    static func bytes(_ n: Int) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var v = Double(n), i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        if i == 0 { return "\(n) bytes" }
        return (v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)) + " " + units[i]
    }

    /// Chart axis time: one format along the whole axis.
    static func axisTime(_ s: Double, span: Double) -> String {
        span < 60 ? String(format: "%.1f s", s) : String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    static func duration(_ s: Double) -> String {
        if s < 1 { return String(format: "%.0f ms", s * 1000) }
        if s < 60 { return String(format: "%.1f s", s) }
        let m = Int(s) / 60, sec = Int(s) % 60
        return m < 60 ? String(format: "%d:%02d", m, sec) : String(format: "%d:%02d:%02d", m / 60, m % 60, sec)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1 ? "0" : bytes(Int(bytesPerSecond)) + "/s"
    }
}

/// How the packet table colours rows.
enum RowColouring: String, CaseIterable, Identifiable {
    case protocols, wireshark, off
    var id: Self { self }
    var title: String {
        switch self {
        case .protocols: "Protocol colours"
        case .wireshark: "Wireshark colouring rules"
        case .off: "No colouring"
        }
    }
}

enum TimeDisplay: String, CaseIterable, Identifiable {
    case relative, delta, clock
    var id: Self { self }
    var title: String {
        switch self {
        case .relative: "Seconds since start"
        case .delta: "Seconds since previous packet"
        case .clock: "Time of day"
        }
    }
}
