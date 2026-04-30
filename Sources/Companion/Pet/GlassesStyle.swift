import SceneKit
import AppKit

enum GlassesStyle: String, CaseIterable {
    case aviator
    case round
    case wayfarer
    case cat_eye
    // New styles
    case sunglasses    // dark square shades
    case visor         // horizontal strip across both eyes (80s/cyberpunk)
    case oversized     // huge 70s frames
    case rimless       // thin-wire minimal

    static let all: [String] = GlassesStyle.allCases.map(\.rawValue)

    var displayName: String {
        switch self {
        case .aviator:    return "aviator"
        case .round:      return "round"
        case .wayfarer:   return "wayfarer"
        case .cat_eye:    return "cat-eye"
        case .sunglasses: return "sunglasses"
        case .visor:      return "visor"
        case .oversized:  return "oversized"
        case .rimless:    return "rimless"
        }
    }

    func frameGeometry() -> SCNBox {
        switch self {
        case .aviator:    return SCNBox(width: 24, height: 20,   length: 2.2, chamferRadius: 9)
        case .round:      return SCNBox(width: 22, height: 22,   length: 2.2, chamferRadius: 11)
        case .wayfarer:   return SCNBox(width: 26, height: 19,   length: 3.0, chamferRadius: 3)
        case .cat_eye:    return SCNBox(width: 26, height: 18,   length: 2.2, chamferRadius: 5)
        case .sunglasses: return SCNBox(width: 28, height: 20,   length: 3.2, chamferRadius: 3)
        case .visor:      return SCNBox(width: 56, height: 10,   length: 2.5, chamferRadius: 3)
        case .oversized:  return SCNBox(width: 32, height: 28,   length: 2.5, chamferRadius: 6)
        case .rimless:    return SCNBox(width: 22, height: 18,   length: 0.8, chamferRadius: 7)
        }
    }

    func lensGeometry() -> SCNBox {
        switch self {
        case .aviator:    return SCNBox(width: 20, height: 16.5, length: 1.5, chamferRadius: 7.5)
        case .round:      return SCNBox(width: 18, height: 18,   length: 1.8, chamferRadius: 9)
        case .wayfarer:   return SCNBox(width: 22, height: 15.5, length: 2.0, chamferRadius: 2)
        case .cat_eye:    return SCNBox(width: 22, height: 14.5, length: 1.8, chamferRadius: 3)
        case .sunglasses: return SCNBox(width: 24, height: 16,   length: 2.2, chamferRadius: 2.5)
        case .visor:      return SCNBox(width: 52, height: 7,    length: 1.8, chamferRadius: 2)
        case .oversized:  return SCNBox(width: 28, height: 24,   length: 1.8, chamferRadius: 5)
        case .rimless:    return SCNBox(width: 20, height: 16,   length: 0.8, chamferRadius: 6)
        }
    }

    // Z-rotation tilt: cat_eye tilts outer corners up.
    // Side is from CHARACTER perspective ("left" = character's left = x=-15 = viewer's right).
    func frameTiltZ(side: String) -> CGFloat {
        switch self {
        case .cat_eye: return side == "left" ? 0.18 : -0.18
        default: return 0
        }
    }

    /// Visor is one continuous bar across BOTH eyes rather than two
    /// separate lenses. The Pet builder reads this flag to decide
    /// whether to emit one wide node (visor) or per-eye pair (all others).
    var isBar: Bool { self == .visor }
}
