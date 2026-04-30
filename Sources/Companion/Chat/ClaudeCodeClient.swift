import Foundation

/// Drives a long-lived `claude` subprocess and exposes per-turn event streams
/// for `ChatSession`. The Event enum is identical to the old ClawdexClient's
/// so downstream consumers (ChatSession, TelemetryBus, BindingEngine) are
/// unchanged.
///
/// Lifecycle: one instance per ChatSession. First call to `stream(userText:)`
/// launches the subprocess; later calls reuse it. `reset()` terminates so the
/// next call starts a fresh session (e.g., after soul prompt changes).
@MainActor
final class ClaudeCodeClient: AgentBackend {
    struct Message: Codable {
        let role: String
        let content: String
    }

    /// Typealias so downstream code that used the old nested
    /// `ClaudeCodeClient.Event` continues to compile unchanged.
    /// All new code should prefer `AgentEvent` directly.
    typealias Event = AgentEvent

    var displayName: String { "Claude Code CLI" }

    struct Config {
        let executablePath: String
        let cwd: String
        let permissionMode: String
        let allowedTools: String?
        let model: String?
        let systemPrompt: String?
        /// If non-nil, pass `--resume <id>` to claude-code so the
        /// subprocess continues an existing server-side session rather
        /// than starting fresh. Read-only across the client's lifetime;
        /// set at construction (ChatSession builds a new client on load).
        let resumeSessionID: String?
    }

    private let config: Config
    private var process: ClaudeCodeProcess?
    private var decoder = StreamJSONDecoder()
    private var consumerTask: Task<Void, Never>?
    private var currentContinuation: AsyncThrowingStream<Event, Error>.Continuation?

    /// Captured from the subprocess `system.init` event. Useful for --resume
    /// across app launches (v2) but otherwise informational.
    private(set) var sessionID: String?

    /// Ring buffer of recent normalized inter-token gaps. Hesitation =
    /// stddev over this window, scaled to [0,1].
    private var latencyWindow: [Double] = []
    private let windowSize = 16

    init(config: Config) {
        self.config = config
    }

    // MARK: - Public API

    /// Sends one user turn and streams events for it. Stream finishes when
    /// the subprocess emits a `result` event; the subprocess itself keeps
    /// running for the next turn.
    nonisolated func stream(userText: String) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    try self.startIfNeeded()
                    // Replace any stale continuation.
                    self.currentContinuation?.finish()
                    self.currentContinuation = continuation

                    continuation.onTermination = { @Sendable _ in
                        Task { @MainActor in
                            if self.currentContinuation != nil {
                                // Caller abandoned us; mark slot empty.
                                self.currentContinuation = nil
                            }
                        }
                    }

                    try self.process?.sendUserMessage(userText)
                } catch {
                    continuation.finish(throwing: error)
                    self.currentContinuation = nil
                }
            }
        }
    }

    /// Terminate the subprocess. Next `stream()` call spawns fresh.
    func reset() {
        currentContinuation?.finish()
        currentContinuation = nil
        process?.terminate()
        process = nil
        consumerTask?.cancel()
        consumerTask = nil
        decoder = StreamJSONDecoder()
        latencyWindow.removeAll()
        sessionID = nil
    }

    // MARK: - Subprocess setup

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }

        let launchConfig = ClaudeCodeProcess.LaunchConfig(
            executablePath: config.executablePath,
            cwd: config.cwd,
            permissionMode: config.permissionMode,
            allowedTools: config.allowedTools,
            model: config.model,
            appendSystemPrompt: config.systemPrompt,
            resumeSessionID: config.resumeSessionID
        )
        let proc = ClaudeCodeProcess(config: launchConfig)
        try proc.start()
        self.process = proc
        self.decoder = StreamJSONDecoder()
        self.latencyWindow.removeAll()

        let lines = proc.lines
        self.consumerTask = Task { @MainActor [weak self] in
            await self?.consumeLines(lines)
        }
    }

    // MARK: - Consumer loop

    private func consumeLines(_ lines: AsyncThrowingStream<String, Error>) async {
        do {
            for try await line in lines {
                if Task.isCancelled { break }
                let outputs = decoder.decode(line: line)
                for output in outputs {
                    dispatch(output)
                }
            }
            // EOF reached normally. Finish any in-flight turn.
            currentContinuation?.finish()
            currentContinuation = nil
        } catch {
            currentContinuation?.finish(throwing: error)
            currentContinuation = nil
            // Mark process dead so next stream() respawns.
            process = nil
        }
    }

    private func dispatch(_ output: StreamJSONDecoder.Output) {
        switch output {
        case .sessionStarted(let id, _):
            sessionID = id

        case .event(let event):
            guard let cont = currentContinuation else { return }
            cont.yield(event)
            if case .tokenLatency(let v) = event {
                updateLatencyWindow(with: v)
                cont.yield(.tokenEntropy(hesitationFromWindow()))
            }

        case .turnComplete:
            currentContinuation?.finish()
            currentContinuation = nil

        case .ignored:
            break

        case .decodeError(let msg):
            FileHandle.standardError.write(
                Data("[ClaudeCodeClient] decode error: \(msg)\n".utf8)
            )
        }
    }

    // MARK: - Hesitation window

    private func updateLatencyWindow(with value: Double) {
        latencyWindow.append(value)
        if latencyWindow.count > windowSize {
            latencyWindow.removeFirst(latencyWindow.count - windowSize)
        }
    }

    private func hesitationFromWindow() -> Double {
        guard latencyWindow.count >= 4 else { return 0 }
        let mean = latencyWindow.reduce(0, +) / Double(latencyWindow.count)
        let variance = latencyWindow
            .map { pow($0 - mean, 2) }
            .reduce(0, +) / Double(latencyWindow.count)
        let stddev = sqrt(variance)
        return max(0, min(1, stddev * 2))
    }
}
