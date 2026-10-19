import Charts
import KagamiCore
import SwiftUI

/// The capture at a glance. Follows the current filters; every mark filters the packet list on click.
struct OverviewView: View {
    @Environment(CaptureStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var stats: CaptureStats?
    @State private var hoverTime: Double?

    var body: some View {
        Group {
            if let stats, stats.packets > 0 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 34) {
                        HStack(alignment: .firstTextBaseline) {
                            Facts(stats: stats)
                            Spacer()
                            Button { if let id = store.windowID { openWindow(value: EndpointsRequest(store: id)) } } label: {
                                Label("Endpoints…", systemImage: "person.2.wave.2")
                            }
                            .buttonStyle(.glass)
                            .help("Traffic per app, host, address and port (⌥⌘E)")
                        }
                        Throughput(stats: stats, hoverTime: $hoverTime)
                        HStack(alignment: .top, spacing: 40) {
                            ProtocolBars(stats: stats).frame(maxWidth: .infinity)
                            Health(stats: stats).frame(maxWidth: .infinity)
                        }
                        HStack(alignment: .top, spacing: 40) {
                            Ranking(title: "Hosts", subtitle: "by bytes", items: Array(stats.hosts.prefix(8)), value: \.bytes, format: Format.bytes) { store.hostFilter = $0; store.mode = .packets }
                                .frame(maxWidth: .infinity)
                            Ranking(title: "Service ports", subtitle: "by packets", items: Array(stats.ports.prefix(8)), value: \.packets, format: { $0.grouped }) { name in
                                let parts = name.split(separator: " ")
                                if parts.count == 2 { store.applyAsFilter("\(parts[0].lowercased()).port == \(parts[1])") }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 1180)
                    .frame(maxWidth: .infinity)
                }
            } else if stats == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Nothing to chart", systemImage: "chart.bar", description: Text("No packets pass the current filters."))
            }
        }
        .task(id: StatsKey(count: store.visible.count, last: store.visible.last?.number ?? 0, first: store.visible.first?.number ?? 0)) {
            let packets = store.visible
            let job = Task.detached(priority: .userInitiated) { CaptureStats(packets) }
            let s = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard !Task.isCancelled else { return }  // a newer capture state already started its own
            withAnimation(.easeOut(duration: 0.2)) { stats = s }
        }
    }

    struct StatsKey: Hashable { let count: Int; let last: Int; let first: Int }
}

// MARK: Facts

private struct Facts: View {
    let stats: CaptureStats

    var body: some View {
        let parts: [(String, String)] = [
            (stats.packets.grouped, "packets"),
            (Format.bytes(stats.bytes), "on the wire"),
            (Format.duration(stats.duration), "captured"),
            (stats.duration > 0 ? Format.rate(Double(stats.bytes) / stats.duration) : "–", "on average"),
            (stats.conversations.grouped, stats.conversations == 1 ? "conversation" : "conversations"),
        ]
        // Each fact holds together (no-break spaces); lines break only after a separator dot.
        let nb = { (s: String) in s.replacingOccurrences(of: " ", with: "\u{00A0}") }
        var line = AttributedString()
        for (i, p) in parts.enumerated() {
            var v = AttributedString(nb(p.0))
            v.font = .title3.weight(.semibold).monospacedDigit()
            var l = AttributedString(nb(" " + p.1) + (i < parts.count - 1 ? "\u{00A0}\u{00A0}·   " : ""))
            l.font = .title3
            l.foregroundColor = .secondary
            line += v + l
        }
        return Text(line).textSelection(.enabled)
    }
}

// MARK: Throughput

private struct Throughput: View {
    @Environment(CaptureStore.self) private var store
    let stats: CaptureStats
    @Binding var hoverTime: Double?
    @State private var hoverX: CGFloat = 0

    var body: some View {
        let families = ProtoFamily.stackOrder.filter { f in stats.families.contains { $0.family == f } }
        let series = filled(families)
        VStack(alignment: .leading, spacing: 12) {
            ChartTitle(title: "Throughput", subtitle: "bytes per second in \(Format.duration(stats.bucketSize)) steps, stacked by protocol")
            Chart(series) { b in
                AreaMark(x: .value("Time", b.start), y: .value("Bytes/s", Double(b.bytes) / stats.bucketSize), stacking: .standard)
                    .foregroundStyle(by: .value("Protocol", b.family.title))
                    .interpolationMethod(.stepStart)  // each bucket is a span of time, drawn as one
                if let t = hoverTime {
                    RuleMark(x: .value("Time", t))
                        .foregroundStyle(Color.primary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartForegroundStyleScale(domain: families.map(\.title), range: families.map(\.color))
            .chartXScale(domain: 0...max(stats.duration, stats.bucketSize))  // the axis runs to the end of the capture
            .chartLegend(position: .top, alignment: .leading, spacing: 10)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8)) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel { if let s = v.as(Double.self) { Text(Format.axisTime(s, span: stats.duration)) } }
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel { if let n = v.as(Double.self) { Text(Format.rate(n)) } }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { g in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            guard case .active(let p) = phase, let plot = proxy.plotFrame else { hoverTime = nil; return }
                            let x = p.x - g[plot].origin.x
                            if let t: Double = proxy.value(atX: x), t >= 0, t <= stats.duration + stats.bucketSize {
                                hoverTime = (t / stats.bucketSize).rounded(.down) * stats.bucketSize
                                // The card rides beside the cursor line, flipping sides near the right edge.
                                hoverX = p.x + 14 + 190 > g.size.width ? p.x - 14 - 190 : p.x + 14
                            } else { hoverTime = nil }
                        }
                }
            }
            .overlay(alignment: .topLeading) {
                if let t = hoverTime {
                    Tooltip(time: t, stats: stats, families: families)
                        .offset(x: hoverX, y: 8)
                        .animation(.snappy(duration: 0.12), value: hoverX)
                }
            }
            .frame(height: 230)
            .accessibilityLabel("Throughput over time by protocol")
        }
    }

    /// Every family gets a value in every bucket, empty ones included: quiet stretches drop to zero
    /// instead of being bridged by an invented line.
    private func filled(_ families: [ProtoFamily]) -> [CaptureStats.Bucket] {
        let byKey = Dictionary(grouping: stats.timeline, by: \.start)
        let last = Int(((byKey.keys.max() ?? 0) / stats.bucketSize).rounded())
        return (0...max(0, last)).flatMap { i -> [CaptureStats.Bucket] in
            let t = Double(i) * stats.bucketSize
            let key = byKey.keys.first { abs($0 - t) < stats.bucketSize / 4 }
            return families.map { f in key.flatMap { k in byKey[k]?.first { $0.family == f } }
                ?? CaptureStats.Bucket(start: t, family: f, bytes: 0, packets: 0) }
        }
    }
}

private struct Tooltip: View {
    let time: Double
    let stats: CaptureStats
    let families: [ProtoFamily]

    var body: some View {
        let rows = families.compactMap { f -> (ProtoFamily, Int)? in
            let b = stats.timeline.first { abs($0.start - time) < stats.bucketSize / 4 && $0.family == f }
            return b.map { (f, $0.bytes) }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("at \(Format.axisTime(time, span: stats.duration))").font(.caption.weight(.semibold))
            if rows.isEmpty { Text("no traffic").font(.caption).foregroundStyle(.secondary) }
            ForEach(rows, id: \.0) { f, bytes in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(f.color).frame(width: 8, height: 8)
                    Text(f.title).font(.caption)
                    Spacer(minLength: 12)
                    Text(Format.rate(Double(bytes) / stats.bucketSize)).font(.caption.monospacedDigit())
                }
            }
        }
        .padding(10)
        .frame(width: 190)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .allowsHitTesting(false)
    }
}

// MARK: Protocols

private struct ProtocolBars: View {
    @Environment(CaptureStore.self) private var store
    let stats: CaptureStats

    var body: some View {
        let items = stats.families.sorted { $0.bytes > $1.bytes }
        let top = Double(items.first?.bytes ?? 1)
        VStack(alignment: .leading, spacing: 12) {
            ChartTitle(title: "Protocols", subtitle: "share of bytes")
            VStack(spacing: 8) {
                ForEach(items) { item in
                    Button { store.protocolFilter = [item.family]; store.mode = .packets } label: {
                        HStack(spacing: 10) {
                            Text(item.family.title).frame(width: 56, alignment: .leading)
                            GeometryReader { g in
                                HStack(spacing: 8) {
                                    UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4)
                                        .fill(item.family.color)
                                        .frame(width: max(3, (g.size.width - 120) * Double(item.bytes) / top), height: 18)
                                    Text("\(Format.bytes(item.bytes)) · \(percent(item.bytes))")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .fixedSize()
                                }
                                .frame(maxHeight: .infinity)
                            }
                            .frame(height: 22)
                        }
                        .font(.callout)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show only \(item.family.title)")
                    .accessibilityLabel("\(item.family.title), \(Format.bytes(item.bytes)), \(percent(item.bytes))")
                }
            }
        }
    }

    private func percent(_ v: Int) -> String {
        stats.bytes == 0 ? "0%" : String(format: "%.0f%%", Double(v) / Double(stats.bytes) * 100)
    }
}

// MARK: Health

private struct Health: View {
    @Environment(CaptureStore.self) private var store
    let stats: CaptureStats

    var body: some View {
        let found = stats.issues.filter { $0.count > 0 }
        VStack(alignment: .leading, spacing: 12) {
            ChartTitle(title: "TCP health", subtitle: "Wireshark's analysis flags")
            if found.isEmpty {
                Label("No retransmissions, resets or lost segments.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
            VStack(spacing: 2) {
                ForEach(stats.issues) { issue in
                    Button { store.applyAsFilter(issue.filter) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: issue.count == 0 ? "checkmark.circle" : (issue.issue.isSevere ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"))
                                .foregroundStyle(issue.count == 0 ? Color.secondary : (issue.issue.isSevere ? .red : .orange))
                                .frame(width: 18)
                            Text(issue.label).foregroundStyle(issue.count == 0 ? .secondary : .primary)
                            Spacer()
                            Text(issue.count.grouped).monospacedDigit().foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                                .opacity(issue.count == 0 ? 0 : 1)
                        }
                        .font(.callout)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(issue.count > 0)
                    .help(issue.count == 0 ? "" : "Show these packets")
                }
            }
        }
    }
}

// MARK: Ranking

private struct Ranking: View {
    let title: String
    let subtitle: String
    let items: [CaptureStats.Ranked]
    let value: KeyPath<CaptureStats.Ranked, Int>
    let format: (Int) -> String
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChartTitle(title: title, subtitle: subtitle)
            if items.isEmpty {
                Text("None in this capture.").font(.callout).foregroundStyle(.secondary)
            }
            let top = Double(items.first?[keyPath: value] ?? 1)
            VStack(spacing: 6) {
                ForEach(items) { item in
                    Button { onPick(item.name) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(item.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(format(item[keyPath: value])).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            GeometryReader { g in
                                UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3)
                                    .fill(Color.secondary.opacity(0.45))  // data, not an action: neutral
                                    .frame(width: max(2, g.size.width * Double(item[keyPath: value]) / top))
                            }
                            .frame(height: 6)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Filter to \(item.name)")
                }
            }
        }
    }
}

private struct ChartTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.headline)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }
}
