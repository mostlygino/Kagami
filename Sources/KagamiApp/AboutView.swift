import AppKit
import KagamiCore
import SwiftUI

/// About Kagami, drawn as what Kagami draws: this copy of the app as a packet header, one field
/// per fact, on a 32-bit ruler. The icon stands over its own reflection, and the author's seal is
/// pressed onto a slip beside the header, like a publisher's colophon stamp.
struct AboutView: View {
    static let developer = "Gino de Graaff"
    static let handle = "mostlygino"
    static let website = URL(string: "https://mostlygino.com")!
    static let github = URL(string: "https://github.com/mostlygino")!
    static let repository = URL(string: "https://github.com/mostlygino/Kagami")!

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var decoded = 0          // how many header fields have resolved
    @State private var pressed = false
    @State private var bloom = false
    @State private var copied = false
    @State private var wireshark: String?

    private let build = BuildInfo.current

    var body: some View {
        VStack(spacing: 0) {
            hero.padding(.top, 34)
            header.padding(.top, 26).padding(.horizontal, 28)
            actions.padding(.top, 20)
            footer.padding(.top, 22).padding(.bottom, 24).padding(.horizontal, 28)
        }
        .frame(width: 520)
        .background { MirrorGround().ignoresSafeArea() }
        .task {
            wireshark = await TShark.version()?.replacingOccurrences(of: "TShark (Wireshark) ", with: "Wireshark ")
                .components(separatedBy: " (").first
            await play()
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 4) {
            VStack(spacing: 2) {
                icon.shadow(color: .black.opacity(0.25), radius: 10, y: 6)
                // The mirror: the icon once more, upside down, fading into the ground.
                icon
                    .scaleEffect(x: 1, y: -1)
                    .frame(height: 34, alignment: .top)
                    .clipped()
                    .mask(LinearGradient(colors: [.black.opacity(0.42), .clear], startPoint: .top, endPoint: .bottom))
                    .blur(radius: 0.6)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Kagami").font(.system(size: 32, weight: .semibold))
                Text("鏡").font(.system(size: 18, weight: .medium)).foregroundStyle(Color.bronze).accessibilityHidden(true)
            }
            .padding(.top, 2)
            Text("See what is on the wire. A Mac packet viewer on Wireshark's\u{00A0}own\u{00A0}dissectors.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
        }
    }

    private var icon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 112, height: 112)
    }

    // MARK: The release header

    private struct Field: Identifiable {
        let id: Int
        let row: Int
        let bits: Int
        let name: String
        let value: String
        var link: URL? = nil
    }

    private var fields: [Field] {
        let date = build.date.map { $0.formatted(.dateTime.day().month(.abbreviated).year()) } ?? "this Mac"
        var f = [
            Field(id: 0, row: 0, bits: 16, name: "Version", value: build.version),
            Field(id: 1, row: 0, bits: 8, name: "Channel", value: build.channel == .release ? "Release" : (build.channel == .beta ? "Beta" : "Dev")),
            Field(id: 2, row: 0, bits: 8, name: "Arch", value: BuildInfo.architecture == "Apple silicon" ? "arm64" : "x86_64"),
            Field(id: 3, row: 1, bits: 16, name: "Build", value: build.number),
            Field(id: 4, row: 1, bits: 16, name: "Built", value: date),
        ]
        f.append(Field(id: 5, row: 2, bits: 32, name: "Commit", value: build.commit ?? "local build",
                       link: build.commit.map { Self.repository.appendingPathComponent("commit/\($0)") }))
        f.append(Field(id: 6, row: 3, bits: 32, name: "Built by", value: "\(Self.handle) · \(Self.developer)", link: Self.website))
        return f
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Color.kagami).frame(width: 9, height: 9)
                    Text("This copy").font(.headline)
                    Text("Kagami release header").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    copyButton
                }
                Ruler()
                GeometryReader { g in
                    VStack(spacing: 0) {
                        ForEach(0..<4) { row in
                            HStack(spacing: 0) {
                                ForEach(fields.filter { $0.row == row }) { field in
                                    FieldBox(name: field.name, value: field.value, bits: field.bits, decoded: decoded > field.id, link: field.link)
                                        .frame(width: g.size.width * CGFloat(field.bits) / 32)
                                }
                            }
                        }
                    }
                    .overlay { Rectangle().strokeBorder(Color.primary.opacity(0.32), lineWidth: 1) }
                }
                .frame(height: 4 * 44)
            }
            kenin.padding(.top, 52)  // level with the top of the header box, below the ruler
        }
    }

    private var copyButton: some View {
        Button {
            copyText(build.report(wireshark: wireshark))
            withAnimation(.snappy) { copied = true }
            Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation(.snappy) { copied = false } }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(copied ? Color.kagami : .secondary)
        .help("Copy version, build, Wireshark and macOS for a bug report")
    }

    // MARK: The seal

    /// The 検印 slip: a scrap of paper the author stamps by hand, here with the mostlygino.com icon.
    /// Click it to stamp again.
    private var kenin: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(red: 0.965, green: 0.955, blue: 0.93))  // paper, in either appearance
                    .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .strokeBorder(Color.kagami.opacity(0.35), lineWidth: 0.75)
                    .padding(5)
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(Color.kagami, lineWidth: 2)
                    .frame(width: 58, height: 58)
                    .scaleEffect(bloom ? 1.45 : 1)
                    .opacity(pressed && !bloom ? 0.5 : 0)
                if let seal = NSImage(contentsOf: Bundle.main.url(forResource: "mostlygino", withExtension: "png") ?? URL(fileURLWithPath: "/")) {
                    Image(nsImage: seal)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 62, height: 62)
                        .rotationEffect(.degrees(-6))
                        .shadow(color: .black.opacity(pressed ? 0.25 : 0), radius: pressed ? 2 : 8, y: pressed ? 1 : 6)
                        .scaleEffect(pressed ? 1 : 1.6)
                        .opacity(pressed ? 1 : 0)
                        .blur(radius: pressed ? 0 : 5)
                }
            }
            .frame(width: 80, height: 80)
            .rotationEffect(.degrees(1.5))
            .shadow(color: .black.opacity(0.14), radius: 2, y: 1.5)
            .contentShape(Rectangle())
            .onTapGesture { Task { await stamp() } }
            Text("検印").font(.system(size: 10, weight: .medium)).tracking(3).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.handle) seal")
    }

    /// One authored moment: the header dissects field by field, then the seal lands.
    private func play() async {
        guard !reduceMotion else { decoded = 99; pressed = true; return }
        for i in 0..<fields.count {
            try? await Task.sleep(for: .milliseconds(i == 0 ? 220 : 90))
            withAnimation(.easeOut(duration: 0.25)) { decoded = i + 1 }
        }
        await stamp()
    }

    private func stamp() async {
        guard !reduceMotion else { pressed = true; return }
        pressed = false
        bloom = false
        try? await Task.sleep(for: .milliseconds(240))
        withAnimation(.easeIn(duration: 0.2)) { pressed = true }
        try? await Task.sleep(for: .milliseconds(200))
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        withAnimation(.easeOut(duration: 0.7)) { bloom = true }
    }

    // MARK: Actions and footer

    private var actions: some View {
        HStack(spacing: 10) {
            Button { NSWorkspace.shared.open(releaseNotes) } label: {
                Label("Release Notes", systemImage: "doc.text").foregroundStyle(.primary)
            }
            .buttonStyle(.glass)
            .tint(nil)  // neutral glass: the window's light cyan under white text would not read
            .help(build.channel == .development ? "Show the latest changes on GitHub" : "Show what changed in \(build.version)")
            // The one prominent action: deep mirror teal under white text keeps 4.5:1 in both appearances.
            Button { Task { await Updater.shared.check(interactive: true) } } label: {
                Label("Check for Updates…", systemImage: "arrow.down.circle").foregroundStyle(.white)
            }
            .buttonStyle(.glassProminent)
            .tint(.kagamiFill)
            .help("Look for a newer signed release on GitHub")
        }
        .font(.body.weight(.medium))
        .labelStyle(.titleAndIcon)
        .controlSize(.large)
    }

    private var releaseNotes: URL {
        build.channel == .development
            ? Self.repository.appendingPathComponent("commits/main")
            : Self.repository.appendingPathComponent("releases/tag/v\(build.version)")
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Text([wireshark ?? "Wireshark not found", "macOS \(BuildInfo.macOS)", BuildInfo.architecture].joined(separator: "  ·  "))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Link("mostlygino.com", destination: Self.website)
                Link("GitHub", destination: Self.repository)
                Link("Feedback", destination: Self.repository.appendingPathComponent("issues/new"))
                    .help("Report a problem or suggest something")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.kagami)
            VStack(spacing: 3) {
                Text("Packets are read by Wireshark's tshark and sharkd. Nothing leaves this Mac.")
                Text("© 2026 \(Self.developer). Code under AGPL-3.0-or-later; name and icon reserved.")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
    }
}

/// tens over units, one column per bit, as in the RFCs.
struct Ruler: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width / 32
            for bit in 0..<32 {
                let x = CGFloat(bit) * w + w / 2
                if bit % 10 == 0 {
                    ctx.draw(Text("\(bit / 10)").font(.system(size: 8.5, weight: .semibold, design: .monospaced)).foregroundStyle(Color.kagami), at: CGPoint(x: x, y: 5))
                }
                ctx.draw(Text("\(bit % 10)").font(.system(size: 8.5, design: .monospaced)).foregroundStyle(.tertiary), at: CGPoint(x: x, y: 16))
            }
        }
        .frame(height: 22)
        .accessibilityHidden(true)
    }
}

struct FieldBox: View {
    let name: String
    let value: String
    let bits: Int
    let decoded: Bool
    let link: URL?
    @State private var hover = false

    var body: some View {
        VStack(spacing: 2) {
            Text(name).font(.system(size: 9.5)).foregroundStyle(.secondary)
            Text(decoded ? value : hex)
                .font(.system(size: 12, weight: decoded ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(decoded ? (link != nil && hover ? Color.kagami : .primary) : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(Color.kagami.opacity(decoded ? (hover ? 0.2 : 0.1) : 0.03))
        .overlay { Rectangle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.5) }
        .contentShape(Rectangle())
        .onHover { hover = $0 && link != nil }
        .onTapGesture { if let link { NSWorkspace.shared.open(link) } }
        .help(link?.absoluteString ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): \(value)")
    }

    /// The field before it is read: its bytes.
    private var hex: String {
        Array(value.utf8.prefix(bits / 4)).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

/// The window ground: a faint, cool sheen across the top, as on polished bronze.
struct MirrorGround: View {
    var body: some View {
        Color.ground.overlay(alignment: .top) {
            LinearGradient(colors: [Color.kagami.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 220)
                .accessibilityHidden(true)
        }
    }
}
