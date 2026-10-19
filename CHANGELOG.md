# Changelog

All notable changes to Kagami. Versions follow [semantic versioning](https://semver.org).

## 0.1.0 beta, 2026-10-19

The first public beta. Everything below is new; expect rough edges and please report them. The code is
under AGPL-3.0-or-later; the name, icon and artwork are reserved (see [BRAND.md](BRAND.md)).

- **Capture and open**: record any interface through Wireshark's tools, or open any capture format
  Wireshark reads (pcap, pcapng, snoop, ERF, compressed captures and more).
- **Packet anatomy**: every packet drawn as RFC header diagrams on a 32-bit ruler, linked to the
  field tree and the bytes.
- **Views**: packet table with protocol colours and TCP problem flags, Overview dashboard, Follow
  Stream ladder diagram, packet Diff, Endpoints, display filters with a rule builder, comments that
  travel in pcapng exports.
- **Flows**: NetFlow v5/v9 and IPFIX inside captures, and flow files on their own: nfdump (binary and
  text output), CSV and TSV (including AWS VPC flow logs), JSON and JSON lines (goflow2, pmacct,
  Elastic) and Zeek conn.log, streamed so multi-gigabyte exports open in seconds. Drill down by
  protocol, host, port and exporter; a flow inspector shows each conversation.
- **⌘K** command palette for every action, packet, host and filter.
- **`kagami` CLI and MCP server**: JSON output for scripts, and read access to captures for MCP
  clients such as Claude Code, with writes confined to one folder.
- **Signed updates** from GitHub releases; DMG and Installer package downloads.
