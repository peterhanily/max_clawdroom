import Foundation

/// Structured model-of-the-user that Max hydrates from raw memory entries
/// and carries into every prompt. Replaces the raw `[memory]` block for
/// sessions that have one synthesised — see `UserModelSynthesiser`.
///
/// Shape is intentionally narrow:
/// - Identity = things that are true about the user (role, stack, timezone).
/// - Preferences = stated / observed likes and dislikes, each with a
///   confidence hint so Max can hedge when the signal is thin.
/// - RunningThreads = projects / bugs / side threads still in motion;
///   `status` lets Max ignore ones marked done and pick up ones marked
///   parked when the user reopens them.
/// - Rituals = predictable rhythms ("starts ~10am", "wraps ~18:30 with
///   a commit run") — lets Max time his greetings + check-ins.
/// - RecentMoodSignal = free-form short phrase. The one non-structured
///   field, used for tone on the *next* turn only; gets re-synthesised.
///
/// All fields are `var` so the Settings pane can offer direct editing.
struct UserModel: Codable, Equatable {
    var identity: Identity
    var preferences: [Preference]
    var runningThreads: [RunningThread]
    var rituals: [Ritual]
    var recentMoodSignal: String
    /// When the model was last synthesised (or edited). `EnvironmentSensors`
    /// compares against this to decide whether to kick a refresh.
    var refreshedAt: Date
    /// Synthesiser version — bumped when prompt / parsing rules change
    /// materially so older cached models can be invalidated without a
    /// full schema bump.
    var synthesiserVersion: Int

    struct Identity: Codable, Equatable {
        var role: String
        var stack: String
        var timezone: String
        var communication: String
    }

    struct Preference: Codable, Equatable, Identifiable {
        let id: UUID
        var pref: String
        var confidence: Confidence
        var evidenceCount: Int

        enum Confidence: String, Codable, CaseIterable {
            case low, medium, high
        }

        init(
            id: UUID = UUID(),
            pref: String,
            confidence: Confidence = .medium,
            evidenceCount: Int = 1
        ) {
            self.id = id
            self.pref = pref
            self.confidence = confidence
            self.evidenceCount = evidenceCount
        }
    }

    struct RunningThread: Codable, Equatable, Identifiable {
        let id: UUID
        var topic: String
        var lastTouched: Date
        var status: Status

        enum Status: String, Codable, CaseIterable {
            case inFlight     = "in_flight"
            case parked
            case done
        }

        init(
            id: UUID = UUID(),
            topic: String,
            lastTouched: Date = Date(),
            status: Status = .inFlight
        ) {
            self.id = id
            self.topic = topic
            self.lastTouched = lastTouched
            self.status = status
        }
    }

    struct Ritual: Codable, Equatable, Identifiable {
        let id: UUID
        var name: String
        /// Free-form — "~09:00-10:30 local", "usually commits between 18:00 and 19:00".
        /// Intentionally not parsed: the agent interprets it on read, and
        /// the user can write it any way they like.
        var pattern: String

        init(id: UUID = UUID(), name: String, pattern: String) {
            self.id = id
            self.name = name
            self.pattern = pattern
        }
    }

    static let currentSynthesiserVersion: Int = 1

    static let empty = UserModel(
        identity: Identity(role: "", stack: "", timezone: "", communication: ""),
        preferences: [],
        runningThreads: [],
        rituals: [],
        recentMoodSignal: "",
        refreshedAt: .distantPast,
        synthesiserVersion: UserModel.currentSynthesiserVersion
    )

    /// True when we have effectively no info — lets callers fall back to
    /// the raw `[memory]` block so Max isn't reasoning from an empty
    /// skeleton on the first install.
    var isEmpty: Bool {
        identity.role.isEmpty
            && identity.stack.isEmpty
            && preferences.isEmpty
            && runningThreads.isEmpty
            && rituals.isEmpty
    }

    /// `[you]` block rendered into the system prompt. Compact JSON keeps
    /// the token cost tight; the agent sees structure and can reason
    /// directly about specific fields.
    func promptBlock() -> String {
        guard !isEmpty else { return "" }

        let dateFmt = ISO8601DateFormatter()
        dateFmt.formatOptions = [.withInternetDateTime]

        var obj: [String: Any] = [:]
        let ident: [String: String] = [
            "role": identity.role,
            "stack": identity.stack,
            "timezone": identity.timezone,
            "communication": identity.communication
        ].filter { !$0.value.isEmpty }
        if !ident.isEmpty { obj["identity"] = ident }

        if !preferences.isEmpty {
            obj["preferences"] = preferences.map { p -> [String: Any] in
                [
                    "pref": p.pref,
                    "confidence": p.confidence.rawValue,
                    "evidence_count": p.evidenceCount
                ]
            }
        }
        if !runningThreads.isEmpty {
            obj["running_threads"] = runningThreads.map { t -> [String: Any] in
                [
                    "topic": t.topic,
                    "last_touched": dateFmt.string(from: t.lastTouched),
                    "status": t.status.rawValue
                ]
            }
        }
        if !rituals.isEmpty {
            obj["rituals"] = rituals.map { r -> [String: Any] in
                ["name": r.name, "pattern": r.pattern]
            }
        }
        if !recentMoodSignal.isEmpty {
            obj["recent_mood_signal"] = recentMoodSignal
        }
        let data = (try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return "[you]\n\(json)"
    }
}
