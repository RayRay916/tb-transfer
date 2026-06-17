import AppKit
import Foundation
import SwiftUI

/// Status-bar (top-right menulet) controller for TBTransfer.
///
/// Owns an `NSStatusItem` and:
///   - Renders an idle/active glyph plus aggregate throughput text in the button.
///   - Maintains a tooltip summarizing the current state.
///   - Hosts a per-peer menu for quick "Send file…" / "Send folder…" actions.
///   - Accepts dropped file URLs via a transparent `NSView` pinned to the button,
///     prompting the user to pick a target peer.
///   - Polls `AppState` every 500ms (cheap) to refresh display.
///
/// Lifecycle:
///   - `install()` is idempotent; calling it twice is a no-op after the first.
///   - `uninstall()` is safe even if `install()` was never called.
@MainActor
final class MenubarController {
    private let appState: AppState
    private var statusItem: NSStatusItem?
    private var dropView: MenubarDropView?
    private var refreshTimer: Timer?

    /// Cache of the last-rendered title so we don't spam attribute changes.
    private var lastRenderedTitle: String = ""

    // Fix for AUDIT bug 2: track menu open state and last-built signature so we
    // don't replace the live NSMenu (which dismisses it / breaks hover) and
    // don't allocate a fresh menu twice per second when nothing changed.
    fileprivate var menuIsOpen: Bool = false
    private var lastMenuSignature: MenuSignature?
    private lazy var menuDelegate: MenuDelegate = MenuDelegate(owner: self)

    /// Coarse-grained fingerprint of the inputs that affect the rendered menu.
    /// If two consecutive computations produce equal values, the menu is
    /// already up-to-date and we can skip the rebuild.
    private struct MenuSignature: Equatable {
        let peerIDs: [UUID]
        let onlineFlags: [Bool]
        let runningTaskIDs: [UUID]
        let summary: String
    }

    init(appState: AppState) {
        self.appState = appState
    }

    deinit {
        // Swift 6 strict concurrency: a nonisolated deinit cannot touch the
        // non-Sendable NSStatusItem / Timer stored properties of this MainActor
        // class. Callers are expected to invoke `uninstall()` explicitly (or via
        // the app's terminate hook) before the controller is released. If they
        // forget, the NSStatusItem will be removed by the system when the app
        // quits anyway, so this is best-effort.
    }

    // MARK: - Install / uninstall

    /// Creates the NSStatusItem, drop view, menu, and refresh timer.
    /// Idempotent: subsequent calls do nothing.
    func install() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        // Configure the button: SF Symbol image + (optional) trailing text.
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "bolt.horizontal.circle",
                accessibilityDescription: "TBTransfer"
            )
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.title = ""
            button.toolTip = "TBTransfer"

            // Pin a transparent NSView over the button so we can accept file drags.
            let drop = MenubarDropView(controller: self)
            drop.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(drop)
            NSLayoutConstraint.activate([
                drop.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                drop.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                drop.topAnchor.constraint(equalTo: button.topAnchor),
                drop.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            dropView = drop
        }

        // Attach the menu. A nil-menu would make the button send actions directly,
        // but we want left-click to open the menu.
        let initialMenu = buildMenu()
        initialMenu.delegate = menuDelegate
        item.menu = initialMenu
        lastMenuSignature = currentMenuSignature()

        // Drive periodic refresh of title/tooltip/menu while installed.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        // Initial render.
        refresh()
    }

    /// Removes the NSStatusItem and invalidates the refresh timer.
    /// Safe to call when `install()` was never invoked or after a previous uninstall.
    func uninstall() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        dropView = nil
        lastRenderedTitle = ""
        lastMenuSignature = nil
        menuIsOpen = false
    }

    // MARK: - Refresh display

    /// Recomputes the button title, tooltip, and rebuilds the menu from current state.
    fileprivate func refresh() {
        guard let item = statusItem, let button = item.button else { return }

        let running = appState.transferEngine.activeTasks.filter { $0.status == .running }
        let throughput = running.reduce(0.0) { $0 + ($1.throughputBytesPerSecond ?? 0) }
        let summary = currentSummary()

        // Title: empty when idle, " 1.2 MB/s" when transferring.
        let newTitle: String
        if running.isEmpty {
            newTitle = ""
        } else {
            newTitle = " " + Self.formatThroughput(throughput)
        }
        if newTitle != lastRenderedTitle {
            button.title = newTitle
            lastRenderedTitle = newTitle
        }

        button.toolTip = summary

        // Fix for AUDIT bug 2: title/tooltip are always safe to mutate, but
        // replacing `item.menu` while the user has it open dismisses the menu
        // or stomps on submenu hover state. Skip the rebuild while the menu is
        // open, and also skip when the menu signature hasn't changed (no point
        // allocating a fresh NSMenu twice per second when nothing varies).
        if menuIsOpen { return }
        let signature = currentMenuSignature(precomputedSummary: summary, runningTasks: running)
        if signature == lastMenuSignature { return }

        let rebuilt = buildMenu()
        rebuilt.delegate = menuDelegate
        item.menu = rebuilt
        lastMenuSignature = signature
    }

    /// Snapshot of the inputs that affect the rendered menu. Used to short-circuit
    /// the 500ms refresh when nothing has changed.
    private func currentMenuSignature(
        precomputedSummary: String? = nil,
        runningTasks: [TransferTask]? = nil
    ) -> MenuSignature {
        let peers = appState.peerStore.peers
        let running = runningTasks ?? appState.transferEngine.activeTasks.filter { $0.status == .running }
        return MenuSignature(
            peerIDs: peers.map(\.id),
            onlineFlags: peers.map(\.isOnline),
            runningTaskIDs: running.map(\.id),
            summary: precomputedSummary ?? currentSummary()
        )
    }

    /// Human-readable summary used in both tooltip and the menu header item.
    fileprivate func currentSummary() -> String {
        let onlineCount = appState.peerStore.peers.filter(\.isOnline).count
        let running = appState.transferEngine.activeTasks.filter { $0.status == .running }

        guard let first = running.first else {
            let peerWord = onlineCount == 1 ? "peer" : "peers"
            return "TBTransfer — \(onlineCount) \(peerWord) online, idle"
        }

        let verb = first.direction == .push ? "pushing" : "pulling"
        let name = first.sources.first.map { ($0 as NSString).lastPathComponent } ?? "(items)"
        let peerName = appState.peerStore.peer(id: first.peerID)?.displayName ?? "peer"
        let pct = Int((first.progressFraction * 100).rounded())
        return "TBTransfer — \(verb) \(name) to \(peerName) (\(pct)%)"
    }

    // MARK: - Menu construction

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 1. Header line.
        let header = NSMenuItem(title: currentSummary(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(.separator())

        // 2. Per-peer submenu.
        let peers = appState.peerStore.peers
        if peers.isEmpty {
            let empty = NSMenuItem(title: "No peers yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for peer in peers {
                let dot = peer.isOnline ? "● " : "○ "
                let item = NSMenuItem(
                    title: "\(dot)\(peer.displayName)",
                    action: nil,
                    keyEquivalent: ""
                )
                item.submenu = buildPeerSubmenu(for: peer)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // 3. Window + quit.
        let showWindow = NSMenuItem(
            title: "Show Main Window",
            action: #selector(MenubarActionTarget.showMainWindow(_:)),
            keyEquivalent: ""
        )
        showWindow.target = actionTarget
        menu.addItem(showWindow)

        let quit = NSMenuItem(
            title: "Quit TBTransfer",
            action: #selector(MenubarActionTarget.quit(_:)),
            keyEquivalent: "q"
        )
        quit.target = actionTarget
        menu.addItem(quit)

        return menu
    }

    private func buildPeerSubmenu(for peer: Peer) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let sendFile = NSMenuItem(
            title: "Send file…",
            action: #selector(MenubarActionTarget.sendFile(_:)),
            keyEquivalent: ""
        )
        sendFile.target = actionTarget
        sendFile.representedObject = PeerSelection(peerID: peer.id, kind: .file)
        sendFile.isEnabled = peer.isOnline
        submenu.addItem(sendFile)

        let sendFolder = NSMenuItem(
            title: "Send folder…",
            action: #selector(MenubarActionTarget.sendFolder(_:)),
            keyEquivalent: ""
        )
        sendFolder.target = actionTarget
        sendFolder.representedObject = PeerSelection(peerID: peer.id, kind: .folder)
        sendFolder.isEnabled = peer.isOnline
        submenu.addItem(sendFolder)

        submenu.addItem(.separator())

        let reveal = NSMenuItem(
            title: "Reveal Downloads in Finder (this Mac)",
            action: #selector(MenubarActionTarget.revealLocalInbox(_:)),
            keyEquivalent: ""
        )
        reveal.target = actionTarget
        reveal.representedObject = LocalInboxRequest(homeUsername: NSUserName())
        submenu.addItem(reveal)

        return submenu
    }

    // MARK: - Actions invoked by the menu

    fileprivate func sendFile(forPeer peerID: UUID, allowFolder: Bool) {
        guard let peer = appState.peerStore.peer(id: peerID) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = !allowFolder
        panel.canChooseDirectories = allowFolder
        panel.allowsMultipleSelection = !allowFolder
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            enqueuePush(urls: panel.urls, peer: peer)
        }
    }

    fileprivate func revealLocalInbox(homeUsername: String) {
        // The default drop target is ~/Downloads on THIS Mac. Use the running
        // user's real home (NSHomeDirectory) rather than reconstructing it from
        // a username, so it's correct regardless of account-name casing.
        let path = "\(NSHomeDirectory())/Downloads"
        // Best-effort: create the directory if it doesn't exist so Finder has something to show.
        try? FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true
        )
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    fileprivate func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            // SwiftUI WindowGroup titles its windows after the navigation title.
            // Match either the literal "TBTransfer" or any window whose title
            // contains it, since the user may have given a peer focus.
            if window.title == "TBTransfer" || window.title.contains("TBTransfer") {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
        // Fallback: bring whatever the first visible window is, if any.
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }

    fileprivate func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Drop handling

    /// Called from MenubarDropView when files are dropped on the status button.
    /// Pops up a transient NSMenu listing online peers; the chosen peer receives a push.
    fileprivate func handleDrop(urls: [URL]) {
        guard !urls.isEmpty else { return }

        let onlinePeers = appState.peerStore.peers.filter(\.isOnline)

        guard !onlinePeers.isEmpty else {
            appState.statusLine = "Drop received but no online peers."
            // Show a tiny disabled-only menu so the user gets feedback.
            let menu = NSMenu()
            let header = NSMenuItem(title: "No online peers", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            presentTransientMenu(menu)
            return
        }

        let menu = NSMenu()
        let header = NSMenuItem(
            title: "Send \(urls.count) item\(urls.count == 1 ? "" : "s") to…",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for peer in onlinePeers {
            let item = NSMenuItem(
                title: peer.displayName,
                action: #selector(MenubarActionTarget.sendDroppedURLs(_:)),
                keyEquivalent: ""
            )
            item.target = actionTarget
            item.representedObject = DropPayload(peerID: peer.id, urls: urls)
            menu.addItem(item)
        }

        presentTransientMenu(menu)
    }

    fileprivate func enqueueDrop(payload: DropPayload) {
        guard let peer = appState.peerStore.peer(id: payload.peerID) else { return }
        enqueuePush(urls: payload.urls, peer: peer)
    }

    private func enqueuePush(urls: [URL], peer: Peer) {
        let task = TransferTask(
            peerID: peer.id,
            direction: .push,
            sources: urls.map(\.path),
            destination: peer.defaultDropDirectory
        )
        appState.transferEngine.enqueue(task, peer: peer)
        appState.statusLine = "Queued push of \(urls.count) item(s) to \(peer.displayName)."
    }

    /// Show a one-shot menu under the status button (used for the drop peer-picker).
    private func presentTransientMenu(_ menu: NSMenu) {
        guard let button = statusItem?.button else { return }
        // popUpMenu(_:positioning:) below the button.
        let origin = NSPoint(x: 0, y: button.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: button)
    }

    // MARK: - Action target

    /// We can't make `MenubarController` itself the Objective-C target (Swift 6
    /// strict concurrency makes that awkward), so we route selector-based
    /// actions through a small NSObject subclass that holds a weak ref back.
    private lazy var actionTarget: MenubarActionTarget = MenubarActionTarget(owner: self)

    // MARK: - Throughput formatting

    /// Format a bytes-per-second value with 3 significant figures and unit suffix.
    /// Uses base-1024 (binary) units to match `ByteCountFormatter(.file)` used
    /// elsewhere in the UI — keeps the menubar number and the queue-view number
    /// agreeing for the same transfer.
    static func formatThroughput(_ bps: Double) -> String {
        guard bps > 0, bps.isFinite else { return "0 B/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var value = bps
        var idx = 0
        while value >= 1024.0, idx < units.count - 1 {
            value /= 1024.0
            idx += 1
        }
        let formatted: String
        if value >= 100 {
            formatted = String(format: "%.0f", value)
        } else if value >= 10 {
            formatted = String(format: "%.1f", value)
        } else {
            formatted = String(format: "%.2f", value)
        }
        return "\(formatted) \(units[idx])"
    }
}

// MARK: - Selector target shim

/// Glue object for #selector-based NSMenuItem actions. Holds a weak reference
/// to its owner so the controller can be released cleanly.
@MainActor
private final class MenubarActionTarget: NSObject {
    weak var owner: MenubarController?

    init(owner: MenubarController) {
        self.owner = owner
        super.init()
    }

    @objc func sendFile(_ sender: NSMenuItem) {
        guard let sel = sender.representedObject as? PeerSelection else { return }
        owner?.sendFile(forPeer: sel.peerID, allowFolder: false)
    }

    @objc func sendFolder(_ sender: NSMenuItem) {
        guard let sel = sender.representedObject as? PeerSelection else { return }
        owner?.sendFile(forPeer: sel.peerID, allowFolder: true)
    }

    @objc func revealLocalInbox(_ sender: NSMenuItem) {
        guard let req = sender.representedObject as? LocalInboxRequest else { return }
        owner?.revealLocalInbox(homeUsername: req.homeUsername)
    }

    @objc func showMainWindow(_ sender: NSMenuItem) {
        owner?.showMainWindow()
    }

    @objc func quit(_ sender: NSMenuItem) {
        owner?.quitApp()
    }

    @objc func sendDroppedURLs(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? DropPayload else { return }
        owner?.enqueueDrop(payload: payload)
    }
}

// MARK: - Represented-object payloads

/// Tag for a peer selection plus the picker mode (file vs folder).
private final class PeerSelection: NSObject {
    enum Kind { case file, folder }
    let peerID: UUID
    let kind: Kind
    init(peerID: UUID, kind: Kind) {
        self.peerID = peerID
        self.kind = kind
    }
}

private final class LocalInboxRequest: NSObject {
    let homeUsername: String
    init(homeUsername: String) { self.homeUsername = homeUsername }
}

private final class DropPayload: NSObject {
    let peerID: UUID
    let urls: [URL]
    init(peerID: UUID, urls: [URL]) {
        self.peerID = peerID
        self.urls = urls
    }
}

// MARK: - Drop view

/// Transparent overlay pinned to the NSStatusItem button that accepts dragged
/// file URLs. Sends them back to the controller via `handleDrop(urls:)`.
@MainActor
private final class MenubarDropView: NSView {
    private weak var controller: MenubarController?
    private var isHighlighted: Bool = false

    init(controller: MenubarController) {
        self.controller = controller
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for MenubarDropView")
    }

    // We want the underlying NSStatusBarButton to handle clicks; only intercept
    // events while a drag is in progress. Letting hitTest return nil here passes
    // mouse events through to the button beneath us — but drag events are still
    // routed to the registered drag types regardless of hit-testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFileURLs(in: sender) else { return [] }
        isHighlighted = true
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isHighlighted = false
        needsDisplay = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isHighlighted = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            isHighlighted = false
            needsDisplay = true
        }
        let pb = sender.draggingPasteboard
        guard let objs = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !objs.isEmpty else {
            return false
        }
        controller?.handleDrop(urls: objs)
        return true
    }

    private func hasFileURLs(in info: NSDraggingInfo) -> Bool {
        let pb = info.draggingPasteboard
        guard let types = pb.types else { return false }
        return types.contains(.fileURL)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHighlighted else { return }
        // Subtle border ring around the status button while a drop is hovering.
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                 xRadius: 4, yRadius: 4)
        NSColor.controlAccentColor.withAlphaComponent(0.75).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}

// MARK: - Menu open/close tracking

/// Fix for AUDIT bug 2: NSMenuDelegate shim that tracks whether the status-item
/// menu is currently being displayed. The refresh timer consults this flag and
/// skips rebuilding `item.menu` while the user has it open (which would
/// otherwise dismiss the menu or break submenu hover state).
///
/// `@MainActor` is correct here: NSMenu delegate callbacks are documented to
/// arrive on the main thread, and being MainActor-isolated lets us touch the
/// owner's `@MainActor`-isolated `menuIsOpen` flag directly.
@MainActor
private final class MenuDelegate: NSObject, NSMenuDelegate {
    private weak var owner: MenubarController?

    init(owner: MenubarController) {
        self.owner = owner
        super.init()
    }

    func menuWillOpen(_ menu: NSMenu) {
        owner?.menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        owner?.menuIsOpen = false
    }
}
