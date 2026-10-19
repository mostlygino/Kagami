# Contributing to Kagami

Thanks for wanting to help. Kagami is a small, opinionated Mac app, so a short conversation before a
large change saves everyone time: open an issue first for new features or big refactors. Bug fixes,
tests and documentation can go straight to a pull request.

## Build and run

You need macOS 26 on Apple silicon, Xcode 26 (the Command Line Tools alone lack the SwiftUI macros),
and Wireshark for its `tshark`, `sharkd` and `dftest` tools (`brew install --cask wireshark`).

```sh
./make-app.sh                 # builds build/Kagami.app with the kagami CLI inside
open build/Kagami.app
swift test                    # unit tests on synthetic fixtures
scripts/check-cli.sh          # the CLI and MCP server, end to end
```

`scripts/install.sh` builds and copies the app into /Applications.

## Where things live

| Path | What |
|---|---|
| `Sources/KagamiCore` | Everything without UI: tshark and sharkd, parsing, flows, analysis. Tested. |
| `Sources/KagamiApp` | The SwiftUI and AppKit app. |
| `Sources/KagamiCLI` | The `kagami` command and its MCP server. |
| `Tests/KagamiTests` | Swift Testing suites and their fixtures. |
| `scripts/` | Build, release, installers, fixtures and demo data. |
| `DESIGN.md`, `PRODUCT.md` | The visual system and what Kagami is for. Read them before UI work. |

## Ground rules

- **No real traffic in the repository.** Captures and flow files must be synthetic: documentation
  addresses (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24, 2001:db8::/32), `example.com`,
  `*.kagami.test`. `scripts/make-fixtures.py`, `scripts/make-demo-capture.sh` and
  `scripts/make-demo-netflow.py` show how.
- **Core logic gets a test.** Parsers, filters and anything in `KagamiCore` come with a test in
  `Tests/KagamiTests`. Keep tests offline; they may use tshark but never the network or a live capture.
- **Match the surrounding code.** Swift 5 language mode, the comment density and naming of the file
  you are in, and the tokens in `DESIGN.md` for anything visible (no new colours, no new fonts).
- **British English** in the interface and docs. Interface text is plain and specific: say what
  happened and what to do next.
- **Security matters here.** Kagami handles other people's traffic. Keep the MCP server's write
  confinement, the opt-in for live capture over MCP and the updater's signature check intact. See
  `SECURITY.md`.

## Pull requests

1. Fork, branch from `main`, keep the change focused.
2. `swift test` and `scripts/check-cli.sh` pass locally; CI runs both.
3. Describe what changed and why; add a screenshot for visible changes (light and dark when colours change).

By contributing you license your work under AGPL-3.0-or-later, the licence of this repository. There is
no contributor licence agreement. The name, icon and artwork are not open for contributions; see
[BRAND.md](BRAND.md).
