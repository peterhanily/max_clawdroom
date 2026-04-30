import Combine
import Foundation

/// Orchestrates the first-run / on-demand demo walk-through.
///
/// Writes assistant messages directly into `ChatSession.messages` with a
/// typewriter effect and fires actions through `ActionDispatcher` so the
/// tour uses the same code paths as real agent replies. During the tour
/// the chat input is disabled and a "Skip" control shows in the header.
@MainActor
final class TourController: ObservableObject {
    @Published private(set) var isActive: Bool = false

    private let session: ChatSession
    private let context: MaxClawdroomContext
    /// Voice engine for tour narration. Optional because not every
    /// construction site has a live VoiceEngine (tests, preview), but
    /// when present, every beat speaks aloud in parallel with the
    /// typewriter text.
    private weak var voice: VoiceEngine?

    private var task: Task<Void, Never>?

    init(session: ChatSession, context: MaxClawdroomContext, voice: VoiceEngine? = nil) {
        self.session = session
        self.context = context
        self.voice = voice
    }

    func start() {
        guard !isActive else { return }
        // Clear the session so the tour starts in a clean transcript and
        // there's no conflict with an in-flight claude stream.
        session.clear()
        isActive = true
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func skip() {
        task?.cancel()
        task = nil
        isActive = false
    }

    // MARK: - Sequencing

    private func run() async {
        for step in TourScript.steps {
            if Task.isCancelled { break }
            await runStep(step)
        }
        if !Task.isCancelled {
            isActive = false
        }
    }

    private func runStep(_ step: TourStep) async {
        async let narrate: Void = typeNarration(step.narration)
        async let fire: Void = fireActions(step.actions)
        _ = await (narrate, fire)
        if Task.isCancelled { return }
        try? await Task.sleep(for: .milliseconds(Int(step.dwell * 1000)))
    }

    private func typeNarration(_ text: String) async {
        guard !text.isEmpty else { return }

        // Speak the beat aloud in parallel with the typewriter. The
        // typewriter advances char-by-char (for the visual feel), but
        // TTS gets the whole line up front so the voice doesn't crawl
        // at 30ms/char. They land roughly in sync on short beats.
        voice?.speakNow(text)

        let id = UUID()
        session.appendMessage(
            ChatMessage(id: id, role: .assistant, kind: .text(""))
        )

        var current = ""
        for ch in text {
            if Task.isCancelled { return }
            current.append(ch)
            if let idx = session.messages.firstIndex(where: { $0.id == id }) {
                session.messages[idx].kind = .text(current)
            }
            // Tiny jitter to avoid feeling mechanical — most chars are 30ms
            // but every few glyphs lands a hair slower so it reads like a
            // live stream rather than a metronome.
            let base: Int = 28
            let jitter = Int.random(in: 0...12)
            try? await Task.sleep(for: .milliseconds(base + jitter))
        }
    }

    private func fireActions(_ actions: [TourAction]) async {
        for action in actions {
            if action.delay > 0 {
                try? await Task.sleep(for: .milliseconds(Int(action.delay * 1000)))
            }
            if Task.isCancelled { return }
            let ca = MaxClawdroomAction(op: action.op, args: action.args)
            ActionDispatcher.dispatch(ca, in: context)
        }
    }
}

// MARK: - Script

enum TourScript {
    /// All narration is pulled from `Localizable.xcstrings` — every
    /// `tour.stepNN` key is flagged NEEDS-NATIVE-REVIEW in the catalog.
    /// English is the only fully-translated locale today; non-English
    /// values fall back to English (state="new") so the tour still runs
    /// for non-English users — just in English. A native-speaker pass
    /// can replace the values per locale without touching this file.
    static let steps: [TourStep] = [
        TourStep(
            narration: String(localized: "tour.step01", bundle: .companionResources),
            actions: [
                TourAction("greet", delay: 1.0),
                TourAction("set_expression", ["name": "amused"], delay: 2.2)
            ],
            dwell: 1.2
        ),
        TourStep(
            narration: String(localized: "tour.step02", bundle: .companionResources),
            actions: [
                TourAction("walk", ["direction": "left", "distance": 160.0], delay: 1.0),
                TourAction("walk", ["direction": "right", "distance": 160.0], delay: 2.6)
            ],
            dwell: 1.5
        ),
        TourStep(
            narration: String(localized: "tour.step03", bundle: .companionResources),
            actions: [
                TourAction("set_expression", ["name": "smug"], delay: 0.6),
                TourAction("set_expression", ["name": "neutral"], delay: 2.0)
            ],
            dwell: 1.2
        ),
        TourStep(
            narration: String(localized: "tour.step04", bundle: .companionResources),
            actions: [
                TourAction("set_part_color", ["part": "tie", "hex": "#2DE1FC"], delay: 1.2),
                TourAction("set_expression", ["name": "curious"], delay: 1.4)
            ],
            dwell: 1.6
        ),
        TourStep(
            narration: String(localized: "tour.step05", bundle: .companionResources),
            actions: [TourAction("set_expression", ["name": "devious"], delay: 1.0)],
            dwell: 2.2
        ),
        TourStep(
            narration: String(localized: "tour.step06", bundle: .companionResources),
            actions: [
                TourAction("hold_prop", ["item": "wizard_hat"], delay: 0.8),
                TourAction("hold_prop", ["item": "wand"], delay: 1.6),
                TourAction("set_expression", ["name": "excited"], delay: 2.0)
            ],
            dwell: 2.4
        ),
        TourStep(
            narration: String(localized: "tour.step07", bundle: .companionResources),
            actions: [
                TourAction("drop_prop", ["item": "wand"], delay: 0.6),
                TourAction("set_expression", ["name": "neutral"], delay: 1.2)
            ],
            dwell: 1.4
        ),
        TourStep(
            narration: String(localized: "tour.step08", bundle: .companionResources),
            actions: [TourAction("set_mode", ["name": "tv"], delay: 1.0)],
            dwell: 3.0
        ),
        TourStep(
            narration: String(localized: "tour.step09", bundle: .companionResources),
            actions: [],
            dwell: 3.0
        ),
        TourStep(
            narration: String(localized: "tour.step10", bundle: .companionResources),
            actions: [
                TourAction("set_mode", ["name": "desktop"], delay: 0.6),
                TourAction("drop_prop", ["item": "wizard_hat"], delay: 1.2)
            ],
            dwell: 1.4
        ),
        TourStep(
            narration: String(localized: "tour.step11", bundle: .companionResources),
            actions: [
                TourAction("set_chat_color", ["target": "border", "hex": "#2DE1FC"], delay: 1.0),
                TourAction("set_chat_color", ["target": "user", "hex": "#F7D046"], delay: 1.2)
            ],
            dwell: 2.0
        ),
        TourStep(
            narration: String(localized: "tour.step12", bundle: .companionResources),
            actions: [
                TourAction("jitter", delay: 0.6),
                TourAction("jitter", delay: 0.7),
                TourAction("look_around", delay: 1.1)
            ],
            dwell: 1.8
        ),
        TourStep(
            narration: String(localized: "tour.step13", bundle: .companionResources),
            actions: [
                TourAction("set_expression", ["name": "focused"], delay: 0.8),
                TourAction("nod", delay: 1.6)
            ],
            dwell: 2.6
        ),
        TourStep(
            narration: String(localized: "tour.step14", bundle: .companionResources),
            actions: [TourAction("look_around", delay: 1.0)],
            dwell: 2.4
        ),
        TourStep(
            narration: String(localized: "tour.step15", bundle: .companionResources),
            actions: [
                TourAction("set_expression", ["name": "amused"], delay: 0.8),
                TourAction("wave", delay: 1.6)
            ],
            dwell: 1.0
        )
    ]
}
