import AppKit
import SwiftUI

/// Generates a thunderbolt app icon at runtime and persists/applies it.
///
/// The icon is a Big-Sur-style squircle: a rounded-rect background filled
/// with a vertical accent→blue gradient, a centered white `bolt.fill` SF
/// symbol on top, and a subtle drop shadow underneath. Rendered at 1024pt
/// (1024 px at scale 1) for the canonical macOS icon size.
enum IconGenerator {

    /// Renders a 1024×1024 thunderbolt icon and assigns it to NSApp's dock icon.
    /// Safe to call repeatedly; cheap (~ms).
    @MainActor
    static func installRuntimeDockIcon() {
        let image = boltImage(size: 1024)
        NSApplication.shared.applicationIconImage = image
    }

    /// Returns a generated NSImage at the requested point size (used both for
    /// the dock icon at runtime and for PNG export at build time).
    @MainActor
    static func boltImage(size: CGFloat) -> NSImage {
        let renderer = ImageRenderer(content: BoltIconView(size: size))
        renderer.scale = 1
        if let img = renderer.nsImage {
            img.size = NSSize(width: size, height: size)
            return img
        }
        // Should never happen, but fall back to a blank image to avoid crashing.
        return NSImage(size: NSSize(width: size, height: size))
    }

    /// Render the icon and write it as a PNG to `path`. Returns true on success.
    /// Used by the `--generate-icon` CLI mode that build.sh drives.
    @MainActor
    static func writePNG(to path: String, size: CGFloat) -> Bool {
        let renderer = ImageRenderer(content: BoltIconView(size: size))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: size, height: size)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

/// Pure SwiftUI view that draws the thunderbolt icon. Sized via `size`
/// (in points) so the same composition renders crisply at any output size.
private struct BoltIconView: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            // Background squircle with a vertical accent/blue gradient.
            RoundedRectangle(cornerRadius: size * (224.0 / 1024.0), style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor,
                            Color.blue.opacity(0.85)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    // Subtle inner highlight along the top edge for depth.
                    RoundedRectangle(cornerRadius: size * (224.0 / 1024.0), style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.35), Color.white.opacity(0.0)],
                                startPoint: .top,
                                endPoint: .center
                            ),
                            lineWidth: size * (4.0 / 1024.0)
                        )
                )

            // Centered thunderbolt glyph. 600pt at 1024 = ~59% of canvas.
            Image(systemName: "bolt.fill")
                .font(.system(size: size * (600.0 / 1024.0), weight: .black))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: size * (24.0 / 1024.0), x: 0, y: size * (8.0 / 1024.0))
        }
        .frame(width: size, height: size)
    }
}
