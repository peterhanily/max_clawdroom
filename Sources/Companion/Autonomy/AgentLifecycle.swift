import AppKit
import Foundation

/// Explicit agent lifecycle — runs above `AutonomyController` and gives
/// Max a deliberate wake → survey → plan → work → idle → sleep loop
/// instead of a flat "fire a prompt every N minutes" cadence.
///
/// Architecture:
/// - A short-cadence `heartbeat` timer (10s) advances the state machine.
/// - Each state has a specific job and transitions to the next on
///   completion or timeout.
/// - Sleep persists the lifecycle's own state to disk so a relaunch
///   resumes where it left off rather than forgetting the current phase.
/// - Sleeping poses Max with `.tired`, pauses the heartbeat, and waits
///   on a wake signal (timer + event-driven).
///
/// Wake signals:
/// - Periodic: a longer wake timer fires every 5–15 min (configurable)
///   regardless of inactivity, so Max doesn't sleep forever.
/// - Event-driven: WorkWatcher commits, large pastes, app-switches,
///   user input in chat — anything that means the world changed.
///
/// The actual LLM prompts still go through `ChatSession.send(silent:)`;
/// this controller just decides WHEN and WHAT to ask.
@MainActor
final class AgentLifecycle {

    enum State: String, Codable {
        case awake
        case surveying   // wake tasks in progress
        case planning    // about to ask the agent "what should we do?"
        case working     // agent turn in flight
        case idle        // nothing to do, about to sleep
        case sleeping    // timers paused, state persisted
    }

    /// Observable so UI / menu bar can surface the current phase if
    /// we ever want to show it. Not exposed yet.
    private(set) var state: State = .awake {
        didSet { if state != oldValue { didTransition(from: oldValue, to: state) } }
    }

    private weak var session: ChatSession?
    private weak var taskStore: AgentTaskStore?
    private weak var memory: MemoryStore?
    private weak var pet: Pet?

    private var heartbeat: Timer?
    private var wakeTimer: Timer?
    private var lastActivityAt: Date = Date()
    /// When `idle` started. Used to decide when to transition to sleeping.
    private var idleSince: Date?
    /// When `sleeping` started. Used to throttle re-wakes.
    private var sleepingSince: Date?

    /// How long `idle` can persist before we go to sleep.
    private let idleToSleepSeconds: TimeInterval = 120
    /// How often the heartbeat runs while awake.
    private let heartbeatInterval: TimeInterval = 10
    /// Minimum time between two consecutive plan phases so we don't
    /// spam the agent. Prevents a burst of wake events (commit +
    /// large paste + app switch) from all producing their own plans.
    private let minPlanInterval: TimeInterval = 90
    private var lastPlanAt: Date = .distantPast
    /// Max time between wakes — even with no activity, Max should check
    /// in now and then.
    private let maxSleepSeconds: TimeInterval = 15 * 60

    init(
        session: ChatSession,
        taskStore: AgentTaskStore,
        memory: MemoryStore,
        pet: Pet
    ) {
        self.session = session
        self.taskStore = taskStore
        self.memory = memory
        self.pet = pet
        loadPersistedState()
    }

    // MARK: - Public lifecycle

    func start() {
        stop()
        guard Prefs.agentLifecycleEnabled else { return }
        // If we persisted as sleeping, stay sleeping — arm only the wake
        // timer. Otherwise kick the heartbeat and start surveying.
        if state == .sleeping {
            armWakeTimer()
        } else {
            armHeartbeat()
            transition(to: .surveying)
        }
        AppLog.autonomy.notice("AgentLifecycle started in state \(self.state.rawValue, privacy: .public)")
    }

    func stop() {
        heartbeat?.invalidate(); heartbeat = nil
        wakeTimer?.invalidate(); wakeTimer = nil
    }

    /// Nudge the lifecycle — something user-visible just happened, so
    /// wake up if sleeping and reset the idle clock. Called by the
    /// WorkWatcher reflex bus, pasteboard events, chat sends, etc.
    func nudge(reason: String) {
        lastActivityAt = Date()
        if state == .sleeping {
            AppLog.autonomy.notice("AgentLifecycle waking: \(reason, privacy: .public)")
            transition(to: .awake)
            armHeartbeat()
            transition(to: .surveying)
        } else if state == .idle {
            transition(to: .awake)
        }
    }

    // MARK: - State machine

    private func transition(to next: State) {
        state = next
    }

    private func didTransition(from previous: State, to next: State) {
        AppLog.autonomy.debug("AgentLifecycle: \(previous.rawValue, privacy: .public) → \(next.rawValue, privacy: .public)")
        persistState()
        switch next {
        case .awake:
            pet?.poseExpression(.neutral)
        case .surveying:
            runSurvey()
        case .planning:
            runPlan()
        case .working:
            // Work is in-flight via ChatSession; we'll get notified
            // on stream end via the chat-idle check in the heartbeat.
            break
        case .idle:
            idleSince = Date()
        case .sleeping:
            sleepingSince = Date()
            pet?.poseExpression(.tired)
            heartbeat?.invalidate(); heartbeat = nil
            armWakeTimer()
            persistState()
        }
    }

    private func armHeartbeat() {
        heartbeat?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.beat() }
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeat = t
    }

    private func armWakeTimer() {
        wakeTimer?.invalidate()
        // Fire after the max sleep budget so even a totally quiet
        // machine eventually gets a check-in.
        let t = Timer.scheduledTimer(withTimeInterval: maxSleepSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.nudge(reason: "periodic wake") }
        }
        RunLoop.main.add(t, forMode: .common)
        wakeTimer = t
    }

    /// One heartbeat tick. Runs every ~10s while awake. Decides whether
    /// to advance the state machine based on the current state + the
    /// in-flight session.
    private func beat() {
        guard let session else { return }
        switch state {
        case .awake:
            // Idle detection — if nothing has happened for a while,
            // head toward sleep.
            let since = Date().timeIntervalSince(lastActivityAt)
            if since > idleToSleepSeconds / 2 {
                transition(to: .idle)
            }
        case .idle:
            guard let start = idleSince else { return }
            if Date().timeIntervalSince(start) > idleToSleepSeconds {
                transition(to: .sleeping)
            }
        case .working:
            // Chat session finished streaming → back to awake.
            if !session.isStreaming {
                transition(to: .awake)
                lastActivityAt = Date()
            }
        case .surveying, .planning, .sleeping:
            break
        }
    }

    // MARK: - Phase implementations

    /// SURVEY — collect the signals that should inform what Max does next.
    /// Cheap (no LLM call). Produces tasks when it detects something
    /// worth working on; transitions to `planning` if new tasks showed
    /// up OR the queue already has high-priority work waiting.
    private func runSurvey() {
        guard let store = taskStore else {
            transition(to: .awake); return
        }
        var discovered = 0

        // Signal 1 — unfinished observations in memory that look like
        // follow-ups. We flag anything the agent wrote as an observation
        // recently that has a "?" or "todo" / "follow up" marker.
        if let mem = memory {
            for entry in mem.entries.suffix(20) {
                let lc = entry.text.lowercased()
                let looksUnfinished = lc.contains("todo")
                    || lc.contains("follow up")
                    || lc.contains("follow-up")
                    || lc.contains("should check")
                // Dedupe — don't re-add if a pending task already cites it.
                let snippet = String(entry.text.prefix(80))
                if looksUnfinished && !store.tasks.contains(where: { $0.summary.hasPrefix(snippet.prefix(40)) }) {
                    store.add(
                        summary: "Follow up: \(snippet)",
                        origin: .survey,
                        priority: 55
                    )
                    discovered += 1
                }
            }
        }

        // Decision: if the queue has ANYTHING pending, plan. Else idle.
        if store.nextPending() != nil {
            transition(to: .planning)
        } else {
            AppLog.autonomy.debug("AgentLifecycle: survey found no tasks (\(discovered, privacy: .public) new)")
            transition(to: .idle)
        }
    }

    /// PLAN — ask the agent what to do with the top task. Silent prompt:
    /// neither the request nor the reply shows in the transcript, but
    /// action blocks the agent emits still dispatch.
    private func runPlan() {
        guard let session, let store = taskStore else {
            transition(to: .awake); return
        }
        let now = Date()
        if now.timeIntervalSince(lastPlanAt) < minPlanInterval {
            transition(to: .idle); return
        }
        guard let task = store.nextPending() else {
            transition(to: .idle); return
        }

        lastPlanAt = now
        store.claim(id: task.id)

        let queueBlock = store.promptSummary()
        let prompt = """
        [lifecycle_plan] A background survey picked up work on your task queue. \
        Spend one beat on this — either take a concrete small action (an \
        expression change, a brief observation via `remember`, a memory fold, \
        a small soul note) or just acknowledge and defer.

        Top task: \(task.summary)

        \(queueBlock)

        Do not speak to the user; this is a silent plan tick. Emit action \
        blocks if you act. If there's nothing meaningful to do, just say so \
        to yourself and we'll move on.
        """
        session.setSilentLabel("planning")
        session.send(prompt, silent: true)
        store.complete(id: task.id)
        transition(to: .working)
    }

    // MARK: - Persistence

    private var persistedURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport
            .appendingPathComponent("Companion", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agent_lifecycle.json")
    }

    private struct PersistedState: Codable {
        let state: State
        let sleepingSince: Date?
        let lastActivityAt: Date
    }

    private func persistState() {
        let payload = PersistedState(
            state: state,
            sleepingSince: sleepingSince,
            lastActivityAt: lastActivityAt
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: persistedURL, options: .atomic)
    }

    private func loadPersistedState() {
        guard let data = try? Data(contentsOf: persistedURL),
              let payload = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }
        // Always wake up fresh on launch. Resuming as `.sleeping` (or
        // any mid-cycle state) fires the matching `didTransition`,
        // which poses Max `.tired` — leaving his eyes squinted from
        // the moment the app appears. Carry forward `lastActivityAt`
        // so idle-detection math still has a reasonable anchor, but
        // the STATE always starts at `.awake` and the first tick
        // re-enters the normal flow.
        //
        // Assigning to the backing `_state` directly would also work
        // (bypasses didSet) but we WANT didTransition to fire for
        // `.awake` here so the neutral pose gets applied.
        sleepingSince = nil
        lastActivityAt = payload.lastActivityAt
        state = .awake
        // Explicit reset in case `state` was already `.awake` (default)
        // and the didSet guard skipped the transition. Always end load
        // with Max's face in the neutral pose, not whatever the prior
        // session left behind.
        pet?.poseExpression(.neutral)
    }
}
