import Foundation

/// Protocol every agent backend conforms to. Defines the minimum
/// surface ChatSession needs to stream assistant events, reset, and
/// track a resumable session-id.
///
/// The original ClaudeCodeClient is one implementation. The new
/// OpenAIHTTPBackend is another. A third (scripted, mock, etc.) can
/// be added without touching ChatSession.
@MainActor
protocol AgentBackend: AnyObject {
    /// Optional backend-assigned session identifier. Used by
    /// persistence (`SessionStore`) to round-trip conversations
    /// across app launches via `--resume`-like flags where supported.
    /// nil for backends that don't carry server-side session state.
    var sessionID: String? { get }

    /// Human-readable tag for logs / UI ("Claude Code CLI", "OpenAI
    /// Compatible HTTP", etc.).
    var displayName: String { get }

    /// Send one user turn. Backends own their own conversation state
    /// across calls — ChatSession doesn't re-send history each turn.
    /// Stream terminates when the backend's turn-complete signal fires.
    nonisolated func stream(userText: String) -> AsyncThrowingStream<AgentEvent, Error>

    /// Tear down any running subprocess / socket / state. Next call to
    /// `stream(...)` re-initialises.
    func reset()
}

/// Events every backend emits during a streaming turn. Shared across
/// ClaudeCodeClient + OpenAIHTTPBackend + any future backend so the
/// downstream consumers (ChatSession, TelemetryBus, BindingEngine)
/// don't care which backend produced them.
enum AgentEvent {
    case text(String)
    case toolCallBegin(id: String, name: String)
    case toolCallArgs(id: String, argumentsDelta: String)
    case toolCallEnd(id: String)
    /// Stdout/stderr payload from tool execution, routed back via
    /// backend-specific mechanisms (claude-code emits `type:"user"`
    /// tool_result messages; OpenAI's Chat Completions doesn't report
    /// tool results in-stream so the HTTP backend synthesises them).
    case toolCallResult(id: String, content: String, isError: Bool)
    /// Hesitation / entropy signal — [0,1]. Backends that don't expose
    /// token-level metrics derive this from latency variance.
    case tokenEntropy(Double)
    case tokenLatency(Double)
}
