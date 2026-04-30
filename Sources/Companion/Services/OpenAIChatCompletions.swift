import Foundation

/// Immutable snapshot of the subset of `BackendSettings` the local
/// server needs to spawn a `ClaudeCodeProcess`. AppDelegate refreshes
/// this via `OpenAIChatCompletions.updateSettings(...)` whenever the
/// user changes model / cwd / binary path, so the handler never has
/// to hop to MainActor per request (which deadlocks against the
/// network-framework queue the listener callbacks run on).
struct LocalServerSettingsSnapshot: Sendable {
    let executablePath: String
    let cwd: String
    let permissionMode: String
    let allowedTools: String?
    let model: String?
}

/// Translates between OpenAI Chat Completions requests and the existing
/// `ClaudeCodeProcess` streaming protocol. Called by `LocalOpenAIServer`
/// on a per-request basis — each POST spawns a fresh claude CLI
/// subprocess, accumulates or streams its text output, emits OpenAI-
/// shaped SSE chunks (or one non-streaming JSON body), then tears
/// the subprocess down.
///
/// What we translate:
///   - OpenAI `messages[]` array → a single prompt we send as the
///     first user message to claude. System role content is collected
///     into `--append-system-prompt`; user/assistant turns become
///     prior-turn context inline in the prompt.
///   - Claude text content deltas → OpenAI SSE chunks with
///     `choices[0].delta.content`.
///   - Claude tool_use events → **inlined as text** for now. Cursor /
///     Continue treat unrecognised chunks as prose, which is fine for
///     a v0 bridge. Structured tool_calls translation is a follow-up.
///
/// What we skip (on purpose, for MVP scope):
///   - `stop` / `max_tokens` / `temperature` / `top_p` — claude CLI
///     doesn't expose per-request knobs we'd map to here.
///   - Function calling / `tools[]` — see above.
///   - `stream_options.include_usage` — no usage accounting.
/// Request handler — nonisolated since `LocalOpenAIServer` calls into
/// it from off-main network-framework queues. It owns no mutable state
/// beyond the config-factory closure (which itself hops to MainActor
/// when it needs to read Settings).
nonisolated final class OpenAIChatCompletions: @unchecked Sendable {

    /// Output events the server streams back to the client.
    enum Event {
        case nonStreamingJSON(Data)
        case startStreaming
        case streamChunk(Data)
        case streamEnd
        case error(Int, String)  // HTTP status + OpenAI-shaped error message
    }

    /// Lock-protected current settings snapshot. Mutated by the app on
    /// MainActor via `updateSettings`; read by request handlers on the
    /// network queue under the same lock. No MainActor hop required.
    private let snapshotLock = NSLock()
    private var snapshot: LocalServerSettingsSnapshot

    init(initial: LocalServerSettingsSnapshot) {
        self.snapshot = initial
    }

    /// Called by AppDelegate on MainActor whenever settings change, so
    /// subsequent requests use the fresh values.
    func updateSettings(_ new: LocalServerSettingsSnapshot) {
        snapshotLock.lock()
        snapshot = new
        snapshotLock.unlock()
    }

    private func currentSnapshot() -> LocalServerSettingsSnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshot
    }

    private func makeConfig() -> ClaudeCodeProcess.LaunchConfig {
        let s = currentSnapshot()
        return ClaudeCodeProcess.LaunchConfig(
            executablePath: s.executablePath,
            cwd: s.cwd,
            permissionMode: s.permissionMode,
            allowedTools: s.allowedTools,
            model: s.model,
            appendSystemPrompt: nil,
            resumeSessionID: nil
        )
    }

    // MARK: - /v1/models

    func handleModelsList(callback: @escaping @Sendable (Data) -> Void) {
        let configModel = currentSnapshot().model ?? ""
        let label = configModel.isEmpty ? "claude-code" : configModel
        let response: [String: Any] = [
            "object": "list",
            "data": [
                [
                    "id": label,
                    "object": "model",
                    "created": Int(Date().timeIntervalSince1970),
                    "owned_by": "max_clawdroom"
                ]
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
        callback(data)
    }

    // MARK: - /v1/chat/completions

    func handleChatCompletions(body: Data, callback: @escaping @Sendable (Event) -> Void) {
        let parsed: ChatRequest
        do {
            parsed = try JSONDecoder().decode(ChatRequest.self, from: body)
        } catch {
            callback(.error(400, "invalid request body: \(error.localizedDescription)"))
            return
        }
        guard !parsed.messages.isEmpty else {
            callback(.error(400, "messages[] is empty"))
            return
        }

        // Compose the prompt. We lift `system` role messages into a
        // dedicated system prompt override; user/assistant turns become
        // prior context inside the final user message. Claude's CLI
        // ingests one user message per invocation, so we collapse a
        // multi-turn OpenAI history into a single prompt with explicit
        // role markers — the model reads it fine.
        let (systemPrompt, finalPrompt) = Self.composePrompt(messages: parsed.messages)

        var config = makeConfig()
        if !systemPrompt.isEmpty {
            config = ClaudeCodeProcess.LaunchConfig(
                executablePath: config.executablePath,
                cwd: config.cwd,
                permissionMode: config.permissionMode,
                allowedTools: config.allowedTools,
                model: parsed.model ?? config.model,
                appendSystemPrompt: systemPrompt,
                resumeSessionID: nil
            )
        } else if let m = parsed.model {
            config = ClaudeCodeProcess.LaunchConfig(
                executablePath: config.executablePath,
                cwd: config.cwd,
                permissionMode: config.permissionMode,
                allowedTools: config.allowedTools,
                model: m,
                appendSystemPrompt: config.appendSystemPrompt,
                resumeSessionID: nil
            )
        }

        let completionID = "chatcmpl-\(UUID().uuidString.prefix(24))"
        let created = Int(Date().timeIntervalSince1970)
        let modelLabel = config.model ?? "claude-code"
        let isStreaming = parsed.stream ?? false

        let proc = ClaudeCodeProcess(config: config)
        do {
            try proc.start()
        } catch {
            callback(.error(500, "failed to start claude subprocess: \(error.localizedDescription)"))
            return
        }

        do {
            try proc.sendUserMessage(finalPrompt)
        } catch {
            proc.terminate()
            callback(.error(500, "failed to write to claude stdin: \(error.localizedDescription)"))
            return
        }

        if isStreaming {
            handleStreamingResponse(
                proc: proc,
                completionID: completionID,
                created: created,
                model: modelLabel,
                callback: callback
            )
        } else {
            handleNonStreamingResponse(
                proc: proc,
                completionID: completionID,
                created: created,
                model: modelLabel,
                callback: callback
            )
        }
    }

    private func handleStreamingResponse(
        proc: ClaudeCodeProcess,
        completionID: String,
        created: Int,
        model: String,
        callback: @escaping @Sendable (Event) -> Void
    ) {
        callback(.startStreaming)
        // Opening chunk — OpenAI spec requires the first delta to include
        // the `role` field on the assistant's turn start.
        let roleOpener = Self.sseChunk(
            id: completionID, created: created, model: model,
            delta: ["role": "assistant"],
            finishReason: nil
        )
        callback(.streamChunk(roleOpener))

        Task.detached {
            do {
                for try await line in proc.lines {
                    if let textDelta = Self.extractTextDelta(from: line) {
                        let chunk = Self.sseChunk(
                            id: completionID, created: created, model: model,
                            delta: ["content": textDelta],
                            finishReason: nil
                        )
                        callback(.streamChunk(chunk))
                    }
                }
                // Final chunk — empty delta + finish_reason=stop.
                let closer = Self.sseChunk(
                    id: completionID, created: created, model: model,
                    delta: [:],
                    finishReason: "stop"
                )
                callback(.streamChunk(closer))
                callback(.streamEnd)
            } catch {
                // Mid-stream error — OpenAI SSE has no great story here,
                // so emit an error JSON as a final data: line and close.
                let errEnvelope: [String: Any] = [
                    "error": [
                        "message": error.localizedDescription,
                        "type": "server_error"
                    ]
                ]
                let errData = (try? JSONSerialization.data(withJSONObject: errEnvelope)) ?? Data()
                var payload = Data("data: ".utf8)
                payload.append(errData)
                payload.append(Data("\n\n".utf8))
                callback(.streamChunk(payload))
                callback(.streamEnd)
            }
            proc.terminate()
        }
    }

    private func handleNonStreamingResponse(
        proc: ClaudeCodeProcess,
        completionID: String,
        created: Int,
        model: String,
        callback: @escaping @Sendable (Event) -> Void
    ) {
        Task.detached {
            var accumulated = ""
            do {
                for try await line in proc.lines {
                    if let delta = Self.extractTextDelta(from: line) {
                        accumulated += delta
                    }
                }
            } catch {
                callback(.error(500, "stream error: \(error.localizedDescription)"))
                proc.terminate()
                return
            }
            proc.terminate()
            let response: [String: Any] = [
                "id": completionID,
                "object": "chat.completion",
                "created": created,
                "model": model,
                "choices": [
                    [
                        "index": 0,
                        "message": [
                            "role": "assistant",
                            "content": accumulated
                        ],
                        "finish_reason": "stop"
                    ]
                ],
                "usage": [
                    "prompt_tokens": 0,
                    "completion_tokens": 0,
                    "total_tokens": 0
                ]
            ]
            let data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
            callback(.nonStreamingJSON(data))
        }
    }

    // MARK: - Translation helpers

    /// Parse one JSONL line from the claude subprocess and return any
    /// text delta it carries. Non-text events (tool_use, tool_result,
    /// system, result) return nil — those get dropped from the OpenAI
    /// stream in this MVP.
    ///
    /// Claude Agent SDK emits events shaped roughly like:
    /// `{"type":"assistant","message":{"content":[{"type":"text","text":"…"}]}}`.
    private static func extractTextDelta(from line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let type = obj["type"] as? String, type == "assistant" else { return nil }
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return nil }
        var out = ""
        for block in content {
            if let blockType = block["type"] as? String, blockType == "text",
               let text = block["text"] as? String {
                out += text
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Collapse OpenAI `messages[]` into (systemPrompt, userPrompt).
    /// System messages are concatenated into the system prompt override.
    /// Prior user/assistant turns are rendered inline as `role: text`
    /// blocks inside a single prompt handed to claude as one user turn.
    private static func composePrompt(messages: [ChatRequest.Message]) -> (String, String) {
        var systemParts: [String] = []
        var priorTurns: [String] = []
        var latestUser: String? = nil

        for (i, msg) in messages.enumerated() {
            let text = msg.contentString
            switch msg.role {
            case "system":
                systemParts.append(text)
            case "user":
                if i == messages.count - 1 {
                    latestUser = text
                } else {
                    priorTurns.append("User: \(text)")
                }
            case "assistant":
                priorTurns.append("Assistant: \(text)")
            case "tool":
                // Tool-call results from prior turns — append inline as
                // context. Real tool_calls translation is deferred.
                priorTurns.append("Tool: \(text)")
            default:
                priorTurns.append("\(msg.role.capitalized): \(text)")
            }
        }

        let systemPrompt = systemParts.joined(separator: "\n\n")
        let finalPrompt: String
        if priorTurns.isEmpty {
            finalPrompt = latestUser ?? ""
        } else {
            finalPrompt = """
            \(priorTurns.joined(separator: "\n\n"))

            User: \(latestUser ?? "")
            """
        }
        return (systemPrompt, finalPrompt)
    }

    /// Assemble one `data: {…}\n\n` SSE frame following the OpenAI
    /// chat.completion.chunk shape.
    private static func sseChunk(
        id: String,
        created: Int,
        model: String,
        delta: [String: Any],
        finishReason: String?
    ) -> Data {
        let choice: [String: Any] = [
            "index": 0,
            "delta": delta,
            "finish_reason": finishReason as Any
        ]
        let chunk: [String: Any] = [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [choice]
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: chunk, options: []) else {
            return Data()
        }
        var out = Data("data: ".utf8)
        out.append(json)
        out.append(Data("\n\n".utf8))
        return out
    }
}

// MARK: - Request decoding

/// Subset of the OpenAI Chat Completions request. Unknown fields
/// are ignored (we only decode what we handle). Nonisolated so the
/// network-thread decode path can use it without an actor hop.
nonisolated struct ChatRequest: Decodable, Sendable {
    let model: String?
    let messages: [Message]
    let stream: Bool?

    struct Message: Decodable, Sendable {
        let role: String
        /// Content is either a plain string (classic OpenAI) or
        /// an array of typed content blocks (vision-era). We accept
        /// both and flatten to a single string.
        let content: ContentField

        var contentString: String {
            switch content {
            case .string(let s): return s
            case .blocks(let blocks):
                return blocks
                    .compactMap { $0.text }
                    .joined(separator: "\n")
            }
        }

        enum ContentField: Decodable, Sendable {
            case string(String)
            case blocks([Block])

            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) {
                    self = .string(s)
                } else if let a = try? c.decode([Block].self) {
                    self = .blocks(a)
                } else {
                    self = .string("")
                }
            }
        }

        struct Block: Decodable, Sendable {
            let type: String?
            let text: String?
        }
    }
}
