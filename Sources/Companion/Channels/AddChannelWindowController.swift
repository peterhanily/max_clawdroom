import AppKit
import SwiftUI

/// Hosts `AddChannelView` in a floating window. The Companion is an
/// NSStatusItem app — there's no SwiftUI Scene to attach a sheet to —
/// so each modal flow gets its own NSWindow, matching the pattern in
/// `SettingsWindowController`.
@MainActor
final class AddChannelWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func present() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = AddChannelView { [weak self] in self?.close() }
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Add Channel"
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
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
