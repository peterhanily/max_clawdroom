import AppKit
import Combine
import CoreGraphics
import Foundation

/// Polls the signals Max already scrapes (editor frontmost, long edit,
/// idle seconds, app backgrounded) every 60 s and publishes a derived
/// `WorkState`. One observer wires the effects; another wires the menu
/// bar indicator; both subscribe to the same `@Published` value.
///
/// The tracker is **purely derivative** — it doesn't touch the LLM, the
/// pet, or any other subsystem. The consumers do. Keeps the heuristic
/// contained so tuning "when is this deep focus?" is one file.
///
/// Runs on the primary overlay only. Running per-screen would fire N
/// times per minute and the signals are app-wide anyway.
@MainActor
final class WorkStateTracker: ObservableObject {
    /// Weak pointer to the primary tracker so the menu bar + future UI
    /// can read current state without threading a reference through.
    static weak var shared: WorkStateTracker?

    @Published private(set) var state: WorkState = .active

    private weak var editorAwareness: EditorAwareness?
    private var timer: Timer?

    /// How long a single file has to stay focused (without intervening
    /// chat activity) before we call it deep focus. 25 min matches the
    /// pomodoro threshold — about the point where someone reads as "in
    /// it" rather than "still warming up".
    private let deepFocusFileMinutes: Int = 25
    /// After this many seconds of system idle, the user is away enough
    /// that we should drop to ambient.
    private let ambientIdleSeconds: Int = 20 * 60
    /// Apps that, when frontmost, justify ambient by themselves — the
    /// user's attention is clearly off coding.
    private static let breakApps: Set<String> = [
        "Safari", "Google Chrome", "Firefox", "Arc",
        "Slack", "Messages", "Mail", "Discord", "Telegram",
        "Twitter", "Mastodon", "Reeder", "Spotify",
        "Music", "Podcasts", "News", "Photos"
    ]

    init(editorAwareness: EditorAwareness?) {
        self.editorAwareness = editorAwareness
        startPolling()
        // Run an immediate tick so a freshly-launched app reflects state
        // without waiting a full minute.
        tick()
    }

    isolated deinit {
        timer?.invalidate()
    }

    // MARK: - Scheduling

    private func startPolling() {
        let t = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Previous compute() candidate we're waiting to confirm. Debounces
    /// transitions OUT of `.active` — a brief flip to Chrome shouldn't
    /// make Max semi-transparent; a real work-change only applies if
    /// two consecutive ticks agree. Returning to `.active` still takes
    /// effect immediately so coming back feels instant.
    private var pendingTransition: WorkState?

    private func tick() {
        let computed = compute()
        if computed == state {
            pendingTransition = nil
            return
        }
        if computed == .active {
            // Coming back to engaged state — take effect immediately so
            // Max snaps back to full presence when the user returns.
            pendingTransition = nil
            state = computed
            AppLog.autonomy.notice("work state → \(computed.rawValue, privacy: .public)")
            return
        }
        // Going away from active: require a second consecutive tick of
        // the same non-active state before applying. Stops a 60-second
        // browser glance from flipping Max mid-session.
        if pendingTransition == computed {
            pendingTransition = nil
            state = computed
            AppLog.autonomy.notice("work state → \(computed.rawValue, privacy: .public)")
        } else {
            pendingTransition = computed
        }
    }

    // MARK: - Heuristics

    private func compute() -> WorkState {
        let idle = currentIdleSeconds()
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""

        // Ambient — only strong "user actually stepped away" signals:
        // long idle OR the Mac backgrounded our app entirely (hidden,
        // rare for a menu-bar-only app). Previously we also flipped to
        // ambient on "frontmost is a break app" which was way too
        // aggressive — glancing at Chrome to look up docs silently
        // dimmed Max to half-transparent. Reflex layer already reacts
        // to break-app switches with a micro-expression; ambient is
        // now reserved for genuine absence.
        if idle >= ambientIdleSeconds { return .ambient }
        if NSApp.isHidden { return .ambient }

        // Deep focus: same file edited 25+ min and user isn't currently
        // in a break app (Chrome/Slack/etc.) — that combination is the
        // signal for "heads-down coding".
        if let minutes = currentEditMinutes(),
           minutes >= deepFocusFileMinutes,
           !Self.breakApps.contains(frontmost) {
            return .deepFocus
        }
        return .active
    }

    private func currentIdleSeconds() -> Int {
        guard let anyType = CGEventType(rawValue: ~0) else { return 0 }
        let secs = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyType)
        guard secs.isFinite, secs >= 0 else { return 0 }
        return Int(secs)
    }

    /// We don't have a direct public getter on `AutonomyController` for
    /// the current-file edit duration, so derive from the same signals
    /// it reads: editor-awareness context's document path + a cached
    /// start time. Kept internal to this tracker since the data shape
    /// is specific to this heuristic.
    private var currentFilePath: String?
    private var currentFileStart: Date?

    private func currentEditMinutes() -> Int? {
        // Read straight from EditorAwareness — the same source the env
        // block uses — so we're not coupled to AutonomyController's
        // private edit-session state.
        let path = editorAwareness?.context?.documentPath
        guard let path, !path.isEmpty else {
            currentFilePath = nil
            currentFileStart = nil
            return nil
        }
        if currentFilePath != path {
            currentFilePath = path
            currentFileStart = Date()
            return 0
        }
        guard let start = currentFileStart else { return 0 }
        return Int(Date().timeIntervalSince(start) / 60)
    }
}
