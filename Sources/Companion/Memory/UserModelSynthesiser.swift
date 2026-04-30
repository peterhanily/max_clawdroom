import Foundation

/// Turns the raw, noisy `MemoryStore` into a structured `UserModel`.
///
/// Strategy: fire a silent one-shot inquiry to the configured backend
/// asking for JSON that conforms to `UserModel`. The response never
/// lands in the visible transcript — `ChatSession.send` is called with
/// `silent: true` and an `onRawComplete` callback collects the raw text.
/// We parse, sanity-check, and write through `UserModelStore`.
///
/// When this runs:
/// - On app launch (a few seconds after overlay wiring) if the cached
///   model is older than `refreshStalenessSeconds`.
/// - Every `refreshEveryUserTurns` completed user turns so the model
///   keeps up with new topics.
/// - On explicit "refresh" from the Settings pane.
///
/// Skipped cleanly when:
/// - `ChatSession` is already streaming (the refresh would queue behind
///   an in-flight turn and feel laggy; try again next cycle).
/// - `MemoryStore` has < 3 entries (nothing to synthesise; falling
///   back to the raw `[memory]` block produces a better first turn).
@MainActor
final class UserModelSynthesiser {

    /// Weak pointer to the primary synthesiser so the Settings pane can
    /// trigger `forceRefresh()` without threading a reference through
    /// SwiftUI. Set once from `OverlayController` on the primary screen.
    static weak var shared: UserModelSynthesiser?

    private weak var session: ChatSession?
    private weak var memory: MemoryStore?
    private let store: UserModelStore
    private var turnCountObserver: NSObjectProtocol?
    private var inFlight = false

    /// Minimum memory-entry count before we bother synthesising. On a
    /// fresh install the raw memory block is more useful than an empty
    /// model — skip until enough signal accumulates.
    private let minEntriesForSynthesis = 3
    /// Seconds before the cached model is considered stale enough to
    /// refresh proactively. 24h strikes a balance between freshness and
    /// not burning tokens every launch.
    private let refreshStalenessSeconds: TimeInterval = 24 * 3_600

    init(
        session: ChatSession,
        memory: MemoryStore,
        store: UserModelStore
    ) {
        self.session = session
        self.memory = memory
        self.store = store
    }

    // MARK: - Public triggers

    /// Called from `OverlayController` a few seconds after launch. Does
    /// nothing if the cache is fresh or memory is too thin.
    func refreshIfStale() {
        guard shouldSynthesise(force: false) else { return }
        kickSynthesis()
    }

    /// User-initiated refresh (Settings → How Max sees you → Refresh).
    /// Runs even if the cache is fresh; still skipped when a chat turn
    /// is in flight to avoid stomping it.
    func forceRefresh() {
        guard shouldSynthesise(force: true) else { return }
        kickSynthesis()
    }

    // MARK: - Gating

    private func shouldSynthesise(force: Bool) -> Bool {
        guard !inFlight else { return false }
        guard let session, !session.isStreaming else { return false }
        guard let memory, memory.entries.count >= minEntriesForSynthesis else {
            return false
        }
        // Don't ship raw memory to a non-local backend without explicit
        // consent. Synthesis sends the last 60 memory entries to the
        // agent — if those entries contain anything private (and they
        // routinely do), an OpenAI-compat URL pointing at a cloud
        // provider quietly exfiltrates them. The Claude Code subprocess
        // path is inherently local-only, so we only need to guard the
        // HTTP case.
        let s = SettingsStore.shared.settings
        if s.backendType == .openAIHTTP, !Self.isLocalEndpoint(s.openAIBaseURL) {
            if !Prefs.allowNonLocalSynthesis {
                AppLog.memory.notice("user-model synthesis skipped: non-local backend and Prefs.allowNonLocalSynthesis is off")
                return false
            }
        }
        if force { return true }
        return store.ageSeconds >= refreshStalenessSeconds
    }

    /// Is this URL pointing at a loopback / local address? Belt-and-
    /// braces: we compare both textually (fast path for the common
    /// `http://127.0.0.1:…` default) and via `URL.host` (handles the
    /// rare `http://localhost:…` and IPv6 loopback). If parsing fails
    /// we fall back to "not local" — safer to skip than leak.
    private static func isLocalEndpoint(_ urlString: String) -> Bool {
        if urlString.contains("127.0.0.1") { return true }
        if urlString.contains("localhost") { return true }
        if urlString.contains("[::1]") { return true }
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else {
            return false
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    // MARK: - Synthesis

    private func kickSynthesis() {
        guard let session, let memory else { return }
        inFlight = true
        let prompt = buildPrompt(memory: memory, priorModel: store.model)
        session.send(prompt, silent: true) { [weak self] rawReply in
            Task { @MainActor in self?.handleReply(rawReply) }
        }
    }

    private func handleReply(_ raw: String) {
        defer { inFlight = false }
        guard let parsed = Self.parseUserModel(from: raw) else {
            AppLog.memory.error("user-model synthesis returned unparseable response (\(raw.count) chars)")
            return
        }
        store.replace(with: parsed)
        AppLog.memory.notice("user model refreshed: \(parsed.preferences.count) prefs, \(parsed.runningThreads.count) threads, \(parsed.rituals.count) rituals")
    }

    // MARK: - Prompt construction

    private func buildPrompt(memory: MemoryStore, priorModel: UserModel) -> String {
        // Pull a generous slice of memory — the agent picks the signal.
        // Capped so a runaway JSONL doesn't blow the context window.
        let recent = memory.recent(limit: 60)
        let lines = recent.map { $0.promptLine() }.joined(separator: "\n")

        let priorHint: String
        if !priorModel.isEmpty {
            let prior = priorModel.promptBlock()
            priorHint = """

            Your previous model-of-them (use as a starting point — keep what's still true, update what's changed):
            \(prior)
            """
        } else {
            priorHint = ""
        }

        return """
        [internal — user_model synthesis]
        This turn is NOT shown to the user. Your prose will be discarded \
        except for the single JSON object I'm asking you to emit. Do NOT \
        emit any action blocks. Do NOT write prose outside the JSON.

        Task: distill the raw memory entries below into a structured \
        model-of-the-user. Output exactly ONE JSON object (no code fence, \
        no prefix prose) matching this shape:

        {
          "identity": {
            "role": "<short phrase — what the user does / is>",
            "stack": "<languages / tools / frameworks seen in their work>",
            "timezone": "<best guess from time-of-day signals>",
            "communication": "<terse/verbose, playful/formal, welcomes-roasts, etc.>"
          },
          "preferences": [
            { "pref": "<single observed preference>", "confidence": "low|medium|high", "evidence_count": <int ≥ 1> }
          ],
          "running_threads": [
            { "topic": "<short title>", "last_touched": "<ISO8601 date>", "status": "in_flight|parked|done" }
          ],
          "rituals": [
            { "name": "<short>", "pattern": "<free-form description>" }
          ],
          "recent_mood_signal": "<one short phrase about tone observed in recent entries>"
        }

        Rules:
        - Empty arrays are fine. Only include fields with actual evidence \
          in the memory below. Don't invent.
        - `confidence: high` only when multiple memory lines point the \
          same way; otherwise `medium` or `low`.
        - `last_touched` defaults to the most recent memory entry date \
          that references the thread.
        - If memory is thin, emit an object with mostly-empty fields \
          rather than guessing.

        Raw memory entries (most recent last):
        \(lines)
        \(priorHint)

        Emit the JSON now.
        """
    }

    // MARK: - Parsing

    /// Tolerant parse — the agent sometimes wraps JSON in prose or a code
    /// fence despite the instructions. Extract the first `{...}` block
    /// and decode from there. Returns nil on any failure so the caller
    /// leaves the cache untouched.
    static func parseUserModel(from raw: String) -> UserModel? {
        guard let jsonString = extractFirstJSONObject(from: raw),
              let data = jsonString.data(using: .utf8)
        else { return nil }

        // The synthesis prompt uses snake_case — match that in the
        // decoder so Swift's camelCase Codable defaults work cleanly.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        // Dictionary decode first so missing fields fall back to our empty
        // defaults — the agent sometimes omits sections it has no evidence
        // for, which is fine.
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var model = UserModel.empty

        if let identity = obj["identity"] as? [String: Any] {
            model.identity = UserModel.Identity(
                role: identity["role"] as? String ?? "",
                stack: identity["stack"] as? String ?? "",
                timezone: identity["timezone"] as? String ?? "",
                communication: identity["communication"] as? String ?? ""
            )
        }
        if let prefs = obj["preferences"] as? [[String: Any]] {
            model.preferences = prefs.compactMap { dict in
                guard let pref = dict["pref"] as? String, !pref.isEmpty else { return nil }
                let confRaw = dict["confidence"] as? String ?? "medium"
                let conf = UserModel.Preference.Confidence(rawValue: confRaw) ?? .medium
                let count = dict["evidence_count"] as? Int ?? 1
                return UserModel.Preference(pref: pref, confidence: conf, evidenceCount: max(1, count))
            }
        }
        if let threads = obj["running_threads"] as? [[String: Any]] {
            let iso = ISO8601DateFormatter()
            model.runningThreads = threads.compactMap { dict in
                guard let topic = dict["topic"] as? String, !topic.isEmpty else { return nil }
                let dateStr = dict["last_touched"] as? String ?? ""
                let lastTouched = iso.date(from: dateStr) ?? Date()
                let statusRaw = dict["status"] as? String ?? "in_flight"
                let status = UserModel.RunningThread.Status(rawValue: statusRaw) ?? .inFlight
                return UserModel.RunningThread(topic: topic, lastTouched: lastTouched, status: status)
            }
        }
        if let rituals = obj["rituals"] as? [[String: Any]] {
            model.rituals = rituals.compactMap { dict in
                guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
                let pattern = dict["pattern"] as? String ?? ""
                return UserModel.Ritual(name: name, pattern: pattern)
            }
        }
        if let mood = obj["recent_mood_signal"] as? String {
            model.recentMoodSignal = mood
        }
        return model
    }

    /// Pick out the first top-level `{...}` block from a streamed reply.
    /// Handles agents that wrap the JSON in prose or code fences.
    private static func extractFirstJSONObject(from raw: String) -> String? {
        var depth = 0
        var startIndex: String.Index?
        var inString = false
        var escape = false
        for idx in raw.indices {
            let c = raw[idx]
            if escape { escape = false; continue }
            if c == "\\" { escape = true; continue }
            if c == "\"" { inString.toggle(); continue }
            if inString { continue }
            if c == "{" {
                if depth == 0 { startIndex = idx }
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0, let start = startIndex {
                    return String(raw[start...idx])
                }
            }
        }
        return nil
    }
}
