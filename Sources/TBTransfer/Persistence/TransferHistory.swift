import Foundation
import Observation

/// Persists the user's completed transfer history. Mirrors the `PeerStore`
/// design: JSON-on-disk, atomic writes, tolerant of a missing file.
///
/// API contract:
///   - `entries: [TransferTask]` — most recent first, capped at `maxEntries`.
///   - `load()` — read JSON from on-disk store; create empty if missing.
///   - `append(_:)` — prepend a task, trim, and save.
///   - `clear()` — drop everything and save (writes an empty array).
///   - `remove(id:)` — drop one entry by id and save.
///   - `save()` — private; writes JSON atomically.
///
/// Storage location: `~/Library/Application Support/TBTransfer/history.json`.
@Observable
@MainActor
final class TransferHistory {
    private(set) var entries: [TransferTask] = []

    /// Cap on the number of historical entries we keep on disk. Excess entries
    /// are trimmed off the tail (oldest first) whenever `append(_:)` is called.
    static let maxEntries = 200

    func load() {
        let url: URL
        do {
            url = try storageURL()
        } catch {
            logToStderr("TransferHistory.load: failed to resolve storage URL: \(error)")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            // No file yet — leave entries empty.
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loaded = try decoder.decode([TransferTask].self, from: data)
            // Defensive: trim in case a previous version wrote more than maxEntries.
            entries = Array(loaded.prefix(Self.maxEntries))
        } catch {
            logToStderr("TransferHistory.load: decode failed: \(error)")
            entries = []
        }
    }

    /// Prepend `task` to `entries`, trim to `maxEntries`, then persist.
    func append(_ task: TransferTask) {
        entries.insert(task, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
    }

    /// Drop everything and persist the empty list.
    func clear() {
        entries.removeAll()
        save()
    }

    /// Remove one entry by id and persist.
    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    private func save() {
        let url: URL
        do {
            url = try storageURL()
        } catch {
            logToStderr("TransferHistory.save: failed to resolve storage URL: \(error)")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            logToStderr("TransferHistory.save: write failed: \(error)")
        }
    }
}

// MARK: - Helpers

@MainActor
fileprivate func storageURL() throws -> URL {
    let fm = FileManager.default
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dir = base.appendingPathComponent("TBTransfer", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("history.json")
}

fileprivate func logToStderr(_ message: String) {
    let line = "[TransferHistory] \(message)\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}
