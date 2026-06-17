import SwiftUI
import Observation

/// The queue panel: a scrollable list of currently-running transfers on top,
/// and a collapsible history of completed/failed/cancelled transfers below.
///
/// Reads state from `AppState` via the environment. Active rows have a Cancel
/// button; recent rows for failed/cancelled tasks have a Retry button that
/// re-enqueues a new `TransferTask` with the same sources/destination.
struct TransferQueueView: View {
    @Environment(AppState.self) private var app

    @State private var activeExpanded = true
    @State private var recentExpanded = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                activeSection
                recentSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Active section

    private var activeSection: some View {
        DisclosureGroup(isExpanded: $activeExpanded) {
            let tasks = app.transferEngine.activeTasks
            if tasks.isEmpty {
                emptyState(text: "No active transfers", systemImage: "tray")
            } else {
                VStack(spacing: 8) {
                    ForEach(tasks) { task in
                        ActiveTransferRow(task: task)
                    }
                }
                .padding(.top, 4)
            }
        } label: {
            sectionHeader(
                title: "Active",
                count: app.transferEngine.activeTasks.count
            )
        }
    }

    // MARK: - Recent section

    private var recentSection: some View {
        DisclosureGroup(isExpanded: $recentExpanded) {
            let entries = recentEntries
            if entries.isEmpty {
                emptyState(text: "No history yet", systemImage: "clock.arrow.circlepath")
            } else {
                VStack(spacing: 8) {
                    ForEach(entries) { task in
                        RecentTransferRow(task: task)
                    }
                }
                .padding(.top, 4)
            }
        } label: {
            sectionHeader(title: "Recent", count: recentEntries.count)
        }
    }

    private var recentEntries: [TransferTask] {
        app.transferHistory.entries
    }

    // MARK: - Pieces

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.headline)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(Color.secondary.opacity(0.15))
                )
        }
    }

    private func emptyState(text: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.tertiary)
            Text(text)
                .foregroundStyle(.secondary)
                .font(.callout)
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }
}

// MARK: - Active row

private struct ActiveTransferRow: View {
    @Environment(AppState.self) private var app
    let task: TransferTask

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: task.direction == .push ? "arrow.up.right" : "arrow.down.left")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headerLine)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let sub = subtitleLine {
                        Text(sub)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                statusPill
                Button {
                    app.transferEngine.cancel(id: task.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel transfer")
            }
            ProgressView(value: task.progressFraction)
                .progressViewStyle(.linear)
            HStack(spacing: 8) {
                Text(progressLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(throughputAndETA)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator)
        )
    }

    private var peerLabel: String {
        app.peerStore.peer(id: task.peerID)?.displayName ?? "Unknown peer"
    }

    private var destinationFilename: String {
        // For multi-source transfers, show first source's filename to identify
        // the payload; otherwise show the destination directory's tail.
        if let first = task.sources.first {
            let trimmed = first.hasSuffix("/") ? String(first.dropLast()) : first
            return (trimmed as NSString).lastPathComponent
        }
        let trimmed = task.destination.hasSuffix("/") ? String(task.destination.dropLast()) : task.destination
        return (trimmed as NSString).lastPathComponent
    }

    private var headerLine: String {
        "\(peerLabel) · \(destinationFilename)"
    }

    private var subtitleLine: String? {
        guard task.sources.count > 1 else { return nil }
        return "+\(task.sources.count - 1) more"
    }

    private var statusPill: some View {
        Text(task.status.rawValue.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(statusColor.opacity(0.15))
            )
            .foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        switch task.status {
        case .queued:    return .secondary
        case .running:   return .blue
        case .paused:    return .orange
        case .completed: return .green
        case .failed:    return .red
        case .cancelled: return .secondary
        }
    }

    private var progressLabel: String {
        let done = formatBytes(task.bytesTransferred)
        if task.totalBytes > 0 {
            let total = formatBytes(task.displayTotalBytes)
            let pct = Int((task.progressFraction * 100).rounded())
            return "\(done) / \(total) · \(pct)%"
        }
        return done
    }

    private var throughputAndETA: String {
        let bps = formatBytesPerSecond(task.throughputBytesPerSecond)
        let remaining = max(task.totalBytes - task.bytesTransferred, 0)
        if let eta = formatETA(remainingBytes: remaining,
                               throughput: task.throughputBytesPerSecond) {
            return "\(bps) · \(eta)"
        }
        return bps
    }
}

// MARK: - Recent row

private struct RecentTransferRow: View {
    @Environment(AppState.self) private var app
    let task: TransferTask

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            let icon = statusIcon(task.status)
            Image(systemName: icon.name)
                .foregroundStyle(icon.color)
                .font(.title3)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: task.direction == .push ? "arrow.up.right" : "arrow.down.left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(headerLine)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(subtitleLine)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let err = task.error, !err.isEmpty {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if canRetry {
                Button {
                    retry()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("Re-enqueue this transfer")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator)
        )
    }

    private var peerLabel: String {
        app.peerStore.peer(id: task.peerID)?.displayName ?? "Unknown peer"
    }

    private var destinationFilename: String {
        if let first = task.sources.first {
            let trimmed = first.hasSuffix("/") ? String(first.dropLast()) : first
            return (trimmed as NSString).lastPathComponent
        }
        let trimmed = task.destination.hasSuffix("/") ? String(task.destination.dropLast()) : task.destination
        return (trimmed as NSString).lastPathComponent
    }

    private var headerLine: String {
        var base = "\(peerLabel) · \(destinationFilename)"
        if task.sources.count > 1 {
            base += " (+\(task.sources.count - 1))"
        }
        return base
    }

    private var subtitleLine: String {
        let duration = formatDuration(task.elapsedSeconds)
        let avg = formatBytesPerSecond(task.throughputBytesPerSecond)
        let directionLabel = task.direction == .push ? "push" : "pull"
        return "\(directionLabel) · \(duration) · avg \(avg)"
    }

    private var canRetry: Bool {
        task.status == .failed || task.status == .cancelled
    }

    private func retry() {
        // Only meaningful if we still know about the peer.
        guard let peer = app.peerStore.peer(id: task.peerID) else { return }
        let fresh = TransferTask(
            peerID: task.peerID,
            direction: task.direction,
            sources: task.sources,
            destination: task.destination
        )
        app.transferEngine.enqueue(fresh, peer: peer)
    }
}

// MARK: - Formatting helpers

/// Returns "12.3 MB/s", "1.4 GB/s", "—" for nil. Uses 1024-based units.
fileprivate func formatBytesPerSecond(_ bps: Double?) -> String {
    guard let bps, bps > 0, bps.isFinite else { return "—" }
    let units: [(label: String, divisor: Double)] = [
        ("GB/s", 1024 * 1024 * 1024),
        ("MB/s", 1024 * 1024),
        ("KB/s", 1024),
    ]
    for unit in units where bps >= unit.divisor {
        let value = bps / unit.divisor
        return String(format: "%.1f %@", value, unit.label)
    }
    return String(format: "%.0f B/s", bps)
}

/// Returns "12s", "1m 30s", "2h 5m", or "—" for nil/<=0. No leading zeros.
fileprivate func formatDuration(_ seconds: TimeInterval?) -> String {
    guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
    let total = Int(seconds.rounded())
    if total < 60 {
        return "\(total)s"
    }
    if total < 3600 {
        let m = total / 60
        let s = total % 60
        return s > 0 ? "\(m)m \(s)s" : "\(m)m"
    }
    let h = total / 3600
    let m = (total % 3600) / 60
    return m > 0 ? "\(h)h \(m)m" : "\(h)h"
}

/// "12s left", "1m 30s left", etc. Returns nil if throughput is unknown or
/// nothing is left.
fileprivate func formatETA(remainingBytes: Int64, throughput: Double?) -> String? {
    guard remainingBytes > 0, let throughput, throughput > 0, throughput.isFinite else {
        return nil
    }
    let remainingSec = Double(remainingBytes) / throughput
    guard remainingSec.isFinite, remainingSec > 0 else { return nil }
    return "\(formatDuration(remainingSec)) left"
}

/// SF Symbol + tint for a terminal-state row.
fileprivate func statusIcon(_ status: TransferTask.Status) -> (name: String, color: Color) {
    switch status {
    case .completed: return ("checkmark.circle.fill", .green)
    case .failed:    return ("xmark.octagon.fill", .red)
    case .cancelled: return ("minus.circle.fill", .secondary)
    case .running:   return ("circle.dotted", .blue)
    case .queued:    return ("circle", .secondary)
    case .paused:    return ("pause.circle.fill", .orange)
    }
}

/// 1024-based byte formatter, e.g. "412.5 MB", "1.2 GB".
fileprivate func formatBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 B" }
    let b = Double(bytes)
    let units: [(label: String, divisor: Double)] = [
        ("GB", 1024 * 1024 * 1024),
        ("MB", 1024 * 1024),
        ("KB", 1024),
    ]
    for unit in units where b >= unit.divisor {
        let value = b / unit.divisor
        return String(format: "%.1f %@", value, unit.label)
    }
    return "\(bytes) B"
}

// MARK: - Previews

#Preview("Populated") {
    TransferQueueView()
        .environment(makePreviewAppState(populated: true))
        .frame(width: 520, height: 620)
}

#Preview("Empty") {
    TransferQueueView()
        .environment(makePreviewAppState(populated: false))
        .frame(width: 520, height: 620)
}

@MainActor
private func makePreviewAppState(populated: Bool) -> AppState {
    let state = AppState()

    // Two sample peers so rows have realistic labels.
    let studio = Peer(
        label: "studio",
        lastKnownHostname: "studio.local",
        sshUsername: "",
        sshKeyPath: nil
    )
    let laptop = Peer(
        label: "laptop",
        lastKnownHostname: "laptop.local",
        sshUsername: "",
        sshKeyPath: nil
    )

    state.peerStore.upsert(studio)
    state.peerStore.upsert(laptop)

    guard populated else { return state }

    // Active transfers — one running, one queued.
    let started = Date().addingTimeInterval(-37)
    let running = TransferTask(
        id: UUID(),
        createdAt: started,
        peerID: studio.id,
        direction: .push,
        sources: ["~/big-dataset"],
        destination: "~/Downloads",
        status: .running,
        bytesTransferred: 4_500_000_000,
        totalBytes: 12_000_000_000,
        startedAt: started
    )
    let queued = TransferTask(
        peerID: laptop.id,
        direction: .pull,
        sources: ["~/backups/2026-05-11"],
        destination: "~/PulledBackups",
        status: .queued
    )
    // The engine's setters are private; mutate via the only public seam.
    state.transferEngine.enqueue(running, peer: studio)
    state.transferEngine.enqueue(queued, peer: laptop)

    return state
}
