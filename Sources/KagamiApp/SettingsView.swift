import KagamiCore
import SwiftUI

struct SettingsView: View {
    @AppStorage("rowColouring") private var colouring = RowColouring.protocols
    @AppStorage("timeDisplay") private var timeDisplay = TimeDisplay.relative
    @State private var version: String?

    var body: some View {
        TabView {
            Form {
                Picker("Row colours", selection: $colouring) {
                    ForEach(RowColouring.allCases) { Text($0.title).tag($0) }
                }
                Picker("Time column", selection: $timeDisplay) {
                    ForEach(TimeDisplay.allCases) { Text($0.title).tag($0) }
                }
                Section("Protocol colours") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(ProtoFamily.stackOrder) { f in ProtoChip(proto: f.title, family: f) }
                    }
                }
            }
            .settingsPane()
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                LabeledContent("tshark", value: TShark.url?.path ?? "Not found")
                LabeledContent("sharkd", value: TShark.sharkdURL?.path ?? "Not found")
                LabeledContent("Version", value: version ?? "…")
                Text("Kagami runs Wireshark's own programs for capture and dissection. It looks in /Applications/Wireshark.app, then Homebrew. Set KAGAMI_WIRESHARK_DIR to use another copy.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .settingsPane()
            .tabItem { Label("Wireshark", systemImage: "puzzlepiece.extension") }
            .task { version = await TShark.version() ?? "Not found" }

            Form {
                Section("The kagami command") {
                    Text("The kagami command reads captures and prints JSON. Link it onto your PATH:")
                        .font(.callout)
                    CommandSnippet(text: "ln -sf \"\(Self.cliPath)\" /usr/local/bin/kagami")
                    CommandSnippet(text: "kagami packets capture.pcapng --filter tls --limit 5 --pretty")
                }
                Section("MCP server") {
                    Text("Let Claude and other MCP clients read captures through Kagami:")
                        .font(.callout)
                    CommandSnippet(text: "claude mcp add kagami -- \"\(Self.cliPath)\" mcp")
                }
            }
            .settingsPane()
            .tabItem { Label("Command Line", systemImage: "terminal") }
        }
    }

    static var cliPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/kagami").path
    }
}

private extension View {
    /// A grouped form on the window ground, as tall as its rows so each tab sizes the window.
    func settingsPane() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(width: 560)
            .fixedSize(horizontal: false, vertical: true)
    }
}
