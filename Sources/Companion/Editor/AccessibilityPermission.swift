import AppKit
@preconcurrency import ApplicationServices

/// Thin wrapper around the AX trust API + deep-link to System Settings.
/// Required before we can query window bounds / cursor line of other apps.
enum AccessibilityPermission {
    /// Current trust status. Updates are event-driven by the system; call
    /// whenever you need a fresh check.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system's permission dialog (and adds Companion to the
    /// Accessibility list so the user can enable it). Returns true if the
    /// app is ALREADY trusted; false if the prompt was shown.
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens the Accessibility pane in System Settings.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
