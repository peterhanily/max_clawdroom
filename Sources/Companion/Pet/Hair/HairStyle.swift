import AppKit
import SceneKit

/// Parameters a Form passes to the hair/grooming builders so they can size
/// themselves to the head. Keeps HairStyle + FacialHair decoupled from any
/// specific Form's private dimensions.
struct HeadStyleContext {
    let headWidth: CGFloat
    let headHeight: CGFloat
    let headDepth: CGFloat
    let hairColor: NSColor
    let skinColor: NSColor
}

/// Forms that support agent-swappable hair/grooming conform to this and
/// surface a `HeadStyleContext` so `Pet.setHairStyle` / `setFacialHair`
/// can build new subtrees that match the form's scale + palette.
protocol HeadStyleCustomizable {
    var headStyleContext: HeadStyleContext { get }
}

/// Hair presets. `pompadour` reproduces Max's default look (5 forward-swept
/// wedges + two sideburns); the rest are agent-addressable alternates.
///
/// Every builder returns SCNNodes parented to a tag-free container. Each
/// node is named `part.hair.*` so the existing parts index groups them
/// under the `hair` key and colour/pattern ops keep working.
enum HairStyle: String, CaseIterable {
    case pompadour
    case crew
    case afro
    case bob
    case mohawk
    case bald
    case dreadlocks
    case ponytail
    case buzz
    case spikes
    case sidepart
    case quiff
    // Phase C — new styles
    case messy
    case undercut
    case top_knot
    case pigtails
    case cornrows

    static let all: [String] = HairStyle.allCases.map(\.rawValue)

    /// Builds the hair subtree for this style. Returns nodes the caller
    /// should add as children of the head container.
    func buildNodes(context ctx: HeadStyleContext) -> [SCNNode] {
        switch self {
        case .pompadour:  return pompadourNodes(ctx)
        case .crew:       return crewNodes(ctx)
        case .afro:       return afroNodes(ctx)
        case .bob:        return bobNodes(ctx)
        case .mohawk:     return mohawkNodes(ctx)
        case .bald:       return []
        case .dreadlocks: return dreadlocksNodes(ctx)
        case .ponytail:   return ponytailNodes(ctx)
        case .buzz:       return buzzNodes(ctx)
        case .spikes:     return spikesNodes(ctx)
        case .sidepart:   return sidepartNodes(ctx)
        case .quiff:      return quiffNodes(ctx)
        case .messy:      return messyNodes(ctx)
        case .undercut:   return undercutNodes(ctx)
        case .top_knot:   return topKnotNodes(ctx)
        case .pigtails:   return pigtailsNodes(ctx)
        case .cornrows:   return cornrowsNodes(ctx)
        }
    }

    // MARK: - Styles

    private func pompadourNodes(_ ctx: HeadStyleContext) -> [SCNNode] {
        var out: [SCNNode] = []
        for i in 0..<5 {
            let t = CGFloat(i) / 4.0 - 0.5
            let xOffset = t * (ctx.headWidth * 0.75)
            let yaw = t * 0.18
            let rollZ = -t * 0.12
            let box = SCNBox(width: 11, height: 34, length: 44, chamferRadius: 3)
            box.materials = [styled(ctx.hairColor, roughness: 0.18, metalness: 0.35)]
            let node = SCNNode(geometry: box)
            node.name = "part.hair.\(i)"
            node.position = SCNVector3(xOffset, ctx.headHeight * 0.48, -ctx.headDepth * 0.04)
            node.eulerAngles = SCNVector3(-Double.pi / 5.5, yaw, rollZ)
            out.append(node)
        }
        // Sideburns
        let burnGeom = SCNBox(width: 5, height: 18, length: 4, chamferRadius: 1.5)
        burnGeom.materials = [styled(ctx.hairColor, roughness: 0.20, metalness: 0.30)]
        let left = SCNNode(geometry: burnGeom)
        left.name = "part.hair.sideburn.left"
        left.position = SCNVector3(-ctx.headWidth / 2 + 2.5, ctx.headHeight * 0.06, ctx.headDepth * 0.22)
        out.append(left)
        let right = SCNNode(geometry: burnGeom.copy() as! SCNGeometry)
        right.name = "part.hair.sideburn.right"
        right.position = SCNVector3(ctx.headWidth / 2 - 2.5, ctx.headHeight * 0.06, ctx.headDepth * 0.22)
        out.append(right)
        return out
    }

    private func crewNodes(_ ctx: HeadStyleContext) -> [SCNNode] {
        // Short flat cap — one thin box resting on top of the skull, clipped
        // to the head silhouette. Reads as a tight buzz/crew cut.
        let box = SCNBox(
            width: ctx.headWidth * 0.94,
            height: ctx.headHeight * 0.20,
            length: ctx.headDepth * 0.92,
            chamferRadius: 6
        )
        box.materials = [styled(ctx.hairColor, roughness: 0.55, metalness: 0.08)]
        let node = SCNNode(geometry: box)
        node.name = "part.hair.0"
        node.position = SCNVector3(0, ctx.headHeight * 0.42, 0)
        return [node]
    }

    private func afroNodes(_ ctx: HeadStyleContext) -> [SCNNode] {
        // One big round mass slightly wider than the head. Second smaller
        // sphere offset back to give it volume without being perfectly round.
        let radius = ctx.headWidth * 0.62
        let big = SCNNode(geometry: SCNSphere(radius: radius))
        big.geometry?.materials = [styled(ctx.hairColor, roughness: 0.85, metalness: 0.02)]
        big.name = "part.hair.0"
        big.position = SCNVector3(0, ctx.headHeight * 0.45, -ctx.headDepth * 0.05)
        let back = SCNNode(geometry: SCNSphere(radius: radius * 0.88))
        back.geometry?.materials = [styled(ctx.hairColor, roughness: 0.85, metalness: 0.02)]
        back.name = "part.hair.1"
        back.position = SCNVector3(0, ctx.headHeight * 0.30, -ctx.headDepth * 0.35)
        return [big, back]
    }

    private func bobNodes(_ ctx: HeadStyleContext) -> [SCNNode] {
        // Flat helmet-ish cap plus two side panels hanging to the jawline.
        let cap = SCNBox(
            width: ctx.headWidth * 1.02,
            height: ctx.headHeight * 0.28,
            length: ctx.headDepth * 1.02,
            chamferRadius: 10
        )
        cap.materials = [styled(ctx.hairColor, roughness: 0.45, metalness: 0.10)]
        let capNode = SCNNode(geometry: cap)
        capNode.name = "part.hair.0"
        capNode.position = SCNVector3(0, ctx.headHeight * 0.38, 0)

        let side = SCNBox(
            width: 5,
            height: ctx.headHeight * 0.55,
            length: ctx.headDepth * 0.85,
            chamferRadius: 2
        )
        side.materials = [styled(ctx.hairColor, roughness: 0.45, metalness: 0.10)]
        let left = SCNNode(geometry: side)
        left.name = "part.hair.1"
        left.position = SCNVector3(-ctx.headWidth / 2 - 1, -ctx.headHeight * 0.05, 0)
        let right = SCNNode(geometry: side.copy() as! SCNGeometry)
        right.name = "part.hair.2"
        right.position = SCNVector3(ctx.headWidth / 2 + 1, -ctx.headHeight * 0.05, 0)
        return [capNode, left, right]
    }

    private func mohawkNodes(_ ctx: HeadStyleContext) -> [SCNNode] {
        // Tall thin strip along the centerline, plus shaved-side sideburn
        // stubs so the head doesn't look bald.
        let strip = SCNBox(
            width: 10,
            height: ctx.headHeight * 0.55,
            length: ctx.headDepth * 0.92,
            chamferRadius: 2
        )
        strip.materials = [styled(ctx.hairColor, roughness: 0.25, metalness: 0.30)]
        let stripNode = SCNNode(geometry: strip)
        stripNode.name = "part.hair.0"
        stripNode.position = SCNVector3(0, ctx.headHeight * 0.55, 0)
        return [stripNode]
    }

    private func dreadlocksNodes(_ ctx: HeadStyleContext) -> [SCNNode] {
        // Short cap on top + dreadlocks dangling around the head's
        // perimeter (not just across the midline). 14 locks arranged
        // in a half-ring around the back + sides of the skull so the
        // silhouette reads as hair-on-the-head, not hair-on-the-face.
        var out: [SCNNode] = []
        let cap = SCNBox(
            width: ctx.headWidth * 0.98,
            height: ctx.headHeight * 0.20,
            length: ctx.headDepth * 0.98,
            chamferRadius: 4
        )
        cap.materials = [styled(ctx.hairColor, roughness: 0.78, metalness: 0.05)]
        let capNode = SCNNode(geometry: cap)
        capNode.name = "part.hair.0"
        capNode.position = SCNVector3(0, ctx.headHeight * 0.40, 0)
        out.append(capNode)

        // Arrange locks along a half-circle hugging the head's back and
        // sides — no locks in the front so the face is clear.
        for i in 0..<14 {
            let t = Double(i) / 13.0  // 0..1
            let theta = .pi * 0.15 + t * (.pi * 0.70)  // 27°..153° (back ring)
            let radius = max(ctx.headWidth, ctx.headDepth) * 0.48
            let x = CGFloat(cos(theta)) * radius
            let z = -CGFloat(sin(theta)) * radius  // negative Z = behind the head
            let lock = SCNCylinder(radius: 3.2, height: 52)
            lock.materials = [styled(ctx.hairColor, roughness: 0.85, metalness: 0.0)]
            let node = SCNNode(geometry: lock)
            node.name = "part.hair.\(i + 1)"
            // Drop each lock so its top hides under the cap and its
            // bottom dangles to ~jaw level.
            node.position = SCNVector3(x, ctx.headHeight * 0.06, z)
            out.append(node)
        }
        return out
    }

    private func ponytailNodes(_ ctx: HeadStyleContext) -> [SCNNode] {
        var out: [SCNNode] = []
        // Slick back cap hugging the skull. Full head coverage,
        // centered — the drama comes from the tail in back, not
        // asymmetric front.
        let cap = SCNBox(
            width: ctx.headWidth * 1.0,
            height: ctx.headHeight * 0.30,
            length: ctx.headDepth * 1.0,
            chamferRadius: 8
        )
        cap.materials = [styled(ctx.hairColor, roughness: 0.25, metalness: 0.25)]
        let capNode = SCNNode(geometry: cap)
        capNode.name = "part.hair.0"
        capNode.position = SCNVector3(0, ctx.headHeight * 0.36, 0)
        out.append(capNode)

        // Tie / scrunchie at the back of the crown.
        let tie = SCNTorus(ringRadius: 7, pipeRadius: 2.5)
        tie.materials = [styled(.black, roughness: 0.8, metalness: 0.0)]
        let tieNode = SCNNode(geometry: tie)
        tieNode.name = "part.hair.1"
        tieNode.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        tieNode.position = SCNVector3(0, ctx.headHeight * 0.30, -ctx.headDepth / 2 - 2)
        out.append(tieNode)

        // The ponytail itself — tapering cylinder hanging straight
        // back from the tie, angled slightly downward so it reads as
        // "hanging" rather than "sticking out".
        let tail = SCNCylinder(radius: 6, height: 85)
        tail.materials = [styled(ctx.hairColor, roughness: 0.35, metalness: 0.2)]
        let tailNode = SCNNode(geometry: tail)
        tailNode.name = "part.hair.2"
        tailNode.eulerAngles = SCNVector3(0.5, 0, 0)  // tip back-and-down
        tailNode.position = SCNVector3(0, ctx.headHeight * 0.0, -ctx.headDepth / 2 - 22)
        out.append(tailNode)

        // Tapered tip — smaller cylinder at the bottom of the tail.
        let tip = SCNCylinder(radius: 2.5, height: 20)
        tip.materials = [styled(ctx.hairColor, roughness: 0.4, metalness: 0.15)]
        let tipNode = SCNNode(geometry: tip)
        tipNode.name = "part.hair.3"
        tipNode.eulerAngles = SCNVector3(0.5, 0, 0)
        tipNode.position = SCNVector3(0, -ctx.headHeight * 0.45, -ctx.headDepth / 2 - 43)
        out.append(tipNode)
        return out
    }

    private func buzzNodes(_ ctx: HeadStyleContext) -> [SCNNode] {
        // Barely-there fuzz — a very thin cap tight to the skull with
        // a slightly darker desaturated hair color to read as stubble
        // rather than volume.
        let cap = SCNBox(
            width: ctx.headWidth * 0.99,
            height: ctx.headHeight * 0.08,
            length: ctx.headDepth * 0.96,
            chamferRadius: 3
        )
        let muted = (ctx.hairColor.usingColorSpace(.sRGB) ?? ctx.hairColor)
            .blended(withFraction: 0.35, of: .black) ?? ctx.hairColor
        cap.materials = [styled(muted, roughness: 0.9, metalness: 0.0)]
        let node = SCNNode(geometry: cap)
        node.name = "part.hair.0"
        node.position = SCNVector3(0, ctx.headHeight * 0.46, 0)
        return [node]
    }

    private func spikesNodes(_ ctx: HeadStyleContext) -> [SCNNode] {
        // Seven cone spikes radiating up + out. Cones aren't a
        // primitive SCN type so approximate with thin tapered cylinders.
        var out: [SCNNode] = []
        // Low cap so the spikes look rooted.
        let cap = SCNBox(
            width: ctx.headWidth * 0.92,
            height: ctx.headHeight * 0.10,
            length: ctx.headDepth * 0.88,
            chamferRadius: 5
        )
        cap.materials = [styled(ctx.hairColor, roughness: 0.28, metalness: 0.30)]
        let capNode = SCNNode(geometry: cap)
        capNode.name = "part.hair.0"
        capNode.position = SCNVector3(0, ctx.headHeight * 0.43, 0)
        out.append(capNode)

        for i in 0..<7 {
            let t = Double(i) / 6.0 - 0.5
            let spike = SCNCone(topRadius: 0.5, bottomRadius: 5, height: 32)
            spike.materials = [styled(ctx.hairColor, roughness: 0.28, metalness: 0.30)]
            let node = SCNNode(geometry: spike)
            node.name = "part.hair.\(i + 1)"
            // Tilt outward based on horizontal offset.
            let tilt = CGFloat(t) * 0.35
            node.eulerAngles = SCNVector3(0, 0, -tilt)
            node.position = SCNVector3(
                CGFloat(t) * ctx.headWidth * 0.65,
                ctx.headHeight * 0.62,
                0
            )
            out.append(node)
        }
        return out
    }

    private func sidepartNodes(_ ctx: HeadStyleContext) -> [SCNNode] {
        // Professional sidepart: a full-head base cap with a raised
        // asymmetric wave on top. The base sits centered on the skull
        // so the overall silhouette stays balanced — the asymmetry is
        // just the slightly-taller "swept" section on top.
        var out: [SCNNode] = []

        // Base layer — hugs the skull, centered.
        let base = SCNBox(
            width: ctx.headWidth * 0.98,
            height: ctx.headHeight * 0.22,
            length: ctx.headDepth * 0.96,
            chamferRadius: 6
        )
        base.materials = [styled(ctx.hairColor, roughness: 0.28, metalness: 0.24)]
        let baseNode = SCNNode(geometry: base)
        baseNode.name = "part.hair.0"
        baseNode.position = SCNVector3(0, ctx.headHeight * 0.38, 0)
        out.append(baseNode)

        // Raised sweep on the user's-left (Max's right) side — the
        // signature sidepart height. Subtle 5px offset, not a full
        // head-width skew.
        let sweep = SCNBox(
            width: ctx.headWidth * 0.58,
            height: ctx.headHeight * 0.18,
            length: ctx.headDepth * 0.80,
            chamferRadius: 4
        )
        sweep.materials = [styled(ctx.hairColor, roughness: 0.22, metalness: 0.30)]
        let sweepNode = SCNNode(geometry: sweep)
        sweepNode.name = "part.hair.1"
        sweepNode.eulerAngles = SCNVector3(0, 0, -0.08)  // slight tip
        sweepNode.position = SCNVector3(-ctx.headWidth * 0.08, ctx.headHeight * 0.52, 0)
        out.append(sweepNode)
        return out
    }

    private func quiffNodes(_ ctx: HeadStyleContext) -> [SCNNode] {
        // Front-swept wave — tall front quiff, lower sides.
        var out: [SCNNode] = []
        let front = SCNBox(
            width: ctx.headWidth * 0.60,
            height: ctx.headHeight * 0.38,
            length: ctx.headDepth * 0.45,
            chamferRadius: 10
        )
        front.materials = [styled(ctx.hairColor, roughness: 0.22, metalness: 0.32)]
        let frontNode = SCNNode(geometry: front)
        frontNode.name = "part.hair.0"
        frontNode.eulerAngles = SCNVector3(-0.35, 0, 0)  // tipped forward
        frontNode.position = SCNVector3(0, ctx.headHeight * 0.48, ctx.headDepth * 0.25)
        out.append(frontNode)

        let sides = SCNBox(
            width: ctx.headWidth * 0.95,
            height: ctx.headHeight * 0.16,
            length: ctx.headDepth * 0.88,
            chamferRadius: 5
        )
        sides.materials = [styled(ctx.hairColor, roughness: 0.28, metalness: 0.28)]
        let sidesNode = SCNNode(geometry: sides)
        sidesNode.name = "part.hair.1"
        sidesNode.position = SCNVector3(0, ctx.headHeight * 0.33, -ctx.headDepth * 0.05)
        out.append(sidesNode)
        return out
    }

    // MARK: - Phase C styles

    private func messyNodes(_ ctx: HeadStyleContext) -> [SCNNode] {
        // Chaotic tufts going in every direction — 7 irregularly-placed
        // chunks with random rotations. Reads as "bed head" / artistic
        // chaos versus the clean geometry of the other styles.
        var out: [SCNNode] = []
        let placements: [(x: CGFloat, y: CGFloat, z: CGFloat, yaw: Double, pitch: Double, roll: Double)] = [
            (-0.35,  0.50,  0.10,  0.3, -0.4,  0.2),
            ( 0.20,  0.55, -0.10, -0.2, -0.5, -0.3),
            (-0.10,  0.58,  0.20,  0.0, -0.3,  0.4),
            ( 0.40,  0.48,  0.00,  0.4, -0.2, -0.15),
            (-0.40,  0.45, -0.20,  0.6, -0.4,  0.1),
            ( 0.05,  0.62, -0.35,  0.0,  0.0, -0.2),
            ( 0.30,  0.50,  0.25, -0.5, -0.3,  0.3)
        ]
        for (i, p) in placements.enumerated() {
            let box = SCNBox(width: 9, height: 24, length: 10, chamferRadius: 2)
            box.materials = [styled(ctx.hairColor, roughness: 0.55, metalness: 0.12)]
            let node = SCNNode(geometry: box)
            node.name = "part.hair.\(i)"
            node.position = SCNVector3(
                p.x * ctx.headWidth,
                p.y * ctx.headHeight,
                p.z * ctx.headDepth
            )
            node.eulerAngles = SCNVector3(p.pitch, p.yaw, p.roll)
            out.append(node)
        }
        return out
    }

    private func undercutNodes(_ ctx: HeadStyleContext) -> [SCNNode] {
        // Shaved sides + back (thin shadow band), full hair only on top.
        // Read as an asymmetric top-slab with darkened flanks.
        var out: [SCNNode] = []

        // Top slab — thick forward-swept volume.
        let top = SCNBox(
            width: ctx.headWidth * 0.78,
            height: ctx.headHeight * 0.32,
            length: ctx.headDepth * 0.78,
            chamferRadius: 6
        )
        top.materials = [styled(ctx.hairColor, roughness: 0.22, metalness: 0.30)]
        let topNode = SCNNode(geometry: top)
        topNode.name = "part.hair.0"
        topNode.position = SCNVector3(-ctx.headWidth * 0.05, ctx.headHeight * 0.48, 0)
        topNode.eulerAngles = SCNVector3(0, 0, -0.08)
        out.append(topNode)

        // Shadow band around the base — thin, darker, hugging the skull.
        let shaved = (ctx.hairColor.usingColorSpace(.sRGB) ?? ctx.hairColor)
            .blended(withFraction: 0.55, of: .black) ?? ctx.hairColor
        let sides = SCNBox(
            width: ctx.headWidth * 0.98,
            height: ctx.headHeight * 0.14,
            length: ctx.headDepth * 0.96,
            chamferRadius: 3
        )
        sides.materials = [styled(shaved, roughness: 0.85, metalness: 0.02)]
        let sidesNode = SCNNode(geometry: sides)
        sidesNode.name = "part.hair.1"
        sidesNode.position = SCNVector3(0, ctx.headHeight * 0.28, 0)
        out.append(sidesNode)
        return out
    }

    private func topKnotNodes(_ ctx: HeadStyleContext) -> [SCNNode] {
        // Slick base + a tight spherical bun on top of the skull.
        var out: [SCNNode] = []

        let base = SCNBox(
            width: ctx.headWidth * 0.98,
            height: ctx.headHeight * 0.22,
            length: ctx.headDepth * 0.96,
            chamferRadius: 6
        )
        base.materials = [styled(ctx.hairColor, roughness: 0.28, metalness: 0.22)]
        let baseNode = SCNNode(geometry: base)
        baseNode.name = "part.hair.0"
        baseNode.position = SCNVector3(0, ctx.headHeight * 0.38, 0)
        out.append(baseNode)

        // The knot — a sphere wrapped in a tie.
        let knot = SCNSphere(radius: 11)
        knot.materials = [styled(ctx.hairColor, roughness: 0.35, metalness: 0.20)]
        let knotNode = SCNNode(geometry: knot)
        knotNode.name = "part.hair.1"
        knotNode.position = SCNVector3(0, ctx.headHeight * 0.70, 0)
        out.append(knotNode)

        // Hair tie ring at the base of the knot.
        let tie = SCNTorus(ringRadius: 10, pipeRadius: 1.5)
        tie.materials = [styled(.black, roughness: 0.9, metalness: 0.0)]
        let tieNode = SCNNode(geometry: tie)
        tieNode.name = "part.hair.2"
        tieNode.position = SCNVector3(0, ctx.headHeight * 0.59, 0)
        out.append(tieNode)
        return out
    }

    private func pigtailsNodes(_ ctx: HeadStyleContext) -> [SCNNode] {
        // Center-part top + two bundled tails hanging from the sides.
        var out: [SCNNode] = []

        // Scalp cover.
        let cap = SCNBox(
            width: ctx.headWidth * 0.96,
            height: ctx.headHeight * 0.22,
            length: ctx.headDepth * 0.94,
            chamferRadius: 6
        )
        cap.materials = [styled(ctx.hairColor, roughness: 0.30, metalness: 0.18)]
        let capNode = SCNNode(geometry: cap)
        capNode.name = "part.hair.0"
        capNode.position = SCNVector3(0, ctx.headHeight * 0.38, 0)
        out.append(capNode)

        // Two tied pigtails — one per side. Each: tie ring + tapering cylinder.
        let sides: [CGFloat] = [-1.0, 1.0]
        for i in 0..<sides.count {
            let sign = sides[i]
            let tie = SCNTorus(ringRadius: 5, pipeRadius: 1.5)
            tie.materials = [styled(.systemPink, roughness: 0.5, metalness: 0.0)]
            let tieNode = SCNNode(geometry: tie)
            tieNode.name = "part.hair.\(i * 2 + 1)"
            tieNode.eulerAngles = SCNVector3(0, 0, Double.pi / 2)
            tieNode.position = SCNVector3(
                sign * (ctx.headWidth / 2 + 2),
                ctx.headHeight * 0.22,
                0
            )
            out.append(tieNode)

            let tail = SCNCylinder(radius: 5, height: 45)
            tail.materials = [styled(ctx.hairColor, roughness: 0.35, metalness: 0.18)]
            let tailNode = SCNNode(geometry: tail)
            tailNode.name = "part.hair.\(i * 2 + 2)"
            tailNode.eulerAngles = SCNVector3(0, 0, Double(sign) * 0.35)
            tailNode.position = SCNVector3(
                sign * (ctx.headWidth / 2 + 9),
                -ctx.headHeight * 0.05,
                0
            )
            out.append(tailNode)
        }
        return out
    }

    private func cornrowsNodes(_ ctx: HeadStyleContext) -> [SCNNode] {
        // 7 parallel rows running front-to-back across the top of the head.
        var out: [SCNNode] = []
        for i in 0..<7 {
            let t = CGFloat(i) / 6.0 - 0.5  // -0.5 .. 0.5
            let row = SCNCylinder(radius: 2.5, height: ctx.headDepth * 0.92)
            row.materials = [styled(ctx.hairColor, roughness: 0.65, metalness: 0.08)]
            let rowNode = SCNNode(geometry: row)
            rowNode.name = "part.hair.\(i)"
            rowNode.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
            rowNode.position = SCNVector3(
                t * ctx.headWidth * 0.78,
                ctx.headHeight * 0.48 - abs(t) * ctx.headHeight * 0.08,
                0
            )
            out.append(rowNode)
        }
        return out
    }

    private func styled(_ color: NSColor, roughness: CGFloat, metalness: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = metalness
        return m
    }
}
