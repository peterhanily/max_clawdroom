import Foundation

/// Which agent backend drives conversations.
/// - `.claudeCode`: long-lived `claude` CLI subprocess (default)
/// - `.openAIHTTP`: HTTP streaming against any `/v1/chat/completions`
///   endpoint — clawdex, Ollama, LM Studio, OpenAI, Groq, etc.
enum AgentBackendType: String, Codable, CaseIterable {
    case claudeCode
    case openAIHTTP

    var displayName: String {
        switch self {
        case .claudeCode:  return "Claude Code CLI"
        case .openAIHTTP:  return "OpenAI-compatible HTTP"
        }
    }
}

/// Per-session configuration for the `claude` subprocess plus the user's
/// soul prompt. Everything here flows into `ClaudeCodeClient.Config` at
/// chat-session init.
///
/// **Schema evolution.** The UserDefaults key (`…settings.v2`) gates major
/// breaking changes; `schemaVersion` inside the struct gates soft changes
/// that can migrate in place (field renames, default shifts, new fields
/// with derived defaults). A new release can bump the version, inspect
/// the decoded value, and run a fix-up step before trusting the struct.
struct BackendSettings: Codable, Equatable {
    /// Current in-struct schema version. Bump when introducing soft
    /// migrations that want a hook in `SettingsStore.init`. The
    /// UserDefaults key bump (v2 → v3) is reserved for changes that
    /// would make older decodes silently produce wrong data.
    static let currentSchemaVersion: Int = 1
    var schemaVersion: Int
    /// Absolute path to the `claude` CLI executable. Auto-detected on first
    /// launch via `which claude`; editable in Settings.
    var claudeBinaryPath: String
    /// Working directory the subprocess runs in. Defaults to the user's
    /// home. Tools like Read/Edit/Write/Bash operate relative to this.
    var cwd: String
    /// Permission mode passed to `claude --permission-mode`. One of
    /// "acceptEdits" (default), "plan", "bypassPermissions", "default",
    /// "auto", "dontAsk".
    var permissionMode: String
    /// Comma-separated pre-approved tool patterns passed to
    /// `claude --allowed-tools`. Empty = no pre-approval (tools will hang
    /// waiting for a prompt that can't be answered in a GUI).
    var allowedTools: String
    /// Model alias or full ID (`sonnet`, `opus`, `haiku`, or
    /// `claude-opus-4-7`). Empty = let the CLI pick the default.
    var model: String
    /// User's soul prompt. Appended to Claude Code's built-in system prompt
    /// via `--append-system-prompt`.
    var systemPrompt: String

    /// Display name for the companion. User-editable from the onboarding
    /// flow and Settings. Renders as the chat header tag, the input
    /// prompt prefix, TV-mode ticker label, Max's Room title, and any
    /// VoiceOver/notification strings. ALWAYS read via
    /// `MaxClawdroomIdentity.displayName()` — never used raw — so the
    /// sanitiser runs on every surface and no injection makes it
    /// through into the system prompt or voice output.
    var companionName: String

    /// Which backend drives chat. Defaults to the Claude Code CLI
    /// subprocess that shipped in v0.1.0; `.openAIHTTP` routes to the
    /// HTTP fields below instead.
    var backendType: AgentBackendType
    /// Base URL for the `.openAIHTTP` backend. Expected to include the
    /// full path to `/v1/chat/completions`. Default targets clawdex's
    /// local proxy. Ignored when `backendType == .claudeCode`.
    var openAIBaseURL: String
    /// Bearer token for the OpenAI HTTP backend. Optional — local
    /// endpoints (Ollama, LM Studio, clawdex) don't need one.
    var openAIApiKey: String
    /// Model name for OpenAI HTTP. `gpt-4o-mini`, `llama3.1`, etc.
    var openAIModel: String

    static let defaultAllowedTools =
        "Read,Edit,Write,Glob,Grep,Bash(*),WebFetch(*),WebSearch(*)"

    static let `default` = BackendSettings(
        schemaVersion: BackendSettings.currentSchemaVersion,
        claudeBinaryPath: Self.autoDetectedClaudePath(),
        cwd: FileManager.default.homeDirectoryForCurrentUser.path,
        permissionMode: "acceptEdits",
        allowedTools: Self.defaultAllowedTools,
        model: "",
        systemPrompt: "",
        companionName: "Max",
        backendType: .claudeCode,
        openAIBaseURL: Constants.Clawdex.chatCompletionsURL,
        openAIApiKey: "",
        openAIModel: "gpt-4o-mini"
    )

    /// Best-effort `which claude` substitute that works in a GUI app where
    /// `PATH` may not include the user's shell profile. Checks common
    /// install locations in order.
    static func autoDetectedClaudePath() -> String {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return candidates[0]
    }

    // Tolerate older saved settings — any missing key falls back to default.
    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case claudeBinaryPath, cwd, permissionMode, allowedTools, model, systemPrompt
        case companionName
        case backendType, openAIBaseURL, openAIApiKey, openAIModel
    }
    init(
        schemaVersion: Int = BackendSettings.currentSchemaVersion,
        claudeBinaryPath: String,
        cwd: String,
        permissionMode: String,
        allowedTools: String,
        model: String,
        systemPrompt: String,
        companionName: String = "Max",
        backendType: AgentBackendType = .claudeCode,
        openAIBaseURL: String = Constants.Clawdex.chatCompletionsURL,
        openAIApiKey: String = "",
        openAIModel: String = "gpt-4o-mini"
    ) {
        self.schemaVersion = schemaVersion
        self.claudeBinaryPath = claudeBinaryPath
        self.cwd = cwd
        self.permissionMode = permissionMode
        self.allowedTools = allowedTools
        self.model = model
        self.systemPrompt = systemPrompt
        self.companionName = companionName
        self.backendType = backendType
        self.openAIBaseURL = openAIBaseURL
        self.openAIApiKey = openAIApiKey
        self.openAIModel = openAIModel
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Default to 0 for pre-schemaVersion installs so the `SettingsStore`
        // migration hook can detect them and run fix-ups if needed.
        self.schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 0
        self.claudeBinaryPath = (try? c.decode(String.self, forKey: .claudeBinaryPath))
            ?? BackendSettings.autoDetectedClaudePath()
        self.cwd = (try? c.decode(String.self, forKey: .cwd))
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        self.permissionMode = (try? c.decode(String.self, forKey: .permissionMode)) ?? "acceptEdits"
        self.allowedTools = (try? c.decode(String.self, forKey: .allowedTools))
            ?? BackendSettings.defaultAllowedTools
        self.model = (try? c.decode(String.self, forKey: .model)) ?? ""
        self.systemPrompt = (try? c.decode(String.self, forKey: .systemPrompt)) ?? ""
        self.backendType = (try? c.decode(AgentBackendType.self, forKey: .backendType)) ?? .claudeCode
        self.openAIBaseURL = (try? c.decode(String.self, forKey: .openAIBaseURL))
            ?? Constants.Clawdex.chatCompletionsURL
        // Pre-Keychain releases persisted the key here in plaintext. We
        // tolerate that on decode (returned as-is) so `SettingsStore.init`
        // can migrate it into the Keychain; subsequent encodes always
        // write an empty string here.
        self.openAIApiKey = (try? c.decode(String.self, forKey: .openAIApiKey)) ?? ""
        self.openAIModel = (try? c.decode(String.self, forKey: .openAIModel)) ?? "gpt-4o-mini"
        // Older saves won't have this; fall back to the canonical default
        // so existing installs feel continuous.
        self.companionName = (try? c.decode(String.self, forKey: .companionName)) ?? "Max"
    }

    /// Custom encode so the API key never lands in UserDefaults. The
    /// Keychain is the source of truth; `SettingsStore` hydrates the
    /// in-memory `openAIApiKey` from there on launch.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion,    forKey: .schemaVersion)
        try c.encode(claudeBinaryPath, forKey: .claudeBinaryPath)
        try c.encode(cwd,              forKey: .cwd)
        try c.encode(permissionMode,   forKey: .permissionMode)
        try c.encode(allowedTools,     forKey: .allowedTools)
        try c.encode(model,            forKey: .model)
        try c.encode(systemPrompt,     forKey: .systemPrompt)
        try c.encode(backendType,      forKey: .backendType)
        try c.encode(openAIBaseURL,    forKey: .openAIBaseURL)
        try c.encode("",               forKey: .openAIApiKey)  // Keychain holds the secret
        try c.encode(openAIModel,      forKey: .openAIModel)
        try c.encode(companionName,    forKey: .companionName)
    }
}
