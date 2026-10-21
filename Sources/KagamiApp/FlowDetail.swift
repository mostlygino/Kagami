import KagamiCore
import SwiftUI

// MARK: Sidebar

/// Flows mode's sidebar: the biggest protocols, hosts, service ports and exporters, each a filter.
struct FlowFacetSections: View {
    @Environment(CaptureStore.self) private var store

    var body: some View {
        if let s = store.flowSummary {
            let f = store.flowFilter
            section("Protocols", s.protocols, clear: f.proto == nil ? nil : { store.flowFilter.proto = nil }) { item in
                let p = Int(item.key)
                SidebarToggle(isOn: f.proto == p && p != nil, count: nil) {
                    store.flowFilter.proto = f.proto == p ? nil : p
                } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(FlowStyle.family(p).color).frame(width: 10, height: 10)
                        Text(FlowStyle.protoName(p))
                        Spacer(minLength: 4)
                        Text(Format.bytes(item.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            hostSection("Sources", s.sources, symbol: "arrow.up.right")
            hostSection("Destinations", s.destinations, symbol: "arrow.down.left")
            section("Service Ports", s.ports, clear: f.port == nil ? nil : { store.flowFilter.port = nil }) { item in
                let port = Int(item.key.split(separator: " ").last ?? "")
                SidebarToggle(isOn: f.port == port && port != nil, count: nil) {
                    store.flowFilter.port = f.port == port ? nil : port
                } label: {
                    HStack {
                        Label(item.key, systemImage: "number").lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Format.bytes(item.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if s.exporters.count > 1 {
                section("Exporters", s.exporters, clear: f.exporter == nil ? nil : { store.flowFilter.exporter = nil }) { item in
                    SidebarToggle(isOn: f.exporter == item.key, count: item.flows) {
                        store.flowFilter.exporter = f.exporter == item.key ? nil : item.key
                    } label: {
                        Label(item.key, systemImage: "server.rack").lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
    }

    private func hostSection(_ title: String, _ items: [FlowSummary.Item], symbol: String) -> some View {
        let host = store.flowFilter.host
        return section(title, items, clear: host == nil ? nil : { store.flowFilter.host = nil }) { item in
            SidebarToggle(isOn: host == item.key, count: nil) {
                store.flowFilter.host = host == item.key ? nil : item.key
            } label: {
                HStack {
                    Text(verbatim: item.key).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                        .truncationMode(item.key.contains(":") ? .middle : .tail)  // only IPv6 is long enough to cut
                    Spacer(minLength: 4)
                    Text(Format.bytes(item.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .help("\(item.flows.grouped) flows, \(item.packets.grouped) packets. Click to show only flows to or from \(item.key).")
        }
    }

    @ViewBuilder
    private func section<Row: View>(_ title: String, _ items: [FlowSummary.Item], clear: (() -> Void)?,
                                    @ViewBuilder row: @escaping (FlowSummary.Item) -> Row) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { row($0) }
            } header: {
                SectionHeader(title: title, clear: clear)
            }
        }
    }
}

enum FlowStyle {
    static func family(_ proto: Int?) -> ProtoFamily {
        switch proto {
        case 6: .tcp
        case 17: .udp
        case 1, 58: .icmp
        default: .other
        }
    }

    static func protoName(_ proto: Int?) -> String { FlowRecord.protoName(proto) }

    // Flow times are technical: 24-hour, milliseconds, the same in every locale except for the month name.
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate(format)
        return f
    }
    // POSIX locale: a fixed 24-hour clock even when the Mac is set to 12-hour time.
    private static let clockOnly: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()
    private static let dayOnly = formatter("dMMMy")
    private static let dayShort = formatter("dMMM")

    static func clock(_ d: Date, withDate: Bool = false) -> String {
        withDate ? "\(dayShort.string(from: d)) \(clockOnly.string(from: d))" : clockOnly.string(from: d)
    }
    static func day(_ d: Date) -> String { dayOnly.string(from: d) }
    /// "19 Oct 2025, 10:00:00.412 – 11:01:57.000", the second date only when it differs.
    static func span(_ a: Date, _ b: Date) -> String {
        let end = Calendar.current.isDate(a, inSameDayAs: b) ? clockOnly.string(from: b) : "\(day(b)), \(clockOnly.string(from: b))"
        return "\(day(a)), \(clockOnly.string(from: a)) – \(end)"
    }
    static func full(_ d: Date) -> String { "\(day(d)), \(clockOnly.string(from: d))" }
}

// MARK: Inspector

/// One flow in full, the conversation it belongs to, and the ways to narrow the table around it.
struct FlowInspector: View {
    @Environment(CaptureStore.self) private var store
    @State private var conversation: Conversation?

    struct Conversation: Sendable {
        let flows: Int, bytes: Int, packets: Int, first: Double?, last: Double?, ports: [Int]
    }

    var body: some View {
        Group {
            if let f = store.selectedFlow {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(f)
                        facts(f)
                        conversationSection(f)
                        actions(f)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .task(id: f.id) { await loadConversation(f) }
            } else {
                ContentUnavailableView {
                    Label("No flow selected", systemImage: "point.3.filled.connected.trianglepath.dotted")
                } description: {
                    Text("Select a flow to see it in full and the conversation it is part of.")
                }
            }
        }
        .frame(minWidth: 340)
        .background(Color.raised)
    }

    private func header(_ f: FlowRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Flow").font(.title3.weight(.semibold))
                Spacer()
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(FlowStyle.family(f.proto).color).frame(width: 8, height: 8)
                    Text(f.protoName).font(.callout.weight(.medium))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                endpoint(f.source, f.sourcePort, role: "From")
                endpoint(f.destination, f.destinationPort, role: "To")
            }
        }
    }

    private func endpoint(_ addr: String, _ port: Int?, role: String) -> some View {
        HStack(spacing: 8) {
            Text(role).font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            Text(FlowRecord.endpoint(addr, port)).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Spacer(minLength: 0)
            Button { store.flowFilter = FlowFilter(host: addr) } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                .buttonStyle(.borderless)
                .help("Show only flows to or from \(addr)")
        }
    }

    private func facts(_ f: FlowRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let s = f.start {
                row("Started", FlowStyle.full(Date(timeIntervalSince1970: s)))
                if let e = f.end, e > s { row("Ended", FlowStyle.full(Date(timeIntervalSince1970: e))) }
            }
            row("Duration", f.duration.map(Format.duration) ?? "–")
            row("Bytes", "\(Format.bytes(f.bytes)) (\(f.bytes.grouped))")
            row("Packets", f.packets.grouped)
            if f.packets > 0 { row("Average packet", Format.bytes(f.bytes / f.packets)) }
            if let d = f.duration, d > 0 { row("Rate", Format.rate(Double(f.bytes) / d)) }
            if !f.tcpFlags.isEmpty { row("TCP flags", "\(FlowsView.flags(f.tcpFlags))  \(f.tcpFlags)", mono: true) }
            if f.inputInterface != nil || f.outputInterface != nil {
                row("Interfaces", "in \(f.inputInterface.map(String.init) ?? "–") → out \(f.outputInterface.map(String.init) ?? "–")")
            }
            if f.sourceAS != nil || f.destinationAS != nil {
                row("AS", "\(f.sourceAS.map { String($0) } ?? "–") → \(f.destinationAS.map { String($0) } ?? "–")")
            }
            row("Exporter", f.exporter.isEmpty ? "Not in the file" : f.exporter)
            row("Format", f.version)
            if f.frame > 0 { row("Export packet", "#\(f.frame)") }
        }
        .font(.callout)
    }

    /// Label and value; the value wraps rather than pushing the panel wider than the inspector.
    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 104, alignment: .trailing)
            Text(verbatim: value).font(mono ? .callout.monospaced() : .callout).monospacedDigit().textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func conversationSection(_ f: FlowRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Conversation").font(.headline)
            Text("Every flow between \(f.source) and \(f.destination), both directions.")
                .font(.caption).foregroundStyle(.secondary)
            if let c = conversation {
                VStack(alignment: .leading, spacing: 7) {
                    row("Flows", c.flows.grouped)
                    row("Bytes", Format.bytes(c.bytes))
                    row("Packets", c.packets.grouped)
                    if let a = c.first, let b = c.last {
                        row("First", FlowStyle.full(Date(timeIntervalSince1970: a)))
                        row("Last", FlowStyle.full(Date(timeIntervalSince1970: b)))
                    }
                    if !c.ports.isEmpty {
                        row("Ports", c.ports.prefix(8).map(String.init).joined(separator: ", ") + (c.ports.count > 8 ? " and \(c.ports.count - 8) more" : ""))
                    }
                }
                .font(.callout)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func actions(_ f: FlowRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Narrow the table").font(.headline)
            Button { store.flowFilter = FlowFilter(pair: [f.source, f.destination]) } label: {
                Label("This conversation", systemImage: "arrow.left.arrow.right")
            }
            Button { store.flowFilter = FlowFilter(host: f.source) } label: { Label("Everything from or to \(f.source)", systemImage: "arrow.up.right") }
            Button { store.flowFilter = FlowFilter(host: f.destination) } label: { Label("Everything from or to \(f.destination)", systemImage: "arrow.down.left") }
            if let p = f.servicePort {
                Button { store.flowFilter = FlowFilter(port: p, proto: f.proto) } label: { Label("All \(f.protoName) \(p) traffic", systemImage: "number") }
            }
            Divider().padding(.vertical, 4)
            Button { copyText(FlowFilter(pair: [f.source, f.destination], port: f.servicePort, proto: f.proto).nfdump) } label: {
                Label("Copy nfdump Filter", systemImage: "doc.on.doc")
            }
            .help("For nfdump -r … '\(FlowFilter(pair: [f.source, f.destination], port: f.servicePort, proto: f.proto).nfdump)'")
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private func loadConversation(_ f: FlowRecord) async {
        conversation = nil
        let all = store.flowRecords, pair = FlowFilter(pair: [f.source, f.destination])
        let result = await Task.detached(priority: .userInitiated) { () -> Conversation in
            var flows = 0, bytes = 0, packets = 0, first = Double.infinity, last = -Double.infinity
            var ports: Set<Int> = []
            for r in all where pair.matches(r) {
                flows += 1; bytes += r.bytes; packets += r.packets
                if let s = r.start { first = min(first, s); last = max(last, r.end ?? s) }
                if let p = r.servicePort { ports.insert(p) }
            }
            return Conversation(flows: flows, bytes: bytes, packets: packets,
                                first: first.isFinite ? first : nil, last: last.isFinite ? last : nil, ports: ports.sorted())
        }.value
        if !Task.isCancelled { conversation = result }
    }
}
