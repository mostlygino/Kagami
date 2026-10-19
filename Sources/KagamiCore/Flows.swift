import Foundation

/// One flow record from a NetFlow v5/v9 or IPFIX export, as a router or firewall reported it.
public struct FlowRecord: Identifiable, Hashable, Sendable {
    public let id: Int
    /// The packet in the capture that carried this record.
    public let frame: Int
    public let exporter: String
    public let version: String
    public let source: String
    public let destination: String
    public let sourcePort: Int?
    public let destinationPort: Int?
    public let proto: Int?
    public let packets: Int
    public let bytes: Int
    /// How long the flow lasted, from the record's own start and end.
    public let duration: Double?
    public let tcpFlags: String
    public let inputInterface: Int?
    public let outputInterface: Int?
    public let sourceAS: Int?
    public let destinationAS: Int?
    /// When the flow started, in seconds since 1970, if the source says.
    public var start: Double? = nil

    public var protoName: String { Self.protoName(proto) }

    public static func protoName(_ proto: Int?) -> String {
        switch proto {
        case 1: "ICMP"
        case 6: "TCP"
        case 17: "UDP"
        case 47: "GRE"
        case 50: "ESP"
        case 58: "ICMPv6"
        case let p?: "IP \(p)"
        case nil: "–"
        }
    }

    /// "192.0.2.10:51000", with brackets for IPv6.
    public static func endpoint(_ addr: String, _ port: Int?) -> String {
        guard let port else { return addr }
        return addr.contains(":") ? "[\(addr)]:\(port)" : "\(addr):\(port)"
    }

    public var sourceEndpoint: String { Self.endpoint(source, sourcePort) }
    public var destinationEndpoint: String { Self.endpoint(destination, destinationPort) }
}

public enum Flows {
    /// UDP ports Wireshark decodes as flow exports without help: NetFlow 2055/9995/9996, IPFIX 4739.
    public static let defaultPorts = [2055, 4739, 9995, 9996]
    /// sFlow (6343) is decoded in the packet list; its samples are packet headers, not flow records.
    public static let collectorFilter = "udp port 2055 or udp port 4739 or udp port 9995 or udp port 9996 or udp port 6343"

    /// Reads every flow record in a capture, or in a flow file (`FlowFiles`). `extraPorts` decodes exports
    /// sent to other UDP ports in a capture.
    public static func read(_ file: URL, extraPorts: [Int] = []) async throws -> [FlowRecord] {
        if FlowFiles.kind(of: file) != .capture { return try await FlowFiles.read(file) }
        var args = ["-r", file.path, "-Y", "cflow", "-T", "json"]
        for p in extraPorts where (1...65535).contains(p) { args += ["-d", "udp.port==\(p),cflow"] }
        return parse(try await TShark.checked(args))
    }

    public static func parse(_ json: Data) -> [FlowRecord] {
        guard let packets = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return [] }
        var out: [FlowRecord] = []
        for packet in packets {
            guard let layers = (packet["_source"] as? [String: Any])?["layers"] as? [String: Any] else { continue }
            let frame = Int(((layers["frame"] as? [String: Any])?["frame.number"] as? String) ?? "") ?? 0
            let ip = (layers["ip"] as? [String: Any]) ?? (layers["ipv6"] as? [String: Any]) ?? [:]
            let exporter = (ip["ip.src"] as? String) ?? (ip["ipv6.src"] as? String) ?? ""
            guard let cflow = layers["cflow"] else { continue }
            let version = findVersion(cflow) ?? ""
            for record in records(in: cflow) {
                func s(_ k: String) -> String? { record[k] as? String }
                func i(_ k: String) -> Int? { s(k).flatMap { Int($0) } }
                let src = s("cflow.srcaddr") ?? s("cflow.srcaddrv6") ?? ""
                let dst = s("cflow.dstaddr") ?? s("cflow.dstaddrv6") ?? ""
                guard !src.isEmpty || !dst.isEmpty else { continue }
                out.append(FlowRecord(
                    id: out.count, frame: frame, exporter: exporter, version: version, source: src, destination: dst,
                    sourcePort: i("cflow.srcport"), destinationPort: i("cflow.dstport"), proto: i("cflow.protocol"),
                    packets: i("cflow.packets") ?? i("cflow.packets64") ?? 0, bytes: i("cflow.octets") ?? i("cflow.octets64") ?? 0,
                    duration: s("cflow.timedelta").flatMap(Double.init), tcpFlags: s("cflow.tcpflags") ?? "",
                    inputInterface: i("cflow.inputint"), outputInterface: i("cflow.outputint"),
                    sourceAS: i("cflow.srcas"), destinationAS: i("cflow.dstas")))
            }
        }
        return out
    }

    /// Every object in the cflow tree that holds an address: one per flow record.
    static func records(in node: Any) -> [[String: Any]] {
        if let d = node as? [String: Any] {
            if d["cflow.srcaddr"] != nil || d["cflow.srcaddrv6"] != nil || d["cflow.dstaddr"] != nil || d["cflow.dstaddrv6"] != nil { return [d] }
            return d.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }).flatMap { records(in: d[$0]!) }
        }
        if let a = node as? [Any] { return a.flatMap(records) }
        return []
    }

    static func findVersion(_ node: Any) -> String? {
        if let d = node as? [String: Any] {
            if let v = d["cflow.version"] as? String { return v == "10" ? "IPFIX" : "NetFlow v\(v)" }
            for v in d.values { if let found = findVersion(v) { return found } }
        }
        return nil
    }

    // MARK: Summaries

    public struct Talker: Identifiable, Sendable {
        public let pair: String
        public let bytes: Int
        public let packets: Int
        public let flows: Int
        public var id: String { pair }
    }

    /// Source and destination address pairs by bytes, both directions folded together.
    public static func topTalkers(_ flows: [FlowRecord], limit: Int = 10) -> [Talker] {
        var t: [String: (Int, Int, Int)] = [:]
        for f in flows {
            let key = [f.source, f.destination].sorted().joined(separator: " ⇄ ")
            t[key, default: (0, 0, 0)].0 += f.bytes
            t[key, default: (0, 0, 0)].1 += f.packets
            t[key, default: (0, 0, 0)].2 += 1
        }
        return t.map { Talker(pair: $0.key, bytes: $0.value.0, packets: $0.value.1, flows: $0.value.2) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.pair < $1.pair }
            .prefix(limit).map { $0 }
    }
}
