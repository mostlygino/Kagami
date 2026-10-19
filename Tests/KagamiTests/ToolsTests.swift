import Foundation
import Testing
@testable import KagamiCore

@Test func filterRulesWriteWiresharkSyntax() {
    #expect(FilterRule(field: .port, condition: .equals, value: "443").expression == "(tcp.port == 443 or udp.port == 443)")
    #expect(FilterRule(field: .source, condition: .equals, value: "192.0.2.10").expression == "ip.src == 192.0.2.10")
    #expect(FilterRule(field: .address, condition: .inSubnet, value: "2001:db8::/32").expression == "ipv6.addr == 2001:db8::/32")
    #expect(FilterRule(field: .address, condition: .equals, value: "not an ip").expression == nil)
    #expect(FilterRule(field: .tcpFlags, condition: .isSet, value: "RST").expression == "tcp.flags.reset == 1")
    #expect(FilterRule(field: .host, condition: .contains, value: "exa\"mple").expression?.contains("contains \"exa\\\"mple\"") == true)
    #expect(FilterRule(field: .proto, condition: .equals, value: "dns; rm").expression == nil)
    let both = FilterRule.combine([FilterRule(field: .proto, condition: .equals, value: "tcp"),
                                   FilterRule(field: .length, condition: .greaterOrEqual, value: "100"),
                                   FilterRule(field: .port, condition: .equals, value: "1", enabled: false)], all: true)
    #expect(both == "(tcp) and (frame.len >= 100)")
}

@Test func builtFiltersAreValidForTshark() async throws {
    let rules: [FilterRule] = [
        FilterRule(field: .host, condition: .hasPrefix, value: "exam"), FilterRule(field: .host, condition: .hasSuffix, value: ".com"),
        FilterRule(field: .info, condition: .matches, value: "HTTP/1\\.1"), FilterRule(field: .stream, condition: .less, value: "3"),
        FilterRule(field: .destinationPort, condition: .notEquals, value: "80"), FilterRule(field: .address, condition: .notEquals, value: "10.0.0.1"),
    ]
    for r in rules {
        let f = try #require(r.expression)
        _ = try await TShark.matching(f, in: anatomyFixture)  // throws on a syntax error
    }
    #expect(try await TShark.matching(FilterRule(field: .host, condition: .hasSuffix, value: ".com").expression!, in: anatomyFixture).count > 0)
}

@Test func endpointsSplitSentAndReceived() async throws {
    let p = try await TShark.packets(in: anatomyFixture)
    let e = Endpoints.compute(p, local: ["192.0.2.10", "2001:db8::1"], hosts: Grouping.streamHosts(p))
    let server = try #require(e[.ipv4]?.first { $0.name == "198.51.100.20" })
    #expect(server.packets == 6 && server.txPackets == 4 && server.rxPackets == 2)
    #expect(e[.tcp]?.contains { $0.name == "198.51.100.20:80" } == true)
    #expect(e[.udp]?.first?.filter == "ipv6.addr == 2001:db8::53 and udp.port == 53")
    #expect(e[.hosts]?.first?.name == "example.com")
}

@Test func rowAndByteFormats() {
    let h = ["No.", "Info"], r = [["1", "a,b"], ["2", "x|y"]]
    #expect(RowFormat.csvHeader.render(header: h, rows: r) == "No.,Info\n1,\"a,b\"\n2,x|y")
    #expect(RowFormat.markdown.render(header: h, rows: r).contains("| 2 | x\\|y |"))
    #expect(RowFormat.json.render(header: h, rows: r).contains("\"no\" : \"1\""))
    let d = Data([0x47, 0x45, 0x54, 0x00])
    #expect(ByteFormat.hexStream.render(d) == "47455400")
    #expect(ByteFormat.goLiteral.render(d) == "[]byte{0x47, 0x45, 0x54, 0x00}")
    #expect(ByteFormat.hexDump.render(d).hasPrefix("0000  47 45 54 00"))
}

@Test func filterCheckWithoutAFile() async throws {
    #expect(try await TShark.filterError("tcp.port == 443 and dns") == nil)
    let e = try await TShark.filterError("tcp.port ==")
    #expect(e != nil && e?.hasPrefix("^") == false)
}

@Test func endpointsSkipNonIPAndMarkUnknownDirection() {
    let arp = Packet(number: 1, time: 0, source: "Apple_aa:bb:cc", destination: "Broadcast", proto: "ARP", length: 42, info: "who-has")
    let six = Packet(number: 2, time: 0, source: "2001:db8:a:b::c:d", destination: "2001:db8::1", proto: "UDP", length: 80, info: "")
    let e = Endpoints.compute([arp, six], local: [])
    #expect(e[.ipv6]?.map(\.name).sorted() == ["2001:db8::1", "2001:db8:a:b::c:d"])
    #expect(e[.ipv6]?.allSatisfy { !$0.directionKnown } == true)
    #expect(e[.ipv4] == nil)
}

@Test func loopbackHostsHaveNoDirection() {
    let lo = Packet(number: 1, time: 0, source: "127.0.0.1", destination: "127.0.0.1", proto: "HTTP", length: 100,
                    host: "api.kagami.test", process: "curl", info: "")
    let out = Packet(number: 2, time: 0, source: "192.0.2.10", destination: "198.51.100.20", proto: "TCP", length: 60,
                     host: "docs.kagami.test", process: "curl", info: "")
    let e = Endpoints.compute([lo, out], local: ["127.0.0.1", "192.0.2.10"])
    #expect(e[.hosts]?.first { $0.name == "api.kagami.test" }?.directionKnown == false)
    #expect(e[.hosts]?.first { $0.name == "docs.kagami.test" }.map { $0.directionKnown && $0.txBytes == 60 } == true)
}

@Test func commentsAreSetExactly() async throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kagami-comments-\(UUID()).pcapng")
    defer { try? FileManager.default.removeItem(at: out) }
    try await TShark.export(anatomyFixture, to: out, filter: nil, pcapng: true)
    try await TShark.setComments([(2, "first"), (5, "second")], in: out)
    #expect(try await TShark.packets(in: out).filter { !$0.comment.isEmpty }.map(\.number) == [2, 5])
    try await TShark.setComments([(5, "kept")], in: out)  // frame 2's comment is removed
    let after = try await TShark.packets(in: out).filter { !$0.comment.isEmpty }
    #expect(after.map(\.number) == [5] && after[0].comment == "kept")
}
