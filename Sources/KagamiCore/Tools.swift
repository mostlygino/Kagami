import Darwin
import Foundation

// MARK: Filter builder

/// Builds a Wireshark display filter from simple rows: field, condition, value. It teaches the
/// syntax too: the app shows the filter it writes.
public struct FilterRule: Identifiable, Hashable, Codable, Sendable {
    public enum Field: String, CaseIterable, Identifiable, Codable, Sendable {
        case host, address, source, destination, port, sourcePort, destinationPort, proto, stream, tcpFlags, length, info
        public var id: Self { self }

        public var title: String {
            switch self {
            case .host: "Host name"
            case .address: "Address (either side)"
            case .source: "Source address"
            case .destination: "Destination address"
            case .port: "Port (either side)"
            case .sourcePort: "Source port"
            case .destinationPort: "Destination port"
            case .proto: "Protocol"
            case .stream: "Stream number"
            case .tcpFlags: "TCP flag"
            case .length: "Frame length"
            case .info: "Any text in the packet"
            }
        }

        public var isNumeric: Bool { [.port, .sourcePort, .destinationPort, .stream, .length].contains(self) }

        public var conditions: [Condition] {
            switch self {
            case .host: [.contains, .notContains, .hasPrefix, .hasSuffix, .matches, .equals]
            case .info: [.contains, .notContains, .matches]
            case .address, .source, .destination: [.equals, .notEquals, .inSubnet]
            case .proto: [.equals, .notEquals]
            case .tcpFlags: [.isSet, .isNotSet]
            case .port, .sourcePort, .destinationPort, .stream, .length: [.equals, .notEquals, .less, .greaterOrEqual]
            }
        }

        public var placeholder: String {
            switch self {
            case .host: "example.com"
            case .address, .source, .destination: "192.0.2.10"
            case .port, .sourcePort, .destinationPort: "443"
            case .proto: "dns"
            case .stream: "0"
            case .tcpFlags: "syn, ack, fin, rst, psh, urg"
            case .length: "1000"
            case .info: "password"
            }
        }
    }

    public enum Condition: String, CaseIterable, Identifiable, Codable, Sendable {
        case contains, notContains, hasPrefix, hasSuffix, matches, equals, notEquals, less, greaterOrEqual, inSubnet, isSet, isNotSet
        public var id: Self { self }
        public var title: String {
            switch self {
            case .contains: "contains"
            case .notContains: "does not contain"
            case .hasPrefix: "starts with"
            case .hasSuffix: "ends with"
            case .matches: "matches regex"
            case .equals: "is"
            case .notEquals: "is not"
            case .less: "is less than"
            case .greaterOrEqual: "is at least"
            case .inSubnet: "is in subnet"
            case .isSet: "is set"
            case .isNotSet: "is not set"
            }
        }
    }

    public var id = UUID()
    public var field: Field = .host
    public var condition: Condition = .contains
    public var value = ""
    public var enabled = true

    public init(field: Field = .host, condition: Condition = .contains, value: String = "", enabled: Bool = true) {
        self.field = field; self.condition = condition; self.value = value; self.enabled = enabled
    }

    /// The Wireshark expression, or nil when the row is incomplete or its value is not valid.
    public var expression: String? {
        let v = value.trimmingCharacters(in: .whitespaces)
        if field == .tcpFlags {
            let names = ["syn": "syn", "ack": "ack", "fin": "fin", "rst": "reset", "reset": "reset", "psh": "push", "push": "push", "urg": "urg"]
            guard let flag = names[v.lowercased()] else { return nil }
            return "tcp.flags.\(flag) == \(condition == .isSet ? 1 : 0)"
        }
        guard !v.isEmpty else { return nil }
        if field.isNumeric {
            guard let n = Int(v), n >= 0 else { return nil }
            let op = [.equals: "==", .notEquals: "!=", .less: "<", .greaterOrEqual: ">="][condition] ?? "=="
            switch field {
            case .port: return condition == .notEquals ? "!(tcp.port == \(n) or udp.port == \(n))" : "(tcp.port \(op) \(n) or udp.port \(op) \(n))"
            case .sourcePort: return "(tcp.srcport \(op) \(n) or udp.srcport \(op) \(n))"
            case .destinationPort: return "(tcp.dstport \(op) \(n) or udp.dstport \(op) \(n))"
            case .stream: return "(tcp.stream \(op) \(n) or udp.stream \(op) \(n))"
            default: return "frame.len \(op) \(n)"
            }
        }
        switch field {
        case .address, .source, .destination:
            guard Self.isAddress(v, subnet: condition == .inSubnet) else { return nil }
            let six = v.contains(":")
            let name = (six ? "ipv6." : "ip.") + (field == .address ? "addr" : (field == .source ? "src" : "dst"))
            return condition == .notEquals ? "!(\(name) == \(v))" : "\(name) == \(v)"
        case .proto:
            guard v.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }) else { return nil }
            return condition == .notEquals ? "!\(v.lowercased())" : v.lowercased()
        case .host:
            let fields = ["tls.handshake.extensions_server_name", "http.host", "dns.qry.name"]
            return "(" + fields.map { text($0, v) }.joined(separator: condition == .notContains ? " and " : " or ") + ")"
        case .info:
            return condition == .notContains ? "!(frame contains \(Self.quote(v)))" : (condition == .matches ? "frame matches \(Self.quote(v))" : "frame contains \(Self.quote(v))")
        default:
            return nil
        }
    }

    private func text(_ f: String, _ v: String) -> String {
        let q = Self.quote(v)
        switch condition {
        case .contains: return "\(f) contains \(q)"
        case .notContains: return "!(\(f) contains \(q))"
        case .hasPrefix: return "\(f) matches \(Self.quote("^" + NSRegularExpression.escapedPattern(for: v)))"
        case .hasSuffix: return "\(f) matches \(Self.quote(NSRegularExpression.escapedPattern(for: v) + "$"))"
        case .matches: return "\(f) matches \(q)"
        default: return "\(f) == \(q)"
        }
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func isAddress(_ s: String, subnet: Bool) -> Bool {
        let parts = s.split(separator: "/", maxSplits: 1)
        guard let host = parts.first, parts.count == (subnet ? 2 : 1) || (!subnet && parts.count == 1) else { return false }
        if parts.count == 2, Int(parts[1]).map({ (0...128).contains($0) }) != true { return false }
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, String(host), &v4) == 1 || inet_pton(AF_INET6, String(host), &v6) == 1
    }

    /// All enabled, valid rows joined with `and` or `or`.
    public static func combine(_ rules: [FilterRule], all: Bool) -> String {
        let parts = rules.filter(\.enabled).compactMap(\.expression)
        return parts.count == 1 ? parts[0] : parts.map { "(\($0))" }.joined(separator: all ? " and " : " or ")
    }
}

// MARK: Endpoints

/// Traffic per endpoint, split into sent (from this Mac) and received.
public struct Endpoint: Identifiable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case apps = "Apps", hosts = "Hosts", ipv4 = "IPv4", ipv6 = "IPv6", tcp = "TCP", udp = "UDP"
        public var id: Self { self }
    }

    public let kind: Kind
    public let name: String
    public var packets = 0, bytes = 0
    public var txPackets = 0, txBytes = 0
    public var rxPackets = 0, rxBytes = 0
    public var protocols: Set<String> = []
    /// False when neither end of its traffic was this Mac (a capture from elsewhere): sent and received are unknown.
    public var directionKnown = true
    public var id: String { "\(kind.rawValue):\(name)" }

    /// Display filter that shows this endpoint's packets, where Wireshark can express it.
    public var filter: String? {
        switch kind {
        case .ipv4: return "ip.addr == \(name)"
        case .ipv6: return "ipv6.addr == \(name)"
        case .tcp, .udp:
            guard let colon = name.lastIndex(of: ":") else { return nil }
            let addr = name[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let port = name[name.index(after: colon)...]
            let ip = addr.contains(":") ? "ipv6.addr" : "ip.addr"
            let p = kind == .tcp ? "tcp.port" : "udp.port"
            return "\(ip) == \(addr) and \(p) == \(port)"
        case .apps, .hosts: return nil
        }
    }
}

public enum Endpoints {
    /// Addresses assigned to this Mac, to tell sent from received.
    public static func localAddresses() -> Set<String> {
        var out: Set<String> = ["127.0.0.1", "::1"]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            if let sa = p.pointee.ifa_addr {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let len = socklen_t(sa.pointee.sa_family == UInt8(AF_INET6) ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size)
                if (sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6)),
                   getnameinfo(sa, len, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let s = String(cString: buf)
                    out.insert(String(s.split(separator: "%").first ?? Substring(s)))
                }
            }
            cur = p.pointee.ifa_next
        }
        return out
    }

    static func family(_ addr: String) -> Int32 {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, addr, &v4) == 1 { return AF_INET }
        if inet_pton(AF_INET6, addr, &v6) == 1 { return AF_INET6 }
        return 0
    }

    public static func compute(_ packets: [Packet], local: Set<String>, hosts: [StreamRef: String] = [:]) -> [Endpoint.Kind: [Endpoint]] {
        var table: [Endpoint.Kind: [String: Endpoint]] = [:]
        func add(_ kind: Endpoint.Kind, _ name: String, _ p: Packet, sent: Bool, known: Bool) {
            guard !name.isEmpty else { return }
            var e = table[kind]?[name] ?? Endpoint(kind: kind, name: name)
            e.packets += 1; e.bytes += p.length
            if !known { e.directionKnown = false }
            else if sent { e.txPackets += 1; e.txBytes += p.length } else { e.rxPackets += 1; e.rxBytes += p.length }
            e.protocols.insert(ProtoFamily.of(p).title)
            table[kind, default: [:]][name] = e
        }
        for p in packets {
            let fromHere = local.contains(p.source)
            let known = fromHere || local.contains(p.destination)
            for (addr, isSource) in [(p.source, true), (p.destination, false)] where !local.contains(addr) || local.contains(p.source) && local.contains(p.destination) {
                let sent = isSource ? fromHere : !local.contains(p.destination) && fromHere
                // Classify by parsing, not by counting colons: a MAC or "Apple_aa:bb:cc" is neither.
                switch family(addr) {
                case AF_INET6: add(.ipv6, addr, p, sent: sent, known: known)
                case AF_INET: add(.ipv4, addr, p, sent: sent, known: known)
                default: continue
                }
                let port = isSource ? p.srcPort : p.dstPort
                if let port {
                    let name = addr.contains(":") ? "[\(addr)]:\(port)" : "\(addr):\(port)"
                    add(p.udpStream != nil ? .udp : .tcp, name, p, sent: sent, known: known)
                }
            }
            // A host or app has one side only when exactly one end is this Mac; loopback traffic has none.
            let oneSided = fromHere != local.contains(p.destination)
            let h = Grouping.host(of: p, in: hosts)
            if !h.isEmpty { add(.hosts, h, p, sent: fromHere, known: oneSided) }
            if !p.process.isEmpty { add(.apps, p.process, p, sent: fromHere, known: oneSided) }
        }
        return table.mapValues { $0.values.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name } }
    }
}

// MARK: Copying

public enum RowFormat: String, CaseIterable, Identifiable, Sendable {
    case plain = "Plain Text", csv = "CSV", csvHeader = "CSV with Header", json = "JSON", markdown = "Markdown Table"
    public var id: Self { self }

    public func render(header: [String], rows: [[String]]) -> String {
        func csvField(_ s: String) -> String {
            s.contains(",") || s.contains("\"") || s.contains("\n") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        switch self {
        case .plain:
            return rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        case .csv, .csvHeader:
            let body = rows.map { $0.map(csvField).joined(separator: ",") }
            return ((self == .csvHeader ? [header.map(csvField).joined(separator: ",")] : []) + body).joined(separator: "\n")
        case .json:
            let keys = header.map { $0.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ".", with: "") }
            let objects = rows.map { Dictionary(uniqueKeysWithValues: zip(keys, $0).map { ($0, $1) }) }
            let data = (try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        case .markdown:
            func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
            func line(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
            var lines: [String] = [line(header.map(cell)), line(header.map { _ in "---" })]
            for row in rows { lines.append(line(row.map(cell))) }
            return lines.joined(separator: "\n")
        }
    }
}

public enum ByteFormat: String, CaseIterable, Identifiable, Sendable {
    case hexDump = "Hex Dump", hexStream = "Hex Stream", base64 = "Base64", utf8 = "UTF-8 Text", cArray = "C Array", goLiteral = "Go Literal"
    public var id: Self { self }

    public func render(_ data: Data) -> String {
        let b = [UInt8](data)
        switch self {
        case .hexDump:
            return stride(from: 0, to: b.count, by: 16).map { start in
                let row = b[start..<min(start + 16, b.count)]
                let hex = row.map { String(format: "%02x", $0) }.joined(separator: " ")
                let ascii = String(row.map { (0x20...0x7e).contains($0) ? Character(UnicodeScalar($0)) : "." })
                return String(format: "%04x  ", start) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + ascii
            }.joined(separator: "\n")
        case .hexStream: return b.map { String(format: "%02x", $0) }.joined()
        case .base64: return data.base64EncodedString()
        case .utf8: return String(decoding: data, as: UTF8.self)
        case .cArray:
            let body = stride(from: 0, to: b.count, by: 12).map { "    " + b[$0..<min($0 + 12, b.count)].map { String(format: "0x%02x", $0) }.joined(separator: ", ") }
            return "unsigned char packet[\(b.count)] = {\n" + body.joined(separator: ",\n") + "\n};"
        case .goLiteral:
            return "[]byte{" + b.map { String(format: "0x%02x", $0) }.joined(separator: ", ") + "}"
        }
    }
}
