import AppKit
import KagamiCore
import SwiftUI

/// First run: three short steps from "what is this" to a real packet on screen. Kagami's aha is seeing a
/// packet drawn the way the RFCs draw it, so the last step opens the demo capture on a TLS Client Hello in
/// Anatomy. Skippable at every step; Help > Welcome to Kagami brings it back.
struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = WelcomeView.initialStep
    @State private var forward = true

    /// Set the moment the window first appears.
    static let seenKey = "welcomeSeen.v1"
    /// --welcome=N opens on step N (screenshots).
    nonisolated(unsafe) static var initialStep = 0
    static let steps = 3

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page
                    .id(step)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity).combined(with: .blurIn),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            footer
        }
        .frame(width: 720, height: 528)
        .background { MirrorGround().ignoresSafeArea() }
        // Seen as soon as it is shown: quitting, a crash or a force quit must not bring it back next time.
        .onAppear { UserDefaults.standard.set(true, forKey: Self.seenKey) }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case 0: IntroStep()
        case 1: SetupStep()
        default: StartStep(close: { dismiss() })
        }
    }

    /// First run only, and never when Kagami was started to open something or by a script.
    static func shouldShowAtLaunch(opened: Bool) -> Bool {
        let args = CommandLine.arguments.dropFirst()
        if let n = args.first(where: { $0.hasPrefix("--welcome") }) {
            initialStep = Int(n.split(separator: "=").last ?? "") ?? 0
            return true
        }
        return !opened && !UserDefaults.standard.bool(forKey: seenKey) && !args.contains { $0.hasPrefix("--") }
    }

    private func go(_ delta: Int) {
        let next = min(max(step + delta, 0), Self.steps - 1)
        guard next != step else { return }
        forward = delta > 0
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.42)) { step = next }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            StepDots(count: Self.steps, current: step)
            Spacer()
            if step < Self.steps - 1 {
                Button("Skip") { dismiss() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .help("Close the welcome. Help > Welcome to Kagami brings it back.")
            }
            if step > 0 {
                Button("Back") { go(-1) }
                    .buttonStyle(.bordered)
                    .tint(nil)
                    .keyboardShortcut(.leftArrow, modifiers: [])
            }
            if step < Self.steps - 1 {
                Button { go(1) } label: { Text("Continue").frame(minWidth: 84) }
                    .buttonStyle(.borderedProminent)
                    .tint(.kagamiFill)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                    .tint(nil)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 28)
        .frame(height: 64)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Where you are: a short bar per step, the current one long and verdigris.
private struct StepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.kagami : Color.primary.opacity(i < current ? 0.35 : 0.15))
                    .frame(width: i == current ? 22 : 7, height: 7)
            }
        }
        .animation(.smooth(duration: 0.35), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

private struct StepTitle: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .semibold))
            Text(text)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
        }
    }
}

// MARK: Step 1

/// What Kagami is, as Kagami would show it: a header that dissects field by field.
private struct IntroStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var decoded = 0

    private let fields: [(name: String, value: String, bits: Int)] = [
        ("Record", "any interface", 16), ("Read", "every layer", 16),
        ("Flows", "NetFlow · nfdump", 16), ("Agents", "CLI · MCP", 16),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .center, spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 76, height: 76)
                    .accessibilityHidden(true)
                StepTitle(title: "Welcome to Kagami",
                          text: "See what is on the wire. Kagami reads packets with Wireshark's own dissectors and draws each one the way the RFCs do.")
            }
            VStack(alignment: .leading, spacing: 6) {
                Ruler()
                VStack(spacing: 0) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(Array(fields.enumerated()).filter { $0.offset / 2 == row }, id: \.offset) { i, f in
                                FieldBox(name: f.name, value: f.value, bits: f.bits, decoded: decoded > i, link: nil)
                            }
                        }
                    }
                }
                .overlay { Rectangle().strokeBorder(Color.primary.opacity(0.32), lineWidth: 1) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Record any interface, read every layer, open NetFlow and nfdump flows, and hand captures to agents through the CLI and MCP.")
            }
            Text("Three short steps: check your setup, then open a real capture. Skip any time; Help > Welcome to Kagami brings this back.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 44)
        .padding(.top, 48)
        .task {
            guard !reduceMotion else { decoded = fields.count; return }
            for i in 0..<fields.count {
                try? await Task.sleep(for: .milliseconds(i == 0 ? 450 : 160))
                withAnimation(.easeOut(duration: 0.3)) { decoded = i + 1 }
            }
        }
    }
}

// MARK: Step 2

/// What Kagami needs, checked live: install something and its row turns green while you watch.
private struct SetupStep: View {
    @State private var checks = SetupChecks.Snapshot()

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            StepTitle(title: "Check your setup",
                      text: checks.verdict)
            VStack(spacing: 0) {
                SetupRow(state: checks.tshark != nil ? .ok : .missing,
                         title: "Wireshark",
                         detail: checks.tshark.map { [$0.version.map { "Wireshark \($0)" } ?? "Found", $0.path].joined(separator: " · ") }
                            ?? "Kagami runs Wireshark's tshark and sharkd to record and read captures.",
                         actions: checks.tshark == nil ? [
                            .link("Download Wireshark", URL(string: "https://www.wireshark.org/download.html")!),
                            .copy("brew install --cask wireshark"),
                         ] : [])
                Divider().padding(.leading, 44)
                SetupRow(state: checks.canCapture ? .ok : .missing,
                         title: "Permission to record",
                         detail: checks.canCapture
                            ? "Your account can read the capture devices, no administrator password needed."
                            : "macOS lets only the access_bpf group record. Wireshark's ChmodBPF helper adds you; then log out and back in.",
                         actions: checks.canCapture ? [] : [.copy("brew install --cask wireshark-chmodbpf")])
                Divider().padding(.leading, 44)
                // The two extras share one row, so a fresh Mac still sees the whole list without scrolling.
                SetupRow(state: checks.gpg && checks.nfdump ? .ok : .optional,
                         title: "Optional extras",
                         detail: [checks.gpg ? "GnuPG is installed: updates are checked for Kagami's signature before they install."
                                             : "GnuPG lets the updater check each release's signature; without it, download updates by hand.",
                                  checks.nfdump ? "nfdump is installed: binary nfcapd flow files open directly."
                                                : "nfdump reads binary nfcapd flow files; CSV, JSON, Zeek and its text output open without it."]
                            .joined(separator: " "),
                         actions: (checks.gpg ? [] : [SetupRow.Action.copy("brew install gnupg")])
                            + (checks.nfdump ? [] : [SetupRow.Action.copy("brew install nfdump")]))
            }
            .padding(.vertical, 4)
            .background(Color.raised.opacity(0.7), in: .rect(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.rule, lineWidth: 1) }
            Text("Everything Kagami records or reads stays on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 44)
        .padding(.top, 36)
        .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task {
            // Re-checked every two seconds while this step is up, so a fresh install shows at once.
            while !Task.isCancelled {
                let next = await SetupChecks.snapshot()
                withAnimation(.smooth(duration: 0.3)) { checks = next }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct SetupRow: View {
    enum State { case ok, missing, optional }
    enum Action: Hashable { case link(String, URL), copy(String) }

    let state: State
    let title: String
    let detail: String
    let actions: [Action]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityLabel(state == .ok ? "Ready" : state == .missing ? "Needs setting up" : "Optional")
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(actions, id: \.self) { action in
                            switch action {
                            case .link(let label, let url):
                                Button(label) { NSWorkspace.shared.open(url) }
                                    .buttonStyle(.bordered)
                                    .tint(nil)
                            case .copy(let command):
                                CopyCommand(command: command)
                            }
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var symbol: String {
        switch state {
        case .ok: "checkmark.circle.fill"
        case .missing: "exclamationmark.circle.fill"
        case .optional: "circle.dashed"
        }
    }

    private var tint: Color {
        switch state {
        case .ok: .kagami
        case .missing: .bronze
        case .optional: .secondary
        }
    }
}

/// A shell command as a small button that copies it.
private struct CopyCommand: View {
    let command: String
    @State private var copied = false

    var body: some View {
        Button {
            copyText(command)
            withAnimation(.snappy) { copied = true }
            Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation(.snappy) { copied = false } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").contentTransition(.symbolEffect(.replace))
                Text(command).font(.system(size: 11.5, design: .monospaced))
            }
        }
        .buttonStyle(.bordered)
        .tint(nil)
        .help(copied ? "Copied. Paste it into Terminal." : "Copy this command for Terminal")
    }
}

/// What the setup step checks. All local: file system and the tools' own version output.
enum SetupChecks {
    struct Snapshot: Equatable {
        var tshark: (path: String, version: String?)?
        var canCapture = false
        var gpg = false
        var nfdump = false

        static func == (a: Snapshot, b: Snapshot) -> Bool {
            a.tshark?.path == b.tshark?.path && a.tshark?.version == b.tshark?.version
                && a.canCapture == b.canCapture && a.gpg == b.gpg && a.nfdump == b.nfdump
        }

        var verdict: String {
            if tshark == nil { return "Kagami needs Wireshark to record and read captures. Flow files already open without it." }
            if !canCapture { return "Reading captures works. One more step lets you record." }
            return "All set: Kagami can record and read on this Mac."
        }
    }

    nonisolated(unsafe) private static var versionCache: [String: String] = [:]

    static func snapshot() async -> Snapshot {
        var s = Snapshot()
        // Screenshots of the first-run state on a Mac that has everything: open --env KAGAMI_WELCOME_FRESH=1.
        if ProcessInfo.processInfo.environment["KAGAMI_WELCOME_FRESH"] == "1" { return s }
        if let url = TShark.url {
            if versionCache[url.path] == nil, let v = await TShark.version() {
                // "TShark (Wireshark) 4.6.7 (v4.6.7-0-g…)." → "4.6.7"
                versionCache[url.path] = v.firstMatch(of: #/\d+\.\d+\.\d+/#).map { String($0.output) } ?? v
            }
            // The app, not the binary inside it: /Applications/Wireshark.app rather than …/Contents/MacOS/tshark.
            let shown = url.path.range(of: ".app/").map { String(url.path[..<$0.lowerBound]) + ".app" } ?? url.path
            s.tshark = (shown, versionCache[url.path])
        }
        // ChmodBPF makes /dev/bpf* readable and writable for the access_bpf group.
        s.canCapture = access("/dev/bpf0", R_OK | W_OK) == 0
        s.gpg = ["/opt/homebrew/bin/gpg", "/usr/local/bin/gpg"].contains(where: FileManager.default.isExecutableFile(atPath:))
        s.nfdump = FlowFiles.nfdumpURL != nil
        return s
    }
}

// MARK: Step 3

/// The aha: a real packet, drawn as its RFC headers. Plus the two other ways in, and five keys worth knowing.
private struct StartStep: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepTitle(title: "Start with something real",
                      text: "Open the demo and Kagami lands on a TLS Client Hello, drawn layer by layer. Click any box and its bytes light up.")
            VStack(alignment: .leading, spacing: 12) {
                Button { Demo.openCapture(); close() } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "play.rectangle.fill").font(.system(size: 22))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open the Demo Capture").font(.body.weight(.semibold))
                            Text("262 packets of synthetic web traffic on loopback").font(.callout).opacity(0.85)
                        }
                        Spacer()
                        Image(systemName: "arrow.right").font(.body.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .background(Color.kagamiFill, in: .rect(cornerRadius: 12, style: .continuous))
                    .contentShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(TShark.url == nil)
                .opacity(TShark.url == nil ? 0.5 : 1)
                .help(TShark.url == nil ? "Install Wireshark first (step 2)" : "Opens the demo in a capture window")
                HStack(spacing: 10) {
                    Button { Demo.openFlows(); close() } label: { Label("Flow Demo", systemImage: "point.3.filled.connected.trianglepath.dotted") }
                        .help("4,000 synthetic NetFlow records; no Wireshark needed")
                    Button { Demo.record(); close() } label: { Label("Record", systemImage: "record.circle") }
                        .disabled(TShark.url == nil)
                        .help("Start recording on the interface picked in the toolbar")
                    Button { Demo.openFile(); close() } label: { Label("Open a File…", systemImage: "doc") }
                        .help("A capture (pcap, pcapng and more) or a flow export")
                }
                .buttonStyle(.bordered)
                .tint(nil)
                .controlSize(.large)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Worth knowing").font(.headline)
                HStack(alignment: .top, spacing: 22) {
                    Shortcut(keys: "⌘K", text: "Find any action, packet or host")
                    Shortcut(keys: "⌘F", text: "Build a filter in plain words")
                    Shortcut(keys: "⇧⌘F", text: "Follow a conversation")
                    Shortcut(keys: "⌘1 ⌘2 ⌘5", text: "Packets, Overview, Flows")
                }
            }
        }
        .padding(.horizontal, 44)
        .padding(.top, 40)
    }
}

private struct Shortcut: View {
    let keys: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(keys.split(separator: " ").map(String.init), id: \.self) { k in
                    Text(k)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.raised, in: .rect(cornerRadius: 5, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.rule, lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.12), radius: 0.5, y: 1)
                }
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 140, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Demo

/// The bundled demo files, copied out of the app on first use so they open like any file of yours.
@MainActor
enum Demo {
    /// Packet 43 is a TLS Client Hello: every layer from loopback to the SNI.
    static let showcasePacket = 43

    static func openCapture() {
        guard let url = copy("demo", ext: "pcapng") else { return }
        let store = target()
        open(url, in: store)
        store.showAnatomyHint = true
        store.inspectorTab = .anatomy
        store.showInspector = true
        Task { @MainActor in
            for _ in 0..<100 where store.packet(showcasePacket) == nil || store.isLoading {
                try? await Task.sleep(for: .milliseconds(100))
            }
            store.select(showcasePacket)
        }
    }

    static func openFlows() {
        guard let url = copy("demo", ext: "netflow.gz") else { return }
        open(url, in: target())
    }

    static func record() {
        let store = target()
        if store.source == .none { store.start() }
    }

    static func openFile() { Stores.shared.openPanel(from: target()) }

    private static func target() -> CaptureStore {
        Stores.shared.frontStore() ?? Stores.shared.store(nil)
    }

    private static func open(_ url: URL, in store: CaptureStore) {
        if store.source == .none { store.open(url) } else { Stores.shared.open(url) }
    }

    /// ~/Library/Application Support/Kagami/Demo/<name>: outside the signed bundle, written once.
    private static func copy(_ name: String, ext: String) -> URL? {
        guard let source = Bundle.main.url(forResource: name, withExtension: ext),
              let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let folder = support.appendingPathComponent("Kagami/Demo", isDirectory: true)
        let target = folder.appendingPathComponent("\(name).\(ext)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.copyItem(at: source, to: target) }
        return FileManager.default.fileExists(atPath: target.path) ? target : nil
    }
}

// MARK: The hint at the point of use

/// Shown once, over the Anatomy of the demo's first packet: what you're looking at and what to try.
struct AnatomyHint: View {
    @Environment(CaptureStore.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.kagami)
            VStack(alignment: .leading, spacing: 4) {
                Text("This is one packet, drawn the way the RFCs draw it").font(.callout.weight(.semibold))
                Text("Each box is a header field, sized by its bits. Click one and its bytes light up below; click a byte to find its field. Press ⌘K to search for anything.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                withAnimation(.smooth(duration: 0.3)) { store.showAnatomyHint = false }
            } label: {
                Text("Got It").font(.callout.weight(.medium))
            }
            .buttonStyle(.bordered)
            .tint(nil)
            .controlSize(.small)
        }
        .padding(14)
        // Opaque: the diagram under it must not show through the text.
        .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.raised) }
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.kagami.opacity(0.55), lineWidth: 1) }
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .padding(12)
        .accessibilityElement(children: .contain)
    }
}
