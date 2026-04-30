import Foundation
import Observation

/// Active-channel reachability + latency tracker. One instance,
/// re-targeted whenever the active channel changes. Drives the
/// expression-as-body signal in `ChannelStageDirector` and the
/// status badge in the menu / settings.
///
/// Probe strategy: a cheap `GET /v1/models` (1.5s timeout) every
/// 15s on the OpenAI-SSE channels. `.claudeCodeCLI` channels skip
/// probing entirely — the subprocess is local and either works or
/// the user has bigger problems than a status dot.
@Observable
@MainActor
final class ChannelHealth {
    static let shared = ChannelHealth()

    enum State: Equatable {
        case unknown
        case live
        case slow
        case unreachable
        case unauthorized
    }

    private(set) var state: State = .unknown
    /// Last successful probe round-trip in seconds. Smoothed via
    /// exponential moving average so a single slow sample doesn't
    /// flip Max into "focused" repeatedly.
    private(set) var latencyEMA: Double = 0

    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// Channel id this health tracker is currently following. Re-armed
    /// on every active-channel change so a user-driven switch resets
    /// state immediately rather than waiting for the next probe tick.
    @ObservationIgnored private var followingID: UUID?

    @ObservationIgnored private var authObserver: NSObjectProtocol?

    private init() {
        retarget()
        observer = NotificationCenter.default.addObserver(
            forName: .companionActiveChannelChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.retarget() }
        }
        // Stream-side 401: flip state immediately so the expression /
        // menu glyph reflects the failure without waiting for the next
        // probe tick (up to 15s).
        authObserver = NotificationCenter.default.addObserver(
            forName: .companionChannelAuthFailed,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Extract userInfo before the Task closure so we don't
            // capture the non-Sendable Notification across actors.
            let raw = note.userInfo?["channelID"] as? String
            Task { @MainActor in
                guard let self else { return }
                if raw == self.followingID?.uuidString {
                    self.state = .unauthorized
                }
            }
        }
    }

    isolated deinit {
        probeTask?.cancel()
        if let obs = observer {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = authObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// Force a probe now — used by the menu's "Channels" submenu open
    /// and by the AddChannel sheet when a fresh channel becomes active.
    func probeNow() {
        Task { await probeOnce() }
    }

    private func retarget() {
        let active = ChannelStore.shared.active
        followingID = active.id
        state = .unknown
        latencyEMA = 0
        probeTask?.cancel()
        guard active.kind != .claudeCodeCLI else {
            // Subprocess "always live" — no remote endpoint to probe.
            state = .live
            return
        }
        probeTask = Task { [weak self] in
            await self?.probeLoop()
        }
    }

    private func probeLoop() async {
        // First probe immediately, then settle into 15s cadence. Backoff
        // to 60s after sustained unreachability so we're not thrashing
        // the radio when the host is genuinely off.
        var interval: UInt64 = 15_000_000_000
        while !Task.isCancelled {
            await probeOnce()
            interval = (state == .unreachable)
                ? min(60_000_000_000, interval * 2)
                : 15_000_000_000
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    private func probeOnce() async {
        let active = ChannelStore.shared.active
        guard active.id == followingID else { return }
        guard active.kind != .claudeCodeCLI else { return }
        guard let url = modelsURL(from: active.endpoint) else {
            state = .unreachable
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        if active.authRef == .bearerInKeychain,
           let bearer = ChannelStore.shared.bearer(for: active.id) {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        let started = Date()
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let elapsed = Date().timeIntervalSince(started)
            guard let http = resp as? HTTPURLResponse else {
                state = .unreachable
                return
            }
            switch http.statusCode {
            case 200..<300:
                latencyEMA = (latencyEMA == 0) ? elapsed : (0.7 * latencyEMA + 0.3 * elapsed)
                state = (latencyEMA > 1.2) ? .slow : .live
            case 401:
                state = .unauthorized
            default:
                state = .unreachable
            }
        } catch {
            state = .unreachable
        }
    }

    private func modelsURL(from chatCompletionsURL: String) -> URL? {
        guard var components = URLComponents(string: chatCompletionsURL) else { return nil }
        var path = components.path
        if path.hasSuffix("/chat/completions") {
            path = String(path.dropLast("/chat/completions".count)) + "/models"
        } else if path.hasSuffix("/") {
            path += "models"
        } else {
            path += "/models"
        }
        components.path = path
        return components.url
    }
}
