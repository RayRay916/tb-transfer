import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum DetailMode: String, CaseIterable, Identifiable {
    case send, browse, models, queue, mirror, benchmark
    var id: Self { self }
    var label: String {
        switch self {
        case .send:      "Send"
        case .browse:    "Browse"
        case .models:    "Models"
        case .queue:     "Queue & History"
        case .mirror:    "Mirror"
        case .benchmark: "Benchmark"
        }
    }
    var icon: String {
        switch self {
        case .send:      "paperplane.fill"
        case .browse:    "folder.fill"
        case .models:    "shippingbox.fill"
        case .queue:     "list.bullet.rectangle"
        case .mirror:    "arrow.triangle.2.circlepath"
        case .benchmark: "speedometer"
        }
    }
}

extension Notification.Name {
    static let tbtPairPeer = Notification.Name("com.tbtransfer.pairPeer")
}

struct MainWindow: View {
    @Environment(AppState.self) private var app
    @State private var detailMode: DetailMode = .send
    @State private var peerToPair: Peer?
    @State private var peerToRename: Peer?
    @State private var peerToForget: Peer?

    var body: some View {
        @Bindable var bindable = app
        // Status bar lives as a real VStack sibling BELOW the split view (not a
        // .safeAreaInset on the NavigationSplitView) — the inset version did not
        // reserve space in the detail column, so a full-width bottom bar in the
        // detail (e.g. the Models tab's Send bar) rendered UNDER the status bar
        // and clipped. As a sibling, the status bar reserves its height and the
        // detail content always stays above it.
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            } detail: {
                detailContent
            }
            .navigationTitle("TBTransfer")
            .toolbar { toolbarItems }
            Divider()
            statusBar
        }
        .onReceive(NotificationCenter.default.publisher(for: .tbtPairPeer)) { note in
            if let peerID = note.object as? UUID, let peer = app.peerStore.peer(id: peerID) {
                peerToPair = peer
            }
        }
        .sheet(item: $peerToRename) { peer in
            RenamePeerSheet(peer: peer) { newLabel in
                var updated = peer
                updated.label = newLabel
                app.peerStore.upsert(updated)
                app.statusLine = "Renamed to \(newLabel)"
            }
        }
        .sheet(item: $peerToPair) { peer in
            PairPeerSheet(
                isPresented: Binding(
                    get: { peerToPair != nil },
                    set: { if !$0 { peerToPair = nil } }
                ),
                peer: peer,
                onSuccess: { username, keyPath, remoteHome in
                    var updated = peer
                    updated.sshUsername = username
                    updated.sshKeyPath = keyPath
                    updated.remoteHome = remoteHome
                    app.peerStore.upsert(updated)
                    app.statusLine = remoteHome.map { "Paired \(peer.displayName) — home \($0)" }
                        ?? "Paired \(peer.displayName)"
                    // Re-probe immediately so the dot flips green without waiting for the 30s tick.
                    Task { await app.probeSSH(peerID: updated.id) }
                }
            )
        }
        .confirmationDialog(
            peerToForget.map { "Forget \($0.displayName)?" } ?? "Forget peer?",
            isPresented: Binding(
                get: { peerToForget != nil },
                set: { if !$0 { peerToForget = nil } }
            ),
            titleVisibility: .visible,
            presenting: peerToForget
        ) { peer in
            Button("Forget & Delete SSH Key", role: .destructive) {
                Task { await app.forgetPeer(peer) }
            }
            Button("Cancel", role: .cancel) { peerToForget = nil }
        } message: { peer in
            Text("Deletes the dedicated SSH key for \(peer.displayName), removes "
                 + "this Mac's access from it, and clears all saved settings. "
                 + "Reconnecting will require pairing from scratch.")
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        @Bindable var bindable = app
        List(selection: $bindable.selectedPeerID) {
            Section("Peers") {
                if app.peerStore.peers.isEmpty {
                    Label("Scanning…", systemImage: "magnifyingglass")
                        .foregroundStyle(.secondary)
                }
                ForEach(app.peerStore.peers) { peer in
                    PeerRow(peer: peer, health: app.sshHealth[peer.id])
                        .tag(peer.id)
                        .contextMenu {
                            Button {
                                peerToRename = peer
                            } label: {
                                Label("Rename…", systemImage: "pencil")
                            }
                            Button {
                                peerToPair = peer
                            } label: {
                                Label("Pair SSH…", systemImage: "key.fill")
                            }
                            Button {
                                Task { await app.probeSSH(peerID: peer.id) }
                            } label: {
                                Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                            }
                            Divider()
                            // Trusted mode toggle. Shows a checkmark when on.
                            Button {
                                var updated = peer
                                updated.trustedMode.toggle()
                                app.peerStore.upsert(updated)
                                app.statusLine = updated.trustedMode
                                    ? "Trusted mode ON for \(updated.displayName) — transfers will skip encryption."
                                    : "Trusted mode OFF for \(updated.displayName)."
                            } label: {
                                Label(
                                    peer.trustedMode
                                        ? "Trusted Mode  ✓  (no encryption)"
                                        : "Enable Trusted Mode (no encryption)",
                                    systemImage: peer.trustedMode ? "bolt.shield.fill" : "bolt.shield"
                                )
                            }
                            Divider()
                            Button(role: .destructive) {
                                peerToForget = peer
                            } label: {
                                Label("Forget Peer", systemImage: "trash")
                            }
                        }
                }
            }
            Section("Thunderbolt") {
                ForEach(app.interfaceMonitor.interfaces) { iface in
                    InterfaceRow(iface: iface)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $detailMode) {
                ForEach(DetailMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)
            Divider()
            switch detailMode {
            case .send:
                if let id = app.selectedPeerID, let peer = app.peerStore.peer(id: id) {
                    TransferPanel(peer: peer)
                } else {
                    placeholder("Pick a peer in the sidebar to send to.")
                }
            case .browse:
                BrowseTab()
            case .models:
                ModelStoreTab()
            case .queue:
                TransferQueueView()
            case .mirror:
                MirrorTab()
            case .benchmark:
                BenchmarkTab()
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        ContentUnavailableView(
            text,
            systemImage: "rectangle.connected.to.line.below",
            description: Text("Use the sidebar to pick a peer.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar / status

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task {
                    await app.refresh()
                    await app.probeAllPeerSSH()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    private var statusBar: some View {
        let usable = app.interfaceMonitor.interfaces.filter(\.isUsable).count
        return HStack(spacing: 8) {
            Circle()
                .fill(app.peerStore.peers.contains(where: \.isOnline) ? .green : .secondary)
                .frame(width: 8, height: 8)
            Text(app.statusLine).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(usable) TB link\(usable == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Sidebar rows

private struct PeerRow: View {
    let peer: Peer
    let health: AppState.SSHHealth?

    var body: some View {
        HStack {
            Image(systemName: peer.isOnline ? "laptopcomputer" : "laptopcomputer.slash")
                .foregroundStyle(peer.isOnline ? .primary : .secondary)
            VStack(alignment: .leading) {
                Text(peer.displayName)
                if let iface = peer.lastSeenInterface, let ip = peer.lastSeenIP {
                    Text("\(iface) · \(ip)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            SSHHealthDot(isOnline: peer.isOnline, health: health)
        }
    }
}

/// Compact dot showing combined TB + SSH health. Tooltip gives the error.
struct SSHHealthDot: View {
    let isOnline: Bool
    let health: AppState.SSHHealth?

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)
            .help(tooltip)
            .accessibilityLabel(tooltip)
    }

    private var symbolName: String {
        guard isOnline else { return "circle" }
        switch health?.status {
        case .ok:                   return "circle.fill"
        case .remoteLoginDisabled:  return "exclamationmark.triangle.fill"
        case .notPaired:            return "key.slash.fill"
        case .unreachable:          return "circle.slash.fill"
        case .otherError:           return "exclamationmark.circle.fill"
        case .probing, .none:       return "circle.dotted"
        }
    }

    private var color: Color {
        guard isOnline else { return .secondary }
        switch health?.status {
        case .ok:                   return .green
        case .remoteLoginDisabled:  return .yellow
        case .notPaired:            return .orange
        case .unreachable:          return .red
        case .otherError:           return .red
        case .probing, .none:       return .gray
        }
    }

    private var tooltip: String {
        guard isOnline else { return "TB peer offline" }
        switch health?.status {
        case .ok:
            return "SSH OK"
        case .remoteLoginDisabled:
            return "Remote Login is OFF on the peer. Enable it in System Settings → General → Sharing on that Mac."
        case .notPaired:
            return "Not paired — right-click → Pair SSH…"
        case .unreachable:
            return health?.detail ?? "Peer unreachable"
        case .otherError:
            return health?.detail ?? "SSH error"
        case .probing, .none:
            return "Probing SSH…"
        }
    }
}

private struct InterfaceRow: View {
    let iface: TBInterface
    var body: some View {
        HStack {
            Image(systemName: iface.isUsable ? "bolt.fill" : "bolt.slash")
                .foregroundStyle(iface.isUsable ? .blue : .secondary)
            VStack(alignment: .leading) {
                Text(iface.hardwareName)
                Text("\(iface.name) · \(iface.localIP ?? "—")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Send tab (quick transfer for selected peer)

private struct TransferPanel: View {
    @Environment(AppState.self) private var app
    let peer: Peer

    @State private var direction: TransferTask.Direction = .push
    @State private var sourcePaths: [String] = []
    @State private var destinationPath: String = ""
    @State private var sheetTaskID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let banner = remediationBanner { banner }
            Divider()
            directionPicker
            sourcePicker
            destinationField
            Spacer()
            actionRow
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { await handleDrop(providers: providers) }
            return true
        }
        .onAppear { if destinationPath.isEmpty { destinationPath = peer.defaultDropDirectory } }
        .sheet(item: Binding(
            get: { sheetTaskID.map(IdentifiedUUID.init) },
            set: { sheetTaskID = $0?.id }
        )) { wrapped in
            TransferProgressSheet(taskID: wrapped.id) {
                sheetTaskID = nil
            }
            .environment(app)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer")
                    .font(.title2)
                    .foregroundStyle(peer.isOnline ? .primary : .secondary)
                Text(peer.displayName).font(.title2.bold())
                SSHHealthDot(isOnline: peer.isOnline, health: app.sshHealth[peer.id])
                    .font(.system(size: 14, weight: .bold))
                Text(healthLabel).font(.caption).foregroundStyle(healthColor)
                Spacer()
            }
            HStack(spacing: 12) {
                Label(peer.sshUsername, systemImage: "person.crop.circle")
                if let ip = peer.lastSeenIP, let iface = peer.lastSeenInterface {
                    Label("\(iface) \(ip)", systemImage: "bolt")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var healthLabel: String {
        guard peer.isOnline else { return "OFFLINE" }
        switch app.sshHealth[peer.id]?.status {
        case .ok:                   return "SSH OK"
        case .remoteLoginDisabled:  return "REMOTE LOGIN OFF"
        case .notPaired:            return "NOT PAIRED"
        case .unreachable:          return "UNREACHABLE"
        case .otherError:           return "SSH ERROR"
        case .probing, .none:       return "PROBING…"
        }
    }

    private var healthColor: Color {
        guard peer.isOnline else { return .secondary }
        switch app.sshHealth[peer.id]?.status {
        case .ok:                   return .green
        case .remoteLoginDisabled:  return .yellow
        case .notPaired:            return .orange
        case .unreachable, .otherError: return .red
        case .probing, .none:       return .gray
        }
    }

    /// Inline remediation banner when the selected peer's SSH probe failed.
    /// Returns nil for healthy / probing states so the caller can `if let` it.
    private var remediationBanner: AnyView? {
        let h = app.sshHealth[peer.id]
        guard peer.isOnline, let status = h?.status else { return nil }
        switch status {
        case .remoteLoginDisabled:
            return AnyView(banner(
                kind: .warning,
                title: "Remote Login is OFF on \(peer.displayName)",
                body: "SSH (port 22) refused the connection. On \(peer.displayName), open System Settings → General → Sharing → turn on Remote Login. Then click Test Again.",
                primary: ("Test Again", { Task { await app.probeSSH(peerID: peer.id) } }),
                secondary: ("Open Sharing on This Mac", {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.sharing") {
                        NSWorkspace.shared.open(url)
                    }
                })
            ))
        case .notPaired:
            return AnyView(banner(
                kind: .info,
                title: "SSH key not authorized on \(peer.displayName)",
                body: "Remote Login is on, but this Mac's public key isn't in \(peer.displayName)'s authorized_keys yet. Pair once and we won't ask again.",
                primary: ("Pair SSH…", {
                    NotificationCenter.default.post(name: .tbtPairPeer, object: peer.id)
                }),
                secondary: ("Test Again", { Task { await app.probeSSH(peerID: peer.id) } })
            ))
        case .unreachable:
            return AnyView(banner(
                kind: .warning,
                title: "Can't reach \(peer.displayName) on \(peer.lastSeenIP ?? "<no IP>")",
                body: h?.detail ?? "TCP timeout. Check the Thunderbolt cable, confirm the peer isn't asleep, and look at System Settings → Network → Thunderbolt Bridge on the peer.",
                primary: ("Test Again", { Task { await app.probeSSH(peerID: peer.id) } }),
                secondary: nil
            ))
        case .otherError:
            return AnyView(banner(
                kind: .warning,
                title: "SSH error on \(peer.displayName)",
                body: h?.detail ?? "Unclassified failure.",
                primary: ("Test Again", { Task { await app.probeSSH(peerID: peer.id) } }),
                secondary: nil
            ))
        case .ok, .probing:
            return nil
        }
    }

    private enum BannerKind { case warning, info }

    private func banner(
        kind: BannerKind,
        title: String,
        body: String,
        primary: (label: String, action: () -> Void),
        secondary: (label: String, action: () -> Void)?
    ) -> some View {
        let (icon, tint): (String, Color) = {
            switch kind {
            case .warning: ("exclamationmark.triangle.fill", .yellow)
            case .info:    ("key.fill", .orange)
            }
        }()
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(body).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(primary.label, action: primary.action)
                        .buttonStyle(.borderedProminent)
                    if let secondary {
                        Button(secondary.label, action: secondary.action)
                    }
                }
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.4)))
    }

    private var directionPicker: some View {
        Picker("Direction", selection: $direction) {
            Label("Send (push)", systemImage: "arrow.up.right.circle").tag(TransferTask.Direction.push)
            Label("Pull", systemImage: "arrow.down.left.circle").tag(TransferTask.Direction.pull)
        }
        .pickerStyle(.segmented)
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(direction == .push ? "Local sources" : "Remote sources").font(.headline)
                Spacer()
                if direction == .push {
                    Button("Choose…") { pickLocalSources() }
                }
            }
            if sourcePaths.isEmpty {
                Text(direction == .push
                     ? "Drop files here, paste with ⇧⌘V, or click Choose."
                     : "Switch to Browse tab for pull, or type remote paths below.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sourcePaths, id: \.self) { path in
                            Text(path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(maxHeight: 120)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            }
        }
    }

    private var destinationField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(direction == .push ? "Remote destination" : "Local destination").font(.headline)
            HStack {
                TextField("path", text: $destinationPath,
                          prompt: Text(direction == .push ? "~/some/remote/dir" : "~/some/local/dir"))
                    .textFieldStyle(.roundedBorder)
                if direction == .pull {
                    Button("Choose…") { pickLocalDestination() }
                }
            }
        }
    }

    private var actionRow: some View {
        HStack {
            Spacer()
            Button {
                startTransfer()
            } label: {
                Label("Start transfer", systemImage: "play.fill")
                    .frame(minWidth: 140)
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canStart)
            .buttonStyle(.borderedProminent)
        }
    }

    private var canStart: Bool {
        peer.isOnline && !sourcePaths.isEmpty && !destinationPath.isEmpty
    }

    private func pickLocalSources() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { sourcePaths = panel.urls.map(\.path) }
    }

    private func pickLocalDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.urls.first { destinationPath = url.path }
    }

    private func handleDrop(providers: [NSItemProvider]) async {
        var collected: [String] = []
        for provider in providers {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                collected.append(url.path)
            } else if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) {
                collected.append(url.path)
            }
        }
        if !collected.isEmpty { sourcePaths = collected }
    }

    private func startTransfer() {
        let task = TransferTask(
            peerID: peer.id,
            direction: direction,
            sources: sourcePaths,
            destination: destinationPath
        )
        app.transferEngine.enqueue(task, peer: peer)
        app.statusLine = "Started \(direction.rawValue) → \(peer.displayName)"
        sheetTaskID = task.id
    }
}

private struct IdentifiedUUID: Identifiable, Hashable {
    let id: UUID
}

// MARK: - Rename peer sheet

struct RenamePeerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let peer: Peer
    var onSave: (String) -> Void

    @State private var draft: String
    @FocusState private var fieldFocused: Bool

    init(peer: Peer, onSave: @escaping (String) -> Void) {
        self.peer = peer
        self.onSave = onSave
        _draft = State(initialValue: peer.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "pencil.circle.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rename peer").font(.headline)
                    Text(peer.lastKnownHostname.isEmpty ? "—" : peer.lastKnownHostname)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            TextField("Label", text: $draft, prompt: Text("e.g. Studio, Office Mac"))
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { commit() }
            Text("Custom labels persist across launches and aren't overwritten by discovery.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: commit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { fieldFocused = true }
    }

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        let value = trimmed
        guard !value.isEmpty else { return }
        onSave(value)
        dismiss()
    }
}

// MARK: - Mini progress sheet (shown immediately when Start is clicked)

private struct TransferProgressSheet: View {
    @Environment(AppState.self) private var app
    let taskID: UUID
    let onClose: () -> Void

    private var task: TransferTask? {
        app.transferEngine.activeTasks.first(where: { $0.id == taskID })
            ?? app.transferEngine.completedTasks.first(where: { $0.id == taskID })
            ?? app.transferHistory.entries.first(where: { $0.id == taskID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let task {
                header(task: task)
                progressBar(task: task)
                footer(task: task)
                Divider()
                buttonRow(task: task)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Starting transfer…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                HStack { Spacer(); Button("Close", action: onClose) }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func header(task: TransferTask) -> some View {
        let peer = app.peerStore.peer(id: task.peerID)
        return HStack(spacing: 10) {
            Image(systemName: task.direction == .push ? "arrow.up.right.circle.fill" : "arrow.down.left.circle.fill")
                .font(.title)
                .foregroundStyle(statusColor(task.status))
            VStack(alignment: .leading, spacing: 2) {
                Text(primaryFilename(task: task)).font(.headline).lineLimit(1).truncationMode(.middle)
                Text("\(task.direction.rawValue) → \(peer?.displayName ?? "peer")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(status: task.status)
        }
    }

    @ViewBuilder
    private func progressBar(task: TransferTask) -> some View {
        if task.status == .running || task.status == .queued {
            ProgressView(value: task.totalBytes > 0 ? task.progressFraction : nil)
                .progressViewStyle(.linear)
        } else if task.status == .completed {
            ProgressView(value: 1.0).progressViewStyle(.linear).tint(.green)
        } else {
            ProgressView(value: task.progressFraction).progressViewStyle(.linear).tint(.red)
        }
    }

    private func footer(task: TransferTask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(byteSummary(task: task))
                    .font(.callout.monospacedDigit())
                Spacer()
                Text(throughputString(task: task))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let err = task.error, !err.isEmpty {
                Text(err)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08)))
            }
        }
    }

    @ViewBuilder
    private func buttonRow(task: TransferTask) -> some View {
        HStack {
            if task.status == .failed || task.status == .cancelled {
                Button {
                    let peer = app.peerStore.peer(id: task.peerID)
                    if let peer {
                        let retry = TransferTask(
                            peerID: task.peerID,
                            direction: task.direction,
                            sources: task.sources,
                            destination: task.destination
                        )
                        app.transferEngine.enqueue(retry, peer: peer)
                    }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
            Spacer()
            if task.status == .running || task.status == .queued {
                Button(role: .destructive) {
                    app.transferEngine.cancel(id: task.id)
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                Button("Hide", action: onClose)
            } else {
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Formatting

    private func primaryFilename(task: TransferTask) -> String {
        let first = task.sources.first ?? ""
        let leaf = (first as NSString).lastPathComponent
        let extra = task.sources.count > 1 ? " (+\(task.sources.count - 1) more)" : ""
        return leaf.isEmpty ? "(no source)" : "\(leaf)\(extra)"
    }

    private func byteSummary(task: TransferTask) -> String {
        let bcf = ByteCountFormatter()
        bcf.countStyle = .file
        let cur = bcf.string(fromByteCount: task.bytesTransferred)
        if task.totalBytes > 0 {
            let total = bcf.string(fromByteCount: task.displayTotalBytes)
            let pct = Int((task.progressFraction * 100).rounded())
            return "\(cur) / \(total)  ·  \(pct)%"
        }
        return cur
    }

    private func throughputString(task: TransferTask) -> String {
        guard let bps = task.throughputBytesPerSecond, bps > 0 else { return "" }
        let bcf = ByteCountFormatter()
        bcf.countStyle = .file
        return "\(bcf.string(fromByteCount: Int64(bps)))/s"
    }

    private func statusColor(_ s: TransferTask.Status) -> Color {
        switch s {
        case .queued:    .secondary
        case .running:   .accentColor
        case .paused:    .orange
        case .completed: .green
        case .failed:    .red
        case .cancelled: .secondary
        }
    }
}

private struct StatusPill: View {
    let status: TransferTask.Status
    var body: some View {
        Text(status.rawValue.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
    private var color: Color {
        switch status {
        case .queued:    .secondary
        case .running:   .accentColor
        case .paused:    .orange
        case .completed: .green
        case .failed:    .red
        case .cancelled: .secondary
        }
    }
}

// MARK: - Browse tab (local + remote dual pane)

private struct BrowseTab: View {
    @Environment(AppState.self) private var app
    @State private var localPath = URL(fileURLWithPath: NSHomeDirectory())
    @State private var localSelection: Set<URL> = []
    @State private var remotePath: String = ""
    @State private var remoteSelection: Set<String> = []
    @State private var droppingOnRemote = false
    @State private var droppingOnLocal = false

    var body: some View {
        let peer = app.selectedPeerID.flatMap(app.peerStore.peer(id:))
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                paneHeader(title: "This Mac", icon: "laptopcomputer", isLocal: true)
                LocalFileBrowser(currentPath: $localPath, selection: $localSelection)
                    // Accept BOTH the batch UTI (what RemoteFileBrowser actually emits
                    // — always a `RemoteFileDragBatch`, even for single-row drags) AND
                    // the singular `RemoteFileDragPayload` UTI in case any other code
                    // path produces it. Order matters: list batch first so SwiftUI
                    // prefers it when both are advertised.
                    .onDrop(
                        of: [RemoteFileDragBatch.contentType, RemoteFileDragPayload.contentType],
                        isTargeted: $droppingOnLocal
                    ) { providers in
                        handleDropToLocal(providers: providers)
                        return true
                    }
                    .overlay(droppingOnLocal ? Color.accentColor.opacity(0.15) : Color.clear)
            }
            .frame(maxWidth: .infinity)
            Divider()
            VStack(spacing: 0) {
                paneHeader(title: peer?.displayName ?? "No peer selected", icon: peer?.isOnline == true ? "laptopcomputer" : "laptopcomputer.slash", isLocal: false)
                if let peer {
                    RemoteFileBrowser(
                        peer: peer,
                        currentPath: $remotePath,
                        selection: $remoteSelection
                    )
                    .onDrop(of: [.fileURL], isTargeted: $droppingOnRemote) { providers in
                        handleDropToRemote(providers: providers, peer: peer)
                        return true
                    }
                    .overlay(droppingOnRemote ? Color.accentColor.opacity(0.15) : Color.clear)
                    .onAppear {
                        if remotePath.isEmpty { remotePath = "~" }
                    }
                } else {
                    ContentUnavailableView(
                        "Pick a peer",
                        systemImage: "laptopcomputer.slash",
                        description: Text("Select a peer in the sidebar to browse its files.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func paneHeader(title: String, icon: String, isLocal: Bool) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func handleDropToRemote(providers: [NSItemProvider], peer: Peer) {
        Task {
            var paths: [String] = []
            for provider in providers {
                if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                    paths.append(url.path)
                } else if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                    paths.append(url.path)
                }
            }
            guard !paths.isEmpty else { return }
            let dest = remotePath.isEmpty ? peer.defaultDropDirectory : remotePath
            let task = TransferTask(peerID: peer.id, direction: .push, sources: paths, destination: dest)
            await MainActor.run {
                app.transferEngine.enqueue(task, peer: peer)
                app.statusLine = "Pushing \(paths.count) item(s) to \(peer.displayName):\(dest)"
            }
        }
    }

    private func handleDropToLocal(providers: [NSItemProvider]) {
        Task {
            var payloads: [RemoteFileDragPayload] = []
            for provider in providers {
                // Try the batch UTI first (what RemoteFileBrowser actually emits).
                if let data = try? await provider.loadItem(
                    forTypeIdentifier: RemoteFileDragBatch.contentType.identifier
                ) as? Data,
                   let batch = try? JSONDecoder().decode(RemoteFileDragBatch.self, from: data) {
                    payloads.append(contentsOf: batch.items)
                    continue
                }
                // Fall back to the singular UTI in case any path emits one.
                if let data = try? await provider.loadItem(
                    forTypeIdentifier: RemoteFileDragPayload.contentType.identifier
                ) as? Data,
                   let decoded = try? JSONDecoder().decode(RemoteFileDragPayload.self, from: data) {
                    payloads.append(decoded)
                }
            }
            guard !payloads.isEmpty,
                  let firstPeerID = payloads.first?.peerID,
                  let peer = app.peerStore.peer(id: firstPeerID) else { return }
            let sources = payloads.map(\.path)
            let dest = localPath.path
            let task = TransferTask(peerID: peer.id, direction: .pull, sources: sources, destination: dest)
            await MainActor.run {
                app.transferEngine.enqueue(task, peer: peer)
                app.statusLine = "Pulling \(sources.count) item(s) from \(peer.displayName) → \(dest)"
            }
        }
    }
}

// MARK: - Mirror tab (folder sync configs)

private struct MirrorTab: View {
    @Environment(AppState.self) private var app
    @State private var showAdd = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Folder mirrors").font(.headline)
                Spacer()
                Button {
                    showAdd = true
                } label: {
                    Label("Add Mirror…", systemImage: "plus")
                }
                .disabled(app.peerStore.peers.isEmpty)
            }
            .padding(12)
            Divider()
            if app.mirrorWatcher.configs.isEmpty {
                ContentUnavailableView(
                    "No mirrors",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("Mirror a local folder to a peer; changes propagate automatically with `--delete`.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(app.mirrorWatcher.configs) { cfg in
                        MirrorRow(cfg: cfg)
                    }
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddMirrorSheet(isPresented: $showAdd)
        }
    }
}

private struct MirrorRow: View {
    @Environment(AppState.self) private var app
    let cfg: MirrorConfig
    var body: some View {
        let peer = app.peerStore.peer(id: cfg.peerID)
        HStack(spacing: 12) {
            Image(systemName: cfg.enabled ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle")
                .foregroundStyle(cfg.enabled ? .green : .secondary)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(cfg.localPath).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Text("→ \(peer?.displayName ?? "?"):\(cfg.remotePath)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let err = cfg.lastError {
                    Text("⚠ \(err)").font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if let last = cfg.lastSyncAt {
                    Text("Last synced \(last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { cfg.enabled },
                set: { newVal in
                    app.mirrorWatcher.setEnabled(cfg.id, enabled: newVal) { app.peerStore.peer(id: $0) }
                }
            ))
            .labelsHidden()
            Button {
                Task { await app.mirrorWatcher.syncNow(cfg.id) { app.peerStore.peer(id: $0) } }
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(app.mirrorWatcher.inFlight.contains(cfg.id))
            Button {
                app.mirrorWatcher.remove(id: cfg.id)
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
        }
        .padding(.vertical, 4)
    }
}

private struct AddMirrorSheet: View {
    @Environment(AppState.self) private var app
    @Binding var isPresented: Bool
    @State private var localPath = ""
    @State private var peerID: UUID?
    @State private var remotePath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add folder mirror").font(.title3.bold())
            VStack(alignment: .leading, spacing: 4) {
                Text("Local folder").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("", text: $localPath, prompt: Text("~/Documents/sync"))
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.urls.first {
                            localPath = url.path
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Peer").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $peerID) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(app.peerStore.peers) { p in
                        Text(p.displayName).tag(UUID?.some(p.id))
                    }
                }
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Remote folder").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $remotePath, prompt: Text("~/Mirror"))
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Add") { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var canAdd: Bool {
        !localPath.isEmpty && peerID != nil && !remotePath.isEmpty
    }

    private func add() {
        guard let peerID, let peer = app.peerStore.peer(id: peerID) else { return }
        let cfg = MirrorConfig(localPath: localPath, peerID: peerID, remotePath: remotePath)
        app.mirrorWatcher.add(cfg, peer: peer)
        isPresented = false
    }
}

#Preview {
    MainWindow()
        .environment(AppState())
}
