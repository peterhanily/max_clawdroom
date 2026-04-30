import Foundation

/// One beat of the tour. A narration line Max "says" (progressively typed
/// into the chat bubble), a set of actions he performs while or after
/// speaking, and a dwell that pauses before the next step fires.
///
/// Actions flow through the same `ActionDispatcher` the agent uses at
/// runtime, so every tour mutation is ⌘Z-undoable just like an
/// agent-authored one — which makes the "press ⌘Z to undo anything I do"
/// callout honest.
struct TourStep {
    let narration: String
    let actions: [TourAction]
    let dwell: TimeInterval
}

struct TourAction {
    let op: String
    let args: [String: AnyHashable]
    /// Seconds to wait before firing this action. Stacks from the start
    /// of the step — an action with delay 2.0 fires ~2s after narration
    /// begins typing.
    let delay: TimeInterval

    init(
        _ op: String,
        _ args: [String: AnyHashable] = [:],
        delay: TimeInterval = 0
    ) {
        self.op = op
        self.args = args
        self.delay = delay
    }
}
