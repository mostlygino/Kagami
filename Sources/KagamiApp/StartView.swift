import AppKit
import KagamiCore
import SwiftUI

/// First screen: every interface with its traffic right now, ready to record; or a file to open.
struct StartView: View {
    @Environment(CaptureStore.self) private var store
    @State private var activity = InterfaceActivity()
    @State private var hovered: String?
    @State private var recents: [URL] = []
    @State private var showAll = false
    @State private var viewport: CGFloat = 0

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(alignment: .center, spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Kagami").font(.largeTitle.weight(.semibold))
                        Text("Record an interface, or open a capture or flow file. Everything stays on this Mac.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 36) {
                        interfacesColumn.frame(minWidth: 460, idealWidth: 620, maxWidth: 620)
                        openColumn.frame(width: 300)
                    }
                    VStack(alignment: .leading, spacing: 32) {
                        interfacesColumn
                        openColumn
                    }
                }
            }
            .padding(40)
            .frame(maxWidth: 1040, alignment: .leading)
            // Optically centred in a tall window (a little above the middle); scrolls when it does not fit.
            .padding(.bottom, viewport * 0.08)
            .frame(maxWidth: .infinity, minHeight: viewport)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, h in viewport = h }
        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        .task { recents = NSDocumentController.shared.recentDocumentURLs.filter { FileManager.default.fileExists(atPath: $0.path) } }
        .task { await activity.run() }
    }

    private var interfacesColumn: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Interfaces").font(.headline)
                            Spacer()
                            Text("traffic right now").font(.caption).foregroundStyle(.tertiary)
                        }
                        VStack(spacing: 2) {
                            ForEach(sortedInterfaces) { i in
                                InterfaceRow(interface: i, history: activity.history[i.name] ?? [], rate: activity.rate[i.name] ?? 0,
                                             isChosen: store.interface == i.name, isHovered: hovered == i.name)
                                    .onHover { hovered = $0 ? i.name : (hovered == i.name ? nil : hovered) }
                                    .onTapGesture(count: 2) { store.interface = i.name; store.start() }
                                    .onTapGesture { store.interface = i.name }
                            }
                            if store.interfaces.isEmpty {
                                ProgressView().controlSize(.small).padding()
                            }
                            let hidden = store.interfaces.filter { !isUseful($0) }.count
                            if hidden > 0 || showAll {
                                Button(showAll ? "Show active interfaces only" : "Show \(hidden) quiet interface\(hidden == 1 ? "" : "s")") {
                                    withAnimation(.easeOut(duration: 0.2)) { showAll.toggle() }
                                }
                                .buttonStyle(.plain)
                                .font(.callout)
                                .foregroundStyle(Color.kagami)
                                .padding(.horizontal, 12)
                                .padding(.top, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                            TextField("Capture filter", text: $store.captureFilter, prompt: Text("Capture filter (BPF), optional: e.g. tcp port 443"))
                                .textFieldStyle(.plain)
                                .font(.callout.monospaced())
                                .onSubmit { store.start() }
                            Button { store.start() } label: {
                                Label("Record", systemImage: "record.circle")
                            }
                            .buttonStyle(.glassProminent)
                            .tint(.red)
                            .controlSize(.large)
                        }
                        .padding(.leading, 12)
                        .padding(.vertical, 6)
                        .padding(.trailing, 6)
                        .glassEffect(.regular, in: .capsule)
                        Button { store.startFlowCollector() } label: {
                            Label("Listen for NetFlow, IPFIX and sFlow exports on \(store.interfaces.first { $0.name == store.interface }?.friendlyName ?? store.interface)", systemImage: "point.3.filled.connected.trianglepath.dotted")
                        }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(Color.kagami)
                        .padding(.leading, 12)
                        .help("Records UDP 2055, 4739, 9995, 9996 and 6343 and shows the exported flows")
                    }
    }

    private var openColumn: some View {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Open a file").font(.headline)
                        Button { store.openPanel() } label: {
                            VStack(spacing: 10) {
                                Image(systemName: "arrow.down.doc")
                                    .font(.system(size: 28, weight: .light))
                                    .foregroundStyle(Color.kagami)
                                Text("Drop a capture or flow export here")
                                    .font(.callout.weight(.medium))
                                Text("pcap, pcapng and every format Wireshark reads; nfdump, CSV, JSON and Zeek conn.log flows")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 18)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("or click to choose one").font(.caption).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .background {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut("o")

                        if !recents.isEmpty {
                            Text("Recent").font(.subheadline.weight(.semibold)).padding(.top, 6)
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(recents.prefix(6), id: \.self) { url in
                                    Button { store.open(url) } label: {
                                        HStack {
                                            Image(systemName: "doc").foregroundStyle(.secondary)
                                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                            Spacer()
                                        }
                                        .padding(.vertical, 5)
                                        .padding(.horizontal, 8)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help(url.path)
                                }
                            }
                        }
                    }
    }

    /// A fixed order, so rows never jump while traffic changes: the main interface, other Ethernet
    /// and Wi-Fi, then virtual ones, loopback last.
    private var sortedInterfaces: [NetInterface] {
        func rank(_ name: String) -> Int { name == "en0" ? 0 : name.hasPrefix("en") ? 1 : name.hasPrefix("lo") ? 3 : 2 }
        return store.interfaces.sorted {
            let a = rank($0.name), b = rank($1.name)
            return a != b ? a < b : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        .filter { showAll || isUseful($0) }
    }

    private func isUseful(_ i: NetInterface) -> Bool {
        (activity.total[i.name] ?? 0) > 0 || i.name == store.interface || i.name == "en0" || i.name.hasPrefix("lo")
    }
}

private struct InterfaceRow: View {
    let interface: NetInterface
    let history: [Double]
    let rate: Double
    let isChosen: Bool
    let isHovered: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: InterfaceIcon.symbol(interface.name))
                .font(.system(size: 15))
                .foregroundStyle(isChosen ? Color.bronze : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(interface.friendlyName).font(.body.weight(isChosen ? .semibold : .regular))
                Text(interface.name).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .frame(width: 170, alignment: .leading)
            Sparkline(values: history)
                .stroke(Color.kagami, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .background(alignment: .bottom) { Sparkline(values: history, closed: true).fill(Color.kagami.opacity(0.10)) }
                .frame(minWidth: 120, idealWidth: 220, maxWidth: .infinity, minHeight: 26, maxHeight: 26)
                .accessibilityHidden(true)
            Text(rate > 0 ? Format.rate(rate) : "quiet")
                .font(.caption.monospacedDigit())
                .foregroundStyle(rate > 0 ? .primary : .tertiary)
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isChosen ? Color.bronze.opacity(0.14) : (isHovered ? Color.primary.opacity(0.05) : .clear))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(interface.friendlyName), \(interface.name), \(rate > 0 ? Format.rate(rate) : "quiet")")
        .accessibilityAddTraits(isChosen ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint("Double-click to start recording")
    }
}

struct Sparkline: Shape {
    let values: [Double]
    var closed = false

    /// Only the seconds measured so far, growing in from the right: no invented flat line before Kagami was watching.
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let n = InterfaceActivity.samples
        let values = Array(self.values.suffix(n))
        guard values.count >= 2 else { return p }
        let top = max(values.max() ?? 1, 1)
        let step = rect.width / CGFloat(n - 1)
        let first = n - values.count
        func pt(_ i: Int) -> CGPoint {
            CGPoint(x: rect.minX + CGFloat(first + i) * step, y: rect.maxY - 1 - CGFloat(values[i] / top) * (rect.height - 2))
        }
        p.move(to: pt(0))
        for i in 1..<values.count { p.addLine(to: pt(i)) }
        if closed {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: pt(0).x, y: rect.maxY))
            p.closeSubpath()
        }
        return p
    }
}

/// Polls interface byte counters once a second while the start screen is up.
@Observable @MainActor
final class InterfaceActivity {
    nonisolated static let samples = 40
    var history: [String: [Double]] = [:]
    var rate: [String: Double] = [:]
    var total: [String: Double] = [:]

    func run() async {
        var last = InterfaceCounters.snapshot()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let now = InterfaceCounters.snapshot()
            for (name, bytes) in now {
                let delta = Double(bytes &- (last[name] ?? bytes))
                let v = delta < 0 || delta > 1e11 ? 0 : delta
                var h = history[name] ?? []
                h.append(v)
                if h.count > Self.samples { h.removeFirst(h.count - Self.samples) }
                withAnimation(.easeOut(duration: 0.3)) { history[name] = h }
                rate[name] = v
                total[name] = h.reduce(0, +)
            }
            last = now
        }
    }
}
