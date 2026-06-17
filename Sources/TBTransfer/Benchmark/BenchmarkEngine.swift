import Foundation
import Observation
import Network

/// Self-contained TB interconnect benchmark — the engine behind the Benchmark
/// tab. Measures UNENCRYPTED throughput over the Thunderbolt link (raw TCP, the
/// same path exo's multi-node clusters use), so it surfaces link/MTU faults the
/// SSH/AES transfer path would mask.
///
/// Method — the prior-art `nc` ladder (a receiving node ACCEPTS, the sender
/// streams `/dev/zero`), kept faithful to how these links were benchmarked
/// before (see ~/tb-transfer/throughput-bench.sh + the cluster memory):
///   1. Validate every node's TB connection (TCP :22 + SSH probe) using the
///      node's own link-local TB IP (`peer.lastSeenIP`) — never Tailscale/Wi-Fi.
///   2. Once validated, install the one dep the measurement needs — `pv` — on
///      each node (and locally). `nc`/`wc` are already built into macOS.
///   3. Per direction, the RECEIVER runs N parallel `nc -l <port>` accepts each
///      piped through `pv -b -n` (exact byte counter); the SENDER streams
///      `/dev/zero` through `nc` for the window. N streams (default 8) is the
///      documented config that saturates IP-over-TB — a single stream is
///      CPU-bound well below link rate and would hide MTU faults.
///   4. Report each direction's Gbit/s alongside the configured MTU of BOTH
///      ends. An MTU mismatch (e.g. one side at 1500/8000) is the classic TB
///      fault — it can halve one direction — so the tab flags it and lets you
///      change either end's MTU.
///
/// All remote commands are fish-safe (simple commands, or piped to `sh -s`) —
/// the peers run fish as their login shell.
@Observable
@MainActor
final class BenchmarkEngine {

    // MARK: - Result model

    struct NodeResult: Identifiable, Sendable {
        let id: UUID                 // peer.id
        var name: String
        var ip: String?
        var localInterface: String?  // this Mac's enN facing the peer
        var remoteInterface: String? // the peer's enN facing us
        var phase: Phase = .idle
        var connectionOK: Bool = false
        // Per-method throughput (Gbit/s). up = this Mac → peer, down = peer → this Mac.
        var iperf3Up: Double?
        var iperf3Down: Double?
        var ncUp: Double?
        var ncDown: Double?
        var localMTU: Int?
        var remoteMTU: Int?
        var detail: String?          // status / error line

        func gbps(_ method: Method, reverse: Bool) -> Double? {
            switch (method, reverse) {
            case (.iperf3, false): iperf3Up
            case (.iperf3, true):  iperf3Down
            case (.nc, false):     ncUp
            case (.nc, true):      ncDown
            }
        }
        mutating func setGbps(_ method: Method, reverse: Bool, _ v: Double?) {
            switch (method, reverse) {
            case (.iperf3, false): iperf3Up = v
            case (.iperf3, true):  iperf3Down = v
            case (.nc, false):     ncUp = v
            case (.nc, true):      ncDown = v
            }
        }
        /// Any throughput recorded at all (so we can mark done vs failed).
        var hasAnyResult: Bool {
            iperf3Up != nil || iperf3Down != nil || ncUp != nil || ncDown != nil
        }

        enum Phase: String, Sendable {
            case idle        = "Idle"
            case validating  = "Validating connection…"
            case installing  = "Installing deps (pv)…"
            case readingMTU  = "Reading MTU…"
            case uploading   = "Testing upload…"
            case downloading = "Testing download…"
            case done        = "Done"
            case failed      = "Failed"
        }

        /// True when both ends report an MTU and they differ — the classic
        /// "one direction collapses" TB fault worth flagging in the UI.
        var mtuMismatch: Bool {
            guard let l = localMTU, let r = remoteMTU else { return false }
            return l != r
        }
    }

    // MARK: - Observable state

    private(set) var results: [UUID: NodeResult] = [:]
    private(set) var isRunning = false
    private(set) var statusLine: String = "Idle."

    /// A single measurement engine. `.iperf3` saturates the link with 8 streams
    /// and reveals MTU faults — the method the cluster's own baseline used.
    /// `.nc` is the raw single-process-per-stream `nc` ladder (unencrypted, but
    /// CPU-bound at ~3–5 Gb/s, so it won't expose MTU faults as sharply).
    enum Method: String, Sendable, CaseIterable, Identifiable {
        case iperf3, nc
        var id: String { rawValue }
        var label: String { self == .iperf3 ? "iperf3" : "nc" }
        var dep: String { self == .iperf3 ? "iperf3" : "pv" }
    }

    /// What a run executes. `.both` (default) runs iperf3 AND nc back-to-back so
    /// you get the link-saturating number and the raw-socket number side by side.
    enum Mode: String, Sendable, CaseIterable, Identifiable {
        case both, iperf3, nc
        var id: String { rawValue }
        var label: String {
            switch self { case .both: "Both"; case .iperf3: "iperf3"; case .nc: "nc" }
        }
        var methods: [Method] {
            switch self { case .both: [.iperf3, .nc]; case .iperf3: [.iperf3]; case .nc: [.nc] }
        }
    }
    var mode: Mode = .both

    /// Per-direction test length. Default ≈6s each → ≈15s total incl. settle/
    /// SSH overhead (a "quick" up+down pass), not a soak test.
    var perDirectionSeconds: Int = 6
    /// Parallel `nc` streams. 8 is the documented config that saturates
    /// IP-over-TB (a single stream is CPU-bound well below link rate).
    var streams: Int = 8

    /// Common TB MTU presets (driver range is 1280–65518; 65518 = jumbo max).
    /// 8000 is the value the exo MTU daemon historically clamped to.
    static let mtuPresets: [Int] = [1500, 8000, 9000, 65518]
    static let mtuMin = 1280
    static let mtuMax = 65518

    // Base TCP port for the ephemeral nc listeners; streams use base..<base+N.
    private static let basePort = 5790

    // MARK: - Public API

    /// Full pipeline across all online peers: validate ALL connections first,
    /// then install deps, then benchmark each node sequentially (sequential so
    /// the nodes don't contend for this Mac's TB egress and skew each other).
    func runAll(peers: [Peer]) async {
        guard !isRunning else { return }
        let targets = peers.filter { $0.isOnline && ($0.lastSeenIP?.isEmpty == false) }
        guard !targets.isEmpty else {
            statusLine = "No online TB peers to benchmark."
            return
        }
        isRunning = true
        defer { isRunning = false }

        for p in targets {
            results[p.id] = NodeResult(
                id: p.id, name: p.displayName, ip: p.lastSeenIP,
                localInterface: p.lastSeenInterface, phase: .validating
            )
        }

        // Phase 1 — validate ALL connections up front.
        statusLine = "Validating \(targets.count) node connection\(targets.count == 1 ? "" : "s")…"
        await withTaskGroup(of: (UUID, Bool, String?).self) { group in
            for p in targets { group.addTask { await Self.validate(peer: p) } }
            for await (id, ok, detail) in group {
                update(id) { $0.connectionOK = ok; $0.detail = detail; if !ok { $0.phase = .failed } }
            }
        }
        let validated = targets.filter { results[$0.id]?.connectionOK == true }
        guard !validated.isEmpty else {
            statusLine = "No nodes passed connection validation."
            return
        }

        // Phase 2 — install deps for every method this run will use (best-effort
        // local once + on every validated node, in parallel). A method whose dep
        // can't be installed is simply skipped per-node in benchmarkNode.
        let methods = mode.methods
        let depNames = methods.map(\.dep).joined(separator: " + ")
        statusLine = "Installing benchmark deps (\(depNames))…"
        for p in validated { update(p.id) { $0.phase = .installing } }
        for m in methods { _ = await ensureLocalDep(m) }
        await withTaskGroup(of: Void.self) { group in
            for p in validated {
                for m in methods {
                    group.addTask { _ = await Self.ensureRemoteDep(peer: p, method: m) }
                }
            }
            await group.waitForAll()
        }

        // Phase 3 — benchmark each node sequentially.
        for p in validated {
            await benchmarkNode(peer: p)
        }
        statusLine = "Benchmark complete."
    }

    /// Full pipeline for a single node (validate → deps → MTU → up/down).
    func run(peer: Peer) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        results[peer.id] = NodeResult(
            id: peer.id, name: peer.displayName, ip: peer.lastSeenIP,
            localInterface: peer.lastSeenInterface, phase: .validating
        )
        statusLine = "Validating \(peer.displayName)…"
        let (_, ok, detail) = await Self.validate(peer: peer)
        update(peer.id) { $0.connectionOK = ok; $0.detail = detail }
        guard ok else {
            update(peer.id) { $0.phase = .failed }
            statusLine = "\(peer.displayName): connection failed."
            return
        }
        update(peer.id) { $0.phase = .installing }
        for m in mode.methods {
            _ = await ensureLocalDep(m)
            _ = await Self.ensureRemoteDep(peer: peer, method: m)
        }
        await benchmarkNode(peer: peer)
        statusLine = "\(peer.displayName): done."
    }

    /// Re-read both ends' MTU without re-running the throughput test.
    func refreshMTU(peer: Peer) async {
        if results[peer.id] == nil {
            results[peer.id] = NodeResult(id: peer.id, name: peer.displayName,
                                          ip: peer.lastSeenIP, localInterface: peer.lastSeenInterface)
        }
        let local = await Self.readLocalMTU(interface: peer.lastSeenInterface)
        let (remoteIface, remoteMTU) = await Self.readRemoteMTU(peer: peer)
        update(peer.id) { $0.localMTU = local; $0.remoteInterface = remoteIface; $0.remoteMTU = remoteMTU }
    }

    enum Side: Sendable { case local, remote }

    /// Outcome of an MTU change. `.needsPassword` means the peer's sudo asked
    /// for a password (no NOPASSWD rule) — the UI should prompt and retry via
    /// `setMTUWithPassword`. Note: the peer's interactive Touch-ID/cached sudo
    /// does NOT apply to `sudo -n` over SSH, so this can fire even when sudo
    /// "feels" passwordless at the machine itself.
    enum MTUResult: Sendable, Equatable { case ok, needsPassword, failed(String) }

    /// Change the MTU of one end. Local uses an admin (osascript) prompt; remote
    /// tries passwordless `sudo -n` over SSH. Re-reads MTU on success.
    func setMTU(peer: Peer, side: Side, mtu: Int) async -> MTUResult {
        let clamped = max(Self.mtuMin, min(Self.mtuMax, mtu))
        let result: MTUResult
        switch side {
        case .local:
            guard let iface = peer.lastSeenInterface else { return .failed("Unknown local interface.") }
            result = await Self.setLocalMTU(interface: iface, mtu: clamped)
        case .remote:
            guard let iface = results[peer.id]?.remoteInterface else {
                return .failed("Remote interface unknown — read MTU first.")
            }
            result = await Self.setRemoteMTU(peer: peer, interface: iface, mtu: clamped, password: nil)
        }
        if result == .ok { await refreshMTU(peer: peer) }
        return result
    }

    /// Retry a REMOTE MTU change with the peer's sudo password (piped to
    /// `sudo -S` via stdin — never stored, never on argv).
    func setMTUWithPassword(peer: Peer, side: Side, mtu: Int, password: String) async -> MTUResult {
        guard side == .remote, let iface = results[peer.id]?.remoteInterface else {
            return .failed("Remote interface unknown — read MTU first.")
        }
        let clamped = max(Self.mtuMin, min(Self.mtuMax, mtu))
        let result = await Self.setRemoteMTU(peer: peer, interface: iface, mtu: clamped, password: password)
        if result == .ok { await refreshMTU(peer: peer) }
        return result
    }

    // MARK: - Per-node benchmark

    private func benchmarkNode(peer: Peer) async {
        guard let ip = peer.lastSeenIP, !ip.isEmpty else {
            update(peer.id) { $0.phase = .failed; $0.detail = "No TB IP." }
            return
        }
        update(peer.id) { $0.phase = .readingMTU }
        let localMTU = await Self.readLocalMTU(interface: peer.lastSeenInterface)
        let (remoteIface, remoteMTU) = await Self.readRemoteMTU(peer: peer)
        update(peer.id) { $0.localMTU = localMTU; $0.remoteInterface = remoteIface; $0.remoteMTU = remoteMTU }

        // Run each selected method's up + down in turn. iperf3 first (the
        // fast/clean one); nc second.
        for m in mode.methods {
            let mLabel = m.label
            statusLine = "\(peer.displayName): \(mLabel) upload…"
            update(peer.id) { $0.phase = .uploading; $0.detail = nil }
            let up = await measureDirection(peer: peer, peerIP: ip, reverse: false, method: m)
            update(peer.id) { $0.setGbps(m, reverse: false, up.value); if let e = up.error { $0.detail = "\(mLabel): \(e)" } }

            statusLine = "\(peer.displayName): \(mLabel) download…"
            update(peer.id) { $0.phase = .downloading }
            let down = await measureDirection(peer: peer, peerIP: ip, reverse: true, method: m)
            update(peer.id) { $0.setGbps(m, reverse: true, down.value); if let e = down.error { $0.detail = "\(mLabel): \(e)" } }
        }

        update(peer.id) { $0.phase = $0.hasAnyResult ? .done : .failed }
    }

    /// Measure one direction with a specific method. Upload: peer is the
    /// RECEIVER (accepts), this Mac streams. Download: this Mac is the RECEIVER,
    /// the peer streams. iperf3 uses its own client/server; nc counts exact
    /// bytes (pv/wc) with a time-boxed sender → throughput = bytes×8 / elapsed.
    private func measureDirection(peer: Peer, peerIP: String, reverse: Bool, method: Method) async -> (value: Double?, error: String?) {
        let n = max(1, min(16, streams))
        let dur = max(1, perDirectionSeconds)

        if method == .iperf3 {
            return await runIperf3Direction(peer: peer, ip: peerIP, reverse: reverse, streams: n, seconds: dur)
        }

        // ---- nc method ----
        // We deliberately do NOT TCP-probe the data ports for readiness: a probe
        // would be accepted as the one-shot `nc -l`'s single connection and
        // consume it. Instead we start the receiver, wait a fixed settle for the
        // listeners to bind, then run the self-timed sender. The sender holds
        // each `nc` PID directly so it can `kill` them cleanly after the window,
        // which closes the sockets → the receiver sees EOF and reports its count.
        if !reverse {
            // UPLOAD: receiver = peer (SSH), sender = local (self-timed sh).
            let recvTask = Task { await Self.runRemoteReceiver(peer: peer, basePort: Self.basePort, n: n, maxSeconds: dur + 20) }
            try? await Task.sleep(for: .milliseconds(1500))   // remote SSH+nc bind (warm control-master)
            let start = Date()
            await Self.runSenders(target: .local, peer: peer, destIP: peerIP,
                                  basePort: Self.basePort, n: n, seconds: dur)
            let elapsed = max(0.001, Date().timeIntervalSince(start))
            let bytes = await recvTask.value
            return rate(bytes: bytes, elapsed: elapsed)
        } else {
            // DOWNLOAD: receiver = local, sender = peer (SSH, self-timed sh).
            guard let ourIP = await Self.localTBIP(interface: peer.lastSeenInterface) else {
                return (nil, "Couldn't determine this Mac's TB IP on \(peer.lastSeenInterface ?? "?").")
            }
            let recvTask = Task { await Self.runLocalReceiver(basePort: Self.basePort, n: n, maxSeconds: dur + 20) }
            try? await Task.sleep(for: .milliseconds(500))    // local nc bind
            let start = Date()
            await Self.runSenders(target: .remote, peer: peer, destIP: ourIP,
                                  basePort: Self.basePort, n: n, seconds: dur)
            let elapsed = max(0.001, Date().timeIntervalSince(start))
            let bytes = await recvTask.value
            return rate(bytes: bytes, elapsed: elapsed)
        }
    }

    private func rate(bytes: Int64, elapsed: TimeInterval) -> (value: Double?, error: String?) {
        guard bytes > 0 else { return (nil, "No bytes transferred (nc/pv blocked or sender failed).") }
        return (Double(bytes) * 8.0 / elapsed / 1e9, nil)
    }

    // MARK: - Receivers / senders (nonisolated statics)

    /// Remote shell that runs N parallel `nc -l` accepts, each counted by
    /// `pv -b -n` (or `wc -c` if pv is missing), and prints the total bytes
    /// once every sender has closed. Piped to `sh -s` (fish-safe).
    nonisolated static func runRemoteReceiver(peer: Peer, basePort: Int, n: Int, maxSeconds: Int) async -> Int64 {
        let (argv, _) = SSHHelper.sshCommand(for: peer)
        let r = try? await ShellRunner.run(
            argv[0], Array(argv.dropFirst()) + ["sh", "-s", String(basePort), String(n)],
            stdin: receiverScript, timeout: TimeInterval(maxSeconds)
        )
        return parseTotalBytes(r?.stdout ?? "")
    }

    /// Same receiver, but on THIS Mac (download direction).
    nonisolated static func runLocalReceiver(basePort: Int, n: Int, maxSeconds: Int) async -> Int64 {
        let r = try? await ShellRunner.run(
            "/bin/sh", ["-s", String(basePort), String(n)],
            stdin: receiverScript, timeout: TimeInterval(maxSeconds)
        )
        return parseTotalBytes(r?.stdout ?? "")
    }

    enum SenderTarget { case local, remote }

    /// Run the self-timed sender script either on THIS Mac (`.local`, upload) or
    /// on the peer (`.remote`, download). It streams /dev/zero to each of the N
    /// listener ports on `destIP` for `seconds`, then kills its `nc`s. Blocks
    /// for ≈`seconds`. Piped to `sh -s` so a fish login shell never parses it.
    nonisolated static func runSenders(target: SenderTarget, peer: Peer, destIP: String,
                                       basePort: Int, n: Int, seconds: Int) async {
        let posArgs = [destIP, String(basePort), String(n), String(seconds)]
        switch target {
        case .local:
            _ = try? await ShellRunner.run(
                "/bin/sh", ["-s"] + posArgs, stdin: senderScript, timeout: TimeInterval(seconds + 20)
            )
        case .remote:
            let (argv, _) = SSHHelper.sshCommand(for: peer)
            _ = try? await ShellRunner.run(
                argv[0], Array(argv.dropFirst()) + ["sh", "-s"] + posArgs,
                stdin: senderScript, timeout: TimeInterval(seconds + 20)
            )
        }
    }

    /// `$1=basePort $2=nstreams` → prints total bytes received across streams.
    /// pv -b -n emits cumulative byte integers to stderr (last = total); wc -c
    /// is the built-in fallback. `nc -l` exits when its single client closes.
    ///
    /// CRITICAL: `nc -d` ("do not read stdin"). Without it, the listener's nc
    /// inherits this script's stdin — which is the script itself, piped in and
    /// already at EOF — and Apple nc tears the connection down after one buffer,
    /// collapsing throughput to a few KB. `-d` makes nc receive-only, which is
    /// exactly what we want for the sink side.
    nonisolated static let receiverScript = """
    bp=$1; n=$2; t=$(mktemp -d) || exit 1
    if command -v pv >/dev/null 2>&1; then USE_PV=1; else USE_PV=0; fi
    i=0
    while [ "$i" -lt "$n" ]; do
      p=$((bp + i))
      if [ "$USE_PV" -eq 1 ]; then
        ( nc -d -l "$p" | pv -b -n -i 1 2>"$t/$i.pv" >/dev/null ) &
      else
        ( nc -d -l "$p" | wc -c >"$t/$i.wc" ) &
      fi
      i=$((i + 1))
    done
    wait
    s=0
    for f in "$t"/*.pv; do [ -f "$f" ] || continue; b=$(tr '\\r' '\\n' < "$f" | grep -E '^[0-9]+$' | tail -1); s=$((s + ${b:-0})); done
    for f in "$t"/*.wc; do [ -f "$f" ] || continue; b=$(tr -dc '0-9' < "$f"); s=$((s + ${b:-0})); done
    rm -rf "$t"
    echo "$s"
    """

    /// `$1=destIP $2=basePort $3=nstreams $4=seconds`. Streams /dev/zero to each
    /// listener port, then self-kills after `seconds`. Each `nc` is backgrounded
    /// DIRECTLY (not in a subshell) so `$!` is the nc PID and `kill "$pids"`
    /// terminates the nc itself — closing the socket so the receiver gets EOF.
    nonisolated static let senderScript = """
    ip=$1; bp=$2; n=$3; dur=$4; i=0; pids=""
    while [ "$i" -lt "$n" ]; do
      nc "$ip" $((bp + i)) < /dev/zero >/dev/null 2>&1 &
      pids="$pids $!"
      i=$((i + 1))
    done
    sleep "$dur"
    kill $pids 2>/dev/null
    wait 2>/dev/null
    exit 0
    """

    nonisolated static func parseTotalBytes(_ s: String) -> Int64 {
        for line in s.split(whereSeparator: \.isNewline).reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let v = Int64(t) { return v }
        }
        return 0
    }

    // MARK: - Validation

    nonisolated static func validate(peer: Peer) async -> (UUID, Bool, String?) {
        guard let ip = peer.lastSeenIP, !ip.isEmpty else {
            return (peer.id, false, "No TB IP discovered yet.")
        }
        guard await waitForPort(host: ip, port: 22, deadlineSeconds: 3) else {
            return (peer.id, false, "Can't reach \(ip):22 over TB (cable/Remote Login?).")
        }
        switch await SSHHelper.probe(peer: peer, timeoutSec: 6) {
        case .success:        return (peer.id, true, "TB connection OK (\(ip)).")
        case .failure(let e): return (peer.id, false, "SSH failed: \((e as NSError).localizedDescription)")
        }
    }

    // MARK: - Dependency install (pv)

    nonisolated static let localPVPaths = ["/opt/homebrew/bin/pv", "/usr/local/bin/pv"]

    nonisolated static func ensureLocalPV() async -> Bool {
        if localPVPaths.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return true }
        _ = try? await ShellRunner.run("/opt/homebrew/bin/brew", ["install", "pv"], timeout: 180)
        return localPVPaths.contains(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// Ensure pv on the peer (install via brew if missing). Returns true if pv
    /// is present afterwards; benchmark still runs via wc fallback if false.
    nonisolated static func ensureRemotePV(peer: Peer) async -> Bool {
        if await remoteHasPV(peer: peer) { return true }
        let (argv, _) = SSHHelper.sshCommand(for: peer)
        _ = try? await ShellRunner.run(
            argv[0], Array(argv.dropFirst()) + ["/opt/homebrew/bin/brew install pv"], timeout: 240
        )
        return await remoteHasPV(peer: peer)
    }

    nonisolated static func remoteHasPV(peer: Peer) async -> Bool {
        let (argv, _) = SSHHelper.sshCommand(for: peer)
        let script = "command -v pv >/dev/null 2>&1 && echo yes || echo no"
        guard let r = try? await ShellRunner.run(
            argv[0], Array(argv.dropFirst()) + ["sh", "-s"], stdin: script, timeout: 10
        ) else { return false }
        return r.stdout.contains("yes")
    }

    /// Unified dep ensure for a method (pv for nc, iperf3 for iperf3).
    func ensureLocalDep(_ method: Method) async -> Bool {
        method == .iperf3 ? await Self.ensureLocalIperf3() : await Self.ensureLocalPV()
    }
    nonisolated static func ensureRemoteDep(peer: Peer, method: Method) async -> Bool {
        method == .iperf3 ? (await ensureRemoteIperf3(peer: peer) != nil) : await ensureRemotePV(peer: peer)
    }

    // MARK: - Dependency install (iperf3)

    nonisolated static let localIperf3Path = "/opt/homebrew/bin/iperf3"

    nonisolated static func ensureLocalIperf3() async -> Bool {
        if FileManager.default.isExecutableFile(atPath: localIperf3Path) { return true }
        _ = try? await ShellRunner.run("/opt/homebrew/bin/brew", ["install", "iperf3"], timeout: 240)
        return FileManager.default.isExecutableFile(atPath: localIperf3Path)
    }

    /// Returns the remote iperf3 path (installing via brew if missing), else nil.
    nonisolated static func ensureRemoteIperf3(peer: Peer) async -> String? {
        if let p = await remoteIperf3Path(peer: peer) { return p }
        let (argv, _) = SSHHelper.sshCommand(for: peer)
        _ = try? await ShellRunner.run(
            argv[0], Array(argv.dropFirst()) + ["/opt/homebrew/bin/brew install iperf3"], timeout: 300
        )
        return await remoteIperf3Path(peer: peer)
    }

    /// Locate iperf3 on the peer (Homebrew arm/intel), or nil. Piped to `sh -s`
    /// so the fish login shell never parses the POSIX `for`/`[`.
    nonisolated static func remoteIperf3Path(peer: Peer) async -> String? {
        let script = "for p in /opt/homebrew/bin/iperf3 /usr/local/bin/iperf3; do " +
                     "[ -x \"$p\" ] && { echo \"$p\"; exit 0; }; done; exit 1"
        let (argv, _) = SSHHelper.sshCommand(for: peer)
        guard let r = try? await ShellRunner.run(
            argv[0], Array(argv.dropFirst()) + ["sh", "-s"], stdin: script, timeout: 12
        ), r.ok else { return nil }
        let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    // MARK: - iperf3 measurement

    /// One direction via iperf3: spawn `iperf3 -s -1` bound to the peer's TB IP
    /// over SSH (held open for its lifetime), settle, then run the local client
    /// with N streams. `-1` exits the server after the single client; the held
    /// SSH Process is terminated as a backstop. We do NOT TCP-probe the port
    /// (that would be the `-1` server's one client) — a fixed settle suffices,
    /// and the control-master is already warm from validation/MTU reads.
    private func runIperf3Direction(peer: Peer, ip: String, reverse: Bool, streams: Int, seconds: Int) async -> (value: Double?, error: String?) {
        let remoteIperf = await Self.remoteIperf3Path(peer: peer) ?? "/opt/homebrew/bin/iperf3"
        let serverCmd = "\(remoteIperf) -s -1 -B \(ip) -p \(Self.iperfPort)"

        let server = Process()
        let serverArgv = Self.sshArgv(for: peer) + [serverCmd]
        server.executableURL = URL(fileURLWithPath: serverArgv[0])
        server.arguments = Array(serverArgv.dropFirst())
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        do { try server.run() } catch {
            return (nil, "Couldn't start iperf3 server on peer: \(error.localizedDescription)")
        }
        defer { if server.isRunning { server.terminate() } }

        try? await Task.sleep(for: .milliseconds(1500))   // remote SSH+iperf3 bind

        var args = ["-c", ip, "-p", String(Self.iperfPort),
                    "-t", String(seconds), "-P", String(streams), "-J"]
        if reverse { args.append("-R") }
        let result: ShellRunner.Result
        do {
            result = try await ShellRunner.run(Self.localIperf3Path, args, timeout: TimeInterval(seconds + 25))
        } catch {
            return (nil, "iperf3 client error: \(error.localizedDescription)")
        }
        return Self.parseIperf3Gbps(result.stdout, stderr: result.stderr)
    }

    /// Pull in-direction throughput (Gbit/s) from `iperf3 -J`. Uses
    /// `end.sum_received.bits_per_second` — the bytes that landed at the
    /// receiver, in whichever direction was tested.
    nonisolated static func parseIperf3Gbps(_ json: String, stderr: String) -> (value: Double?, error: String?) {
        guard let data = json.data(using: .utf8), !data.isEmpty else {
            let e = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, e.isEmpty ? "No iperf3 output." : e)
        }
        struct Sum: Decodable { let bits_per_second: Double }
        struct End: Decodable { let sum_received: Sum?; let sum_sent: Sum? }
        struct Root: Decodable { let end: End?; let error: String? }
        guard let root = try? JSONDecoder().decode(Root.self, from: data) else {
            return (nil, "Couldn't parse iperf3 output.")
        }
        if let e = root.error, !e.isEmpty { return (nil, e) }
        let bps = root.end?.sum_received?.bits_per_second ?? root.end?.sum_sent?.bits_per_second
        guard let bps, bps > 0 else { return (nil, "iperf3 reported no throughput.") }
        return (bps / 1e9, nil)
    }

    private static let iperfPort = 5791

    /// Dedicated SSH argv for the held-open iperf3 server spawn. Deliberately
    /// NOT SSHHelper.sshCommand (no ControlMaster — sharing the master with the
    /// short-lived control commands causes hangs), but it reuses the per-peer
    /// host-key alias + dedicated known_hosts so reused link-local IPs don't
    /// trip "host key changed".
    nonisolated static func sshArgv(for peer: Peer) -> [String] {
        var argv = ["/usr/bin/ssh", "-o", "ConnectTimeout=5"]
        argv += SSHHelper.hostKeyArgv(for: peer)
        argv += ["-o", "BatchMode=yes", "-c", "aes128-gcm@openssh.com"]
        if let key = peer.sshKeyPath, !key.isEmpty {
            argv += ["-i", Peer.expandTildePath(key), "-o", "IdentitiesOnly=yes"]
        }
        argv.append("\(peer.sshUsername)@\(peer.lastSeenIP ?? peer.lastKnownHostname)")
        return argv
    }

    // MARK: - MTU read/set

    nonisolated static func readLocalMTU(interface: String?) async -> Int? {
        guard let iface = interface, !iface.isEmpty else { return nil }
        guard let r = try? await ShellRunner.run("/sbin/ifconfig", [iface], timeout: 5), r.ok else { return nil }
        return parseMTU(fromIfconfig: r.stdout)
    }

    /// This Mac's IPv4 on `interface` (the address the peer dials for download).
    nonisolated static func localTBIP(interface: String?) async -> String? {
        guard let iface = interface, !iface.isEmpty else { return nil }
        guard let r = try? await ShellRunner.run("/sbin/ifconfig", [iface], timeout: 5), r.ok else { return nil }
        for raw in r.stdout.split(whereSeparator: \.isNewline) {
            let toks = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if let i = toks.firstIndex(of: "inet"), i + 1 < toks.count, isIPv4Address(toks[i + 1]) {
                return toks[i + 1]
            }
        }
        return nil
    }

    /// Find the peer's interface holding the TB IP and report `(iface, mtu)`.
    nonisolated static func readRemoteMTU(peer: Peer) async -> (String?, Int?) {
        guard let ip = peer.lastSeenIP, !ip.isEmpty else { return (nil, nil) }
        let script =
            "for i in $(ifconfig -l); do " +
            "ifconfig \"$i\" 2>/dev/null | grep -q \"inet \(ip) \" || continue; " +
            "m=$(ifconfig \"$i\" | awk 'NR==1{for(k=1;k<=NF;k++) if($k==\"mtu\"){print $(k+1); exit}}'); " +
            "echo \"$i $m\"; exit 0; done; exit 1"
        let (argv, _) = SSHHelper.sshCommand(for: peer)
        guard let r = try? await ShellRunner.run(
            argv[0], Array(argv.dropFirst()) + ["sh", "-s"], stdin: script, timeout: 10
        ), r.ok else { return (nil, nil) }
        let parts = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return (nil, nil) }
        return (String(parts[0]), Int(parts[1]))
    }

    /// Change THIS Mac's interface MTU via an admin (osascript) prompt.
    nonisolated static func setLocalMTU(interface: String, mtu: Int) async -> MTUResult {
        let script = "do shell script \"/sbin/ifconfig \(interface) mtu \(mtu)\" with administrator privileges"
        guard let r = try? await ShellRunner.run("/usr/bin/osascript", ["-e", script], timeout: 60) else {
            return .failed("Failed to invoke osascript.")
        }
        if r.ok { return .ok }
        let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if err.localizedCaseInsensitiveContains("cancel") { return .failed("Cancelled.") }
        return .failed(err.isEmpty ? "ifconfig failed (exit \(r.exitCode))." : err)
    }

    /// Change the peer's interface MTU over SSH. With `password == nil`, tries
    /// `sudo -n` (NOPASSWD); returns `.needsPassword` if the peer's sudo wants a
    /// password. With a password, uses `sudo -S -p ''` reading it from stdin
    /// (never on argv/disk). `ifconfig`/`sudo` are simple commands → fish-safe.
    nonisolated static func setRemoteMTU(peer: Peer, interface: String, mtu: Int, password: String?) async -> MTUResult {
        let (argv, _) = SSHHelper.sshCommand(for: peer)
        let cmd = password == nil
            ? "sudo -n /sbin/ifconfig \(interface) mtu \(mtu)"
            : "sudo -S -p '' /sbin/ifconfig \(interface) mtu \(mtu)"
        let stdin = password.map { $0 + "\n" }
        guard let r = try? await ShellRunner.run(
            argv[0], Array(argv.dropFirst()) + [cmd], stdin: stdin, timeout: 15
        ) else { return .failed("SSH failed.") }
        if r.ok { return .ok }
        let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = err.lowercased()
        if password == nil, lower.contains("password is required") {
            return .needsPassword
        }
        if lower.contains("incorrect password") || lower.contains("sorry, try again") {
            return .failed("Incorrect password.")
        }
        return .failed(err.isEmpty ? "ifconfig failed (exit \(r.exitCode))." : err)
    }

    // MARK: - Pure parsers (internal for tests)

    /// MTU from `ifconfig <iface>` (first line: `enN: flags=...<...> mtu 65518`).
    nonisolated static func parseMTU(fromIfconfig output: String) -> Int? {
        for raw in output.split(whereSeparator: \.isNewline) {
            let toks = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if let i = toks.firstIndex(of: "mtu"), i + 1 < toks.count, let v = Int(toks[i + 1]) { return v }
        }
        return nil
    }

    // MARK: - TCP probe

    nonisolated static func waitForPort(host: String, port: Int, deadlineSeconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(deadlineSeconds))
        while Date() < deadline {
            if await tcpOpen(host: host, port: port, timeoutMillis: 250) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    nonisolated static func tcpOpen(host: String, port: Int, timeoutMillis: Int) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let done = OnceFlag()
            let finish: @Sendable (Bool) -> Void = { ok in
                if done.set() { conn.cancel(); cont.resume(returning: ok) }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:               finish(true)
                case .failed, .cancelled:  finish(false)
                default: break
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMillis)) { finish(false) }
            conn.start(queue: .global())
        }
    }

    /// Atomic once-latch so the TCP continuation fires exactly once.
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock(); private var fired = false
        func set() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
    }

    // MARK: - Mutation helper

    private func update(_ id: UUID, _ mutate: (inout NodeResult) -> Void) {
        guard var r = results[id] else { return }
        mutate(&r)
        results[id] = r
    }
}
