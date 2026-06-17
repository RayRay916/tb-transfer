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

    private var peer: Peer? {
        app.selectedPeerID.flatMap(app.peerStore.peer(id:))
    }

    var body: some View {
        // The model list is the single flexible element; the control bar and
        // action bar are pinned via safeAreaInset so they never get clipped or
        // overlapped when the window is resized (a plain VStack lets the List
        // over-claim height and push the action bar off the bottom edge).
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    controlBar
                    Divider()
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    actionBar
                }
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
        return "\(n) model\(n == 1 ? "" : "s")"
    }

    // MARK: Content (model list)

    @ViewBuilder
    private var content: some View {
        if !storeExists {
            ContentUnavailableView(
                "No \(sourceStore.shortLabel) store on this Mac",
                systemImage: "shippingbox",
                description: Text("~/\(sourceStore.relativePath) doesn't exist here. Pick another store above.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if models.isEmpty {
            ContentUnavailableView(
                scanning ? "Scanning…" : "No models found",
                systemImage: scanning ? "hourglass" : "tray",
                description: Text("~/\(sourceStore.relativePath) has no model folders.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                Section {
                    ForEach(models) { model in
                        ModelRow(
                            name: model.name,
                            size: sizes[model.name],
                            isSelected: selection.contains(model.name)
                        )
                        .tag(model.name)
                    }
                } header: {
                    HStack {
                        Text("Models in ~/\(sourceStore.relativePath)")
                        Spacer()
                        Button(selection.count == models.count ? "Deselect All" : "Select All") {
                            selection = selection.count == models.count
                                ? []
                                : Set(models.map(\.name))
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
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
        // Only allow when the peer's SSH path is healthy (or trusted-mode) —
        // mirrors the Send tab's effective gate without re-implementing it.
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
                // Guard against a store-switch race: ignore stale results.
                guard store == sourceStore else { return }
                models = entries
                scanning = false
            }
            // Size each model in the background (du is fast; fills in live).
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
        }
        let n = selection.count
        let route = dst == src ? dst.shortLabel : "\(src.shortLabel)→\(dst.shortLabel)"
        app.statusLine = "Queued \(n) model\(n == 1 ? "" : "s") → \(peer.displayName):~/\(dst.relativePath) [\(route)]"
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
            Image(systemName: "cube.fill")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
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
        .padding(.vertical, 2)
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
