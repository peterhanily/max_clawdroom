# max_clawdroom

A native macOS menu-bar app. Max — a Max-Headroom-style 3D character — lives on a transparent overlay and is driven by the [Claude Code](https://www.anthropic.com/claude-code) CLI (`claude`).

Max controls his own body language, voice, appearance, and chat panel by emitting structured `[action]` blocks inside his chat responses. The app parses them out of the stream and applies them live; his prose is shown normally.

**Status: v0.2.0 prep — private alpha.** Multi-channel routing (local / LAN / remote / Claude Code CLI), agent-driven sound effects with myinstants soundboard fetch, per-channel chat history, the cape, and a stack of stability fixes for the macOS 26.x runtime executor-check bug all landed in this cycle. See `CHANGELOG.md`.

```
       🌝  ←  menu bar
    ┌─────────────────────┐
    │  MAX                │   ← chat bubble
    │                     │
    │  ▸ I noticed you've │
    │    been in Xcode    │
    │    all afternoon.   │
    │                     │
    │  M>  _              │
    └─────────────────────┘
           │
           │            ╱|
           ▼           ( ) ← Max
                        |
                       / \
```

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon
- Xcode 15+ / Swift 5.9+
- [`claude` CLI](https://claude.com/claude-code) on PATH
- Jamie (Premium) Apple voice recommended — download via System Settings → Accessibility → Spoken Content → Manage Voices

## Build & run

```bash
git clone git@github.com:peterhanily/max_clawdroom.git
cd max_clawdroom

# Build
swift build

# Run
.build/arm64-apple-macosx/debug/max_clawdroom
```

### Package a signed, notarized `.app`

One-time setup (interactive — stores credentials under the project-
scoped Keychain profile `notarytool-max_clawdroom`, optionally grants
keychain partition access so subsequent builds run silently):

```bash
./tools/setup-notarization.sh
```

Then build:

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (XXXXXXXXXX)"
./tools/package.sh
# → dist/max_clawdroom-<version>.zip + dist/max_clawdroom-<version>.dmg
```

See [`NOTARIZATION.md`](NOTARIZATION.md) for the underlying mechanics
and [`RELEASE.md`](RELEASE.md) for the appcast / Sparkle flow.

## What's new in v0.2 (current dev cycle)

- **Channels** — Max attaches to whichever clawdex / Claude Code instance you tell him to. Local loopback, Bonjour-paired LAN, Tailscale / Cloudflare / direct remote, or the legacy direct CLI. Per-channel personas (tie color, voice, expression baseline), per-channel chat transcripts, and live health probes that drive Max's expression (sad when unreachable, confused when his token's revoked).
- **Sound effects** — agent-emitted `play_sound` op with three input shapes: built-in catalog, any audio URL, or a free-text myinstants.com search. Procedural synth covers the body / UI sounds; bundled stings ship later. URL + myinstants paths are off by default and gated behind an explicit Settings toggle.
- **Cape** — back-mounted, billowing, optional color hex.
- **Baseline awareness** — `MaxClawdroomBaseline` is the single source of truth for what "normal" means. Right-click → Revert to Baseline AND the agent's `revert_to_baseline` op restore mode + body + voice + chat panel from the same struct, and Max's prompt advertises the values verbatim.
- **macOS 26.x runtime patch** — see `Sources/CompanionRuntimePatch/` for the dyld interpose + constructor that replaces the broken `swift_task_isMainExecutor` family with `pthread_main_np` checks.

## Features

**Memory & context**
- Per-project memory (JSONL under `~/Library/Application Support/Companion/memory/<cwd-hash>/`) — observations, preferences, journal, topic threads
- `[env]` block injected per turn: time, date, frontmost app, mode, battery, display topology, git SHA, accessibility flags
- `[editor]` block via the macOS Accessibility API: document path, cursor line, selection
- Tool-result pipe — Max sees stdout/stderr of his own tool calls on the next turn

**Soul**
- `propose_soul_patch` — Max queues amendments to his own system prompt; user reviews in a dedicated window before accepting
- Session journal — on chat close with ≥3 turns, Max writes a persistent observation
- Preference learning — voice/gravity/mode/autonomy flips aggregated into a prompt block so Max grounds proposals in observed patterns

**Conversation**
- Per-cwd session persistence; `--resume <session-id>` passthrough to claude-code
- Clock-menu in chat header lists recent conversations
- `farewell` op — Max waves, chat closes

**Autonomy**
- Morning greeting on first launch in 6–10 am window after a >6 h shutdown
- Idle variants: active-ambient / quiet-idle / welcome-back based on `CGEventSource` idle time
- Monthly summary on first launch of a new calendar month

**Appearance (agent-authored)**
- Body patterns: `stripes`, `polka`, `plaid`, `houndstooth`, `static`, `gradient`, `solid` on any part
- Hair styles: pompadour, crew, afro, bob, mohawk, bald
- Grooming overlays: stubble, moustache, goatee, beard
- Body / face morphs: physique (lanky/default/stocky), nose / brow scale
- Rag-doll mode, CRT scanline effect (opt-in), chat chrome theming (9 color channels)

**Voice**
- Apple `AVSpeechSynthesizer`, Premium voices only (Jamie default)
- Max Filter DSP: +220¢ pitch, digital distortion, delay, presence EQ
- Confidence-gated rate — speech slows when token hesitation is high
- Mute mid-sentence with buffer; unmute to resume

**Accessibility**
- VoiceOver stage announcements
- Dynamic Type (`@ScaledMetric`)
- Caption-only mode (big bottom-screen bar, TTS silenced)
- High-contrast theme (auto + agent-settable)
- Reduce-motion compliance

**Sensor awareness**
- Lid close → Max goes to sleep (tired expression, voice stops)
- Lid open / wake → Max wakes up and greets
- Fling Max across the screen quickly → he gets jostled
- System notifications when Max queues a soul proposal (visible even when chat is closed)

**Modes**
Auto-detected or user-pinned: laptop / desktop / tv / meeting. Each preset applies scale, panel anchor, and a prompt register hint.

## Menu bar

```
🌝
 ├─ Max
 ├─ Summon                   ⌥Space
 ├─ Max's Proposals
 ├─ Behaviour  ▸
 │   ├─ Gravity              ⌥⌘G
 │   ├─ Autonomy
 │   └─ Mode  ▸
 ├─ Appearance  ▸
 │   ├─ Voice  ▸
 │   ├─ Accessibility  ▸
 │   └─ CRT Effects (experimental)
 ├─ Help  ▸
 │   ├─ Show Welcome…
 │   └─ Take the Tour…
 ├─ Settings…                ⌘,
 ├─ Debug  ▸
 └─ Quit                     ⌘Q
```

## Agent ops

Max emits `[action]{"op":"…", …}[/action]` blocks. They're parsed out of the stream before display; every mutation is ⌘Z-undoable.

| Category | Ops |
|---|---|
| Body | `set_part_color`, `set_part_pattern`, `set_hair`, `set_grooming`, `set_physique`, `set_face_morph`, `set_scale`, `set_expression` |
| Motion | `walk`, `walk_to_editor`, `look_around`, `jitter`, `greet`, `wave`, `beckon`, `point_forward`, `point_at_line`, `point_at_cursor`, `shrug`, `nod`, `shake_head`, `farewell` |
| Chat chrome | `set_chat_color` (9 targets: panel / border / text / user / assistant / prompt / cursor / input / send) |
| Voice | `set_voice`, `set_voice_filter`, `mute_voice` |
| Memory | `remember`, `set_preference`, `forget`, `write_journal` |
| Soul | `propose_soul_patch` |
| Settings | `set_mode`, `set_gravity`, `set_accessibility_mode`, `reset_colors` |
| Bindings | `bind`, `unbind`, `clear_bindings` — wire telemetry signals to body-part reactions |

## Architecture

```
App/            NSApplication + delegate, overlay lifecycle
Overlay/        Per-screen transparent NSWindow + SCNView
Pet/            Character rig, expressions, gestures, walk cycle
Pet/Forms/      Swappable character styles (BroadcasterForm = Max)
Pet/Hair/       Hairstyle + grooming + physique builders
Chat/           ChatSession (streaming), ChatView (SwiftUI), persistence
Actions/        ActionParser + ActionDispatcher
Memory/         Per-cwd MemoryStore, PreferenceLearner
Soul/           SoulPatchQueue, SoulHistory, review window
Environment/    [env] + [editor] snapshot builder
Editor/         Accessibility API bridge
Voice/          Apple TTS + MaxVoiceEffects DSP chain
Sensors/        Lid-close/wake detection + fling-tap proxy
Notifications/  UNUserNotificationCenter wrapper
Mode/           Device-topology detection + named presets
Tour/           Guided first-run demo
Autonomy/       Event-driven silent-prompt controller
Telemetry/      Signals + bindings engine
```

## License

Private / not yet decided.

## Acknowledgements

- [Claude Code](https://www.anthropic.com/claude-code) — the backend
- Max Headroom (1985) — the aesthetic
