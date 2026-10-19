import Foundation

/// One row of the packet list, read from `tshark -T fields`.
public struct Packet: Identifiable, Hashable, Sendable {
    public let number: Int
    public let time: Double
    public let epoch: Double
    public let source: String
    public let destination: String
    public let proto: String
    public let length: Int
    public let tcpStream: Int?
    public let udpStream: Int?
    public let srcPort: Int?
    public let dstPort: Int?
    public let host: String
    public let issues: TCPIssues
    public var process: String
    /// The pcapng packet comment, if the file carries one.
    public var comment: String = ""
    public let info: String
    public var id: Int { number }

    public init(number: Int, time: Double, epoch: Double = 0, source: String, destination: String, proto: String,
                length: Int, tcpStream: Int? = nil, udpStream: Int? = nil, srcPort: Int? = nil, dstPort: Int? = nil,
                host: String = "", issues: TCPIssues = [], process: String = "", info: String) {
        self.number = number; self.time = time; self.epoch = epoch; self.source = source; self.destination = destination
        self.proto = proto; self.length = length; self.tcpStream = tcpStream; self.udpStream = udpStream
        self.srcPort = srcPort; self.dstPort = dstPort; self.host = host; self.issues = issues
        self.process = process; self.info = info
    }

    /// `tcp` / `udp` plus the stream index, when the packet belongs to a stream.
    public var stream: StreamRef? {
        if let s = tcpStream { return StreamRef(proto: .tcp, index: s) }
        if let s = udpStream { return StreamRef(proto: .udp, index: s) }
        return nil
    }
}

public struct StreamRef: Hashable, Codable, Sendable {
    public enum Proto: String, Codable, Sendable { case tcp, udp }
    public let proto: Proto
    public let index: Int
    public init(proto: Proto, index: Int) { self.proto = proto; self.index = index }
    public var filter: String { "\(proto.rawValue).stream eq \(index)" }
}

/// TCP trouble Wireshark's analysis flags on a packet.
public struct TCPIssues: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let retransmission = TCPIssues(rawValue: 1 << 0)
    public static let fastRetransmission = TCPIssues(rawValue: 1 << 1)
    public static let lostSegment = TCPIssues(rawValue: 1 << 2)
    public static let duplicateAck = TCPIssues(rawValue: 1 << 3)
    public static let zeroWindow = TCPIssues(rawValue: 1 << 4)
    public static let outOfOrder = TCPIssues(rawValue: 1 << 5)
    public static let reset = TCPIssues(rawValue: 1 << 6)

    /// Order matches the tshark fields that set them.
    public static let ordered: [(TCPIssues, String, String)] = [
        (.retransmission, "tcp.analysis.retransmission", "Retransmission"),
        (.fastRetransmission, "tcp.analysis.fast_retransmission", "Fast retransmission"),
        (.lostSegment, "tcp.analysis.lost_segment", "Lost segment"),
        (.duplicateAck, "tcp.analysis.duplicate_ack", "Duplicate ACK"),
        (.zeroWindow, "tcp.analysis.zero_window", "Zero window"),
        (.outOfOrder, "tcp.analysis.out_of_order", "Out of order"),
        (.reset, "tcp.flags.reset", "Reset"),
    ]

    public var labels: [String] { Self.ordered.filter { contains($0.0) }.map(\.2) }
    /// Serious enough to colour the row red rather than amber.
    public var isSevere: Bool { !intersection([.lostSegment, .reset, .zeroWindow]).isEmpty }
}

public struct NetInterface: Identifiable, Hashable, Sendable {
    public let name: String
    public let label: String
    public var id: String { name }
    public init(name: String, label: String) { self.name = name; self.label = label }

    /// "Wi-Fi" from "en0 (Wi-Fi)"; falls back to the device name.
    public var friendlyName: String {
        guard let open = label.firstIndex(of: "("), label.hasSuffix(")") else { return name }
        return String(label[label.index(after: open)..<label.index(before: label.endIndex)])
    }
}

public enum Direction: Hashable, Sendable { case clientToServer, serverToClient }

public struct StreamChunk: Identifiable, Sendable {
    public let id: Int
    public let frame: Int
    public let time: Double
    public let direction: Direction
    public let bytes: Data
}

public struct FollowResult: Sendable {
    public var client = ""
    public var server = ""
    public var chunks: [StreamChunk] = []
    public init() {}
}

/// One node of a packet's protocol tree, from sharkd or tshark PDML.
public final class FieldNode: Identifiable, Hashable, @unchecked Sendable {
    public let label: String
    public let field: String
    public let filter: String
    /// Byte range in the frame. `nil` for generated or reassembled-source fields.
    public let range: Range<Int>?
    public let isProtocol: Bool
    public internal(set) var children: [FieldNode]
    public internal(set) weak var parent: FieldNode?
    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    public init(label: String, field: String, filter: String, range: Range<Int>?, isProtocol: Bool, children: [FieldNode] = []) {
        self.label = label; self.field = field; self.filter = filter; self.range = range
        self.isProtocol = isProtocol; self.children = children
        for c in children { c.parent = self }
    }

    public static func == (a: FieldNode, b: FieldNode) -> Bool { a === b }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }

    public var ancestors: [FieldNode] {
        var out: [FieldNode] = []
        var p = parent
        while let n = p { out.append(n); p = n.parent }
        return out
    }

    /// Depth-first, self first.
    public func allNodes() -> [FieldNode] { [self] + children.flatMap { $0.allNodes() } }
}

public struct FrameDetail: Sendable {
    public let tree: [FieldNode]
    public let bytes: Data
    public init(tree: [FieldNode], bytes: Data) { self.tree = tree; self.bytes = bytes }

    /// The smallest node whose range covers `byte`: the field the byte belongs to.
    public func node(at byte: Int) -> FieldNode? {
        tree.flatMap { $0.allNodes() }
            .filter { $0.range?.contains(byte) == true }
            .min { ($0.range!.count, $0.isProtocol ? 1 : 0) < ($1.range!.count, $1.isProtocol ? 1 : 0) }
    }
}
