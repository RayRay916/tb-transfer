import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Finder-style browser for a remote peer's filesystem.
///
/// Lists `currentPath` on `peer` via `SSHHelper.listDirectory`, reloading whenever
/// the peer or the path changes. Selection uses absolute remote paths so it stays
/// stable across renavigation. Rows are draggable as `RemoteFileDragPayload` (or a
/// homogeneous array of them when multi-selected) so drop targets can route the
/// drag back into a transfer task.
struct RemoteFileBrowser: View {
    let peer: Peer

    /// Absolute path currently shown. Caller persists navigation; default to
    /// `/Users/<peer.sshUsername>`.
    @Binding var currentPath: String

    /// Selected entries as absolute remote paths.
    @Binding var selection: Set<String>

    @State private var entries: [RemoteEntry] = []
    @State private var isLoading: Bool = false
    @State private var loadError: String?
    @State private var loadToken: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .task(id: TaskKey(peerID: peer.id, path: currentPath, token: loadToken)) {
            await loadIfPossible()
        }
        .onChange(of: currentPath) { _, _ in
            // New directory: reset selection.
            selection.removeAll()
        }
        .onChange(of: peer.id) { _, _ in
            selection.removeAll()
            currentPath = defaultHome
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    goUp()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .help("Up one folder")
                .disabled(currentPath == "/" || currentPath.isEmpty)

                breadcrumb

                Spacer(minLength: 8)

                Button {
                    loadToken &+= 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh listing")
            }

            shortcutRow
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(breadcrumbComponents.enumerated()), id: \.offset) { index, component in
                    Button {
                        currentPath = component.path
                    } label: {
                        Text(component.label)
                            .lineLimit(1)
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == breadcrumbComponents.count - 1 ? Color.primary : Color.accentColor)

                    if index < breadcrumbComponents.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var shortcutRow: some View {
        HStack(spacing: 8) {
            shortcutButton(label: "Home", systemImage: "house", target: defaultHome)
            shortcutButton(label: "Desktop", systemImage: "menubar.dock.rectangle", target: defaultHome + "/Desktop")
            shortcutButton(label: "Downloads", systemImage: "arrow.down.circle", target: defaultHome + "/Downloads")
            shortcutButton(label: "Documents", systemImage: "folder", target: defaultHome + "/Documents")
            Spacer()
            Text(peer.isOnline ? "ONLINE" : "OFFLINE")
                .font(.caption2.bold())
                .foregroundStyle(peer.isOnline ? .green : .secondary)
        }
        .font(.caption)
    }

    private func shortcutButton(label: String, systemImage: String, target: String) -> some View {
        Button {
            currentPath = target
        } label: {
            Label(label, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var defaultHome: String {
        // `~` is the remote user's home — works without knowing the remote
        // username, and the listDirectory script POSIX-expands it server-side.
        "~"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !peer.isOnline {
            ContentUnavailableView(
                "Peer offline",
                systemImage: "wifi.slash",
                description: Text("Reconnect \(peer.displayName) and try again.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isLoading && entries.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Listing \(currentPath)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = loadError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text("Couldn't list \(currentPath)")
                    .font(.headline)
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                Button("Retry") { loadToken &+= 1 }
                    .controlSize(.regular)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if entries.isEmpty {
            ContentUnavailableView("Empty folder",
                                   systemImage: "folder",
                                   description: Text(currentPath))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            entriesTable
        }
    }

    private var entriesTable: some View {
        Table(of: RowItem.self, selection: $selection) {
            TableColumn("Name") { row in
                HStack(spacing: 6) {
                    Image(systemName: row.systemImage)
                        .frame(width: 16, height: 16)
                        .foregroundStyle(row.iconColor)
                    Text(row.entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    open(row: row)
                }
                // Always drag a `RemoteFileDragBatch` (1-or-many) so the receiver can
                // decode a single type. Single drags produce a batch of one item.
                .draggable(batchTransferable(for: row))
            }
            TableColumn("Size") { row in
                Text(row.entry.kind == .dir ? "—" : formatSize(row.entry.size))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 90)
            TableColumn("Modified") { row in
                Text(formatDate(row.entry.mtime))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)
            TableColumn("Kind") { row in
                Text(row.kindLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 100)
        } rows: {
            ForEach(rowItems) { row in
                TableRow(row)
            }
        }
    }

    // MARK: - Row model

    private var rowItems: [RowItem] {
        entries.map { e in
            RowItem(
                absolutePath: joinedPath(currentPath, e.name),
                entry: e
            )
        }
    }

    /// One displayed row. `id` is the absolute path so selection lives in `Set<String>`.
    private struct RowItem: Identifiable, Hashable {
        let absolutePath: String
        let entry: RemoteEntry

        var id: String { absolutePath }

        var systemImage: String {
            switch entry.kind {
            case .dir: return "folder.fill"
            case .symlink: return "link"
            case .file: return "doc.fill"
            }
        }

        var iconColor: Color {
            switch entry.kind {
            case .dir: return .accentColor
            case .symlink: return .purple
            case .file: return .secondary
            }
        }

        var kindLabel: String {
            switch entry.kind {
            case .dir: return "Folder"
            case .symlink: return "Symbolic Link"
            case .file: return "File"
            }
        }
    }

    // MARK: - Drag

    /// Build a `RemoteFileDragBatch` (1-or-many) for the drag. If the row is part of
    /// the current multi-selection, drag every selected row; otherwise drag just this
    /// row. Always wrapping in a batch keeps the drag's `Transferable` type singular,
    /// which `.draggable` requires.
    private func batchTransferable(for row: RowItem) -> RemoteFileDragBatch {
        if selection.contains(row.absolutePath) && selection.count > 1 {
            let selected = rowItems.filter { selection.contains($0.absolutePath) }
            return RemoteFileDragBatch(items: selected.map(payload(for:)))
        }
        return RemoteFileDragBatch(items: [payload(for: row)])
    }

    private func payload(for row: RowItem) -> RemoteFileDragPayload {
        RemoteFileDragPayload(
            peerID: peer.id,
            path: row.absolutePath,
            isDirectory: row.entry.kind == .dir,
            displayName: row.entry.name
        )
    }

    // MARK: - Navigation

    private struct Crumb: Hashable { let path: String; let label: String }

    private var breadcrumbComponents: [Crumb] {
        let trimmed = currentPath.hasPrefix("/") ? currentPath : "/" + currentPath
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var out: [Crumb] = [Crumb(path: "/", label: "/")]
        var accumulated = ""
        for p in parts {
            accumulated += "/" + p
            out.append(Crumb(path: accumulated, label: p))
        }
        return out
    }

    private func goUp() {
        let trimmed = currentPath.hasPrefix("/") ? currentPath : "/" + currentPath
        let comps = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if comps.count <= 1 {
            currentPath = "/"
        } else {
            currentPath = "/" + comps.dropLast().joined(separator: "/")
        }
    }

    private func open(row: RowItem) {
        guard row.entry.kind == .dir else { return }
        currentPath = row.absolutePath
    }

    private func joinedPath(_ base: String, _ name: String) -> String {
        if base.hasSuffix("/") {
            return base + name
        } else {
            return base + "/" + name
        }
    }

    // MARK: - Loading

    /// Task identity so `.task(id:)` reruns on peer change, path change, or refresh.
    private struct TaskKey: Hashable {
        let peerID: UUID
        let path: String
        let token: Int
    }

    private func loadIfPossible() async {
        guard peer.isOnline else {
            entries = []
            isLoading = false
            loadError = nil
            return
        }
        isLoading = true
        loadError = nil
        do {
            let listed = try await SSHHelper.listDirectory(peer: peer, path: currentPath)
            // Fix for AUDIT bug 1: SSHHelper.listDirectory doesn't honor
            // Task.isCancelled, so a stale task from a prior peer/path can return
            // after the user switched away. Guard the assignment on both sides so
            // we never clobber the new peer's freshly-loaded entries with stale
            // results from the old one.
            guard !Task.isCancelled else { return }
            entries = listed
            guard !Task.isCancelled else { return }
            loadError = nil
        } catch {
            // Fix for AUDIT bug 1: same race applies to the error path.
            guard !Task.isCancelled else { return }
            entries = []
            loadError = error.localizedDescription
        }
        guard !Task.isCancelled else { return }
        isLoading = false
    }
}

// MARK: - Formatting

@MainActor private let _byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f
}()

@MainActor
fileprivate func formatSize(_ bytes: Int64) -> String {
    _byteFormatter.string(fromByteCount: bytes)
}

@MainActor private let _relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

@MainActor
fileprivate func formatDate(_ date: Date) -> String {
    let now = Date()
    let delta = now.timeIntervalSince(date)
    if delta >= 0 && delta < 7 * 24 * 3600 {
        return _relativeFormatter.localizedString(for: date, relativeTo: now)
    }
    return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
}

// MARK: - Preview

#Preview {
    StatePreview()
        .frame(width: 720, height: 480)
}

private struct StatePreview: View {
    @State private var path: String = "/Users/preview"
    @State private var sel: Set<String> = []

    private let samplePeer = Peer(
        label: "Sample Peer",
        lastKnownHostname: "preview.local",
        sshUsername: "preview"
    )

    var body: some View {
        RemoteFileBrowser(peer: samplePeer, currentPath: $path, selection: $sel)
    }
}
