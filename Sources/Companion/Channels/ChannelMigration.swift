import Foundation

/// One-shot bootstrap that builds the initial channel list from the
/// legacy `BackendSettings` on first launch of a build that has
/// channels. After this runs, `ChannelStore` is the source of truth
/// for backend selection; `BackendSettings` continues to hold per-
/// claude-code-CLI configuration (binary path, permission mode,
/// allowed tools, soul) that the CLI channel reads at build time.
@MainActor
enum ChannelMigration {
    /// Synthesise a single channel that mirrors whatever the user had
    /// configured before channels existed. Always returns at least one
    /// channel so the store has something to point at.
    static func bootstrapFromLegacySettings() -> [Channel] {
        let s = SettingsStore.shared.settings
        switch s.backendType {
        case .claudeCode:
            return [
                Channel(
                    name: "This Mac (Claude Code)",
                    kind: .claudeCodeCLI,
                    endpoint: "",
                    model: s.model,
                    authRef: .none,
                    cwd: s.cwd
                )
            ]
        case .openAIHTTP:
            // Pre-channels installs may have stashed an API key in
            // settings. If so, mint a fresh channel id, move the key
            // into the per-channel Keychain slot, and return a channel
            // configured to use it. Otherwise it's a loopback channel
            // with no auth.
            let id = UUID()
            let hasKey = !s.openAIApiKey.isEmpty
            if hasKey {
                KeychainStore.write(
                    account: KeychainStore.bearerAccount(for: id),
                    value: s.openAIApiKey
                )
            }
            let isLoopback = s.openAIBaseURL.contains("127.0.0.1")
                || s.openAIBaseURL.contains("localhost")
            return [
                Channel(
                    id: id,
                    name: isLoopback ? "This Mac" : "Local",
                    kind: isLoopback ? .local : .remote,
                    endpoint: s.openAIBaseURL.isEmpty
                        ? Constants.Clawdex.chatCompletionsURL
                        : s.openAIBaseURL,
                    model: s.openAIModel,
                    authRef: hasKey ? .bearerInKeychain : .none
                )
            ]
        }
    }
}
