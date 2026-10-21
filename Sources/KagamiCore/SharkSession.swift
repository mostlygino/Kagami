import Foundation

/// A long-lived `sharkd` holding one capture file in memory. Answers detail, filter and match
/// queries in milliseconds instead of re-reading the file per click.
///
/// sharkd speaks newline-delimited JSON-RPC 2.0 on stdin/stdout. Responses are matched by id,
/// so overlapping callers never receive each other's answers.
public actor SharkSession {
    public nonisolated let file: URL
    private let process: Process
    private let input: FileHandle
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextID = 1
    private var closed = false

    public static var isAvailable: Bool { TShark.sharkdURL != nil }
    public static let stoppedMessage = "sharkd stopped."

    public init(file: URL) async throws {
        guard let sharkd = TShark.sharkdURL else { throw TSharkError("Wireshark's sharkd was not found.") }
        self.file = file
        let p = Process()
        p.executableURL = sharkd
        p.arguments = ["-"]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        process = p
        input = inPipe.fileHandleForWriting

        let lines = LineBuffer(keepLog: false)
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil }
            for line in lines.feed(data) where line.first == "{" {
                let d = Data(line.utf8)
                Task { await self?.deliver(d) }
            }
        }
        p.terminationHandler = { [weak self] _ in Task { await self?.failAll() } }
        try p.run()

        let r = try await call("load", ["file": file.path])
        guard (r["status"] as? String) == "OK" else { throw TSharkError("sharkd could not load \(file.lastPathComponent).") }
    }

    deinit { if process.isRunning { process.terminate() } }

    public func close() {
        closed = true
        if process.isRunning { process.terminate() }
        failAll()
    }

    // MARK: RPC

    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        guard !closed, process.isRunning else { throw TSharkError(Self.stoppedMessage) }
        let id = nextID
        nextID += 1
        var req: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty { req["params"] = params }
        var line = try JSONSerialization.data(withJSONObject: req)
        line.append(0x0A)
        return try await withCheckedThrowingContinuation { c in
            pending[id] = c
            do { try input.write(contentsOf: line) } catch {
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
    }

    private func deliver(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = obj["id"] as? Int, let c = pending.removeValue(forKey: id) else { return }
        if let err = obj["error"] as? [String: Any] {
            c.resume(throwing: TSharkError(Self.clean(err["message"] as? String ?? "sharkd error")))
        } else {
            // Some methods answer with an array; wrap so every caller gets a dictionary.
            c.resume(returning: (obj["result"] as? [String: Any]) ?? ["items": obj["result"] ?? []])
        }
    }

    private func failAll() {
        let all = pending
        pending = [:]
        for c in all.values { c.resume(throwing: TSharkError(Self.stoppedMessage)) }
    }

    static func clean(_ message: String) -> String {
        message.replacingOccurrences(of: "Filter invalid - ", with: "")
    }

    // MARK: Queries

    /// nil when the display filter is valid, otherwise the parser's message.
    public func check(_ filter: String) async throws -> String? {
        do { _ = try await call("check", ["filter": filter]); return nil }
        catch let e as TSharkError where e.message != Self.stoppedMessage { return e.message }
    }

    public func matching(_ filter: String) async throws -> Set<Int> {
        let r = try await call("frames", ["filter": filter])
        let items = r["items"] as? [[String: Any]] ?? []
        return Set(items.compactMap { $0["num"] as? Int })
    }

    /// Wireshark's own colouring rules: frame number to (background, foreground) hex colours.
    public func colours() async throws -> [Int: (bg: String, fg: String)] {
        let r = try await call("frames")
        var out: [Int: (String, String)] = [:]
        for item in r["items"] as? [[String: Any]] ?? [] {
            if let n = item["num"] as? Int, let bg = item["bg"] as? String, let fg = item["fg"] as? String { out[n] = (bg, fg) }
        }
        return out
    }

    public func frame(_ number: Int) async throws -> FrameDetail {
        let r = try await call("frame", ["frame": number, "proto": true, "bytes": true])
        let bytes = (r["bytes"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
        let tree = (r["tree"] as? [[String: Any]] ?? []).map(Self.node)
        return FrameDetail(tree: tree, bytes: bytes)
    }

    static func node(_ d: [String: Any]) -> FieldNode {
        var range: Range<Int>?
        // `ds` points at another data source (reassembled payload); its offsets are not frame offsets.
        if let h = d["h"] as? [Int], h.count == 2, h[1] > 0, (d["ds"] as? Int ?? 0) == 0 { range = h[0]..<(h[0] + h[1]) }
        if d["g"] as? Bool == true { range = nil }
        return FieldNode(label: d["l"] as? String ?? "", field: d["fn"] as? String ?? "", filter: d["f"] as? String ?? "",
                         range: range, isProtocol: (d["t"] as? String) == "proto",
                         children: (d["n"] as? [[String: Any]] ?? []).map(node))
    }
}
