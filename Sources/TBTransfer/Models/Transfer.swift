import Foundation

/// A transfer job. Source can be multiple files; destination is a directory.
struct TransferTask: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let peerID: UUID
    let direction: Direction
    let sources: [String]      // absolute paths (local if .push, remote if .pull)
    let destination: String    // absolute path (remote if .push, local if .pull)
    var status: Status
    var bytesTransferred: Int64
    var totalBytes: Int64
    var startedAt: Date?
    var completedAt: Date?
    var error: String?

    enum Direction: String, Codable, Sendable { case push, pull }

    enum Status: String, Codable, Sendable {
        case queued, running, paused, completed, failed, cancelled
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        peerID: UUID,
        direction: Direction,
        sources: [String],
        destination: String,
        status: Status = .queued,
        bytesTransferred: Int64 = 0,
        totalBytes: Int64 = 0,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.peerID = peerID
        self.direction = direction
        self.sources = sources
        self.destination = destination
        self.status = status
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.error = error
    }

    /// Progress as a fraction in [0, 1]. The total is only an ESTIMATE
    /// (`du -sk`, which differs from the bytes rsync actually writes — block
    /// allocation, APFS compression on the source, etc.), so the live byte
    /// count can legitimately exceed it. Clamp so the bar never overflows and
    /// the percentage never shows >100%.
    var progressFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(bytesTransferred) / Double(totalBytes)))
    }

    /// Total to DISPLAY: never less than what's already transferred, so the
    /// "X / Y" readout stays consistent with a capped 100% (avoids the
    /// "43.67 GB / 37.72 GB · 116%" overshoot when the estimate ran low).
    var displayTotalBytes: Int64 {
        totalBytes > 0 ? max(totalBytes, bytesTransferred) : 0
    }

    var elapsedSeconds: TimeInterval? {
        guard let started = startedAt else { return nil }
        let end = completedAt ?? Date()
        return end.timeIntervalSince(started)
    }

    var throughputBytesPerSecond: Double? {
        guard let elapsed = elapsedSeconds, elapsed > 0 else { return nil }
        return Double(bytesTransferred) / elapsed
    }
}
