import KagamiCore
import SwiftUI

/// Right-hand inspector: the selected packet as RFC header diagrams (Anatomy) or a field tree,
/// above its bytes. A field picked in any of the three lights up in the other two.
struct InspectorView: View {
    @Environment(CaptureStore.self) private var store
    let onCompare: ([Int]) -> Void

    var body: some View {
        @Bindable var store = store
        Group {
            if let packet = store.focusedPacket {
                VStack(spacing: 0) {
                    InspectorHeader(packet: packet)
                    Picker("View", selection: $store.inspectorTab) {
                        ForEach(CaptureStore.InspectorTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).tint(nil)
                    .labelsHidden()
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    VSplitView {
                        VStack(spacing: 0) {
                            content
                                // Dim the last packet's headers while the new ones load, instead of flashing a spinner.
                                .opacity(store.detailFrame == nil || store.detailFrame == packet.number ? 1 : 0.45)
                                .animation(.easeOut(duration: 0.12), value: store.detailFrame)
                            if let field = store.selectedField { FieldBar(field: field) }
                        }
                        .frame(minHeight: 300, idealHeight: 560, maxHeight: .infinity)
                        BytesView()
                            .frame(minHeight: 120, idealHeight: 200)
                    }
                }
            } else if store.selection.count > 1 {
                ContentUnavailableView {
                    Label("\(store.selection.count) packets selected", systemImage: "square.on.square")
                } description: {
                    Text(store.selection.count == 2 ? "Compare them field by field or byte by byte." : "Select one packet to see its headers.")
                } actions: {
                    if store.selection.count == 2 {
                        Button("Compare Packets") { onCompare(store.selection.sorted()) }
                            .buttonStyle(.glassProminent)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No packet selected", systemImage: "square.grid.3x3.topleft.filled")
                } description: {
                    Text("Select a packet. Its headers appear here, drawn the way the RFCs draw them.")
                }
            }
        }
        .frame(minWidth: 360)
        .background(Color.raised)
    }

    @ViewBuilder private var content: some View {
        if let error = store.detailError {
            ContentUnavailableView("Could not read this packet", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if store.detail == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.inspectorTab == .anatomy {
            AnatomyView()
        } else {
            FieldsView()
        }
    }
}

private struct InspectorHeader: View {
    @Environment(CaptureStore.self) private var store
    let packet: Packet

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Packet \(packet.number)")
                    .font(.title3.weight(.semibold))
                Spacer()
                ProtoChip(proto: packet.proto, family: ProtoFamily.of(packet))
                    .font(.callout)
            }
            Text(verbatim: "\(FlowRecord.endpoint(packet.source, packet.srcPort))  →  \(FlowRecord.endpoint(packet.destination, packet.dstPort))")
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Label("\(packet.length) bytes", systemImage: "ruler")
                Label(String(format: "%.6f s", packet.time), systemImage: "clock")
                if !packet.issues.isEmpty {
                    Label(packet.issues.labels.joined(separator: ", "), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(packet.issues.isSevere ? .red : .orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(TightLabel())
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

/// The selected field in full, with what you can do with it.
private struct FieldBar: View {
    @Environment(CaptureStore.self) private var store
    let field: FieldNode

    var body: some View {
        // The label shares a row with the action; the filter gets the full width below, so it reads whole.
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(field.label)
                    .font(.callout)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                if !field.filter.isEmpty {
                    Menu {
                        Button("Add to Filter") { store.applyAsFilter(field.filter, combine: true) }
                        Divider()
                        Button("Copy Filter") { copyText(field.filter) }
                        Button("Copy Value") { copyText(Anatomy.split(field.label).1) }
                        Button("Copy Field") { copyText(field.label) }
                    } label: {
                        Label("Apply as Filter", systemImage: "line.3.horizontal.decrease")
                            .labelStyle(.titleAndIcon)
                    } primaryAction: {
                        store.applyAsFilter(field.filter)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .fixedSize()
                    .help("Apply as display filter")
                }
            }
            if !field.filter.isEmpty {
                Text(field.filter)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(field.filter)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

func copyText(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

// MARK: Anatomy

struct AnatomyView: View {
    @Environment(CaptureStore.self) private var store

    /// Scrolls to the layer that holds the field: the box when it is drawn, otherwise the layer header
    /// (a TLS extension past the first 64 bytes still brings its TLS layer into view).
    private func scroll(_ proxy: ScrollViewProxy, to field: FieldNode?, animated: Bool = true) {
        guard let field else { return }
        let top = field.ancestors.last ?? field
        let target: AnyHashable?
        if let layer = store.layers.first(where: { l in l.node === top || l.boxes.contains { b in b.node === field || field.ancestors.contains { $0 === b.node } } }) {
            target = layer.id
        } else if store.textLayers.contains(where: { $0 === top }) {
            target = "text-\(top.field)"
        } else { target = nil }
        guard let target else { return }
        if animated { withAnimation(.easeOut(duration: 0.24)) { proxy.scrollTo(target, anchor: .top) } }
        else { DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) } }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(store.layers) { layer in
                        AnatomyLayerView(layer: layer, family: CaptureStore.family(forLayer: layer.node.field))
                            .id(layer.id)
                    }
                    ForEach(store.textLayers) { node in
                        TextLayerView(node: node).id("text-\(node.field)")
                    }
                    if store.layers.isEmpty && store.textLayers.isEmpty {
                        Text("No fixed-format headers in this packet. The Fields tab has every field.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .onChange(of: store.selectedField) { _, field in scroll(proxy, to: field) }
            .onAppear { scroll(proxy, to: store.selectedField, animated: false) }
        }
    }
}

/// The RFC ruler: tens over units, one column per bit.
private struct BitRuler: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width / CGFloat(Anatomy.bitsPerRow)
            for bit in 0..<Anatomy.bitsPerRow {
                let x = CGFloat(bit) * w + w / 2
                if bit % 10 == 0 {
                    ctx.draw(Text("\(bit / 10)").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(Color.kagami), at: CGPoint(x: x, y: 5))
                }
                ctx.draw(Text("\(bit % 10)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary), at: CGPoint(x: x, y: 17))
            }
        }
        .frame(height: 24)
        .accessibilityHidden(true)
    }
}

struct AnatomyLayerView: View {
    @Environment(CaptureStore.self) private var store
    @Environment(\.displayScale) private var scale
    let layer: Anatomy.Layer
    let family: ProtoFamily

    static let rowHeight: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(family.color).frame(width: 9, height: 9)
                Text(layer.name).font(.headline)
                Text("bytes \(layer.byteStart)–\(layer.byteStart + layer.byteCount + layer.hiddenBytes - 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if layer.hiddenBytes > 0 {
                    Text("+\(layer.hiddenBytes) more bytes in Fields")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { store.selectedField = layer.node }

            BitRuler()

            Canvas(rendersAsynchronously: false) { ctx, size in draw(ctx, size) }
                .frame(height: CGFloat(layer.rows) * Self.rowHeight + 1)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in store.selectedField = box(at: p, width: lastWidth)?.node }
                .onContinuousHover(coordinateSpace: .local) { phase in
                    if case .active(let p) = phase { store.hoveredField = box(at: p, width: lastWidth)?.node }
                    else if store.hoveredField.map({ f in layer.boxes.contains { $0.node === f } }) == true { store.hoveredField = nil }
                }
                .background(GeometryReader { g in Color.clear.onAppear { lastWidth = g.size.width }.onChange(of: g.size.width) { _, w in lastWidth = w } })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(layer.name) header diagram")
                .accessibilityRepresentation {
                    VStack {
                        ForEach(layer.boxes.filter { !$0.isGap }) { b in
                            Button("\(b.name): \(b.value)") { store.selectedField = b.node }
                        }
                    }
                }
        }
    }

    @State private var lastWidth: CGFloat = 0

    private func box(at p: CGPoint, width: CGFloat) -> Anatomy.Box? {
        guard width > 0 else { return nil }
        let w = width / CGFloat(Anatomy.bitsPerRow)
        let row = Int(p.y / Self.rowHeight)
        let bit = row * Anatomy.bitsPerRow + min(Anatomy.bitsPerRow - 1, max(0, Int(p.x / w)))
        return layer.boxes.first { !$0.isGap && $0.bitStart <= bit && bit < $0.bitEnd }
    }

    private func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width / CGFloat(Anatomy.bitsPerRow)
        let hair = 1 / scale
        let line = Color.primary.opacity(0.30)
        let selected = store.selectedField, hovered = store.hoveredField

        for box in layer.boxes {
            let isSelected = box.node != nil && (box.node === selected || selected.map { box.node!.ancestors.contains($0) } == true)
            let isHovered = box.node != nil && box.node === hovered
            let isFlagSet = box.bitWidth == 1 && ["Set", "1", "True"].contains(box.value)
            let segs = Anatomy.segments(of: box)
            for s in segs {
                let r = CGRect(x: snap(CGFloat(s.bitStart) * w), y: snap(CGFloat(s.row) * Self.rowHeight),
                               width: snap(CGFloat(s.bitEnd) * w) - snap(CGFloat(s.bitStart) * w),
                               height: snap(CGFloat(s.rowSpan) * Self.rowHeight))
                let fill: Color
                if box.isGap { fill = Color.primary.opacity(0.03) }
                else if isSelected { fill = family.color.opacity(0.38) }
                else if isHovered { fill = family.color.opacity(0.22) }
                else if isFlagSet { fill = family.color.opacity(0.26) }
                else { fill = family.color.opacity(0.09) }
                ctx.fill(Path(r), with: .color(fill))
                if box.isGap {
                    // Bits Wireshark does not name as a field: hatched, so they read as "not broken out", not as a missing label.
                    var hatch = Path()
                    var x = r.minX - r.height
                    while x < r.maxX {
                        hatch.move(to: CGPoint(x: x, y: r.maxY))
                        hatch.addLine(to: CGPoint(x: x + r.height, y: r.minY))
                        x += 6
                    }
                    ctx.drawLayer { l in
                        l.clip(to: Path(r))
                        l.stroke(hatch, with: .color(Color.primary.opacity(0.09)), lineWidth: hair)
                    }
                }
                // Rules sit on device pixels: offset by half a pixel so a 1-pixel line covers exactly one pixel.
                let edge = Path(r.insetBy(dx: hair / 2, dy: hair / 2))
                ctx.stroke(edge, with: .color(isSelected ? Color.bronze : line), lineWidth: isSelected ? hair * 2 : hair)
            }
            guard !box.isGap, let ls = Anatomy.labelSegment(of: box) else { continue }
            // Tall boxes (a 32-byte Random) carry their label in their first row, not stranded mid-block.
            let labelRows = min(ls.rowSpan, 1)
            let rect = CGRect(x: CGFloat(ls.bitStart) * w, y: CGFloat(ls.row) * Self.rowHeight,
                              width: CGFloat(ls.bits) * w, height: CGFloat(labelRows) * Self.rowHeight).insetBy(dx: 3, dy: 3)
            drawLabel(ctx, box: box, in: rect, strong: isSelected || isFlagSet)
        }
    }

    private func drawLabel(_ ctx: GraphicsContext, box: Anatomy.Box, in rect: CGRect, strong: Bool) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let value = Anatomy.shortValue(box.value)
        let name = ctx.resolve(Text(box.name).font(.system(size: 9.5)).foregroundStyle(.secondary))
        let valueText = ctx.resolve(Text(value).font(.system(size: 11.5, weight: strong ? .semibold : .regular, design: .monospaced)).foregroundStyle(.primary))
        let ns = name.measure(in: CGSize(width: 2000, height: 100)), vs = valueText.measure(in: CGSize(width: 2000, height: 100))

        if ns.width <= rect.width, vs.width <= rect.width, rect.height >= 30, !value.isEmpty {
            ctx.draw(name, at: CGPoint(x: center.x, y: center.y - 7))
            ctx.draw(valueText, at: CGPoint(x: center.x, y: center.y + 7))
            return
        }
        let tiny = rect.width < 22
        let shortName = tiny && box.bitWidth == 1 ? String(box.shortName.prefix(1)) : box.shortName
        let short = ctx.resolve(Text(shortName).font(.system(size: tiny ? 8 : 9.5, weight: strong ? .semibold : .regular)).foregroundStyle(strong ? .primary : .secondary))
        let ss = short.measure(in: CGSize(width: 2000, height: 100))
        if ss.width <= rect.width, vs.width <= rect.width, rect.height >= 30, !value.isEmpty, box.bitWidth > 1 {
            ctx.draw(short, at: CGPoint(x: center.x, y: center.y - 7))
            ctx.draw(valueText, at: CGPoint(x: center.x, y: center.y + 7))
        } else if ss.width <= rect.width + 5 {
            ctx.draw(short, at: center)
        } else if vs.width <= rect.width {
            ctx.draw(valueText, at: center)
        }
    }


}

// MARK: Bytes

struct BytesView: View {
    @Environment(CaptureStore.self) private var store

    var body: some View {
        let bytes = [UInt8](store.detail?.bytes ?? Data())
        let families = byteFamilies(count: bytes.count)
        let highlight = store.selectedField?.range
        let hover = store.hoveredField?.range
        let selectedFamily = store.selectedField.map(store.layerFamily) ?? .other
        VStack(spacing: 0) {
            HStack {
                Text("Bytes").font(.subheadline.weight(.semibold))
                Spacer()
                if let all = store.detail?.bytes, !all.isEmpty {
                    Menu {
                        let part = highlight.flatMap { $0.upperBound <= all.count ? all.subdata(in: $0) : nil }
                        if let part {
                            Section("Selected field") {
                                ForEach(ByteFormat.allCases) { f in Button(f.rawValue) { copyText(f.render(part)) } }
                            }
                        }
                        Section("Whole packet") {
                            ForEach(ByteFormat.allCases) { f in Button(f.rawValue) { copyText(f.render(all)) } }
                        }
                    } label: { Image(systemName: "doc.on.doc") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Copy bytes as hex dump, hex stream, Base64, C array…")
                }
                if let r = highlight {
                    Text("\(r.lowerBound)–\(r.upperBound - 1) · \(r.count) byte\(r.count == 1 ? "" : "s")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            Divider()
            GeometryReader { g in
                // 16 bytes a row when it fits, 8 when the inspector is narrow: never scroll sideways.
                let perRow = g.size.width >= HexRow.width(16) + 28 ? 16 : 8
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(0..<(bytes.count + perRow - 1) / perRow, id: \.self) { row in
                                HexRow(row: row, perRow: perRow, bytes: bytes, families: families, highlight: highlight, hover: hover, family: selectedFamily)
                                    .id(row)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: highlight) { _, r in
                        if let r { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(r.lowerBound / perRow, anchor: .center) } }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Packet bytes, \(bytes.count) bytes")
    }

    /// Which protocol layer each byte belongs to; deeper layers overwrite the ones that contain them.
    private func byteFamilies(count: Int) -> [ProtoFamily?] {
        var out = [ProtoFamily?](repeating: nil, count: count)
        for proto in store.detail?.tree ?? [] where proto.field != "frame" {
            guard let r = proto.range else { continue }
            let f = CaptureStore.family(forLayer: proto.field)
            for i in r where i < count { out[i] = f }
        }
        return out
    }
}

private struct HexRow: View {
    @Environment(CaptureStore.self) private var store
    let row: Int
    let perRow: Int
    let bytes: [UInt8]
    let families: [ProtoFamily?]
    let highlight: Range<Int>?
    let hover: Range<Int>?
    let family: ProtoFamily

    static let cell: CGFloat = 21
    static let ascii: CGFloat = 8.4
    static let offsetWidth: CGFloat = 44
    static let height: CGFloat = 19
    static func hexWidth(_ n: Int) -> CGFloat { cell * CGFloat(n) + (n > 8 ? 8 : 0) }
    static func width(_ n: Int) -> CGFloat { offsetWidth + hexWidth(n) + 12 + CGFloat(n) * ascii + 4 }

    var body: some View {
        Canvas { ctx, size in
            let start = row * perRow
            ctx.draw(Text(String(format: "%04x", start)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary),
                     at: CGPoint(x: 0, y: Self.height / 2), anchor: .leading)
            for i in start..<min(start + perRow, bytes.count) {
                let col = i - start
                let hx = Self.offsetWidth + CGFloat(col) * Self.cell + (col >= 8 ? 8 : 0)
                let ax = Self.offsetWidth + Self.hexWidth(perRow) + 12 + CGFloat(col) * Self.ascii
                let hexRect = CGRect(x: hx - 1, y: 1, width: Self.cell - 1, height: Self.height - 2)
                let asciiRect = CGRect(x: ax, y: 1, width: Self.ascii, height: Self.height - 2)
                var fill: Color?
                if highlight?.contains(i) == true { fill = Color.bronze.opacity(0.42) }
                else if hover?.contains(i) == true { fill = family.color.opacity(0.22) }
                else if let f = families[i] { fill = f.color.opacity(0.07) }
                if let fill {
                    ctx.fill(Path(roundedRect: hexRect, cornerRadius: 3), with: .color(fill))
                    ctx.fill(Path(roundedRect: asciiRect, cornerRadius: 2), with: .color(fill))
                }
                let b = bytes[i]
                ctx.draw(Text(String(format: "%02x", b)).font(.system(size: 11.5, design: .monospaced)),
                         at: CGPoint(x: hexRect.midX, y: Self.height / 2))
                let printable = (0x20...0x7e).contains(b)
                ctx.draw(Text(printable ? String(UnicodeScalar(b)) : "·").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(printable ? .primary : .tertiary),
                         at: CGPoint(x: asciiRect.midX, y: Self.height / 2))
            }
        }
        .frame(width: Self.width(perRow), height: Self.height)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { p in
            if let i = byte(at: p) { store.selectedField = store.detail?.node(at: i) }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let p) = phase, let i = byte(at: p) { store.hoveredField = store.detail?.node(at: i) }
            else { store.hoveredField = nil }
        }
    }

    private func byte(at p: CGPoint) -> Int? {
        let start = row * perRow
        var col: Int?
        let hexX = p.x - Self.offsetWidth
        let asciiX = p.x - (Self.offsetWidth + Self.hexWidth(perRow) + 12)
        if hexX >= 0, hexX < Self.hexWidth(perRow) {
            let half = Self.cell * 8
            let x: CGFloat? = perRow > 8 && hexX >= half + 8 ? hexX - 8 : (perRow > 8 && hexX >= half ? nil : hexX)
            col = x.map { Int($0 / Self.cell) }
        } else if asciiX >= 0, asciiX < CGFloat(perRow) * Self.ascii {
            col = Int(asciiX / Self.ascii)
        }
        guard let c = col, c >= 0, c < perRow, start + c < bytes.count else { return nil }
        return start + c
    }
}

/// Text protocols (HTTP, SIP...) are lines, not bit fields: one row per line, sized by its bytes.
struct TextLayerView: View {
    @Environment(CaptureStore.self) private var store
    let node: FieldNode

    var body: some View {
        let family = CaptureStore.family(forLayer: node.field)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(family.color).frame(width: 9, height: 9)
                Text(Anatomy.displayName(node)).font(.headline)
                if let r = node.range {
                    Text("bytes \(r.lowerBound)–\(r.upperBound - 1) · text").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(spacing: 0) {
                ForEach(node.children.filter { $0.range != nil }) { line in
                    let selected = store.selectedField === line || store.selectedField?.ancestors.contains { $0 === line } == true
                    HStack(spacing: 8) {
                        let text = line.label.replacingOccurrences(of: "\\r\\n", with: "")
                        // The bare line break that ends HTTP headers says so instead of looking like an empty row.
                        Text(text.trimmingCharacters(in: .whitespaces).isEmpty ? "End of headers (blank line)" : text)
                            .foregroundStyle(text.trimmingCharacters(in: .whitespaces).isEmpty ? .secondary : .primary)
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        Text("\(line.range?.count ?? 0) B")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(family.color.opacity(selected ? 0.38 : (store.hoveredField === line ? 0.2 : 0.09)))
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.18)).frame(height: 1) }
                    .contentShape(Rectangle())
                    .onTapGesture { store.selectedField = line }
                    .onHover { store.hoveredField = $0 ? line : (store.hoveredField === line ? nil : store.hoveredField) }
                    .help(line.label)
                }
            }
            .overlay { Rectangle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1) }
        }
    }
}

// MARK: Fields

struct FieldsView: View {
    @Environment(CaptureStore.self) private var store
    @State private var query = ""

    private struct Row: Identifiable { let node: FieldNode; let depth: Int; var id: ObjectIdentifier { node.id } }

    private var rows: [Row] {
        var out: [Row] = []
        let q = query.trimmingCharacters(in: .whitespaces)
        func matches(_ n: FieldNode) -> Bool { n.label.localizedCaseInsensitiveContains(q) || n.field.localizedCaseInsensitiveContains(q) }
        func walk(_ nodes: [FieldNode], _ depth: Int) {
            for n in nodes {
                if q.isEmpty {
                    out.append(Row(node: n, depth: depth))
                    if store.expandedFields.contains(n.id) { walk(n.children, depth + 1) }
                } else if matches(n) || n.allNodes().dropFirst().contains(where: matches) {
                    // Searching opens every branch that leads to a match.
                    out.append(Row(node: n, depth: depth))
                    walk(n.children, depth + 1)
                }
            }
        }
        walk(store.detail?.tree ?? [], 0)
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search fields", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 7))
            .padding(.horizontal, 12)
            .padding(.top, 6)
            fieldList
        }
    }

    private var fieldList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in FieldRow(node: row.node, depth: row.depth).id(row.id) }
                }
                .padding(.top, 10)
                .padding(.bottom, 6)
            }
            .onChange(of: store.selectedField) { _, f in
                if let f { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(f.id, anchor: UnitPoint(x: 0, y: 0.5)) } }
            }
            .onAppear {
                if let f = store.selectedField {
                    for a in f.ancestors { store.expandedFields.insert(a.id) }
                    DispatchQueue.main.async { proxy.scrollTo(f.id, anchor: UnitPoint(x: 0, y: 0.5)) }
                }
            }
        }
        .background(.background)
    }
}

private struct FieldRow: View {
    @Environment(CaptureStore.self) private var store
    let node: FieldNode
    let depth: Int

    var body: some View {
        let expanded = store.expandedFields.contains(node.id)
        let selected = store.selectedField === node
        let hovered = store.hoveredField === node
        let generated = node.label.hasPrefix("[")
        HStack(spacing: 5) {
            Group {
                if node.children.isEmpty {
                    Color.clear
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .frame(width: 12)
            if node.isProtocol {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(CaptureStore.family(forLayer: node.field).color)
                    .frame(width: 8, height: 8)
            }
            Text(node.label)
                .font(node.isProtocol ? .callout.weight(.semibold) : .callout)
                .italic(generated)
                .foregroundStyle(generated ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)  // the value sits at the end of the label; keep it in view
                .help(node.label)
            Spacer(minLength: 0)
        }
        .padding(.leading, 10 + CGFloat(depth) * 14)
        .padding(.trailing, 10)
        .frame(height: 22)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 5).fill(Color.bronze.opacity(0.22))
                    .overlay(alignment: .leading) { Capsule().fill(Color.bronze).frame(width: 3).padding(.vertical, 3) }
                    .padding(.horizontal, 6)
            }
            else if hovered { RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)).padding(.horizontal, 6) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !node.children.isEmpty && store.selectedField === node { toggle() }
            store.selectedField = node
        }
        .onTapGesture(count: 2) { toggle() }
        .onHover { inside in store.hoveredField = inside ? node : (store.hoveredField === node ? nil : store.hoveredField) }
        .help(node.label)
        .contextMenu {
            if !node.filter.isEmpty {
                Button("Apply as Filter") { store.applyAsFilter(node.filter) }
                Button("Add to Filter") { store.applyAsFilter(node.filter, combine: true) }
                Divider()
                Button("Copy Filter") { copyText(node.filter) }
            }
            Button("Copy Value") { copyText(Anatomy.split(node.label).1) }
            Button("Copy Field") { copyText(node.label) }
            if !node.field.isEmpty && !node.isProtocol {
                Button("Add as Column") { store.addColumn(node.field) }
            }
            if let r = node.range, let bytes = store.detail?.bytes, r.upperBound <= bytes.count {
                Menu("Copy Bytes As") {
                    ForEach(ByteFormat.allCases) { f in Button(f.rawValue) { copyText(f.render(bytes.subdata(in: r))) } }
                }
            }
            if !node.children.isEmpty {
                Divider()
                Button(expanded ? "Collapse" : "Expand") { toggle() }
                Button("Expand All") { for n in node.allNodes() { store.expandedFields.insert(n.id) } }
            Divider()
            Button("Expand Everything") { for n in (store.detail?.tree ?? []).flatMap({ $0.allNodes() }) { store.expandedFields.insert(n.id) } }
            Button("Collapse Everything") { store.expandedFields = [] }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(node.label)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.15)) {
            if store.expandedFields.contains(node.id) { store.expandedFields.remove(node.id) } else { store.expandedFields.insert(node.id) }
        }
    }
}
