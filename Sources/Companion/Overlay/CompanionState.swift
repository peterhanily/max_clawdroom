import Foundation
import Observation

/// The character's current cognitive/presentational state. Drives the
/// screen-space CRT post-process (§2.3) and — in later phases — the per-part
/// animation state machine (§7).
///
/// Phase 0 only needs the intensity plumbing so the post-process technique
/// has something to read. The full state machine wires up in Phase 2.
enum MaxClawdroomStage: Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case toolUse(tool: String)
    case error
    case sleeping

    /// Baseline glitch intensity for the stage, on a 0..1 scale. Transient
    /// effects (glitch spikes, RGB splits on events) are layered on top of
    /// this via `MaxClawdroomState.triggerGlitch`.
    var baseGlitchIntensity: Float {
        switch self {
        case .idle:       return 0.20
        case .listening:  return 0.30
        case .thinking:   return 0.70
        case .speaking:   return 0.30
        case .toolUse:    return 0.45
        case .error:      return 0.90
        case .sleeping:   return 0.05
        }
    }
}

@Observable
@MainActor
final class MaxClawdroomState {
    private(set) var stage: MaxClawdroomStage = .idle

    /// Current composite glitch intensity fed into the CRT post-process
    /// (0..1). Combines the stage baseline with any transient spike.
    private(set) var glitchIntensity: Float = MaxClawdroomStage.idle.baseGlitchIntensity

    /// User/accessibility override. When true, the post-process holds a
    /// minimal steady intensity and ignores transient spikes so the pipeline
    /// stays consistent with `NSAccessibilityReduceMotion`.
    var reduceMotion: Bool = false {
        didSet { rebuildIntensity() }
    }

    @ObservationIgnored private var transientSpike: Float = 0
    @ObservationIgnored private var spikeDecayWorkItem: DispatchWorkItem?

    func setStage(_ newStage: MaxClawdroomStage) {
        stage = newStage
        rebuildIntensity()
    }

    /// Fires a transient glitch — intensity spike on top of the stage baseline
    /// that decays linearly back to zero over `duration`. Used for RGB split
    /// events, tool-call signatures, and error flashes.
    func triggerGlitch(intensity: Float, duration: TimeInterval) {
        guard !reduceMotion else { return }
        transientSpike = max(transientSpike, max(0, min(1, intensity)))
        rebuildIntensity()

        spikeDecayWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.transientSpike = 0
            self?.rebuildIntensity()
        }
        spikeDecayWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func rebuildIntensity() {
        if reduceMotion {
            glitchIntensity = 0
            return
        }
        let base = stage.baseGlitchIntensity
        glitchIntensity = min(1.0, base + transientSpike)
    }
}
