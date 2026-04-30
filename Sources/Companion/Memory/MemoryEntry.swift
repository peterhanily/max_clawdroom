import Foundation

/// One record in Max's per-project memory. Four kinds cover the useful
/// shapes without over-schema-ing:
///
/// - `observation` — a note he wrote to himself about the session
///   ("user wants subtle personality, not loud").
/// - `preference` — a key/value the user has expressed a preference for
///   ("tie_color = cyan"). Last write wins when multiple exist for the
///   same key.
/// - `journal` — end-of-session reflection (Phase 2 will write these
///   automatically; Phase 1 accepts them if emitted).
/// - `topic` — a named thread he can reference ("we were working on the
///   chat collapse animation"). `text` holds the summary.
///
/// Single flat struct rather than an enum-with-associated-values so the
/// JSONL shape is trivial to read by hand or grep.
struct MemoryEntry: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, Hashable {
        case observation
        case preference
        case journal
        case topic
    }

    let id: UUID
    let kind: Kind
    let timestamp: Date
    /// Body text. `.observation` / `.journal` / `.topic` use this for the
    /// note itself. `.preference` uses it as the preference value.
    let text: String
    /// Only populated for `.preference` and `.topic` — the preference
    /// name, or the topic's short title.
    let key: String?

    init(
        id: UUID = UUID(),
        kind: Kind,
        timestamp: Date = Date(),
        text: String,
        key: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        // Strip ANSI escape sequences (terminal colour codes, cursor
        // moves) at construction time. These end up in memory when a
        // user pastes terminal output into chat or when a tool's
        // stdout is captured raw. Rendering them in Max's Room or
        // feeding them into the next [you] prompt adds no information
        // and can produce visual glitches / false tokens.
        self.text = Self.stripANSI(text)
        self.key = key.map(Self.stripANSI)
    }

    /// Remove CSI / OSC escape sequences. Intentionally narrow — this
    /// is for terminal-style control codes, not a full sanitiser.
    private static func stripANSI(_ s: String) -> String {
        // Matches: ESC [ <params> <final>, and ESC ] <payload> BEL / ESC \
        guard let regex = ansiRegex else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.stringByReplacingMatches(
            in: s, options: [], range: range, withTemplate: ""
        )
    }

    private static let ansiRegex: NSRegularExpression? = {
        let pattern = "\u{001B}(?:\\[[0-9;?]*[@-~]|\\][^\u{0007}]*(?:\u{0007}|\u{001B}\\\\))"
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    // MARK: - Convenience constructors

    static func observation(_ text: String) -> MemoryEntry {
        MemoryEntry(kind: .observation, text: text)
    }

    static func preference(_ key: String, value: String) -> MemoryEntry {
        MemoryEntry(kind: .preference, text: value, key: key)
    }

    static func journal(_ text: String) -> MemoryEntry {
        MemoryEntry(kind: .journal, text: text)
    }

    static func topic(_ name: String, summary: String) -> MemoryEntry {
        MemoryEntry(kind: .topic, text: summary, key: name)
    }

    // MARK: - Prompt rendering

    /// One-line representation for the `[memory]` block in the agent's
    /// system prompt. Short date + kind-specific shape.
    func promptLine() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let date = f.string(from: timestamp)
        switch kind {
        case .observation:
            return "• [\(date)] \(text)"
        case .preference:
            return "• pref \(key ?? "?") = \(text)"
        case .journal:
            return "• journal \(date): \(text)"
        case .topic:
            return "• topic \"\(key ?? "?")\": \(text)"
        }
    }
}
