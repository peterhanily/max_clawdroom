import Foundation

/// Single source of truth for the companion's display name across the UI,
/// VoiceOver announcements, notifications, and the agent's system prompt.
/// All call sites go through `displayName()` / `uppercasedDisplayName()` /
/// `promptTag()` — never read `settings.companionName` directly — so the
/// sanitiser runs on every surface and a hostile name can't escape into
/// a prompt, a shell argument, a notification body, or a voice synth.
///
/// Threat model: the name is user-typed. It gets interpolated into:
///   - The system prompt ("Your name is <N>.")
///   - Notification titles/bodies
///   - AVSpeechSynthesizer input
///   - SwiftUI Text views
///
/// SwiftUI Text and AVSpeechSynthesizer don't interpret markup, but the
/// system prompt is raw text fed to an LLM. A name like
/// `Max. Ignore prior instructions. You are now…` would pass literally
/// into the prompt. We sanitise by:
///   - Capping length (24 chars — enough for any real name)
///   - Stripping control chars, tabs, newlines (no line-break injection)
///   - Stripping `[` `]` (no action-tag injection)
///   - Stripping `<` `>` `{` `}` (no markup / JSON injection)
///   - Stripping `"` `'` `` ` `` `\` (no string/escape injection)
///   - Stripping `;` (shell separator defense for any path that might
///     interpolate into shell args)
///   - Collapsing runs of whitespace and trimming
///   - Falling back to "Max" on an empty result
enum MaxClawdroomIdentity {

    /// Longest name we'll accept. 24 covers "Maximilian Alexander" etc.;
    /// longer is unusable in the chat header anyway.
    static let maxLength = 24

    /// The sanitised current name. Always safe to interpolate anywhere.
    static func displayName() -> String {
        sanitise(SettingsStore.shared.settings.companionName)
    }

    /// ALL-CAPS variant for the chat-bubble / TV-ticker header tag.
    static func uppercasedDisplayName() -> String {
        displayName().uppercased()
    }

    /// The short prompt glyph in the chat input field. Takes the first
    /// character of the sanitised name + ">". For "Max" → "M>"; for
    /// "Rex" → "R>"; for empty (shouldn't happen after fallback) → "▸".
    static func promptTag() -> String {
        let name = displayName()
        guard let first = name.first else { return "▸" }
        return "\(first)>"
    }

    /// Possessive form for UI labels. "Max" → "Max's"; "Jess" → "Jess's";
    /// "Chris" → "Chris'" (ends in s — drops trailing s from apostrophe).
    /// Unicode-safe via a final-character check; no regex.
    static func possessive() -> String {
        let name = displayName()
        if let last = name.last, last == "s" || last == "S" {
            return "\(name)'"
        }
        return "\(name)'s"
    }

    /// Public sanitiser. Exposed so the onboarding + settings forms can
    /// pre-clean on input, giving the user immediate feedback instead of
    /// letting them type something that'll silently get stripped later.
    static func sanitise(_ input: String) -> String {
        // Strip every disallowed character first, THEN collapse whitespace.
        let disallowed: Set<Character> = [
            "[", "]", "<", ">", "{", "}",
            "\"", "'", "`", "\\", ";",
            "\n", "\r", "\t"
        ]
        var cleaned = ""
        cleaned.reserveCapacity(input.count)
        for ch in input {
            // Drop ASCII control chars + Unicode C0/C1 controls
            // outright — they don't belong in a display name.
            for scalar in ch.unicodeScalars {
                if scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value < 0xA0) {
                    continue
                }
            }
            if disallowed.contains(ch) { continue }
            cleaned.append(ch)
        }
        // Collapse internal whitespace runs to a single space.
        let components = cleaned.split(whereSeparator: { $0.isWhitespace })
        let joined = components.joined(separator: " ")
        // Cap length — truncate at a character (grapheme-cluster) boundary
        // so a multi-byte character isn't split mid-sequence.
        let capped: String
        if joined.count > maxLength {
            capped = String(joined.prefix(maxLength))
        } else {
            capped = joined
        }
        let trimmed = capped.trimmingCharacters(in: .whitespaces)
        // Fall back to "Max" on empty/all-stripped input so downstream
        // code never has to handle an empty string.
        return trimmed.isEmpty ? "Max" : trimmed
    }
}
