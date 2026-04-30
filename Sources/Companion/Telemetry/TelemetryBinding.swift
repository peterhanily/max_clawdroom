import AppKit
import Foundation

/// A runtime connection from a telemetry signal to a body-part sink.
/// Authored by the agent via `[action]{"op":"bind",...}[/action]`.
struct TelemetryBinding: Identifiable {
    let id: UUID
    let signal: String
    let part: String
    let mode: BindingMode
    let params: BindingParams

    init(
        id: UUID = UUID(),
        signal: String,
        part: String,
        mode: BindingMode,
        params: BindingParams = .init()
    ) {
        self.id = id
        self.signal = signal
        self.part = part
        self.mode = mode
        self.params = params
    }
}

enum BindingMode: String, CaseIterable {
    case flash       // discrete: tint briefly, revert (params: color, duration)
    case ripple      // discrete: brief color pulse (params: color, duration)
    case pulse       // continuous: scale oscillates (params: amplitude)
    case shake       // continuous: rotation jitter (params: amplitude)
    case tint        // continuous: lerp diffuse toward target (params: color)
    case tilt        // continuous: rotate on Z (params: amplitude)
    case brightness  // continuous: emission intensity
}

struct BindingParams {
    let color: NSColor?
    let amplitude: Double?
    let duration: Double?
    let minValue: Double?
    let maxValue: Double?

    init(
        color: NSColor? = nil,
        amplitude: Double? = nil,
        duration: Double? = nil,
        minValue: Double? = nil,
        maxValue: Double? = nil
    ) {
        self.color = color
        self.amplitude = amplitude
        self.duration = duration
        self.minValue = minValue
        self.maxValue = maxValue
    }
}
