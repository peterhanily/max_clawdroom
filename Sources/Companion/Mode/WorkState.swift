import Foundation

/// What Max thinks the user is doing right now — distinct from the
/// display-sizing `MaxClawdroomMode` (desktop / laptop / tv / meeting).
/// Work state is a register: how present should the companion be?
///
/// - `active` — user is at the keyboard in a normal cadence. Max is at
///   full presence: default expression, full opacity, normal idle jitter.
/// - `deepFocus` — user has been editing one file for a long stretch, no
///   recent chat, editor is frontmost. Max quiets down — holds a
///   `focused` expression, drops opacity slightly, lowers idle-motion
///   amplitude. The register of someone in the room who won't interrupt.
/// - `ambient` — user is away (idle), app is backgrounded, or they're
///   in a break app. Max fades to minimum presence — low opacity, no
///   expression animations. He's a presence, not a participant.
///
/// Kept as a small discriminated enum so the tracker, effects, and menu
/// bar can switch on it without string-matching.
enum WorkState: String, Equatable {
    case active
    case deepFocus
    case ambient

    /// One-word human-readable label for the menu bar.
    var displayName: String {
        switch self {
        case .active:    return "Active"
        case .deepFocus: return "Deep focus"
        case .ambient:   return "Ambient"
        }
    }

    /// Emoji glyph for the menu-bar indicator so the user can
    /// recognise the state at a glance without reading.
    var glyph: String {
        switch self {
        case .active:    return "●"
        case .deepFocus: return "◉"
        case .ambient:   return "○"
        }
    }
}
