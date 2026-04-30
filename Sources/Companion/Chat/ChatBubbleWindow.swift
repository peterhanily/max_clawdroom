import AppKit

/// Borderless NSWindow that can accept keyboard focus (default borderless windows cannot).
///
/// **macOS 26.x note.** These overrides must be `nonisolated`. The
/// project's default-@MainActor isolation otherwise generates
/// implicit `_checkExpectedExecutor` calls in their getters, which
/// AppKit invokes from `-[NSWindow _handleMouseDownEvent:]` via @objc
/// dispatch — and the executor probe (`swift_task_isCurrentExecutor-
/// WithFlagsImpl`) trips a SIGSEGV intermittently on this OS. The
/// getters return constants and access no state, so explicit
/// `nonisolated` is correct (and was probably the right annotation
/// regardless — these are pure-Bool readonly properties).
final class ChatBubbleWindow: NSWindow {
    nonisolated override var canBecomeKey: Bool { true }
    nonisolated override var canBecomeMain: Bool { false }
    nonisolated override var acceptsFirstResponder: Bool { true }
}
