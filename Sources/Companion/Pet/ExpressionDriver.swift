import Foundation
import Observation

/// Observes `MaxClawdroomState.stage` and auto-poses the pet with the
/// matching default expression. Keeps Max's face reading the stage
/// correctly without every dispatcher action needing to reach in.
///
/// Explicit `set_expression` action-tag ops still work — whichever pose
/// fires last wins. A stage change after an explicit set will override,
/// which is desired behavior (next thinking / tool-use beat takes over
/// from a held amused pose).
@MainActor
final class ExpressionDriver {
    private weak var pet: Pet?
    private let state: MaxClawdroomState

    init(pet: Pet, state: MaxClawdroomState) {
        self.pet = pet
        self.state = state
        poseFor(state.stage)
        track()
    }

    private func track() {
        withObservationTracking { [state] in
            _ = state.stage
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.poseFor(self.state.stage)
                self.track()
            }
        }
    }

    private func poseFor(_ stage: MaxClawdroomStage) {
        let expr: MaxClawdroomExpression
        switch stage {
        case .idle:       expr = .neutral
        case .listening:  expr = .curious
        case .thinking:   expr = .focused
        case .speaking:   expr = .neutral
        case .toolUse:    expr = .focused
        case .error:      expr = .concerned
        case .sleeping:   expr = .tired
        }
        pet?.poseExpression(expr)
    }
}
