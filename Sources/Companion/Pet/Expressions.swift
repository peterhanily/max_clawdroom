import Foundation
import SceneKit

/// Named emotional/attentional poses Max can hold. Each Form supplies its
/// own pose dictionary — Broadcaster uses brow angle, head tilt, lens
/// scale, mouth shape. Orb and future forms can map the same expressions
/// onto whatever parts they have.
///
/// Distinct from `MaxClawdroomStage` (idle/thinking/speaking/error/sleeping)
/// which is internal state. Expressions are the VISIBLE pose; a single
/// stage can use multiple expressions (a long `thinking` stage might
/// shift focused → curious → focused).
enum MaxClawdroomExpression: String, CaseIterable, Hashable {
    case neutral
    case focused      // brows drawn in, head slightly down — "I'm on it"
    case curious      // one brow up, head tilt — "tell me more"
    case amused       // brows up, teeth visible — "that's funny"
    case uncertain    // brows knitted inward, eyes narrowed — "hmm"
    case surprised    // brows up high, lens wide — "oh"
    case concerned    // brows furrowed, mouth flat — "something's wrong"
    case tired        // brows relaxed, lens narrowed, head drooped — "powering down"
    // Phase D — expanded palette
    case excited      // brows rocketing up, eyes wide, head tipped up — "YES!"
    case thoughtful   // one brow raised, head tilted down, eyes half-lidded — "hmm…"
    case skeptical    // one brow up hard, other slightly down — "really?"
    case sleepy       // eyes barely open, head drooped a bit — "5 more min"
    case angry        // brows slammed down+in, narrow eyes, head forward — "no."
    case embarrassed  // brows slight up, head down+turned — "oh god"
    case devious      // one brow up, sly head tilt, eyes narrowed — "heheh"
    case determined   // brows low + square, focused eyes, squared head — "got this"
    case confused     // mismatched brows, head tilt, asymmetric eyes — "??"
    case dreamy       // soft brows up, eyes half closed, head tilted up — "sigh"
    case smug         // one brow up, head back, half-lidded eyes — "told you"
    case shy          // head down, soft concerned brows, narrow eyes — "…"
}

/// Per-node transform delta applied to reach an expression. All deltas
/// are relative to the node's rest pose (eulerAngles zero, scale one,
/// position zero) — applying a pose means snapping those attributes to
/// the delta, not accumulating. A missing field means "don't touch".
struct ExpressionPose {
    /// Smooth animation duration when transitioning into this pose.
    let duration: TimeInterval

    /// Keyed by SceneKit node name (e.g. `part.brow.left`, `part.head`).
    /// Missing keys resolve to rest pose.
    let nodes: [String: NodeDelta]

    struct NodeDelta {
        var eulerAngles: SCNVector3? = nil
        var scale: SCNVector3? = nil
        var position: SCNVector3? = nil
    }

    /// Identity pose — every known node reset to rest. Used on transition
    /// to `.neutral` and on initial `Pet.rebuild`.
    static func rest(for nodeNames: [String]) -> ExpressionPose {
        var nodes: [String: NodeDelta] = [:]
        for name in nodeNames {
            nodes[name] = NodeDelta(
                eulerAngles: SCNVector3Zero,
                scale: SCNVector3(1, 1, 1),
                position: nil  // position rest is form-specific; skip
            )
        }
        return ExpressionPose(duration: 0.35, nodes: nodes)
    }
}
