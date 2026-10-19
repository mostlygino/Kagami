import AppKit
import KagamiCore
import SwiftUI

/// Two packets field by field or byte by byte, side by side or unified.
struct DiffView: View {
    @Environment(CaptureStore.self) private var store
    @State var request: DiffRequest

    enum Source: String, CaseIterable, Identifiable { case fields = "Fields", bytes = "Bytes"; var id: Self { self } }
    enum Layout: String, CaseIterable, Identifiable { case sideBySide = "Side by Side", unified = "Unified"; var id: Self { self } }

    @State private var source = Source.fields
    @State private var layout = Layout.sideBySide
    @State private var onlyChanges = false
    /// The Frame block (arrival times, frame number) differs between any two packets; it hides by default.
    @AppStorage("diffShowsFrame") private var showFrame = false
    @State private var left: FrameDetail?
    @State private var right: FrameDetail?
    @State private var error: String?
    /// The difference the arrows last moved to (a row id).
    @State private var focus: Int?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.fileURL?.path != request.path {
                ContentUnavailableView("That capture is closed", systemImage: "doc.questionmark",
                                       description: Text("These packets belong to \(URL(fileURLWithPath: request.path).lastPathComponent). Open it again to compare them."))
            } else if let error {
                ContentUnavailableView("Could not compare", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if left == nil || right == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                rowsView
            }
        }
        .navigationTitle("Packets \(request.left) and \(request.right)")
        .navigationSubtitle(store.title)
        .toolbar {
            ToolbarItemGroup {
                Button { step(-1) } label: { Label("Previous Difference", systemImage: "chevron.up") }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .help("Previous difference (⌥⌘↑)")
                    .disabled(hunks.isEmpty)
                Button { step(1) } label: { Label("Next Difference", systemImage: "chevron.down") }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .help("Next difference (⌥⌘↓)")
                    .disabled(hunks.isEmpty)
            }
            ToolbarItem { Picker("Compare", selection: $source) { ForEach(Source.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).tint(nil).fixedSize() }
            ToolbarItem { Picker("Layout", selection: $layout) { ForEach(Layout.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).tint(nil).fixedSize() }
            ToolbarItem {
                Toggle(isOn: $showFrame) {
                    Label("Frame Info", systemImage: showFrame ? "clock.fill" : "clock")
                        .foregroundStyle(showFrame ? Color.kagami : Color.primary)
                }
                .toggleStyle(.button)
                .help(showFrame ? "Hide the Frame block: arrival times and frame numbers always differ" : "Show the Frame block (arrival times, frame number)")
                .disabled(source == .bytes)
            }
            ToolbarItem {
                Toggle(isOn: $onlyChanges) {
                    Label("Only Differences", systemImage: onlyChanges ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(onlyChanges ? Color.kagami : Color.primary)
                }
                .toggleStyle(.button)
                .help(onlyChanges ? "Showing only lines that differ" : "Show only lines that differ")
            }
            ToolbarItem {
                Button { request = DiffRequest(path: request.path, left: request.right, right: request.left, store: request.store) } label: { Label("Swap", systemImage: "arrow.left.arrow.right") }
                    .help("Swap left and right")
            }
        }
        .task(id: request) {
            do {
                async let l = store.detail(for: request.left)
                async let r = store.detail(for: request.right)
                (left, right) = (try await l, try await r)
            } catch { self.error = error.localizedDescription }
        }
    }

    private var lines: ([String], [String]) {
        switch source {
        case .fields: (LineDiff.lines(tree(left)), LineDiff.lines(tree(right)))
        case .bytes: (LineDiff.hexLines(left?.bytes ?? Data()), LineDiff.hexLines(right?.bytes ?? Data()))
        }
    }

    private func tree(_ d: FrameDetail?) -> [FieldNode] {
        let t = d?.tree ?? []
        return showFrame ? t : t.filter { $0.field != "frame" }
    }

    private var allRows: [LineDiff.Row] {
        let (a, b) = lines
        return layout == .sideBySide ? LineDiff.sideBySide(a, b) : LineDiff.unified(a, b)
    }

    private var rows: [LineDiff.Row] { onlyChanges ? allRows.filter { $0.kind != .same } : allRows }

    /// The first row of each run of changed rows, over every row so runs stay apart with Only Differences on.
    private var hunks: [Int] {
        var starts: [Int] = [], previous = LineDiff.Kind.same
        for row in allRows {
            if row.kind != .same && previous == .same { starts.append(row.id) }
            previous = row.kind
        }
        return starts
    }

    private func step(_ direction: Int) {
        let h = hunks
        guard !h.isEmpty else { return }
        if let focus {
            focusTo(direction > 0 ? (h.first { $0 > focus } ?? h.first!) : (h.last { $0 < focus } ?? h.last!))
        } else {
            focusTo(direction > 0 ? h.first! : h.last!)
        }
    }

    private func focusTo(_ id: Int) { focus = id }

    private var header: some View {
        let (a, b) = lines
        let changed = LineDiff.sideBySide(a, b).filter { $0.kind != .same }.count
        return HStack(spacing: 0) {
            PacketBadge(number: request.left, side: "Left").frame(maxWidth: .infinity, alignment: .leading)
            Text(changed == 0 ? "Identical" : "\(changed) line\(changed == 1 ? "" : "s") differ")
                .font(.callout.weight(.medium))
                .foregroundStyle(changed == 0 ? Color.secondary : Color.primary)
            PacketBadge(number: request.right, side: "Right").frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder private var rowsView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        Group {
                            if layout == .sideBySide {
                                HStack(alignment: .top, spacing: 0) {
                                    DiffCell(text: row.left, kind: row.kind == .added ? nil : row.kind, sign: row.kind == .same ? " " : "−", other: row.kind == .changed ? row.right : nil)
                                    Divider()
                                    DiffCell(text: row.right, kind: row.kind == .removed ? nil : (row.kind == .changed ? .changed : row.kind), sign: row.kind == .same ? " " : "+", other: row.kind == .changed ? row.left : nil)
                                }
                            } else {
                                DiffCell(text: row.left ?? row.right, kind: row.kind, sign: row.kind == .removed ? "−" : (row.kind == .added ? "+" : " "))
                            }
                        }
                        .overlay(alignment: .leading) {
                            if row.id == focus { Rectangle().fill(Color.bronze).frame(width: 3) }
                        }
                        .id(row.id)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.vertical, 6)
            }
            .onChange(of: focus) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

private struct PacketBadge: View {
    @Environment(CaptureStore.self) private var store
    let number: Int
    let side: String

    var body: some View {
        if let p = store.packet(number) {
            VStack(alignment: side == "Left" ? .leading : .trailing, spacing: 2) {
                HStack(spacing: 8) {
                    Text("\(side) · Packet \(number)").font(.callout.weight(.semibold))
                    ProtoChip(proto: p.proto, family: ProtoFamily.of(p)).font(.caption)
                }
                Text("\(p.source) → \(p.destination)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct DiffCell: View {
    let text: String?
    let kind: LineDiff.Kind?
    let sign: String
    var other: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text == nil ? " " : sign)
                .foregroundStyle(.secondary)
                .frame(width: 10)
            // Lines wrap, never truncate; a wrapped line hangs under its own text, past the tree indent.
            Text(highlighted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Double(indent) * Self.charWidth)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        .background(background)
        .textSelection(.enabled)
    }

    static let charWidth = ("0" as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]).width

    private var indent: Int { text?.prefix { $0 == " " }.count ?? 0 }

    /// The changed characters of a changed line, from the first difference to the last.
    private var highlighted: AttributedString {
        var a = AttributedString(text.map { String($0.dropFirst(indent)) } ?? "")
        guard let t = text.map({ String($0.dropFirst(indent)) }), let o = other.map({ String($0.drop { $0 == " " }) }) else { return a }
        let x = Array(t), y = Array(o)
        var p = 0
        while p < x.count && p < y.count && x[p] == y[p] { p += 1 }
        var s = 0
        while s < x.count - p && s < y.count - p && x[x.count - 1 - s] == y[y.count - 1 - s] { s += 1 }
        guard p < x.count - s else { return a }
        let lo = a.index(a.startIndex, offsetByCharacters: p)
        let hi = a.index(a.startIndex, offsetByCharacters: x.count - s)
        a[lo..<hi].backgroundColor = Color.bronze.opacity(0.28)
        a[lo..<hi].inlinePresentationIntent = .stronglyEmphasized
        return a
    }

    private var background: Color {
        guard text != nil, let kind else { return text == nil && kind == nil ? Color.primary.opacity(0.03) : .clear }
        switch kind {
        case .same: return .clear
        case .removed: return Color.red.opacity(0.10)
        case .added: return Color.green.opacity(0.10)
        case .changed: return Color.primary.opacity(0.08)
        }
    }
}
