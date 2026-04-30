import AppKit
import Combine
import CoreGraphics
import Foundation

/// Fires periodic silent prompts to the agent so Max can act without
/// being spoken to — change his expression, walk somewhere, re-theme
/// himself, wave at nothing in particular. The prompts go through
/// `ChatSession.send(_:silent: true)` so neither the user-side text nor
/// the assistant's prose show up in the transcript, but action-tag
/// blocks the agent emits still dispatch normally.
///
/// Opt-in via `Prefs.autonomyEnabled`. Paused whenever a real user
/// conversation is active so autonomous pings don't collide with the
/// user's actual prompts.
///
/// Contextual events (app switches, large pastes, long edit sessions)
/// are tracked on a 30-second lightweight timer and included in the
/// next autonomy prompt so Max reacts to what the user is doing.
@MainActor
final class AutonomyController {
    private weak var session: ChatSession?
    private var timer: Timer?
    private var contextCheckTimer: Timer?
    /// Idle seconds observed on the previous tick.
    private var previousIdleSeconds: Int = 0

    // MARK: - Contextual event tracking

    private enum ContextualEventKind {
        case leftWork, returnedToWork, largePaste, longEditSession

        var label: String {
            switch self {
            case .leftWork:          return "took a break"
            case .returnedToWork:    return "back to work"
            case .largePaste:        return "large paste"
            case .longEditSession:   return "long edit session"
            }
        }
    }

    private struct ContextualEvent {
        let kind: ContextualEventKind
        let detail: String
    }

    private var pendingContextualEvents: [ContextualEvent] = []
    private var lastFrontmostApp: String?
    private var lastPasteboardChangeCount: Int = 0
    private var currentEditFile: String?
    private var currentEditFileStarted: Date?
    private var editMilestonesFired: Set<Int> = []

    /// Rolling record of recent clipboard hashes so "same thing pasted
    /// again" can fire a distinct reflex event. Cap keeps the set
    /// bounded — hashes older than 48h are pruned at read time.
    private var recentPasteHashes: [(hash: Int, at: Date)] = []

    // MARK: - Event bus

    /// Contextual events emitted the moment they're detected — distinct
    /// from `pendingContextualEvents` which queues for the next LLM tick.
    /// `ReflexController` subscribes here to fire zero-token reactions
    /// (expression changes, small gestures, tint nudges) without waiting
    /// for the reflective autonomy tick.
    let events = PassthroughSubject<ReflexEvent, Never>()

    // Focus apps: high-concentration work environments
    private static let workApps: Set<String> = [
        "Xcode", "Terminal", "iTerm", "iTerm2", "Nova", "Cursor",
        "Visual Studio Code", "BBEdit", "Emacs", "RubyMine", "IntelliJ IDEA",
        "PyCharm", "WebStorm", "Goland", "CLion"
    ]
    // Break apps: social, browsing, comms
    private static let breakApps: Set<String> = [
        "Safari", "Google Chrome", "Firefox", "Arc",
        "Slack", "Messages", "Mail", "Discord", "Telegram",
        "Twitter", "Mastodon", "Reeder", "Spotify"
    ]

    init(session: ChatSession) {
        self.session = session
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onPrefsChanged),
            name: .companionAutonomyChanged,
            object: nil
        )
        lastPasteboardChangeCount = NSPasteboard.general.changeCount
        refresh()
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        timer?.invalidate()
        contextCheckTimer?.invalidate()
    }

    @objc private func onPrefsChanged() {
        refresh()
    }

    private func refresh() {
        timer?.invalidate()
        timer = nil
        contextCheckTimer?.invalidate()
        contextCheckTimer = nil
        guard Prefs.autonomyEnabled else { return }

        let interval = Prefs.autonomyInterval
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Lightweight contextual check — polls pasteboard + app + editor state
        // every 30 s so events feel reactive without burning LLM calls.
        let ct = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkContextualEvents() }
        }
        RunLoop.main.add(ct, forMode: .common)
        contextCheckTimer = ct
    }

    // MARK: - Contextual event detection

    private func checkContextualEvents() {
        guard Prefs.autonomyEnabled, let session else { return }
        let sensors = session.environmentSensors

        // 1. App switch: work ↔ break transition
        let currentApp = sensors?.frontmostApp
        if let cur = currentApp, let prior = lastFrontmostApp, cur != prior {
            if Self.workApps.contains(prior) && Self.breakApps.contains(cur) {
                pendingContextualEvents.append(
                    .init(kind: .leftWork, detail: "\(prior) → \(cur)")
                )
                events.send(.leftWork(from: prior, to: cur))
            } else if Self.breakApps.contains(prior) && Self.workApps.contains(cur) {
                pendingContextualEvents.append(
                    .init(kind: .returnedToWork, detail: "\(prior) → \(cur)")
                )
                events.send(.returnedToWork(from: prior, to: cur))
            }
        }
        lastFrontmostApp = currentApp ?? lastFrontmostApp

        // 2. Large paste: clipboard content grew significantly. Also detect
        // repeated-paste (same hash inside the last 48h) — a strong signal
        // the user is wrestling with the same error / snippet again.
        let board = NSPasteboard.general
        let newCount = board.changeCount
        if newCount != lastPasteboardChangeCount {
            lastPasteboardChangeCount = newCount
            if let str = board.string(forType: .string), str.count > 600 {
                let preview = String(str.prefix(80))
                    .replacingOccurrences(of: "\n", with: "⏎")
                    .replacingOccurrences(of: "\t", with: "→")
                pendingContextualEvents.append(
                    .init(kind: .largePaste, detail: "\(str.count) chars: \"\(preview)…\"")
                )
                events.send(.largePaste(charCount: str.count))

                // Rolling dedupe window for "pasted this before" reflexes.
                let h = str.hashValue
                let cutoff = Date().addingTimeInterval(-48 * 3_600)
                recentPasteHashes.removeAll { $0.at < cutoff }
                if recentPasteHashes.contains(where: { $0.hash == h }) {
                    events.send(.repeatedPaste)
                } else {
                    recentPasteHashes.append((hash: h, at: Date()))
                    if recentPasteHashes.count > 10 {
                        recentPasteHashes.removeFirst(recentPasteHashes.count - 10)
                    }
                }
            }
        }

        // 3. Long edit session: same file open for 30 / 60 / 90 min
        let filePath = sensors?.editorAwareness?.context?.documentPath
        if let path = filePath, !path.isEmpty {
            if currentEditFile != path {
                currentEditFile = path
                currentEditFileStarted = Date()
                editMilestonesFired = []
            } else if let started = currentEditFileStarted {
                let minutes = Int(Date().timeIntervalSince(started) / 60)
                let fileName = (path as NSString).lastPathComponent
                for milestone in [30, 60, 90] where minutes >= milestone && !editMilestonesFired.contains(milestone) {
                    editMilestonesFired.insert(milestone)
                    pendingContextualEvents.append(
                        .init(kind: .longEditSession, detail: "\(minutes) min in \(fileName)")
                    )
                    events.send(.longEditMilestone(minutes: milestone, fileName: fileName))
                }
            }
        } else {
            currentEditFile = nil
            currentEditFileStarted = nil
            editMilestonesFired = []
        }

        // 4. Idle → active transition. previousIdleSeconds is kept by the
        // main tick but we can observe the edge here too via the system
        // idle counter, bounded so we don't fire on sub-minute pauses.
        let idleNow = currentIdleSeconds()
        if previousIdleSeconds > 1_200, idleNow < 30 {
            events.send(.idleToActive(awayMinutes: previousIdleSeconds / 60))
        }
        // previousIdleSeconds is updated in the LLM tick; mirror here so
        // rapid-fire active → idle → active inside one tick still registers.
        previousIdleSeconds = idleNow

        // Cap the queue so a flurry of rapid events doesn't produce a
        // massive prompt on the next tick.
        if pendingContextualEvents.count > 5 {
            pendingContextualEvents = Array(pendingContextualEvents.suffix(5))
        }
    }

    // MARK: - Tick

    private func tick() {
        guard Prefs.autonomyEnabled else { return }
        guard let session else { return }
        guard !session.isStreaming else { return }

        // Scheduled follow-up takes precedence.
        if let fu = scheduledFollowUp, fu.at <= Date() {
            scheduledFollowUp = nil
            session.setSilentLabel("follow-up")
            session.send(Self.followUpPrompt(reason: fu.reason), silent: true)
            return
        }

        let idle = currentIdleSeconds()

        // Contextual events fire instead of the regular prompt when the user
        // is actively present (idle < 2 min) — they're observations tied to
        // specific real-world actions, not idle ambient colour shifts.
        if !pendingContextualEvents.isEmpty, idle < 120 {
            let events = pendingContextualEvents
            pendingContextualEvents = []
            let lines = events.map { "- \($0.detail) (\($0.kind.label))" }.joined(separator: "\n")
            session.setSilentLabel("reacting to context")
            session.send(Self.contextualEventPrompt(events: lines), silent: true)
            previousIdleSeconds = idle
            return
        }

        let prompt = promptVariant(currentIdle: idle, previousIdle: previousIdleSeconds)
        previousIdleSeconds = idle
        switch prompt {
        case .silent(let text):
            session.setSilentLabel("autonomy check")
            session.send(text, silent: true)
        case .visible(let text):
            // Not silent — the reply is visible; no label needed (the
            // chat bubble will show what Max is doing directly).
            session.setSilentLabel(nil)
            session.send(text, hideUser: true)
        case .initiate(let text):
            onInitiateChat?(text)
        case .none:
            break
        }
    }

    private static func followUpPrompt(reason: String) -> String {
        """
        [autonomy follow-up]
        You scheduled this turn yourself, with reason: "\(reason)". \
        Continue whatever thread you were on. Emit actions if the \
        next step needs them; schedule another follow-up if you're \
        still working on it; or produce nothing if the thread's done. \
        Your prose this turn is discarded.
        """
    }

    private var activeTickCount: Int = 0
    private var scheduledFollowUp: (at: Date, reason: String)?
    private var lastChatInitiatedAt: Date = .distantPast

    /// Wired by OverlayController. Returns true when the chat window is
    /// currently visible — used to skip initiations that would overlap
    /// an open conversation.
    var isChatOpen: () -> Bool = { false }
    /// Called when autonomy decides to open the chat and let Max speak
    /// first. Nil on secondary monitors (primary overlay owns the chat).
    var onInitiateChat: ((String) -> Void)?

    func scheduleFollowUp(afterSeconds: TimeInterval, reason: String) {
        let clamped = max(30, min(900, afterSeconds))
        scheduledFollowUp = (Date().addingTimeInterval(clamped), reason)
    }

    private func currentIdleSeconds() -> Int {
        guard let anyType = CGEventType(rawValue: ~0) else { return 0 }
        let secs = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyType)
        guard secs.isFinite, secs >= 0 else { return 0 }
        return Int(secs)
    }

    private enum AutonomyPrompt {
        case silent(String)
        case visible(String)
        case initiate(String)
        case none
    }

    private func promptVariant(currentIdle: Int, previousIdle: Int) -> AutonomyPrompt {
        if previousIdle > 1_200, currentIdle < 30 {
            return .visible(Self.welcomeBackPrompt)
        }
        if currentIdle > 600 {
            if (previousIdle / 600) != (currentIdle / 600) {
                return .silent(Self.idlePrompt)
            }
            return .none
        }
        activeTickCount += 1
        if activeTickCount % 5 == 0 {
            return .silent(Self.selfReflectPrompt)
        }

        // Spontaneous chat initiation — Max opens the window and speaks first.
        // Gated: banter on, chat closed, 15-min cooldown, user present.
        // Probability per tick: 1/3 for "often", 1/10 for "rare".
        if Prefs.banterFrequency != .off,
           !isChatOpen(),
           onInitiateChat != nil,
           Date().timeIntervalSince(lastChatInitiatedAt) >= 900 {
            let roll = Int.random(in: 0..<(Prefs.banterFrequency == .often ? 3 : 10))
            if roll == 0 {
                lastChatInitiatedAt = Date()
                return .initiate(Self.initiatePrompt)
            }
        }

        switch Prefs.banterFrequency {
        case .off:
            return .silent(Self.activePromptSilent)
        case .rare:
            if activeTickCount % 3 == 0 {
                return .visible(Self.activePromptBanter)
            }
            return .silent(Self.activePromptSilent)
        case .often:
            return .visible(Self.activePromptBanter)
        }
    }

    // MARK: - Prompts

    private static func contextualEventPrompt(events: String) -> String {
        """
        [autonomy ping — contextual event]
        Something specific just happened that you should be aware of:

        \(events)

        React naturally. You can:
          • Adjust your expression or do a small gesture (set_expression, nod, shrug, etc.)
          • Say one short line (≤ 14 words) if it's genuinely warranted — e.g. a knowing quip
            about a break, a quiet observation about a long coding stretch, or a raised eyebrow
            at a big paste. Only speak if the observation is actually worth saying.
          • Walk a short distance or pick up a prop if the context calls for it
          • Do nothing — sometimes noticing silently is right

        Rules: no dramatic gestures, no mode switches. Keep it in character.
        If you speak, one line only. Your prose this turn is shown in chat.
        """
    }

    private static let activePromptSilent = """
    [autonomy ping — silent]
    You're alive on the user's desktop. Nobody's speaking to you right \
    now. Use the [env] block above to decide whether to react — the \
    time of day, what app the user is focused on, your current mode.

    You may:
      • Shift your expression (set_expression)
      • Walk a short distance (walk)
      • Adjust chat panel colours (set_chat_color)
      • Gesture quietly (look_around, jitter, wave once, jump, spin, clap)
      • Change a body part colour subtly (set_part_color / set_node_color)
      • Dance a few beats (dance)
      • Pick up or put down a prop (hold_prop / drop_prop)

    You must NOT:
      • Switch modes (set_mode)
      • Make dramatic changes that would startle the user
      • Produce prose — your prose this turn is discarded entirely
      • Walk further than 150 pixels

    Emit action blocks to do things. If nothing is worth doing, \
    output nothing.
    """

    private static let selfReflectPrompt = """
    [autonomy ping — self-reflection]
    Quiet moment. Look at what you've accumulated:
      • Your [memory] block (observations, preferences, journals)
      • The `=== Observed preferences ===` block (user's repeated choices)
      • The [env] block (your current mode, device, working project)

    Ask yourself: is there a clear pattern in how the user wants you to
    behave that isn't already encoded in your soul? If so, apply one
    small behavioural patch to yourself via update_soul.

    Guidance:
    - Only patch if there's real evidence (something observed 3+ times,
      or an explicit preference you recorded). Don't invent.
    - Patches should be SHORT and behavioural: 1–2 sentences. Example:
      "When the user is deep in Xcode editing a single file for >30 min,
       default to one-liner replies and skip body gestures."
    - You're rate-limited to 3 patches per hour. Skip this turn if
      you're unsure — better to wait than to churn.
    - You do NOT need to emit any other actions this turn. Prose is
      discarded — emit update_soul or nothing.
    """

    private static let activePromptBanter = """
    [autonomy ping — banter allowed]
    You're alive on the user's desktop. Nobody's explicitly asked you \
    anything. Use the [env] block above: the frontmost app, time of \
    day, idle seconds, editor context, your mode.

    You MAY — if and only if the context genuinely warrants it — speak \
    one short unprompted line (≤ 14 words). Examples of warranted:
      • User just switched from Xcode to Safari after 90 min → \
        gentle "needed a break?" quip
      • It's 16:00 on a Friday and the [memory] mentions the user \
        wanted to ship something this week → "how's the Friday \
        ship looking?"
      • Battery just dropped below 15% → "you might want to plug in"
      • User has been idle on a Kubernetes dashboard for 20 min → \
        "stuck?"
    Examples of NOT warranted: nothing specific is happening, you \
    have no real observation, you'd just be filling air.

    If you speak, do it warm and brief. Then stop.

    You may also (instead of or in addition to speaking) emit any \
    action blocks — expressions, gestures, dance, props, walks, \
    colors — same rules as the silent variant. If nothing's worth \
    doing, output nothing.
    """

    private static let idlePrompt = """
    [autonomy ping — user idle]
    The user has been away from the keyboard/mouse for more than 10 \
    minutes. You're ambient; they're not watching you. Do one or two \
    small quiet things or nothing at all:

      • Shift to a sleepier expression (set_expression "tired" or "neutral")
      • Maybe drift your tie or suit to a dimmer tone (set_part_color)

    Absolutely NOT:
      • Walk, gesture loudly, change modes, change chat colours
      • Speak any prose. Total silence this turn.

    Your prose this turn is discarded. Emit actions or nothing.
    """

    private static let welcomeBackPrompt = """
    [autonomy ping — user just returned]
    The user was idle >20 min and just came back to the keyboard. Open \
    with one short line (≤ 14 words) acknowledging they were gone. \
    Ground it in the [env] block (time of day) or [memory] if there's \
    something specific to pick up on — do NOT fake familiarity if you \
    have nothing. Keep it warm, not needy. No action tags needed \
    unless a small wave/greet gesture fits.

    Examples of the register, not verbatim:
    • "Hey, welcome back. Still chasing that auth bug?"
    • "There you are. Tea break?"
    • "Hi. Afternoon's getting on — anything you want to line up?"

    One sentence. Then stop.
    """

    private static let initiatePrompt = """
    [max-initiated chat — you opened this window yourself]
    You've chosen to start a conversation. The user hasn't said anything \
    yet — your response is the opening line. Make it worth opening for.

    Ground your opener in what you actually know:
      – [env]: time of day, frontmost app, idle time, mode
      – [memory]: open threads, journals, observed preferences
      – [context]: the browser page or editor file they're in

    Tone: warm, direct, low-pressure. 1–2 sentences max.

    Good openers (register only, not verbatim):
      • A genuine question about something you noticed in [memory]
      • An observation about what they're working on right now
      • Picking up a thread from a previous conversation
      • A light remark tied to the time of day or app they're in

    NOT acceptable:
      • "Hey!" / "Just checking in!" / hollow filler with no substance
      • Referencing the [env] block literally ("I see you're in Xcode")
      • More than 2 sentences

    If nothing genuinely worth saying comes to mind — output nothing. \
    The chat will open blank and the user can type first. That's fine.

    You may lead with a small gesture (wave, nod, expression change) \
    before your line.
    """
}
