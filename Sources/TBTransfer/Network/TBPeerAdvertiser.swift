import Foundation
import Network

/// Advertises this Mac to other TBTransfer instances over Bonjour.
///
/// Why advertise at all: on macOS 27 the ARP table is hidden from app processes,
/// and mDNS name→address resolution over a Thunderbolt link is unreliable in
/// practice — a peer would answer the `_ssh._tcp` SRV query across the cable but
/// return `No Such Record` for its own A record on that interface, leaving us
/// with only its LAN address. Publishing our Thunderbolt IPv4s *inside a TXT
/// record* sidesteps both: TXT travels with the service answer, so the address
/// arrives regardless of what the responder decides to publish as an A record.
/// The TXT payload of a TBTransfer advertisement, isolated from the publisher so
/// the codecs are testable (and usable) without MainActor isolation.
enum TBPeerTXT {
    /// `tbv` tags the payload version; each `<enN>=<ipv4>` entry carries one
    /// Thunderbolt port's address as we see it.
    static func entries(interfaceAddresses: [String: String]) -> [(String, String)] {
        var out: [(String, String)] = [("tbv", "1")]
        for (iface, ip) in interfaceAddresses.sorted(by: { $0.key < $1.key }) {
            out.append((iface, ip))
        }
        return out
    }

    /// RFC 6763: one length byte followed by `key=value`, repeated.
    static func encode(_ entries: [(String, String)]) -> Data {
        var data = Data()
        for (key, value) in entries {
            var entry = Array("\(key)=\(value)".utf8)
            if entry.count > 255 { entry = Array(entry.prefix(255)) }
            data.append(UInt8(entry.count))
            data.append(contentsOf: entry)
        }
        return data
    }

    static func decode(_ data: Data) -> [String: String] {
        var out: [String: String] = [:]
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let length = Int(bytes[index])
            index += 1
            guard length > 0, index + length <= bytes.count else { break }
            let entry = String(decoding: bytes[index..<(index + length)], as: UTF8.self)
            index += length
            if let eq = entry.firstIndex(of: "=") {
                out[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
            } else {
                out[entry] = ""
            }
        }
        return out
    }

    /// The Thunderbolt addresses a peer declared, skipping the version tag and
    /// anything that is not a usable IPv4.
    static func peerInterfaceAddresses(_ txt: [String: String]) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: txt.filter { key, value in
                key.hasPrefix("en") && isIPv4Address(value)
            }.map { ($0.key, $0.value) }
        )
    }
}

@MainActor
final class TBPeerAdvertiser: NSObject, NetServiceDelegate {
    static let serviceType = "_tbtransfer._tcp."
    static let serviceDomain = "local."
    /// Port carried in the SRV. No server is bound behind it in v1 — the TXT is
    /// the payload, and the value is only a stable placeholder.
    private static let advertisedPort: Int32 = 41617

    private var service: NetService?
    private var published = false
    /// TXT to push the moment publication lands (it can't be set before then).
    private var pendingTXT: Data?

    /// Publish ourselves, then keep the TXT in step with the live interfaces.
    ///
    /// - Parameter interfaces: `enN → 169.254.x.y` for every *usable* Thunderbolt
    ///   port. Called every refresh, so a replug or a new link updates the
    ///   advertisement in place.
    func publish(interfaceAddresses: [String: String]) {
        let txt = TBPeerTXT.encode(TBPeerTXT.entries(interfaceAddresses: interfaceAddresses))
        if published {
            service?.setTXTRecord(txt)
            return
        }
        pendingTXT = txt
        guard service == nil else { return }
        // Name the service after this machine's `LocalHostName` (`mac-studio`),
        // NOT the display/computer name: dns-sd prints instance names unescaped,
        // so "Ray’s Mac Studio" arrives as three columns and cannot be parsed. An
        // empty name is also unusable — NetService then registers the display name
        // and mints a random UUID as the SRV target, which would make our identity
        // churn on every launch.
        let service = NetService(
            domain: Self.serviceDomain,
            type: Self.serviceType,
            name: TBHostPeerBrowser.localHostNameInstance(),
            port: Self.advertisedPort
        )
        service.delegate = self
        service.includesPeerToPeer = true
        self.service = service
        service.publish()
    }

    // MARK: - NetServiceDelegate

    nonisolated func netServiceDidPublish(_ sender: NetService) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.published = true
            // Set on our own reference: `sender` is not Sendable, so hopping it
            // across the queue would risk a data race under strict concurrency.
            if let txt = self.pendingTXT { self.service?.setTXTRecord(txt) }
        }
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        DispatchQueue.main.async { [weak self] in
            // Retry from scratch on the next refresh rather than staying muted.
            self?.published = false
            self?.service = nil
        }
    }
}
