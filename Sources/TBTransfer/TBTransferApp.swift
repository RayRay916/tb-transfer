import SwiftUI
import AppKit

/// Root SwiftUI App. Gates between an animated splash and the main window
/// on `appState.isReady`.
///
/// NOTE: this is intentionally NOT marked `@main`. We use a top-level
/// `main.swift` instead so we can intercept `--generate-icon` (used by
/// build.sh to render the iconset) before SwiftUI/NSApplication start up.
struct TBTransferApp: App {
    @State private var appState = AppState()
    @State private var showAbout = false
    @NSApplicationDelegateAdaptor(QuitGuard.self) private var quitGuard

    var body: some Scene {
        WindowGroup("TBTransfer") {
            ZStack {
                if appState.isReady {
                    MainWindow()
                        .environment(appState)
                        .frame(minWidth: 900, minHeight: 560)
                        .transition(.opacity)
                } else {
                    SplashView()
                        .environment(appState)
                        .frame(minWidth: 900, minHeight: 560)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: appState.isReady)
            .sheet(isPresented: $showAbout) {
                AboutView(isPresented: $showAbout)
            }
            .task {
                IconGenerator.installRuntimeDockIcon()
                // Confirm quit when transfers are running.
                quitGuard.shouldAllowQuit = { [appState] in
                    QuitGuard.confirmIfTransfersActive(in: appState)
                }
                await appState.start()
            }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About TBTransfer") { showAbout = true }
            }
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .pasteboard) {
                Button("Paste Files Here") { appState.pasteFromClipboard() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }
    }
}
