import Foundation
import CryptoKit

/// SSH helpers: directory listing on remote peers, host fingerprint capture,
/// and a one-shot connectivity probe. Used by the file browser (Phase 2) and
/// peer reconciliation (Phase 1).
///
/// API contract:
///   - `probe(peer:)` — attempt `ssh peer 'true'`, return ok/error.
///   - `hostFingerprint(host:port:)` — run `ssh-keyscan -t ed25519` and return
///     the sha256 fingerprint string.
///   - `listDirectory(peer:path:)` — run a small remote shell to emit tab-separated
///     entries. Path is shell-quoted from Swift to avoid quoting hazards.
///
/// All commands target `peer.lastSeenIP` (the TB link-local) when available,
/// falling back to `peer.lastKnownHostname`.
struct RemoteEntry: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let kind: Kind
    let size: Int64
    let mtime: Date

    enum Kind: String, Sendable { case file, dir, symlink }
}

enum SSHHelper {
    /// Build the canonical ssh argv for a peer (key, ciphers, target).
    /// Returns ([executable, args...], remoteTarget like "user@1.2.3.4").
    ///
    /// Uses SSH connection multiplexing (ControlMaster=auto) so repeated
    /// listDirectory / probe / mkdir calls reuse a single persistent TCP+TLS
    /// session instead of paying the ~125ms handshake every time. Measured on
    /// TB5: 125ms cold → ~15ms multiplexed. That's the difference between
    /// "noticeable lag when clicking folders" and "feels instant".
    ///
    /// NOTE: deliberately NOT used by `TransferEngine` (which spawns rsync
    /// over its own ssh invocation with `ControlMaster=no` so parallel rsync
    /// streams don't get serialized through one TCP socket) or by
    /// `SSHBootstrap` (which builds its own argv inside an `expect` script).
    static func sshCommand(for peer: Peer, extraOptions: [String] = []) -> (argv: [String], target: String) {
        let host = effectiveHost(for: peer)
        let target = "\(peer.sshUsername)@\(host)"

        // Ensure the socket directory exists. OpenSSH won't create parent dirs.
        let socketDir = "\(NSHomeDirectory())/.ssh/sockets"
        try? FileManager.default.createDirectory(
            atPath: socketDir,
            withIntermediateDirectories: true,
            attributes: [FileAttributeKey.posixPermissions: 0o700]
        )
        // %C = hash of (l)ocal hostname, (h)ost, (p)ort, (r)emote user — short,
        // safe filename, unique per peer. ControlPersist keeps the master alive
        // for 60s of idle so the next click in <60s reuses it instantly.
        let controlPath = "\(socketDir)/tbt-%C"

        var argv: [String] = ["/usr/bin/ssh"]
        argv += ["-o", "ConnectTimeout=4"]
        argv += Self.hostKeyArgv(for: peer)
        argv += ["-o", "BatchMode=yes"]
        argv += ["-o", "ControlMaster=auto"]
        argv += ["-o", "ControlPath=\(controlPath)"]
        argv += ["-o", "ControlPersist=60"]
        argv += ["-c", "aes128-gcm@openssh.com"]

        if let keyPath = peer.sshKeyPath {
            argv += ["-i", expandTilde(keyPath)]
            argv += ["-o", "IdentitiesOnly=yes"]
        }

        argv += extraOptions
        argv.append(target)

        return (argv, target)
    }

    /// Ensure the app-managed `~/.ssh/tbtransfer` directory exists (0700). ssh
    /// won't create parent dirs for `UserKnownHostsFile`, so we must, or the
    /// host key silently fails to persist and every session re-TOFUs.
    static func ensureManagedSSHDirectory() {
        let dir = expandTilde(Peer.managedKeyDirectory)
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [FileAttributeKey.posixPermissions: 0o700]
        )
    }

    /// Stable host-key verification options for a peer, in argv form. Pins the
    /// host key under a per-peer alias (survives link-local IP churn) and keeps
    /// it in a dedicated app known_hosts file (never touches ~/.ssh/known_hosts).
    /// `accept-new` is retained: it TOFU-accepts a never-seen alias but still
    /// rejects a genuinely CHANGED key for the same peer — real MITM protection.
    static func hostKeyArgv(for peer: Peer) -> [String] {
        ensureManagedSSHDirectory()
        let knownHosts = expandTilde(Peer.managedKnownHostsFile)
        return [
            "-o", "HostKeyAlias=\(peer.hostKeyAlias)",
            "-o", "UserKnownHostsFile=\(knownHosts)",
            "-o", "StrictHostKeyChecking=accept-new",
        ]
    }

    /// Same options as `hostKeyArgv`, but a single space-joined string for use
    /// inside an `ssh …` command embedded in a shell line (rsync `-e`, etc.).
    /// The known_hosts path is shell-quoted; the alias is `[a-f0-9-]` (safe).
    static func hostKeyOptionString(for peer: Peer) -> String {
        ensureManagedSSHDirectory()
        let knownHosts = expandTilde(Peer.managedKnownHostsFile)
        return "-o HostKeyAlias=\(peer.hostKeyAlias) "
             + "-o UserKnownHostsFile=\(shellQuote(knownHosts)) "
             + "-o StrictHostKeyChecking=accept-new"
    }

    static func probe(peer: Peer, timeoutSec: Int = 6) async -> Result<Void, Error> {
        let (argv, _) = sshCommand(for: peer, extraOptions: [])
        let fullArgv = argv + ["true"]
        guard let exe = fullArgv.first else {
            return .failure(NSError(
                domain: "ssh",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "empty argv"]
            ))
        }
        let args = Array(fullArgv.dropFirst())

        do {
            let result = try await ShellRunner.run(
                exe,
                args,
                timeout: TimeInterval(timeoutSec)
            )
            if result.exitCode == 0 {
                return .success(())
            } else {
                let stderrMsg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let stdoutMsg = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = !stderrMsg.isEmpty ? stderrMsg :
                              (!stdoutMsg.isEmpty ? stdoutMsg : "ssh exited \(result.exitCode)")
                return .failure(NSError(
                    domain: "ssh",
                    code: Int(result.exitCode),
                    userInfo: [NSLocalizedDescriptionKey: message]
                ))
            }
        } catch {
            return .failure(error)
        }
    }

    static func hostFingerprint(host: String, port: Int = 22) async -> String? {
        let args = ["-t", "ed25519", "-p", String(port), "-T", "4", host]
        do {
            let result = try await ShellRunner.run(
                "/usr/bin/ssh-keyscan",
                args,
                timeout: 8
            )
            guard !result.stdout.isEmpty else { return nil }

            // Find first non-comment, non-empty line.
            let lines = result.stdout.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            var keyLine: String? = nil
            for rawLine in lines {
                let line = String(rawLine).trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                if line.hasPrefix("#") { continue }
                keyLine = line
                break
            }
            guard let parsed = keyLine else { return nil }

            // Expected format: "<host> ssh-ed25519 AAAA..."
            let parts = parsed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3 else { return nil }
            let base64Key = String(parts[2])

            guard let keyData = Data(base64Encoded: base64Key) else { return nil }
            let digest = SHA256.hash(data: keyData)
            let digestData = Data(digest)
            return "SHA256:" + digestData.base64EncodedString()
        } catch {
            return nil
        }
    }

    static func listDirectory(peer: Peer, path: String) async throws -> [RemoteEntry] {
        let (argv, _) = sshCommand(for: peer, extraOptions: [])
        let quotedPath = shellQuote(path)
        // _ is $0, the path becomes $1. Translate a leading `~` to `$HOME`
        // ourselves because `cd "~/..."` (quoted) does NOT trigger shell tilde
        // expansion. We use `cut -c3-` to slice off the `~/` prefix because
        // `${p#~/}` is unreliable — bash interprets `~` inside the parameter
        // expansion pattern as tilde-substitution rather than literal, so the
        // strip silently fails and produces `$HOME/~/foo` instead of `$HOME/foo`.
        let remoteScript = """
        sh -c 'p="$1"; case "$p" in "~"|"~/") p="$HOME";; "~/"*) p="$HOME/$(printf %s "$p" | cut -c3-)";; esac; cd "$p" 2>/dev/null || exit 1; for f in .* * ; do [ "$f" = "." ] && continue; [ "$f" = ".." ] && continue; [ "$f" = "*" ] && continue; if [ -L "$f" ]; then k=symlink; elif [ -d "$f" ]; then k=dir; else k=file; fi; s=$(stat -f%z "$f" 2>/dev/null || echo 0); m=$(stat -f%m "$f" 2>/dev/null || echo 0); printf "%s\\t%s\\t%s\\t%s\\n" "$k" "$s" "$m" "$f"; done' _ \(quotedPath)
        """

        let fullArgv = argv + [remoteScript]
        guard let exe = fullArgv.first else {
            throw NSError(
                domain: "ssh.listDirectory",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "empty argv"]
            )
        }
        let args = Array(fullArgv.dropFirst())

        let result = try await ShellRunner.run(exe, args, timeout: 20)

        if result.exitCode != 0 {
            let stderrMsg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdoutMsg = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = !stderrMsg.isEmpty ? stderrMsg :
                          (!stdoutMsg.isEmpty ? stdoutMsg : "ssh exited \(result.exitCode)")
            throw NSError(
                domain: "ssh.listDirectory",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        var entries: [RemoteEntry] = []
        let lines = result.stdout.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
        for rawLine in lines {
            let line = String(rawLine)
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 4 else { continue }
            let kindStr = String(parts[0])
            let sizeStr = String(parts[1])
            let mtimeStr = String(parts[2])
            // Name may legitimately contain tabs in pathological cases; join the rest.
            let name = parts[3...].map(String.init).joined(separator: "\t")

            if name == "." || name == ".." || name == "*" { continue }

            guard let kind = RemoteEntry.Kind(rawValue: kindStr) else { continue }
            let size = Int64(sizeStr) ?? 0
            let mtimeSecs = TimeInterval(Int(mtimeStr) ?? 0)
            let mtime = Date(timeIntervalSince1970: mtimeSecs)

            entries.append(RemoteEntry(name: name, kind: kind, size: size, mtime: mtime))
        }

        // Sort: directories first, then symlinks, then files; each group sorted case-insensitively.
        let kindRank: (RemoteEntry.Kind) -> Int = { k in
            switch k {
            case .dir: return 0
            case .symlink: return 1
            case .file: return 2
            }
        }
        entries.sort { a, b in
            let ra = kindRank(a.kind)
            let rb = kindRank(b.kind)
            if ra != rb { return ra < rb }
            return a.name.lowercased() < b.name.lowercased()
        }

        return entries
    }
}

// MARK: - Internal helpers

fileprivate func shellQuote(_ s: String) -> String {
    // Wrap in single quotes; replace any embedded single-quote with '\''.
    let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
}

fileprivate func expandTilde(_ s: String) -> String {
    guard s.hasPrefix("~") else { return s }
    let home = NSHomeDirectory()
    if s == "~" { return home }
    if s.hasPrefix("~/") {
        return home + String(s.dropFirst(1)) // drop the ~, keep the leading /
    }
    return s
}

fileprivate func effectiveHost(for peer: Peer) -> String {
    return peer.lastSeenIP ?? peer.lastKnownHostname
}
