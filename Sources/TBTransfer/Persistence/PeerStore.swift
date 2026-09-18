import Foundation
import Observation

/// Persists the user-labelled set of known peers. Identity is the SSH host
/// fingerprint (stable), NOT the IP (ephemeral).
///
/// API contract used by `AppState`:
///   - `peers: [Peer]` — sorted by label.
///   - `load()` — read JSON from on-disk store; create empty if missing.
///   - `save()` — write JSON to on-disk store.
///   - `peer(id:)` — lookup by Peer.id.
///   - `upsert(_:)` — insert or update by id; saves.
///   - `remove(id:)` — delete by id; saves.
///   - `reconcile(with: DiscoveredPeer)` — match a discovered peer to an
///     existing Peer (by MAC fallback → hostname), update its lastSeen* fields,
///     OR insert a new Peer pre-filled with sensible defaults if no match.
///     Pre-fill rules for new peers — NO hardcoded usernames or keys. Every
///     new peer starts blank:
///       - label = hostname (or "Peer-<short-mac>" when unresolved)
///       - sshUsername = ""  → forces the Pair-SSH wizard to ask the user
///       - sshKeyPath  = nil → the wizard generates a dedicated per-peer key
///     The username and key are established entirely during provisioning and
///     re-established from scratch after a "Forget Peer".
///
/// Storage location: `~/Library/Application Support/TBTransfer/peers.json`.
@Observable
@MainActor
final class PeerStore {
    private(set) var peers: [Peer] = []

    func load() {
        let url: URL
        do {
            url = try storageURL()
        } catch {
            logToStderr("PeerStore.load: failed to resolve storage URL: \(error)")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            // No file yet — leave peers empty.
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loaded = try decoder.decode([Peer].self, from: data)
            peers = loaded.sorted { $0.label.lowercased() < $1.label.lowercased() }
            // Clean up any duplicates created by the pre-fix reconcile logic
            // (same hostname, different MAC because TB Bridge regenerated it).
            deduplicateByHostname()
        } catch {
            logToStderr("PeerStore.load: decode failed: \(error)")
            peers = []
        }
    }

    func save() {
        let url: URL
        do {
            url = try storageURL()
        } catch {
            logToStderr("PeerStore.save: failed to resolve storage URL: \(error)")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(peers)
            try data.write(to: url, options: .atomic)
        } catch {
            logToStderr("PeerStore.save: write failed: \(error)")
        }
    }

    func peer(id: UUID) -> Peer? {
        peers.first(where: { $0.id == id })
    }

    func upsert(_ peer: Peer) {
        if let idx = peers.firstIndex(where: { $0.id == peer.id }) {
            peers[idx] = peer
        } else {
            peers.append(peer)
        }
        peers.sort { $0.label.lowercased() < $1.label.lowercased() }
        save()
    }

    func remove(id: UUID) {
        peers.removeAll { $0.id == id }
        save()
    }

    /// Reconcile a WHOLE discovery pass at once. This is the entry point used by
    /// AppState each refresh, and is what makes port changes robust.
    ///
    /// The same physical Mac can surface as MULTIPLE discovered paths in one
    /// pass: when its cable moves to a different TB port (a lingering stale ARP
    /// entry on the old `enN` briefly overlaps the live entry on the new one),
    /// or when two cables genuinely connect the pair over two ports at once.
    /// Reconciling those paths one-by-one is last-writer-wins — the peer record
    /// can latch onto the DEAD port or flip-flop between live ports every 5s.
    ///
    /// Instead we group all paths by physical machine, pick ONE path
    /// deterministically (sticky to the port the record already uses, so a still-
    /// live port is never abandoned), and reconcile once per machine.
    func reconcile(batch discovered: [DiscoveredPeer]) {
        guard !discovered.isEmpty else { return }

        var groups: [String: [DiscoveredPeer]] = [:]
        var order: [String] = []
        for d in discovered {
            let key = discoveryIdentityKey(d)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(d)
        }

        for key in order {
            guard let candidates = groups[key] else { continue }
            let sticky = stickyInterface(forCandidates: candidates)
            if let chosen = selectDiscoveredPath(candidates, stickyInterface: sticky) {
                reconcile(with: chosen)
            }
        }
    }

    func reconcile(with discovered: DiscoveredPeer) {
        let now = Date()

        if let idx = indexOfMatchingPeer(for: discovered) {
            let before = peers[idx]
            var updated = before
            updated.lastSeenInterface = discovered.interfaceName
            updated.lastSeenIP = discovered.ipAddress
            updated.lastSeenAt = now
            updated.lastSeenMAC = discovered.macAddress
            // If the discovered hostname is non-empty and differs from what we
            // had, update it (e.g., a previously-unresolved entry now has its
            // real `.local` name). Don't touch the LABEL — that's user-set.
            if let dh = discovered.hostname, !dh.isEmpty,
               normalizeHostname(updated.lastKnownHostname) != normalizeHostname(dh) {
                updated.lastKnownHostname = dh
            }
            peers[idx] = updated
            // Persist ONLY when an identity-relevant field actually moved. The
            // lastSeenAt timestamp changes every 5s tick; saving on that alone
            // would thrash the disk + trigger needless UI churn, badly so for a
            // peer reachable over two live ports. lastSeenAt still updates in
            // memory above (keeps `isOnline` fresh); it's refreshed by discovery
            // on next launch, so not persisting each tick is harmless.
            if before.lastSeenInterface != updated.lastSeenInterface ||
               before.lastSeenIP != updated.lastSeenIP ||
               before.lastSeenMAC != updated.lastSeenMAC ||
               before.lastKnownHostname != updated.lastKnownHostname {
                save()
            }
            return
        }

        // No match — insert a new peer with pre-filled defaults.
        var newPeer = prefillForNewPeer(discovered: discovered)
        newPeer.lastSeenInterface = discovered.interfaceName
        newPeer.lastSeenIP = discovered.ipAddress
        newPeer.lastSeenAt = now
        newPeer.lastSeenMAC = discovered.macAddress
        peers.append(newPeer)
        peers.sort { $0.label.lowercased() < $1.label.lowercased() }
        save()
    }

    /// Index of the existing peer that `discovered` refers to, or nil.
    ///   PRIMARY: normalized hostname — the most stable, PORT-INDEPENDENT
    ///     identity (a cable moving to another port doesn't change it).
    ///   SECONDARY: MAC — only when the hostname is briefly unresolved (mDNS
    ///     race after wake/replug). Cable-swap stays safe: a different machine
    ///     on the port has a different hostname AND a different MAC.
    private func indexOfMatchingPeer(for discovered: DiscoveredPeer) -> Int? {
        if let dh = normalizeHostname(discovered.hostname), !dh.isEmpty {
            if let i = peers.firstIndex(where: {
                guard let ph = normalizeHostname($0.lastKnownHostname), !ph.isEmpty else { return false }
                return ph == dh
            }) {
                return i
            }
        }
        return peers.firstIndex(where: {
            guard let storedMAC = $0.lastSeenMAC, !storedMAC.isEmpty else { return false }
            return storedMAC == discovered.macAddress
        })
    }

    /// The interface an existing record for this group is currently using, if
    /// any. Used to keep path selection sticky across refreshes.
    private func stickyInterface(forCandidates candidates: [DiscoveredPeer]) -> String? {
        for c in candidates {
            if let i = indexOfMatchingPeer(for: c) {
                return peers[i].lastSeenInterface
            }
        }
        return nil
    }

    /// Collapse entries that share the same normalized hostname. Keep the most
    /// recently seen one (so we don't lose freshly-paired credentials), drop
    /// the rest. Used at `load()` time to clean up duplicates created by the
    /// pre-fix reconcile logic. Idempotent and safe to call any time.
    func deduplicateByHostname() {
        var seenByHostname: [String: Int] = [:]   // normalized hostname -> index in peers
        var indicesToDrop: [Int] = []
        for (i, peer) in peers.enumerated() {
            guard let host = normalizeHostname(peer.lastKnownHostname), !host.isEmpty else { continue }
            if let existing = seenByHostname[host] {
                // Keep the one with the more recent lastSeenAt.
                let existingDate = peers[existing].lastSeenAt ?? .distantPast
                let currentDate = peer.lastSeenAt ?? .distantPast
                if currentDate > existingDate {
                    indicesToDrop.append(existing)
                    seenByHostname[host] = i
                } else {
                    indicesToDrop.append(i)
                }
            } else {
                seenByHostname[host] = i
            }
        }
        guard !indicesToDrop.isEmpty else { return }
        // Remove highest indices first so earlier indices stay valid.
        for i in indicesToDrop.sorted(by: >) {
            peers.remove(at: i)
        }
        save()
    }
}

// MARK: - Helpers

@MainActor
fileprivate func storageURL() throws -> URL {
    let fm = FileManager.default
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dir = base.appendingPathComponent("TBTransfer", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("peers.json")
}

internal func normalizeHostname(_ raw: String?) -> String? {
    guard let raw else { return nil }
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while s.hasSuffix(".") {
        s.removeLast()
    }
    return s.isEmpty ? nil : s
}

/// Stable identity key for grouping discovered paths that belong to the SAME
/// physical machine within one discovery pass. Prefer the normalized hostname
/// (PORT-INDEPENDENT — survives a cable moving between TB ports); fall back to
/// the MAC only when the hostname hasn't resolved yet.
internal func discoveryIdentityKey(_ d: DiscoveredPeer) -> String {
    if let h = normalizeHostname(d.hostname), !h.isEmpty { return "h:\(h)" }
    return "m:\(d.macAddress)"
}

/// Choose ONE path when a machine is reachable over multiple ports in a single
/// pass (two live cables, or a stale ARP entry on the old port overlapping the
/// live one mid-move). Deterministic and stable:
///   1. Sticky — keep the interface the existing record already uses if it's
///      still present this pass, so a still-live port is never abandoned and
///      two live ports don't cause a 5s flip-flop.
///   2. Else prefer a path whose hostname is resolved (more trustworthy than a
///      bare ARP entry whose mDNS name hasn't come back).
///   3. Else the lowest interface name — a stable, deterministic tiebreak.
internal func selectDiscoveredPath(
    _ candidates: [DiscoveredPeer],
    stickyInterface: String?
) -> DiscoveredPeer? {
    guard !candidates.isEmpty else { return nil }
    if let sticky = stickyInterface, !sticky.isEmpty,
       let keep = candidates.first(where: { $0.interfaceName == sticky }) {
        return keep
    }
    let resolved = candidates.filter { (normalizeHostname($0.hostname)?.isEmpty == false) }
    let pool = resolved.isEmpty ? candidates : resolved
    return pool.sorted { $0.interfaceName < $1.interfaceName }.first
}

@MainActor
fileprivate func prefillForNewPeer(discovered: DiscoveredPeer) -> Peer {
    // No hardcoded usernames or keys for ANY hostname. Every newly-discovered
    // peer starts as a blank slate; the username and a dedicated per-peer key
    // are established entirely by the Pair-SSH wizard. This keeps identity
    // user-driven and makes "Forget Peer → re-pair" a true clean re-provision.

    // Label: prefer the resolved hostname, else Peer-<last4ofMac>.
    let label: String
    if let h = discovered.hostname, !h.isEmpty {
        label = h
    } else {
        let cleaned = discovered.macAddress.replacingOccurrences(of: ":", with: "")
        let last4 = String(cleaned.suffix(4))
        label = "Peer-\(last4)"
    }
    // EMPTY username + nil key. Using NSUserName() (the running user on THIS
    // Mac) is almost always wrong — peer Macs have their own accounts. Empty
    // forces the wizard to prompt for the actual remote account name, and the
    // wizard generates a dedicated key (peer.dedicatedKeyPath) on pairing.
    return Peer(
        label: label,
        lastKnownHostname: discovered.hostname ?? "",
        sshUsername: "",
        sshKeyPath: nil
    )
}

fileprivate func logToStderr(_ message: String) {
    let line = "[PeerStore] \(message)\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}
