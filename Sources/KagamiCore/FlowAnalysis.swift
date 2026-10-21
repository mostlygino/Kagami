import Foundation

/// Narrows a list of flows: by host, by conversation, by service port, protocol or exporter. Every set
/// condition must hold.
public struct FlowFilter: Equatable, Hashable, Sendable {
    public var host: String?
    /// Both ends of one conversation, in either direction.
    public var pair: [String]?
    public var port: Int?
    public var proto: Int?
    public var exporter: String?

    public init(host: String? = nil, pair: [String]? = nil, port: Int? = nil, proto: Int? = nil, exporter: String? = nil) {
        self.host = host; self.pair = pair; self.port = port; self.proto = proto; self.exporter = exporter
    }

    public var isEmpty: Bool { self == FlowFilter() }

    public func matches(_ f: FlowRecord) -> Bool {
        if let host, f.source != host && f.destination != host { return false }
        if let pair, pair.count == 2, !((f.source == pair[0] && f.destination == pair[1]) || (f.source == pair[1] && f.destination == pair[0])) { return false }
        if let port, f.sourcePort != port && f.destinationPort != port { return false }
        if let proto, f.proto != proto { return false }
        if let exporter, f.exporter != exporter { return false }
        return true
    }

    /// The same selection in nfdump's filter language, to take back to the collector.
    public var nfdump: String {
        var parts: [String] = []
        if let host { parts.append("host \(host)") }
        if let pair, pair.count == 2 { parts.append("host \(pair[0]) and host \(pair[1])") }
        if let port { parts.append("port \(port)") }
        if let proto { parts.append("proto \(proto)") }
        return parts.joined(separator: " and ")
    }
}

extension FlowRecord {
    /// The port that names the service: the lower of the two (443 rather than 51515).
    public var servicePort: Int? {
        switch (sourcePort, destinationPort) {
        case let (s?, d?): min(s, d)
        case let (s?, nil): s
        case let (nil, d?): d
        default: nil
        }
    }

    public var end: Double? { start.map { $0 + (duration ?? 0) } }
}

/// Totals and rankings over a set of flows, worked out in one pass.
public struct FlowSummary: Sendable {
    public struct Item: Identifiable, Sendable, Hashable {
        public let key: String
        public let bytes: Int
        public let packets: Int
        public let flows: Int
        public var id: String { key }
    }

    public let count: Int
    public let bytes: Int
    public let packets: Int
    public let exporters: [Item]
    public let formats: [String]
    public let talkers: [Flows.Talker]
    public let sources: [Item]
    public let destinations: [Item]
    /// Keys like "TCP 443".
    public let ports: [Item]
    /// Keys are protocol numbers as text.
    public let protocols: [Item]
    public let first: Double?
    public let last: Double?
    /// Which optional fields any record carries; columns nobody fills stay hidden.
    public let hasFlags: Bool, hasInterfaces: Bool, hasAS: Bool

    public init(_ flows: [FlowRecord], top: Int = 10) {
        var src: [String: (Int, Int, Int)] = [:], dst = src, port = src, proto = src, exp = src
        var formats: Set<String> = []
        var bytes = 0, packets = 0
        var first = Double.infinity, last = -Double.infinity
        var hasFlags = false, hasInterfaces = false, hasAS = false
        func add(_ d: inout [String: (Int, Int, Int)], _ k: String, _ f: FlowRecord) {
            d[k, default: (0, 0, 0)].0 += f.bytes
            d[k, default: (0, 0, 0)].1 += f.packets
            d[k, default: (0, 0, 0)].2 += 1
        }
        for f in flows {
            bytes += f.bytes; packets += f.packets
            add(&src, f.source, f)
            add(&dst, f.destination, f)
            if let p = f.servicePort { add(&port, "\(f.protoName) \(p)", f) }
            add(&proto, f.proto.map(String.init) ?? "", f)
            if !f.exporter.isEmpty { add(&exp, f.exporter, f) }
            formats.insert(f.version)
            if let s = f.start { first = min(first, s); last = max(last, f.end ?? s) }
            if !hasFlags, let v = Int(f.tcpFlags.dropFirst(2), radix: 16), v != 0 { hasFlags = true }
            if !hasInterfaces, f.inputInterface != nil || f.outputInterface != nil { hasInterfaces = true }
            if !hasAS, (f.sourceAS ?? 0) != 0 || (f.destinationAS ?? 0) != 0 { hasAS = true }
        }
        self.hasFlags = hasFlags
        self.hasInterfaces = hasInterfaces
        self.hasAS = hasAS
        func ranked(_ d: [String: (Int, Int, Int)], _ n: Int) -> [Item] {
            d.map { Item(key: $0.key, bytes: $0.value.0, packets: $0.value.1, flows: $0.value.2) }
                .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.key < $1.key }
                .prefix(n).map { $0 }
        }
        count = flows.count
        self.bytes = bytes
        self.packets = packets
        exporters = ranked(exp, 50)
        self.formats = formats.sorted()
        talkers = Flows.topTalkers(flows, limit: 6)
        sources = ranked(src, top)
        destinations = ranked(dst, top)
        ports = ranked(port, top)
        protocols = ranked(proto, 12)
        self.first = first.isFinite ? first : nil
        self.last = last.isFinite ? last : nil
    }
}
