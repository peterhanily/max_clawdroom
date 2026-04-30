import Foundation

/// A frozen cross-section of who Max is and who he thinks the user is
/// at a given point in time. Auto-captured every ~90 days as a
/// retention / storytelling lever: users can flip back through capsules
/// later and see how both have changed.
///
/// Shape is deliberately self-contained — a capsule should make sense
/// standing alone, without needing to cross-reference the live stores.
/// Capsules never change after capture; `TimeCapsuleStore` appends new
/// ones and never rewrites existing records.
struct TimeCapsule: Codable, Identifiable, Equatable {
    let id: UUID
    let capturedAt: Date
    /// Frozen copy of the `UserModel` at capture time. May be empty
    /// when captured on a fresh install with no synthesis yet.
    let userModelSnapshot: UserModel
    /// The full composed system prompt as Max was experiencing it. A
    /// short-but-complete record of his "soul" at that moment.
    let soulPrompt: String
    /// Lightweight "what happened in this window" numbers — how many
    /// soul patches accepted, memory entries added, ritual fires, etc.
    let stats: Stats

    struct Stats: Codable, Equatable {
        let memoryEntriesTotal: Int
        let soulPatchesApplied: Int
        let rituals: [String: Int]  // ritual.id → count

        static let empty = Stats(
            memoryEntriesTotal: 0,
            soulPatchesApplied: 0,
            rituals: [:]
        )
    }

    init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        userModelSnapshot: UserModel,
        soulPrompt: String,
        stats: Stats
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.userModelSnapshot = userModelSnapshot
        self.soulPrompt = soulPrompt
        self.stats = stats
    }

    /// Human-readable headline for the row in Max's Room. Short enough
    /// to fit on one line, specific enough to be more than a date.
    var headline: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .long
        fmt.timeStyle = .none
        let date = fmt.string(from: capturedAt)
        let role = userModelSnapshot.identity.role
        if role.isEmpty { return date }
        return "\(date) — \(role)"
    }
}
