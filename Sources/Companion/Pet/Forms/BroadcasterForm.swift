import AppKit
import SceneKit

/// A retro-broadcast digital character built entirely from SceneKit primitives.
/// Every node that carries a mutable color is tagged with a `part.<name>`
/// identifier so the agent can re-color it at runtime via action messages.
///
/// Node origin is at the feet.
struct BroadcasterForm: Form, HeadStyleCustomizable {
    var displayName: String { "Broadcaster" }
    var tint: NSColor { Palette.default.suit }
    var approximateRadius: CGFloat { 90 }
    var walkEagerness: Double { 0.5 }
    var baseY: CGFloat { 60 }
    var walkBobAmplitude: CGFloat { 0 }
    var walkLeanAngle: CGFloat { 0.03 }
    var walkStepAmplitude: CGFloat { 6 }

    var bubbleAccent: NSColor { Palette.default.tie }

    var hitBoundsRelative: CGRect {
        CGRect(x: -95, y: -10, width: 190, height: 340)
    }

    var greeting: String? {
        "H-h-hey there. Welcome to the s-studio."
    }

    func attachBehaviors(to pet: Pet) {
        pet.startPeriodicJitter()
        pet.startPeriodicBlink()
        pet.startIdlePupilDrift()
    }

    // MARK: - Expressions
    //
    // The brow/head/lens rest pose is the default — each expression nudges
    // those nodes and Pet.poseExpression smoothly animates to the new
    // transform. Positions here are DELTAS relative to wherever the node
    // was authored; we avoid setting `position` for head/lens so their
    // rest placements stay intact.

    func mouthShape(for expression: MaxClawdroomExpression) -> String {
        // Mapping rationale per expression — keep these in sync with
        // the 5 shape nodes built in makeGrin(): arc / smile / frown /
        // open / flat.
        switch expression {
        case .neutral:     return "arc"
        case .focused:     return "flat"     // tight mouth, concentration
        case .curious:     return "arc"      // default line; brow does the work
        case .amused:      return "smile"    // wry / enjoying
        case .uncertain:   return "flat"     // hedging
        case .surprised:   return "open"     // "oh"
        case .concerned:   return "frown"    // something's wrong
        case .tired:       return "flat"     // powering down
        case .excited:     return "smile"    // big yes
        case .thoughtful:  return "arc"      // soft pondering, not committed
        case .skeptical:   return "flat"     // "really?"
        case .sleepy:      return "flat"
        case .angry:       return "frown"    // rare
        case .embarrassed: return "flat"     // small
        case .devious:     return "smile"    // sly
        case .determined:  return "flat"     // squared
        case .confused:    return "flat"     // "??"
        case .dreamy:      return "smile"    // soft sigh
        case .smug:        return "smile"    // "told you"
        case .shy:         return "arc"      // neutral but eyes/head do work
        }
    }

    var expressionPoses: [MaxClawdroomExpression: ExpressionPose] {
        // Helper — 5 hair wedges `part.hair.0` … `part.hair.4`. Each pose
        // can tilt all five consistently (up = wedges rotate closer to
        // vertical; down = more forward-flopping).
        func hairDelta(xOffset: Float, yOffset: Float = 0) -> [String: ExpressionPose.NodeDelta] {
            var out: [String: ExpressionPose.NodeDelta] = [:]
            for i in 0..<5 {
                // Authored rest x = -Double.pi / 5.5 ≈ -0.571. xOffset is
                // added to that via our delta-as-absolute engine, so we
                // reconstruct authored rest + offset.
                let restX = Float(-Double.pi / 5.5)
                let t = Float(i) / 4.0 - 0.5
                let restY = Float(0)
                let restZ = -t * 0.14
                out["part.hair.\(i)"] = .init(
                    eulerAngles: SCNVector3(restX + xOffset, restY, restZ),
                    position: yOffset != 0 ? SCNVector3(0, yOffset, 0) : nil
                )
            }
            return out
        }

        func merge(
            _ a: [String: ExpressionPose.NodeDelta],
            _ b: [String: ExpressionPose.NodeDelta]
        ) -> [String: ExpressionPose.NodeDelta] {
            a.merging(b) { _, new in new }
        }

        return [
            .neutral: ExpressionPose(
                duration: 0.4,
                nodes: merge(hairDelta(xOffset: 0), [
                    "part.brow.left":  .init(eulerAngles: SCNVector3Zero, scale: SCNVector3(1, 1, 1)),
                    "part.brow.right": .init(eulerAngles: SCNVector3Zero, scale: SCNVector3(1, 1, 1)),
                    "part.head":       .init(eulerAngles: SCNVector3(-0.08, 0, 0)),
                    "part.eye.left":   .init(scale: SCNVector3(1, 1, 1)),
                    "part.eye.right":  .init(scale: SCNVector3(1, 1, 1))
                ])
            ),
            .focused: ExpressionPose(
                duration: 0.35,
                nodes: merge(hairDelta(xOffset: -0.08), [
                    // Brows tilt inward hard — knit of concentration.
                    "part.brow.left":  .init(eulerAngles: SCNVector3(0, 0,  0.45), scale: SCNVector3(1, 0.8, 1), position: SCNVector3(2, -2.5, 0)),
                    "part.brow.right": .init(eulerAngles: SCNVector3(0, 0, -0.45), scale: SCNVector3(1, 0.8, 1), position: SCNVector3(-2, -2.5, 0)),
                    "part.head":       .init(eulerAngles: SCNVector3(-0.28, 0, 0)),
                    "part.eye.left":   .init(scale: SCNVector3(1, 0.85, 1)),
                    "part.eye.right":  .init(scale: SCNVector3(1, 0.85, 1))
                ])
            ),
            .curious: ExpressionPose(
                duration: 0.3,
                nodes: merge(hairDelta(xOffset: -0.04), [
                    // One brow up way high, head tilts.
                    "part.brow.left":  .init(eulerAngles: SCNVector3(0, 0, 0.05), position: SCNVector3(0, 5, 0)),
                    "part.brow.right": .init(eulerAngles: SCNVector3(0, 0, -0.12)),
                    "part.head":       .init(eulerAngles: SCNVector3(-0.02, 0, 0.22))
                ])
            ),
            .amused: ExpressionPose(
                duration: 0.3,
                nodes: merge(hairDelta(xOffset: -0.15, yOffset: 1.5), [
                    // Both brows shoot up, eyes widen. Hair bounces up.
                    "part.brow.left":  .init(eulerAngles: SCNVector3(0, 0, -0.08), position: SCNVector3(0, 4, 0)),
                    "part.brow.right": .init(eulerAngles: SCNVector3(0, 0,  0.08), position: SCNVector3(0, 4, 0)),
                    "part.eye.left":   .init(scale: SCNVector3(1.08, 1.15, 1)),
                    "part.eye.right":  .init(scale: SCNVector3(1.08, 1.15, 1)),
                    "part.head":       .init(eulerAngles: SCNVector3(-0.04, 0, 0))
                ])
            ),
            .uncertain: ExpressionPose(
                duration: 0.35,
                nodes: merge(hairDelta(xOffset: 0.02), [
                    // Brows knit inward and down hard. Eyes narrow significantly.
                    "part.brow.left":  .init(eulerAngles: SCNVector3(0, 0,  0.55), position: SCNVector3(2, -3, 0)),
                    "part.brow.right": .init(eulerAngles: SCNVector3(0, 0, -0.55), position: SCNVector3(-2, -3, 0)),
                    "part.eye.left":   .init(scale: SCNVector3(1, 0.55, 1)),
                    "part.eye.right":  .init(scale: SCNVector3(1, 0.55, 1)),
                    "part.head":       .init(eulerAngles: SCNVector3(-0.18, 0, -0.08))
                ])
            ),
            .surprised: ExpressionPose(
                duration: 0.18,
                nodes: merge(hairDelta(xOffset: -0.25, yOffset: 3), [
                    // Brows JUMP up, eyes go wide, hair nearly straight up.
                    "part.brow.left":  .init(position: SCNVector3(0, 8, 0)),
                    "part.brow.right": .init(position: SCNVector3(0, 8, 0)),
                    "part.eye.left":   .init(scale: SCNVector3(1.2, 1.35, 1)),
                    "part.eye.right":  .init(scale: SCNVector3(1.2, 1.35, 1)),
                    "part.head":       .init(eulerAngles: SCNVector3(0.04, 0, 0))
                ])
            ),
            .concerned: ExpressionPose(
                duration: 0.35,
                nodes: merge(hairDelta(xOffset: 0.05, yOffset: -1), [
                    // Brows furrowed HARD.
                    "part.brow.left":  .init(eulerAngles: SCNVector3(0, 0,  0.62), position: SCNVector3(3, -3.5, 0)),
                    "part.brow.right": .init(eulerAngles: SCNVector3(0, 0, -0.62), position: SCNVector3(-3, -3.5, 0)),
                    "part.eye.left":   .init(scale: SCNVector3(1, 0.70, 1)),
                    "part.eye.right":  .init(scale: SCNVector3(1, 0.70, 1)),
                    "part.head":       .init(eulerAngles: SCNVector3(-0.32, 0, 0))
                ])
            ),
            .tired: ExpressionPose(
                duration: 0.6,
                nodes: merge(hairDelta(xOffset: 0.2, yOffset: -2.5), [
                    // Brows flat & drooping, eyes nearly closed, head deeply droops, hair flops forward.
                    "part.brow.left":  .init(eulerAngles: SCNVector3(0, 0,  0.08), position: SCNVector3(0, -3, 0)),
                    "part.brow.right": .init(eulerAngles: SCNVector3(0, 0, -0.08), position: SCNVector3(0, -3, 0)),
                    "part.eye.left":   .init(scale: SCNVector3(1, 0.15, 1)),
                    "part.eye.right":  .init(scale: SCNVector3(1, 0.15, 1)),
                    "part.head":       .init(eulerAngles: SCNVector3(-0.40, 0, 0))
                ])
            ),
            // MARK: Phase D
            .excited: ExpressionPose(
                duration: 0.18,
                nodes: merge(hairDelta(xOffset: -0.30, yOffset: 4), [
                    // Even higher than surprised — brows fly up, eyes pop wide, head tips back.
                    "part.brow.left":  .init(eulerAngles: SCNVector3(0, 0, -0.04), position: SCNVector3(0, 10, 0)),
                    "part.brow.right": .init(eulerAngles: SCNVector3(0, 0,  0.04), position: SCNVector3(0, 10, 0)),
                    "part.eye.left":   .init(scale: SCNVector3(1.25, 1.40, 1)),
                    "part.eye.right":  .init(scale: SCNVector3(1.25, 1.40, 1)),
                    "part.head":       .init(eulerAngles: SCNVector3(0.10, 0, 0))
                ])
            ),
            .thoughtful: ExpressionPose(
                duration: 0.5,
                nodes: merge(hairDelta(xOffset: 0.02), [
                    // Left brow raised a touch, head tilts down + slightly to right, eyes half-lidded.
                    "part.brow.left":  .init(eulerAngles: SCNVector3(0, 0,  0.04), position: SCNVector3(0, 2, 0)),
                    "part.brow.right": .init(eulerAngles: SCNVector3(0, 0, -0.22)),
                    "part.eye.left":   .init(scale: SCNVector3(1, 0.70, 1)),
                    "part.eye.right":  .init(scale: SCNVector3(1, 0.70, 1)),
                    "part.head":       .init(eulerAngles: SCNVector3(-0.22, 0, 0.12))
                ])
            ),
            .skeptical: ExpressionPose(
                duration: 0.32,
                nodes: merge(hairDelta(xOffset: -0.02), [
                    // Big asymmetric — left brow WAY up, right brow slightly down, eyes narrow.
                    "part.brow.left":  .init(eulerAngles: SCNVector3(0, 0,  0.02), position: SCNVector3(0, 9, 0)),
                    "part.brow.right": .init(eulerAngles: SCNVector3(0, 0, -0.28), position: SCNVector3(0, -1, 0)),
                    "part.eye.left":   .init(scale: SCNVector3(1.05, 0.95, 1)),
                    "part.eye.right":  .init(scale: SCNVector3(1, 0.65, 1)),
                    "part.head":       .init(eulerAngles: SCNVector3(-0.08, 0, -0.10))
                ])
            ),
            .sleepy: ExpressionPose(
                duration: 0.55,
                nodes: merge(hairDelta(xOffset: 0.14, yOffset: -1.5), [
                    // Between neutral and tired — eyes quite narrow, head drooped but not flat.
                    "part.brow.left":  .init(eulerAngles: SCNVector3(0, 0,  0.04), position: SCNVector3(0, -1, 0)),
                    "part.brow.right": .init(eulerAngles: SCNVector3(0, 0, -0.04), position: SCNVector3(0, -1, 0)),
                    "part.eye.left":   .init(scale: SCNVector3(1, 0.32, 1)),
                    "part.eye.right":  .init(scale: SCNVector3(1, 0.32, 1)),
                    "part.head":       .init(eulerAngles: SCNVector3(-0.26, 0, 0.04))
                ])
            ),
            .angry: ExpressionPose(
                duration: 0.22,
                nodes: merge(hairDelta(xOffset: 0.06, yOffset: -1), [
                    // Brows drive DOWN and IN hard, eyes narrow to slits, head forward.
                    "part.brow.left":  .init(eulerAngles: SCNVector3(0, 0,  0.78), scale: SCNVector3(1.1, 1.0, 1), position: SCNVector3(4, -4, 0)),
                    "part.brow.right": .init(eulerAngles: SCNVector3(0, 0, -0.78), scale: SCNVector3(1.1, 1.0, 1), position: SCNVector3(-4, -4, 0)),
                    "part.eye.left":   .init(scale: SCNVector3(1, 0.45, 1)),
                    "part.eye.right":  .init(scale: SCNVector3(1, 0.45, 1)),
                    "part.head":       .init(eulerAngles: SCNVector3(-0.24, 0, 0))
                ])
            ),
            .embarrassed: ExpressionPose(
                duration: 0.38,
                nodes: merge(hairDelta(xOffset: 0.08, yOffset: -1), [
                    // Brows soft up, eyes narrowed, head turns away + down.
                    "part.brow.left":  .init(eulerAngles: SCNVector3(0, 0, -0.10), position: SCNVector3(0, 3, 0)),
                    "part.brow.right": .init(eulerAngles: SCNVector3(0, 0,  0.10), position: SCNVector3(0, 3, 0)),
                    "part.eye.left":   .init(scale: SCNVector3(1, 0.62, 1)),
                    "part.eye.right":  .init(scale: SCNVector3(1, 0.62, 1)),
                    "part.head":       .init(eulerAngles: SCNVector3(-0.22, 0.20, 0.15))
                ])
            ),
            .devious: ExpressionPose(
                duration: 0.3,
                nodes: merge(hairDelta(xOffset: -0.08), [
                    // Sly — left brow up, right low, eyes half-lidded, head cocked back.
                    "part.brow.left":  .init(eulerAngles: SCNVector3(0, 0,  0.04), position: SCNVector3(0, 7, 0)),
                    "part.brow.right": .init(eulerAngles: SCNVector3(0, 0, -0.20), position: SCNVector3(0, 1, 0)),
                    "part.eye.left":   .init(scale: SCNVector3(1.05, 0.65, 1)),
                    "part.eye.right":  .init(scale: SCNVector3(1.05, 0.65, 1)),
                    "part.head":       .init(eulerAngles: SCNVector3(0.02, 0, -0.12))
                ])
            ),
            .determined: ExpressionPose(
                duration: 0.32,
                nodes: merge(hairDelta(xOffset: -0.04), [
                    // Like focused but squarer, eyes more set, no head tilt.
                    "part.brow.left":  .init(eulerAngles: SCNVector3(0, 0,  0.24), scale: SCNVector3(1, 0.9, 1), position: SCNVector3(1, -2, 0)),
                    "part.brow.right": .init(eulerAngles: SCNVector3(0, 0, -0.24), scale: SCNVector3(1, 0.9, 1), position: SCNVector3(-1, -2, 0)),
                    "part.eye.left":   .init(scale: SCNVector3(1.04, 0.80, 1)),
                    "part.eye.right":  .init(scale: SCNVector3(1.04, 0.80, 1)),
                    "part.head":       .init(eulerAngles: SCNVector3(-0.10, 0, 0))
                ])
            ),
            .confused: ExpressionPose(
                duration: 0.3,
                nodes: merge(hairDelta(xOffset: -0.04), [
                    // Lopsided brows, head tilted heavily, eye scales differ.
                    "part.brow.left":  .init(eulerAngles: SCNVector3(0, 0,  0.22), position: SCNVector3(2, 5, 0)),
                    "part.brow.right": .init(eulerAngles: SCNVector3(0, 0, -0.22), position: SCNVector3(-2, -4, 0)),
                    "part.eye.left":   .init(scale: SCNVector3(1.10, 1.05, 1)),
                    "part.eye.right":  .init(scale: SCNVector3(0.95, 0.72, 1)),
                    "part.head":       .init(eulerAngles: SCNVector3(-0.04, 0, 0.30))
                ])
            ),
            .dreamy: ExpressionPose(
                duration: 0.6,
                nodes: merge(hairDelta(xOffset: -0.06, yOffset: 1), [
                    // Soft brows a little up, eyes at half mast, head tipped UP.
                    "part.brow.left":  .init(eulerAngles: SCNVector3(0, 0, -0.05), position: SCNVector3(0, 4, 0)),
                    "part.brow.right": .init(eulerAngles: SCNVector3(0, 0,  0.05), position: SCNVector3(0, 4, 0)),
                    "part.eye.left":   .init(scale: SCNVector3(0.95, 0.55, 1)),
                    "part.eye.right":  .init(scale: SCNVector3(0.95, 0.55, 1)),
                    "part.head":       .init(eulerAngles: SCNVector3(0.14, 0, 0.08))
                ])
            ),
            .smug: ExpressionPose(
                duration: 0.30,
                nodes: merge(hairDelta(xOffset: -0.10), [
                    // Smug — right brow up, left dropped, eyes low, head leaned back.
                    "part.brow.left":  .init(eulerAngles: SCNVector3(0, 0, -0.22), position: SCNVector3(0, 1, 0)),
                    "part.brow.right": .init(eulerAngles: SCNVector3(0, 0,  0.04), position: SCNVector3(0, 7, 0)),
                    "part.eye.left":   .init(scale: SCNVector3(1, 0.62, 1)),
                    "part.eye.right":  .init(scale: SCNVector3(1, 0.62, 1)),
                    "part.head":       .init(eulerAngles: SCNVector3(0.06, 0, 0.12))
                ])
            ),
            .shy: ExpressionPose(
                duration: 0.42,
                nodes: merge(hairDelta(xOffset: 0.16, yOffset: -1.5), [
                    // Brows slope up-and-in (soft concern), eyes narrowed, head down + turned.
                    "part.brow.left":  .init(eulerAngles: SCNVector3(0, 0, -0.22), position: SCNVector3(0, 3, 0)),
                    "part.brow.right": .init(eulerAngles: SCNVector3(0, 0,  0.22), position: SCNVector3(0, 3, 0)),
                    "part.eye.left":   .init(scale: SCNVector3(1, 0.60, 1)),
                    "part.eye.right":  .init(scale: SCNVector3(1, 0.60, 1)),
                    "part.head":       .init(eulerAngles: SCNVector3(-0.32, -0.15, -0.08))
                ])
            )
        ]
    }

    // MARK: - Palette

    struct Palette {
        let skin: NSColor
        let hair: NSColor
        let suit: NSColor
        let tie: NSColor
        let shirt: NSColor
        let frame: NSColor
        let lens: NSColor
        let lensGlow: NSColor
        let shoe: NSColor
        let mouthDark: NSColor
        let teeth: NSColor

        static let `default` = Palette(
            skin: NSColor(srgbRed: 0.95, green: 0.86, blue: 0.77, alpha: 1.0),
            hair: NSColor(srgbRed: 0.95, green: 0.80, blue: 0.30, alpha: 1.0),
            suit: NSColor(srgbRed: 0.06, green: 0.42, blue: 0.56, alpha: 1.0),
            // Pushed magenta saturation — matches accent.magenta (#FF2D8A) in v2 spec §3.1.
            tie: NSColor(srgbRed: 1.00, green: 0.18, blue: 0.54, alpha: 1.0),
            shirt: NSColor(srgbRed: 0.94, green: 0.94, blue: 0.90, alpha: 1.0),
            frame: NSColor(srgbRed: 0.90, green: 0.70, blue: 0.24, alpha: 1.0),
            // Near-black lens base — spec §2.1 calls for #0A0A0F so rim light reads as
            // a crisp highlight rather than a warm orange glow.
            lens: NSColor(srgbRed: 0.04, green: 0.04, blue: 0.06, alpha: 1.0),
            // Retained for API compatibility but no longer used on the lens — the
            // orange glow was the culprit behind the "bright orange lens" critique.
            lensGlow: NSColor(srgbRed: 0.02, green: 0.02, blue: 0.03, alpha: 1.0),
            shoe: NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1.0),
            mouthDark: NSColor(srgbRed: 0.18, green: 0.06, blue: 0.10, alpha: 1.0),
            teeth: NSColor(srgbRed: 0.96, green: 0.96, blue: 0.93, alpha: 1.0)
        )
    }

    // MARK: - HeadStyleCustomizable

    var headStyleContext: HeadStyleContext {
        HeadStyleContext(
            headWidth: headWidth,
            headHeight: headHeight,
            headDepth: headDepth,
            hairColor: Palette.default.hair,
            skinColor: Palette.default.skin
        )
    }

    // MARK: - Dimensions

    private var headWidth: CGFloat { 60 }
    private var headHeight: CGFloat { 70 }
    private var headDepth: CGFloat { 46 }
    private var neckHeight: CGFloat { 10 }
    private var torsoWidth: CGFloat { 100 }
    private var torsoHeight: CGFloat { 80 }
    private var torsoDepth: CGFloat { 38 }
    private var armRadius: CGFloat { 12 }
    private var armLength: CGFloat { 92 }
    private var legRadius: CGFloat { 13 }
    private var legLength: CGFloat { 100 }
    private var footHeight: CGFloat { 9 }
    private var footLength: CGFloat { 32 }
    private var footWidth: CGFloat { 24 }

    // MARK: - Material helper

    private func mat(
        _ color: NSColor,
        roughness: CGFloat = 0.6,
        metalness: CGFloat = 0.0,
        emission: NSColor? = nil
    ) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = metalness
        if let e = emission { m.emission.contents = e }
        return m
    }

    private func tag(_ node: SCNNode, _ name: String) -> SCNNode {
        node.name = name
        return node
    }

    // MARK: - Build

    func makeNode() -> SCNNode {
        let p = Palette.default
        let root = SCNNode()
        root.name = "pet.root"

        root.addChildNode(makeGroundShadow())

        let body = SCNNode()
        body.name = "body"
        root.addChildNode(body)

        // Legs + feet as pivot groups — pivot at the HIP so rotating
        // swings the whole limb including the foot. Feet stay attached
        // to legs during walks and kicks.
        let leftLegPivot = makeLegPivot(p: p, legName: "part.suit.leg.left", footName: "part.shoe.left")
        leftLegPivot.name = "pivot.leg.left"
        leftLegPivot.position = SCNVector3(-13, footHeight + legLength, 0)
        body.addChildNode(leftLegPivot)
        let rightLegPivot = makeLegPivot(p: p, legName: "part.suit.leg.right", footName: "part.shoe.right")
        rightLegPivot.name = "pivot.leg.right"
        rightLegPivot.position = SCNVector3(13, footHeight + legLength, 0)
        body.addChildNode(rightLegPivot)

        // Torso
        let torsoY = footHeight + legLength + torsoHeight / 2
        let torso = tag(makeTorso(p: p), "part.suit.torso")
        torso.position = SCNVector3(0, torsoY, 0)
        body.addChildNode(torso)

        // Shoulder orbs — share suit material. Stiff plastic look per §2.1.
        let shoulderRadius: CGFloat = 16
        let leftShoulder = SCNNode(geometry: SCNSphere(radius: shoulderRadius))
        leftShoulder.geometry?.firstMaterial = mat(p.suit, roughness: 0.42, metalness: 0.15)
        leftShoulder.name = "part.suit.shoulder.left"
        leftShoulder.position = SCNVector3(-torsoWidth / 2 + 2, torsoHeight / 2 - 4, 0)
        torso.addChildNode(leftShoulder)
        let rightShoulder = SCNNode(geometry: SCNSphere(radius: shoulderRadius))
        rightShoulder.geometry?.firstMaterial = mat(p.suit, roughness: 0.42, metalness: 0.15)
        rightShoulder.name = "part.suit.shoulder.right"
        rightShoulder.position = SCNVector3(torsoWidth / 2 - 2, torsoHeight / 2 - 4, 0)
        torso.addChildNode(rightShoulder)

        // Shirt V
        let collar = SCNNode(geometry: makeCollarGeometry(p: p))
        collar.name = "part.shirt.collar"
        collar.position = SCNVector3(0, torsoHeight / 2 - 6, torsoDepth / 2 + 0.4)
        torso.addChildNode(collar)

        // Tie
        let tieNode = SCNNode(geometry: makeTieGeometry(p: p))
        tieNode.name = "part.tie.strap"
        tieNode.position = SCNVector3(0, torsoHeight / 2 - 26, torsoDepth / 2 + 0.8)
        torso.addChildNode(tieNode)
        let tieKnot = SCNNode(geometry: makeTieKnotGeometry(p: p))
        tieKnot.name = "part.tie.knot"
        tieKnot.position = SCNVector3(0, torsoHeight / 2 - 9, torsoDepth / 2 + 1.3)
        torso.addChildNode(tieKnot)

        // Arms as pivot groups — pivot at the SHOULDER. Rotating pivot
        // swings the arm + hand around the shoulder. Used for walking
        // arm-swing, waving, beckoning, pointing.
        let shoulderX = torsoWidth / 2 - armRadius * 0.2
        let shoulderY = torsoHeight / 2 - armRadius * 0.8
        let leftArmPivot = makeArmPivot(p: p, side: "left")
        leftArmPivot.name = "pivot.arm.left"
        leftArmPivot.position = SCNVector3(-shoulderX, shoulderY, 0)
        torso.addChildNode(leftArmPivot)
        let rightArmPivot = makeArmPivot(p: p, side: "right")
        rightArmPivot.name = "pivot.arm.right"
        rightArmPivot.position = SCNVector3(shoulderX, shoulderY, 0)
        torso.addChildNode(rightArmPivot)

        // Neck
        let neck = SCNNode(geometry: SCNCylinder(radius: 9, height: neckHeight))
        neck.geometry?.materials = [mat(p.skin, roughness: 0.50)]
        neck.name = "part.skin.neck"
        neck.position = SCNVector3(0, torsoHeight / 2 + neckHeight / 2, 0)
        torso.addChildNode(neck)

        // Head (slight forward lean)
        let head = makeHead(p: p)
        head.name = "part.head"
        head.position = SCNVector3(0, torsoHeight / 2 + neckHeight + headHeight / 2 - 2, 2)
        head.eulerAngles = SCNVector3(-0.08, 0, 0)
        torso.addChildNode(head)

        attachBreathing(to: torso)
        attachHeadSway(to: head)
        return root
    }

    // MARK: - Parts

    private func makeGroundShadow() -> SCNNode {
        let g = SCNPlane(width: 66, height: 24)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor(calibratedWhite: 0, alpha: 0.38)
        m.writesToDepthBuffer = false
        m.transparencyMode = .aOne
        g.materials = [m]
        let node = SCNNode(geometry: g)
        node.eulerAngles = SCNVector3(-Double.pi / 2, 0, 0)
        node.position = SCNVector3(0, 0.5, 0)
        node.renderingOrder = -10
        return node
    }

    /// Leg pivot group: unnamed parent node placed at the hip, with the
    /// leg cylinder and foot as children. Rotating the pivot swings the
    /// whole limb from the hip.
    private func makeLegPivot(p: Palette, legName: String, footName: String) -> SCNNode {
        let pivot = SCNNode()

        let cyl = SCNCylinder(radius: legRadius, height: legLength)
        cyl.materials = [mat(p.suit, roughness: 0.42, metalness: 0.15)]
        let leg = SCNNode(geometry: cyl)
        leg.name = legName
        leg.position = SCNVector3(0, -legLength / 2, 0)
        pivot.addChildNode(leg)

        let footBox = SCNBox(width: footWidth, height: footHeight, length: footLength, chamferRadius: 3)
        footBox.materials = [mat(p.shoe, roughness: 0.32, metalness: 0.18)]
        let foot = SCNNode(geometry: footBox)
        foot.name = footName
        foot.position = SCNVector3(0, -legLength - footHeight / 2, 5)
        pivot.addChildNode(foot)

        return pivot
    }

    /// Arm pivot group with elbow joint. Tree:
    ///
    ///   shoulder pivot (returned, anchored at shoulder)
    ///     ├── upper arm cylinder (part.suit.arm.upper.<side>)
    ///     └── elbow pivot (pivot.elbow.<side>, at end of upper arm)
    ///           ├── lower arm cylinder (part.suit.arm.lower.<side>)
    ///           └── hand sphere (part.skin.hand)
    ///
    /// Rotating the shoulder pivot swings the whole arm. Rotating the
    /// elbow pivot bends the forearm + hand relative to the upper arm
    /// — enables waving, beckoning, pointing without the arm reading
    /// as a rigid stick.
    private func makeArmPivot(p: Palette, side: String) -> SCNNode {
        let upperLen = armLength / 2
        let lowerLen = armLength / 2

        let shoulder = SCNNode()

        let upperCyl = SCNCylinder(radius: armRadius, height: upperLen)
        upperCyl.materials = [mat(p.suit, roughness: 0.42, metalness: 0.15)]
        let upper = SCNNode(geometry: upperCyl)
        upper.name = "part.suit.arm.upper.\(side)"
        upper.position = SCNVector3(0, -upperLen / 2, 0)
        shoulder.addChildNode(upper)

        let elbow = SCNNode()
        elbow.name = "pivot.elbow.\(side)"
        elbow.position = SCNVector3(0, -upperLen, 0)
        shoulder.addChildNode(elbow)

        let lowerCyl = SCNCylinder(radius: armRadius, height: lowerLen)
        lowerCyl.materials = [mat(p.suit, roughness: 0.42, metalness: 0.15)]
        let lower = SCNNode(geometry: lowerCyl)
        lower.name = "part.suit.arm.lower.\(side)"
        lower.position = SCNVector3(0, -lowerLen / 2, 0)
        elbow.addChildNode(lower)

        let hand = SCNNode(geometry: SCNSphere(radius: armRadius * 1.1))
        hand.geometry?.materials = [mat(p.skin, roughness: 0.50)]
        hand.name = "part.skin.hand"
        hand.position = SCNVector3(0, -lowerLen - armRadius * 0.55, 0)
        elbow.addChildNode(hand)

        return shoulder
    }

    private func makeTorso(p: Palette) -> SCNNode {
        let box = SCNBox(
            width: torsoWidth,
            height: torsoHeight,
            length: torsoDepth,
            chamferRadius: 12
        )
        box.materials = [mat(p.suit, roughness: 0.42, metalness: 0.15)]
        return SCNNode(geometry: box)
    }

    private func makeCollarGeometry(p: Palette) -> SCNGeometry {
        let box = SCNBox(width: torsoWidth * 0.42, height: 16, length: 3, chamferRadius: 2)
        box.materials = [mat(p.shirt, roughness: 0.55)]
        return box
    }

    private func makeTieGeometry(p: Palette) -> SCNGeometry {
        let box = SCNBox(width: 15, height: 42, length: 2.5, chamferRadius: 1.4)
        box.materials = [mat(p.tie, roughness: 0.35, metalness: 0.20)]
        return box
    }

    private func makeTieKnotGeometry(p: Palette) -> SCNGeometry {
        let box = SCNBox(width: 12, height: 11, length: 3, chamferRadius: 1.4)
        box.materials = [mat(p.tie, roughness: 0.28, metalness: 0.22)]
        return box
    }

    private func makeHead(p: Palette) -> SCNNode {
        let container = SCNNode()

        let headBox = SCNBox(
            width: headWidth,
            height: headHeight,
            length: headDepth,
            chamferRadius: 12
        )
        // Flatter, more plastic face per §2.1 — naturalistic PBR was too soft.
        headBox.materials = [mat(p.skin, roughness: 0.48)]
        let headNode = SCNNode(geometry: headBox)
        headNode.name = "part.skin.face"
        container.addChildNode(headNode)

        // Hair wedges — yaw zeroed (all wedges face straight forward) to
        // guarantee left/right symmetry. rollZ fans the tops outward for
        // the pompadour silhouette without introducing any lateral bias.
        for i in 0..<5 {
            let t = CGFloat(i) / 4.0 - 0.5
            let xOffset = t * (headWidth * 0.75)
            let yaw = CGFloat(0)
            let rollZ = -t * 0.14
            let wedge = makeHairWedge(p: p, xOffset: xOffset, yaw: yaw, rollZ: rollZ)
            wedge.name = "part.hair.\(i)"
            container.addChildNode(wedge)
        }

        // Sideburns
        let leftBurn = SCNNode(geometry: makeSideburnGeometry(p: p))
        leftBurn.name = "part.hair.sideburn.left"
        leftBurn.position = SCNVector3(-headWidth / 2 + 2.5, headHeight * 0.06, headDepth * 0.22)
        container.addChildNode(leftBurn)
        let rightBurn = SCNNode(geometry: makeSideburnGeometry(p: p))
        rightBurn.name = "part.hair.sideburn.right"
        rightBurn.position = SCNVector3(headWidth / 2 - 2.5, headHeight * 0.06, headDepth * 0.22)
        container.addChildNode(rightBurn)

        // Eyes (sclera + pupil) and glasses (lens + frame, hidden by default)
        let leftEye = makeEye(p: p, side: "left")
        leftEye.position = SCNVector3(-15, headHeight * 0.12, headDepth / 2 + 0.5)
        container.addChildNode(leftEye)
        let rightEye = makeEye(p: p, side: "right")
        rightEye.position = SCNVector3(15, headHeight * 0.12, headDepth / 2 + 0.5)
        container.addChildNode(rightEye)

        let bridge = SCNNode(geometry: makeBridgeGeometry(p: p))
        bridge.name = "part.frame.bridge"
        bridge.position = SCNVector3(0, headHeight * 0.14, headDepth / 2 + 0.8)
        container.addChildNode(bridge)

        // Brows — small plastic bars above the lenses. Part of the
        // expression system; can rotate (raise/knit/furrow) and translate
        // (vertical shift) to pose emotion. See Expressions.swift.
        let leftBrow = SCNNode(geometry: makeBrowGeometry(p: p))
        leftBrow.name = "part.brow.left"
        leftBrow.position = SCNVector3(-15, headHeight * 0.28, headDepth / 2 + 0.6)
        container.addChildNode(leftBrow)
        let rightBrow = SCNNode(geometry: makeBrowGeometry(p: p))
        rightBrow.name = "part.brow.right"
        rightBrow.position = SCNVector3(15, headHeight * 0.28, headDepth / 2 + 0.6)
        container.addChildNode(rightBrow)

        // Nose
        let nose = SCNNode(geometry: makeNoseGeometry(p: p))
        nose.name = "part.skin.nose"
        nose.position = SCNVector3(0, -headHeight * 0.04, headDepth / 2 + 3.8)
        container.addChildNode(nose)

        // Grin
        let grin = makeGrin(p: p)
        grin.position = SCNVector3(0, -headHeight * 0.30, headDepth / 2 + 0.2)
        container.addChildNode(grin)

        return container
    }

    private func makeHairWedge(p: Palette, xOffset: CGFloat, yaw: CGFloat, rollZ: CGFloat) -> SCNNode {
        let box = SCNBox(width: 11, height: 34, length: 44, chamferRadius: 3)
        // Stylised hair — low roughness for the sheen, metalness kept
        // modest (0.10) without a strand normal map. Anything higher read
        // as moulded plastic against the rim lights.
        box.materials = [mat(p.hair, roughness: 0.22, metalness: 0.10)]
        let node = SCNNode(geometry: box)
        node.position = SCNVector3(xOffset, headHeight * 0.48, -headDepth * 0.04)
        node.eulerAngles = SCNVector3(-Double.pi / 5.5, yaw, rollZ)
        return node
    }

    private func makeSideburnGeometry(p: Palette) -> SCNGeometry {
        let box = SCNBox(width: 5, height: 18, length: 4, chamferRadius: 1.5)
        box.materials = [mat(p.hair, roughness: 0.24, metalness: 0.08)]
        return box
    }

    /// Eye container: sclera base + pupil child (always visible) +
    /// tinted glasses lens + gold frame (both hidden by default).
    /// Z ordering from camera (z=1500):
    ///   glasses.lens (z=2.5) > frame (z=1.8) > pupil (z=1.5 local to eye) > eye (z=0)
    private func makeEye(p: Palette, side: String) -> SCNNode {
        let container = SCNNode()

        // Sclera — off-white eye base, always visible.
        let eyeBox = SCNBox(width: 20, height: 16.5, length: 2.8, chamferRadius: 7.5)
        eyeBox.materials = [mat(
            NSColor(srgbRed: 0.95, green: 0.95, blue: 0.90, alpha: 1),
            roughness: 0.55
        )]
        let eyeNode = SCNNode(geometry: eyeBox)
        eyeNode.name = "part.eye.\(side)"
        eyeNode.position = SCNVector3(0, 0, 0)
        container.addChildNode(eyeNode)

        // Pupil — pure-black, child of eye so it blinks with the sclera.
        // metalness=0 + low roughness keeps IBL from washing it grey on
        // bright rim setups; the pupil should read as a clean punch-out.
        let pupilBox = SCNBox(width: 7, height: 8, length: 1.5, chamferRadius: 2)
        pupilBox.materials = [mat(
            NSColor(srgbRed: 0.02, green: 0.02, blue: 0.03, alpha: 1),
            roughness: 0.05,
            metalness: 0.0
        )]
        let pupilNode = SCNNode(geometry: pupilBox)
        pupilNode.name = "part.pupil.\(side)"
        pupilNode.position = SCNVector3(0, 0, 1.5)
        eyeNode.addChildNode(pupilNode)

        // Tinted glasses lens — dark mirror, hidden by default. Explicit
        // renderingOrder so the lens always draws in front of the pupil /
        // eye at oblique expression angles instead of z-fighting.
        let glassesLensBox = SCNBox(width: 20, height: 16.5, length: 2.2, chamferRadius: 7.5)
        glassesLensBox.materials = [mat(
            NSColor(srgbRed: 0.04, green: 0.04, blue: 0.06, alpha: 1),
            roughness: 0.04,
            metalness: 0.85
        )]
        let glassesLensNode = SCNNode(geometry: glassesLensBox)
        glassesLensNode.name = "part.glasses.lens.\(side)"
        glassesLensNode.position = SCNVector3(0, 0, 3.0)
        glassesLensNode.renderingOrder = 2
        glassesLensNode.isHidden = true
        container.addChildNode(glassesLensNode)

        // Gold frame — wider than lens to show as border, hidden by default.
        let frameBox = SCNBox(width: 24, height: 20, length: 2.2, chamferRadius: 9)
        frameBox.materials = [mat(p.frame, roughness: 0.14, metalness: 0.90)]
        let frameNode = SCNNode(geometry: frameBox)
        frameNode.name = "part.frame.\(side)"
        frameNode.position = SCNVector3(0, 0, 2.5)
        frameNode.renderingOrder = 1
        frameNode.isHidden = true
        container.addChildNode(frameNode)

        return container
    }

    private func makeBridgeGeometry(p: Palette) -> SCNGeometry {
        let box = SCNBox(width: 10, height: 3, length: 2.5, chamferRadius: 1.3)
        box.materials = [mat(p.frame, roughness: 0.15, metalness: 0.90)]
        return box
    }

    private func makeBrowGeometry(p: Palette) -> SCNGeometry {
        let box = SCNBox(width: 20, height: 3.2, length: 3, chamferRadius: 1.2)
        box.materials = [mat(p.hair, roughness: 0.22, metalness: 0.3)]
        return box
    }

    private func makeNoseGeometry(p: Palette) -> SCNGeometry {
        let box = SCNBox(width: 6, height: 11, length: 4, chamferRadius: 2)
        box.materials = [mat(p.skin, roughness: 0.48)]
        return box
    }

    private func makeGrin(p: Palette) -> SCNNode {
        let container = SCNNode()

        // Neutral mouth — the authored rest shape. Named `.arc` for
        // backward compat with call sites that expected that name
        // (mouth-related action ops, older undo snapshots), AND
        // `.neutral` via an alias child so the expression→shape
        // mapping can reference it uniformly with the other shapes.
        let mouth = SCNBox(width: 30, height: 9, length: 3, chamferRadius: 4)
        mouth.materials = [mat(p.mouthDark, roughness: 0.55)]
        let mouthNode = SCNNode(geometry: mouth)
        mouthNode.name = "part.mouth.arc"
        container.addChildNode(mouthNode)

        // --- Expression-driven mouth variants ---
        // Each sibling node is a distinct mouth "shape." Pet.setMouthShape
        // shows exactly one and hides the rest based on the current
        // expression. The authored neutral (part.mouth.arc) is shown when
        // the target is `.neutral`; all others start hidden.

        // SMILE — upward crescent via SCNShape + NSBezierPath.
        container.addChildNode(makeSmile(p: p))
        // FROWN — downward crescent.
        container.addChildNode(makeFrown(p: p))
        // OPEN — small oval for surprise / shock / "o" moments.
        container.addChildNode(makeOpenMouth(p: p))
        // FLAT — thin narrow line for concerned / focused / determined.
        container.addChildNode(makeFlatMouth(p: p))

        let teeth = SCNBox(width: 24, height: 4.5, length: 2, chamferRadius: 0.6)
        teeth.materials = [mat(p.teeth, roughness: 0.18)]
        let teethNode = SCNNode(geometry: teeth)
        teethNode.name = "part.teeth.row"
        teethNode.position = SCNVector3(0, 0.8, 2.2)
        container.addChildNode(teethNode)

        for i in 0..<5 {
            let t = CGFloat(i + 1) / 6.0
            let xPos = -12 + t * 24
            let sep = SCNBox(width: 0.5, height: 4.5, length: 2, chamferRadius: 0)
            sep.materials = [mat(p.mouthDark, roughness: 0.55)]
            let sepNode = SCNNode(geometry: sep)
            sepNode.name = "part.mouth.gap.\(i)"
            sepNode.position = SCNVector3(xPos, 0.8, 2.4)
            container.addChildNode(sepNode)
        }

        return container
    }

    private func makeSmile(p: Palette) -> SCNNode {
        // Crescent — outer arc curves upward. Built from two cubic curves
        // forming a thin upward U. Extrusion depth matches the neutral
        // mouth so lighting reads the same.
        let path = NSBezierPath()
        path.move(to: NSPoint(x: -16, y: 2.5))
        path.curve(to: NSPoint(x: 16, y: 2.5),
                   controlPoint1: NSPoint(x: -8, y: -7),
                   controlPoint2: NSPoint(x:  8, y: -7))
        path.line(to: NSPoint(x: 14, y: 4))
        path.curve(to: NSPoint(x: -14, y: 4),
                   controlPoint1: NSPoint(x:  6, y: -4),
                   controlPoint2: NSPoint(x: -6, y: -4))
        path.close()
        let shape = SCNShape(path: path, extrusionDepth: 3)
        shape.materials = [mat(p.mouthDark, roughness: 0.55)]
        let node = SCNNode(geometry: shape)
        node.name = "part.mouth.smile"
        node.isHidden = true
        return node
    }

    private func makeFrown(p: Palette) -> SCNNode {
        // Inverse of smile — outer arc curves downward.
        let path = NSBezierPath()
        path.move(to: NSPoint(x: -16, y: -2.5))
        path.curve(to: NSPoint(x: 16, y: -2.5),
                   controlPoint1: NSPoint(x: -8, y: 7),
                   controlPoint2: NSPoint(x:  8, y: 7))
        path.line(to: NSPoint(x: 14, y: -4))
        path.curve(to: NSPoint(x: -14, y: -4),
                   controlPoint1: NSPoint(x:  6, y: 4),
                   controlPoint2: NSPoint(x: -6, y: 4))
        path.close()
        let shape = SCNShape(path: path, extrusionDepth: 3)
        shape.materials = [mat(p.mouthDark, roughness: 0.55)]
        let node = SCNNode(geometry: shape)
        node.name = "part.mouth.frown"
        node.isHidden = true
        return node
    }

    private func makeOpenMouth(p: Palette) -> SCNNode {
        // Small oval for surprise / excited / shocked beats. A
        // flattened sphere reads as an open "o" without needing
        // per-frame rigging.
        let sphere = SCNSphere(radius: 8)
        sphere.materials = [mat(p.mouthDark, roughness: 0.55)]
        let node = SCNNode(geometry: sphere)
        node.name = "part.mouth.open"
        node.scale = SCNVector3(1.2, 1.0, 0.4)
        node.isHidden = true
        return node
    }

    private func makeFlatMouth(p: Palette) -> SCNNode {
        // Thin narrow line for focused / concerned / determined poses.
        let box = SCNBox(width: 22, height: 1.8, length: 3, chamferRadius: 0.8)
        box.materials = [mat(p.mouthDark, roughness: 0.55)]
        let node = SCNNode(geometry: box)
        node.name = "part.mouth.flat"
        node.isHidden = true
        return node
    }

    // MARK: - Idle

    private func attachBreathing(to node: SCNNode) {
        let expand = SCNAction.scale(by: 1.012, duration: 2.4)
        expand.timingMode = .easeInEaseOut
        let contract = SCNAction.scale(by: 1.0 / 1.012, duration: 2.4)
        contract.timingMode = .easeInEaseOut
        node.runAction(.repeatForever(.sequence([expand, contract])), forKey: "breathing")
    }

    private func attachHeadSway(to node: SCNNode) {
        let baseX: CGFloat = -0.08
        // Start left (viewer's right) so the first impression is centred/right
        // rather than immediately drifting the hair to the viewer's left.
        let left  = SCNAction.rotateTo(x: baseX, y: CGFloat(-0.035), z: 0, duration: 3.8)
        left.timingMode = .easeInEaseOut
        let right = SCNAction.rotateTo(x: baseX, y: CGFloat( 0.035), z: 0, duration: 3.8)
        right.timingMode = .easeInEaseOut
        node.runAction(.repeatForever(.sequence([left, right])), forKey: "headsway")
    }
}
