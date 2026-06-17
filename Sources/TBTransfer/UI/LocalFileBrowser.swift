import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Finder-style browser for the local filesystem.
///
/// Shows entries of `currentPath` in a `Table`-style list with selection, double-click
/// to descend, drag-out support for file URLs, and a breadcrumb / quick-jump toolbar.
/// Selection uses `Set<URL>`; URLs are stable across reloads inside a single directory
/// (re-resolved each refresh) and double-click navigation is provided by an explicit
/// gesture so that selection semantics remain Finder-like.
struct LocalFileBrowser: View {
    /// Directory currently shown. External binding so the parent can persist navigation.
    @Binding var currentPath: URL

    /// Selected entries (files or directories). Uses absolute URLs.
    @Binding var selection: Set<URL>

    @State private var entries: [LocalEntry] = []
    @State private var showsHidden: Bool = false
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .onAppear(perform: reload)
        .onChange(of: currentPath) { _, _ in
            // New directory: reset selection and reload.
            selection.removeAll()
            reload()
        }
        .onChange(of: showsHidden) { _, _ in reload() }
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
                .disabled(currentPath.pathComponents.count <= 1)

                breadcrumb

                Spacer(minLength: 8)

                Toggle(isOn: $showsHidden) {
                    Image(systemName: showsHidden ? "eye" : "eye.slash")
                }
                .toggleStyle(.button)
                .help(showsHidden ? "Hide hidden files" : "Show hidden files")

                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
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
                        navigateToBreadcrumb(index: index)
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
            shortcutButton(label: "Home", systemImage: "house", url: FileManager.default.homeDirectoryForCurrentUser)
            shortcutButton(label: "Desktop", systemImage: "menubar.dock.rectangle", url: subdir("Desktop"))
            shortcutButton(label: "Downloads", systemImage: "arrow.down.circle", url: subdir("Downloads"))
            shortcutButton(label: "Documents", systemImage: "folder", url: subdir("Documents"))
            Spacer()
        }
        .font(.caption)
    }

    private func shortcutButton(label: String, systemImage: String, url: URL) -> some View {
        Button {
            currentPath = url
        } label: {
            Label(label, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func subdir(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let err = loadError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { reload() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if entries.isEmpty {
            ContentUnavailableView("Empty folder",
                                   systemImage: "folder",
                                   description: Text(currentPath.path))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            entriesTable
        }
    }

    private var entriesTable: some View {
        Table(of: LocalEntry.self, selection: $selection) {
            TableColumn("Name") { entry in
                HStack(spacing: 6) {
                    Image(nsImage: iconFor(url: entry.url))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    open(entry: entry)
                }
                // Drag the single row URL. SwiftUI's `Transferable` for `[URL]` is not
                // available across versions; multi-selection drag-out is left to the
                // future Finder-multi-drag NSItemProvider path.
                .draggable(entry.url)
            }
            TableColumn("Size") { entry in
                Text(entry.isDirectory ? "—" : formatSize(entry.size))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 90)
            TableColumn("Modified") { entry in
                Text(formatDate(entry.mtime))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)
            TableColumn("Kind") { entry in
                Text(entry.kindLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 80, ideal: 120)
        } rows: {
            ForEach(entries) { entry in
                TableRow(entry)
            }
        }
    }

    // MARK: - Navigation

    private struct Crumb: Hashable { let url: URL; let label: String }

    private var breadcrumbComponents: [Crumb] {
        let components = currentPath.pathComponents
        guard !components.isEmpty else { return [] }
        var crumbs: [Crumb] = []
        var accumulated: URL = URL(fileURLWithPath: "/")
        for (i, comp) in components.enumerated() {
            if i == 0 {
                // Root: "/" → show as "Macintosh HD"-ish "/".
                crumbs.append(Crumb(url: accumulated, label: "/"))
            } else {
                accumulated.appendPathComponent(comp)
                crumbs.append(Crumb(url: accumulated, label: comp))
            }
        }
        return crumbs
    }

    private func navigateToBreadcrumb(index: Int) {
        let crumbs = breadcrumbComponents
        guard index >= 0, index < crumbs.count else { return }
        currentPath = crumbs[index].url
    }

    private func goUp() {
        let parent = currentPath.deletingLastPathComponent()
        if parent.path != currentPath.path {
            currentPath = parent
        }
    }

    private func open(entry: LocalEntry) {
        guard entry.isDirectory else { return }
        currentPath = entry.url
    }

    // MARK: - Loading

    private func reload() {
        loadError = nil
        let path = currentPath
        let includeHidden = showsHidden
        do {
            let keys: [URLResourceKey] = [
                .fileSizeKey,
                .contentModificationDateKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .localizedTypeDescriptionKey,
            ]
            let opts: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
            let urls = try FileManager.default.contentsOfDirectory(
                at: path,
                includingPropertiesForKeys: keys,
                options: opts
            )

            var rows: [LocalEntry] = []
            rows.reserveCapacity(urls.count)
            for url in urls {
                let values = try? url.resourceValues(forKeys: Set(keys))
                let isDir = values?.isDirectory ?? false
                let isLink = values?.isSymbolicLink ?? false
                let size = Int64(values?.fileSize ?? 0)
                let mtime = values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
                let kindLabel = values?.localizedTypeDescription
                    ?? (isLink ? "Symbolic Link" : (isDir ? "Folder" : "File"))

                rows.append(LocalEntry(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: isDir,
                    isSymlink: isLink,
                    size: size,
                    mtime: mtime,
                    kindLabel: kindLabel
                ))
            }

            rows.sort(by: localEntryOrder)
            entries = rows
        } catch {
            entries = []
            loadError = "Couldn't read \(path.path):\n\(error.localizedDescription)"
        }
    }

    // MARK: - Icon

    private func iconFor(url: URL) -> NSImage {
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.size = NSSize(width: 16, height: 16)
        return img
    }
}

// MARK: - Entry model

/// One row in the local directory listing.
private struct LocalEntry: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64
    let mtime: Date
    let kindLabel: String

    var id: URL { url }
}

private func localEntryOrder(_ a: LocalEntry, _ b: LocalEntry) -> Bool {
    if a.isDirectory != b.isDirectory {
        return a.isDirectory && !b.isDirectory
    }
    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
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
    @State private var path: URL = FileManager.default.homeDirectoryForCurrentUser
    @State private var sel: Set<URL> = []
    var body: some View {
        LocalFileBrowser(currentPath: $path, selection: $sel)
    }
}
