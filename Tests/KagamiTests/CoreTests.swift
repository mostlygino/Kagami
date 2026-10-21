import Foundation
import Testing
@testable import KagamiCore

// Both fixtures are synthetic: fixture.pcap from `randpkt -c 30 -t tcp`, anatomy.pcap from
// scripts/make-fixtures.py (documentation addresses, example.com). Never commit real captures.
let randomFixture = Bundle.module.url(forResource: "fixture", withExtension: "pcap")!
let anatomyFixture = Bundle.module.url(forResource: "anatomy", withExtension: "pcap")!

// MARK: tshark

@Test func readsEveryPacket() async throws {
    let packets = try await TShark.packets(in: randomFixture)
    #expect(packets.map(\.number) == Array(1...30))
}

@Test func rowsCarryHostsPortsAndIssues() async throws {
    let p = try await TShark.packets(in: anatomyFixture)
    #expect(p.count == 8)
    #expect(p[3].host == "example.com" && p[3].proto == "HTTP" && p[3].dstPort == 80 && p[3].tcpStream == 0)
    #expect(p[5].issues.contains(.reset) && p[5].issues.isSevere)
    #expect(p[0].issues.isEmpty)
    #expect(p[6].udpStream == 0 && p[6].host == "example.com" && p[6].dstPort == 53)
}

@Test func infoKeepsItsTabs() {
    var cols = Array(repeating: "", count: TShark.fields.count)
    cols[0] = "7"; cols[5] = "TCP"; cols[TShark.fields.count - 1] = "info\twith tab"
    let p = TShark.parseRow(Substring(cols.joined(separator: "\t")))
    #expect(p?.info == "info\twith tab")
}

@Test func badDisplayFilterThrowsTsharkMessage() async {
    await #expect(throws: TSharkError.self) { try await TShark.matching("tcp.port ==", in: randomFixture) }
}

@Test func exportRoundTrip() async throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kagami-export-\(UUID()).pcap")
    defer { try? FileManager.default.removeItem(at: out) }
    try await TShark.export(randomFixture, to: out, filter: "frame.number <= 5", pcapng: false)
    #expect(try await TShark.packets(in: out).count == 5)
}

@Test func followCarriesFrameNumbersAndDirections() async throws {
    let r = try await TShark.follow(StreamRef(proto: .tcp, index: 0), in: anatomyFixture)
    #expect(r.client == "192.0.2.10:51000" && r.server == "198.51.100.20:80")
    #expect(r.chunks.map(\.frame) == [4, 5])
    #expect(r.chunks.map(\.direction) == [.clientToServer, .serverToClient])
    #expect(String(decoding: r.chunks[0].bytes, as: UTF8.self).hasPrefix("GET / HTTP/1.1"))
    #expect(String(decoding: r.chunks[1].bytes, as: UTF8.self).hasSuffix("hello"))
}

@Test func interfacesSkipExtcap() {
    let list = TShark.parseInterfaces("1. en0 (Wi-Fi)\n11. lo0 (Loopback)\n28. sshdump (SSH remote capture)\n27. randpkt (Random packet generator)")
    #expect(list.map(\.name) == ["en0", "lo0"])
    #expect(list[0].friendlyName == "Wi-Fi")
}

@Test func filterQuoting() {
    #expect(FilterText.quote("443") == "443")
    #expect(FilterText.quote("example.com") == "\"example.com\"")
    #expect(FilterText.quote("fe80::1") == "fe80::1")
    #expect(FilterText.and(["tcp", " "]) == "tcp")
    #expect(FilterText.and(["tcp or udp", "ip.ttl > 3"]) == "(tcp or udp) and (ip.ttl > 3)")
}

// MARK: sharkd

@Test func sharkSessionAnswersDetailChecksAndMatches() async throws {
    let s = try await SharkSession(file: anatomyFixture)
    defer { Task { await s.close() } }
    #expect(try await s.matching("frame").count == 8)
    #expect(try await s.check("tcp.port == 80") == nil)
    #expect(try await s.check("tcp.port ==") != nil)
    #expect(try await s.matching("dns") == [7, 8])
    let d = try await s.frame(1)
    #expect(d.bytes.count == 74)
    #expect(d.tree.map(\.field).starts(with: ["frame", "eth", "ip", "tcp"]))
    // Concurrent callers each get their own answer.
    async let a = s.matching("tcp.flags.reset == 1")
    async let b = s.matching("http")
    #expect(try await a == [6])
    #expect(try await b == [4, 5])
}

// MARK: Anatomy

@Test func anatomyDrawsIPv4AndTCPLikeTheRFC() async throws {
    let s = try await SharkSession(file: anatomyFixture)
    defer { Task { await s.close() } }
    let layers = Anatomy.layers(from: try await s.frame(1).tree)
    #expect(layers.map(\.name) == ["Ethernet II", "IPv4", "TCP"])

    let ip = layers[1]
    func box(_ l: Anatomy.Layer, _ field: String) -> Anatomy.Box? { l.boxes.first { $0.node?.field == field } }
    #expect(box(ip, "ip.version").map { ($0.bitStart, $0.bitWidth) }! == (0, 4))
    #expect(box(ip, "ip.hdr_len").map { ($0.bitStart, $0.bitWidth) }! == (4, 4))
    #expect(box(ip, "ip.dsfield.dscp").map { ($0.bitStart, $0.bitWidth) }! == (8, 6))
    #expect(box(ip, "ip.flags.df").map { ($0.bitStart, $0.bitWidth) }! == (49, 1))
    #expect(box(ip, "ip.frag_offset").map { ($0.bitStart, $0.bitWidth) }! == (51, 13))
    #expect(box(ip, "ip.ttl").map { ($0.bitStart, $0.bitWidth) }! == (64, 8))
    #expect(box(ip, "ip.src").map { ($0.bitStart, $0.bitWidth) }! == (96, 32))
    #expect(ip.rows == 5 && ip.hiddenBytes == 0)
    #expect(!ip.boxes.contains { $0.isGap })

    let tcp = layers[2]
    #expect(box(tcp, "tcp.srcport")?.value == "51000")
    #expect(box(tcp, "tcp.hdr_len").map { ($0.bitStart, $0.bitWidth) }! == (96, 4))
    // TCP flags: 12-bit patterns on a 2-byte field, anchored on the parent.
    #expect(box(tcp, "tcp.flags.syn").map { ($0.bitStart, $0.bitWidth) }! == (110, 1))
    #expect(box(tcp, "tcp.flags.ack").map { ($0.bitStart, $0.bitWidth) }! == (107, 1))
    #expect(box(tcp, "tcp.flags.syn")?.value == "Set")
    #expect(box(tcp, "tcp.window_size_value").map { ($0.bitStart, $0.bitWidth) }! == (112, 16))
    // Options are opened up into their parts.
    #expect(box(tcp, "tcp.option_kind") != nil || box(tcp, "tcp.options.mss_val") != nil)
    #expect(tcp.rows == 10)
    // Boxes tile the layer without overlaps.
    var cursor = 0
    for b in tcp.boxes { #expect(b.bitStart == cursor); cursor = b.bitEnd }
    #expect(cursor == 40 * 8)
}

@Test func anatomyBoxesCrossRowsLikeAddresses() {
    let b = Anatomy.Box(id: 0, node: nil, bitStart: 64, bitWidth: 128, name: "Source Address", value: "")
    #expect(Anatomy.segments(of: b) == [Anatomy.Segment(row: 2, rowSpan: 4, bitStart: 0, bitEnd: 32)])
    let mac = Anatomy.Box(id: 1, node: nil, bitStart: 0, bitWidth: 48, name: "Destination", value: "")
    #expect(Anatomy.segments(of: mac) == [Anatomy.Segment(row: 0, rowSpan: 1, bitStart: 0, bitEnd: 32),
                                          Anatomy.Segment(row: 1, rowSpan: 1, bitStart: 0, bitEnd: 16)])
    let odd = Anatomy.Box(id: 2, node: nil, bitStart: 16, bitWidth: 64, name: "x", value: "")
    #expect(Anatomy.segments(of: odd).map(\.bits) == [16, 32, 16])
}

@Test func anatomySplitsLabels() {
    #expect(Anatomy.bitPattern("0100 .... = Version: 4") == "0100....")
    #expect(Anatomy.bitPattern("Source Port: 443") == nil)
    #expect(Anatomy.split(".... .... ..1. = Syn: Set") == ("Syn", "Set"))
    #expect(Anatomy.split("Time to Live: 64") == ("Time to Live", "64"))
    #expect(Anatomy.abbreviation(for: "Time to Live") == "TTL")
}

@Test func hostNamesDropPorts() {
    #expect(TShark.hostName("docs.example.com:8080") == "docs.example.com")
    #expect(TShark.hostName("example.com") == "example.com")
    #expect(TShark.hostName("2001:db8::1") == "2001:db8::1")
}

@Test func asciiDiagramMatchesTheRFCGrid() async throws {
    let s = try await SharkSession(file: anatomyFixture)
    defer { Task { await s.close() } }
    let ip = Anatomy.layers(from: try await s.frame(1).tree)[1]
    let text = Anatomy.ascii(ip)
    let lines = text.split(separator: "\n").map(String.init)
    let expectedLines = 13  // ruler (2) + 5 rows with rules above + closing rule
    #expect(lines.count == expectedLines)
    let widths = Set(lines.dropFirst(2).map(\.count))
    #expect(widths == [65])
    #expect(lines[3].contains("Ver") && lines[3].contains("Total Length: 60"))
    #expect(text.contains("Source Address: 192.0.2.10"))
}

// MARK: Review regressions

@Test func twoPassFiltersSeeLaterFrames() async throws {
    // dns.response_in is only known after the response is read; single-pass tshark matches nothing.
    #expect(try await TShark.matching("dns.response_in", in: anatomyFixture) == [7])
}

@Test func lineBufferKeepsPartialLines() {
    let b = LineBuffer(keepLog: false)
    #expect(b.feed(Data("ab".utf8)).isEmpty)
    #expect(b.feed(Data("c\nde".utf8)) == ["abc"])
    #expect(b.feed(Data(), flush: true) == ["de"])
}

@Test func liveCaptureNamesAreSafeAndUnique() throws {
    let a = try CaptureFiles.newLiveCapture(interface: "../../etc/x")
    let b = try CaptureFiles.newLiveCapture(interface: "en0")
    #expect(a.deletingLastPathComponent() == b.deletingLastPathComponent())
    #expect(!a.lastPathComponent.contains("/") && a.lastPathComponent.hasPrefix("etcx-"))
    #expect(a != (try CaptureFiles.newLiveCapture(interface: "../../etc/x")))
}
