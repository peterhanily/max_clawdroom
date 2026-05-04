import Foundation
import Combine
import CryptoKit

/// Append-only ledger of every action op the agent dispatched. Lets the
/// user see what Max actually did — memory writes, soul proposals, media
/// downloads, settings mutations, body movement — when, with what args,
/// and whether it touched durable state.
///
/// Wires in passively via `companionAgentAction`, the broadcast
/// `CompanionActions.dispatch` already posts on every op (see
/// CompanionActions.swift:269). No surgery in the dispatcher itself.
///
/// Persistence mirrors `MemoryStore`: one JSONL file under
/// `~/Library/Application Support/Companion/actions/audit.jsonl`,
/// rewritten atomically on each append, owner-only permissions, capped
/// at `entryCap` rows. Cross-project — the audit log is global, not
/// per-cwd, because durable ops (soul patches, settings changes) don't
/// belong to a single repo.
@MainActor
final class ActionAuditLog: ObservableObject {

    /// Single shared instance. Wired up in `AppDelegate` so the observer
    /// is live before any chat session starts streaming.
    static let shared = ActionAuditLog()

    @Published private(set) var entries: [ActionAuditEntry] = []

    private let writeQueue = DispatchQueue(label: "com.peterhanily.max_clawdroom.actions.write", qos: .utility)
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let entryCap = 5_000
    private var observer: NSObjectProtocol?
    /// AES-GCM key for at-rest encryption of `audit.jsonl`. Same key
    /// account as MemoryStore / SessionStore — one at-rest key per
    /// install, multiple stores share it. nil on Keychain miss; the
    /// read/write paths fall back to plaintext + 0o600 in that case.
    private let atRestKey: SymmetricKey?

    private lazy var fileURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("actions", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("audit.jsonl")
    }()

    private init() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        encoder = e
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        decoder = d
        atRestKey = KeychainStore.loadOrCreateSymmetricKey(account: KeychainStore.atRestKeyAccount)
        loadFromDisk()
    }

    /// Begin observing `companionAgentAction`. Idempotent — calling more
    /// than once won't double-register.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .companionAgentAction,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let info = note.userInfo ?? [:]
            let op = (info["op"] as? String) ?? "unknown"
            let args = (info["args"] as? [String: String]) ?? [:]
            // The closure is nonisolated; hop to main where `entries`
            // and the @Published machinery live.
            Task { @MainActor [weak self] in
                self?.append(op: op, args: args)
            }
        }
    }

    /// Drop every recorded entry — both in-memory and on disk. Surfaced
    /// as the "Clear history" button in the Privacy tab.
    func clear() {
        entries.removeAll()
        rewriteDisk()
    }

    // MARK: - Internals

    private func append(op: String, args: [String: String]) {
        let entry = ActionAuditEntry(
            id: UUID(),
            timestamp: Date(),
            op: op,
            args: args,
            durable: ActionAuditEntry.opIsDurable(op)
        )
        entries.append(entry)
        if entries.count > entryCap {
            entries.removeFirst(entries.count - entryCap)
        }
        rewriteDisk()
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let blob = try? Data(contentsOf: fileURL)
        else { return }

        // Resolve to JSONL plaintext bytes — encrypted envelope first
        // (with key), legacy plaintext fallback. Same shape as
        // MemoryStore.loadFromDisk; the abstraction lives in
        // EncryptedJSONStore.tolerantLoadData.
        let data: Data
        if let key = atRestKey {
            guard let result = EncryptedJSONStore.tolerantLoadData(blob, using: key) else {
                AppLog.actions.error("audit.jsonl looks like a corrupted envelope; refusing to parse")
                return
            }
            data = result.value
            if result.wasPlaintext {
                AppLog.actions.notice("audit.jsonl is legacy plaintext; will re-save sealed on next write")
            }
        } else {
            data = blob
        }

        var loaded: [ActionAuditEntry] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let entry = try? decoder.decode(ActionAuditEntry.self, from: Data(line)) {
                loaded.append(entry)
            }
        }
        entries = loaded
    }

    private func rewriteDisk() {
        var buffer = Data()
        for entry in entries {
            guard let d = try? encoder.encode(entry) else { continue }
            buffer.append(d)
            buffer.append(0x0A)
        }
        let plaintext = buffer

        // Seal under the at-rest key when present; plaintext-fallback
        // on encrypt failure (logged) or no-Keychain — same posture as
        // MemoryStore / SessionStore.
        let payload: Data
        if let key = atRestKey {
            do {
                payload = try EncryptedJSONStore.sealData(plaintext, using: key)
            } catch {
                AppLog.actions.error("seal failed for audit.jsonl; writing plaintext: \(error.localizedDescription, privacy: .public)")
                payload = plaintext
            }
        } else {
            payload = plaintext
        }

        let url = fileURL
        writeQueue.async {
            do {
                try payload.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o600))],
                    ofItemAtPath: url.path
                )
            } catch {
                AppLog.actions.error("audit log rewrite failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// One ledger row. Persisted as JSONL; rendered as a row in the Privacy
/// → Action history list. Args are stringified at the notification
/// boundary, so the entry only carries a flat dict — fine for display.
struct ActionAuditEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let op: String
    let args: [String: String]
    /// Whether this op writes state that survives the current session.
    /// Memory entries, soul patches, settings changes, downloaded media
    /// are durable; body animation, expression changes, walking are not.
    let durable: Bool

    /// Compact human-readable arg preview for the row. Drops empty
    /// values; truncates anything over 60 chars to keep rows uniform.
    var argsPreview: String {
        let parts = args
            .filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { kv -> String in
                let v = kv.value.count > 60
                    ? String(kv.value.prefix(60)) + "…"
                    : kv.value
                return "\(kv.key)=\(v)"
            }
        return parts.joined(separator: " · ")
    }

    /// Set of op names whose effects survive a session. Conservative —
    /// any op not on the list is treated as ephemeral. Ops added later
    /// without a list update will surface as `durable: false`; that's
    /// safe (over-displaying is worse than under-displaying for trust).
    private static let durableOps: Set<String> = [
        "write_memory",
        "remember",
        "propose_soul_patch",
        "set_chat_color",
        "set_chat_font",
        "set_chat_background",
        "set_outfit",
        "set_voice",
        "set_voice_filter",
        "set_companion_name",
        "bind",
        "unbind",
        "download_image",
        "post_link",
        "set_mode",
        "revert_to_baseline",
        "reset_chat_theme"
    ]

    static func opIsDurable(_ op: String) -> Bool {
        durableOps.contains(op)
    }
}
