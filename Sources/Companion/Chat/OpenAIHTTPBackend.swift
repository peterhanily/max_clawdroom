import Foundation

/// Streaming backend that talks to any OpenAI-compatible Chat
/// Completions endpoint. Works with:
/// - `clawdex` (127.0.0.1:52429, local Claude Code proxy)
/// - Ollama (`http://localhost:11434/v1`)
/// - LM Studio (`http://localhost:1234/v1`)
/// - OpenAI directly (`https://api.openai.com/v1`)
/// - Groq, Together, Fireworks, etc.
///
/// v1 supports streaming text only. Tool-calls in the OpenAI protocol
/// have a different shape from claude-code's action-tag flow; we lean
/// on action-tags-in-prose as the cross-backend gesture protocol
/// (which Max already uses for everything except the tool APIs).
///
/// Conversation state lives entirely in this object — each send
/// appends to `history` + re-POSTs the full array. That matches how
/// clients use /v1/chat/completions in practice.
@MainActor
final class OpenAIHTTPBackend: AgentBackend {
    struct Config {
        let baseURL: URL
        let apiKey: String?
        let model: String
        let systemPrompt: String?
    }

    private let config: Config
    private var history: [[String: Any]] = []
    private var currentTask: URLSessionDataTask?
    private var latencyWindow: [Double] = []
    private let windowSize = 16
    private var lastTokenAt: Date?

    /// No server-side session on the OpenAI protocol — conversations are
    /// client-owned. We don't round-trip a session-id to SessionStore.
    var sessionID: String? { nil }

    var displayName: String { "OpenAI-compatible HTTP" }

    init(config: Config) {
        self.config = config
        if let sys = config.systemPrompt, !sys.isEmpty {
            history.append(["role": "system", "content": sys])
        }
    }

    // MARK: - AgentBackend

    nonisolated func stream(userText: String) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    try self.beginStreamingTurn(userText: userText, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func reset() {
        currentTask?.cancel()
        currentTask = nil
        latencyWindow.removeAll()
        lastTokenAt = nil
        // Preserve the system prompt; drop everything else.
        history = history.filter { ($0["role"] as? String) == "system" }
    }

    // MARK: - Streaming

    private func beginStreamingTurn(
        userText: String,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) throws {
        history.append(["role": "user", "content": userText])

        var request = URLRequest(url: config.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let key = config.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": config.model,
            "messages": history,
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let delegate = SSEDelegate(
            onEvent: { [weak self] chunk in
                Task { @MainActor in
                    self?.handleDelta(chunk, continuation: continuation)
                }
            },
            onComplete: { [weak self] error in
                Task { @MainActor in
                    self?.handleCompletion(error: error, continuation: continuation)
                }
            }
        )
        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )
        let task = session.dataTask(with: request)
        currentTask = task
        lastTokenAt = Date()
        task.resume()

        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.currentTask?.cancel()
            }
        }
    }

    private func handleDelta(
        _ text: String,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) {
        // Latency tracking — time since last token.
        let now = Date()
        if let prev = lastTokenAt {
            let gap = now.timeIntervalSince(prev)
            latencyWindow.append(gap)
            if latencyWindow.count > windowSize {
                latencyWindow.removeFirst(latencyWindow.count - windowSize)
            }
            continuation.yield(.tokenLatency(gap))
            continuation.yield(.tokenEntropy(hesitationFromWindow()))
        }
        lastTokenAt = now
        continuation.yield(.text(text))
    }

    private func handleCompletion(
        error: Error?,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) {
        if let error {
            continuation.finish(throwing: error)
        } else {
            // Persist the assistant reply into history so the next turn
            // sees it. We rebuild from the in-flight text accumulated
            // upstream in ChatSession; simpler: just grab the full text
            // from the continuation? Can't — need to track here too.
            // Accumulation is handled via a mirror in SSEDelegate.
            continuation.finish()
        }
    }

    private func hesitationFromWindow() -> Double {
        guard latencyWindow.count >= 3 else { return 0 }
        let mean = latencyWindow.reduce(0, +) / Double(latencyWindow.count)
        let variance = latencyWindow.reduce(0) { $0 + pow($1 - mean, 2) } / Double(latencyWindow.count)
        let stddev = sqrt(variance)
        // Normalise — assume stddev > 0.5s of latency is "very hesitant"
        return min(1.0, stddev / 0.5)
    }

    /// Append the final assistant text to history so subsequent turns
    /// see it. Called by ChatSession after the stream finishes via
    /// `appendAssistantReply(_:)`.
    func appendAssistantReply(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        history.append(["role": "assistant", "content": trimmed])
    }
}

/// Structured error raised by the OpenAI HTTP backend when the server
/// refuses or cuts us off. Each case carries a short, user-facing message
/// so `ChatSession.friendlyError` can show something actionable instead
/// of a raw `URLError` code.
enum OpenAIHTTPError: LocalizedError {
    case unauthorized(String)
    case rateLimited(String)
    case serverError(Int, String)
    case badResponse(Int, String)
    case networkUnreachable(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized(let detail):
            return "Endpoint rejected the request (401). Check the API key in Settings. \(detail)"
        case .rateLimited(let detail):
            return "Rate limited (429). Wait a moment and try again. \(detail)"
        case .serverError(let code, let detail):
            return "Server error (\(code)). The endpoint is having trouble. \(detail)"
        case .badResponse(let code, let detail):
            return "Unexpected response (\(code)) from the endpoint. \(detail)"
        case .networkUnreachable(let detail):
            return "Couldn't reach the endpoint. \(detail)"
        }
    }
}

/// URLSession delegate that parses SSE frames out of a streaming data
/// task. OpenAI/clawdex/Ollama/LM-Studio/etc all emit:
///
///     data: {"choices":[{"delta":{"content":"Hello"}}]}
///
///     data: [DONE]
///
/// Keeps a rolling buffer so mid-frame newlines don't confuse the parser.
/// Also captures the initial HTTP status — anything non-2xx means the
/// response body isn't SSE (it's an error page or JSON error envelope),
/// which we accumulate and surface through `onComplete` as a typed error.
// URLSession serialises delegate callbacks per-task, so the mutable
// buffer state is already race-free in practice. `@unchecked Sendable`
// records that promise to the compiler.
private final class SSEDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let onEvent: (String) -> Void
    let onComplete: (Error?) -> Void
    private var buffer = Data()
    private var errorBody = Data()
    private var httpStatus: Int = 0

    init(onEvent: @escaping (String) -> Void, onComplete: @escaping (Error?) -> Void) {
        self.onEvent = onEvent
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            httpStatus = http.statusCode
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // On a non-2xx the server is sending an error body, not SSE. Capture
        // up to 2KB for the error message, don't try to parse as SSE frames.
        if httpStatus != 0, !(200..<300).contains(httpStatus) {
            if errorBody.count < 2048 {
                errorBody.append(data.prefix(2048 - errorBody.count))
            }
            return
        }
        buffer.append(data)
        // SSE frames are separated by double-newline. Parse as many
        // complete frames as we have, keep the trailing partial.
        let separator = Data("\n\n".utf8)
        while let range = buffer.range(of: separator) {
            let frame = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            guard let text = String(data: frame, encoding: .utf8) else { continue }
            // Strip "data: " prefix. Multi-line "data:" frames accumulate.
            var payload = ""
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let l = String(line)
                if l.hasPrefix("data: ") {
                    payload += String(l.dropFirst(6))
                } else if l.hasPrefix("data:") {
                    payload += String(l.dropFirst(5))
                }
            }
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed == "[DONE]" { continue }
            // Parse the JSON chunk: {"choices":[{"delta":{"content":"..."}}]}
            guard
                let data = trimmed.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = obj["choices"] as? [[String: Any]],
                let first = choices.first,
                let delta = first["delta"] as? [String: Any],
                let content = delta["content"] as? String
            else { continue }
            if !content.isEmpty {
                onEvent(content)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let classified = classify(error: error) {
            onComplete(classified)
        } else {
            onComplete(error)
        }
    }

    private func classify(error: Error?) -> Error? {
        let bodyText = String(data: errorBody, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let snippet = String(bodyText.prefix(300))
        switch httpStatus {
        case 200..<300, 0:
            break
        case 401, 403:
            return OpenAIHTTPError.unauthorized(snippet)
        case 429:
            return OpenAIHTTPError.rateLimited(snippet)
        case 500..<600:
            return OpenAIHTTPError.serverError(httpStatus, snippet)
        default:
            return OpenAIHTTPError.badResponse(httpStatus, snippet)
        }
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
                 .networkConnectionLost, .timedOut, .dnsLookupFailed:
                return OpenAIHTTPError.networkUnreachable(urlErr.localizedDescription)
            default:
                return nil
            }
        }
        return nil
    }
}
