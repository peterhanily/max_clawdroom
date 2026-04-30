import AppKit

/// Dynamically toggles `ignoresMouseEvents` on each overlay window based on
/// whether the cursor is inside the pet's projected screen rect.
/// - Cursor over pet → window captures clicks (character is interactive)
/// - Cursor over transparent pixels → window passes clicks through to apps beneath
///
/// **macOS 26.x note.** Earlier this used
/// `NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown])`
/// which fired hundreds of times per second during normal cursor
/// motion. Both monitor variants got `@MainActor` annotations in the
/// 26.x SDK, and the executor probe injected at every callback's
/// prologue intermittently corrupts the runtime's actor-check state
/// — the heap-shape shifts that crash other unrelated `@MainActor`
/// closures appear to originate from this hot path. Replaced with a
/// 200 ms polling timer (`Timer.scheduledTimer` on the main run
/// loop). Trade-off: click-passthrough updates 5×/second instead of
/// per-pixel. Practically indistinguishable for "is cursor inside
/// Max's projected rect", since the rect is dozens of pixels wide and
/// the user can't move the cursor faster than 5 transitions/second
/// across that target. No NSEvent monitor, no Combine, no actor probe.
@MainActor
final class MouseTracker {
    private let overlays: [OverlayController]
    private var pollTimer: Timer?

    init(overlays: [OverlayController]) {
        self.overlays = overlays
    }

    func start() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            DispatchQueue.main.async { [weak self] in
                self?.update()
            }
        }
        update()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func update() {
        let mouse = NSEvent.mouseLocation
        for overlay in overlays {
            if overlay.mouseEventsLocked {
                if overlay.window.ignoresMouseEvents {
                    overlay.window.ignoresMouseEvents = false
                }
                continue
            }
            let petRect = overlay.petScreenRect()
            let hot = petRect.insetBy(dx: -12, dy: -12)
            let inside = NSMouseInRect(mouse, hot, false)
            if overlay.window.ignoresMouseEvents != !inside {
                overlay.window.ignoresMouseEvents = !inside
            }
        }
    }
}
