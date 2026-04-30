import Foundation
import UserNotifications

/// Thin wrapper around UNUserNotificationCenter. Requests permission once on
/// first use and exposes a fire-and-forget `post` method the rest of the app
/// calls without worrying about auth state.
@MainActor
final class NotificationController: NSObject {
    static let shared = NotificationController()

    private var authorized = false

    /// True only when running inside a proper .app bundle.
    /// UNUserNotificationCenter crashes when called from a plain binary.
    private static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    override private init() {
        super.init()
        guard Self.isBundled else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Call once at app launch. Asks for permission the first time;
    /// subsequent calls are no-ops once the system stores the decision.
    func requestAuthorization() {
        guard Self.isBundled else { return }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                self?.authorized = granted
            }
        }
    }

    /// Post a system notification. No-op if the user denied permission or not bundled.
    func post(title: String, body: String, identifier: String, delay: TimeInterval = 0) {
        guard Self.isBundled, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = delay > 0
            ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            : nil
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AppLog.app.error("failed to post notification '\(identifier, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Remove a pending notification by id (e.g. after the user opens the app).
    func remove(identifier: String) {
        guard Self.isBundled else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [identifier]
        )
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [identifier]
        )
    }
}

extension NotificationController: UNUserNotificationCenterDelegate {
    /// Show notification as a banner even when the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Convenience identifiers
extension NotificationController {
    static let idSoulPatch   = "max.soul_patch"
    static let idMorning     = "max.morning"
    static let idMonthly     = "max.monthly"
    static let idWelcomeBack = "max.welcome_back"
}
