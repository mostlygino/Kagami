#!/bin/sh
# Checks the kagami CLI and MCP server: exit codes, JSON output, protocol errors, MCP write confinement.
set -u
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build --product kagami-cli >/dev/null 2>&1 || { echo "build failed"; exit 1; }
K=.build/debug/kagami-cli
F=$PWD/Tests/KagamiTests/anatomy.pcap
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
fails=0
expect() { # expect <code> <description> <command...>
    want=$1; what=$2; shift 2
    "$@" >"$OUT/last" 2>&1; got=$?
    if [ "$got" = "$want" ]; then echo "ok   $what"; else echo "FAIL $what: exit $got, wanted $want"; cat "$OUT/last"; fails=$((fails+1)); fi
}
expect 0 "packets lists rows"         $K packets "$F" --limit 3
expect 0 "anatomy draws diagrams"     $K anatomy "$F" 1
expect 0 "follow reassembles"         $K follow "$F" 0
expect 2 "missing file is usage"      $K packets /nonexistent.pcap
expect 2 "a FIFO is not a capture"    $K packets /dev/stdin
expect 2 "unknown command is usage"   $K frobnicate
expect 4 "bad filter exits 4"         $K check "tcp.port =="
expect 0 "good filter passes check"   $K check "tls.handshake.type == 1"
expect 2 "export never overwrites"    $K export "$F" -o "$F"
ln -s "$OUT/nowhere.pcap" "$OUT/link.pcap"
expect 2 "export refuses symlinks"    $K export "$F" -o "$OUT/link.pcap"
expect 0 "export writes a new file"   $K export "$F" -o "$OUT/dns.pcapng" --filter dns
[ "$(stat -f %Lp "$OUT/dns.pcapng")" = "600" ] && echo "ok   exports are private (0600)" || { echo "FAIL export mode"; fails=$((fails+1)); }
$K packets "$F" --filter dns | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["matched"]==2, d' && echo "ok   filter narrows to 2 DNS packets" || fails=$((fails+1))
$K flows "$PWD/Tests/KagamiTests/flows.pcap" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["flows"]==5 and d["records"][0]["bytes"]==98000, d' && echo "ok   flows reads NetFlow v5 and IPFIX" || fails=$((fails+1))
$K anatomy "$F" 1 | grep -q "| Ver=4 | IHL=5 |" && echo "ok   RFC grid for IPv4" || { echo "FAIL RFC grid"; fails=$((fails+1)); }

printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"list_packets\",\"arguments\":{\"file\":\"$F\",\"limit\":2}}}" \
  '{"jsonrpc":"2.0","id":4,"method":"nope"}' \
  "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"list_packets\",\"arguments\":{\"file\":\"$F\",\"limit\":1e30}}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"export_packets\",\"arguments\":{\"file\":\"$F\",\"output_name\":\"../../.zshenv\",\"filter\":\"dns\"}}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"capture\",\"arguments\":{\"interface\":\"lo0\",\"seconds\":1}}}" \
  '{"jsonrpc":"2.0","id":8,"method":"ping"}' \
  | KAGAMI_MCP_OUTPUT_DIR="$OUT/mcp" $K mcp | OUT="$OUT" python3 -c '
import sys, json, os
r = {m["id"]: m for m in (json.loads(l) for l in sys.stdin)}
assert sorted(r) == [1, 2, 3, 4, 5, 6, 7, 8], sorted(r)
assert r[1]["result"]["protocolVersion"] == "2025-06-18"
assert len(r[2]["result"]["tools"]) == 10
assert r[3]["result"]["isError"] is False and json.loads(r[3]["result"]["content"][0]["text"])["matched"] == 8
assert r[4]["error"]["code"] == -32601
assert r[5]["result"]["isError"] is True, "1e30 must be rejected, not crash"
out = json.loads(r[6]["result"]["content"][0]["text"])["output"]
assert os.path.realpath(out) == os.path.realpath(os.path.join(os.environ["OUT"], "mcp", "zshenv.pcapng")), out
assert r[7]["result"]["isError"] is True and "KAGAMI_MCP_ALLOW_CAPTURE" in r[7]["result"]["content"][0]["text"]
assert r[8]["result"] == {}
' && echo "ok   MCP: handshake, tools, errors, no crash on 1e30, writes confined, capture off by default" || fails=$((fails+1))
[ $fails = 0 ] && echo "all CLI checks passed" || { echo "$fails CLI check(s) failed"; exit 1; }
