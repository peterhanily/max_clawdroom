import AppKit
import Combine
import Foundation
import SceneKit

/// Applies visible "mood" changes to the pet as `WorkState` transitions.
/// Without rebuilding the SceneKit hierarchy — we just animate opacity,
/// scale, and a held-expression bias on the existing pet node.
///
/// Shipping form-swap (Broadcaster → Gentleman → Orb tied to state)
/// would need a full pet-rebuild path because `Pet` stores many weak
/// references to itself across Locomotion / CursorGaze / BindingEngine
/// / Reflex / SoulTintDrift / ExpressionDriver. The mood layer delivers
/// most of the felt value — "Max matches my register" — without that
/// architectural cost. Form-swap stays on the backlog.
@MainActor
final class WorkStateEffects {

    private weak var pet: Pet?
    private weak var tracker: WorkStateTracker?
    private var cancellable: AnyCancellable?

    init(pet: Pet, tracker: WorkStateTracker) {
        self.pet = pet
        self.tracker = tracker
        cancellable = tracker.$state
            .sink { [weak self] newState in
                Task { @MainActor in self?.apply(newState) }
            }
    }

    // MARK: - Apply

    /// Map each state to a target opacity + scale + expression. The
    /// transition itself is animated via `SCNTransaction` so the change
    /// reads as Max "settling" rather than snapping.
    private func apply(_ state: WorkState) {
        guard let pet else { return }
        let (opacity, scale, expression) = parameters(for: state)

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 1.2
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pet.node.opacity = opacity
        // Scale is applied on a uniform axis; form-level geometry scale
        // already lives on bodyNode, so we nudge the root instead and
        // keep form geometry untouched.
        let s = Float(scale)
        pet.node.scale = SCNVector3(s, s, s)
        SCNTransaction.commit()

        // Expression is a separate animation path (SCNTransaction inside
        // poseExpression already has its own duration), so call after
        // the opacity/scale transition kicks off.
        if let expression {
            pet.poseExpression(expression)
        }
    }

    /// Narrow tuning surface — change these numbers, behaviour changes.
    /// Everything else in this file is plumbing.
    ///
    /// Early tuning had ambient at 0.55 opacity which made Max read as
    /// "half gone" — felt like a glitch rather than a mood. Users want
    /// solid most of the time with gentle register shifts, so the
    /// extremes are pulled in. Ambient is still visibly softer than
    /// active; it just no longer looks like the pet is broken.
    private func parameters(
        for state: WorkState
    ) -> (opacity: CGFloat, scale: CGFloat, expression: MaxClawdroomExpression?) {
        switch state {
        case .active:
            return (1.0, 1.0, nil)
        case .deepFocus:
            // Originally 0.97 opacity to be "barely perceptible." In
            // practice users did perceive it — Max read as faintly
            // transparent in the everyday "I'm at the keyboard
            // working" state, which made the baseline appearance
            // look broken. Opacity stays at 1.0; deep-focus is
            // signalled through scale (a hair smaller) and the
            // focused expression alone.
            return (1.0, 0.97, .focused)
        case .ambient:
            // Present but quieter — NOT translucent. Max stays readable
            // across the room; the signal is "I'm not actively waiting
            // on you" rather than "I've faded out." 0.85 looked
            // visibly translucent for the everyday-idle case; bumped
            // to 0.95 so the dim is only noticed when looked for.
            return (0.95, 0.94, .neutral)
        }
    }
}
