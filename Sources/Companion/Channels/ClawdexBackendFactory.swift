import Foundation

/// Builds an `AgentBackend` from a `Channel`. Single chokepoint that
/// `ChatSession.clientOrBuild` calls — keeps the kind→backend mapping
/// in one place so adding a new transport tier (e.g. WebSocket) means
/// editing one switch.
///
/// All three OpenAI-SSE tiers (`.local`, `.lan`, `.remote`) reuse
/// `OpenAIHTTPBackend`. The only differences are URL, bearer, and
/// timeout policy — and `OpenAIHTTPBackend` already handles the first
/// two. `.claudeCodeCLI` builds the legacy subprocess client.
@MainActor
enum ClawdexBackendFactory {
    static func makeBackend(
        for channel: Channel,
        composedSystemPrompt: String,
        resumeSessionID: String?
    ) -> AgentBackend {
        switch channel.kind {
        case .claudeCodeCLI:
            // The CLI needs the full BackendSettings tail (binary
            // path, permission mode, allowed tools). Channels that
            // will eventually want to override these can do it later;
            // for now the global SettingsStore values flow through.
            let s = SettingsStore.shared.settings
            let cfg = ClaudeCodeClient.Config(
                executablePath: s.claudeBinaryPath,
                cwd: channel.cwd ?? s.cwd,
                permissionMode: s.permissionMode,
                allowedTools: s.allowedTools.isEmpty ? nil : s.allowedTools,
                model: channel.model.isEmpty ? nil : channel.model,
                systemPrompt: composedSystemPrompt,
                resumeSessionID: resumeSessionID
            )
            return ClaudeCodeClient(config: cfg)

        case .local, .lan, .remote:
            let endpoint = channel.endpoint.isEmpty
                ? Constants.Clawdex.chatCompletionsURL
                : channel.endpoint
            let url = URL(string: endpoint)
                ?? URL(string: Constants.Clawdex.chatCompletionsURL)!
            let bearer: String? = {
                guard channel.authRef == .bearerInKeychain else { return nil }
                return ChannelStore.shared.bearer(for: channel.id)
            }()
            let cfg = OpenAIHTTPBackend.Config(
                baseURL: url,
                apiKey: bearer,
                model: channel.model.isEmpty ? "gpt-4o-mini" : channel.model,
                systemPrompt: composedSystemPrompt
            )
            return OpenAIHTTPBackend(config: cfg)
        }
    }
}
