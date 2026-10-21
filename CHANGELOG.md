# Changelog

All notable changes to Kagami. Versions follow [semantic versioning](https://semver.org).

## 0.1.1 beta, 2026-10-21

- **New app icon**: the cast bronze mirror back in black lacquer, its relief a carrier wave, redrawn to the
  standard of the other mostlygino apps. README banners and the social preview carry it too.

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
- **Welcome**: on first launch a three-step window explains Kagami, checks the setup live (Wireshark,
  permission to record, GnuPG, nfdump; each fix one copy away) and opens the bundled demo on a TLS Client
  Hello, with a one-time hint over its Anatomy. Skippable; Help > Welcome to Kagami and ⌘K bring it back.
