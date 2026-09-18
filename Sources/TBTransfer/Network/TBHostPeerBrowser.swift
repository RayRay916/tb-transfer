import Foundation
import Network

/// Bonjour-based peer discovery — the macOS 27 replacement for the ARP scan.
///
/// macOS 27 privacy-filters the ARP table for every process whose responsible
/// program is an app bundle: `arp -an` exits 0 and prints *nothing*, whether or
/// not Local Network access is granted (verified on 27.0 / 26A428 — an approved
/// app still sees zero entries). `ifconfig` likewise withholds the real MAC and
/// answers `ether 02:00:00:00:00:00`. `networksetup`, mDNSResponder
/// (`dscacheutil`), `route` and outbound TCP are unaffected.
///
/// So discovery becomes: browse for services every reachable Mac advertises,
/// turn those instance names into `.local` hosts, resolve them with
/// `dscacheutil`, keep the link-local (RFC 3927 — what a Thunderbolt bridge
/// uses) addresses that are not ours, and attribute each one to a port with
/// `route -n get`.
enum TBHostPeerBrowser {
    /// Service types advertised by a stock macOS with Remote Login or Remote
    /// Management on. TBTransfer needs SSH to move files either way, so a peer
    /// that shows up in neither is a peer it could not have used.
    static let browseTypes = ["_ssh._tcp", "_rfb._tcp"]

    /// One advertised Bonjour service seen on the network.
    struct Service: Hashable, Sendable {
        let instanceName: String
        let type: String
    }

    /// Browse for `browseTypes` for `dwell` seconds. Non-blocking on the caller:
    /// returns after the dwell, with whatever landed.
    static func browse(dwell: TimeInterval = 2.5) async -> [Service] {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let box = ServiceBox()
        await withTaskGroup(of: Void.self) { group in
            for type in browseTypes {
                group.addTask {
                    let browser = NWBrowser(
                        for: .bonjour(type: type, domain: "local"),
                        using: params
                    )
                    browser.browseResultsChangedHandler = { results, _ in
                        var seen: [Service] = []
                        for r in results {
                            if case .service(let name, let t, _, _) = r.endpoint {
                                seen.append(Service(instanceName: name, type: t))
                            }
                        }
                        box.merge(seen)
                    }
                    browser.start(queue: DispatchQueue.global(qos: .userInitiated))
                    try? await Task.sleep(for: .seconds(dwell))
                    browser.cancel()
                }
            }
            await group.waitForAll()
        }
        return box.services()
    }

    /// Bonjour instance names are a display string, while the resolvable host is
    /// `<LocalHostName>.local` — the lowercased computer name with non
    /// `[a-z0-9-]` runs collapsed to single hyphens (System Settings builds it
    /// that way). Same transform applied to both sides makes them match without
    /// any hardcoding.
    static func localHostName(fromInstance instance: String) -> String {
        var out = ""
        var lastWasDash = false
        for scalar in instance.lowercased().unicodeScalars {
            let isAlnum = CharacterSet.alphanumerics.contains(scalar)
            if isAlnum {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out + ".local"
    }

    /// One advertised Bonjour service, with the interface index it was seen on.
    struct DNSSDInstance: Hashable, Sendable {
        let interfaceIndex: Int
        let instance: String
        let serviceType: String
    }

    /// Short-lived `dns-sd -B` capture. Reports one row per (service, interface),
    /// which is how a peer on a Thunderbolt port is distinguished from the same
    /// peer seen on Wi-Fi.
    static func browseInstances(types: [String] = browseTypes, dwell: TimeInterval = 2.5) async -> [DNSSDInstance] {
        await withTaskGroup(of: [DNSSDInstance].self) { group in
            for type in types {
                group.addTask { await browseInstances(type: type, dwell: dwell) }
            }
            var all: [DNSSDInstance] = []
            for await part in group { all.append(contentsOf: part) }
            return all
        }
    }

    static func browseInstances(type: String, dwell: TimeInterval) async -> [DNSSDInstance] {
        guard let result = try? await ShellRunner.run(
            "/usr/bin/dns-sd", ["-B", type, "local"], timeout: dwell + 2
        ) else { return [] }
        return parseBrowseOutput(result.stdout, type: type)
    }

    /// Parse `dns-sd -B` output. Rows look like:
    ///   `15:28:47.492  Add        3  13 local.  _ssh._tcp.  MacBook Pro (2)`
    /// with the interface index in column 3 — the only per-port attribution left
    /// to us once the ARP table is hidden.
    static func parseBrowseOutput(_ output: String, type: String) -> [DNSSDInstance] {
        var out: [DNSSDInstance] = []
        var headerSeen = false
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            // Skip the "Browsing for…" preamble and the "DATE/…STARTING…" banner.
            if line.contains("...STARTING...") || line.hasPrefix("Browsing for")
                || line.hasPrefix("DATE:") || line.trimmingCharacters(in: .whitespaces).isEmpty {
                if line.contains("...STARTING...") { headerSeen = true }
                continue
            }
            guard headerSeen else { continue }
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // Timestamp A/R Flags <ifindex> <domain> <service type.> <instance...>
            guard cols.count >= 7, cols[1] == "Add" else { continue }
            guard let ifIndex = Int(cols[3]) else { continue }
            guard cols[4].hasPrefix("local") else { continue }
            guard cols[5] == type + "." else { continue }
            let instance = unescapeDNSSD(cols[6...].joined(separator: " "))
            guard !instance.isEmpty else { continue }
            out.append(DNSSDInstance(interfaceIndex: ifIndex, instance: instance, serviceType: type))
        }
        return out
    }

    /// `dns-sd` escapes spaces in instance names as `\032`.
    static func unescapeDNSSD(_ s: String) -> String {
        var out = s
        // Longest first so `\032` is not half-consumed.
        for (esc, ch) in [("\\032", " "), ("\\\\", "\\"), ("\\046", "."), ("\\064", "@"), ("\\092", "\\")] {
            out = out.replacingOccurrences(of: esc, with: ch)
        }
        return out
    }

    /// What a service resolves to: the host it points at, its port, and the
    /// interface index the answer arrived on.
    struct ServiceTarget: Hashable, Sendable {
        let host: String      // e.g. "mbp2.local"
        let port: Int
        let interfaceIndex: Int
    }

    /// The host a service actually points at, e.g. `mbp2.local` — read from
    /// `dns-sd -L`, which prints
    ///   `<instance> can be reached at <host>:<port> (interface <n>) Flags: <f>`
    /// This is the machine's own advertised hostname, so unlike the instance
    /// name (its *display* name) it resolves without guessing, and the interface
    /// index tells us which physical port the peer is on.
    static func lookupTarget(instance: String, type: String) async -> ServiceTarget? {
        guard let result = try? await ShellRunner.run(
            "/usr/bin/dns-sd", ["-L", instance, type, "local"], timeout: 4
        ) else { return nil }
        return parseLookupOutput(result.stdout)
    }

    /// Parse the first useful `dns-sd -L` answer line.
    static func parseLookupOutput(_ output: String) -> ServiceTarget? {
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            guard let atRange = line.range(of: "can be reached at ") else { continue }
            let tail = String(line[atRange.upperBound...])
            // "<host>:<port>" is the first whitespace-delimited field.
            guard let field = tail.split(separator: " ", omittingEmptySubsequences: true).first
            else { continue }
            let hostPort = String(field)
            guard let colon = hostPort.lastIndex(of: ":") else { continue }
            let hostText = String(hostPort[..<colon])
            guard let port = Int(hostPort[hostPort.index(after: colon)...]) else { continue }
            var host = hostText
            while host.hasSuffix(".") { host.removeLast() }
            guard host.lowercased().hasSuffix(".local") else { continue }
            var ifIndex = 0
            if let iRange = tail.range(of: "(interface ") {
                let digits = tail[iRange.upperBound...].prefix { $0.isNumber }
                ifIndex = Int(digits) ?? 0
            }
            return ServiceTarget(host: host, port: port, interfaceIndex: ifIndex)
        }
        return nil
    }

    /// This machine's own `.local` host, for dropping self-advertisements.
    static func selfHostName() -> String {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard gethostname(&buffer, buffer.count) == 0 else { return "" }
        return String(decoding: Array(buffer.prefix { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Resolve a `.local` host to its link-local IPv4 addresses.
    ///
    /// - Parameter hosts: host → the interface index it was advertised on, so a
    ///   peer seen on the Thunderbolt port keeps that attribution.
    static func linkLocalAddresses(for hosts: [String: Int]) async -> [(host: String, ip: String, interfaceIndex: Int)] {
        var out: [(host: String, ip: String, interfaceIndex: Int)] = []
        await withTaskGroup(of: (String, [String], Int).self) { group in
            for (host, ifIndex) in hosts {
                group.addTask { (host, await addresses(of: host), ifIndex) }
            }
            for await (host, ips, ifIndex) in group {
                for ip in ips where isLinkLocalIPv4(ip) {
                    out.append((host, ip, ifIndex))
                }
            }
        }
        return out
    }

    /// A resolved address plus the interface index it was answered on. mDNS
    /// answers per interface, which is exactly the port attribution the hidden
    /// ARP table used to give us.
    struct ResolvedAddress: Hashable, Sendable {
        let ip: String
        let interfaceIndex: Int
    }

    /// Every IPv4 the resolver has for `host`, with interface attribution, via
    /// `dns-sd -G v4` (one row per interface the address is reachable through).
    /// Unlike `dscacheutil`, which collapses a host to a single flat answer, this
    /// tells us *which port* a peer is reachable on — and does not depend on a
    /// possibly-stale cloned route.
    static func resolvedAddresses(of host: String, dwell: TimeInterval = 1.5) async -> [ResolvedAddress] {
        var query = host
        while query.hasSuffix(".") { query.removeLast() }
        guard let result = try? await ShellRunner.run(
            "/usr/bin/dns-sd", ["-G", "v4", query.hasSuffix(".local") ? query : query + ".local"],
            timeout: dwell + 2
        ) else { return [] }
        return parseAddressOutput(result.stdout)
    }

    /// Parse `dns-sd -G v4` output:
    ///   `15:41:55.496  Add  40000003  13  mac-studio-2.local.  169.254.235.83  4500`
    /// Rows with a `No Such Record` tail carry `0.0.0.0` and are dropped.
    static func parseAddressOutput(_ output: String) -> [ResolvedAddress] {
        var out: [ResolvedAddress] = []
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            guard line.contains("Add") || line.contains("Rmk") else { continue }
            if line.contains("No Such Record") { continue }
            if line.contains("No Such Record") { continue }
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 5, cols[1] == "Add" else { continue }
            guard let ifIndex = Int(cols[3]) else { continue }
            // The address is the first dotted-quad after the interface column.
            guard let ip = cols.dropFirst(3).first(where: { octets in
                octets.split(separator: ".").count == 4 && isIPv4Address(octets)
            }) else { continue }
            guard ip != "0.0.0.0" else { continue }
            out.append(ResolvedAddress(ip: ip, interfaceIndex: ifIndex))
        }
        return Array(Set(out))
    }

    /// All IPv4 addresses the resolver has for `host` (mDNS included).
    static func addresses(of host: String) async -> [String] {
        // dscacheutil wants the bare name, not the FQDN form dns-sd prints.
        var query = host
        while query.hasSuffix(".") { query.removeLast() }
        guard let result = try? await ShellRunner.run(
            "/usr/bin/dscacheutil",
            ["-q", "host", "-a", "name", query],
            timeout: 2
        ) else { return [] }
        var ips: [String] = []
        for rawLine in result.stdout.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("ip_address:") else { continue }
            let ip = String(line.dropFirst("ip_address:".count)).trimmingCharacters(in: .whitespaces)
            if isIPv4Address(ip) { ips.append(ip) }
        }
        return ips
    }

    /// The interface `route` would use for `ip`, e.g. "en3". Used to attribute a
    /// resolved peer to a specific Thunderbolt port.
    static func interface(forIP ip: String) async -> String? {
        guard let result = try? await ShellRunner.run(
            "/sbin/route",
            ["-n", "get", ip],
            timeout: 2
        ) else { return nil }
        for rawLine in result.stdout.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let value = optionalStrip(line, "interface:") {
                let dev = value.trimmingCharacters(in: .whitespaces)
                return dev.isEmpty ? nil : dev
            }
        }
        return nil
    }

    /// Deterministic stand-in for a hardware address we can no longer read:
    /// a locally-administered, unicast, zero-unicast-litter MAC derived from the
    /// peer's hostname. Stable across passes (so `lastSeenMAC` doesn't churn)
    /// and cannot collide with a burned-in OUI-assigned address.
    static func syntheticMAC(forHost host: String) -> String {
        let digest = SHA256Digest.of(Data(host.lowercased().utf8))
        let octets = digest.prefix(6).map { Int($0) }
        var first = octets[0]
        first |= 0x02      // locally administered
        first &= 0xFE      // unicast
        return String(
            format: "%02x:%02x:%02x:%02x:%02x:%02x",
            first, octets[1], octets[2], octets[3], octets[4], octets[5]
        )
    }
}

/// Lock-protected accumulator: `NWBrowser`'s result callback is synchronous and
/// fires on its own queue, so an actor cannot be used from inside it.
private final class ServiceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TBHostPeerBrowser.Service] = []
    func merge(_ new: [TBHostPeerBrowser.Service]) {
        lock.lock(); defer { lock.unlock() }
        for s in new where !items.contains(s) { items.append(s) }
    }
    func services() -> [TBHostPeerBrowser.Service] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

/// Minimal SHA-256 (CryptoKit `Hasher` is not stable across process launches,
/// and we need a value that survives a restart without importing CryptoKit).
enum SHA256Digest {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func of(_ message: Data) -> [UInt8] {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var data = [UInt8](message)
        let bitLength = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }
        var w = [UInt32](repeating: 0, count: 64)
        for chunkStart in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                let o = chunkStart + i * 4
                w[i] = (UInt32(data[o]) << 24) | (UInt32(data[o + 1]) << 16)
                     | (UInt32(data[o + 2]) << 8) | UInt32(data[o + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        var out: [UInt8] = []
        for word in h {
            out.append(UInt8((word >> 24) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8(word & 0xff))
        }
        return out
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}
