import Foundation

/// Single source of truth for: which sound names exist, what category
/// each falls into, and how the system-prompt paragraph that tells
/// Max about the catalog is generated.
///
/// Adding a sound = one line in `entries`. The reactor's auto-bindings
/// reference these names directly; the agent's `play_sound` op accepts
/// any of them. Names not in this list are still playable if a procedural
/// recipe or bundled sample exists, but they won't appear in the agent's
/// prompt — defensive default so half-implemented sounds don't get
/// promised before they work.
enum SoundLibrary {
    struct Entry {
        let name: String
        let category: SoundCategory
        /// Short user-facing description for the agent's prompt block
        /// and the future Settings sound browser.
        let description: String
    }

    static let entries: [Entry] = [
        // Body / motion
        .init(name: "footstep",      category: .body, description: "single footstep tap"),
        .init(name: "jitter",        category: .body, description: "small electric zap"),
        .init(name: "wave_woosh",    category: .body, description: "hand-wave whoosh"),
        .init(name: "nod_tick",      category: .body, description: "tiny tick for a nod"),
        .init(name: "look_around",   category: .body, description: "head-pan whoosh"),
        .init(name: "blink",         category: .body, description: "very short blink blip"),
        // Expression mood
        .init(name: "chime_soft",    category: .sting, description: "warm two-note chime — amused / pleased"),
        .init(name: "chord_low",     category: .sting, description: "descending low chord — sad / disappointed"),
        .init(name: "chord_resolve", category: .sting, description: "ascending major triad — confident finish"),
        .init(name: "synth_riser",   category: .sting, description: "synth riser — devious / about to do something"),
        .init(name: "bonk_uplift",   category: .sting, description: "two-note bonk — confused but recovering"),
        // UI
        .init(name: "pop_pickup",    category: .ui,   description: "soft pop — pick up a prop"),
        .init(name: "thunk_low",     category: .ui,   description: "low thunk — drop a prop"),
        .init(name: "pip_chord",     category: .ui,   description: "three-note pip — color change"),
        .init(name: "pip_low",       category: .ui,   description: "single low pip — minor confirm"),
        .init(name: "paper_flip",    category: .ui,   description: "paper flip — font swap"),
        // Mode transitions
        .init(name: "tv_static_in",  category: .mode, description: "TV-static crackle — entering TV mode"),
        .init(name: "whoosh_settle", category: .mode, description: "soft settle — entering desktop mode"),
        // Channel
        .init(name: "glitch_swoop",  category: .channel, description: "glitchy swoop — channel switch"),
        .init(name: "error_bonk",    category: .channel, description: "low bonk — channel auth failed"),
        // Stings
        .init(name: "fanfare_tiny",  category: .sting, description: "tiny fanfare — small win"),
        .init(name: "lofi_morning",  category: .sting, description: "lo-fi morning pad — first greeting of the day"),
        .init(name: "magic_shimmer", category: .sting, description: "shimmering arpeggio — wizard hat / mystical")
    ]

    private static let lookup: [String: Entry] = {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
    }()

    static func category(for name: String) -> SoundCategory? {
        lookup[name]?.category
    }

    static func exists(_ name: String) -> Bool {
        lookup[name] != nil || ProceduralSounds.recipes[name] != nil
    }

    /// Block injected into Max's system prompt so he knows what's in
    /// the catalog before he calls `play_sound`. Grouped by category
    /// for scannability. Also documents the three input shapes:
    /// built-in `name`, generic `url`, and `myinstants` query.
    static func promptBlock() -> String {
        let grouped = Dictionary(grouping: entries, by: { $0.category })
        var lines = ["Available sounds (use the play_sound action):"]
        lines.append("")
        lines.append("Three ways to call play_sound — pick exactly one:")
        lines.append("  • {\"op\":\"play_sound\",\"name\":\"<catalog name>\"}")
        lines.append("      → built-in / procedural sound; always works.")
        lines.append("  • {\"op\":\"play_sound\",\"url\":\"https://.../clip.mp3\"}")
        lines.append("      → any audio URL on the web. Requires user opt-in")
        lines.append("        (Settings → Voice & Look → Sound effects → Allow")
        lines.append("        agent audio fetch). 2 MB cap, 5 s timeout, audio-only.")
        lines.append("  • {\"op\":\"play_sound\",\"myinstants\":\"<search query>\"}")
        lines.append("      → looks up the first matching clip on myinstants.com.")
        lines.append("        Same gate + safeguards as the url path. Use for the")
        lines.append("        meme catalog (\"vine boom\", \"airhorn\", \"sad trombone\",")
        lines.append("        \"oof\", \"taco bell bong\", etc.) — broad cultural")
        lines.append("        vocabulary you don't have to enumerate.")
        lines.append("")
        lines.append("Optional args:")
        lines.append("  volume:   0…1, scales this fire only.")
        lines.append("  cache_as: stable name for url/myinstants paths so")
        lines.append("            repeat plays skip the network.")
        lines.append("")
        lines.append("Built-in catalog (always available, no opt-in needed):")
        for cat in SoundCategory.allCases {
            guard let items = grouped[cat], !items.isEmpty else { continue }
            lines.append("  \(cat.displayName):")
            for entry in items.sorted(by: { $0.name < $1.name }) {
                lines.append("    - \(entry.name) — \(entry.description)")
            }
        }
        lines.append("")
        lines.append("Use sparingly — punctuation, not soundtrack. Skip when speaking long replies.")
        return lines.joined(separator: "\n")
    }
}
