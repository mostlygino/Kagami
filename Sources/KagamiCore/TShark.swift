import Foundation

// Every dissection goes through Wireshark's own binaries. Arguments are always an argv array, never a shell string.

public struct TSharkError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }

    public static let missing = TSharkError("Wireshark's tshark was not found. Install Wireshark from wireshark.org or with `brew install --cask wireshark`.")
}

public enum TShark {
    static let searchDirs = ["/Applications/Wireshark.app/Contents/MacOS", "/opt/homebrew/bin", "/usr/local/bin"]

    static func locate(_ name: String) -> URL? {
        if let override = ProcessInfo.processInfo.environment["KAGAMI_WIRESHARK_DIR"] {
            let u = URL(fileURLWithPath: override).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        return searchDirs.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static var url: URL? { locate("tshark") }
    public static var sharkdURL: URL? { locate("sharkd") }
    public static var dftestURL: URL? { locate("dftest") }

    /// nil when `filter` is a valid display filter, else Wireshark's message. Uses dftest, which
    /// compiles the filter without reading any file.
    public static func filterError(_ filter: String) async throws -> String? {
        let o = try await run([filter], tool: dftestURL ?? url, limit: 20)
        guard o.status != 0 else { return nil }
        let lines = (o.err + String(decoding: o.out, as: UTF8.self)).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let message = lines.first { !$0.isEmpty && !$0.hasPrefix("^") && $0 != filter && !$0.hasPrefix("Filter:") }
        return message.map { $0.replacingOccurrences(of: "dftest: ", with: "").replacingOccurrences(of: "tshark: ", with: "") } ?? "Invalid display filter."
    }

    public static func version() async -> String? {
        guard let o = try? await run(["-v"]) else { return nil }
        return String(decoding: o.out, as: UTF8.self).split(separator: "\n").first.map(String.init)
    }

    // MARK: Fields

    /// Info goes last: it is the only column that can contain a tab.
    public static let fields = [
        "frame.number", "frame.time_relative", "frame.time_epoch", "_ws.col.def_src", "_ws.col.def_dst",
        "_ws.col.protocol", "frame.len", "tcp.stream", "udp.stream", "tcp.srcport", "tcp.dstport",
        "udp.srcport", "udp.dstport", "tls.handshake.extensions_server_name", "http.host", "dns.qry.name",
    ] + TCPIssues.ordered.map(\.1) + ["frame.comment", "frame.darwin.process_info.pname", "_ws.col.info"]

    public static let fieldArgs = ["-T", "fields", "-E", "separator=/t", "-E", "occurrence=f"] + fields.flatMap { ["-e", $0] }

    // MARK: Running

    public struct Output: Sendable { public let out: Data; public let err: String; public let status: Int32 }

    /// Longest any one tshark run may take before it is stopped. The CLI and MCP server lower it.
    nonisolated(unsafe) public static var timeout: TimeInterval = 600

    /// Runs a Wireshark tool to completion. Cancelling the task or passing `timeout` terminates it.
    public static func run(_ args: [String], tool: URL? = url, limit: TimeInterval? = nil) async throws -> Output {
        guard let tool else { throw TSharkError.missing }
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let limit = limit ?? timeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                DispatchQueue.global().async { c.resume(with: Result { try runBlocking(p, limit: limit) }) }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
    }

    private static func runBlocking(_ p: Process, limit: TimeInterval) throws -> Output {
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: watchdog)
        defer { watchdog.cancel() }
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()  // drain both pipes so a full one never blocks tshark
        group.wait()
        p.waitUntilExit()
        if p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGTERM {
            throw TSharkError("\(p.executableURL?.lastPathComponent ?? "tshark") was stopped: it ran longer than \(Int(limit)) seconds or was cancelled.")
        }
        return Output(out: outData, err: String(decoding: errData, as: UTF8.self), status: p.terminationStatus)
    }

    /// Runs tshark and throws its last stderr line on a non-zero exit.
    public static func checked(_ args: [String], tool: URL? = url) async throws -> Data {
        let o = try await run(args, tool: tool)
        guard o.status == 0 else { throw TSharkError(lastLine(o.err) ?? "tshark exited with \(o.status)") }
        return o.out
    }

    public static func lastLine(_ s: String) -> String? {
        s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("^") && !$0.hasPrefix("Capturing on") && !$0.hasSuffix("packets captured") && !$0.hasSuffix("packet captured") }
    }

    /// Starts tshark and streams parsed rows while it runs. Used for live capture and for loading files,
    /// so a big file fills the table as it is read. `onEnd` gets the exit status and the last error line.
    public static func stream(_ args: [String], onRows: @escaping @Sendable ([Packet]) -> Void,
                              onEnd: @escaping @Sendable (Int32, String?) -> Void) throws -> Process {
        guard let url else { throw TSharkError.missing }
        let p = Process()
        p.executableURL = url
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        let rows = LineBuffer(keepLog: false)
        out.fileHandleForReading.readabilityHandler = { h in
            let parsed = rows.feed(h.availableData).compactMap(parseRow)
            if !parsed.isEmpty { onRows(parsed) }
        }
        let errors = LineBuffer(keepLog: true)
        err.fileHandleForReading.readabilityHandler = { h in _ = errors.feed(h.availableData) }
        p.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let rest = rows.feed(out.fileHandleForReading.readDataToEndOfFile(), flush: true).compactMap(parseRow)
            _ = errors.feed(err.fileHandleForReading.readDataToEndOfFile(), flush: true)
            if !rest.isEmpty { onRows(rest) }
            onEnd(proc.terminationStatus, lastLine(errors.log))
        }
        try p.run()
        return p
    }

    // MARK: Queries

    public static func interfaces() async throws -> [NetInterface] {
        parseInterfaces(String(decoding: try await checked(["-D"]), as: UTF8.self))
    }

    public static func packets(in file: URL, filter: String? = nil) async throws -> [Packet] {
        var args = ["-r", file.path]
        // Two passes, so filters on later frames (dns.response_in, tcp.reassembled_in) match like in Wireshark.
        if let filter, !filter.isEmpty { args += ["-2", "-Y", filter] }
        return parseRows(String(decoding: try await checked(args + fieldArgs), as: UTF8.self))
    }

    public static func matching(_ filter: String, in file: URL) async throws -> Set<Int> {
        let out = try await checked(["-r", file.path, "-2", "-Y", filter, "-T", "fields", "-e", "frame.number"])
        return Set(String(decoding: out, as: UTF8.self).split(separator: "\n").compactMap { Int($0) })
    }

    /// Detail without sharkd, used while a capture file is still being written.
    // ponytail: re-reads the file per packet; only used during live capture, sharkd takes over afterwards.
    public static func detail(frame: Int, in file: URL) async throws -> FrameDetail {
        let filter = "frame.number == \(frame)"
        async let pdml = checked(["-r", file.path, "-2", "-Y", filter, "-T", "pdml"])
        async let json = checked(["-r", file.path, "-2", "-Y", filter, "-T", "json", "-x"])
        return FrameDetail(tree: parsePDML(try await pdml), bytes: parseRawFrame(try await json))
    }

    public static func follow(_ stream: StreamRef, in file: URL) async throws -> FollowResult {
        parseFollowYAML(String(decoding: try await checked(["-r", file.path, "-q", "-z", "follow,\(stream.proto.rawValue),yaml,\(stream.index)"]), as: UTF8.self))
    }

    /// Makes a pcapng carry exactly these packet comments (1-based frame, text), in place, through
    /// editcap: existing comments go, then these are written, in batches that keep argv small.
    public static func setComments(_ comments: [(Int, String)], in file: URL) async throws {
        guard let editcap = locate("editcap") else { throw TSharkError("Wireshark's editcap was not found.") }
        let batches = comments.isEmpty ? [[]] : stride(from: 0, to: comments.count, by: 400).map { Array(comments[$0..<min($0 + 400, comments.count)]) }
        for (i, batch) in batches.enumerated() {
            let tmp = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString.prefix(6))")
            let args = (i == 0 ? ["--discard-packet-comments"] : ["--preserve-packet-comments"])
                + batch.flatMap { ["-a", "\($0.0):\($0.1.replacingOccurrences(of: "\n", with: " "))"] } + ["-F", "pcapng", file.path, tmp.path]
            do {
                _ = try await checked(args, tool: editcap)
                _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                throw error
            }
        }
    }

    public static func export(_ file: URL, to dest: URL, filter: String?, pcapng: Bool) async throws {
        guard file.resolvingSymlinksInPath() != dest.resolvingSymlinksInPath() else { throw TSharkError("Choose a different file to export to.") }
        var args = ["-r", file.path, "-w", dest.path, "-F", pcapng ? "pcapng" : "pcap"]
        if let filter, !filter.isEmpty { args += ["-2", "-Y", filter] }
        _ = try await checked(args)
    }

    // MARK: Parsers

    public static func parseInterfaces(_ text: String) -> [NetInterface] {
        text.split(separator: "\n").compactMap { line in
            guard let dot = line.firstIndex(of: ".") else { return nil }
            let rest = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            let name = String(rest.prefix { $0 != " " })
            guard !name.isEmpty, !rest.contains("remote capture"), !rest.contains("generator") else { return nil }
            return NetInterface(name: name, label: rest)
        }
    }

    public static func parseRows(_ text: String) -> [Packet] {
        text.split(separator: "\n").compactMap(parseRow)
    }

    public static func parseRow(_ line: Substring) -> Packet? {
        let f = line.split(separator: "\t", maxSplits: fields.count - 1, omittingEmptySubsequences: false)
        guard f.count == fields.count, let number = Int(f[0]) else { return nil }
        var issues: TCPIssues = []
        for (i, entry) in TCPIssues.ordered.enumerated() {
            let v = f[16 + i]
            // tcp.flags.reset prints True/False or 1/0; the analysis fields are empty unless set.
            if !v.isEmpty && v != "False" && v != "0" { issues.insert(entry.0) }
        }
        let tcpStream = Int(f[7]), udpStream = Int(f[8])
        var p = Packet(
            number: number, time: Double(f[1]) ?? 0, epoch: Double(f[2]) ?? 0,
            source: String(f[3]), destination: String(f[4]), proto: String(f[5]), length: Int(f[6]) ?? 0,
            tcpStream: tcpStream, udpStream: udpStream,
            srcPort: Int(f[9]) ?? Int(f[11]), dstPort: Int(f[10]) ?? Int(f[12]),
            host: hostName([f[13], f[14], f[15]].first { !$0.isEmpty }.map(String.init) ?? ""),
            issues: issues, process: String(f[fields.count - 2]), info: String(f[fields.count - 1]))
        p.comment = String(f[fields.count - 3])
        return p
    }

    /// "docs.example.com:8080" -> "docs.example.com", so one host groups as one. IPv6 literals stay intact.
    public static func hostName(_ h: String) -> String {
        guard let colon = h.lastIndex(of: ":"), h.firstIndex(of: ":") == colon, Int(h[h.index(after: colon)...]) != nil else { return h }
        return String(h[..<colon])
    }

    /// Parses `-z follow,<proto>,yaml,<n>`: peers, then one entry per payload with its frame number.
    public static func parseFollowYAML(_ text: String) -> FollowResult {
        var r = FollowResult()
        var peers: [Int: String] = [:]
        var peerHost = "", peerID = -1
        var frame = 0, peer = 0, time = 0.0
        var data = "", inData = false

        func flushChunk() {
            guard inData else { return }
            inData = false
            guard let bytes = Data(base64Encoded: data) else { return }
            r.chunks.append(StreamChunk(id: r.chunks.count, frame: frame, time: time,
                                        direction: peer == 0 ? .clientToServer : .serverToClient, bytes: bytes))
            data = ""
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if inData {
                if raw.hasPrefix("      ") && !line.contains(":") { data += line; continue }
                flushChunk()
            }
            if line.hasPrefix("- peer: ") { peerID = Int(line.dropFirst(8)) ?? -1 }
            else if line.hasPrefix("host: ") { peerHost = String(line.dropFirst(6)) }
            else if line.hasPrefix("port: "), peerID >= 0 {
                let host = peerHost.contains(":") ? "[\(peerHost)]" : peerHost
                peers[peerID] = "\(host):\(line.dropFirst(6))"
            }
            else if line.hasPrefix("- packet: ") { frame = Int(line.dropFirst(10)) ?? 0 }
            else if line.hasPrefix("peer: ") { peer = Int(line.dropFirst(6)) ?? 0 }
            else if line.hasPrefix("timestamp: ") { time = Double(line.dropFirst(11)) ?? 0 }
            else if line.hasPrefix("data: ") { inData = true; data = "" }
        }
        flushChunk()
        r.client = peers[0] ?? ""
        r.server = peers[1] ?? ""
        return r
    }

    static func parseRawFrame(_ json: Data) -> Data {
        guard let arr = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]],
              let layers = (arr.first?["_source"] as? [String: Any])?["layers"] as? [String: Any],
              let raw = layers["frame_raw"] as? [Any], let hex = raw.first as? String
        else { return Data() }
        return Data(hex: Substring(hex)) ?? Data()
    }

    public static func parsePDML(_ xml: Data) -> [FieldNode] {
        let d = PDMLDelegate()
        let p = XMLParser(data: xml)
        p.delegate = d
        p.parse()
        return d.roots.map { $0.freeze() }
    }
}

/// Mutable builder; frozen into `FieldNode`s once the document is parsed.
private final class PDMLNode {
    let label: String, field: String, filter: String, range: Range<Int>?, isProto: Bool
    var children: [PDMLNode] = []
    init(label: String, field: String, filter: String, range: Range<Int>?, isProto: Bool) {
        self.label = label; self.field = field; self.filter = filter; self.range = range; self.isProto = isProto
    }
    func freeze() -> FieldNode {
        FieldNode(label: label, field: field, filter: filter, range: range, isProtocol: isProto, children: children.map { $0.freeze() })
    }
}

private final class PDMLDelegate: NSObject, XMLParserDelegate {
    var roots: [PDMLNode] = []
    private var stack: [PDMLNode?] = []  // nil marks a skipped element so its end tag still pops

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        guard name == "proto" || name == "field" else { return }
        if stack.contains(where: { $0 == nil }) || a["hide"] == "yes" || a["name"] == "geninfo" { stack.append(nil); return }
        let pos = Int(a["pos"] ?? "") ?? 0, size = Int(a["size"] ?? "") ?? 0
        let field = a["name"] ?? "", show = a["show"] ?? ""
        let filter = field.isEmpty || show.isEmpty ? "" : "\(field) == \(FilterText.quote(show))"
        let node = PDMLNode(label: a["showname"] ?? a["show"] ?? field, field: field, filter: filter,
                            range: size > 0 ? pos..<(pos + size) : nil, isProto: name == "proto")
        if let parent = stack.last ?? nil { parent.children.append(node) } else { roots.append(node) }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "proto" || name == "field" { stack.removeLast() }
    }
}

public enum FilterText {
    /// Numbers, addresses and booleans go in bare; anything else is quoted.
    public static func quote(_ value: String) -> String {
        if Double(value) != nil || value.hasPrefix("0x") || value == "True" || value == "False" { return value }
        if (value.contains(":") && !value.contains(" ")) || value.allSatisfy({ $0.isNumber || $0 == "." }) { return value }
        return "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    /// Joins the parts with `and`, wrapping each in parentheses when needed.
    public static func and(_ parts: [String]) -> String {
        let p = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return p.count == 1 ? p[0] : p.map { "(\($0))" }.joined(separator: " and ")
    }
}

/// Splits a byte stream into complete lines; keeps the partial tail for the next read.
public final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private var tail = ""
    private let keepLog: Bool
    private let lock = NSLock()

    public init(keepLog: Bool) { self.keepLog = keepLog }

    /// The last few kilobytes of text seen, for error messages.
    public var log: String { lock.withLock { tail } }

    public func feed(_ data: Data, flush: Bool = false) -> [Substring] {
        lock.withLock {
            // Only the new bytes can hold the newline we are waiting for; rescanning `pending` would be quadratic.
            let hasNewline = data.contains(UInt8(ascii: "\n"))
            pending.append(data)
            let cut: Data.Index
            if flush { cut = pending.endIndex }
            else if hasNewline, let last = pending.lastIndex(of: UInt8(ascii: "\n")) { cut = last }
            else { return [] }
            let text = String(decoding: pending[pending.startIndex..<cut], as: UTF8.self)
            pending = cut < pending.endIndex ? Data(pending[pending.index(after: cut)...]) : Data()
            if keepLog {
                tail += text + "\n"
                if tail.utf8.count > 8_000 { tail = String(tail.suffix(4_000)) }
            }
            return text.split(separator: "\n")
        }
    }
}

extension Data {
    public init?(hex: Substring) {
        let u = Array(hex.utf8)
        guard u.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 97...102: c - 87
            case 65...70: c - 55
            default: nil
            }
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(u.count / 2)
        for i in stride(from: 0, to: u.count, by: 2) {
            guard let h = nibble(u[i]), let l = nibble(u[i + 1]) else { return nil }
            bytes.append(h << 4 | l)
        }
        self.init(bytes)
    }
}


// MARK: Capture files

public enum CaptureFiles {
    /// `$TMPDIR/Kagami`, private to this user.
    public static func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Kagami", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    /// A fresh, unique path for a live capture. The interface name is reduced to safe characters.
    public static func newLiveCapture(interface: String) throws -> URL {
        let safe = String(interface.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }.prefix(32))
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let short = UUID().uuidString.prefix(6)
        return try directory().appendingPathComponent("\(safe.isEmpty ? "capture" : safe)-\(stamp)-\(short).pcapng")
    }

    /// Removes live captures older than `age` from earlier sessions.
    public static func sweep(olderThan age: TimeInterval = 24 * 3600) {
        guard let dir = try? directory(),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for f in files where f.pathExtension == "pcapng" {
            if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < cutoff {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    /// Owner read/write only: captures hold private traffic.
    public static func makePrivate(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
