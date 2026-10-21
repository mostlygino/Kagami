#!/usr/bin/env python3
"""Writes a synthetic nfdump `-o raw` export: documentation addresses only (RFC 5737 / 3849).

The repository ships it gzipped: scripts/make-demo-netflow.py Demo/demo.netflow 4000 && gzip -9 Demo/demo.netflow
"""
import random, sys
random.seed(7)
out = open(sys.argv[1], "w")
clients = [f"192.0.2.{i}" for i in range(10, 60)]
servers = [(f"203.0.113.{i}", p, 6) for i, p in [(10, 443), (11, 443), (12, 80), (20, 22), (30, 3389), (40, 25)]] + \
          [(f"198.51.100.{i}", p, pr) for i, p, pr in [(53, 53, 17), (54, 53, 17), (80, 443, 6), (81, 443, 17), (123, 123, 17)]]
weights = [30, 18, 8, 3, 2, 2, 12, 6, 10, 6, 3]
t0 = 1760860800000  # 2025-10-19 08:00 UTC
routers = ["edge-ams-1", "edge-ams-2"]
flags = {6: ["0x1b ...AP.SF", "0x10 ....A....", "0x02 ......S.", "0x14 ...A.R.."], 17: ["0x00 ........"]}
n = int(sys.argv[2]) if len(sys.argv) > 2 else 4000
for k in range(n):
    c = random.choice(clients); s, port, pr = random.choices(servers, weights)[0]
    out_dir = random.random() < 0.55
    src, dst = (c, s) if out_dir else (s, c)
    sp, dp = (random.randint(49152, 65535), port) if out_dir else (port, random.randint(49152, 65535))
    first = t0 + int(k * 3600_000 / n) + random.randint(0, 2000)
    dur = random.choice([0, 0, 40, 900, 4000, 30000, 120000]) if pr == 6 else random.choice([0, 20, 60])
    pk = max(1, int(random.lognormvariate(3, 1.4))); by = pk * random.randint(60, 1400)
    print(f"""
Flow Record: 
  RecordCount  =       {k + 1}
  Ident        =       {random.choice(routers)}
  first        =       {first} [x]
  last         =       {first + dur} [x]
  proto        =       {pr} {'TCP' if pr == 6 else 'UDP'}
  tcp flags    =       {random.choice(flags[pr])}
  src port     =       {sp}
  dst port     =       {dp}
  in packets   =       {pk}
  in bytes     =       {by}
  src addr     =       {src}
  dst addr     =       {dst}
  input        =       {random.choice([1, 2])}
  output       =       {random.choice([3, 4])}
  src as       =       {64500 if src.startswith('192.0.2') else 64511}
  dst as       =       {64500 if dst.startswith('192.0.2') else 64511}""", file=out)
