import Foundation

/// Observed events that drive zero-token `ReflexController` reactions.
/// Emitted by `AutonomyController` (via its Combine publisher) alongside
/// its normal LLM-tick queueing. Kept deliberately narrow — every case
/// here is a signal strong enough to justify a visible in-world reaction
/// without needing a model to interpret it.
///
/// Adding a case here is a one-line change; the behaviour that fires in
/// response lives in `ReflexController.plan(for:)` as a pure table so
/// the mapping stays readable.
enum ReflexEvent {
    /// User switched from a work app to a break / comms app.
    case leftWork(from: String, to: String)
    /// User switched from a break app back to a work app.
    case returnedToWork(from: String, to: String)
    /// Clipboard grew >600 chars — agent probably pasted a stack trace,
    /// log, file, or big code block.
    case largePaste(charCount: Int)
    /// Same clipboard payload appeared again within 48h — user is
    /// wrestling with the same problem.
    case repeatedPaste
    /// Idle streak (>20 min) ended — user just came back.
    case idleToActive(awayMinutes: Int)
    /// One file has had focus for a milestone duration (30 / 60 / 90 min).
    case longEditMilestone(minutes: Int, fileName: String)
    /// A soul patch was accepted — Max just absorbed a new trait.
    case soulPatchAccepted(rationale: String)
    /// A new commit landed on the currently-checked-out branch. The
    /// message is the first line of the commit's log entry (trimmed).
    case commitLanded(message: String)
    /// User switched to a different branch.
    case branchSwitched(to: String)
}
