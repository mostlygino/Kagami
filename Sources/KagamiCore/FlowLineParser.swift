import Darwin
import Foundation

/// Reads flow records one line at a time, so files of any size stream through. The first meaningful line
/// decides the format: nfdump `-o raw` blocks, nfdump `-o line` columns, Zeek TSV, JSON lines, or a
/// delimited table with a header (CSV, TSV, AWS VPC flow logs, nfdump `-o csv`).
struct LineParser {
    enum Mode { case unknown, table, nfdumpRaw, nfdumpLine, jsonLines }

    private(set) var records: [FlowRecord] = []
    private var mode = Mode.unknown
    private var label: String?
    private var header: [String] = []
    private var separator: Character = ","
    private var raw = RawRecord()
    let limit: Int

    init(label: String? = nil, limit: Int = FlowFiles.recordLimit) {
        self.label = label
        self.limit = limit
    }

    var isFull: Bool { records.count >= limit }

    /// One line as bytes. nfdump's raw blocks are parsed on the bytes; other formats get a String.
    mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
        if mode == .nfdumpRaw { rawLine(bytes); return }
        feed(Substring(String(decoding: bytes, as: UTF8.self)))
    }

    mutating func feed(_ line: Substring) {
        if line.hasPrefix("#") {
            // Zeek: "#fields<TAB>ts<TAB>uid<TAB>id.orig_h…"; other # lines are comments.
            if line.hasPrefix("#fields") {
                header = line.split(separator: "\t").dropFirst().map { FlowFiles.norm(String($0)) }
                separator = "\t"
                mode = .table
                label = label ?? "Zeek conn.log"
            }
            return
        }
        let t = line.drop { $0 == " " || $0 == "\t" || $0 == "\r" }
        guard !t.isEmpty else { return }
        switch mode {
        case .unknown: detect(line, trimmed: t)
        case .nfdumpRaw: var copy = String(t); copy.withUTF8 { rawLine($0) }
        case .nfdumpLine: columnLine(t)
        case .table: tableLine(line)
        case .jsonLines: jsonLine(t)
        }
    }

    /// Flushes the last nfdump raw block.
    mutating func finish() {
        if mode == .nfdumpRaw { flushRaw() }
    }

    private mutating func append(_ r: FlowRecord?) {
        if let r, records.count < limit { records.append(r) }
    }

    // MARK: Detecting the format

    private mutating func detect(_ line: Substring, trimmed t: Substring) {
        if t.hasPrefix("Flow Record:") { mode = .nfdumpRaw; label = label ?? "nfdump"; return }
        if t.hasPrefix("Date first seen") || t.hasPrefix("Date flow start") {
            // The columns after the destination: "Packets Bytes Flows", or "Flags Tos Packets Bytes pps bps Bpp Flows".
            let after = t.range(of: "Dst IP Addr:Port").map { t[$0.upperBound...] } ?? ""
            header = after.split(separator: " ").map { FlowFiles.norm(String($0)) }
            mode = .nfdumpLine
            label = label ?? "nfdump"
            return
        }
        if t.first == "{" {
            mode = .jsonLines
            label = label ?? "JSON"
            jsonLine(t)
            return
        }
        separator = line.contains("\t") ? "\t" : line.contains(",") ? "," : " "
        let names = FlowFiles.split(line, separator).map(FlowFiles.norm)
        guard names.contains(where: FlowFiles.aliases.source.contains) else { return }
        header = names
        mode = .table
        label = label ?? (names.contains("logstatus") ? "VPC flow log" : separator == "," ? "CSV" : "TSV")
    }

    // MARK: Delimited tables and JSON lines

    private mutating func tableLine(_ line: Substring) {
        let cells = FlowFiles.split(line, separator)
        guard cells.count == header.count else { return }  // summaries and footers
        var row: [String: String] = [:]
        for (k, v) in zip(header, cells) where v != "-" && v != "(empty)" && !v.isEmpty { row[k] = v }
        append(FlowFiles.record(row, id: records.count, label: label ?? "CSV"))
    }

    private mutating func jsonLine(_ t: Substring) {
        guard let o = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any] else { return }
        var flat: [String: String] = [:]
        FlowFiles.flatten(o, into: &flat)
        append(FlowFiles.record(flat, id: records.count, label: label ?? "JSON"))
    }

    // MARK: nfdump -o raw

    /// The fields of one "Flow Record:" block that Kagami shows; the rest are skipped without allocating.
    private struct RawRecord {
        var src: String?, dst: String?, sport: String?, dport: String?, proto: String?, flags: String?
        var packets: String?, bytes: String?, first: String?, last: String?
        var ident: String?, router: String?, input: String?, output: String?, srcAS: String?, dstAS: String?
        var isEmpty: Bool { src == nil && dst == nil }
    }

    /// "  src addr     =          192.0.2.30": key, then the value; nfdump appends readable forms after the
    /// first word ("6 TCP", "0x10 ...A....", "1726… [2024-…]"), which are dropped.
    private mutating func rawLine(_ line: UnsafeBufferPointer<UInt8>) {
        var i = 0
        while i < line.count, line[i] == 32 || line[i] == 9 { i += 1 }
        let t = UnsafeBufferPointer(rebasing: line[i...])
        if Self.starts(t, "Flow Record:") { flushRaw(); return }
        guard let eq = t.firstIndex(of: 61) else { return }  // "="
        var keyEnd = eq
        while keyEnd > 0, t[keyEnd - 1] == 32 { keyEnd -= 1 }
        let key = UnsafeBufferPointer(rebasing: t[..<keyEnd])
        var v = eq + 1
        while v < t.count, t[v] == 32 { v += 1 }
        var valueEnd = t.count
        while valueEnd > v, t[valueEnd - 1] == 32 || t[valueEnd - 1] == 9 { valueEnd -= 1 }
        let value = UnsafeBufferPointer(rebasing: t[v..<valueEnd])
        let wordEnd = value.firstIndex(of: 32) ?? value.count
        func whole() -> String { String(decoding: value, as: UTF8.self) }
        func word() -> String { String(decoding: UnsafeBufferPointer(rebasing: value[..<wordEnd]), as: UTF8.self) }
        switch key.count {
        case 4 where Self.equal(key, "last"): raw.last = word()
        case 5 where Self.equal(key, "first"): raw.first = word()
        case 5 where Self.equal(key, "proto"): raw.proto = word()
        case 5 where Self.equal(key, "Ident"): raw.ident = whole()
        case 5 where Self.equal(key, "input"): raw.input = word()
        case 6 where Self.equal(key, "output"): raw.output = word()
        case 6 where Self.equal(key, "src as"): raw.srcAS = word()
        case 6 where Self.equal(key, "dst as"): raw.dstAS = word()
        case 8 where Self.equal(key, "src addr"): raw.src = whole()
        case 8 where Self.equal(key, "dst addr"): raw.dst = whole()
        case 8 where Self.equal(key, "src port"): raw.sport = word()
        case 8 where Self.equal(key, "dst port"): raw.dport = word()
        case 8 where Self.equal(key, "in bytes"): raw.bytes = word()
        case 9 where Self.equal(key, "tcp flags"): raw.flags = word()
        case 9 where Self.equal(key, "ip router"): raw.router = whole()
        case 10 where Self.equal(key, "in packets"): raw.packets = word()
        case 11 where Self.equal(key, "ip exporter"): raw.router = whole()
        default: break
        }
    }

    private static func equal(_ b: UnsafeBufferPointer<UInt8>, _ s: StaticString) -> Bool {
        b.count == s.utf8CodeUnitCount && memcmp(b.baseAddress!, s.utf8Start, b.count) == 0
    }

    private static func starts(_ b: UnsafeBufferPointer<UInt8>, _ s: StaticString) -> Bool {
        b.count >= s.utf8CodeUnitCount && memcmp(b.baseAddress!, s.utf8Start, s.utf8CodeUnitCount) == 0
    }

    private mutating func flushRaw() {
        defer { raw = RawRecord() }
        guard !raw.isEmpty, let src = raw.src, let dst = raw.dst else { return }
        var duration: Double?
        if let f = raw.first.flatMap({ Double($0) }), let l = raw.last.flatMap({ Double($0) }), l >= f { duration = (l - f) / 1000 }
        func sub(_ s: String?) -> Substring? { s.map { Substring($0) } }
        append(FlowFiles.make(id: records.count, exporter: sub(raw.router ?? raw.ident), version: label ?? "nfdump",
                              source: Substring(src), destination: Substring(dst), sourcePort: sub(raw.sport), destinationPort: sub(raw.dport),
                              proto: sub(raw.proto), packets: sub(raw.packets), bytes: sub(raw.bytes), duration: duration, tcpFlags: sub(raw.flags),
                              input: sub(raw.input), output: sub(raw.output), sourceAS: sub(raw.srcAS), destinationAS: sub(raw.dstAS),
                              start: raw.first.flatMap { Double($0) }.map { $0 / 1000 }))
    }

    // MARK: nfdump -o line

    /// "2024-09-14 10:00:00.083  00:00:12.345 TCP  192.0.2.1:443 -> 198.51.100.7:51000  12  1.2 M  1"
    private mutating func columnLine(_ t: Substring) {
        guard t.first?.isNumber == true else { return }  // the summary and its friends
        let tokens = t.split(separator: " ")
        guard let arrow = tokens.firstIndex(of: "->"), arrow >= 4, arrow + 1 < tokens.count else { return }
        let (src, sport) = Self.addressPort(tokens[arrow - 1])
        let (dst, dport) = Self.addressPort(tokens[arrow + 1])
        // Numbers may carry a unit word: "1.2 M". Fold it into the number before lining values up with the header.
        var values: [String] = []
        for tok in tokens[(arrow + 2)...] {
            if let scale = Self.units[tok], let last = values.last, let n = Double(last) {
                values[values.count - 1] = String(Int(n * scale))
            } else {
                values.append(String(tok))
            }
        }
        var col: [String: String] = [:]
        for (k, v) in zip(header, values) { col[k] = v }
        append(FlowFiles.make(id: records.count, exporter: nil, version: label ?? "nfdump",
                              source: src, destination: dst, sourcePort: sport, destinationPort: dport, proto: tokens[arrow - 2],
                              packets: col["packets"].map { Substring($0) }, bytes: col["bytes"].map { Substring($0) },
                              duration: Self.clock(tokens[2]), tcpFlags: col["flags"].map { Substring($0) },
                              input: nil, output: nil, sourceAS: nil, destinationAS: nil,
                              start: FlowFiles.date("\(tokens[0]) \(tokens[1])")))
    }

    // ponytail: nfdump scales by 1000; the numbers it prints this way are already rounded.
    static let units: [Substring: Double] = ["K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12]

    /// "192.0.2.1:443", or nfdump's IPv6 form "2001:db8::1.443".
    static func addressPort(_ s: Substring) -> (Substring, Substring?) {
        let colons = s.reduce(0) { $0 + ($1 == ":" ? 1 : 0) }
        let cut = colons > 1 ? s.lastIndex(of: ".") : s.lastIndex(of: ":")
        guard let cut else { return (s, nil) }
        return (s[..<cut], s[s.index(after: cut)...])
    }

    /// "00:01:02.345" or "62.345" in seconds.
    static func clock(_ s: Substring) -> Double? {
        s.split(separator: ":").reduce(Double?(0)) { acc, part in acc.flatMap { a in Double(part).map { a * 60 + $0 } } }
    }
}

extension FlowFiles {
    /// A record from fields already picked out (the nfdump text formats); skips the alias lookup that tables need.
    static func make(id: Int, exporter: Substring?, version: String, source: Substring, destination: Substring,
                     sourcePort: Substring?, destinationPort: Substring?, proto: Substring?, packets: Substring?, bytes: Substring?,
                     duration: Double?, tcpFlags: Substring?, input: Substring?, output: Substring?,
                     sourceAS: Substring?, destinationAS: Substring?, start: Double? = nil) -> FlowRecord? {
        let src = String(source), dst = String(destination)
        guard Endpoints.family(src) != 0, Endpoints.family(dst) != 0 else { return nil }
        func n(_ s: Substring?) -> Int? { s.flatMap { Int($0) ?? int(String($0)) } }
        return FlowRecord(
            id: id, frame: 0, exporter: exporter.map(String.init) ?? "", version: version, source: src, destination: dst,
            sourcePort: n(sourcePort), destinationPort: n(destinationPort), proto: proto.flatMap { protocolNumber(String($0)) },
            packets: n(packets) ?? 0, bytes: n(bytes) ?? 0, duration: duration,
            tcpFlags: tcpFlags.map { flagsHex(String($0)) } ?? "",
            inputInterface: n(input), outputInterface: n(output), sourceAS: n(sourceAS), destinationAS: n(destinationAS), start: start)
    }
}

private extension Substring {
    var trimmingTrailingSpaces: Substring {
        var s = self
        while let c = s.last, c == " " || c == "\r" || c == "\t" { s = s.dropLast() }
        return s
    }
}
