import AppKit
import Foundation

/// Orchestrates Max's recurring rituals — short, personal, first-person
/// prompts delivered through the visible chat at meaningful moments.
/// Think: Sunday-evening reflection, "wrapping up?" nudge after a long
/// day, 7-day install anniversary.
///
/// Rituals are the single highest-leverage attachment mechanism in the
/// product. One LLM call per ritual per occurrence — not expensive, but
/// felt.
///
/// Design:
/// - Each `Ritual` is a pure value: id, a `shouldFire(context:)` gate,
///   a prompt template. The engine itself stays dumb — it just polls
///   the gates on a schedule.
/// - Idempotency is persisted per-ritual via `lastFiredKey`. A ritual
///   that fires twice in the same window is a coding bug, not a
///   runtime quirk — the gate is responsible for getting it right.
/// - Gates are pure functions of `(now, lastFiredAt, sensors)` so they
///   can be tested without the whole app booted.
/// - Everything runs on the primary overlay only; secondary monitors
///   don't own a RitualEngine so we can't fire twice on multi-display
///   setups.
///
/// The morning-greeting and monthly-summary hooks in `AppDelegate`
/// predate this system and stay where they are for now — they work.
/// This engine adds the rituals that didn't exist before.
@MainActor
final class RitualEngine {

    private weak var primaryOverlay: OverlayController?
    private weak var memory: MemoryStore?
    private var timer: Timer?

    /// How often gates are re-checked. 10 minutes is enough granularity
    /// for "it's now 18:00" and "user has been idle 5 min" conditions
    /// without waking the CPU for nothing.
    private let tickInterval: TimeInterval = 10 * 60

    init(primaryOverlay: OverlayController, memory: MemoryStore) {
        self.primaryOverlay = primaryOverlay
        self.memory = memory
        startTicking()
    }

    isolated deinit {
        timer?.invalidate()
    }

    /// Immediate check — called after a launch delay so rituals that
    /// depend on "it's 18:30 and I just opened the app" aren't held for
    /// ten minutes before firing. Safe to call repeatedly.
    func checkNow() {
        evaluate()
    }

    // MARK: - Scheduling

    private func startTicking() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(
            withTimeInterval: tickInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func evaluate() {
        guard let overlay = primaryOverlay else { return }
        guard let memory = memory else { return }
        guard Prefs.autonomyEnabled else { return }

        let ctx = RitualContext(
            now: Date(),
            memory: memory,
            idleSeconds: RitualEngine.currentIdleSeconds()
        )

        for ritual in Self.catalogue {
            let lastFired = Ritual.lastFired(for: ritual)
            guard ritual.shouldFire(ctx, lastFired) else { continue }
            let prompt = ritual.buildPrompt(ctx)
            Ritual.markFired(for: ritual, at: ctx.now)
            AppLog.autonomy.notice("ritual fired: \(ritual.id, privacy: .public)")
            overlay.openChatForMorningGreeting(prompt: prompt)
            // Only one ritual per tick — avoid a burst where three
            // different conditions happen to align.
            return
        }
    }

    // MARK: - Idle

    private static func currentIdleSeconds() -> Int {
        guard let anyType = CGEventType(rawValue: ~0) else { return 0 }
        let secs = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyType)
        guard secs.isFinite, secs >= 0 else { return 0 }
        return Int(secs)
    }

    // MARK: - Catalogue

    /// All rituals the engine knows about. Order matters — earlier
    /// rituals take priority when multiple would fire on the same tick.
    /// Anniversary first because it's rare + special; Sunday reflection
    /// before evening checkout so a late-Sunday user gets the week
    /// summary instead of a nightly wrap.
    private static let catalogue: [Ritual] = [
        .anniversary,
        .sundayReflection,
        .eveningCheckout
    ]
}

// MARK: - Context

/// Everything a ritual gate needs to decide whether to fire. Passed by
/// value so tests can construct one without booting the app.
struct RitualContext {
    let now: Date
    weak var memory: MemoryStore?
    let idleSeconds: Int

    var calendar: Calendar { Calendar.current }
    var hour: Int { calendar.component(.hour, from: now) }
    var weekday: Int { calendar.component(.weekday, from: now) }  // Sunday = 1
    var weekOfYear: Int { calendar.component(.weekOfYear, from: now) }
    var dayKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: now)
    }
}

// MARK: - Ritual

struct Ritual {
    /// Stable identifier used as the UserDefaults key for lastFiredAt.
    /// Don't rename casually — renaming loses idempotency for installed
    /// users (the engine will think the ritual has never fired).
    let id: String
    let displayName: String
    /// `@MainActor` because gates read from `MemoryStore`, which is main-
    /// isolated. Calling from `RitualEngine.evaluate` (also @MainActor)
    /// works without a hop; the annotation just lets the compiler confirm.
    let shouldFire: @MainActor (RitualContext, Date?) -> Bool
    let buildPrompt: @MainActor (RitualContext) -> String

    // MARK: - Persistence

    static func lastFired(for ritual: Ritual) -> Date? {
        UserDefaults.standard.object(
            forKey: "companion.ritual.\(ritual.id).last_fired_at"
        ) as? Date
    }

    static func markFired(for ritual: Ritual, at date: Date) {
        UserDefaults.standard.set(
            date,
            forKey: "companion.ritual.\(ritual.id).last_fired_at"
        )
    }
}
