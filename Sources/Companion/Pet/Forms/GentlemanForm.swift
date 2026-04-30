import AppKit
import SceneKit
import ModelIO
import SceneKit.ModelIO
import GLTFSceneKit

/// Humanoid gentleman in a dark suit with wraparound sunglasses. Built from
/// SceneKit primitives. Node origin is at the feet; body extends upward in +Y.
/// Standing pose by default; a subtle breathing + head-sway cycle runs when
/// idle. No baked walk cycle — locomotion just translates the root.
///
/// Swap in a custom mesh / persona by creating a `Form` in
/// `Sources/Companion/Pet/Forms/Private/` (gitignored) and selecting it in
/// `OverlayController.init`.
struct GentlemanForm: Form {
    var displayName: String { "Gentleman" }
    var tint: NSColor { NSColor(calibratedWhite: 0.10, alpha: 1.0) }
    var approximateRadius: CGFloat { 70 }
    var walkEagerness: Double { 0.25 }
    var baseY: CGFloat { 80 }

    var bubbleAccent: NSColor {
        NSColor(srgbRed: 0.92, green: 0.52, blue: 0.15, alpha: 1.0)
    }

    var hitBoundsRelative: CGRect {
        CGRect(x: -80, y: -10, width: 160, height: 380)
    }

    var greeting: String? { "Hello. What can I help with?" }

    // MARK: - Dimensions (scene pixels)
    private var headRadius: CGFloat { 22 }
    private var neckHeight: CGFloat { 8 }
    private var torsoWidth: CGFloat { 46 }
    private var torsoHeight: CGFloat { 72 }
    private var torsoDepth: CGFloat { 28 }
    private var armRadius: CGFloat { 9 }
    private var armLength: CGFloat { 86 }
    private var legRadius: CGFloat { 11 }
    private var legLength: CGFloat { 96 }
    private var footLength: CGFloat { 28 }
    private var footHeight: CGFloat { 8 }
    private var footWidth: CGFloat { 18 }

    // MARK: - Materials
    private var suitMat: SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(calibratedWhite: 0.07, alpha: 1.0)
        m.roughness.contents = 0.72
        m.metalness.contents = 0.05
        return m
    }

    private var hairMat: SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(calibratedWhite: 0.03, alpha: 1.0)
        m.roughness.contents = 0.28
        m.metalness.contents = 0.12
        return m
    }

    private var skinMat: SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(srgbRed: 0.88, green: 0.74, blue: 0.64, alpha: 1.0)
        m.roughness.contents = 0.62
        m.metalness.contents = 0.0
        return m
    }

    private var lensMat: SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(calibratedWhite: 0.02, alpha: 1.0)
        m.roughness.contents = 0.08
        m.metalness.contents = 0.85
        m.emission.contents = NSColor(calibratedWhite: 0.02, alpha: 1.0)
        return m
    }

    private var frameMat: SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(calibratedWhite: 0.04, alpha: 1.0)
        m.roughness.contents = 0.25
        m.metalness.contents = 0.55
        return m
    }

    private var shoeMat: SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(calibratedWhite: 0.05, alpha: 1.0)
        m.roughness.contents = 0.28
        m.metalness.contents = 0.20
        return m
    }

    private var collarMat: SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(calibratedWhite: 0.92, alpha: 1.0)
        m.roughness.contents = 0.6
        return m
    }

    // MARK: - Build
    func makeNode() -> SCNNode {
        // Preference order:
        //   1. 3D mesh (.usdz / .usdc / .obj / .stl) in Resources/, textured
        //      with the image if present (front-projection mapping).
        //   2. Billboard PNG — 2D plane always facing camera.
        //   3. Primitives fallback — ships in the public repo.
        if let meshNode = tryLoadMesh() {
            return meshNode
        }
        if let image = loadBillboardImage() {
            return makeBillboardNode(with: image)
        }
        return makePrimitiveNode()
    }

    private func findMeshURL() -> URL? {
        guard let resDir = Bundle.module.resourceURL else { return nil }
        guard
            let items = try? FileManager.default.contentsOfDirectory(
                at: resDir, includingPropertiesForKeys: nil
            )
        else { return nil }
        for ext in ["usdz", "usdc", "glb", "gltf", "obj", "stl"] {
            if let found = items.first(where: { $0.pathExtension.lowercased() == ext }) {
                return found
            }
        }
        return nil
    }

    private func tryLoadMesh() -> SCNNode? {
        guard let url = findMeshURL() else { return nil }

        // Trust the loaded scene's materials (GLB/USDZ come with PBR
        // textures embedded). Apply smooth normals only if source format
        // is known to lack them (STL).
        let ext = url.pathExtension.lowercased()
        var loadedScene: SCNScene?
        switch ext {
        case "glb", "gltf":
            // SceneKit has no native glTF loader — use GLTFSceneKit.
            if
                let source = try? GLTFSceneSource(url: url),
                let scene = try? source.scene()
            {
                loadedScene = scene
            }
        case "stl":
            let asset = MDLAsset(url: url)
            if asset.count > 0 {
                for i in 0..<asset.count {
                    if let m = asset.object(at: i) as? MDLMesh {
                        m.addNormals(
                            withAttributeNamed: MDLVertexAttributeNormal,
                            creaseThreshold: 0.4
                        )
                    }
                }
                loadedScene = SCNScene(mdlAsset: asset)
            }
        default:
            // USDZ / USDC / OBJ — SCNScene natively.
            if let s = try? SCNScene(url: url, options: nil) {
                loadedScene = s
            } else {
                let asset = MDLAsset(url: url)
                if asset.count > 0 {
                    loadedScene = SCNScene(mdlAsset: asset)
                }
            }
        }

        guard let scene = loadedScene, !scene.rootNode.childNodes.isEmpty else {
            FileHandle.standardError.write(
                "Mesh load failed or empty: \(url.lastPathComponent)\n"
                    .data(using: .utf8)!
            )
            return nil
        }

        let mesh = SCNNode()
        mesh.name = "mesh"
        for child in scene.rootNode.childNodes {
            mesh.addChildNode(child)
        }

        // Object-space bounding box.
        let (objMin, objMax) = mesh.boundingBox
        let ox = CGFloat(objMax.x - objMin.x)
        let oy = CGFloat(objMax.y - objMin.y)
        let oz = CGFloat(objMax.z - objMin.z)
        FileHandle.standardError.write(
            "Mesh \(url.lastPathComponent) bounds dx=\(ox) dy=\(oy) dz=\(oz)\n"
                .data(using: .utf8)!
        )

        // Pick the tallest axis as "up" and rotate to Y-up.
        let tallest = max(ox, oy, oz)
        if oz == tallest && oz > oy {
            mesh.eulerAngles = SCNVector3(-Double.pi / 2, 0, 0)
        } else if ox == tallest && ox > oy {
            mesh.eulerAngles = SCNVector3(0, 0, -Double.pi / 2)
        }

        // Recompute bounding box after rotation.
        let rotated = SCNNode()
        rotated.addChildNode(mesh)
        let (rMin, rMax) = rotated.boundingBox
        let rHeight = CGFloat(rMax.y - rMin.y)

        let targetHeight: CGFloat = 360
        let scale = rHeight > 0 ? Double(targetHeight / rHeight) : 1.0

        let placed = SCNNode()
        placed.addChildNode(rotated)
        placed.scale = SCNVector3(scale, scale, scale)
        placed.position = SCNVector3(
            -Double(rMin.x + rMax.x) / 2 * scale,
            -Double(rMin.y) * scale,
            -Double(rMin.z + rMax.z) / 2 * scale
        )

        let root = SCNNode()
        root.name = "pet.root"
        root.addChildNode(makeGroundShadow())
        let body = SCNNode()
        body.name = "body"
        body.addChildNode(placed)
        root.addChildNode(body)

        let bobUp = SCNAction.moveBy(x: 0, y: 1.2, z: 0, duration: 2.8)
        bobUp.timingMode = .easeInEaseOut
        let bobDown = SCNAction.moveBy(x: 0, y: -1.2, z: 0, duration: 2.8)
        bobDown.timingMode = .easeInEaseOut
        placed.runAction(.repeatForever(.sequence([bobUp, bobDown])), forKey: "breathing")

        // Inventory but don't auto-play — Pet controls playback based on
        // locomotion state. Stop all animations so the mesh rests in bind
        // pose until startWalkAnimation() is called.
        let stats = inventoryAndStopAnimations(on: mesh)
        FileHandle.standardError.write(
            "Mesh \(url.lastPathComponent): materials=\(stats.materials) animations=\(stats.animations) nodes=\(stats.nodes)\n"
                .data(using: .utf8)!
        )

        return root
    }

    private struct MeshStats {
        var nodes = 0
        var materials = 0
        var animations = 0
    }

    private func inventoryAndStopAnimations(on node: SCNNode) -> MeshStats {
        var stats = MeshStats()
        node.enumerateHierarchy { n, _ in
            stats.nodes += 1
            if let geom = n.geometry {
                stats.materials += geom.materials.count
            }
            for key in n.animationKeys {
                stats.animations += 1
                if let player = n.animationPlayer(forKey: key) {
                    player.stop()
                }
            }
        }
        return stats
    }

    private func makeProjectionMaterial(
        image: NSImage?,
        objMinX: Float, objWidth: Float,
        objMinVertical: Float, objHeight: Float,
        zUp: Bool
    ) -> SCNMaterial {
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.isDoubleSided = true
        mat.roughness.contents = 0.55
        mat.metalness.contents = 0.08
        _ = image  // the photo has no UVs we can use cleanly; palette is reliable

        // Palette gradient as a 1x256 texture. Geometry modifier writes
        // texcoords from object-space height. PBR samples the gradient at
        // the correct band. Reliable path that doesn't rely on world/view
        // space guessing.
        mat.diffuse.contents = makePaletteGradient()
        mat.diffuse.wrapS = .clamp
        mat.diffuse.wrapT = .clamp
        mat.diffuse.magnificationFilter = .linear
        mat.diffuse.minificationFilter = .linear

        let vertComp = zUp ? "z" : "y"
        let geomShader = """
        #pragma body
        float v = (_geometry.position.\(vertComp) - (\(objMinVertical))) / \(objHeight);
        _geometry.texcoords[0] = vec2(0.5, clamp(v, 0.0, 1.0));
        """
        mat.shaderModifiers = [.geometry: geomShader]
        return mat
    }

    /// Builds a 1x256 vertical gradient with the suit/shirt/skin/hair bands.
    /// The gradient matches the image's color palette; sampling at v=0 gives
    /// suit (feet), v=1 gives hair (top of head).
    private func makePaletteGradient() -> NSImage {
        let width = 4
        let height = 256
        let bpc = 8
        let bpp = 32
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        let bands: [(Float, (Float, Float, Float))] = [
            (0.00, (0.050, 0.050, 0.055)),  // shoes
            (0.06, (0.050, 0.050, 0.055)),
            (0.10, (0.070, 0.070, 0.075)),  // trousers
            (0.50, (0.080, 0.080, 0.085)),  // jacket mid
            (0.80, (0.075, 0.075, 0.080)),  // jacket upper
            (0.825, (0.930, 0.920, 0.905)), // collar / shirt
            (0.865, (0.930, 0.920, 0.905)),
            (0.885, (0.885, 0.745, 0.640)), // skin (cheek/chin)
            (0.945, (0.885, 0.745, 0.640)),
            (0.960, (0.050, 0.040, 0.045)), // hair + sunglasses
            (1.00, (0.045, 0.035, 0.045))
        ]

        for y in 0..<height {
            let t = Float(y) / Float(height - 1)
            var color: (Float, Float, Float) = bands[0].1
            for i in 0..<(bands.count - 1) {
                let (t0, c0) = bands[i]
                let (t1, c1) = bands[i + 1]
                if t >= t0 && t <= t1 {
                    let denom = max(0.0001, t1 - t0)
                    let f = (t - t0) / denom
                    color = (
                        c0.0 + (c1.0 - c0.0) * f,
                        c0.1 + (c1.1 - c0.1) * f,
                        c0.2 + (c1.2 - c0.2) * f
                    )
                    break
                }
            }
            let r = UInt8(max(0, min(255, color.0 * 255)))
            let g = UInt8(max(0, min(255, color.1 * 255)))
            let b = UInt8(max(0, min(255, color.2 * 255)))
            for x in 0..<width {
                let idx = y * bytesPerRow + x * 4
                pixels[idx] = r
                pixels[idx + 1] = g
                pixels[idx + 2] = b
                pixels[idx + 3] = 255
            }
        }

        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        // sRGB explicitly so the generated texture renders the same colours
        // on wide-gamut displays as on a standard 1x panel. DeviceRGB meant
        // "whatever the display happens to be," which showed up as pink
        // shifts on P3 hardware.
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: bpc, bitsPerPixel: bpp,
            bytesPerRow: bytesPerRow,
            space: space, bitmapInfo: info,
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        )!
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    private func applyMaterial(_ mat: SCNMaterial, to node: SCNNode) {
        if let geom = node.geometry {
            geom.materials = [mat]
        }
        for child in node.childNodes {
            applyMaterial(mat, to: child)
        }
    }

    private func loadBillboardImage() -> NSImage? {
        let candidates = ["companion", "hero", "roy"]
        for name in candidates {
            if
                let url = Bundle.module.url(forResource: name, withExtension: "png"),
                let image = NSImage(contentsOf: url)
            {
                return image
            }
        }
        return nil
    }

    private func makeBillboardNode(with image: NSImage) -> SCNNode {
        let root = SCNNode()
        root.name = "pet.root"

        root.addChildNode(makeGroundShadow())

        let body = SCNNode()
        body.name = "body"
        root.addChildNode(body)

        let targetHeight: CGFloat = 260
        let aspect: CGFloat
        if image.size.height > 0 {
            aspect = image.size.width / image.size.height
        } else {
            aspect = 0.666
        }
        let width = targetHeight * aspect

        let plane = SCNPlane(width: width, height: targetHeight)
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = image
        mat.diffuse.magnificationFilter = .linear
        mat.diffuse.minificationFilter = .linear
        mat.diffuse.mipFilter = .linear
        mat.transparencyMode = .aOne
        mat.blendMode = .alpha
        mat.writesToDepthBuffer = false
        mat.isDoubleSided = false
        plane.materials = [mat]

        let planeNode = SCNNode(geometry: plane)
        planeNode.position = SCNVector3(0, targetHeight / 2, 0)
        planeNode.name = "billboard"

        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .Y
        planeNode.constraints = [billboard]

        body.addChildNode(planeNode)

        // Breathing — subtle vertical bob
        let up = SCNAction.moveBy(x: 0, y: 2, z: 0, duration: 2.6)
        up.timingMode = .easeInEaseOut
        let down = SCNAction.moveBy(x: 0, y: -2, z: 0, duration: 2.6)
        down.timingMode = .easeInEaseOut
        planeNode.runAction(.repeatForever(.sequence([up, down])), forKey: "breathing")

        // Weight-shift sway — slow side-to-side lean when idle
        let swayRight = SCNAction.rotateTo(
            x: 0, y: 0, z: CGFloat(-0.018), duration: 3.2
        )
        swayRight.timingMode = .easeInEaseOut
        let swayLeft = SCNAction.rotateTo(
            x: 0, y: 0, z: CGFloat(0.018), duration: 3.2
        )
        swayLeft.timingMode = .easeInEaseOut
        planeNode.runAction(
            .repeatForever(.sequence([swayRight, swayLeft])),
            forKey: "sway"
        )

        return root
    }

    private func makePrimitiveNode() -> SCNNode {
        let root = SCNNode()
        root.name = "pet.root"

        root.addChildNode(makeGroundShadow())

        let body = SCNNode()
        body.name = "body"
        root.addChildNode(body)

        let leftFoot = makeFoot()
        leftFoot.position = SCNVector3(-10, footHeight / 2, 4)
        body.addChildNode(leftFoot)
        let rightFoot = makeFoot()
        rightFoot.position = SCNVector3(10, footHeight / 2, 4)
        body.addChildNode(rightFoot)

        let leftLeg = makeLeg()
        leftLeg.position = SCNVector3(-10, footHeight + legLength / 2, 0)
        body.addChildNode(leftLeg)
        let rightLeg = makeLeg()
        rightLeg.position = SCNVector3(10, footHeight + legLength / 2, 0)
        body.addChildNode(rightLeg)

        let torsoY = footHeight + legLength + torsoHeight / 2
        let torso = makeTorso()
        torso.name = "torso"
        torso.position = SCNVector3(0, torsoY, 0)
        body.addChildNode(torso)

        let collar = SCNNode(geometry: makeCollarGeometry())
        collar.position = SCNVector3(0, torsoHeight / 2 + 2, 2)
        torso.addChildNode(collar)

        let shoulderX = torsoWidth / 2 + armRadius * 0.6
        let shoulderY = torsoHeight / 2 - armRadius * 1.2
        let leftArm = makeArm()
        leftArm.position = SCNVector3(-shoulderX, shoulderY - armLength / 2, 0)
        torso.addChildNode(leftArm)
        let rightArm = makeArm()
        rightArm.position = SCNVector3(shoulderX, shoulderY - armLength / 2, 0)
        torso.addChildNode(rightArm)

        let neck = SCNNode(geometry: SCNCylinder(radius: 7, height: neckHeight))
        neck.geometry?.materials = [skinMat]
        neck.position = SCNVector3(0, torsoHeight / 2 + neckHeight / 2, 0)
        torso.addChildNode(neck)

        let head = makeHead()
        head.name = "part.head"
        head.position = SCNVector3(0, torsoHeight / 2 + neckHeight + headRadius * 0.95, 0)
        torso.addChildNode(head)

        attachBreathing(to: torso)
        attachHeadSway(to: head)

        return root
    }

    // MARK: - Body parts
    private func makeGroundShadow() -> SCNNode {
        let g = SCNPlane(width: 54, height: 22)
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

    private func makeFoot() -> SCNNode {
        let box = SCNBox(width: footWidth, height: footHeight, length: footLength, chamferRadius: 3)
        box.materials = [shoeMat]
        return SCNNode(geometry: box)
    }

    private func makeLeg() -> SCNNode {
        let cyl = SCNCylinder(radius: legRadius, height: legLength)
        cyl.materials = [suitMat]
        return SCNNode(geometry: cyl)
    }

    private func makeArm() -> SCNNode {
        let cyl = SCNCylinder(radius: armRadius, height: armLength)
        cyl.materials = [suitMat]
        let arm = SCNNode(geometry: cyl)

        let hand = SCNNode(geometry: SCNSphere(radius: armRadius * 1.1))
        hand.geometry?.materials = [skinMat]
        hand.position = SCNVector3(0, -armLength / 2 - armRadius * 0.6, 0)
        arm.addChildNode(hand)

        return arm
    }

    private func makeTorso() -> SCNNode {
        let box = SCNBox(
            width: torsoWidth,
            height: torsoHeight,
            length: torsoDepth,
            chamferRadius: 9
        )
        box.materials = [suitMat]
        return SCNNode(geometry: box)
    }

    private func makeCollarGeometry() -> SCNGeometry {
        let box = SCNBox(
            width: torsoWidth * 0.55,
            height: 5,
            length: torsoDepth * 0.7,
            chamferRadius: 2
        )
        box.materials = [collarMat]
        return box
    }

    private func makeHead() -> SCNNode {
        let container = SCNNode()

        let headGeom = SCNSphere(radius: headRadius)
        headGeom.segmentCount = 64
        headGeom.materials = [skinMat]
        let head = SCNNode(geometry: headGeom)
        head.scale = SCNVector3(1.0, 1.12, 0.95)
        container.addChildNode(head)

        let hair = SCNNode(geometry: makeHairGeometry())
        hair.position = SCNVector3(0, headRadius * 0.55, -headRadius * 0.2)
        hair.eulerAngles = SCNVector3(-Double.pi / 16, 0, 0)
        hair.scale = SCNVector3(1.05, 0.78, 1.2)
        container.addChildNode(hair)

        let leftBurn = SCNNode(geometry: makeSideburnGeometry())
        leftBurn.position = SCNVector3(-headRadius * 0.85, headRadius * 0.1, headRadius * 0.25)
        leftBurn.eulerAngles = SCNVector3(0, 0, -Double.pi / 18)
        container.addChildNode(leftBurn)
        let rightBurn = SCNNode(geometry: makeSideburnGeometry())
        rightBurn.position = SCNVector3(headRadius * 0.85, headRadius * 0.1, headRadius * 0.25)
        rightBurn.eulerAngles = SCNVector3(0, 0, Double.pi / 18)
        container.addChildNode(rightBurn)

        let leftLens = SCNNode(geometry: makeLensGeometry())
        leftLens.position = SCNVector3(-headRadius * 0.45, headRadius * 0.22, headRadius * 0.88)
        container.addChildNode(leftLens)
        let rightLens = SCNNode(geometry: makeLensGeometry())
        rightLens.position = SCNVector3(headRadius * 0.45, headRadius * 0.22, headRadius * 0.88)
        container.addChildNode(rightLens)
        let bridge = SCNNode(geometry: makeBridgeGeometry())
        bridge.position = SCNVector3(0, headRadius * 0.22, headRadius * 0.88)
        container.addChildNode(bridge)

        let mouth = SCNNode(geometry: makeMouthGeometry())
        mouth.position = SCNVector3(0, -headRadius * 0.32, headRadius * 0.92)
        container.addChildNode(mouth)

        let nose = SCNNode(geometry: makeNoseGeometry())
        nose.position = SCNVector3(0, -headRadius * 0.08, headRadius * 1.02)
        nose.eulerAngles = SCNVector3(Double.pi / 2, 0, 0)
        container.addChildNode(nose)

        return container
    }

    private func makeHairGeometry() -> SCNGeometry {
        let g = SCNSphere(radius: headRadius * 1.02)
        g.segmentCount = 48
        g.materials = [hairMat]
        return g
    }

    private func makeSideburnGeometry() -> SCNGeometry {
        let g = SCNBox(width: 5, height: 18, length: 3, chamferRadius: 1.5)
        g.materials = [hairMat]
        return g
    }

    private func makeLensGeometry() -> SCNGeometry {
        let box = SCNBox(width: 17, height: 11, length: 3, chamferRadius: 2.4)
        box.materials = [lensMat]
        return box
    }

    private func makeBridgeGeometry() -> SCNGeometry {
        let box = SCNBox(width: 8, height: 2.5, length: 3, chamferRadius: 1.0)
        box.materials = [frameMat]
        return box
    }

    private func makeMouthGeometry() -> SCNGeometry {
        let box = SCNBox(width: 12, height: 1.6, length: 2, chamferRadius: 0.8)
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(srgbRed: 0.42, green: 0.22, blue: 0.20, alpha: 1.0)
        m.roughness.contents = 0.45
        box.materials = [m]
        return box
    }

    private func makeNoseGeometry() -> SCNGeometry {
        let cone = SCNCone(topRadius: 2.2, bottomRadius: 3.8, height: 6)
        cone.materials = [skinMat]
        return cone
    }

    // MARK: - Idle animations
    private func attachBreathing(to node: SCNNode) {
        let expand = SCNAction.scale(by: 1.018, duration: 2.2)
        expand.timingMode = .easeInEaseOut
        let contract = SCNAction.scale(by: 1.0 / 1.018, duration: 2.2)
        contract.timingMode = .easeInEaseOut
        node.runAction(.repeatForever(.sequence([expand, contract])), forKey: "breathing")
    }

    private func attachHeadSway(to node: SCNNode) {
        let swayRight = SCNAction.rotateTo(
            x: 0, y: CGFloat(0.04), z: 0, duration: 3.6
        )
        swayRight.timingMode = .easeInEaseOut
        let swayLeft = SCNAction.rotateTo(
            x: 0, y: CGFloat(-0.04), z: 0, duration: 3.6
        )
        swayLeft.timingMode = .easeInEaseOut
        node.runAction(.repeatForever(.sequence([swayRight, swayLeft])), forKey: "headsway")
    }
}
