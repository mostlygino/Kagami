import AppKit
import KagamiCore
import SwiftUI

/// ⌘K: one floating field for every action, packet, host, app, stream, interface and display filter.
@MainActor
final class CommandPalette: NSObject, NSWindowDelegate {
    static let shared = CommandPalette()

    private var panel: PalettePanel?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(_ context: PaletteContext) {
        isVisible ? close() : show(context)
    }

    func show(_ context: PaletteContext, query: String = "") {
        // A fixed, tall panel: the glass card inside grows and shrinks with the results, top-aligned,
        // so the panel never has to resize (it would lag behind fast typing).
        let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: PaletteView.width + 40, height: PaletteView.panelHeight),
                                 styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        let host = NSHostingView(rootView: PaletteView(context: context, close: { [weak self] in self?.close() }, initialQuery: query)
            .environment(context.store).tint(.kagamiFill)
            .padding(.horizontal, 20).padding(.top, 12)
            .frame(width: PaletteView.width + 40, height: PaletteView.panelHeight, alignment: .top))
        host.sizingOptions = []
        panel.contentView = host

        // Upper third of the window's screen, like Spotlight; over the capture it belongs to.
        let anchor = context.window?.frame ?? NSApp.keyWindow?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameTopLeftPoint(NSPoint(x: anchor.midX - (PaletteView.width + 40) / 2, y: anchor.maxY - min(128, anchor.height * 0.15)))
        self.panel?.close()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        focusField(in: panel)
    }

    /// SwiftUI's focus request can land before the hosting view is in the panel.
    private func focusField(in panel: NSPanel) {
        DispatchQueue.main.async {
            guard let field = Self.textField(in: panel.contentView) else { return }
            panel.makeFirstResponder(field)
        }
    }

    private static func textField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap(textField(in:)).first
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}

/// Borderless panels refuse key status by default; this one takes typing.
private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// What the palette acts on: the capture of the window it was opened from, and that window's actions.
@MainActor
struct PaletteContext {
    let store: CaptureStore
    let actions: KagamiActions?
    weak var window: NSWindow?
    let openWindow: OpenWindowAction
    let openSettings: () -> Void
}

// MARK: - Items

struct PaletteItem: Identifiable {
    enum Icon { case symbol(String), proto(ProtoFamily), interface(String) }
    enum Group: Int { case suggested, filter, packets, actions, hosts, apps, streams, interfaces, recent }

    let id: String
    let title: String
    var subtitle: String?
    let icon: Icon
    var shortcut: String?
    var keywords: [String] = []
    let group: Group
    let run: () -> Void
    /// ⌘Return: a second action for the row (follow a host's conversation, record with a filter…).
    var alternate: (label: String, run: () -> Void)?
    var isDisabled = false
}

/// Fuzzy match: prefix beats word start beats substring beats letters in order.
enum PaletteSearch {
    static func score(_ query: String, in candidates: [String]) -> Int? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        return candidates.compactMap { score(q, $0.lowercased()) }.max()
    }

    static func score(_ q: String, _ text: String) -> Int? {
        if text.hasPrefix(q) { return 1000 - text.count }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(q) }) { return 800 - text.count }
        if text.contains(q) { return 600 - text.count }
        var gaps = 0, index = text.startIndex
        for ch in q {
            guard let found = text[index...].firstIndex(of: ch) else { return nil }
            gaps += text.distance(from: index, to: found)
            index = text.index(after: found)
        }
        return max(1, 400 - gaps * 10 - text.count)
    }
}

@MainActor
enum PaletteCatalog {
    /// `filterCheck`: the query as a display filter and Wireshark's verdict (nil error = valid), once known.
    static func items(_ c: PaletteContext, query: String, filterCheck: (text: String, error: String?)?) -> [PaletteItem] {
        let s = c.store
        let q = query.trimmingCharacters(in: .whitespaces)
        let actions = actionItems(c)

        guard !q.isEmpty else {
            let suggested = s.source == .none
                ? ["record", "open", "collect-flows", "new-tab"]
                : s.isFlowFile ? ["open", "new-tab"]
                : (s.isCapturing ? ["stop", "filter-builder", "overview", "endpoints"] : ["filter-builder", "follow", "endpoints", "overview", "export"])
            let top = suggested.compactMap { id in actions.first { $0.id == id && !$0.isDisabled } }
                .map { var i = $0; i = PaletteItem(id: i.id, title: i.title, subtitle: i.subtitle, icon: i.icon, shortcut: i.shortcut,
                                                   group: .suggested, run: i.run, alternate: i.alternate); return i }
            return top + (s.source == .none ? Array(interfaceItems(c).prefix(4)) + recentItems(c) : Array(hostItems(c).prefix(5)))
        }

        var exact: [PaletteItem] = []
        // "42" or "#42": that packet.
        if let n = Int(q.hasPrefix("#") ? String(q.dropFirst()) : q), let p = s.packet(n) {
            exact.append(PaletteItem(id: "packet-\(n)", title: "Packet \(n)", subtitle: "\(p.source) → \(p.destination) · \(p.proto) · \(p.info)",
                                     icon: .proto(ProtoFamily.of(p)), group: .packets, run: { s.select(n) },
                                     alternate: p.stream.map { _ in ("Follow its stream", { s.select(n); c.actions?.follow() }) }))
        }
        // Anything Wireshark accepts as a display filter.
        if let check = filterCheck, check.text == q, s.source != .none, Int(q) == nil {
            if check.error == nil {
                exact.append(PaletteItem(id: "apply-filter", title: "Filter: \(q)", subtitle: "Show only packets matching this Wireshark display filter",
                                         icon: .symbol("line.3.horizontal.decrease.circle.fill"), group: .filter, run: { s.displayFilter = q; s.applyAsFilter(q) },
                                         alternate: s.appliedFilter.isEmpty ? nil : ("Add to the current filter", { s.applyAsFilter(q, combine: true) })))
            } else if looksLikeFilter(q) {
                exact.append(PaletteItem(id: "bad-filter", title: "Not a valid filter yet", subtitle: check.error, icon: .symbol("exclamationmark.circle"),
                                         group: .filter, run: {}, isDisabled: true))
            }
        }

        let pool = actions.filter { !$0.isDisabled } + hostItems(c) + appItems(c) + streamItems(c) + interfaceItems(c) + recentItems(c)
        let scored = pool.compactMap { item -> (item: PaletteItem, score: Int)? in
            let title = PaletteSearch.score(q, in: [item.title]).map { $0 + 200 }
            // Subtitles and keywords count only as real substrings; stray letters in them are noise.
            let other = PaletteSearch.score(q, in: item.keywords + [item.subtitle ?? ""]).flatMap { $0 >= 600 ? $0 : nil }
            guard let s = [title, other].compactMap({ $0 }).max() else { return nil }
            // Letters-in-order matches are for actions; for long lists (interfaces, files, streams) they are noise.
            if [.interfaces, .recent, .streams, .apps].contains(item.group) && s < 600 { return nil }
            return (item, s)
        }
        let best = Dictionary(scored.map { ($0.item.group, $0.score) }, uniquingKeysWith: max)
        let ranked = scored.sorted {
            let (a, b) = (best[$0.item.group] ?? 0, best[$1.item.group] ?? 0)
            return a != b ? a > b : $0.score > $1.score
        }.map(\.item)
        return exact + ranked.prefix(40)
    }

    static func looksLikeFilter(_ q: String) -> Bool {
        q.contains("==") || q.contains("!=") || q.contains(" and ") || q.contains(" or ") || q.contains(".") && !q.contains(" ") && q.first?.isLetter == true
    }

    private static func actionItems(_ c: PaletteContext) -> [PaletteItem] {
        let s = c.store, a = c.actions
        let hasCapture = s.source != .none
        let iface = s.interfaces.first { $0.name == s.interface }?.friendlyName ?? s.interface
        var items: [PaletteItem] = [
            PaletteItem(id: s.isCapturing ? "stop" : "record", title: s.isCapturing ? "Stop Recording" : "Record on \(iface)",
                        subtitle: s.isCapturing ? "Close the capture file and keep every packet" : "Capture live packets; change the interface with the toolbar menu",
                        icon: .symbol(s.isCapturing ? "stop.circle.fill" : "record.circle"), shortcut: "⌘R",
                        keywords: ["capture", "start", "live", "sniff", "stop"], group: .actions, run: { s.toggleCapture() }, isDisabled: s.tsharkMissing),
            PaletteItem(id: "open", title: "Open…", subtitle: "Captures (pcap, pcapng…) or flow files (nfdump, CSV, JSON, Zeek)", icon: .symbol("doc"), shortcut: "⌘O",
                        keywords: ["file", "pcap", "pcapng", "load", "capture", "netflow", "nfdump", "csv", "json", "zeek", "flows"], group: .actions, run: { s.openPanel() }),
            PaletteItem(id: "welcome", title: "Welcome to Kagami", subtitle: "Setup check, the demo capture and the keys worth knowing",
                        icon: .symbol("hand.wave"), keywords: ["onboarding", "tour", "help", "demo", "getting started", "setup"],
                        group: .actions, run: { c.openWindow(id: "welcome") }),
            PaletteItem(id: "new-tab", title: "New Tab", icon: .symbol("plus.square.on.square"), shortcut: "⌘T", keywords: ["window", "tab"],
                        group: .actions, run: { Stores.shared.newWindow(tabbed: true) }),
            PaletteItem(id: "collect-flows", title: "Collect NetFlow, IPFIX and sFlow", subtitle: "Record \(iface) as a flow collector",
                        icon: .symbol("point.3.filled.connected.trianglepath.dotted"), keywords: ["netflow", "ipfix", "sflow", "collector", "flows"],
                        group: .actions, run: { s.startFlowCollector() }, isDisabled: s.isCapturing || s.tsharkMissing),
            PaletteItem(id: "filter-builder", title: "Build a Filter…", subtitle: "Rules in plain words, written out as Wireshark syntax",
                        icon: .symbol("slider.horizontal.3"), shortcut: "⌘F", keywords: ["display filter", "rules", "search"],
                        group: .actions, run: { a?.buildFilter() }, isDisabled: !hasCapture || s.isFlowFile),
            PaletteItem(id: "clear-filters", title: "Clear Filters", icon: .symbol("line.3.horizontal.decrease.circle"), shortcut: "⌘⎋",
                        keywords: ["reset", "show all"], group: .actions,
                        run: { s.protocolFilter = []; s.hostFilter = nil; s.appFilter = nil; s.markFilter = nil; s.clearFilter() },
                        isDisabled: !hasCapture || (s.appliedFilter.isEmpty && s.protocolFilter.isEmpty && s.hostFilter == nil && s.appFilter == nil)),
            PaletteItem(id: "follow", title: "Follow Stream", subtitle: s.focusedPacket.map { "Packet \($0.number)'s conversation" },
                        icon: .symbol("arrow.left.and.right.text.vertical"), shortcut: "⇧⌘F", keywords: ["conversation", "tcp", "udp", "reassemble"],
                        group: .actions, run: { a?.follow() }, isDisabled: a?.canFollow != true),
            PaletteItem(id: "compare", title: "Compare Packets", icon: .symbol("square.split.2x1"), shortcut: "⌘D", keywords: ["diff"],
                        group: .actions, run: { a?.compare() }, isDisabled: a?.canCompare != true),
            PaletteItem(id: "comment", title: "Add Comment…", icon: .symbol("text.bubble"), shortcut: "⌘L", keywords: ["note", "annotate"],
                        group: .actions, run: { a?.comment() }, isDisabled: a?.hasSelection != true),
            PaletteItem(id: "packets", title: "Show Packets", icon: .symbol("list.bullet.rectangle"), shortcut: "⌘1", keywords: ["table", "list"],
                        group: .actions, run: { s.mode = .packets }, isDisabled: !hasCapture || s.mode == .packets),
            PaletteItem(id: "overview", title: "Show Overview", subtitle: "Throughput, protocols, hosts, TCP health", icon: .symbol("chart.bar.xaxis"),
                        shortcut: "⌘2", keywords: ["dashboard", "charts", "stats", "statistics"], group: .actions,
                        run: { s.mode = .overview }, isDisabled: !hasCapture || s.mode == .overview),
            PaletteItem(id: "flows", title: "Show Flows", subtitle: "NetFlow and IPFIX records", icon: .symbol("point.3.filled.connected.trianglepath.dotted"),
                        shortcut: "⌘5", keywords: ["netflow", "ipfix", "talkers"], group: .actions, run: { s.mode = .flows },
                        isDisabled: !hasCapture || s.mode == .flows),
            PaletteItem(id: "endpoints", title: "Endpoints…", subtitle: "Traffic per app, host, address and port", icon: .symbol("person.2.wave.2"),
                        shortcut: "⌥⌘E", keywords: ["conversations", "talkers", "statistics", "sent", "received"], group: .actions,
                        run: { a?.endpoints() }, isDisabled: !hasCapture),
            PaletteItem(id: "export", title: "Export Packets…", subtitle: "All, shown or selected, as pcapng or pcap", icon: .symbol("square.and.arrow.up"),
                        shortcut: "⇧⌘E", keywords: ["save", "pcap", "pcapng"], group: .actions, run: { a?.export() }, isDisabled: a?.canExport != true),
            PaletteItem(id: "inspector", title: s.showInspector ? "Hide Inspector" : "Show Inspector", icon: .symbol("sidebar.trailing"), shortcut: "⌥⌘I",
                        keywords: ["anatomy", "fields", "bytes", "details"], group: .actions, run: { s.showInspector.toggle() }, isDisabled: !hasCapture),
            PaletteItem(id: "restart", title: "Clear and Restart", subtitle: "Empty the list and keep recording", icon: .symbol("arrow.counterclockwise"),
                        shortcut: "⇧⌘K", keywords: ["clear", "reset"], group: .actions, run: { s.clear() }, isDisabled: !s.canClear),
            PaletteItem(id: "updates", title: "Check for Updates…", icon: .symbol("arrow.down.circle"), keywords: ["release", "version", "upgrade"],
                        group: .actions, run: { Task { await Updater.shared.check(interactive: true) } }),
            PaletteItem(id: "about", title: "About Kagami", icon: .symbol("info.circle"), keywords: ["version", "build"], group: .actions,
                        run: { c.openWindow(id: "about") }),
            PaletteItem(id: "settings", title: "Settings…", icon: .symbol("gearshape"), shortcut: "⌘,", keywords: ["preferences", "colours", "time"],
                        group: .actions, run: c.openSettings),
            PaletteItem(id: "mcp", title: "Copy MCP Command", subtitle: "claude mcp add kagami …", icon: .symbol("terminal"),
                        keywords: ["claude", "ai", "agent", "cli"], group: .actions,
                        run: { copyText("claude mcp add kagami -- \"\(SettingsView.cliPath)\" mcp") }),
        ]
        for q in CaptureStore.quickFilters {
            items.append(PaletteItem(id: "quick-\(q.title)", title: q.title, subtitle: q.filter, icon: .symbol(q.symbol), keywords: ["filter", "quick"],
                                     group: .actions, run: { s.applyAsFilter(q.filter) }, isDisabled: !hasCapture))
        }
        for f in ProtoFamily.stackOrder where s.families.contains(where: { $0.family == f }) {
            items.append(PaletteItem(id: "proto-\(f.rawValue)", title: "Only \(f.title)", subtitle: "\(s.families.first { $0.family == f }?.count ?? 0) packets",
                                     icon: .proto(f), keywords: ["protocol", f.rawValue], group: .actions, run: { s.protocolFilter = [f] }))
        }
        return items
    }

    private static func hostItems(_ c: PaletteContext) -> [PaletteItem] {
        // In Flows the hosts are the flow records' addresses; picking one narrows the flow table.
        if c.store.mode == .flows, let sum = c.store.flowSummary {
            var seen = Set<String>()
            return (sum.sources + sum.destinations).filter { seen.insert($0.key).inserted }.prefix(40).map { item in
                PaletteItem(id: "flowhost-\(item.key)", title: item.key, subtitle: "\(Format.bytes(item.bytes)) in \(item.flows.grouped) flows",
                            icon: .symbol("point.3.filled.connected.trianglepath.dotted"), keywords: ["host", "address", "flow"], group: .hosts,
                            run: { c.store.flowFilter = FlowFilter(host: item.key) })
            }
        }
        return c.store.hosts.prefix(60).map { h in
            PaletteItem(id: "host-\(h.name)", title: h.name, subtitle: "\(h.count.grouped) packets", icon: .symbol("globe"),
                        keywords: ["host", "domain"], group: .hosts, run: { c.store.hostFilter = h.name; c.store.mode = .packets },
                        alternate: ("Show in Endpoints", { c.actions?.endpoints() }))
        }
    }

    private static func appItems(_ c: PaletteContext) -> [PaletteItem] {
        c.store.apps.prefix(30).map { app in
            PaletteItem(id: "app-\(app.name)", title: app.name, subtitle: "\(app.count.grouped) packets", icon: .symbol("app.dashed"),
                        keywords: ["app", "process"], group: .apps, run: { c.store.appFilter = app.name; c.store.mode = .packets })
        }
    }

    /// One row per conversation with a name: "api.example.com · TCP stream 4".
    private static func streamItems(_ c: PaletteContext) -> [PaletteItem] {
        c.store.streamHosts.sorted { $0.key.index < $1.key.index }.prefix(80).map { ref, host in
            PaletteItem(id: "stream-\(ref.proto.rawValue)-\(ref.index)", title: "\(host) · \(ref.proto.rawValue.uppercased()) stream \(ref.index)",
                        subtitle: "Follow this conversation", icon: .symbol("arrow.left.arrow.right"), keywords: ["follow", "stream", "conversation"],
                        group: .streams, run: {
                            if let first = c.store.packets.first(where: { $0.stream == ref }) { c.store.select(first.number) }
                            c.actions?.follow()
                        },
                        alternate: ("Filter to this stream", { c.store.applyAsFilter(ref.filter) }))
        }
    }

    private static func interfaceItems(_ c: PaletteContext) -> [PaletteItem] {
        guard !c.store.isCapturing else { return [] }
        return c.store.interfaces.map { i in
            PaletteItem(id: "iface-\(i.name)", title: "Record on \(i.friendlyName)", subtitle: i.name, icon: .interface(i.name),
                        keywords: ["interface", "capture", i.name], group: .interfaces,
                        run: { c.store.interface = i.name; c.store.start() },
                        alternate: ("Collect flows here", { c.store.interface = i.name; c.store.startFlowCollector() }))
        }
    }

    private static func recentItems(_ c: PaletteContext) -> [PaletteItem] {
        NSDocumentController.shared.recentDocumentURLs.prefix(8).filter { FileManager.default.fileExists(atPath: $0.path) }.map { url in
            PaletteItem(id: "recent-\(url.path)", title: url.lastPathComponent, subtitle: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                        icon: .symbol("doc"), keywords: ["recent", "open", "file"], group: .recent,
                        run: { if c.store.source == .none { c.store.open(url) } else { Stores.shared.open(url) } })
        }
    }
}

// MARK: - View

struct PaletteView: View {
    static let width: CGFloat = 660
    static let panelHeight: CGFloat = 600

    let context: PaletteContext
    let close: () -> Void
    var initialQuery = ""
    @Environment(CaptureStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var selectedID: String?
    @State private var appeared = false
    @State private var filterCheck: (text: String, error: String?)?
    @State private var listHeight: CGFloat = 300
    @FocusState private var fieldFocused: Bool
    @Namespace private var highlight

    private var items: [PaletteItem] { PaletteCatalog.items(context, query: query, filterCheck: filterCheck) }
    private var selected: PaletteItem? {
        let items = items
        return items.first { $0.id == selectedID && !$0.isDisabled } ?? items.first { !$0.isDisabled }
    }

    var body: some View {
        let items = items
        VStack(spacing: 0) {
            field
            if !items.isEmpty {
                Divider().opacity(0.5)
                results(items)
                Divider().opacity(0.5)
                footer
            } else if !query.isEmpty {
                Divider().opacity(0.5)
                Text("Nothing matches “\(query)”. Try a packet number, a host, an action such as “follow”, or a Wireshark filter like tcp.port == 443.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
        .frame(width: Self.width)
        .modifier(PaletteGlass())
        .scaleEffect(appeared || reduceMotion ? 1 : 0.96, anchor: .top)
        .opacity(appeared ? 1 : 0)
        .blur(radius: appeared || reduceMotion ? 0 : 6)
        .onAppear {
            query = initialQuery
            fieldFocused = true
            withAnimation(.spring(duration: 0.3, bounce: 0.12)) { appeared = true }
        }
        .onChange(of: query) { selectedID = nil }
        // Wireshark decides what a filter is: checked with dftest a beat after typing stops.
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty, store.source != .none, Int(q) == nil else { filterCheck = nil; return }
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            let verdict: String?
            do { verdict = try await TShark.filterError(q) } catch let failure { verdict = (failure as? TSharkError)?.message ?? failure.localizedDescription }
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.18)) { filterCheck = (q, verdict) }
        }
        .onExitCommand(perform: close)
        .animation(.smooth(duration: 0.22), value: items.count)
    }

    private var field: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
                .rotationEffect(.degrees(-4))
                .accessibilityHidden(true)
            TextField("Search actions, packets, hosts, or type a filter", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 21, weight: .regular))
                .focused($fieldFocused)
                .onSubmit { run(selected) }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .onKeyPress(keys: [.return], phases: .down) { press in
                    if press.modifiers.contains(.command), let alt = selected?.alternate { finish(alt.run); return .handled }
                    return .ignored
                }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .help("Clear the search")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    /// Hugs its rows (measured); scrolls only once they pass 400 pt, so one result makes a small card.
    private func results(_ items: [PaletteItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                list(items)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(listHeight, 44), 400))
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: nil) }
            }
        }
    }

    private func list(_ items: [PaletteItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index == 0 || items[index - 1].group != item.group {
                    groupHeader(item.group).padding(.top, index == 0 ? 6 : 12)
                }
                row(item).id(item.id)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private func groupHeader(_ group: PaletteItem.Group) -> some View {
        let title: String = switch group {
        case .suggested: "Suggested"
        case .filter: "Display filter"
        case .packets: "Packet"
        case .actions: "Actions"
        case .hosts: "Hosts"
        case .apps: "Apps"
        case .streams: "Conversations"
        case .interfaces: "Interfaces"
        case .recent: "Recent captures"
        }
        return Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
    }

    private func row(_ item: PaletteItem) -> some View {
        let isSelected = item.id == selected?.id
        return HStack(spacing: 12) {
            icon(item.icon, selected: isSelected, disabled: item.isDisabled)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(item.group == .filter ? .body.monospaced().weight(.medium) : .body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(item.isDisabled ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = item.shortcut {
                Text(shortcut).font(.callout.monospaced()).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .opacity(item.isDisabled && item.group != .filter ? 0.45 : 1)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.bronze.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.bronze.opacity(0.45), lineWidth: 1))
                    .matchedGeometryEffect(id: "highlight", in: highlight)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { run(item) }
        .onHover { if $0 && !item.isDisabled { withAnimation(.snappy(duration: 0.16)) { selectedID = item.id } } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func icon(_ icon: PaletteItem.Icon, selected: Bool, disabled: Bool) -> some View {
        let box = RoundedRectangle(cornerRadius: 8, style: .continuous)
        switch icon {
        case .proto(let f):
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(f.color).frame(width: 12, height: 12)
                .frame(width: 30, height: 30)
                .background(.quaternary.opacity(selected ? 0 : 0.6), in: box)
        case .interface(let name):
            Image(systemName: InterfaceIcon.symbol(name))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? Color.bronze : .secondary)
                .frame(width: 30, height: 30)
                .background(.quaternary.opacity(selected ? 0 : 0.6), in: box)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(disabled && name.hasPrefix("exclamationmark") ? Color.red : (selected ? Color.bronze : .secondary))
                .frame(width: 30, height: 30)
                .background(.quaternary.opacity(selected ? 0 : 0.6), in: box)
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            hint("↵", selected?.group == .filter ? "Apply" : (selected?.group == .packets ? "Show" : "Run"))
            if let alt = selected?.alternate { hint("⌘↵", alt.label) }
            hint("↑↓", "Choose")
            Spacer()
            hint("esc", "Close")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.caption.monospaced().weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label)
        }
    }

    private func move(_ delta: Int) {
        let items = items.filter { !$0.isDisabled }
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selected?.id } ?? 0
        let next = min(max(current + delta, 0), items.count - 1)
        withAnimation(.snappy(duration: 0.16)) { selectedID = items[next].id }
    }

    private func run(_ item: PaletteItem?) {
        guard let item, !item.isDisabled else { return }
        finish(item.run)
    }

    private func finish(_ action: @escaping () -> Void) {
        let window = context.window
        close()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // After the panel is gone, so windows and sheets open in front of the capture.
        DispatchQueue.main.async(execute: action)
    }
}

/// Liquid Glass over a tinted surface.
private struct PaletteGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        content
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.55), in: shape)
            .glassEffect(.regular, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }
}
