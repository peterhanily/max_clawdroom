import AppKit
import SceneKit

struct OrbForm: Form {
    private let overrideTint: NSColor?

    init(tint: NSColor? = nil) {
        self.overrideTint = tint
    }

    var displayName: String { "Orb" }
    var tint: NSColor {
        overrideTint ?? NSColor(srgbRed: 0.96, green: 0.49, blue: 0.22, alpha: 1.0)
    }
    var approximateRadius: CGFloat { 48 }

    func makeNode() -> SCNNode {
        let root = SCNNode()
        root.name = "pet.root"

        let body = SCNNode(geometry: makeBodyGeometry())
        body.name = "body"
        root.addChildNode(body)

        let leftEye = makeEye()
        leftEye.position = SCNVector3(-14, 10, 38)
        body.addChildNode(leftEye)

        let rightEye = makeEye()
        rightEye.position = SCNVector3(14, 10, 38)
        body.addChildNode(rightEye)

        let glow = SCNNode(geometry: makeGlowGeometry())
        glow.opacity = 0.35
        body.addChildNode(glow)

        attachIdleBob(to: body)
        return root
    }

    private func makeBodyGeometry() -> SCNGeometry {
        let sphere = SCNSphere(radius: 44)
        sphere.segmentCount = 64
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.diffuse.contents = tint
        mat.emission.contents = NSColor(
            srgbRed: 0.5, green: 0.22, blue: 0.05, alpha: 1.0
        )
        mat.roughness.contents = 0.35
        mat.metalness.contents = 0.15
        sphere.materials = [mat]
        return sphere
    }

    private func makeGlowGeometry() -> SCNGeometry {
        let sphere = SCNSphere(radius: 58)
        sphere.segmentCount = 32
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = tint.withAlphaComponent(0.2)
        mat.writesToDepthBuffer = false
        mat.transparent.contents = NSColor(white: 0, alpha: 0.3)
        mat.blendMode = .add
        sphere.materials = [mat]
        return sphere
    }

    private func makeEye() -> SCNNode {
        let g = SCNSphere(radius: 6)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.black
        g.materials = [m]
        return SCNNode(geometry: g)
    }

    private func attachIdleBob(to node: SCNNode) {
        let up = SCNAction.moveBy(x: 0, y: 6, z: 0, duration: 1.1)
        up.timingMode = .easeInEaseOut
        let down = SCNAction.moveBy(x: 0, y: -6, z: 0, duration: 1.1)
        down.timingMode = .easeInEaseOut
        node.runAction(.repeatForever(.sequence([up, down])), forKey: "bob")
    }
}
