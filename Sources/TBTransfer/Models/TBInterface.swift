import Foundation

/// A Thunderbolt Bridge interface on this Mac.
struct TBInterface: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String           // "en3"
    let hardwareName: String   // "Thunderbolt 2" (from networksetup)
    let macAddress: String     // local MAC, lowercased "36:0a:fa:6e:db:04"
    let localIP: String?       // our 169.254.x.y on this interface, nil if inactive
    let status: Status
    let broadcastIP: String?   // IPv4 broadcast for this subnet, for ARP warming

    init(
        name: String,
        hardwareName: String,
        macAddress: String,
        localIP: String?,
        status: Status,
        broadcastIP: String? = nil
    ) {
        self.name = name
        self.hardwareName = hardwareName
        self.macAddress = macAddress
        self.localIP = localIP
        self.status = status
        self.broadcastIP = broadcastIP
    }

    enum Status: String, Sendable {
        case active, inactive, unknown
    }

    /// Active with ANY routable IPv4 — broadened from link-local-only so a TB
    /// link with a manually-assigned static IP is still usable for discovery.
    var isUsable: Bool { status == .active && (localIP.map(isIPv4Address) ?? false) }
}

/// True for a dotted-quad IPv4 string ("169.254.5.6", "10.0.0.2"). Cheap, no
/// allocation of NSRegularExpression — used on the discovery hot path.
func isIPv4Address(_ s: String) -> Bool {
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return false }
    return parts.allSatisfy { octet in
        guard !octet.isEmpty, octet.count <= 3, let v = Int(octet) else { return false }
        return v >= 0 && v <= 255
    }
}

/// A peer found on a TB interface via ARP scan. Ephemeral — IPs change session-to-session.
struct DiscoveredPeer: Hashable, Sendable, Identifiable {
    var id: String { "\(interfaceName):\(macAddress)" }
    let interfaceName: String  // "en3"
    let ipAddress: String      // "169.254.202.29"
    let macAddress: String     // remote MAC, lowercased
    let hostname: String?      // resolved via reverse DNS, e.g. "mbp2.local"
}
