import Foundation
import Observation
import AppKit
import Network

/// Top-level observable app state. Owns the discovery monitor, peer registry,
/// and transfer engine. Created once at app launch.
@Observable
@MainActor
final class AppState {
    let interfaceMonitor = TBInterfaceMonitor()
    let peerStore = PeerStore()
    let transferEngine = TransferEngine()
    let transferHistory = TransferHistory()
    let mirrorWatcher = MirrorWatcher()
    let benchmarkEngine = BenchmarkEngine()

    /// Lives outside @Observable observation tracking — menubar internals shouldn't
    /// trigger SwiftUI re-renders.
    private(set) var menubarController: MenubarController?

    /// Currently selected peer in the UI (for the minimal Phase 1 window).
    var selectedPeerID: UUID?

    /// Last status line shown in the UI.
    var statusLine: String = "Idle."

    /// Flips true once initial discovery completes (with a minimum splash
    /// visible time enforced in `start()`). The root view gates on this to
    /// swap the splash for the main window.
    var isReady: Bool = false

    /// Per-peer SSH reachability health. Runtime-only (not persisted) — we
    /// always want a fresh probe on each launch, never a stale "ok" from
    /// yesterday. Keyed by Peer.id.
    var sshHealth: [UUID: SSHHealth] = [:]

    struct SSHHealth: Sendable {
        var status: Status
        var lastProbeAt: Date
        var detail: String?

        enum Status: Sendable, Equatable {
            case probing
            case ok
            /// TCP :22 refused — sshd is not running. Most likely cause: Remote
            /// Login is disabled in System Settings → General → Sharing.
            case remoteLoginDisabled
            /// TCP :22 succeeded but the SSH handshake / auth was rejected.
            /// Almost always: pubkey isn't in the peer's authorized_keys.
            case notPaired
            /// TCP :22 timed out or host was unreachable — cable / power / TB-Bridge.
            case unreachable
            /// Anything we couldn't classify into the buckets above.
            case otherError
        }
    }

    /// Active discovery/refresh task handle.
    private var discoveryTask: Task<Void, Never>?
    /// Active SSH-health probe loop handle.
    private var sshProbeTask: Task<Void, Never>?

    /// Watched count of completedTasks so we know when to mirror into history.
    private var lastCompletedCount: Int = 0

    /// Kick off interface monitoring + peer reconciliation on launch.
    func start() async {
        let splashStart = Date()
        statusLine = "Starting discovery…"
        peerStore.load()
        transferHistory.load()
        mirrorWatcher.load { [weak self] id in self?.peerStore.peer(id: id) }
        installMenubarIfNeeded()

        // Ask for user-notification permission once at launch so transfer
        // completion notifications land without a modal dialog mid-transfer.
        TransferEngine.requestNotificationPermission()

        // Plumb a fresh-IP refresh hook into the transfer engine: when the
        // engine's pre-flight reach probe fails on the registry IP, it asks
        // us to re-run discovery + reconcile and returns the updated Peer.
        transferEngine.freshPeerProvider = { [weak self] id in
            guard let self else { return nil }
            await self.refresh()
            return self.peerStore.peer(id: id)
        }

        await refresh()
        // Ensure splash stays up for at least 1.2s so the launch animation
        // doesn't strobe on machines where discovery completes instantly.
        let elapsed = Date().timeIntervalSince(splashStart)
        if elapsed < 1.2 {
            try? await Task.sleep(for: .seconds(1.2 - elapsed))
        }
        isReady = true
        // Continuous refresh every 5s; cheap (ifconfig + arp). Also harvest completed
        // transfers into the persistent history on each tick.
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                await self.refresh()
                self.harvestCompletedTransfers()
            }
        }
        // Kick off the SSH health probe immediately, then loop every 30s.
        // Each probe is ~SSH-connect-overhead (sub-second on TB), so the cost
        // is trivial; we get a fast green/red indicator without users hitting Send.
        Task { await self.probeAllPeerSSH() }
        sshProbeTask?.cancel()
        sshProbeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                await self.probeAllPeerSSH()
            }
        }
    }

    /// Probe SSH reachability for every online peer in parallel. Updates `sshHealth`.
    /// Skips peers that are TB-offline (no point probing — they'd just time out).
    func probeAllPeerSSH() async {
        let targets = peerStore.peers.filter(\.isOnline)
        for peer in targets where sshHealth[peer.id] == nil {
            sshHealth[peer.id] = SSHHealth(status: .probing, lastProbeAt: Date())
        }
        await withTaskGroup(of: (UUID, SSHHealth).self) { group in
            for peer in targets {
                group.addTask {
                    let health = await Self.classifyPeerHealth(peer)
                    return (peer.id, health)
                }
            }
            for await (id, health) in group {
                sshHealth[id] = health
            }
        }
        // Drop entries for peers that no longer exist.
        let activeIDs = Set(peerStore.peers.map(\.id))
        sshHealth = sshHealth.filter { activeIDs.contains($0.key) }
    }

    /// Probe a single peer immediately — useful after a successful Pair-SSH so the
    /// indicator flips green without waiting for the next 30s tick.
    func probeSSH(peerID: UUID) async {
        guard let peer = peerStore.peer(id: peerID) else { return }
        sshHealth[peerID] = SSHHealth(status: .probing, lastProbeAt: Date())
        sshHealth[peerID] = await Self.classifyPeerHealth(peer)
    }

    /// Fully forget a peer. This wipes ALL configuration for it so that adding
    /// it back requires the same from-scratch provisioning as the first time:
    ///   1. SSH de-provision — delete the dedicated per-peer key, strip our
    ///      pubkey from the peer's authorized_keys, scrub known_hosts.
    ///   2. Tear down any mirror folders configured for the peer.
    ///   3. Drop runtime SSH health + clear selection.
    ///   4. Remove it from the persistent registry.
    func forgetPeer(_ peer: Peer) async {
        statusLine = "Forgetting \(peer.displayName)…"

        // 1. SSH de-provision (managed key files + remote authorized_keys +
        //    known_hosts). Safe no-op for legacy/user-supplied keys.
        await SSHBootstrap.unpair(peer: peer)

        // 2. Remove any mirror configs that pointed at this peer.
        let mirrorIDs = mirrorWatcher.configs
            .filter { $0.peerID == peer.id }
            .map(\.id)
        for id in mirrorIDs {
            mirrorWatcher.remove(id: id)
        }

        // 3. Runtime cleanup.
        sshHealth[peer.id] = nil
        if selectedPeerID == peer.id { selectedPeerID = nil }

        // 4. Drop from the registry (persists peers.json).
        peerStore.remove(id: peer.id)

        statusLine = "Forgot \(peer.displayName) — SSH key deleted; re-pair to reconnect."
    }

    /// Two-layer probe used by the health indicator:
    ///   1. TCP probe to :22 (with 2s deadline). If it can't even open a socket,
    ///      we can distinguish "port refused" (sshd not running → Remote Login off)
    ///      from "timed out / unreachable" (cable / sleep / TB-Bridge wedged).
    ///   2. Only if TCP succeeds do we run the full SSH handshake. Auth-failure
    ///      now uniquely means "pubkey not in authorized_keys" — actionable as
    ///      "use the Pair SSH wizard". This is the upgrade from the old
    ///      single-call probe which conflated those two failure modes.
    nonisolated static func classifyPeerHealth(_ peer: Peer) async -> SSHHealth {
        guard let ip = peer.lastSeenIP, !ip.isEmpty else {
            return SSHHealth(status: .unreachable, lastProbeAt: Date(),
                             detail: "No TB IP yet — peer hasn't been ARP-discovered.")
        }
        let tcp = await tcpProbe(host: ip, port: 22, timeoutMillis: 2000)
        switch tcp {
        case .connectionRefused:
            return SSHHealth(status: .remoteLoginDisabled, lastProbeAt: Date(),
                             detail: "Port 22 refused on \(ip) — sshd not running on \(peer.displayName).")
        case .timeout:
            return SSHHealth(status: .unreachable, lastProbeAt: Date(),
                             detail: "Timed out connecting to \(ip):22.")
        case .unreachable:
            return SSHHealth(status: .unreachable, lastProbeAt: Date(),
                             detail: "No route to \(ip).")
        case .otherError(let msg):
            return SSHHealth(status: .otherError, lastProbeAt: Date(), detail: msg)
        case .success:
            break
        }
        // TCP works — try a real SSH handshake.
        let result = await SSHHelper.probe(peer: peer, timeoutSec: 5)
        switch result {
        case .success:
            return SSHHealth(status: .ok, lastProbeAt: Date(), detail: nil)
        case .failure(let error):
            let msg = (error as NSError).localizedDescription
            // Permission denied / auth failure → not paired yet.
            let lower = msg.lowercased()
            if lower.contains("permission denied") || lower.contains("publickey") {
                return SSHHealth(status: .notPaired, lastProbeAt: Date(),
                                 detail: "SSH key not authorized on \(peer.displayName). Right-click → Pair SSH…")
            }
            return SSHHealth(status: .otherError, lastProbeAt: Date(), detail: msg)
        }
    }

    /// TCP-only reachability probe. Distinguishes refused / timeout / unreachable.
    /// Single-resume guard ensures the continuation isn't double-fired by both
    /// the state handler and the deadline.
    nonisolated private static func tcpProbe(
        host: String, port: UInt16, timeoutMillis: Int
    ) async -> TCPProbeResult {
        await withCheckedContinuation { (cont: CheckedContinuation<TCPProbeResult, Never>) in
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            let box = SingleResume<TCPProbeResult>()
            let resume: @Sendable (TCPProbeResult) -> Void = { result in
                if box.tryResume() {
                    cont.resume(returning: result)
                    conn.cancel()
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resume(.success)
                case .failed(let error):
                    switch error {
                    case .posix(let code):
                        switch code {
                        case .ECONNREFUSED: resume(.connectionRefused)
                        case .ETIMEDOUT:    resume(.timeout)
                        case .EHOSTUNREACH, .ENETUNREACH: resume(.unreachable)
                        default: resume(.otherError(error.localizedDescription))
                        }
                    default:
                        resume(.otherError(error.localizedDescription))
                    }
                default:
                    break
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMillis)) {
                resume(.timeout)
            }
            conn.start(queue: .global())
        }
    }

    enum TCPProbeResult: Sendable {
        case success
        case connectionRefused
        case timeout
        case unreachable
        case otherError(String)
    }

    /// Tiny atomic-once latch for continuations.
    private final class SingleResume<T>: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func tryResume() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    private func installMenubarIfNeeded() {
        if menubarController == nil {
            let controller = MenubarController(appState: self)
            controller.install()
            menubarController = controller
        }
    }

    private func harvestCompletedTransfers() {
        let completed = transferEngine.completedTasks
        guard completed.count > lastCompletedCount else { return }
        let newOnes = completed.prefix(completed.count - lastCompletedCount)
        for task in newOnes.reversed() {
            transferHistory.append(task)
        }
        lastCompletedCount = completed.count
    }

    /// One full discovery pass: enumerate interfaces, ARP-scan for peers, reconcile with registry.
    func refresh() async {
        // Feed last-known peer IPs to the scanner as unicast ping hints so a
        // peer whose IP hasn't churned is re-found instantly and reliably.
        let hintIPs = peerStore.peers.compactMap { $0.lastSeenIP }.filter { !$0.isEmpty }
        await interfaceMonitor.refresh(hintIPs: hintIPs)
        // Batch reconcile: groups all discovered paths by physical machine and
        // picks ONE stable path per machine, so a peer reachable over two ports
        // (or mid-cable-move with a stale ARP entry on the old port) doesn't
        // latch onto a dead path or flip-flop between live ones.
        peerStore.reconcile(batch: interfaceMonitor.discoveredPeers)
        // Collapse any duplicates that slipped in this pass (e.g. a peer whose
        // TB-Bridge MAC regenerated, briefly creating a second same-hostname
        // entry). Idempotent; cheap; keeps the sidebar clean mid-session.
        peerStore.deduplicateByHostname()
        if selectedPeerID == nil, let first = peerStore.peers.first {
            selectedPeerID = first.id
        }
        let online = peerStore.peers.filter(\.isOnline).count
        statusLine = "\(online) of \(peerStore.peers.count) peer\(peerStore.peers.count == 1 ? "" : "s") online"
    }

    /// Read NSPasteboard for file URLs and queue a push transfer to the selected peer.
    func pasteFromClipboard() {
        guard let peerID = selectedPeerID, let peer = peerStore.peer(id: peerID) else {
            statusLine = "No peer selected — choose one first."
            return
        }
        let pb = NSPasteboard.general
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        guard !urls.isEmpty else {
            statusLine = "Clipboard has no files."
            return
        }
        let task = TransferTask(
            peerID: peer.id,
            direction: .push,
            sources: urls.map(\.path),
            destination: peer.defaultDropDirectory
        )
        transferEngine.enqueue(task, peer: peer)
        statusLine = "Queued push of \(urls.count) item(s) to \(peer.displayName)."
    }
}

extension Peer {
    /// Where files dropped to this peer land by default: the peer's Downloads
    /// folder. Uses `~/` which expands to the REMOTE user's `$HOME` at transfer
    /// time (via the remote shell for SSH, or the daemon's `home` module for
    /// trusted mode) — so it always tracks whatever account the most recent
    /// pairing provisioned, with no hardcoded username, and adapts if it ever
    /// changes. `~/Downloads` exists on every stock macOS account, and the
    /// transfer pre-flight `mkdir -p`s it (and any sub-path) regardless.
    var defaultDropDirectory: String {
        "~/Downloads"
    }
}
