import Foundation
import Testing
@testable import KagamiCore

// flows.pcap is synthetic (scripts/make-fixtures.py): a NetFlow v5 export and an IPFIX export.
let flowsFixture = Bundle.module.url(forResource: "flows", withExtension: "pcap")!

@Test func readsNetFlowV5AndIPFIXRecords() async throws {
    let flows = try await Flows.read(flowsFixture)
    #expect(flows.count == 5)
    let v5 = flows.filter { $0.version == "NetFlow v5" }
    let ipfix = flows.filter { $0.version == "IPFIX" }
    #expect(v5.count == 3 && ipfix.count == 2)
    let web = try #require(v5.first { $0.destinationPort == 80 })
    #expect(web.sourceEndpoint == "192.0.2.10:51000" && web.protoName == "TCP" && web.packets == 6 && web.bytes == 693)
    #expect(web.exporter == "192.0.2.254" && web.sourceAS == 64500 && web.frame == 1)
    let big = try #require(ipfix.first { $0.destinationPort == 443 })
    #expect(big.bytes == 98_000 && big.duration == 9)
}

@Test func topTalkersFoldBothDirections() async throws {
    let t = Flows.topTalkers(try await Flows.read(flowsFixture))
    #expect(t.first?.pair == "192.0.2.30 ⇄ 203.0.113.80")
    let web = try #require(t.first { $0.pair == "192.0.2.10 ⇄ 198.51.100.20" })
    #expect(web.flows == 2 && web.bytes == 693 + 1200)
}

@Test func exportsOnOtherPortsNeedDecodeAs() async throws {
    // The fixture uses the standard ports; an unrelated extra port changes nothing and stays valid.
    #expect(try await Flows.read(flowsFixture, extraPorts: [9999]).count == 5)
    #expect(try await Flows.read(anatomyFixture).isEmpty)
}

// MARK: Flow files

@Test func readsFlowExportsByColumnName() {
    // nfdump -o csv
    let nfcsv = """
    firstSeen,duration,proto,srcAddr,srcPort,dstAddr,dstPort,packets,bytes,flows
    2023-11-14 23:14:50.000,9.000,6,192.0.2.10,51000,198.51.100.20,80,6,693,1
    Summary: total flows: 1
    """
    let a = FlowFiles.parse(nfcsv)
    #expect(a.count == 1 && a[0].sourceEndpoint == "192.0.2.10:51000" && a[0].protoName == "TCP" && a[0].bytes == 693 && a[0].duration == 9)

    // AWS VPC flow log: spaces, "-" for missing, epoch start/end, NODATA rows skipped
    let vpc = """
    version account-id interface-id srcaddr dstaddr srcport dstport protocol packets bytes start end action log-status
    2 123456789012 eni-0a1b2c3d 192.0.2.30 203.0.113.80 51515 443 6 120 98000 1700000000 1700000009 ACCEPT OK
    2 123456789012 eni-0a1b2c3d - - - - - - - 1700000000 1700000060 - NODATA
    """
    let b = FlowFiles.parse(vpc)
    #expect(b.count == 1 && b[0].version == "VPC flow log" && b[0].exporter == "eni-0a1b2c3d" && b[0].duration == 9 && b[0].packets == 120)

    // Zeek conn.log: both sides summed, protocol by name
    let zeek = """
    #separator \\x09
    #fields\tts\tuid\tid.orig_h\tid.orig_p\tid.resp_h\tid.resp_p\tproto\tservice\tduration\torig_bytes\tresp_bytes\torig_pkts\torig_ip_bytes\tresp_pkts\tresp_ip_bytes
    1700000000.0\tC1\t192.0.2.10\t53000\t203.0.113.7\t53\tudp\tdns\t0.05\t40\t118\t1\t68\t1\t146
    """
    let c = FlowFiles.parse(zeek)
    #expect(c.count == 1 && c[0].version == "Zeek conn.log" && c[0].protoName == "UDP" && c[0].packets == 2 && c[0].bytes == 214)

    // goflow2 JSON lines and Elastic-style nested JSON
    let goflow = """
    {"type":"IPFIX","sampler_address":"192.0.2.254","time_flow_start_ns":1700000000000000000,"time_flow_end_ns":1700000002000000000,"bytes":1200,"packets":4,"src_addr":"198.51.100.20","dst_addr":"192.0.2.10","proto":"TCP","src_port":80,"dst_port":51000,"tcp_flags":27,"src_as":64501,"dst_as":64500}
    {"type":"NETFLOW_V5","src_addr":"2001:db8::1","dst_addr":"2001:db8::2","proto":17,"bytes":80,"packets":1}
    """
    let d = FlowFiles.parse(goflow)
    #expect(d.count == 2 && d[0].version == "IPFIX" && d[0].exporter == "192.0.2.254" && d[0].tcpFlags == "0x1b" && d[0].duration == 2)
    #expect(d[1].version == "NetFlow v5" && d[1].sourceEndpoint == "2001:db8::1")
    let ecs = #"[{"source":{"ip":"192.0.2.31","port":53000},"destination":{"ip":"198.51.100.53","port":53},"network":{"transport":"udp","bytes":180,"packets":2}}]"#
    let e = FlowFiles.parse(ecs)
    #expect(e.count == 1 && e[0].destinationEndpoint == "198.51.100.53:53" && e[0].bytes == 180)

    // Not a flow export
    #expect(FlowFiles.parse("hello, world\n1,2\n").isEmpty)
    #expect(FlowFiles.flagsHex("...AP.SF") == "0x1b")
}

@Test func detectsFileKinds() {
    #expect(FlowFiles.kind(of: flowsFixture) == .capture)
    let nf = Bundle.module.url(forResource: "flows", withExtension: "nfcapd")!
    #expect(FlowFiles.kind(of: nf) == .nfdump)
    let csv = FileManager.default.temporaryDirectory.appendingPathComponent("kagami-flows-\(UUID()).csv")
    try? "srcaddr,dstaddr\n192.0.2.1,192.0.2.2\n".write(to: csv, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: csv) }
    #expect(FlowFiles.kind(of: csv) == .text(gzipped: false))
}

// flows.nfcapd is the flows.pcap exports replayed into nfcapd; needs nfdump installed.
@Test(.enabled(if: FlowFiles.nfdumpURL != nil)) func readsNfdumpFiles() async throws {
    let flows = try await FlowFiles.read(Bundle.module.url(forResource: "flows", withExtension: "nfcapd")!)
    #expect(flows.count == 5 && flows.reduce(0) { $0 + $1.bytes } == 100_271)
    let web = try #require(flows.first { $0.destinationPort == 80 })
    #expect(web.version == "nfdump" && web.sourceAS == 64500 && web.tcpFlags == "0x1b" && web.duration == 9 && web.inputInterface == 1)
}

@Test func readsNfdumpTextOutput() {
    // nfdump -o raw: one block per flow, readable forms after the value
    let raw = """

    Flow Record: 
      RecordCount  =                   1
      Ident        =          edge-1
      first        =       1700000000000 [2023-11-14 22:13:20.000]
      last         =       1700000009500 [2023-11-14 22:13:29.500]
      proto        =                   6 TCP
      tcp flags    =                0x1b ...AP.SF
      src port     =               51515
      dst port     =                 443
      in packets   =                 120
      in bytes     =               98000
      src addr     =          192.0.2.30
      dst addr     =        203.0.113.80
      in src mac   = 00:00:5e:00:53:01

    Flow Record: 
      proto        =                  17 UDP
      src port     =               53000
      dst port     =                  53
      in packets   =                   2
      in bytes     =                 180
      src addr     =          192.0.2.31
      dst addr     =       198.51.100.53
    """
    let r = FlowFiles.parse(raw)
    #expect(r.count == 2 && r[0].version == "nfdump" && r[0].exporter == "edge-1" && r[0].tcpFlags == "0x1b" && r[0].duration == 9.5)
    #expect(r[0].sourceEndpoint == "192.0.2.30:51515" && r[0].bytes == 98_000 && r[1].protoName == "UDP" && r[1].destinationPort == 53)

    // nfdump -o line: fixed columns, units on big numbers, a summary to skip
    let line = """
    Date first seen         Duration         Proto      Src IP Addr:Port          Dst IP Addr:Port   Packets    Bytes Flows
    2023-11-14 22:13:20.000     00:00:09.500 TCP        192.0.2.30:51515  ->     203.0.113.80:443        120    1.2 M     1
    2023-11-14 22:13:25.000     00:01:00.000 UDP     2001:db8::1.53000    ->      2001:db8::2.53          2      180     1
    Summary: total flows: 2, total bytes: 1.2 M, total packets: 122
    """
    let l = FlowFiles.parse(line)
    #expect(l.count == 2 && l[0].duration == 9.5 && l[0].bytes == 1_200_000 && l[0].packets == 120 && l[0].destinationPort == 443)
    #expect(l[1].sourceEndpoint == "[2001:db8::1]:53000" && l[1].duration == 60 && l[1].protoName == "UDP")
}

@Test func filtersAndSummarisesFlows() async throws {
    let flows = try await Flows.read(flowsFixture)
    let web = FlowFilter(pair: ["198.51.100.20", "192.0.2.10"])
    #expect(flows.filter(web.matches).count == 2)  // both directions of the HTTP conversation
    #expect(flows.filter(FlowFilter(port: 53).matches).count == 2)
    #expect(flows.filter(FlowFilter(host: "192.0.2.10", proto: 17).matches).count == 1)
    #expect(FlowFilter(host: "192.0.2.10", port: 443).nfdump == "host 192.0.2.10 and port 443")
    let s = FlowSummary(flows)
    #expect(s.count == 5 && s.bytes == 100_271)
    #expect(s.sources.first?.key == "192.0.2.30" && s.ports.first?.key == "TCP 443" && s.protocols.first?.key == "6")
}
