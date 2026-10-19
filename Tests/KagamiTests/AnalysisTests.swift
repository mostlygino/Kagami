import Foundation
import Testing
@testable import KagamiCore

@Test func familiesClassifyColumnProtocols() {
    #expect(ProtoFamily.classify("TLSv1.3", tcp: true, udp: false) == .tls)
    #expect(ProtoFamily.classify("HTTP/JSON", tcp: true, udp: false) == .http)
    #expect(ProtoFamily.classify("MDNS", tcp: false, udp: true) == .dns)
    #expect(ProtoFamily.classify("ICMPv6", tcp: false, udp: false) == .icmp)
    #expect(ProtoFamily.classify("SSDP", tcp: false, udp: true) == .udp)
    #expect(ProtoFamily.classify("LLDP", tcp: false, udp: false) == .other)
}

@Test func statsOnTheFixture() async throws {
    let s = CaptureStats(try await TShark.packets(in: anatomyFixture))
    #expect(s.packets == 8 && s.conversations == 2)
    #expect(s.hosts.first?.name == "example.com")
    #expect(s.issues.first { $0.issue == .reset }?.count == 1)
    #expect(Set(s.ports.map(\.name)) == ["TCP 80", "UDP 53"])
    #expect(s.families.map(\.packets).reduce(0, +) == 8)
    #expect(s.timeline.map(\.packets).reduce(0, +) == 8)
}

@Test func streamHostsNameTheWholeConversation() async throws {
    let p = try await TShark.packets(in: anatomyFixture)
    let names = Grouping.streamHosts(p)
    #expect(Grouping.host(of: p[0], in: names) == "example.com")  // the SYN carries no host itself
}

@Test func diffPairsChangesSideBySide() {
    let a = ["eth", "  ttl 64", "  src 1", "tcp"]
    let b = ["eth", "  ttl 63", "  src 1", "tcp", "http"]
    #expect(LineDiff.unified(a, b).map(\.kind) == [.same, .removed, .added, .same, .same, .added])
    let s = LineDiff.sideBySide(a, b)
    #expect(s.map(\.kind) == [.same, .changed, .same, .same, .added])
    #expect(s[1].left == "  ttl 64" && s[1].right == "  ttl 63")
}

@Test func lsofFieldOutputMapsPorts() {
    let out = "p123\ncSafari\nf12\nn192.168.1.2:52000->17.1.1.1:443\np456\ncmDNSResponder\nn*:5353\n"
    #expect(ProcessMap.parse(out) == [52000: "Safari", 5353: "mDNSResponder"])
}

@Test func interfaceCountersIncludeLoopback() {
    #expect(InterfaceCounters.snapshot()["lo0"] != nil)
}

@Test func versionsCompareAndTagsAreStrict() {
    #expect(Version("1.0.0")! < Version("1.0.1")!)
    #expect(Version("1.10.0")! > Version("1.9.9")!)
    #expect(Version("1.0")! == Version("1.0.0")!)
    #expect(Version(tag: "v1.2.3")?.description == "1.2.3")
    #expect(Version(tag: "v1.2.3; rm -rf /") == nil)
    #expect(Version(tag: "1.2.3") == nil)
}

@Test func releaseSignatureNeedsThePinnedPrimaryKey() {
    let key = "4C49B6E8DC9F50C80A1A20B805BE68B6158B9E08"
    let good = "[GNUPG:] NEWSIG\n[GNUPG:] VALIDSIG AAAA 2026-10-19 1 0 4 0 1 10 00 \(key)\n"
    let other = "[GNUPG:] VALIDSIG AAAA 2026-10-19 1 0 4 0 1 10 00 0123456789ABCDEF0123456789ABCDEF01234567\n"
    #expect(ReleaseStatus.signedBy(key, status: good))
    #expect(!ReleaseStatus.signedBy(key, status: other))
    #expect(!ReleaseStatus.signedBy(key, status: "[GNUPG:] BADSIG \(key) x"))
}
