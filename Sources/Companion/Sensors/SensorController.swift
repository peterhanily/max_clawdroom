import AppKit
import Foundation

/// Monitors Mac hardware events and posts notifications the rest of the app
/// can react to:
///
///   - `.companionLidClosing`  — screens going dark (lid close / display sleep)
///   - `.companionLidOpening`  — screens waking (lid open / wake from sleep)
///   - `.companionTapDetected` — window dragged sharply (proxy for physical tap)
///
/// Note: `CMMotionManager` accelerometer APIs are not available on macOS.
/// Tap detection uses drag-velocity as a proxy — when the user yanks Max
/// across the screen quickly, it registers as a "tap."
@MainActor
final class SensorController {
    static let shared = SensorController()

    /// Pixels-per-second threshold above which a drag is considered a "fling".
    private let flingThreshold: CGFloat = 1200
    private var lastDragPos: NSPoint?
    private var lastDragTime: Date = .distantPast
    private var lastTapAt: Date = .distantPast
    private let tapDebounce: TimeInterval = 0.6

    private init() {}

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(screensDidSleep),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensDidWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    // MARK: - Lid / sleep

    @objc private func screensDidSleep() {
        NotificationCenter.default.post(name: .companionLidClosing, object: nil)
    }

    @objc private func screensDidWake() {
        NotificationCenter.default.post(name: .companionLidOpening, object: nil)
    }

    // MARK: - Fling / tap proxy

    /// Call from the drag handler with the current cursor position.
    /// When the velocity exceeds `flingThreshold`, fires `.companionTapDetected`.
    func reportDragPosition(_ pos: NSPoint) {
        let now = Date()
        defer {
            lastDragPos = pos
            lastDragTime = now
        }
        guard let prev = lastDragPos else { return }
        let dt = now.timeIntervalSince(lastDragTime)
        guard dt > 0, dt < 0.1 else { return }

        let dx = pos.x - prev.x
        let dy = pos.y - prev.y
        let velocity = (dx * dx + dy * dy).squareRoot() / CGFloat(dt)

        guard velocity > flingThreshold else { return }
        guard now.timeIntervalSince(lastTapAt) > tapDebounce else { return }
        lastTapAt = now

        NotificationCenter.default.post(name: .companionTapDetected, object: nil)
    }
}

// MARK: - Notification names
extension Notification.Name {
    static let companionLidClosing  = Notification.Name("companion.sensor.lid_closing")
    static let companionLidOpening  = Notification.Name("companion.sensor.lid_opening")
    static let companionTapDetected = Notification.Name("companion.sensor.tap")
}
