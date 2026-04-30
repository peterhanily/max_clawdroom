import Combine
import Foundation

/// App-global observer of user-driven preference changes. Logs each flip
/// (gravity, voice source/id/filter, autonomy, mode) with a timestamp,
/// caps the log at the last N events, and exposes an aggregated
/// `[observed_preferences]` block for injection into Max's system prompt.
///
/// The value of this isn't replacing UserDefaults — it's giving Max a
/// longitudinal view of the user's behaviour so he can notice patterns
/// ("you've flipped to Kokoro 7 of the last 10 launches") and, per the
/// soul-patch guardrails, propose durable personality changes grounded
/// in those patterns instead of assumption.
@MainActor
final class PreferenceLearner: ObservableObject {
    static let shared = PreferenceLearner()

    struct Event: Codable, Equatable {
        let key: String
        let value: String
        let at: Date
    }

    private(set) var events: [Event] = []
    private let cap = 200
    private let fileURL: URL
    private var observers: [NSObjectProtocol] = []

    private init() {
        let fm = FileManager.default
        let base = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = (base ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support"))
            .appendingPathComponent("Companion", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("pref_log.json")
        load()
        attachObservers()
    }

    /// Called once at app startup by the owning controller so the learner
    /// actually wires up (singletons don't auto-init until first access).
    func start() { /* init did the wiring */ }

    private func attachObservers() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: .companionGravityChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.record(key: "gravity", value: Prefs.gravityEnabled ? "on" : "off")
            }
        })
        observers.append(nc.addObserver(
            forName: .companionVoiceChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Voice is a trio — log whichever field best describes this
                // event. Coalesce rapid fire via a short dedup window.
                self.record(key: "voice_enabled", value: Prefs.voiceEnabled ? "on" : "off")
                self.record(key: "voice_max_filter", value: Prefs.voiceMaxFilter ? "on" : "off")
                if let id = Prefs.voiceID, !id.isEmpty {
                    self.record(key: "voice_id", value: id)
                }
            }
        })
        observers.append(nc.addObserver(
            forName: .companionAutonomyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.record(key: "autonomy", value: Prefs.autonomyEnabled ? "on" : "off")
            }
        })
        observers.append(nc.addObserver(
            forName: .companionModeChanged, object: nil, queue: .main
        ) { [weak self] note in
            // Extract the primitives out of `note` before hopping actors —
            // Notification isn't Sendable, so sending it into a @MainActor
            // Task would fail strict concurrency. Strings are fine.
            let raw = note.userInfo?["mode"] as? String
            let pinned = (note.userInfo?["pinned"] as? Bool) ?? false
            guard let raw else { return }
            Task { @MainActor in
                self?.record(key: "mode", value: pinned ? raw : "auto:\(raw)")
            }
        })
    }

    isolated deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Write

    private func record(key: String, value: String) {
        // Coalesce: if the most-recent event for this key has the same
        // value AND is < 2s old, drop it. Keeps rapid-fire menu-bar
        // interactions from generating a flood of identical records.
        if let last = events.last(where: { $0.key == key }) {
            if last.value == value, Date().timeIntervalSince(last.at) < 2 {
                return
            }
        }
        events.append(Event(key: key, value: value, at: Date()))
        if events.count > cap {
            events = Array(events.suffix(cap))
        }
        save()
    }

    // MARK: - Summarise

    /// One-line-per-key aggregate of the N most recent events. Included
    /// in Max's system prompt so he can spot patterns. Empty string when
    /// there's nothing notable to say (< 3 total events).
    func promptBlock() -> String {
        guard events.count >= 3 else { return "" }
        var lines: [String] = []
        let keys = Array(Set(events.map(\.key))).sorted()
        for key in keys {
            let keyEvents = events.filter { $0.key == key }
            guard keyEvents.count >= 2 else { continue }
            // Tally value frequencies over the whole history and over the
            // last 10 events separately — the "last 10" view catches
            // recent-shift patterns the whole-history view drowns out.
            let all = tally(keyEvents)
            let recent = tally(Array(keyEvents.suffix(10)))
            let summary = format(key: key, all: all, recent: recent, total: keyEvents.count)
            if !summary.isEmpty { lines.append(summary) }
        }
        guard !lines.isEmpty else { return "" }
        return "=== Observed preferences ===\n" + lines.joined(separator: "\n")
    }

    private func tally(_ events: [Event]) -> [(value: String, count: Int)] {
        var map: [String: Int] = [:]
        for e in events { map[e.value, default: 0] += 1 }
        return map.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    private func format(
        key: String,
        all: [(value: String, count: Int)],
        recent: [(value: String, count: Int)],
        total: Int
    ) -> String {
        guard let top = all.first else { return "" }
        let pct = Int(Double(top.count) / Double(total) * 100)
        // If recent strongly diverges from all-time, flag both.
        if
            let recentTop = recent.first,
            recentTop.value != top.value,
            recentTop.count >= 4
        {
            return "• \(key): was mostly \(top.value) (\(pct)% of \(total)), but recently \(recentTop.value) (\(recentTop.count) of last 10)"
        }
        return "• \(key): \(top.value) (\(pct)% of \(total))"
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            events = try decoder.decode([Event].self, from: data)
        } catch {
            AppLog.memory.error("PreferenceLearner decode failure: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(events) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
