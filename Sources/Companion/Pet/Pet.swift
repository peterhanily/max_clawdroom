import AppKit
import SceneKit

final class Pet {
    let form: Form
    let node: SCNNode
    let bodyNode: SCNNode
    let headNode: SCNNode?
    private var facingRight: Bool = true
    private var isWalkAnimPlaying: Bool = false

    /// Materials grouped by logical part name (e.g. "suit", "hair").
    /// Populated by walking the node tree at init and collecting any node
    /// whose name starts with "part.<partName>".
    private var partMaterials: [String: [SCNMaterial]] = [:]
    private var originalPartColors: [String: [Any?]] = [:]
    /// Nodes grouped by part name — used for transform-based bindings
    /// (pulse, shake, tilt).
    private var partNodes: [String: [SCNNode]] = [:]

    var approximateRadius: CGFloat { form.approximateRadius }
    var availableParts: [String] { Array(partMaterials.keys).sorted() }

    init(form: Form) {
        self.form = form
        self.node = form.makeNode()
        self.bodyNode = node.childNode(withName: "body", recursively: true) ?? node
        self.headNode = node.childNode(withName: "part.head", recursively: true)
            ?? node.childNode(withName: "head", recursively: true)
        indexParts()
        indexExpressionRestPositions()
        form.attachBehaviors(to: self)
    }

    // MARK: - Part indexing & color mutation

    private func indexParts() {
        partNodes.removeAll()
        partMaterials.removeAll()
        originalPartColors.removeAll()
        node.enumerateHierarchy { n, _ in
            guard let name = n.name, name.hasPrefix("part.") else { return }
            let stripped = String(name.dropFirst("part.".count))
            let key = stripped.split(separator: ".").first.map(String.init) ?? stripped
            partNodes[key, default: []].append(n)
            if let materials = n.geometry?.materials {
                partMaterials[key, default: []].append(contentsOf: materials)
                originalPartColors[key, default: []].append(
                    contentsOf: materials.map { $0.diffuse.contents as Any? }
                )
            }
        }
    }

    /// Public re-indexer for callers that mutate the head subtree at runtime
    /// (hair/grooming swaps, face morphs). Relaxes unchanged expression-
    /// targeted nodes back to their STORED authored rest before re-snapshot
    /// so the snapshot doesn't capture an active expression pose as "rest",
    /// then re-poses to the prior expression so a hair swap doesn't stomp
    /// the pet's current mood. Newly-rebuilt subtrees identified by
    /// `isChanged` are left alone so their freshly-built transforms become
    /// the new authored rest (using them as fallback by calling
    /// `poseExpression(.neutral)` instead would apply stale rest values from
    /// the previous style's nodes to the new ones).
    func reindexAfterAppearanceChange(isChanged: (String) -> Bool = { _ in false }) {
        let priorExpression = currentExpression
        for key in expressionAllKeys {
            if isChanged(key) { continue }
            // Use the cached node ref from the previous index. Nodes marked
            // `isChanged` are about to be rebuilt so skipping them here is
            // the whole point — the next indexExpressionRestPositions will
            // populate fresh refs for whatever the subtree swap added.
            guard let target = expressionNodes[key] else { continue }
            if let e = expressionRestEuler[key] { target.eulerAngles = e }
            if let s = expressionRestScale[key] { target.scale = s }
            if let p = expressionRestPositions[key] { target.position = p }
        }
        indexParts()
        indexExpressionRestPositions()
        if priorExpression != .neutral {
            poseExpression(priorExpression)
        }
    }

    /// Change the diffuse color of every material belonging to `partName`.
    /// Silently no-ops if the part doesn't exist.
    func setPartColor(_ partName: String, to color: NSColor) {
        guard let materials = partMaterials[partName] else { return }
        for m in materials {
            m.diffuse.contents = color
        }
    }

    /// Swap every material on `partName` to a procedurally-generated pattern
    /// image. `primary` drives the base fill; `accent` is the secondary colour
    /// (stripes, polka dots, plaid crosshatch). Tiles across the geometry via
    /// `wrapS/T = .repeat`. Passing `.solid` with no accent yields a flat
    /// fill equivalent to `setPartColor` but via a bitmap — keep using
    /// `setPartColor` for plain colour changes.
    func setPartPattern(
        _ partName: String,
        kind: PatternFactory.Kind,
        primary: NSColor,
        accent: NSColor?
    ) {
        guard let materials = partMaterials[partName] else { return }
        let image = PatternFactory.image(kind: kind, primary: primary, accent: accent)
        for m in materials {
            m.diffuse.contents = image
            m.diffuse.wrapS = .repeat
            m.diffuse.wrapT = .repeat
            // Patterns were designed to look right at ~3× tile frequency on the
            // torso box; cylinders (sleeves, legs) get the same frequency so
            // stripes read as vertical across the figure.
            m.diffuse.contentsTransform = SCNMatrix4MakeScale(3, 3, 1)
        }
    }

    // MARK: - Appearance swaps (hair / grooming)

    /// Currently-applied hair style. Tracked so ⌘Z can restore the prior
    /// style. Starts at `.pompadour` because BroadcasterForm authors that
    /// look as the rest pose.
    private(set) var currentHairStyle: HairStyle = .pompadour
    private(set) var currentFacialHair: FacialHair = .clean

    /// Swap the hair subtree on the head. No-ops on Forms that don't
    /// expose a `HeadStyleContext`. After the swap, the parts index and
    /// expression rest positions are rebuilt so colour, pattern, and
    /// expression ops keep targeting the right nodes.
    func setHairStyle(_ style: HairStyle) {
        guard let form = form as? HeadStyleCustomizable,
              let head = headNode
        else { return }
        // Remove every node under the head whose name starts `part.hair.`.
        // Enumerate children only (not whole hierarchy) so facial hair
        // (which lives at the same level) is untouched.
        for child in head.childNodes where (child.name ?? "").hasPrefix("part.hair.") {
            child.removeFromParentNode()
        }
        for n in style.buildNodes(context: form.headStyleContext) {
            head.addChildNode(n)
        }
        currentHairStyle = style
        reindexAfterAppearanceChange { $0.hasPrefix("part.hair.") }
        // Fresh nodes default to visible; hide them again if a hat is on
        // so swapping hair while wearing a hat doesn't briefly clip through.
        reconcileHairForHatState()
    }

    // MARK: - Outfits & granular color

    /// Apply an OutfitPreset — fires one `setPartColor` or
    /// `setPartPattern` per part-group based on the preset's recipe.
    /// Returns a snapshot of the prior material state so the caller
    /// can wire ⌘Z-undo via the existing captureAllPartMaterialContents.
    @discardableResult
    func applyOutfit(_ preset: OutfitPreset) -> AllPartsMaterialSnapshot {
        let snap = captureAllPartMaterialContents()
        let r = preset.recipe
        applyOutfitSpec(part: "suit", spec: r.suit)
        applyOutfitSpec(part: "tie", spec: r.tie)
        applyOutfitSpec(part: "shirt", spec: r.shirt)
        applyOutfitSpec(part: "shoe", spec: r.shoe)
        return snap
    }

    private func applyOutfitSpec(part: String, spec: OutfitPartSpec) {
        guard let primary = NSColor.fromHex(spec.primary) else { return }
        let accent = spec.accent.flatMap(NSColor.fromHex)
        if spec.pattern == .solid && accent == nil {
            setPartColor(part, to: primary)
        } else {
            setPartPattern(part, kind: spec.pattern, primary: primary, accent: accent)
        }
    }

    /// Whether Max's glasses frames are currently visible. The lenses are
    /// always on (they serve as his eyes), so this tracks frame state only.
    var glassesVisible: Bool {
        let bridge = node.childNode(withName: "part.frame.bridge", recursively: true)
        return !(bridge?.isHidden ?? false)
    }

    /// Show or hide Max's glasses frames and tinted lenses. The eye sclera and
    /// pupils are NEVER hidden — they are his eyes. Pass `nil` to toggle
    /// current state; pass `true`/`false` to set explicitly.
    @discardableResult
    func setGlassesVisible(_ visible: Bool?) -> Bool {
        let toggleableNames = [
            "part.frame.left", "part.frame.right", "part.frame.bridge",
            "part.glasses.lens.left", "part.glasses.lens.right"
        ]
        let newVisible: Bool
        if let v = visible {
            newVisible = v
        } else {
            // Toggle: check bridge to determine current state.
            let bridge = node.childNode(withName: "part.frame.bridge", recursively: true)
            newVisible = bridge?.isHidden ?? false
        }
        for name in toggleableNames {
            node.childNode(withName: name, recursively: true)?.isHidden = !newVisible
        }
        // Eyes and pupils are always shown — they are his eyes.
        for name in ["part.eye.left", "part.eye.right", "part.pupil.left", "part.pupil.right"] {
            node.childNode(withName: name, recursively: true)?.isHidden = false
        }
        return newVisible
    }

    /// Change the glasses frame shape (and tinted lens shape to match),
    /// then show the glasses. Material colors are re-applied from the
    /// canonical gold/dark-lens values so style swaps don't require
    /// prior state.
    func setGlassesStyle(_ style: GlassesStyle) {
        let goldMat: () -> SCNMaterial = {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = NSColor(srgbRed: 0.90, green: 0.70, blue: 0.24, alpha: 1)
            m.roughness.contents = CGFloat(0.14)
            m.metalness.contents = CGFloat(0.90)
            return m
        }
        let lensMat: () -> SCNMaterial = {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = NSColor(srgbRed: 0.04, green: 0.04, blue: 0.06, alpha: 1)
            m.roughness.contents = CGFloat(0.04)
            m.metalness.contents = CGFloat(0.85)
            return m
        }
        for side in ["left", "right"] {
            if let frameNode = node.childNode(withName: "part.frame.\(side)", recursively: true) {
                let geom = style.frameGeometry()
                geom.materials = [goldMat()]
                frameNode.geometry = geom
                frameNode.eulerAngles.z = style.frameTiltZ(side: side)
            }
            if let glassesLensNode = node.childNode(withName: "part.glasses.lens.\(side)", recursively: true) {
                let geom = style.lensGeometry()
                geom.materials = [lensMat()]
                glassesLensNode.geometry = geom
                glassesLensNode.eulerAngles.z = style.frameTiltZ(side: side)
            }
        }
        // Show the glasses when style is set.
        setGlassesVisible(true)
    }

    /// Finer-grained color control than `setPartColor(_:)`: targets
    /// a single named scene node (e.g. `part.brow.left`) and overrides
    /// just that one material's diffuse. The part-group APIs remain
    /// for broad strokes; this is the surgical knife.
    func setNodeColor(_ nodeName: String, to color: NSColor) -> Any? {
        guard let target = node.childNode(withName: nodeName, recursively: true),
              let mat = target.geometry?.firstMaterial
        else { return nil }
        let prior = mat.diffuse.contents
        mat.diffuse.contents = color
        return prior
    }

    /// Undo partner for `setNodeColor` — restores whatever `contents`
    /// was returned from the original call.
    func restoreNodeColor(_ nodeName: String, contents: Any?) {
        guard let target = node.childNode(withName: nodeName, recursively: true),
              let mat = target.geometry?.firstMaterial
        else { return }
        mat.diffuse.contents = contents
    }

    // MARK: - Dance & extended gestures

    /// Dance styles. Each one runs a scripted SCNAction choreography
    /// on the pivot + head nodes over 2–4 seconds. Actions layered on
    /// existing breathing / headsway, but limb animations stomp those
    /// during execution.
    enum DanceStyle: String, CaseIterable {
        case disco, robot, shuffle, headbang
    }

    /// Kick off the named dance. Non-blocking — returns immediately
    /// while SCNActions run out. Kills any prior dance first so a
    /// back-to-back `dance` call doesn't layer choreographies.
    func dance(_ style: DanceStyle) {
        // Clear any in-flight dance from limbs + head.
        for key in ["pivot.arm.left", "pivot.arm.right", "pivot.leg.left", "pivot.leg.right"] {
            node.childNode(withName: key, recursively: true)?.removeAction(forKey: "dance")
        }
        headNode?.removeAction(forKey: "dance")
        switch style {
        case .disco:    danceDisco()
        case .robot:    danceRobot()
        case .shuffle:  danceShuffle()
        case .headbang: danceHeadbang()
        }
    }

    private func danceDisco() {
        // Saturday Night Fever point: right arm up-and-down on diagonal,
        // hips + knees bouncing to a 0.42s beat. 6 beats = 2.52s.
        guard let ra = node.childNode(withName: "pivot.arm.right", recursively: true) else { return }
        let up = SCNAction.rotateTo(x: -0.9, y: 0, z: -1.2, duration: 0.21)
        let down = SCNAction.rotateTo(x: 0.2, y: 0, z: -0.3, duration: 0.21)
        ra.runAction(.sequence([
            .repeat(.sequence([up, down]), count: 6),
            .rotateTo(x: 0, y: 0, z: 0, duration: 0.3)
        ]), forKey: "dance")
        // Left arm counter-swings.
        if let la = node.childNode(withName: "pivot.arm.left", recursively: true) {
            let up = SCNAction.rotateTo(x: 0.3, y: 0, z: 0.4, duration: 0.21)
            let down = SCNAction.rotateTo(x: -0.2, y: 0, z: 0.1, duration: 0.21)
            la.runAction(.sequence([
                .repeat(.sequence([up, down]), count: 6),
                .rotateTo(x: 0, y: 0, z: 0, duration: 0.3)
            ]), forKey: "dance")
        }
        // Legs alternate step lift.
        stepLegsAlternating(count: 6, beat: 0.21)
    }

    private func danceRobot() {
        // Mechanical staccato: sharp 90° arm locks, wait, snap to next.
        let beats: [(x: CGFloat, z: CGFloat)] = [
            (0.0, -1.2), (0.0, -0.6), (-1.0, -0.6), (-1.0, -1.4), (0.0, 0.0)
        ]
        guard let ra = node.childNode(withName: "pivot.arm.right", recursively: true) else { return }
        var seq: [SCNAction] = []
        for b in beats {
            let pose = SCNAction.rotateTo(x: b.x, y: 0, z: b.z, duration: 0.08)
            let hold = SCNAction.wait(duration: 0.32)
            seq.append(pose)
            seq.append(hold)
        }
        ra.runAction(.sequence(seq), forKey: "dance")
        // Head does 90° left/right snaps.
        if let h = headNode {
            let l = SCNAction.rotateTo(x: -0.08, y: -0.7, z: 0, duration: 0.08)
            let r = SCNAction.rotateTo(x: -0.08, y: 0.7, z: 0, duration: 0.08)
            let rest = SCNAction.rotateTo(x: -0.08, y: 0, z: 0, duration: 0.08)
            let hold = SCNAction.wait(duration: 0.32)
            h.runAction(.sequence([l, hold, r, hold, l, hold, rest]), forKey: "dance")
        }
    }

    private func danceShuffle() {
        // Melbourne shuffle foot pattern — quick alternating leg kicks.
        stepLegsAlternating(count: 10, beat: 0.15)
        // Arms swing loose at sides, slight up-and-down.
        for side in ["left", "right"] {
            guard let arm = node.childNode(withName: "pivot.arm.\(side)", recursively: true) else { continue }
            let up = SCNAction.rotateTo(x: -0.2, y: 0, z: side == "left" ? 0.3 : -0.3, duration: 0.15)
            let down = SCNAction.rotateTo(x: 0.0, y: 0, z: 0.0, duration: 0.15)
            arm.runAction(.sequence([
                .repeat(.sequence([up, down]), count: 10),
                .rotateTo(x: 0, y: 0, z: 0, duration: 0.2)
            ]), forKey: "dance")
        }
    }

    private func danceHeadbang() {
        guard let h = headNode else { return }
        let restX: CGFloat = -0.08
        let down = SCNAction.rotateTo(x: restX + 0.55, y: 0, z: 0, duration: 0.18)
        let up = SCNAction.rotateTo(x: restX - 0.1, y: 0, z: 0, duration: 0.18)
        h.runAction(.sequence([
            .repeat(.sequence([down, up]), count: 6),
            .rotateTo(x: restX, y: 0, z: 0, duration: 0.25)
        ]), forKey: "dance")
        // Arms pump out raised fists.
        for side in ["left", "right"] {
            guard let arm = node.childNode(withName: "pivot.arm.\(side)", recursively: true) else { continue }
            let u = SCNAction.rotateTo(x: -1.9, y: 0, z: 0, duration: 0.2)
            let d = SCNAction.rotateTo(x: -1.4, y: 0, z: 0, duration: 0.2)
            arm.runAction(.sequence([
                u,
                .repeat(.sequence([d, u]), count: 6),
                .rotateTo(x: 0, y: 0, z: 0, duration: 0.3)
            ]), forKey: "dance")
        }
    }

    private func stepLegsAlternating(count: Int, beat: Double) {
        for side in ["left", "right"] {
            guard let leg = node.childNode(withName: "pivot.leg.\(side)", recursively: true) else { continue }
            let phaseOffset = side == "left" ? beat : 0
            let kick = SCNAction.rotateTo(x: -0.4, y: 0, z: 0, duration: beat)
            let back = SCNAction.rotateTo(x: 0.2, y: 0, z: 0, duration: beat)
            leg.runAction(.sequence([
                .wait(duration: phaseOffset),
                .repeat(.sequence([kick, back]), count: count / 2),
                .rotateTo(x: 0, y: 0, z: 0, duration: 0.25)
            ]), forKey: "dance")
        }
    }

    // MARK: - Additional one-shot gestures

    /// Both arms up, whole body bounces. ~0.9s.
    func jump() {
        let up = SCNAction.moveBy(x: 0, y: 40, z: 0, duration: 0.25)
        up.timingMode = .easeOut
        let down = SCNAction.moveBy(x: 0, y: -40, z: 0, duration: 0.35)
        down.timingMode = .easeIn
        node.runAction(.sequence([up, down]), forKey: "jump")
        for side in ["left", "right"] {
            guard let arm = node.childNode(withName: "pivot.arm.\(side)", recursively: true) else { continue }
            let raise = SCNAction.rotateTo(x: -2.4, y: 0, z: 0, duration: 0.25)
            let lower = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.35)
            arm.runAction(.sequence([raise, lower]))
        }
    }

    /// 360° body rotation around Y. ~0.8s.
    func spin() {
        let turn = SCNAction.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 0.8)
        bodyNode.runAction(turn, forKey: "spin")
    }

    /// Two claps of the hands — meet at centre, back to sides.
    func clap() {
        guard
            let la = node.childNode(withName: "pivot.arm.left", recursively: true),
            let ra = node.childNode(withName: "pivot.arm.right", recursively: true)
        else { return }
        let lClose = SCNAction.rotateTo(x: -1.0, y: 0, z: 0.9, duration: 0.15)
        let lOpen = SCNAction.rotateTo(x: -0.6, y: 0, z: 0.5, duration: 0.12)
        let lRest = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.2)
        let rClose = SCNAction.rotateTo(x: -1.0, y: 0, z: -0.9, duration: 0.15)
        let rOpen = SCNAction.rotateTo(x: -0.6, y: 0, z: -0.5, duration: 0.12)
        let rRest = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.2)
        la.runAction(.sequence([lClose, lOpen, lClose, lRest]))
        ra.runAction(.sequence([rClose, rOpen, rClose, rRest]))
    }

    /// Right hand to forehead — military salute. ~0.8s.
    func salute() {
        let side = gestureArmSide()
        let s = gestureArmZSign(for: side)
        guard let ra = node.childNode(withName: "pivot.arm.\(side)", recursively: true) else { return }
        let up = SCNAction.rotateTo(x: -1.4, y: 0, z: -0.6 * s, duration: 0.25)
        up.timingMode = .easeOut
        let hold = SCNAction.wait(duration: 0.3)
        let rest = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.3)
        ra.runAction(.sequence([up, hold, rest]))
    }

    /// Both arms bent inward to flex biceps. ~1.1s hold.
    func flex() {
        guard
            let la = node.childNode(withName: "pivot.arm.left", recursively: true),
            let ra = node.childNode(withName: "pivot.arm.right", recursively: true),
            let le = node.childNode(withName: "pivot.elbow.left", recursively: true),
            let re = node.childNode(withName: "pivot.elbow.right", recursively: true)
        else { return }
        let lUp = SCNAction.rotateTo(x: -0.3, y: 0, z: 1.3, duration: 0.2)
        let rUp = SCNAction.rotateTo(x: -0.3, y: 0, z: -1.3, duration: 0.2)
        let elbow = SCNAction.rotateTo(x: 0, y: 0, z: -2.2, duration: 0.2)
        let elbowR = SCNAction.rotateTo(x: 0, y: 0, z: 2.2, duration: 0.2)
        let hold = SCNAction.wait(duration: 0.6)
        let rest = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.3)
        la.runAction(.sequence([lUp, hold, rest]))
        ra.runAction(.sequence([rUp, hold, rest]))
        le.runAction(.sequence([elbow, hold, rest]))
        re.runAction(.sequence([elbowR, hold, rest]))
    }

    /// Right hand to face — the classic facepalm. ~1s.
    func facepalm() {
        guard let ra = node.childNode(withName: "pivot.arm.right", recursively: true) else { return }
        let up = SCNAction.rotateTo(x: -1.9, y: 0, z: -0.3, duration: 0.28)
        up.timingMode = .easeIn
        let hold = SCNAction.wait(duration: 0.45)
        let rest = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.3)
        ra.runAction(.sequence([up, hold, rest]))
        if let h = headNode {
            let restX: CGFloat = -0.08
            let tilt = SCNAction.rotateTo(x: restX - 0.25, y: 0, z: 0, duration: 0.28)
            let back = SCNAction.rotateTo(x: restX, y: 0, z: 0, duration: 0.3)
            h.runAction(.sequence([tilt, hold, back]))
        }
    }

    /// One hand up with thumb extended — approval. ~0.8s hold.
    /// Side randomised so users don't always see the same arm.
    func thumbsUp() {
        let side = gestureArmSide()
        let s = gestureArmZSign(for: side)
        guard let ra = node.childNode(withName: "pivot.arm.\(side)", recursively: true) else { return }
        let up = SCNAction.rotateTo(x: -1.6, y: 0, z: -0.9 * s, duration: 0.22)
        up.timingMode = .easeOut
        let hold = SCNAction.wait(duration: 0.5)
        let rest = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.3)
        ra.runAction(.sequence([up, hold, rest]))
    }

    /// Slight forward hinge from the waist — theatrical bow. ~1.4s.
    func bow() {
        let fwd = SCNAction.rotateTo(x: 0.35, y: 0, z: 0, duration: 0.35)
        fwd.timingMode = .easeInEaseOut
        let hold = SCNAction.wait(duration: 0.5)
        let back = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.4)
        back.timingMode = .easeInEaseOut
        bodyNode.runAction(.sequence([fwd, hold, back]))
    }

    // MARK: - Phase E: general animations

    /// Big crouch, launch up, 360° tumble, land. ~1.6s.
    func backflip() {
        let crouch = SCNAction.moveBy(x: 0, y: -12, z: 0, duration: 0.18)
        crouch.timingMode = .easeIn
        let launch = SCNAction.moveBy(x: 0, y: 70, z: 0, duration: 0.28)
        launch.timingMode = .easeOut
        let fall = SCNAction.moveBy(x: 0, y: -58, z: 0, duration: 0.35)
        fall.timingMode = .easeIn
        node.runAction(.sequence([crouch, launch, fall]), forKey: "backflip")

        let tumble = SCNAction.rotateBy(x: -2 * .pi, y: 0, z: 0, duration: 0.60)
        tumble.timingMode = .easeInEaseOut
        let settle = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.2)
        bodyNode.runAction(.sequence([SCNAction.wait(duration: 0.18), tumble, settle]))
    }

    /// Toss invisible items in a looping rhythm — both hands alternate up.
    /// ~1.8s, three throws.
    func juggle() {
        guard
            let la = node.childNode(withName: "pivot.arm.left", recursively: true),
            let ra = node.childNode(withName: "pivot.arm.right", recursively: true)
        else { return }
        let upL = SCNAction.rotateTo(x: -1.5, y: 0, z: 0.3, duration: 0.18)
        let downL = SCNAction.rotateTo(x: -0.7, y: 0, z: 0.3, duration: 0.18)
        let upR = SCNAction.rotateTo(x: -1.5, y: 0, z: -0.3, duration: 0.18)
        let downR = SCNAction.rotateTo(x: -0.7, y: 0, z: -0.3, duration: 0.18)
        let rest = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.2)
        let cycleL = SCNAction.sequence([upL, downL])
        let cycleR = SCNAction.sequence([SCNAction.wait(duration: 0.18), upR, downR])
        la.runAction(.sequence([SCNAction.repeat(cycleL, count: 3), rest]))
        ra.runAction(.sequence([SCNAction.repeat(cycleR, count: 3), rest]))
    }

    /// Slide backward while appearing to walk forward — moonwalk. ~1.4s.
    func moonwalk() {
        let slide = SCNAction.moveBy(x: -90, y: 0, z: 0, duration: 1.2)
        slide.timingMode = .linear
        node.runAction(slide, forKey: "moonwalk")

        // Mini leg pumps — pivot the legs alternately without lifting so
        // it reads as walk-in-place.
        if let left = node.childNode(withName: "pivot.leg.left", recursively: true),
           let right = node.childNode(withName: "pivot.leg.right", recursively: true) {
            let leftUp = SCNAction.rotateTo(x: -0.25, y: 0, z: 0, duration: 0.2)
            let leftDown = SCNAction.rotateTo(x: 0.1, y: 0, z: 0, duration: 0.2)
            let rightUp = SCNAction.rotateTo(x: -0.25, y: 0, z: 0, duration: 0.2)
            let rightDown = SCNAction.rotateTo(x: 0.1, y: 0, z: 0, duration: 0.2)
            let rest = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.2)
            let leftCycle = SCNAction.sequence([leftUp, leftDown])
            let rightCycle = SCNAction.sequence([SCNAction.wait(duration: 0.2), rightUp, rightDown])
            left.runAction(.sequence([SCNAction.repeat(leftCycle, count: 3), rest]))
            right.runAction(.sequence([SCNAction.repeat(rightCycle, count: 3), rest]))
        }
    }

    /// Head rocks to the beat — four down/up cycles. ~1.4s.
    func headbang() {
        guard let h = headNode else { return }
        let restX: CGFloat = -0.08
        let down = SCNAction.rotateTo(x: restX + 0.45, y: 0, z: 0, duration: 0.12)
        let up = SCNAction.rotateTo(x: restX - 0.18, y: 0, z: 0, duration: 0.12)
        let rest = SCNAction.rotateTo(x: restX, y: 0, z: 0, duration: 0.18)
        let cycle = SCNAction.sequence([down, up])
        h.runAction(.sequence([SCNAction.repeat(cycle, count: 4), rest]))
    }

    /// Quick right-arm chop across body + "hi-YA" body pivot. ~0.9s.
    func karateChop() {
        guard let ra = node.childNode(withName: "pivot.arm.right", recursively: true) else { return }
        let wind = SCNAction.rotateTo(x: -1.7, y: 0, z: -1.1, duration: 0.14)
        wind.timingMode = .easeOut
        let chop = SCNAction.rotateTo(x: -0.3, y: 0, z: 0.7, duration: 0.12)
        chop.timingMode = .easeIn
        let rest = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.3)
        ra.runAction(.sequence([wind, chop, rest]))
        let pivot = SCNAction.rotateBy(x: 0, y: -0.35, z: 0, duration: 0.14)
        let back = SCNAction.rotateBy(x: 0, y: 0.35, z: 0, duration: 0.3)
        bodyNode.runAction(.sequence([pivot, back]))
    }

    /// Break-dance style: spin body while crouched. ~1.4s.
    func breakdance() {
        let crouch = SCNAction.moveBy(x: 0, y: -18, z: 0, duration: 0.18)
        let rise = SCNAction.moveBy(x: 0, y: 18, z: 0, duration: 0.22)
        let spin1 = SCNAction.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 0.55)
        let spin2 = SCNAction.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 0.35)
        bodyNode.runAction(.sequence([crouch, spin1, spin2, rise]), forKey: "breakdance")
    }

    // MARK: - Phase E: prop-aware animations

    /// Both hands bob at waist height as if typing — use with a laptop.
    /// ~1.4s, repeats.
    func typing() {
        guard
            let la = node.childNode(withName: "pivot.arm.left", recursively: true),
            let ra = node.childNode(withName: "pivot.arm.right", recursively: true)
        else { return }
        let dip = SCNAction.rotateTo(x: -0.85, y: 0, z: 0.25, duration: 0.14)
        let lift = SCNAction.rotateTo(x: -0.70, y: 0, z: 0.25, duration: 0.14)
        let rDip = SCNAction.rotateTo(x: -0.85, y: 0, z: -0.25, duration: 0.14)
        let rLift = SCNAction.rotateTo(x: -0.70, y: 0, z: -0.25, duration: 0.14)
        let rest = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.3)
        let cycleL = SCNAction.sequence([dip, lift])
        let cycleR = SCNAction.sequence([SCNAction.wait(duration: 0.07), rDip, rLift])
        la.runAction(.sequence([SCNAction.repeat(cycleL, count: 4), rest]))
        ra.runAction(.sequence([SCNAction.repeat(cycleR, count: 4), rest]))
    }

    /// Right arm strums across chest — use with a guitar. ~1.2s, 3 strums.
    func playGuitar() {
        guard let ra = node.childNode(withName: "pivot.arm.right", recursively: true) else { return }
        let down = SCNAction.rotateTo(x: -0.8, y: 0, z: -0.6, duration: 0.14)
        let up = SCNAction.rotateTo(x: -0.8, y: 0, z: -1.2, duration: 0.14)
        let rest = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.25)
        let cycle = SCNAction.sequence([down, up])
        ra.runAction(.sequence([SCNAction.repeat(cycle, count: 3), rest]))

        if let h = headNode {
            let restX: CGFloat = -0.08
            let bob = SCNAction.rotateTo(x: restX + 0.10, y: 0, z: 0, duration: 0.14)
            let up2 = SCNAction.rotateTo(x: restX - 0.10, y: 0, z: 0, duration: 0.14)
            let restH = SCNAction.rotateTo(x: restX, y: 0, z: 0, duration: 0.2)
            h.runAction(.sequence([SCNAction.repeat(.sequence([bob, up2]), count: 3), restH]))
        }
    }

    /// Lifts right arm to face, tilts head down, holds, lowers — use with a mug/cup.
    /// ~1.4s.
    func sip() {
        guard let ra = node.childNode(withName: "pivot.arm.right", recursively: true) else { return }
        let up = SCNAction.rotateTo(x: -2.2, y: 0, z: -0.2, duration: 0.28)
        up.timingMode = .easeOut
        let hold = SCNAction.wait(duration: 0.45)
        let down = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.35)
        down.timingMode = .easeIn
        ra.runAction(.sequence([up, hold, down]))

        if let h = headNode {
            let restX: CGFloat = -0.08
            let tilt = SCNAction.rotateTo(x: restX + 0.18, y: 0, z: 0, duration: 0.28)
            let back = SCNAction.rotateTo(x: restX, y: 0, z: 0, duration: 0.35)
            h.runAction(.sequence([tilt, hold, back]))
        }
    }

    /// Hold right arm in reading position, head tilts slightly down — use with a book.
    /// ~1.8s.
    func reading() {
        guard let ra = node.childNode(withName: "pivot.arm.right", recursively: true) else { return }
        let lift = SCNAction.rotateTo(x: -1.2, y: 0, z: -0.15, duration: 0.28)
        lift.timingMode = .easeOut
        let hold = SCNAction.wait(duration: 1.0)
        let down = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.35)
        down.timingMode = .easeIn
        ra.runAction(.sequence([lift, hold, down]))

        if let h = headNode {
            let restX: CGFloat = -0.08
            let tilt = SCNAction.rotateTo(x: restX + 0.12, y: 0, z: 0, duration: 0.28)
            let back = SCNAction.rotateTo(x: restX, y: 0, z: 0, duration: 0.35)
            h.runAction(.sequence([tilt, hold, back]))
        }
    }

    /// Raise phone to selfie position — use with a phone. ~1.2s.
    func takePhoto() {
        guard let ra = node.childNode(withName: "pivot.arm.right", recursively: true) else { return }
        let up = SCNAction.rotateTo(x: -1.6, y: 0, z: 0.0, duration: 0.22)
        up.timingMode = .easeOut
        let shake = SCNAction.rotateBy(x: 0, y: 0, z: 0.05, duration: 0.06)
        let shakeBack = SCNAction.rotateBy(x: 0, y: 0, z: -0.10, duration: 0.06)
        let shakeMid = SCNAction.rotateBy(x: 0, y: 0, z: 0.05, duration: 0.06)
        let hold = SCNAction.wait(duration: 0.3)
        let rest = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.3)
        ra.runAction(.sequence([up, hold, shake, shakeBack, shakeMid, rest]))
    }

    /// Body rears back as if lifting a front wheel — use while on a bike.
    /// ~1.2s.
    func popWheelie() {
        let back = SCNAction.rotateTo(x: -0.40, y: 0, z: 0, duration: 0.28)
        back.timingMode = .easeOut
        let hold = SCNAction.wait(duration: 0.45)
        let level = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.35)
        level.timingMode = .easeIn
        bodyNode.runAction(.sequence([back, hold, level]), forKey: "wheelie")

        // Small body lift to match the weight shift.
        let lift = SCNAction.moveBy(x: 0, y: 10, z: 0, duration: 0.28)
        let drop = SCNAction.moveBy(x: 0, y: -10, z: 0, duration: 0.35)
        node.runAction(.sequence([lift, hold, drop]))
    }

    // MARK: - Props

    /// A prop currently attached to the pet. Tracks the anchor so
    /// `holdProp` can enforce anchor-exclusivity (no two hats, no two
    /// props in the same hand, no single-hand prop while holding a
    /// both-hands prop, etc.).
    private struct HeldProp {
        let prop: Prop
        let anchor: PropAnchor
        let node: SCNNode
    }

    /// Currently-attached props keyed by Prop.rawValue. A prop can only
    /// exist in one anchor at a time, so keying by rawValue is unique.
    private var attachedProps: [String: HeldProp] = [:]

    /// Attach a prop at the given anchor. Any props currently occupying
    /// a conflicting anchor are removed first — e.g. adding a second hat
    /// drops the first, adding a two-handed guitar drops any single-hand
    /// prop. Exclusivity rules live on `PropAnchor.conflictingAnchors`
    /// so adding a new anchor updates one place. Silently accepts missing
    /// anchor nodes (e.g. "heldLeft" when no left hand exists).
    func holdProp(_ prop: Prop, at anchor: PropAnchor? = nil, args: [String: Any] = [:]) {
        let effectiveAnchor = anchor ?? prop.defaultAnchor
        let conflicts = effectiveAnchor.conflictingAnchors
        let evictKeys = attachedProps.compactMap { key, held in
            (conflicts.contains(held.anchor) || key == prop.rawValue) ? key : nil
        }
        for key in evictKeys {
            guard let held = attachedProps.removeValue(forKey: key) else { continue }
            removeHeld(held, animated: true)
        }
        guard let anchorNode = anchorNode(for: effectiveAnchor) else { return }
        let propNode = PropCatalog.build(prop, args: args)
        placeProp(propNode, prop: prop, at: effectiveAnchor, in: anchorNode)
        // Scale from zero so the prop pops into existence with a little bounce.
        propNode.scale = SCNVector3(0.01, 0.01, 0.01)
        anchorNode.addChildNode(propNode)
        let grow = SCNAction.scale(to: 1.0, duration: 0.22)
        grow.timingMode = .easeOut
        let bounce = SCNAction.scale(to: 0.9, duration: 0.08)
        bounce.timingMode = .easeIn
        let settle = SCNAction.scale(to: 1.0, duration: 0.10)
        settle.timingMode = .easeOut
        propNode.runAction(.sequence([grow, bounce, settle]), forKey: "prop.scale")
        attachedProps[prop.rawValue] = HeldProp(prop: prop, anchor: effectiveAnchor, node: propNode)
        reconcileHairForHatState()
    }

    func dropProp(_ prop: Prop) {
        guard let held = attachedProps[prop.rawValue] else { return }
        attachedProps.removeValue(forKey: prop.rawValue)
        removeHeld(held, animated: true)
        reconcileHairForHatState()
    }

    func dropAllProps() {
        let snapshot = attachedProps
        attachedProps.removeAll()
        for held in snapshot.values {
            removeHeld(held, animated: true)
        }
        reconcileHairForHatState()
    }

    /// Apply an NSImage as the diffuse texture for every material in a
    /// part group (suit / tie / shirt / shoe / hair / skin / etc). The
    /// image wraps via SceneKit's default UV mapping on primitive
    /// geometries — cylinders/boxes/spheres all get reasonable wrapping
    /// out of the box for texture-style fills. `wrapMode` clamps to
    /// `.repeat` so tiling patterns don't stretch.
    ///
    /// Returns the prior diffuse snapshot so the action dispatcher can
    /// wire ⌘Z via `restorePartMaterialContents`.
    @discardableResult
    func setPartTexture(_ partName: String, image: NSImage) -> [SCNMaterial: Any?]? {
        guard let nodes = partNodes[partName] else { return nil }
        var snap: [SCNMaterial: Any?] = [:]
        for node in nodes {
            guard let materials = node.geometry?.materials else { continue }
            for m in materials {
                snap[m] = m.diffuse.contents
                m.diffuse.contents = image
                m.diffuse.wrapS = .repeat
                m.diffuse.wrapT = .repeat
                // Slight metalness drop so textures read as fabric not
                // painted-on. Leave roughness as authored.
                m.metalness.contents = CGFloat(0.05)
            }
        }
        return snap
    }

    /// Restore a part's materials from a snapshot produced by
    /// `setPartTexture` OR `setPartColor` — the snapshot shape is the
    /// same ([material: prior diffuse contents]).
    func restorePartMaterialContents(_ snapshot: [SCNMaterial: Any?]) {
        for (material, prior) in snapshot {
            material.diffuse.contents = prior ?? NSColor.white
        }
    }

    /// Recolor every material on an attached prop's subtree. No-op when
    /// the prop isn't currently held. Returns the prior material snapshot
    /// so callers (action dispatcher) can wire ⌘Z — nil if no prop was
    /// actually recoloured.
    @discardableResult
    func setPropColor(_ prop: Prop, to color: NSColor) -> [SCNMaterial: Any?]? {
        guard let held = attachedProps[prop.rawValue] else { return nil }
        var snap: [SCNMaterial: Any?] = [:]
        held.node.enumerateHierarchy { node, _ in
            guard let materials = node.geometry?.materials else { return }
            for m in materials {
                snap[m] = m.diffuse.contents
                m.diffuse.contents = color
            }
        }
        return snap
    }

    /// Restore a prop recolour snapshot from `setPropColor`. Safe to call
    /// even if the prop has since been dropped — no-ops on unknown materials.
    func restorePropColor(_ snapshot: [SCNMaterial: Any?]) {
        for (material, prior) in snapshot {
            material.diffuse.contents = prior ?? NSColor.white
        }
    }

    /// True while any hat-style prop occupies the `aboveHead` anchor. Used
    /// to decide whether hair should be visible — tall hair (afro, mohawk,
    /// spikes) clips right through a hat otherwise, which reads as glitchy.
    private var isHatWorn: Bool {
        attachedProps.values.contains(where: { $0.anchor == .aboveHead && Self.isHat($0.prop) })
    }

    private static func isHat(_ prop: Prop) -> Bool {
        switch prop {
        case .baseball_cap, .top_hat, .cowboy_hat, .beanie, .crown,
             .party_hat, .wizard_hat, .hard_hat,
             .chef_hat, .military_helmet, .motorcycle_helmet,
             .pirate_hat, .astronaut_helmet, .ninja_headband:
            return true
        default:
            return false
        }
    }

    /// Show or hide all `part.hair.*` nodes based on whether a hat is
    /// currently worn. Called from every prop mutation + from
    /// `setHairStyle` after a fresh build so the hidden state survives a
    /// swap. `isHidden` on a parent hides its subtree, so this is cheap.
    func reconcileHairForHatState() {
        guard let head = headNode else { return }
        let hatOn = isHatWorn
        for child in head.childNodes where (child.name ?? "").hasPrefix("part.hair.") {
            child.isHidden = hatOn
        }
    }

    /// Cancels any in-flight scale animation and removes the node with a
    /// shrink-then-remove sequence so props always fade out consistently
    /// and can't collide with a stale grow animation when rapidly swapped.
    private func removeHeld(_ held: HeldProp, animated: Bool) {
        held.node.removeAction(forKey: "prop.scale")
        guard animated else {
            held.node.removeFromParentNode()
            return
        }
        let shrink = SCNAction.scale(to: 0.01, duration: 0.18)
        shrink.timingMode = .easeIn
        held.node.runAction(.sequence([shrink, .removeFromParentNode()]))
    }

    var currentlyHeldProps: [String] { Array(attachedProps.keys).sorted() }

    /// Map an anchor enum to the actual scene node it should parent under.
    /// Both arms expose `part.skin.hand` with the SAME name — a naive
    /// `childNode(withName:recursively:)` returns whichever hand was
    /// built first (usually the left). Always dive through the right/left
    /// pivot arm explicitly so the anchor lands on the intended side.
    private func anchorNode(for anchor: PropAnchor) -> SCNNode? {
        switch anchor {
        case .heldRight:
            if let rightArm = node.childNode(withName: "pivot.arm.right", recursively: true) {
                return rightArm.childNode(withName: "part.skin.hand", recursively: true) ?? rightArm
            }
            return bodyNode
        case .heldLeft:
            if let leftArm = node.childNode(withName: "pivot.arm.left", recursively: true) {
                return leftArm.childNode(withName: "part.skin.hand", recursively: true) ?? leftArm
            }
            return bodyNode
        case .heldBoth:
            return node.childNode(withName: "part.suit.torso", recursively: true) ?? bodyNode
        case .ridden, .leaningNearby:
            // Parented to the outer pet root, NOT bodyNode. Walking moves
            // the root so the bike/skateboard/ladder goes with Max, but
            // body-only animations (dance, wave, jitter, jump-crouch)
            // rotate bodyNode independently — attaching to bodyNode made
            // the bike swing around during those, reading as "glued to
            // him" rather than something he's riding.
            return node
        case .aboveHead:
            return headNode ?? bodyNode
        case .backMounted:
            // Torso-attached. Bobs with his body during dance/wave which
            // reads correctly for something worn on him (unlike ridden).
            return node.childNode(withName: "part.suit.torso", recursively: true) ?? bodyNode
        case .aroundNeck:
            // High on the torso, just under the chin. Parent to torso so
            // body movement carries it naturally.
            return node.childNode(withName: "part.suit.torso", recursively: true) ?? bodyNode
        case .onEars:
            // Parent to head — earrings should move when Max shakes his head.
            return headNode ?? bodyNode
        case .onWrist:
            // Right wrist is the expressive side; same hand props use that.
            // If the right arm isn't built, fall back to the torso.
            if let rightArm = node.childNode(withName: "pivot.arm.right", recursively: true) {
                return rightArm.childNode(withName: "part.skin.hand", recursively: true) ?? rightArm
            }
            return bodyNode
        case .onFinger:
            // Same hand as wrist.
            if let rightArm = node.childNode(withName: "pivot.arm.right", recursively: true) {
                return rightArm.childNode(withName: "part.skin.hand", recursively: true) ?? rightArm
            }
            return bodyNode
        case .onEye:
            // Parented to head so the patch swings with head movement.
            return headNode ?? bodyNode
        case .onFace:
            // Lower-face mask. Same anchor as the head so it tracks tilts /
            // shakes / nods. Placement (front of face, mid height) lives
            // in placeProp(_:at:in:).
            return headNode ?? bodyNode
        }
    }

    /// Position / rotate the fresh prop subtree inside its anchor.
    /// Scales baked into PropCatalog geometries are absolute pixels,
    /// so here we just apply placement offsets + orientation.
    private func placeProp(_ propNode: SCNNode, prop: Prop, at anchor: PropAnchor, in anchorNode: SCNNode) {
        switch anchor {
        case .heldRight:
            propNode.position = SCNVector3(6, 0, 4)
            propNode.eulerAngles = SCNVector3(0, 0, -0.2)
            if prop == .guitar {
                propNode.eulerAngles = SCNVector3(-0.4, 0, -1.2)
                propNode.position = SCNVector3(-10, -30, 15)
            }
        case .heldLeft:
            propNode.position = SCNVector3(-6, 0, 4)
            propNode.eulerAngles = SCNVector3(0, 0, 0.2)
        case .heldBoth:
            propNode.position = SCNVector3(0, 0, 20)
        case .ridden:
            // Skateboard goes under the feet; bike + other ridden props
            // need a positive z so they render in front of the character.
            if prop == .skateboard {
                propNode.position = SCNVector3(0, 0, 8)
            } else {
                propNode.position = SCNVector3(0, 0, 12)
            }
        case .leaningNearby:
            // Ladder leans ~20° to the pet's right, in front of the body.
            propNode.position = SCNVector3(80, 0, 10)
            if prop == .ladder {
                propNode.eulerAngles = SCNVector3(0, 0, -0.35)
            }
        case .aboveHead:
            // Hats sit on the head (face-box top ≈ y=35 from head origin).
            // Other above-head props (umbrella) float higher.
            let isHat = Self.isHat(prop)
            propNode.position = SCNVector3(0, isHat ? 33 : 55, 0)
        case .backMounted:
            // Snugged behind the torso, slightly above Max's shoulders
            // so the thruster ports peek over. Z negative = behind him.
            propNode.position = SCNVector3(0, 12, -20)
        case .aroundNeck:
            // High on the chest — top of the torso, front-facing.
            propNode.position = SCNVector3(0, 36, 12)
        case .onEars:
            // Placed at the sides of the head; the builder is responsible
            // for doubling the piece to both sides.
            propNode.position = SCNVector3(0, 0, 0)
        case .onWrist:
            // On the forearm just above the hand; in hand-local space.
            propNode.position = SCNVector3(0, 5, 0)
        case .onFinger:
            // On the hand itself; small offset forward so it's visible.
            propNode.position = SCNVector3(2, 0, 4)
        case .onEye:
            // Covers the right eye (viewer's left). Positioned forward so
            // it sits in front of the face rather than inside the skull.
            // Head is ~40 wide; right eye is at x ≈ 11.
            propNode.position = SCNVector3(11, 7, 20)
        case .onFace:
            // Centred over the lower face (nose + mouth area). Z=20
            // matches `.onEye` so masks sit on the same forward plane
            // as eye accessories. Y is below eye line.
            propNode.position = SCNVector3(0, -8, 20)
        }
    }

    // MARK: - Rag doll (gravity-off idle sway)

    private(set) var isRagDoll = false

    /// Start a gentle pendulum sway on arms, legs, and head. Each limb
    /// uses its own period/phase/amplitude so the result reads as slack
    /// floating rather than a synchronised dance. Called when gravity is
    /// turned off — runs until `stopRagDoll()` or another authored motion
    /// overrides these nodes. Walks will override rag-doll on the
    /// affected pivots for the duration of the walk; rag-doll resumes
    /// naturally once the repeat-forever custom-action ticks again.
    func startRagDoll() {
        guard !isRagDoll else { return }
        // Reduce-motion: skip the continuous sinusoidal sway entirely —
        // a vestibular-disorder user with the system flag set should not
        // see Max gently rocking forever. The flag is read live so a
        // mid-session toggle (Settings → Accessibility) takes effect on
        // the next gravity-off event without needing a relaunch.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || Prefs.sessionReduceMotion {
            isRagDoll = true   // mark so stopRagDoll() still runs the settle
            return
        }
        isRagDoll = true
        applyLimbSway(path: "pivot.arm.left",  amplitude: 0.22, period: 4.2, phase: 0.0)
        applyLimbSway(path: "pivot.arm.right", amplitude: 0.18, period: 3.7, phase: 1.1)
        applyLimbSway(path: "pivot.leg.left",  amplitude: 0.12, period: 5.3, phase: 2.4)
        applyLimbSway(path: "pivot.leg.right", amplitude: 0.10, period: 4.6, phase: 3.1)
        applyHeadSway()
    }

    /// Restart the ambient left/right headsway on `headNode`. Removes any
    /// existing "headsway" action first, then schedules a new
    /// repeatForever sequence on key "headsway". Called after rag-doll,
    /// gaze sessions, and anything else that overrides head rotation.
    private func restartHeadsway(on head: SCNNode) {
        head.removeAction(forKey: "headsway")
        let baseX: CGFloat = -0.08
        let left  = SCNAction.rotateTo(x: baseX, y: -0.035, z: 0, duration: 3.8)
        left.timingMode = .easeInEaseOut
        let right = SCNAction.rotateTo(x: baseX, y:  0.035, z: 0, duration: 3.8)
        right.timingMode = .easeInEaseOut
        head.runAction(.repeatForever(.sequence([left, right])), forKey: "headsway")
    }

    /// Stop rag-doll, ease each touched node back to its authored rest
    /// pose, and restore the ambient head-sway that rag-doll replaced.
    func stopRagDoll() {
        guard isRagDoll else { return }
        isRagDoll = false
        for name in ["pivot.arm.left", "pivot.arm.right", "pivot.leg.left", "pivot.leg.right"] {
            guard let n = node.childNode(withName: name, recursively: true) else { continue }
            n.removeAction(forKey: "ragdoll")
            let settle = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.35)
            settle.timingMode = .easeInEaseOut
            n.runAction(settle)
        }
        if let head = headNode {
            head.removeAction(forKey: "ragdoll.head")
            // Restore the authored forward-lean (-0.08 on X) and restart
            // the ambient idle headsway that rag-doll overrode.
            let settle = SCNAction.rotateTo(x: -0.08, y: 0, z: 0, duration: 0.35)
            settle.timingMode = .easeInEaseOut
            head.runAction(.sequence([settle, .run { @Sendable [weak self] _ in
                // SCNAction.run fires on SceneKit's presentation queue, not
                // main. Hop back via DispatchQueue.main and re-derive the
                // node from self.headNode — sending the captured SCNNode
                // across actor boundaries isn't safe under strict mode, but
                // the MainActor always has a live ref to the same node.
                DispatchQueue.main.async { [weak self] in
                    guard let self, let h = self.headNode else { return }
                    self.restartHeadsway(on: h)
                }
            }]))
        }
    }

    private func applyLimbSway(path: String, amplitude: CGFloat, period: Double, phase: Double) {
        guard let pivot = node.childNode(withName: path, recursively: true) else { return }
        pivot.removeAction(forKey: "ragdoll")
        let action = SCNAction.customAction(duration: period) { node, t in
            let tau = Double(t) / period * 2 * .pi
            node.eulerAngles.z = amplitude * CGFloat(sin(tau + phase))
        }
        pivot.runAction(.repeatForever(action), forKey: "ragdoll")
    }

    private func applyHeadSway() {
        guard let head = headNode else { return }
        head.removeAction(forKey: "headsway")
        head.removeAction(forKey: "ragdoll.head")
        let period: Double = 4.5
        let ampX: CGFloat = 0.06
        let ampZ: CGFloat = 0.10
        let phaseX = 0.5
        let phaseZ = 1.8
        let restX: CGFloat = -0.08
        let action = SCNAction.customAction(duration: period) { n, t in
            let tau = Double(t) / period * 2 * .pi
            n.eulerAngles.x = restX + ampX * CGFloat(sin(tau + phaseX))
            n.eulerAngles.z = ampZ * CGFloat(sin(tau + phaseZ))
        }
        head.runAction(.repeatForever(action), forKey: "ragdoll.head")
    }

    /// Currently-applied physique. Exposes enough state for the undo stack
    /// and for the agent to decide whether a change is a no-op.
    private(set) var currentPhysique: Physique = .default
    /// Y-axis scale per face morph feature, keyed by raw name. Missing
    /// means "rest (1.0)".
    private(set) var faceMorphValues: [String: CGFloat] = [:]

    func setPhysique(_ physique: Physique) {
        bodyNode.scale = physique.bodyScale
        currentPhysique = physique
    }

    /// Scale a single facial feature on its Y axis. `value` is clamped to
    /// [0.5, 1.5]; 1.0 resets the feature. When the feature overlaps an
    /// expression-animated node (e.g. brows), we re-index rest positions so
    /// future expression transitions animate FROM the morphed baseline
    /// rather than snapping it back to the authored rest on the next pose
    /// change.
    func setFaceMorph(feature: FaceMorphFeature, value: CGFloat) {
        let clamped = max(0.5, min(1.5, value))
        for name in feature.targetNodeNames {
            guard let n = node.childNode(withName: name, recursively: true) else { continue }
            let s = n.scale
            n.scale = SCNVector3(s.x, clamped, s.z)
        }
        faceMorphValues[feature.rawValue] = clamped
        if feature.targetNodeNames.contains(where: expressionAllKeys.contains) {
            let changed = Set(feature.targetNodeNames)
            reindexAfterAppearanceChange { changed.contains($0) }
        }
    }

    func setFacialHair(_ style: FacialHair) {
        guard let form = form as? HeadStyleCustomizable,
              let head = headNode
        else { return }
        for child in head.childNodes where (child.name ?? "").hasPrefix("part.facial.") {
            child.removeFromParentNode()
        }
        for n in style.buildNodes(context: form.headStyleContext) {
            head.addChildNode(n)
        }
        currentFacialHair = style
        reindexAfterAppearanceChange { $0.hasPrefix("part.facial.") }
    }

    /// Restore every indexed part to its original diffuse color.
    func resetColors() {
        for (part, materials) in partMaterials {
            guard let originals = originalPartColors[part] else { continue }
            for (i, m) in materials.enumerated() where i < originals.count {
                m.diffuse.contents = originals[i]
            }
        }
    }

    // MARK: - Undo-support snapshots
    //
    // Capture current diffuse contents (not factory defaults) so the undo
    // stack can revert a mutation to whatever colour was live before it.

    typealias PartMaterialSnapshot = [Any?]
    typealias AllPartsMaterialSnapshot = [String: [Any?]]

    func capturePartMaterialContents(part: String) -> PartMaterialSnapshot? {
        guard let materials = partMaterials[part] else { return nil }
        return materials.map { $0.diffuse.contents }
    }

    func restorePartMaterialContents(part: String, contents: PartMaterialSnapshot) {
        guard let materials = partMaterials[part] else { return }
        for (i, m) in materials.enumerated() where i < contents.count {
            m.diffuse.contents = contents[i]
        }
    }

    func captureAllPartMaterialContents() -> AllPartsMaterialSnapshot {
        var snap: AllPartsMaterialSnapshot = [:]
        for (part, materials) in partMaterials {
            snap[part] = materials.map { $0.diffuse.contents }
        }
        return snap
    }

    func restoreAllPartMaterialContents(_ snap: AllPartsMaterialSnapshot) {
        for (part, contents) in snap {
            guard let materials = partMaterials[part] else { continue }
            for (i, m) in materials.enumerated() where i < contents.count {
                m.diffuse.contents = contents[i]
            }
        }
    }

    // MARK: - Binding primitives
    // Called by the BindingEngine when telemetry events match a binding.

    /// Briefly tint a part, then revert to its original color.
    func flashPart(_ partName: String, to color: NSColor, duration: TimeInterval) {
        guard let mats = partMaterials[partName] else { return }
        let originals = mats.map { $0.diffuse.contents }
        for m in mats { m.diffuse.contents = color }
        let d = max(0.05, min(3.0, duration))
        DispatchQueue.main.asyncAfter(deadline: .now() + d) {
            for (i, m) in mats.enumerated() where i < originals.count {
                m.diffuse.contents = originals[i]
            }
        }
    }

    /// Brief color pulse. Currently implemented as a fast flash; future work
    /// can render an expanding glow shell.
    func ripplePart(_ partName: String, color: NSColor, duration: TimeInterval) {
        flashPart(partName, to: color, duration: min(0.25, duration))
    }

    /// One scale-up/down cycle on the part's nodes. Amplitude is fractional
    /// (0.05 = ±5%). Clamped to sane range.
    ///
    /// **Drift fix.** Earlier this used `SCNAction.scale(by:)` — relative
    /// multiplier. Each pulse did × 1.05 up then × 1/1.05 down, which
    /// round-trips perfectly *if* the down step finishes. Pulses are
    /// keyed `binding.pulse`, so a new pulse arriving before the
    /// previous one's down-step replaces the action and the down never
    /// runs. The node stays at × 1.05 permanently. Over many telemetry-
    /// driven pulses (entropy / hesitation signals can fire at 20 Hz)
    /// the scale compounds exponentially — at 1.05 per fire that's
    /// ×7 in 40 fires, ×50 in 80 fires. User saw arms "huge and wide,
    /// down to legs" because the bound part's scale ratchetted up and
    /// never came back down.
    ///
    /// Now: capture each node's canonical rest scale on first pulse,
    /// stored in `pulseRestScales`. Every cycle animates to absolute
    /// `rest × (1+amp)` then back to absolute `rest`. Interrupts can't
    /// drift — the next cycle's TO targets the recorded rest, not the
    /// current scale.
    func pulsePart(_ partName: String, amplitude: CGFloat) {
        guard let nodes = partNodes[partName] else { return }
        let amp = max(0, min(0.5, amplitude))
        guard amp > 0.001 else { return }
        for n in nodes {
            let key = ObjectIdentifier(n)
            // Capture canonical rest the FIRST time we ever pulse this
            // node. Subsequent calls reuse it. If a previous pulse
            // drifted the node up, the very first capture might lock
            // in that drift — but in practice pulsePart is called
            // before any other scale modifier on these binding-target
            // parts, so the capture happens at true rest.
            let rest: SCNVector3
            if let cached = pulseRestScales[key] {
                rest = cached
            } else {
                rest = n.scale
                pulseRestScales[key] = rest
            }
            let up = SCNAction.scale(
                to: CGFloat(rest.x) * (1.0 + amp),
                duration: 0.12
            )
            up.timingMode = .easeOut
            let down = SCNAction.scale(
                to: CGFloat(rest.x),
                duration: 0.18
            )
            down.timingMode = .easeIn
            // Per-axis scale-to isn't a single SCNAction, so for non-
            // uniform rest scales we'd need a custom action. Body parts
            // bound by pulse (suit, sleeves, head, etc.) all sit at
            // uniform rest scale, so the uniform scale-to(to: x) above
            // is correct in practice. If we ever expose pulse on a
            // non-uniformly-scaled part, swap to a customAction.
            n.runAction(.sequence([up, down]), forKey: "binding.pulse")
        }
    }
    /// Canonical rest scale per pulse-target node, captured lazily on
    /// first call. Pulse cycles always animate to/from this value so
    /// interrupts can't accumulate drift. Keyed by node identity so
    /// the table stays bounded and follows node lifetime.
    private var pulseRestScales: [ObjectIdentifier: SCNVector3] = [:]

    /// Quick twist-and-return — chains into continuous jitter when called
    /// at high frequency (e.g. from token.hesitation at 20Hz).
    func shakePart(_ partName: String, amplitude: CGFloat) {
        guard let nodes = partNodes[partName] else { return }
        let amp = max(0, min(0.3, amplitude))
        guard amp > 0.001 else { return }
        for n in nodes {
            let angle = CGFloat.random(in: -amp...amp)
            let seq = SCNAction.sequence([
                SCNAction.rotateBy(x: 0, y: angle, z: 0, duration: 0.04),
                SCNAction.rotateBy(x: 0, y: -angle, z: 0, duration: 0.08)
            ])
            n.runAction(seq, forKey: "binding.shake")
        }
    }

    /// Lerp each material's diffuse color from its original toward `target`
    /// by `amount` in [0, 1]. amount=0 reverts, amount=1 fully targets.
    func tintPart(_ partName: String, toward target: NSColor, amount: CGFloat) {
        guard let mats = partMaterials[partName] else { return }
        guard let origs = originalPartColors[partName] else { return }
        let a = max(0, min(1, amount))
        for (i, m) in mats.enumerated() where i < origs.count {
            guard let from = origs[i] as? NSColor,
                  let blended = Self.lerpColor(from: from, to: target, amount: a) else { continue }
            m.diffuse.contents = blended
        }
    }

    /// Rotate the part's nodes on Z to the given angle (radians).
    func tiltPart(_ partName: String, amount: CGFloat) {
        guard let nodes = partNodes[partName] else { return }
        let a = max(-0.6, min(0.6, amount))
        for n in nodes {
            let action = SCNAction.rotateTo(x: 0, y: 0, z: a, duration: 0.18)
            action.timingMode = .easeInEaseOut
            n.runAction(action, forKey: "binding.tilt")
        }
    }

    /// Set the part's emission intensity [0, 1] — makes it glow.
    func brightnessPart(_ partName: String, intensity: CGFloat) {
        guard let mats = partMaterials[partName] else { return }
        let v = max(0, min(1, intensity))
        for m in mats {
            m.emission.contents = NSColor(calibratedWhite: v, alpha: 1.0)
        }
    }

    private static func lerpColor(from: NSColor, to: NSColor, amount: CGFloat) -> NSColor? {
        guard
            let f = from.usingColorSpace(.sRGB),
            let t = to.usingColorSpace(.sRGB)
        else { return nil }
        let r = f.redComponent + (t.redComponent - f.redComponent) * amount
        let g = f.greenComponent + (t.greenComponent - f.greenComponent) * amount
        let b = f.blueComponent + (t.blueComponent - f.blueComponent) * amount
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    // MARK: - Agent-triggered movements

    /// Walk a given distance in the given direction. Used by agent actions.
    func walkDirection(_ direction: String, distance: CGFloat) {
        let currentX = CGFloat(node.presentation.position.x)
        let delta: CGFloat
        switch direction.lowercased() {
        case "left":  delta = -abs(distance)
        case "right": delta =  abs(distance)
        default: return
        }
        let targetX = currentX + delta
        face(right: delta > 0)
        let duration = max(0.8, Double(abs(delta) / 70))
        moveTo(x: targetX, y: form.baseY, duration: duration)
    }

    /// One-off jitter on demand (separate from the periodic schedule).
    func manualJitter() {
        let target = headNode ?? bodyNode
        let angle = CGFloat.random(in: -0.08...0.08)
        let twist = SCNAction.rotateBy(x: 0, y: angle, z: 0, duration: 0.18)
        twist.timingMode = .easeOut
        let untwist = SCNAction.rotateBy(x: 0, y: -angle, z: 0, duration: 0.30)
        untwist.timingMode = .easeIn
        target.runAction(.sequence([twist, untwist]), forKey: "jitter")
    }

    /// Smoothly scale the root (grow or shrink).
    func setRootScale(_ scale: CGFloat) {
        let action = SCNAction.scale(to: Double(scale), duration: 0.35)
        action.timingMode = .easeInEaseOut
        node.runAction(action, forKey: "rootScale")
    }

    // MARK: - Blink idle

    private var blinkActive: Bool = false

    func startPeriodicBlink() {
        guard !blinkActive else { return }
        blinkActive = true
        scheduleBlink()
    }

    func stopPeriodicBlink() {
        blinkActive = false
    }

    private func scheduleBlink() {
        guard blinkActive else { return }
        let delay = TimeInterval.random(in: 3.0...6.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.performBlink()
            self?.scheduleBlink()
        }
    }

    private func performBlink() {
        // Scale eye sclera Y down then back — quick half-second close.
        // The pupil is a child of the eye node, so it blinks with it.
        let lensNodes = [
            node.childNode(withName: "part.eye.left", recursively: true),
            node.childNode(withName: "part.eye.right", recursively: true)
        ].compactMap { $0 }
        guard !lensNodes.isEmpty else { return }

        for lens in lensNodes {
            let currentScale = lens.scale
            let close = SCNAction.customAction(duration: 0.08) { n, t in
                let p = min(1, t / 0.08)
                let ease = sin(p * .pi * 0.5)  // half-sine ease-out
                n.scale = SCNVector3(
                    currentScale.x,
                    currentScale.y * (1.0 - 0.88 * ease),
                    currentScale.z
                )
            }
            let reopen = SCNAction.customAction(duration: 0.12) { n, t in
                let p = min(1, t / 0.12)
                let ease = sin(p * .pi * 0.5)
                n.scale = SCNVector3(
                    currentScale.x,
                    currentScale.y * (0.12 + 0.88 * ease),
                    currentScale.z
                )
            }
            lens.runAction(.sequence([close, reopen]), forKey: "blink")
        }
    }

    // MARK: - Pupil tracking

    /// Shift both pupils toward the cursor. dx/dy are screen-space pixels
    /// from Max's centre to the cursor. Called by CursorGazeController
    /// alongside gazeAtOffset so pupils and head track together.
    func setPupilOffset(dx: CGFloat, dy: CGFloat) {
        // dx/dy are screen-space pixels from pet center to cursor
        let x = max(-4.0, min(4.0,  dx / 80.0))
        let y = max(-3.0, min(3.0, -dy / 80.0))  // inverted: screen up = +y in scene
        for name in ["part.pupil.left", "part.pupil.right"] {
            guard let pupil = node.childNode(withName: name, recursively: true) else { continue }
            let target = SCNVector3(x, y, pupil.position.z)
            let action = SCNAction.move(to: target, duration: 0.12)
            action.timingMode = .easeOut
            pupil.runAction(action, forKey: "pupilMove")
        }
    }

    /// Return both pupils to the resting (centered) position.
    func resetPupils() {
        for name in ["part.pupil.left", "part.pupil.right"] {
            guard let pupil = node.childNode(withName: name, recursively: true) else { continue }
            let action = SCNAction.move(to: SCNVector3(0, 0, pupil.position.z), duration: 0.25)
            action.timingMode = .easeOut
            pupil.runAction(action, forKey: "pupilMove")
        }
    }

    // MARK: - Idle pupil drift

    private var pupilDriftActive = false

    func startIdlePupilDrift() {
        guard !pupilDriftActive else { return }
        pupilDriftActive = true
        schedulePupilDrift()
    }

    func stopIdlePupilDrift() {
        pupilDriftActive = false
    }

    private func schedulePupilDrift() {
        guard pupilDriftActive else { return }
        let delay = TimeInterval.random(in: 1.5...4.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pupilDriftActive else { return }
            self.performPupilDrift()
            self.schedulePupilDrift()
        }
    }

    private func performPupilDrift() {
        let x = CGFloat.random(in: -3.5...3.5)
        let y = CGFloat.random(in: -2.5...2.5)
        for name in ["part.pupil.left", "part.pupil.right"] {
            guard let pupil = node.childNode(withName: name, recursively: true) else { continue }
            let action = SCNAction.move(to: SCNVector3(x, y, pupil.position.z), duration: 0.2)
            action.timingMode = .easeInEaseOut
            pupil.runAction(action, forKey: "pupilDrift")
        }
    }

    // MARK: - Procedural jitter (broadcaster-style stutter)

    private var jitterActive: Bool = false

    func startPeriodicJitter() {
        guard !jitterActive else { return }
        jitterActive = true
        scheduleJitter()
    }

    func stopPeriodicJitter() {
        jitterActive = false
    }

    var isPeriodicJitterActive: Bool { jitterActive }

    private func scheduleJitter() {
        guard jitterActive else { return }
        let delay = TimeInterval.random(in: 3.0...7.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.performJitter()
            self?.scheduleJitter()
        }
    }

    private func performJitter() {
        // Smoother than the snappy 0.04s twitch — eased ~0.5s round-trip.
        // Target head if the Form exposes one so the stutter feels localized.
        let target = headNode ?? bodyNode
        let angle = CGFloat.random(in: -0.05...0.05)
        let twist = SCNAction.rotateBy(x: 0, y: angle, z: 0, duration: 0.22)
        twist.timingMode = .easeOut
        let untwist = SCNAction.rotateBy(x: 0, y: -angle, z: 0, duration: 0.35)
        untwist.timingMode = .easeIn
        target.runAction(.sequence([twist, untwist]), forKey: "jitter")
    }

    // MARK: - Rigged-mesh animation control

    func startWalkAnimation() {
        guard !isWalkAnimPlaying else { return }
        isWalkAnimPlaying = true
        forEachAnimationPlayer { $0.play() }
    }

    func stopWalkAnimation() {
        guard isWalkAnimPlaying else { return }
        isWalkAnimPlaying = false
        forEachAnimationPlayer { $0.stop() }
    }

    private func forEachAnimationPlayer(_ block: (SCNAnimationPlayer) -> Void) {
        node.enumerateHierarchy { n, _ in
            for key in n.animationKeys {
                if let player = n.animationPlayer(forKey: key) {
                    block(player)
                }
            }
        }
    }

    // MARK: - Procedural idle actions

    /// Brief body turn with a hold and return. Used for idle variety when
    /// the pet isn't walking. No rigged animation required.
    func lookAround() {
        let amount = CGFloat.random(in: 0.12...0.22) * (Bool.random() ? 1 : -1)
        let turn = SCNAction.rotateTo(x: 0, y: amount, z: 0, duration: 0.9)
        turn.timingMode = .easeInEaseOut
        let hold = SCNAction.wait(duration: 1.6)
        let back = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.9)
        back.timingMode = .easeInEaseOut
        bodyNode.runAction(.sequence([turn, hold, back]), forKey: "lookAround")
    }

    /// Tilt the head to look toward an offset (screen-space dx/dy from Max's
    /// centre). Called at ~10 Hz by CursorGazeController. Uses the headNode
    /// so the body stays planted; the action key "cursorGaze" is overwritten
    /// on each tick so only the latest target matters.
    func gazeAtOffset(dx: CGFloat, dy: CGFloat) {
        guard let head = headNode else { return }
        // Stop headsway so it doesn't fight the cursorGaze rotation.
        head.removeAction(forKey: "headsway")
        // dy > 0 means cursor is above Max → look up → negative X in SceneKit.
        let yaw   = max(-0.35, min(0.35,  dx / 480.0))
        let pitch = max(-0.22, min(0.28, -dy / 560.0))
        let action = SCNAction.rotateTo(x: pitch, y: yaw, z: 0, duration: 0.28)
        action.timingMode = .easeInEaseOut
        head.runAction(action, forKey: "cursorGaze")
    }

    /// Return the head to the authored forward-lean (-0.08 on X) after a
    /// gaze session ends, then restart the ambient headsway.
    func endCursorGaze() {
        guard let head = headNode else { return }
        head.removeAction(forKey: "cursorGaze")
        let settle = SCNAction.rotateTo(x: -0.08, y: 0, z: 0, duration: 0.5)
        settle.timingMode = .easeInEaseOut
        head.runAction(.sequence([settle, .run { @Sendable [weak self] _ in
            // See `rampDownRagdoll` — SCNAction.run is off-main. Hop back
            // and re-derive the head node from self rather than sending
            // the captured SCNNode ref across actor boundaries.
            DispatchQueue.main.async { [weak self] in
                guard let self, let h = self.headNode else { return }
                self.restartHeadsway(on: h)
            }
        }]), forKey: "cursorGaze")
    }

    /// Cheap visual lipsync — one quick open-then-close of the mouth.
    /// Driven by AVSpeechSynthesizer's word-boundary delegate on the
    /// VoiceEngine. Scales the currently-visible mouth shape + teeth
    /// row briefly. No real phoneme tracking in v1 — just a flap that
    /// pulses with speech rhythm.
    ///
    /// Uses absolute `scale(to:)` targets so a new speech burst
    /// interrupting this one via the `mouthBounce` key ALWAYS settles
    /// back to scale 1.0, even if cancelled mid-sequence. The old
    /// `scale(by:)` variant compounded multiplicatively on every
    /// cancel-and-restart and shrank the mouth toward invisible over
    /// long conversations — reliable "expression looks frozen" bug.
    ///
    /// Since the expression system swaps which `part.mouth.*` node is
    /// visible, we animate whichever shape is currently not hidden
    /// instead of a hard-coded `part.mouth.arc` — otherwise when Max
    /// smiles or frowns, the teeth would bounce but the lip shape
    /// wouldn't.
    func mouthBounce() {
        var targets: [SCNNode] = []
        if let teeth = node.childNode(withName: "part.teeth.row", recursively: true) {
            targets.append(teeth)
        }
        if let visible = currentMouthShapeNode() {
            targets.append(visible)
        }
        guard !targets.isEmpty else { return }

        for target in targets {
            let open = SCNAction.scale(to: 0.82, duration: 0.06)
            open.timingMode = .easeOut
            let close = SCNAction.scale(to: 1.0, duration: 0.10)
            close.timingMode = .easeIn
            target.runAction(.sequence([open, close]), forKey: "mouthBounce")
        }
    }

    /// Swap the visible mouth shape. Called by `poseExpression` after
    /// the pose delta is applied. Hides every `part.mouth.<shape>`
    /// sibling except the target; cheap (at most 5 isHidden flips).
    func setMouthShape(_ name: String) {
        let target = "part.mouth.\(name)"
        let shapeNames = ["part.mouth.arc", "part.mouth.smile",
                          "part.mouth.frown", "part.mouth.open",
                          "part.mouth.flat"]
        for n in shapeNames {
            guard let node = self.node.childNode(withName: n, recursively: true) else { continue }
            node.isHidden = (n != target)
        }
    }

    /// Find whichever `part.mouth.<shape>` node is currently visible.
    /// Used by lipsync so the animating node matches the expression's
    /// current mouth shape. Falls back to `.arc` (the original name)
    /// if no shape node is found — keeps Forms that never adopt the
    /// multi-shape mouth working.
    private func currentMouthShapeNode() -> SCNNode? {
        let shapeNames = ["part.mouth.arc", "part.mouth.smile",
                          "part.mouth.frown", "part.mouth.open",
                          "part.mouth.flat"]
        for n in shapeNames {
            if let node = self.node.childNode(withName: n, recursively: true),
               !node.isHidden {
                return node
            }
        }
        return self.node.childNode(withName: "part.mouth.arc", recursively: true)
    }

    // MARK: - Gestures
    //
    // Transient full-body gestures — wave, shrug, nod, shake. Each runs
    // self-returning SCNActions on specific parts. Safe to call at any
    // time; if interrupted by another gesture the next one takes over
    // (forKey keys prevent stack-up).

    /// Returns a random side ("left" or "right") for single-arm gestures.
    /// Most single-arm functions used to hardcode "right" which made
    /// one-sidedness obvious to the user — they'd notice the same arm
    /// always animating. Randomising per call gives organic variety.
    /// Bilateral gestures (dance, walk, shrug) keep their explicit
    /// side semantics; this helper is for wave / beckon / point /
    /// salute / thumbs_up where either arm reads naturally.
    private func gestureArmSide() -> String {
        Bool.random() ? "left" : "right"
    }

    /// Sign multiplier for shoulder/elbow Z rotations so a left-arm
    /// gesture mirrors the right-arm version (same outward swing
    /// direction relative to the body's centerline).
    private func gestureArmZSign(for side: String) -> CGFloat {
        side == "right" ? 1 : -1
    }

    func wave() {
        // Wave uses BOTH the shoulder and the elbow. Shoulder lifts the
        // upper arm overhead; elbow bends so the forearm is vertical
        // (like holding up a hand); hand oscillates via elbow Z rotation.
        // Side randomised per call — prior hardcoded right produced the
        // visible "only one arm moves" complaint.
        let side = gestureArmSide()
        let s = gestureArmZSign(for: side)
        guard
            let shoulder = node.childNode(withName: "pivot.arm.\(side)", recursively: true),
            let elbow = node.childNode(withName: "pivot.elbow.\(side)", recursively: true)
        else { return }

        // Shoulder: lift up and outward (away from torso center), hold, relax.
        let shoulderLift = SCNAction.rotateTo(x: 0, y: 0, z: 1.6 * s, duration: 0.32)
        shoulderLift.timingMode = .easeOut
        let shoulderHold = SCNAction.wait(duration: 1.25)
        let shoulderRelax = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.45)
        shoulderRelax.timingMode = .easeInEaseOut
        shoulder.runAction(
            .sequence([shoulderLift, shoulderHold, shoulderRelax]),
            forKey: "gesture"
        )

        // Elbow: wait for the shoulder to lift first, then bend forearm
        // up, oscillate side-to-side for the wave, then relax.
        let elbowDelay = SCNAction.wait(duration: 0.3)
        let elbowBend = SCNAction.rotateTo(x: 0, y: 0, z: -1.35 * s, duration: 0.22)
        elbowBend.timingMode = .easeOut
        let waveA = SCNAction.rotateBy(x: 0, y: 0, z: 0.35 * s, duration: 0.16)
        waveA.timingMode = .easeInEaseOut
        let waveB = SCNAction.rotateBy(x: 0, y: 0, z: -0.35 * s, duration: 0.16)
        waveB.timingMode = .easeInEaseOut
        let elbowRelax = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.38)
        elbowRelax.timingMode = .easeInEaseOut
        elbow.runAction(
            .sequence([elbowDelay, elbowBend, waveA, waveB, waveA, waveB, elbowRelax]),
            forKey: "gesture"
        )
    }

    /// "Come here." Shoulder to horizontal, elbow bends hard to bring
    /// the hand close to the body, then elbow oscillates on X to
    /// suggest a curling palm summoning motion.
    func beckon() {
        let side = gestureArmSide()
        let s = gestureArmZSign(for: side)
        guard
            let shoulder = node.childNode(withName: "pivot.arm.\(side)", recursively: true),
            let elbow = node.childNode(withName: "pivot.elbow.\(side)", recursively: true)
        else { return }

        let shoulderLift = SCNAction.rotateTo(x: 0, y: 0, z: 1.25 * s, duration: 0.28)
        shoulderLift.timingMode = .easeOut
        let shoulderHold = SCNAction.wait(duration: 1.35)
        let shoulderRelax = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.4)
        shoulderRelax.timingMode = .easeInEaseOut
        shoulder.runAction(
            .sequence([shoulderLift, shoulderHold, shoulderRelax]),
            forKey: "gesture"
        )

        let elbowDelay = SCNAction.wait(duration: 0.22)
        let elbowBend = SCNAction.rotateTo(x: -0.9, y: 0, z: -1.2 * s, duration: 0.2)
        elbowBend.timingMode = .easeOut
        let curlIn  = SCNAction.rotateBy(x: -0.35, y: 0, z: 0, duration: 0.18)
        curlIn.timingMode = .easeInEaseOut
        let curlOut = SCNAction.rotateBy(x:  0.35, y: 0, z: 0, duration: 0.22)
        curlOut.timingMode = .easeInEaseOut
        let elbowRelax = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.35)
        elbowRelax.timingMode = .easeInEaseOut
        elbow.runAction(
            .sequence([elbowDelay, elbowBend, curlIn, curlOut, curlIn, curlOut, elbowRelax]),
            forKey: "gesture"
        )
    }

    /// "Look at this." Raises one arm vertically with the forearm
    /// angled forward — reads as "indicating up-and-out" rather than
    /// the previous straight-arm-forward pose, which read as a
    /// fascist / Roman salute (especially on the left arm). The
    /// original silhouette was `x: -1.5, z: 0.15` (arm extended
    /// ~86° forward, no elbow bend); now the shoulder rotates to
    /// near-vertical (x: -2.3) and the elbow flexes the forearm
    /// forward, so the gesture reads as a clear raised-hand-with-
    /// point.
    func pointForward() {
        let side = gestureArmSide()
        let s = gestureArmZSign(for: side)
        guard
            let shoulder = node.childNode(withName: "pivot.arm.\(side)", recursively: true),
            let elbow = node.childNode(withName: "pivot.elbow.\(side)", recursively: true)
        else { return }
        // Shoulder: lift the upper arm to near-vertical (slightly
        // outward via z so the elbow is the apex of the silhouette).
        let shoulderUp = SCNAction.rotateTo(x: -2.3, y: 0, z: 0.25 * s, duration: 0.35)
        shoulderUp.timingMode = .easeOut
        let shoulderHold = SCNAction.wait(duration: 0.7)
        let shoulderRelax = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.45)
        shoulderRelax.timingMode = .easeInEaseOut
        shoulder.runAction(
            .sequence([shoulderUp, shoulderHold, shoulderRelax]),
            forKey: "gesture"
        )
        // Elbow: bend forearm forward (toward camera) so the gesture
        // says "look at this thing in front of me" not just "I have
        // a question." The bend amount is moderate — too far flat
        // and the forearm crosses through the chest.
        let elbowBend = SCNAction.rotateTo(x: -0.9, y: 0, z: 0, duration: 0.32)
        elbowBend.timingMode = .easeOut
        let elbowHold = SCNAction.wait(duration: 0.73)
        let elbowRelax = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.45)
        elbowRelax.timingMode = .easeInEaseOut
        elbow.runAction(
            .sequence([elbowBend, elbowHold, elbowRelax]),
            forKey: "gesture.elbow"
        )
    }

    func shrug() {
        // Arms rotate outward + up via pivot rotation, shoulders rise.
        let leftPivot  = node.childNode(withName: "pivot.arm.left",  recursively: true)
        let rightPivot = node.childNode(withName: "pivot.arm.right", recursively: true)
        let leftShoulder  = node.childNode(withName: "part.suit.shoulder.left",  recursively: true)
        let rightShoulder = node.childNode(withName: "part.suit.shoulder.right", recursively: true)

        if let l = leftPivot {
            let up   = SCNAction.rotateTo(x: 0, y: 0, z: -0.35, duration: 0.22)
            up.timingMode = .easeOut
            let hold = SCNAction.wait(duration: 0.4)
            let down = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.3)
            down.timingMode = .easeInEaseOut
            l.runAction(.sequence([up, hold, down]), forKey: "gesture")
        }
        if let r = rightPivot {
            let up   = SCNAction.rotateTo(x: 0, y: 0, z: 0.35, duration: 0.22)
            up.timingMode = .easeOut
            let hold = SCNAction.wait(duration: 0.4)
            let down = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.3)
            down.timingMode = .easeInEaseOut
            r.runAction(.sequence([up, hold, down]), forKey: "gesture")
        }
        for sh in [leftShoulder, rightShoulder].compactMap({ $0 }) {
            let up = SCNAction.moveBy(x: 0, y: 8, z: 0, duration: 0.22)
            up.timingMode = .easeOut
            let hold = SCNAction.wait(duration: 0.4)
            let down = SCNAction.moveBy(x: 0, y: -8, z: 0, duration: 0.3)
            down.timingMode = .easeInEaseOut
            sh.runAction(.sequence([up, hold, down]), forKey: "gesture")
        }
    }

    func nod() {
        // Two deliberate affirmation nods.
        let target = headNode ?? bodyNode
        let down1 = SCNAction.rotateBy(x: 0.14, y: 0, z: 0, duration: 0.18)
        down1.timingMode = .easeInEaseOut
        let up1 = SCNAction.rotateBy(x: -0.14, y: 0, z: 0, duration: 0.22)
        up1.timingMode = .easeInEaseOut
        target.runAction(
            .sequence([down1, up1, down1, up1]),
            forKey: "gesture"
        )
    }

    func shakeHead() {
        // Three small horizontal head shakes.
        let target = headNode ?? bodyNode
        let right = SCNAction.rotateBy(x: 0, y: -0.14, z: 0, duration: 0.14)
        right.timingMode = .easeInEaseOut
        let left = SCNAction.rotateBy(x: 0, y: 0.28, z: 0, duration: 0.2)
        left.timingMode = .easeInEaseOut
        let center = SCNAction.rotateBy(x: 0, y: -0.14, z: 0, duration: 0.16)
        center.timingMode = .easeInEaseOut
        target.runAction(
            .sequence([right, left, right, left, center]),
            forKey: "gesture"
        )
    }

    /// Called when the user clicks to open chat — brief attention nod.
    func greet() {
        let nod = SCNAction.rotateBy(x: 0.08, y: 0, z: 0, duration: 0.25)
        nod.timingMode = .easeInEaseOut
        let back = SCNAction.rotateBy(x: -0.08, y: 0, z: 0, duration: 0.3)
        back.timingMode = .easeInEaseOut
        bodyNode.runAction(.sequence([nod, back]), forKey: "greet")
    }

    // MARK: - Anticipation (pre-latency cue)

    /// Tracks whether we're currently mid-anticipation so `endAnticipation`
    /// can be a safe no-op if called without a matching begin.
    private var anticipationHoldKey = "anticipation.lean"
    private(set) var isAnticipating = false

    /// Micro-gesture fired the instant the user commits a turn (voice
    /// hotkey released, chat Enter pressed) — BEFORE the first LLM token
    /// arrives. A ~180ms forward lean + `.curious` pose registers as
    /// "he got it" in the brain, dropping perceived latency well past
    /// what the actual round-trip costs. Stays held until
    /// `endAnticipation()` fires (on first-token arrival or stream end).
    ///
    /// Idempotent — a second `beginAnticipation` while already leaning
    /// is a no-op rather than doubling the rotation.
    func beginAnticipation() {
        guard !isAnticipating else { return }
        isAnticipating = true
        poseExpression(.curious)
        let lean = SCNAction.rotateBy(x: 0.12, y: 0, z: 0, duration: 0.18)
        lean.timingMode = .easeOut
        bodyNode.runAction(lean, forKey: anticipationHoldKey)
    }

    /// Release the lean. Called on first-token arrival (primary recovery
    /// point) and defensively on stream error / cancel so Max can't get
    /// stuck hunched forward if something goes wrong mid-turn.
    func endAnticipation() {
        guard isAnticipating else { return }
        isAnticipating = false
        // Cancel the lean action in case it's still mid-rotation, then
        // rotate back to zero with a matching easing so the return
        // reads as the same gesture unwinding rather than a snap.
        bodyNode.removeAction(forKey: anticipationHoldKey)
        let recover = SCNAction.rotateBy(x: -0.12, y: 0, z: 0, duration: 0.22)
        recover.timingMode = .easeInEaseOut
        bodyNode.runAction(recover, forKey: "anticipation.recover")
    }

    // MARK: - Expressions

    /// Current expression held on the pet. Changes only via
    /// `poseExpression` or undo. Default is `.neutral` at construction.
    private(set) var currentExpression: MaxClawdroomExpression = .neutral

    /// Rest positions / eulers / scales for nodes referenced by expression
    /// poses. Captured at init so poses can (a) apply position deltas
    /// relative to the authored placement and (b) fall back to the
    /// authored rest pose when a pose doesn't specify a given component.
    ///
    /// Important: the head has an authored forward-lean (-0.08 on X), so
    /// resetting euler to identity would pop the head upright.
    private var expressionRestPositions: [String: SCNVector3] = [:]
    private var expressionRestEuler: [String: SCNVector3] = [:]
    private var expressionRestScale: [String: SCNVector3] = [:]
    private var expressionAllKeys: Set<String> = []
    /// Cached SCNNode refs for every expression-targeted key, populated in
    /// indexExpressionRestPositions. `poseExpression` runs on every expression
    /// change (and every appearance re-pose) and used to do a recursive
    /// name walk per key — this makes those lookups O(1).
    private var expressionNodes: [String: SCNNode] = [:]

    private func indexExpressionRestPositions() {
        var keys: Set<String> = []
        for pose in form.expressionPoses.values {
            for key in pose.nodes.keys { keys.insert(key) }
        }
        expressionAllKeys = keys
        expressionNodes.removeAll(keepingCapacity: true)
        for key in keys {
            guard let found = node.childNode(withName: key, recursively: true) else { continue }
            expressionNodes[key] = found
            expressionRestPositions[key] = found.position
            expressionRestEuler[key] = found.eulerAngles
            expressionRestScale[key] = found.scale
        }
    }

    /// Apply an expression pose. Every expression-authored node is
    /// touched on every pose change — nodes referenced by the current
    /// pose animate to their delta, nodes not referenced animate back to
    /// their captured rest transform. Uses SCNTransaction so the
    /// animation is implicit and accurate (no custom interpolation drift).
    func poseExpression(_ expression: MaxClawdroomExpression) {
        guard let pose = form.expressionPoses[expression] else { return }
        currentExpression = expression

        // Swap the visible mouth shape. The Form decides which of the
        // authored shape nodes (arc/smile/frown/open/flat) matches
        // this expression; Pet.setMouthShape just flips isHidden.
        setMouthShape(form.mouthShape(for: expression))

        SCNTransaction.begin()
        SCNTransaction.animationDuration = pose.duration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        for key in expressionAllKeys {
            // O(1) lookup via expressionNodes cache — previously every pose
            // change did a recursive name walk per key, O(keys × tree).
            guard let target = expressionNodes[key] else { continue }
            let restEuler = expressionRestEuler[key] ?? SCNVector3Zero
            let restScale = expressionRestScale[key] ?? SCNVector3(1, 1, 1)
            let restPos = expressionRestPositions[key] ?? target.position

            if let delta = pose.nodes[key] {
                target.eulerAngles = delta.eulerAngles ?? restEuler
                target.scale = delta.scale ?? restScale
                if let p = delta.position {
                    target.position = SCNVector3(restPos.x + p.x, restPos.y + p.y, restPos.z + p.z)
                } else {
                    target.position = restPos
                }
            } else {
                // Not in this pose → relax to rest.
                target.eulerAngles = restEuler
                target.scale = restScale
                target.position = restPos
            }
        }

        SCNTransaction.commit()
    }

    /// Cancels any in-flight move / walk animation / procedural actions.
    /// Use at drag start.
    func stopAll() {
        node.removeAction(forKey: "walk")
        bodyNode.removeAction(forKey: "lean")
        bodyNode.removeAction(forKey: "walkbob")
        stopWalkAnimation()
    }

    /// Smoothly translates the pet root to the given x,y in scene coordinates.
    /// Applies a lean into the direction of motion, a step-cadence bob, and
    /// a settle at the end so he feels deliberate instead of hovering.
    func moveTo(x: CGFloat, y: CGFloat, duration: TimeInterval = 0.9) {
        node.removeAction(forKey: "walk")
        startWalkAnimation()
        let translate = SCNAction.move(
            to: SCNVector3(Double(x), Double(y), 0),
            duration: duration
        )
        translate.timingMode = .easeInEaseOut
        let endWalkAnim = SCNAction.run { [weak self] _ in
            Task { @MainActor in self?.stopWalkAnimation() }
        }
        node.runAction(.sequence([translate, endWalkAnim]), forKey: "walk")

        let currentX = CGFloat(node.presentation.position.x)
        let movingRight = x > currentX

        // Lean — eased, tunable per Form. Skip entirely if Form disables it.
        let leanMagnitude = form.walkLeanAngle
        if leanMagnitude > 0.001 {
            let leanZ: CGFloat = movingRight ? -leanMagnitude : leanMagnitude
            let leanIn = SCNAction.rotateTo(
                x: 0, y: 0, z: leanZ,
                duration: min(0.55, duration * 0.35)
            )
            leanIn.timingMode = .easeInEaseOut
            let hold = SCNAction.wait(duration: max(0, duration - 1.1))
            let leanOut = SCNAction.rotateTo(
                x: 0, y: 0, z: 0, duration: 0.55
            )
            leanOut.timingMode = .easeInEaseOut
            bodyNode.runAction(.sequence([leanIn, hold, leanOut]), forKey: "lean")
        } else {
            bodyNode.removeAction(forKey: "lean")
        }

        // Continuous gentle bob instead of discrete step-hops. Only if the
        // Form wants a bob at all (Broadcaster sets amplitude=0 for glide).
        let bobAmplitude = form.walkBobAmplitude
        if bobAmplitude > 0.01 {
            let cycle = 0.9
            let up = SCNAction.moveBy(x: 0, y: bobAmplitude, z: 0, duration: cycle / 2)
            up.timingMode = .easeInEaseOut
            let down = SCNAction.moveBy(x: 0, y: -bobAmplitude, z: 0, duration: cycle / 2)
            down.timingMode = .easeInEaseOut
            let cycles = max(1, Int(duration / cycle))
            bodyNode.runAction(
                .repeat(.sequence([up, down]), count: cycles),
                forKey: "walkbob"
            )
        } else {
            bodyNode.removeAction(forKey: "walkbob")
        }

        // Step cycle — alternating leg kicks + opposite arm swings.
        // Each limb is a pivot node at its joint; rotating around Z
        // swings the leg/arm forward-back in the screen plane. Opposite
        // phase between sides so it reads as walking, not skipping.
        //
        // Critical: the customAction ends at whatever sin(phase) is at
        // t=duration, which is almost never zero. An explicit easeTo-zero
        // tail is appended so limbs visibly settle back to rest when the
        // walk completes — otherwise he freezes in mid-stride.
        let stepAmp = form.walkStepAmplitude
        if stepAmp > 0.01 {
            let stepDur: TimeInterval = 0.55
            let legKick: CGFloat = 0.32
            let armSwing: CGFloat = 0.22
            let settleDur: TimeInterval = 0.28

            let legL = node.childNode(withName: "pivot.leg.left",  recursively: true)
            let legR = node.childNode(withName: "pivot.leg.right", recursively: true)
            let armL = node.childNode(withName: "pivot.arm.left",  recursively: true)
            let armR = node.childNode(withName: "pivot.arm.right", recursively: true)

            func cycleThenSettle(_ node: SCNNode, phaseOffset: Double, amplitude: CGFloat) {
                let step = SCNAction.customAction(duration: duration) { n, t in
                    let phase = 2 * .pi * Double(t) / stepDur + phaseOffset
                    n.eulerAngles = SCNVector3(0, 0, amplitude * CGFloat(sin(phase)))
                }
                let settle = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: settleDur)
                settle.timingMode = .easeInEaseOut
                node.runAction(.sequence([step, settle]), forKey: "walkstep")
            }

            if let l = legL { cycleThenSettle(l, phaseOffset: 0,       amplitude: legKick) }
            if let r = legR { cycleThenSettle(r, phaseOffset: .pi,     amplitude: legKick) }
            // Arm on same side swings OPPOSITE phase from its leg —
            // natural walking rhythm (left leg forward = right arm forward).
            if let la = armL { cycleThenSettle(la, phaseOffset: .pi, amplitude: armSwing) }
            if let ra = armR { cycleThenSettle(ra, phaseOffset: 0,   amplitude: armSwing) }
        }
    }

    /// Sets facing direction. Symmetric Forms (Orb) ignore this; asymmetric
    /// Forms in the future will override Form.applyFacing to flip their mesh.
    func face(right: Bool) {
        if facingRight == right { return }
        facingRight = right
        form.applyFacing(bodyNode: bodyNode, right: right)
    }
}
