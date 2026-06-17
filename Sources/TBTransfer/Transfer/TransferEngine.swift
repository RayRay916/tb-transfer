import Foundation
import Observation
import Darwin
import Network
import UserNotifications

/// Orchestrates parallel-rsync transfers to/from peers. One concurrent
/// transfer at a time. Within each task we use the 16-stream parallel rsync
/// pipeline (`ls -1A | xargs -P 16 rsync ...`) to saturate the TB link.
///
/// API contract used by `AppState`:
///   - `activeTasks: [TransferTask]` — currently-running or queued tasks.
///   - `completedTasks: [TransferTask]` — finished tasks (most recent first).
///   - `enqueue(_:peer:)` — append a task, start it if idle.
///   - `cancel(id:)` — terminate a running task by id.
@Observable
@MainActor
final class TransferEngine {
    private(set) var activeTasks: [TransferTask] = []
    private(set) var completedTasks: [TransferTask] = []
    private var runningProcess: Process?

    /// Map task.id -> peer so we can resume the queue without re-supplying the peer.
    private var pendingPeers: [UUID: Peer] = [:]

    /// True while a task is being executed (covers the brief window between
    /// dequeue and `runningProcess` being assigned).
    private var isBusy: Bool = false

    /// Task id of whatever is currently `runningProcess`.
    private var runningTaskID: UUID?

    /// Optional hook to refresh peer discovery + reconcile when the
    /// last-known TB IP for a peer is stale. Set by `AppState.start()`.
    /// Returning a fresh Peer with an updated `lastSeenIP` allows
    /// `ensureReachable(peer:)` to retry connectivity after a re-scan.
    var freshPeerProvider: (@MainActor (UUID) async -> Peer?)?

    func enqueue(_ task: TransferTask, peer: Peer) {
        activeTasks.append(task)
        pendingPeers[task.id] = peer
        startNextIfIdle()
    }

    func cancel(id: UUID) {
        // Queued: just drop it.
        if let idx = activeTasks.firstIndex(where: { $0.id == id }),
           activeTasks[idx].status == .queued {
            var t = activeTasks.remove(at: idx)
            t.status = .cancelled
            t.completedAt = Date()
            completedTasks.insert(t, at: 0)
            pendingPeers.removeValue(forKey: id)
            return
        }

        // Running: terminate the process; run() will finalize the state.
        if runningTaskID == id, let proc = runningProcess {
            // Mark cancellation intent so the finalizer uses `.cancelled` instead of `.failed`.
            if let idx = activeTasks.firstIndex(where: { $0.id == id }) {
                activeTasks[idx].status = .cancelled
            }
            proc.terminate()
            Self.escalateTerminate(proc)
        }
    }

    /// Send SIGKILL to `process` after `afterSec` if it is still running.
    /// Used as a follow-up to `process.terminate()` (SIGTERM) so cancellation
    /// of an rsync/ssh blocked in a syscall cannot hang the engine.
    nonisolated fileprivate static func escalateTerminate(_ process: Process, afterSec: TimeInterval = 2.0) {
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + afterSec) {
            if process.isRunning {
                _ = kill(pid, SIGKILL)
            }
        }
    }

    /// Request UserNotifications permission. Called once at app start so the
    /// completion notification at the end of `finalize()` lands without a
    /// modal permission dialog mid-transfer. Silently ignores denial.
    static func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Queue driver

    private func startNextIfIdle() {
        // Self-heal: if isBusy is set but no task is actually running (a prior
        // run() crashed or never reached `isBusy=false`), clear the flag so a
        // new transfer can proceed. The authoritative check is whether any
        // task currently has status==.running — if none, no one's working.
        if isBusy && !activeTasks.contains(where: { $0.status == .running }) {
            isBusy = false
            runningTaskID = nil
        }
        guard !isBusy else { return }
        guard let idx = activeTasks.firstIndex(where: { $0.status == .queued }) else { return }
        let task = activeTasks[idx]
        guard let peer = pendingPeers[task.id] else {
            // Shouldn't happen, but be safe.
            activeTasks.remove(at: idx)
            return
        }
        isBusy = true
        Task { [weak self] in
            // `defer` guarantees isBusy clears even if run() throws or is
            // cancelled — prevents the queue from getting permanently stuck.
            defer {
                Task { @MainActor [weak self] in
                    self?.isBusy = false
                    self?.startNextIfIdle()
                }
            }
            await self?.run(task, peer: peer)
        }
    }

    // MARK: - Task execution

    private func run(_ task: TransferTask, peer: Peer) async {
        // 1. Mark running.
        guard let runningIdx = activeTasks.firstIndex(where: { $0.id == task.id }) else { return }
        activeTasks[runningIdx].status = .running
        activeTasks[runningIdx].startedAt = Date()
        runningTaskID = task.id

        // 2. Verify the peer's last-known IP is actually reachable. Discovery
        //    runs every 5s; if the cable was just replugged the registry IP
        //    can be stale (kernel route flush → "No route to host"). Probe and
        //    fall back to a forced re-discovery via freshPeerProvider.
        let livePeer: Peer
        do {
            livePeer = try await ensureReachable(peer: peer)
        } catch {
            await finalize(taskID: task.id,
                           exitCode: 1,
                           stderrTail: "Pre-flight failed: \(error.localizedDescription)")
            return
        }

        // 3. Resolve peer target — prefer the discovered TB IP over a .local hostname.
        let target: String = livePeer.lastSeenIP ?? livePeer.lastKnownHostname
        let userTarget = "\(livePeer.sshUsername)@\(target)"
        let sshOpts = Self.buildSSHOptions(for: livePeer)
        let sshCmd = "ssh \(sshOpts)"

        // 3b. If the peer opted into trusted mode, spin up a rsync --daemon on
        //     the peer for plain-TCP (no AES) transfer. SSH still does the
        //     preflight + progress polling — only the bulk data path is plain.
        var daemon: DaemonTransport? = nil
        if livePeer.trustedMode {
            let transport = DaemonTransport()
            do {
                try await transport.start(peer: livePeer)
                daemon = transport
            } catch {
                await finalize(taskID: task.id,
                               exitCode: 1,
                               stderrTail: "Trusted-mode startup failed: \(error.localizedDescription)")
                return
            }
        }
        // Ensure the daemon is torn down on every exit path from here.
        defer { daemon?.close() }

        // 4. Pre-flight: ensure destination exists.
        do {
            try await preflight(task: task, peer: livePeer, sshOpts: sshOpts, userTarget: userTarget)
        } catch {
            await finalize(taskID: task.id,
                           exitCode: 1,
                           stderrTail: "Pre-flight failed: \(error.localizedDescription)")
            return
        }

        // 5. Estimate totalBytes (best-effort; missing total is non-fatal).
        let total = await estimateTotalBytes(task: task, sshOpts: sshOpts, userTarget: userTarget)
        if total > 0, let idx = activeTasks.firstIndex(where: { $0.id == task.id }) {
            activeTasks[idx].totalBytes = total
        }

        // 6. Build the per-source pipelines and run them sequentially.
        //    (xargs gives us 16-way parallelism within each directory source already.)
        var aggregatedStderrTail = ""
        var firstFailureExitCode: Int32 = 0

        for source in task.sources {
            // Refresh task to check for cancellation between sources.
            if let idx = activeTasks.firstIndex(where: { $0.id == task.id }),
               activeTasks[idx].status == .cancelled {
                await finalize(taskID: task.id, exitCode: 130, stderrTail: aggregatedStderrTail)
                return
            }

            let pipeline = buildPipeline(direction: task.direction,
                                         source: source,
                                         destination: task.destination,
                                         userTarget: userTarget,
                                         sshCmd: sshCmd,
                                         daemonPeerIP: daemon != nil ? livePeer.lastSeenIP : nil)

            // Kick off a polling task that updates bytesTransferred every 500ms.
            let pollTask = Task { [weak self] in
                await self?.pollProgress(taskID: task.id,
                                         direction: task.direction,
                                         destination: task.destination,
                                         sshOpts: sshOpts,
                                         userTarget: userTarget)
            }

            let (exitCode, stderrTail) = await runBashPipeline(pipeline, taskID: task.id)
            pollTask.cancel()

            // One final progress poll so the bar reflects the finished state.
            await updateProgressOnce(taskID: task.id,
                                     direction: task.direction,
                                     destination: task.destination,
                                     sshOpts: sshOpts,
                                     userTarget: userTarget)

            if exitCode != 0 {
                firstFailureExitCode = exitCode
                aggregatedStderrTail = stderrTail
                break // Stop on first failure.
            }
        }

        await finalize(taskID: task.id, exitCode: firstFailureExitCode, stderrTail: aggregatedStderrTail)
    }

    // MARK: - Reachability probe

    /// Verify the peer is reachable on its currently-known IP. If not, ask the
    /// host app to refresh discovery (via `freshPeerProvider`) and try again
    /// with whatever IP the new scan produced. Returns the (possibly updated)
    /// `Peer`. Throws a preflight error if still unreachable after the refresh.
    private func ensureReachable(peer: Peer) async throws -> Peer {
        // Step 1: TCP probe to <ip>:22 with 2s timeout.
        if let ip = peer.lastSeenIP, !ip.isEmpty,
           await Self.tcpProbe(host: ip, port: 22, timeoutMillis: 2000) {
            return peer
        }

        // Step 2: ask the host app to re-run discovery + reconcile, then look the
        //    peer up by its stable id. Provider may be nil in tests / detached use.
        guard let provider = freshPeerProvider else {
            throw TransferError.preflight(
                "Peer unreachable at \(peer.lastSeenIP ?? "<no IP>") (no refresh hook available)"
            )
        }

        guard let refreshed = await provider(peer.id) else {
            throw TransferError.preflight(
                "Peer unreachable and was not rediscovered after refresh"
            )
        }

        // Step 3: probe the refreshed IP. If still no luck, surface a clear message.
        if let ip = refreshed.lastSeenIP, !ip.isEmpty,
           await Self.tcpProbe(host: ip, port: 22, timeoutMillis: 2000) {
            return refreshed
        }

        throw TransferError.preflight(
            "Peer unreachable at \(refreshed.lastSeenIP ?? "<no IP>") after rediscovery"
        )
    }

    /// Open a TCP connection to `host:port` and wait up to `timeoutMillis`.
    /// Returns true if the connection reached `.ready` (host accepted), false
    /// on failure or timeout. Uses Network.framework rather than spawning a
    /// `nc` subprocess — cheaper and Sendable-clean.
    fileprivate static func tcpProbe(host: String, port: Int, timeoutMillis: Int) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)

        // TCP-only parameters with a short connect timeout. We don't tolerate
        // long blocking syscalls here — this is a fast pre-flight check.
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, (timeoutMillis + 999) / 1000)
        let params = NWParameters(tls: nil, tcp: tcp)
        params.prohibitedInterfaceTypes = [.loopback]

        let connection = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue.global(qos: .userInitiated)

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            // Sendable box so we can mark resumption exactly once from either
            // the state handler or the timeout deadline.
            let resumed = AtomicBox()

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

    private func finalize(taskID: UUID, exitCode: Int32, stderrTail: String) async {
        runningProcess = nil
        runningTaskID = nil
        // Capture the peer label BEFORE we drop the pendingPeers entry so the
        // completion notification can include it.
        let peerLabel = pendingPeers[taskID]?.displayName ?? "peer"
        pendingPeers.removeValue(forKey: taskID)

        guard let idx = activeTasks.firstIndex(where: { $0.id == taskID }) else { return }
        var task = activeTasks.remove(at: idx)

        if task.status == .cancelled {
            // Already marked cancelled by cancel(id:); just finalize timestamps.
            task.completedAt = Date()
        } else if exitCode == 0 {
            task.status = .completed
            task.completedAt = Date()
            // Make sure the bar shows 100% on success even if du polling lagged.
            if task.totalBytes > 0 {
                task.bytesTransferred = task.totalBytes
            }
        } else {
            task.status = .failed
            task.completedAt = Date()
            task.error = String(stderrTail.suffix(200))
        }

        postCompletionNotification(task: task, peerLabel: peerLabel)
        completedTasks.insert(task, at: 0)
    }

    /// Post a UserNotification on transfer completion / failure. Cancellation is
    /// silent (the user already knows they pressed cancel). Notification body
    /// includes the source filename(s), the peer label, and either the elapsed
    /// time/throughput (success) or the error tail (failure).
    private func postCompletionNotification(task: TransferTask, peerLabel: String) {
        let content = UNMutableNotificationContent()
        let firstSource = task.sources.first.map { ($0 as NSString).lastPathComponent } ?? "<unknown>"
        let nMore = max(0, task.sources.count - 1)
        let sourceDesc = nMore > 0 ? "\(firstSource) (+\(nMore) more)" : firstSource

        switch task.status {
        case .completed:
            content.title = "Transfer complete"
            var bodyParts: [String] = ["\(sourceDesc) → \(peerLabel)"]
            if let elapsed = task.elapsedSeconds, elapsed > 0 {
                bodyParts.append(Self.formatDuration(elapsed))
            }
            if let bps = task.throughputBytesPerSecond, bps > 0 {
                bodyParts.append(Self.formatThroughput(bps))
            }
            content.body = bodyParts.joined(separator: " • ")
        case .failed:
            content.title = "Transfer failed"
            let errLine = task.error?.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            content.body = "\(sourceDesc) → \(peerLabel)\n\(errLine)"
        default:
            return  // .cancelled / .queued / .running / .paused — no notification.
        }
        content.sound = .default

        let req = UNNotificationRequest(
            identifier: task.id.uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let secs = total % 60
        if minutes < 60 { return "\(minutes)m \(secs)s" }
        let hours = minutes / 60
        return "\(hours)h \(minutes % 60)m"
    }

    private static func formatThroughput(_ bytesPerSecond: Double) -> String {
        let mb = bytesPerSecond / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.2f GB/s", mb / 1024)
        }
        return String(format: "%.0f MB/s", mb)
    }

    // MARK: - Pre-flight

    // Fix for AUDIT bug 1: preflight() and estimateTotalBytes() previously used
    // `ShellRunner.run`, whose Process never escapes. So `cancel(id:)` could not
    // kill a hung SSH handshake — the cancel only marked the status flag and
    // then waited up to 15 s for SSH's own timeout. Now both call sites use
    // `runCancellableShell`, which mirrors `runBashPipeline`'s pattern:
    // the Process is parked in `runningProcess` while it runs, so
    // `cancel(id:)` can terminate it immediately.
    private func preflight(task: TransferTask,
                           peer: Peer,
                           sshOpts: String,
                           userTarget: String) async throws {
        switch task.direction {
        case .push:
            // Make remote destination directory.
            // `~/` in destination must expand to remote $HOME — use the
            // remote-aware quoter so `mkdir -p ~/Foo` doesn't create a
            // literal `~` directory.
            let cmd = "ssh \(sshOpts) \(Self.shellQuote(userTarget)) \(Self.shellQuote("mkdir -p \(Self.shellQuoteRemotePath(task.destination))"))"
            let result = await runCancellableShell(cmd, timeout: 15)
            if result.exitCode != 0 {
                throw TransferError.preflight("Cannot reach peer: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        case .pull:
            // Expand `~` for FileManager (which doesn't auto-expand). The
            // remote-side rsync arg below stays as the user-typed string —
            // bash -c handles `~` expansion on the local rsync invocation too.
            try FileManager.default.createDirectory(
                atPath: PathExpander.absolute(task.destination),
                withIntermediateDirectories: true
            )
            // Light SSH probe so we fail fast if the peer is unreachable.
            let cmd = "ssh \(sshOpts) \(Self.shellQuote(userTarget)) true"
            let result = await runCancellableShell(cmd, timeout: 15)
            if result.exitCode != 0 {
                throw TransferError.preflight("Cannot reach peer: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    // MARK: - Size estimation

    // Fix for AUDIT bug 1: see note on preflight() — these SSH/du calls also
    // run via `runCancellableShell` so a Cancel pressed during estimation
    // terminates the subprocess immediately instead of waiting on the timeout.
    private func estimateTotalBytes(task: TransferTask,
                                    sshOpts: String,
                                    userTarget: String) async -> Int64 {
        switch task.direction {
        case .push:
            var sumKB: Int64 = 0
            for source in task.sources {
                let cmd = "du -sk \(Self.shellQuote(source))"
                let result = await runCancellableShell(cmd, timeout: 30)
                if result.exitCode == 0, let kb = Self.parseLeadingInt64(result.stdout) {
                    sumKB += kb
                }
            }
            return sumKB * 1024
        case .pull:
            // One ssh call: du -sck <sources...> | tail -1
            // Sources are REMOTE paths — use the remote-aware quoter so any
            // `~/` in them expands against the peer's $HOME, not stays literal.
            let quotedSources = task.sources.map(Self.shellQuoteRemotePath).joined(separator: " ")
            let inner = "du -sck \(quotedSources) | tail -1"
            let cmd = "ssh \(sshOpts) \(Self.shellQuote(userTarget)) \(Self.shellQuote(inner))"
            let result = await runCancellableShell(cmd, timeout: 60)
            guard result.exitCode == 0, let kb = Self.parseLeadingInt64(result.stdout) else {
                return 0
            }
            return kb * 1024
        }
    }

    // MARK: - Cancellable shell helper

    /// Result triple returned by `runCancellableShell`.
    private struct ShellOutcome: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    // Fix for AUDIT bug 1: short-lived shell helper that parks its Process in
    // `runningProcess` so `cancel(id:)` can terminate it. Mirrors the structure
    // of `runBashPipeline`. Unlike `ShellRunner.run`, the Process is reachable
    // for the duration of the call, which is what makes Cancel responsive
    // during the pre-flight / size-estimation phases.
    //
    // Implementation notes:
    //   - stdout and stderr are collected via thread-safe accumulators.
    //   - We rely solely on the readability handlers for draining the pipes
    //     (no post-exit `readToEnd`), so we don't hit the same race that bug 2
    //     describes for `runBashPipeline`. EOF is signalled by an empty-data
    //     callback per Apple's contract; we use a DispatchSemaphore to wait
    //     for both pipes to drain before returning.
    //   - The optional `timeout` schedules a SIGTERM + SIGKILL escalation
    //     equivalent to what `ShellRunner.run` does internally.
    private func runCancellableShell(_ pipeline: String, timeout: TimeInterval? = nil) async -> ShellOutcome {
        // StderrCollector is a generic thread-safe capped string accumulator
        // (4 KB suffix). The name is historical — we're using it for both
        // stdout and stderr here. The 4 KB cap is fine for our callers
        // (`du -sk`/`du -sck` produce a single-line numeric+path output,
        // and `mkdir -p`/`true` produce nothing on success).
        let stdoutCollector = StderrCollector()
        let stderrCollector = StderrCollector()

        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", pipeline]
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Each pipe gets its own EOF signal — the readability handler fires
        // with an empty `availableData` when the writer closes the descriptor.
        let stdoutDrained = DispatchSemaphore(value: 0)
        let stderrDrained = DispatchSemaphore(value: 0)

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                stdoutDrained.signal()
            } else {
                stdoutCollector.append(String(decoding: data, as: UTF8.self))
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                stderrDrained.signal()
            } else {
                stderrCollector.append(String(decoding: data, as: UTF8.self))
            }
        }

        runningProcess = process

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            if runningProcess === process {
                runningProcess = nil
            }
            return ShellOutcome(exitCode: 127, stdout: "", stderr: "Failed to launch bash: \(error.localizedDescription)")
        }

        // Schedule the timeout — mirrors ShellRunner.run's behavior so callers
        // that previously relied on a 15/30/60 s ceiling still see one.
        // Captures `process` strongly, matching the existing pattern in
        // `ShellRunner.run` and `TransferEngine.escalateTerminate`. The closure
        // is short-lived (fires once and exits) so the strong ref doesn't
        // meaningfully extend the Process lifetime.
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                    Self.escalateTerminate(process)
                }
            }
        }

        // Wait for the process to exit on a background queue.
        let exitCode: Int32 = await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                cont.resume(returning: process.terminationStatus)
            }
        }

        // Wait for the handlers to see EOF (a short bound — if the handler
        // never gets the empty callback because the kernel closed the pipe
        // before we could install the handler, the timeout protects us).
        // Hop the wait onto a background queue so we don't block the actor.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = stdoutDrained.wait(timeout: .now() + 2.0)
                _ = stderrDrained.wait(timeout: .now() + 2.0)
                cont.resume()
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        if runningProcess === process {
            runningProcess = nil
        }

        return ShellOutcome(
            exitCode: exitCode,
            stdout: stdoutCollector.snapshot(),
            stderr: stderrCollector.snapshot()
        )
    }

    // MARK: - Pipeline construction

    /// Locate the best rsync binary. Prefer Homebrew's GNU rsync (3.x) for
    /// `--no-compress`, `--info=progress2`, and other modern flags; fall back
    /// to Apple's `/usr/bin/rsync` (openrsync, 2.6.9-compatible) and use only
    /// flags that BSD/openrsync accepts.
    static let rsyncBinary: (path: String, isGNU: Bool) = {
        let candidates = ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync", "/opt/local/bin/rsync"]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return (p, true)
        }
        return ("/usr/bin/rsync", false)
    }()

    private func buildPipeline(direction: TransferTask.Direction,
                               source: String,
                               destination: String,
                               userTarget: String,
                               sshCmd: String,
                               daemonPeerIP: String?) -> String {
        let (rsyncPath, isGNU) = Self.rsyncBinary
        let rsyncFlags = isGNU
            ? "-aWL --inplace --no-compress --partial"
            : "-aWL --inplace --partial"

        // Trusted mode: rsync connects directly to `rsync://<peer-ip>:<port>/`
        // — no SSH wrapper, no AES bottleneck. Saves the `-e ssh ...` part.
        let useDaemon = daemonPeerIP != nil
        let rsyncEsc = useDaemon
            ? "\(rsyncPath) \(rsyncFlags)"
            : "\(rsyncPath) \(rsyncFlags) -e \(Self.shellQuote(sshCmd))"

        func remoteURL(subpath: String) -> String {
            if let peerIP = daemonPeerIP {
                return DaemonTransport.url(peerIP: peerIP, subpath: subpath)
            }
            return "\(userTarget):\(subpath)"
        }

        switch direction {
        case .push:
            // `source` is LOCAL — expand a leading `~` against THIS Mac's home
            // before single-quoting (single quotes would otherwise keep `~`
            // literal, so rsync would look for a "~" directory). The REMOTE
            // `destination` keeps its `~`, expanded peer-side by the shell
            // (SSH) or the daemon's `home` module (trusted mode).
            let localSource = PathExpander.absolute(source)
            let isDir = Self.isLocalDirectory(localSource)
            if isDir {
                let qSrc = Self.shellQuote(localSource)
                let qRemote = Self.shellQuote(remoteURL(subpath: destination) + "/")
                return """
                ls -1A \(qSrc) | xargs -P 16 -I{} \(rsyncEsc) \(qSrc)/"{}" \(qRemote)
                """
            } else {
                let qSrc = Self.shellQuote(localSource)
                let qRemote = Self.shellQuote(remoteURL(subpath: destination) + "/")
                return "\(rsyncEsc) \(qSrc) \(qRemote)"
            }
        case .pull:
            // `destination` is LOCAL — expand `~` against THIS Mac's home so it
            // matches the dir the pull pre-flight `mkdir -p`'d (and isn't a
            // literal "~"). The REMOTE `source` keeps its `~` for peer-side
            // expansion.
            let qRemote = Self.shellQuote(remoteURL(subpath: source))
            let qDest = Self.shellQuote(PathExpander.absolute(destination) + "/")
            return "\(rsyncEsc) \(qRemote) \(qDest)"
        }
    }

    // MARK: - Bash pipeline execution (with Process capture)

    /// Runs `/bin/bash -c <pipeline>`, streaming stderr (we don't care about stdout
    /// for progress — `du` polling handles that). Stores the Process into
    /// `runningProcess` so `cancel(id:)` can terminate it.
    private func runBashPipeline(_ pipeline: String, taskID: UUID) async -> (Int32, String) {
        // Use a detached task to host the Process; hop back to MainActor for state updates.
        let stderrCollector = StderrCollector()

        // We need a way to capture the Process synchronously so cancel() works.
        // Build the Process here on the MainActor, hand it off to a detached task to wait.
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", pipeline]
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Fix for AUDIT bug 2: previously the code combined a stderr
        // readability handler with a post-exit `readToEnd()`. Setting
        // `readabilityHandler = nil` does NOT synchronize with a handler
        // already in flight on its dispatch queue, so the final chunk of
        // stderr could be appended via the handler AND/OR via readToEnd,
        // producing either duplicate or truncated `task.error` text.
        //
        // The fix keeps the readability handler (required to avoid pipe-buffer
        // deadlock on long-running rsync that emits >16 KB of stderr) and adds
        // a DispatchSemaphore that the handler signals when it sees the EOF
        // callback (empty `availableData`). We wait for that signal (with a
        // short safety timeout) before returning, then clear the handler.
        // `readToEnd()` is no longer used here — the handler drains everything.
        let stderrDrained = DispatchSemaphore(value: 0)
        let stdoutDrained = DispatchSemaphore(value: 0)

        // Drain stdout silently (avoid pipe-buffer deadlock on noisy rsync).
        // Signal EOF the same way as stderr so we know it's fully consumed.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                stdoutDrained.signal()
            }
            // else: drop the bytes on the floor; we don't need stdout here.
        }
        // Collect stderr lines for the failure message.
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                stderrDrained.signal()
            } else {
                let text = String(decoding: data, as: UTF8.self)
                stderrCollector.append(text)
            }
        }

        runningProcess = process

        do {
            try process.run()
        } catch {
            runningProcess = nil
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return (127, "Failed to launch bash: \(error.localizedDescription)")
        }

        // Wait on a background queue so we don't block the actor.
        let exitCode: Int32 = await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                cont.resume(returning: process.terminationStatus)
            }
        }

        // Fix for AUDIT bug 2: wait for both pipe readers to observe EOF
        // before tearing down the handlers. Done on a background queue so we
        // don't block the MainActor on the semaphore. The 2 s ceiling guards
        // against the rare case where the EOF callback never lands (e.g. the
        // kernel closed the pipe before the handler was installed).
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = stdoutDrained.wait(timeout: .now() + 2.0)
                _ = stderrDrained.wait(timeout: .now() + 2.0)
                cont.resume()
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        // Suppress this task's reference to the Process; cancel() needs it cleared.
        if runningProcess === process {
            runningProcess = nil
        }

        return (exitCode, stderrCollector.snapshot())
    }

    // MARK: - Progress polling via du

    private func pollProgress(taskID: UUID,
                              direction: TransferTask.Direction,
                              destination: String,
                              sshOpts: String,
                              userTarget: String) async {
        while !Task.isCancelled {
            await updateProgressOnce(taskID: taskID,
                                     direction: direction,
                                     destination: destination,
                                     sshOpts: sshOpts,
                                     userTarget: userTarget)
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
        }
    }

    private func updateProgressOnce(taskID: UUID,
                                    direction: TransferTask.Direction,
                                    destination: String,
                                    sshOpts: String,
                                    userTarget: String) async {
        let cmd: String
        switch direction {
        case .push:
            // The polled destination is REMOTE — `~/` must expand to peer's $HOME.
            let inner = "du -sk \(Self.shellQuoteRemotePath(destination))"
            cmd = "ssh \(sshOpts) \(Self.shellQuote(userTarget)) \(Self.shellQuote(inner))"
        case .pull:
            // Local du — expand `~` Swift-side because FileManager / local bash
            // both work with the already-expanded absolute path.
            cmd = "du -sk \(Self.shellQuote(PathExpander.absolute(destination)))"
        }

        guard let result = try? await ShellRunner.run("/bin/bash", ["-c", cmd], timeout: 3),
              result.ok,
              let kb = Self.parseLeadingInt64(result.stdout) else {
            return
        }
        let bytes = kb * 1024
        if let idx = activeTasks.firstIndex(where: { $0.id == taskID }) {
            // Only ever increase — never let a slow `du` rewind the progress bar.
            if bytes > activeTasks[idx].bytesTransferred {
                // Replace the whole element instead of mutating in place via
                // subscript. SwiftUI's `@Observable` macro reliably re-renders
                // on element assignment (`activeTasks[i] = x`) but can miss
                // a struct-property mutation behind a subscript on certain
                // build configurations. This guarantees the progress bar and
                // bytes counter follow the polling tick.
                var updated = activeTasks[idx]
                updated.bytesTransferred = bytes
                activeTasks[idx] = updated
            }
        }
    }

    // MARK: - Helpers

    private static func buildSSHOptions(for peer: Peer) -> String {
        var parts: [String] = []
        if let key = peer.sshKeyPath, !key.isEmpty {
            parts.append("-i \(shellQuote(key))")
        }
        parts.append("-c aes128-gcm@openssh.com")
        parts.append("-o Compression=no")
        parts.append("-o ControlMaster=no")
        // Stable per-peer host-key alias + dedicated known_hosts — survives
        // link-local IP reuse that would otherwise hard-fail the transfer.
        parts.append(SSHHelper.hostKeyOptionString(for: peer))
        parts.append("-o ConnectTimeout=5")
        return parts.joined(separator: " ")
    }

    /// Single-quote a path for safe use in a bash command.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Shell-quote a path that may start with `~/`, designed for commands sent
    /// to a REMOTE shell over ssh. Plain `shellQuote` wraps in single quotes
    /// which suppresses `~` expansion, so `du -sk '~/foo'` looks at a literal
    /// `~` directory and fails. This emits `"$HOME"/'<rest-quoted>'` instead —
    /// `$HOME` expands inside the double quotes, and the rest of the path
    /// stays safely single-quoted against spaces/specials.
    /// Examples:
    ///   `~/TBTransfer-Inbox` → `"$HOME"/'TBTransfer-Inbox'`
    ///   `~`                  → `"$HOME"`
    ///   `/Users/x/foo bar`   → `'/Users/x/foo bar'`  (unchanged)
    static func shellQuoteRemotePath(_ s: String) -> String {
        if s == "~" { return "\"$HOME\"" }
        if s.hasPrefix("~/") {
            let rest = String(s.dropFirst(2))
            return "\"$HOME\"/" + shellQuote(rest)
        }
        return shellQuote(s)
    }

    private static func parseLeadingInt64(_ s: String) -> Int64? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Take the last line (handles cases like `du -sck ... | tail -1` or multi-line stdout).
        let lastLine = trimmed.split(whereSeparator: \.isNewline).last.map(String.init) ?? trimmed
        // First whitespace-separated field.
        let firstField = lastLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? lastLine
        return Int64(firstField)
    }

    private static func isLocalDirectory(_ path: String) -> Bool {
        // Expand `~` before asking FileManager — it does NOT auto-expand.
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: PathExpander.absolute(path),
            isDirectory: &isDir
        )
        return exists && isDir.boolValue
    }
}

// MARK: - Errors

private enum TransferError: LocalizedError {
    case preflight(String)

    var errorDescription: String? {
        switch self {
        case .preflight(let msg): return msg
        }
    }
}

// MARK: - One-shot atomic flag

/// Single-writer flag used by `tcpProbe` to make sure the continuation is
/// resumed exactly once (state handler can race with the timeout deadline).
private final class AtomicBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    /// Atomically set the flag to true if it wasn't already; returns true on
    /// the unique caller that won the race.
    func setIfFalse() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if flag { return false }
        flag = true
        return true
    }
}

// MARK: - Stderr collector

/// Thread-safe stderr accumulator for the bash pipeline. Keeps only the tail.
private final class StderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: String = ""
    private let maxLen = 4096

    func append(_ chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        if buffer.count > maxLen {
            buffer = String(buffer.suffix(maxLen))
        }
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
