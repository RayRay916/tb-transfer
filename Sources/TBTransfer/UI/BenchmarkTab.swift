import SwiftUI

/// Benchmark tab — validates every node's TB connection, installs the measure
/// dep (pv), then runs a quick unencrypted raw-TCP (`nc`) throughput pass in
/// both directions and shows the result next to each end's MTU (with a control
/// to change it). Surfaces link/MTU faults the encrypted transfer path hides.
struct BenchmarkTab: View {
    @Environment(AppState.self) private var app

    private var onlinePeers: [Peer] {
        app.peerStore.peers.filter { $0.isOnline && ($0.lastSeenIP?.isEmpty == false) }
    }

    var body: some View {
        @Bindable var engine = app.benchmarkEngine
        VStack(spacing: 0) {
            header(engine: engine)
            Divider()
            if onlinePeers.isEmpty {
                ContentUnavailableView(
                    "No online TB peers",
                    systemImage: "speedometer",
                    description: Text("Connect a Mac over Thunderbolt and pair it, then run the benchmark.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(onlinePeers) { peer in
                            BenchmarkNodeCard(peer: peer)
                        }
                    }
                    .padding(14)
                }
            }
            footer
        }
        .onAppear {
            // Read MTUs up front so the values are visible before running.
            for peer in onlinePeers {
                Task { await app.benchmarkEngine.refreshMTU(peer: peer) }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(engine: BenchmarkEngine) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TB Throughput Benchmark").font(.headline)
                Text(engine.statusLine).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            // Mode toggle: Both / iperf3 / nc.
            Picker("Mode", selection: Binding(
                get: { engine.mode },
                set: { engine.mode = $0 }
            )) {
                ForEach(BenchmarkEngine.Mode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .help("Both runs iperf3 + nc. iperf3 saturates the link (reveals MTU faults); nc is raw TCP (~3–5 Gb/s, CPU-bound).")
            .disabled(engine.isRunning)
            // Streams knob.
            HStack(spacing: 4) {
                Text("\(engine.streams)×").font(.caption.monospaced()).foregroundStyle(.secondary)
                Stepper("streams", value: Binding(
                    get: { engine.streams },
                    set: { engine.streams = max(1, min(16, $0)) }
                ), in: 1...16)
                .labelsHidden()
                .help("Parallel streams (8 saturates IP-over-TB)")
            }
            .disabled(engine.isRunning)
            Button {
                let peers = onlinePeers
                Task { await app.benchmarkEngine.runAll(peers: peers) }
            } label: {
                if engine.isRunning {
                    ProgressView().controlSize(.small).padding(.horizontal, 10)
                } else {
                    Label("Run All", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(engine.isRunning || onlinePeers.isEmpty)
        }
        .padding(12)
    }

    // MARK: - Footer

    private var footer: some View {
        Divider().overlay(alignment: .center) { EmptyView() }
            .background(
                VStack(spacing: 2) {
                    Text("Unencrypted raw TCP over the TB link — the same path exo nodes use. Targets each node's link-local TB IP.")
                    Text("Jumbo MTU 65518 is the TB target; an MTU mismatch between ends can halve one direction.")
                }
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                .padding(.vertical, 6).padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(.bar)
            )
            .frame(height: 38)
    }
}

// MARK: - Node card

private struct PWRequest: Identifiable {
    let id = UUID()
    let side: BenchmarkEngine.Side
    let mtu: Int
}

private struct CustomMTURequest: Identifiable {
    let id = UUID()
    let side: BenchmarkEngine.Side
}

private struct BenchmarkNodeCard: View {
    @Environment(AppState.self) private var app
    let peer: Peer
    @State private var mtuMessage: String?
    @State private var mtuMessageIsError = false
    @State private var pwRequest: PWRequest?
    @State private var sudoPassword = ""
    @State private var pwBusy = false
    @State private var customMTU: CustomMTURequest?
    @State private var customMTUText = ""

    private var result: BenchmarkEngine.NodeResult? { app.benchmarkEngine.results[peer.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            Divider()
            throughputRow
            Divider()
            mtuRow
            if let msg = mtuMessage {
                Text(msg).font(.caption)
                    .foregroundStyle(mtuMessageIsError ? .red : .green)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
        .sheet(item: $pwRequest) { req in sudoSheet(req) }
        .sheet(item: $customMTU) { req in customMTUSheet(req) }
    }

    // MARK: custom MTU entry sheet

    private func customMTUSheet(_ req: CustomMTURequest) -> some View {
        let parsed = Int(customMTUText.trimmingCharacters(in: .whitespaces))
        let valid = parsed.map { $0 >= BenchmarkEngine.mtuMin && $0 <= BenchmarkEngine.mtuMax } ?? false
        return VStack(alignment: .leading, spacing: 14) {
            Label("Custom \(req.side == .local ? "local" : "remote") MTU", systemImage: "ruler")
                .font(.headline)
            Text("Enter an MTU for \(peer.displayName) (\(BenchmarkEngine.mtuMin)–\(BenchmarkEngine.mtuMax); 65518 = jumbo).")
                .font(.caption).foregroundStyle(.secondary)
            TextField("MTU", text: $customMTUText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .onSubmit { if valid { submitCustomMTU(req) } }
            if !customMTUText.isEmpty && !valid {
                Text("Must be a number between \(BenchmarkEngine.mtuMin) and \(BenchmarkEngine.mtuMax).")
                    .font(.caption2).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { customMTU = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Set MTU") { submitCustomMTU(req) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func submitCustomMTU(_ req: CustomMTURequest) {
        guard let v = Int(customMTUText.trimmingCharacters(in: .whitespaces)),
              v >= BenchmarkEngine.mtuMin, v <= BenchmarkEngine.mtuMax else { return }
        customMTU = nil
        changeMTU(side: req.side, mtu: v)
    }

    private func presetLabel(_ v: Int) -> String {
        switch v {
        case 1500:  "1500  (standard)"
        case 65518: "65518  (jumbo)"
        default:    "\(v)"
        }
    }

    // MARK: sudo password sheet (remote MTU change)

    private func sudoSheet(_ req: PWRequest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("sudo password for \(peer.displayName)", systemImage: "lock.shield")
                .font(.headline)
            Text("\(peer.displayName) requires a password for `sudo` over SSH (no NOPASSWD rule). "
                 + "Enter \(peer.sshUsername.isEmpty ? "its" : "\(peer.sshUsername)'s") login password to set MTU \(req.mtu). "
                 + "It's piped to `sudo -S` and never stored.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $sudoPassword)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitPassword(req) }
            HStack {
                Spacer()
                Button("Cancel") { sudoPassword = ""; pwRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Set MTU") { submitPassword(req) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(sudoPassword.isEmpty || pwBusy)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func submitPassword(_ req: PWRequest) {
        guard !sudoPassword.isEmpty, !pwBusy else { return }
        pwBusy = true
        let p = peer, pw = sudoPassword
        Task {
            let r = await app.benchmarkEngine.setMTUWithPassword(peer: p, side: req.side, mtu: req.mtu, password: pw)
            sudoPassword = ""
            pwBusy = false
            pwRequest = nil
            applyMTUResult(r, side: req.side, mtu: req.mtu)
        }
    }

    private func applyMTUResult(_ r: BenchmarkEngine.MTUResult, side: BenchmarkEngine.Side, mtu: Int) {
        switch r {
        case .ok:
            mtuMessageIsError = false
            mtuMessage = "Set \(side == .local ? "local" : "remote") MTU to \(mtu)."
        case .failed(let m):
            mtuMessageIsError = true
            mtuMessage = m
        case .needsPassword:
            pwRequest = PWRequest(side: side, mtu: mtu)
        }
    }

    // MARK: Title

    private var titleRow: some View {
        HStack(spacing: 10) {
            SSHHealthDot(isOnline: peer.isOnline, health: app.sshHealth[peer.id])
            VStack(alignment: .leading, spacing: 1) {
                Text(peer.displayName).font(.headline)
                if let iface = peer.lastSeenInterface, let ip = peer.lastSeenIP {
                    Text("\(iface) · \(ip)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let r = result, r.phase != .idle, r.phase != .done, r.phase != .failed {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(r.phase.rawValue).font(.caption).foregroundStyle(.secondary)
                }
            } else if let r = result, r.phase == .failed {
                Label("Failed", systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
            }
            Button {
                let p = peer
                Task { await app.benchmarkEngine.run(peer: p) }
            } label: { Label("Run", systemImage: "play.fill") }
                .disabled(app.benchmarkEngine.isRunning)
        }
    }

    // MARK: Throughput

    private var throughputRow: some View {
        VStack(spacing: 8) {
            ForEach(app.benchmarkEngine.mode.methods) { m in
                HStack(spacing: 0) {
                    Text(m.label)
                        .font(.caption.monospaced().bold())
                        .frame(width: 50, alignment: .leading)
                        .foregroundStyle(.secondary)
                    directionCell(title: "Up", system: "arrow.up.circle.fill",
                                  gbps: result.flatMap { $0.gbps(m, reverse: false) })
                    Divider().frame(height: 40)
                    directionCell(title: "Down", system: "arrow.down.circle.fill",
                                  gbps: result.flatMap { $0.gbps(m, reverse: true) })
                }
            }
        }
    }

    private func directionCell(title: String, system: String, gbps: Double?) -> some View {
        VStack(spacing: 1) {
            Label(title, systemImage: system).font(.caption2).foregroundStyle(.secondary)
            if let g = gbps {
                Text(String(format: "%.1f", g)).font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(color(forGbps: g)) +
                Text(" Gb/s").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("—").font(.system(size: 23, weight: .bold, design: .rounded)).foregroundStyle(.tertiary)
            }
            Text(gbps.map { String(format: "%.2f GB/s", $0 / 8) } ?? " ")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func color(forGbps g: Double) -> Color {
        switch g {
        case 45...:  return .green
        case 20..<45: return .orange
        default:     return .red
        }
    }

    // MARK: MTU

    private var mtuRow: some View {
        HStack(alignment: .top, spacing: 16) {
            mtuCell(label: "Local MTU", iface: peer.lastSeenInterface, mtu: result?.localMTU, side: .local)
            mtuCell(label: "Remote MTU", iface: result?.remoteInterface, mtu: result?.remoteMTU, side: .remote)
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if result?.mtuMismatch == true {
                    Label("MTU mismatch", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .help("The two ends have different MTUs — this can collapse one direction. Set both to 65518.")
                }
                Button {
                    let p = peer
                    Task { await app.benchmarkEngine.refreshMTU(peer: p) }
                } label: { Label("Re-read MTU", systemImage: "arrow.clockwise").font(.caption) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func mtuCell(label: String, iface: String?, mtu: Int?, side: BenchmarkEngine.Side) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(mtu.map(String.init) ?? "—").font(.body.monospaced().bold())
                if let iface { Text(iface).font(.caption2.monospaced()).foregroundStyle(.tertiary) }
            }
            Menu("Change…") {
                ForEach(BenchmarkEngine.mtuPresets, id: \.self) { v in
                    Button(presetLabel(v)) { changeMTU(side: side, mtu: v) }
                }
                Divider()
                Button("Custom…") {
                    customMTUText = (mtu.map(String.init)) ?? ""
                    customMTU = CustomMTURequest(side: side)
                }
            }
            .menuStyle(.borderlessButton)
            .font(.caption)
            .fixedSize()
            .disabled(app.benchmarkEngine.isRunning || (side == .remote && result?.remoteInterface == nil))
        }
    }

    private func changeMTU(side: BenchmarkEngine.Side, mtu: Int) {
        let p = peer
        mtuMessage = nil
        Task {
            let r = await app.benchmarkEngine.setMTU(peer: p, side: side, mtu: mtu)
            applyMTUResult(r, side: side, mtu: mtu)
        }
    }
}
