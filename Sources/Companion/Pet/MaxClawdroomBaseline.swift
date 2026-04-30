import Foundation

/// Canonical "rest" appearance, voice, and chat presentation for Max.
///
/// This is the single source of truth that:
/// - The right-click "Revert to Baseline" menu / `revert_to_baseline`
///   action op fires on, restoring every customisable axis in one shot.
/// - The system prompt advertises so Max knows what his defaults are
///   and what "look normal again" means concretely.
///
/// The values are deliberately *literal action arguments* rather than
/// strongly-typed enums, because they're consumed by the action
/// dispatcher's switch statement (string-keyed args) and by the
/// system-prompt generator (which embeds them as JSON-ish examples
/// for the agent to mirror).
///
/// Update one value here → both the revert path and the agent's
/// prompt change in lockstep. No drift between "what Max thinks
/// normal is" and "what Revert to Baseline actually does."
enum MaxClawdroomBaseline {

    /// Action sequence the revert path runs, in order. Order matters
    /// because (a) outfit preset rebuilds geometry, (b) body builds
    /// re-anchor accessories, (c) `set_mode` resizes / re-positions
    /// the overlay so it must run BEFORE the body-axis revert that
    /// reads the current mode for camera-distance assumptions.
    static var revertSequence: [(op: String, args: [String: AnyHashable])] {
        [
            ("set_mode",           ["name": "desktop"]),
            ("set_outfit_preset",  ["preset": "broadcaster"]),
            ("set_hair",           ["style": "pompadour"]),
            ("set_grooming",       ["style": "clean"]),
            ("set_physique",       ["build": "default"]),
            ("set_expression",     ["name": "neutral"]),
            ("toggle_glasses",     ["show": false]),
            ("drop_all_props",     [:]),
            ("set_scale",          ["scale": 1.0]),
            ("reset_colors",       [:]),
            ("set_voice",          ["name": "Jamie"]),
            ("set_voice_filter",   ["enabled": false]),
            ("reset_chat_theme",   [:])
        ]
    }

    /// Block injected into Max's system prompt so he knows his rest
    /// appearance/voice/chat defaults and that he can restore them in
    /// one shot via `revert_to_baseline`. The block is human-readable
    /// (he reads it; he isn't parsing it), so we use sentences not JSON.
    static func promptBlock() -> String {
        """
        Your baseline appearance, voice, chat, and mode — these are your defaults.
        When the user asks you to "look normal", "go back to default",
        "reset", or similar, restore THESE values (or fire `revert_to_baseline`
        for the whole thing in one action):
          • Mode:        desktop (overlay sized + positioned for desktop use,
                         not TV / laptop / meeting)
          • Outfit:      broadcaster preset (white shirt, cyan tie, dark trousers)
          • Hair:        pompadour
          • Grooming:    clean (no facial hair)
          • Physique:    default
          • Expression:  neutral (rest pose between beats)
          • Glasses:     none
          • Props:       none held / nothing back-mounted
          • Body scale:  1.0
          • Body colors: factory (no part recolours, no patterns, no textures)
          • Voice:       Jamie (Apple Premium, English)
          • Voice filter: off (clean voice — the Max Headroom DSP filter is OFF by default)
          • Chat panel:  CRT defaults (cyan border, magenta user bubble, dark panel,
                         mono font, no background image)
        Drift away from these on purpose for character moments — change clothes
        for the bit, hold a wand for wizard mode, switch to a serif font when
        the conversation gets formal, swap to TV mode for movie night — but
        treat them as your "home base".

        Action ops you have for resets:
          • {"op":"revert_to_baseline"} — restores every axis above in one call,
            including mode (returns to desktop) and the chat panel (resets
            colors, font, and any background image). Use this when the user
            clearly wants the whole package reset.
          • {"op":"reset_chat_theme"} — chat panel only (colors + font +
            background image), leaves the body and mode alone.
          • Individual ops (set_voice, set_mode, set_chat_color, etc.) — for
            one-axis reverts ("just put your normal voice back, keep the cape").
        """
    }
}
