import Foundation
import Observation
import CoreServices
import Network

/// A registered folder mirror: keep `localPath` synced into `remotePath` on
/// `peerID` whenever local changes happen. Identity is a stable UUID so the
/// UI can refer to the mirror across config edits.
struct MirrorConfig: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var localPath: String        // absolute local dir
    var peerID: UUID
    var remotePath: String       // absolute remote dir
    var enabled: Bool
    var lastSyncAt: Date?
    var lastError: String?

    init(
        id: UUID = UUID(),
        localPath: String,
        peerID: UUID,
        remotePath: String,
        enabled: Bool = true,
        lastSyncAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.localPath = localPath
        self.peerID = peerID
        self.remotePath = remotePath
        self.enabled = enabled
        self.lastSyncAt = lastSyncAt
        self.lastError = lastError
    }
}

/// Watches one or more local folders via FSEvents and rsyncs changes to a
/// peer Mac. One running `MirrorWatcher` per app process.
///
/// API contract:
///   - `configs: [MirrorConfig]` — sorted by localPath, observable.
///   - `inFlight: Set<UUID>` — configs currently mid-sync, observable.
///   - `load(peerLookup:)` — read `mirrors.json` and start enabled watchers.
///   - `save()` — write `mirrors.json`.
///   - `add(_:peer:)` — persist a new mirror and start watching if enabled.
///   - `remove(id:)` — stop the watcher and delete the mirror.
///   - `setEnabled(_:enabled:peerLookup:)` — toggle. Turning ON triggers an
///     initial sync after the watcher starts.
///   - `syncNow(_:peerLookup:)` — one-shot sync, idempotent (no-op if in-flight).
///
/// Storage: `~/Library/Application Support/TBTransfer/mirrors.json`.
@Observable
@MainActor
final class MirrorWatcher {
    private(set) var configs: [MirrorConfig] = []
    private(set) var inFlight: Set<UUID> = []

    /// Active watchers, keyed by config id. `stream` is the FSEvents handle;
    /// `debounceTask` is the most-recent debounce timer (may be nil between
    /// callbacks). Both are reset on disable/remove.
    private var watchers: [UUID: WatcherHandle] = [:]

    /// Per-config "do not sync until" timestamp. Set when an offline probe
    /// fails so a flurry of FSEvent-triggered debounces doesn't drown the
    /// UI in identical "Peer offline" errors. Cleared on next successful sync.
    private var cooldownUntil: [UUID: Date] = [:]
    private static let offlineCooldownSeconds: TimeInterval = 30

    /// Resolves a Peer for a given UUID. Captured at load() / setEnabled() time
    /// so syncNow() can re-resolve current peer state (lastSeenIP changes per
    /// TB session).
    private var peerLookup: (@MainActor (UUID) -> Peer?)?

    /// Dedicated dispatch queue for FSEvent callbacks. NOT main — FSEvents
    /// callbacks should never block the UI.
    private static let fsEventQueue =
        DispatchQueue(label: "com.tbtransfer.mirrorwatcher.fsevents", qos: .utility)

    // Note: no deinit-driven FSEvent teardown. The `MirrorWatcher` is owned by
    // `AppState` and lives for the lifetime of the app process; macOS reclaims
    // FSEventStreams on process exit. Per-config cleanup is handled by
    // `stopWatcher(for:)` from `remove(id:)` / `setEnabled(_:false…)`.

    // MARK: - Persistence

    func load(peerLookup: @escaping @MainActor (UUID) -> Peer?) {
        self.peerLookup = peerLookup

        let url: URL
        do {
            url = try Self.storageURL()
        } catch {
            Self.logToStderr("load: failed to resolve storage URL: \(error)")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loaded = try decoder.decode([MirrorConfig].self, from: data)
            configs = loaded.sorted { $0.localPath.lowercased() < $1.localPath.lowercased() }
        } catch {
            Self.logToStderr("load: decode failed: \(error)")
            configs = []
            return
        }

        // Start watchers for the enabled mirrors.
        for config in configs where config.enabled {
            startWatcher(for: config)
        }
    }

    func save() {
        let url: URL
        do {
            url = try Self.storageURL()
        } catch {
            Self.logToStderr("save: failed to resolve storage URL: \(error)")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(configs)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logToStderr("save: write failed: \(error)")
        }
    }

    // MARK: - Public mutation API

    func add(_ config: MirrorConfig, peer: Peer) {
        configs.removeAll { $0.id == config.id }
        configs.append(config)
        configs.sort { $0.localPath.lowercased() < $1.localPath.lowercased() }
        save()

        if config.enabled {
            startWatcher(for: config)
            // Also run an initial push so the remote matches immediately.
            let id = config.id
            let lookup = peerLookup
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let lookup {
                    await self.syncNow(id, peerLookup: lookup)
                } else {
                    // Caller passed peer directly; resolve via a one-shot closure.
                    await self.syncNow(id) { pid in pid == peer.id ? peer : nil }
                }
            }
        }
    }

    func remove(id: UUID) {
        stopWatcher(for: id)
        configs.removeAll { $0.id == id }
        save()
    }

    func setEnabled(_ id: UUID, enabled: Bool, peerLookup: @escaping @MainActor (UUID) -> Peer?) {
        guard let idx = configs.firstIndex(where: { $0.id == id }) else { return }
        configs[idx].enabled = enabled
        save()

        if enabled {
            // Cache the lookup for future FSEvent-triggered syncs.
            self.peerLookup = peerLookup
            let config = configs[idx]
            startWatcher(for: config)
            Task { @MainActor [weak self] in
                await self?.syncNow(id, peerLookup: peerLookup)
            }
        } else {
            stopWatcher(for: id)
        }
    }

    // MARK: - One-shot sync

    func syncNow(_ id: UUID, peerLookup: @MainActor (UUID) -> Peer?) async {
        // 1. Idempotency.
        if inFlight.contains(id) { return }
        guard let idx = configs.firstIndex(where: { $0.id == id }) else { return }
        let config = configs[idx]

        // 1a. Offline cooldown: if a previous attempt failed the reach probe,
        //     silently suppress further syncs for `offlineCooldownSeconds` so
        //     a debounced FSEvent burst doesn't churn `lastError` and flicker
        //     the UI. This is a deliberate no-op (no markError) — the existing
        //     "Peer offline; waiting" message stays on screen.
        if let until = cooldownUntil[id], until > Date() {
            return
        }

        // 2. Resolve peer + IP.
        guard let peer = peerLookup(config.peerID) else {
            await markError(id: id, message: "Peer not found")
            return
        }
        guard let ip = peer.lastSeenIP, !ip.isEmpty else {
            await markError(id: id, message: "Peer offline (no TB IP)")
            cooldownUntil[id] = Date().addingTimeInterval(Self.offlineCooldownSeconds)
            return
        }

        // 2a. Quick TCP probe to the SSH port. If the peer is unreachable,
        //     don't even attempt rsync — that would spawn an ssh process that
        //     blocks on a TCP SYN until the kernel times out. Just record
        //     "Peer offline; waiting" and cool down for a bit.
        if !(await Self.tcpProbe(host: ip, port: 22, timeoutMillis: 2000)) {
            await markError(id: id, message: "Peer offline; waiting")
            cooldownUntil[id] = Date().addingTimeInterval(Self.offlineCooldownSeconds)
            return
        }

        // 3. Mark in-flight.
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        // 4. Pre-create remote dir.
        // Fix for AUDIT bug 4: runMkdir no longer takes an `ip:` parameter —
        // the caller already verified `peer.lastSeenIP` is non-empty just
        // above, and SSHHelper.sshCommand(for:) resolves the same value
        // internally. Passing `ip` separately was a footgun (the parameter
        // was unused and implied the caller could override the SSH target).
        let mkdirResult = await runMkdir(peer: peer, remotePath: config.remotePath)
        if !mkdirResult.ok {
            let tail = String(mkdirResult.stderr.suffix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
            await markError(id: id, message: tail.isEmpty ? "mkdir failed (exit \(mkdirResult.exitCode))" : tail)
            return
        }

        // 5. Build and run rsync.
        let rsyncArgs = buildRsyncArgs(
            peer: peer,
            ip: ip,
            localPath: config.localPath,
            remotePath: config.remotePath
        )
        do {
            let result = try await ShellRunner.run(
                "/usr/bin/rsync",
                rsyncArgs,
                timeout: 600
            )
            if result.ok {
                await markSuccess(id: id)
            } else {
                let combined = result.stderr.isEmpty ? result.stdout : result.stderr
                let tail = String(combined.suffix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
                await markError(id: id, message: tail.isEmpty ? "rsync exited \(result.exitCode)" : tail)
            }
        } catch {
            await markError(id: id, message: "rsync launch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - rsync / ssh command construction

    /// Builds the argv for the one-shot rsync. Single invocation (not the
    /// 16-stream pipeline) because `--delete` can't be split per-child cleanly.
    private func buildRsyncArgs(peer: Peer, ip: String, localPath: String, remotePath: String) -> [String] {
        let sshCmd = buildInnerSSHCommand(for: peer)
        let userTarget = "\(peer.sshUsername)@\(ip)"

        // Trailing slash on source is critical: copies *contents* of localPath
        // into remotePath, instead of nesting localPath inside remotePath.
        let srcWithSlash = ensureTrailingSlash(localPath)
        let dstWithSlash = "\(userTarget):\(ensureTrailingSlash(remotePath))"

        return [
            "-aWL",
            "--delete",
            "--inplace",
            "--no-compress",
            "-e", sshCmd,
            srcWithSlash,
            dstWithSlash,
        ]
    }

    /// Builds the `-e <command>` argument for rsync. This is a single string
    /// passed to rsync; rsync invokes it via the shell, so paths inside it
    /// need shell-quoting.
    private func buildInnerSSHCommand(for peer: Peer) -> String {
        var parts: [String] = ["ssh"]
        if let key = peer.sshKeyPath, !key.isEmpty {
            parts.append("-i \(Self.shellQuote(Self.expandTilde(key)))")
        }
        parts.append("-c aes128-gcm@openssh.com")
        parts.append("-o Compression=no")
        parts.append("-o ControlMaster=no")
        // Stable per-peer host-key alias + dedicated known_hosts — survives
        // link-local IP reuse that would otherwise hard-fail the mirror sync.
        parts.append(SSHHelper.hostKeyOptionString(for: peer))
        parts.append("-o ConnectTimeout=5")
        return parts.joined(separator: " ")
    }

    /// Runs `ssh ... 'mkdir -p <remote>'` with the standard SSH argv from SSHHelper.
    // Fix for AUDIT bug 4: dropped the unused `ip:` parameter. SSHHelper.sshCommand
    // resolves `peer.lastSeenIP ?? peer.lastKnownHostname` internally, and
    // syncNow has already verified `peer.lastSeenIP` is non-empty before
    // reaching here. The previous signature suggested the caller could
    // override the SSH target — they couldn't — which was misleading.
    private func runMkdir(peer: Peer, remotePath: String) async -> ShellRunner.Result {
        // Use SSHHelper's canonical argv so the connect options stay consistent.
        // We pass the peer through unchanged — SSHHelper resolves `lastSeenIP`
        // internally, which we already confirmed is set.
        let (argv, _) = SSHHelper.sshCommand(for: peer, extraOptions: [])
        let inner = "mkdir -p \(Self.shellQuote(remotePath))"
        let fullArgv = argv + [inner]
        guard let exe = fullArgv.first else {
            return ShellRunner.Result(exitCode: 127, stdout: "", stderr: "empty ssh argv")
        }
        let args = Array(fullArgv.dropFirst())

        do {
            return try await ShellRunner.run(exe, args, timeout: 15)
        } catch {
            return ShellRunner.Result(
                exitCode: 1,
                stdout: "",
                stderr: "ssh launch failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - State mutation helpers

    private func markError(id: UUID, message: String) async {
        guard let idx = configs.firstIndex(where: { $0.id == id }) else { return }
        configs[idx].lastError = message
        save()
    }

    private func markSuccess(id: UUID) async {
        guard let idx = configs.firstIndex(where: { $0.id == id }) else { return }
        configs[idx].lastSyncAt = Date()
        configs[idx].lastError = nil
        cooldownUntil.removeValue(forKey: id)
        save()
    }

    // MARK: - FSEvents watcher lifecycle

    private func startWatcher(for config: MirrorConfig) {
        // If a stream is already running for this id, replace it.
        stopWatcher(for: config.id)

        // FSEventStream wants an absolute path — does NOT expand `~`.
        let pathsToWatch = [PathExpander.absolute(config.localPath)] as CFArray
        let latency: CFTimeInterval = 0.5

        // Build a context whose info pointer is an unmanaged ref to a Box wrapping
        // (self, config.id). We keep this box alive in the WatcherHandle so the
        // callback can resolve it back into our actor.
        let box = CallbackBox(owner: self, configID: config.id)
        let boxPtr = Unmanaged.passRetained(box).toOpaque()

        var context = FSEventStreamContext(
            version: 0,
            info: boxPtr,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            mirrorWatcherCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            // Release the box if stream creation failed, so we don't leak.
            Unmanaged<CallbackBox>.fromOpaque(boxPtr).release()
            Self.logToStderr("startWatcher: FSEventStreamCreate returned nil for \(config.localPath)")
            return
        }

        FSEventStreamSetDispatchQueue(stream, Self.fsEventQueue)
        let started = FSEventStreamStart(stream)
        if !started {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            Unmanaged<CallbackBox>.fromOpaque(boxPtr).release()
            Self.logToStderr("startWatcher: FSEventStreamStart failed for \(config.localPath)")
            return
        }

        watchers[config.id] = WatcherHandle(
            stream: stream,
            boxPtr: boxPtr,
            debounceTask: nil
        )
    }

    private func stopWatcher(for id: UUID) {
        cooldownUntil.removeValue(forKey: id)
        guard let handle = watchers.removeValue(forKey: id) else { return }
        handle.debounceTask?.cancel()
        FSEventStreamStop(handle.stream)
        FSEventStreamInvalidate(handle.stream)

        // Fix for AUDIT bug 3: use-after-free race on the CallbackBox.
        // The C callback reads `box.configID` / `box.owner` synchronously
        // before hopping to MainActor. `FSEventStreamInvalidate` detaches
        // the stream from its dispatch queue but does NOT wait for an
        // in-flight callback already executing on `fsEventQueue` to finish.
        // If we released the box while a callback was mid-call, the
        // callback would deref freed memory.
        //
        // Callbacks for this stream run serially on `fsEventQueue` (set via
        // FSEventStreamSetDispatchQueue in startWatcher). After Invalidate,
        // no new callbacks will be scheduled for this stream. A synchronous
        // barrier on the same queue therefore waits for any in-flight
        // callback to return before we proceed to release. Hop is from
        // MainActor → fsEventQueue (safe; we never call this from inside
        // the callback itself).
        let boxPtr = handle.boxPtr
        Self.fsEventQueue.sync { /* drain in-flight callbacks */ }

        FSEventStreamRelease(handle.stream)
        // Now safe to release our retained box — no callback is mid-flight.
        Unmanaged<CallbackBox>.fromOpaque(boxPtr).release()
    }

    /// Called from the FSEvents C callback after it has hopped to MainActor.
    /// Cancels any pending debounce task and schedules a fresh one.
    fileprivate func didReceiveFSEvent(for configID: UUID) {
        guard var handle = watchers[configID] else { return }
        handle.debounceTask?.cancel()

        let lookup = peerLookup
        let task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(800))
            } catch {
                return
            }
            guard let self else { return }
            guard let lookup else { return }
            await self.syncNow(configID, peerLookup: lookup)
        }
        handle.debounceTask = task
        watchers[configID] = handle
    }

    // MARK: - Path helpers

    private func ensureTrailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    // MARK: - TCP probe

    /// Open a TCP connection to `host:port` and wait up to `timeoutMillis`.
    /// Returns true on `.ready` (handshake accepted), false on failure or
    /// timeout. Used by `syncNow` to skip rsync attempts when the peer is
    /// unplugged (otherwise we burn ~30s on a dead SSH connect attempt
    /// per FSEvent burst). Uses Network.framework — no subprocess.
    fileprivate static func tcpProbe(host: String, port: Int, timeoutMillis: Int) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, (timeoutMillis + 999) / 1000)
        let params = NWParameters(tls: nil, tcp: tcp)
        params.prohibitedInterfaceTypes = [.loopback]

        let connection = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue.global(qos: .userInitiated)

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let resumed = MirrorAtomicBox()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.setIfFalse() {
                        connection.cancel()
                        cont.resume(returning: true)
                    }
                case .failed, .cancelled:
                    if resumed.setIfFalse() {
                        connection.cancel()
                        cont.resume(returning: false)
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMillis)) {
                if resumed.setIfFalse() {
                    connection.cancel()
                    cont.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Static helpers

    @MainActor
    private static func storageURL() throws -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("TBTransfer", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mirrors.json")
    }

    fileprivate static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    fileprivate static func expandTilde(_ s: String) -> String {
        guard s.hasPrefix("~") else { return s }
        let home = NSHomeDirectory()
        if s == "~" { return home }
        if s.hasPrefix("~/") { return home + String(s.dropFirst(1)) }
        return s
    }

    fileprivate static func logToStderr(_ message: String) {
        let line = "[MirrorWatcher] \(message)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

// MARK: - Internal types

/// Holds an active FSEvents subscription plus a debounce timer task.
/// FSEventStreamRef is a CoreFoundation type and `void *` for the box pointer —
/// both are pointer-shaped and not Sendable, but they're only ever touched on
/// the MainActor (the dispatch queue callback never mutates the handle).
fileprivate struct WatcherHandle: @unchecked Sendable {
    let stream: FSEventStreamRef
    let boxPtr: UnsafeMutableRawPointer
    var debounceTask: Task<Void, Never>?
}

/// Single-writer flag used by `MirrorWatcher.tcpProbe` to make sure the
/// continuation is resumed exactly once (state handler races the timeout).
private final class MirrorAtomicBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func setIfFalse() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if flag { return false }
        flag = true
        return true
    }
}

/// Boxed reference passed through FSEventStreamContext.info. The C callback
/// reconstructs this from the raw pointer to find its owner.
private final class CallbackBox: @unchecked Sendable {
    weak var owner: MirrorWatcher?
    let configID: UUID

    init(owner: MirrorWatcher, configID: UUID) {
        self.owner = owner
        self.configID = configID
    }
}

/// The C-compatible FSEvents callback. Runs on the dispatch queue set via
/// FSEventStreamSetDispatchQueue. Hops to MainActor before mutating state.
private let mirrorWatcherCallback: FSEventStreamCallback = {
    (
        _ streamRef: ConstFSEventStreamRef,
        _ clientCallBackInfo: UnsafeMutableRawPointer?,
        _ numEvents: Int,
        _ eventPaths: UnsafeMutableRawPointer,
        _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
        _ eventIDs: UnsafePointer<FSEventStreamEventId>
    ) in
    guard let info = clientCallBackInfo else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
    let configID = box.configID
    // Capture a weak owner on this thread; hop to MainActor to mutate.
    let owner = box.owner
    Task { @MainActor in
        owner?.didReceiveFSEvent(for: configID)
    }
}
