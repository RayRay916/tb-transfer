import Foundation
import Observation

/// Discovers active Thunderbolt Bridge interfaces on this Mac and ARP-scans
/// each for peer Macs. Re-runs on demand (`refresh()`).
///
/// API contract used by `AppState`:
///   - `interfaces: [TBInterface]` — current state of all TB Bridge interfaces (active+inactive).
///   - `discoveredPeers: [DiscoveredPeer]` — peers seen during the last refresh().
///   - `refresh()` — perform one full discovery pass.
///
/// Implementation strategy:
///   1. Read `networksetup -listallhardwareports` and parse "Thunderbolt N" entries
///      → maps hardware name → device name (enN) → MAC address.
///   2. For each enN, run `ifconfig enN` → parse "status:" + "inet ".
///   3. For each *active* TB interface with an inet address:
///        a. Broadcast-ping: `ping -c 2 -t 1 -b enN 169.254.255.255`
///        b. Read ARP table: `arp -a -i enN` filtered to exclude broadcast (ff:ff:ff)
///           and multicast (01:00:5e) MACs, and exclude our own MAC.
///        c. For each remote (ip, mac), attempt reverse-DNS via `getnameinfo` /
///           `dns-sd -G` fallback to None.
///   4. Use `ShellRunner.run("/usr/sbin/networksetup", ...)`, `/sbin/ifconfig`,
///      `/sbin/ping`, `/usr/sbin/arp`. Absolute paths only — Process doesn't search PATH reliably.
///   5. Run scans in parallel across interfaces (TaskGroup) for speed.
@Observable
@MainActor
final class TBInterfaceMonitor {
    private(set) var interfaces: [TBInterface] = []
    private(set) var discoveredPeers: [DiscoveredPeer] = []
    private(set) var lastRefreshAt: Date?
    private(set) var lastError: String?

    /// Run one full discovery pass. `hintIPs` are last-known peer IPs from the
    /// registry; we unicast-ping them alongside the broadcast so a peer whose
    /// IP hasn't churned is re-found instantly and reliably (broadcast ARP is
    /// lossy right after wake / replug). Safe to call with an empty array.
    func refresh(hintIPs: [String] = []) async {
        // Step 1: enumerate Thunderbolt hardware ports.
        let ports: [HardwarePort]
        do {
            let result = try await ShellRunner.run(
                "/usr/sbin/networksetup",
                ["-listallhardwareports"],
                timeout: 5
            )
            ports = parseHardwarePorts(result.stdout)
        } catch {
            self.lastError = "networksetup failed: \(error.localizedDescription)"
            self.lastRefreshAt = Date()
            return
        }

        // Step 2: query each TB device's ifconfig status, in parallel.
        let builtInterfaces: [TBInterface] = await withTaskGroup(
            of: TBInterface?.self,
            returning: [TBInterface].self
        ) { group in
            for port in ports {
                group.addTask {
                    do {
                        let result = try await ShellRunner.run(
                            "/sbin/ifconfig",
                            [port.device],
                            timeout: 5
                        )
                        let parsed = parseIfconfig(result.stdout)
                        // Prefer the ifconfig MAC if present (more authoritative), else use the
                        // networksetup MAC. Normalize either way.
                        let mac = normalizeMAC(parsed.mac ?? port.mac)
                        return TBInterface(
                            name: port.device,
                            hardwareName: port.hardware,
                            macAddress: mac,
                            localIP: parsed.ip,
                            status: parsed.status,
                            broadcastIP: parsed.broadcast
                        )
                    } catch {
                        return TBInterface(
                            name: port.device,
                            hardwareName: port.hardware,
                            macAddress: normalizeMAC(port.mac),
                            localIP: nil,
                            status: .unknown
                        )
                    }
                }
            }
            var out: [TBInterface] = []
            for await iface in group {
                if let iface { out.append(iface) }
            }
            return out
        }

        // Sort for stable UI ordering by hardware name (Thunderbolt 1, Thunderbolt 2, ...).
        let sortedInterfaces = builtInterfaces.sorted { lhs, rhs in
            lhs.hardwareName.localizedStandardCompare(rhs.hardwareName) == .orderedAscending
        }

        // Assign interfaces atomically before scanning peers, so the UI updates quickly.
        self.interfaces = sortedInterfaces

        // Step 3+4: ARP convergence loop. One broadcast/unicast ping pass, a
        // short settle, then read the global ARP cache. Repeat (bounded) until
        // we've found at least as many peers as we have hints (known peers), or
        // the attempt budget is spent. This is far more robust than a single
        // ping→300ms→read against wake/replug races where the first ARP reply
        // hasn't landed yet. Peers accumulate across attempts (union).
        let active = sortedInterfaces.filter(\.isUsable)
        // Two identities per interface: `networksetup` reports the burned-in
        // address, while `ifconfig` sometimes returns a placeholder (macOS 27
        // intermittently answers `ether 02:00:00:00:00:00`). Filter against both.
        var ownMacsByInterface: [String: Set<String>] = [:]
        for port in ports {
            ownMacsByInterface[port.device, default: []].insert(normalizeMAC(port.mac))
        }
        for iface in sortedInterfaces {
            ownMacsByInterface[iface.name, default: []].insert(iface.macAddress)
        }

        var unionByKey: [String: DiscoveredPeer] = [:]
        let maxAttempts = 3
        let target = max(1, hintIPs.count)
        var sawAnyArpEntry = false

        if !active.isEmpty {
            for attempt in 0..<maxAttempts {
                await warmArpCache(active: active, hintIPs: hintIPs)
                // Progressive settle: later attempts wait a touch longer for a
                // slow peer's reply to arrive.
                try? await Task.sleep(for: .milliseconds(250 + attempt * 150))

                let arp = await readGlobalArpTable()
                if arp.entries > 0 { sawAnyArpEntry = true }
                for line in parseGlobalArpTable(arp.output) {
                    guard let ownMacs = ownMacsByInterface[line.ifname] else { continue }
                    if ownMacs.contains(line.mac) { continue }
                    if line.mac == "ff:ff:ff:ff:ff:ff" { continue }
                    if line.mac.hasPrefix("01:00:5e") { continue }
                    if line.mac.hasPrefix("33:33:")   { continue }
                    let key = "\(line.ifname)\u{0}\(line.mac)"
                    unionByKey[key] = DiscoveredPeer(   // latest IP/host wins
                        interfaceName: line.ifname,
                        ipAddress: line.ip,
                        macAddress: line.mac,
                        hostname: line.host
                    )
                }

                // Early-exit once we've found everything we expected. With hints
                // we can stop on attempt 0; on a first-ever run (no hints) take a
                // second pass so a slow second peer isn't missed.
                if unionByKey.count >= target && (attempt >= 1 || !hintIPs.isEmpty) {
                    break
                }
            }
        }

        // Second discovery path: mDNS. Always run when a TB link is up — on
        // macOS 27 it is often the ONLY path (the ARP table is hidden from app
        // processes), and on older systems it resolves names the ARP table
        // leaves as "?". Results carry a hostname, which is the app's primary
        // peer identity, so they reconcile onto the same registry records.
        var hostPeers: [DiscoveredPeer] = []
        if !active.isEmpty {
            hostPeers = await discoverViaHostnames(
                active: active,
                ownIPs: await allLocalIPv4()

            )
            for peer in hostPeers {
                let key = "\(peer.interfaceName)\u{0}\(peer.macAddress)"
                // An ARP row with the same interface+MAC wins: it is the live
                // hardware address rather than our hostname-derived stand-in.
                if unionByKey[key] == nil || unionByKey[key]?.hostname == nil {
                    unionByKey[key] = peer
                }
            }
        }

        let peers = Array(unionByKey.values)

        // Enrich with reverse DNS — bounded so it can't hang the refresh.
        let enriched = await enrichHostnames(peers)

        self.discoveredPeers = enriched
        self.lastRefreshAt = Date()
        // Diagnostic (internal; not shown as a UI error banner): distinguish
        // "no TB link" from "link up but nobody answered".
        if active.isEmpty {
            self.lastError = sortedInterfaces.isEmpty
                ? "No Thunderbolt interfaces found."
                : "Thunderbolt interface(s) present but none active (cable unplugged / peer asleep)."
        } else if enriched.isEmpty {
            let names = active.map(\.name).joined(separator: ", ")
            if !sawAnyArpEntry {
                // A healthy ARP table always has entries, so 0 rows means macOS
                // 27 is filtering it from this process (normal for an app bundle,
                // and unrelated to the Local Network grant). That is fine as long
                // as mDNS found somebody; reaching here means both paths were
                // empty, i.e. there is genuinely no reachable peer on the link.
                self.lastError =
                    "TB link up on \(names), but no peer answered ARP (hidden by macOS) or Bonjour. "
                    + "Is Remote Login enabled on the other Mac?"
            } else {
                self.lastError = "TB link up on \(names) but no peer responded after \(maxAttempts) ARP attempts."
            }
        } else {
            self.lastError = nil
        }
    }

    /// Discover peers over Thunderbolt from their Bonjour advertisements instead
    /// of the (macOS 27-hidden) ARP table. A TBTransfer peer states its own
    /// per-port IPv4s in the TXT record, so it is found even when its responder
    /// publishes no A record for the link; foreign service types (`_ssh`, `_rfb`)
    /// still resolve through per-interface address records.
    ///
    /// Returns one path per (interface, peer host) pair so a machine on two ports
    /// still reconciles as one machine via `discoveryIdentityKey`.
    private func discoverViaHostnames(
        active: [TBInterface],
        ownIPs: Set<String>
    ) async -> [DiscoveredPeer] {
        guard !active.isEmpty else { return [] }

        let selfHost = normalizeHostname(TBHostPeerBrowser.selfHostName()) ?? ""
        let ownInstance = normalizeHostname(TBHostPeerBrowser.localHostNameInstance()) ?? ""
        var byHost: [String: (serviceType: String, txt: [String: String])] = [:]
        for advertisement in await TBHostPeerBrowser.browsePeerToPeer() {
            // Our own service type names the machine in its instance; the SRV
            // target is a random UUID NetService invents, so it cannot be used as
            // identity. Foreign types (`_ssh`, `_rfb`) carry the real host there.
            let isOurs = advertisement.isFromTBTransfer
            let host = isOurs
                ? TBHostPeerBrowser.localHostName(fromInstance: advertisement.instance)
                : advertisement.targetHost
            let normalized = normalizeHostname(host) ?? ""
            guard !normalized.isEmpty else { continue }
            guard normalized != selfHost, normalized != ownInstance else { continue }

            let declared = TBPeerTXT.peerInterfaceAddresses(advertisement.txt)
            if isOurs {
                // A machine advertising its own addresses back at us is us.
                guard !declared.isEmpty, !declared.values.allSatisfy({ ownIPs.contains($0) }) else { continue }
            }
            // Prefer our own type: it is the only one carrying TB addresses.
            if let existing = byHost[normalized], existing.txt["tbv"] != nil, !isOurs { continue }
            byHost[normalized] = (advertisement.serviceType, advertisement.txt)
        }
        guard !byHost.isEmpty else { return [] }

        var out: [DiscoveredPeer] = []
        var used = Set<String>()
        for host in byHost.keys.sorted() {
            let record = byHost[host]!
            var candidates: [String] = []

            if record.txt["tbv"] != nil {
                // A TBTransfer peer declares EVERY Thunderbolt address it has,
                // including a port cabled to some other Mac. Which of them we
                // can reach is settled per port below; sorted so the outcome
                // does not follow dictionary order from pass to pass.
                candidates = TBPeerTXT.peerInterfaceAddresses(record.txt).values.sorted()
            } else {
                candidates = await TBHostPeerBrowser.resolvedAddresses(of: host).map(\.ip).sorted()
            }

            for ip in candidates {
                guard isLinkLocalIPv4(ip), !ownIPs.contains(ip) else { continue }
                guard let iface = await resolveThunderboltInterface(forPeerIP: ip, active: active) else { continue }
                let mac = TBHostPeerBrowser.syntheticMAC(forHost: host)
                guard used.insert("\(iface)\u{0}\(mac)").inserted else { continue }
                out.append(DiscoveredPeer(
                    interfaceName: iface,
                    ipAddress: ip,
                    macAddress: mac,
                    hostname: host
                ))
            }
        }
        return out
    }

    /// Which of our Thunderbolt ports reaches `peerIP`, or nil when none does.
    ///
    /// The kernel route is authoritative when it has a host entry (one is learned
    /// as soon as the peer answers anything on the link). Before the first reply
    /// there is no route, so ask each port directly: a ping bound to a port is
    /// only answered by the machine on that cable. An address the peer declared
    /// for a port cabled to a *different* Mac answers on none of ours and is
    /// dropped. The old /16 guess pinned it to our first port instead, which
    /// stored an unreachable IP for the peer and broke every probe and pairing.
    private func resolveThunderboltInterface(forPeerIP peerIP: String, active: [TBInterface]) async -> String? {
        let route = await TBHostPeerBrowser.interface(forIP: peerIP)
        if let hit = attributeThunderboltInterface(routeInterface: route, answeringInterfaces: [], active: active) {
            return hit
        }
        let answering = await portsAnsweringPing(ip: peerIP, ports: active.map(\.name))
        return attributeThunderboltInterface(routeInterface: nil, answeringInterfaces: answering, active: active)
    }

    /// Ping `ip` once from every port concurrently. `-b` binds the socket to the
    /// port — an unbound ping to a link-local address with no host route leaves
    /// through the LAN interface and proves nothing about the cable.
    private func portsAnsweringPing(ip: String, ports: [String]) async -> Set<String> {
        await withTaskGroup(of: String?.self) { group in
            for port in ports {
                group.addTask {
                    let result = try? await ShellRunner.run(
                        "/sbin/ping", ["-c", "1", "-t", "1", "-b", port, ip], timeout: 2
                    )
                    return result?.ok == true ? port : nil
                }
            }
            var out = Set<String>()
            for await port in group {
                if let port { out.insert(port) }
            }
            return out
        }
    }

    /// One ARP-warming pass: broadcast-ping each active interface's subnet AND
    /// unicast-ping every hint IP (last-known peer addresses). Unicast pings are
    /// the reliable path when an IP hasn't changed; the broadcast catches peers
    /// on a new IP. All run concurrently with tight per-ping timeouts.
    private func warmArpCache(active: [TBInterface], hintIPs: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for iface in active {
                let name = iface.name
                let bcast = iface.broadcastIP ?? "169.254.255.255"
                group.addTask {
                    _ = try? await ShellRunner.run(
                        "/sbin/ping",
                        ["-c", "1", "-t", "1", "-b", name, bcast],
                        timeout: 2
                    )
                }
            }
            for ip in Set(hintIPs) where isIPv4Address(ip) {
                group.addTask {
                    _ = try? await ShellRunner.run(
                        "/sbin/ping",
                        ["-c", "1", "-t", "1", ip],
                        timeout: 2
                    )
                }
            }
            await group.waitForAll()
        }
    }
}

// MARK: - Global ARP table read + parse

private func readGlobalArpTable() async -> (output: String, entries: Int) {
    // CRITICAL: `arp -a` (without -n) does synchronous reverse DNS for each entry.
    // Uncached link-local mDNS lookups can take 5-30s and DO NOT respond to SIGTERM
    // from Process timeout, hanging the whole discovery flow. Always pass `-n`.
    // Hostnames are enriched separately via `enrichHostnames(...)`.
    for attempt in 0..<3 {
        if let result = try? await ShellRunner.run(
            "/usr/sbin/arp",
            ["-an"],
            timeout: 3
        ), !result.stdout.isEmpty {
            return (result.stdout, result.stdout.split(separator: "\n").count)
        }
        if attempt < 2 {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
    return ("", 0)
}

/// Best-effort reverse DNS for each peer IP. Bounded total time via a TaskGroup
/// with per-lookup timeout. Updates a copy of the peer list with the resolved
/// hostname (or leaves it nil).
private func enrichHostnames(_ peers: [DiscoveredPeer]) async -> [DiscoveredPeer] {
    guard !peers.isEmpty else { return peers }
    let results: [(Int, String?)] = await withTaskGroup(
        of: (Int, String?).self,
        returning: [(Int, String?)].self
    ) { group in
        for (idx, peer) in peers.enumerated() {
            let ip = peer.ipAddress
            group.addTask {
                let host = await reverseDNS(ip: ip, timeoutMillis: 800)
                return (idx, host)
            }
        }
        var out: [(Int, String?)] = []
        for await r in group { out.append(r) }
        return out
    }
    var enriched = peers
    for (idx, host) in results {
        if let host, !host.isEmpty {
            enriched[idx] = DiscoveredPeer(
                interfaceName: enriched[idx].interfaceName,
                ipAddress: enriched[idx].ipAddress,
                macAddress: enriched[idx].macAddress,
                hostname: host
            )
        }
    }
    return enriched
}

/// Reverse-DNS a single IPv4 string via `dscacheutil`, which (unlike `host`)
/// queries mDNSResponder and so resolves `.local` Bonjour names on link-local IPs.
/// Returns the resolved name (e.g. "mbp.local") or nil on timeout/failure.
private func reverseDNS(ip: String, timeoutMillis: Int) async -> String? {
    let timeoutSec = TimeInterval(timeoutMillis) / 1000.0
    guard let result = try? await ShellRunner.run(
        "/usr/bin/dscacheutil",
        ["-q", "host", "-a", "ip_address", ip],
        timeout: timeoutSec
    ) else { return nil }
    // Output:
    //   name: mbp2.local
    //   alias: 29.202.254.169.in-addr.arpa
    //   ip_address: 169.254.202.29
    for rawLine in result.stdout.split(separator: "\n") {
        let line = String(rawLine).trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("name:") {
            var name = String(line.dropFirst("name:".count)).trimmingCharacters(in: .whitespaces)
            while name.hasSuffix(".") { name.removeLast() }
            if !name.isEmpty { return name }
        }
    }
    return nil
}

internal struct ArpLine: Sendable {
    let host: String?
    let ip: String
    let mac: String
    let ifname: String
}

/// Parse `arp -a` output (hostnames included). Each line:
///   `mbp.local (169.254.205.44) at 36:c2:3:f3:96:4 on en4 [ethernet]`
internal func parseGlobalArpTable(_ output: String) -> [ArpLine] {
    var rows: [ArpLine] = []
    for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = String(rawLine).trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.contains("(incomplete)") { continue }

        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 6 else { continue }

        // Token 0 = host (or "?"). Token 1 = "(ip)". Token 2 = "at". Token 3 = mac. Token 4 = "on". Token 5 = ifname.
        let hostnameToken = tokens[0]
        let host: String? = (hostnameToken == "?" || hostnameToken.hasPrefix("(")) ? nil : hostnameToken

        guard let ipToken = tokens.first(where: { $0.hasPrefix("(") && $0.hasSuffix(")") }) else { continue }
        let ip = String(ipToken.dropFirst().dropLast())
        guard ip.split(separator: ".").count == 4 else { continue }

        guard let atIndex = tokens.firstIndex(of: "at"), atIndex + 1 < tokens.count else { continue }
        let rawMac = tokens[atIndex + 1]
        guard rawMac.split(separator: ":").count == 6 else { continue }
        let mac = normalizeMAC(rawMac)

        guard let onIndex = tokens.firstIndex(of: "on"), onIndex + 1 < tokens.count else { continue }
        let ifname = tokens[onIndex + 1]

        rows.append(ArpLine(host: host, ip: ip, mac: mac, ifname: ifname))
    }
    return rows
}

// MARK: - Parsing helpers (fileprivate, pure functions)

internal struct HardwarePort: Sendable {
    let hardware: String
    let device: String
    let mac: String
}

/// Parse `networksetup -listallhardwareports` output into TB-only ports.
///
/// Each port is a 3-line block:
///   Hardware Port: Thunderbolt 1
///   Device: en2
///   Ethernet Address: 36:0a:fa:6e:db:00
///
/// Skips "Thunderbolt Bridge" (the aggregate).
internal func parseHardwarePorts(_ output: String) -> [HardwarePort] {
    var ports: [HardwarePort] = []
    var currentHardware: String?
    var currentDevice: String?
    var currentMAC: String?

    func flush() {
        defer {
            currentHardware = nil
            currentDevice = nil
            currentMAC = nil
        }
        guard
            let hw = currentHardware,
            let dev = currentDevice,
            let mac = currentMAC
        else { return }
        // Match "Thunderbolt 1", "Thunderbolt 2", etc. Exclude "Thunderbolt Bridge".
        guard hw.hasPrefix("Thunderbolt"), hw != "Thunderbolt Bridge" else { return }
        // Sanity: only accept TB ports with a numeric suffix or pure "Thunderbolt".
        let suffix = hw.dropFirst("Thunderbolt".count).trimmingCharacters(in: .whitespaces)
        if !suffix.isEmpty && Int(suffix) == nil { return }
        ports.append(HardwarePort(hardware: hw, device: dev, mac: mac))
    }

    for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine).trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            flush()
            continue
        }
        if let value = stripPrefix(line, "Hardware Port:") {
            // New block starting — flush any in-progress one first.
            flush()
            currentHardware = value.trimmingCharacters(in: .whitespaces)
        } else if let value = stripPrefix(line, "Device:") {
            currentDevice = value.trimmingCharacters(in: .whitespaces)
        } else if let value = stripPrefix(line, "Ethernet Address:") {
            currentMAC = value.trimmingCharacters(in: .whitespaces)
        }
    }
    // Last block may not be followed by a blank line.
    flush()
    return ports
}

/// Parse `ifconfig enN` output. Also extracts the IPv4 broadcast address so the
/// ARP-warming ping can target the interface's ACTUAL broadcast rather than a
/// hardcoded `169.254.255.255` (which is wrong on a non-link-local TB subnet).
internal func parseIfconfig(
    _ output: String
) -> (status: TBInterface.Status, ip: String?, mac: String?, broadcast: String?) {
    var status: TBInterface.Status = .unknown
    var ip: String?
    var mac: String?
    var broadcast: String?

    for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine).trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("status:") {
            let value = line
                .dropFirst("status:".count)
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            switch value {
            case "active":   status = .active
            case "inactive": status = .inactive
            default:         status = .unknown
            }
        } else if line.hasPrefix("inet ") {
            // "inet 169.254.207.237 netmask 0xffff0000 broadcast 169.254.255.255"
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if parts.count >= 2 {
                ip = parts[1]
            }
            if let bIdx = parts.firstIndex(of: "broadcast"), bIdx + 1 < parts.count {
                broadcast = parts[bIdx + 1]
            }
        } else if line.hasPrefix("ether ") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2 {
                mac = String(parts[1])
            }
        }
    }

    return (status, ip, mac, broadcast)
}

/// Parse `arp -a -i enN` output into peer rows, filtering out our own MAC and
/// non-unicast / unresolved entries.
///
/// Expected line format (variants):
///   `mbp2.local (169.254.202.29) at 36:c3:e8:89:79:8 on en3 [ethernet]`
///   `? (169.254.207.237) at 36:a:fa:6e:db:0 on en2 ifscope [ethernet]`
///   `? (169.254.255.255) at (incomplete) on en3 ...`
internal func parseArpTable(
    _ output: String,
    ownMac: String
) -> [(host: String?, ip: String, mac: String)] {
    var rows: [(host: String?, ip: String, mac: String)] = []
    let normalizedOwn = normalizeMAC(ownMac)

    for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = String(rawLine).trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.contains("(incomplete)") { continue }

        // Split into space-delimited tokens. The line begins with a hostname (possibly "?"),
        // then "(ip)", "at", "<mac>", "on", "<ifname>", ...
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 5 else { continue }

        // tokens[0] is the hostname token. Anything from "?" → nil. Any "(...)" → nil.
        let hostnameToken = tokens[0]
        let host: String? = {
            if hostnameToken == "?" || hostnameToken.hasPrefix("(") {
                return nil
            }
            return hostnameToken
        }()

        // Find the IP token: the one wrapped in parentheses like "(169.254.x.y)".
        guard let ipToken = tokens.first(where: { $0.hasPrefix("(") && $0.hasSuffix(")") }) else {
            continue
        }
        let ip = String(ipToken.dropFirst().dropLast())
        guard !ip.isEmpty else { continue }
        // IPv4 sanity: must look like "a.b.c.d".
        let ipParts = ip.split(separator: ".")
        guard ipParts.count == 4 else { continue }

        // Find the MAC token: the one immediately after "at".
        guard
            let atIndex = tokens.firstIndex(of: "at"),
            atIndex + 1 < tokens.count
        else { continue }
        let rawMac = tokens[atIndex + 1]
        // Sanity: a MAC has 5 colons separating 6 octets.
        guard rawMac.split(separator: ":").count == 6 else { continue }
        let mac = normalizeMAC(rawMac)

        // Filter: drop broadcast / multicast / our own MAC.
        if mac == "ff:ff:ff:ff:ff:ff" { continue }
        if mac.hasPrefix("01:00:5e") { continue }   // IPv4 multicast
        if mac.hasPrefix("33:33:")    { continue }  // IPv6 multicast
        if mac == normalizedOwn { continue }

        rows.append((host: host, ip: ip, mac: mac))
    }

    return rows
}

/// Attribute a peer address to one of our Thunderbolt ports from evidence of a
/// reply only: the kernel host route when it names an active port, otherwise the
/// lowest-named active port that answered a bound ping. Never guesses from the
/// address prefix or from the peer's own interface names, so an address no port
/// reaches yields nil and is never stored as the peer's IP.
internal func attributeThunderboltInterface(
    routeInterface: String?,
    answeringInterfaces: Set<String>,
    active: [TBInterface]
) -> String? {
    if let routeInterface, active.contains(where: { $0.name == routeInterface }) {
        return routeInterface
    }
    return active.map(\.name).filter(answeringInterfaces.contains).sorted().first
}

/// True for the RFC 3927 link-local range — the space a Thunderbolt bridge
/// self-assigns from when neither side has a static address.
func isLinkLocalIPv4(_ ip: String) -> Bool {
    guard isIPv4Address(ip) else { return false }
    return ip.hasPrefix("169.254.")
}

/// Every IPv4 currently bound on this machine, so discovery can tell our own
/// address (seen through a shared or virtual interface) apart from a peer's.
func allLocalIPv4() async -> Set<String> {
    guard let result = try? await ShellRunner.run("/sbin/ifconfig", [], timeout: 3) else { return [] }
    return parseLocalIPv4Addresses(result.stdout)
}

/// Parse `ifconfig` (no arguments) output into every IPv4 bound on this machine.
func parseLocalIPv4Addresses(_ output: String) -> Set<String> {
    var out: Set<String> = []
    for rawLine in output.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("inet ") else { continue }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { continue }
        let ip = String(parts[1])
        if isIPv4Address(ip) { out.insert(ip) }
    }
    return out
}

/// Normalize a MAC address to lowercase + zero-padded octets.
/// Example: `36:c3:e8:89:79:8` → `36:c3:e8:89:79:08`.
/// Inputs that don't look like a MAC are returned lowercased unchanged.
internal func normalizeMAC(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 6 else {
        return trimmed.lowercased()
    }
    let padded = parts.map { octet -> String in
        let o = String(octet).lowercased()
        return o.count == 1 ? "0\(o)" : o
    }
    return padded.joined(separator: ":")
}

/// Returns the substring after `prefix` if `line` starts with it (case-sensitive),
/// otherwise nil. Used for line-prefix parsing.
fileprivate func stripPrefix(_ line: String, _ prefix: String) -> String? {
    guard line.hasPrefix(prefix) else { return nil }
    return String(line.dropFirst(prefix.count))
}

internal func optionalStrip(_ line: String, _ prefix: String) -> String? {
    stripPrefix(line, prefix)
}
