import CryptoKit
import Foundation
import Security

/// Minimal wrapper over the macOS Keychain for secrets that shouldn't sit
/// plaintext in `UserDefaults` — the only store that app-sandbox-escaped
/// processes running as the same user can read. Keyed by a stable
/// account name so we can read/update/delete in place across launches.
enum KeychainStore {
    /// Account name under which the OpenAI-compatible HTTP backend's API
    /// key is stored. `KeychainStore` is the single source of truth; the
    /// JSON-serialised `BackendSettings.openAIApiKey` field is always
    /// written as empty so a settings-export never carries the secret.
    static let openAIAccount = "companion.backend.openai.apiKey"

    /// Shared at-rest AES-256 key used by `EncryptedJSONStore` for
    /// on-disk sealed blobs (time capsules, user models). One key per
    /// install, generated lazily on first read. Losing this key (e.g.
    /// via `--resetKeychain` or a migration to a new Mac without
    /// restore) renders previously-encrypted files unrecoverable — the
    /// consumer stores treat that as "start fresh."
    static let atRestKeyAccount = "companion.at_rest_aes_key"

    /// Per-channel bearer-token account name. One Keychain item per
    /// channel UUID; deleted when the channel is removed. Used for
    /// `.lan` (clawdex pairing token) and `.remote` (Tailscale /
    /// Cloudflare-Tunnel / direct port-forward bearer).
    static func bearerAccount(for channelID: UUID) -> String {
        "companion.channel.\(channelID.uuidString).bearer"
    }

    /// Service name scopes all items so other tools running as the same
    /// user can't collide with our keys. Intentionally hard-coded — the
    /// bundle identifier is the natural namespace.
    private static let service = "com.peterhanily.max_clawdroom"

    /// Read a string value for `account`. Returns "" when nothing is
    /// stored or the read fails — callers treat that as "no key set".
    static func read(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return "" }
        return string
    }

    /// Load the stored 256-bit symmetric key for `account`, generating a
    /// fresh one on first access. Used for at-rest encryption of on-disk
    /// stores whose contents shouldn't be readable by other processes
    /// running as the same user.
    ///
    /// Returns nil only if both the read AND the generate-and-store
    /// fallback fail — e.g. Keychain is inaccessible entirely. Callers
    /// treat nil as "encryption unavailable, fall back to plaintext"
    /// rather than crashing.
    static func loadOrCreateSymmetricKey(account: String) -> SymmetricKey? {
        let existingData = readData(account: account)
        if existingData.count == 32 {
            return SymmetricKey(data: existingData)
        }
        // No key (or corrupt size) — generate a fresh one and store.
        let fresh = SymmetricKey(size: .bits256)
        let rawData = fresh.withUnsafeBytes { Data($0) }
        let ok = writeData(account: account, data: rawData)
        guard ok else {
            AppLog.keychain.error("failed to persist fresh AES key for \(account, privacy: .public)")
            return nil
        }
        return fresh
    }

    /// Read raw Data for `account`. Empty Data when missing.
    private static func readData(account: String) -> Data {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return Data()
        }
        return data
    }

    /// Write or update raw Data for `account`.
    @discardableResult
    private static func writeData(account: String, data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        if existing == errSecSuccess {
            let attrs: [String: Any] = [kSecValueData as String: data]
            return SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecSuccess
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Write or update a string value for `account`. Writing an empty
    /// string deletes the item — callers use that to clear a credential.
    @discardableResult
    static func write(account: String, value: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        if existing == errSecSuccess {
            let attrs: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            if status != errSecSuccess {
                AppLog.keychain.error("update failed (\(status)) for \(account, privacy: .public)")
            }
            return status == errSecSuccess
        } else {
            var add = query
            add[kSecValueData as String] = data
            // Only accessible when the device is unlocked — a desktop app
            // running in an active session always satisfies this.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let status = SecItemAdd(add as CFDictionary, nil)
            if status != errSecSuccess {
                AppLog.keychain.error("add failed (\(status)) for \(account, privacy: .public)")
            }
            return status == errSecSuccess
        }
    }
}
