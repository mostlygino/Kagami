import KagamiCore
import SwiftUI

/// NetFlow v5/v9 and IPFIX records found in the capture, as a table of flows: what routers and
/// firewalls reported, rather than the packets themselves.
struct FlowsView: View {
    @Environment(CaptureStore.self) private var store
    @State private var truncated = false
    @State private var loading = true
    @State private var reading = ReadProgress()
    @State private var error: String?
    @State private var selection: Set<FlowRecord.ID> = []
    @State private var order = [KeyPathComparator(\FlowRecord.bytes, order: .reverse)]
    /// Sorted, searched and capped off the main thread: a flow file can hold millions of records.
    @State private var shown: [FlowRecord] = []
    @State private var matching = 0
    @State private var sorting = false
    @State private var generation = 0
    @AppStorage("flowExtraPorts") private var extraPorts = ""

    /// Rows the table holds at once; search or sort to reach the rest.
    nonisolated static let displayLimit = 100_000

    private var ports: [Int] { extraPorts.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }.filter { (1...65535).contains($0) } }

    private var flows: [FlowRecord] { store.flowRecords }
    private var facts: FlowSummary? { store.flowSummary }

    var body: some View {
        Group {
            if loading && flows.isEmpty {
                VStack(spacing: 12) {
                    if store.isFlowFile, let p = reading.fraction {
                        ProgressView(value: p) { Text("Reading \(store.documentURL?.lastPathComponent ?? "flows")…") }
                            .frame(width: 320)
                    } else {
                        ProgressView("Reading flow exports…")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView("Could not read flows", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if flows.isEmpty {
                empty
            } else {
                VStack(spacing: 0) {
                    summary.padding(.horizontal, 16).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    if !store.flowFilter.isEmpty { filterBar; Divider() }
                    table
                        .overlay { if sorting && shown.isEmpty { ProgressView() } }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .task(id: FlowKey(file: store.documentURL, count: store.isCapturing ? store.packets.count / 50 : store.packets.count, ports: extraPorts)) {
            await load()
        }
        .task(id: ViewKey(generation: generation, order: order, search: store.flowSearch, filter: store.flowFilter)) { await arrange() }
        .onChange(of: selection) { _, ids in
            // One flow fills the inspector; the first pick brings it in.
            guard let id = ids.first, ids.count == 1 else { return }
            store.selectedFlow = shown.first { $0.id == id }
        }
    }

    struct FlowKey: Hashable { let file: URL?; let count: Int; let ports: String }
    struct ViewKey: Equatable { let generation: Int; let order: [KeyPathComparator<FlowRecord>]; let search: String; let filter: FlowFilter }

    @Observable @MainActor final class ReadProgress { var fraction: Double? }

    private func load() async {
        guard let url = store.documentURL else { return }
        loading = true
        defer { loading = false }
        do {
            if store.isFlowFile {
                reading.fraction = 0
                let box = reading
                let loaded = try await FlowFiles.load(url) { v in Task { @MainActor in box.fraction = v } }
                guard !Task.isCancelled else { return }
                store.flowRecords = loaded.records
                truncated = loaded.truncated
            } else {
                let read = try await Flows.read(url, extraPorts: ports)
                guard !Task.isCancelled else { return }
                store.flowRecords = read
                truncated = false
            }
            error = nil
            generation += 1
            let all = flows
            store.flowSummary = await Task.detached(priority: .userInitiated) { FlowSummary(all) }.value
        } catch {
            if !Task.isCancelled && flows.isEmpty { self.error = error.localizedDescription }
        }
    }

    /// Search, sort and cap, away from the main thread. A new search or sort cancels the one in flight.
    private func arrange() async {
        let all = flows, q = store.flowSearch.trimmingCharacters(in: .whitespaces), order = order, filter = store.flowFilter
        if !q.isEmpty && all.count > 50_000 { try? await Task.sleep(for: .milliseconds(200)) }  // let typing settle
        guard !Task.isCancelled else { return }
        sorting = true
        defer { sorting = false }
        let job = Task.detached(priority: .userInitiated) { () -> ([FlowRecord], Int)? in
            let narrowed = filter.isEmpty ? all : all.filter(filter.matches)
            let found = q.isEmpty ? narrowed : narrowed.filter {
                $0.source.contains(q) || $0.destination.contains(q) || $0.sourceEndpoint.contains(q) || $0.destinationEndpoint.contains(q)
                    || $0.exporter.contains(q) || $0.protoName.localizedCaseInsensitiveContains(q)
            }
            if Task.isCancelled { return nil }
            return (Array(FlowsView.sorted(found, order).prefix(FlowsView.displayLimit)), found.count)
        }
        let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
        guard let result, !Task.isCancelled else { return }
        shown = result.0
        matching = result.1
        if let n = store.launchFlow, shown.indices.contains(n) {
            store.launchFlow = nil
            selection = [shown[n].id]
        }
    }

    /// Sorts with a plain closure for the table's columns: a key-path comparator is many times slower
    /// on millions of rows.
    nonisolated static func sorted(_ flows: [FlowRecord], _ order: [KeyPathComparator<FlowRecord>]) -> [FlowRecord] {
        guard let c = order.first else { return flows }
        let up = c.order == .forward
        func by<T: Comparable>(_ key: (FlowRecord) -> T) -> [FlowRecord] {
            flows.sorted { up ? key($0) < key($1) : key($0) > key($1) }
        }
        let k = c.keyPath
        if k == \FlowRecord.bytes as PartialKeyPath<FlowRecord> { return by(\.bytes) }
        if k == \FlowRecord.packets as PartialKeyPath<FlowRecord> { return by(\.packets) }
        if k == \FlowRecord.source as PartialKeyPath<FlowRecord> { return by(\.source) }
        if k == \FlowRecord.destination as PartialKeyPath<FlowRecord> { return by(\.destination) }
        if k == \FlowRecord.exporter as PartialKeyPath<FlowRecord> { return by(\.exporter) }
        if k == \FlowRecord.tcpFlags as PartialKeyPath<FlowRecord> { return by(\.tcpFlags) }
        if k == \FlowRecord.startKey as PartialKeyPath<FlowRecord> { return by(\.startKey) }
        if k == \FlowRecord.protoName as PartialKeyPath<FlowRecord> { return by { $0.proto ?? -1 } }
        return flows.sorted(using: order)
    }

    // MARK: Summary

    private var summary: some View {
        let f = facts
        let talkers = f?.talkers ?? []
        // Side by side when there is room; the talkers drop below the facts in a narrow window.
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 32) { factsColumn(f); talkersColumn(talkers).frame(minWidth: 380) }
            VStack(alignment: .leading, spacing: 18) { factsColumn(f); talkersColumn(talkers) }
        }
    }

    private func factsColumn(_ f: FlowSummary?) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(flows.count.grouped) flows").font(.title2.weight(.semibold).monospacedDigit())
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow { Text("Reported traffic").foregroundStyle(.secondary); Text(f.map { "\(Format.bytes($0.bytes)) in \($0.packets.grouped) packets" } ?? "…").monospacedDigit() }
                    GridRow {
                        Text("Exporters").foregroundStyle(.secondary)
                        Text(f.map { $0.exporters.isEmpty ? "Not in the file" : $0.exporters.prefix(4).map(\.key).joined(separator: ", ") + ($0.exporters.count > 4 ? " and \($0.exporters.count - 4) more" : "") } ?? "…").lineLimit(2)
                    }
                    GridRow { Text("Formats").foregroundStyle(.secondary); Text(f?.formats.joined(separator: ", ") ?? "…") }
                    if let a = f?.first, let b = f?.last {
                        GridRow {
                            Text("Time span").foregroundStyle(.secondary)
                            Text(verbatim: FlowStyle.span(Date(timeIntervalSince1970: a), Date(timeIntervalSince1970: b))).monospacedDigit()
                        }
                    }
                }
                .font(.callout)
                Text(truncated ? "Kagami stopped at the first \(FlowFiles.recordLimit.grouped) records of \(store.documentURL?.lastPathComponent ?? "this file")."
                     : store.isFlowFile ? "Records as the exporters reported them, read from \(store.documentURL?.lastPathComponent ?? "the file")."
                     : "Counts come from the exporters, not from packets in this capture.")
                    .font(.caption).foregroundStyle(truncated ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: 260, alignment: .leading)
    }

    private func talkersColumn(_ talkers: [Flows.Talker]) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Top talkers").font(.headline)
                    Text("by bytes, both directions").font(.callout).foregroundStyle(.secondary)
                }
                let top = Double(talkers.first?.bytes ?? 1)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(talkers) { t in
                        Button { store.flowFilter = FlowFilter(pair: t.pair.components(separatedBy: " ⇄ ")) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(t.pair).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text("\(Format.bytes(t.bytes)) · \(t.flows.grouped) flow\(t.flows == 1 ? "" : "s")").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            GeometryReader { g in
                                UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3)
                                    .fill(Color.kagami.opacity(0.8))
                                    .frame(width: max(3, g.size.width * Double(t.bytes) / top))
                            }
                            .frame(height: 5)
                        }
                        .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show only the flows between these two")
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: 520)
            }
    }

    // MARK: Filter

    /// What the table is narrowed to, each part removable.
    private var filterBar: some View {
        let f = store.flowFilter
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(Color.kagami)
            if let h = f.host { chip("Host \(h)") { store.flowFilter.host = nil } }
            if let p = f.pair, p.count == 2 { chip("\(p[0]) ⇄ \(p[1])") { store.flowFilter.pair = nil } }
            if let p = f.port { chip("Port \(p)") { store.flowFilter.port = nil } }
            if let p = f.proto { chip(FlowRecord.protoName(p)) { store.flowFilter.proto = nil } }
            if let e = f.exporter { chip("Exporter \(e)") { store.flowFilter.exporter = nil } }
            Spacer()
            Button("Copy nfdump Filter") { copyText(f.nfdump) }
                .buttonStyle(.borderless)
                .disabled(f.nfdump.isEmpty)
                .help(f.nfdump)
            Button("Clear") { store.flowFilter = FlowFilter() }
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private func chip(_ text: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: text).font(.callout.monospaced()).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Color.kagami.opacity(0.14), in: .capsule)
    }

    // MARK: Table

    private var table: some View {
        Table(shown, selection: $selection, sortOrder: $order) {
            // Sort on the stored address, not the joined endpoint string: cheap enough for millions of rows.
            // The essentials only, so the table fits without scrolling sideways; interfaces, AS and exporter are in the inspector.
            Group {
                TableColumn("Source", value: \.source) { (f: FlowRecord) in Self.mono(f.sourceEndpoint) }.width(min: 110, ideal: 150)
                TableColumn("Destination", value: \.destination) { (f: FlowRecord) in Self.mono(f.destinationEndpoint) }.width(min: 110, ideal: 150)
                TableColumn("Protocol", value: \.protoName) { (f: FlowRecord) in Text(f.protoName) }.width(min: 50, ideal: 56)
                TableColumn("Start", value: \.startKey) { (f: FlowRecord) in Self.startCell(f, withDate: spansDays) }.width(min: 80, ideal: spansDays ? 150 : 96)
            }
            Group {
                TableColumn("Packets", value: \.packets) { (f: FlowRecord) in Self.number(f.packets.grouped) }.width(min: 50, ideal: 60).alignment(.numeric)
                TableColumn("Bytes", value: \.bytes) { (f: FlowRecord) in Self.number(Format.bytes(f.bytes)) }.width(min: 60, ideal: 72).alignment(.numeric)
                TableColumn("Duration") { (f: FlowRecord) in Self.number(f.duration.map(Format.duration) ?? "–") }.width(min: 50, ideal: 60).alignment(.numeric)
                if facts?.hasFlags ?? true {
                    TableColumn("TCP flags", value: \.tcpFlags) { (f: FlowRecord) in Self.mono(Self.flags(f.tcpFlags)) }.width(min: 56, ideal: 60)
                }
            }
        }
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: FlowRecord.ID.self) { ids in
            // A flow file has no packets behind its records.
            if !store.isFlowFile {
                Button("Show Export Packet") { show(ids) }
                Button("Filter Packets to These Hosts") { filterHosts(ids) }
                Divider()
            }
            Button("Copy as CSV") { copy(ids, .csvHeader) }
            Button("Copy as JSON") { copy(ids, .json) }
        } primaryAction: { ids in if !store.isFlowFile { show(ids) } }
    }

    static func mono(_ s: String) -> Text { Text(verbatim: s).font(.system(size: 11.5, design: .monospaced)) }
    static func number(_ s: String) -> Text { Text(verbatim: s).monospacedDigit() }

    static func interfaces(_ f: FlowRecord) -> String {
        "\(f.inputInterface.map { String($0) } ?? "–") → \(f.outputInterface.map { String($0) } ?? "–")"
    }

    static func asPath(_ f: FlowRecord) -> String {
        guard let a = f.sourceAS else { return "–" }
        return "\(String(a)) → \(f.destinationAS.map { String($0) } ?? "–")"
    }

    static func startCell(_ f: FlowRecord, withDate: Bool) -> Text {
        let text: String = f.start.map { FlowStyle.clock(Date(timeIntervalSince1970: $0), withDate: withDate) } ?? "–"
        return Text(verbatim: text).monospacedDigit()
    }

    /// When every flow is from one day the column shows the time alone and its title names the day.
    private var spansDays: Bool {
        guard let a = facts?.first, let b = facts?.last else { return false }
        return !Calendar.current.isDate(Date(timeIntervalSince1970: a), inSameDayAs: Date(timeIntervalSince1970: b))
    }



    /// "0x1b" as the letters of the flags that are set.
    static func flags(_ hex: String) -> String {
        guard let v = Int(hex.dropFirst(hex.hasPrefix("0x") ? 2 : 0), radix: 16), v != 0 else { return "–" }
        return [(0x20, "U"), (0x10, "A"), (0x08, "P"), (0x04, "R"), (0x02, "S"), (0x01, "F")].map { v & $0.0 != 0 ? $0.1 : "·" }.joined()
    }

    private func show(_ ids: Set<FlowRecord.ID>) {
        guard let f = flows.first(where: { ids.contains($0.id) }) else { return }
        store.select(f.frame)
    }

    private func filterHosts(_ ids: Set<FlowRecord.ID>) {
        let chosen = flows.filter { ids.contains($0.id) }
        let addrs = Set(chosen.flatMap { [$0.source, $0.destination] }).sorted()
        guard !addrs.isEmpty else { return }
        store.applyAsFilter(addrs.map { ($0.contains(":") ? "ipv6.addr == " : "ip.addr == ") + $0 }.joined(separator: " or "))
    }

    private func copy(_ ids: Set<FlowRecord.ID>, _ format: RowFormat) {
        let chosen = shown.filter { ids.contains($0.id) }
        let header = ["Source", "Destination", "Protocol", "Packets", "Bytes", "Duration", "TCP flags", "Input", "Output", "Source AS", "Destination AS", "Exporter", "Version", "Frame"]
        copyText(format.render(header: header, rows: chosen.map {
            [$0.sourceEndpoint, $0.destinationEndpoint, $0.protoName, String($0.packets), String($0.bytes), $0.duration.map { String($0) } ?? "",
             $0.tcpFlags, $0.inputInterface.map(String.init) ?? "", $0.outputInterface.map(String.init) ?? "",
             $0.sourceAS.map(String.init) ?? "", $0.destinationAS.map(String.init) ?? "", $0.exporter, $0.version, String($0.frame)]
        }))
    }

    // MARK: Empty and footer

    @ViewBuilder private var empty: some View {
        if store.isFlowFile {
            ContentUnavailableView("No flow records", systemImage: "point.3.filled.connected.trianglepath.dotted",
                                   description: Text("\(store.documentURL?.lastPathComponent ?? "This file") holds no flow records."))
        } else {
            collectorEmpty
        }
    }

    private var collectorEmpty: some View {
        ContentUnavailableView {
            Label("No flow exports here", systemImage: "point.3.filled.connected.trianglepath.dotted")
        } description: {
            Text("Flows lists NetFlow v5/v9 and IPFIX records that routers, firewalls and switches send to a collector. To collect them, point an exporter at this Mac and record with the flow collector preset.")
        } actions: {
            Button("Record as Flow Collector") { store.startFlowCollector() }
                .buttonStyle(.glassProminent)
                .disabled(store.isCapturing)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if store.isFlowFile {
                EmptyView()
            } else {
                Text("Also decode flow exports on UDP ports:").foregroundStyle(.secondary)
                TextField("e.g. 9999, 6000", text: $extraPorts)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .help("Decode these ports as NetFlow/IPFIX too (Wireshark “Decode As”). Standard ports 2055, 4739, 9995 and 9996 are decoded already.")
            }
            Spacer()
            if loading { ProgressView().controlSize(.mini) }
            if sorting { ProgressView().controlSize(.mini) }
            Text(matching > shown.count
                 ? "First \(shown.count.grouped) of \(matching.grouped) matching · search or sort to see others"
                 : "\(shown.count.grouped) of \(flows.count.grouped) flows")
                .monospacedDigit().foregroundStyle(.secondary)
                .help(matching > shown.count ? "The table holds \(FlowsView.displayLimit.grouped) rows at a time; the summary counts every record." : "")
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}


/// Holds UDP sockets on the collector ports while collecting, so exporters see a listener rather
/// than ICMP port-unreachable. The packets themselves are read from the capture.
@MainActor
final class FlowListener {
    static let shared = FlowListener()
    private var sockets: [Int32] = []
    /// The capture that asked for the sockets; only it can close them.
    private weak var owner: CaptureStore?

    func start(for store: CaptureStore) {
        close()
        owner = store
        for port in [2055, 4739, 9995, 9996, 6343] {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { continue }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr = in_addr(s_addr: INADDR_ANY)
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            if ok == 0 { sockets.append(fd) } else { Darwin.close(fd) }  // a port already taken by another collector is fine
        }
    }

    func stop(for store: CaptureStore) {
        guard owner === store else { return }
        close()
    }

    private func close() {
        for fd in sockets { Darwin.close(fd) }
        sockets = []
        owner = nil
    }
}

extension FlowRecord {
    /// Start time for sorting; flows without one sort first.
    var startKey: Double { start ?? -1 }
}
