import Foundation
import KagamiCore

/// Every operation the CLI and the MCP server share. Inputs are checked here, once.
enum Commands {
    struct Failure: Error {
        let message: String
        let code: Int32
        static func usage(_ m: String) -> Failure { Failure(message: m, code: 2) }
        static func runtime(_ m: String) -> Failure { Failure(message: m, code: 1) }
        static func filter(_ m: String) -> Failure { Failure(message: m, code: 4) }
        static let missing = Failure(message: TSharkError.missing.message, code: 3)
    }

    static func requireWireshark() throws {
        if TShark.url == nil { throw Failure.missing }
    }

    /// Largest capture file the MCP server reads; the CLI has no limit. Override with KAGAMI_MAX_FILE_MB.
    nonisolated(unsafe) static var maxFileBytes: Int? = nil

    /// Paths from a caller must name an existing regular file (not a FIFO or device), within the size limit.
    static func captureFile(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { throw Failure.usage("No capture file at \(url.path).") }
        if let max = maxFileBytes, let size = values?.fileSize, size > max {
            throw Failure.usage("\(url.lastPathComponent) is \(size / 1_048_576) MB; the limit here is \(max / 1_048_576) MB. Split it with editcap, or raise KAGAMI_MAX_FILE_MB.")
        }
        return url
    }

    static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Output paths must not exist yet, unless overwriting was asked for, must not be symlinks, and never equal the input.
    static func outputFile(_ path: String, overwrite: Bool) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        if isSymlink(url) { throw Failure.usage("\(url.path) is a symbolic link. Write to a regular path.") }
        if FileManager.default.fileExists(atPath: url.path) && !overwrite {
            throw Failure.usage("\(url.path) already exists. Choose a new file name; Kagami does not overwrite files unless asked (--force on the command line).")
        }
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else {
            throw Failure.usage("The folder \(url.deletingLastPathComponent().path) does not exist.")
        }
        return url
    }

    /// Where MCP clients may write: one folder, never anywhere else. KAGAMI_MCP_OUTPUT_DIR moves it.
    static func mcpOutputDirectory() throws -> URL {
        let env = ProcessInfo.processInfo.environment["KAGAMI_MCP_OUTPUT_DIR"]
        let dir = env.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Kagami", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.resolvingSymlinksInPath()
    }

    /// An MCP output: only the file name of what the client asked for, inside the MCP folder, with a capture
    /// extension, created exclusively (no overwrite, no symlink follow) and private to this user.
    static func mcpOutputFile(_ requested: String) throws -> URL {
        var name = URL(fileURLWithPath: requested).lastPathComponent
        name = String(name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) })
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "export" }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext != "pcap" && ext != "pcapng" { name += ".pcapng" }
        let url = try mcpOutputDirectory().appendingPathComponent(String(name.prefix(120)))
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw Failure.usage(errno == EEXIST ? "\(url.lastPathComponent) already exists in \(url.deletingLastPathComponent().path). Choose another name."
                                                : "Could not create \(url.path): \(String(cString: strerror(errno))).")
        }
        close(fd)
        return url
    }

    static func checkFilter(_ filter: String?, in file: URL? = nil) async throws {
        guard let filter, !filter.isEmpty else { return }
        if let message = try await TShark.filterError(filter) { throw Failure.filter(message) }
    }

    // MARK: Operations

    static func interfaces() async throws -> [[String: Any]] {
        try requireWireshark()
        return try await TShark.interfaces().map { ["name": $0.name, "description": $0.friendlyName] }
    }

    static func packets(file: String, filter: String?, offset: Int, limit: Int) async throws -> [String: Any] {
        try requireWireshark()
        let url = try captureFile(file)
        try await checkFilter(filter, in: url)
        let all = try await TShark.packets(in: url, filter: filter)
        let names = Grouping.streamHosts(all)
        let page = all.dropFirst(max(0, offset)).prefix(max(0, limit))
        return ["file": url.path, "filter": filter ?? "", "matched": all.count, "offset": offset,
                "packets": page.map { json($0, host: Grouping.host(of: $0, in: names)) }]
    }

    static func json(_ p: Packet, host: String) -> [String: Any] {
        var d: [String: Any] = [
            "number": p.number, "time": p.time, "epoch": p.epoch, "source": p.source, "destination": p.destination,
            "protocol": p.proto, "family": ProtoFamily.of(p).rawValue, "length": p.length, "info": p.info,
        ]
        if !host.isEmpty { d["host"] = host }
        if let s = p.stream { d["stream"] = ["protocol": s.proto.rawValue, "index": s.index] }
        if let v = p.srcPort { d["src_port"] = v }
        if let v = p.dstPort { d["dst_port"] = v }
        if !p.issues.isEmpty { d["tcp_issues"] = p.issues.labels }
        if !p.process.isEmpty { d["process"] = p.process }
        return d
    }

    static func detail(file: String, frame: Int) async throws -> FrameDetail {
        try requireWireshark()
        let url = try captureFile(file)
        guard frame > 0 else { throw Failure.usage("Frame numbers start at 1.") }
        let d: FrameDetail
        if SharkSession.isAvailable {
            let s = try await SharkSession(file: url)
            defer { Task { await s.close() } }
            d = try await s.frame(frame)
        } else {
            d = try await TShark.detail(frame: frame, in: url)
        }
        guard !d.tree.isEmpty else { throw Failure.usage("There is no frame \(frame) in \(url.lastPathComponent).") }
        return d
    }

    static func tree(_ d: FrameDetail, bytes: Bool) -> [String: Any] {
        func node(_ n: FieldNode) -> [String: Any] {
            var o: [String: Any] = ["label": n.label]
            if !n.field.isEmpty { o["field"] = n.field }
            if !n.filter.isEmpty { o["filter"] = n.filter }
            if let r = n.range { o["offset"] = r.lowerBound; o["length"] = r.count }
            if !n.children.isEmpty { o["children"] = n.children.map(node) }
            return o
        }
        var out: [String: Any] = ["tree": d.tree.map(node), "length": d.bytes.count]
        if bytes { out["bytes_hex"] = d.bytes.map { String(format: "%02x", $0) }.joined() }
        return out
    }

    /// The tree as indented text: what Wireshark's packet details pane shows.
    static func treeText(_ d: FrameDetail) -> String {
        LineDiff.lines(d.tree).joined(separator: "\n")
    }

    static func anatomyText(_ d: FrameDetail) -> String {
        let layers = Anatomy.layers(from: d.tree)
        guard !layers.isEmpty else { return "No fixed-format headers in this packet." }
        return layers.map { "\($0.name) (bytes \($0.byteStart)–\($0.byteStart + $0.byteCount + $0.hiddenBytes - 1))\n\(Anatomy.ascii($0))" }
            .joined(separator: "\n\n")
    }

    static func follow(file: String, stream: Int, udp: Bool, format: String, maxBytes: Int) async throws -> [String: Any] {
        try requireWireshark()
        let url = try captureFile(file)
        guard stream >= 0 else { throw Failure.usage("Stream numbers start at 0.") }
        let r = try await TShark.follow(StreamRef(proto: udp ? .udp : .tcp, index: stream), in: url)
        var budget = max(0, maxBytes)
        var truncated = false
        let chunks: [[String: Any]] = r.chunks.map { c in
            let take = min(c.bytes.count, budget)
            budget -= take
            if take < c.bytes.count { truncated = true }
            let data = c.bytes.prefix(take)
            let payload: String
            switch format {
            case "hex": payload = data.map { String(format: "%02x", $0) }.joined()
            case "base64": payload = data.base64EncodedString()
            default: payload = String(decoding: data.map { ($0 >= 0x20 && $0 < 0x7f) || $0 == 0x0a || $0 == 0x09 ? $0 : UInt8(ascii: ".") }, as: UTF8.self)
            }
            return ["frame": c.frame, "time": c.time, "direction": c.direction == .clientToServer ? "client_to_server" : "server_to_client",
                    "length": c.bytes.count, "data": payload]
        }
        return ["client": r.client, "server": r.server, "format": format, "truncated": truncated, "payloads": chunks]
    }

    static func flows(file: String, ports: [Int], limit: Int) async throws -> [String: Any] {
        let url = try captureFile(file)
        if FlowFiles.kind(of: url) == .capture { try requireWireshark() }  // flow files need no Wireshark
        let all = try await Flows.read(url, extraPorts: ports)
        let records: [[String: Any]] = all.sorted { $0.bytes > $1.bytes }.prefix(max(0, limit)).map { f in
            var d: [String: Any] = ["source": f.source, "destination": f.destination, "protocol": f.protoName, "packets": f.packets,
                                    "bytes": f.bytes, "exporter": f.exporter, "version": f.version]
            if f.frame > 0 { d["frame"] = f.frame }  // flow files have no packets behind their records
            if let p = f.sourcePort { d["source_port"] = p }
            if let p = f.destinationPort { d["destination_port"] = p }
            if let v = f.duration { d["duration_seconds"] = v }
            if !f.tcpFlags.isEmpty { d["tcp_flags"] = f.tcpFlags }
            if let v = f.inputInterface { d["input_interface"] = v }
            if let v = f.outputInterface { d["output_interface"] = v }
            if let v = f.sourceAS { d["source_as"] = v }
            if let v = f.destinationAS { d["destination_as"] = v }
            return d
        }
        return ["file": url.path, "flows": all.count, "bytes": all.reduce(0) { $0 + $1.bytes },
                "top_talkers": Flows.topTalkers(all).map { ["pair": $0.pair, "bytes": $0.bytes, "packets": $0.packets, "flows": $0.flows] },
                "records": records]
    }

    static func stats(file: String, filter: String?) async throws -> [String: Any] {
        try requireWireshark()
        let url = try captureFile(file)
        try await checkFilter(filter, in: url)
        let s = CaptureStats(try await TShark.packets(in: url, filter: filter))
        return [
            "packets": s.packets, "bytes": s.bytes, "duration_seconds": s.duration, "conversations": s.conversations,
            "protocols": s.families.map { ["protocol": $0.family.rawValue, "packets": $0.packets, "bytes": $0.bytes] },
            "top_hosts": s.hosts.prefix(20).map { ["host": $0.name, "packets": $0.packets, "bytes": $0.bytes] },
            "top_service_ports": s.ports.prefix(20).map { ["port": $0.name, "packets": $0.packets, "bytes": $0.bytes] },
            "tcp_issues": Dictionary(uniqueKeysWithValues: s.issues.map { ($0.label, $0.count) }),
        ]
    }

    static func export(file: String, output: URL, filter: String?, pcap: Bool) async throws -> [String: Any] {
        try requireWireshark()
        let input = try captureFile(file)
        guard input.resolvingSymlinksInPath() != output.resolvingSymlinksInPath() else { throw Failure.usage("Export to a different file than the one you read.") }
        do {
            try await checkFilter(filter, in: input)
            try await TShark.export(input, to: output, filter: filter, pcapng: !pcap)
        } catch {
            // Don't leave the reserved (empty) file behind when nothing was written.
            if (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 0 { try? FileManager.default.removeItem(at: output) }
            throw error
        }
        CaptureFiles.makePrivate(output)
        let out = output
        let count = try await TShark.packets(in: out).count
        return ["output": out.path, "format": pcap ? "pcap" : "pcapng", "packets": count]
    }

    static func capture(interface: String, seconds: Int, count: Int?, bpf: String?, output: URL?) async throws -> [String: Any] {
        try requireWireshark()
        guard (1...3600).contains(seconds) else { throw Failure.usage("Capture duration must be 1 to 3600 seconds.") }
        if let count, count < 1 { throw Failure.usage("Packet count must be at least 1.") }
        let known = try await TShark.interfaces().map(\.name)
        guard known.contains(interface) else { throw Failure.usage("Unknown interface \(interface). Run `kagami interfaces`.") }
        let out = try output ?? CaptureFiles.newLiveCapture(interface: interface)
        var args = ["-i", interface, "-w", out.path, "-q", "-a", "duration:\(seconds)"]
        if let count { args += ["-c", String(count)] }
        if let bpf, !bpf.isEmpty { args += ["-f", bpf] }
        let o = try await TShark.run(args, limit: TimeInterval(seconds + 60))
        guard o.status == 0 else {
            let msg = TShark.lastLine(o.err) ?? "Capture failed."
            throw Failure.runtime(msg.contains("ermission") ? msg + " Install ChmodBPF (Wireshark's installer, or `brew install --cask wireshark-chmodbpf`) and log in again." : msg)
        }
        CaptureFiles.makePrivate(out)
        let packets = try await TShark.packets(in: out).count
        return ["output": out.path, "interface": interface, "seconds": seconds, "packets": packets]
    }
}
