# Kagami design

The app's visual system as built (2026-10-19, Verdigris theme). The icon and brand art follow `docs/design/APP_DESIGN.md`
and `docs/brand/`; product truth is in `PRODUCT.md`. This file covers the app's own interface.

## Direction

**RFC Header Diagram.** Every packet is drawn the way the RFCs draw it: a 32-bit ruler, each field a box
sized by its bits, the live value inside. The category default (a tree over a hex dump) is still there,
as the Fields tab and the Bytes pane, but the Anatomy diagram leads.

Three rules carry the world everywhere:

1. **One protocol colour code**, always beside its name, never colour alone.
2. **Rules on device pixels.** Diagram lines are exactly one device pixel; nothing is drawn fuzzy.
3. **Native first.** Liquid Glass toolbar, sidebar and inspector; standard menus, tables, sheets and
   tabs. Expression lives in the diagrams, the colour code and a few authored moments.

## Colour

Protocol families, in the dataviz reference palette's validated order (worst adjacent CVD ΔE 9.1
light / 8.4 dark). Light / dark hex:

| Family | Light | Dark |
|---|---|---|
| TCP | `#2A78D6` | `#3987E5` |
| TLS | `#EB6834` | `#D95926` |
| DNS | `#1BAF7A` | `#199E70` |
| HTTP | `#EDA100` | `#C98500` |
| QUIC | `#E87BA4` | `#D55181` |
| ICMP | `#008300` | `#008300` |
| UDP | `#6250D6` | `#9085E9` |
| ARP | `#E34948` | `#E66767` |
| Other | `#8A8984` | `#6F6E69` |

### Theme: Verdigris

Taken from the icon: a bronze mirror gone green with age. Dark-first, with a light mode built to the
same finish.

| Token | Light | Dark | Use |
|---|---|---|---|
| `Color.kagami` (verdigris) | `#127F6E` | `#3FB8A6` | links, ruler tens, the client in Follow, Flows bars, direction bars |
| `Color.kagamiFill` / AccentColor | `#127F6E` | `#1A7F70` | prominent buttons, switches, AppKit controls (asset compiled by `actool`) |
| `Color.bronze` | `#A2672B` | `#D6A35E` | selection: table row edge, Anatomy box, bytes, Diff changed characters and focus |
| `Color.ground` | `#F6F8F7` | `#121719` | every window and sheet ground |
| `Color.raised` | `#FFFFFF` | `#171E21` | inspector |
| `Color.rule` | `#DDE3E1` | `#263034` | hairlines |

Verdigris says "you can act here"; bronze says "this is the thing you chose". Segmented controls stay
neutral so the protocol colours and the two theme colours remain the only hues.
- **Record** is system red, the only red control.
- **Status** (TCP problems): orange for warnings, red for severe (reset, lost segment, zero window),
  always with an SF Symbol and a label.
- **Follow Stream peers**: client in the tint, server in a neutral grey, so protocol colours stay
  protocol-only.
- Row tints: the protocol colour at 9% opacity; user highlights at 30%; text never wears a data colour.
  Selection does not add another tint: a bronze edge and wash, appearance-specific.

## Type

SF Pro for interface text, SF Mono for data: addresses, numbers, times, hex, filters, field values.
Monospaced digits in every column of numbers. No display faces.

## Surfaces

| Surface | Built from |
|---|---|
| Window | `NavigationSplitView`: sidebar (protocols, hosts, apps, quick filters, your marks) · content · `.inspector` |
| Packet table | `NSTableView` (appends without re-diffing; sorting, column menus, custom columns); columns always fill the pane, Info gives way first |
| Anatomy | `Canvas` per layer; ruler `0…3 / 0…9`, boxes by bit range, labels name over value, short names when narrow |
| Bytes | 16 or 8 bytes per row by width, never sideways scrolling; layer tints at 7%, bronze selection |
| Overview | facts as one line of text; Swift Charts stacked area (linear, no invented curves); ranked bars |
| Flows | NetFlow/IPFIX table and top-talker rows; numbers right-aligned, addresses in SF Mono |
| Endpoints | per app, host, address and port; protocol colour chips (whole chips only, then "+N") |
| Follow Stream | ladder diagram (two rails, arrows per payload) beside the transcript |
| Diff | side by side or unified; lines wrap with a hanging indent, never truncate; changed lines a neutral wash, changed characters bold on bronze; ⌥⌘↑/↓ step through differences |
| About | the app as a packet header on the RFC ruler, icon over its reflection, the mostlygino seal |

## Motion

150–250 ms, ease-out, state changes only. Authored moments:

- **About**: the release header dissects field by field (hex resolving to values), then the seal lands
  with a haptic tap.
- **Live capture**: rows append in place; with the list scrolled up, new rows get a tint dot until
  seen and a "N new packets" glass button.

- **Opening a capture**: the start screen blurs out, the table in; the sidebar arrives a beat later,
  and on a narrow window it stays folded so the inspector has room.

Reduce Motion skips the authored moments.

## Accessibility

Every custom view has an accessibility label or representation (Anatomy boxes are buttons by name and
value); colour always has a text partner; full keyboard paths for every command (menus list them).
