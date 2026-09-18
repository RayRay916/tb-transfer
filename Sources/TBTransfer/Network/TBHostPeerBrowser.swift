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

    /// `dns-sd` escapes spaces in instance names as `\032`.
    static func unescapeDNSSD(_ s: String) -> String {
        var out = s
        // Longest first so `\032` is not half-consumed.
        for (esc, ch) in [("\\032", " "), ("\\\\", "\\"), ("\\046", "."), ("\\064", "@"), ("\\092", "\\")] {
            out = out.replacingOccurrences(of: esc, with: ch)
        }
        return out
    }

    /// This machine's own `.local` host, for dropping self-advertisements.
    static func selfHostName() -> String {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard gethostname(&buffer, buffer.count) == 0 else { return "" }
        return String(decoding: Array(buffer.prefix { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Our Bonjour instance name: `selfHostName()` minus the `.local` suffix, i.e.
    /// the `LocalHostName` System Settings derives from the computer name.
    static func localHostNameInstance() -> String {
        var host = selfHostName()
        if host.lowercased().hasSuffix(".local") {
            host = String(host.dropLast(".local".count))
        }
        return host
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

    /// Service types we browse for. `_tbtransfer._tcp` is our own advertisement
    /// and the only one that carries Thunderbolt addresses in its TXT record;
    /// the other two are the fallback for peers still running a pre-advertisement
    /// build (they expose the peer's host but not its TB address).
    static let browseTypes = ["_tbtransfer._tcp", "_ssh._tcp", "_rfb._tcp"]

    /// One advertised instance with everything a single `dns-sd -Z` pass tells us.
    struct Advertisement: Hashable, Sendable {
        let instance: String
        let serviceType: String
        /// The peer's `foo.local` host, taken from the SRV target.
        let targetHost: String
        let port: Int
        /// `enN → ipv4` from the TXT record; empty for foreign service types.
        let txt: [String: String]

        /// True when the TXT declares itself as coming from a TBTransfer peer.
        var isFromTBTransfer: Bool { txt["tbv"] != nil }
    }

    /// Everything after the record type on a zone-file line is the record value:
    /// `<name> <TYPE> <value...>` — value begins at index 2.
    private static func zoneValue(_ line: Substring) -> String {
        line.split(separator: " ", omittingEmptySubsequences: true).dropFirst(2)
            .joined(separator: " ")
    }

    /// Parse `dns-sd -Z <type> local` output into advertisements:
    ///   `mac-studio-2._tbtransfer._tcp  SRV  0 0 41617 mac-studio-2.local. ; comment`
    ///   `mac-studio-2._tbtransfer._tcp  TXT  "tbv=1" "en3=169.254.235.83"`
    ///
    /// Instances come from the SRV/TXT record names, not the PTR line: dns-sd
    /// prints instance names *unescaped*, so a display name containing a space
    /// (`MacBook Pro (2)._ssh._tcp`) would otherwise break column parsing.
    static func parseZoneOutput(_ output: String, type: String) -> [Advertisement] {
        var order: [String] = []
        var srv: [String: (String, Int)] = [:]
        var txt: [String: [String: String]] = [:]
        let suffix = "." + type

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix(";") else { continue }
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 3, cols[1] == "SRV" || cols[1] == "TXT" else { continue }
            let name = cols[0]
            guard name.hasSuffix(suffix) else { continue }
            let instance = String(name.dropLast(suffix.count))
            let value = zoneValue(rawLine)

            switch cols[1] {
            case "SRV":
                // "<priority> <weight> <port> <target.>"
                let parts = value.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard parts.count >= 4, let port = Int(parts[2]) else { continue }
                var host = parts[3]
                while host.hasSuffix(".") { host.removeLast() }
                if srv[instance] == nil { order.append(instance) }
                srv[instance] = (host, port)
            default:
                txt[instance] = parseTXTQuotedEntries(value)
            }
        }

        return order.compactMap { instance in
            guard let (host, port) = srv[instance] else { return nil }
            return Advertisement(
                instance: instance,
                serviceType: type,
                targetHost: host,
                port: port,
                txt: txt[instance] ?? [:]
            )
        }
    }

    /// Parse the `"key=value" "other=2"` form `dns-sd -Z` prints for TXT records.
    static func parseTXTQuotedEntries(_ value: String) -> [String: String] {
        var out: [String: String] = [:]
        let chars = Array(value)
        var i = 0
        while i < chars.count {
            guard chars[i] == "\"" else { i += 1; continue }
            i += 1
            var entry = ""
            while i < chars.count, chars[i] != "\"" { entry.append(chars[i]); i += 1 }
            i += 1                                     // step over the closing quote
            if let eq = entry.firstIndex(of: "=") {
                out[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
            } else {
                out[entry] = ""
            }
        }
        return out
    }

    /// Browse one type and return its full advertisement records.
    static func advertisements(type: String, dwell: TimeInterval = 2.5) async -> [Advertisement] {
        guard let result = try? await ShellRunner.run(
            "/usr/bin/dns-sd", ["-Z", type, "local"], timeout: dwell + 2
        ) else { return [] }
        return parseZoneOutput(result.stdout, type: type)
    }

    static func advertisements(types: [String] = browseTypes, dwell: TimeInterval = 2.5) async -> [Advertisement] {
        await withTaskGroup(of: [Advertisement].self) { group in
            for type in types {
                group.addTask { await advertisements(type: type, dwell: dwell) }
            }
            var all: [Advertisement] = []
            for await part in group { all.append(contentsOf: part) }
            return all
        }
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
