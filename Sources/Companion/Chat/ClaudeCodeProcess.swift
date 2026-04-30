import Foundation

/// Long-lived `claude` subprocess with bidirectional JSONL over stdin/stdout.
/// Mirrors the pattern the @anthropic-ai/claude-agent-sdk TypeScript SDK uses:
/// spawn once, feed user turns as JSONL lines on stdin, consume stream-json
/// events as JSONL lines on stdout. The subprocess stays alive across turns.
///
/// stderr is drained continuously into a ring buffer so the OS pipe buffer
/// never fills (unread stderr deadlocks the child).
///
/// `nonisolated` — this is a subprocess wrapper, not a UI type. The
/// readabilityHandler callbacks fire off-main by design; the class is
/// internally lock-protected for shared state (stderr tail, stdout line
/// buffer) so Swift 6 concurrency sees a race-free surface.
nonisolated final class ClaudeCodeProcess: @unchecked Sendable {
    struct LaunchConfig: Sendable {
        let executablePath: String
        let cwd: String
        let permissionMode: String
        let allowedTools: String?
        let model: String?
        let appendSystemPrompt: String?
        let resumeSessionID: String?
    }

    enum LaunchError: Error, LocalizedError {
        case executableMissing(String)
        case failedToStart(String)
        case terminated(Int32, tail: String)

        var errorDescription: String? {
            switch self {
            case .executableMissing(let path):
                return "claude CLI not found at \(path). Install Claude Code and try again."
            case .failedToStart(let msg):
                return "Failed to start claude: \(msg)"
            case .terminated(let code, let tail):
                return "claude exited with code \(code). \(tail)"
            }
        }
    }

    private let config: LaunchConfig
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let stderrLock = NSLock()
    private var stderrTail: [String] = []
    private let stderrTailLimit = 200
    /// Accumulates stdout bytes until a newline delimiter is seen. Shared
    /// between the readabilityHandler (off-main) and nothing else —
    /// protected by `stdoutBufferLock` so strict concurrency can reason
    /// about the mutation. Previously a function-local `var buffer` inside
    /// start(), which Swift 6 flagged as a captured-var race.
    private let stdoutBufferLock = NSLock()
    private var stdoutBuffer = Data()
    /// Hard cap on how many bytes we'll hold waiting for a newline.
    /// `claude --output-format stream-json` emits one JSONL event per line;
    /// a single line should be KB at most, even with large tool-call
    /// payloads. 8 MB is wildly generous; anything beyond that means the
    /// subprocess is misbehaving or writing binary junk and we want to
    /// surface a clear error rather than silently accumulate RAM.
    private static let maxStdoutBufferBytes = 8 * 1024 * 1024

    /// AsyncThrowingStream of raw JSONL lines from stdout. One line per element.
    /// Finishes when the process exits or on decode error.
    let lines: AsyncThrowingStream<String, Error>
    private let linesContinuation: AsyncThrowingStream<String, Error>.Continuation

    init(config: LaunchConfig) {
        self.config = config
        self.process = Process()
        self.stdinPipe = Pipe()
        self.stdoutPipe = Pipe()
        self.stderrPipe = Pipe()

        var continuation: AsyncThrowingStream<String, Error>.Continuation!
        self.lines = AsyncThrowingStream { continuation = $0 }
        self.linesContinuation = continuation
    }

    // MARK: - Lifecycle

    func start() throws {
        guard FileManager.default.isExecutableFile(atPath: config.executablePath) else {
            throw LaunchError.executableMissing(config.executablePath)
        }

        process.executableURL = URL(fileURLWithPath: config.executablePath)
        process.arguments = buildArguments()
        process.currentDirectoryURL = URL(fileURLWithPath: config.cwd)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Sanitise the inherited environment before launching the
        // subprocess. DYLD_* injection from a poisoned ~/.zshrc would
        // otherwise let any local shell config inject a dylib into the
        // claude CLI we're spawning. Same defense for LD_PRELOAD-shaped
        // attacks. We pass through PATH, HOME, USER, LANG, TERM, plus
        // anything the user explicitly opted into via ANTHROPIC_* /
        // CLAUDE_* (the CLI's documented config surface).
        var env = ProcessInfo.processInfo.environment
        for key in env.keys
        where key.hasPrefix("DYLD_")
            || key.hasPrefix("LD_")
            || key == "DYLD_INSERT_LIBRARIES"
            || key == "LD_PRELOAD" {
            env.removeValue(forKey: key)
        }
        process.environment = env

        // Drain stderr into a ring buffer so the pipe never blocks the child.
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            if let s = String(data: data, encoding: .utf8) {
                self.appendStderr(s)
            }
        }

        // Stream stdout lines into the AsyncThrowingStream. Buffer lives
        // on the instance (lock-protected) so the handler closure doesn't
        // capture mutable local state — Swift 6 strict-concurrency safe.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            self.ingestStdout(chunk)
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            // Stop readability handlers.
            self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil

            if proc.terminationStatus == 0 {
                self.linesContinuation.finish()
            } else {
                let tail = self.recentStderr()
                self.linesContinuation.finish(
                    throwing: LaunchError.terminated(proc.terminationStatus, tail: tail)
                )
            }
        }

        do {
            try process.run()
        } catch {
            throw LaunchError.failedToStart(error.localizedDescription)
        }
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
        linesContinuation.finish()
    }

    var isRunning: Bool { process.isRunning }

    // MARK: - Stdin (user turns)

    /// Sends one user-message JSONL object on stdin. Thread-safe.
    /// Throws `LaunchError.terminated` if the subprocess has already died so
    /// the caller sees the stderr tail instead of a generic write failure.
    /// SIGPIPE on dead-stdin is squelched app-wide in `AppDelegate`, so the
    /// write() call raises a Swift error rather than crashing the process.
    func sendUserMessage(_ text: String) throws {
        guard process.isRunning else {
            throw LaunchError.terminated(process.terminationStatus, tail: recentStderr())
        }
        let obj: [String: Any] = [
            "type": "user",
            "session_id": "",
            "message": [
                "role": "user",
                "content": [
                    ["type": "text", "text": text]
                ]
            ],
            "parent_tool_use_id": NSNull()
        ]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [])
        var line = data
        line.append(0x0A)
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: line)
        } catch {
            throw LaunchError.terminated(process.terminationStatus, tail: recentStderr())
        }
    }

    // MARK: - Stdout line reassembly

    /// Thread-safe stdout buffer ingest. Called from the readabilityHandler
    /// off-main; takes the lock, accumulates bytes, and yields completed
    /// lines through the AsyncThrowingStream continuation. The continuation
    /// is itself Sendable and safe to call from any thread.
    private func ingestStdout(_ chunk: Data) {
        stdoutBufferLock.lock()
        defer { stdoutBufferLock.unlock() }
        if chunk.isEmpty {
            // EOF — flush any trailing line without newline.
            if !stdoutBuffer.isEmpty, let tail = String(data: stdoutBuffer, encoding: .utf8) {
                linesContinuation.yield(tail)
                stdoutBuffer = Data()
            }
            return
        }
        stdoutBuffer.append(chunk)
        // Overflow guard. A legitimate stream-json line is KB at most. If
        // the buffer balloons, the subprocess is stuck writing without a
        // newline — drop the stream loudly rather than pinning RAM.
        if stdoutBuffer.count > Self.maxStdoutBufferBytes {
            let sample = stdoutBuffer.prefix(200)
            let preview = String(data: sample, encoding: .utf8) ?? "(binary)"
            stdoutBuffer = Data()
            linesContinuation.finish(
                throwing: LaunchError.failedToStart(
                    "stdout buffer overflowed (\(Self.maxStdoutBufferBytes) bytes with no newline): \(preview)"
                )
            )
            return
        }
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.prefix(upTo: nl)
            // `Data.firstIndex(of:)` returns an ABSOLUTE Data.Index (offset
            // into the underlying buffer), not a 0-based offset into the
            // current slice. After the first `removeFirst`, the slice's
            // startIndex shifts forward, so on subsequent iterations
            // `nl + 1` is much larger than `count` and `removeFirst(_:)`
            // traps with "Can't remove more items than the collection
            // contains". Compute the byte count via `distance` instead so
            // it's correct regardless of where startIndex is.
            let bytesToRemove = stdoutBuffer.distance(from: stdoutBuffer.startIndex, to: nl) + 1
            stdoutBuffer.removeFirst(bytesToRemove)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                linesContinuation.yield(line)
            }
        }
    }

    // MARK: - Stderr ring buffer

    private func appendStderr(_ chunk: String) {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        for line in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
            stderrTail.append(String(line))
            if stderrTail.count > stderrTailLimit {
                stderrTail.removeFirst(stderrTail.count - stderrTailLimit)
            }
        }
    }

    func recentStderr() -> String {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        return stderrTail.suffix(20).joined(separator: "\n")
    }

    // MARK: - Argv

    private func buildArguments() -> [String] {
        var args: [String] = [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-mode", config.permissionMode
        ]
        if let tools = config.allowedTools, !tools.isEmpty {
            args.append("--allowed-tools")
            args.append(tools)
        }
        if let model = config.model, !model.isEmpty {
            args.append("--model")
            args.append(model)
        }
        if let sys = config.appendSystemPrompt, !sys.isEmpty {
            args.append("--append-system-prompt")
            args.append(sys)
        }
        if let resume = config.resumeSessionID, !resume.isEmpty {
            args.append("--resume")
            args.append(resume)
        }
        return args
    }
}
