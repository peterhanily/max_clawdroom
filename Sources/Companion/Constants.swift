import Foundation

/// App-wide constants that previously lived as duplicated string / integer
/// literals across multiple modules. Anything here is a "hard-coded fact
/// about the product" rather than a user preference — tunables that should
/// be configurable live in `Prefs` or `BackendSettings` instead.
enum Constants {
    /// Built-in local OpenAI-compatible endpoint. max_clawdroom can host
    /// its own Chat Completions server on 127.0.0.1:52429 (opt-in via
    /// Settings), so downstream tools like Cursor/Continue point at the
    /// same app they already talk to. The chat-completions URL below is
    /// also the OpenAI-HTTP-backend default, so if the user flips on the
    /// local server and switches backend to OpenAI HTTP, the loop closes.
    /// Port 52429 is retained from the original `clawdex` standalone so
    /// existing tool configs keep working.
    enum LocalEndpoint {
        static let port: Int = 52429
        static let chatCompletionsURL: String =
            "http://127.0.0.1:\(port)/v1/chat/completions"
    }

    /// Old alias retained so nothing breaks during the incremental
    /// rename. New call sites should reference `LocalEndpoint`.
    typealias Clawdex = LocalEndpoint

    /// Streaming-latency telemetry windows used by both backends to feed
    /// the binding engine's hesitation signal. Kept in one place so the
    /// two backends stay numerically comparable.
    enum Telemetry {
        /// Rolling samples considered when computing hesitation std-dev.
        static let latencyWindowSize: Int = 16
    }

    /// Limits for agent-emitted free-form content that reaches persistent
    /// stores or the prompt. Preventing runaway growth from a broken reply
    /// matters more than the exact number.
    enum Memory {
        /// Maximum characters the agent can push into a single memory entry
        /// (`remember` / `write_journal`). Long entries get truncated.
        static let entryCharCap: Int = 10_000
    }
}
