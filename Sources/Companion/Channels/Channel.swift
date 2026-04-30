import Foundation

/// A configured OpenClaw destination Max can attach to. Roughly: a
/// (transport, endpoint, auth, persona) tuple persisted as a row in
/// `ChannelStore`. The active channel drives `ChatSession.clientOrBuild`.
///
/// Three transport tiers map onto the same OpenAI-SSE wire format
/// (clawdex speaks Chat Completions on loopback, on `--lan`, and over
/// any tunnel), so `.local`/`.lan`/`.remote` all build an
/// `OpenAIHTTPBackend` under the hood. `.claudeCodeCLI` is the legacy
/// direct-subprocess path retained for users who don't run clawdex.
struct Channel: Codable, Identifiable, Equatable, Hashable {
    enum Kind: String, Codable {
        case local            // loopback clawdex on this Mac
        case lan              // Bonjour-paired clawdex on the LAN
        case remote           // arbitrary URL (Tailscale, Cloudflare Tunnel, port-forward)
        case claudeCodeCLI    // long-lived `claude` subprocess (legacy)
    }

    /// How the bearer for this channel is stored. `.none` is loopback /
    /// CLI where no auth is needed; `.bearerInKeychain` means the token
    /// lives in Keychain under `KeychainStore.bearerAccount(for: id)`.
    enum AuthRefKind: String, Codable {
        case none
        case bearerInKeychain
    }

    /// Bonjour service handle so we can re-resolve a `.lan` channel
    /// after the host's IP changes (DHCP rotation, Wi-Fi rejoin).
    /// Phase 1 stores it; Phase 2's discovery sheet writes it; the
    /// re-resolve loop is Phase 3.
    struct BonjourRef: Codable, Equatable, Hashable {
        var serviceName: String
        var serviceType: String
        var serviceDomain: String
    }

    let id: UUID
    var name: String
    var kind: Kind
    /// For `.local`/`.lan`/`.remote`: full chat-completions URL.
    /// Ignored for `.claudeCodeCLI`.
    var endpoint: String
    /// Forwarded as the `model` field in the request body.
    var model: String
    var authRef: AuthRefKind
    /// `.claudeCodeCLI`: working directory the subprocess runs in.
    /// Other kinds: optional human-readable hint ("Studio iMac, ~/code")
    /// shown in the channel list. Doesn't affect routing for non-CLI kinds.
    var cwd: String?
    var persona: ChannelPersona
    var lastSeenAt: Date?
    var bonjour: BonjourRef?

    init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        endpoint: String = "",
        model: String = "",
        authRef: AuthRefKind = .none,
        cwd: String? = nil,
        persona: ChannelPersona = .default,
        lastSeenAt: Date? = nil,
        bonjour: BonjourRef? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.endpoint = endpoint
        self.model = model
        self.authRef = authRef
        self.cwd = cwd
        self.persona = persona
        self.lastSeenAt = lastSeenAt
        self.bonjour = bonjour
    }
}
