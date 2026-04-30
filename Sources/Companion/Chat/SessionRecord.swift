import Foundation

/// Lightweight persistable snapshot of a chat conversation. Only text
/// messages are saved — tool-call UI state is ephemeral, and the claude
/// subprocess holds the authoritative tool history keyed by session_id.
/// Resuming a session passes `--resume <id>` and claude-code replays the
/// semantic state; we just replay the text messages in the UI so the
/// user can see the conversation they had.
struct SessionRecord: Codable, Identifiable, Equatable {
    /// Our own UUID — distinct from `claudeSessionID` (which is set
    /// server-side by claude-code on first user turn). Lets us persist
    /// a record even before the first turn emits a session_id.
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    /// cwd the session was opened in. Used for per-project listing.
    var cwd: String
    /// The session_id that claude-code assigned. Nil until the first
    /// user turn completes and StreamJSONDecoder surfaces it.
    var claudeSessionID: String?
    /// First ~60 chars of the first user message, for the picker list.
    /// Empty string when the user hasn't sent anything yet.
    var title: String
    /// Channel this conversation belongs to. Nil for records persisted
    /// before per-channel transcripts shipped — those land in
    /// "whatever channel is active when listed" on first read so users
    /// don't lose their old chat history. New records always carry
    /// the active channel's id at save time.
    var channelID: UUID?
    /// Ordered visible conversation. Only user/assistant text — no tools.
    var messages: [PersistedMessage]

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        cwd: String,
        claudeSessionID: String? = nil,
        title: String = "",
        channelID: UUID? = nil,
        messages: [PersistedMessage] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cwd = cwd
        self.claudeSessionID = claudeSessionID
        self.title = title
        self.channelID = channelID
        self.messages = messages
    }
}

struct PersistedMessage: Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
    }
    let role: Role
    let text: String
    let at: Date

    init(role: Role, text: String, at: Date = Date()) {
        self.role = role
        self.text = text
        self.at = at
    }
}
