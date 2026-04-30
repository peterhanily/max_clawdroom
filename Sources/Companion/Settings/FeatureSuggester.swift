import Foundation

/// Surfaces optional-but-currently-OFF features in Max's system prompt
/// so he can suggest one to the user when contextually relevant.
///
/// Builds a one-block summary like:
///
///     Optional features the user could enable (suggest at most one,
///     only when contextually relevant — never list):
///       • Voice input — needs microphone permission. Lets the user
///         hold ⌘⌥Space to talk to you instead of typing.
///       • Autonomy — Max periodically acts on his own (~10 min
///         cadence: tiny gestures, ambient mood shifts).
///       • Music-reactive — syncs Max's tie pulse and walk cadence
///         to whatever's playing in Now Playing.
///
/// The block tells Max explicitly: suggest at most one, only when
/// the conversation gives a natural opening, and never enumerate
/// all of them. He's not a sales bot — these are quiet hints he can
/// drop ("by the way, if you ever want me to talk back, you can
/// turn on voice from Settings").
///
/// Gated on `Prefs.allowMaxToSuggestFeatures` (default true). When
/// off the block isn't injected and Max only knows about features
/// already in use.
enum FeatureSuggester {

    /// Build the system-prompt block. Returns empty when no features
    /// are off, when the user opted out, or when the list collapses
    /// to nothing useful — so the prompt always reads cleanly.
    @MainActor
    static func promptBlock() -> String {
        guard Prefs.allowMaxToSuggestFeatures else { return "" }
        let candidates = currentlyOffFeatures()
        guard !candidates.isEmpty else { return "" }

        var lines = [
            "Optional features the user could enable (suggest at most ONE,",
            "only when contextually relevant — never list, never enumerate,",
            "never lead a reply with a suggestion):"
        ]
        for feature in candidates {
            lines.append("  • \(feature.title) — \(feature.rationale)")
        }
        lines.append(
            "When you do mention one, say it casually and once. " +
            "Don't repeat across turns. Don't ask permission to mention."
        )
        return lines.joined(separator: "\n")
    }

    // MARK: - Feature inventory

    private struct Feature {
        let title: String
        let rationale: String
        let isOn: () -> Bool
    }

    /// All known optional features. `isOn` returns the current state;
    /// `currentlyOffFeatures()` filters to the subset that's OFF.
    @MainActor
    private static let inventory: [Feature] = [
        Feature(
            title: "Voice input (⌘⌥Space — disabled on macOS 26.x)",
            rationale: "Lets the user hold a hotkey to talk to you instead of typing. Needs microphone permission.",
            isOn: { Prefs.hasOptedIntoMicrophone }
        ),
        Feature(
            title: "Voice output (Max speaks aloud)",
            rationale: "Reads your replies through the system Jamie voice. ⌥⌘V to toggle.",
            isOn: { Prefs.voiceEnabled }
        ),
        Feature(
            title: "Sound effects",
            rationale: "Footsteps when you walk, glitch on channel swap, chime on expression shift.",
            isOn: { Prefs.soundEffectsEnabled }
        ),
        Feature(
            title: "Notifications",
            rationale: "Lets Max nudge the user with a morning greeting, soul-patch reviews, ambient pings.",
            isOn: { Prefs.hasOptedIntoNotifications }
        ),
        Feature(
            title: "Autonomy",
            rationale: "You periodically act on your own — tiny expressions, walks, theme shifts. ~10 min cadence.",
            isOn: { Prefs.autonomyEnabled }
        ),
        Feature(
            title: "Music-reactive",
            rationale: "Syncs your tie pulse and walk cadence to whatever's playing in Now Playing.",
            isOn: { Prefs.musicReactiveEnabled }
        ),
        Feature(
            title: "Weather grounding",
            rationale: "Adds a [world] block to the env with current weather + city — lets you flavour replies and outfits.",
            isOn: { Prefs.weatherEnabled }
        ),
        Feature(
            title: "Agent audio fetch",
            rationale: "Lets you reach beyond the built-in sound catalog (search myinstants.com, fetch any audio URL).",
            isOn: { Prefs.allowAgentAudioFetch }
        ),
        Feature(
            title: "Soul auto-apply",
            rationale: "Your update_soul ops apply directly instead of queueing for user review.",
            isOn: { Prefs.soulAutoApply }
        )
    ]

    @MainActor
    private static func currentlyOffFeatures() -> [Feature] {
        inventory.filter { !$0.isOn() }
    }
}
