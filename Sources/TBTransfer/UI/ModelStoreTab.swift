import SwiftUI
import AppKit

// MARK: - Model store locations

/// The local AI model stores TBTransfer knows how to survey and sync. Each maps
/// to a `~/`-relative directory that exists on every node of Ray's cluster.
/// `.exo` is the canonical weight store (and what Skulk's SKULK_MODELS_PATH +
/// `tbcluster.py --home skulk` target); `.mtplx` / `.mlxstudio` are alternate
/// runtime stores you can push INTO for robustness (e.g. seed an MTPLX or LM
/// Studio box from an EXO copy without re-downloading from HF).
enum ModelStore: String, CaseIterable, Identifiable {
    case exo, mtplx, mlxstudio
    var id: Self { self }

    /// `~/`-relative path, used as the remote rsync destination (the `~`
    /// expands against the peer's `$HOME` at transfer time).
    var relativePath: String {
        switch self {
        case .exo:       ".exo/models"
        case .mtplx:     ".mtplx/models"
        case .mlxstudio: ".mlxstudio/models"
        }
    }

    var label: String {
        switch self {
        case .exo:       "EXO  (.exo/models)"
        case .mtplx:     "MTPLX  (.mtplx/models)"
        case .mlxstudio: "LM Studio  (.mlxstudio/models)"
        }
    }

    var shortLabel: String {
        switch self {
        case .exo:       "EXO"
        case .mtplx:     "MTPLX"
        case .mlxstudio: "LM Studio"
        }
    }

    /// Absolute local directory on THIS Mac.
    var localURL: URL {
        URL(fileURLWithPath: Peer.expandTildePath("~/\(relativePath)"))
    }
}

/// One model directory discovered in a local store.
private struct ModelEntry: Identifiable, Hashable {
    let name: String      // directory name, e.g. "m5max--Huihui-...-oQ8-mtp"
    let path: String      // absolute local path
    var id: String { name }
}

// MARK: - Model store sync tab

/// Surveys a local model store, lists the models present, and pushes selected
/// ones to the connected peer's matching store over Thunderbolt (16-stream
/// rsync). Optionally retargets the destination store (.exo / .mtplx /
/// .mlxstudio) so weights downloaded once can be fanned out to every runtime.
struct ModelStoreTab: View {
    @Environment(AppState.self) private var app

    @State private var sourceStore: ModelStore = .exo
    @State private var destStore: ModelStore = .exo
    @State private var models: [ModelEntry] = []
    @State private var sizes: [String: Int64] = [:]
    @State private var selection: Set<String> = []
    @State private var scanning = false
    @State private var storeExists = true

    // Tracks the tasks enqueued by the most recent Send so the progress sheet
    // can show a live bar per model (mirrors the Send tab's progress sheet).
    @State private var inFlightTaskIDs: [UUID] = []
    @State private var showProgress = false

    private var peer: Peer? {
        app.selectedPeerID.flatMap(app.peerStore.peer(id:))
    }

    var body: some View {
        // Plain VStack with a ScrollView as the flexible middle. A ScrollView
        // (unlike List) cleanly yields height to its VStack siblings, so the
        // control bar and action bar keep their space and never clip when the
        // window is resized — the bug a List + safeAreaInset could not fix.
        VStack(spacing: 0) {
            controlBar
            Divider()
            listContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            actionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showProgress) {
            ModelSendProgressSheet(
                taskIDs: inFlightTaskIDs,
                peerName: peer?.displayName ?? "peer",
                destRelativePath: destStore.relativePath
            ) { showProgress = false }
                .environment(app)
        }
        .onAppear {
            // Default the destination to mirror the source the first time in.
            destStore = sourceStore
            scan()
        }
        .onChange(of: sourceStore) { _, _ in
            destStore = sourceStore
            scan()
        }
    }

    // MARK: Control bar (source store + refresh)

    private var controlBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill").foregroundStyle(.tint)
            Picker("Store", selection: $sourceStore) {
                ForEach(ModelStore.allCases) { store in
                    Text(store.label).tag(store)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)
            Spacer()
            if scanning { ProgressView().controlSize(.small) }
            Text(summaryText).font(.caption).foregroundStyle(.secondary)
            Button {
                scan()
            } label: { Image(systemName: "arrow.clockwise") }
                .help("Re-scan this store")
        }
        .padding(12)
        .background(.bar)
    }

    private var summaryText: String {
        guard storeExists else { return "store not found" }
        let n = models.count
        let sel = selection.count
        return sel > 0 ? "\(sel) of \(n) selected" : "\(n) model\(n == 1 ? "" : "s")"
    }

    // MARK: Content (model list — ScrollView for predictable layout)

    @ViewBuilder
    private var listContent: some View {
        if !storeExists {
            ContentUnavailableView(
                "No \(sourceStore.shortLabel) store on this Mac",
                systemImage: "shippingbox",
                description: Text("~/\(sourceStore.relativePath) doesn't exist here. Pick another store above.")
            )
        } else if models.isEmpty {
            ContentUnavailableView(
                scanning ? "Scanning…" : "No models found",
                systemImage: scanning ? "hourglass" : "tray",
                description: Text("~/\(sourceStore.relativePath) has no model folders.")
            )
        } else {
            VStack(spacing: 0) {
                listHeader
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(models) { model in
                            ModelRow(
                                name: model.name,
                                size: sizes[model.name],
                                isSelected: selection.contains(model.name)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(model.name) }
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var listHeader: some View {
        HStack {
            Text("Models in ~/\(sourceStore.relativePath)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button(selection.count == models.count ? "Deselect All" : "Select All") {
                selection = selection.count == models.count ? [] : Set(models.map(\.name))
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func toggle(_ name: String) {
        if selection.contains(name) { selection.remove(name) } else { selection.insert(name) }
    }

    // MARK: Action bar (destination store + send)

    private var actionBar: some View {
        HStack(spacing: 12) {
            if let peer, peer.isOnline {
                Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                Text(peer.displayName).font(.callout.weight(.medium))
                SSHHealthDot(isOnline: peer.isOnline, health: app.sshHealth[peer.id])
            } else {
                Image(systemName: "laptopcomputer.slash").foregroundStyle(.secondary)
                Text(peer == nil ? "No peer selected" : "Peer offline")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Spacer()

            // Destination store — defaults to the source store, but can be
            // retargeted to seed a different runtime ("robustness" option).
            HStack(spacing: 6) {
                Text("→").foregroundStyle(.secondary)
                Picker("Destination store", selection: $destStore) {
                    ForEach(ModelStore.allCases) { store in
                        Text(store.shortLabel).tag(store)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                .help("Where on the peer the models land (~/\(destStore.relativePath))")
            }

            Button {
                send()
            } label: {
                Label(sendLabel, systemImage: "paperplane.fill")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canSend)
        }
        .padding(12)
        .background(.bar)
    }

    private var sendLabel: String {
        let n = selection.count
        let bytes = selection.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
        if n == 0 { return "Send" }
        let sizeStr = bytes > 0 ? "  (\(byteString(bytes)))" : ""
        return "Send \(n)\(sizeStr)"
    }

    private var canSend: Bool {
        guard let peer, peer.isOnline, !selection.isEmpty else { return false }
        return true
    }

    // MARK: - Actions

    private func scan() {
        let store = sourceStore
        let url = store.localURL
        let exists = (try? url.checkResourceIsReachable()) ?? false
        storeExists = exists
        models = []
        sizes = [:]
        selection = []
        guard exists else { scanning = false; return }
        scanning = true
        Task {
            let entries = await Self.listModels(in: url)
            await MainActor.run {
                guard store == sourceStore else { return }  // store-switch race guard
                models = entries
                scanning = false
            }
            for entry in entries {
                let kb = await Self.dirSizeKB(entry.path)
                await MainActor.run {
                    guard store == sourceStore else { return }
                    sizes[entry.name] = kb
                }
            }
        }
    }

    private func send() {
        guard let peer, peer.isOnline, !selection.isEmpty else { return }
        let src = sourceStore
        let dst = destStore
        // One task per model: each lands in its OWN subdir, because the engine
        // copies a directory source's CONTENTS into the destination, so the
        // destination must be the per-model folder (mkdir -p'd by the push
        // pre-flight). Batching into one task can't do per-source destinations.
        var ids: [UUID] = []
        for name in selection.sorted() {
            let sourcePath = src.localURL.appendingPathComponent(name).path
            let destPath = "~/\(dst.relativePath)/\(name)"
            let task = TransferTask(
                peerID: peer.id,
                direction: .push,
                sources: [sourcePath],
                destination: destPath
            )
            app.transferEngine.enqueue(task, peer: peer)
            ids.append(task.id)
        }
        let n = selection.count
        let route = dst == src ? dst.shortLabel : "\(src.shortLabel)→\(dst.shortLabel)"
        app.statusLine = "Queued \(n) model\(n == 1 ? "" : "s") → \(peer.displayName):~/\(dst.relativePath) [\(route)]"
        // Show the live progress sheet (mirrors the Send tab) and clear selection.
        inFlightTaskIDs = ids
        showProgress = true
        selection = []
    }

    // MARK: - Scanning helpers (off the main actor)

    /// List model directories in `storeURL`. A "model" is any non-hidden
    /// subdirectory that actually holds weights — a `config.json`, a
    /// `*.safetensors` (or its index), or a `*.gguf`. Filters out caches and
    /// stray non-model folders so the list is just loadable models.
    nonisolated private static func listModels(in storeURL: URL) async -> [ModelEntry] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard let kids = try? fm.contentsOfDirectory(
                at: storeURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            var out: [ModelEntry] = []
            for url in kids {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDir else { continue }
                let name = url.lastPathComponent
                if name == "caches" || name == "cache" { continue }
                if looksLikeModel(url) {
                    out.append(ModelEntry(name: name, path: url.path))
                }
            }
            return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
    }

    nonisolated private static func looksLikeModel(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        for n in names {
            if n == "config.json" { return true }
            if n.hasSuffix(".safetensors") || n.hasSuffix(".safetensors.index.json") { return true }
            if n.hasSuffix(".gguf") { return true }
        }
        return false
    }

    /// Directory size in KB via `du -sk` (fast; far quicker than walking the
    /// tree in Foundation for a 40-70 GB model dir).
    nonisolated private static func dirSizeKB(_ path: String) async -> Int64 {
        guard let result = try? await ShellRunner.run("/usr/bin/du", ["-sk", path], timeout: 30),
              result.ok,
              let field = result.stdout.split(whereSeparator: \.isWhitespace).first,
              let kb = Int64(field) else { return 0 }
        return kb * 1024
    }

    private func byteString(_ bytes: Int64) -> String {
        let bcf = ByteCountFormatter()
        bcf.countStyle = .file
        return bcf.string(fromByteCount: bytes)
    }
}

// MARK: - Model row

private struct ModelRow: View {
    let name: String
    let size: Int64?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .font(.system(size: 15))
            Image(systemName: "cube.fill")
                .foregroundStyle(.secondary)
            Text(displayName)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(name)
            Spacer()
            if let size, size > 0 {
                Text(sizeString(size))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    /// Render the flattened `org--model` store name back as `org/model` for
    /// readability — that's how the cluster (HF ids, Skulk cards) refers to it.
    private var displayName: String {
        name.replacingOccurrences(of: "--", with: "/")
    }

    private func sizeString(_ bytes: Int64) -> String {
        let bcf = ByteCountFormatter()
        bcf.countStyle = .file
        return bcf.string(fromByteCount: bytes)
    }
}

// MARK: - Send progress sheet (one live bar per model)

/// Live transfer progress for a batch of model pushes — the Models-tab analog
/// of the Send tab's `TransferProgressSheet`. Pulls each task's state from the
/// engine (active → completed → history) so the bars track in real time. The
/// engine runs transfers serially, so models complete one at a time.
private struct ModelSendProgressSheet: View {
    @Environment(AppState.self) private var app
    let taskIDs: [UUID]
    let peerName: String
    let destRelativePath: String
    let onClose: () -> Void

    private func task(_ id: UUID) -> TransferTask? {
        app.transferEngine.activeTasks.first { $0.id == id }
            ?? app.transferEngine.completedTasks.first { $0.id == id }
            ?? app.transferHistory.entries.first { $0.id == id }
    }

    private var tasks: [TransferTask] { taskIDs.compactMap(task) }

    private var overallFraction: Double {
        let total = tasks.reduce(Int64(0)) { $0 + max($1.totalBytes, $1.bytesTransferred) }
        guard total > 0 else { return 0 }
        let done = tasks.reduce(Int64(0)) { $0 + $1.bytesTransferred }
        return min(1, max(0, Double(done) / Double(total)))
    }

    private var doneCount: Int { tasks.filter { $0.status == .completed }.count }
    private var anyActive: Bool { tasks.contains { $0.status == .running || $0.status == .queued } }
    private var allFinished: Bool {
        !tasks.isEmpty && tasks.allSatisfy { $0.status == .completed || $0.status == .failed || $0.status == .cancelled }
    }
    private var allSucceeded: Bool {
        !tasks.isEmpty && tasks.allSatisfy { $0.status == .completed }
    }
    private var overallTint: Color {
        allSucceeded ? .green : .accentColor
    }
    private var headerTint: Color {
        guard allFinished else { return .accentColor }
        return tasks.contains { $0.status == .failed } ? .red : .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ProgressView(value: overallFraction) {
                HStack {
                    Text("\(doneCount) of \(taskIDs.count) complete")
                    Spacer()
                    Text("\(Int((overallFraction * 100).rounded()))%").monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .tint(overallTint)
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(tasks) { t in
                        TaskProgressRow(task: t)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 260)
            Divider()
            buttonRow
        }
        .padding(20)
        .frame(width: 540)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.fill")
                .font(.title)
                .foregroundStyle(headerTint)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(taskIDs.count) model\(taskIDs.count == 1 ? "" : "s") → \(peerName)")
                    .font(.headline)
                Text("~/\(destRelativePath)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var buttonRow: some View {
        HStack {
            if anyActive {
                Button(role: .destructive) {
                    for t in tasks where t.status == .running || t.status == .queued {
                        app.transferEngine.cancel(id: t.id)
                    }
                } label: {
                    Label("Cancel All", systemImage: "xmark.circle")
                }
            }
            Spacer()
            Button(allFinished ? "Done" : "Hide", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// One model's progress row inside the send sheet.
private struct TaskProgressRow: View {
    let task: TransferTask

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(color)
                Text(filename).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(task.status.rawValue.capitalized)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
            }
            ProgressView(
                value: task.status == .completed ? 1.0 : task.progressFraction
            )
            .progressViewStyle(.linear)
            .tint(color)
            HStack {
                Text(byteSummary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if let bps = task.throughputBytesPerSecond, bps > 0, task.status == .running {
                    Text("\(byteStr(Int64(bps)))/s").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let err = task.error, !err.isEmpty, task.status == .failed {
                Text(err).font(.caption2.monospaced()).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
    }

    private var filename: String {
        let leaf = ((task.sources.first ?? "") as NSString).lastPathComponent
        return leaf.replacingOccurrences(of: "--", with: "/")
    }

    private var icon: String {
        switch task.status {
        case .completed: "checkmark.circle.fill"
        case .failed:    "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        case .running:   "arrow.up.circle.fill"
        default:         "clock"
        }
    }

    private var color: Color {
        switch task.status {
        case .completed: .green
        case .failed:    .red
        case .cancelled: .secondary
        case .running:   .accentColor
        default:         .secondary
        }
    }

    private var byteSummary: String {
        let cur = byteStr(task.bytesTransferred)
        if task.totalBytes > 0 {
            let pct = Int((task.progressFraction * 100).rounded())
            return "\(cur) / \(byteStr(task.displayTotalBytes))  ·  \(pct)%"
        }
        return cur
    }

    private func byteStr(_ b: Int64) -> String {
        let bcf = ByteCountFormatter()
        bcf.countStyle = .file
        return bcf.string(fromByteCount: b)
    }
}
