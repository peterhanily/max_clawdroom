import Foundation
import Observation

@Observable
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    var settings: BackendSettings {
        didSet { persist() }
    }

    // Bumped from v1 → v2 on the switch from OpenAI-compat HTTP config to
    // direct-CLI config. Old v1 data is ignored.
    @ObservationIgnored private let key = "companion.backend.settings.v2"

    private init() {
        var decoded: BackendSettings
        if
            let data = UserDefaults.standard.data(forKey: key),
            let d = try? JSONDecoder().decode(BackendSettings.self, from: data)
        {
            decoded = d
        } else {
            decoded = .default
        }
        // Keychain is the source of truth for the OpenAI API key. Prefer its
        // value; fall through to any plaintext we found in UserDefaults so a
        // pre-migration install doesn't lose the user's key on this launch.
        // `persist()` below will then write it into the Keychain and blank
        // the plaintext field on disk.
        let keychainKey = KeychainStore.read(account: KeychainStore.openAIAccount)
        if !keychainKey.isEmpty {
            decoded.openAIApiKey = keychainKey
        }
        // Schema migration hook. Pre-schemaVersion installs decode as 0;
        // newer releases read the value and run per-version fix-ups. This
        // single step-up keeps migrations linear — v0 → v1 → v2 — rather
        // than every version having to know about every previous shape.
        if decoded.schemaVersion < BackendSettings.currentSchemaVersion {
            AppLog.settings.notice("migrating settings from schema v\(decoded.schemaVersion) to v\(BackendSettings.currentSchemaVersion)")
            decoded.schemaVersion = BackendSettings.currentSchemaVersion
        }
        self.settings = decoded
        // didSet doesn't fire during init — do one explicit write so the
        // Keychain mirrors the in-memory struct and any legacy plaintext
        // gets wiped from UserDefaults on the rewritten JSON blob.
        persist()
    }

    private func persist() {
        // Keychain first — if this fails we log but keep writing the rest
        // of the settings so a keychain-refusal doesn't lose everything.
        KeychainStore.write(
            account: KeychainStore.openAIAccount,
            value: settings.openAIApiKey
        )
        do {
            let data = try JSONEncoder().encode(settings)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            AppLog.settings.error("encode failure — settings NOT saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
