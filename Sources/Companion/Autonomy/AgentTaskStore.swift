import Foundation

/// One self-assigned task Max has given himself. Persisted so the list
/// survives sleep / relaunch; the whole point of the agent lifecycle is
/// that Max accumulates work he wants to do across sessions, not just
/// within one tick.
struct AgentTask: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// When the task was first added.
    let createdAt: Date
    /// Last time the state changed (picked up, deferred, completed).
    var updatedAt: Date
    /// Short human-readable description — "review yesterday's commit",
    /// "follow up on the refactor thread", etc. Agent-written; short.
    var summary: String
    /// Where the task came from. Helps the agent reason about priority
    /// and whether it's still relevant.
    var origin: Origin
    /// Agent-visible priority, 0–100. Higher = do sooner. Defaults to 50.
    var priority: Int
    /// Current state. Tasks don't get deleted — they get marked done so
    /// Max can see his own history.
    var status: Status

    enum Origin: String, Codable, Sendable {
        /// The agent added it during a plan phase.
        case selfGenerated = "self"
        /// A user message or explicit "remind me" call produced it.
        case user
        /// Survey phase detected something (new commit, unfinished thread).
        case survey
    }

    enum Status: String, Codable, Sendable {
        case pending
        case inflight
        case done
        case deferred
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        summary: String,
        origin: Origin,
        priority: Int = 50,
        status: Status = .pending
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.summary = summary
        self.origin = origin
        self.priority = priority
        self.status = status
    }
}

/// Append-only-ish persistent task list. Lives per-cwd next to the
/// memory store so different projects have different queues — the
/// tasks Max is tracking for an iOS side project aren't relevant when
/// he wakes up in a Rust server repo.
///
/// The file is a plain JSON array. Small enough (sub-KB for most
/// realistic sizes) that full rewrite on every mutation is fine; no
/// need for the JSONL append pattern MemoryStore uses.
@Observable
@MainActor
final class AgentTaskStore {

    private(set) var tasks: [AgentTask] = []

    @ObservationIgnored let cwd: String
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let encoder: JSONEncoder
    @ObservationIgnored private let decoder: JSONDecoder
    @ObservationIgnored private let writeQueue = DispatchQueue(
        label: "companion.agent_tasks.writes",
        qos: .utility
    )

    init(cwd: String) {
        self.cwd = cwd
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        self.fileURL = Self.locate(cwd: cwd)
        loadFromDisk()
    }

    // MARK: - CRUD

    /// Add a new task. Called by the lifecycle's plan phase when the
    /// agent emits `enqueue_task` action blocks, or by survey when it
    /// detects new work.
    @discardableResult
    func add(summary: String, origin: AgentTask.Origin, priority: Int = 50) -> AgentTask {
        let task = AgentTask(
            summary: summary,
            origin: origin,
            priority: max(0, min(100, priority))
        )
        tasks.append(task)
        save()
        return task
    }

    /// Mark a task as in-flight (lifecycle just picked it as the next
    /// thing to work on). Kept explicit so concurrent work phases
    /// don't grab the same task twice.
    func claim(id: UUID) {
        updateStatus(id: id, to: .inflight)
    }

    func complete(id: UUID) {
        updateStatus(id: id, to: .done)
    }

    func defer_(id: UUID) {
        updateStatus(id: id, to: .deferred)
    }

    private func updateStatus(id: UUID, to newStatus: AgentTask.Status) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].status = newStatus
        tasks[idx].updatedAt = Date()
        save()
    }

    // MARK: - Queries

    /// Next task to work on, by priority then age. Skips in-flight /
    /// done / deferred. Nil when the queue is empty.
    func nextPending() -> AgentTask? {
        tasks
            .filter { $0.status == .pending }
            .sorted { a, b in
                if a.priority != b.priority { return a.priority > b.priority }
                return a.createdAt < b.createdAt
            }
            .first
    }

    /// Compact one-line summary of the current queue for the agent's
    /// next plan prompt. Shows at most the top 5 pending items so the
    /// prompt doesn't balloon as the queue grows.
    func promptSummary() -> String {
        let pending = tasks
            .filter { $0.status == .pending }
            .sorted { $0.priority > $1.priority }
            .prefix(5)
        if pending.isEmpty { return "" }
        var lines = ["Your current self-assigned tasks:"]
        for t in pending {
            let sanitised = EnvironmentSensors.sanitiseForPrompt(t.summary)
            lines.append("  [\(t.priority)] \(sanitised)")
        }
        return lines.joined(separator: "\n")
    }

    /// Recent completions — used by survey to decide if the agent has
    /// been active enough to skip a plan phase this tick.
    func recentlyCompleted(within seconds: TimeInterval = 900) -> [AgentTask] {
        let cutoff = Date().addingTimeInterval(-seconds)
        return tasks.filter { $0.status == .done && $0.updatedAt > cutoff }
    }

    /// Prune very old done tasks. Keeps the file bounded without losing
    /// recent history. Called opportunistically from save().
    private func prune() {
        let cutoff = Date().addingTimeInterval(-60 * 86_400)  // 60 days
        tasks.removeAll { $0.status == .done && $0.updatedAt < cutoff }
    }

    // MARK: - Persistence

    private static func locate(cwd: String) -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        // Reuse the memory directory layout so each project has a single
        // data root: memory entries, user model, time capsules, AND
        // tasks all live under the same hash dir for that cwd.
        let hash = AgentTaskStore.cwdHash(cwd)
        let dir = appSupport
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent(hash, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agent_tasks.json")
    }

    private static func cwdHash(_ cwd: String) -> String {
        // Deliberately simple — we just need a stable filesystem-safe
        // suffix. SHA-256 is overkill but matches what MemoryStore does,
        // so both files land in the same directory.
        var hasher = Hasher()
        hasher.combine(cwd)
        let v = UInt64(bitPattern: Int64(hasher.finalize()))
        return String(format: "%016llx", v)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            tasks = try decoder.decode([AgentTask].self, from: data)
        } catch {
            AppLog.memory.error("agent task decode failure: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        prune()
        let snapshot = tasks
        let url = fileURL
        let enc = encoder
        writeQueue.async {
            do {
                let data = try enc.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                Task { @MainActor in
                    AppLog.memory.error("agent task write failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
