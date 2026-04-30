import CoreGraphics
import SceneKit

/// Body-silhouette presets. Applied as a non-uniform scale on Pet's body
/// node — deliberately simple: no geometry remesh, no rig changes, just a
/// single scale that reads as "lanky" or "stocky" at a glance.
///
/// `default` restores identity scale so ⌘Z and "reset" paths are trivial.
enum Physique: String, CaseIterable {
    case lanky
    case `default`
    case stocky

    static let all: [String] = Physique.allCases.map(\.rawValue)

    /// Non-uniform scale to apply to the `body` node. Axis breakdown:
    /// X = width (narrower / wider), Y = height (taller / shorter).
    /// Z tracks X so the silhouette reads consistently in 3/4 view.
    var bodyScale: SCNVector3 {
        switch self {
        case .lanky:   return SCNVector3(0.92, 1.10, 0.92)
        case .default: return SCNVector3(1.00, 1.00, 1.00)
        case .stocky: return SCNVector3(1.12, 0.88, 1.12)
        }
    }
}

/// Agent-addressable facial feature morphs. Each morph is a single-axis
/// scale on a specific named node — lightweight, avoids SCNMorpher setup,
/// and works on existing primitive geometry.
///
/// Values clamp to [0.5, 1.5]; 1.0 is authored rest. Applied to the Y
/// axis only so features grow/shrink rather than fattening sideways.
enum FaceMorphFeature: String, CaseIterable {
    case nose
    case brow

    static let all: [String] = FaceMorphFeature.allCases.map(\.rawValue)

    /// Nodes to scale for this morph. Y-axis scaling only; X/Z stay at 1.
    var targetNodeNames: [String] {
        switch self {
        case .nose: return ["part.skin.nose"]
        case .brow: return ["part.brow.left", "part.brow.right"]
        }
    }
}
