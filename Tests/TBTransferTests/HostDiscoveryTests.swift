import XCTest
@testable import TBTransfer

/// Tests for the ARP-free discovery path added for macOS 27, where the ARP
/// table is hidden from every app-bundle process (`arp -an` exits 0 with no
/// output, granted Local Network or not) and `ifconfig` withholds the real MAC.
/// Discovery now leans on Bonjour + the resolver, so the pieces that replace
/// ARP — instance-name → host mapping, link-local classification, and the
/// synthetic MAC that stands in for an unreadable hardware address — are pinned
/// here. A wrong transform means either no peers or a peer that re-registers
/// with a new identity on every refresh.
final class HostDiscoveryTests: XCTestCase {

    // MARK: - localHostName(fromInstance:)

    func testLocalHostName_displayNameWithSpacesAndParens() {
        XCTAssertEqual(
            TBHostPeerBrowser.localHostName(fromInstance: "MacBook Pro (2)"),
            "macbook-pro-2.local"
        )
    }

    // MARK: - dns-sd output parsing (verbatim 27.0 samples)

    func testParseBrowseOutput_realSample() {
        let sample = """
        Browsing for _ssh._tcp.local
        DATE: ---Fri 18 Sep 2026---
        15:28:47.492  ...STARTING...
        Timestamp     A/R    Flags  if Domain               Service Type         Instance Name
        15:28:47.492  Add        3  13 local.               _ssh._tcp.           MacBook Pro (2)
        15:28:47.492  Add        2  18 local.               _ssh._tcp.           Raymond\\032Mac\\032Studio
        15:28:47.500  Rem        3  13 local.               _ssh._tcp.           MacBook Pro (2)
        15:28:52.000  Add        3  13 local.               _afpovertcp._tcp.    MacBook Pro (2)
        """
        let rows = TBHostPeerBrowser.parseBrowseOutput(sample, type: "_ssh._tcp")
        XCTAssertEqual(rows.count, 2, "Rem rows and other service types must be dropped")
        XCTAssertEqual(rows[0].instance, "MacBook Pro (2)")
        XCTAssertEqual(rows[0].interfaceIndex, 13)
        XCTAssertEqual(rows[1].instance, "Raymond Mac Studio", "\\032 must unescape to a space")
        XCTAssertEqual(rows[0].serviceType, "_ssh._tcp")
    }

    func testParseLookupOutput_realSample() {
        let sample = """
        Lookup MacBook Pro (2)._ssh._tcp.local
        DATE: ---Fri 18 Sep 2026---
        15:29:09.293  ...STARTING...
        15:29:09.293  MacBook\\032Pro\\032(2)._ssh._tcp.local. can be reached at mbp2.local.:22 (interface 18) Flags: 1
        """
        let target = TBHostPeerBrowser.parseLookupOutput(sample)
        XCTAssertEqual(target?.host, "mbp2.local", "the trailing dot on the FQDN must be stripped")
        XCTAssertEqual(target?.port, 22, "port is the field after the LAST colon of the address token")
        XCTAssertEqual(target?.interfaceIndex, 18, "must read the interface, not the 'Flags: 1' colon")
    }

    func testParseLookupOutput_rejectsNonLocalTarget() {
        // A unicast-DNS host is not a Thunderbolt peer.
        let sample = "x  can be reached at printer.lan:22 (interface 3)\n"
        XCTAssertNil(TBHostPeerBrowser.parseLookupOutput(sample))
    }

    func testParseLookupOutput_emptyAnswer() {
        XCTAssertNil(TBHostPeerBrowser.parseLookupOutput("Lookup failed\n"))
    }

    func testParseAddressOutput_realSample() {
        // `dns-sd -G v4 mac-studio-2.local` on 27.0: one row per interface,
        // link-local addresses on the Thunderbolt ports, negatives as 0.0.0.0.
        let sample = """
        Timestamp     A/R  Flags         IF  Hostname                 Address        TTL
        15:41:55.496  Add  40000003       7  mac-studio-2.local.      0.0.0.0        1   No Such Record
        15:41:55.496  Add  40000003       1  mac-studio-2.local.      127.0.0.1      4500
        15:41:55.496  Add  40000003      14  mac-studio-2.local.      169.254.130.196 4500
        15:41:55.496  Add  40000003      18  mac-studio-2.local.      192.168.68.51  4500
        15:41:55.496  Add  40000003      13  mac-studio-2.local.      169.254.235.83 4500
        """
        let rows = TBHostPeerBrowser.parseAddressOutput(sample)
        let byInterface = Dictionary(uniqueKeysWithValues: rows.map { ($0.interfaceIndex, $0.ip) })
        XCTAssertEqual(byInterface[13], "169.254.235.83")
        XCTAssertEqual(byInterface[14], "169.254.130.196")
        XCTAssertNil(byInterface[7], "No Such Record rows must be dropped")
        XCTAssertEqual(byInterface[18], "192.168.68.51", "non-link-local answers are kept; the caller filters")
    }

    func testParseAddressOutput_emptyAndGarbage() {
        XCTAssertTrue(TBHostPeerBrowser.parseAddressOutput("").isEmpty)
        XCTAssertTrue(TBHostPeerBrowser.parseAddressOutput("Lookup failed\n").isEmpty)
    }

    func testLocalHostName_curlyApostropheAndUnicode() {
        // Non-ASCII is folded to a separator; the display name is only ever a
        // fallback, since `dns-sd -L` gives the peer's real host directly.
        XCTAssertEqual(
            TBHostPeerBrowser.localHostName(fromInstance: "Ray’s Mac Studio"),
            "ray-s-mac-studio.local"
        )
    }

    func testUnescapeDNSSD() {
        XCTAssertEqual(
            TBHostPeerBrowser.unescapeDNSSD("MacBook\\032Pro\\032(2)"),
            "MacBook Pro (2)"
        )
        XCTAssertEqual(TBHostPeerBrowser.unescapeDNSSD("plain"), "plain")
    }

    func testParseLocalIPv4Addresses() {        let sample = """
        en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 9000
        \tinet 192.168.68.66 netmask 0xffffff00 broadcast 192.168.68.255
        \tinet6 fe80::1c1d:d3ff:fe5e:8b4e%en0 prefixlen 64 secured scopeid 0x1
        en3: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 65518
        \tinet 169.254.235.83 netmask 0xffff0000 broadcast 169.254.255.255
        lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
        \tinet 127.0.0.1 netmask 0xff000000
        """
        XCTAssertEqual(
            parseLocalIPv4Addresses(sample),
            ["192.168.68.66", "169.254.235.83", "127.0.0.1"]
        )
    }

    func testLocalHostName_collapseRunsAndTrimEdges() {
        XCTAssertEqual(
            TBHostPeerBrowser.localHostName(fromInstance: "  Two   Spaces  --  Here  "),
            "two-spaces-here.local"
        )
    }

    func testLocalHostName_alreadyNormalized_isIdempotent() {
        let once = TBHostPeerBrowser.localHostName(fromInstance: "mac-studio-2")
        XCTAssertEqual(once, "mac-studio-2.local")
        XCTAssertEqual(
            TBHostPeerBrowser.localHostName(fromInstance: "mac-studio-2"),
            once
        )
    }

    // MARK: - isLinkLocalIPv4

    func testIsLinkLocalIPv4() {
        XCTAssertTrue(isLinkLocalIPv4("169.254.48.164"))
        XCTAssertTrue(isLinkLocalIPv4("169.254.0.1"))
        XCTAssertFalse(isLinkLocalIPv4("169.253.4.4"))
        XCTAssertFalse(isLinkLocalIPv4("192.168.68.52"))
        XCTAssertFalse(isLinkLocalIPv4("fe80::1"))
        XCTAssertFalse(isLinkLocalIPv4(""))
    }

    // MARK: - syntheticMAC

    func testSyntheticMAC_isStableAndWellFormed() {
        let a = TBHostPeerBrowser.syntheticMAC(forHost: "mbp2.local")
        let b = TBHostPeerBrowser.syntheticMAC(forHost: "MBP2.LOCAL")
        XCTAssertEqual(a, b, "identity must not depend on host casing")
        XCTAssertEqual(a.split(separator: ":").count, 6)
        XCTAssertTrue(
            a.range(of: "^([0-9a-f]{2}:){5}[0-9a-f]{2}$", options: .regularExpression) != nil,
            "not a MAC-shaped string: \(a)"
        )
        let first = UInt8(a.prefix(2), radix: 16)!
        XCTAssertEqual(first & 0x02, 0x02, "must be locally administered")
        XCTAssertEqual(first & 0x01, 0x00, "must be unicast")
        XCTAssertNotEqual(a, "00:00:00:00:00:00")
    }

    func testSyntheticMAC_differsPerHost() {
        XCTAssertNotEqual(
            TBHostPeerBrowser.syntheticMAC(forHost: "mbp2.local"),
            TBHostPeerBrowser.syntheticMAC(forHost: "mac-studio-2.local")
        )
    }

    func testSyntheticMAC_neverCollidesWithThePlaceholderMAC() {
        // macOS 27 answers `ether 02:00:00:00:00:00` to apps; our stand-in must
        // not be mistaken for it by any de-dup that special-cases that value.
        XCTAssertNotEqual(TBHostPeerBrowser.syntheticMAC(forHost: "mbp2.local"),
                          normalizeMAC("02:00:00:00:00:00"))
    }

    // MARK: - ARP-table row filtering must survive the hidden-table case

    func testParseGlobalArpTable_emptyOutput_yieldsNoRows() {
        // The macOS 27 app-bundle reality: exit 0, zero bytes of entries.
        XCTAssertTrue(parseGlobalArpTable("").isEmpty)
    }
}
