import Foundation

/// A single agent-proposed addition to the soul (system prompt) waiting
/// for user review. Proposals are the mechanism through which Max asks
/// for a personality change — the user keeps final veto power so the
/// soul never mutates silently.
struct SoulPatchProposal: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    /// One-paragraph natural-language case for the change, written by Max.
    /// Shown verbatim to the user in the review pane.
    let rationale: String
    /// The prompt snippet Max wants appended. Kept short (ideally one
    /// or two sentences) so the soul stays legible and bounded.
    let patch: String

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        rationale: String,
        patch: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rationale = rationale
        self.patch = patch
    }
}
