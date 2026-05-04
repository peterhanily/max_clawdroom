import CryptoKit
import Foundation
import Observation

/// Per-project persistent memory. One instance per `cwd` — different
/// projects get separate memory spaces keyed by a stable SHA-256 of
/// the path.
///
/// Storage: JSONL. One entry per line. The file is rewritten atomically
/// on EVERY mutation — append-via-`FileHandle.seekToEnd` was retired
/// because a crash mid-write left torn JSONL lines that the loader
/// silently dropped. Atomic-rewrite is O(N) per write; at the documented
/// size budget (≤ 5 000 entries / ~1 MB) that's a few ms even on slow
/// disks, which the background `writeQueue` absorbs cleanly.
///
/// Pruning: enforced on every append. We cap at `maxEntries` and drop
/// observations older than `observationTTL`. Preferences are immune
/// (latest-write-wins fold below means dead preference rows clutter the
/// file but don't corrupt prompt rendering); journals + observations
/// roll off after the TTL so a year-old "you opened Xcode" is gone.
///
/// Per-turn cap: a chatty / poisoned agent could spam `remember` /
/// `write_journal` calls. The dispatcher in `MaxClawdroomActions` is the
/// gate that enforces this — `MemoryStore` itself is a dumb sink.
///
/// Location: `~/Library/Application Support/Companion/memory/<hash>/entries.jsonl`
///
/// Thread-safety: public mutations called on @MainActor; disk writes
/// hop to a background `writeQueue`, encoded inline on main from the
/// already-immutable in-memory snapshot (no captured-var race).
@Observable
@MainActor
final class MemoryStore {
    @ObservationIgnored let cwd: String
    private(set) var entries: [MemoryEntry] = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let encoder: JSONEncoder
    @ObservationIgnored private let decoder: JSONDecoder
    /// AES-GCM key for at-rest encryption of `entries.jsonl`. nil only
    /// when Keychain is locked / inaccessible at init — the read and
    /// write paths fall back to plaintext with `0o600` perms in that
    /// case (matching the SessionStore pattern). Mirrors the
    /// `atRestKey` caching SessionStore does so we don't hit Keychain
    /// on every rewrite. The key never leaves this process.
    @ObservationIgnored private let atRestKey: SymmetricKey?
    /// Serial queue for disk writes. Keeps `remember` / `write_journal`
    /// off the main thread — a chatty agent emitting 10+ memory ops per
    /// turn used to hitch the UI while each entry flushed synchronously.
    @ObservationIgnored private let writeQueue = DispatchQueue(label: "companion.memorystore.writes", qos: .utility)

    /// Hard cap on retained entries. Preferences excluded — they're
    /// keyed (latest-write-wins) so the count stays bounded by the
    /// preference key cardinality. Observations / journals / topics
    /// can grow unbounded across years, so this is the cap that
    /// matters in practice.
    @ObservationIgnored private let maxEntries: Int = 5_000
    /// Age cap for observations + journal entries. Anything older falls
    /// off on the next append. Preferences and topic anchors are kept
    /// regardless (they accrete meaning with age).
    @ObservationIgnored private let observationTTL: TimeInterval = 365 * 86_400

    init(cwd: String) {
        self.cwd = cwd

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        self.atRestKey = KeychainStore.loadOrCreateSymmetricKey(
            account: KeychainStore.atRestKeyAccount
        )

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
        // Restrict to owner-only. Memory entries can contain anything
        // the user discussed with Max (API keys, passwords,
        // private project notes), so world-readable or group-readable
        // defaults are a real exfiltration surface on shared machines.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: dir.path
        )
        return dir.appendingPathComponent("entries.jsonl")
    }

    // MARK: - Load / save

    private func loadFromDisk() {
        guard let blob = try? Data(contentsOf: fileURL) else { return }

        // Resolve the on-disk bytes to JSONL plaintext. With a key, try
        // the encrypted envelope first; on failure (or no key), fall
        // back to legacy plaintext bytes. `tolerantLoadData` returns nil
        // only when the file LOOKS like a corrupted envelope — better
        // to refuse than feed envelope JSON to the JSONL parser.
        let data: Data
        if let key = atRestKey {
            guard let result = EncryptedJSONStore.tolerantLoadData(blob, using: key) else {
                AppLog.memory.error("\(self.fileURL.lastPathComponent, privacy: .public) looks like a corrupted envelope; refusing to parse as JSONL")
                return
            }
            data = result.value
            if result.wasPlaintext {
                AppLog.memory.notice("\(self.fileURL.lastPathComponent, privacy: .public) is legacy plaintext; will re-save sealed on next write")
            }
        } else {
            data = blob
        }

        guard let text = String(data: data, encoding: .utf8) else { return }
        var skipped = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let d = line.data(using: .utf8) else { continue }
            do {
                let entry = try decoder.decode(MemoryEntry.self, from: d)
                entries.append(entry)
            } catch {
                skipped += 1
                // Log first few failures; truncate line preview so a
                // corrupted megabyte-long entry doesn't blow the log.
                if skipped <= 3 {
                    let preview = String(line.prefix(200))
                    AppLog.memory.error("decode failure in \(self.fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public) (line: \(preview, privacy: .public))")
                }
            }
        }
        if skipped > 3 {
            AppLog.memory.error("\(skipped - 3) additional decode failures suppressed in \(self.fileURL.lastPathComponent, privacy: .public)")
        }
    }

    /// Atomic full-rewrite of the JSONL file. Replaces the prior
    /// `FileHandle.seekToEnd + write` path which left torn lines on
    /// crash mid-write. Encoding runs on main from the snapshotted
    /// in-memory array (cheap — entries are tiny); the actual disk
    /// write hops to `writeQueue` so the UI never blocks even when
    /// the agent fires a burst.
    private func appendToDisk(_ entry: MemoryEntry) {
        // The in-memory `entries` array is the source of truth. Rewrite
        // the whole file from it — the parameter is kept for ABI clarity
        // (the caller has already appended) but its bytes are not used.
        _ = entry
        rewriteDisk()
    }

    /// Rewrite the whole file from the in-memory array. Used by remove.
    /// Encode inline, seal under `atRestKey` if available (legacy
    /// plaintext callers / locked-Keychain installs fall through to
    /// raw JSONL with 0o600). Disk write hops to `writeQueue`.
    private func rewriteDisk() {
        var buffer = Data()
        for entry in entries {
            guard let d = try? encoder.encode(entry) else { continue }
            buffer.append(d)
            buffer.append(0x0A)
        }
        let plaintext = buffer

        // Seal under the at-rest key when we have one. On encrypt
        // failure, fall back to plaintext rather than dropping the
        // write — the user still gets owner-only file perms and the
        // SessionStore precedent treats this as the safe degradation
        // path. Logged loudly so the failure is visible in Console.
        let payload: Data
        if let key = atRestKey {
            do {
                payload = try EncryptedJSONStore.sealData(plaintext, using: key)
            } catch {
                AppLog.memory.error("seal failed for \(self.fileURL.lastPathComponent, privacy: .public); writing plaintext: \(error.localizedDescription, privacy: .public)")
                payload = plaintext
            }
        } else {
            payload = plaintext
        }

        let url = fileURL
        writeQueue.async {
            do {
                try payload.write(to: url, options: .atomic)
                // chmod the file owner-only so a wide umask doesn't leak
                // memory contents to group/other readers.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o600))],
                    ofItemAtPath: url.path
                )
            } catch {
                AppLog.memory.error("rewrite failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Public mutations

    @discardableResult
    func append(_ entry: MemoryEntry) -> MemoryEntry {
        entries.append(entry)
        pruneIfNeeded()
        appendToDisk(entry)
        return entry
    }

    /// Drop expired observations + journals and trim the total entry
    /// count to `maxEntries`. Preferences and topic anchors are kept.
    /// Idempotent — safe to call before every write.
    private func pruneIfNeeded() {
        let cutoff = Date().addingTimeInterval(-observationTTL)
        let beforeAge = entries.count
        entries.removeAll { entry in
            // Preferences are immune (latest-write-wins; folded by key).
            // Topics anchor running threads that span months, so keep
            // those too — only observations + journals age out.
            switch entry.kind {
            case .preference, .topic:
                return false
            case .observation, .journal:
                return entry.timestamp < cutoff
            }
        }
        let agedOff = beforeAge - entries.count

        // Total cap. Drop oldest non-preference entries first; keep
        // preferences regardless because they encode current truth.
        if entries.count > maxEntries {
            let overflow = entries.count - maxEntries
            var dropped = 0
            // Walk from the front (oldest) and drop non-preference rows
            // until we're under the cap.
            entries.removeAll { entry in
                guard dropped < overflow else { return false }
                if entry.kind == .preference || entry.kind == .topic { return false }
                dropped += 1
                return true
            }
            if dropped > 0 {
                AppLog.memory.notice("pruned \(dropped, privacy: .public) entries (cap)")
            }
        }
        if agedOff > 0 {
            AppLog.memory.notice("pruned \(agedOff, privacy: .public) entries (age TTL)")
        }
    }

    /// Remove one entry by id. Returns the removed entry so callers
    /// (e.g. undo stack) can re-append it if reverting.
    @discardableResult
    func remove(id: UUID) -> MemoryEntry? {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = entries.remove(at: idx)
        rewriteDisk()
        return removed
    }

    /// Remove all entries whose `text` contains `needle` (case-insensitive).
    /// Returns the removed entries for undo.
    @discardableResult
    func removeMatching(_ needle: String) -> [MemoryEntry] {
        let lower = needle.lowercased()
        let matches = entries.filter { $0.text.lowercased().contains(lower) }
        guard !matches.isEmpty else { return [] }
        entries.removeAll { matches.contains($0) }
        rewriteDisk()
        return matches
    }

    // MARK: - Queries

    /// Most-recent `limit` entries (oldest to newest).
    func recent(limit: Int = 20) -> [MemoryEntry] {
        Array(entries.suffix(limit))
    }

    /// Latest-write-wins fold of all `.preference` entries.
    func preferences() -> [String: String] {
        var out: [String: String] = [:]
        for entry in entries where entry.kind == .preference {
            if let key = entry.key {
                out[key] = entry.text
            }
        }
        return out
    }

    // MARK: - Prompt rendering

    /// Returns the `[memory]` block to inject into the system prompt.
    /// Empty string when there are no entries worth showing.
    ///
    /// Every user-controlled string (preference keys + values, observation
    /// text, journal entries) runs through `EnvironmentSensors.sanitiseForPrompt`
    /// before it lands in the prompt. The agent itself writes memory via
    /// `remember` / `set_preference`, so an adversarial turn can inject
    /// `[action]`-lookalikes, `[env]`/`[memory]` harness-tag lookalikes, or
    /// raw newlines that break out of the single-line `• key = value` format
    /// and look like fresh directives on the next line. The sanitiser
    /// defangs all of that.
    func formattedForPrompt(limit: Int = 25) -> String {
        guard !entries.isEmpty else { return "" }

        // Combine: all preferences (rolled up) + the N most-recent other
        // entries. Preferences are terse and always relevant; observations
        // / journal / topic trail by recency.
        let prefs = preferences()
        let nonPrefTail = entries
            .filter { $0.kind != .preference }
            .suffix(limit)

        var lines: [String] = []
        lines.append("=== Memory for this project (\(abbreviateCWD(cwd))) ===")

        if !prefs.isEmpty {
            lines.append("User preferences you've recorded:")
            for (k, v) in prefs.sorted(by: { $0.key < $1.key }) {
                let safeKey = EnvironmentSensors.sanitiseForPrompt(k)
                let safeVal = EnvironmentSensors.sanitiseForPrompt(v)
                lines.append("  • \(safeKey) = \(safeVal)")
            }
        }

        if !nonPrefTail.isEmpty {
            lines.append("Recent observations / journal / topics (most recent last):")
            for entry in nonPrefTail {
                let safe = EnvironmentSensors.sanitiseForPrompt(entry.promptLine())
                lines.append("  \(safe)")
            }
        }

        lines.append("")
        lines.append("Use these as continuity, not as a script. Don't recite them unprompted. When you notice something worth keeping, call `remember` or `set_preference`.")

        return lines.joined(separator: "\n")
    }

    private func abbreviateCWD(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}
