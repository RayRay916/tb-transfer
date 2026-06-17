import SwiftUI

/// Modal sheet that walks the user through SSH key bootstrap for a single peer.
/// Caller binds `isPresented` and supplies an `onSuccess(username:keyPath:)`
/// callback. The sheet itself does NOT persist anything — the caller is
/// responsible for calling `PeerStore.upsert(...)` with the returned creds.
///
/// Security notes:
///   - The password is held in `@State` ONLY. Cleared on dismiss in both the
///     cancel path and the success path.
///   - We never print/log the password — not in `print`, not in error strings.
struct PairPeerSheet: View {

    // MARK: - Public API

    @Binding var isPresented: Bool
    let peer: Peer
    var onSuccess: (_ username: String, _ keyPath: String, _ remoteHome: String?) -> Void

    // MARK: - Form state

    @State private var username: String = ""
    @State private var password: String = ""

    // MARK: - Bootstrap state

    @State private var currentStep: SSHBootstrap.Step = .idle
    @State private var failureMessage: String? = nil
    @State private var isRunning: Bool = false
    @State private var pairTask: Task<Void, Never>? = nil
    @State private var didSucceed: Bool = false

    @FocusState private var passwordFieldFocused: Bool

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            form
            if isRunning || didSucceed || failureMessage != nil {
                Divider()
                progressList
                if let msg = failureMessage {
                    errorBanner(msg)
                }
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(22)
        .frame(width: 480)
        .onAppear {
            if username.isEmpty {
                username = peer.sshUsername
            }
            // Defer focus to next runloop so the field exists.
            DispatchQueue.main.async {
                passwordFieldFocused = true
            }
        }
        .onDisappear {
            // Clear sensitive state — belt and suspenders. SwiftUI may keep
            // the view around briefly; explicit zeroing makes it visible.
            password = ""
            pairTask?.cancel()
            pairTask = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.shield.fill")
                .font(.system(size: 36, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pair with \(peer.displayName)")
                    .font(.title3.bold())
                // Make the actual SSH target visible so it's unambiguous what
                // the wizard is connecting to (not the label, the real IP/host).
                Text("ssh \(username.isEmpty ? "<user>" : username)@\(sshTargetHost)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("Install an SSH key so this Mac can connect without a password.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    /// The actual host string the bootstrap will SSH to — TB IP if known,
    /// else the .local hostname. Displayed in the header so the user always
    /// knows what they're connecting to (not the friendly label).
    private var sshTargetHost: String {
        if let ip = peer.lastSeenIP, !ip.isEmpty { return ip }
        if !peer.lastKnownHostname.isEmpty { return peer.lastKnownHostname }
        return "<unreachable>"
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Username on \(peer.displayName)").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $username,
                          prompt: Text(peer.sshUsername.isEmpty ? "remote account name" : peer.sshUsername))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .disabled(isRunning)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Login password (peer Mac's macOS password)")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("", text: $password, prompt: Text("•••••••"))
                    .textFieldStyle(.roundedBorder)
                    .focused($passwordFieldFocused)
                    .disabled(isRunning)
                    .onSubmit { startPair() }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("SSH key").font(.caption).foregroundStyle(.secondary)
                Label {
                    Text("A dedicated key is generated for this peer. " +
                         "Forgetting the peer deletes it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    // MARK: - Progress list

    private var progressList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(displayedSteps, id: \.self) { step in
                StepRow(
                    label: label(for: step),
                    status: status(of: step)
                )
            }
        }
    }

    /// The 5 visible steps, in order.
    private var displayedSteps: [SSHBootstrap.Step] {
        [.generatingKey, .connecting, .installing, .verifying, .success]
    }

    private func label(for step: SSHBootstrap.Step) -> String {
        switch step {
        case .generatingKey: return "Generate or reuse SSH key"
        case .connecting:    return "Reach \(peer.lastSeenIP ?? peer.lastKnownHostname):22"
        case .installing:    return "Install pubkey on peer"
        case .verifying:     return "Verify passwordless login"
        case .success:       return "Done"
        case .idle, .failed: return "" // never shown directly
        }
    }

    private func status(of step: SSHBootstrap.Step) -> StepRow.Status {
        // We sort by the order of `displayedSteps` to decide what's done,
        // in progress, or pending.
        let order: [SSHBootstrap.Step] = displayedSteps
        guard let stepIdx = order.firstIndex(of: step) else { return .pending }

        // Map currentStep to an index. .failed and .idle don't appear in `order`.
        if case .failed = currentStep {
            // Find the step that was in progress when it failed. We do that by
            // re-using the last "running" step state, which we kept in
            // failureAtIndex below — but to keep this view stateless, derive
            // from `failureAtStep` set when failure happened.
            if let failedAtIdx = failureAtIndex {
                if stepIdx < failedAtIdx { return .done }
                if stepIdx == failedAtIdx { return .failed }
                return .pending
            }
            return .pending
        }

        // Normal case: derive from currentStep.
        let currentIdx = order.firstIndex(of: currentStep) ?? -1
        if currentStep == .success {
            return stepIdx <= currentIdx ? .done : .pending
        }
        if stepIdx < currentIdx { return .done }
        if stepIdx == currentIdx { return isRunning ? .running : .done }
        return .pending
    }

    // Track which step the failure happened on so we can render the X marker
    // on the correct row.
    @State private var failureAtIndex: Int? = nil

    // MARK: - Error banner

    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.title3)
            Text(msg)
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.red.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(role: .cancel) {
                cancel()
            } label: {
                Text(didSucceed ? "Close" : "Cancel")
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if failureMessage != nil {
                Button {
                    startPair()
                } label: {
                    Text("Retry").frame(minWidth: 80)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
            } else {
                Button {
                    startPair()
                } label: {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 16)
                    } else {
                        Text("Pair").frame(minWidth: 80)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canStart || isRunning || didSucceed)
            }
        }
    }

    // MARK: - Actions

    private var canStart: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty
    }

    private func startPair() {
        guard canStart, !isRunning else { return }
        failureMessage = nil
        failureAtIndex = nil
        currentStep = .idle
        isRunning = true

        let bootstrap = SSHBootstrap()
        let host = peer.lastSeenIP ?? peer.lastKnownHostname
        let user = username.trimmingCharacters(in: .whitespaces)
        let pwd = password
        // Always provision a dedicated, per-peer key under ~/.ssh/tbtransfer/.
        // This makes the peer fully self-contained: Forget Peer can delete
        // exactly this key without touching the user's personal id_ed25519.
        let keyPath = peer.dedicatedKeyPath

        pairTask?.cancel()
        pairTask = Task { @MainActor in
            do {
                let creds = try await bootstrap.pair(
                    host: host,
                    username: user,
                    password: pwd,
                    keyPath: keyPath,
                    hostKeyAlias: peer.hostKeyAlias,
                    progress: { step in
                        // Track failure-at index so the X mark appears on the
                        // step that was in flight.
                        if case .failed = step {
                            // currentStep at this moment is the last running
                            // step. Snapshot its index.
                            let order: [SSHBootstrap.Step] = [.generatingKey, .connecting, .installing, .verifying, .success]
                            failureAtIndex = order.firstIndex(of: currentStep)
                        }
                        currentStep = step
                    }
                )
                isRunning = false
                didSucceed = true
                // Hold the green check briefly so the user can see it.
                try? await Task.sleep(nanoseconds: 500_000_000)
                if !Task.isCancelled {
                    onSuccess(creds.username, creds.keyPath, creds.remoteHome)
                    // Wipe the password before dismissing.
                    password = ""
                    isPresented = false
                }
            } catch let e as SSHBootstrap.BootstrapError {
                isRunning = false
                failureMessage = e.errorDescription ?? "Pairing failed."
                // If the bootstrap didn't already mark failure-at-index via
                // progress (rare, e.g. throw before any progress call), fall
                // back to the first incomplete step.
                if failureAtIndex == nil {
                    let order: [SSHBootstrap.Step] = [.generatingKey, .connecting, .installing, .verifying, .success]
                    failureAtIndex = order.firstIndex(of: currentStep) ?? 0
                }
            } catch is CancellationError {
                isRunning = false
                // Don't show a banner for user-initiated cancellation.
            } catch {
                isRunning = false
                failureMessage = error.localizedDescription
            }
        }
    }

    private func cancel() {
        pairTask?.cancel()
        pairTask = nil
        password = ""
        isPresented = false
    }
}

// MARK: - StepRow

private struct StepRow: View {
    enum Status: Sendable {
        case pending
        case running
        case done
        case failed
    }

    let label: String
    let status: Status

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 18, height: 18)
            Text(label)
                .font(.callout)
                .foregroundStyle(textColor)
            Spacer()
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch status {
        case .pending:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.tertiary)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var textColor: Color {
        switch status {
        case .pending: return .secondary
        case .running, .done: return .primary
        case .failed: return .red
        }
    }
}

// MARK: - Preview

#Preview("Pair Peer Sheet") {
    PairPeerSheet(
        isPresented: .constant(true),
        peer: Peer(
            label: "workshop-mac",
            lastKnownHostname: "workshop-mac.local",
            sshUsername: "",
            sshKeyPath: nil,
            lastSeenIP: "169.254.205.44"
        ),
        onSuccess: { _, _, _ in }
    )
    .frame(width: 480, height: 560)
}
