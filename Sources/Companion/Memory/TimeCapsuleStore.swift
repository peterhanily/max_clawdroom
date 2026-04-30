import CryptoKit
import Foundation
import Observation

// Keychain key lookup is shared across stores — done lazily so the
// cost is incurred only when an encrypted store is actually used, and
// cached so repeated reads don't thrash the Keychain API.
@MainActor
private enum AtRestKey {
    static var cached: SymmetricKey?
    static func get() -> SymmetricKey? {
        if let cached { return cached }
        let key = KeychainStore.loadOrCreateSymmetricKey(
            account: KeychainStore.atRestKeyAccount
        )
        cached = key
        return key
    }
}

/// Persistent append-only log of `TimeCapsule` snapshots, keyed per-cwd
/// next to `UserModelStore` and `MemoryStore`. Auto-captures every
/// ~90 days; manual capture via `captureNow()`.
///
/// Capsules never change after capture — new ones append, stale ones
/// stay put. Users flipping through their history should see the real
/// shape of growth, not an after-the-fact edit.
@Observable
@MainActor
final class TimeCapsuleStore {
    @ObservationIgnored static weak var shared: TimeCapsuleStore?

    private(set) var capsules: [TimeCapsule] = []

    @ObservationIgnored let cwd: String
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let encoder: JSONEncoder
    @ObservationIgnored private let decoder: JSONDecoder
    @ObservationIgnored private let writeQueue = DispatchQueue(
        label: "companion.capsules.writes",
        qos: .utility
    )

    /// Minimum days between auto-captures. 90 is quarterly which feels
    /// right for a retention artefact — enough distance that changes
    /// are visible, short enough that users don't wait a year for
    /// their first one.
    @ObservationIgnored private let autoCaptureIntervalDays: Int = 90

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

    // MARK: - Paths

    private static func locate(cwd: String) -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let hash = SHA256.hash(data: Data(cwd.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let dir = appSupport
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent(hash, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        // Owner-only — capsules snapshot both the UserModel and the
        // literal soul prompt. Treat them with the same care as the
        // raw memory they're derived from.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: dir.path
        )
        return dir.appendingPathComponent("time_capsules.json")
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let key = AtRestKey.get() else {
            // Keychain unavailable — last-resort plaintext fallback so
            // the feature keeps working even on quirky setups.
            if let decoded = try? decoder.decode([TimeCapsule].self, from: data) {
                self.capsules = decoded.sorted { $0.capturedAt < $1.capturedAt }
            }
            return
        }
        guard let loaded = EncryptedJSONStore.tolerantLoad(
            data,
            as: [TimeCapsule].self,
            using: key
        ) else {
            AppLog.memory.error("time capsule decode failure (neither encrypted nor plaintext)")
            return
        }
        self.capsules = loaded.value.sorted { $0.capturedAt < $1.capturedAt }
        // Migrate legacy plaintext files to encrypted form on first
        // read. The save() helper encrypts going forward.
        if loaded.wasPlaintext {
            AppLog.memory.notice("migrating time capsules from plaintext to encrypted")
            save()
        }
    }

    // MARK: - Capture

    /// Trigger to call on app launch. No-op if a recent capsule already
    /// exists within the auto-capture window; otherwise grabs a fresh
    /// snapshot from the live stores and appends it.
    func captureIfDue(
        userModel: UserModel,
        soulPrompt: String,
        memory: MemoryStore
    ) {
        if let last = capsules.last {
            let daysSinceLast = Int(Date().timeIntervalSince(last.capturedAt) / 86_400)
            if daysSinceLast < autoCaptureIntervalDays { return }
        }
        captureNow(userModel: userModel, soulPrompt: soulPrompt, memory: memory)
    }

    /// User-invoked capture from Max's Room "capture now" button.
    func captureNow(
        userModel: UserModel,
        soulPrompt: String,
        memory: MemoryStore
    ) {
        let stats = Self.computeStats(memory: memory)
        let capsule = TimeCapsule(
            userModelSnapshot: userModel,
            soulPrompt: soulPrompt,
            stats: stats
        )
        capsules.append(capsule)
        save()
        AppLog.memory.notice("time capsule captured: \(capsule.id.uuidString, privacy: .public)")
    }

    private static func computeStats(memory: MemoryStore) -> TimeCapsule.Stats {
        // Soul patches applied — read from SoulHistory total.
        let soulPatches = SoulHistory.shared.entries.filter {
            !$0.rationale.hasPrefix("Reverted to snapshot")
        }.count
        // Rituals fired — read the lastFired UserDefaults flags. We don't
        // track per-count, but we can report "has fired" per ritual. A
        // proper counter is a follow-up; for now, count = 1 per ritual
        // that has ever fired.
        let ritualIDs = ["sunday_reflection", "evening_checkout", "anniversary"]
        var ritualCounts: [String: Int] = [:]
        for id in ritualIDs {
            if UserDefaults.standard.object(forKey: "companion.ritual.\(id).last_fired_at") != nil {
                ritualCounts[id] = 1
            }
        }
        return TimeCapsule.Stats(
            memoryEntriesTotal: memory.entries.count,
            soulPatchesApplied: soulPatches,
            rituals: ritualCounts
        )
    }

    // MARK: - Persistence

    private func save() {
        let snapshot = capsules
        let url = fileURL
        // Encryption key lookup is MainActor-bound; capture on the
        // main thread, then hand the sealed bytes to the background
        // queue for the actual write.
        guard let key = AtRestKey.get() else {
            // No key — fall back to plaintext so the capsule isn't lost.
            // We log this so power users know at-rest encryption isn't
            // active on their install.
            let enc = encoder
            writeQueue.async {
                do {
                    let data = try enc.encode(snapshot)
                    try data.write(to: url, options: .atomic)
                } catch {
                    Task { @MainActor in
                        AppLog.memory.error("time capsule write failed (plaintext fallback): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            return
        }
        let sealed: Data
        do {
            sealed = try EncryptedJSONStore.encode(snapshot, using: key)
        } catch {
            AppLog.memory.error("time capsule encrypt failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        writeQueue.async {
            do {
                try sealed.write(to: url, options: .atomic)
            } catch {
                Task { @MainActor in
                    AppLog.memory.error("time capsule write failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
