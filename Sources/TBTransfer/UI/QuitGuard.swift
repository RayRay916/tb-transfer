import AppKit
import SwiftUI

/// Quit-with-active-transfer confirmation.
///
/// On macOS the only synchronous lifecycle hook for "user is about to quit"
/// is `NSApplicationDelegate.applicationShouldTerminate(_:)`. SwiftUI surfaces
/// that hook via `@NSApplicationDelegateAdaptor`. This class is that delegate.
///
/// The class doesn't know about `AppState` directly — instead it exposes a
/// `shouldAllowQuit` closure that the integration code sets at startup. The
/// closure is invoked synchronously on the main actor when the user attempts
/// to quit (Cmd-Q, dock menu, force-quit menu, or `NSApp.terminate(_:)`).
/// If it returns `true`, termination proceeds; if it returns `false`,
/// termination is cancelled.
///
/// ## Wiring (handled by the orchestrator in TBTransferApp)
///
/// Add these two lines to `TBTransferApp`:
///
///   ```
///   @NSApplicationDelegateAdaptor(QuitGuard.self) private var quitGuard
///   ```
///
/// then, after `appState` is available (e.g. in a `.task` or `.onAppear` on
/// the root view), install the predicate:
///
///   ```
///   quitGuard.shouldAllowQuit = { [appState] in
///       QuitGuard.confirmIfTransfersActive(in: appState)
///   }
///   ```
///
/// `confirmIfTransfersActive` checks `appState.transferEngine.activeTasks`
/// for anything in `.running`; if there is, it shows a synchronous `NSAlert`
/// asking the user to confirm the quit, and returns whichever button they
/// chose.
@MainActor
final class QuitGuard: NSObject, NSApplicationDelegate {
    /// Returns `true` to allow termination, `false` to cancel it.
    /// Default permits quit so the app behaves normally before wiring.
    var shouldAllowQuit: () -> Bool = { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shouldAllowQuit() {
            return .terminateNow
        }
        return .terminateCancel
    }

    /// Convenience predicate suitable for assigning to `shouldAllowQuit`.
    ///
    /// Returns `true` immediately when no transfer is currently `.running`.
    /// When at least one transfer is running, shows a synchronous modal alert
    /// and returns `true` only if the user clicks "Quit".
    static func confirmIfTransfersActive(in appState: AppState) -> Bool {
        let activeRunning = appState.transferEngine.activeTasks.contains { $0.status == .running }
        guard activeRunning else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Active transfers in progress"
        alert.informativeText = "TBTransfer is still copying files. Quit anyway?"

        // First button receives the default keyEquivalent ("\r"). Cancel is the
        // safer default, so it goes first; Quit is the deliberate second click
        // (Escape also cancels). The button identity below uses
        // `.alertFirstButtonReturn` / `.alertSecondButtonReturn` accordingly.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        // Cancel is button 1 (return); Quit is button 2. Permit termination
        // only when the user explicitly clicked Quit.
        return response == .alertSecondButtonReturn
    }
}
