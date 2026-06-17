import SwiftUI
import AppKit

// Top-level entry point. We use a `main.swift` (instead of `@main` on
// TBTransferApp) so we can intercept the `--generate-icon` build-time CLI
// flag BEFORE SwiftUI/NSApplication start up and try to open a window.

let args = CommandLine.arguments
if let idx = args.firstIndex(of: "--generate-icon"), idx + 1 < args.count {
    let outPath = args[idx + 1]
    var size: CGFloat = 1024
    if let sIdx = args.firstIndex(of: "--icon-size"),
       sIdx + 1 < args.count,
       let parsed = Double(args[sIdx + 1]) {
        size = CGFloat(parsed)
    }
    // ImageRenderer needs to run on the main actor. Since we're at the top
    // level of the executable and haven't started a runloop, drive it
    // synchronously via MainActor.assumeIsolated.
    let ok = MainActor.assumeIsolated {
        IconGenerator.writePNG(to: outPath, size: size)
    }
    exit(ok ? 0 : 1)
}

// Normal launch — hand off to SwiftUI's runtime.
TBTransferApp.main()
