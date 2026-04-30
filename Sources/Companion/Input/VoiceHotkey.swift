import AppKit
import Carbon.HIToolbox

/// Global hold-to-talk hotkey for voice input. Pressing ⌘⌥Space begins
/// recording; releasing Space ends it and sends the transcript to the
/// primary chat session. Escape while held cancels without sending.
///
/// Uses `NSEvent.addGlobalMonitorForEvents` for system-wide detection —
/// same accessibility permission Max already needs for editor awareness,
/// so we're not asking for anything new. Local monitors run in parallel
/// so the keypress is also consumed when Max is the frontmost app, which
/// keeps Space out of any accidental text-field insertions.
///
/// Why ⌘⌥Space specifically: ⌘Space is Spotlight, ⌘⇧Space is the shout
/// hotkey (typed input), so ⌘⌥Space stays the natural neighbour for
/// "voice input" — same base key, different modifier axis.
///
/// **Concurrency note (2026-04-28):** macOS 26.x has a runtime bug in
/// `swift_task_isCurrentExecutorWithFlagsImpl` that crashes when an
/// NSEvent monitor closure either spawns `Task { @MainActor in ... }`
/// or calls `MainActor.assumeIsolated { ... }` — both paths hit the
/// same broken probe. The class is therefore deliberately NOT
/// @MainActor; all event-handler methods are nonisolated and rely on
/// AppKit's guarantee that monitor closures fire on the main thread.
/// The handler closures supplied by the caller are typed `@Sendable
/// () -> Void` so they can do their own MainActor hop if they need it
/// (none of today's callers do — they're already main-thread state
/// mutations of OverlayController).
final class VoiceHotkey: @unchecked Sendable {
    private let onStart: @Sendable () -> Void
    private let onStop:  @Sendable () -> Void
    private let onCancel: @Sendable () -> Void

    private var keyDownGlobal: Any?
    private var keyUpGlobal: Any?
    private var keyLocal: Any?
    private var isHeld = false

    init(
        onStart: @escaping @Sendable () -> Void,
        onStop: @escaping @Sendable () -> Void,
        onCancel: @escaping @Sendable () -> Void
    ) {
        self.onStart = onStart
        self.onStop = onStop
        self.onCancel = onCancel
        register()
    }

    isolated deinit {
        if let m = keyDownGlobal { NSEvent.removeMonitor(m) }
        if let m = keyUpGlobal   { NSEvent.removeMonitor(m) }
        if let m = keyLocal      { NSEvent.removeMonitor(m) }
    }

    // MARK: - Registration

    private func register() {
        // **macOS 26.x runtime bug — hotkey disabled on this OS.**
        //
        // Apple annotated `addLocalMonitorForEvents` and (we now know)
        // `addGlobalMonitorForEvents` `@MainActor` in the 26.x SDK. The
        // executor-isolation probe Swift injects at every annotated
        // closure's prologue (`swift_task_isCurrentExecutorWithFlags-
        // ImpI`) trips a SIGBUS / SIGSEGV intermittently as heap
        // layout shifts.
        //
        // Diagnostic chain across this work:
        //   1. Crash in local-monitor closure — wrapped Task/assume-
        //      Isolated, didn't help (probe is in the prologue).
        //   2. Took VoiceHotkey out of the actor system, still crashed.
        //   3. Dropped the local monitor; crash moved to NSTimer in
        //      Pet.swift (other @MainActor closures).
        //   4. Now the GLOBAL monitor's closure #1 has tripped too —
        //      same probe, called via GlobalObserverHandler →
        //      _DPSNextEvent.
        //
        // Hotkey users lose ⌘⌥Space (push-to-talk) on macOS 26.x
        // until Apple ships the runtime fix. Voice input is still
        // reachable via the menu bar item and chat-window mic button.
        // Track Apple's fix and restore both monitors when the
        // executor-probe bug is patched.
        AppLog.app.notice("VoiceHotkey: skipping NSEvent monitor registration — disabled on macOS 26.x to avoid the swift_task_isCurrentExecutorWithFlagsImpl crash. Push-to-talk hotkey unavailable until Apple ships the runtime fix.")
    }

    // MARK: - Event handlers — all nonisolated, all main-thread by AppKit guarantee.

    private func handleKeyDown(event: NSEvent) {
        if matchesStart(event), !isHeld {
            isHeld = true
            onStart()
            return
        }
        // Escape cancels a held session.
        if isHeld, event.keyCode == UInt16(kVK_Escape) {
            handleCancel()
        }
    }

    private func handleKeyUp(event: NSEvent) {
        guard isHeld, event.keyCode == UInt16(kVK_Space) else { return }
        isHeld = false
        onStop()
    }

    private func handleCancel() {
        guard isHeld else { return }
        isHeld = false
        onCancel()
    }

    private func matchesStart(_ event: NSEvent) -> Bool {
        guard event.keyCode == UInt16(kVK_Space) else { return false }
        let required: NSEvent.ModifierFlags = [.command, .option]
        return event.modifierFlags.intersection([.command, .option, .shift, .control])
            == required
    }
}
