# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native macOS app (SwiftUI, AppKit where SwiftUI falls short). Apple's Human Interface Guidelines for macOS govern structure, navigation and controls. Target: the current macOS release (macOS 27 at time of writing) with its Liquid Glass design language; minimum macOS 15.

## Stack

Existing codebase: Swift Package (SwiftUI app target), Wireshark's `tshark` as the dissection and capture engine, run as a separate process. No linked Wireshark code.

## Users

Mac developers and security people who need to see what is on the wire: API and app developers debugging a connection, security engineers and pentesters looking at a capture, people doing abuse or incident work who were handed a pcap. They know roughly what TCP, TLS and DNS are, and many know Wireshark, but they want something that feels like a Mac app and gets them to the answer faster.

## Product Purpose

Kagami (鏡, "mirror") shows network traffic back to you clearly. Capture live or open a capture file, narrow it down, read one packet field by field, follow a conversation, compare packets, see the overview, and export exactly the packets that matter. Success: someone opens a pcap and finds the conversation they care about within a minute, without reading a manual.

## Positioning

A simpler, Mac-native alternative to Wireshark that keeps Wireshark's full dissector engine underneath. Every protocol Wireshark understands, Kagami shows, through native macOS interaction instead of a cross-platform UI. Open source.

## Operating Context

- Live capture on a laptop (Wi-Fi, Ethernet, loopback, VPN tunnels), without root, through Wireshark's ChmodBPF setup.
- Opening `.pcap` / `.pcapng` files from colleagues, CI, tcpdump on servers, or other tools.
- Long sessions at a desk, often next to an editor and a terminal; both light and dark appearance.
- Scripted use: a CLI with JSON output and an MCP server so AI clients can query captures.

## Capabilities and Constraints

- Requires Wireshark (tshark) installed; the app must explain this clearly when it is missing.
- Capture without root depends on ChmodBPF (`access_bpf` group); otherwise capture fails with a permission message that must be shown plainly.
- Features: live capture with BPF capture filter, open files (open panel, drag and drop, Finder), packet table with sorting and Wireshark-style colouring, display filters and protocol shortcuts, protocol tree with hex highlighting both ways, Follow TCP/UDP stream, packet diff, overview dashboard, grouping by domain and by app, export (all, filtered, selected; pcapng or pcap), CLI and MCP server.
- Grouping by app relies on macOS process metadata, which needs Apple's pktap interface and root; without it, app grouping is limited and must say so.
- Real captures contain private data; nothing leaves the machine.

## Brand Commitments

- Name: Kagami (鏡). The mirror is the governing idea: traffic reflected back, clear and undistorted.
- Part of Gino de Graaff's family of personal Mac tools: Japanese names, each with its own identity.
- Voice: plain, direct, British English. No hype. Errors name the problem and the fix.

## Evidence on Hand

- No users, testimonials, benchmarks or press yet. Do not invent any.
- Test data is synthetic (`randpkt`) or generated locally; never commit real captures.

## Product Principles

1. The answer before the detail: show the conversation first, the bytes when asked.
2. Native over novel: standard macOS controls, menus, shortcuts and windows; delight in precise details, not reinvented affordances.
3. Wireshark's truth, Kagami's clarity: never hide or reinterpret what the dissector says.
4. Local and private by default.
5. Every state is designed: empty, loading, capturing, error, missing Wireshark, huge file.

## Accessibility & Inclusion

Full keyboard operation, VoiceOver labels on custom views, Dynamic Type-friendly system text styles where macOS supports them, Reduce Motion and Increase Contrast respected, colour never the only signal (protocol colouring always paired with text).
