import AppKit
import SceneKit

/// Facial-hair overlays anchored to the head container. Built as small
/// SCN primitives parented to the head — they render in front of the skin
/// box but don't intrude on the mouth/teeth area animated by the
/// expression system, so poses keep working through a beard.
///
/// Node names use `part.facial.*` so the parts indexer groups them under
/// a new `facial` key, recolourable independently of `hair`.
enum FacialHair: String, CaseIterable {
    case clean
    case stubble
    case moustache
    case goatee
    case beard

    static let all: [String] = FacialHair.allCases.map(\.rawValue)

    func buildNodes(context ctx: HeadStyleContext) -> [SCNNode] {
        switch self {
        case .clean:     return []
        case .stubble:   return stubbleNodes(ctx)
        case .moustache: return moustacheNodes(ctx)
        case .goatee:    return goateeNodes(ctx)
        case .beard:     return beardNodes(ctx)
        }
    }

    // MARK: - Styles

    private func stubbleNodes(_ ctx: HeadStyleContext) -> [SCNNode] {
        // Thin dark wash across lower face — a short wide box sitting flush
        // with the skin. Low-emission dark desaturation reads as stubble
        // without adding thickness that'd clip the mouth.
        let geom = SCNBox(
            width: ctx.headWidth * 0.70,
            height: ctx.headHeight * 0.18,
            length: 1.0,
            chamferRadius: 2
        )
        geom.materials = [darkWash(ctx, alpha: 0.65)]
        let node = SCNNode(geometry: geom)
        node.name = "part.facial.stubble"
        node.position = SCNVector3(0, -ctx.headHeight * 0.22, ctx.headDepth / 2 + 0.3)
        return [node]
    }

    private func moustacheNodes(_ ctx: HeadStyleContext) -> [SCNNode] {
        let geom = SCNBox(
            width: ctx.headWidth * 0.38,
            height: 4,
            length: 3,
            chamferRadius: 1.5
        )
        geom.materials = [hairMat(ctx)]
        let node = SCNNode(geometry: geom)
        node.name = "part.facial.moustache"
        node.position = SCNVector3(0, -ctx.headHeight * 0.20, ctx.headDepth / 2 + 2)
        return [node]
    }

    private func goateeNodes(_ ctx: HeadStyleContext) -> [SCNNode] {
        let geom = SCNBox(
            width: 14,
            height: 14,
            length: 4,
            chamferRadius: 2
        )
        geom.materials = [hairMat(ctx)]
        let node = SCNNode(geometry: geom)
        node.name = "part.facial.goatee"
        node.position = SCNVector3(0, -ctx.headHeight * 0.40, ctx.headDepth / 2 + 2.2)
        return [node]
    }

    private func beardNodes(_ ctx: HeadStyleContext) -> [SCNNode] {
        // Full beard: wider box under the jaw, plus a moustache on top so
        // it reads as one connected piece.
        let jaw = SCNBox(
            width: ctx.headWidth * 0.88,
            height: ctx.headHeight * 0.34,
            length: ctx.headDepth * 0.6,
            chamferRadius: 8
        )
        jaw.materials = [hairMat(ctx)]
        let jawNode = SCNNode(geometry: jaw)
        jawNode.name = "part.facial.beard"
        jawNode.position = SCNVector3(0, -ctx.headHeight * 0.38, ctx.headDepth * 0.14)

        let stache = SCNBox(
            width: ctx.headWidth * 0.42,
            height: 5,
            length: 3.5,
            chamferRadius: 1.6
        )
        stache.materials = [hairMat(ctx)]
        let stacheNode = SCNNode(geometry: stache)
        stacheNode.name = "part.facial.moustache"
        stacheNode.position = SCNVector3(0, -ctx.headHeight * 0.20, ctx.headDepth / 2 + 1.8)
        return [jawNode, stacheNode]
    }

    private func hairMat(_ ctx: HeadStyleContext) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = ctx.hairColor
        m.roughness.contents = 0.45
        m.metalness.contents = 0.10
        return m
    }

    private func darkWash(_ ctx: HeadStyleContext, alpha: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        let base = (ctx.hairColor.usingColorSpace(.sRGB) ?? ctx.hairColor)
            .blended(withFraction: 0.6, of: .black) ?? ctx.hairColor
        m.diffuse.contents = base.withAlphaComponent(alpha)
        m.transparency = alpha
        m.roughness.contents = 0.85
        m.metalness.contents = 0.0
        return m
    }
}
