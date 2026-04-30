import AppKit
import SceneKit

/// A Form is a swappable visual style for the Pet.
/// Every Form must produce a node rooted at (0,0,0), sized roughly around
/// `approximateRadius`, with a child node named "body" that can be animated
/// (scale, bob). Future Forms share a canonical skeleton; v1 Forms are primitive.
protocol Form {
    var displayName: String { get }
    var tint: NSColor { get }
    var approximateRadius: CGFloat { get }
    /// 0…1, higher = walks more often. Values near 0 = mostly stationary.
    var walkEagerness: Double { get }
    /// Where the pet node's origin sits on screen in scene pixels.
    var baseY: CGFloat { get }
    /// Hit rectangle relative to the pet node's origin. Used for click/drag hit-testing.
    /// Origin (0,0) = pet.node.position. +y = up.
    var hitBoundsRelative: CGRect { get }
    /// Accent color used for speech bubble borders / user-bubble tint.
    /// Defaults to `tint` but Forms with dark bodies can override.
    var bubbleAccent: NSColor { get }
    /// Vertical pulse during walks (px). 0 = glide, no bob.
    var walkBobAmplitude: CGFloat { get }
    /// Max lean angle into direction of motion (radians). 0 = no lean.
    var walkLeanAngle: CGFloat { get }
    /// Per-step leg lift amplitude (px). 0 = no stepping, just glide.
    /// Broadcaster is a digital character that glides; tune to ~5 for a
    /// subtle stride, higher for more pronounced walking.
    var walkStepAmplitude: CGFloat { get }
    /// Optional persona prompt injected as system role on chats from this Form.
    var systemPrompt: String? { get }
    /// Optional opening line shown as a preseeded assistant message when chat opens.
    var greeting: String? { get }
    /// Per-expression pose dictionary. Each expression maps to a set of
    /// node transforms applied via `Pet.poseExpression`. Forms that don't
    /// support expressions return an empty map and pose calls no-op.
    var expressionPoses: [MaxClawdroomExpression: ExpressionPose] { get }
    /// Returns the name suffix for the mouth shape this expression wants.
    /// Must be one of: `"arc"` (neutral chamfered box), `"smile"`,
    /// `"frown"`, `"open"`, `"flat"`. Pet.setMouthShape resolves the
    /// suffix to a `part.mouth.<name>` child and hides the rest.
    /// Default implementation returns `"arc"` for every expression,
    /// preserving pre-mouth-expression behaviour.
    func mouthShape(for expression: MaxClawdroomExpression) -> String
    func makeNode() -> SCNNode
    func applyFacing(bodyNode: SCNNode, right: Bool)
    /// Called after Pet is fully constructed. Use to attach recurring
    /// procedural behaviors (jitter, twitches, glitches, breathing cadence,
    /// whatever the Form wants).
    func attachBehaviors(to pet: Pet)
}

extension Form {
    var walkEagerness: Double { 1.0 }
    var baseY: CGFloat { 220 }
    var hitBoundsRelative: CGRect {
        let r = approximateRadius
        return CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
    }
    var bubbleAccent: NSColor { tint }
    var walkBobAmplitude: CGFloat { 3.0 }
    var walkLeanAngle: CGFloat { 0.08 }
    var walkStepAmplitude: CGFloat { 0 }
    var systemPrompt: String? { nil }
    var greeting: String? { nil }
    var expressionPoses: [MaxClawdroomExpression: ExpressionPose] { [:] }
    func mouthShape(for expression: MaxClawdroomExpression) -> String { "arc" }
    func applyFacing(bodyNode: SCNNode, right: Bool) {}
    func attachBehaviors(to pet: Pet) {}
}
