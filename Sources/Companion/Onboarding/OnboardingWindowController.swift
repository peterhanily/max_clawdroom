import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var onComplete: (() -> Void)?

    func present() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(
            rootView: OnboardingView(store: SettingsStore.shared) { [weak self] in
                self?.close()
            }
        )
        let window = NSWindow(contentViewController: host)
        window.title = "max_clawdroom — Welcome"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.delegate = self
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        onComplete?()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onComplete?()
    }
}
