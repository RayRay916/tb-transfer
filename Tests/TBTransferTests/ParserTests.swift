import XCTest
@testable import TBTransfer

/// Tests for the parsing helpers in `TBInterfaceMonitor.swift`.
///
/// The parsers are pure functions over raw shell output; they're the
/// translation surface between the network discovery commands
/// (`networksetup`, `ifconfig`, `arp -an`) and the typed `TBInterface` /
/// `DiscoveredPeer` models. Failing parsers cascade into "no peers found"
/// or "wrong interface used", which is silent and frustrating to debug —
/// hence pinning their behaviour with tests.
final class ParserTests: XCTestCase {

    // MARK: - parseHardwarePorts

    func testParseHardwarePorts_realSample_returnsTBOnly() {
        // Verbatim from the audit's task description.
        let input = """
        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: a2:8b:cd:ef:12:34

        Hardware Port: Thunderbolt 1
        Device: en2
        Ethernet Address: 36:0a:fa:6e:db:00

        Hardware Port: Thunderbolt Bridge
        Device: bridge0
        Ethernet Address: 36:0a:fa:6e:db:64

        Hardware Port: Thunderbolt 2
        Device: en3
        Ethernet Address: 36:0a:fa:6e:db:04
        """

        let ports = parseHardwarePorts(input)
        XCTAssertEqual(ports.count, 2, "Expected exactly two real Thunderbolt ports (Bridge excluded, Wi-Fi excluded).")

        // Order is preserved (parseHardwarePorts doesn't sort).
        XCTAssertEqual(ports[0].hardware, "Thunderbolt 1")
        XCTAssertEqual(ports[0].device, "en2")
        XCTAssertEqual(ports[0].mac, "36:0a:fa:6e:db:00")

        XCTAssertEqual(ports[1].hardware, "Thunderbolt 2")
        XCTAssertEqual(ports[1].device, "en3")
        XCTAssertEqual(ports[1].mac, "36:0a:fa:6e:db:04")
    }

    func testParseHardwarePorts_excludesThunderboltBridge() {
        // Bridge alone is the aggregate — must be filtered.
        let input = """
        Hardware Port: Thunderbolt Bridge
        Device: bridge0
        Ethernet Address: 36:0a:fa:6e:db:64
        """
        let ports = parseHardwarePorts(input)
        XCTAssertTrue(ports.isEmpty, "Thunderbolt Bridge should be excluded.")
    }

    func testParseHardwarePorts_noThunderboltEntries_returnsEmpty() {
        let input = """
        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: a2:8b:cd:ef:12:34

        Hardware Port: Ethernet
        Device: en4
        Ethernet Address: a0:b1:c2:d3:e4:f5
        """
        let ports = parseHardwarePorts(input)
        XCTAssertTrue(ports.isEmpty)
    }

    func testParseHardwarePorts_truncatedInput_doesNotCrashAndReturnsValidOnly() {
        // Trailing block is missing Ethernet Address — should be silently dropped.
        let input = """
        Hardware Port: Thunderbolt 1
        Device: en2
        Ethernet Address: 36:0a:fa:6e:db:00

        Hardware Port: Thunderbolt 2
        Device: en3
        """
        let ports = parseHardwarePorts(input)
        XCTAssertEqual(ports.count, 1, "Only the complete block should be returned.")
        XCTAssertEqual(ports[0].hardware, "Thunderbolt 1")
        XCTAssertEqual(ports[0].device, "en2")
    }

    func testParseHardwarePorts_emptyInput_returnsEmpty() {
        XCTAssertEqual(parseHardwarePorts("").count, 0)
    }

    func testParseHardwarePorts_excludesNonNumericThunderboltSuffix() {
        // "Thunderbolt FireWire" et al. that share the prefix but aren't TB ports
        // should be dropped by the numeric-suffix sanity check.
        let input = """
        Hardware Port: Thunderbolt FireWire
        Device: fw0
        Ethernet Address: aa:bb:cc:dd:ee:ff
        """
        let ports = parseHardwarePorts(input)
        XCTAssertTrue(ports.isEmpty, "Non-numeric suffix should be rejected.")
    }

    // MARK: - parseIfconfig

    func testParseIfconfig_activeWithInet() {
        // Trimmed-down realistic ifconfig output.
        let input = """
        en3: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
                options=460<TSO4,TSO6,CHANNEL_IO>
                ether 36:0a:fa:6e:db:04
                inet6 fe80::340a:faff:fe6e:db04%en3 prefixlen 64 scopeid 0xa
                inet 169.254.207.237 netmask 0xffff0000 broadcast 169.254.255.255
                nd6 options=201<PERFORMNUD,DAD>
                media: autoselect <full-duplex>
                status: active
        """
        let parsed = parseIfconfig(input)
        XCTAssertEqual(parsed.status, .active)
        XCTAssertEqual(parsed.ip, "169.254.207.237")
        XCTAssertEqual(parsed.mac, "36:0a:fa:6e:db:04")
        XCTAssertEqual(parsed.broadcast, "169.254.255.255",
                       "Broadcast address must be parsed for ARP warming.")
    }

    func testParseIfconfig_staticSubnetBroadcast() {
        // A manually-assigned static TB IP (non-link-local) must still yield its
        // real broadcast so the warming ping targets the right address.
        let input = """
        en5: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
                ether 36:0a:fa:6e:db:0c
                inet 10.77.3.1 netmask 0xffffff00 broadcast 10.77.3.255
                status: active
        """
        let parsed = parseIfconfig(input)
        XCTAssertEqual(parsed.ip, "10.77.3.1")
        XCTAssertEqual(parsed.broadcast, "10.77.3.255")
    }

    func testParseIfconfig_inactive_noInetButHasMac() {
        // An inactive TB interface has no inet line.
        let input = """
        en4: flags=8822<BROADCAST,SMART,SIMPLEX,MULTICAST> mtu 1500
                options=460<TSO4,TSO6,CHANNEL_IO>
                ether 36:0a:fa:6e:db:08
                media: autoselect <full-duplex>
                status: inactive
        """
        let parsed = parseIfconfig(input)
        XCTAssertEqual(parsed.status, .inactive)
        XCTAssertNil(parsed.ip)
        XCTAssertEqual(parsed.mac, "36:0a:fa:6e:db:08")
    }

    func testParseIfconfig_missingInetLine() {
        // "active" status declared but no inet line — represents a corner case
        // (e.g. interface is up but address not yet assigned).
        let input = """
        en3: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
                ether 36:0a:fa:6e:db:04
                status: active
        """
        let parsed = parseIfconfig(input)
        XCTAssertEqual(parsed.status, .active)
        XCTAssertNil(parsed.ip, "No inet line means ip must be nil.")
        XCTAssertEqual(parsed.mac, "36:0a:fa:6e:db:04")
    }

    func testParseIfconfig_onlyEtherLine_statusUnknown() {
        // Bare ether line with no status declaration.
        let input = """
        en3: flags=8822<BROADCAST,SMART,SIMPLEX,MULTICAST> mtu 1500
                ether 36:0a:fa:6e:db:04
        """
        let parsed = parseIfconfig(input)
        XCTAssertEqual(parsed.status, .unknown, "Missing status should be reported as .unknown.")
        XCTAssertNil(parsed.ip)
        XCTAssertEqual(parsed.mac, "36:0a:fa:6e:db:04")
    }

    func testParseIfconfig_emptyInput() {
        let parsed = parseIfconfig("")
        XCTAssertEqual(parsed.status, .unknown)
        XCTAssertNil(parsed.ip)
        XCTAssertNil(parsed.mac)
    }

    // MARK: - parseGlobalArpTable

    func testParseGlobalArpTable_multiLine_normalizesMACsAndStripsQuestionHost() {
        // Multi-line output mixing resolved and unresolved hostnames.
        // Note: `arp -an` always uses "?" for the host; `arp -a` may use a name.
        // Parser supports both.
        let input = """
        mbp2.local (169.254.202.29) at 36:c3:e8:89:79:8 on en3 ifscope [ethernet]
        ? (169.254.207.237) at 36:0a:fa:6e:db:0 on en2 ifscope [ethernet]
        """
        let rows = parseGlobalArpTable(input)
        XCTAssertEqual(rows.count, 2)

        XCTAssertEqual(rows[0].host, "mbp2.local")
        XCTAssertEqual(rows[0].ip, "169.254.202.29")
        // Short octet `8` should be zero-padded to `08`.
        XCTAssertEqual(rows[0].mac, "36:c3:e8:89:79:08")
        XCTAssertEqual(rows[0].ifname, "en3")

        // "?" hostname is normalized to nil.
        XCTAssertNil(rows[1].host)
        XCTAssertEqual(rows[1].ip, "169.254.207.237")
        XCTAssertEqual(rows[1].mac, "36:0a:fa:6e:db:00")
        XCTAssertEqual(rows[1].ifname, "en2")
    }

    func testParseGlobalArpTable_excludesIncomplete() {
        // An ARP entry with no MAC yet is "(incomplete)" — must be dropped.
        let input = """
        ? (169.254.255.255) at (incomplete) on en3 ifscope [ethernet]
        mbp2.local (169.254.202.29) at 36:c3:e8:89:79:8 on en3 ifscope [ethernet]
        """
        let rows = parseGlobalArpTable(input)
        XCTAssertEqual(rows.count, 1, "incomplete entry should be skipped.")
        XCTAssertEqual(rows[0].ip, "169.254.202.29")
    }

    func testParseGlobalArpTable_normalizesShortOctetMACs() {
        // Single-digit octets must all be zero-padded.
        let input = "? (169.254.50.50) at 3:6:a:fa:6e:db on en4 ifscope [ethernet]"
        let rows = parseGlobalArpTable(input)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].mac, "03:06:0a:fa:6e:db")
    }

    func testParseGlobalArpTable_includesMulticastMAC_filterIsCallersJob() {
        // The parser itself doesn't filter multicast (01:00:5e:..). The
        // top-level refresh() does that filtering at line ~135. We verify the
        // parser passes these through so the caller can decide.
        let input = "? (224.0.0.251) at 1:0:5e:0:0:fb on en4 ifscope [ethernet]"
        let rows = parseGlobalArpTable(input)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].mac, "01:00:5e:00:00:fb")
        // The caller (TBInterfaceMonitor.refresh) drops anything starting with
        // "01:00:5e" — covered separately by the integration logic, not here.
    }

    func testParseGlobalArpTable_handlesBroadcastMAC() {
        // Broadcast appears for 255-suffixed link-local IPs. The parser returns
        // them as-is; the caller filters by `mac == "ff:ff:ff:ff:ff:ff"`.
        let input = "? (169.254.255.255) at ff:ff:ff:ff:ff:ff on en3 ifscope [ethernet]"
        let rows = parseGlobalArpTable(input)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].mac, "ff:ff:ff:ff:ff:ff")
        XCTAssertEqual(rows[0].ifname, "en3")
    }

    func testParseGlobalArpTable_skipsLinesMissingTokens() {
        // Truncated / malformed lines should be skipped silently.
        let input = """
        garbage
        ? (169.254.202.29) at 36:c3:e8:89:79:8 on en3 ifscope [ethernet]
        ? (some-bogus) at xx on en4
        """
        let rows = parseGlobalArpTable(input)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].ip, "169.254.202.29")
    }

    func testParseGlobalArpTable_emptyInput() {
        XCTAssertTrue(parseGlobalArpTable("").isEmpty)
    }

    // MARK: - normalizeMAC

    func testNormalizeMAC_padsSingleDigitOctets() {
        XCTAssertEqual(normalizeMAC("36:c3:e8:89:79:8"), "36:c3:e8:89:79:08")
    }

    func testNormalizeMAC_alreadyPaddedLowercaseUnchanged() {
        XCTAssertEqual(normalizeMAC("36:0a:fa:6e:db:04"), "36:0a:fa:6e:db:04")
    }

    func testNormalizeMAC_uppercaseLowered() {
        XCTAssertEqual(normalizeMAC("36:0A:FA:6E:DB:04"), "36:0a:fa:6e:db:04")
    }

    func testNormalizeMAC_mixedCaseAndShortOctets() {
        XCTAssertEqual(normalizeMAC("3:6:A:FA:6E:db"), "03:06:0a:fa:6e:db")
    }

    func testNormalizeMAC_notAMAC_returnedLowercasedUnchanged() {
        // The function returns non-MAC input lowercased to avoid crashing
        // callers that pass through stray strings.
        XCTAssertEqual(normalizeMAC("hello world"), "hello world")
        XCTAssertEqual(normalizeMAC("Hello World"), "hello world")
    }

    func testNormalizeMAC_wrongOctetCount_returnedLowercasedUnchanged() {
        // 5 octets — still falls back to lowercase-only.
        XCTAssertEqual(normalizeMAC("36:0A:FA:6E:DB"), "36:0a:fa:6e:db")
        // 7 octets.
        XCTAssertEqual(normalizeMAC("36:0A:FA:6E:DB:04:EE"), "36:0a:fa:6e:db:04:ee")
    }

    func testNormalizeMAC_emptyString() {
        XCTAssertEqual(normalizeMAC(""), "")
    }

    // MARK: - parseArpTable (single-interface variant with ownMac filter)
    //
    // Bonus coverage for the variant that takes ownMac and applies all the
    // broadcast/multicast/self filters at parser layer.

    func testParseArpTable_filtersOwnAndMulticastAndBroadcast() {
        let ownMac = "36:0a:fa:6e:db:00"
        let input = """
        mbp2.local (169.254.202.29) at 36:c3:e8:89:79:8 on en3 ifscope [ethernet]
        ? (169.254.207.237) at 36:0a:fa:6e:db:0 on en2 ifscope [ethernet]
        ? (169.254.255.255) at ff:ff:ff:ff:ff:ff on en3 ifscope [ethernet]
        ? (224.0.0.251) at 1:0:5e:0:0:fb on en3 ifscope [ethernet]
        ? (ff02::fb) at 33:33:0:0:0:fb on en3 ifscope [ethernet]
        """
        let rows = parseArpTable(input, ownMac: ownMac)
        // Only the legitimate peer (mbp2.local) survives. Own MAC dropped,
        // broadcast/multicast dropped.
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].host, "mbp2.local")
        XCTAssertEqual(rows[0].mac, "36:c3:e8:89:79:08")
    }
}

/// Tests for the discovery/establishment robustness helpers added to harden
/// peer detection (IP validation, broadened usability) and SSH establishment
/// (stable per-peer host-key identity that survives link-local IP reuse).
final class RobustnessTests: XCTestCase {

    // MARK: - isIPv4Address

    func testIsIPv4Address_valid() {
        XCTAssertTrue(isIPv4Address("169.254.5.6"))
        XCTAssertTrue(isIPv4Address("10.0.0.2"))
        XCTAssertTrue(isIPv4Address("255.255.255.255"))
        XCTAssertTrue(isIPv4Address("0.0.0.0"))
    }

    func testIsIPv4Address_invalid() {
        XCTAssertFalse(isIPv4Address(""))
        XCTAssertFalse(isIPv4Address("169.254.5"))         // too few octets
        XCTAssertFalse(isIPv4Address("169.254.5.6.7"))     // too many
        XCTAssertFalse(isIPv4Address("169.254.5.256"))     // out of range
        XCTAssertFalse(isIPv4Address("169.254.x.6"))       // non-numeric
        XCTAssertFalse(isIPv4Address("fe80::1"))           // IPv6
        XCTAssertFalse(isIPv4Address("169.254..6"))        // empty octet
    }

    // MARK: - TBInterface.isUsable (broadened beyond link-local)

    func testInterfaceUsable_linkLocal() {
        let iface = TBInterface(name: "en3", hardwareName: "Thunderbolt 1",
                                macAddress: "aa:bb:cc:dd:ee:ff",
                                localIP: "169.254.1.2", status: .active)
        XCTAssertTrue(iface.isUsable)
    }

    func testInterfaceUsable_staticPrivateIP() {
        // A TB link with a manually-assigned static IP must now count as usable.
        let iface = TBInterface(name: "en5", hardwareName: "Thunderbolt 3",
                                macAddress: "aa:bb:cc:dd:ee:ff",
                                localIP: "10.77.3.1", status: .active)
        XCTAssertTrue(iface.isUsable)
    }

    func testInterfaceNotUsable_inactiveOrNoIP() {
        let inactive = TBInterface(name: "en4", hardwareName: "Thunderbolt 2",
                                   macAddress: "aa:bb:cc:dd:ee:ff",
                                   localIP: "169.254.1.2", status: .inactive)
        XCTAssertFalse(inactive.isUsable)
        let noIP = TBInterface(name: "en4", hardwareName: "Thunderbolt 2",
                               macAddress: "aa:bb:cc:dd:ee:ff",
                               localIP: nil, status: .active)
        XCTAssertFalse(noIP.isUsable)
        let garbageIP = TBInterface(name: "en4", hardwareName: "Thunderbolt 2",
                                    macAddress: "aa:bb:cc:dd:ee:ff",
                                    localIP: "not-an-ip", status: .active)
        XCTAssertFalse(garbageIP.isUsable)
    }

    // MARK: - Peer host-key identity (stable across IP churn)

    func testHostKeyAlias_isStableAndUUIDDerived() {
        let id = UUID()
        let p1 = Peer(id: id, label: "a", lastKnownHostname: "a.local",
                      sshUsername: "u", lastSeenIP: "169.254.1.2")
        let p2 = Peer(id: id, label: "renamed", lastKnownHostname: "b.local",
                      sshUsername: "u", lastSeenIP: "169.254.9.9")  // different IP/host
        // Alias depends ONLY on the UUID — so it survives IP/hostname/label
        // changes, which is the whole point (no false host-key-changed fails).
        XCTAssertEqual(p1.hostKeyAlias, p2.hostKeyAlias)
        XCTAssertEqual(p1.hostKeyAlias, "tbtransfer-\(id.uuidString.lowercased())")
    }

    func testHostKeyAlias_differsPerPeer() {
        let a = Peer(label: "a", lastKnownHostname: "a", sshUsername: "u")
        let b = Peer(label: "b", lastKnownHostname: "b", sshUsername: "u")
        XCTAssertNotEqual(a.hostKeyAlias, b.hostKeyAlias)
    }

    // MARK: - Managed-key gating (forget safety)

    func testUsesManagedKey_trueForDedicatedPath() {
        let id = UUID()
        var p = Peer(id: id, label: "a", lastKnownHostname: "a", sshUsername: "u")
        p.sshKeyPath = p.dedicatedKeyPath
        XCTAssertTrue(p.usesManagedKey,
                      "A key under ~/.ssh/tbtransfer/ must be recognised as managed.")
    }

    func testUsesManagedKey_falseForPersonalKeys() {
        // Legacy/shared/personal keys must NOT be treated as managed — Forget
        // Peer must never delete these.
        for path in ["~/.ssh/id_ed25519", "~/.ssh/mbp2", "/Users/x/.ssh/id_rsa"] {
            var p = Peer(label: "a", lastKnownHostname: "a", sshUsername: "u")
            p.sshKeyPath = path
            XCTAssertFalse(p.usesManagedKey, "\(path) must not be flagged managed.")
        }
        // nil key path → not managed.
        let noKey = Peer(label: "a", lastKnownHostname: "a", sshUsername: "u")
        XCTAssertFalse(noKey.usesManagedKey)
    }

    func testUsesManagedKey_rejectsSiblingPrefix() {
        // "~/.ssh/tbtransferX/..." must NOT match "~/.ssh/tbtransfer/" — the
        // boundary check requires a trailing slash on the directory prefix.
        var p = Peer(label: "a", lastKnownHostname: "a", sshUsername: "u")
        p.sshKeyPath = "~/.ssh/tbtransferX/key"
        XCTAssertFalse(p.usesManagedKey)
    }

    // MARK: - Port-change path selection (same machine, different TB ports)

    private func dp(_ iface: String, _ ip: String, _ mac: String, _ host: String?) -> DiscoveredPeer {
        DiscoveredPeer(interfaceName: iface, ipAddress: ip, macAddress: mac, hostname: host)
    }

    func testIdentityKey_hostnameIsPortIndependent() {
        // Same machine on two ports → same hostname → SAME identity key, even
        // though interface / IP / MAC all differ.
        let a = dp("en3", "169.254.1.2", "aa:aa:aa:aa:aa:aa", "studio.local")
        let b = dp("en5", "169.254.9.9", "bb:bb:bb:bb:bb:bb", "studio.local.")
        XCTAssertEqual(discoveryIdentityKey(a), discoveryIdentityKey(b))
    }

    func testIdentityKey_fallsBackToMacWhenUnresolved() {
        let a = dp("en3", "169.254.1.2", "aa:aa:aa:aa:aa:aa", nil)
        XCTAssertEqual(discoveryIdentityKey(a), "m:aa:aa:aa:aa:aa:aa")
        let b = dp("en3", "169.254.1.2", "aa:aa:aa:aa:aa:aa", "studio.local")
        XCTAssertEqual(discoveryIdentityKey(b), "h:studio.local")
    }

    func testSelectPath_stickyKeepsLivePort() {
        // Peer currently on en3; both en3 and en5 are live this pass. We must
        // STAY on en3 (no 5s flip-flop between two live ports).
        let candidates = [
            dp("en5", "169.254.9.9", "bb:bb:bb:bb:bb:bb", "studio.local"),
            dp("en3", "169.254.1.2", "aa:aa:aa:aa:aa:aa", "studio.local"),
        ]
        let chosen = selectDiscoveredPath(candidates, stickyInterface: "en3")
        XCTAssertEqual(chosen?.interfaceName, "en3")
    }

    func testSelectPath_migratesWhenStickyPortGone() {
        // Cable moved from en3 → en5: the old sticky interface is no longer in
        // this pass, so we must migrate to the live port.
        let candidates = [
            dp("en5", "169.254.9.9", "bb:bb:bb:bb:bb:bb", "studio.local"),
        ]
        let chosen = selectDiscoveredPath(candidates, stickyInterface: "en3")
        XCTAssertEqual(chosen?.interfaceName, "en5")
        XCTAssertEqual(chosen?.ipAddress, "169.254.9.9")
    }

    func testSelectPath_prefersResolvedHostnameThenLowestInterface() {
        // No sticky. A resolved-hostname path beats a bare ARP entry, even if
        // the bare one is on a lower interface.
        let candidates = [
            dp("en3", "169.254.1.2", "aa:aa:aa:aa:aa:aa", nil),
            dp("en5", "169.254.9.9", "bb:bb:bb:bb:bb:bb", "studio.local"),
        ]
        let chosen = selectDiscoveredPath(candidates, stickyInterface: nil)
        XCTAssertEqual(chosen?.interfaceName, "en5")

        // All unresolved → lowest interface name wins (deterministic).
        let bare = [
            dp("en5", "169.254.9.9", "bb:bb:bb:bb:bb:bb", nil),
            dp("en3", "169.254.1.2", "aa:aa:aa:aa:aa:aa", nil),
        ]
        XCTAssertEqual(selectDiscoveredPath(bare, stickyInterface: nil)?.interfaceName, "en3")
    }

    func testSelectPath_emptyCandidatesAndStaleSticky() {
        XCTAssertNil(selectDiscoveredPath([], stickyInterface: "en3"))
        // A sticky interface that isn't among candidates is ignored gracefully.
        let candidates = [dp("en5", "169.254.9.9", "bb:bb:bb:bb:bb:bb", "studio.local")]
        XCTAssertEqual(selectDiscoveredPath(candidates, stickyInterface: "enX")?.interfaceName, "en5")
    }
}

/// Tests for the benchmark engine's pure parsers (MTU + byte-count extraction).
final class BenchmarkParserTests: XCTestCase {

    func testParseMTU_jumbo() {
        let ifc = """
        en3: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 65518
        \tether 36:0a:fa:6e:db:04
        \tinet 169.254.207.237 netmask 0xffff0000 broadcast 169.254.255.255
        \tstatus: active
        """
        XCTAssertEqual(BenchmarkEngine.parseMTU(fromIfconfig: ifc), 65518)
    }

    func testParseMTU_standardAndMissing() {
        XCTAssertEqual(BenchmarkEngine.parseMTU(fromIfconfig: "en0: flags=8863<UP> mtu 1500"), 1500)
        XCTAssertNil(BenchmarkEngine.parseMTU(fromIfconfig: "en0: flags=8863<UP>\n\tstatus: active"))
        XCTAssertNil(BenchmarkEngine.parseMTU(fromIfconfig: ""))
    }

    func testParseTotalBytes_takesLastInteger() {
        // The receiver script echoes the summed byte total as the final line.
        XCTAssertEqual(BenchmarkEngine.parseTotalBytes("recv: debug\n1467061248\n"), 1467061248)
        XCTAssertEqual(BenchmarkEngine.parseTotalBytes("0"), 0)
        XCTAssertEqual(BenchmarkEngine.parseTotalBytes(""), 0)
        // Trailing whitespace / blank lines tolerated.
        XCTAssertEqual(BenchmarkEngine.parseTotalBytes("  889192448  \n\n"), 889192448)
    }
}
