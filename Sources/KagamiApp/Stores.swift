import AppKit
import KagamiCore
import SwiftUI

/// Every open capture window's store, by window id. Follow and Diff windows find their capture
/// here, and files opened from Finder go to an empty window or a new tab.
@MainActor
final class Stores {
    static let shared = Stores()

    private var stores: [UUID: CaptureStore] = [:]
    private var windows: [ObjectIdentifier: NSWindow] = [:]
    var openWindow: OpenWindowAction?
    var appliedArguments = false
    /// The next capture window opens on its own instead of as a tab (⌘N).
    private var nextIsSeparate = false
    /// Follow/Diff/Endpoints windows without a known capture share one empty store.
    private static let orphan = UUID()



    /// Follow, Diff and Endpoints windows look up their capture without creating one: once the
    /// capture window has closed they get an empty, unregistered store.
    func existing(_ id: UUID?) -> CaptureStore {
        id.flatMap { stores[$0] } ?? Self.closedStore
    }
    private static let closedStore = CaptureStore()

    /// Files opened before the first window exists (a double-click while Kagami is closed).
    private var pending: [URL] = []

    /// Called by each capture window as it appears: the first takes the queued files.
    func windowReady(_ store: CaptureStore) {
        let queued = pending
        pending = []
        for url in queued {
            if store.source == .none { store.open(url) } else { open(url) }
        }
    }

    func store(_ id: UUID?) -> CaptureStore {
        let key = id ?? Self.orphan
        if let s = stores[key] { return s }
        let s = CaptureStore()
        s.windowID = key
        stores[key] = s
        return s
    }

    /// Ties a window to its store, and tabs it into the key window when ⌘T asked for a tab.
    func attach(_ window: NSWindow, to store: CaptureStore) {
        if windows[ObjectIdentifier(store)] !== window {
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, weak store] _ in
                MainActor.assumeIsolated { if let id = store?.windowID { self?.release(id) } }
            }
        }
        windows[ObjectIdentifier(store)] = window
        window.tabbingIdentifier = "KagamiCapture"
        // A capture lives in memory: AppKit must not bring an empty copy of this window back after a crash or kill.
        window.isRestorable = false
        // New capture windows join the frontmost one as tabs, like a browser; ⌘N opts out once.
        // SwiftUI shows the window before we see it, so it is tabbed in by hand.
        let separate = nextIsSeparate
        nextIsSeparate = false
        if !separate, window.tabbedWindows == nil,
           let front = NSApp.orderedWindows.first(where: { $0 !== window && $0.isVisible && $0.tabbingIdentifier == "KagamiCapture" }) {
            front.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Called when a capture window closes (not when its tab is merely hidden): stops and frees its capture.
    func release(_ id: UUID) {
        guard let s = stores[id] else { return }
        s.stop()
        s.close()
        windows[ObjectIdentifier(s)] = nil
        stores[id] = nil
    }

    func stopAll() { for s in stores.values { s.stop() } }

    func newWindow(tabbed: Bool) {
        nextIsSeparate = !tabbed
        openWindow?(id: "capture", value: UUID())
    }

    /// Opens a file in the frontmost empty window, or in a new tab.
    func open(_ url: URL) {
        guard openWindow != nil else { pending.append(url); return }
        let key = NSApp.keyWindow
        if let s = stores.values.first(where: { windows[ObjectIdentifier($0)] === key && $0.source == .none })
            ?? stores.values.first(where: { $0.source == .none && windows[ObjectIdentifier($0)]?.isVisible == true }) {
            s.open(url)
            return
        }
        let id = UUID()
        store(id).open(url)
        openWindow?(id: "capture", value: id)
    }

    func openPanel(from store: CaptureStore?) {
        let panel = NSOpenPanel()
        // Any file: Wireshark reads dozens of capture formats, and nfdump's files have no extension.
        panel.allowedContentTypes = []
        panel.canChooseDirectories = true  // a folder of nfcapd files reads as one
        panel.allowsMultipleSelection = true
        panel.message = "Choose captures or flow exports (pcap, pcapng, nfdump, CSV, JSON, Zeek conn.log). Each opens in its own tab."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let store, store.source == .none { store.open(url) } else { open(url) }
        }
    }
}

/// Hands the hosting NSWindow to a closure once the view is in a window.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
