import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` for opt-in launch-at-login.
/// Writes the desired state to the OS and logs failures — it does NOT
/// persist the user's intent (that's `Prefs.launchAtLogin`). Keeping this
/// separate lets the menu-bar toggle stay snappy: flip the pref, then
/// kick this asynchronously.
///
/// Requires macOS 13+; `Package.swift` pins the deployment target at 14
/// so no availability guards are needed.
@MainActor
enum LaunchAtLoginController {

    /// Mirror the current `Prefs.launchAtLogin` flag into the OS's login
    /// items. Called on launch to ensure the OS matches the last user
    /// choice, and whenever the toggle flips.
    static func apply() {
        let service = SMAppService.mainApp
        let desired = Prefs.launchAtLogin
        let current = service.status
        if desired {
            guard current != .enabled else { return }
            do {
                try service.register()
            } catch {
                AppLog.app.error("SMAppService.register failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            guard current == .enabled else { return }
            do {
                try service.unregister()
            } catch {
                AppLog.app.error("SMAppService.unregister failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Read the actual OS state (which can diverge if the user edited
    /// Login Items directly). Used by the menu-bar toggle to show the
    /// real current state rather than the user's last-expressed intent.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
