import CryptoKit
import Foundation
import Observation

/// Persistent cache for the `UserModel` synthesised from raw memory
/// entries. Lives per-cwd next to the JSONL memory log so different
/// projects get different model-of-you snapshots.
///
/// Writes are atomic and on a background queue so a burst of "edit the
/// model" calls from the Settings pane doesn't hitch the UI.
@Observable
@MainActor
final class UserModelStore {

    /// Weak pointer to the primary overlay's store, set once from
    /// `AppDelegate`. Lets the Settings pane bind to the current model
    /// without plumbing a reference through SwiftUI's environment.
    /// Weak so store teardown (unlikely but possible in tests) can't be
    /// held alive by a forgotten UI binding.
    @ObservationIgnored static weak var shared: UserModelStore?

    private(set) var model: UserModel = .empty

    @ObservationIgnored let cwd: String
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let encoder: JSONEncoder
    @ObservationIgnored private let decoder: JSONDecoder
    @ObservationIgnored private let writeQueue = DispatchQueue(
        label: "companion.usermodel.writes",
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
        // Owner-only permissions — same rationale as MemoryStore. The
        // user model is a distilled *structured* version of memory; if
        // anything the raw memory has, the model has it too.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: dir.path
        )
        return dir.appendingPathComponent("user_model.json")
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        // Try encrypted first, fall back to legacy plaintext, migrate on
        // hit. Plaintext users ride free — the next save() seals it.
        var wasPlaintext = false
        var decoded: UserModel
        if let key = KeychainStore.loadOrCreateSymmetricKey(account: KeychainStore.atRestKeyAccount),
           let loaded = EncryptedJSONStore.tolerantLoad(data, as: UserModel.self, using: key) {
            decoded = loaded.value
            wasPlaintext = loaded.wasPlaintext
        } else if let plaintext = try? decoder.decode(UserModel.self, from: data) {
            decoded = plaintext
            wasPlaintext = true
        } else {
            AppLog.memory.error("user model decode failure (neither encrypted nor plaintext)")
            return
        }
        // Invalidate caches from an older synthesiser version so the
        // next turn triggers a fresh synthesis instead of carrying
        // structural artefacts from a prompt shape we no longer use.
        if decoded.synthesiserVersion < UserModel.currentSynthesiserVersion {
            AppLog.memory.notice("user model cache is from synthesiser v\(decoded.synthesiserVersion), invalidating")
            decoded = .empty
        }
        self.model = decoded
        if wasPlaintext {
            AppLog.memory.notice("migrating user model from plaintext to encrypted")
            save(decoded)
        }
    }

    // MARK: - Mutation

    /// Replace the model with a fresh synthesis result. `refreshedAt` is
    /// stamped here so callers can't forget.
    ///
    /// Ordering: we encode + write to disk FIRST, then publish via
    /// @Published. Previously publish ran ahead of the background write,
    /// so a Settings view reading the model could see fields that hadn't
    /// yet been committed to disk; a crash between publish and write
    /// would leave UI and storage diverged. Encoding is cheap in-memory
    /// so doing it inline costs nothing user-visible.
    func replace(with newModel: UserModel) {
        var m = newModel
        m.refreshedAt = Date()
        m.synthesiserVersion = UserModel.currentSynthesiserVersion
        save(m)
        self.model = m
    }

    /// User-editable-in-Settings hook. Callers mutate the published
    /// model directly; this flushes the change to disk. Intentionally
    /// separate from `replace` so an edit stamps `refreshedAt` too
    /// (the edit IS a refresh from the model's perspective).
    func flushEdit() {
        var m = self.model
        m.refreshedAt = Date()
        save(m)
        self.model = m
    }

    private func save(_ m: UserModel) {
        // Seal through the encrypted-store helper. Falls back to
        // plaintext if the Keychain is unavailable so the feature
        // keeps working on quirky setups (logged so it's visible).
        let url = fileURL
        let data: Data
        do {
            if let key = KeychainStore.loadOrCreateSymmetricKey(account: KeychainStore.atRestKeyAccount) {
                data = try EncryptedJSONStore.encode(m, using: key)
            } else {
                AppLog.memory.notice("at-rest key unavailable; saving user model unencrypted")
                data = try encoder.encode(m)
            }
        } catch {
            AppLog.memory.error("user model encode failed, skipping save: \(error.localizedDescription, privacy: .public)")
            return
        }
        writeQueue.async {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                Task { @MainActor in
                    AppLog.memory.error("user model write failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Age

    /// How old the cached model is in seconds. Callers (synthesiser) use
    /// this to decide whether to kick a refresh. `distantPast` means
    /// "never synthesised" — age is effectively infinite.
    var ageSeconds: TimeInterval {
        guard model.refreshedAt != .distantPast else { return .infinity }
        return Date().timeIntervalSince(model.refreshedAt)
    }
}
