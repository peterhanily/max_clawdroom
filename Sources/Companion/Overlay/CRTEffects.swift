import AppKit
import Observation
import SceneKit

/// CRT screen-space effects applied over the SceneKit render.
///
/// Phase 7.2: full-framebuffer post-process via SCNTechnique — RGB chromatic
/// aberration, horizontal roll, and scanlines applied as a DRAW_QUAD pass
/// over the rendered scene. Falls back to a per-material scanline modifier
/// when no Metal device is available.
@MainActor
final class CRTEffects {
    private weak var pet: Pet?
    private weak var scnView: SCNView?
    private let state: MaxClawdroomState
    /// Tracking handles are self-rearming; we don't need to hold them.
    /// Tearing the driver down stops scheduling further re-arm Tasks,
    /// which lets the observation graph drop the reference naturally.
    private var torndown: Bool = false

    // Technique path (Phase 7.2)
    private var crtTechnique: CRTTechnique?

    // Fallback: per-material modifier (Phase 7.1)
    private var modifierMaterials: [SCNMaterial] = []

    init(pet: Pet, state: MaxClawdroomState, scnView: SCNView) {
        self.pet = pet
        self.state = state
        self.scnView = scnView

        if let device = scnView.device, let technique = CRTTechnique(device: device) {
            crtTechnique = technique
            scnView.technique = technique.technique
        } else {
            installModifier(on: pet.node)
        }

        bindState()
    }

    func teardown() {
        if crtTechnique != nil {
            scnView?.technique = nil
            crtTechnique = nil
        } else {
            for m in modifierMaterials {
                var mods = m.shaderModifiers ?? [:]
                mods[.fragment] = nil
                m.shaderModifiers = mods.isEmpty ? nil : mods
                m.setValue(Float(0), forKey: "scanlineIntensity")
            }
            modifierMaterials.removeAll()
        }
        torndown = true
    }

    // MARK: - Modifier fallback

    private func installModifier(on root: SCNNode) {
        root.enumerateHierarchy { node, _ in
            guard let materials = node.geometry?.materials else { return }
            for m in materials {
                if m.lightingModel == .constant { continue }
                var modifiers = m.shaderModifiers ?? [:]
                modifiers[.fragment] = Self.fragmentSource
                m.shaderModifiers = modifiers
                m.setValue(Float(0.06), forKey: "scanlineIntensity")
                modifierMaterials.append(m)
            }
        }
        if let pet { applyIntensity(state.glitchIntensity, to: pet) }
    }

    private func bindState() {
        // Prime once, then self-rearm via observation tracking. Mirrors the
        // previous Combine .sink behaviour without the @Published dependency.
        if let pet { applyIntensity(state.glitchIntensity, to: pet) }
        trackIntensity()
    }

    private func trackIntensity() {
        withObservationTracking { [state] in
            _ = state.glitchIntensity
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.torndown, let pet = self.pet else { return }
                self.applyIntensity(self.state.glitchIntensity, to: pet)
                self.trackIntensity()
            }
        }
    }

    private func applyIntensity(_ g: Float, to pet: Pet) {
        guard crtTechnique == nil else { return }
        let scan: Float = g < 0.01 ? 0 : 0.06 + 0.12 * g
        for m in modifierMaterials {
            m.setValue(scan, forKey: "scanlineIntensity")
        }
    }

    // MARK: - Modifier shader source (fallback)

    private static let fragmentSource: String = """
    #pragma arguments
    float scanlineIntensity;

    #pragma body
    float scan = sin(_surface.position.y * 0.82);
    _output.color.rgb = _output.color.rgb * (1.0 - scanlineIntensity * (0.5 + 0.5 * scan));
    """
}
