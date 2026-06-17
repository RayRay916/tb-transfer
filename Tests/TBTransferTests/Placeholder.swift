import XCTest
@testable import TBTransfer

final class PlaceholderTests: XCTestCase {
    func testPeerIsOnlineFreshness() {
        let recent = Peer(label: "x", lastKnownHostname: "x", sshUsername: "u", lastSeenAt: Date())
        XCTAssertTrue(recent.isOnline)
        let stale = Peer(label: "x", lastKnownHostname: "x", sshUsername: "u", lastSeenAt: Date().addingTimeInterval(-3600))
        XCTAssertFalse(stale.isOnline)
    }
}
