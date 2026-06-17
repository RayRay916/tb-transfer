import Foundation

/// A discovered or registered TB peer Mac. Identity is the SSH host fingerprint
/// (stable across reboots), NOT the link-local IP (which changes every session).
struct Peer: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var label: String
    var sshHostFingerprint: String?
    var lastKnownHostname: String
    var sshUsername: String
    var sshKeyPath: String?
    var lastSeenInterface: String?
    var lastSeenIP: String?
    var lastSeenAt: Date?
    /// Remote MAC observed on the most recent ARP. The PRIMARY identity key
    /// for reconcile — stable across reboots, IP changes, and cable swaps.
    /// Optional for backward compat with peers.json from before this field existed;
    /// will be backfilled on the next successful reconcile.
    var lastSeenMAC: String?

    /// User opts a peer into UNENCRYPTED transfer mode. When true, the engine
    /// bypasses the SSH-tunneled rsync and instead spawns a transient
    /// `rsync --daemon` on the peer (via SSH for control), then connects on
    /// plain TCP via `rsync://peer:port/`. Bypasses the AES-128-GCM CPU
    /// bottleneck — single-stream throughput typically jumps 2–3x on TB5.
    /// Safe ONLY because TB is a physical point-to-point cable you own; would
    /// be a terrible idea on any shared network.
    /// Defaults to false (Codable picks up the default via decodeIfPresent
    /// behavior on optional → non-optional with default — see init below).
    var trustedMode: Bool = false

    /// The peer's `$HOME` as captured during the most recent successful SSH
    /// pairing (e.g. "/Users/ray"). This is the concrete value `~` resolves to
    /// for this peer. Re-captured on every pairing, so it adapts if the
    /// provisioned account ever changes. Informational/diagnostic — transfer
    /// paths still expand `~` against the LIVE remote `$HOME` at run time, so
    /// they stay correct even if this cached value goes stale between pairings.
    /// Optional for backward compat with peers.json written before this field.
    var remoteHome: String?

    init(
        id: UUID = UUID(),
        label: String,
        sshHostFingerprint: String? = nil,
        lastKnownHostname: String,
        sshUsername: String,
        sshKeyPath: String? = nil,
        lastSeenInterface: String? = nil,
        lastSeenIP: String? = nil,
        lastSeenAt: Date? = nil,
        lastSeenMAC: String? = nil,
        trustedMode: Bool = false,
        remoteHome: String? = nil
    ) {
        self.id = id
        self.label = label
        self.sshHostFingerprint = sshHostFingerprint
        self.lastKnownHostname = lastKnownHostname
        self.sshUsername = sshUsername
        self.sshKeyPath = sshKeyPath
        self.lastSeenInterface = lastSeenInterface
        self.lastSeenIP = lastSeenIP
        self.lastSeenAt = lastSeenAt
        self.lastSeenMAC = lastSeenMAC
        self.trustedMode = trustedMode
        self.remoteHome = remoteHome
    }

    // Custom Codable to provide default for `trustedMode` when reading legacy
    // peers.json that doesn't include the field.
    private enum CodingKeys: String, CodingKey {
        case id, label, sshHostFingerprint, lastKnownHostname, sshUsername
        case sshKeyPath, lastSeenInterface, lastSeenIP, lastSeenAt, lastSeenMAC
        case trustedMode, remoteHome
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        sshHostFingerprint = try c.decodeIfPresent(String.self, forKey: .sshHostFingerprint)
        lastKnownHostname = try c.decode(String.self, forKey: .lastKnownHostname)
        sshUsername = try c.decode(String.self, forKey: .sshUsername)
        sshKeyPath = try c.decodeIfPresent(String.self, forKey: .sshKeyPath)
        lastSeenInterface = try c.decodeIfPresent(String.self, forKey: .lastSeenInterface)
        lastSeenIP = try c.decodeIfPresent(String.self, forKey: .lastSeenIP)
        lastSeenAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        lastSeenMAC = try c.decodeIfPresent(String.self, forKey: .lastSeenMAC)
        trustedMode = try c.decodeIfPresent(Bool.self, forKey: .trustedMode) ?? false
        remoteHome = try c.decodeIfPresent(String.self, forKey: .remoteHome)
    }

    var isOnline: Bool {
        guard let when = lastSeenAt else { return false }
        return Date().timeIntervalSince(when) < 90
    }

    var displayName: String {
        label.isEmpty ? lastKnownHostname : label
    }

    /// Directory (under `~/.ssh`) that holds the app-managed per-peer keypairs.
    /// Anything inside here is owned exclusively by TBTransfer and is safe to
    /// delete on "Forget Peer". Keys OUTSIDE this dir (e.g. a user's personal
    /// `~/.ssh/id_ed25519`) are never touched.
    static let managedKeyDirectory = "~/.ssh/tbtransfer"

    /// Deterministic, per-peer SSH key path. Every peer gets its OWN dedicated
    /// keypair so pairing is fully self-contained and "Forget Peer" can delete
    /// exactly this peer's key without affecting any other peer or the user's
    /// personal keys. Derived from the stable peer UUID.
    var dedicatedKeyPath: String {
        "\(Peer.managedKeyDirectory)/id_\(id.uuidString.lowercased())_ed25519"
    }

    /// Dedicated known_hosts file for app-managed SSH. Keeping host keys OUT of
    /// the user's `~/.ssh/known_hosts` means (a) we never pollute their file and
    /// (b) Forget Peer can scrub our entry cleanly. Lives in the managed dir so
    /// it shares the same lifecycle as the per-peer keys.
    static let managedKnownHostsFile = "~/.ssh/tbtransfer/known_hosts"

    /// Stable per-peer host-key identity, passed to ssh as `-o HostKeyAlias`.
    /// The peer's host key is then stored/verified under a name that NEVER
    /// changes, even though its link-local IP is reassigned every session.
    /// Without this, a reused 169.254.x.y address (a DIFFERENT Mac on the same
    /// IP next session) trips SSH's "REMOTE HOST IDENTIFICATION HAS CHANGED"
    /// hard-fail, which silently breaks probing, pairing, and transfers until
    /// known_hosts is hand-edited. Derived from the stable peer UUID.
    var hostKeyAlias: String {
        "tbtransfer-\(id.uuidString.lowercased())"
    }

    /// True when this peer's configured key lives inside the app-managed
    /// directory (i.e. we generated it during pairing and own its lifecycle).
    /// Forget-time key deletion + remote authorized_keys cleanup are gated on
    /// this so we never destroy a user-supplied or shared key.
    var usesManagedKey: Bool {
        guard let path = sshKeyPath else { return false }
        let expanded = Peer.expandTildePath(path)
        let dir = Peer.expandTildePath(Peer.managedKeyDirectory)
        // Normalize to ensure a trailing slash so "/tbtransferX" can't match.
        let dirPrefix = dir.hasSuffix("/") ? dir : dir + "/"
        return expanded.hasPrefix(dirPrefix)
    }

    /// Tilde-expansion shared by the helpers above. Kept here (not in a UI
    /// file) so model-level identity logic has no view-layer dependency.
    static func expandTildePath(_ s: String) -> String {
        guard s.hasPrefix("~") else { return s }
        let home = NSHomeDirectory()
        if s == "~" { return home }
        if s.hasPrefix("~/") { return home + String(s.dropFirst(1)) }
        return s
    }
}
