import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onOpenSoulEditor),
            name: .companionOpenSoulEditor,
            object: nil
        )
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func onOpenSoulEditor() {
        present()
    }

    func present() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: SettingsView(store: SettingsStore.shared))
        let window = NSWindow(contentViewController: host)
        window.title = "max_clawdroom — Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.delegate = self
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
