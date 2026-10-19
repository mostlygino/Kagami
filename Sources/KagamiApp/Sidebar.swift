import KagamiCore
import SwiftUI

/// Narrow the capture without writing a filter: by protocol, by host name, by app.
struct Sidebar: View {
    @Environment(CaptureStore.self) private var store
    @State private var showAllHosts = false

    var body: some View {
        List {
            if store.source != .none {
                Section(store.isFlowFile ? "File" : "Capture") { SourceRow() }
            }
            if store.mode == .flows {
                FlowFacetSections()
            } else {
            if store.source != .none && !store.isFlowFile {
                Section("Quick Filters") {
                    ForEach(CaptureStore.quickFilters) { q in
                        SidebarToggle(isOn: store.appliedFilter == q.filter, count: nil) {
                            if store.appliedFilter == q.filter { store.clearFilter() } else { store.applyAsFilter(q.filter) }
                        } label: {
                            Label(q.title, systemImage: q.symbol)
                        }
                        .help(q.filter)
                    }
                }
            }
            let markCounts = store.markCounts
            if !markCounts.isEmpty {
                Section {
                    ForEach(CaptureStore.MarkFilter.allCases) { m in
                        if let n = markCounts[m] {
                            SidebarToggle(isOn: store.markFilter == m, count: n) {
                                store.markFilter = store.markFilter == m ? nil : m
                            } label: {
                                Label(m.rawValue, systemImage: m.symbol)
                            }
                        }
                    }
                } header: {
                    SectionHeader(title: "Your Marks", clear: store.markFilter == nil ? nil : { store.markFilter = nil })
                }
            }
            if !store.families.isEmpty {
                Section {
                    ForEach(store.families, id: \.family) { item in
                        SidebarToggle(isOn: store.protocolFilter.contains(item.family), count: item.count) {
                            if store.protocolFilter.contains(item.family) { store.protocolFilter.remove(item.family) }
                            else { store.protocolFilter.insert(item.family) }
                        } label: {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(item.family.color).frame(width: 10, height: 10)
                                Text(item.family.title)
                            }
                        }
                    }
                } header: {
                    SectionHeader(title: "Protocols", clear: store.protocolFilter.isEmpty ? nil : { store.protocolFilter = [] })
                }
            }
            if !store.hosts.isEmpty {
                Section {
                    ForEach(store.hosts.prefix(showAllHosts ? 200 : 12), id: \.name) { item in
                        SidebarToggle(isOn: store.hostFilter == item.name, count: item.count) {
                            store.hostFilter = store.hostFilter == item.name ? nil : item.name
                        } label: {
                            Label(item.name, systemImage: "globe").lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if store.hosts.count > 12 {
                        Button(showAllHosts ? "Show Fewer" : "Show All \(store.hosts.count)") { withAnimation(.easeOut(duration: 0.2)) { showAllHosts.toggle() } }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.kagami)
                            .font(.callout)
                    }
                } header: {
                    SectionHeader(title: "Hosts", clear: store.hostFilter == nil ? nil : { store.hostFilter = nil })
                }
            }
            if !store.apps.isEmpty || store.isCapturing {
                Section {
                    ForEach(store.apps, id: \.name) { item in
                        SidebarToggle(isOn: store.appFilter == item.name, count: item.count) {
                            store.appFilter = store.appFilter == item.name ? nil : item.name
                        } label: {
                            Label(item.name, systemImage: "app.dashed").lineLimit(1)
                        }
                    }
                    if store.apps.isEmpty {
                        Text("Apps appear as they open connections.").font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    SectionHeader(title: "Apps", clear: store.appFilter == nil ? nil : { store.appFilter = nil })
                } footer: {
                    Text("Your own apps only. System services need a root capture.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            }
        }
        .listStyle(.sidebar)
        .animation(.smooth(duration: 0.3), value: store.families.map(\.family))
        .animation(.smooth(duration: 0.3), value: store.hosts.map(\.name))
        .animation(.smooth(duration: 0.3), value: store.apps.map(\.name))
        .overlay {
            if store.source == .none {
                Text("Protocols, hosts and apps appear here once packets arrive.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    let clear: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let clear {
                Button("Clear", action: clear)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.kagami)
            }
        }
    }
}

struct SidebarToggle<L: View>: View {
    let isOn: Bool
    let count: Int?
    let action: () -> Void
    @ViewBuilder let label: L

    var body: some View {
        Button(action: action) {
            HStack {
                label
                Spacer(minLength: 6)
                if let count {
                    Text(count.grouped)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: Double(count)))
                        .animation(.snappy(duration: 0.3), value: count)
                }
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.kagami)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isOn ? RoundedRectangle(cornerRadius: 6).fill(Color.kagami.opacity(0.16)).padding(.horizontal, 8) : nil)
        .animation(.easeOut(duration: 0.15), value: isOn)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct SourceRow: View {
    @Environment(CaptureStore.self) private var store

    var body: some View {
        // The caption lines sit in the label's title, so they align with the name, not the icon.
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if case .live = store.source {
                    Text(store.isCapturing ? "Recording" : "Recorded capture")
                        .font(.caption)
                        .foregroundStyle(store.isCapturing ? .red : .secondary)
                } else if store.isFlowFile {
                    Text("Flow records").font(.caption).foregroundStyle(.secondary)
                }
                if let url = store.documentURL, !store.isCapturing {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.kagami)
                }
            }
        } icon: {
            Image(systemName: symbol)
        }
        .padding(.vertical, 2)
    }

    private var name: String {
        if case .live(let iface, _) = store.source { return store.interfaces.first { $0.name == iface }?.friendlyName ?? iface }
        return store.documentURL?.lastPathComponent ?? ""
    }

    private var symbol: String {
        if case .live(let iface, _) = store.source { return InterfaceIcon.symbol(iface) }
        return store.isFlowFile ? "point.3.filled.connected.trianglepath.dotted" : "doc"
    }
}
