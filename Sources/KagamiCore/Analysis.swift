import Darwin
import Foundation

// MARK: Protocol families

/// The protocol colour code. Every view that colours traffic goes through this, and every
/// colour is shown next to the family's name.
public enum ProtoFamily: String, CaseIterable, Identifiable, Codable, Sendable {
    case tls, http, quic, dns, tcp, udp, icmp, arp, other
    public var id: Self { self }

    public var title: String {
        switch self {
        case .tls: "TLS"
        case .http: "HTTP"
        case .quic: "QUIC"
        case .dns: "DNS"
        case .tcp: "TCP"
        case .udp: "UDP"
        case .icmp: "ICMP"
        case .arp: "ARP"
        case .other: "Other"
        }
    }

    /// Display filter that selects the family in Wireshark syntax.
    public var filter: String {
        switch self {
        case .tls: "tls"
        case .http: "http or http2"
        case .quic: "quic"
        case .dns: "dns or mdns or llmnr"
        case .tcp: "tcp"
        case .udp: "udp"
        case .icmp: "icmp or icmpv6"
        case .arp: "arp"
        case .other: "not (tcp or udp or icmp or icmpv6 or arp)"
        }
    }

    public static func of(_ p: Packet) -> ProtoFamily { classify(p.proto, tcp: p.tcpStream != nil, udp: p.udpStream != nil) }

    public static func classify(_ proto: String, tcp: Bool, udp: Bool) -> ProtoFamily {
        let p = proto.lowercased()
        if p.hasPrefix("tls") || p.hasPrefix("ssl") { return .tls }
        if p.hasPrefix("http") { return .http }
        if p.hasPrefix("quic") { return .quic }
        if p == "dns" || p == "mdns" || p == "llmnr" || p == "nbns" { return .dns }
        if p.hasPrefix("icmp") { return .icmp }
        if p == "arp" || p == "rarp" { return .arp }
        if p == "tcp" || tcp { return .tcp }
        if p == "udp" || udp { return .udp }
        return .other
    }
}

// MARK: Grouping

public enum Grouping {
    /// The best name for each stream: TLS SNI or HTTP Host seen anywhere in it.
    public static func streamHosts(_ packets: [Packet]) -> [StreamRef: String] {
        var out: [StreamRef: String] = [:]
        for p in packets where !p.host.isEmpty {
            if let s = p.stream, out[s] == nil, p.udpStream == nil || p.proto.lowercased().hasPrefix("quic") { out[s] = p.host }
        }
        return out
    }

    public static func host(of p: Packet, in streamHosts: [StreamRef: String]) -> String {
        if let s = p.stream, let h = streamHosts[s] { return h }
        return p.host
    }

    /// Counts per key, most first, ties by name.
    public static func counted(_ keys: some Sequence<String>) -> [(name: String, count: Int)] {
        var c: [String: Int] = [:]
        for k in keys where !k.isEmpty { c[k, default: 0] += 1 }
        return c.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    }
}

// MARK: Statistics

public struct CaptureStats: Sendable {
    public struct Family: Identifiable, Sendable { public let family: ProtoFamily; public let packets: Int; public let bytes: Int; public var id: ProtoFamily { family } }
    public struct Bucket: Identifiable, Sendable {
        public let start: Double; public let family: ProtoFamily; public let bytes: Int; public let packets: Int
        public var id: String { "\(start)-\(family.rawValue)" }
        public init(start: Double, family: ProtoFamily, bytes: Int, packets: Int) { self.start = start; self.family = family; self.bytes = bytes; self.packets = packets }
    }
    public struct Ranked: Identifiable, Sendable { public let name: String; public let packets: Int; public let bytes: Int; public var id: String { name } }
    public struct Issue: Identifiable, Sendable { public let issue: TCPIssues; public let label: String; public let filter: String; public let count: Int; public var id: String { label } }

    public let packets: Int
    public let bytes: Int
    public let duration: Double
    public let bucketSize: Double
    public let families: [Family]
    public let timeline: [Bucket]
    public let hosts: [Ranked]
    public let ports: [Ranked]
    public let issues: [Issue]
    public let conversations: Int

    public init(_ packets: [Packet], buckets: Int = 90) {
        self.packets = packets.count
        bytes = packets.reduce(0) { $0 + $1.length }
        let t0 = packets.map(\.time).min() ?? 0, t1 = packets.map(\.time).max() ?? 0
        duration = max(0, t1 - t0)
        // Round the bucket to a readable step so the axis reads "per 100 ms", not "per 87.3 ms".
        let raw = max(duration / Double(buckets), 0.001)
        let steps: [Double] = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let size = steps.first { $0 >= raw } ?? 3600
        bucketSize = size

        var fam: [ProtoFamily: (Int, Int)] = [:]
        var buck: [Int: [ProtoFamily: (Int, Int)]] = [:]
        var hostMap: [String: (Int, Int)] = [:]
        var portMap: [String: (Int, Int)] = [:]
        var streams = Set<StreamRef>()
        let names = Grouping.streamHosts(packets)
        for p in packets {
            let f = ProtoFamily.of(p)
            fam[f, default: (0, 0)].0 += 1
            fam[f, default: (0, 0)].1 += p.length
            let b = Int(((p.time - t0) / size).rounded(.down))
            buck[b, default: [:]][f, default: (0, 0)].0 += 1
            buck[b, default: [:]][f, default: (0, 0)].1 += p.length
            let h = Grouping.host(of: p, in: names)
            if !h.isEmpty { hostMap[h, default: (0, 0)].0 += 1; hostMap[h, default: (0, 0)].1 += p.length }
            if let port = Self.servicePort(p) {
                let key = "\(p.udpStream != nil ? "UDP" : "TCP") \(port)"
                portMap[key, default: (0, 0)].0 += 1; portMap[key, default: (0, 0)].1 += p.length
            }
            if let s = p.stream { streams.insert(s) }
        }
        families = fam.map { Family(family: $0.key, packets: $0.value.0, bytes: $0.value.1) }.sorted { $0.bytes > $1.bytes }
        timeline = buck.sorted { $0.key < $1.key }.flatMap { b in
            b.value.map { Bucket(start: Double(b.key) * size, family: $0.key, bytes: $0.value.1, packets: $0.value.0) }
        }
        hosts = hostMap.map { Ranked(name: $0.key, packets: $0.value.0, bytes: $0.value.1) }.sorted { $0.bytes > $1.bytes }
        ports = portMap.map { Ranked(name: $0.key, packets: $0.value.0, bytes: $0.value.1) }.sorted { $0.packets > $1.packets }
        issues = TCPIssues.ordered.map { entry in
            let filter = entry.1 == "tcp.flags.reset" ? "tcp.flags.reset == 1" : entry.1
            return Issue(issue: entry.0, label: entry.2, filter: filter, count: packets.lazy.filter { $0.issues.contains(entry.0) }.count)
        }
        conversations = streams.count
    }

    /// The well-known side of a conversation: the lower port, which is nearly always the service.
    static func servicePort(_ p: Packet) -> Int? {
        switch (p.srcPort, p.dstPort) {
        case let (s?, d?): min(s, d)
        case let (s?, nil): s
        case let (nil, d?): d
        default: nil
        }
    }
}

// MARK: Diff

public enum LineDiff {
    public enum Kind: Sendable { case same, removed, added, changed }

    public struct Row: Identifiable, Sendable {
        public let id: Int
        public let kind: Kind
        public let left: String?
        public let right: String?
    }

    /// Unified rows: same, removed and added lines in reading order.
    public static func unified(_ a: [String], _ b: [String]) -> [Row] {
        let d = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in d {
            switch c {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var rows: [Row] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { rows.append(Row(id: rows.count, kind: .removed, left: a[i], right: nil)); i += 1 }
            else if j < b.count, inserted.contains(j) { rows.append(Row(id: rows.count, kind: .added, left: nil, right: b[j])); j += 1 }
            else if i < a.count, j < b.count { rows.append(Row(id: rows.count, kind: .same, left: a[i], right: b[j])); i += 1; j += 1 }
            else if i < a.count { rows.append(Row(id: rows.count, kind: .removed, left: a[i], right: nil)); i += 1 }
            else { rows.append(Row(id: rows.count, kind: .added, left: nil, right: b[j])); j += 1 }
        }
        return rows
    }

    /// Side-by-side rows: a run of removals next to the following run of additions becomes `changed` pairs.
    public static func sideBySide(_ a: [String], _ b: [String]) -> [Row] {
        let u = unified(a, b)
        var rows: [Row] = []
        var k = 0
        while k < u.count {
            guard u[k].kind == .removed else { rows.append(Row(id: rows.count, kind: u[k].kind, left: u[k].left, right: u[k].right)); k += 1; continue }
            var dels: [String] = [], adds: [String] = []
            while k < u.count, u[k].kind == .removed { dels.append(u[k].left!); k += 1 }
            while k < u.count, u[k].kind == .added { adds.append(u[k].right!); k += 1 }
            for n in 0..<max(dels.count, adds.count) {
                let l = n < dels.count ? dels[n] : nil, r = n < adds.count ? adds[n] : nil
                rows.append(Row(id: rows.count, kind: l != nil && r != nil ? .changed : (l != nil ? .removed : .added), left: l, right: r))
            }
        }
        return rows
    }

    /// The protocol tree as indented lines, for comparing two packets field by field.
    public static func lines(_ tree: [FieldNode]) -> [String] {
        func walk(_ n: FieldNode, _ depth: Int) -> [String] {
            [String(repeating: "  ", count: depth) + n.label] + n.children.flatMap { walk($0, depth + 1) }
        }
        return tree.flatMap { walk($0, 0) }
    }

    /// Bytes as 16-per-line hex dump lines.
    public static func hexLines(_ data: Data) -> [String] {
        let b = [UInt8](data)
        return stride(from: 0, to: b.count, by: 16).map { start in
            let row = b[start..<min(start + 16, b.count)]
            return String(format: "%04x  ", start) + row.map { String(format: "%02x", $0) }.joined(separator: " ")
        }
    }
}

// MARK: Processes

/// Maps local ports to the processes that own them, from `lsof -F`. Only sees the current user's
/// processes; capturing per-process metadata for everything needs Apple's pktap and root.
public enum ProcessMap {
    public static func snapshot() async -> [Int: String] {
        guard let o = try? await TShark.run(["-nP", "-iTCP", "-iUDP", "-F", "pcn"], tool: URL(fileURLWithPath: "/usr/sbin/lsof")) else { return [:] }
        return parse(String(decoding: o.out, as: UTF8.self))
    }

    /// `lsof -F pcn` output: `p<pid>`, `c<command>`, then `n<local>[-><remote>]` per socket.
    public static func parse(_ text: String) -> [Int: String] {
        var out: [Int: String] = [:]
        var command = ""
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            switch tag {
            case "c": command = String(value)
            case "n":
                let local = value.split(separator: "-", maxSplits: 1).first ?? value
                if let colon = local.lastIndex(of: ":"), let port = Int(local[local.index(after: colon)...]), out[port] == nil {
                    out[port] = command
                }
            default: break
            }
        }
        return out
    }
}

// MARK: Interface activity

/// Byte counters per interface from `getifaddrs`, for the start screen's activity lines. No root needed.
public enum InterfaceCounters {
    public static func snapshot() -> [String: UInt64] {
        var out: [String: UInt64] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            let ifa = p.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                out[String(cString: ifa.ifa_name)] = UInt64(d.ifi_ibytes) + UInt64(d.ifi_obytes)
            }
            cur = ifa.ifa_next
        }
        return out
    }
}
