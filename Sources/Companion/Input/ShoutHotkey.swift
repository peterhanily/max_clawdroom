import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Global "shout at Max" hotkey. Registers ⌘⇧Space application-wide
/// (system-wide would need additional entitlements — app-global is
/// enough for a menu-bar companion the user lives alongside) and on
/// press opens a tiny transient input field at the cursor. Enter sends
/// the text to the primary overlay's session silently (no chat window
/// opens), Escape dismisses, both close the input immediately.
///
/// The point is friction. Typing "max, did we ship X yet" into the
/// chat bubble is three steps; the shout hotkey is one. Messages the
/// user sends this way are marked silent so Max can react in-world
/// (gesture, micro-expression, colour shift) without the chat window
/// popping up — which is exactly what makes it feel like a companion
/// instead of a chat app.
@MainActor
final class ShoutHotkey {
    private let onShout: (String) -> Void
    private var monitor: Any?
    private var panel: ShoutPanel?

    init(onShout: @escaping (String) -> Void) {
        self.onShout = onShout
        register()
    }

    isolated deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Hotkey registration

    /// Global + local keyboard monitor. `LSUIElement` apps like this
    /// one are never truly "frontmost," so a local-only monitor never
    /// fires ⌘⇧Space in practice — that was the "shout hotkey is
    /// broken" bug. Global monitor observes events app-wide and
    /// doesn't require additional entitlements (Accessibility is
    /// helpful so the observer runs while other apps have focus;
    /// absent it, the observer still works when our own menu or
    /// overlay has focus).
    ///
    /// We register BOTH monitors: the global observer catches events
    /// when another app is frontmost; the local monitor lets us
    /// consume the event (return nil) when WE are frontmost so the
    /// Space key doesn't also get typed into our own chat input.
    private func register() {
        // **macOS 26.x runtime bug — hotkey disabled on this OS.**
        // Both addGlobalMonitorForEvents and addLocalMonitorForEvents
        // were annotated `@MainActor` in the 26.x SDK. The closure
        // prologue's executor probe (swift_task_isCurrentExecutorWith-
        // FlagsImpl) trips a SIGBUS / SIGSEGV intermittently when
        // heap layout shifts. VoiceHotkey was the canary; ShoutHotkey
        // hits the same path. ⌘⇧Space (quick reply) goes dark on
        // this OS; users can still type into the chat window directly
        // by clicking Max. Restore both monitors when Apple ships the
        // runtime fix.
        AppLog.app.notice("ShoutHotkey: skipping NSEvent monitor registration — disabled on macOS 26.x. Use the chat window directly until Apple ships the runtime fix.")
    }

    // MARK: - Panel lifecycle

    private func showPanel() {
        if let existing = panel {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let p = ShoutPanel(
            onSubmit: { [weak self] text in
                guard let self else { return }
                self.dismissPanel()
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                self.onShout(trimmed)
            },
            onCancel: { [weak self] in
                self?.dismissPanel()
            }
        )
        panel = p
        p.present(at: NSEvent.mouseLocation)
    }

    private func dismissPanel() {
        panel?.dismiss()
        panel = nil
    }
}

// MARK: - Floating panel

@MainActor
private final class ShoutPanel: NSObject, NSWindowDelegate {
    weak var window: NSWindow?
    private let onSubmit: (String) -> Void
    private let onCancel: () -> Void

    init(onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    func present(at mouse: NSPoint) {
        let size = NSSize(width: 420, height: 48)
        // mouseLocation is screen coordinates (bottom-left origin). Offset
        // slightly so the field opens NEXT to, not under, the cursor.
        let origin = NSPoint(x: mouse.x + 8, y: mouse.y - size.height - 8)
        let frame = NSRect(origin: origin, size: size)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        let host = NSHostingController(
            rootView: ShoutField(
                onSubmit: { [weak self] in self?.onSubmit($0) },
                onCancel: { [weak self] in self?.onCancel() }
            )
        )
        panel.contentViewController = host
        self.window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // Click outside → dismiss.
        onCancel()
    }
}

// MARK: - SwiftUI input

private struct ShoutField: View {
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(CRTPalette.magenta)
            TextField("shout at max", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Color.white)
                .focused($focused)
                .onSubmit { onSubmit(text) }
                .onExitCommand { onCancel() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(CRTPalette.magenta.opacity(0.7), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 8)
        .onAppear { focused = true }
    }
}
