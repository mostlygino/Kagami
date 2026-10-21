#!/usr/bin/env python3
"""Writes Tests/KagamiTests/anatomy.pcap: a small, fully synthetic capture for the test suite.

Documentation addresses only (192.0.2.0/24, 198.51.100.0/24, 2001:db8::/32) and example.com.
Never replace this with a real capture.
"""
import struct, sys, pathlib

def csum(data: bytes) -> int:
    if len(data) % 2: data += b"\0"
    s = sum(struct.unpack(f"!{len(data)//2}H", data))
    while s >> 16: s = (s & 0xFFFF) + (s >> 16)
    return ~s & 0xFFFF

def ip4(a): return bytes(int(x) for x in a.split("."))

def eth(payload, ethertype):
    return bytes.fromhex("02005e0000aa") + bytes.fromhex("02005e0000bb") + struct.pack("!H", ethertype) + payload

def ipv4(src, dst, proto, payload, ident):
    hdr = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(payload), ident, 0x4000, 64, proto, 0, ip4(src), ip4(dst))
    hdr = hdr[:10] + struct.pack("!H", csum(hdr)) + hdr[12:]
    return hdr + payload

def tcp(src, dst, sport, dport, seq, ack, flags, payload=b"", options=b"", window=64240):
    off = (20 + len(options)) // 4
    seg = struct.pack("!HHIIBBHHH", sport, dport, seq, ack, off << 4, flags, window, 0, 0) + options + payload
    pseudo = ip4(src) + ip4(dst) + struct.pack("!BBH", 0, 6, len(seg))
    return seg[:16] + struct.pack("!H", csum(pseudo + seg)) + seg[18:]

SYN, ACK, PSH, RST = 0x02, 0x10, 0x08, 0x04
C, S = "192.0.2.10", "198.51.100.20"
opts = bytes.fromhex("020405b4") + bytes.fromhex("0402") + bytes.fromhex("080a0000000100000000") + bytes.fromhex("01") + bytes.fromhex("030307")
req = b"GET / HTTP/1.1\r\nHost: example.com\r\nUser-Agent: kagami-test\r\n\r\n"
resp = b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello"

frames = [
    eth(ipv4(C, S, 6, tcp(C, S, 51000, 80, 1000, 0, SYN, options=opts), 1), 0x0800),
    eth(ipv4(S, C, 6, tcp(S, C, 80, 51000, 5000, 1001, SYN | ACK, options=opts), 2), 0x0800),
    eth(ipv4(C, S, 6, tcp(C, S, 51000, 80, 1001, 5001, ACK), 3), 0x0800),
    eth(ipv4(C, S, 6, tcp(C, S, 51000, 80, 1001, 5001, PSH | ACK, req), 4), 0x0800),
    eth(ipv4(S, C, 6, tcp(S, C, 80, 51000, 5001, 1001 + len(req), PSH | ACK, resp), 5), 0x0800),
    eth(ipv4(C, S, 6, tcp(C, S, 51000, 80, 1001 + len(req), 0, RST, window=0), 6), 0x0800),
]

# IPv6 + UDP + DNS query/response for example.com
def ipv6(src, dst, nh, payload):
    a = bytes.fromhex(src); b = bytes.fromhex(dst)
    return struct.pack("!IHBB", 0x60000000, len(payload), nh, 64) + a + b + payload
def udp6(src, dst, sport, dport, payload):
    seg = struct.pack("!HHHH", sport, dport, 8 + len(payload), 0) + payload
    pseudo = bytes.fromhex(src) + bytes.fromhex(dst) + struct.pack("!IxxxB", len(seg), 17)
    return seg[:6] + struct.pack("!H", csum(pseudo + seg)) + seg[8:]
qname = b"\x07example\x03com\x00"
q = struct.pack("!HHHHHH", 0x1a2b, 0x0100, 1, 0, 0, 0) + qname + struct.pack("!HH", 1, 1)
r = struct.pack("!HHHHHH", 0x1a2b, 0x8180, 1, 1, 0, 0) + qname + struct.pack("!HH", 1, 1) + b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 300, 4) + ip4("203.0.113.7")
A6 = "20010db8000000000000000000000001"; D6 = "20010db8000000000000000000000053"
frames += [
    eth(ipv6(A6, D6, 17, udp6(A6, D6, 53000, 53, q)), 0x86DD),
    eth(ipv6(D6, A6, 17, udp6(D6, A6, 53, 53000, r)), 0x86DD),
]

out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "Tests/KagamiTests/anatomy.pcap")
with open(out, "wb") as f:
    f.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1))
    for i, fr in enumerate(frames):
        f.write(struct.pack("<IIII", 1_700_000_000, i * 25_000, len(fr), len(fr)) + fr)
print(f"wrote {out} ({len(frames)} frames)")

# --- flows.pcap: NetFlow v5 and IPFIX exports from documentation addresses ---------------------
def udp4(src, dst, sport, dport, payload, ident):
    seg = struct.pack("!HHHH", sport, dport, 8 + len(payload), 0) + payload
    return ipv4(src, dst, 17, seg, ident)

def netflow_v5(records, uptime=600000, secs=1_700_000_100):
    hdr = struct.pack("!HHIIIIBBH", 5, len(records), uptime, secs, 0, 42, 0, 0, 0)
    body = b""
    for (src, dst, sport, dport, proto, pkts, octets, first, last, flags, sas, das) in records:
        body += struct.pack("!4s4s4sHHIIIIHHBBBBHHBBH", ip4(src), ip4(dst), ip4("0.0.0.0"), 1, 2, pkts, octets,
                            first, last, sport, dport, 0, flags, proto, 0, sas, das, 24, 24, 0)
    return hdr + body

def ipfix(template_and_data, export_time=1_700_000_200, seq=1):
    return struct.pack("!HHIII", 10, 16 + len(template_and_data), export_time, seq, 7) + template_and_data

ies = [(8, 4), (12, 4), (7, 2), (11, 2), (4, 1), (2, 8), (1, 8), (152, 8), (153, 8)]
tmpl = struct.pack("!HH", 256, len(ies)) + b"".join(struct.pack("!HH", i, l) for i, l in ies)
template_set = struct.pack("!HH", 2, 4 + len(tmpl)) + tmpl
def ipfix_rec(src, dst, sp, dp, proto, pkts, octets, start, end):
    return ip4(src) + ip4(dst) + struct.pack("!HHBQQQQ", sp, dp, proto, pkts, octets, start, end)
recs = ipfix_rec("192.0.2.30", "203.0.113.80", 51515, 443, 6, 120, 98_000, 1_700_000_190_000, 1_700_000_199_000) \
     + ipfix_rec("192.0.2.31", "198.51.100.53", 53000, 53, 17, 2, 180, 1_700_000_195_000, 1_700_000_195_050)
data_set = struct.pack("!HH", 256, 4 + len(recs)) + recs

EXP, COL = "192.0.2.254", "192.0.2.2"
v5 = netflow_v5([
    ("192.0.2.10", "198.51.100.20", 51000, 80, 6, 6, 693, 590000, 599000, 0x1b, 64500, 64501),
    ("192.0.2.10", "203.0.113.7", 53000, 53, 17, 2, 198, 595000, 595050, 0, 64500, 64502),
    ("198.51.100.20", "192.0.2.10", 80, 51000, 6, 4, 1200, 590010, 598000, 0x13, 64501, 64500),
])
flow_frames = [
    eth(udp4(EXP, COL, 40000, 2055, v5, 100), 0x0800),
    eth(udp4(EXP, COL, 40001, 4739, ipfix(template_set + data_set), 101), 0x0800),
]
out2 = out.with_name("flows.pcap")
with open(out2, "wb") as f:
    f.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1))
    for i, fr in enumerate(flow_frames):
        f.write(struct.pack("<IIII", 1_700_000_300, i * 1000, len(fr), len(fr)) + fr)
print(f"wrote {out2} ({len(flow_frames)} frames)")
