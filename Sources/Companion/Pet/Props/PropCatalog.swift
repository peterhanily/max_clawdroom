import AppKit
import SceneKit

/// Pure-SceneKit builders for every `Prop` case. Each returns a freshly-
/// constructed SCNNode subtree sized to Max's scale — Max is ~300px tall,
/// so a coffee mug is ~25px, a bike ~180px wide, a ladder ~260px tall.
///
/// Naming convention: top-level nodes are `prop.<name>`; internal
/// meshes use `prop.<name>.<part>`. This keeps the parts indexer from
/// mis-grouping them with Max's own `part.*` nodes.
enum PropCatalog {

    static func build(_ prop: Prop, args: [String: Any] = [:]) -> SCNNode {
        let root = SCNNode()
        root.name = "prop.\(prop.rawValue)"
        switch prop {
        case .bike:            buildBike(into: root)
        case .ladder:          buildLadder(into: root)
        case .water_gun:       buildWaterGun(into: root)
        case .guitar:          buildGuitar(into: root)
        case .skateboard:      buildSkateboard(into: root)
        case .coffee_mug:      buildCoffeeMug(into: root)
        case .umbrella:        buildUmbrella(into: root)
        case .briefcase:       buildBriefcase(into: root)
        case .phone:           buildPhone(into: root)
        case .book:            buildBook(into: root)
        case .balloon:         buildBalloon(into: root)
        case .flower:          buildFlower(into: root)
        case .scooter:         buildScooter(into: root)
        case .rollerblades:    buildRollerblades(into: root)
        case .pogo_stick:      buildPogoStick(into: root)
        case .hoverboard:      buildHoverboard(into: root)
        case .motorcycle:      buildMotorcycle(into: root)
        case .jetpack:         buildJetpack(into: root)
        case .sparkler:        buildSparkler(into: root)
        case .party_horn:      buildPartyHorn(into: root)
        case .laptop:          buildLaptop(into: root)
        case .paintbrush:      buildPaintbrush(into: root)
        case .magnifier:       buildMagnifier(into: root)
        case .wand:            buildWand(into: root)
        case .football:        buildFootball(into: root)
        case .baseball_bat:    buildBaseballBat(into: root)
        case .wrench:          buildWrench(into: root)
        case .pizza_slice:     buildPizzaSlice(into: root)
        case .ice_cream_cone:  buildIceCreamCone(into: root)
        case .donut:           buildDonut(into: root)
        case .cupcake:         buildCupcake(into: root)
        case .baseball_cap:    buildBaseballCap(into: root)
        case .top_hat:         buildTopHat(into: root)
        case .cowboy_hat:      buildCowboyHat(into: root)
        case .beanie:          buildBeanie(into: root)
        case .crown:           buildCrown(into: root)
        case .party_hat:       buildPartyHat(into: root)
        case .wizard_hat:      buildWizardHat(into: root)
        case .hard_hat:        buildHardHat(into: root)
        case .necklace:        buildNecklace(into: root)
        case .earrings:        buildEarrings(into: root)
        case .bracelet:        buildBracelet(into: root)
        case .watch:           buildWatch(into: root)
        case .ring:            buildRing(into: root)
        case .chef_hat:        buildChefHat(into: root)
        case .military_helmet: buildMilitaryHelmet(into: root)
        case .motorcycle_helmet: buildMotorcycleHelmet(into: root)
        case .pirate_hat:      buildPirateHat(into: root)
        case .astronaut_helmet: buildAstronautHelmet(into: root)
        case .ninja_headband:  buildNinjaHeadband(into: root)
        case .eye_patch:       buildEyePatch(into: root)
        case .gold_chain:      buildGoldChain(into: root)
        case .silver_chain:    buildSilverChain(into: root)
        case .nightcap:        buildNightcap(into: root)
        case .sleep_mask:      buildSleepMask(into: root)
        case .slippers:        buildSlippers(into: root)
        case .surgical_mask:   buildEmojiMask(into: root, emoji: "😷")
        case .bandit_mask:     buildEmojiMask(into: root, emoji: "🥷")
        case .gas_mask:        buildEmojiMask(into: root, emoji: "🥴")
        case .hockey_mask:     buildEmojiMask(into: root, emoji: "💀")
        case .plague_doctor:   buildEmojiMask(into: root, emoji: "👹")
        case .face_emoji:
            // Resolution order: explicit `emoji` (verbatim glyph) →
            // `name` (curated lookup) → fallback ❓ so failure is loud.
            let resolved: String
            if let raw = args["emoji"] as? String, !raw.isEmpty {
                resolved = raw
            } else if let name = (args["name"] as? String)?.lowercased(),
                      let glyph = faceEmojiTable[name] {
                resolved = glyph
            } else {
                resolved = "❓"
            }
            buildEmojiMask(into: root, emoji: resolved)
        case .tentacles:
            // Count is the only tunable arg today (4–10, default 6).
            // Anything outside the band gets clamped — keeps Max from
            // disappearing under 30 tentacles or showing 1 lonely one.
            let raw = (args["count"] as? Int)
                ?? (args["count"] as? Double).map(Int.init)
                ?? 6
            let count = max(4, min(10, raw))
            buildTentacles(into: root, count: count)
        case .cape:
            // Optional color override; default is classic comic-book
            // red. Agent passes `{"color":"#rrggbb"}` for noir black,
            // gold-foil yellow, etc. Anything that fails to parse falls
            // back to the default — silent rather than a build error.
            let color: NSColor = {
                if let hex = args["color"] as? String,
                   let parsed = NSColor.fromHex(hex) {
                    return parsed
                }
                return NSColor(srgbRed: 0.78, green: 0.09, blue: 0.11, alpha: 1.0)
            }()
            buildCape(into: root, color: color)
        }
        return root
    }

    // MARK: - Material helpers

    private static func mat(_ color: NSColor, roughness: CGFloat = 0.55, metalness: CGFloat = 0.05) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = metalness
        return m
    }

    private static func matMetal(_ color: NSColor) -> SCNMaterial {
        mat(color, roughness: 0.25, metalness: 0.85)
    }

    // MARK: - Props

    private static func buildBike(into root: SCNNode) {
        let frameColor = NSColor(srgbRed: 0.86, green: 0.18, blue: 0.22, alpha: 1.0)
        let tireColor  = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        let rimColor   = NSColor(calibratedWhite: 0.80, alpha: 1.0)
        let spokeColor = NSColor(calibratedWhite: 0.90, alpha: 1.0)
        let seatColor  = NSColor(calibratedWhite: 0.05, alpha: 1.0)
        let chainColor = NSColor(calibratedWhite: 0.35, alpha: 1.0)

        let wheelR: CGFloat = 48
        let wheelTube: CGFloat = 5

        // Wheel factory — tire + rim + 6 spokes.
        func wheel(x: CGFloat) -> SCNNode {
            let assembly = SCNNode()

            let tire = SCNTorus(ringRadius: wheelR, pipeRadius: wheelTube)
            tire.materials = [mat(tireColor, roughness: 0.9)]
            let tireNode = SCNNode(geometry: tire)
            tireNode.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
            assembly.addChildNode(tireNode)

            // Rim just inside the tire.
            let rimTube = SCNTorus(ringRadius: wheelR - 6, pipeRadius: 1.2)
            rimTube.materials = [matMetal(rimColor)]
            let rimNode = SCNNode(geometry: rimTube)
            rimNode.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
            assembly.addChildNode(rimNode)

            // Hub in the center.
            let hub = SCNCylinder(radius: 5, height: 3)
            hub.materials = [matMetal(rimColor)]
            let hubNode = SCNNode(geometry: hub)
            hubNode.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
            assembly.addChildNode(hubNode)

            // Six spokes radiating from hub to rim.
            for i in 0..<6 {
                let theta = Double(i) / 6.0 * 2 * .pi
                let spoke = SCNCylinder(radius: 0.5, height: wheelR - 7)
                spoke.materials = [matMetal(spokeColor)]
                let node = SCNNode(geometry: spoke)
                // Rotate spoke to point at angle theta in the wheel plane.
                node.eulerAngles = SCNVector3(0, 0, CGFloat(theta))
                // Offset toward the rim by half its length.
                let midR = (wheelR - 7) / 2 + 3
                node.position = SCNVector3(
                    CGFloat(cos(theta)) * midR,
                    CGFloat(sin(theta)) * midR,
                    0
                )
                assembly.addChildNode(node)
            }

            assembly.position = SCNVector3(x, wheelR, 0)
            return assembly
        }
        root.addChildNode(wheel(x: -55))
        root.addChildNode(wheel(x: 55))

        func strut(from a: SCNVector3, to b: SCNVector3, radius: CGFloat = 3.2) -> SCNNode {
            let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
            let length = CGFloat(sqrt(Double(dx * dx + dy * dy + dz * dz)))
            let cyl = SCNCylinder(radius: radius, height: length)
            cyl.materials = [mat(frameColor, roughness: 0.25, metalness: 0.4)]
            let node = SCNNode(geometry: cyl)
            node.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
            let up = SCNVector3(0, 1, 0)
            let axis = SCNVector3(
                up.y * CGFloat(dz) - up.z * CGFloat(dy),
                up.z * CGFloat(dx) - up.x * CGFloat(dz),
                up.x * CGFloat(dy) - up.y * CGFloat(dx)
            )
            let angle = acos(CGFloat(dy) / length)
            node.rotation = SCNVector4(axis.x, axis.y, axis.z, angle)
            return node
        }

        // Classic diamond frame plus seat tube + seat stays so the
        // silhouette reads as a real bike rather than a stick figure.
        let bottomBracket = SCNVector3(0, wheelR - 12, 0)
        let seatCluster   = SCNVector3(-18, wheelR + 70, 0)
        let headTubeTop   = SCNVector3(48, wheelR + 58, 0)
        let headTubeBot   = SCNVector3(50, wheelR + 10, 0)
        let rearHub       = SCNVector3(-55, wheelR, 0)
        let frontHub      = SCNVector3(55, wheelR, 0)

        // Main triangle.
        root.addChildNode(strut(from: bottomBracket, to: seatCluster, radius: 3.5))
        root.addChildNode(strut(from: bottomBracket, to: headTubeBot, radius: 3.5))
        root.addChildNode(strut(from: seatCluster, to: headTubeTop, radius: 3.5))

        // Head tube + fork + steering column.
        root.addChildNode(strut(from: headTubeBot, to: headTubeTop, radius: 3))
        root.addChildNode(strut(from: headTubeBot, to: frontHub, radius: 2.5))

        // Seat stays + chain stays (rear triangle).
        root.addChildNode(strut(from: seatCluster, to: rearHub, radius: 2.5))
        root.addChildNode(strut(from: bottomBracket, to: rearHub, radius: 2.5))

        // Bottom bracket nub.
        let bb = SCNSphere(radius: 5)
        bb.materials = [matMetal(rimColor)]
        let bbNode = SCNNode(geometry: bb)
        bbNode.position = bottomBracket
        root.addChildNode(bbNode)

        // Seat.
        let seat = SCNBox(width: 26, height: 4, length: 12, chamferRadius: 3)
        seat.materials = [mat(seatColor, roughness: 0.35)]
        let seatNode = SCNNode(geometry: seat)
        seatNode.position = SCNVector3(seatCluster.x, seatCluster.y + 4, 0)
        root.addChildNode(seatNode)

        // Handlebars + grips.
        let bar = SCNCylinder(radius: 2, height: 42)
        bar.materials = [matMetal(rimColor)]
        let barNode = SCNNode(geometry: bar)
        barNode.eulerAngles = SCNVector3(0, 0, Double.pi / 2)
        barNode.position = SCNVector3(headTubeTop.x + 6, headTubeTop.y + 4, 0)
        root.addChildNode(barNode)

        for z in [-18.0, 18.0] {
            let grip = SCNCylinder(radius: 2.5, height: 7)
            grip.materials = [mat(seatColor, roughness: 0.6)]
            let g = SCNNode(geometry: grip)
            g.eulerAngles = SCNVector3(0, 0, Double.pi / 2)
            g.position = SCNVector3(
                headTubeTop.x + 6 + CGFloat(z > 0 ? 22 : -22),
                headTubeTop.y + 4,
                0
            )
            root.addChildNode(g)
        }

        // Pedals + crank arm.
        for xs in [-12.0, 12.0] {
            let crank = SCNBox(width: 18, height: 3, length: 2, chamferRadius: 0.5)
            crank.materials = [matMetal(rimColor)]
            let c = SCNNode(geometry: crank)
            c.eulerAngles = SCNVector3(0, 0, xs > 0 ? 0.5 : -0.5)
            c.position = SCNVector3(
                bottomBracket.x + CGFloat(xs > 0 ? 10 : -10),
                bottomBracket.y + CGFloat(xs > 0 ? 6 : -6),
                CGFloat(xs > 0 ? 4 : -4)
            )
            root.addChildNode(c)

            // Pedal on each crank end.
            let pedal = SCNBox(width: 10, height: 2, length: 5, chamferRadius: 0.5)
            pedal.materials = [mat(seatColor, roughness: 0.5)]
            let p = SCNNode(geometry: pedal)
            p.position = SCNVector3(
                bottomBracket.x + CGFloat(xs > 0 ? 20 : -20),
                bottomBracket.y + CGFloat(xs > 0 ? 12 : -12),
                CGFloat(xs > 0 ? 4 : -4)
            )
            root.addChildNode(p)
        }

        // Chain — thin dark line from bottom bracket to rear hub,
        // approximated with a cylinder.
        let chain = strut(
            from: SCNVector3(bottomBracket.x, bottomBracket.y - 2, 0),
            to: SCNVector3(rearHub.x, rearHub.y - 2, 0),
            radius: 0.8
        )
        // Override material to chain color.
        chain.geometry?.materials = [matMetal(chainColor)]
        root.addChildNode(chain)
    }

    private static func buildLadder(into root: SCNNode) {
        let woodColor = NSColor(srgbRed: 0.75, green: 0.55, blue: 0.32, alpha: 1.0)
        let rail = SCNCylinder(radius: 3, height: 260)
        rail.materials = [mat(woodColor, roughness: 0.75)]
        let leftRail = SCNNode(geometry: rail)
        leftRail.position = SCNVector3(-20, 130, 0)
        root.addChildNode(leftRail)
        let rightRail = SCNNode(geometry: rail.copy() as! SCNGeometry)
        rightRail.position = SCNVector3(20, 130, 0)
        root.addChildNode(rightRail)

        // Rungs every 45 px.
        for i in 0..<6 {
            let rung = SCNCylinder(radius: 2, height: 46)
            rung.materials = [mat(woodColor, roughness: 0.75)]
            let node = SCNNode(geometry: rung)
            node.eulerAngles = SCNVector3(0, 0, Double.pi / 2)
            node.position = SCNVector3(0, 30 + CGFloat(i) * 42, 0)
            root.addChildNode(node)
        }
    }

    private static func buildWaterGun(into root: SCNNode) {
        let bodyColor    = NSColor(srgbRed: 0.96, green: 0.55, blue: 0.12, alpha: 1.0)  // Super Soaker orange
        let accentColor  = NSColor(srgbRed: 0.80, green: 0.30, blue: 0.08, alpha: 1.0)
        let tankColor    = NSColor(srgbRed: 0.15, green: 0.55, blue: 0.85, alpha: 0.80)
        let waterColor   = NSColor(srgbRed: 0.10, green: 0.45, blue: 0.80, alpha: 1.0)
        let nozzleColor  = NSColor(calibratedWhite: 0.12, alpha: 1.0)
        let triggerColor = NSColor(calibratedWhite: 0.20, alpha: 1.0)

        // Main body — shaped in two stages: fore-body (thinner, with
        // nozzle) and rear-body (chunkier, with tank-well).
        let foreBody = SCNBox(width: 28, height: 22, length: 46, chamferRadius: 5)
        foreBody.materials = [mat(bodyColor, roughness: 0.35, metalness: 0.05)]
        let foreNode = SCNNode(geometry: foreBody)
        foreNode.position = SCNVector3(0, 0, 12)
        root.addChildNode(foreNode)

        let rearBody = SCNBox(width: 32, height: 30, length: 32, chamferRadius: 6)
        rearBody.materials = [mat(bodyColor, roughness: 0.35, metalness: 0.05)]
        let rearNode = SCNNode(geometry: rearBody)
        rearNode.position = SCNVector3(0, 4, -18)
        root.addChildNode(rearNode)

        // Accent stripe along the body sides.
        for sx in [-1.0, 1.0] {
            let stripe = SCNBox(width: 2, height: 6, length: 70, chamferRadius: 0.5)
            stripe.materials = [mat(accentColor, roughness: 0.3)]
            let s = SCNNode(geometry: stripe)
            s.position = SCNVector3(CGFloat(sx) * 15, 0, 0)
            root.addChildNode(s)
        }

        // Grip — angled slightly back for ergonomic feel.
        let grip = SCNBox(width: 16, height: 42, length: 18, chamferRadius: 4)
        grip.materials = [mat(bodyColor, roughness: 0.45, metalness: 0.05)]
        let gripNode = SCNNode(geometry: grip)
        gripNode.eulerAngles = SCNVector3(-0.25, 0, 0)
        gripNode.position = SCNVector3(0, -28, -14)
        root.addChildNode(gripNode)

        // Trigger — visible dark curl under the body.
        let trigger = SCNTorus(ringRadius: 4, pipeRadius: 1.2)
        trigger.materials = [mat(triggerColor, roughness: 0.35, metalness: 0.4)]
        let triggerNode = SCNNode(geometry: trigger)
        triggerNode.eulerAngles = SCNVector3(0, 0, Double.pi / 2)
        triggerNode.position = SCNVector3(0, -14, 0)
        root.addChildNode(triggerNode)

        // Trigger guard.
        let guardGeom = SCNTorus(ringRadius: 9, pipeRadius: 1.5)
        guardGeom.materials = [mat(bodyColor, roughness: 0.35)]
        let guard_ = SCNNode(geometry: guardGeom)
        guard_.eulerAngles = SCNVector3(0, 0, Double.pi / 2)
        guard_.position = SCNVector3(0, -14, 0)
        root.addChildNode(guard_)

        // Tank — big chunky translucent reservoir riding on top.
        let tank = SCNSphere(radius: 20)
        let tankM = mat(tankColor, roughness: 0.15, metalness: 0.10)
        tankM.transparency = 0.75
        tank.materials = [tankM]
        let tankNode = SCNNode(geometry: tank)
        tankNode.scale = SCNVector3(1.1, 1.0, 1.0)
        tankNode.position = SCNVector3(0, 20, -20)
        root.addChildNode(tankNode)

        // Water inside the tank — smaller inner sphere at half height.
        let water = SCNSphere(radius: 17)
        water.materials = [mat(waterColor, roughness: 0.08, metalness: 0.0)]
        let waterNode = SCNNode(geometry: water)
        waterNode.scale = SCNVector3(1.05, 0.6, 0.95)
        waterNode.position = SCNVector3(0, 14, -20)
        root.addChildNode(waterNode)

        // Tank mounting tube — connects tank to gun body.
        let tankTube = SCNCylinder(radius: 4, height: 10)
        tankTube.materials = [mat(accentColor, roughness: 0.3)]
        let tankTubeNode = SCNNode(geometry: tankTube)
        tankTubeNode.position = SCNVector3(0, 8, -20)
        root.addChildNode(tankTubeNode)

        // Barrel extension — narrower tube sticking forward from main body.
        let barrel = SCNCylinder(radius: 4, height: 24)
        barrel.materials = [mat(accentColor, roughness: 0.3, metalness: 0.3)]
        let barrelNode = SCNNode(geometry: barrel)
        barrelNode.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        barrelNode.position = SCNVector3(0, 0, 45)
        root.addChildNode(barrelNode)

        // Nozzle tip — dark flared end.
        let nozzle = SCNCone(topRadius: 4.5, bottomRadius: 3, height: 8)
        nozzle.materials = [mat(nozzleColor, roughness: 0.25, metalness: 0.7)]
        let nozzleNode = SCNNode(geometry: nozzle)
        nozzleNode.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        nozzleNode.position = SCNVector3(0, 0, 60)
        root.addChildNode(nozzleNode)

        // Pump handle — the bit you slide on a super-soaker.
        let pump = SCNBox(width: 12, height: 8, length: 20, chamferRadius: 2)
        pump.materials = [mat(accentColor, roughness: 0.3)]
        let pumpNode = SCNNode(geometry: pump)
        pumpNode.position = SCNVector3(0, -14, 20)
        root.addChildNode(pumpNode)
    }

    private static func buildGuitar(into root: SCNNode) {
        let bodyColor    = NSColor(srgbRed: 0.38, green: 0.14, blue: 0.08, alpha: 1.0)
        let bodyAccent   = NSColor(srgbRed: 0.22, green: 0.08, blue: 0.05, alpha: 1.0)
        let neckColor    = NSColor(srgbRed: 0.24, green: 0.12, blue: 0.06, alpha: 1.0)
        let fretColor    = NSColor(calibratedWhite: 0.80, alpha: 1.0)
        let stringColor  = NSColor(calibratedWhite: 0.90, alpha: 1.0)
        let tunerColor   = NSColor(calibratedWhite: 0.75, alpha: 1.0)

        // Lower bout — the larger of the two body curves.
        let lowerBout = SCNSphere(radius: 32)
        lowerBout.materials = [mat(bodyColor, roughness: 0.18, metalness: 0.20)]
        let lowerNode = SCNNode(geometry: lowerBout)
        lowerNode.scale = SCNVector3(1.0, 0.9, 0.35)
        lowerNode.position = SCNVector3(0, -5, 0)
        root.addChildNode(lowerNode)

        // Upper bout — slightly smaller, overlapping so the transition
        // reads as a guitar's classic waist.
        let upperBout = SCNSphere(radius: 24)
        upperBout.materials = [mat(bodyColor, roughness: 0.18, metalness: 0.20)]
        let upperNode = SCNNode(geometry: upperBout)
        upperNode.scale = SCNVector3(0.9, 0.85, 0.35)
        upperNode.position = SCNVector3(0, 35, 0)
        root.addChildNode(upperNode)

        // Sound hole — dark disc set into the lower bout.
        let soundHole = SCNCylinder(radius: 7, height: 1.5)
        soundHole.materials = [mat(bodyAccent, roughness: 0.8)]
        let soundHoleNode = SCNNode(geometry: soundHole)
        soundHoleNode.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        soundHoleNode.position = SCNVector3(0, 0, 11)
        root.addChildNode(soundHoleNode)

        // Bridge — small box below the sound hole where the strings
        // anchor.
        let bridge = SCNBox(width: 14, height: 3, length: 2, chamferRadius: 0.5)
        bridge.materials = [mat(neckColor, roughness: 0.4)]
        let bridgeNode = SCNNode(geometry: bridge)
        bridgeNode.position = SCNVector3(0, -20, 12)
        root.addChildNode(bridgeNode)

        // Neck — longer, wider at the body end.
        let neck = SCNBox(width: 9, height: 115, length: 4.5, chamferRadius: 1)
        neck.materials = [mat(neckColor, roughness: 0.3)]
        let neckNode = SCNNode(geometry: neck)
        neckNode.position = SCNVector3(0, 118, 2)
        root.addChildNode(neckNode)

        // Fretboard overlay — darker strip on top of the neck.
        let fretboard = SCNBox(width: 7, height: 112, length: 0.8, chamferRadius: 0.2)
        fretboard.materials = [mat(bodyAccent, roughness: 0.5)]
        let fretboardNode = SCNNode(geometry: fretboard)
        fretboardNode.position = SCNVector3(0, 118, 4.5)
        root.addChildNode(fretboardNode)

        // Frets — 6 thin metal strips across the fretboard.
        for i in 0..<6 {
            let y = 70 + CGFloat(i) * 18
            let fret = SCNBox(width: 8, height: 0.8, length: 1, chamferRadius: 0)
            fret.materials = [matMetal(fretColor)]
            let f = SCNNode(geometry: fret)
            f.position = SCNVector3(0, y, 5)
            root.addChildNode(f)
        }

        // Head — paddle-shaped. Slightly wider than the neck, angled back.
        let head = SCNBox(width: 14, height: 22, length: 4, chamferRadius: 1)
        head.materials = [mat(neckColor, roughness: 0.3)]
        let headNode = SCNNode(geometry: head)
        headNode.eulerAngles = SCNVector3(-0.25, 0, 0)
        headNode.position = SCNVector3(0, 184, 0)
        root.addChildNode(headNode)

        // Six tuning pegs — three each side of the head.
        for side in [-6.0, 6.0] {
            for i in 0..<3 {
                let peg = SCNCylinder(radius: 1.2, height: 4)
                peg.materials = [matMetal(tunerColor)]
                let p = SCNNode(geometry: peg)
                p.eulerAngles = SCNVector3(0, 0, Double.pi / 2)
                p.position = SCNVector3(
                    CGFloat(side),
                    178 + CGFloat(i) * 6,
                    -2
                )
                root.addChildNode(p)
            }
        }

        // Six strings — run from bridge through sound-hole-ish area
        // up the fretboard to the head.
        for i in 0..<6 {
            let s = SCNCylinder(radius: 0.35 + CGFloat(i) * 0.06, height: 208)
            s.materials = [matMetal(stringColor)]
            let sn = SCNNode(geometry: s)
            sn.position = SCNVector3(CGFloat(i - 2) * 1.6 - 0.5, 78, 6)
            root.addChildNode(sn)
        }
    }

    private static func buildSkateboard(into root: SCNNode) {
        let deckTop    = NSColor(srgbRed: 0.15, green: 0.20, blue: 0.35, alpha: 1.0)
        let deckBottom = NSColor(srgbRed: 0.75, green: 0.14, blue: 0.20, alpha: 1.0)
        let gripColor  = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        let wheelColor = NSColor(srgbRed: 0.96, green: 0.93, blue: 0.82, alpha: 1.0)  // cream urethane
        let truckColor = NSColor(calibratedWhite: 0.75, alpha: 1.0)
        let boltColor  = NSColor(calibratedWhite: 0.25, alpha: 1.0)

        // Deck top — the stand-on surface with grip tape layer.
        let deck = SCNBox(width: 150, height: 4, length: 42, chamferRadius: 14)
        deck.materials = [mat(deckTop, roughness: 0.5)]
        let deckNode = SCNNode(geometry: deck)
        deckNode.position = SCNVector3(0, 12, 0)
        root.addChildNode(deckNode)

        // Grip tape — thin black layer on top of deck.
        let grip = SCNBox(width: 146, height: 0.8, length: 38, chamferRadius: 12)
        grip.materials = [mat(gripColor, roughness: 0.95)]
        let gripNode = SCNNode(geometry: grip)
        gripNode.position = SCNVector3(0, 14.4, 0)
        root.addChildNode(gripNode)

        // Deck graphic underside — red panel.
        let underside = SCNBox(width: 148, height: 0.6, length: 40, chamferRadius: 13)
        underside.materials = [mat(deckBottom, roughness: 0.35, metalness: 0.1)]
        let undersideNode = SCNNode(geometry: underside)
        undersideNode.position = SCNVector3(0, 9.7, 0)
        root.addChildNode(undersideNode)

        for xs in [-55.0, 55.0] {
            // Mounting bolts (4 per truck) on top of deck.
            for bx in [-4.0, 4.0] {
                for bz in [-10.0, 10.0] {
                    let bolt = SCNCylinder(radius: 1.2, height: 2)
                    bolt.materials = [matMetal(boltColor)]
                    let b = SCNNode(geometry: bolt)
                    b.position = SCNVector3(CGFloat(xs + bx), 15, CGFloat(bz))
                    root.addChildNode(b)
                }
            }

            // Base plate + hanger (the two-part truck).
            let basePlate = SCNBox(width: 20, height: 3, length: 22, chamferRadius: 1)
            basePlate.materials = [matMetal(truckColor)]
            let bp = SCNNode(geometry: basePlate)
            bp.position = SCNVector3(CGFloat(xs), 9, 0)
            root.addChildNode(bp)

            let hanger = SCNBox(width: 10, height: 5, length: 40, chamferRadius: 2)
            hanger.materials = [matMetal(truckColor)]
            let h = SCNNode(geometry: hanger)
            h.position = SCNVector3(CGFloat(xs), 6, 0)
            root.addChildNode(h)

            // Axles — thin cylinders poking out each side of the hanger.
            let axle = SCNCylinder(radius: 1.2, height: 44)
            axle.materials = [matMetal(boltColor)]
            let axleNode = SCNNode(geometry: axle)
            axleNode.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
            axleNode.position = SCNVector3(CGFloat(xs), 6, 0)
            root.addChildNode(axleNode)

            // Wheels — cylinders (not spheres) for the flat urethane look.
            for zs in [-17.0, 17.0] {
                let wheel = SCNCylinder(radius: 5.5, height: 6)
                wheel.materials = [mat(wheelColor, roughness: 0.75)]
                let w = SCNNode(geometry: wheel)
                w.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
                w.position = SCNVector3(CGFloat(xs), 5.5, CGFloat(zs))
                root.addChildNode(w)

                // Inner wheel disc (hub) — darker, contrasts with urethane.
                let hub = SCNCylinder(radius: 2.2, height: 6.2)
                hub.materials = [matMetal(boltColor)]
                let hubNode = SCNNode(geometry: hub)
                hubNode.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
                hubNode.position = SCNVector3(CGFloat(xs), 5.5, CGFloat(zs))
                root.addChildNode(hubNode)
            }
        }
    }

    private static func buildCoffeeMug(into root: SCNNode) {
        let cupColor    = NSColor(calibratedWhite: 0.96, alpha: 1.0)
        let bandColor   = NSColor(srgbRed: 0.82, green: 0.18, blue: 0.24, alpha: 1.0)
        let coffeeColor = NSColor(srgbRed: 0.22, green: 0.10, blue: 0.04, alpha: 1.0)
        let steamColor  = NSColor(calibratedWhite: 1.0, alpha: 0.35)

        // Body — tapered (slightly wider at top).
        let cup = SCNCylinder(radius: 12, height: 28)
        cup.materials = [mat(cupColor, roughness: 0.35, metalness: 0.05)]
        let cupNode = SCNNode(geometry: cup)
        root.addChildNode(cupNode)

        // Decorative red band around the middle — classic diner mug.
        let band = SCNTube(innerRadius: 12.0, outerRadius: 12.6, height: 5)
        band.materials = [mat(bandColor, roughness: 0.3, metalness: 0.1)]
        let bandNode = SCNNode(geometry: band)
        bandNode.position = SCNVector3(0, 2, 0)
        root.addChildNode(bandNode)

        // Interior rim so you can see the cup is hollow-ish from
        // above. A dark inner cylinder one step inside the walls.
        let inner = SCNCylinder(radius: 10, height: 24)
        inner.materials = [mat(NSColor(calibratedWhite: 0.88, alpha: 1.0), roughness: 0.5)]
        let innerNode = SCNNode(geometry: inner)
        innerNode.position = SCNVector3(0, 1, 0)
        root.addChildNode(innerNode)

        // Coffee surface.
        let coffee = SCNCylinder(radius: 10, height: 1.2)
        let coffeeM = mat(coffeeColor, roughness: 0.12)
        coffeeM.specular.contents = NSColor(calibratedWhite: 0.9, alpha: 1.0)
        coffee.materials = [coffeeM]
        let coffeeNode = SCNNode(geometry: coffee)
        coffeeNode.position = SCNVector3(0, 13, 0)
        root.addChildNode(coffeeNode)

        // Chunky D-shaped handle: two stubs + connecting torus. A
        // single torus looked anemic at Max's scale.
        let handleTube: CGFloat = 2.2
        let outerR: CGFloat = 8.5
        let handle = SCNTorus(ringRadius: outerR, pipeRadius: handleTube)
        handle.materials = [mat(cupColor, roughness: 0.35)]
        let handleNode = SCNNode(geometry: handle)
        handleNode.eulerAngles = SCNVector3(0, 0, Double.pi / 2)
        handleNode.position = SCNVector3(12.5, 2, 0)
        root.addChildNode(handleNode)

        // Three wisps of steam — thin vertical cylinders with a bit
        // of wave via sine offsets, semi-transparent.
        let steamM = mat(steamColor, roughness: 0.9, metalness: 0.0)
        steamM.transparency = 0.6
        for i in 0..<3 {
            let phase = Double(i) * 0.6
            let x = CGFloat(sin(phase)) * 3
            let wisp = SCNCylinder(radius: 1.2, height: 18)
            wisp.materials = [steamM]
            let w = SCNNode(geometry: wisp)
            w.position = SCNVector3(x + CGFloat(i - 1) * 3, 26, 0)
            w.eulerAngles = SCNVector3(0, 0, CGFloat(sin(phase) * 0.2))
            root.addChildNode(w)
        }
    }

    private static func buildUmbrella(into root: SCNNode) {
        let canopyColor = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.5, alpha: 1.0)
        let handleColor = NSColor(srgbRed: 0.4, green: 0.25, blue: 0.12, alpha: 1.0)

        let shaft = SCNCylinder(radius: 1.5, height: 140)
        shaft.materials = [mat(handleColor, roughness: 0.5)]
        let shaftNode = SCNNode(geometry: shaft)
        root.addChildNode(shaftNode)

        // Canopy: half-sphere.
        let canopy = SCNSphere(radius: 55)
        canopy.materials = [mat(canopyColor, roughness: 0.4)]
        let canopyNode = SCNNode(geometry: canopy)
        canopyNode.scale = SCNVector3(1, 0.55, 1)
        canopyNode.position = SCNVector3(0, 68, 0)
        root.addChildNode(canopyNode)

        // Crook at bottom of shaft.
        let crook = SCNTorus(ringRadius: 8, pipeRadius: 1.5)
        crook.materials = [mat(handleColor, roughness: 0.5)]
        let crookNode = SCNNode(geometry: crook)
        crookNode.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        crookNode.position = SCNVector3(6, -72, 0)
        root.addChildNode(crookNode)
    }

    private static func buildBriefcase(into root: SCNNode) {
        let caseColor   = NSColor(srgbRed: 0.3, green: 0.18, blue: 0.08, alpha: 1.0)
        let handleColor = NSColor(calibratedWhite: 0.2, alpha: 1.0)

        let body = SCNBox(width: 42, height: 30, length: 12, chamferRadius: 2)
        body.materials = [mat(caseColor, roughness: 0.35)]
        let bodyNode = SCNNode(geometry: body)
        root.addChildNode(bodyNode)

        let handle = SCNTorus(ringRadius: 6, pipeRadius: 1.5)
        handle.materials = [mat(handleColor, roughness: 0.4, metalness: 0.4)]
        let handleNode = SCNNode(geometry: handle)
        handleNode.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        handleNode.position = SCNVector3(0, 20, 0)
        root.addChildNode(handleNode)

        // Two latches
        for xs in [-12, 12] {
            let latch = SCNBox(width: 5, height: 3, length: 2, chamferRadius: 0.5)
            latch.materials = [matMetal(handleColor)]
            let latchNode = SCNNode(geometry: latch)
            latchNode.position = SCNVector3(CGFloat(xs), 6, 7)
            root.addChildNode(latchNode)
        }
    }

    private static func buildPhone(into root: SCNNode) {
        let caseColor   = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        let screenColor = NSColor(srgbRed: 0.2, green: 0.35, blue: 0.55, alpha: 1.0)

        let body = SCNBox(width: 14, height: 28, length: 3, chamferRadius: 1.5)
        body.materials = [mat(caseColor, roughness: 0.25, metalness: 0.1)]
        let bodyNode = SCNNode(geometry: body)
        root.addChildNode(bodyNode)

        let screen = SCNPlane(width: 11, height: 24)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = screenColor
        m.emission.contents = screenColor.withAlphaComponent(0.4)
        screen.materials = [m]
        let screenNode = SCNNode(geometry: screen)
        screenNode.position = SCNVector3(0, 0, 1.6)
        root.addChildNode(screenNode)
    }

    private static func buildBook(into root: SCNNode) {
        let coverColor = NSColor(srgbRed: 0.3, green: 0.15, blue: 0.5, alpha: 1.0)
        let pageColor  = NSColor(calibratedWhite: 0.95, alpha: 1.0)

        let cover = SCNBox(width: 26, height: 36, length: 4, chamferRadius: 0.5)
        cover.materials = [mat(coverColor, roughness: 0.5)]
        let coverNode = SCNNode(geometry: cover)
        root.addChildNode(coverNode)

        let pages = SCNBox(width: 24, height: 34, length: 3, chamferRadius: 0)
        pages.materials = [mat(pageColor, roughness: 0.7)]
        let pageNode = SCNNode(geometry: pages)
        pageNode.position = SCNVector3(0, 0, 0)
        root.addChildNode(pageNode)
    }

    private static func buildBalloon(into root: SCNNode) {
        let balloonColor = NSColor(srgbRed: 0.9, green: 0.18, blue: 0.32, alpha: 1.0)
        let stringColor = NSColor(calibratedWhite: 0.6, alpha: 1.0)

        let balloon = SCNSphere(radius: 26)
        balloon.materials = [mat(balloonColor, roughness: 0.15, metalness: 0.0)]
        let balloonNode = SCNNode(geometry: balloon)
        balloonNode.scale = SCNVector3(0.9, 1.1, 0.9)
        balloonNode.position = SCNVector3(0, 60, 0)
        root.addChildNode(balloonNode)

        // Knot
        let knot = SCNSphere(radius: 4)
        knot.materials = [mat(balloonColor, roughness: 0.2)]
        let knotNode = SCNNode(geometry: knot)
        knotNode.position = SCNVector3(0, 30, 0)
        root.addChildNode(knotNode)

        // Dangling string
        let s = SCNCylinder(radius: 0.4, height: 55)
        s.materials = [mat(stringColor, roughness: 0.8)]
        let sn = SCNNode(geometry: s)
        sn.position = SCNVector3(0, 0, 0)
        root.addChildNode(sn)
    }

    private static func buildFlower(into root: SCNNode) {
        let petalColor = NSColor(srgbRed: 1.0, green: 0.6, blue: 0.7, alpha: 1.0)
        let centerColor = NSColor(srgbRed: 0.98, green: 0.85, blue: 0.25, alpha: 1.0)
        let stemColor = NSColor(srgbRed: 0.15, green: 0.55, blue: 0.22, alpha: 1.0)

        let stem = SCNCylinder(radius: 0.8, height: 70)
        stem.materials = [mat(stemColor, roughness: 0.7)]
        let stemNode = SCNNode(geometry: stem)
        root.addChildNode(stemNode)

        // 5 petals arranged around the head.
        for i in 0..<5 {
            let angle = Double(i) / 5 * 2 * .pi
            let petal = SCNSphere(radius: 6)
            petal.materials = [mat(petalColor, roughness: 0.3)]
            let petalNode = SCNNode(geometry: petal)
            petalNode.scale = SCNVector3(1.2, 0.6, 1.2)
            petalNode.position = SCNVector3(
                cos(angle) * 7,
                35,
                sin(angle) * 7
            )
            root.addChildNode(petalNode)
        }
        let center = SCNSphere(radius: 4)
        center.materials = [mat(centerColor, roughness: 0.35)]
        let centerNode = SCNNode(geometry: center)
        centerNode.position = SCNVector3(0, 35, 0)
        root.addChildNode(centerNode)
    }

    // MARK: - Hats (aboveHead anchor; y=0 = bottom of hat, rests on head)

    private static func buildBaseballCap(into root: SCNNode) {
        let navy = NSColor(srgbRed: 0.10, green: 0.15, blue: 0.27, alpha: 1)
        let dark = NSColor(srgbRed: 0.06, green: 0.08, blue: 0.14, alpha: 1)
        // Dome — squished sphere resting at y=0
        let dome = SCNSphere(radius: 26)
        dome.materials = [mat(navy, roughness: 0.55)]
        let domeNode = SCNNode(geometry: dome)
        domeNode.scale = SCNVector3(1.0, 0.65, 0.95)
        domeNode.position = SCNVector3(0, 8, 0)
        root.addChildNode(domeNode)
        // Bill — flat box jutting forward
        let bill = SCNBox(width: 36, height: 4, length: 20, chamferRadius: 1)
        bill.materials = [mat(dark, roughness: 0.6)]
        let billNode = SCNNode(geometry: bill)
        billNode.eulerAngles = SCNVector3(-0.12, 0, 0)
        billNode.position = SCNVector3(0, 0, 22)
        root.addChildNode(billNode)
        // Band at base
        let band = SCNCylinder(radius: 27, height: 4)
        band.materials = [mat(dark, roughness: 0.5)]
        let bandNode = SCNNode(geometry: band)
        bandNode.position = SCNVector3(0, 3, 0)
        root.addChildNode(bandNode)
    }

    private static func buildTopHat(into root: SCNNode) {
        let black = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.08, alpha: 1)
        let band  = NSColor(srgbRed: 0.18, green: 0.08, blue: 0.04, alpha: 1)
        // Brim
        let brim = SCNCylinder(radius: 34, height: 3)
        brim.materials = [mat(black, roughness: 0.5, metalness: 0.1)]
        let brimNode = SCNNode(geometry: brim)
        brimNode.position = SCNVector3(0, 1.5, 0)
        root.addChildNode(brimNode)
        // Body
        let body = SCNCylinder(radius: 21, height: 42)
        body.materials = [mat(black, roughness: 0.45, metalness: 0.08)]
        let bodyNode = SCNNode(geometry: body)
        bodyNode.position = SCNVector3(0, 3 + 21, 0)
        root.addChildNode(bodyNode)
        // Hat band
        let stripe = SCNCylinder(radius: 22, height: 5)
        stripe.materials = [mat(band, roughness: 0.6)]
        let stripeNode = SCNNode(geometry: stripe)
        stripeNode.position = SCNVector3(0, 7, 0)
        root.addChildNode(stripeNode)
    }

    private static func buildCowboyHat(into root: SCNNode) {
        let tan   = NSColor(srgbRed: 0.72, green: 0.58, blue: 0.35, alpha: 1)
        let brown = NSColor(srgbRed: 0.42, green: 0.26, blue: 0.12, alpha: 1)
        // Wide brim
        let brim = SCNCylinder(radius: 40, height: 3)
        brim.materials = [mat(tan, roughness: 0.7)]
        let brimNode = SCNNode(geometry: brim)
        brimNode.position = SCNVector3(0, 1.5, 0)
        root.addChildNode(brimNode)
        // Crown (tapered with cone top)
        let crown = SCNCylinder(radius: 22, height: 24)
        crown.materials = [mat(tan, roughness: 0.65)]
        let crownNode = SCNNode(geometry: crown)
        crownNode.position = SCNVector3(0, 3 + 12, 0)
        root.addChildNode(crownNode)
        let tip = SCNCone(topRadius: 2, bottomRadius: 22, height: 8)
        tip.materials = [mat(tan, roughness: 0.65)]
        let tipNode = SCNNode(geometry: tip)
        tipNode.position = SCNVector3(0, 3 + 24 + 4, 0)
        root.addChildNode(tipNode)
        // Band
        let band = SCNCylinder(radius: 23, height: 4)
        band.materials = [mat(brown, roughness: 0.55)]
        let bandNode = SCNNode(geometry: band)
        bandNode.position = SCNVector3(0, 5, 0)
        root.addChildNode(bandNode)
    }

    private static func buildBeanie(into root: SCNNode) {
        let wool = NSColor(srgbRed: 0.42, green: 0.10, blue: 0.16, alpha: 1)
        let dark = NSColor(srgbRed: 0.28, green: 0.06, blue: 0.10, alpha: 1)
        // Main body — three ribbed cylinders
        for i in 0..<3 {
            let c = i % 2 == 0 ? wool : dark
            let rib = SCNCylinder(radius: 27 - CGFloat(i) * 1.5, height: 9)
            rib.materials = [mat(c, roughness: 0.85)]
            let ribNode = SCNNode(geometry: rib)
            ribNode.position = SCNVector3(0, 4.5 + CGFloat(i) * 9, 0)
            root.addChildNode(ribNode)
        }
        // Pom-pom on top
        let pom = SCNSphere(radius: 9)
        pom.materials = [mat(wool, roughness: 0.9)]
        let pomNode = SCNNode(geometry: pom)
        pomNode.position = SCNVector3(0, 32, 0)
        root.addChildNode(pomNode)
    }

    private static func buildCrown(into root: SCNNode) {
        let gold  = NSColor(srgbRed: 0.83, green: 0.68, blue: 0.21, alpha: 1)
        let jewel = NSColor(srgbRed: 0.85, green: 0.12, blue: 0.18, alpha: 1)
        // Ring base
        let ring = SCNTube(innerRadius: 23, outerRadius: 28, height: 11)
        ring.materials = [mat(gold, roughness: 0.25, metalness: 0.85)]
        let ringNode = SCNNode(geometry: ring)
        ringNode.position = SCNVector3(0, 5.5, 0)
        root.addChildNode(ringNode)
        // 5 points
        for i in 0..<5 {
            let angle = Double(i) / 5 * 2 * .pi
            let spike = SCNCone(topRadius: 1, bottomRadius: 5, height: 16)
            spike.materials = [mat(gold, roughness: 0.25, metalness: 0.85)]
            let spikeNode = SCNNode(geometry: spike)
            spikeNode.position = SCNVector3(
                cos(angle) * 25,
                11 + 8,
                sin(angle) * 25
            )
            root.addChildNode(spikeNode)
            // Jewel on alternating points
            if i % 2 == 0 {
                let gem = SCNSphere(radius: 4)
                gem.materials = [mat(jewel, roughness: 0.08, metalness: 0.2)]
                let gemNode = SCNNode(geometry: gem)
                gemNode.position = SCNVector3(
                    cos(angle) * 25,
                    6,
                    sin(angle) * 25
                )
                root.addChildNode(gemNode)
            }
        }
    }

    // MARK: - Phase B: transport

    private static func buildScooter(into root: SCNNode) {
        let frame = NSColor(srgbRed: 0.20, green: 0.60, blue: 0.95, alpha: 1.0)
        let deck  = NSColor(calibratedWhite: 0.15, alpha: 1.0)
        let grip  = NSColor(calibratedWhite: 0.08, alpha: 1.0)

        // Deck — flat plank under feet.
        let d = SCNBox(width: 38, height: 6, length: 90, chamferRadius: 2)
        d.materials = [mat(deck, roughness: 0.5)]
        let deckNode = SCNNode(geometry: d)
        deckNode.position = SCNVector3(0, -30, 0)
        root.addChildNode(deckNode)

        // Front wheel + fork.
        let wheel = SCNTorus(ringRadius: 14, pipeRadius: 3)
        wheel.materials = [mat(.black, roughness: 0.9)]
        let fw = SCNNode(geometry: wheel)
        fw.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        fw.position = SCNVector3(0, -42, 42)
        root.addChildNode(fw)

        let rw = SCNNode(geometry: wheel.copy() as! SCNGeometry)
        rw.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        rw.position = SCNVector3(0, -42, -42)
        root.addChildNode(rw)

        // Stem — vertical post up to handlebars.
        let stem = SCNCylinder(radius: 2.5, height: 95)
        stem.materials = [matMetal(frame)]
        let stemNode = SCNNode(geometry: stem)
        stemNode.position = SCNVector3(0, 15, 42)
        root.addChildNode(stemNode)

        // Handlebars — horizontal crossbar.
        let bar = SCNCylinder(radius: 2, height: 60)
        bar.materials = [matMetal(frame)]
        let barNode = SCNNode(geometry: bar)
        barNode.eulerAngles = SCNVector3(0, 0, Double.pi / 2)
        barNode.position = SCNVector3(0, 60, 42)
        root.addChildNode(barNode)

        // Grips.
        for dx in [-28.0, 28.0] {
            let g = SCNCylinder(radius: 3, height: 10)
            g.materials = [mat(grip, roughness: 0.85)]
            let gn = SCNNode(geometry: g)
            gn.eulerAngles = SCNVector3(0, 0, Double.pi / 2)
            gn.position = SCNVector3(dx, 60, 42)
            root.addChildNode(gn)
        }
    }

    private static func buildRollerblades(into root: SCNNode) {
        let bootColor = NSColor(srgbRed: 0.95, green: 0.25, blue: 0.45, alpha: 1.0)
        let frameColor = NSColor(calibratedWhite: 0.15, alpha: 1.0)
        let wheelColor = NSColor(srgbRed: 0.9, green: 0.85, blue: 0.2, alpha: 1.0)

        func skate(xOffset: CGFloat) -> SCNNode {
            let s = SCNNode()
            let boot = SCNBox(width: 18, height: 22, length: 44, chamferRadius: 4)
            boot.materials = [mat(bootColor, roughness: 0.4)]
            let bn = SCNNode(geometry: boot)
            bn.position = SCNVector3(0, 0, 0)
            s.addChildNode(bn)

            let frame = SCNBox(width: 8, height: 6, length: 42, chamferRadius: 1)
            frame.materials = [matMetal(frameColor)]
            let fn = SCNNode(geometry: frame)
            fn.position = SCNVector3(0, -14, 0)
            s.addChildNode(fn)

            // 4 inline wheels.
            for i in 0..<4 {
                let w = SCNCylinder(radius: 5, height: 3)
                w.materials = [mat(wheelColor, roughness: 0.45)]
                let wn = SCNNode(geometry: w)
                wn.eulerAngles = SCNVector3(0, 0, Double.pi / 2)
                let z = CGFloat(i) * 11 - 16.5
                wn.position = SCNVector3(0, -21, z)
                s.addChildNode(wn)
            }
            s.position = SCNVector3(xOffset, -38, 0)
            return s
        }
        root.addChildNode(skate(xOffset: -13))
        root.addChildNode(skate(xOffset: 13))
    }

    private static func buildPogoStick(into root: SCNNode) {
        let poleColor = NSColor(calibratedWhite: 0.35, alpha: 1.0)
        let springColor = NSColor(calibratedWhite: 0.55, alpha: 1.0)
        let footColor = NSColor(srgbRed: 0.80, green: 0.15, blue: 0.15, alpha: 1.0)

        // Main pole.
        let pole = SCNCylinder(radius: 2.5, height: 120)
        pole.materials = [matMetal(poleColor)]
        let poleNode = SCNNode(geometry: pole)
        poleNode.position = SCNVector3(0, 0, 0)
        root.addChildNode(poleNode)

        // Spring — 6 small torus loops stacked.
        for i in 0..<6 {
            let ring = SCNTorus(ringRadius: 5, pipeRadius: 0.8)
            ring.materials = [matMetal(springColor)]
            let rn = SCNNode(geometry: ring)
            rn.position = SCNVector3(0, -55 + CGFloat(i) * 3.5, 0)
            root.addChildNode(rn)
        }

        // Footplate — small ledge to stand on.
        let plate = SCNBox(width: 24, height: 4, length: 18, chamferRadius: 1)
        plate.materials = [mat(footColor, roughness: 0.4)]
        let pn = SCNNode(geometry: plate)
        pn.position = SCNVector3(0, -20, 0)
        root.addChildNode(pn)

        // Tip — hemispherical bottom.
        let tip = SCNSphere(radius: 5)
        tip.materials = [mat(.black, roughness: 0.9)]
        let tn = SCNNode(geometry: tip)
        tn.position = SCNVector3(0, -62, 0)
        root.addChildNode(tn)

        // Handlebars.
        let bar = SCNCylinder(radius: 1.8, height: 48)
        bar.materials = [matMetal(poleColor)]
        let barNode = SCNNode(geometry: bar)
        barNode.eulerAngles = SCNVector3(0, 0, Double.pi / 2)
        barNode.position = SCNVector3(0, 58, 0)
        root.addChildNode(barNode)
    }

    private static func buildHoverboard(into root: SCNNode) {
        let deck = NSColor(srgbRed: 0.10, green: 0.12, blue: 0.18, alpha: 1.0)
        let glow = NSColor(srgbRed: 0.20, green: 0.95, blue: 0.85, alpha: 1.0)

        // Deck slab.
        let d = SCNBox(width: 42, height: 8, length: 120, chamferRadius: 6)
        d.materials = [mat(deck, roughness: 0.3, metalness: 0.4)]
        let deckNode = SCNNode(geometry: d)
        deckNode.position = SCNVector3(0, -35, 0)
        root.addChildNode(deckNode)

        // Glowing under-rim.
        let rimGeo = SCNBox(width: 44, height: 2, length: 122, chamferRadius: 1)
        let glowMat = SCNMaterial()
        glowMat.lightingModel = .constant
        glowMat.diffuse.contents = glow
        glowMat.emission.contents = glow
        rimGeo.materials = [glowMat]
        let rim = SCNNode(geometry: rimGeo)
        rim.position = SCNVector3(0, -40, 0)
        root.addChildNode(rim)

        // Two footpads on top.
        for z in [-32.0, 32.0] {
            let pad = SCNBox(width: 34, height: 2, length: 24, chamferRadius: 2)
            pad.materials = [mat(NSColor(calibratedWhite: 0.25, alpha: 1.0), roughness: 0.6)]
            let pn = SCNNode(geometry: pad)
            pn.position = SCNVector3(0, -30, z)
            root.addChildNode(pn)
        }
    }

    private static func buildMotorcycle(into root: SCNNode) {
        let frame = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.14, alpha: 1.0)
        let tank  = NSColor(srgbRed: 0.75, green: 0.12, blue: 0.15, alpha: 1.0)
        let seat  = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        let chrome = NSColor(calibratedWhite: 0.85, alpha: 1.0)

        // Wheels.
        let wheelGeo = SCNTorus(ringRadius: 28, pipeRadius: 6)
        wheelGeo.materials = [mat(.black, roughness: 0.9)]
        let fw = SCNNode(geometry: wheelGeo)
        fw.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        fw.position = SCNVector3(0, -45, 60)
        root.addChildNode(fw)
        let rw = SCNNode(geometry: wheelGeo.copy() as! SCNGeometry)
        rw.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        rw.position = SCNVector3(0, -45, -60)
        root.addChildNode(rw)

        // Frame.
        let fr = SCNBox(width: 14, height: 14, length: 90, chamferRadius: 3)
        fr.materials = [mat(frame, roughness: 0.35, metalness: 0.4)]
        let frNode = SCNNode(geometry: fr)
        frNode.position = SCNVector3(0, -30, 0)
        root.addChildNode(frNode)

        // Fuel tank.
        let t = SCNBox(width: 22, height: 16, length: 38, chamferRadius: 6)
        t.materials = [mat(tank, roughness: 0.2, metalness: 0.3)]
        let tNode = SCNNode(geometry: t)
        tNode.position = SCNVector3(0, -15, 0)
        root.addChildNode(tNode)

        // Seat.
        let st = SCNBox(width: 20, height: 6, length: 34, chamferRadius: 3)
        st.materials = [mat(seat, roughness: 0.6)]
        let stNode = SCNNode(geometry: st)
        stNode.position = SCNVector3(0, -4, -18)
        root.addChildNode(stNode)

        // Handlebars.
        let hb = SCNCylinder(radius: 1.8, height: 44)
        hb.materials = [matMetal(chrome)]
        let hbNode = SCNNode(geometry: hb)
        hbNode.eulerAngles = SCNVector3(0, 0, Double.pi / 2)
        hbNode.position = SCNVector3(0, 8, 50)
        root.addChildNode(hbNode)

        // Headlight.
        let hl = SCNSphere(radius: 5)
        let hlMat = SCNMaterial()
        hlMat.lightingModel = .constant
        hlMat.diffuse.contents = NSColor(srgbRed: 1.0, green: 0.95, blue: 0.70, alpha: 1.0)
        hlMat.emission.contents = NSColor(srgbRed: 1.0, green: 0.95, blue: 0.70, alpha: 1.0)
        hl.materials = [hlMat]
        let hln = SCNNode(geometry: hl)
        hln.position = SCNVector3(0, 2, 70)
        root.addChildNode(hln)
    }

    private static func buildJetpack(into root: SCNNode) {
        let shell = NSColor(calibratedWhite: 0.75, alpha: 1.0)
        let thrust = NSColor(srgbRed: 1.0, green: 0.55, blue: 0.15, alpha: 1.0)
        let stripe = NSColor(srgbRed: 0.85, green: 0.15, blue: 0.15, alpha: 1.0)

        // Two stubby tanks side-by-side.
        for dx in [-14.0, 14.0] {
            let tank = SCNCapsule(capRadius: 10, height: 58)
            tank.materials = [mat(shell, roughness: 0.25, metalness: 0.5)]
            let t = SCNNode(geometry: tank)
            t.position = SCNVector3(dx, 0, 0)
            root.addChildNode(t)

            // Red racing stripe down each.
            let s = SCNBox(width: 2, height: 46, length: 3, chamferRadius: 0.5)
            s.materials = [mat(stripe, roughness: 0.4)]
            let sNode = SCNNode(geometry: s)
            sNode.position = SCNVector3(dx, 0, 10.5)
            root.addChildNode(sNode)

            // Thruster cone at the bottom.
            let cone = SCNCone(topRadius: 8, bottomRadius: 5, height: 14)
            cone.materials = [matMetal(NSColor(calibratedWhite: 0.3, alpha: 1.0))]
            let cn = SCNNode(geometry: cone)
            cn.position = SCNVector3(dx, -36, 0)
            root.addChildNode(cn)

            // Flame glow underneath.
            let flame = SCNCone(topRadius: 6, bottomRadius: 1, height: 18)
            let fm = SCNMaterial()
            fm.lightingModel = .constant
            fm.diffuse.contents = thrust
            fm.emission.contents = thrust
            flame.materials = [fm]
            let fn = SCNNode(geometry: flame)
            fn.eulerAngles = SCNVector3(Double.pi, 0, 0)
            fn.position = SCNVector3(dx, -52, 0)
            root.addChildNode(fn)
        }
    }

    // MARK: - Cape (back-mounted)

    /// Heroic cape: a small collar curving around the back of the
    /// neck plus four tapered drape panels hanging down to mid-leg.
    /// Each panel sways with a gentle independent oscillation so the
    /// silhouette reads as cloth catching air rather than a flat
    /// board. Single-sided lighting kept off so both faces of each
    /// panel render — capes get viewed from behind a lot when Max
    /// turns.
    private static func buildCape(into root: SCNNode, color: NSColor) {
        // Trim is a slightly darker variant of the body colour for the
        // collar piece, so it reads as a separate finished edge rather
        // than a continuous slab.
        let trim = NSColor(deviceWhite: 0, alpha: 1.0).blended(withFraction: 0.22, of: color) ?? color
        let cloth = mat(color, roughness: 0.85, metalness: 0.0)
        cloth.isDoubleSided = true
        let trimMat = mat(trim, roughness: 0.7, metalness: 0.05)
        trimMat.isDoubleSided = true

        // Calibration: the back-mount anchor is parented to
        // `part.suit.torso` (Pet.placeAnchor). The torso is the
        // BroadcasterForm default — 100 wide × 80 tall, centred on
        // the torso node's origin. Anchor-local space therefore
        // works out roughly to: y=0 is upper-chest, y=±40 is torso
        // top/bottom, x=±50 is torso left/right edge, z negative is
        // behind. Cape needs to span the FULL torso width so it
        // doesn't look like a bib hanging off the spine.

        // Collar — wraps the back of the neck. Width matches the
        // upper torso (~80% of full torso width) so it reads as a
        // proper cape attachment point.
        let collar = SCNBox(width: 90, height: 8, length: 6, chamferRadius: 2.5)
        collar.materials = [trimMat]
        let collarNode = SCNNode(geometry: collar)
        collarNode.position = SCNVector3(0, 36, 0)
        collarNode.eulerAngles = SCNVector3(-0.10, 0, 0)
        root.addChildNode(collarNode)

        // Five drape panels spanning the full torso width plus a
        // little extra at the edges for the heroic wind-flap. Total
        // visual width ~120 (vs torso 100), height 120 so the cape
        // hangs to mid-thigh below the torso bottom (y=-40 anchor-local).
        let panelOffsets: [Double] = [-46, -23, 0, 23, 46]
        let panelHeight: CGFloat = 120
        for (idx, x) in panelOffsets.enumerated() {
            // Panel width 26 with 23-unit centre-to-centre spacing
            // gives a 3-unit overlap between adjacent panels — a
            // continuous cloth surface across the back, no spine-line
            // gap.
            let panel = SCNBox(width: 26, height: panelHeight, length: 1.6, chamferRadius: 1.5)
            panel.materials = [cloth]
            let p = SCNNode(geometry: panel)
            // Pivot at the TOP of the panel so it hangs from the
            // collar and tilts rotate around the hanging point. With
            // pivot translated +y by half the height, position(.y) is
            // the y of the panel's top.
            p.pivot = SCNMatrix4MakeTranslation(0, panelHeight / 2, 0)
            // Position the top edge at the collar height, close to
            // the body in z so the cape sits ON the back rather
            // than floating units behind it. Slight nudge back to
            // avoid z-fighting with the torso.
            p.position = SCNVector3(x, 36, -1)
            // Heroic flap — outer panels tilt outward, all panels lean
            // back a little so they catch implied wind from behind.
            // bottom-of-panel x ≈ x * 1.25, converted to a z-axis tilt
            // since the panels hang along -y.
            let outwardTilt = atan((x * 0.25) / Double(panelHeight))
            // Slight backward lean so the cape silhouette is visible
            // from front quarter angles, not just dead behind.
            let backwardLean: CGFloat = 0.18
            p.eulerAngles = SCNVector3(backwardLean, 0, outwardTilt)
            root.addChildNode(p)

            // Independent sway. Each panel oscillates ±3° forward/back
            // around the lean baseline. Staggered phases mean the
            // cape ripples rather than swinging as one rigid board.
            let amplitude: CGFloat = 0.055
            let phase = Double(idx) * 0.55
            let forward = SCNAction.rotateTo(
                x: backwardLean + amplitude,
                y: 0,
                z: CGFloat(outwardTilt),
                duration: 1.8,
                usesShortestUnitArc: true
            )
            forward.timingMode = .easeInEaseOut
            let back = SCNAction.rotateTo(
                x: backwardLean - amplitude,
                y: 0,
                z: CGFloat(outwardTilt),
                duration: 1.8,
                usesShortestUnitArc: true
            )
            back.timingMode = .easeInEaseOut
            let cycle = SCNAction.sequence([forward, back])
            let staggered = SCNAction.sequence([
                SCNAction.wait(duration: phase),
                SCNAction.repeatForever(cycle)
            ])
            p.runAction(staggered)
        }
    }

    // MARK: - Phase B: novelties

    private static func buildSparkler(into root: SCNNode) {
        let stickColor = NSColor(calibratedWhite: 0.4, alpha: 1.0)
        let spark = NSColor(srgbRed: 1.0, green: 0.95, blue: 0.35, alpha: 1.0)

        // Thin stick.
        let stick = SCNCylinder(radius: 0.6, height: 70)
        stick.materials = [matMetal(stickColor)]
        let stickNode = SCNNode(geometry: stick)
        root.addChildNode(stickNode)

        // Glowing tip.
        let tip = SCNSphere(radius: 3.5)
        let tipMat = SCNMaterial()
        tipMat.lightingModel = .constant
        tipMat.diffuse.contents = spark
        tipMat.emission.contents = spark
        tip.materials = [tipMat]
        let tipNode = SCNNode(geometry: tip)
        tipNode.position = SCNVector3(0, 35, 0)
        root.addChildNode(tipNode)

        // Spark flecks radiating out — small spheres emitting.
        for i in 0..<8 {
            let angle = Double(i) / 8 * 2 * .pi
            let r: CGFloat = 9
            let fleck = SCNSphere(radius: 0.9)
            let fm = SCNMaterial()
            fm.lightingModel = .constant
            fm.diffuse.contents = spark
            fm.emission.contents = spark
            fleck.materials = [fm]
            let fn = SCNNode(geometry: fleck)
            fn.position = SCNVector3(cos(angle) * r, 35 + sin(angle) * r, 0)
            root.addChildNode(fn)
        }
    }

    private static func buildPartyHorn(into root: SCNNode) {
        let body = NSColor(srgbRed: 0.95, green: 0.25, blue: 0.35, alpha: 1.0)
        let tip  = NSColor(srgbRed: 0.98, green: 0.85, blue: 0.20, alpha: 1.0)

        // Tapered cone horn — wider at far end.
        let horn = SCNCone(topRadius: 12, bottomRadius: 3, height: 42)
        horn.materials = [mat(body, roughness: 0.3)]
        let hNode = SCNNode(geometry: horn)
        hNode.eulerAngles = SCNVector3(0, 0, Double.pi / 2)
        hNode.position = SCNVector3(22, 0, 0)
        root.addChildNode(hNode)

        // Mouthpiece.
        let m = SCNCylinder(radius: 3, height: 8)
        m.materials = [mat(tip, roughness: 0.4)]
        let mn = SCNNode(geometry: m)
        mn.eulerAngles = SCNVector3(0, 0, Double.pi / 2)
        mn.position = SCNVector3(-3, 0, 0)
        root.addChildNode(mn)

        // A little curly paper streamer coming out of the wide end.
        for i in 0..<5 {
            let curl = SCNTorus(ringRadius: 4 + CGFloat(i), pipeRadius: 0.4)
            curl.materials = [mat(tip, roughness: 0.6)]
            let cn = SCNNode(geometry: curl)
            cn.position = SCNVector3(43 + CGFloat(i) * 4, 0, 0)
            cn.eulerAngles = SCNVector3(0, Double(i) * 0.4, 0)
            root.addChildNode(cn)
        }
    }

    // MARK: - Phase B: persona items

    private static func buildLaptop(into root: SCNNode) {
        let shell = NSColor(calibratedWhite: 0.75, alpha: 1.0)
        let screen = NSColor(srgbRed: 0.08, green: 0.10, blue: 0.16, alpha: 1.0)
        let glow   = NSColor(srgbRed: 0.35, green: 0.78, blue: 1.00, alpha: 1.0)

        // Base (keyboard half).
        let base = SCNBox(width: 48, height: 2.5, length: 34, chamferRadius: 1)
        base.materials = [mat(shell, roughness: 0.3, metalness: 0.6)]
        let baseNode = SCNNode(geometry: base)
        baseNode.position = SCNVector3(0, 0, 0)
        root.addChildNode(baseNode)

        // Keyboard darkening pad.
        let kb = SCNBox(width: 42, height: 0.4, length: 26, chamferRadius: 0.5)
        kb.materials = [mat(NSColor(calibratedWhite: 0.18, alpha: 1.0), roughness: 0.8)]
        let kbNode = SCNNode(geometry: kb)
        kbNode.position = SCNVector3(0, 1.5, 2)
        root.addChildNode(kbNode)

        // Lid, rotated open ~110°.
        let lid = SCNBox(width: 48, height: 32, length: 2.5, chamferRadius: 1)
        lid.materials = [mat(shell, roughness: 0.3, metalness: 0.6)]
        let lidNode = SCNNode(geometry: lid)
        lidNode.position = SCNVector3(0, 15, -16)
        lidNode.eulerAngles = SCNVector3(-0.3, 0, 0)
        root.addChildNode(lidNode)

        // Emissive screen on the lid's front face.
        let scr = SCNPlane(width: 42, height: 26)
        let sm = SCNMaterial()
        sm.lightingModel = .constant
        sm.diffuse.contents = screen
        sm.emission.contents = glow.withAlphaComponent(0.55)
        scr.materials = [sm]
        let scrNode = SCNNode(geometry: scr)
        scrNode.position = SCNVector3(0, 15, -14.5)
        scrNode.eulerAngles = SCNVector3(-0.3, 0, 0)
        root.addChildNode(scrNode)
    }

    private static func buildPaintbrush(into root: SCNNode) {
        let handle = NSColor(srgbRed: 0.55, green: 0.30, blue: 0.15, alpha: 1.0)
        let ferrule = NSColor(calibratedWhite: 0.75, alpha: 1.0)
        let bristle = NSColor(srgbRed: 0.95, green: 0.85, blue: 0.35, alpha: 1.0)

        // Long wood handle.
        let h = SCNCylinder(radius: 1.8, height: 52)
        h.materials = [mat(handle, roughness: 0.6)]
        let hn = SCNNode(geometry: h)
        root.addChildNode(hn)

        // Metal ferrule ring near the tip.
        let f = SCNCylinder(radius: 2.3, height: 7)
        f.materials = [matMetal(ferrule)]
        let fn = SCNNode(geometry: f)
        fn.position = SCNVector3(0, 30, 0)
        root.addChildNode(fn)

        // Bristle tuft — wedge-shaped.
        let b = SCNBox(width: 5, height: 14, length: 3, chamferRadius: 0.5)
        b.materials = [mat(bristle, roughness: 0.85)]
        let bn = SCNNode(geometry: b)
        bn.position = SCNVector3(0, 40, 0)
        root.addChildNode(bn)
    }

    private static func buildMagnifier(into root: SCNNode) {
        let handle = NSColor(srgbRed: 0.45, green: 0.28, blue: 0.16, alpha: 1.0)
        let rim    = NSColor(calibratedWhite: 0.85, alpha: 1.0)

        // Handle.
        let h = SCNCylinder(radius: 2, height: 48)
        h.materials = [mat(handle, roughness: 0.5)]
        let hn = SCNNode(geometry: h)
        hn.position = SCNVector3(0, -18, 0)
        root.addChildNode(hn)

        // Rim — torus.
        let r = SCNTorus(ringRadius: 15, pipeRadius: 1.8)
        r.materials = [matMetal(rim)]
        let rn = SCNNode(geometry: r)
        rn.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        rn.position = SCNVector3(0, 18, 0)
        root.addChildNode(rn)

        // Lens — translucent disc inside rim.
        let lens = SCNCylinder(radius: 14, height: 0.6)
        let lm = SCNMaterial()
        lm.lightingModel = .physicallyBased
        lm.diffuse.contents = NSColor(srgbRed: 0.85, green: 0.92, blue: 1.0, alpha: 0.35)
        lm.transparency = 0.55
        lens.materials = [lm]
        let ln = SCNNode(geometry: lens)
        ln.position = SCNVector3(0, 18, 0)
        root.addChildNode(ln)
    }

    private static func buildWand(into root: SCNNode) {
        let shaft = NSColor(srgbRed: 0.25, green: 0.15, blue: 0.30, alpha: 1.0)
        let tip = NSColor(srgbRed: 0.95, green: 0.85, blue: 0.45, alpha: 1.0)

        // Tapered shaft — thin at one end.
        let s = SCNCone(topRadius: 0.8, bottomRadius: 2.5, height: 55)
        s.materials = [mat(shaft, roughness: 0.5)]
        let sNode = SCNNode(geometry: s)
        root.addChildNode(sNode)

        // Glowing star tip.
        let star = SCNSphere(radius: 4.5)
        let sm = SCNMaterial()
        sm.lightingModel = .constant
        sm.diffuse.contents = tip
        sm.emission.contents = tip
        star.materials = [sm]
        let starNode = SCNNode(geometry: star)
        starNode.position = SCNVector3(0, 28, 0)
        root.addChildNode(starNode)

        // 4 point spikes for the star shape.
        for i in 0..<4 {
            let angle = Double(i) / 4 * 2 * .pi
            let spike = SCNCone(topRadius: 0.5, bottomRadius: 2, height: 8)
            let spm = SCNMaterial()
            spm.lightingModel = .constant
            spm.diffuse.contents = tip
            spm.emission.contents = tip
            spike.materials = [spm]
            let spn = SCNNode(geometry: spike)
            spn.position = SCNVector3(cos(angle) * 6, 28 + sin(angle) * 2, 0)
            spn.eulerAngles = SCNVector3(0, 0, -angle)
            root.addChildNode(spn)
        }
    }

    private static func buildFootball(into root: SCNNode) {
        let leather = NSColor(srgbRed: 0.55, green: 0.30, blue: 0.18, alpha: 1.0)
        let laces = NSColor(calibratedWhite: 0.95, alpha: 1.0)

        // American football — ellipsoid via scaled sphere.
        let ball = SCNSphere(radius: 14)
        ball.materials = [mat(leather, roughness: 0.75)]
        let ballNode = SCNNode(geometry: ball)
        ballNode.scale = SCNVector3(0.72, 0.72, 1.25)
        root.addChildNode(ballNode)

        // Laces — 4 little stripes down the centerline.
        for i in 0..<4 {
            let l = SCNBox(width: 4, height: 0.8, length: 1.5, chamferRadius: 0.3)
            l.materials = [mat(laces, roughness: 0.6)]
            let ln = SCNNode(geometry: l)
            ln.position = SCNVector3(0, 9.5, -3 + CGFloat(i) * 2)
            root.addChildNode(ln)
        }
    }

    private static func buildBaseballBat(into root: SCNNode) {
        let wood = NSColor(srgbRed: 0.72, green: 0.52, blue: 0.30, alpha: 1.0)
        let grip = NSColor(calibratedWhite: 0.12, alpha: 1.0)

        // Taper — cone gives a nice bat silhouette.
        let bat = SCNCone(topRadius: 3, bottomRadius: 7, height: 90)
        bat.materials = [mat(wood, roughness: 0.6)]
        let batNode = SCNNode(geometry: bat)
        root.addChildNode(batNode)

        // Grip tape at the handle end.
        let g = SCNCylinder(radius: 3.3, height: 28)
        g.materials = [mat(grip, roughness: 0.9)]
        let gn = SCNNode(geometry: g)
        gn.position = SCNVector3(0, -31, 0)
        root.addChildNode(gn)

        // Pommel knob.
        let knob = SCNSphere(radius: 4)
        knob.materials = [mat(wood, roughness: 0.5)]
        let kn = SCNNode(geometry: knob)
        kn.position = SCNVector3(0, -47, 0)
        root.addChildNode(kn)
    }

    private static func buildWrench(into root: SCNNode) {
        let steel = NSColor(calibratedWhite: 0.68, alpha: 1.0)
        let darker = NSColor(calibratedWhite: 0.45, alpha: 1.0)

        // Long handle.
        let h = SCNBox(width: 5, height: 56, length: 3, chamferRadius: 1)
        h.materials = [matMetal(steel)]
        let hn = SCNNode(geometry: h)
        root.addChildNode(hn)

        // Head — chunky block at one end.
        let head = SCNBox(width: 14, height: 12, length: 5, chamferRadius: 1.5)
        head.materials = [matMetal(steel)]
        let headNode = SCNNode(geometry: head)
        headNode.position = SCNVector3(0, 31, 0)
        root.addChildNode(headNode)

        // Jaw slot — dark cutout suggesting a socket.
        let slot = SCNBox(width: 6, height: 4, length: 5.6, chamferRadius: 0.5)
        slot.materials = [mat(darker, roughness: 0.5, metalness: 0.5)]
        let sn = SCNNode(geometry: slot)
        sn.position = SCNVector3(0, 34, 0)
        root.addChildNode(sn)
    }

    // MARK: - Phase B: food

    private static func buildPizzaSlice(into root: SCNNode) {
        let crust = NSColor(srgbRed: 0.85, green: 0.65, blue: 0.30, alpha: 1.0)
        let cheese = NSColor(srgbRed: 0.98, green: 0.82, blue: 0.28, alpha: 1.0)
        let pepperoni = NSColor(srgbRed: 0.75, green: 0.18, blue: 0.15, alpha: 1.0)

        // Triangle approximated by a thin wedge.
        let wedge = SCNCone(topRadius: 0.5, bottomRadius: 22, height: 4)
        wedge.materials = [mat(cheese, roughness: 0.75)]
        let wn = SCNNode(geometry: wedge)
        wn.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)  // lay flat
        // Cut in half by scale to fake a slice.
        wn.scale = SCNVector3(1.0, 1.0, 0.5)
        root.addChildNode(wn)

        // Crust — thicker rim at the wide end.
        let rim = SCNTorus(ringRadius: 19, pipeRadius: 3)
        rim.materials = [mat(crust, roughness: 0.8)]
        let rimNode = SCNNode(geometry: rim)
        rimNode.scale = SCNVector3(1.0, 1.0, 0.25)  // arc segment
        rimNode.position = SCNVector3(0, 0, -8)
        root.addChildNode(rimNode)

        // 3 pepperonis.
        for (x, z) in [(-6.0, -3.0), (7.0, -5.0), (0.0, 4.0)] {
            let p = SCNCylinder(radius: 3, height: 0.5)
            p.materials = [mat(pepperoni, roughness: 0.6)]
            let pn = SCNNode(geometry: p)
            pn.position = SCNVector3(x, 2.2, z)
            root.addChildNode(pn)
        }
    }

    private static func buildIceCreamCone(into root: SCNNode) {
        let waffle = NSColor(srgbRed: 0.80, green: 0.55, blue: 0.25, alpha: 1.0)
        let scoop = NSColor(srgbRed: 0.98, green: 0.75, blue: 0.85, alpha: 1.0)
        let cherry = NSColor(srgbRed: 0.85, green: 0.15, blue: 0.18, alpha: 1.0)

        // Cone, pointed down.
        let cone = SCNCone(topRadius: 9, bottomRadius: 0.5, height: 28)
        cone.materials = [mat(waffle, roughness: 0.7)]
        let cn = SCNNode(geometry: cone)
        cn.eulerAngles = SCNVector3(Double.pi, 0, 0)
        cn.position = SCNVector3(0, -8, 0)
        root.addChildNode(cn)

        // Ice cream scoop.
        let scp = SCNSphere(radius: 11)
        scp.materials = [mat(scoop, roughness: 0.3)]
        let sn = SCNNode(geometry: scp)
        sn.position = SCNVector3(0, 10, 0)
        root.addChildNode(sn)

        // Cherry on top.
        let ch = SCNSphere(radius: 2.5)
        ch.materials = [mat(cherry, roughness: 0.25)]
        let chn = SCNNode(geometry: ch)
        chn.position = SCNVector3(0, 22, 0)
        root.addChildNode(chn)
    }

    private static func buildDonut(into root: SCNNode) {
        let dough = NSColor(srgbRed: 0.85, green: 0.65, blue: 0.42, alpha: 1.0)
        let icing = NSColor(srgbRed: 0.95, green: 0.45, blue: 0.70, alpha: 1.0)
        let sprinkleA = NSColor(srgbRed: 0.35, green: 0.75, blue: 0.95, alpha: 1.0)
        let sprinkleB = NSColor(srgbRed: 0.95, green: 0.85, blue: 0.25, alpha: 1.0)

        // Ring.
        let ring = SCNTorus(ringRadius: 11, pipeRadius: 5)
        ring.materials = [mat(dough, roughness: 0.7)]
        let rn = SCNNode(geometry: ring)
        rn.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        root.addChildNode(rn)

        // Icing — half-torus on top, slightly thicker.
        let ic = SCNTorus(ringRadius: 11, pipeRadius: 5.4)
        ic.materials = [mat(icing, roughness: 0.45)]
        let icn = SCNNode(geometry: ic)
        icn.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        icn.position = SCNVector3(0, 2, 0)
        // Only render top half-ish via a subtle lift.
        root.addChildNode(icn)

        // Sprinkles.
        for i in 0..<8 {
            let angle = Double(i) / 8 * 2 * .pi
            let sp = SCNBox(width: 0.7, height: 0.7, length: 3, chamferRadius: 0)
            sp.materials = [mat(i % 2 == 0 ? sprinkleA : sprinkleB, roughness: 0.4)]
            let spn = SCNNode(geometry: sp)
            spn.position = SCNVector3(cos(angle) * 11, 6, sin(angle) * 11)
            spn.eulerAngles = SCNVector3(0, angle, 0)
            root.addChildNode(spn)
        }
    }

    private static func buildCupcake(into root: SCNNode) {
        let wrapper = NSColor(srgbRed: 0.35, green: 0.22, blue: 0.55, alpha: 1.0)
        let frosting = NSColor(srgbRed: 0.98, green: 0.75, blue: 0.85, alpha: 1.0)
        let cherry = NSColor(srgbRed: 0.85, green: 0.15, blue: 0.18, alpha: 1.0)

        // Wrapper — inverted cone.
        let wr = SCNCone(topRadius: 10, bottomRadius: 7, height: 14)
        wr.materials = [mat(wrapper, roughness: 0.65)]
        let wn = SCNNode(geometry: wr)
        wn.position = SCNVector3(0, -6, 0)
        root.addChildNode(wn)

        // Frosting swirl — 3 stacked ovoids ascending.
        for i in 0..<3 {
            let sw = SCNSphere(radius: 8.5 - CGFloat(i) * 2)
            sw.materials = [mat(frosting, roughness: 0.35)]
            let sn = SCNNode(geometry: sw)
            sn.scale = SCNVector3(1.1, 0.85, 1.1)
            sn.position = SCNVector3(0, CGFloat(i) * 5 + 4, 0)
            root.addChildNode(sn)
        }

        // Cherry.
        let ch = SCNSphere(radius: 2.2)
        ch.materials = [mat(cherry, roughness: 0.25)]
        let chn = SCNNode(geometry: ch)
        chn.position = SCNVector3(0, 21, 0)
        root.addChildNode(chn)
    }

    // MARK: - Phase B: more hats

    private static func buildPartyHat(into root: SCNNode) {
        let body = NSColor(srgbRed: 0.25, green: 0.70, blue: 0.95, alpha: 1.0)
        let dots = NSColor(srgbRed: 1.0, green: 0.95, blue: 0.25, alpha: 1.0)
        let pom  = NSColor(srgbRed: 0.95, green: 0.50, blue: 0.70, alpha: 1.0)

        // Cone.
        let cone = SCNCone(topRadius: 1, bottomRadius: 16, height: 38)
        cone.materials = [mat(body, roughness: 0.3)]
        let cn = SCNNode(geometry: cone)
        cn.position = SCNVector3(0, 15, 0)
        root.addChildNode(cn)

        // Pom-pom on top.
        let p = SCNSphere(radius: 4.5)
        p.materials = [mat(pom, roughness: 0.7)]
        let pn = SCNNode(geometry: p)
        pn.position = SCNVector3(0, 38, 0)
        root.addChildNode(pn)

        // Polka dots — 4 small spheres stuck on the cone.
        for i in 0..<4 {
            let angle = Double(i) / 4 * 2 * .pi
            let d = SCNSphere(radius: 2)
            d.materials = [mat(dots, roughness: 0.4)]
            let dn = SCNNode(geometry: d)
            dn.position = SCNVector3(cos(angle) * 10, 18, sin(angle) * 10)
            root.addChildNode(dn)
        }
    }

    private static func buildWizardHat(into root: SCNNode) {
        let hat = NSColor(srgbRed: 0.15, green: 0.10, blue: 0.35, alpha: 1.0)
        let trim = NSColor(srgbRed: 0.95, green: 0.85, blue: 0.35, alpha: 1.0)

        // Wide brim.
        let brim = SCNCylinder(radius: 26, height: 2)
        brim.materials = [mat(hat, roughness: 0.5)]
        let bn = SCNNode(geometry: brim)
        bn.position = SCNVector3(0, 1, 0)
        root.addChildNode(bn)

        // Tall cone, slightly bent forward.
        let cone = SCNCone(topRadius: 0.5, bottomRadius: 14, height: 52)
        cone.materials = [mat(hat, roughness: 0.45)]
        let cn = SCNNode(geometry: cone)
        cn.position = SCNVector3(0, 27, 0)
        cn.eulerAngles = SCNVector3(-0.15, 0, 0)
        root.addChildNode(cn)

        // Gold band around base.
        let band = SCNTorus(ringRadius: 13.5, pipeRadius: 1.5)
        band.materials = [matMetal(trim)]
        let bandNode = SCNNode(geometry: band)
        bandNode.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        bandNode.position = SCNVector3(0, 5, 0)
        root.addChildNode(bandNode)

        // Stars sprinkled on the cone.
        for (y, z) in [(18.0, 8.0), (32.0, 4.0), (40.0, 0.0)] {
            let star = SCNSphere(radius: 1.8)
            let sm = SCNMaterial()
            sm.lightingModel = .constant
            sm.diffuse.contents = trim
            sm.emission.contents = trim
            star.materials = [sm]
            let sn = SCNNode(geometry: star)
            sn.position = SCNVector3(0, y, z)
            root.addChildNode(sn)
        }
    }

    private static func buildHardHat(into root: SCNNode) {
        let shell = NSColor(srgbRed: 0.95, green: 0.70, blue: 0.15, alpha: 1.0)
        let band = NSColor(calibratedWhite: 0.15, alpha: 1.0)

        // Hemispherical shell.
        let dome = SCNSphere(radius: 20)
        dome.materials = [mat(shell, roughness: 0.35, metalness: 0.05)]
        let dn = SCNNode(geometry: dome)
        dn.scale = SCNVector3(1.1, 0.75, 1.1)
        dn.position = SCNVector3(0, 8, 0)
        root.addChildNode(dn)

        // Brim — small visor ledge.
        let brim = SCNBox(width: 30, height: 2, length: 12, chamferRadius: 3)
        brim.materials = [mat(shell, roughness: 0.5)]
        let bn = SCNNode(geometry: brim)
        bn.position = SCNVector3(0, 2, 14)
        root.addChildNode(bn)

        // Center ridge — signature construction-helmet rib along the crown.
        let rib = SCNBox(width: 4, height: 3, length: 36, chamferRadius: 1)
        rib.materials = [mat(shell, roughness: 0.5)]
        let rn = SCNNode(geometry: rib)
        rn.position = SCNVector3(0, 18, 0)
        root.addChildNode(rn)

        // Dark band around the base.
        let bandGeo = SCNTorus(ringRadius: 19, pipeRadius: 1.2)
        bandGeo.materials = [mat(band, roughness: 0.85)]
        let bandNode = SCNNode(geometry: bandGeo)
        bandNode.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        bandNode.position = SCNVector3(0, 2, 0)
        root.addChildNode(bandNode)
    }

    // MARK: - Phase C: jewelry

    private static func buildNecklace(into root: SCNNode) {
        let chain = NSColor(srgbRed: 0.92, green: 0.78, blue: 0.28, alpha: 1.0)
        let pendant = NSColor(srgbRed: 0.30, green: 0.85, blue: 1.00, alpha: 1.0)

        // Chain as a flattened torus — sits on the collarbone ring.
        let ring = SCNTorus(ringRadius: 20, pipeRadius: 0.8)
        ring.materials = [matMetal(chain)]
        let rn = SCNNode(geometry: ring)
        rn.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        rn.scale = SCNVector3(1.0, 1.0, 0.75)  // slight ellipse to wrap the neck
        root.addChildNode(rn)

        // Pendant hanging at the front.
        let p = SCNSphere(radius: 3.5)
        p.materials = [mat(pendant, roughness: 0.1, metalness: 0.2)]
        let pn = SCNNode(geometry: p)
        pn.position = SCNVector3(0, -8, 15)
        root.addChildNode(pn)
    }

    private static func buildEarrings(into root: SCNNode) {
        let gold = NSColor(srgbRed: 0.92, green: 0.78, blue: 0.28, alpha: 1.0)
        // A pair — one studs placed at each side of the head. Head is
        // ~40px wide so offset ±20.
        for dx in [-20.0, 20.0] {
            let stud = SCNSphere(radius: 2.2)
            stud.materials = [matMetal(gold)]
            let sn = SCNNode(geometry: stud)
            sn.position = SCNVector3(dx, -6, 0)
            root.addChildNode(sn)

            // Small dangling drop below each stud.
            let drop = SCNCylinder(radius: 0.6, height: 6)
            drop.materials = [matMetal(gold)]
            let dn = SCNNode(geometry: drop)
            dn.position = SCNVector3(dx, -12, 0)
            root.addChildNode(dn)
        }
    }

    private static func buildBracelet(into root: SCNNode) {
        let band = NSColor(srgbRed: 0.20, green: 0.70, blue: 0.95, alpha: 1.0)
        // Single band on the right wrist (anchor lives on right hand).
        let ring = SCNTorus(ringRadius: 8, pipeRadius: 1.3)
        ring.materials = [matMetal(band)]
        let rn = SCNNode(geometry: ring)
        rn.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        root.addChildNode(rn)

        // A couple of bead accents.
        for i in 0..<3 {
            let angle = Double(i) * 2 * .pi / 3
            let bead = SCNSphere(radius: 1.5)
            bead.materials = [mat(NSColor(srgbRed: 0.98, green: 0.85, blue: 0.25, alpha: 1.0), roughness: 0.2)]
            let bn = SCNNode(geometry: bead)
            bn.position = SCNVector3(cos(angle) * 8, 0, sin(angle) * 8)
            root.addChildNode(bn)
        }
    }

    private static func buildWatch(into root: SCNNode) {
        let strap = NSColor(calibratedWhite: 0.12, alpha: 1.0)
        let faceColor = NSColor(calibratedWhite: 0.9, alpha: 1.0)
        let bezel = NSColor(calibratedWhite: 0.70, alpha: 1.0)
        let hand = NSColor(srgbRed: 0.92, green: 0.20, blue: 0.20, alpha: 1.0)

        // Strap as a thin torus.
        let strapRing = SCNTorus(ringRadius: 8, pipeRadius: 1.2)
        strapRing.materials = [mat(strap, roughness: 0.7)]
        let sn = SCNNode(geometry: strapRing)
        sn.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        root.addChildNode(sn)

        // Watch case.
        let caseBox = SCNBox(width: 10, height: 10, length: 3, chamferRadius: 1)
        caseBox.materials = [matMetal(bezel)]
        let cn = SCNNode(geometry: caseBox)
        cn.position = SCNVector3(0, 0, 8)
        root.addChildNode(cn)

        // Watch face.
        let face = SCNPlane(width: 7, height: 7)
        face.materials = [mat(faceColor, roughness: 0.1)]
        let fn = SCNNode(geometry: face)
        fn.position = SCNVector3(0, 0, 9.6)
        root.addChildNode(fn)

        // Single red second hand.
        let handBox = SCNBox(width: 0.5, height: 3, length: 0.3, chamferRadius: 0)
        handBox.materials = [mat(hand, roughness: 0.3)]
        let hn = SCNNode(geometry: handBox)
        hn.position = SCNVector3(0, 0.5, 10.1)
        root.addChildNode(hn)
    }

    private static func buildRing(into root: SCNNode) {
        let gold = NSColor(srgbRed: 0.92, green: 0.78, blue: 0.28, alpha: 1.0)
        let gem = NSColor(srgbRed: 0.95, green: 0.15, blue: 0.35, alpha: 1.0)

        // Band.
        let band = SCNTorus(ringRadius: 2.5, pipeRadius: 0.6)
        band.materials = [matMetal(gold)]
        let bn = SCNNode(geometry: band)
        root.addChildNode(bn)

        // Gem on top.
        let g = SCNSphere(radius: 1.4)
        g.materials = [mat(gem, roughness: 0.08, metalness: 0.25)]
        let gn = SCNNode(geometry: g)
        gn.position = SCNVector3(0, 2, 0)
        root.addChildNode(gn)
    }

    // MARK: - Phase E.1: persona hats

    private static func buildChefHat(into root: SCNNode) {
        let white = NSColor(calibratedWhite: 0.98, alpha: 1.0)

        // Short cylindrical base — sized to frame the head (~40 wide).
        let band = SCNCylinder(radius: 24, height: 14)
        band.materials = [mat(white, roughness: 0.65)]
        let bandNode = SCNNode(geometry: band)
        bandNode.position = SCNVector3(0, 7, 0)
        root.addChildNode(bandNode)

        // Puffy top — stack 5 spheres offset for a billowy look.
        let puffOffsets: [(x: CGFloat, z: CGFloat, r: CGFloat)] = [
            (0,   0,   20),
            (-12, -4,  15),
            (12,  -3,  15),
            (-4,  11,  14),
            (7,   9,   14)
        ]
        for (i, o) in puffOffsets.enumerated() {
            let puff = SCNSphere(radius: o.r)
            puff.materials = [mat(white, roughness: 0.55)]
            let pn = SCNNode(geometry: puff)
            pn.position = SCNVector3(o.x, 32, o.z)
            pn.name = "prop.chef_hat.puff.\(i)"
            root.addChildNode(pn)
        }
    }

    private static func buildMilitaryHelmet(into root: SCNNode) {
        let olive = NSColor(srgbRed: 0.35, green: 0.38, blue: 0.20, alpha: 1.0)
        let strap = NSColor(calibratedWhite: 0.10, alpha: 1.0)

        // Dome — flattened sphere hugging the crown.
        let dome = SCNSphere(radius: 28)
        dome.materials = [mat(olive, roughness: 0.55, metalness: 0.15)]
        let dn = SCNNode(geometry: dome)
        dn.scale = SCNVector3(1.05, 0.72, 1.18)
        dn.position = SCNVector3(0, 8, 0)
        root.addChildNode(dn)

        // Thin brim rim at the base.
        let rim = SCNTorus(ringRadius: 26, pipeRadius: 2)
        rim.materials = [mat(olive, roughness: 0.7)]
        let rn = SCNNode(geometry: rim)
        rn.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        rn.position = SCNVector3(0, 0, 0)
        root.addChildNode(rn)

        // Chinstrap — thin dark band dropping from both sides.
        let straps: [CGFloat] = [-22, 22]
        for x in straps {
            let s = SCNBox(width: 2.5, height: 16, length: 2, chamferRadius: 0.4)
            s.materials = [mat(strap, roughness: 0.8)]
            let sNode = SCNNode(geometry: s)
            sNode.position = SCNVector3(x, -7, 0)
            root.addChildNode(sNode)
        }
    }

    private static func buildMotorcycleHelmet(into root: SCNNode) {
        let shell = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
        let visor = NSColor(srgbRed: 0.15, green: 0.20, blue: 0.25, alpha: 0.85)
        let accent = NSColor(srgbRed: 0.90, green: 0.12, blue: 0.15, alpha: 1.0)

        // Main shell — bigger-than-head sphere flattened to look snug.
        let dome = SCNSphere(radius: 30)
        dome.materials = [mat(shell, roughness: 0.22, metalness: 0.35)]
        let dn = SCNNode(geometry: dome)
        dn.scale = SCNVector3(1.15, 0.95, 1.20)
        dn.position = SCNVector3(0, 6, 0)
        root.addChildNode(dn)

        // Visor — transparent-ish plane across the face.
        let vis = SCNBox(width: 42, height: 18, length: 2, chamferRadius: 3)
        let vm = SCNMaterial()
        vm.lightingModel = .physicallyBased
        vm.diffuse.contents = visor
        vm.transparency = 0.55
        vm.roughness.contents = 0.1
        vis.materials = [vm]
        let vn = SCNNode(geometry: vis)
        vn.position = SCNVector3(0, 2, 28)
        root.addChildNode(vn)

        // Accent stripe down the middle of the shell.
        let stripe = SCNBox(width: 5, height: 34, length: 2, chamferRadius: 1)
        stripe.materials = [mat(accent, roughness: 0.35)]
        let sn = SCNNode(geometry: stripe)
        sn.position = SCNVector3(0, 14, 30)
        root.addChildNode(sn)
    }

    private static func buildPirateHat(into root: SCNNode) {
        let felt = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
        let trim = NSColor(srgbRed: 0.90, green: 0.78, blue: 0.35, alpha: 1.0)
        let bone = NSColor(calibratedWhite: 0.95, alpha: 1.0)

        // Tricorne base — three upturned points around a flat crown.
        let disk = SCNCylinder(radius: 34, height: 3)
        disk.materials = [mat(felt, roughness: 0.72)]
        let dn = SCNNode(geometry: disk)
        dn.position = SCNVector3(0, 4, 0)
        root.addChildNode(dn)

        // Crown — short cylinder atop the disk.
        let crown = SCNCylinder(radius: 20, height: 14)
        crown.materials = [mat(felt, roughness: 0.72)]
        let cn = SCNNode(geometry: crown)
        cn.position = SCNVector3(0, 12, 0)
        root.addChildNode(cn)

        // Three upturned wedges (front, back-left, back-right).
        let wedgeOffsets: [(x: CGFloat, z: CGFloat, yaw: Double)] = [
            (0,   28,  0),
            (-22, -16, 0.9),
            (22,  -16, -0.9)
        ]
        for (x, z, yaw) in wedgeOffsets {
            let wedge = SCNBox(width: 22, height: 14, length: 5, chamferRadius: 2)
            wedge.materials = [mat(felt, roughness: 0.72)]
            let wn = SCNNode(geometry: wedge)
            wn.position = SCNVector3(x, 15, z)
            wn.eulerAngles = SCNVector3(0, yaw, 0)
            root.addChildNode(wn)
        }

        // Gold trim rim around the base of the crown.
        let rim = SCNTorus(ringRadius: 20.2, pipeRadius: 1)
        rim.materials = [matMetal(trim)]
        let rn = SCNNode(geometry: rim)
        rn.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        rn.position = SCNVector3(0, 5.5, 0)
        root.addChildNode(rn)

        // Skull & crossbones on the front.
        let skull = SCNSphere(radius: 4)
        skull.materials = [mat(bone, roughness: 0.4)]
        let skn = SCNNode(geometry: skull)
        skn.position = SCNVector3(0, 15, 20.3)
        root.addChildNode(skn)

        for angle: Double in [0.6, -0.6] {
            let bn = SCNBox(width: 8, height: 1.6, length: 1.6, chamferRadius: 0.3)
            bn.materials = [mat(bone, roughness: 0.5)]
            let bnn = SCNNode(geometry: bn)
            bnn.eulerAngles = SCNVector3(0, 0, angle)
            bnn.position = SCNVector3(0, 12, 20.8)
            root.addChildNode(bnn)
        }
    }

    private static func buildAstronautHelmet(into root: SCNNode) {
        let shell = NSColor(calibratedWhite: 0.97, alpha: 1.0)
        let visor = NSColor(srgbRed: 0.25, green: 0.40, blue: 0.55, alpha: 1.0)
        let ring = NSColor(calibratedWhite: 0.75, alpha: 1.0)

        // Big sphere — full bubble around the head.
        let bubble = SCNSphere(radius: 28)
        let bm = SCNMaterial()
        bm.lightingModel = .physicallyBased
        bm.diffuse.contents = shell
        bm.transparency = 0.85
        bm.roughness.contents = 0.20
        bubble.materials = [bm]
        let bubbleNode = SCNNode(geometry: bubble)
        bubbleNode.scale = SCNVector3(1.0, 0.95, 1.0)
        bubbleNode.position = SCNVector3(0, 8, 0)
        root.addChildNode(bubbleNode)

        // Gold-tinted visor — front quarter of the bubble.
        let vis = SCNSphere(radius: 26)
        let vm = SCNMaterial()
        vm.lightingModel = .physicallyBased
        vm.diffuse.contents = visor
        vm.transparency = 0.35
        vm.roughness.contents = 0.10
        vm.metalness.contents = 0.6
        vis.materials = [vm]
        let vn = SCNNode(geometry: vis)
        vn.scale = SCNVector3(0.85, 0.55, 0.55)
        vn.position = SCNVector3(0, 10, 15)
        root.addChildNode(vn)

        // Collar ring — where the helmet would seal to a suit.
        let collar = SCNTorus(ringRadius: 20, pipeRadius: 2.5)
        collar.materials = [matMetal(ring)]
        let cn = SCNNode(geometry: collar)
        cn.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        cn.position = SCNVector3(0, -12, 0)
        root.addChildNode(cn)
    }

    private static func buildNinjaHeadband(into root: SCNNode) {
        let cloth = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1.0)
        let accent = NSColor(srgbRed: 0.88, green: 0.12, blue: 0.15, alpha: 1.0)

        // Low band wrapping the forehead — scaled to match head width (~40).
        let band = SCNTorus(ringRadius: 26, pipeRadius: 5)
        band.materials = [mat(cloth, roughness: 0.85)]
        let bn = SCNNode(geometry: band)
        bn.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        bn.position = SCNVector3(0, 0, 0)
        root.addChildNode(bn)

        // Red circle insignia on the front.
        let dot = SCNCylinder(radius: 5, height: 1.2)
        dot.materials = [mat(accent, roughness: 0.4)]
        let dn = SCNNode(geometry: dot)
        dn.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        dn.position = SCNVector3(0, 1, 27)
        root.addChildNode(dn)

        // Two trailing fabric ends flapping off the back.
        for dx in [-7.0, 7.0] {
            let tail = SCNBox(width: 5, height: 28, length: 2, chamferRadius: 1)
            tail.materials = [mat(cloth, roughness: 0.9)]
            let tn = SCNNode(geometry: tail)
            tn.position = SCNVector3(dx, -15, -22)
            tn.eulerAngles = SCNVector3(0.35, 0, 0)
            root.addChildNode(tn)
        }
    }

    // MARK: - Phase E.2: face + chains

    private static func buildEyePatch(into root: SCNNode) {
        let leather = NSColor(calibratedWhite: 0.06, alpha: 1.0)
        let strap = NSColor(calibratedWhite: 0.10, alpha: 1.0)

        // Oval patch — flattened sphere in front of the eye.
        let patch = SCNSphere(radius: 9)
        patch.materials = [mat(leather, roughness: 0.7)]
        let pn = SCNNode(geometry: patch)
        pn.scale = SCNVector3(1.2, 1.0, 0.22)
        root.addChildNode(pn)

        // Elastic strap — a thin ring wrapping back around the head.
        let strapRing = SCNTorus(ringRadius: 20, pipeRadius: 1.0)
        strapRing.materials = [mat(strap, roughness: 0.85)]
        let sn = SCNNode(geometry: strapRing)
        // Rotate around vertical so the ring wraps front-to-back on the head.
        sn.eulerAngles = SCNVector3(0, Double.pi / 2, 0)
        sn.position = SCNVector3(-11, 0, -20)
        root.addChildNode(sn)
    }

    private static func buildGoldChain(into root: SCNNode) {
        let gold = NSColor(srgbRed: 0.92, green: 0.78, blue: 0.28, alpha: 1.0)
        // Chunkier than the necklace — 16 small link-like toruses in a ring.
        let linkCount = 16
        for i in 0..<linkCount {
            let t = Double(i) / Double(linkCount) * 2 * .pi
            let link = SCNTorus(ringRadius: 2.2, pipeRadius: 0.9)
            link.materials = [matMetal(gold)]
            let node = SCNNode(geometry: link)
            let r: CGFloat = 22
            node.position = SCNVector3(cos(t) * r, 0, sin(t) * r * 0.8)  // slight ellipse
            // Alternate link orientation so they read as interlocked.
            node.eulerAngles = SCNVector3(
                i % 2 == 0 ? 0 : Double.pi / 2,
                t,
                0
            )
            root.addChildNode(node)
        }

        // Big pendant dangling at the front.
        let pendant = SCNBox(width: 12, height: 14, length: 2, chamferRadius: 2)
        pendant.materials = [matMetal(gold)]
        let pen = SCNNode(geometry: pendant)
        pen.position = SCNVector3(0, -12, 20)
        root.addChildNode(pen)
    }

    private static func buildSilverChain(into root: SCNNode) {
        let silver = NSColor(calibratedWhite: 0.85, alpha: 1.0)
        // Simpler Cuban-link style — each link is a thin flattened torus.
        let linkCount = 20
        for i in 0..<linkCount {
            let t = Double(i) / Double(linkCount) * 2 * .pi
            let link = SCNTorus(ringRadius: 1.8, pipeRadius: 0.6)
            link.materials = [matMetal(silver)]
            let node = SCNNode(geometry: link)
            let r: CGFloat = 20
            node.position = SCNVector3(cos(t) * r, 0, sin(t) * r * 0.8)
            node.eulerAngles = SCNVector3(
                i % 2 == 0 ? 0 : Double.pi / 2,
                t,
                0
            )
            root.addChildNode(node)
        }
    }

    // MARK: - Sleep / loungewear kit

    /// Wee-Willie-Winkie nightcap — soft cone sloping forward with a
    /// pompom on the tip. Pairs naturally with the `pajamas` and
    /// `bathrobe` outfit presets.
    private static func buildNightcap(into root: SCNNode) {
        let cap = NSColor(srgbRed: 0.86, green: 0.62, blue: 0.78, alpha: 1.0)
        let trim = NSColor(srgbRed: 0.98, green: 0.95, blue: 0.92, alpha: 1.0)

        // Cuff at the head — short cylinder.
        let cuff = SCNCylinder(radius: 14, height: 4)
        cuff.materials = [mat(trim, roughness: 0.7)]
        let cuffNode = SCNNode(geometry: cuff)
        cuffNode.position = SCNVector3(0, 2, 0)
        root.addChildNode(cuffNode)

        // Drooping cone — pointed forward and slightly to one side so
        // it reads as floppy-soft rather than wizard-rigid.
        let cone = SCNCone(topRadius: 1.0, bottomRadius: 13, height: 38)
        cone.materials = [mat(cap, roughness: 0.65)]
        let coneNode = SCNNode(geometry: cone)
        coneNode.position = SCNVector3(0, 20, 4)
        coneNode.eulerAngles = SCNVector3(-0.55, 0, 0.18)
        root.addChildNode(coneNode)

        // Pompom on the tip.
        let pom = SCNSphere(radius: 4)
        pom.materials = [mat(trim, roughness: 0.8)]
        let pomNode = SCNNode(geometry: pom)
        // Position at the tip — same eulerAngles math as the cone but
        // translated to height/2 along the cone's local +Y, then back
        // through the cone's tilt. Approximate by placing in world.
        pomNode.position = SCNVector3(0, 36, 22)
        root.addChildNode(pomNode)
    }

    /// Soft band across the eyes — for sleeping. Anchor is `.onEye`,
    /// same as `eye_patch`, so it sits flush across the face.
    private static func buildSleepMask(into root: SCNNode) {
        let band = NSColor(srgbRed: 0.20, green: 0.18, blue: 0.32, alpha: 1.0)
        // A slim, slightly curved box wrapping across the eye area.
        let strap = SCNBox(width: 38, height: 11, length: 3, chamferRadius: 4)
        strap.materials = [mat(band, roughness: 0.6)]
        let strapNode = SCNNode(geometry: strap)
        root.addChildNode(strapNode)

        // Tiny tassel detail in the centre — a thread + ball — so it
        // reads as a sleep mask rather than a generic blindfold.
        let cord = SCNCylinder(radius: 0.4, height: 6)
        cord.materials = [mat(NSColor(white: 0.95, alpha: 1.0))]
        let cordNode = SCNNode(geometry: cord)
        cordNode.position = SCNVector3(0, -7, 1)
        root.addChildNode(cordNode)
    }

    /// Pair of soft house slippers placed beside Max on the ground.
    /// Anchor is `.leaningNearby` so they sit on the floor — easier
    /// than rigging them onto invisible feet.
    private static func buildSlippers(into root: SCNNode) {
        let body = NSColor(srgbRed: 0.55, green: 0.40, blue: 0.30, alpha: 1.0)
        let lining = NSColor(srgbRed: 0.95, green: 0.92, blue: 0.85, alpha: 1.0)

        for x in [CGFloat(-12), CGFloat(12)] {
            let shell = SCNBox(width: 18, height: 10, length: 28, chamferRadius: 6)
            shell.materials = [mat(body, roughness: 0.65)]
            let shellNode = SCNNode(geometry: shell)
            shellNode.position = SCNVector3(x, 5, 0)
            root.addChildNode(shellNode)

            // Inset cushion shows lining colour through the open top.
            let cushion = SCNBox(width: 14, height: 3, length: 22, chamferRadius: 3)
            cushion.materials = [mat(lining, roughness: 0.85)]
            let cushionNode = SCNNode(geometry: cushion)
            cushionNode.position = SCNVector3(x, 9, 0)
            root.addChildNode(cushionNode)
        }
    }

    // MARK: - Face masks (anchor `.onFace`)

    /// Render an emoji into a flat plane bigger than Max's head, parented
    /// to root. Anchored at face level so the emoji floats over the front
    /// of the head — covers Max's eyes, nose, mouth, and overshoots the
    /// silhouette so it reads as a giant sticker / emoji-mask. Constant
    /// lighting model so shading doesn't dim the glyph; double-sided so
    /// it's visible if Max turns. Centre of plane = (0, 8, 1) relative to
    /// the .onFace anchor (which sits at chin), putting the emoji centred
    /// on the head front.
    /// Curated face-emoji vocabulary. Names are lowercase, hyphen-free;
    /// agent passes the key via `{"item":"face_emoji","name":"<key>"}`.
    /// Covers every well-known face glyph across Smileys & Emotion plus
    /// the iconic non-human faces (skull, ghost, alien, etc.). New
    /// entries: stick to FACES — anything that's a body, object, or
    /// scene element belongs in a different prop, not here.
    static let faceEmojiTable: [String: String] = [
        // Smiles
        "grinning":      "😀",
        "smile":         "🙂",
        "joy":           "😂",
        "rofl":          "🤣",
        "wink":          "😉",
        "blush":         "😊",
        "halo":          "😇",
        "love":          "🥰",
        "heart_eyes":    "😍",
        "hearts":        "🥰",
        "star_struck":   "🤩",
        "kiss":          "😘",
        "yum":           "😋",
        "tongue":        "😛",
        "crazy":         "🤪",
        "money_face":    "🤑",
        "hug":           "🤗",
        "shush":         "🤫",
        "thinking":      "🤔",
        // Neutral / wry
        "neutral":       "😐",
        "expressionless":"😑",
        "smirk":         "😏",
        "unamused":      "😒",
        "eye_roll":      "🙄",
        "grimace":       "😬",
        "lying":         "🤥",
        "relief":        "😌",
        "pensive":       "😔",
        "sleepy":        "😪",
        "drool":         "🤤",
        "sleeping":      "😴",
        // Sick / unwell
        "mask":          "😷",
        "thermometer":   "🤒",
        "bandage":       "🤕",
        "nauseated":     "🤢",
        "vomit":         "🤮",
        "sneeze":        "🤧",
        "hot":           "🥵",
        "cold":          "🥶",
        "woozy":         "🥴",
        "dizzy":         "😵",
        "spiral_eyes":   "😵‍💫",
        "explosion":     "🤯",
        // Hat / cool
        "cowboy":        "🤠",
        "partying":      "🥳",
        "disguise":      "🥸",
        "sunglasses":    "😎",
        "nerd":          "🤓",
        "monocle":       "🧐",
        // Sad / scared
        "confused":      "😕",
        "worried":       "😟",
        "frown":         "🙁",
        "open_mouth":    "😮",
        "shocked":       "😲",
        "flushed":       "😳",
        "pleading":      "🥺",
        "fear":          "😨",
        "anxious":       "😰",
        "cry":           "😢",
        "sob":           "😭",
        "scream":        "😱",
        "weary":         "😩",
        "tired":         "😫",
        "yawn":          "🥱",
        // Anger
        "huff":          "😤",
        "angry":         "😠",
        "rage":          "😡",
        "cursing":       "🤬",
        // Mythic / non-human faces
        "devil":         "😈",
        "imp":           "👿",
        "skull":         "💀",
        "skull_x":       "☠️",
        "clown":         "🤡",
        "oni":           "👹",
        "goblin":        "👺",
        "ghost":         "👻",
        "alien":         "👽",
        "alien_monster": "👾",
        "robot":         "🤖",
        "ninja":         "🥷",
        // Cat-face variants — popular subset
        "cat_smile":     "😺",
        "cat_joy":       "😹",
        "cat_heart":     "😻",
        "cat_kiss":      "😽",
        "cat_scream":    "🙀"
    ]

    private static func buildEmojiMask(into root: SCNNode, emoji: String, side: CGFloat = 100) {
        let texture = renderEmojiImage(emoji, side: 256)
        let plane = SCNPlane(width: side, height: side)
        let m = SCNMaterial()
        m.diffuse.contents = texture
        m.transparent.contents = texture          // PNG alpha doubles as cutout mask
        m.lightingModel = .constant                // emoji should not be lit
        m.isDoubleSided = true
        // Disable BOTH depth read and write so the plane is unconditionally
        // drawn on top — head primitives extend forward roughly to z=22 in
        // head-local space, and a plane at +1 was getting depth-tested
        // BEHIND the face plane. With reads off + a high rendering order,
        // the emoji always paints in front of Max regardless of head shape.
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        // Z is also pushed well forward (24 above anchor → head-local
        // z ≈ 44) as belt-and-braces — even if a future shader change
        // re-enables depth, the geometry sits clearly outside the head.
        node.position = SCNVector3(0, 8, 24)
        node.renderingOrder = 100
        root.addChildNode(node)
    }

    /// Render `emoji` as an NSImage with a transparent background. Emoji
    /// fonts on macOS are colour bitmap fonts, so a normal `draw(in:)`
    /// produces a colour glyph against the locked-focus image's clear
    /// pixels, which is exactly what we want for the SCNPlane texture.
    private static func renderEmojiImage(_ emoji: String, side: CGFloat) -> NSImage {
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        // Clear the canvas explicitly — lockFocus() on a fresh NSImage
        // doesn't guarantee a transparent backing on every macOS rev.
        NSColor.clear.set()
        NSRect(origin: .zero, size: size).fill(using: .copy)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: side * 0.78),
            .paragraphStyle: para
        ]
        let attributed = NSAttributedString(string: emoji, attributes: attrs)
        let glyphSize = attributed.size()
        let originY = (side - glyphSize.height) / 2 - side * 0.04   // tiny visual lift
        let drawRect = NSRect(
            x: (side - glyphSize.width) / 2,
            y: originY,
            width: glyphSize.width,
            height: glyphSize.height
        )
        attributed.draw(in: drawRect)
        return image
    }


    // MARK: - Tentacles (anchor `.backMounted`)

    /// Build N writhing tentacles emerging from the back of the
    /// torso. Distribution: half on each side, vertically staggered,
    /// fanned out so the silhouette reads as eight-armed-octopus from
    /// the front. Each tentacle is a chain of progressively-smaller
    /// spheres parented hierarchically (bend at the base ripples to
    /// the tip). Tips are eye-shaped: pale flesh-coloured "ball hand"
    /// with a black pupil sphere protruding forward.
    ///
    /// `count` should be 4–10; the dispatcher clamps before calling.
    private static func buildTentacles(into root: SCNNode, count: Int) {
        let bodyCol = NSColor(srgbRed: 0.18, green: 0.10, blue: 0.22, alpha: 1.0)
        let underCol = NSColor(srgbRed: 0.45, green: 0.18, blue: 0.36, alpha: 1.0)
        let tipCol = NSColor(srgbRed: 0.96, green: 0.84, blue: 0.74, alpha: 1.0)
        let pupilCol = NSColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 1.0)

        // Reduce-motion: skip the writhing animation but keep the
        // static silhouette. Vestibular users still see the costume.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || Prefs.sessionReduceMotion

        // Distribute tentacle origins along the SIDES of the torso so
        // they emerge into camera view, not behind Max where the body
        // hides them. Odd indices → left side, even → right side; even
        // counts split balanced left/right, odd counts get one extra on
        // the right. Within each side we stagger vertically across the
        // full torso height. Origins x sit just outside the torso (~32),
        // z fans slightly fore/aft so the bundle has depth instead of
        // a flat ribbon.
        let perSide = (count + 1) / 2     // upper half (right gets the extra)
        for i in 0..<count {
            let side: CGFloat = (i % 2 == 0) ? 1.0 : -1.0
            let sideIndex = i / 2
            let perThisSide = (i % 2 == 0)
                ? (count - count / 2)     // right side count
                : (count / 2)             // left side count
            // 0…1 within this side. Single-tentacle side → centred at 0.5.
            let vt: Double = perThisSide > 1
                ? Double(sideIndex) / Double(perThisSide - 1)
                : 0.5

            // Torso half-width is roughly 30; sit just outside so the
            // tentacle base doesn't poke through the suit.
            let originX = side * 34
            // Spread vertically from low-hip to shoulder.
            let originY = CGFloat(-32 + vt * 64)               // -32…+32
            // Slight Z fan: top tentacles further back, bottom further
            // forward. Reads as 3D rather than flat-paper.
            let originZ = CGFloat(-6 + (vt - 0.5) * 14)        // -13…+1

            // Point the chain OUTWARD (and slightly down) instead of
            // straight up. baseZRot ≈ ±π/2 → tentacle's local +Y now
            // points along world ±X, i.e. the tentacle extends out to
            // the side. Subtract a touch (·0.18) so they angle slightly
            // downward like an octopus drape rather than splayed flat.
            let baseZRot = side * (Double.pi / 2 - 0.18 - vt * 0.30)
            // Tilt forward toward the camera so the eye-tips face the
            // viewer. Bottom tentacles tilt forward more, top less.
            let baseXRot: Double = -0.45 + vt * 0.35

            let pivot = SCNNode()
            pivot.name = "prop.tentacles.\(i).pivot"
            pivot.position = SCNVector3(originX, originY, originZ)
            pivot.eulerAngles = SCNVector3(baseXRot, 0, baseZRot)
            root.addChildNode(pivot)
            _ = perSide   // silence unused-let in single-side edge cases

            // Build the chain. Each segment is a SCNSphere; subsequent
            // segments are children of the prior, offset along +Y by
            // the segment length so rotations propagate. Radii taper
            // toward the tip but the FINAL tip restores to a ball-hand
            // size so the eye reads.
            //
            // 10 segments × 26px → reach ≈ 260px. Tentacles now stretch
            // well clear of Max's silhouette so the eye-tips always
            // sit in negative space rather than over the body.
            let segments = 10
            let segmentLength: CGFloat = 26
            var parent: SCNNode = pivot
            for s in 0..<segments {
                let isTip = s == segments - 1
                let radius: CGFloat
                if isTip {
                    radius = 8                                  // ball-hand tip
                } else {
                    // 8.5 → 3.0 over 7 segments (linear taper).
                    radius = 8.5 - CGFloat(s) * (5.5 / 7.0)
                }
                let sphereGeom = SCNSphere(radius: radius)
                let segCol = isTip ? tipCol : (s == 0 ? bodyCol : (s % 2 == 0 ? bodyCol : underCol))
                sphereGeom.materials = [mat(segCol, roughness: 0.55)]
                let seg = SCNNode(geometry: sphereGeom)
                seg.name = "prop.tentacles.\(i).seg.\(s)"
                // Offset along the parent's local +Y. First segment
                // sits at the pivot origin; each subsequent segment
                // is one segment-length further out.
                seg.position = s == 0
                    ? SCNVector3(0, 0, 0)
                    : SCNVector3(0, segmentLength, 0)

                // Pupil at the very tip — small dark sphere protruding
                // along +Z (camera-facing in head local). Reads as an
                // eye embedded in the ball hand.
                if isTip {
                    let pupilGeom = SCNSphere(radius: 2.6)
                    pupilGeom.materials = [mat(pupilCol, roughness: 0.25)]
                    let pupil = SCNNode(geometry: pupilGeom)
                    pupil.name = "prop.tentacles.\(i).pupil"
                    pupil.position = SCNVector3(0, 0, radius * 0.85)
                    seg.addChildNode(pupil)
                }
                parent.addChildNode(seg)

                // Writhe animation. Each segment oscillates around its
                // own X axis; phase offset along the chain produces a
                // wave that propagates from base to tip. Slow + low
                // amplitude — earlier setting felt epileptic. Period
                // 3.2–4.2s, amplitude tip ~9° not 26°. Reads as a
                // gentle drift rather than a panic.
                if !reduceMotion {
                    let period = 3.2 + Double(i % 4) * 0.25
                    let phaseOffset = Double(s) * 0.32 + Double(i) * 0.5
                    let amplitude: CGFloat = 0.07 + CGFloat(s) * 0.012
                    let action = SCNAction.customAction(duration: period) { node, t in
                        let phase = 2 * Double.pi * (Double(t) / period) + phaseOffset
                        // X-axis rotation — bends forward/back along the
                        // tentacle direction. Z-axis adds a subtle yaw
                        // so it doesn't look 1-D.
                        node.eulerAngles.x = amplitude * CGFloat(sin(phase))
                        node.eulerAngles.z = amplitude * 0.30 * CGFloat(cos(phase))
                    }
                    seg.runAction(SCNAction.repeatForever(action), forKey: "tentacle.writhe")
                }

                parent = seg
            }
        }
    }
}
