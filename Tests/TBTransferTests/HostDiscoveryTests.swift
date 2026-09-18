import XCTest
@testable import TBTransfer

/// Tests for the ARP-free discovery path added for macOS 27, where the ARP table
/// is hidden from every app-bundle process (`arp -an` exits 0 with no output,
/// granted Local Network access or not) and `ifconfig` withholds the real MAC.
///
/// Discovery now rides on Bonjour: a peer's Thunderbolt IPv4 addresses travel in
/// the TXT record of our `_tbtransfer._tcp` advertisement, with per-interface
/// mDNS address records as the fallback. These parsers are the whole translation
/// surface between that output and `DiscoveredPeer`, and every failure mode here
/// is silent — a wrong parse reads as "no peers" or re-births a peer under a new
/// identity, so the fixtures are verbatim 27.0 output.
final class HostDiscoveryTests: XCTestCase {

    // MARK: - TXT payload

    func testTXTRoundTrip() {
        let entries = TBPeerTXT.entries(interfaceAddresses: [
            "en4": "169.254.41.7",
            "en3": "169.254.235.83",
        ])
        XCTAssertEqual(entries.map { $0.0 }, ["tbv", "en3", "en4"], "must be sorted for a stable record")
        let decoded = TBPeerTXT.decode(TBPeerTXT.encode(entries))
        XCTAssertEqual(decoded["tbv"], "1")
        XCTAssertEqual(decoded["en3"], "169.254.235.83")
        XCTAssertEqual(decoded["en4"], "169.254.41.7")
    }

    func testTXTEncodingIsLengthPrefixed() {
        let data = TBPeerTXT.encode([("tbv", "1")])
        XCTAssertEqual([UInt8](data), [UInt8(5)] + Array("tbv=1".utf8))
    }

    func testTXTDecodingToleratesTruncation() {
        // A length byte promising more bytes than exist must not crash or run on.
        var data = Data([0xFF])
        data.append(contentsOf: Array("short".utf8))
        XCTAssertTrue(TBPeerTXT.decode(data).isEmpty)
    }

    func testPeerInterfaceAddressesFiltersNonIPs() {
        let txt: [String: String] = [
            "tbv": "1", "en3": "169.254.235.83", "en4": "169.254.41.7",
            "en5": "", "bogus": "not-an-ip", "mac": "36:0a:fa:6e:db:04",
        ]
        XCTAssertEqual(
            TBPeerTXT.peerInterfaceAddresses( txt),
            ["en3": "169.254.235.83", "en4": "169.254.41.7"]
        )
    }

    func testParseZoneOutput_realTBTransferSampleFrom27() {
        // Verbatim from the Studio after the advertiser shipped: the SRV target is
        // a per-launch UUID minted by NetService, which is why peer identity must
        // come from the record NAME, not the target.
        let sample = """
        Ray\\222s\\032Mac\\032Studio._tbtransfer._tcp  SRV  0 0 41617 5084d6ee-c4ca-4f88-baa3-d5b86c271fbd.local. ; Replace with unicast FQDN of target host
        Ray\\222s\\032Mac\\032Studio._tbtransfer._tcp  TXT  "tbv=1" "en3=169.254.235.83" "en4=169.254.130.196" "en5=169.254.218.90"
        """
        let rows = TBHostPeerBrowser.parseZoneOutput(sample, type: "_tbtransfer._tcp")
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].targetHost.contains("5084d6ee"), "SRV target captured as published")
        XCTAssertEqual(
            TBPeerTXT.peerInterfaceAddresses(rows[0].txt),
            ["en3": "169.254.235.83", "en4": "169.254.130.196", "en5": "169.254.218.90"]
        )
    }

    func testLocalHostNameInstanceStripsLocalSuffix() {
        // Identity advertised and recognised must be derived the same way, or every
        // node sees itself as a peer.
        let instance = TBHostPeerBrowser.localHostNameInstance()
        XCTAssertFalse(instance.isEmpty)
        XCTAssertFalse(instance.lowercased().hasSuffix(".local"))
        XCTAssertEqual(
            normalizeHostname(TBHostPeerBrowser.selfHostName()),
            normalizeHostname(TBHostPeerBrowser.localHostName(fromInstance: instance))
        )
    }

    // MARK: - dns-sd -Z zone parsing

    func testParseZoneOutput_realTBTransferSample() {
        // Verbatim `dns-sd -Z _tbtransfer._tcp local` from 27.0 (build 26A428).
        let sample = """
        Browsing for _tbtransfer._tcp.local
        ; comment line
        _tbtransfer._tcp                    PTR     mac-studio-2._tbtransfer._tcp
        mac-studio-2._tbtransfer._tcp       SRV     0 0 41613 mac-studio-2.local. ; Replace with unicast FQDN of target host
        mac-studio-2._tbtransfer._tcp       TXT     "tbv=1" "en3=169.254.99.11" "en4=169.254.99.12"
        """
        let rows = TBHostPeerBrowser.parseZoneOutput(sample, type: "_tbtransfer._tcp")
        XCTAssertEqual(rows.count, 1)
        let adv = rows[0]
        XCTAssertEqual(adv.instance, "mac-studio-2")
        XCTAssertEqual(adv.targetHost, "mac-studio-2.local", "trailing dot must be stripped")
        XCTAssertEqual(adv.port, 41613)
        XCTAssertTrue(adv.isFromTBTransfer)
        XCTAssertEqual(
            TBPeerTXT.peerInterfaceAddresses( adv.txt),
            ["en3": "169.254.99.11", "en4": "169.254.99.12"]
        )
    }

    func testParseZoneOutput_foreignServiceHasNoTXT() {
        let sample = """
        15:51:57.248  x
        _ssh._tcp                         PTR     MacBook\\032Pro\\032(2)._ssh._tcp.local.
        MacBook\\032Pro\\032(2)._ssh._tcp  SRV     0 0 22 mbp2.local. ; comment
        """
        let rows = TBHostPeerBrowser.parseZoneOutput(sample, type: "_ssh._tcp")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].targetHost, "mbp2.local")
        XCTAssertFalse(rows[0].isFromTBTransfer, "must fall through to address-record discovery")
    }

    func testParseZoneOutput_skipsIncompleteRecords() {
        let sample = """
        _ssh._tcp       PTR     Orphan._ssh._tcp
        Other._ssh._tcp TXT     "a=1"
        """
        XCTAssertTrue(TBHostPeerBrowser.parseZoneOutput(sample, type: "_ssh._tcp").isEmpty)
    }

    func testParseTXTQuotedEntries() {
        XCTAssertEqual(
            TBHostPeerBrowser.parseTXTQuotedEntries(#""tbv=1" "en3=169.254.235.83" "flag""#),
            ["tbv": "1", "en3": "169.254.235.83", "flag": ""]
        )
        XCTAssertTrue(TBHostPeerBrowser.parseTXTQuotedEntries("no quotes here").isEmpty)
    }

    // MARK: - per-interface address records (the fallback path)

    func testParseAddressOutput_realSample() {
        let sample = """
        Timestamp     A/R  Flags         IF  Hostname                 Address        TTL
        15:41:55.496  Add  40000003       7  mac-studio-2.local.      0.0.0.0        1   No Such Record
        15:41:55.496  Add  40000003       1  mac-studio-2.local.      127.0.0.1      4500
        15:41:55.496  Add  40000003      14  mac-studio-2.local.      169.254.130.196 4500
        15:41:55.496  Add  40000003      18  mac-studio-2.local.      192.168.68.51  4500
        15:41:55.496  Add  40000003      13  mac-studio-2.local.      169.254.235.83 4500
        15:51:39.204  Add  40000003      14  ms2.local.               FE80:0000:0000:0000:10C3:B4E4:F5C8:C002%en4 4500
        """
        let rows = TBHostPeerBrowser.parseAddressOutput(sample)
        let byInterface = Dictionary(uniqueKeysWithValues: rows.map { ($0.interfaceIndex, $0.ip) })
        XCTAssertEqual(byInterface[13], "169.254.235.83")
        XCTAssertEqual(byInterface[14], "169.254.130.196", "the v4 answer wins over the AAAA on the same index")
        XCTAssertNil(byInterface[7], "No Such Record rows must be dropped")
        XCTAssertFalse(rows.contains { $0.ip.contains(":") }, "IPv6 link-locals are not usable by ssh/rsync here")
    }

    func testParseAddressOutput_emptyAndGarbage() {
        XCTAssertTrue(TBHostPeerBrowser.parseAddressOutput("").isEmpty)
        XCTAssertTrue(TBHostPeerBrowser.parseAddressOutput("Lookup failed\n").isEmpty)
    }

    // MARK: - synthetic identity

    func testSyntheticMAC_isStableAndWellFormed() {
        let a = TBHostPeerBrowser.syntheticMAC(forHost: "mbp2.local")
        XCTAssertEqual(a, TBHostPeerBrowser.syntheticMAC(forHost: "MBP2.LOCAL"))
        XCTAssertEqual(a, normalizeMAC("f6:f7:ba:d4:04:1b"),
                       "pins the digest against a known SHA-256 value (f5f7bad4041b…) after the "
                       + "locally-administered-set / unicast-clear masks hit the first octet")
        let first = UInt8(a.prefix(2), radix: 16)!
        XCTAssertEqual(first & 0x02, 0x02, "locally administered")
        XCTAssertEqual(first & 0x01, 0x00, "unicast")
        XCTAssertNotEqual(a, normalizeMAC("02:00:00:00:00:00"),
                          "must not be confused with macOS 27's placeholder MAC")
    }

    func testSyntheticMAC_differsPerHost() {
        XCTAssertNotEqual(
            TBHostPeerBrowser.syntheticMAC(forHost: "mbp2.local"),
            TBHostPeerBrowser.syntheticMAC(forHost: "mac-studio.local")
        )
    }

    // MARK: - SHA-256 (backing the synthetic identity)

    func testSHA256_knownVectors() {
        func hex(_ data: Data) -> String {
            SHA256Digest.of(data).map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            hex(Data("mbp2.local".utf8)),
            "f5f7bad4041b6b42d85d2b5a213bd0b6e7f5006e8b05c7804623fbffe128ddc0"
        )
        // 56-byte boundary: needs a second padding block.
        XCTAssertEqual(
            hex(Data(String(repeating: "a", count: 56).utf8)),
            "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"
        )
    }

    // MARK: - link-local classification + local addresses

    func testIsLinkLocalIPv4() {
        XCTAssertTrue(isLinkLocalIPv4("169.254.48.164"))
        XCTAssertTrue(isLinkLocalIPv4("169.254.0.1"))
        XCTAssertFalse(isLinkLocalIPv4("169.253.4.4"))
        XCTAssertFalse(isLinkLocalIPv4("192.168.68.52"))
        XCTAssertFalse(isLinkLocalIPv4("fe80::1"))
        XCTAssertFalse(isLinkLocalIPv4(""))
    }

    func testParseLocalIPv4Addresses() {
        let sample = """
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

    // MARK: - instance-name fallback

    func testLocalHostName_displayNameWithSpacesAndParens() {
        XCTAssertEqual(
            TBHostPeerBrowser.localHostName(fromInstance: "MacBook Pro (2)"),
            "macbook-pro-2.local"
        )
    }

    func testUnescapeDNSSD() {
        XCTAssertEqual(
            TBHostPeerBrowser.unescapeDNSSD("MacBook\\032Pro\\032(2)"),
            "MacBook Pro (2)"
        )
    }
}
