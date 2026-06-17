import SwiftUI

/// Modal "About TBTransfer" sheet.
///
/// Renders the app icon, name, version (from Info.plist), a brief description,
/// and the underlying tech stack. The caller owns the presentation state via
/// the `isPresented` binding; the view's only interactive control is a
/// trailing "Close" button that flips the binding to `false`.
///
/// Designed to be presented as `.sheet(isPresented:)` from any view that
/// wants an about dialog. Fixed frame so the layout stays stable regardless
/// of the host window size.
struct AboutView: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 64))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            Text("TBTransfer")
                .font(.largeTitle.bold())

            Text("Version \(Self.versionString)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Text("Peer-to-peer Thunderbolt file transfer")
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(
                "Discovers Macs connected via Thunderbolt cable and transfers files "
                + "between them at up to ~2 GB/s using 16-stream parallel rsync."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24)

            Spacer(minLength: 0)

            Text("Built with SwiftUI \u{00B7} Swift 6 \u{00B7} macOS 14+")
                .font(.caption)
                .foregroundStyle(.tertiary)

            HStack {
                Spacer()
                Button("Close") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.regular)
            }
        }
        .padding(20)
        .frame(width: 420, height: 360)
    }

    /// Reads `CFBundleShortVersionString` from `Info.plist` with a sensible
    /// fallback so previews and unbundled test runs don't show a blank label.
    private static var versionString: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.0.0"
    }
}

// MARK: - Preview

#Preview("About") {
    AboutViewPreviewHost()
}

/// Local preview host: stores the `isPresented` binding so the sheet's Close
/// button has somewhere to write. The preview shows the dialog inline rather
/// than as a sheet so we can iterate on the layout without re-presenting.
private struct AboutViewPreviewHost: View {
    @State private var presented: Bool = true

    var body: some View {
        AboutView(isPresented: $presented)
    }
}
