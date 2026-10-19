import Foundation

/// Flow records stored as files rather than captured as packets: nfdump's nfcapd files and its text
/// output (-o raw, -o line), CSV and TSV exports (nfdump, pmacct, AWS VPC flow logs), JSON and JSON lines
/// (goflow2, pmacct, nfdump, Elastic) and Zeek conn.log. Columns are found by name, so any export with a
/// header line works. Text is streamed, so a multi-gigabyte export reads in one pass.
public enum FlowFiles {
    public enum Kind: Equatable, Sendable {
        /// Packets: anything Wireshark reads (pcap, pcapng, snoop, ERF, compressed captures…).
        case capture
        /// nfdump's binary nfcapd format, or a folder of them; read through the `nfdump` tool.
        case nfdump
        /// A text flow export, possibly gzip-compressed.
        case text(gzipped: Bool)
    }

    /// Looks at the first bytes, not the name, except to tell a gzipped log from a gzipped capture.
    public static func kind(of url: URL) -> Kind {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return .nfdump }
        guard let h = try? FileHandle(forReadingFrom: url) else { return .capture }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 4096)) ?? Data()
        let b = [UInt8](head.prefix(4))
        guard b.count >= 2 else { return .capture }
        if b[0] == 0x0C && b[1] == 0xA5 { return .nfdump }
        if b[0] == 0x1F && b[1] == 0x8B {
            let inner = url.deletingPathExtension().pathExtension.lowercased()
            return ["log", "csv", "tsv", "txt", "json", "jsonl", "ndjson", "netflow", "nfdump"].contains(inner) ? .text(gzipped: true) : .capture
        }
        return looksLikeText(head) ? .text(gzipped: false) : .capture
    }

    static func looksLikeText(_ d: Data) -> Bool {
        guard !d.isEmpty, !d.contains(0) else { return false }
        let printable = d.filter { $0 >= 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }.count
        return Double(printable) / Double(d.count) > 0.97
    }

    /// Most records read from one file. Text exports are streamed, so file size itself has no limit.
    public static let recordLimit = 5_000_000
    /// Largest JSON document (one array, not JSON lines) read whole.
    public static let jsonDocumentLimit = 1_024 * 1_048_576

    /// What a flow file held, and whether reading stopped at `recordLimit`.
    public struct Loaded: Sendable {
        public let records: [FlowRecord]
        public let truncated: Bool
    }

    public static func read(_ url: URL) async throws -> [FlowRecord] { try await load(url).records }

    /// Reads a flow file. `progress` gets the share of the file read so far (0…1) for plain files.
    public static func load(_ url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Loaded {
        switch kind(of: url) {
        case .capture:
            throw TSharkError("\(url.lastPathComponent) is a packet capture, not a flow file.")
        case .nfdump:
            guard let tool = nfdumpURL else {
                throw TSharkError("\(url.lastPathComponent) is an nfdump file. Install nfdump to read it (brew install nfdump), then open it again.")
            }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let o = try await TShark.run([isDir.boolValue ? "-R" : "-r", url.path, "-o", "json", "-c", String(recordLimit)], tool: tool)
            guard o.status == 0 else { throw TSharkError(TShark.lastLine(o.err) ?? "nfdump could not read \(url.lastPathComponent).") }
            let records = parse(String(decoding: o.out, as: UTF8.self), label: "nfdump")
            return Loaded(records: records, truncated: records.count >= recordLimit)
        case .text(let gzipped):
            let head = (try? FileHandle(forReadingFrom: url).read(upToCount: 64)) ?? Data()
            let opensArray = !gzipped && String(decoding: head, as: UTF8.self).drop { $0.isWhitespace }.first == "["
            var parser = LineParser()
            if !opensArray {
                try await streamLines(url, gzipped: gzipped, progress: progress) { parser.feed($0); return !parser.isFull }
                parser.finish()
            }
            if parser.records.isEmpty && !gzipped {
                // One JSON document (an array, or an object wrapping one) can only be read whole.
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size <= jsonDocumentLimit, opensArray || String(decoding: head, as: UTF8.self).drop(while: { $0.isWhitespace }).first == "{" {
                    let records = parseJSON(String(decoding: try Data(contentsOf: url, options: .mappedIfSafe), as: UTF8.self), label: "JSON")
                    if !records.isEmpty { return Loaded(records: records, truncated: records.count >= recordLimit) }
                } else if opensArray {
                    throw TSharkError("\(url.lastPathComponent) is one JSON document of \(size / 1_048_576) MB; Kagami reads those up to \(jsonDocumentLimit / 1_048_576) MB. JSON lines (one record per line) have no limit.")
                }
            }
            guard !parser.records.isEmpty else {
                throw TSharkError("Kagami found no flow records in \(url.lastPathComponent). It reads nfdump text output (-o raw, -o line, -o csv, -o json), CSV, TSV, JSON and Zeek conn.log exports that name their columns.")
            }
            return Loaded(records: parser.records, truncated: parser.isFull)
        }
    }

    /// Feeds `body` every line of the file as raw bytes, decompressing on the way if needed, in 8 MB blocks;
    /// `body` returns false to stop. Bytes, not Strings: a multi-gigabyte export has tens of millions of lines.
    static func streamLines(_ url: URL, gzipped: Bool, progress: (@Sendable (Double) -> Void)?,
                            _ body: (UnsafeBufferPointer<UInt8>) -> Bool) async throws {
        let handle: FileHandle
        var gunzip: Process?
        if gzipped {
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            p.arguments = ["-dc", url.path]
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            try p.run()
            gunzip = p
            handle = pipe.fileHandleForReading
        } else {
            handle = try FileHandle(forReadingFrom: url)
        }
        defer { try? handle.close(); if let gunzip, gunzip.isRunning { gunzip.terminate() } }
        let total = Double((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var buffer: [UInt8] = []
        var read = 0.0, lastReport = 0.0
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 8 << 20) ?? Data()
            let atEnd = chunk.isEmpty
            buffer.append(contentsOf: chunk)
            read += Double(chunk.count)
            // Every complete line in the buffer; at the end, the last line without its newline too.
            var consumed = 0, stop = false
            buffer.withUnsafeBufferPointer { all in
                var start = 0
                while start < all.count {
                    let rest = UnsafeBufferPointer(rebasing: all[start...])
                    guard let nl = rest.firstIndex(of: 10) else {
                        if atEnd { _ = body(trimCR(rest)) ; start = all.count }
                        break
                    }
                    if !body(trimCR(UnsafeBufferPointer(rebasing: rest[..<nl]))) { stop = true; return }
                    start += nl + 1
                }
                consumed = start
            }
            if stop || atEnd { return }
            buffer.removeFirst(consumed)
            if let progress, total > 0, !gzipped, read / total - lastReport > 0.01 { lastReport = read / total; progress(min(1, lastReport)) }
        }
    }

    private static func trimCR(_ b: UnsafeBufferPointer<UInt8>) -> UnsafeBufferPointer<UInt8> {
        b.last == 13 ? UnsafeBufferPointer(rebasing: b.dropLast()) : b
    }

    static var nfdumpURL: URL? {
        let env = ProcessInfo.processInfo.environment
        let dirs = [env["KAGAMI_NFDUMP_DIR"], "/opt/homebrew/bin", "/usr/local/bin"].compactMap { $0 }
            + (env["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.map { URL(fileURLWithPath: $0).appendingPathComponent("nfdump") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: Parsing

    /// Parses text already in memory: a JSON document, or any of the line formats `LineParser` knows.
    public static func parse(_ text: String, label: String? = nil) -> [FlowRecord] {
        if text.drop(while: { $0.isWhitespace }).first == "[" { return parseJSON(text, label: label ?? "JSON") }
        var parser = LineParser(label: label)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) { parser.feed(line); if parser.isFull { break } }
        parser.finish()
        if parser.records.isEmpty, text.drop(while: { $0.isWhitespace }).first == "{" { return parseJSON(text, label: label ?? "JSON") }
        return parser.records
    }

    static func parseJSON(_ text: String, label: String) -> [FlowRecord] {
        var objects: [[String: Any]] = []
        if let whole = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
            objects = jsonRecords(whole)
        } else {
            // JSON lines: one record per line.
            for line in text.split(whereSeparator: \.isNewline) {
                if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] { objects.append(o) }
            }
        }
        var out: [FlowRecord] = []
        for o in objects.prefix(recordLimit) {
            var flat: [String: String] = [:]
            flatten(o, into: &flat)
            if let r = record(flat, id: out.count, label: label) { out.append(r) }
        }
        return out
    }

    /// The flow objects in a JSON document: the array itself, or the first array of objects inside a wrapper.
    static func jsonRecords(_ node: Any) -> [[String: Any]] {
        if let a = node as? [[String: Any]] { return a }
        if let d = node as? [String: Any] {
            for key in d.keys.sorted() { let found = jsonRecords(d[key]!); if !found.isEmpty { return found } }
            return [d]
        }
        return []
    }

    /// Nested objects become dotted keys: Elastic's {"source": {"ip": …}} reads as "source.ip".
    static func flatten(_ node: [String: Any], prefix: String = "", into out: inout [String: String]) {
        for (k, v) in node {
            let key = prefix.isEmpty ? k : "\(prefix).\(k)"
            switch v {
            case let d as [String: Any]: flatten(d, prefix: key, into: &out)
            case let s as String: out[norm(key)] = s
            case let n as NSNumber: out[norm(key)] = n.stringValue
            default: continue
            }
        }
    }

    /// Splits one line; commas honour double quotes, other separators collapse runs of spaces.
    static func split(_ line: Substring, _ sep: Character) -> [String] {
        if sep == " " { return line.split(separator: " ").map(String.init) }
        if sep == "\t" { return line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        var cells: [String] = [], cur = "", quoted = false
        var it = line.makeIterator()
        while let c = it.next() {
            if c == "\"" { quoted.toggle() }
            else if c == sep && !quoted { cells.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" }
            else { cur.append(c) }
        }
        cells.append(cur.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: Columns

    /// Lower case, letters and digits only: "id.orig_h", "SrcAddr" and "src_addr" all compare plainly.
    static func norm(_ key: String) -> String { String(key.lowercased().filter { $0.isLetter || $0.isNumber }) }

    /// Accepted names per field, already normalised. A `+` joins columns that are summed (Zeek counts each side).
    enum aliases {
        static let source = ["srcaddr", "src4addr", "src6addr", "sa", "srcip", "sourceip", "src", "source", "ipsrc", "idorigh",
                                  "ipv4srcaddr", "ipv6srcaddr", "sourceipv4address", "sourceipv6address", "sourceaddress", "srcaddrv6"]
        static let destination = ["dstaddr", "dst4addr", "dst6addr", "da", "dstip", "destinationip", "dst", "destination", "ipdst",
                                       "idresph", "ipv4dstaddr", "ipv6dstaddr", "destinationipv4address", "destinationipv6address",
                                       "destinationaddress", "dstaddrv6"]
        static let sourcePort = ["srcport", "sp", "sport", "sourceport", "portsrc", "idorigp", "l4srcport", "sourcetransportport"]
        static let destinationPort = ["dstport", "dp", "dport", "destinationport", "portdst", "idrespp", "l4dstport", "destinationtransportport"]
        static let proto = ["proto", "pr", "protocol", "ipproto", "protocolidentifier", "networktransport", "networkianatransport"]
        static let packets = ["packets", "ipkt", "inpackets", "pkts", "inpkts", "packetdeltacount", "networkpackets", "origpkts+resppkts"]
        static let bytes = ["bytes", "ibyt", "inbytes", "octets", "inoctets", "octetdeltacount", "bytecount", "networkbytes",
                            "origipbytes+respipbytes", "origbytes+respbytes"]
        static let tcpFlags = ["tcpflags", "flg", "flags", "tcpcontrolbits"]
        static let input = ["inputsnmp", "in", "inif", "inputint", "ingressinterface", "inputinterface"]
        static let output = ["outputsnmp", "out", "outif", "outputint", "egressinterface", "outputinterface"]
        static let sourceAS = ["srcas", "sas", "assrc", "bgpsourceasnumber", "srcasn", "sourceas"]
        static let destinationAS = ["dstas", "das", "asdst", "bgpdestinationasnumber", "dstasn", "destinationas"]
        static let exporter = ["ip4router", "ip6router", "ra", "exporter", "sampleraddress", "peeripsrc", "netflowexporteraddress",
                               "exporteraddress", "interfaceid"]
        static let duration: [(String, Double)] = [("duration", 1), ("td", 1), ("flowdurationmilliseconds", 0.001), ("eventduration", 1e-9)]
        /// Start and end columns, with the factor that turns a numeric value into seconds.
        static let span: [(String, String, Double)] = [
            ("first", "last", 1), ("ts", "te", 1), ("firstseen", "lastseen", 1), ("start", "end", 1),
            ("timeflowstartns", "timeflowendns", 1e-9), ("timeflowstartms", "timeflowendms", 0.001), ("timeflowstart", "timeflowend", 1),
            ("flowstartmilliseconds", "flowendmilliseconds", 0.001), ("flowstartseconds", "flowendseconds", 1),
            ("timestampstart", "timestampend", 1), ("eventstart", "eventend", 1),
        ]
    }

    static func record(_ row: [String: String], id: Int, label: String) -> FlowRecord? {
        func value(_ names: some Sequence<String>) -> String? {
            for n in names {
                if n.contains("+") {
                    let parts = n.split(separator: "+").compactMap { row[String($0)].flatMap(int) }
                    if !parts.isEmpty { return String(parts.reduce(0, +)) }
                } else if let v = row[n] { return v }
            }
            return nil
        }
        func number(_ names: [String]) -> Int? { value(names).flatMap(int) }
        guard let src = value(aliases.source), let dst = value(aliases.destination),
              Endpoints.family(src) != 0, Endpoints.family(dst) != 0 else { return nil }
        let typeLabel = row["type"].flatMap(Self.flowType)
        return FlowRecord(
            id: id, frame: 0, exporter: value(aliases.exporter) ?? "", version: typeLabel ?? label,
            source: src, destination: dst,
            sourcePort: number(aliases.sourcePort), destinationPort: number(aliases.destinationPort),
            proto: value(aliases.proto).flatMap(protocolNumber),
            packets: number(aliases.packets) ?? 0, bytes: number(aliases.bytes) ?? 0,
            duration: duration(row), tcpFlags: value(aliases.tcpFlags).map(flagsHex) ?? "",
            inputInterface: number(aliases.input), outputInterface: number(aliases.output),
            sourceAS: number(aliases.sourceAS), destinationAS: number(aliases.destinationAS), start: startTime(row))
    }

    /// "123", "123.0" and "1.2e3" as whole numbers.
    static func int(_ s: String) -> Int? { Int(s) ?? Double(s).flatMap { $0.isFinite && abs($0) < 9e18 ? Int($0) : nil } }

    static func protocolNumber(_ s: String) -> Int? {
        if let n = Int(s) { return n }
        switch s.lowercased() {
        case "tcp": return 6
        case "udp": return 17
        case "icmp": return 1
        case "icmpv6", "ipv6-icmp", "icmp6": return 58
        case "gre": return 47
        case "esp": return 50
        case "sctp": return 132
        default: return nil
        }
    }

    /// TCP flags as "0x1b", from a number or nfdump's "...AP.SF" letters.
    static func flagsHex(_ s: String) -> String {
        if s.hasPrefix("0x") { return s }
        if let n = Int(s) { return String(format: "0x%02x", n) }
        let bits: [Character: Int] = ["C": 0x80, "E": 0x40, "U": 0x20, "A": 0x10, "P": 0x08, "R": 0x04, "S": 0x02, "F": 0x01]
        let letters = s.uppercased().filter { $0 != "." }
        guard !letters.isEmpty, letters.allSatisfy({ bits[$0] != nil }) else { return "" }
        return String(format: "0x%02x", letters.reduce(0) { $0 | bits[$1]! })
    }

    static func flowType(_ s: String) -> String? {
        switch s.uppercased() {
        case "IPFIX": "IPFIX"
        case "NETFLOW_V5": "NetFlow v5"
        case "NETFLOW_V9": "NetFlow v9"
        case "SFLOW_5": "sFlow v5"
        default: nil
        }
    }

    static func duration(_ row: [String: String]) -> Double? {
        for (k, scale) in aliases.duration { if let v = row[k].flatMap(Double.init), v >= 0 { return v * scale } }
        for (a, b, scale) in aliases.span {
            guard let s = row[a], let e = row[b] else { continue }
            if let x = Double(s), let y = Double(e) { return y >= x ? (y - x) * scale : nil }
            if let x = date(s), let y = date(e) { return y >= x ? y - x : nil }
        }
        return nil
    }

    static func startTime(_ row: [String: String]) -> Double? {
        for (a, _, scale) in aliases.span {
            guard let v = row[a] else { continue }
            if let n = Double(v) { return n * scale }
            if let d = date(v) { return d }
        }
        return nil
    }

    private static let dateFormats: [DateFormatter] = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss",
    ].map { f in
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.timeZone = .current  // nfdump and most tools write local time without a zone; zoned forms carry their own
        d.dateFormat = f
        return d
    }

    /// Seconds since 1970 for the date formats flow tools write; a date without a zone is read as this Mac's local time.
    static func date(_ s: String) -> Double? {
        // DateFormatter wants at most three fractional digits; Elastic and goflow2 write nine.
        let trimmed = s.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        for f in dateFormats { if let d = f.date(from: trimmed) { return d.timeIntervalSince1970 } }
        return nil
    }
}
