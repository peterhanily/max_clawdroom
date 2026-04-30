import CryptoKit
import Foundation

/// Per-cwd persistence for chat sessions. Each session lives in its own
/// JSON file under `~/Library/Application Support/Companion/sessions/
/// <cwd-hash>/<uuid>.json` so one project's history is isolated from
/// another's. Debounced writes keep disk churn low during active chat.
///
/// **Encryption:** session JSON contains `[env]` blocks (frontmost app
/// names), `[editor]` blocks (file paths, cursor-line text from the AX
/// API), and the full chat transcript including any code Max read or
/// edited. All of that lands in `EncryptedJSONStore` (AES-GCM, key in
/// Keychain) so another local user, a backup tool, or any process running
/// as the same user can't read past sessions cold. Plaintext fallback
/// only when the Keychain itself is unreachable; legacy plaintext files
/// auto-migrate on next save.
///
/// **Pruning:** on each write we trim the dir to `keepNewest` files and
/// delete anything older than `keepAge`. Without this the dir grew
/// monotonically — every visited cwd, forever. Tunables stay generous
/// (50 files / 180 days) so users keep recent history but ephemeral
/// throwaway projects don't sediment.
@MainActor
final class SessionStore {
    let cwd: String
    private let dir: URL

    private var pendingWriteTask: Task<Void, Never>?
    /// Debounce window: collapse bursts of message appends into one
    /// write. 500ms is tight enough that a crash during streaming loses
    /// at most that much, loose enough to avoid hammering the disk on
    /// token-by-token updates to the streaming assistant message.
    private let debounceSeconds: Double = 0.5

    /// Pruning bounds. Either condition triggers a delete on the next
    /// write — keep the most-recent N files AND drop anything older
    /// than `keepAge`. The intersection is intentional: a user who works
    /// daily in one cwd accumulates lots of recent sessions and we don't
    /// want a per-day prune; a user who pops into a cwd once and never
    /// returns gets cleaned up after six months.
    private let keepNewest: Int = 50
    private let keepAge: TimeInterval = 180 * 86_400

    /// Lazily-loaded at-rest key. Nil only when Keychain is unavailable;
    /// in that case persist falls back to plaintext (logged) so the user
    /// doesn't lose chat history just because Keychain is asleep.
    private let atRestKey: SymmetricKey?

    init(cwd: String) {
        self.cwd = cwd
        self.atRestKey = KeychainStore.loadOrCreateSymmetricKey(account: KeychainStore.atRestKeyAccount)
        let fm = FileManager.default
        let base = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = (base ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support"))
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(Self.hash(cwd), isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Owner-only — the dir holds AES-GCM blobs (and possibly plaintext
        // legacy files mid-migration). Same posture as MemoryStore.
        try? fm.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: root.path
        )
        self.dir = root
    }

    /// Write immediately, flushing any pending debounced write. Called
    /// on explicit save points (session end, session switch).
    func saveNow(_ record: SessionRecord) {
        pendingWriteTask?.cancel()
        pendingWriteTask = nil
        persist(record)
    }

    /// Debounced save — fine for per-token streaming updates.
    func save(_ record: SessionRecord) {
        pendingWriteTask?.cancel()
        pendingWriteTask = Task { [weak self, debounceSeconds] in
            try? await Task.sleep(nanoseconds: UInt64(debounceSeconds * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run {
                self?.persist(record)
            }
        }
    }

    /// List sessions for this cwd, newest first. Returns a lightweight
    /// summary for the picker — caller calls `load(id:)` for the full
    /// record when the user picks one.
    func list(limit: Int = 20) -> [SessionRecord] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let records = files
            .filter { $0.pathExtension == "json" }
            .compactMap { load(url: $0) }
            .sorted { $0.updatedAt > $1.updatedAt }
        return Array(records.prefix(limit))
    }

    /// Most recently-updated record for `channelID`. Pre-channels
    /// records (channelID == nil) are treated as belonging to every
    /// channel — they surface as the "latest" for whichever channel
    /// the user looks under first, so old history isn't orphaned.
    /// Returns nil when no record matches AND no nil-channel records
    /// exist; ChatSession then starts a fresh transcript.
    func latestRecord(forChannel channelID: UUID) -> SessionRecord? {
        let all = list(limit: 50)
        // Prefer a record explicitly tagged with this channel.
        if let exact = all.first(where: { $0.channelID == channelID }) {
            return exact
        }
        // Fall back to a legacy untagged record (oldest-record-first
        // policy intentional: list() is sorted newest-first, so
        // first(where: nil) returns the user's most-recent legacy
        // session — i.e. the one they were probably mid-conversation
        // in before the per-channel work shipped).
        return all.first(where: { $0.channelID == nil })
    }

    /// Load a specific session by its internal UUID.
    func load(id: UUID) -> SessionRecord? {
        let url = dir.appendingPathComponent(id.uuidString + ".json")
        return load(url: url)
    }

    /// Delete a session file permanently.
    func delete(id: UUID) {
        let url = dir.appendingPathComponent(id.uuidString + ".json")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Internal

    private func persist(_ record: SessionRecord) {
        let url = dir.appendingPathComponent(record.id.uuidString + ".json")
        let data: Data
        do {
            if let key = atRestKey {
                data = try EncryptedJSONStore.encode(record, using: key)
            } else {
                // Keychain unavailable — log once, fall back to plaintext
                // so the user doesn't lose chat history. Migrations on
                // subsequent saves (when Keychain comes back) re-encrypt.
                AppLog.session.notice("Keychain unavailable; writing session plaintext (will migrate later)")
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                data = try encoder.encode(record)
            }
        } catch {
            AppLog.session.error("encode failure for \(record.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            // chmod the file itself — the parent dir is 0o700 but the
            // OS default for newly-written files honours umask, which
            // can leak group/other read on weird shells.
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path
            )
        } catch {
            AppLog.session.error("write failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        pruneIfNeeded()
    }

    private func load(url: URL) -> SessionRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Try encrypted load first; fall back to legacy plaintext for
        // pre-encryption files. `tolerantLoad` flags `wasPlaintext` so
        // we know to re-save through the encrypted path.
        guard let key = atRestKey else {
            return decodePlain(data, urlForLog: url)
        }
        if let result = EncryptedJSONStore.tolerantLoad(data, as: SessionRecord.self, using: key) {
            if result.wasPlaintext {
                // Migrate inline — re-save sealed so the plaintext blob
                // is overwritten on the next debounced write. Don't
                // persist here directly to avoid a load→save loop on
                // every list() call; flag via Task so it lands later.
                let record = result.value
                Task { @MainActor [weak self] in
                    self?.persist(record)
                }
            }
            return result.value
        }
        return decodePlain(data, urlForLog: url)
    }

    private func decodePlain(_ data: Data, urlForLog url: URL) -> SessionRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(SessionRecord.self, from: data)
        } catch {
            AppLog.session.error("decode failure for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Drop session files past the keep-newest cap or older than the
    /// keep-age TTL. Cheap — runs after each persist; the dir is small
    /// in the steady state. Errors are logged but never thrown; pruning
    /// failure must never break the save path.
    private func pruneIfNeeded() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let jsons = urls.filter { $0.pathExtension == "json" }
        let dated: [(URL, Date)] = jsons.compactMap { url in
            guard let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return nil }
            return (url, mod)
        }
        let sorted = dated.sorted { $0.1 > $1.1 }     // newest first
        let cutoff = Date().addingTimeInterval(-keepAge)
        var deleted = 0
        for (idx, (url, mod)) in sorted.enumerated() {
            if idx >= keepNewest || mod < cutoff {
                do {
                    try fm.removeItem(at: url)
                    deleted += 1
                } catch {
                    AppLog.session.error("prune delete failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if deleted > 0 {
            AppLog.session.notice("pruned \(deleted, privacy: .public) old sessions in \(self.dir.lastPathComponent, privacy: .public)")
        }
    }

    /// 16 hex chars (64-bit) of SHA-256(cwd). Held at 16 for backward
    /// compatibility with existing on-disk dirs; encryption + 0o700
    /// dir/file modes are the actual confidentiality posture, and the
    /// hash only buys us per-cwd separation. A future major version
    /// can widen to 128-bit with an opportunistic migration path.
    private static func hash(_ path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }
}
