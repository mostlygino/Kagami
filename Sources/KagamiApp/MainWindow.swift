import KagamiCore
import SwiftUI

struct MainWindow: View {
    @Environment(CaptureStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @AppStorage("rowColouring") private var colouring = RowColouring.protocols
    @AppStorage("timeDisplay") private var timeDisplay = TimeDisplay.relative
    @State private var exporting = false
    @State private var dropTargeted = false
    @State private var showPermissionHelp = false
    @State private var inspectorAllowed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @State private var commenting: [Int]?
    @State private var buildingFilter = false
    @State private var columns = NavigationSplitViewVisibility.detailOnly
    @State private var windowWidth: CGFloat = 1200
    @State private var foldedForInspector = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 320)
        } detail: {
            content
                // No inspector before there is a capture: nothing to inspect, and its width would squeeze the start screen.
                // The inspector's presence must not flip in the same pass that swaps the start screen for the
                // table: AppKit's split view then loops on its minimum sizes and throws. It follows a settled flag.
                .inspector(isPresented: Binding(get: { store.showInspector && inspectorAllowed }, set: { store.showInspector = $0 })) {
                    Group {
                        if store.mode == .flows { FlowInspector() } else { InspectorView(onCompare: compare) }
                    }
                        .inspectorColumnWidth(min: 340, ideal: store.mode == .flows ? 360 : 400, max: 680)
                }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        // The start screen has nothing for a sidebar to list; it arrives with the capture, a beat after the swap.
        .task(id: store.source == .none) {
            if store.source == .none { foldedForInspector = false; withAnimation(.smooth(duration: 0.3)) { columns = .detailOnly }; return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            // A packet chosen at open (--select, a link) already wants the inspector: on a narrow window keep the room for it.
            if store.hasSelectedOnce && store.showInspector && windowWidth < 1260 { foldedForInspector = true; return }
            withAnimation(.smooth(duration: 0.35)) { columns = .all }
        }
        .navigationTitle(store.title)
        .toolbar(removing: .title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let problem = store.problem {
                ProblemBanner(problem: problem, showHelp: { showPermissionHelp = true }) { store.problem = nil }
            }
        }
        .task { await store.loadInterfaces() }
        .task(id: wantsInspector) {
            let want = wantsInspector
            if want { try? await Task.sleep(for: .milliseconds(120)) }  // let any content swap land first
            guard !Task.isCancelled else { return }
            // On a narrow window the table needs the room: fold the sidebar first (once per capture),
            // then let the inspector glide in. The sidebar button brings it back.
            // Flows' table and summary need more room than the packet list.
            if want && !inspectorAllowed && store.showInspector && windowWidth < (store.mode == .flows ? 1600 : 1260) && columns != .detailOnly && !foldedForInspector {
                foldedForInspector = true
                withAnimation(.smooth(duration: 0.3)) { columns = .detailOnly }
                try? await Task.sleep(for: .milliseconds(260))
                guard !Task.isCancelled else { return }
            }
            withAnimation(.smooth(duration: 0.32)) { inspectorAllowed = want }
        }
        .task { if store.launchAbout { store.launchAbout = false; try? await Task.sleep(for: .milliseconds(400)); openWindow(id: "about") } }
        .task {
            guard let q = store.launchPalette else { return }
            store.launchPalette = nil
            try? await Task.sleep(for: .seconds(2.5))
            CommandPalette.shared.show(PaletteContext(store: store, actions: paletteActions, window: NSApp.windows.first { $0.tabbingIdentifier == "KagamiCapture" },
                                                      openWindow: openWindow, openSettings: {}), query: q)
        }
        .onChange(of: store.engineReady) {
            if let surface = store.launchSurface, store.engineReady {
                store.launchSurface = nil
                switch surface {
                case "--endpoints": if let id = store.windowID { openWindow(value: EndpointsRequest(store: id)) }
                case "--builder": buildingFilter = true
                case "--export": exporting = true
                default: openSettings()
                }
            }
            if store.launchFollow, let p = store.focusedPacket { store.launchFollow = false; follow(p) }
            if let c = store.launchCompare, store.packet(c.last ?? 0) != nil { store.launchCompare = nil; store.selection = Set(c); compare(c) }
        }
        .onChange(of: colouring) { _, c in if c == .wireshark { Task { await store.loadWiresharkColours() } } }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            store.open(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay { if dropTargeted { DropOverlay() } }
        .sheet(isPresented: $exporting) { ExportSheet() }
        .sheet(isPresented: $showPermissionHelp) { PermissionHelp() }
        .sheet(isPresented: $buildingFilter) { FilterBuilderView() }
        .onChange(of: store.showFilterBuilder) { if store.showFilterBuilder { store.showFilterBuilder = false; buildingFilter = true } }
        .sheet(item: Binding(get: { commenting.map(CommentTarget.init) }, set: { commenting = $0?.numbers })) { target in
            CommentSheet(numbers: target.numbers)
        }
        .focusedSceneValue(\.kagamiActions, paletteActions)
    }

    private var paletteActions: KagamiActions {
        KagamiActions(
            follow: { if let p = store.focusedPacket { follow(p) } },
            compare: { compare(store.selection.sorted()) },
            export: { exporting = true },
            comment: { if !store.selection.isEmpty { commenting = store.selection.sorted() } },
            buildFilter: { if store.source != .none && !store.isFlowFile { buildingFilter = true } },
            endpoints: { if let id = store.windowID { openWindow(value: EndpointsRequest(store: id)) } },
            canFollow: store.focusedPacket?.stream != nil,
            canCompare: store.selection.count == 2,
            canExport: store.fileURL != nil && !store.isCapturing,
            hasSelection: !store.selection.isEmpty,
            hasCapture: store.source != .none)
    }

    /// The packet inspector after the first pick of a packet; the flow inspector once a flow is picked.
    private var wantsInspector: Bool {
        guard store.source != .none else { return false }
        switch store.mode {
        case .packets: return store.hasSelectedOnce
        case .flows: return store.selectedFlow != nil
        case .overview: return false
        }
    }

    private var subtitle: String {
        if store.isCapturing { return "Capturing on \(store.interfaces.first { $0.name == store.interface }?.friendlyName ?? store.interface)" }
        if store.isLoading { return "Reading…" }
        return ""
    }

    private enum Phase: Hashable { case missing, start, packets, overview, flows }

    private var phase: Phase {
        if store.tsharkMissing { return .missing }
        if store.source == .none { return .start }
        switch store.mode {
        case .overview: return .overview
        case .flows: return .flows
        case .packets: return .packets
        }
    }

    /// One authored move between screens: the old one blurs out as the new one sharpens in.
    @ViewBuilder private var content: some View {
        ZStack {
            screen
                .id(phase)
                .transition(reduceMotion ? .opacity : .blurIn)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ground)
        .overlay(alignment: .top) { Sheen() }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.42), value: phase)
    }

    @ViewBuilder private var screen: some View {
        if store.tsharkMissing {
            MissingWireshark()
        } else if store.source == .none {
            StartView()
        } else if store.mode == .overview {
            OverviewView()
        } else if store.mode == .flows {
            FlowsView()
        } else {
            PacketTable(colouring: colouring, timeDisplay: timeDisplay, onFollow: follow, onCompare: compare, onComment: { commenting = $0 })
                .overlay {
                    if store.visible.isEmpty && !store.isLoading {
                        EmptyTable().transition(reduceMotion ? .opacity : .blurIn)
                    }
                }
                .animation(.smooth(duration: 0.36), value: store.visible.isEmpty)
                .overlay(alignment: .bottom) {
                    if store.isCapturing && !store.followLive && store.newCount > 0 {
                        Button { store.jumpToLatest() } label: {
                            Label("\(store.newCount.grouped) new packet\(store.newCount == 1 ? "" : "s")", systemImage: "arrow.down")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: store.followLive)
                .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        @Bindable var store = store
        ToolbarItemGroup(placement: .navigation) {
            InterfaceMenu()
            RecordButton()
        }
        ToolbarItem(placement: .principal) {
            // Flows are exporter records, not packets: there the one field searches them instead of filtering packets.
            if store.mode == .flows { FlowSearchField() } else { FilterField() }
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $store.mode) {
                Label("Packets", systemImage: "list.bullet.rectangle").tag(CaptureStore.Mode.packets)
                Label("Overview", systemImage: "chart.bar.xaxis").tag(CaptureStore.Mode.overview)
                Label("Flows", systemImage: "point.3.filled.connected.trianglepath.dotted").tag(CaptureStore.Mode.flows)
            }
            .pickerStyle(.segmented).tint(nil)
            .labelStyle(.iconOnly)
            .disabled(store.source == .none || store.isFlowFile)
            .help(store.isFlowFile ? "A flow file holds flow records only" : "Packets, Overview or Flows (⌘1, ⌘2, ⌘5)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { if let p = store.focusedPacket { follow(p) } } label: { Label("Follow Stream", systemImage: "arrow.left.and.right.text.vertical") }
                .disabled(store.focusedPacket?.stream == nil)
                .help("Follow the conversation of the selected packet (⇧⌘F)")
            Button { exporting = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(store.fileURL == nil || store.isCapturing)
                .help(store.isCapturing ? "Stop the capture to export" : "Export packets (⇧⌘E)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { store.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                .help("Show or hide the inspector (⌥⌘I)")
        }
    }

    private func follow(_ packet: Packet) {
        guard let s = packet.stream, let url = store.fileURL else { return }
        openWindow(value: FollowRequest(path: url.path, stream: s, store: store.windowID))
    }

    private func compare(_ numbers: [Int]) {
        guard numbers.count == 2, let url = store.fileURL else { return }
        openWindow(value: DiffRequest(path: url.path, left: numbers[0], right: numbers[1], store: store.windowID))
    }
}

struct FollowRequest: Codable, Hashable {
    let path: String
    let stream: StreamRef
    var store: UUID?
}

struct DiffRequest: Codable, Hashable {
    let path: String
    let left: Int
    let right: Int
    var store: UUID?
}

// MARK: Menu commands

struct KagamiActions {
    var follow: () -> Void
    var compare: () -> Void
    var export: () -> Void
    var comment: () -> Void
    var buildFilter: () -> Void
    var endpoints: () -> Void
    var canFollow: Bool
    var canCompare: Bool
    var canExport: Bool
    var hasSelection: Bool
    var hasCapture: Bool
}

struct EndpointsRequest: Codable, Hashable {
    let store: UUID
}

private struct CommentTarget: Identifiable {
    let numbers: [Int]
    var id: [Int] { numbers }
}

/// ⌘L: a note on one or more packets. Kept for this window; written into pcapng exports.
struct CommentSheet: View {
    @Environment(CaptureStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let numbers: [Int]
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(numbers.count == 1 ? "Comment on packet \(numbers[0])" : "Comment on \(numbers.count) packets")
                .font(.headline)
            TextField("What is going on here?", text: $text, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .onChange(of: text) { if text.count > 1000 { text = String(text.prefix(1000)) } }
            HStack {
                Text("\(text.count) / 1000 · saved in pcapng exports").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if numbers.contains(where: { !store.mark($0).comment.isEmpty }) {
                    Button("Remove") { store.updateMarks(numbers) { $0.comment = "" }; dismiss() }
                }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { store.updateMarks(numbers) { $0.comment = text.trimmingCharacters(in: .whitespacesAndNewlines) }; dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { text = numbers.count == 1 ? store.mark(numbers[0]).comment : "" }
    }
}

struct KagamiActionsKey: FocusedValueKey { typealias Value = KagamiActions }

extension FocusedValues {
    var kagamiActions: KagamiActions? {
        get { self[KagamiActionsKey.self] }
        set { self[KagamiActionsKey.self] = newValue }
    }
}

// MARK: Capture controls

struct InterfaceMenu: View {
    @Environment(CaptureStore.self) private var store

    var body: some View {
        let current = store.interfaces.first { $0.name == store.interface }
        Menu {
            ForEach(store.interfaces) { i in
                Button { store.interface = i.name } label: {
                    Label("\(i.friendlyName)  \(i.name == i.friendlyName ? "" : i.name)", systemImage: InterfaceIcon.symbol(i.name))
                }
            }
        } label: {
            Label(current?.friendlyName ?? store.interface, systemImage: InterfaceIcon.symbol(store.interface))
                .labelStyle(.titleAndIcon)
        }
        .menuIndicator(.visible)
        .disabled(store.isCapturing)
        .help("Interface to capture on")
        .fixedSize()
    }
}

enum InterfaceIcon {
    static func symbol(_ name: String) -> String {
        if name == "en0" { return "wifi" }
        if name.hasPrefix("lo") { return "arrow.trianglehead.2.clockwise" }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") { return "lock.shield" }
        if name.hasPrefix("bridge") { return "point.3.connected.trianglepath.dotted" }
        if name.hasPrefix("awdl") || name.hasPrefix("llw") { return "antenna.radiowaves.left.and.right" }
        if name.hasPrefix("en") { return "cable.connector.horizontal" }
        return "network"
    }
}

struct RecordButton: View {
    @Environment(CaptureStore.self) private var store

    var body: some View {
        Button { store.toggleCapture() } label: {
            HStack(spacing: 6) {
                Image(systemName: store.isCapturing ? "stop.fill" : "record.circle.fill")
                    .symbolRenderingMode(store.isCapturing ? .monochrome : .multicolor)
                    .contentTransition(.symbolEffect(.replace.downUp))
                if let start = store.captureStart {
                    // While recording, the button is the clock: time on the wire, ticking in place.
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        let s = Int(ctx.date.timeIntervalSince(start))
                        Text(String(format: "%d:%02d", s / 60, s % 60))
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .contentTransition(.numericText(countsDown: false))
                            .animation(.snappy(duration: 0.25), value: s)
                    }
                    .transition(AnyTransition.blurIn.combined(with: .scale(scale: 0.6, anchor: .leading)))
                }
            }
            .padding(.horizontal, store.isCapturing ? 2 : 0)
            .animation(.smooth(duration: 0.35), value: store.isCapturing)
            .accessibilityLabel(store.isCapturing ? "Stop recording" : "Record")
        }
        .tint(.red)
        .buttonStyle(.glassProminent)
        .keyboardShortcut("r")
        .disabled(store.tsharkMissing)
        .help(store.isCapturing ? "Stop capturing (⌘R)" : "Start capturing on the chosen interface (⌘R)")
    }
}

// MARK: Display filter

struct FilterField: View {
    @Environment(CaptureStore.self) private var store
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var store = store
        let text = store.displayFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let applied = !text.isEmpty && text == store.appliedFilter
        HStack(spacing: 7) {
            Image(systemName: icon(applied: applied))
                .foregroundStyle(store.filterIsValid ? (applied ? Color.kagami : Color.secondary) : Color.red)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 16)
            TextField("Display filter", text: $store.displayFilter, prompt: Text(store.source == .none ? "Display filter" : "Filter, e.g. dns or tcp.port == 443"))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .focused($focused)
                .onSubmit { store.applyFilter() }
                .onChange(of: store.displayFilter) { store.displayFilterEdited() }
                .disabled(store.source == .none)
            Button { store.showFilterBuilder = true } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Build a filter from rules (⌘F)")
                .disabled(store.source == .none)
            if !store.displayFilter.isEmpty {
                if !applied && store.filterIsValid {
                    Text("↩")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .help("Press Return to apply")
                }
                Button { store.clearFilter() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear filter")
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 300, idealWidth: 420, maxWidth: 540)
        .help(store.filterError ?? "Wireshark display filter. Return applies it.")
        .background { Button("") { focused = true }.keyboardShortcut("l").hidden() }
    }

    private func icon(applied: Bool) -> String {
        if !store.filterIsValid { return "exclamationmark.circle.fill" }
        return applied ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease"
    }
}

/// The toolbar field in Flows mode: plain text over addresses, ports, protocol and exporter.
struct FlowSearchField: View {
    @Environment(CaptureStore.self) private var store
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(store.flowSearch.isEmpty ? Color.secondary : Color.kagami)
                .frame(width: 16)
            TextField("Search flows", text: $store.flowSearch, prompt: Text("Search flows: address, port or exporter"))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .focused($focused)
            if !store.flowSearch.isEmpty {
                Button { store.flowSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 300, idealWidth: 420, maxWidth: 540)
        .background { Button("") { focused = true }.keyboardShortcut("l").hidden() }
    }
}

// MARK: Status bar

struct StatusBar: View {
    @Environment(CaptureStore.self) private var store

    var body: some View {
        HStack(spacing: 14) {
            if let start = store.captureStart {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        Text(Format.duration(ctx.date.timeIntervalSince(start))).monospacedDigit()
                    }
                }
                .accessibilityLabel("Recording")
            } else if store.isLoading {
                ProgressView().controlSize(.mini)
                Text("Reading \(store.packets.count.grouped) packets…").monospacedDigit()
            }
            Text(counts)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(store.packets.count)))
                .animation(.snappy(duration: 0.3), value: store.packets.count)
            if store.isCapturing {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(LiveRate.shared.sample(store.totalBytes)).monospacedDigit()
                }
            }
            if let f = store.filterError {
                Label(f, systemImage: "exclamationmark.circle").foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
            // Memory matters while a capture grows; for a file that is read it is noise.
            if store.isCapturing {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    Text("\(Format.bytes(MemoryUse.footprint())) memory").monospacedDigit()
                }
                .foregroundStyle(.tertiary)
                .help("Memory Kagami uses right now")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var counts: String {
        let total = store.packets.count
        let shown = store.visible.count
        let bytes = Format.bytes(store.totalBytes)
        return shown == total ? "\(total.grouped) packets · \(bytes)" : "\(shown.grouped) of \(total.grouped) packets shown · \(bytes)"
    }
}

// MARK: States

private struct EmptyTable: View {
    @Environment(CaptureStore.self) private var store

    var body: some View {
        if store.isCapturing {
            ListeningView()
        } else {
            ContentUnavailableView {
                Label("No packets match", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Nothing in this capture passes the current filters.")
            } actions: {
                Button("Clear Filters") {
                    store.protocolFilter = []; store.hostFilter = nil; store.appFilter = nil
                    store.clearFilter()
                }
            }
        }
    }
}

struct ProblemBanner: View {
    let problem: CaptureStore.Problem
    let showHelp: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: problem.kind == .permission ? "lock.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(problem.kind == .permission ? .orange : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(problem.kind == .permission ? "Kagami isn't allowed to capture on this Mac yet." : "Something went wrong.")
                    .font(.callout.weight(.semibold))
                Text(problem.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            Spacer()
            if problem.kind == .permission { Button("How to Fix…", action: showHelp) }
            Button("Dismiss", action: dismiss)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct PermissionHelp: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allow packet capture").font(.title2.weight(.semibold))
            Text("macOS only lets members of the access_bpf group capture packets. Wireshark sets this up with a small helper called ChmodBPF.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Install ChmodBPF: open the Wireshark disk image and run “Install ChmodBPF.pkg”, or run:")
                CommandSnippet(text: "brew install --cask wireshark-chmodbpf")
                Text("2. Log out and back in, so your account picks up the access_bpf group.")
                Text("3. Press Record again.")
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

struct CommandSnippet: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(text).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
            Spacer()
            Button(copied ? "Copied" : "Copy") {
                copyText(text)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
    }
}

private struct MissingWireshark: View {
    @Environment(CaptureStore.self) private var store
    @State private var tick = 0

    var body: some View {
        ContentUnavailableView {
            Label("Kagami needs Wireshark", systemImage: "puzzlepiece.extension")
        } description: {
            VStack(spacing: 12) {
                Text("Kagami reads packets with Wireshark's own engine, so every protocol Wireshark understands shows up here. Install Wireshark, then press Check Again.")
                CommandSnippet(text: "brew install --cask wireshark")
                    .frame(maxWidth: 420)
            }
        } actions: {
            Button("Download Wireshark") { NSWorkspace.shared.open(URL(string: "https://www.wireshark.org/download.html")!) }
                .buttonStyle(.glassProminent)
            Button("Check Again") { tick += 1; Task { await store.loadInterfaces() } }
        }
        .id(tick)
    }
}

private struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.kagami, style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
            .background(Color.kagami.opacity(0.06), in: .rect(cornerRadius: 16, style: .continuous))
            .overlay { Label("Open capture", systemImage: "arrow.down.doc").font(.title3.weight(.semibold)).foregroundStyle(Color.kagami) }
            .padding(12)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

// MARK: Export

struct ExportSheet: View {
    @Environment(CaptureStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var range = CaptureStore.ExportRange.all
    @State private var pcapng = true

    var body: some View {
        let packets = store.exportPackets(range)
        VStack(alignment: .leading, spacing: 0) {
            Text("Export Packets").font(.title3.weight(.semibold)).padding([.horizontal, .top], 20)
            Form {
                Picker("Packets", selection: $range) {
                    ForEach(CaptureStore.ExportRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).tint(nil)
                LabeledContent("Count", value: packets.count.grouped)
                LabeledContent("Size", value: Format.bytes(packets.reduce(0) { $0 + $1.length }))
                LabeledContent("Duration", value: duration(packets))
                LabeledContent("Protocols", value: protocols(packets))
                Picker("Format", selection: $pcapng) {
                    Text("pcapng: keeps interface and comment metadata").tag(true)
                    Text("pcap: the classic format every tool reads").tag(false)
                }
                .pickerStyle(.radioGroup)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .tint(nil)
                Button("Export…") {
                    let (r, ng) = (range, pcapng)
                    dismiss()
                    DispatchQueue.main.async { store.export(r, pcapng: ng) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(packets.isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .background(Color.ground)
        .onAppear { if store.selection.count > 1 { range = .selected } else if store.visible.count != store.packets.count { range = .shown } }
    }

    private func duration(_ p: [Packet]) -> String {
        guard let lo = p.map(\.time).min(), let hi = p.map(\.time).max() else { return "–" }
        return Format.duration(hi - lo)
    }

    private func protocols(_ p: [Packet]) -> String {
        let all = Grouping.counted(p.map { ProtoFamily.of($0).title }).map(\.name)
        guard !all.isEmpty else { return "–" }
        return all.prefix(4).joined(separator: ", ") + (all.count > 4 ? " and \(all.count - 4) more" : "")
    }
}


/// Bytes per second over the last tick, for the status bar.
@MainActor
final class LiveRate {
    static let shared = LiveRate()
    private var last: (Date, Int)?

    func sample(_ total: Int) -> String {
        defer { last = (.now, total) }
        guard let (t, b) = last, total >= b else { return "↓↑ –" }
        let dt = max(Date.now.timeIntervalSince(t), 0.25)
        return "↓↑ " + Format.rate(Double(total - b) / dt)
    }
}

enum MemoryUse {
    /// The app's physical footprint, as Activity Monitor shows it.
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}


/// The wait before the first packet: ripples spread across the window like a touched mirror, and
/// fade as packets arrive.
struct ListeningView: View {
    @Environment(CaptureStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var begin = Date.now

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                if !reduceMotion {
                    TimelineView(.animation) { ctx in
                        Canvas { g, size in
                            let t = ctx.date.timeIntervalSince(begin)
                            let c = CGPoint(x: size.width / 2, y: size.height / 2)
                            let maxR = min(size.width, size.height) / 2
                            for i in 0..<4 {
                                // Each ring is born every 0.7 s, grows with an ease-out and fades as it widens.
                                let phase = (t / 2.8 + Double(i) / 4).truncatingRemainder(dividingBy: 1)
                                let eased = 1 - pow(1 - phase, 2.2)
                                let r = 18 + (maxR - 18) * eased
                                let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                                g.stroke(Path(ellipseIn: rect), with: .color(Color.kagami.opacity(0.55 * (1 - phase))), lineWidth: 1.5)
                            }
                        }
                    }
                }
                Circle()
                    .fill(Color.kagami.opacity(0.14))
                    .frame(width: 52, height: 52)
                Image(systemName: InterfaceIcon.symbol(store.interface))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.kagami)
            }
            .frame(width: 220, height: 220)
            .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Listening on \(store.interfaces.first { $0.name == store.interface }?.friendlyName ?? store.interface)")
                    .font(.title3.weight(.semibold))
                Text(store.captureFilter.isEmpty ? "Packets appear here the moment they cross the wire."
                                                 : "Waiting for packets that match “\(store.captureFilter)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}


extension AnyTransition {
    /// SwiftUI's blur-replace as an AnyTransition, so it can stand in a conditional beside .opacity.
    static var blurIn: AnyTransition { AnyTransition(BlurReplaceTransition(configuration: .downUp)) }
}
