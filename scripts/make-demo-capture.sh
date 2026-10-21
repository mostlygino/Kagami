#!/bin/sh
# Records Demo/demo.pcapng on loopback while local servers produce HTTP, TLS, DNS, ICMP and a reset.
# Synthetic by construction: only 127.0.0.1 and *.kagami.test names. Used for screenshots and the README.
set -eu
cd "$(dirname "$0")/.."
WS=/Applications/Wireshark.app/Contents/MacOS
work=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; wait 2>/dev/null; rm -rf "$work"' EXIT
mkdir -p Demo "$work/site"
printf '<!doctype html><title>Kagami demo</title><h1>Hello from docs.kagami.test</h1>\n' > "$work/site/index.html"
printf '{"status":"ok","service":"api.kagami.test","items":[1,2,3]}\n' > "$work/site/status.json"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/key.pem" -out "$work/cert.pem" -days 2 -subj "/CN=kagami.test" 2>/dev/null

python3 -m http.server 18080 --bind 127.0.0.1 --directory "$work/site" >/dev/null 2>&1 &
openssl s_server -accept 18443 -cert "$work/cert.pem" -key "$work/key.pem" -www -quiet >/dev/null 2>&1 &
python3 - <<'PY' >/dev/null 2>&1 &
import socket, struct
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 15353))
while True:
    q, a = s.recvfrom(512)
    i = 12
    while q[i]: i += q[i] + 1
    qend = i + 5
    r = q[:2] + b"\x81\x80" + q[4:6] + b"\x00\x01\x00\x00\x00\x00" + q[12:qend] + b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 60, 4) + bytes([127, 0, 0, 1])
    s.sendto(r, a)
PY
sleep 1.5
"$WS/dumpcap" -i lo0 -f "port 18080 or port 18443 or port 15353 or port 18009 or icmp" -w Demo/demo.pcapng -q -a duration:14 &
cap=$!
sleep 2
for name in api docs cdn auth telemetry; do dig +short +tries=1 +time=1 -p 15353 @127.0.0.1 "$name.kagami.test" >/dev/null || true; done
curl -s --resolve docs.kagami.test:18080:127.0.0.1 http://docs.kagami.test:18080/ >/dev/null
curl -s --resolve api.kagami.test:18080:127.0.0.1 http://api.kagami.test:18080/status.json >/dev/null
for name in api cdn auth; do curl -sk --resolve $name.kagami.test:18443:127.0.0.1 "https://$name.kagami.test:18443/" >/dev/null || true; sleep 0.4; done
curl -s --max-time 1 http://127.0.0.1:18009/ >/dev/null || true
ping -c 3 -i 0.3 127.0.0.1 >/dev/null
for i in 1 2 3; do curl -sk --resolve telemetry.kagami.test:18443:127.0.0.1 https://telemetry.kagami.test:18443/ >/dev/null || true; sleep 0.6; done
curl -s --resolve docs.kagami.test:18080:127.0.0.1 http://docs.kagami.test:18080/missing >/dev/null
wait $cap
"$WS/capinfos" -c -u Demo/demo.pcapng | tail -2
