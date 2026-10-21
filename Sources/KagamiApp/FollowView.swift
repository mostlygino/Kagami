import KagamiCore
import SwiftUI

/// One conversation, reassembled: a ladder diagram of who sent what, beside the bytes themselves.
struct FollowView: View {
    @Environment(CaptureStore.self) private var store
    let request: FollowRequest

    enum Show: String, CaseIterable, Identifiable {
        case both = "Both directions", c2s = "Client → Server", s2c = "Server → Client"
        var id: Self { self }
        func includes(_ d: Direction) -> Bool {
            switch self {
            case .both: true
            case .c2s: d == .clientToServer
            case .s2c: d == .serverToClient
            }
        }
    }

    struct Match: Hashable { let chunk: Int; let range: Range<String.Index> }

    @State private var result: FollowResult?
    @State private var error: String?
    @State private var show = Show.both
    @State private var hex = false
    /// Bytes per hex row, from the transcript's width: 16 when it fits, else 8, so no row ever wraps.
    @State private var perRow = 16
    @State private var query = ""
    @State private var current = 0
    @State private var texts: [Int: String] = [:]
    @State private var matches: [Match] = []

    // ponytail: very large payloads are cut for display; Export keeps every byte.
    static let displayLimit = 160_000

    var body: some View {
        VStack(spacing: 0) {
            if let result {
                Summary(result: result, request: request)
                if Self.isTLS(result) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill").foregroundStyle(Color.bronze)
                        Text("Encrypted with TLS. The payloads are ciphertext, so they are shown in Hex; the handshake is readable in the packet list.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.bronze.opacity(0.08))
                    .overlay(alignment: .bottom) { Divider() }
                }
            }
            content
        }
        .navigationTitle("\(request.stream.proto.rawValue.uppercased()) Stream \(request.stream.index)")
        .navigationSubtitle(URL(fileURLWithPath: request.path).lastPathComponent)
        .searchable(text: $query, placement: .toolbar, prompt: "Search conversation")
        .onSubmit(of: .search) { step(1) }
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Direction", selection: $show) {
                        ForEach(Show.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(show.rawValue, systemImage: show == .both ? "arrow.left.arrow.right" : (show == .c2s ? "arrow.right" : "arrow.left"))
                        .labelStyle(.titleAndIcon)
                }
                .fixedSize()
                .help("Which direction to show")
            }
            ToolbarItem {
                Picker("View", selection: $hex) {
                    Text("Text").tag(false)
                    Text("Hex").tag(true)
                }
                .pickerStyle(.segmented).tint(nil)
                .fixedSize()
            }
            ToolbarItemGroup {
                Button { step(-1) } label: { Label("Previous Match", systemImage: "chevron.up") }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(matches.isEmpty)
                Button { step(1) } label: { Label("Next Match", systemImage: "chevron.down") }
                    .keyboardShortcut("g")
                    .disabled(matches.isEmpty)
            }
            ToolbarItem {
                Button { store.applyAsFilter(request.stream.filter) } label: { Label("Filter to Stream", systemImage: "line.3.horizontal.decrease.circle") }
                    .help("Show only this conversation in the packet list")
                    .disabled(store.fileURL?.path != request.path)
            }
        }
        .task {
            do { result = try await TShark.follow(request.stream, in: URL(fileURLWithPath: request.path)) }
            catch { self.error = error.localizedDescription }
            // Ciphertext as text is noise; start encrypted streams in Hex.
            if let result, Self.isTLS(result) { hex = true }
            render()
        }
        .onChange(of: hex) { render() }
        .onChange(of: query) { current = 0; findMatches() }
        .onChange(of: show) { current = 0; findMatches() }
    }

    @ViewBuilder private var content: some View {
        if let error {
            ContentUnavailableView("Could not follow this stream", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if result == nil {
            ProgressView("Reassembling…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shown.isEmpty {
            ContentUnavailableView("No payload", systemImage: "tray",
                                   description: Text("This conversation carries no data in the chosen direction. Handshakes and acknowledgements have no payload."))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, chunk in
                            ChunkRow(chunk: chunk, text: attributed(chunk), previousTime: i > 0 ? shown[i - 1].time : chunk.time,
                                     onReveal: { if store.fileURL?.path == request.path { store.select(chunk.frame) } })
                                .id(chunk.id)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: current) { scroll(proxy) }
                .onChange(of: matches.count) { scroll(proxy) }
            }
            .onGeometryChange(for: Int.self) { $0.size.width >= 760 ? 16 : 8 } action: { n in
                if n != perRow { perRow = n; render() }
            }
            .overlay(alignment: .bottomTrailing) {
                if !query.isEmpty {
                    Text(matches.isEmpty ? "No matches" : "\(current + 1) of \(matches.count)")
                        .font(.callout.monospacedDigit())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                        .padding(14)
                }
            }
        }
    }

    // MARK: Data

    private var shown: [StreamChunk] { result?.chunks.filter { show.includes($0.direction) } ?? [] }

    private func render() {
        texts = Dictionary(uniqueKeysWithValues: (result?.chunks ?? []).map { ($0.id, Self.render($0.bytes, hex: hex, perRow: perRow)) })
        findMatches()
    }

    private func findMatches() {
        guard !query.isEmpty else { matches = []; return }
        matches = shown.flatMap { chunk -> [Match] in
            guard let text = texts[chunk.id] else { return [] }
            var out: [Match] = []
            var from = text.startIndex
            while let r = text.range(of: query, options: .caseInsensitive, range: from..<text.endIndex) {
                out.append(Match(chunk: chunk.id, range: r))
                from = r.upperBound
            }
            return out
        }
    }

    /// Most payloads start with a TLS record header: content type 20 to 23, then version 3.x.
    static func isTLS(_ r: FollowResult) -> Bool {
        let looks = r.chunks.filter { c in
            let b = [UInt8](c.bytes.prefix(2))
            return b.count == 2 && (20...23).contains(b[0]) && b[1] == 3
        }.count
        return !r.chunks.isEmpty && looks * 2 >= r.chunks.count
    }

    static func render(_ data: Data, hex: Bool, perRow: Int = 16) -> String {
        let bytes = [UInt8](data.prefix(hex ? displayLimit / 4 : displayLimit))
        var s: String
        if hex {
            s = stride(from: 0, to: bytes.count, by: perRow).map { start in
                let row = bytes[start..<min(start + perRow, bytes.count)]
                let hexPart = row.map { String(format: "%02x", $0) }.joined(separator: " ")
                let ascii = String(row.map { (0x20...0x7e).contains($0) ? Character(UnicodeScalar($0)) : "·" })
                return String(format: "%08x  ", start) + hexPart.padding(toLength: perRow * 3, withPad: " ", startingAt: 0) + "  " + ascii
            }.joined(separator: "\n")
        } else {
            s = String(bytes.compactMap { b -> Character? in
                switch b {
                case 0x0d: nil
                case 0x0a, 0x09, 0x20...0x7e: Character(UnicodeScalar(b))
                default: "·"
                }
            })
        }
        if bytes.count < data.count { s += "\n… \((data.count - bytes.count).grouped) more bytes not shown" }
        return s
    }

    private func attributed(_ chunk: StreamChunk) -> AttributedString {
        var a = AttributedString(texts[chunk.id] ?? "")
        for (i, m) in matches.enumerated() where m.chunk == chunk.id {
            guard let lo = AttributedString.Index(m.range.lowerBound, within: a),
                  let hi = AttributedString.Index(m.range.upperBound, within: a) else { continue }
            a[lo..<hi].backgroundColor = i == current ? Color.yellow : Color.yellow.opacity(0.32)
            if i == current { a[lo..<hi].foregroundColor = .black }
        }
        return a
    }

    private func step(_ by: Int) {
        guard !matches.isEmpty else { return }
        current = (current + by + matches.count) % matches.count
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard matches.indices.contains(current) else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(matches[current].chunk, anchor: .center) }
    }
}

enum Peer {
    static let client = Color.kagami
    static let server = Color.dynamic(light: 0x6B6A66, dark: 0xA6A59F)  // neutral: protocol colours stay protocol-only
    static func color(_ d: Direction) -> Color { d == .clientToServer ? client : server }
}

private struct Summary: View {
    let result: FollowResult
    let request: FollowRequest

    var body: some View {
        let up = result.chunks.filter { $0.direction == .clientToServer }.reduce(0) { $0 + $1.bytes.count }
        let down = result.chunks.filter { $0.direction == .serverToClient }.reduce(0) { $0 + $1.bytes.count }
        let span = (result.chunks.last?.time ?? 0) - (result.chunks.first?.time ?? 0)
        HStack(spacing: 0) {
            PeerLabel(title: "Client", address: result.client, bytes: up, color: Peer.client)
                .frame(width: LadderMetrics.width, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(result.chunks.count) payloads over \(Format.duration(span))")
                    .font(.callout)
                Text("Arrows show who sent each payload. Click a packet number to find it in the list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 10)
            Spacer()
            PeerLabel(title: "Server", address: result.server, bytes: down, color: Peer.server)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct PeerLabel: View {
    let title: String
    let address: String
    let bytes: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(address).font(.callout.monospaced()).textSelection(.enabled)
            Text("\(Format.bytes(bytes)) sent").font(.caption).foregroundStyle(.secondary)
        }
    }
}

enum LadderMetrics {
    static let width: CGFloat = 150
    static let clientX: CGFloat = 18
    static let serverX: CGFloat = 132
}

private struct ChunkRow: View {
    let chunk: StreamChunk
    let text: AttributedString
    let previousTime: Double
    let onReveal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ladder
                .frame(width: LadderMetrics.width)
                .padding(.leading, 16)
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Peer.color(chunk.direction).opacity(0.07), in: .rect(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Peer.color(chunk.direction).opacity(chunk.direction == .clientToServer ? 0.35 : 0.15), lineWidth: 1)
                }
                .padding(.trailing, 16)
                .padding(.vertical, 4)
        }
    }

    /// Rails for client and server run the whole height; this payload's arrow crosses near the top.
    private var ladder: some View {
        let toServer = chunk.direction == .clientToServer
        let color = Peer.color(chunk.direction)
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                for x in [LadderMetrics.clientX, LadderMetrics.serverX] {
                    ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(.secondary.opacity(0.35)))
                }
                let y: CGFloat = 26
                let from = toServer ? LadderMetrics.clientX : LadderMetrics.serverX
                let to = toServer ? LadderMetrics.serverX : LadderMetrics.clientX
                var line = Path()
                line.move(to: CGPoint(x: from, y: y))
                line.addLine(to: CGPoint(x: to + (toServer ? -6 : 6), y: y))
                ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                var head = Path()
                head.move(to: CGPoint(x: to, y: y))
                head.addLine(to: CGPoint(x: to + (toServer ? -8 : 8), y: y - 4.5))
                head.addLine(to: CGPoint(x: to + (toServer ? -8 : 8), y: y + 4.5))
                head.closeSubpath()
                ctx.fill(head, with: .color(color))
                ctx.fill(Path(ellipseIn: CGRect(x: from - 4, y: y - 4, width: 8, height: 8)), with: .color(color))
            }
            HStack(spacing: 4) {
                Button("#\(chunk.frame)", action: onReveal)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.kagami)
                    .help("Show packet \(chunk.frame) in the list")
                Text("· \(Format.bytes(chunk.bytes.count))")
                    .foregroundStyle(.secondary)
            }
            .font(.caption2.monospacedDigit())
            .frame(width: LadderMetrics.serverX - LadderMetrics.clientX - 10)
            .offset(x: LadderMetrics.clientX + 5, y: 5)
            Text(chunk.time - previousTime >= 0.001 ? "+" + Format.duration(chunk.time - previousTime) : "")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: LadderMetrics.serverX - LadderMetrics.clientX - 10)
                .offset(x: LadderMetrics.clientX + 5, y: 33)
        }
        .frame(minHeight: 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Packet \(chunk.frame), \(chunk.bytes.count) bytes, \(toServer ? "client to server" : "server to client")")
    }
}
