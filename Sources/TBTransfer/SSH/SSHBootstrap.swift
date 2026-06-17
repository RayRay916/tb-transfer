import Foundation

/// One-time SSH pairing helper. Generates (or reuses) a local ed25519 keypair,
/// drives password authentication via `/usr/bin/expect`, appends the local
/// pubkey to the peer's `~/.ssh/authorized_keys`, and verifies that
/// passwordless SSH back to the peer works.
///
/// Why expect?
///   `ssh` reads its password directly from /dev/tty. There is no environment
///   variable, stdin redirection, or commandline flag for it. expect drives a
///   pty and writes the password when the prompt appears. expect ships in
///   `/usr/bin` on every stock macOS install.
///
/// Security:
///   - The password NEVER lives on disk. It is set in the parent process
///     environment as `TBTRANSFER_PEER_PASSWORD`, the expect script reads it
///     via `$env(TBTRANSFER_PEER_PASSWORD)`, and the parent clears it from
///     its own argv-derived state immediately after spawn completes.
///   - The expect script itself contains NO secrets — only the public key.
///   - Nothing is logged. No `print`, no `fputs`, no stderr/stdout dumps that
///     contain the password.
///
/// Idempotency:
///   - The install step uses `grep -qxF` so re-running this against an
///     already-paired peer is a no-op (no duplicate authorized_keys lines).
@MainActor
final class SSHBootstrap {

    // MARK: - Public types

    enum Step: Equatable, Hashable, Sendable {
        case idle
        case generatingKey
        case connecting
        case installing
        case verifying
        case success
        case failed(reason: String)
    }

    enum BootstrapError: Error, LocalizedError {
        case expectMissing
        case sshKeygenFailed(String)
        case authFailed
        case passwordAuthDisabled
        case installFailed(String)
        case verifyFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .expectMissing:
                return "/usr/bin/expect is missing — it ships preinstalled on macOS. " +
                       "Check that /usr/bin is on $PATH or that the system tools are not pruned."
            case .sshKeygenFailed(let msg):
                return "Failed to generate SSH key: \(msg)"
            case .authFailed:
                return "Authentication failed. Three likely causes — check in order:\n" +
                       "  1. Wrong username — does the remote account really exist?\n" +
                       "  2. Wrong password — try `ssh <user>@<peer>` from Terminal to confirm.\n" +
                       "  3. macOS Service ACL — System Settings → Sharing → Remote Login → 'Allow access for: All users' on the peer."
            case .passwordAuthDisabled:
                return "The peer's sshd doesn't accept password authentication " +
                       "(it advertised only publickey). Either enable PasswordAuthentication in " +
                       "/etc/ssh/sshd_config on the peer, or copy your public key into " +
                       "~/.ssh/authorized_keys on the peer manually."
            case .installFailed(let msg):
                return "Failed to install pubkey on the peer: \(msg)"
            case .verifyFailed(let msg):
                return "Passwordless SSH verification failed: \(msg)"
            case .cancelled:
                return "Pairing was cancelled."
            }
        }
    }

    // MARK: - Public API

    /// Ensure a local ed25519 keypair exists. If `path` is supplied, that
    /// private key path is used; otherwise `~/.ssh/id_ed25519`. Creates the
    /// `~/.ssh` directory (mode 0700) and the keypair (private mode 0600,
    /// public mode 0644, no passphrase) if missing.
    /// Returns the absolute (tilde-expanded) paths to the private and public keys.
    static func ensureLocalKey(path: String? = nil) async throws -> (privatePath: String, publicPath: String) {
        let privatePath = expandTilde(path ?? "~/.ssh/id_ed25519")
        let publicPath = privatePath + ".pub"

        // Make sure ~/.ssh exists with the right perms.
        let parentDir = (privatePath as NSString).deletingLastPathComponent
        if !parentDir.isEmpty {
            try FileManager.default.createDirectory(
                atPath: parentDir,
                withIntermediateDirectories: true,
                attributes: [FileAttributeKey.posixPermissions: 0o700]
            )
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: privatePath) && fm.fileExists(atPath: publicPath) {
            return (privatePath, publicPath)
        }

        // If only one of the two exists, the keypair is broken. Regenerate
        // both — but only do so if BOTH are missing. If only one is present,
        // remove the leftover to avoid ssh-keygen's "already exists" prompt.
        if fm.fileExists(atPath: privatePath) && !fm.fileExists(atPath: publicPath) {
            // Rebuild .pub from private (or just regen). Regen is simpler and
            // safer than `ssh-keygen -y -f` because we don't know if the key
            // has a passphrase. Remove the orphan private key.
            try? fm.removeItem(atPath: privatePath)
        } else if !fm.fileExists(atPath: privatePath) && fm.fileExists(atPath: publicPath) {
            try? fm.removeItem(atPath: publicPath)
        }

        // Whitelist the local hostname to alphanumerics + dash + dot. Anything
        // else (including unicode, spaces, control chars) is stripped — the
        // comment is only for human readability inside authorized_keys.
        let rawLabel = ProcessInfo.processInfo.hostName
        var hostLabel = ""
        for scalar in rawLabel.unicodeScalars {
            let ch = Character(scalar)
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "." {
                hostLabel.append(ch)
            }
        }
        if hostLabel.isEmpty { hostLabel = "mac" }
        let comment = "tbtransfer@\(hostLabel)"

        // ssh-keygen -t ed25519 -N "" -f <privatePath> -C "tbtransfer@<host>"
        let result = try await ShellRunner.run(
            "/usr/bin/ssh-keygen",
            ["-t", "ed25519", "-N", "", "-f", privatePath, "-C", comment],
            timeout: 15
        )
        if !result.ok {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = !stderr.isEmpty ? stderr : (!stdout.isEmpty ? stdout : "exit \(result.exitCode)")
            throw BootstrapError.sshKeygenFailed(msg)
        }

        // Tighten perms — ssh-keygen usually does this already, but make sure.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privatePath)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: publicPath)

        return (privatePath, publicPath)
    }

    /// Bootstrap a peer. Drives the 5-step state machine end to end. Calls
    /// `progress` on every transition. On success returns the credentials the
    /// caller should write to PeerStore.
    /// Expanded path to the app's dedicated known_hosts file. All bootstrap SSH
    /// invocations pin host keys here (under a per-peer `HostKeyAlias`) so the
    /// user's `~/.ssh/known_hosts` is never touched and link-local IP reuse
    /// can't trigger a host-key-changed hard-fail.
    static var managedKnownHosts: String { expandTilde(Peer.managedKnownHostsFile) }

    func pair(
        host: String,
        username: String,
        password: String,
        keyPath: String? = nil,
        hostKeyAlias: String,
        progress: @escaping @MainActor (Step) -> Void
    ) async throws -> (username: String, keyPath: String, remoteHome: String?) {

        // Step 1: generatingKey
        progress(.generatingKey)
        let (privatePath, publicPath): (String, String)
        do {
            (privatePath, publicPath) = try await Self.ensureLocalKey(path: keyPath)
        } catch let e as BootstrapError {
            progress(.failed(reason: e.errorDescription ?? "key generation failed"))
            throw e
        } catch {
            let msg = error.localizedDescription
            progress(.failed(reason: msg))
            throw BootstrapError.sshKeygenFailed(msg)
        }

        // Read the pubkey file's single-line content. ssh-keygen always emits
        // exactly one line ("ssh-ed25519 AAAA... comment\n").
        let pubkey: String
        do {
            let raw = try String(contentsOfFile: publicPath, encoding: .utf8)
            pubkey = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if pubkey.isEmpty {
                progress(.failed(reason: "public key file is empty"))
                throw BootstrapError.sshKeygenFailed("public key file is empty")
            }
        } catch let e as BootstrapError {
            throw e
        } catch {
            progress(.failed(reason: "failed to read public key: \(error.localizedDescription)"))
            throw BootstrapError.sshKeygenFailed(error.localizedDescription)
        }

        // Make sure expect is available before we go any further.
        if !FileManager.default.isExecutableFile(atPath: "/usr/bin/expect") {
            progress(.failed(reason: BootstrapError.expectMissing.errorDescription ?? "expect missing"))
            throw BootstrapError.expectMissing
        }

        try Task.checkCancellation()

        // Step 2: connecting (TCP reachability probe — quick fail before the
        // user wastes time on a typo'd host).
        progress(.connecting)
        if !(await tcpReachable(host: host, port: 22, timeoutSec: 3)) {
            progress(.failed(reason: "Cannot reach \(host):22 — host is offline, sshd is not running, or the address is wrong."))
            throw BootstrapError.authFailed
        }

        // Pre-flight: ask sshd which auth methods it advertises. If only
        // `publickey` is on offer, our password-based bootstrap can't work and
        // we should fail fast with a tailored message instead of letting the
        // expect script time out or report a misleading "auth failed".
        let methods = await advertisedAuthMethods(host: host, username: username, hostKeyAlias: hostKeyAlias)
        switch methods {
        case .publickeyOnly:
            progress(.failed(reason: BootstrapError.passwordAuthDisabled.errorDescription ?? "password auth disabled"))
            throw BootstrapError.passwordAuthDisabled
        case .passwordAvailable, .unknown:
            break
        }

        try Task.checkCancellation()

        // Step 3: installing — drive ssh+expect to append the pubkey.
        progress(.installing)
        do {
            try await installPubkey(host: host, username: username, password: password, pubkey: pubkey, hostKeyAlias: hostKeyAlias)
        } catch let e as BootstrapError {
            progress(.failed(reason: e.errorDescription ?? "install failed"))
            throw e
        } catch {
            let msg = error.localizedDescription
            progress(.failed(reason: msg))
            throw BootstrapError.installFailed(msg)
        }

        try Task.checkCancellation()

        // Step 4: verifying — confirm passwordless login now works, and capture
        // the peer's $HOME (the concrete value `~` resolves to for this account).
        progress(.verifying)
        let remoteHome: String?
        do {
            remoteHome = try await verifyPasswordless(host: host, username: username, privatePath: privatePath, hostKeyAlias: hostKeyAlias)
        } catch let e as BootstrapError {
            progress(.failed(reason: e.errorDescription ?? "verify failed"))
            throw e
        } catch {
            let msg = error.localizedDescription
            progress(.failed(reason: msg))
            throw BootstrapError.verifyFailed(msg)
        }

        // Step 5: success.
        progress(.success)
        return (username: username, keyPath: privatePath, remoteHome: remoteHome)
    }

    // MARK: - Unpair (full de-provision)

    /// The inverse of `pair`. Fully de-provisions a peer so that re-adding it
    /// requires the same from-scratch pairing as the very first time:
    ///   1. Tear down any live SSH multiplexing socket (best-effort).
    ///   2. For app-managed keys ONLY: strip our public key from the peer's
    ///      `~/.ssh/authorized_keys` (while still reachable), then delete the
    ///      local private + public key files.
    ///   3. Scrub the peer's host keys from `~/.ssh/known_hosts` for both the
    ///      TB IP and the `.local` hostname.
    ///
    /// SAFETY: steps that destroy keys / mutate the remote authorized_keys run
    /// ONLY when `peer.usesManagedKey` is true (the key lives under
    /// `~/.ssh/tbtransfer/`, so we generated it and own its lifecycle). A peer
    /// configured with a user-supplied or shared key is removed from the
    /// registry without ever touching that key — we must never delete a user's
    /// personal `~/.ssh/id_ed25519`.
    static func unpair(peer: Peer) async {
        // 1. Drop any live control-master socket so a future re-pair to a
        //    freshly-discovered peer doesn't ride a stale multiplexed session.
        let (closeArgv, _) = SSHHelper.sshCommand(for: peer, extraOptions: ["-O", "exit"])
        if let exe = closeArgv.first {
            _ = try? await ShellRunner.run(exe, Array(closeArgv.dropFirst()), timeout: 5)
        }

        // 2. Managed-key cleanup: strip remote authorized_keys, delete local key.
        if peer.usesManagedKey, let keyPath = peer.sshKeyPath {
            let priv = expandTilde(keyPath)
            let pub = priv + ".pub"

            // Read the pubkey BEFORE deleting so we can target the exact line.
            let host = peer.lastSeenIP ?? peer.lastKnownHostname
            if !host.isEmpty,
               let raw = try? String(contentsOfFile: pub, encoding: .utf8) {
                let pubkey = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pubkey.isEmpty {
                    await stripRemoteAuthorizedKey(peer: peer, pubkey: pubkey)
                }
            }

            // Delete the local managed keypair.
            try? FileManager.default.removeItem(atPath: priv)
            try? FileManager.default.removeItem(atPath: pub)
        }

        // 3. Scrub the peer's host key from our DEDICATED known_hosts file so a
        //    re-pair re-TOFUs cleanly. We pin host keys under a stable alias, so
        //    the alias is the primary entry; also remove any legacy IP/hostname
        //    entries. Scoped to the app file — never touches ~/.ssh/known_hosts.
        let knownHosts = managedKnownHosts
        if FileManager.default.fileExists(atPath: knownHosts) {
            let targets = ([peer.hostKeyAlias, peer.lastSeenIP, peer.lastKnownHostname]
                .compactMap { $0 })
                .filter { !$0.isEmpty }
            for target in targets {
                _ = try? await ShellRunner.run(
                    "/usr/bin/ssh-keygen", ["-f", knownHosts, "-R", target], timeout: 8
                )
            }
        }
    }

    /// Remove our exact public-key line from the peer's `~/.ssh/authorized_keys`.
    /// Best-effort — if the peer is offline the local key deletion still wins,
    /// and a stale authorized_keys line is harmless (it authorizes a key that
    /// no longer exists). Uses the peer's own key for passwordless auth.
    private static func stripRemoteAuthorizedKey(peer: Peer, pubkey: String) async {
        // ssh-keygen never emits single quotes or newlines in a pubkey line, so
        // single-quoting it for the remote `grep -vxF` is safe. Bail if somehow
        // it does, rather than risk a malformed remote command.
        guard !pubkey.contains("'"), !pubkey.contains("\n") else { return }

        // -x = whole-line, -F = fixed string. Rewrite authorized_keys without
        // our line. `;`-separated so each step runs regardless of grep's exit
        // code (grep exits 1 when it filters out every line — expected here).
        // Piped to remote `sh -s` via stdin (NOT passed as an ssh command arg)
        // so the peer's LOGIN shell — which may be fish — never parses this
        // POSIX-only script (fish chokes on `$(...)`/`[ ]`, exit 127). sh reads
        // it from stdin and the single-quoted pubkey is parsed by sh, not fish.
        let script =
            "f=\"$HOME/.ssh/authorized_keys\"; [ -f \"$f\" ] || exit 0; " +
            "tmp=$(mktemp \"$HOME/.ssh/ak.XXXXXX\") || exit 0; " +
            "grep -vxF '\(pubkey)' \"$f\" > \"$tmp\"; " +
            "cat \"$tmp\" > \"$f\"; rm -f \"$tmp\"; chmod 600 \"$f\""

        let (argv, _) = SSHHelper.sshCommand(
            for: peer, extraOptions: ["-o", "ConnectTimeout=5"]
        )
        let full = argv + ["sh", "-s"]
        guard let exe = full.first else { return }
        _ = try? await ShellRunner.run(exe, Array(full.dropFirst()), stdin: script, timeout: 12)
    }

    // MARK: - Internal: install pubkey via expect

    /// Build a temp expect script, then spawn `/usr/bin/expect` against it.
    /// The password is passed via the `TBTRANSFER_PEER_PASSWORD` env var only —
    /// it is never written to disk and never appears on argv.
    private func installPubkey(
        host: String,
        username: String,
        password: String,
        pubkey: String,
        hostKeyAlias: String
    ) async throws {
        let scriptURL = try makeExpectScript(host: host, username: username, pubkey: pubkey, hostKeyAlias: hostKeyAlias)
        defer {
            // Best-effort cleanup. We don't surface failures here.
            try? FileManager.default.removeItem(at: scriptURL)
        }

        let result: ShellRunner.Result
        do {
            result = try await ShellRunner.run(
                "/usr/bin/expect",
                ["-f", scriptURL.path],
                env: ["TBTRANSFER_PEER_PASSWORD": password],
                timeout: 45
            )
        } catch {
            throw BootstrapError.installFailed(error.localizedDescription)
        }

        // Map expect exit codes to typed errors. The expect script defines:
        //   exit 0 → success
        //   exit 2 → permission denied (bad password / wrong user)
        //   exit 3 → connection refused
        //   exit 4 → timeout
        //   exit 5 → host key verification failed
        //   else  → remote command failed; stderr explains
        switch result.exitCode {
        case 0:
            return
        case 2:
            throw BootstrapError.authFailed
        case 3:
            throw BootstrapError.installFailed("Connection refused on \(host):22. Is Remote Login enabled?")
        case 4:
            throw BootstrapError.installFailed("Timed out waiting for password prompt from \(host).")
        case 5:
            throw BootstrapError.installFailed("Host key verification failed for \(host).")
        default:
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip anything containing the username@host echo lines but keep
            // shell-level errors. Don't bother trying to scrub a password — we
            // never embed it in the script in the first place.
            let msg = !stderr.isEmpty ? stderr : (!stdout.isEmpty ? stdout : "expect exit \(result.exitCode)")
            throw BootstrapError.installFailed(msg)
        }
    }

    /// Writes the expect script to a unique file under /tmp with 0600 perms.
    /// Returns the file URL — caller is responsible for deleting it.
    private func makeExpectScript(host: String, username: String, pubkey: String, hostKeyAlias: String) throws -> URL {
        // Tcl injection guard: pubkey is base64 + algo + comment, all
        // [A-Za-z0-9+/=@. _-]. The Tcl `{ ... }` braces below treat the body
        // literally so $-substitution doesn't kick in. The pubkey is shell-
        // single-quoted on the remote command line, so the only character we
        // really need to worry about is a single quote inside the pubkey —
        // which ssh-keygen never emits.
        //
        // Username/host go through `[lindex ... 0]`-style interpolation; to be
        // safe we whitelist-check them and refuse on bad chars.
        guard isSafeIdentifier(username) else {
            throw BootstrapError.installFailed("Invalid username: \(username)")
        }
        guard isSafeHost(host) else {
            throw BootstrapError.installFailed("Invalid host: \(host)")
        }
        if pubkey.contains("'") || pubkey.contains("\n") {
            // Ed25519 pubkeys from ssh-keygen never contain these. Be paranoid.
            throw BootstrapError.installFailed("Public key contains unsafe characters.")
        }
        guard isSafeHost(hostKeyAlias) else {
            throw BootstrapError.installFailed("Invalid host-key alias: \(hostKeyAlias)")
        }
        // Make sure the dedicated known_hosts directory exists so ssh can write
        // the peer's host key under our alias (ssh won't create parent dirs).
        SSHHelper.ensureManagedSSHDirectory()
        let knownHosts = Self.managedKnownHosts

        // The remote command. CRITICAL: we wrap it in an explicit `/bin/sh -c`
        // because `ssh host "<cmd>"` runs <cmd> through the REMOTE user's LOGIN
        // shell — which on these Macs is often **fish**, and fish mis-parses a
        // POSIX compound like `a && ( b || c ) && d` (its `( )` is command
        // substitution, not a subshell), producing a "command not found"-style
        // exit 127. Forcing `/bin/sh -c '...'` means the login shell only has to
        // parse a single simple `sh -c '<script>' _ '<pubkey>'` invocation, and
        // the real logic runs in POSIX sh regardless of fish/zsh/bash.
        //
        // The pubkey is passed as a positional arg ($1), so the script body
        // needs no single quotes inside (avoids nested-quote hazards) and the
        // pubkey — validated above to contain no single quote — is safely
        // single-quoted as the trailing argument.
        // It: 1) umask 077  2) mkdir ~/.ssh  3) append pubkey iff absent
        //     (idempotent re-pairing)  4) chmod 600.
        let remoteCmd =
            "sh -c 'umask 077; mkdir -p ~/.ssh && " +
            "( grep -qxF \"$1\" ~/.ssh/authorized_keys 2>/dev/null || " +
            "echo \"$1\" >> ~/.ssh/authorized_keys ) && " +
            "chmod 600 ~/.ssh/authorized_keys' _ '\(pubkey)'"

        // Compose the expect program. Note the use of curly-brace quoting for
        // literal bodies (no $-substitution) and `set` for variables we want
        // interpolated.
        //
        // Behavior:
        //   - read password from $env(TBTRANSFER_PEER_PASSWORD) — never on disk.
        //   - send the password ONCE; if asked again, treat as auth failure.
        //   - accept new host keys (TOFU); fail on existing-mismatch.
        let script = """
        #!/usr/bin/expect -f
        log_user 0
        set timeout 30
        set sent_password 0
        set host "\(username)@\(host)"

        if {[info exists env(TBTRANSFER_PEER_PASSWORD)] == 0} {
            exit 9
        }
        set password $env(TBTRANSFER_PEER_PASSWORD)

        # The remote command is single-quoted on the ssh side, so the only
        # special chars we need to escape for Tcl are backslashes and \\$ and \\[.
        # The pubkey is whitelisted base64+algo+comment, so safe.
        set remote_cmd {\(remoteCmd)}

        spawn /usr/bin/ssh -o StrictHostKeyChecking=accept-new \\
            -o HostKeyAlias=\(hostKeyAlias) \\
            -o UserKnownHostsFile="\(knownHosts)" \\
            -o NumberOfPasswordPrompts=1 \\
            -o PubkeyAuthentication=no \\
            -o PreferredAuthentications=password,keyboard-interactive \\
            -o LogLevel=ERROR \\
            "$host" "$remote_cmd"

        expect {
            -re {(?i)password:} {
                if {$sent_password == 1} {
                    # second prompt = first password was wrong
                    exit 2
                }
                set sent_password 1
                send -- "$password\\r"
                # Re-enable output AFTER the password is sent so any remote-side
                # error (e.g. shell/command failure) is captured and surfaced
                # instead of a bare "expect exit <code>". ssh never echoes the
                # typed password, so this can't leak it.
                log_user 1
                exp_continue
            }
            -re {(?i)permission denied} {
                exit 2
            }
            -re {(?i)connection refused} {
                exit 3
            }
            -re {(?i)host key verification failed} {
                exit 5
            }
            timeout { exit 4 }
            eof
        }

        # Clear the password from this process's memory before exiting.
        set password ""
        unset password

        catch wait result
        # result is "PID SPAWNID OS_ERR_FLAG EXIT_STATUS" on normal exit.
        set exit_status [lindex $result 3]
        exit $exit_status
        """

        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("tbtransfer-pair-\(UUID().uuidString).expect")
        try script.data(using: .utf8)!.write(to: url, options: .atomic)
        // 0600 — only the user can read the script. (No secrets in it, but
        // belt-and-suspenders.)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return url
    }

    // MARK: - Internal: verify passwordless

    /// Verifies passwordless login works AND captures the peer's `$HOME` (so we
    /// have the concrete value `~` resolves to for this account). Returns the
    /// parsed remote home, or nil if it couldn't be read (verification still
    /// succeeds as long as the magic token came back). Wrapped in `/bin/sh -c`
    /// so it's robust against a fish/zsh login shell on the peer.
    private func verifyPasswordless(host: String, username: String, privatePath: String, hostKeyAlias: String) async throws -> String? {
        let magic = "TBTRANSFER_VERIFY_OK"
        let homeMarker = "TBTHOME="
        let argv = [
            "-i", privatePath,
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "BatchMode=yes",
            "-o", "HostKeyAlias=\(hostKeyAlias)",
            "-o", "UserKnownHostsFile=\(Self.managedKnownHosts)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=4",
            "-o", "IdentitiesOnly=yes",
            "-o", "LogLevel=ERROR",
            "\(username)@\(host)",
            "sh -c 'echo \(magic); echo \(homeMarker)$HOME'"
        ]

        let result: ShellRunner.Result
        do {
            result = try await ShellRunner.run("/usr/bin/ssh", argv, timeout: 10)
        } catch {
            throw BootstrapError.verifyFailed(error.localizedDescription)
        }

        guard result.exitCode == 0 && result.stdout.contains(magic) else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty ? "ssh exited \(result.exitCode)" : stderr
            throw BootstrapError.verifyFailed(detail)
        }

        // Parse the home line, if present.
        for raw in result.stdout.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(homeMarker) {
                let home = String(line.dropFirst(homeMarker.count)).trimmingCharacters(in: .whitespaces)
                if !home.isEmpty { return home }
            }
        }
        return nil
    }

    // MARK: - Internal: auth-method advertisement probe

    enum AdvertisedMethods: Sendable {
        case passwordAvailable   // password or keyboard-interactive offered
        case publickeyOnly       // only publickey — bootstrap can't proceed
        case unknown             // couldn't determine; proceed and hope
    }

    /// Ask sshd which auth methods it offers for this user. We do this by
    /// invoking ssh with `PreferredAuthentications=none` — sshd then responds
    /// with a stderr line like
    /// `Permission denied (publickey,password,keyboard-interactive).` listing
    /// the methods it WOULD have accepted. Parse it to decide whether the
    /// wizard's password-based flow is even possible.
    private func advertisedAuthMethods(host: String, username: String, hostKeyAlias: String) async -> AdvertisedMethods {
        guard let result = try? await ShellRunner.run(
            "/usr/bin/ssh",
            ["-o", "ConnectTimeout=4",
             "-o", "PreferredAuthentications=none",
             "-o", "BatchMode=yes",
             "-o", "HostKeyAlias=\(hostKeyAlias)",
             "-o", "UserKnownHostsFile=\(Self.managedKnownHosts)",
             "-o", "StrictHostKeyChecking=accept-new",
             "-o", "LogLevel=ERROR",
             "\(username)@\(host)", "exit"],
            timeout: 8
        ) else {
            return .unknown
        }
        // The "authentications that can continue" line lists methods. Some
        // sshd versions just say "Permission denied (<methods>)." instead.
        let blob = result.stderr.lowercased()
        let listSubstring: String? = {
            if let r = blob.range(of: "authentications that can continue: ") {
                return String(blob[r.upperBound...])
            }
            if let r = blob.range(of: "permission denied ("),
               let end = blob.range(of: ")", range: r.upperBound..<blob.endIndex) {
                return String(blob[r.upperBound..<end.lowerBound])
            }
            return nil
        }()
        guard let listSubstring else { return .unknown }
        let methods = listSubstring
            .split(whereSeparator: { ", \n.".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let hasPassword = methods.contains("password") || methods.contains("keyboard-interactive")
        if hasPassword { return .passwordAvailable }
        if methods.contains("publickey") { return .publickeyOnly }
        return .unknown
    }

    // MARK: - Internal: TCP reachability probe

    private func tcpReachable(host: String, port: Int, timeoutSec: Int) async -> Bool {
        // Use /usr/bin/nc -G timeout — preinstalled on macOS, doesn't depend
        // on Network.framework's DNS quirks.
        do {
            let result = try await ShellRunner.run(
                "/usr/bin/nc",
                ["-z", "-G", String(timeoutSec), host, String(port)],
                timeout: TimeInterval(timeoutSec + 2)
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }
}

// MARK: - Free helpers

fileprivate func expandTilde(_ s: String) -> String {
    guard s.hasPrefix("~") else { return s }
    let home = NSHomeDirectory()
    if s == "~" { return home }
    if s.hasPrefix("~/") {
        return home + String(s.dropFirst(1))
    }
    return s
}

/// Lowercase letters, digits, dot, dash, underscore — covers all reasonable
/// macOS usernames. Rejects anything that could be Tcl/shell metacharacters.
fileprivate func isSafeIdentifier(_ s: String) -> Bool {
    guard !s.isEmpty, s.count <= 64 else { return false }
    let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )
    return s.unicodeScalars.allSatisfy { allowed.contains($0) }
}

/// Hostnames: alphanumerics + dot + dash + colon (for IPv6) + percent (for
/// scoped IPv6). Excludes spaces, quotes, dollar, backslash, etc.
fileprivate func isSafeHost(_ s: String) -> Bool {
    guard !s.isEmpty, s.count <= 255 else { return false }
    let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:-_%"
    )
    return s.unicodeScalars.allSatisfy { allowed.contains($0) }
}
