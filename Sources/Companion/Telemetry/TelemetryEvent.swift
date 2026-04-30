import Foundation

/// Namespaced signal identifiers. Adding a new signal? Add it here AND list
/// it in SignalRegistry so the system prompt auto-generator picks it up.
enum TelemetrySignal {
    // Discrete events — fire once. Event.value is nil.
    static let toolStart     = "tool.start"
    static let toolEnd       = "tool.end"
    static let toolError     = "tool.error"
    /// Emitted when a tool's stdout/stderr arrives back via the
    /// subprocess's tool_result user messages. Separate from tool.end
    /// because the result can lag the tool_use by many seconds.
    static let toolResult    = "tool.result"
    static let toolRead      = "tool.read"
    static let toolWrite     = "tool.write"
    static let toolEdit      = "tool.edit"
    static let toolBash      = "tool.bash"
    static let toolGrep      = "tool.grep"
    static let toolGlob      = "tool.glob"
    static let toolWeb       = "tool.web"
    static let subagentSpawn = "subagent.spawn"
    static let subagentEnd   = "subagent.complete"

    // Continuous signals — Event.value is in [0, 1].
    /// Perceived hesitation: inter-token latency variance. Anthropic
    /// Messages API does not expose logprobs, so this is a timing-based
    /// proxy, not true per-token entropy.
    static let tokenHesitation = "token.hesitation"
    static let latency         = "latency"
    static let activeTools     = "tool.active_count"

    // Music-reactive signals (NowPlayingObserver). All gated on
    // Prefs.musicReactiveEnabled — the observer simply doesn't run when
    // the toggle is off so these never fire.
    /// Discrete event when track changes. payload: title, artist, album.
    static let musicTrackChanged = "music.track_changed"
    /// Discrete event when playback toggles. payload: playing (Bool).
    static let musicPlayState    = "music.play_state"
    /// Continuous: derived tempo / energy estimate, normalised 0..1.
    /// Fed to BindingEngine so an agent-bound part (e.g. tie pulse,
    /// shoe tap) reacts to the music's intensity. The estimate is
    /// crude (BPM-from-metadata when available, else playbackRate
    /// heuristic) — it's a feel knob, not a beat-detection engine.
    static let musicTempo        = "music.tempo"
}

/// A telemetry event pushed through the TelemetryBus.
/// Discrete events carry nil `value`; continuous signals carry [0,1].
struct TelemetryEvent {
    let signal: String
    let value: Double?
    let payload: [String: Any]?
    let timestamp: Date

    init(
        signal: String,
        value: Double? = nil,
        payload: [String: Any]? = nil,
        at ts: Date = Date()
    ) {
        self.signal = signal
        self.value = value
        self.payload = payload
        self.timestamp = ts
    }
}
