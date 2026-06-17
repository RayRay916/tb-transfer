import SwiftUI
import AppKit

// MARK: - Model store locations

/// The local AI model stores TBTransfer knows how to survey and sync. Each maps
/// to a `~/`-relative directory that exists on every node of Ray's cluster.
/// `.exo` is the canonical weight store (and what Skulk's SKULK_MODELS_PATH +
/// `tbcluster.py --home skulk` target); `.mtplx` / `.lmstudio` are alternate
/// runtime stores you can push INTO for robustness (e.g. seed an MTPLX or LM
/// Studio box from an EXO copy without re-downloading from HF).
///
/// Stores differ in how they lay a model identity (`org/model`) onto disk, so
/// surveying + sending are **layout-aware**: the parser reads the identity out
/// of whatever shape the SOURCE store uses, and the packager rebuilds it in the
/// DESTINATION store's shape (flat ⇄ nested) — so an EXO copy lands correctly
/// in LM Studio and vice-versa.
enum ModelStore: String, CaseIterable, Identifiable {
    case exo, mtplx, lmstudio, huggingface
    var id: Self { self }

    /// On-disk layout of a model identity ("org/model") for this store:
    /// - `flat`:        one dir `org--model/` with the weight files inside (EXO, MTPLX).
    /// - `nested`:      two dirs `org/model/` (LM Studio's `publisher/repo/` tree).
    /// - `huggingface`: the HF hub cache — `models--org--model/snapshots/<hash>/`,
    ///   files symlinked into `blobs/`. Read-only (see `canBeDestination`).
    enum Layout { case flat, nested, huggingface }

    var layout: Layout {
        switch self {
        case .exo, .mtplx: .flat
        case .lmstudio:    .nested
        case .huggingface: .huggingface
        }
    }

    /// HF's hub cache is a content-addressed download cache (snapshots + blobs +
    /// refs) that `huggingface_hub` owns — you fan models OUT of it into
    /// runtimes, you don't hand-assemble repos INTO it. So it's offered as a
    /// source to survey/send-from, but never as a transfer destination.
    var canBeDestination: Bool { self != .huggingface }

    /// `~/`-relative store root. For destinations this is the remote rsync base
    /// (the `~` expands against the peer's `$HOME` at transfer time).
    var relativePath: String {
        switch self {
        case .exo:         ".exo/models"
        case .mtplx:       ".mtplx/models"
        case .lmstudio:    ".lmstudio/models"
        case .huggingface: ".cache/huggingface/hub"
        }
    }

    var label: String {
        switch self {
        case .exo:         "EXO  (.exo/models)"
        case .mtplx:       "MTPLX  (.mtplx/models)"
        case .lmstudio:    "LM Studio  (.lmstudio/models)"
        case .huggingface: "Hugging Face  (.cache/huggingface/hub)"
        }
    }

    var shortLabel: String {
        switch self {
        case .exo:         "EXO"
        case .mtplx:       "MTPLX"
        case .lmstudio:    "LM Studio"
        case .huggingface: "HF"
        }
    }

    /// Absolute local store root on THIS Mac.
    var localURL: URL {
        URL(fileURLWithPath: Peer.expandTildePath("~/\(relativePath)"))
    }

    /// **Packager.** Store-relative subpath where a model identity ("org/model")
    /// must land so it conforms to THIS store's on-disk shape. Inverse of the
    /// parser's identity extraction, so flat→nested and nested→flat round-trip.
    /// The transfer engine's push pre-flight `mkdir -p`s this full path, so the
    /// nested `org/model` directory pair is created remotely before files copy.
    /// (Only ever called for destinations, so `.huggingface` is unreachable; it
    /// falls back to flat to keep the switch total.)
    func subpath(for identity: String) -> String {
        switch layout {
        case .flat, .huggingface: identity.replacingOccurrences(of: "/", with: "--")
        case .nested:             identity
        }
    }
}

/// One model discovered in a local store, normalized to its canonical identity.
private struct ModelEntry: Identifiable, Hashable {
    let identity: String  // canonical "org/model" (layout-independent)
    let path: String      // absolute local dir holding this model's weight files
    var id: String { identity }
}

// MARK: - Model store sync tab

/// Surveys a local model store, lists the models present, and pushes selected
/// ones to the connected peer's matching store over Thunderbolt (16-stream
/// rsync). Layout-aware: retargeting the destination store (.exo / .mtplx /
/// .lmstudio) reconstructs each model into that store's on-disk shape (flat
/// `org--model/` ⇄ nested `org/model/`), so weights downloaded once can be
/// fanned out to every runtime regardless of how it lays models out.
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
                destRelativePath: destStore.relativePath
            ) { showProgress = false }
                .environment(app)
        }
        .onAppear {
            // Default the destination to mirror the source — except a read-only
            // source (HF cache) can't be a destination, so fall back to EXO.
            destStore = sourceStore.canBeDestination ? sourceStore : .exo
            scan()
        }
        .onChange(of: sourceStore) { _, _ in
            destStore = sourceStore.canBeDestination ? sourceStore : .exo
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
                                identity: model.identity,
                                size: sizes[model.identity],
                                isSelected: selection.contains(model.identity)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(model.identity) }
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
                selection = selection.count == models.count ? [] : Set(models.map(\.identity))
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
                    // HF cache is source-only — never a destination.
                    ForEach(ModelStore.allCases.filter(\.canBeDestination)) { store in
                        Text(store.shortLabel).tag(store)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                .help("Where on the peer the models land (~/\(destStore.relativePath))")
            }

            // Fan-out: push the selected models to EVERY online node's store at
            // once, so any node can load them locally (no per-node WiFi staging).
            Button {
                syncToAll()
            } label: {
                Label(syncAllLabel, systemImage: "square.stack.3d.up.fill")
            }
            .buttonStyle(.bordered)
            .disabled(!canSyncAll)
            .help("Push the selected models to EVERY online node's \(destStore.shortLabel) store over Thunderbolt — so any node loads them instantly, no staging.")

            Button {
                send()
            } label: {
                Label(sendLabel, systemImage: "paperplane.fill")
                    .frame(minWidth: 110)
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

    /// Every reachable peer — the targets for a fan-out sync.
    private var onlinePeers: [Peer] { app.peerStore.peers.filter(\.isOnline) }
    private var canSyncAll: Bool { !selection.isEmpty && !onlinePeers.isEmpty }
    private var syncAllLabel: String {
        let m = onlinePeers.count
        return "Sync All · \(m) node\(m == 1 ? "" : "s")"
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
            let entries = await Self.listModels(in: url, layout: store.layout)
            await MainActor.run {
                guard store == sourceStore else { return }  // store-switch race guard
                models = entries
                scanning = false
            }
            for entry in entries {
                let kb = await Self.dirSizeKB(entry.path)
                await MainActor.run {
                    guard store == sourceStore else { return }
                    sizes[entry.identity] = kb
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
        //
        // PACKAGER: the source path is wherever the model's files actually live
        // in the SOURCE store (flat or nested), and the destination subpath is
        // rebuilt for the DESTINATION store's layout via `dst.subpath(for:)`.
        // So a flat EXO `org--model` sent to LM Studio lands at nested
        // `org/model/`, and a nested LM Studio `org/model` sent to EXO lands at
        // flat `org--model/` — the engine's `mkdir -p` makes the nested pair.
        var ids: [UUID] = []
        for identity in selection.sorted() {
            guard let entry = models.first(where: { $0.identity == identity }) else { continue }
            let sourcePath = entry.path
            let destPath = "~/\(dst.relativePath)/\(dst.subpath(for: identity))"
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

    /// Fan-out: push each selected model to the matching store on EVERY online
    /// peer (one task per model per node). This is the "make it fast everywhere"
    /// action — once every node holds the complete model in its store, any
    /// single-/multi-node launch loads it locally with zero staging. Same
    /// layout-aware packager as `send()`; the engine serializes the tasks so the
    /// progress sheet fills node-by-node.
    private func syncToAll() {
        guard !selection.isEmpty, !onlinePeers.isEmpty else { return }
        let dst = destStore
        var ids: [UUID] = []
        for identity in selection.sorted() {
            guard let entry = models.first(where: { $0.identity == identity }) else { continue }
            let destPath = "~/\(dst.relativePath)/\(dst.subpath(for: identity))"
            for p in onlinePeers {
                let task = TransferTask(
                    peerID: p.id, direction: .push, sources: [entry.path], destination: destPath
                )
                app.transferEngine.enqueue(task, peer: p)
                ids.append(task.id)
            }
        }
        app.statusLine = "Syncing \(selection.count) model\(selection.count == 1 ? "" : "s") → \(onlinePeers.count) node\(onlinePeers.count == 1 ? "" : "s") (~/\(dst.relativePath))"
        inFlightTaskIDs = ids
        showProgress = true
        selection = []
    }

    // MARK: - Scanning helpers / parser (off the main actor)

    /// **Parser.** Survey `storeURL` and normalize every model to its canonical
    /// `org/model` identity regardless of the store's on-disk shape:
    /// - `flat`:   each `org--model/` dir is one model (identity = first `--`→`/`).
    /// - `nested`: each `publisher/repo/` dir pair is one model (identity =
    ///   `publisher/repo`); tolerates a rare publisher dir that holds weights
    ///   directly. A "model" must actually hold weights (config.json /
    ///   `*.safetensors` / index / `*.gguf`), so caches and stray folders drop.
    nonisolated private static func listModels(
        in storeURL: URL, layout: ModelStore.Layout
    ) async -> [ModelEntry] {
        await Task.detached(priority: .userInitiated) {
            let skip: Set<String> = ["caches", "cache", "outputs", ".cache"]
            var out: [ModelEntry] = []
            switch layout {
            case .flat:
                for dir in subdirectories(of: storeURL) where !skip.contains(dir.lastPathComponent) {
                    guard looksLikeModel(dir) else { continue }
                    out.append(ModelEntry(identity: identity(fromFlatName: dir.lastPathComponent),
                                          path: dir.path))
                }
            case .nested:
                for pub in subdirectories(of: storeURL) where !skip.contains(pub.lastPathComponent) {
                    // A publisher dir holding weights directly is an edge case;
                    // normally we descend one level to `publisher/repo`.
                    if looksLikeModel(pub) {
                        out.append(ModelEntry(identity: pub.lastPathComponent, path: pub.path))
                        continue
                    }
                    for repo in subdirectories(of: pub) where looksLikeModel(repo) {
                        out.append(ModelEntry(identity: "\(pub.lastPathComponent)/\(repo.lastPathComponent)",
                                              path: repo.path))
                    }
                }
            case .huggingface:
                // HF hub cache: each `models--org--model/` repo has its weights
                // under `snapshots/<commit>/` (files symlinked into `blobs/`).
                // Identity = org/model (strip the `models--` prefix, then the
                // usual first-`--`→`/`). datasets--/spaces-- repos are skipped.
                for repo in subdirectories(of: storeURL) {
                    let name = repo.lastPathComponent
                    guard name.hasPrefix("models--") else { continue }
                    guard let snapshot = huggingfaceSnapshot(in: repo),
                          looksLikeModel(snapshot) else { continue }
                    let flat = String(name.dropFirst("models--".count))
                    out.append(ModelEntry(identity: identity(fromFlatName: flat), path: snapshot.path))
                }
            }
            return out.sorted { $0.identity.localizedCaseInsensitiveCompare($1.identity) == .orderedAscending }
        }.value
    }

    /// Resolve the active snapshot directory of an HF cache repo (`models--…`).
    /// Prefers the commit `refs/main` points at; falls back to the
    /// most-recently-modified snapshot. nil if the repo has no usable snapshot.
    nonisolated private static func huggingfaceSnapshot(in repo: URL) -> URL? {
        let fm = FileManager.default
        let snaps = repo.appendingPathComponent("snapshots")
        if let raw = try? String(contentsOf: repo.appendingPathComponent("refs/main"), encoding: .utf8) {
            let hash = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = snaps.appendingPathComponent(hash)
            if !hash.isEmpty, fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return subdirectories(of: snaps).max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da < db
        }
    }

    /// `org--model` → `org/model`. Splits on the FIRST `--` only: HF org names
    /// never contain `--`, and a model name keeping its single dashes (and any
    /// rare embedded `--`) stays intact on the right side.
    nonisolated private static func identity(fromFlatName name: String) -> String {
        guard let r = name.range(of: "--") else { return name }
        return String(name[..<r.lowerBound]) + "/" + String(name[r.upperBound...])
    }

    nonisolated private static func subdirectories(of url: URL) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return [] }
        var out: [URL] = []
        for name in names where !name.hasPrefix(".") {
            let child = url.appendingPathComponent(name)
            var isDir: ObjCBool = false
            // fileExists FOLLOWS symlinks (unlike URL's .isDirectoryKey, which
            // reports the link itself as a non-directory). Many of Ray's models
            // are symlinks — LM Studio entries point into EXO / the HF cache —
            // so without this they'd be invisible to the scanner.
            if fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue {
                out.append(child)
            }
        }
        return out
    }

    /// A directory is a usable model only if it holds at least one REAL weight
    /// file — a `*.safetensors` or `*.gguf` that actually resolves. A lone
    /// `config.json`, or a broken blob symlink left behind after dedup / an
    /// HF `--local-dir` download, does NOT count — so metadata-only cache
    /// shells (which would fail to transfer) are filtered out. `fileExists`
    /// follows symlinks, so a working symlinked weight still qualifies.
    nonisolated private static func looksLikeModel(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        // Weight formats: safetensors (MLX/HF), gguf (llama.cpp), npz (older MLX,
        // e.g. whisper). config.json/index alone never qualify.
        for n in names where n.hasSuffix(".safetensors") || n.hasSuffix(".gguf") || n.hasSuffix(".npz") {
            if fm.fileExists(atPath: dir.appendingPathComponent(n).path) { return true }
        }
        return false
    }

    /// Directory size in KB via `du -skL` (fast; far quicker than walking the
    /// tree in Foundation for a 40-70 GB model dir). `-L` dereferences symlinks
    /// so a symlinked model (e.g. an LM Studio entry pointing into the HF cache)
    /// reports its real size, not the ~0-byte link — matching what rsync's `-L`
    /// will actually transfer.
    nonisolated private static func dirSizeKB(_ path: String) async -> Int64 {
        guard let result = try? await ShellRunner.run("/usr/bin/du", ["-skL", path], timeout: 30),
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
    let identity: String   // canonical "org/model" (already display-ready)
    let size: Int64?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .font(.system(size: 15))
            Image(systemName: "cube.fill")
                .foregroundStyle(.secondary)
            Text(identity)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(identity)
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
    let destRelativePath: String
    let onClose: () -> Void

    private func task(_ id: UUID) -> TransferTask? {
        app.transferEngine.activeTasks.first { $0.id == id }
            ?? app.transferEngine.completedTasks.first { $0.id == id }
            ?? app.transferHistory.entries.first { $0.id == id }
    }

    private var tasks: [TransferTask] { taskIDs.compactMap(task) }

    /// Distinct target nodes — drives whether this is a single Send or a Sync-All.
    private var peerIDs: [UUID] { Array(Set(tasks.map(\.peerID))) }
    private var modelCount: Int { Set(tasks.map { $0.sources.first ?? "" }).count }
    /// "Studio" for a single peer, "3 nodes" for a fan-out.
    private var targetLabel: String {
        if peerIDs.count == 1, let p = app.peerStore.peer(id: peerIDs[0]) { return p.displayName }
        return "\(peerIDs.count) node\(peerIDs.count == 1 ? "" : "s")"
    }
    private func nodeName(_ id: UUID) -> String { app.peerStore.peer(id: id)?.displayName ?? "peer" }

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
                        TaskProgressRow(task: t, nodeName: nodeName(t.peerID))
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
                Text("\(modelCount) model\(modelCount == 1 ? "" : "s") → \(targetLabel)")
                    .font(.headline)
                Text("~/\(destRelativePath)\(peerIDs.count > 1 ? " · \(taskIDs.count) transfers" : "")")
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
    let nodeName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(color)
                Text(filename).font(.callout).lineLimit(1).truncationMode(.middle)
                Text("→ \(nodeName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
