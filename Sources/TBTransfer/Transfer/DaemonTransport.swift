import Foundation
import Network

/// Plain-TCP rsync daemon transport for peers marked `trustedMode = true`.
///
/// Why this exists:
///   SSH-tunneled rsync is bottlenecked by per-connection AES, which caps a
///   single rsync stream at ~700 MB/s on TB5 even on Apple Silicon's hardware
///   AES. The rsync daemon protocol uses raw TCP — no encryption — and a
///   single stream can saturate the TB Bridge driver at 2+ GB/s.
///
/// Security:
///   The daemon listens on a high port, bound to the peer's TB-Bridge IP,
///   with hosts allow restricted to the source's TB IP. There is no
///   authentication beyond that IP restriction. The threat model is "trusted
///   point-to-point cable" — appropriate for direct TB but **never** safe
///   over Wi-Fi or Ethernet. The `trustedMode` flag on Peer is the user's
///   explicit acknowledgment of this trade-off.
///
/// Lifecycle:
///   1. SSH into the peer, spawning `rsync --daemon --no-detach --port <P>
///      --config /dev/stdin <<EOF ... EOF`. The daemon runs in foreground,
///      so when we close the SSH connection, sshd kills the daemon.
///   2. Wait briefly (200ms) for the daemon to bind the port.
///   3. Caller runs `rsync rsync://<peer-IP>:<P>/<module>/<path>` over plain TCP.
///   4. Caller calls `close()` to terminate the SSH session (and the daemon).
@MainActor
final class DaemonTransport {
    /// rsync daemon module name we create on the peer. Maps to `~` on the peer.
    nonisolated static let moduleName = "home"
    /// TCP port the daemon listens on. Chosen to avoid common service ports
    /// but be high enough to bind without root.
    nonisolated static let port: Int = 8730

    enum TransportError: Error, LocalizedError {
        case sshLaunchFailed(String)
        case daemonNeverBound(String)
        case gnuRsyncMissing

        var errorDescription: String? {
            switch self {
            case .sshLaunchFailed(let s):
                return "Couldn't start rsync daemon on peer via SSH: \(s)"
            case .daemonNeverBound(let s):
                return "rsync daemon didn't bind port \(DaemonTransport.port) on peer: \(s)"
            case .gnuRsyncMissing:
                return "Trusted mode requires GNU rsync on the peer (Apple's openrsync " +
                       "at /usr/bin/rsync doesn't support --daemon). " +
                       "On the peer: `brew install rsync`. Then re-enable Trusted Mode."
            }
        }
    }

    /// Live SSH session that's hosting the rsync daemon. Killed by `close()`
    /// or by deinit. The daemon dies when SSH dies (no-detach mode).
    private var sessionProcess: Process?

    /// Start a daemon on `peer` and return when its port is listening (or
    /// throw). `hosts allow` restricts to 169.254.0.0/16 — link-local IPs are
    /// physically reachable only over a directly-attached TB cable, which is
    /// the intended threat model.
    func start(peer: Peer) async throws {
        guard let peerIP = peer.lastSeenIP, !peerIP.isEmpty else {
            throw TransportError.sshLaunchFailed("peer has no lastSeenIP")
        }

        // Precheck: confirm GNU rsync (3.x) is installed on the peer. Apple's
        // openrsync at /usr/bin/rsync is a client-only reimplementation and
        // does NOT support --daemon. Without GNU rsync we can't bring up the
        // listener, so fail fast with a clear remediation message.
        let rsyncPath = await findRemoteGnuRsync(peer: peer, peerIP: peerIP)
        guard let remoteRsync = rsyncPath else {
            throw TransportError.gnuRsyncMissing
        }

        // Compose rsyncd.conf. `use chroot = no` avoids needing root.
        // `read only = no` for pushes. `hosts allow = 169.254.0.0/16` scopes to
        // link-local — RFC-3927 addresses are only routable on directly-attached
        // links, so this is effectively "trust anyone on the TB cable".
        // `path` is filled in below via shell expansion of $HOME.
        let conf = """
        use chroot = no
        read only = no
        hosts allow = 169.254.0.0/16
        hosts deny = *
        max connections = 32
        # lock/pid/log MUST be in a path the unprivileged user owns. The
        # defaults (/var/run/rsyncd.{lock,pid}) require root.
        lock file = /tmp/tbtransfer-rsyncd.lock
        log file = /tmp/tbtransfer-rsyncd.log
        pid file = /tmp/tbtransfer-rsyncd.pid

        [\(Self.moduleName)]
            path = HOMEPLACEHOLDER
            read only = no
            list = no
            comment = TBTransfer trusted mode
        """

        // Bash on the peer expands $HOME at run time; we substitute it server-side.
        // The whole conf is written to a temp file by the peer's shell, then
        // rsync --daemon --no-detach --config <tempfile> --port <P>.
        let bashScript = """
        set -e
        TMPCONF=$(mktemp /tmp/tbtransfer-rsyncd.XXXXXX.conf)
        cat > "$TMPCONF" <<'EOF_CONF'
        \(conf)
        EOF_CONF
        # Sub $HOME into the path line now that the file exists.
        sed -i.bak "s|HOMEPLACEHOLDER|$HOME|" "$TMPCONF" && rm -f "$TMPCONF.bak"
        # Kill any previous daemon we left behind (best effort).
        [ -f /tmp/tbtransfer-rsyncd.pid ] && kill "$(cat /tmp/tbtransfer-rsyncd.pid)" 2>/dev/null || true
        # Run in foreground so this SSH session controls its lifecycle.
        # Use the GNU rsync path we located in the precheck — Apple's openrsync
        # at /usr/bin/rsync does NOT implement --daemon.
        exec \(remoteRsync) --daemon --no-detach --port \(Self.port) --config "$TMPCONF" --address \(peerIP)
        """

        // Build the ssh argv. We deliberately DO NOT use SSHHelper.sshCommand
        // (which has ControlMaster=auto) — sharing this long-lived control
        // channel with short-lived commands causes weird hangs. Build our own.
        var argv: [String] = ["/usr/bin/ssh"]
        argv += ["-o", "ConnectTimeout=4"]
        argv += SSHHelper.hostKeyArgv(for: peer)
        argv += ["-o", "BatchMode=yes"]
        argv += ["-c", "aes128-gcm@openssh.com"]
        if let keyPath = peer.sshKeyPath {
            argv += ["-i", expandTilde(keyPath)]
            argv += ["-o", "IdentitiesOnly=yes"]
        }
        argv.append("\(peer.sshUsername)@\(peerIP)")
        argv.append("bash -s")

        // Spawn ssh, pipe the bash script in via stdin.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw TransportError.sshLaunchFailed(error.localizedDescription)
        }
        sessionProcess = process

        // Feed the bash script and close stdin so `bash -s` starts executing.
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data(bashScript.utf8))
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            close()
            throw TransportError.sshLaunchFailed("stdin write failed: \(error.localizedDescription)")
        }

        // Poll the port for up to 3s waiting for the daemon to bind.
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if await Self.tcpProbe(host: peerIP, port: Self.port, timeoutMillis: 200) {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // If we got here, the daemon never bound. Grab any stderr to surface.
        let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errMsg = String(decoding: errData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        close()
        throw TransportError.daemonNeverBound(errMsg.isEmpty ? "timed out" : errMsg)
    }

    /// Build the `rsync://` URL for pushing to (or pulling from) this transport.
    /// `subpath` is appended after the module — e.g. `subpath = "Downloads/x.dmg"`
    /// yields `rsync://peer:8730/home/Downloads/x.dmg`.
    static func url(peerIP: String, subpath: String) -> String {
        // Strip any leading `~/` or `/` — module paths are always module-relative.
        var trimmed = subpath
        while trimmed.hasPrefix("~/") || trimmed.hasPrefix("/") {
            trimmed = String(trimmed.dropFirst())
        }
        // `~` alone (the home dir itself) → just the module root.
        if trimmed == "~" { trimmed = "" }
        let suffix = trimmed.isEmpty ? "" : "/\(trimmed)"
        return "rsync://\(peerIP):\(port)/\(moduleName)\(suffix)"
    }

    /// Terminate the SSH session that's hosting the daemon. Safe to call
    /// multiple times.
    func close() {
        if let p = sessionProcess, p.isRunning {
            p.terminate()
            // Belt and suspenders: SIGKILL 1s later if SIGTERM didn't take.
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                _ = kill(pid, SIGKILL)
            }
        }
        sessionProcess = nil
    }

    deinit {
        if let p = sessionProcess, p.isRunning {
            p.terminate()
        }
    }

    /// Locate a GNU rsync binary on the peer via SSH. Returns the absolute
    /// path (e.g. `/opt/homebrew/bin/rsync`) or nil if only Apple's openrsync
    /// is installed. We check Homebrew (arm + intel) and MacPorts in that
    /// order and confirm the binary's `--version` mentions "rsync version 3"
    /// (openrsync identifies as "rsync 2.6.9 compatible" so we exclude it).
    private func findRemoteGnuRsync(peer: Peer, peerIP: String) async -> String? {
        var argv: [String] = ["/usr/bin/ssh"]
        argv += ["-o", "ConnectTimeout=4"]
        argv += SSHHelper.hostKeyArgv(for: peer)
        argv += ["-o", "BatchMode=yes"]
        argv += ["-c", "aes128-gcm@openssh.com"]
        if let keyPath = peer.sshKeyPath {
            argv += ["-i", expandTilde(keyPath)]
            argv += ["-o", "IdentitiesOnly=yes"]
        }
        argv.append("\(peer.sshUsername)@\(peerIP)")
        // POSIX `for`/`case`/`$(...)` script — piped to remote `sh -s` via stdin
        // rather than passed as an ssh command arg, so the peer's LOGIN shell
        // (which may be fish, and would choke on this syntax → exit 127) never
        // parses it. sh reads it from stdin and runs it correctly.
        argv += ["sh", "-s"]
        let detectScript =
            "for p in /opt/homebrew/bin/rsync /usr/local/bin/rsync /opt/local/bin/rsync; do " +
            "[ -x \"$p\" ] || continue; " +
            "v=$(\"$p\" --version 2>/dev/null | head -1); " +
            "case \"$v\" in *'rsync  version'*' 3.'*|*'rsync version 3.'*) echo \"$p\"; exit 0;; esac; " +
            "done; exit 1"
        guard let result = try? await ShellRunner.run(
            argv[0], Array(argv.dropFirst()), stdin: detectScript, timeout: 8
        ), result.ok else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// One-shot TCP probe used to wait for the daemon to bind.
    nonisolated private static func tcpProbe(host: String, port: Int, timeoutMillis: Int) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                cont.resume(returning: false); return
            }
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: nwPort,
                using: .tcp
            )
            // Atomic-once latch — keeps the captured continuation safe across
            // both the state handler (possibly multi-threaded) and the timeout.
            let latch = OneShotLatch()
            let resume: @Sendable (Bool) -> Void = { ok in
                if latch.tryFire() {
                    cont.resume(returning: ok)
                    conn.cancel()
                }
            }
            conn.stateUpdateHandler = { state in
                if case .ready = state { resume(true) }
                else if case .failed = state { resume(false) }
                else if case .cancelled = state { resume(false) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMillis)) {
                resume(false)
            }
            conn.start(queue: .global())
        }
    }
}

/// Lock-guarded boolean that returns true exactly once. Used to gate a
/// `CheckedContinuation` against double-resumption from racing callbacks.
fileprivate final class OneShotLatch: @unchecked Sendable {
    private var fired = false
    private let lock = NSLock()
    func tryFire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

fileprivate func expandTilde(_ s: String) -> String {
    guard s.hasPrefix("~") else { return s }
    let home = NSHomeDirectory()
    if s == "~" { return home }
    if s.hasPrefix("~/") { return home + String(s.dropFirst(1)) }
    return s
}
