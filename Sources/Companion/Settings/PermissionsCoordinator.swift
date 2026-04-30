import AppKit
import UserNotifications

/// Single shared surface for the four macOS permissions Max can use.
/// Lets Settings, Onboarding, and the agent's `FeatureSuggester` all
/// ask the same questions ("is microphone granted?", "is accessibility
/// granted?") without each reimplementing the TCC bridge.
///
/// **What this owns:** status checks + request triggers + "what this
/// unlocks" copy. **What it doesn't:** prompting at launch. The whole
/// point of moving to this layer is that nothing fires a system
/// permission dialog *unless the user explicitly asked* — onboarding
/// step or Settings re-ask button. Drive-by prompts in
/// `applicationDidFinishLaunching` are gone.
enum AppPermission: String, CaseIterable {
    case accessibility   // AX (editor awareness, walk-to-editor, hotkeys)
    case notifications   // morning greetings, soul-patch nudges, etc.
    case microphone      // voice input via ⌘⌥Space (lazy — not in this gate)
    case automation      // future: control of other apps via AppleEvents

    var displayName: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .notifications: return "Notifications"
        case .microphone:    return "Microphone"
        case .automation:    return "Automation"
        }
    }

    /// One-line "what this unlocks" copy. Shown next to the permission
    /// in onboarding + Settings. Speaks the user's language: "lets Max
    /// X" — never "the app requires Y."
    var rationale: String {
        switch self {
        case .accessibility:
            return "Lets Max see your focused editor window so he can walk to where you're working, follow your cursor for gaze, and trigger hotkeys. Nothing leaves your machine."
        case .notifications:
            return "Lets Max nudge you with morning greetings, soul-patch reviews, and any reminders he sets. Off by default — Max stays quiet until you opt in."
        case .microphone:
            return "Lets you hold ⌘⌥Space to talk to Max instead of typing. Audio stays on-device."
        case .automation:
            return "Future capability — would let Max control other apps via AppleEvents. Not used today."
        }
    }
}

@MainActor
enum PermissionsCoordinator {

    enum Status {
        case granted
        case denied
        case notDetermined
        /// Permission can't be queried at this time (e.g. notifications
        /// before authorization status fetched, or `automation` which
        /// has no general-purpose status check).
        case unknown
    }

    /// Snapshot the current grant status for `permission`. For permissions
    /// that need an async query (notifications), call `refreshNotificationsStatus()`
    /// first.
    static func status(_ permission: AppPermission) -> Status {
        switch permission {
        case .accessibility:
            return AccessibilityPermission.isTrusted ? .granted : .notDetermined
        case .notifications:
            return cachedNotificationsStatus
        case .microphone:
            return micStatus()
        case .automation:
            return .unknown
        }
    }

    /// Trigger a request for `permission`. **Only** ever call this in
    /// response to an explicit user gesture (toggle in Settings, button
    /// in Onboarding) — never on launch. Returns immediately; the
    /// system handles the dialog asynchronously.
    static func request(_ permission: AppPermission) {
        switch permission {
        case .accessibility:
            _ = AccessibilityPermission.requestTrust()
        case .notifications:
            // Same .app-bundle gate as refreshNotificationsStatus —
            // calling currentNotificationCenter from a raw binary
            // throws an NSException at the dispatch_once layer.
            Prefs.hasOptedIntoNotifications = true
            guard Bundle.main.bundleURL.pathExtension == "app" else { return }
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            ) { granted, _ in
                Task { @MainActor in
                    cachedNotificationsStatus = granted ? .granted : .denied
                }
            }
        case .microphone:
            // AVCaptureDevice.requestAccess fires the system dialog.
            // We only invoke it when the user clicks "grant"; otherwise
            // microphone stays lazy (the AVAudioSession path handles
            // the prompt on first voice-input use).
            // Importing AVFoundation here would expand the surface;
            // a small async helper that wraps it lives in
            // SpeechCapture, which we'll wire up when that flow
            // becomes user-driven instead of automatic.
            break
        case .automation:
            // No proactive request API for Automation/AppleEvents —
            // macOS prompts on first use. Until we ship a feature
            // that actually uses AppleEvents, this is a placeholder.
            break
        }
    }

    /// Open System Settings to the relevant Privacy & Security pane.
    /// Used by "I want to revoke this" / "the dialog said deny but I
    /// changed my mind" flows.
    static func openSystemSettings(_ permission: AppPermission) {
        let url: URL? = {
            switch permission {
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            case .notifications:
                return URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
            case .microphone:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            case .automation:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
            }
        }()
        if let url { NSWorkspace.shared.open(url) }
    }

    /// Notifications status is async — `UNUserNotificationCenter` only
    /// gives it via callback. Cache the latest known value so synchronous
    /// `status(.notifications)` lookups return something usable.
    private(set) static var cachedNotificationsStatus: Status = .unknown

    /// Refresh the notifications cache. Call early in app launch (after
    /// Onboarding fires its own check) so Settings can render the right
    /// state without flicker.
    static func refreshNotificationsStatus() {
        // UNUserNotificationCenter throws when invoked from a binary
        // that isn't inside a real `.app` bundle (no bundle id, TCC
        // can't resolve the caller). Plain `swift run` and the
        // dev `.build/debug/max_clawdroom` path both hit this.
        // Mirror NotificationController's gate.
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            cachedNotificationsStatus = .unknown
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            // settings isn't Sendable. Extract the enum inside the
            // delegate-queue closure (Sendable), then hop to main.
            let resolved: Status = {
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: return .granted
                case .denied:                               return .denied
                case .notDetermined:                        return .notDetermined
                @unknown default:                           return .unknown
                }
            }()
            Task { @MainActor in
                cachedNotificationsStatus = resolved
            }
        }
    }

    private static func micStatus() -> Status {
        // Avoid the AVCaptureDevice import. Read the TCC-style
        // privacy state via the same mechanism Speech Capture uses
        // when it's lazy-prompted; if we never asked, we never know.
        // For the UI's purposes this collapses to: did we ever opt in?
        return Prefs.hasOptedIntoMicrophone ? .granted : .notDetermined
    }
}
