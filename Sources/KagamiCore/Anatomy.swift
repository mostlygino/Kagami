import Foundation

/// Lays a packet's protocol headers out the way the RFCs draw them: a 32-bit ruler per row,
/// every field a box sized by its bits.
public enum Anatomy {
    public static let bitsPerRow = 32
    /// Longer layers (TLS records, DNS answers) are cut here and end in a "+N bytes" note.
    public static let maxBytesPerLayer = 64

    public struct Box: Identifiable, Hashable, Sendable {
        public let id: Int
        public let node: FieldNode?
        /// Relative to the start of the layer.
        public let bitStart: Int
        public let bitWidth: Int
        public let name: String
        public let value: String
        public var isGap: Bool { node == nil }
        public var bitEnd: Int { bitStart + bitWidth }

        /// Short name for narrow boxes.
        public var shortName: String { Anatomy.abbreviation(for: name) }

        public static func == (a: Box, b: Box) -> Bool { a.id == b.id && a.node === b.node }
        public func hash(into h: inout Hasher) { h.combine(id) }
    }

    public struct Layer: Identifiable, Sendable {
        public let id: Int
        public let node: FieldNode
        public let name: String
        public let byteStart: Int
        /// Bytes drawn (capped); `hiddenBytes` were cut.
        public let byteCount: Int
        public let hiddenBytes: Int
        public let boxes: [Box]
        public var rows: Int { (byteCount * 8 + Anatomy.bitsPerRow - 1) / Anatomy.bitsPerRow }
    }

    /// One rectangle of a box on the grid. Boxes that cross a row edge become several segments;
    /// whole rows in the middle merge into one tall segment, as RFC diagrams draw addresses.
    public struct Segment: Hashable, Sendable {
        public let row: Int
        public let rowSpan: Int
        public let bitStart: Int  // 0..<32 within the row
        public let bitEnd: Int    // 1...32 within the row
        public var bits: Int { bitEnd - bitStart }
    }

    // MARK: Layers

    /// Line-based protocols: drawn as lines, never on the bit ruler.
    public static let textProtocols: Set<String> = ["http", "sip", "smtp", "imap", "pop", "ftp", "rtsp", "ssdp", "data-text-lines", "json", "xml", "urlencoded-form", "media"]

    public static func layers(from tree: [FieldNode]) -> [Layer] {
        var out: [Layer] = []
        for proto in tree where proto.isProtocol && proto.field != "frame" && !textProtocols.contains(proto.field) {
            guard let range = proto.range, let layer = layer(proto, range: range, id: out.count) else { continue }
            out.append(layer)
        }
        return out
    }

    static func layer(_ proto: FieldNode, range: Range<Int>, id: Int) -> Layer? {
        let shown = min(range.count, maxBytesPerLayer)
        let start = range.lowerBound
        let limit = shown * 8
        var boxes: [Box] = []

        func add(_ node: FieldNode, anchor: Range<Int>?) {
            guard let r = node.range, var bits = bitRange(of: node, range: r, anchor: anchor) else { return }
            bits = (bits.lowerBound - start * 8)..<(bits.upperBound - start * 8)
            guard bits.lowerBound >= 0, bits.lowerBound < limit else { return }
            bits = bits.lowerBound..<min(bits.upperBound, limit)
            // First field in tree order wins a spot; aliases like tcp.seq_raw overlap it and are dropped.
            guard !boxes.contains(where: { $0.bitStart < bits.upperBound && bits.lowerBound < $0.bitEnd }) else { return }
            let (name, value) = split(node.label)
            boxes.append(Box(id: boxes.count, node: node, bitStart: bits.lowerBound, bitWidth: bits.count, name: name, value: value))
        }

        func walk(_ nodes: [FieldNode], parentRange: Range<Int>?) {
            for child in nodes {
                guard let r = child.range, r.lowerBound >= start, r.lowerBound < start + shown else { continue }
                let ranged = child.children.filter { $0.range != nil }
                let isFlags = bitPattern(child.label) != nil || r.count <= 2  // ip.flags, dsfield, tcp.flags; not a MAC with LG/IG bits
                if isFlags && !ranged.isEmpty && ranged.allSatisfy({ bitPattern($0.label) != nil }) {
                    for bit in ranged { add(bit, anchor: r) }          // flags: draw each bit
                } else if !ranged.isEmpty && r.count > 4 && bitPattern(child.label) == nil && tiles(ranged, r) {
                    walk(child.children, parentRange: r)               // options, records: open them up
                } else {
                    add(child, anchor: parentRange)
                }
            }
        }
        walk(proto.children, parentRange: range)

        boxes.sort { $0.bitStart < $1.bitStart }
        var filled: [Box] = []
        var cursor = 0
        for b in boxes {
            if b.bitStart > cursor { filled.append(Box(id: -1, node: nil, bitStart: cursor, bitWidth: b.bitStart - cursor, name: "", value: "")) }
            filled.append(b)
            cursor = b.bitEnd
        }
        if cursor < limit { filled.append(Box(id: -1, node: nil, bitStart: cursor, bitWidth: limit - cursor, name: "", value: "")) }
        guard filled.contains(where: { !$0.isGap }) else { return nil }
        filled = filled.enumerated().map { i, b in
            Box(id: i, node: b.node, bitStart: b.bitStart, bitWidth: b.bitWidth, name: b.name, value: b.value)
        }
        return Layer(id: id, node: proto, name: displayName(proto), byteStart: start, byteCount: shown,
                     hiddenBytes: range.count - shown, boxes: filled)
    }

    /// Children worth opening up: they sit side by side (no overlaps) and cover most of the parent.
    /// An address with OUI and flag-bit children overlaps itself, so it stays one box.
    static func tiles(_ kids: [FieldNode], _ parent: Range<Int>) -> Bool {
        let ranges = kids.compactMap(\.range).sorted { $0.lowerBound < $1.lowerBound }
        for (a, b) in zip(ranges, ranges.dropFirst()) where a.upperBound > b.lowerBound { return false }
        let covered = ranges.reduce(0) { $0 + $1.count }
        return covered * 4 >= parent.count * 3
    }

    // MARK: Bits

    /// The pattern before " = " in labels like "0100 .... = Version: 4", spaces removed.
    public static func bitPattern(_ label: String) -> String? {
        guard let eq = label.range(of: " = ") else { return nil }
        let head = label[..<eq.lowerBound]
        guard !head.isEmpty, head.allSatisfy({ "01. ".contains($0) }), head.contains(".") || head.count >= 4 else { return nil }
        let p = head.filter { $0 != " " }
        return p.isEmpty ? nil : p
    }

    /// Absolute bit range in the frame. Bit patterns are right-aligned in the field's bytes,
    /// or in the parent's bytes when the pattern is wider than the field (TCP flags: 12 bits shown on 1 byte).
    public static func bitRange(of node: FieldNode, range: Range<Int>, anchor: Range<Int>?) -> Range<Int>? {
        guard let p = bitPattern(node.label) else { return (range.lowerBound * 8)..<(range.upperBound * 8) }
        let chars = Array(p)
        let base = chars.count > range.count * 8 ? (anchor ?? range) : range
        let width = base.count * 8
        guard chars.count <= width, let first = chars.firstIndex(where: { $0 != "." }),
              let last = chars.lastIndex(where: { $0 != "." }) else { return nil }
        let offset = base.lowerBound * 8 + (width - chars.count)
        return (offset + first)..<(offset + last + 1)
    }

    // MARK: Grid

    public static func segments(of box: Box) -> [Segment] {
        var out: [Segment] = []
        var bit = box.bitStart
        while bit < box.bitEnd {
            let row = bit / bitsPerRow
            let from = bit % bitsPerRow
            let to = min(bitsPerRow, from + (box.bitEnd - bit))
            if from == 0, to == bitsPerRow, let last = out.last, last.bitStart == 0, last.bitEnd == bitsPerRow,
               last.row + last.rowSpan == row {
                out[out.count - 1] = Segment(row: last.row, rowSpan: last.rowSpan + 1, bitStart: 0, bitEnd: bitsPerRow)
            } else {
                out.append(Segment(row: row, rowSpan: 1, bitStart: from, bitEnd: to))
            }
            bit += to - from
        }
        return out
    }

    /// The segment that carries the box's label: the largest one.
    public static func labelSegment(of box: Box) -> Segment? {
        segments(of: box).max { $0.bits * $0.rowSpan < $1.bits * $1.rowSpan }
    }

    // MARK: Text

    /// "Source Port: 443" -> ("Source Port", "443"); strips the bit pattern first.
    public static func split(_ label: String) -> (String, String) {
        var text = Substring(label)
        if bitPattern(label) != nil, let eq = label.range(of: " = ") { text = label[eq.upperBound...] }
        for prefix in ["TCP Option - ", "IPv6 Option - ", "IP Option - "] where text.hasPrefix(prefix) { text = text.dropFirst(prefix.count) }
        guard let colon = text.range(of: ": ") else { return (String(text), "") }
        return (String(text[..<colon.lowerBound]), String(text[colon.upperBound...]))
    }

    /// A value short enough for a box: "1460 bytes" stays, notes in brackets go,
    /// "20 bytes (5)" becomes the raw "5" the RFC would show.
    public static func shortValue(_ v: String) -> String {
        var s = v
        for cut in [" [", "    "] { if let p = s.range(of: cut) { s = String(s[..<p.lowerBound]) } }
        if let p = s.range(of: " ("), s.hasSuffix(")"), p.lowerBound > s.startIndex {
            let inner = s[s.index(p.lowerBound, offsetBy: 2)..<s.index(before: s.endIndex)]
            s = Int(inner) != nil && s[..<p.lowerBound].contains(" ") ? String(inner) : String(s[..<p.lowerBound])
        }
        return s.count > 28 ? String(s.prefix(27)) + "…" : s
    }

    static let abbreviations: [String: String] = [
        "Version": "Ver", "Differentiated Services Codepoint": "DSCP",
        "Explicit Congestion Notification": "ECN", "Total Length": "Total Length", "Identification": "ID",
        "Reserved bit": "R", "Don't fragment": "DF", "More fragments": "MF", "Header Length": "IHL", "Fragment Offset": "Frag Offset",
        "Time to Live": "TTL", "Protocol": "Proto", "Header Checksum": "Checksum",
        "Reserved": "Rsv", "Accurate ECN": "AE", "No-Operation (NOP)": "NOP", "SACK permitted": "SACK OK",
        "Maximum segment size": "MSS", "Window scale": "WS", "Timestamps": "TS", "Congestion Window Reduced": "C", "ECN-Echo": "E",
        "Urgent": "U", "Acknowledgment": "A", "Push": "P", "Reset": "R", "Syn": "S", "Fin": "F",
        "Traffic Class": "Traffic Class", "Flow Label": "Flow Label", "Payload Length": "Payload Len",
        "Next Header": "Next Hdr", "Hop Limit": "Hops", "Kind": "Kind", "Length": "Len",
        "Content Type": "Type", "Transaction ID": "ID", "Hardware type": "HW Type", "Protocol type": "Proto Type",
        "Hardware size": "HW Size", "Protocol size": "Proto Size", "Opcode": "Op",
    ]

    public static func abbreviation(for name: String) -> String {
        if let a = abbreviations[name] { return a }
        let words = name.split(separator: " ")
        return words.count > 1 ? String(words.compactMap(\.first)).uppercased() : String(name.prefix(4))
    }

    static let names: [String: String] = [
        "eth": "Ethernet II", "ip": "IPv4", "ipv6": "IPv6", "tcp": "TCP", "udp": "UDP", "icmp": "ICMP",
        "icmpv6": "ICMPv6", "arp": "ARP", "dns": "DNS", "mdns": "mDNS", "tls": "TLS", "quic": "QUIC",
        "http": "HTTP", "null": "Loopback", "loop": "Loopback", "vlan": "802.1Q VLAN", "sll": "Linux cooked",
    ]

    public static func displayName(_ proto: FieldNode) -> String {
        names[proto.field] ?? proto.field.uppercased()
    }
}

// MARK: Plain-text diagrams

extension Anatomy {
    /// The layer as RFC-style ASCII art: two columns per bit, `+-+` rules, labels centred in their box.
    public static func ascii(_ layer: Layer) -> String {
        let bits = layer.byteCount * 8
        let rows = layer.rows
        // Which box owns each bit.
        var owner = [Int](repeating: -1, count: rows * bitsPerRow)
        for (i, b) in layer.boxes.enumerated() { for bit in b.bitStart..<min(b.bitEnd, owner.count) { owner[bit] = i } }
        // Where each box's label goes: the middle row of its largest segment.
        var labelRow: [Int: Int] = [:]
        for (i, b) in layer.boxes.enumerated() { if let s = labelSegment(of: b) { labelRow[i] = s.row + s.rowSpan / 2 } }

        func rule(_ r: Int) -> String {  // the rule above row r
            let width = min(bitsPerRow, max(0, bits - (r == rows ? (r - 1) : r) * bitsPerRow))
            var s = "+"
            for bit in 0..<width {
                let below = r < rows ? owner[r * bitsPerRow + bit] : -1
                let above = r > 0 ? owner[(r - 1) * bitsPerRow + bit] : -2
                let open = below == above && r > 0 && r < rows && (r * bitsPerRow + bit) < bits
                s += open ? " " : "-"
                let nextBelow = bit + 1 < width && r < rows ? owner[r * bitsPerRow + bit + 1] : -3
                let nextAbove = bit + 1 < width && r > 0 ? owner[(r - 1) * bitsPerRow + bit + 1] : -4
                let corner = bit + 1 == width || !open || nextBelow != below || nextAbove != above
                s += corner ? "+" : " "
            }
            return s
        }

        var out = [" 0                   1                   2                   3",
                   " 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1"]
        for r in 0..<rows {
            out.append(rule(r))
            var line = "|"
            var bit = r * bitsPerRow
            let end = min(bits, (r + 1) * bitsPerRow)
            while bit < end {
                let id = owner[bit]
                var n = 0
                while bit + n < end && owner[bit + n] == id { n += 1 }
                let width = n * 2 - 1
                var text = ""
                if id >= 0, labelRow[id] == r {
                    let b = layer.boxes[id]
                    let v = shortValue(b.value)
                    for candidate in [v.isEmpty ? b.name : "\(b.name): \(v)", v.isEmpty ? b.shortName : "\(b.shortName)=\(v)", b.name, b.shortName, String(b.shortName.prefix(1))] where !b.isGap {
                        if candidate.count <= width { text = candidate; break }
                    }
                }
                let pad = width - text.count
                line += String(repeating: " ", count: pad / 2) + text + String(repeating: " ", count: pad - pad / 2) + "|"
                bit += n
            }
            out.append(line)
        }
        out.append(rule(rows))
        if layer.hiddenBytes > 0 { out.append("  … \(layer.hiddenBytes) more bytes") }
        return out.joined(separator: "\n")
    }
}
