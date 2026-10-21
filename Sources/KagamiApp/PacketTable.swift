import AppKit
import KagamiCore
import SwiftUI

/// The packet list. NSTableView rather than SwiftUI `Table`: live captures append thousands of rows a
/// second, and appends must not rediff the whole list, lose the scroll position or the selection.
struct PacketTable: NSViewRepresentable {
    @Environment(CaptureStore.self) private var store
    let colouring: RowColouring
    let timeDisplay: TimeDisplay
    let onFollow: (Packet) -> Void
    let onCompare: ([Int]) -> Void
    var onComment: ([Int]) -> Void = { _ in }

    struct Column {
        let id: String
        let title: String
        let width: CGFloat
        let min: CGFloat
        let align: NSTextAlignment
    }

    static let columns: [Column] = [
        Column(id: "issues", title: "", width: 16, min: 16, align: .center),
        Column(id: "number", title: "No.", width: 64, min: 44, align: .right),
        Column(id: "time", title: "Time", width: 96, min: 60, align: .right),
        Column(id: "source", title: "Source", width: 132, min: 70, align: .left),
        Column(id: "destination", title: "Destination", width: 132, min: 70, align: .left),
        Column(id: "protocol", title: "Protocol", width: 96, min: 78, align: .left),
        Column(id: "length", title: "Length", width: 58, min: 44, align: .right),
        Column(id: "host", title: "Host", width: 160, min: 60, align: .left),
        Column(id: "app", title: "App", width: 96, min: 50, align: .left),
        Column(id: "comment", title: "Comment", width: 160, min: 60, align: .left),
        Column(id: "info", title: "Info", width: 380, min: 140, align: .left),
    ]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KagamiTableView()
        table.style = .fullWidth
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = NSColor(Color.ground)
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        // AppKit's own column autoresizing hands growth to the wrong columns; FittingScrollView refits instead.
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = []
        table.autosaveName = "KagamiPacketTable.v7"
        for c in Self.columns {
            let col = NSTableColumn(identifier: .init(c.id))
            col.title = c.title
            col.width = c.width
            col.minWidth = c.min
            col.headerCell.alignment = c.align
            col.sortDescriptorPrototype = NSSortDescriptor(key: c.id, ascending: true)
            if c.id == "info" { col.resizingMask = [] }  // Info is always "the rest of the width"
            if c.id == "issues" {
                col.headerToolTip = "TCP problems Wireshark found: retransmissions, resets, lost segments"
                col.resizingMask = []
                col.headerCell.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "TCP problems")?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
            }
            table.addTableColumn(col)
        }
        table.autosaveTableColumns = true
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.copyHandler = { [weak coordinator = context.coordinator] in coordinator?.copySelection() }
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        let header = NSMenu()
        header.delegate = context.coordinator
        table.headerView?.menu = header
        table.setAccessibilityLabel("Packets")

        let scroll = FittingScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false  // the columns always fit the pane (fitColumns)
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        // After the layout pass, not inside it: column widths changed mid-layout leave some rows' cells where they were.
        scroll.onLayout = { [weak coordinator = context.coordinator] in DispatchQueue.main.async { coordinator?.fitColumns() } }
        context.coordinator.table = table
        context.coordinator.apply(store.visible, force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if let app = c.table?.tableColumn(withIdentifier: .init("app")) {
            let hide = store.apps.isEmpty
            if app.isHidden != hide { app.isHidden = hide; c.fitColumns() }
        }
        if let comment = c.table?.tableColumn(withIdentifier: .init("comment")) {
            let hide = store.markCounts[.commented] == nil
            if comment.isHidden != hide { comment.isHidden = hide; c.fitColumns() }
        }
        c.syncCustomColumns(store.customColumns)
        if c.marksVersion != store.marksVersion {
            c.marksVersion = store.marksVersion
            c.reloadKeepingSelection()
        }
        let styleChanged = c.colouring != colouring || c.timeDisplay != timeDisplay
        c.colouring = colouring
        c.timeDisplay = timeDisplay
        c.apply(store.visible, force: styleChanged || c.coloursCount != store.wiresharkColours.count || c.version != store.visibleVersion)
        c.coloursCount = store.wiresharkColours.count
        c.version = store.visibleVersion
        if c.unseenVersion != store.refreshUnseen {
            c.unseenVersion = store.refreshUnseen
            c.repaintUnseen()
        }
        c.syncSelection()
        if c.revealRequest != store.revealRequest {
            c.revealRequest = store.revealRequest
            c.reveal()
        }
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: PacketTable
        weak var table: NSTableView?
        var rows: [Packet] = []
        var colouring: RowColouring
        var timeDisplay: TimeDisplay
        var coloursCount = 0
        var revealRequest = 0
        var version = -1
        var unseenVersion = 0
        var marksVersion = 0
        private var updatingSelection = false
        private var store: CaptureStore { parent.store }

        static let clock: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSSSSS"
            return f
        }()

        init(_ parent: PacketTable) {
            self.parent = parent
            colouring = parent.colouring
            timeDisplay = parent.timeDisplay
        }

        func apply(_ new: [Packet], force: Bool) {
            guard let table else { return }
            let old = rows
            // Appending grows the table under the viewport; that is not you scrolling away.
            let wasFollowing = store.followLive
            appending = true
            defer { appending = false }
            let isAppend = !old.isEmpty && new.count > old.count && new[old.count - 1].number == old.last!.number && new[0].number == old[0].number
            rows = new
            if force || !(isAppend || new.count == old.count) {
                // Selection follows packet numbers, not row indexes: keep AppKit from writing stale rows back.
                updatingSelection = true
                table.reloadData()
                updatingSelection = false
                syncSelection()
            } else if isAppend {
                // Live rows fade in; a burst (or a file loading) goes in at once.
                let batch = new.count - old.count
                let animate = store.isCapturing && batch < 150 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                table.insertRows(at: IndexSet(old.count..<new.count), withAnimation: animate ? .effectFade : [])
            }
            if isAppend && store.isCapturing && wasFollowing { glideToEnd() }
        }

        /// Follows the newest packet with a short ease-out glide instead of a jump per batch.
        private var gliding = false
        private var appending = false
        func glideToEnd() {
            guard let table, let scroll = table.enclosingScrollView else { return }
            let clip = scroll.contentView
            let bottom = max(0, table.frame.height - clip.bounds.height + scroll.contentInsets.top)
            let target = NSPoint(x: clip.bounds.origin.x, y: bottom)
            guard abs(clip.bounds.origin.y - target.y) > 0.5 else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                clip.setBoundsOrigin(target); scroll.reflectScrolledClipView(clip); return
            }
            gliding = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                ctx.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(target)
                scroll.reflectScrolledClipView(clip)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.gliding = false }
            }
        }

        func reloadKeepingSelection() {
            updatingSelection = true
            table?.reloadData()
            updatingSelection = false
            syncSelection()
        }

        /// One table column per custom field, added after Info and removed when dropped.
        func syncCustomColumns(_ fields: [String]) {
            guard let table else { return }
            let have = table.tableColumns.filter { $0.identifier.rawValue.hasPrefix("custom:") }
            for col in have where !fields.contains(String(col.identifier.rawValue.dropFirst(7))) { table.removeTableColumn(col) }
            for f in fields where table.tableColumn(withIdentifier: .init("custom:" + f)) == nil {
                let col = NSTableColumn(identifier: .init("custom:" + f))
                col.title = f
                col.width = 140
                col.minWidth = 50
                col.headerToolTip = "Wireshark field \(f). Right-click the header to remove it."
                col.sortDescriptorPrototype = nil
                table.addTableColumn(col)
            }
        }

        func syncSelection() {
            guard let table else { return }
            let wanted = IndexSet(rows.indices.filter { store.selection.contains(rows[$0].number) })
            guard wanted != table.selectedRowIndexes else { return }
            updatingSelection = true
            table.selectRowIndexes(wanted, byExtendingSelection: false)
            updatingSelection = false
        }

        /// Brings the selection into view: at once (so it is never lost), then, once the layout has
        /// settled (the inspector may be gliding in), a short glide that centres it.
        func reveal() {
            guard let table else { return }
            if store.isCapturing && store.followLive { glideToEnd(); return }
            guard let first = table.selectedRowIndexes.first else { return }
            table.scrollRowToVisible(first)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { [weak self] in
                MainActor.assumeIsolated { self?.centre(row: first) }
            }
        }

        private func centre(row index: Int) {
            guard let table, let scroll = table.enclosingScrollView, index < table.numberOfRows,
                  table.selectedRowIndexes.contains(index) else { return }
            let clip = scroll.contentView
            let row = table.rect(ofRow: index)
            guard !clip.bounds.insetBy(dx: 0, dy: clip.bounds.height * 0.2).contains(row) else { return }
            let maxY = max(0, table.frame.height - clip.bounds.height + scroll.contentInsets.top)
            let target = NSPoint(x: clip.bounds.origin.x, y: min(maxY, max(-scroll.contentInsets.top, row.midY - clip.bounds.height / 2)))
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                clip.setBoundsOrigin(target); scroll.reflectScrolledClipView(clip); return
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                clip.animator().setBoundsOrigin(target)
                scroll.reflectScrolledClipView(clip)
            }
        }

        func repaintUnseen() {
            table?.enumerateAvailableRowViews { view, row in
                guard row < rows.count, let v = view as? PacketRowView else { return }
                v.isUnseen = store.unseen.contains(rows[row].number)
            }
        }

        /// The columns exactly fill the pane: restored widths or a hidden column must never leave a sideways scroller or a gap.
        @objc func fitColumns() {
            guard let table, let clip = table.enclosingScrollView?.contentView, clip.bounds.width > 300 else { return }
            let shown = table.tableColumns.filter { !$0.isHidden }
            let used = shown.reduce(0) { $0 + $1.width + table.intercellSpacing.width }
            var delta = clip.bounds.width - used
            guard abs(delta) > 1 else { return }
            // Growing: Info takes it all. Shrinking: columns wider than their default give back first,
            // then Info, then the rest from the right down to their minimums.
            let info = shown.first { $0.identifier.rawValue == "info" }
            // Row views made under the old widths keep their cell frames unless told to lay out again.
            // Cells made under the old widths can keep stale frames; reload the visible ones. A full reloadData
            // would also reset the selection behind the inspector's back.
            defer {
                let visible = table.rows(in: table.visibleRect)
                if visible.length > 0 {
                    table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                                     columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
                }
            }
            let defaults = Dictionary(uniqueKeysWithValues: PacketTable.columns.map { ($0.id, $0.width) })
            if delta > 0 {
                // Columns squeezed earlier get their default width back first, then Info takes the rest.
                for col in shown where col !== info && col.resizingMask != [] {
                    guard let d = defaults[col.identifier.rawValue], col.width < d, delta >= 1 else { continue }
                    let grow = min(d - col.width, delta).rounded(.down)
                    col.width += grow
                    delta -= grow
                }
                if let col = info ?? shown.last { col.width = (col.width + delta).rounded(.down) }
                return
            }
            let rightToLeft = shown.reversed().filter { $0.resizingMask != [] && $0 !== info }
            let passes: [([NSTableColumn], (NSTableColumn) -> CGFloat)] = [
                (rightToLeft, { max($0.minWidth, defaults[$0.identifier.rawValue] ?? $0.minWidth) }),
                (info.map { [$0] } ?? [], { $0.minWidth }),
                (rightToLeft, { $0.minWidth }),
            ]
            for (cols, floor) in passes {
                for col in cols where col.width > floor(col) {
                    // Whole points: fractional column edges snap differently in rows made at different times.
                    let target = max(floor(col), (col.width + delta).rounded(.down))
                    delta -= target - col.width
                    col.width = target
                    if delta > -1 { return }
                }
            }
        }

        @objc func scrolled() {
            guard let table, let scroll = table.enclosingScrollView else { return }
            let visibleRows = table.rows(in: scroll.contentView.bounds)
            // Our own glide passes through "not at the bottom"; only your scrolling turns following off.
            if store.isCapturing && !gliding && !appending {
                let atBottom = visibleRows.upperBound >= rows.count - 2
                if store.followLive != atBottom { store.followLive = atBottom }
            }
            if !store.unseen.isEmpty, visibleRows.length > 0 {
                let seen = rows[max(0, visibleRows.lowerBound)..<min(rows.count, visibleRows.upperBound)].map(\.number)
                // Let the dot register before it clears.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    MainActor.assumeIsolated { self?.store.markSeen(seen) }
                }
            }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let d = tableView.sortDescriptors.first, let key = d.key else { return }
            store.sortOrder = CaptureStore.SortOrder(key: key, ascending: d.ascending)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updatingSelection, let table else { return }
            store.selection = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].number : nil })
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let v = (tableView.makeView(withIdentifier: .init("row"), owner: nil) as? PacketRowView) ?? {
                let r = PacketRowView(); r.identifier = .init("row"); return r
            }()
            let p = rows[row]
            switch colouring {
            case .protocols: v.tint = ProtoFamily.of(p).nsColor.withAlphaComponent(0.09); v.textTint = nil
            case .wireshark:
                let c = store.wiresharkColours[p.number]
                v.tint = c?.bg; v.textTint = c?.fg
            case .off: v.tint = nil; v.textTint = nil
            }
            if let h = store.mark(p.number).highlight { v.tint = NSColor(h.color).withAlphaComponent(0.30) }
            v.isUnseen = store.unseen.contains(p.number)
            return v
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier.rawValue, row < rows.count else { return nil }
            let p = rows[row]
            let fg: NSColor? = colouring == .wireshark ? store.wiresharkColours[p.number]?.fg : nil

            if id == "issues" {
                let v = reuse(tableView, "issues") { IssueCell() }
                v.set(p.issues)
                return v
            }
            if id == "protocol" {
                let v = reuse(tableView, "protocol") { ProtoCell() }
                v.set(p.proto, family: ProtoFamily.of(p), textColor: fg)
                return v
            }
            let v = reuse(tableView, id) { TextCell(align: PacketTable.columns.first { $0.id == id }?.align ?? .left, mono: ["number", "time", "length", "source", "destination"].contains(id) || id.hasPrefix("custom:")) }
            let text = text(for: id, row: row, packet: p)
            if store.mark(p.number).struck {
                v.field.attributedStringValue = NSAttributedString(string: text, attributes: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue, .font: v.field.font as Any,
                    .foregroundColor: NSColor.tertiaryLabelColor])
            } else {
                v.field.stringValue = text
                v.field.textColor = fg ?? (id == "info" || id == "number" || id == "source" || id == "destination" || id == "protocol" ? .labelColor : .secondaryLabelColor)
            }
            v.field.toolTip = id == "info" || id == "comment" || id.hasPrefix("custom:") ? text : nil
            return v
        }

        private func reuse<T: NSView>(_ table: NSTableView, _ id: String, make: () -> T) -> T {
            if let v = table.makeView(withIdentifier: .init(id), owner: nil) as? T { return v }
            let v = make()
            v.identifier = .init(id)
            return v
        }

        func text(for id: String, row: Int, packet p: Packet) -> String {
            switch id {
            case "number": return String(p.number)
            case "time":
                switch timeDisplay {
                case .relative: return String(format: "%.6f", p.time)
                case .delta:
                    // Since the previous captured packet, whatever the sort or filter.
                    let prev = store.packet(p.number - 1)
                    return String(format: "%.6f", prev.map { p.time - $0.time } ?? 0)
                case .clock: return Self.clock.string(from: Date(timeIntervalSince1970: p.epoch))
                }
            case "source": return p.source
            case "destination": return p.destination
            case "length": return String(p.length)
            case "host": return store.host(of: p)
            case "app": return p.process
            case "info": return p.info
            case "comment": return store.mark(p.number).comment
            default:
                if id.hasPrefix("custom:") { return store.customValues[String(id.dropFirst(7))]?[p.number] ?? "" }
                return ""
            }
        }

        // MARK: Actions

        @objc func doubleClicked() {
            guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
            parent.onFollow(rows[table.clickedRow])
        }

        func copySelection() { copyRows(.plain) }

        /// The selected rows in the visible columns, in their on-screen order.
        func copyRows(_ format: RowFormat) {
            guard let table else { return }
            let cols = table.tableColumns.filter { !$0.isHidden && $0.identifier.rawValue != "issues" }
            let header = cols.map { $0.title }
            let body = table.selectedRowIndexes.map { i in cols.map { text(for: $0.identifier.rawValue, row: i, packet: rows[i]) } }
            copyText(format.render(header: header, rows: body))
        }

        // MARK: Menus

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            if menu === table.headerView?.menu {
                for col in table.tableColumns where !col.title.isEmpty && !col.identifier.rawValue.hasPrefix("custom:") {
                    menu.addItem(BlockItem(col.title, state: !col.isHidden) { col.isHidden.toggle() })
                }
                let custom = table.tableColumns.filter { $0.identifier.rawValue.hasPrefix("custom:") }
                if !custom.isEmpty {
                    menu.addItem(.separator())
                    for col in custom {
                        let field = String(col.identifier.rawValue.dropFirst(7))
                        menu.addItem(BlockItem("Remove “\(field)”") { [weak self] in self?.store.removeColumn(field) })
                    }
                }
                menu.addItem(.separator())
                menu.addItem(BlockItem("Add Column for a Field…") { [weak self] in self?.promptForColumn() })
                return
            }
            let clicked = table.clickedRow
            guard clicked >= 0, clicked < rows.count else { return }
            if !table.selectedRowIndexes.contains(clicked) {
                table.selectRowIndexes([clicked], byExtendingSelection: false)
            }
            let p = rows[clicked]
            let selected = store.selection.sorted()
            if let s = p.stream {
                menu.addItem(BlockItem("Follow \(s.proto.rawValue.uppercased()) Stream") { [weak self] in self?.parent.onFollow(p) })
            }
            if selected.count == 2 {
                menu.addItem(BlockItem("Compare Packets \(selected[0]) and \(selected[1])") { [weak self] in self?.parent.onCompare(selected) })
            }
            menu.addItem(.separator())
            let filters = NSMenu()
            if let s = p.stream { filters.addItem(BlockItem("This Conversation") { [weak self] in self?.store.applyAsFilter(s.filter) }) }
            let h = store.host(of: p)
            if !h.isEmpty { filters.addItem(BlockItem("Host \(h)") { [weak self] in self?.store.hostFilter = h }) }
            filters.addItem(BlockItem("Source \(p.source)") { [weak self] in self?.store.applyAsFilter(Self.addressFilter(p.source, side: "src")) })
            filters.addItem(BlockItem("Destination \(p.destination)") { [weak self] in self?.store.applyAsFilter(Self.addressFilter(p.destination, side: "dst")) })
            filters.addItem(BlockItem("Protocol \(ProtoFamily.of(p).title)") { [weak self] in self?.store.protocolFilter = [ProtoFamily.of(p)] })
            let filterItem = NSMenuItem(title: "Filter On", action: nil, keyEquivalent: "")
            filterItem.submenu = filters
            menu.addItem(filterItem)
            menu.addItem(.separator())
            let numbers = store.selection
            let highlight = NSMenu()
            for h in CaptureStore.Highlight.allCases {
                let item = BlockItem(h.title, state: store.mark(p.number).highlight == h) { [weak self] in self?.store.updateMarks(numbers) { $0.highlight = h } }
                item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [NSColor(h.color)]))
                highlight.addItem(item)
            }
            highlight.addItem(.separator())
            highlight.addItem(BlockItem("None") { [weak self] in self?.store.updateMarks(numbers) { $0.highlight = nil } })
            let hItem = NSMenuItem(title: "Highlight", action: nil, keyEquivalent: "")
            hItem.submenu = highlight
            menu.addItem(hItem)
            let struck = store.mark(p.number).struck
            menu.addItem(BlockItem(struck ? "Remove Strikethrough" : "Strike Through") { [weak self] in self?.store.updateMarks(numbers) { $0.struck = !struck } })
            menu.addItem(BlockItem(store.mark(p.number).comment.isEmpty ? "Add Comment…" : "Edit Comment…") { [weak self] in self?.parent.onComment(numbers.sorted()) })
            menu.addItem(.separator())
            let column = table.clickedColumn >= 0 ? table.tableColumns[table.clickedColumn] : nil
            if let column, column.identifier.rawValue != "issues" {
                let value = text(for: column.identifier.rawValue, row: clicked, packet: p)
                menu.addItem(BlockItem("Copy \(column.title.isEmpty ? "Value" : column.title)") { copyText(value) })
            }
            let copyAs = NSMenu()
            for f in RowFormat.allCases { copyAs.addItem(BlockItem(f.rawValue) { [weak self] in self?.copyRows(f) }) }
            let copyItem = NSMenuItem(title: "Copy Rows As", action: nil, keyEquivalent: "")
            copyItem.submenu = copyAs
            menu.addItem(copyItem)
        }

        private func promptForColumn() {
            let alert = NSAlert()
            alert.messageText = "Add a column"
            alert.informativeText = "Type a Wireshark field name, for example tcp.window_size or http.user_agent. In the Fields tab, right-click a field to add it directly."
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            input.placeholderString = "tcp.window_size"
            alert.accessoryView = input
            alert.addButton(withTitle: "Add Column")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = input
            if alert.runModal() == .alertFirstButtonReturn { store.addColumn(input.stringValue.trimmingCharacters(in: .whitespaces)) }
        }

        static func addressFilter(_ a: String, side: String) -> String {
            if a.contains(":") && a.split(separator: ":").count == 6 && a.count == 17 { return "eth.\(side) == \(a)" }
            return a.contains(":") ? "ipv6.\(side) == \(a)" : "ip.\(side) == \(a)"
        }
    }
}

// MARK: AppKit pieces

final class KagamiTableView: NSTableView {
    var copyHandler: (() -> Void)?
    @objc func copy(_ sender: Any?) { copyHandler?() }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(copy(_:)) ? !selectedRowIndexes.isEmpty : super.validateUserInterfaceItem(item)
    }
}

final class PacketRowView: NSTableRowView {
    var tint: NSColor? { didSet { needsDisplay = true } }
    var textTint: NSColor?
    var isUnseen = false { didSet { if oldValue != isUnseen { needsDisplay = true } } }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        // A selected row drops its protocol tint, so the bronze reads on TLS orange and HTTP yellow alike.
        if let tint, !isSelected { tint.setFill(); bounds.fill() }
        if isUnseen {
            NSColor(Color.kagami).setFill()
            NSBezierPath(ovalIn: NSRect(x: 5, y: bounds.midY - 3, width: 6, height: 6)).fill()
        }
    }

    /// Selection in bronze: a warm wash and a rule at the leading edge, text stays in its own colours.
    override func drawSelection(in dirtyRect: NSRect) {
        let bronze = NSColor(Color.bronze)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // Strong enough to stand apart from the warm TLS and HTTP row tints, and still clear in an inactive window.
        bronze.withAlphaComponent(isEmphasized ? (dark ? 0.5 : 0.42) : (dark ? 0.36 : 0.3)).setFill()
        bounds.fill()
        bronze.withAlphaComponent(isEmphasized ? 1 : 0.8).setFill()
        NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 3, height: bounds.height - 4), xRadius: 1.5, yRadius: 1.5).fill()
        // Hairlines top and bottom so a selected row reads as one band even between two tinted rows.
        bronze.withAlphaComponent(isEmphasized ? 0.7 : 0.45).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override var isEmphasized: Bool { didSet { needsDisplay = true } }
}

final class TextCell: NSTableCellView {
    let field = NSTextField(labelWithString: "")

    init(align: NSTextAlignment, mono: Bool) {
        super.init(frame: .zero)
        field.font = mono ? .monospacedSystemFont(ofSize: 11.5, weight: .regular) : .systemFont(ofSize: 12)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.alignment = align
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class ProtoCell: NSTableCellView {
    private let swatch = NSView()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 2
        swatch.layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [swatch, label] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 8),
            swatch.heightAnchor.constraint(equalToConstant: 8),
            label.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private var family = ProtoFamily.other

    func set(_ proto: String, family: ProtoFamily, textColor: NSColor?) {
        self.family = family
        label.stringValue = proto
        label.textColor = textColor ?? .labelColor
        paintSwatch()
        setAccessibilityLabel("\(proto), \(family.title)")
    }

    private func paintSwatch() {
        effectiveAppearance.performAsCurrentDrawingAppearance { swatch.layer?.backgroundColor = family.nsColor.cgColor }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paintSwatch()
    }
}

final class IssueCell: NSTableCellView {
    private let image = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        NSLayoutConstraint.activate([image.centerXAnchor.constraint(equalTo: centerXAnchor), image.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ issues: TCPIssues) {
        guard !issues.isEmpty else { image.image = nil; toolTip = nil; setAccessibilityLabel(nil); return }
        let name = issues.isSevere ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
        image.image = NSImage(systemSymbolName: name, accessibilityDescription: issues.labels.joined(separator: ", "))?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        image.contentTintColor = issues.isSevere ? .systemRed : .systemOrange
        toolTip = issues.labels.joined(separator: ", ")
        setAccessibilityLabel(toolTip)
    }
}

/// A menu item that runs a closure.
final class BlockItem: NSMenuItem {
    private let block: () -> Void
    init(_ title: String, state on: Bool? = nil, _ block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let on { state = on ? .on : .off }
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { block() }
}

/// Calls back after every layout pass, so the columns are refitted whenever the pane changes size
/// (window, sidebar, inspector), however that size change arrives.
final class FittingScrollView: NSScrollView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}
