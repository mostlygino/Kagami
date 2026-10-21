import KagamiCore
import SwiftUI

/// Who talked, how much, and which way: per app, host, address and port, split into sent from
/// this Mac and received. Double-click a row to see its packets.
struct EndpointsView: View {
    @Environment(CaptureStore.self) private var store
    @State private var kind = Endpoint.Kind.hosts
    @State private var search = ""
    @State private var data: [Endpoint.Kind: [Endpoint]] = [:]
    @State private var selection: Set<Endpoint.ID> = []
    @State private var order = [KeyPathComparator(\Endpoint.bytes, order: .reverse)]

    private var rows: [Endpoint] {
        let all = data[kind] ?? []
        let q = search.trimmingCharacters(in: .whitespaces)
        let shown = q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.protocols.contains { $0.localizedCaseInsensitiveContains(q) } }
        return shown.sorted(using: order)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Group", selection: $kind) {
                ForEach(Endpoint.Kind.allCases) { k in Text("\(k.rawValue)  \(data[k]?.count ?? 0)").tag(k) }
            }
            .pickerStyle(.segmented).tint(nil)
            .labelsHidden()
            .padding(12)
            Table(rows, selection: $selection, sortOrder: $order) {
                TableColumn(kind == .apps ? "App" : (kind == .hosts ? "Host" : "Address"), value: \.name) { e in
                    Text(e.name).font(kind == .apps || kind == .hosts ? .body : .body.monospaced()).lineLimit(1)
                }
                .width(min: 160, ideal: 260)
                TableColumn("Packets", value: \.packets) { Text($0.packets.grouped).monospacedDigit() }.width(70).alignment(.numeric)
                TableColumn("Bytes", value: \.bytes) { Text(Format.bytes($0.bytes)).monospacedDigit() }.width(80).alignment(.numeric)
                // Sent and received only mean something when one end is this Mac; a loopback or someone else's capture hides them.
                if hasDirection {
                    TableColumn("Sent", value: \.txBytes) { (e: Endpoint) in Text(verbatim: e.directionKnown ? Format.bytes(e.txBytes) : "–").monospacedDigit() }.width(80).alignment(.numeric)
                    TableColumn("Received", value: \.rxBytes) { (e: Endpoint) in Text(verbatim: e.directionKnown ? Format.bytes(e.rxBytes) : "–").monospacedDigit() }.width(80).alignment(.numeric)
                    TableColumn("Direction") { (e: Endpoint) in DirectionCell(endpoint: e) }.width(min: 90, ideal: 120)
                }
                TableColumn("Protocols") { (e: Endpoint) in ProtocolChips(titles: e.protocols) }.width(min: 110, ideal: 180)
            }
            .alternatingRowBackgrounds(.disabled)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: Endpoint.ID.self) { ids in
                Button("Show Related Packets") { show(ids) }.disabled(ids.isEmpty)
                Divider()
                Button("Copy as CSV") { copy(ids, .csvHeader) }
                Button("Copy as JSON") { copy(ids, .json) }
                Button("Copy as Markdown") { copy(ids, .markdown) }
            } primaryAction: { ids in show(ids) }
            HStack {
                Text(hasDirection ? "Sent and received are from this Mac's point of view."
                                  : "No traffic here has exactly one end on this Mac, so sent and received are not shown.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(rows.count) of \(data[kind]?.count ?? 0)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 26)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search endpoints")
        .navigationTitle("Endpoints")
        .navigationSubtitle(store.title)
        .task(id: store.packets.count) {
            let packets = store.packets, hosts = store.streamHosts
            let job = Task.detached(priority: .userInitiated) { Endpoints.compute(packets, local: Endpoints.localAddresses(), hosts: hosts) }
            let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            if !Task.isCancelled { data = result }
        }
    }

    private var hasDirection: Bool { (data[kind] ?? []).contains(where: \.directionKnown) }

    private func show(_ ids: Set<Endpoint.ID>) {
        guard let id = ids.first, let e = data[kind]?.first(where: { $0.id == id }) else { return }
        switch e.kind {
        case .apps: store.appFilter = e.name; store.mode = .packets
        case .hosts: store.hostFilter = e.name; store.mode = .packets
        default: if let f = e.filter { store.applyAsFilter(f) }
        }
        NSApp.windows.first { $0.tabbingIdentifier == "KagamiCapture" && $0.isVisible }?.makeKeyAndOrderFront(nil)
    }

    private func copy(_ ids: Set<Endpoint.ID>, _ format: RowFormat) {
        let chosen = rows.filter { ids.contains($0.id) }
        let header = ["Endpoint", "Packets", "Bytes", "Sent packets", "Sent bytes", "Received packets", "Received bytes", "Protocols"]
        let body = chosen.map { [$0.name, String($0.packets), String($0.bytes), String($0.txPackets), String($0.txBytes),
                                 String($0.rxPackets), String($0.rxBytes), $0.protocols.sorted().joined(separator: " ")] }
        copyText(format.render(header: header, rows: body))
    }
}

/// Up to three protocol families as colour dot plus name, in the app's stack order, then "+N".
private struct ProtocolChips: View {
    let titles: Set<String>

    var body: some View {
        let families = ProtoFamily.stackOrder.filter { titles.contains($0.title) }
        // As many whole chips as fit, never a truncated name.
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: min(3, families.count), through: 1, by: -1)), id: \.self) { n in
                chips(families, n)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(families.map(\.title).joined(separator: ", "))
    }

    private func chips(_ families: [ProtoFamily], _ n: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(families.prefix(n)) { f in
                HStack(spacing: 4) {
                    Circle().fill(f.color).frame(width: 7, height: 7)
                    Text(f.title)
                }
            }
            if families.count > n {
                Text("+\(families.count - n)").foregroundStyle(.tertiary)
                    .help(families.dropFirst(n).map(\.title).joined(separator: ", "))
            }
        }
        .fixedSize()
    }
}

private struct DirectionCell: View {
    let endpoint: Endpoint
    var body: some View {
        if endpoint.directionKnown { DirectionBar(tx: endpoint.txBytes, rx: endpoint.rxBytes) }
        else { Text("–").foregroundStyle(.tertiary).help("Sent and received need exactly one end of the traffic on this Mac. Here neither end is, or both are (loopback).") }
    }
}

/// Sent against received, as one bar: tint for sent, neutral for received.
private struct DirectionBar: View {
    let tx: Int
    let rx: Int

    var body: some View {
        let total = max(1, tx + rx)
        GeometryReader { g in
            HStack(spacing: 2) {
                if tx > 0 { Capsule().fill(Color.kagami).frame(width: max(3, (g.size.width - 2) * Double(tx) / Double(total))) }
                if rx > 0 { Capsule().fill(Color.secondary.opacity(0.5)) }
            }
        }
        .frame(height: 6)
        .help("\(Int((Double(tx) / Double(total) * 100).rounded()))% sent, \(Int((Double(rx) / Double(total) * 100).rounded()))% received")
        .accessibilityLabel("\(Int((Double(tx) / Double(total) * 100).rounded())) percent sent")
    }
}
