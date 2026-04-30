import Foundation

/// Introspectable catalog of available signals + modes. Drives the system
/// prompt so the agent knows exactly what it has to work with, and stays in
/// sync automatically when we add new signals.
enum SignalRegistry {
    struct Entry {
        let name: String
        let description: String
    }

    static let discreteSignals: [Entry] = [
        .init(name: TelemetrySignal.toolStart, description: "any tool invocation starts"),
        .init(name: TelemetrySignal.toolEnd, description: "any tool invocation ends"),
        .init(name: TelemetrySignal.toolError, description: "a tool call fails"),
        .init(name: TelemetrySignal.toolRead, description: "Read tool fires"),
        .init(name: TelemetrySignal.toolWrite, description: "Write tool fires"),
        .init(name: TelemetrySignal.toolEdit, description: "Edit tool fires"),
        .init(name: TelemetrySignal.toolBash, description: "Bash tool fires"),
        .init(name: TelemetrySignal.toolGrep, description: "Grep tool fires"),
        .init(name: TelemetrySignal.toolGlob, description: "Glob tool fires"),
        .init(name: TelemetrySignal.toolWeb, description: "WebFetch/WebSearch tool fires"),
        .init(name: TelemetrySignal.subagentSpawn, description: "a Task subagent is dispatched"),
        .init(name: TelemetrySignal.subagentEnd, description: "a subagent returns"),
    ]

    static let continuousSignals: [Entry] = [
        .init(name: TelemetrySignal.tokenHesitation, description: "perceived hesitation from inter-token timing variance, 0..1 (bound to head/shake by default)"),
        .init(name: TelemetrySignal.latency, description: "inter-token latency, 0..1"),
        .init(name: TelemetrySignal.activeTools, description: "active tool count, 0..1"),
        .init(name: TelemetrySignal.musicTempo, description: "music tempo / energy when Now Playing is active, 0..1 (off unless musicReactiveEnabled)"),
    ]

    static let modes: [Entry] = [
        .init(name: "flash", description: "discrete; tint part briefly then revert. params: color, duration"),
        .init(name: "ripple", description: "discrete; brief color pulse. params: color, duration"),
        .init(name: "pulse", description: "continuous; scale oscillates. params: amplitude"),
        .init(name: "shake", description: "continuous; rotation jitter. params: amplitude"),
        .init(name: "tint", description: "continuous; lerp diffuse toward target. params: color"),
        .init(name: "tilt", description: "continuous; rotate on Z. params: amplitude"),
        .init(name: "brightness", description: "continuous; emission intensity"),
    ]

    static let availableParts: [String] = [
        "suit", "hair", "tie", "shirt", "skin", "frame", "lens", "shoe",
        "mouth", "teeth"
    ]
}
