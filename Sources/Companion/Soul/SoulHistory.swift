import Foundation
import Observation

/// One entry in Max's soul revision log. A snapshot of the soul that was
/// live before a patch was accepted, paired with the rationale Max gave
/// for the change so the user can remember why they clicked Accept.
struct SoulVersion: Codable, Identifiable, Equatable {
    let id: UUID
    let appliedAt: Date
    /// Rationale from the accepted proposal (if any). Empty for manual
    /// edits the user makes directly in Settings.
    let rationale: String
    /// The patch text that was appended. Also empty for manual edits.
    let patch: String
    /// The FULL system prompt as it was BEFORE this patch — the thing to
    /// restore to if the user reverts.
    let priorPrompt: String

    init(
        id: UUID = UUID(),
        appliedAt: Date = Date(),
        rationale: String,
        patch: String,
        priorPrompt: String
    ) {
        self.id = id
        self.appliedAt = appliedAt
        self.rationale = rationale
        self.patch = patch
        self.priorPrompt = priorPrompt
    }
}

/// App-global history of soul mutations. Written alongside the soul-patch
/// queue. Caps at the last 50 entries so the file doesn't grow unbounded.
@Observable
@MainActor
final class SoulHistory {
    static let shared = SoulHistory()

    private(set) var entries: [SoulVersion] = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let cap = 50

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
        self.fileURL = dir.appendingPathComponent("soul_history.json")
        load()
    }

    /// Push a new snapshot. Called from `SoulPatchQueue.accept` BEFORE the
    /// new prompt is written, so `priorPrompt` captures the pre-patch state.
    func snapshot(rationale: String, patch: String, priorPrompt: String) {
        entries.insert(
            SoulVersion(rationale: rationale, patch: patch, priorPrompt: priorPrompt),
            at: 0
        )
        if entries.count > cap {
            entries = Array(entries.prefix(cap))
        }
        save()
    }

    /// Revert the live soul to a prior snapshot. The user triggers this
    /// from Settings → Soul History. Posts `companionSoulChanged` so open
    /// ChatSessions flush their cached client.
    @discardableResult
    func revert(to id: UUID) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        // Before reverting, snapshot the CURRENT state too so revert-of-
        // revert works naturally. Rationale marks this as a rollback.
        let current = SettingsStore.shared.settings.systemPrompt
        entries.insert(
            SoulVersion(
                rationale: "Reverted to snapshot from \(formatted(entry.appliedAt))",
                patch: "",
                priorPrompt: current
            ),
            at: 0
        )
        if entries.count > cap {
            entries = Array(entries.prefix(cap))
        }
        save()

        var snap = SettingsStore.shared.settings
        snap.systemPrompt = entry.priorPrompt
        SettingsStore.shared.settings = snap
        NotificationCenter.default.post(name: .companionSoulChanged, object: nil)
        return true
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            entries = try decoder.decode([SoulVersion].self, from: data)
        } catch {
            AppLog.soul.error("history decode failure: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(entries)
        } catch {
            AppLog.soul.error("history encode failure: \(error.localizedDescription, privacy: .public)")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLog.soul.error("history write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func formatted(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}
