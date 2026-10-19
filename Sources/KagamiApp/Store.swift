import AppKit
import KagamiCore
import Observation
import SwiftUI

/// Everything one Kagami window shows: the capture, the filters, the selection and its detail.
@Observable @MainActor
final class CaptureStore {
    enum Source: Equatable {
        case none
        case file(URL)
        case live(interface: String, file: URL)
        /// Flow records saved as a file (nfdump, CSV, JSON, Zeek): no packets, so only the Flows view.
        case flowFile(URL)

        /// The capture tshark reads; nil for flow files, so every packet path stays out of their way.
        var url: URL? {
            switch self {
            case .none, .flowFile: nil
            case .file(let u), .live(_, let u): u
            }
        }

        /// The file this window shows, whatever kind it is.
        var documentURL: URL? {
            if case .flowFile(let u) = self { return u }
            return url
        }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case packets = "Packets", overview = "Overview", flows = "Flows"
        var id: Self { self }
    }

    enum InspectorTab: String, CaseIterable, Identifiable {
        case anatomy = "Anatomy", fields = "Fields"
        var id: Self { self }
    }

    struct SortOrder: Equatable {
        var key = "number"
        var ascending = true
    }

    /// A problem worth a banner. `permission` gets its own instructions.
    struct Problem: Equatable {
        enum Kind { case general, permission, missingWireshark }
        let kind: Kind
        let message: String
    }

    // MARK: Source

    private(set) var source: Source = .none
    var interfaces: [NetInterface] = []
    var interface = UserDefaults.standard.string(forKey: "interface") ?? "en0" {
        didSet { UserDefaults.standard.set(interface, forKey: "interface") }
    }
    var captureFilter = ""
    private(set) var captureStart: Date?
    private(set) var isLoading = false
    private(set) var engineReady = false
    var problem: Problem?

    var isCapturing: Bool { if case .live = source, live != nil { return true }; return false }
    var fileURL: URL? { source.url }
    var documentURL: URL? { source.documentURL }
    var isFlowFile: Bool { if case .flowFile = source { return true }; return false }
    var title: String {
        if case .live(let iface, _) = source {
            return "\(interfaces.first { $0.name == iface }?.friendlyName ?? iface) capture"
        }
        return documentURL?.lastPathComponent ?? "Kagami"
    }

    // MARK: Flows

    /// Every flow record of the capture or flow file, as Flows read them; the sidebar and inspector share them.
    var flowRecords: [FlowRecord] = []
    var flowSummary: FlowSummary?
    /// Narrows the Flows table; set from the sidebar, the top talkers and the flow inspector.
    var flowFilter = FlowFilter()
    /// Free text over addresses, ports, protocol and exporter; the toolbar field holds it in Flows mode.
    var flowSearch = ""
    var selectedFlow: FlowRecord?

    // MARK: Packets and filters

    private(set) var packets: [Packet] = []
    private(set) var visible: [Packet] = []
    /// Bumped whenever `visible` changes other than by appending; the table reloads on it.
    private(set) var visibleVersion = 0
    /// Bumped when the "new packet" dots need repainting.
    private(set) var refreshUnseen = 0
    private(set) var totalBytes = 0

    // MARK: Marks

    enum Highlight: String, CaseIterable, Identifiable, Codable {
        case red, orange, yellow, green, blue, purple
        var id: Self { self }
        var title: String { rawValue.capitalized }
        var color: Color {
            switch self {
            case .red: .red
            case .orange: .orange
            case .yellow: .yellow
            case .green: .green
            case .blue: .blue
            case .purple: .purple
            }
        }
    }

    struct Mark: Equatable {
        var highlight: Highlight?
        var struck = false
        var comment = ""
        var isEmpty: Bool { highlight == nil && !struck && comment.isEmpty }
    }

    /// Your own notes on packets, kept for this window. Comments go into pcapng exports.
    private(set) var marks: [Int: Mark] = [:]
    private(set) var marksVersion = 0

    enum MarkFilter: String, CaseIterable, Identifiable {
        case highlighted = "Highlighted", commented = "Commented", struck = "Struck Through"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .highlighted: "highlighter"
            case .commented: "text.bubble"
            case .struck: "strikethrough"
            }
        }
    }
    var markFilter: MarkFilter? { didSet { refreshVisible() } }

    func mark(_ n: Int) -> Mark { marks[n] ?? Mark(comment: packet(n)?.comment ?? "") }

    func updateMarks(_ numbers: some Sequence<Int>, _ change: (inout Mark) -> Void) {
        for n in numbers {
            var m = mark(n)
            change(&m)
            marks[n] = m.isEmpty && (packet(n)?.comment ?? "").isEmpty ? nil : m
        }
        marksVersion += 1
        if markFilter != nil { refreshVisible() }
    }

    var markCounts: [MarkFilter: Int] {
        var c: [MarkFilter: Int] = [:]
        for n in Set(marks.keys).union(packets.lazy.filter { !$0.comment.isEmpty }.map(\.number)) {
            let m = mark(n)
            if m.highlight != nil { c[.highlighted, default: 0] += 1 }
            if !m.comment.isEmpty { c[.commented, default: 0] += 1 }
            if m.struck { c[.struck, default: 0] += 1 }
        }
        return c
    }

    // MARK: Custom columns

    /// Extra table columns, one per Wireshark field, kept across launches.
    private(set) var customColumns: [String] = UserDefaults.standard.stringArray(forKey: "customColumns") ?? [] {
        didSet { UserDefaults.standard.set(customColumns, forKey: "customColumns") }
    }
    private(set) var customValues: [String: [Int: String]] = [:]

    func addColumn(_ field: String) {
        guard !field.isEmpty, !customColumns.contains(field), field.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { return }
        Task {
            // A field name is a valid display filter; an unknown one would break every custom column.
            if let error = try? await TShark.filterError(field) {
                problem = Problem(kind: .general, message: "“\(field)” is not a Wireshark field: \(error)")
                return
            }
            customColumns.append(field)
            await loadCustomValues([field])
        }
    }

    func removeColumn(_ field: String) {
        customColumns.removeAll { $0 == field }
        customValues[field] = nil
    }

    func loadCustomValues(_ fields: [String]? = nil) async {
        guard let url = fileURL, !isCapturing else { return }
        let wanted = fields ?? customColumns
        guard !wanted.isEmpty else { return }
        let gen = generation
        let args = ["-r", url.path, "-2", "-T", "fields", "-E", "separator=/t", "-E", "occurrence=a", "-E", "aggregator=, ", "-e", "frame.number"] + wanted.flatMap { ["-e", $0] }
        guard let out = try? await TShark.checked(args), gen == generation else { return }
        var values: [String: [Int: String]] = Dictionary(uniqueKeysWithValues: wanted.map { ($0, [:]) })
        for line in String(decoding: out, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == wanted.count + 1, let n = Int(f[0]) else { continue }
            for (i, field) in wanted.enumerated() where !f[i + 1].isEmpty { values[field]?[n] = String(f[i + 1]) }
        }
        customValues.merge(values) { _, new in new }
        visibleVersion += 1
    }

    // MARK: Quick filters

    struct QuickFilter: Identifiable {
        let title: String
        let symbol: String
        let filter: String
        var id: String { title }
    }

    static let quickFilters: [QuickFilter] = [
        QuickFilter(title: "Errors", symbol: "exclamationmark.octagon", filter: "_ws.expert.severity >= error or _ws.malformed"),
        QuickFilter(title: "TCP problems", symbol: "exclamationmark.triangle", filter: "tcp.analysis.flags and !tcp.analysis.window_update"),
        QuickFilter(title: "TLS handshakes", symbol: "lock", filter: "tls.handshake.type == 1 or tls.handshake.type == 2"),
        QuickFilter(title: "DNS queries", symbol: "signpost.right", filter: "dns.flags.response == 0"),
        QuickFilter(title: "Connections opened", symbol: "arrow.right.circle", filter: "tcp.flags.syn == 1 and tcp.flags.ack == 0"),
    ]
    private var indexByNumber: [Int: Int] = [:]

    var displayFilter = ""
    private(set) var appliedFilter = ""
    private(set) var filterError: String?
    private(set) var filterIsValid = true
    private(set) var matches: Set<Int>?

    var protocolFilter: Set<ProtoFamily> = [] { didSet { refreshVisible() } }
    var hostFilter: String? { didSet { refreshVisible() } }
    var appFilter: String? { didSet { refreshVisible() } }
    var sortOrder = SortOrder() { didSet { refreshVisible() } }

    private(set) var families: [(family: ProtoFamily, count: Int)] = []
    private(set) var hosts: [(name: String, count: Int)] = []
    private(set) var apps: [(name: String, count: Int)] = []
    private(set) var streamHosts: [StreamRef: String] = [:]
    private(set) var wiresharkColours: [Int: (bg: NSColor, fg: NSColor)] = [:]

    var mode = Mode.packets {
        didSet { if isFlowFile && mode != .flows { mode = .flows } }  // a flow file has no packets to list or chart
    }
    var showInspector = true
    var inspectorTab = InspectorTab.anatomy

    // MARK: Selection

    var selection: Set<Int> = [] { didSet { if selection != oldValue { selectionChanged() } } }
    private(set) var detail: FrameDetail?
    /// The frame `detail` belongs to; differs from the selection while a new one loads.
    private(set) var detailFrame: Int?
    private(set) var layers: [Anatomy.Layer] = []
    private(set) var textLayers: [FieldNode] = []
    private(set) var detailError: String?
    var selectedField: FieldNode? { didSet { if let f = selectedField { revealField(f) } } }
    var hoveredField: FieldNode?
    var expandedFields: Set<ObjectIdentifier> = []
    /// Bumped to ask the table to scroll the selection into view.
    private(set) var revealRequest = 0

    /// The inspector arrives with the first packet you pick, not with the capture: on a narrow
    /// window its arrival would squeeze the table and fold the sidebar while packets stream in.
    private(set) var hasSelectedOnce = false

    var focusedPacket: Packet? {
        guard selection.count == 1, let n = selection.first, let i = indexByNumber[n] else { return nil }
        return packets[i]
    }

    /// Set by launch arguments; the main window opens the matching window.
    /// The window this capture lives in; Follow and Diff windows point back with it.
    var windowID: UUID?
    var launchFollow = false
    /// --flow=N: pick the Nth row of the Flows table once it is sorted (screenshots).
    var launchFlow: Int?
    var showFilterBuilder = false
    var launchAbout = false
    /// --palette[=query]: opens ⌘K for screenshots.
    var launchPalette: String?
    /// --endpoints, --builder, --export, --settings: opens that surface once the capture is read (screenshots).
    var launchSurface: String?
    var launchCompare: [Int]?

    // MARK: Live

    private var live: Process?
    private var clearTask: Task<Void, Never>?
    private var loader: Process?
    private var stoppedByUser = false
    private var pendingRows: [Packet] = []
    private var flushScheduled = false
    private var regroupTask: Task<Void, Never>?
    private var refilterTask: Task<Void, Never>?
    private var processTask: Task<Void, Never>?
    private var processByPort: [Int: String] = [:]
    var followLive = true
    private(set) var unseen: Set<Int> = []
    private(set) var newCount = 0

    // MARK: Engine

    private var session: SharkSession?
    private var detailTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var generation = 0

    var tsharkMissing: Bool { TShark.url == nil }

    // MARK: Interfaces

    func loadInterfaces() async {
        guard interfaces.isEmpty, !tsharkMissing else { return }
        do {
            interfaces = try await TShark.interfaces()
            if !interfaces.contains(where: { $0.name == interface }), let first = interfaces.first { interface = first.name }
        } catch { problem = Problem(kind: .general, message: error.localizedDescription) }
    }

    // MARK: Opening files

    func open(_ url: URL) {
        if FlowFiles.kind(of: url) != .capture { openFlows(url); return }
        stop()
        reset(.file(url))
        isLoading = true
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        let gen = generation
        do {
            live = nil
            loader = try TShark.stream(["-r", url.path, "-l"] + TShark.fieldArgs,
                onRows: { [weak self] rows in Task { @MainActor in self?.receive(rows, generation: gen) } },
                onEnd: { [weak self] status, message in Task { @MainActor in self?.fileLoaded(status: status, message: message, generation: gen) } })
        } catch {
            isLoading = false
            problem = Problem(kind: .missingWireshark, message: error.localizedDescription)
        }
    }

    /// A flow export opens straight into Flows, which reads it.
    private func openFlows(_ url: URL) {
        stop()
        reset(.flowFile(url))
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        mode = .flows
    }

    func openPanel() { Stores.shared.openPanel(from: self) }

    /// Releases the engine when the window closes.
    func close() {
        clearTask?.cancel()
        windowID = nil
        FlowListener.shared.stop(for: self)
        reset(.none)
    }

    private func fileLoaded(status: Int32, message: String?, generation gen: Int) {
        guard gen == generation else { return }
        flushRows()
        loader = nil
        isLoading = false
        if status != 0 { problem = Problem(kind: .general, message: message ?? "tshark could not read this file.") }
        regroup()
        startEngine()
    }

    private func reset(_ new: Source) {
        generation += 1
        for t in [refilterTask, processTask, regroupTask, detailTask, checkTask] { t?.cancel() }
        refilterTask = nil; processTask = nil; regroupTask = nil; detailTask = nil; checkTask = nil
        if let loader, loader.isRunning { loader.terminate() }
        loader = nil
        if let session { Task { await session.close() } }
        session = nil
        engineReady = false
        flowRecords = []; flowSummary = nil; flowFilter = FlowFilter(); flowSearch = ""; selectedFlow = nil
        let wasFlowFile = isFlowFile
        source = new
        if wasFlowFile && !isFlowFile { mode = .packets }  // a capture replacing a flow file starts on its packets
        packets = []
        visible = []
        indexByNumber = [:]
        matches = nil
        appliedFilter = ""
        displayFilter = ""
        filterError = nil
        filterIsValid = true
        totalBytes = 0
        visibleVersion += 1
        selection = []
        hasSelectedOnce = false
        detail = nil
        layers = []
        selectedField = nil
        families = []; hosts = []; apps = []; streamHosts = [:]
        wiresharkColours = [:]
        processByPort = [:]
        unseen = []; newCount = 0
        pendingRows = []
        problem = nil
        marks = [:]; marksVersion += 1
        customValues = [:]
        protocolFilter = []; hostFilter = nil; appFilter = nil; markFilter = nil
    }

    // MARK: Live capture

    func start() {
        guard !isCapturing else { return }
        guard !tsharkMissing else { problem = Problem(kind: .missingWireshark, message: TSharkError.missing.message); return }
        guard interfaces.isEmpty || interfaces.contains(where: { $0.name == interface }) else {
            problem = Problem(kind: .general, message: "There is no interface called \(interface).")
            return
        }
        let url: URL
        do { url = try CaptureFiles.newLiveCapture(interface: interface) }
        catch { problem = Problem(kind: .general, message: error.localizedDescription); return }
        reset(.live(interface: interface, file: url))

        var args = ["-i", interface, "-l", "-P", "-w", url.path] + TShark.fieldArgs
        let bpf = captureFilter.trimmingCharacters(in: .whitespaces)
        if !bpf.isEmpty { args += ["-f", bpf] }
        let gen = generation
        do {
            live = try TShark.stream(args,
                onRows: { [weak self] rows in Task { @MainActor in self?.receive(rows, generation: gen) } },
                onEnd: { [weak self] status, message in Task { @MainActor in self?.captureEnded(status: status, message: message, generation: gen) } })
            stoppedByUser = false
            captureStart = .now
            if captureFilter == Flows.collectorFilter { FlowListener.shared.start(for: self) }
            followLive = true
            startLiveLoops()
        } catch {
            source = .none
            problem = Problem(kind: .general, message: error.localizedDescription)
        }
    }

    func stop() {
        guard let live, live.isRunning else { return }
        stoppedByUser = true
        live.interrupt()  // SIGINT so tshark closes the pcapng cleanly
    }

    func toggleCapture() { isCapturing ? stop() : start() }

    /// Records the chosen interface with a filter for NetFlow, IPFIX and sFlow exports, and keeps UDP
    /// sockets open on the collector ports so exporters see a listener instead of port-unreachable replies.
    func startFlowCollector() {
        captureFilter = Flows.collectorFilter
        start()
        mode = .flows
    }

    /// ⌘K: empties the list. A live capture starts over on the same interface with a fresh file.
    func clear() {
        guard isCapturing else { return }
        stop()
        let gen = generation
        clearTask = Task { @MainActor [weak self] in
            for _ in 0..<50 { if self?.isCapturing != true { break }; try? await Task.sleep(for: .milliseconds(50)) }
            // Restart only the capture that was cleared: not after the window closed or something else opened.
            guard let self, !Task.isCancelled, self.generation == gen, self.windowID != nil else { return }
            self.start()
        }
    }

    var canClear: Bool { isCapturing }

    private func captureEnded(status: Int32, message: String?, generation gen: Int) {
        guard gen == generation else { return }
        flushRows()
        live = nil
        captureStart = nil
        FlowListener.shared.stop(for: self)
        refilterTask?.cancel(); processTask?.cancel()
        if status != 0 && !stoppedByUser {
            let text = message ?? "The capture stopped unexpectedly (status \(status))."
            let permission = text.localizedCaseInsensitiveContains("permission") || text.contains("/dev/bpf")
            problem = Problem(kind: permission ? .permission : .general, message: text)
        }
        unseen = []
        newCount = 0
        refreshUnseen += 1
        if packets.isEmpty, case .live = source, problem != nil { source = .none; return }
        regroup()
        startEngine()
        // Rows that arrived after the last live refilter: settle them against the closed file.
        if !appliedFilter.isEmpty { Task { await refilter(appliedFilter) } }
    }

    private func startLiveLoops() {
        // ponytail: the display filter re-runs over the whole file every 2 s while capturing.
        let gen = generation
        refilterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, gen == self.generation, !self.appliedFilter.isEmpty, let url = self.fileURL else { continue }
                let filter = self.appliedFilter
                guard let set = try? await TShark.matching(filter, in: url),
                      !Task.isCancelled, gen == self.generation, filter == self.appliedFilter else { continue }
                self.matches = set
                self.refreshVisible()
            }
        }
        // ponytail: lsof polling misses connections shorter than a second and other users' processes.
        processTask = Task { [weak self] in
            while !Task.isCancelled {
                let map = await ProcessMap.snapshot()
                guard let self else { return }
                self.processByPort.merge(map) { old, _ in old }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Rows

    private func receive(_ rows: [Packet], generation gen: Int) {
        guard gen == generation else { return }
        pendingRows.append(contentsOf: rows)
        // Coalesce bursts into one table update per frame.
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            MainActor.assumeIsolated { self?.flushRows() }
        }
    }

    private func flushRows() {
        flushScheduled = false
        guard !pendingRows.isEmpty else { return }
        var rows = pendingRows
        pendingRows = []
        if !processByPort.isEmpty {
            for i in rows.indices where rows[i].process.isEmpty {
                rows[i].process = rows[i].srcPort.flatMap { processByPort[$0] } ?? rows[i].dstPort.flatMap { processByPort[$0] } ?? ""
            }
        }
        for r in rows { indexByNumber[r.number] = packets.count; packets.append(r); totalBytes += r.length }
        let isDefaultOrder = sortOrder == SortOrder()
        let shown = rows.filter(passes)
        if isDefaultOrder && !hasSidebarFilter {
            visible.append(contentsOf: shown)
        } else {
            refreshVisible()
        }
        if isCapturing && !followLive { unseen.formUnion(shown.map(\.number)); newCount = unseen.count }
        scheduleRegroup()
    }

    private var hasSidebarFilter: Bool { !protocolFilter.isEmpty || hostFilter != nil || appFilter != nil || markFilter != nil }

    private func passes(_ p: Packet) -> Bool {
        if let m = matches, !m.contains(p.number) { return false }
        if !protocolFilter.isEmpty, !protocolFilter.contains(ProtoFamily.of(p)) { return false }
        if let h = hostFilter, Grouping.host(of: p, in: streamHosts) != h { return false }
        if let a = appFilter, p.process != a { return false }
        if let mf = markFilter {
            let m = mark(p.number)
            switch mf {
            case .highlighted: if m.highlight == nil { return false }
            case .commented: if m.comment.isEmpty { return false }
            case .struck: if !m.struck { return false }
            }
        }
        // Matches are only known up to the last refilter while capturing; newer rows show until then.
        return true
    }

    // ponytail: refilters and sorts the whole list; fine to a few hundred thousand rows.
    func refreshVisible() {
        var v = packets.filter(passes)
        if sortOrder != SortOrder() { v.sort(by: comparator) }
        visible = v
        visibleVersion += 1
    }

    private var comparator: (Packet, Packet) -> Bool {
        let asc = sortOrder.ascending
        func by<T: Comparable>(_ k: KeyPath<Packet, T>) -> (Packet, Packet) -> Bool {
            { a, b in a[keyPath: k] == b[keyPath: k] ? a.number < b.number : (a[keyPath: k] < b[keyPath: k]) == asc }
        }
        /// Natural order, so 10.0.0.2 sorts before 10.0.0.10.
        func text(_ f: @escaping (Packet) -> String) -> (Packet, Packet) -> Bool {
            { a, b in
                let r = f(a).localizedStandardCompare(f(b))
                return r == .orderedSame ? a.number < b.number : (r == .orderedAscending) == asc
            }
        }
        let names = streamHosts
        switch sortOrder.key {
        case "time": return by(\.time)
        case "source": return text(\.source)
        case "destination": return text(\.destination)
        case "protocol": return by(\.proto)
        case "length": return by(\.length)
        case "host": return text { Grouping.host(of: $0, in: names) }
        case "app": return by(\.process)
        case "info": return by(\.info)
        case "issues": return { a, b in a.issues.rawValue == b.issues.rawValue ? a.number < b.number : (a.issues.rawValue < b.issues.rawValue) == asc }
        default: return by(\.number)
        }
    }

    func packet(_ number: Int) -> Packet? { indexByNumber[number].map { packets[$0] } }

    func host(of p: Packet) -> String { Grouping.host(of: p, in: streamHosts) }

    // MARK: Grouping

    private func scheduleRegroup() {
        guard regroupTask == nil else { return }
        let delay = isCapturing || isLoading ? 600 : 50
        regroupTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            self?.regroupTask = nil
            self?.regroup()
        }
    }

    private func regroup() {
        streamHosts = Grouping.streamHosts(packets)
        var fam: [ProtoFamily: Int] = [:]
        for p in packets { fam[ProtoFamily.of(p), default: 0] += 1 }
        families = ProtoFamily.stackOrder.compactMap { f in fam[f].map { (f, $0) } }
        let newHosts = Grouping.counted(packets.lazy.map { Grouping.host(of: $0, in: self.streamHosts) })
        let newApps = Grouping.counted(packets.lazy.map(\.process))
        // While packets stream in, rows keep their place and new names join at the end, so the
        // sidebar never reshuffles under the pointer. A stopped capture sorts by count again.
        hosts = isCapturing ? Self.stable(hosts, newHosts) : newHosts
        apps = isCapturing ? Self.stable(apps, newApps) : newApps
        // Stream names can now cover early packets (a SYN before the SNI), so host filters and sorts must re-run.
        if hostFilter != nil || sortOrder.key == "host" { refreshVisible() }
    }

    static func stable(_ old: [(name: String, count: Int)], _ new: [(name: String, count: Int)]) -> [(name: String, count: Int)] {
        let counts = Dictionary(new.map { ($0.name, $0.count) }, uniquingKeysWith: { a, _ in a })
        let kept = old.compactMap { o in counts[o.name].map { (o.name, $0) } }
        let known = Set(old.map(\.name))
        return kept + new.filter { !known.contains($0.name) }
    }

    // MARK: Display filter

    /// Validates as you type (debounced) against sharkd, or tshark while capturing.
    func displayFilterEdited() {
        checkTask?.cancel()
        let text = displayFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { filterError = nil; filterIsValid = true; return }
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            let error: String?
            if let s = self.session { error = (try? await s.check(text)) ?? nil }
            else { error = await Self.checkWithTShark(text) }
            guard !Task.isCancelled, text == self.displayFilter.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            self.filterIsValid = error == nil
            self.filterError = error
        }
    }

    private static func checkWithTShark(_ filter: String) async -> String? {
        (try? await TShark.filterError(filter)) ?? nil
    }

    func applyFilter() {
        let filter = displayFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await refilter(filter) }
    }

    func clearFilter() {
        displayFilter = ""
        filterError = nil
        filterIsValid = true
        Task { await refilter("") }
    }

    private func refilter(_ filter: String) async {
        guard !filter.isEmpty, let url = fileURL else {
            matches = nil; appliedFilter = ""; filterError = nil; refreshVisible(); return
        }
        let gen = generation
        do {
            let set: Set<Int>
            if let s = session { set = try await s.matching(filter) } else { set = try await TShark.matching(filter, in: url) }
            guard gen == generation, filter == displayFilter.trimmingCharacters(in: .whitespacesAndNewlines) || filter == appliedFilter else { return }
            matches = set
            appliedFilter = filter
            filterError = nil
            filterIsValid = true
            refreshVisible()
        } catch {
            filterError = error.localizedDescription
            filterIsValid = false
        }
    }

    /// Sets the display filter from a field, a chart or the sidebar, and applies it.
    func applyAsFilter(_ filter: String, combine: Bool = false) {
        guard !filter.isEmpty else { return }
        displayFilter = combine && !appliedFilter.isEmpty ? FilterText.and([appliedFilter, filter]) : filter
        filterError = nil
        filterIsValid = true
        mode = .packets
        applyFilter()
    }

    // MARK: Engine and detail

    private func startEngine() {
        guard let url = fileURL, SharkSession.isAvailable else { return }
        let gen = generation
        Task {
            do {
                let s = try await SharkSession(file: url)
                guard gen == self.generation else { await s.close(); return }
                self.session = s
                self.engineReady = true
                if !self.selection.isEmpty { self.selectionChanged() }
                if UserDefaults.standard.string(forKey: "rowColouring") == RowColouring.wireshark.rawValue { await self.loadWiresharkColours() }
                await self.loadCustomValues()
            } catch {
                // tshark keeps working without sharkd; only speed is lost.
            }
        }
    }

    func loadWiresharkColours() async {
        guard let s = session, wiresharkColours.isEmpty, let raw = try? await s.colours() else { return }
        var out: [Int: (NSColor, NSColor)] = [:]
        for (n, c) in raw { if let bg = NSColor(hexString: c.bg), let fg = NSColor(hexString: c.fg) { out[n] = (bg, fg) } }
        wiresharkColours = out
    }

    private func selectionChanged() {
        if !selection.isEmpty && !hasSelectedOnce { hasSelectedOnce = true }
        detailTask?.cancel()
        guard let p = focusedPacket, let url = fileURL else {
            if selection.count != 1 { detail = nil; detailFrame = nil; layers = []; selectedField = nil }
            return
        }
        let capturing = isCapturing
        detailTask = Task { [weak self] in
            guard let self else { return }
            var result: Result<FrameDetail, Error>?
            for attempt in 0..<2 {
                do {
                    let d: FrameDetail
                    if let s = self.session {
                        do { d = try await s.frame(p.number) }
                        catch let e as TSharkError where e.message == SharkSession.stoppedMessage {
                            // sharkd died (a dissector crash, for one): read with tshark and start a fresh engine.
                            self.engineLost()
                            d = try await TShark.detail(frame: p.number, in: url)
                        }
                    } else {
                        d = try await TShark.detail(frame: p.number, in: url)
                    }
                    // A live pcapng flushes behind stdout; the newest frame may not be on disk yet.
                    if d.tree.isEmpty && capturing && attempt == 0 { try await Task.sleep(for: .milliseconds(300)); continue }
                    result = .success(d)
                } catch { result = .failure(error) }
                break
            }
            guard !Task.isCancelled, self.focusedPacket?.number == p.number, let result else { return }
            switch result {
            case .success(let d):
                self.detail = d
                self.detailFrame = p.number
                self.layers = Anatomy.layers(from: d.tree)
                self.textLayers = d.tree.filter { $0.isProtocol && Anatomy.textProtocols.contains($0.field) && !$0.children.isEmpty }
                self.detailError = nil
                self.expandedFields = Set(d.tree.filter { $0.field != "frame" }.suffix(1).map(\.id))
                self.selectedField = nil
            case .failure(let e):
                self.detail = nil
                self.detailFrame = nil
                self.layers = []
                self.detailError = e.localizedDescription
            }
        }
    }

    private func engineLost() {
        session = nil
        engineReady = false
        startEngine()
    }

    private func revealField(_ f: FieldNode) {
        for a in f.ancestors { expandedFields.insert(a.id) }
    }

    /// The protocol layer a node belongs to: its top-level ancestor.
    func layerFamily(of node: FieldNode) -> ProtoFamily {
        let root = node.ancestors.last ?? node
        return Self.family(forLayer: root.field)
    }

    static func family(forLayer field: String) -> ProtoFamily {
        ProtoFamily.classify(field, tcp: field == "tcp", udp: field == "udp")
    }

    /// Detail for any frame, for Diff. Uses sharkd when the file is loaded.
    func detail(for number: Int) async throws -> FrameDetail {
        guard let url = fileURL else { throw TSharkError("No capture is open.") }
        if let s = session { return try await s.frame(number) }
        return try await TShark.detail(frame: number, in: url)
    }

    // MARK: Table helpers

    func select(_ number: Int, reveal: Bool = true) {
        if !visible.contains(where: { $0.number == number }) {
            protocolFilter = []; hostFilter = nil; appFilter = nil
            if matches != nil { clearFilter() }
        }
        selection = [number]
        mode = .packets
        if reveal { revealRequest += 1 }
    }

    func markSeen(_ numbers: some Sequence<Int>) {
        guard !unseen.isEmpty else { return }
        let before = unseen.count
        unseen.subtract(numbers)
        if unseen.count != before { newCount = unseen.count; refreshUnseen += 1 }
    }

    func jumpToLatest() {
        followLive = true
        unseen = []
        newCount = 0
        refreshUnseen += 1
        revealRequest += 1
    }

    // MARK: Export

    enum ExportRange: String, CaseIterable, Identifiable {
        case all = "All", shown = "Shown", selected = "Selected"
        var id: Self { self }
    }

    func exportFilter(_ range: ExportRange) -> String? {
        switch range {
        case .all: return nil
        case .shown:
            if !hasSidebarFilter { return appliedFilter.isEmpty ? nil : appliedFilter }
            return frameSet(visible.map(\.number))
        case .selected: return frameSet(selection.sorted())
        }
    }

    /// `frame.number in {1..40 42 50..90}`: runs collapse into ranges so the filter stays short.
    static func frameSet(_ numbers: [Int]) -> String {
        var parts: [String] = []
        var i = 0
        let n = numbers.sorted()
        while i < n.count {
            var j = i
            while j + 1 < n.count && n[j + 1] == n[j] + 1 { j += 1 }
            parts.append(j > i ? "\(n[i])..\(n[j])" : "\(n[i])")
            i = j + 1
        }
        return "frame.number in {\(parts.joined(separator: " "))}"
    }

    private func frameSet(_ numbers: [Int]) -> String { Self.frameSet(numbers) }

    func exportPackets(_ range: ExportRange) -> [Packet] {
        switch range {
        case .all: packets
        case .shown: visible
        case .selected: selection.sorted().compactMap(packet)
        }
    }

    func export(_ range: ExportRange, pcapng: Bool) {
        guard let url = fileURL else { return }
        let panel = NSSavePanel()
        let ext = pcapng ? "pcapng" : "pcap"
        let base = url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = (range == .all ? base : "\(base)-\(range.rawValue.lowercased())") + ".\(ext)"
        panel.allowedContentTypes = [.init(filenameExtension: ext)!]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let filter = exportFilter(range)
        // Comments travel in pcapng: frame N of the export is the N-th exported packet.
        let exported = exportPackets(range).sorted { $0.number < $1.number }
        // Rewritten only when you changed a comment; then the file gets exactly your comments.
        let changed = exported.contains { mark($0.number).comment != $0.comment }
        let comments: [(Int, String)] = pcapng && changed ? exported.enumerated().compactMap { i, p in
            let c = mark(p.number).comment
            return c.isEmpty ? nil : (i + 1, c)
        } : []
        Task {
            do {
                try await TShark.export(url, to: dest, filter: filter, pcapng: pcapng)
                if pcapng && changed { try await TShark.setComments(comments, in: dest) }
                CaptureFiles.makePrivate(dest)
            } catch { problem = Problem(kind: .general, message: error.localizedDescription) }
        }
    }
}
