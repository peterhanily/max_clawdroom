import AppKit
import Combine
import Foundation

/// Zero-LLM-cost behaviour layer. Subscribes to events emitted by
/// `AutonomyController` (and `SoulPatchQueue` via notifications) and
/// fires small in-world reactions — expression changes, head tilts, brief
/// gestures — directly on `Pet` without routing through `ActionDispatcher`.
///
/// Why bypass the dispatcher: reflex reactions are transient, meant to
/// feel ambient. If they pushed onto `UndoStack` the user's ⌘Z would pop
/// random head-tilts they never noticed instead of their own last action.
/// The dispatcher is for agent- or user-authored intent; this is for the
/// ambient mood channel.
///
/// Design rules:
/// 1. **Never calls the LLM.** Every reaction is a direct `Pet` method
///    call — zero tokens, zero subprocess IO.
/// 2. **Cheap by default.** Most events produce one expression pose +
///    one gesture. Loud events (repeated paste) get a compound reaction.
/// 3. **Throttled.** A per-event-kind cooldown prevents a spammy
///    environment (rapid app-switching, chained pastes) from producing a
///    jittery pet.
/// 4. **Respectful of in-flight chat.** Skips reactions while the
///    session is streaming a response so an LLM-driven pose / walk isn't
///    stomped mid-animation.
@MainActor
final class ReflexController {

    private weak var pet: Pet?
    private weak var session: ChatSession?
    private weak var memory: MemoryStore?

    private var cancellables: Set<AnyCancellable> = []
    private var soulObserver: NSObjectProtocol?

    /// Per-event-kind last-fire timestamps. Keyed by `cooldownKey(for:)`
    /// — different events can share a key if they should throttle each
    /// other (e.g. any "attention glance" flavour).
    private var lastFiredAt: [String: Date] = [:]

    init(
        pet: Pet,
        session: ChatSession,
        memory: MemoryStore? = nil,
        events: AnyPublisher<ReflexEvent, Never>
    ) {
        self.pet = pet
        self.session = session
        self.memory = memory
        events
            .sink { [weak self] event in
                self?.react(to: event)
            }
            .store(in: &cancellables)

        // SoulPatchQueue doesn't share the event bus yet — it posts a
        // notification on apply. Bridge that into the reflex flow so
        // soul absorption visibly registers on the pet.
        soulObserver = NotificationCenter.default.addObserver(
            forName: .companionSoulChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let rationale = (note.userInfo?["rationale"] as? String) ?? ""
            Task { @MainActor in
                self?.react(to: .soulPatchAccepted(rationale: rationale))
            }
        }
    }

    isolated deinit {
        if let obs = soulObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Reaction pipeline

    func react(to event: ReflexEvent) {
        // Don't clobber an active LLM-driven response.
        if session?.isStreaming == true { return }
        guard let pet else { return }

        let key = cooldownKey(for: event)
        let minGap = cooldownSeconds(for: event)
        if let last = lastFiredAt[key], Date().timeIntervalSince(last) < minGap {
            return
        }
        lastFiredAt[key] = Date()

        // Side-effect: write an observation entry on commits so the
        // next `[you]` synthesis picks up that the user shipped
        // something. Kept concise — the message itself is the signal.
        if case .commitLanded(let message) = event, !message.isEmpty {
            let preview = String(message.prefix(120))
            memory?.append(.observation("commit: \(preview)"))
        }

        apply(plan(for: event), on: pet)
    }

    private func apply(_ reaction: Reaction, on pet: Pet) {
        pet.poseExpression(reaction.expression)
        switch reaction.gesture {
        case .none:       break
        case .nod:        pet.nod()
        case .shakeHead:  pet.shakeHead()
        case .wave:       pet.wave()
        case .beckon:     pet.beckon()
        case .flex:       pet.flex()
        case .thumbsUp:   pet.thumbsUp()
        case .bow:        pet.bow()
        case .lookAround: pet.lookAround()
        }
    }

    // MARK: - Event → action mapping

    /// Pure function from event to the action-tag burst that should fire.
    /// Keeping it a single switch makes the full catalogue of reactions
    /// readable on one screen — add a case, ship a new reaction.
    /// A single reflex reaction — an expression pose plus an optional
    /// bounded gesture. Keeping the shape narrow means new events can't
    /// invent new behaviour surfaces; they pick from an existing palette.
    private struct Reaction {
        let expression: MaxClawdroomExpression
        let gesture: Gesture
    }

    private enum Gesture {
        case none, nod, shakeHead, wave, beckon, flex, thumbsUp, bow, lookAround
    }

    /// Pure function from event to reaction. Keeping it a single switch
    /// makes the full catalogue of reactions readable on one screen — add
    /// a case, ship a new reaction.
    private func plan(for event: ReflexEvent) -> Reaction {
        switch event {
        case .leftWork:
            // User slipped off to Slack / browser. Max notices without
            // judging — half-smile expression, slight head turn.
            return Reaction(expression: .amused, gesture: .lookAround)

        case .returnedToWork:
            // Welcome-back energy. Focused posture, small nod.
            return Reaction(expression: .focused, gesture: .nod)

        case .largePaste:
            // Eyes go wide, a moment of attention.
            return Reaction(expression: .curious, gesture: .lookAround)

        case .repeatedPaste:
            // Stronger signal — user is stuck. Subtle offer of attention:
            // leaning-in expression + a beckon. Max doesn't SAY anything
            // here (that's the LLM tick's job) but he notices.
            return Reaction(expression: .uncertain, gesture: .beckon)

        case .idleToActive(let awayMinutes):
            // Short greeting gesture — wave for very long gaps, nod
            // otherwise. Expression brightens.
            return Reaction(
                expression: .amused,
                gesture: awayMinutes >= 60 ? .wave : .nod
            )

        case .longEditMilestone(let minutes, _):
            // Quiet acknowledgement at 30 min, a thumbs-up at 60, a bow at
            // 90. Deep-work markers — should feel like a nod from across
            // the room, not an interruption.
            let g: Gesture
            switch minutes {
            case ..<60:   g = .nod
            case 60..<90: g = .thumbsUp
            default:      g = .bow
            }
            return Reaction(expression: .focused, gesture: g)

        case .soulPatchAccepted:
            // He just absorbed a new trait. Small visible ceremony —
            // expression lights up, a small flex. The tie-tint drift is
            // applied separately by `SoulTintDrift` hooked off the same
            // notification.
            return Reaction(expression: .amused, gesture: .flex)

        case .commitLanded:
            // User shipped something. Full-body acknowledgement —
            // amused expression, thumbs up. Silent — Max doesn't
            // comment on every commit; he just registers it.
            return Reaction(expression: .amused, gesture: .thumbsUp)

        case .branchSwitched:
            // Context shift — head tilt, focused expression. Don't make
            // noise about branches; the user is just navigating.
            return Reaction(expression: .focused, gesture: .lookAround)
        }
    }

    // MARK: - Cooldowns

    /// Events with the same key throttle each other. Attention-flavoured
    /// events share one key so rapid app-switching doesn't chain
    /// reactions; milestone events are distinct per minute-bucket.
    private func cooldownKey(for event: ReflexEvent) -> String {
        switch event {
        case .leftWork, .returnedToWork, .idleToActive:
            return "attention"
        case .largePaste, .repeatedPaste:
            return "paste"
        case .longEditMilestone(let minutes, _):
            return "edit.\(minutes)"
        case .soulPatchAccepted:
            return "soul"
        case .commitLanded:
            return "commit"
        case .branchSwitched:
            return "branch"
        }
    }

    private func cooldownSeconds(for event: ReflexEvent) -> TimeInterval {
        switch event {
        case .leftWork, .returnedToWork, .idleToActive:
            return 45   // at most one attention glance per ~minute
        case .largePaste, .repeatedPaste:
            return 20
        case .longEditMilestone:
            return 1    // milestones are already de-duped at the source
        case .soulPatchAccepted:
            return 5
        case .commitLanded:
            return 3    // rapid-fire commits (rebase, amend) coalesce
        case .branchSwitched:
            return 8
        }
    }
}
