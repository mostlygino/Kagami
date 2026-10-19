/*
 THESIS: Every packet drawn the way the RFCs draw it: a 32-bit ruler, each field a box sized by its bits,
 live values inside. Refuses the category default of a tree over a hex dump as the only way to read a packet.
 OWN-WORLD: Native macOS 26 (Liquid Glass toolbar, sidebar and inspector, SF Pro, SF Mono for data). One
 protocol colour code (TCP blue, TLS orange, DNS aqua, HTTP yellow, QUIC magenta, ICMP green, UDP violet,
 ARP red) on every surface, always beside its name. Diagram rules drawn at exactly one device pixel.
 Mirror-cyan tint for selection and actions.
 STORY: A Mac developer or security engineer opens a capture or records an interface, narrows it by protocol,
 host, app or a Wireshark filter, reads one packet field by field, follows the conversation, compares two
 packets, and exports exactly what matters.
 FIRST VIEWPORT: Sidebar (protocols, hosts, apps with counts) left; colour-coded packet table centre; Anatomy
 inspector right with the selected packet's Ethernet, IP and TCP headers stacked as RFC diagrams over its
 bytes. Record and the interface sit at the toolbar's leading edge, the display filter in its centre.
 FORM: RFC Header Diagram, position 3 of 7 on the grounded list, seed 85da56db. Raised by: centre-rail
 (one-pixel rules), Saville sleeve (one colour code), gate board (live rows keep place, new ones marked until
 seen), transit diagram (Follow Stream ladder).
 FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict,
 DESIGN.md, and every shipping raster carrying its provenance
 */

import AppKit
import KagamiCore
import SwiftUI

@main
struct KagamiApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        // One capture per window; windows tab together (⌘T), like browser tabs.
        WindowGroup("Kagami", id: "capture", for: UUID.self) { $id in
            CaptureWindow(id: id)
                .frame(minWidth: 1080, minHeight: 640)
                .tint(.kagamiFill)
        }
        .defaultSize(width: 1500, height: 920)
        // Opened files arrive as external events: an empty capture window takes them (onOpenURL),
        // otherwise SwiftUI makes a new window, which opens as a tab.
        .handlesExternalEvents(matching: ["*"])
        // Captures live in memory and temp files; a restored window would come back empty.
        .restorationBehavior(.disabled)
        .commands { KagamiCommands() }

        WindowGroup("Follow Stream", for: FollowRequest.self) { $request in
            if let request {
                FollowView(request: request)
                    .environment(Stores.shared.existing(request.store))
                    .tint(.kagamiFill)
                    .frame(minWidth: 720, minHeight: 420)
                    .containerBackground(Color.ground, for: .window)
            }
        }
        .defaultSize(width: 980, height: 760)
        .handlesExternalEvents(matching: [])  // files and URLs go through AppDelegate, never a window per argument
        .restorationBehavior(.disabled)  // a stream number means nothing once its capture is gone

        WindowGroup("Compare Packets", for: DiffRequest.self) { $request in
            if let request {
                DiffView(request: request)
                    .environment(Stores.shared.existing(request.store))
                    .tint(.kagamiFill)
                    .frame(minWidth: 820, minHeight: 420)
                    .containerBackground(Color.ground, for: .window)
            }
        }
        .defaultSize(width: 1240, height: 780)
        .handlesExternalEvents(matching: [])  // files and URLs go through AppDelegate, never a window per argument
        .restorationBehavior(.disabled)

        WindowGroup("Endpoints", for: EndpointsRequest.self) { $request in
            if let request {
                EndpointsView()
                    .environment(Stores.shared.existing(request.store))
                    .tint(.kagamiFill)
                    .frame(minWidth: 760, minHeight: 420)
                    .containerBackground(Color.ground, for: .window)
            }
        }
        .defaultSize(width: 980, height: 640)
        .handlesExternalEvents(matching: [])  // files and URLs go through AppDelegate, never a window per argument
        .restorationBehavior(.disabled)

        Window("About Kagami", id: "about") {
            AboutView().tint(.kagamiFill)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)

        Settings { SettingsView().tint(.kagamiFill).containerBackground(Color.ground, for: .window) }
    }
}

/// A capture window: owns its store for as long as it is open.
struct CaptureWindow: View {
    let id: UUID?
    @Environment(\.openWindow) private var openWindow
    /// The launch window and windows from the tab bar's "+" come without an id: each keeps its own.
    @State private var fallback = UUID()

    var body: some View {
        let store = Stores.shared.store(id ?? fallback)
        MainWindow()
            .environment(store)
            .focusedSceneValue(\.captureStore, store)
            .background(WindowAccessor { window in Stores.shared.attach(window, to: store) })
            .handlesExternalEvents(preferring: store.source == .none ? ["*"] : [], allowing: ["*"])
            .onOpenURL { url in
                guard url.isFileURL, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return }
                if store.source == .none { store.open(url) } else { Stores.shared.open(url) }
            }
            .onAppear {
                Stores.shared.openWindow = openWindow
                if !Stores.shared.appliedArguments { Stores.shared.appliedArguments = true; AppDelegate.applyLaunchArguments(to: store) }
                Stores.shared.windowReady(store)
            }
    }
}

struct KagamiCommands: Commands {
    @FocusedValue(\.captureStore) private var store
    @FocusedValue(\.kagamiActions) private var actions
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Kagami") { openWindow(id: "about") }
            Button("Check for Updates…") { Task { await Updater.shared.check(interactive: true) } }
        }
        CommandGroup(replacing: .help) {
            Button("Kagami on GitHub") { NSWorkspace.shared.open(AboutView.repository) }
            Button("Report a Problem…") { NSWorkspace.shared.open(AboutView.repository.appendingPathComponent("issues/new")) }
            Divider()
            Button("Wireshark Display Filter Reference") { NSWorkspace.shared.open(URL(string: "https://www.wireshark.org/docs/dfref/")!) }
            Button("mostlygino.com") { NSWorkspace.shared.open(AboutView.website) }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Window") { Stores.shared.newWindow(tabbed: false) }.keyboardShortcut("n")
            Button("New Tab") { Stores.shared.newWindow(tabbed: true) }.keyboardShortcut("t")
            Divider()
            Button("Open…") { Stores.shared.openPanel(from: store) }.keyboardShortcut("o")
        }
        CommandGroup(after: .newItem) {
            Button("Export Packets…") { actions?.export() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(actions?.canExport != true)
        }
        CommandGroup(after: .toolbar) {
            Button("Search Actions, Packets and Hosts…") {
                guard let store else { return }
                let window = NSApp.keyWindow?.tabbingIdentifier == "KagamiCapture" ? NSApp.keyWindow
                    : NSApp.orderedWindows.first { $0.tabbingIdentifier == "KagamiCapture" && $0.isVisible }
                CommandPalette.shared.toggle(PaletteContext(store: store, actions: actions, window: window,
                                                            openWindow: openWindow, openSettings: { openSettings() }))
            }
            .keyboardShortcut("k")
            .disabled(store == nil)
            Divider()
        }
        CommandMenu("Capture") {
            Button(store?.isCapturing == true ? "Stop Capture" : "Start Capture") { store?.toggleCapture() }
                .keyboardShortcut("r")
                .disabled(store == nil)
            Divider()
            Button("Follow Stream") { actions?.follow() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(actions?.canFollow != true)
            Button("Compare Packets") { actions?.compare() }
                .keyboardShortcut("d")
                .disabled(actions?.canCompare != true)
            Divider()
            Button("Clear and Restart") { store?.clear() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(store?.canClear != true)
            Button("Build a Filter…") { actions?.buildFilter() }
                .keyboardShortcut("f")
                .disabled(actions?.hasCapture != true)
            Button("Endpoints…") { actions?.endpoints() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(actions?.hasCapture != true)
            Divider()
            Button("Clear Filters") {
                store?.protocolFilter = []; store?.hostFilter = nil; store?.appFilter = nil
                store?.clearFilter()
            }
            .keyboardShortcut(.escape, modifiers: [.command])
            .disabled(store == nil)
        }
        CommandMenu("Packet") {
            Button("Add Comment…") { actions?.comment() }
                .keyboardShortcut("l")
                .disabled(actions?.hasSelection != true)
            Menu("Highlight") {
                ForEach(Array(CaptureStore.Highlight.allCases.enumerated()), id: \.element) { i, h in
                    Button(h.title) { if let s = store { s.updateMarks(s.selection) { $0.highlight = h } } }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .control])
                }
                Divider()
                Button("None") { if let s = store { s.updateMarks(s.selection) { $0.highlight = nil } } }
                    .keyboardShortcut("0", modifiers: [.command, .control])
            }
            .disabled(actions?.hasSelection != true)
            Button("Strike Through") { if let s = store { let on = !(s.selection.allSatisfy { s.mark($0).struck }); s.updateMarks(s.selection) { $0.struck = on } } }
                .keyboardShortcut("x", modifiers: [.command, .control])
                .disabled(actions?.hasSelection != true)
        }
        CommandGroup(before: .sidebar) {
            Button("Packets") { store?.mode = .packets }.keyboardShortcut("1").disabled(store == nil)
            Button("Overview") { store?.mode = .overview }.keyboardShortcut("2").disabled(store == nil)
            Button("Flows") { store?.mode = .flows }.keyboardShortcut("5").disabled(store == nil)
            Divider()
            Button("Anatomy") { store?.showInspector = true; store?.inspectorTab = .anatomy }.keyboardShortcut("3").disabled(store == nil)
            Button("Fields") { store?.showInspector = true; store?.inspectorTab = .fields }.keyboardShortcut("4").disabled(store == nil)
            Button(store?.showInspector == false ? "Show Inspector" : "Hide Inspector") { store?.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(store == nil)
            Divider()
        }
    }
}

extension FocusedValues {
    @Entry var captureStore: CaptureStore?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // Live captures from earlier sessions hold private traffic; drop the ones nobody exported.
        DispatchQueue.global(qos: .utility).async { CaptureFiles.sweep() }
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--window") }) { Updater.shared.checkInBackground() }
        // Launched in the background (open -g, a script, another app), SwiftUI makes no first window and Kagami
        // would sit in the Dock with nothing to show. A reopen event, as a Dock click sends, makes one.
        if (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool) == false {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return }
                let me = NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier)
                let reopen = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                                    targetDescriptor: me, returnID: AEReturnID(kAutoGenerateReturnID),
                                                    transactionID: AETransactionID(kAnyTransactionID))
                _ = try? reopen.sendEvent(options: [.noReply], timeout: 2)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { Stores.shared.stopAll() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Launch arguments for scripted screenshots and demos:
    /// --open=FILE  --select=N  --inspector=anatomy|fields  --field=NAME  --overview  --flows  --appearance=light|dark
    /// --window=WxH  --follow (the selected packet's stream)  --compare=A,B  --record=IFACE [--bpf=FILTER]  --about
    static func applyLaunchArguments(to store: CaptureStore) {
        let args = CommandLine.arguments
        // --key=value only: AppKit treats a bare argument such as "dark" as a document to open.
        func value(_ flag: String) -> String? {
            args.first { $0.hasPrefix(flag + "=") }.map { String($0.dropFirst(flag.count + 1)) }
        }
        if let a = value("--appearance") { NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua) }
        if let size = value("--window")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let w = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.identifier?.rawValue.hasPrefix("capture") == true })
                        ?? NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }), let screen = w.screen else { return }
                let f = screen.visibleFrame
                w.setFrame(NSRect(x: f.midX - size[0] / 2, y: f.midY - size[1] / 2, width: size[0], height: size[1]), display: true)
            }
        }
        store.launchFollow = args.contains("--follow")
        store.launchFlow = value("--flow").flatMap { Int($0) }
        if let c = value("--compare")?.split(separator: ",").compactMap({ Int($0) }), c.count == 2 { store.launchCompare = c }
        if let f = value("--open") { store.open(URL(fileURLWithPath: f)) }
        if let i = value("--record") { store.interface = i; store.captureFilter = value("--bpf") ?? ""; store.start() }
        if let t = value("--inspector") { store.inspectorTab = t == "fields" ? .fields : .anatomy }
        if args.contains("--overview") { store.mode = .overview }
        if args.contains("--flows") { store.mode = .flows }
        store.launchPalette = value("--palette") ?? (args.contains("--palette") ? "" : nil)
        store.launchSurface = ["--endpoints", "--builder", "--export", "--settings"].first { args.contains($0) }
        store.launchAbout = args.contains("--about")
        if let n = value("--select").flatMap(Int.init) {
            let field = value("--field")
            Task { @MainActor in
                for _ in 0..<100 where store.packet(n) == nil || store.isLoading { try? await Task.sleep(for: .milliseconds(100)) }
                store.select(n)
                if let field {
                    for _ in 0..<50 where store.detail == nil { try? await Task.sleep(for: .milliseconds(100)) }
                    store.selectedField = store.detail?.tree.flatMap { $0.allNodes() }.first { $0.field == field }
                }
            }
        }
    }
}
