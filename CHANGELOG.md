# Changelog

All notable changes to `max_clawdroom` are documented here.

Versioning follows [SemVer](https://semver.org). This is an alpha — expect breaking changes across 0.x releases.

## [Unreleased]

## [0.3.1] — 2026-05-02

### Fixed
- **Character picker now live-previews on the actual overlay.** The 🎲 dice button mutated only the picker's local state — it never called `onCommit`, so the on-screen Max never reflected a roll, and clicking "Next" before "Keep this one" silently discarded it. Same shape inside the Custom… sheet: dropdown changes didn't propagate to the live Pet. The dice button now commits each roll, and `CustomCharacterSheet` fires a new `onPreview` callback on every outfit / chat-look change so the live Pet + ChatTheme update as you tweak. Name field still commits only on dismiss (per-keystroke would thrash UserDefaults and there's no visible re-render mid-type).
- **Sparkle signature account.** The keychain has two `https://sparkle-project.org` entries — a default `ed25519` account and the `max_clawdroom` account whose pubkey matches `Info.plist`'s `SUPublicEDKey`. Without `--account max_clawdroom`, `sign_update` silently picks the wrong key and Sparkle rejects the update with "improperly signed". `RELEASE.md` checklist now spells the flag out.

## [0.3.0] — 2026-05-01

### Added — Character picker
- **Onboarding character step** — new step between welcome and connect. Two cards (`Max` / `Custom…`) plus an `🎲 I'm feeling lucky` button. Lucky rolls a name + outfit + chat-theme triple in place; the user can roll repeatedly before committing via "Keep this one" or tweaking via "Customize…". Custom sub-sheet exposes name field, full `OutfitPreset` dropdown (25 cases), and a new `ChatThemePreset` dropdown (4 cases).
- **`ChatThemePreset` enum** — `classic` (CRT default — byte-identical to `ChatTheme.resetToDefaults()`), `minimal`, `terminal`, `comic`. Snapping a preset reassigns every `@Published` channel on `ChatTheme` and re-runs the high-contrast accessibility override; agent's per-channel `set_chat_color` overrides still work after the snap.
- **Settings → Character row** — same `Max` / `Custom` / `🎲` picker mirrored into General tab so the choice is reversible post-onboarding.
- **`BackendSettings` schema v2** — adds `characterPreset` + optional `customCharacter`. Pre-v2 saves decode with `.max` and `nil` (no behaviour change for existing installs). Apply path lives on `SettingsStore.applyCharacter(_:)` (one shared mutator for both onboarding + Settings), which posts `companionAppliedCharacter`; `AppDelegate` forwards outfit to every overlay's `Pet` and theme to the shared `ChatTheme`.

### Added — Release tooling
- **Post-notary smoke-launch guard in `tools/package.sh`** — runs the freshly-stapled binary for 3s before building artefacts. Catches dyld / framework / runtime-patch regressions that pass notary but crash on launch. Six such bugs slipped through to v0.2.0; this gate prevents the next class of them. `SKIP_SMOKE=1` to override.

### Changed
- **Appcast release-notes URL** — drops `.html` (`releases/<VERSION>` instead of `releases/<VERSION>.html`). Cloudflare Pages serves the same content; the trailing form 307'd.

### Fixed
- **`MaxClawdroomIdentity.sanitise`** — the C0/C1 control-character strip used a nested `for scalar in ch.unicodeScalars { … continue }` whose `continue` only skipped the inner scalar loop, leaving the character to fall through and append. Replaced with `unicodeScalars.contains(where:)` so the skip applies to the outer character loop. Not exploitable (the explicit disallowed-char Set already filtered CR/LF/TAB), but the dead branch was misleading.

## [0.2.0] — 2026-04-30

First public release. GitHub repo public, Sparkle-signed DMG live on the
[website](https://maxclawdroom.app), Apache 2.0 licensed. Everything below
shipped between v0.1.0 (private) and today.

### Added — Channels (multi-host backend routing)
- **`Channel` abstraction** — Max can attach to any OpenClaw / clawdex on demand. Three transport tiers: `.local` (loopback), `.lan` (Bonjour-paired with 6-digit code, ported from the TV companion), `.remote` (Tailscale / Cloudflare Tunnel / direct host:port + bearer). `.claudeCodeCLI` retains the legacy direct-subprocess path. All three OpenAI-SSE tiers share `OpenAIHTTPBackend` with per-channel URL + bearer.
- **Menu bar Channels submenu** — kind glyphs (💻 / 📡 / ☁️ / ▶︎), ⌘1–⌘9 hotkeys, top-level title shows the active channel + a health badge (● live / ◐ slow / ○ unreachable / ✕ unauthorized). Settings → Channels gives a list with Make Active / Remove / Add Channel… (Local / LAN / Remote tabs, each with reachability test).
- **Per-channel personas** — tie color, chat colors, voice id + filter, baseline expression, optional greet gesture. On channel switch, Max physically transforms — wave, color swap, voice change — via existing action ops, no new dispatch logic.
- **Per-channel transcripts** — every saved `SessionRecord` carries a `channelID`; channel switch saves the leaving record then loads the new channel's most recent. Legacy untagged records surface in whichever channel the user looks at first. New `Prefs.resumeTranscriptOnChannelSwitch` (default true) for users who want each channel ephemeral.
- **`ChannelHealth` probe** — 15s `GET /v1/models` on the active channel. State drives both a status badge and Max's expression: live = baseline, slow = focused, unreachable = sad, unauthorized = confused. Stream-side 401 flips state immediately without waiting for the probe tick. CLI channels skip probing.

### Added — Sound effects + soundboards
- **`SoundEngine`** — single shared `AVAudioEngine` + 6-node player pool, per-name buffer cache, master gain follows `Prefs.soundEffectsVolume`. Per-node format tracking with `node.stop()/reset()` before reconnect so mixing 44.1kHz mono procedural buffers with 44.1kHz stereo MP3s doesn't trip `scheduleBuffer` NSExceptions.
- **`ProceduralSounds`** — ~25 synth recipes (sine/square blips, sweeps, noise taps, arpeggios) covering footsteps, blinks, mood pips, glitch swoops, error bonks, stand-in stings. Zero asset bytes.
- **`SoundReactor`** — wires action ops + notifications to the engine: `walk → footstep`, `set_expression "amused" → chime_soft`, `hold_prop wizard_hat → magic_shimmer`, `set_mode tv → tv_static_in`, channel swap → `glitch_swoop`, auth-fail → `error_bonk`, soul absorbed → `fanfare_tiny`. TTS ducking polls `AnySpeechSynthesizerActive.isSpeaking` and drops category gains to 30% while voice is speaking.
- **`play_sound` agent op** — three input shapes: built-in catalog `name`, generic `url`, or `myinstants:"<query>"`. URL + myinstants paths gated by `Prefs.allowAgentAudioFetch` (default off). `RemoteAudioFetcher` enforces 2 MB cap, 5 s timeout, audio-only Content-Type, in-memory only. `MyInstantsLookup` is a tiny scrape helper — no MCP dependency, same legal posture as a browser loading a URL.
- **Menu**: "Mute voice" → "Silence Max" (⌥⌘V flips both voice + sound effects together via the menu handler; per-feature Settings toggles work independently).

### Added — Cape, baseline, polish
- **Cape prop** — back-mounted, 5 drape panels with independent billowing, optional `color` hex arg (default heroic red). Conflicts with jetpack/tentacles (single back-mount slot).
- **`MaxClawdroomBaseline`** — single source of truth for canonical defaults (mode, outfit, hair, grooming, physique, expression, glasses, props, scale, body colors, voice + filter, chat panel + font + background image). The right-click "Revert to Baseline" menu and the new `revert_to_baseline` agent op both read from this one struct, and the system prompt advertises the values verbatim so Max knows what "look normal" means concretely. `reset_chat_theme` op also added for chat-only resets.
- **Diagnostics panel** — Settings → General → Diagnostics. "Copy last hour" pulls process logs from `OSLogStore` (no entitlement needed for own-PID), formats one-line-per-entry with timestamp / level / category / message, copies to clipboard. "Open Console" / "Show Application Support" complete the surface.
- **Tabbed Settings** — 16 sections collapsed to 5 tabs (General · Channels · Mind · Voice & Look · Behaviour). Legacy "Agent Backend" picker removed; CLI fields render only when a `.claudeCodeCLI` channel exists. Window resizable.
- **First-run polish** — onboarding 3 steps → 5 (Welcome / Connect / Permissions / Soul / Tour). Connect step detects `claude` CLI on disk and offers one-click "Start local server"; Permissions step explains Accessibility before showing the system dialog; final step prompts "Take the tour?" which auto-fires `TourController` after a 0.3s settle.

### Added — Permissions overhaul
- **`PermissionsCoordinator`** — single shared status/request surface for Accessibility / Notifications / Microphone / Automation. Onboarding's permissions step is the only proactive surface; nothing fires a system permission dialog at launch any more.
- **No more drive-by prompts** — `NotificationController.requestAuthorization()` is now gated on `Prefs.hasOptedIntoNotifications` (default false). The legacy AppDelegate accessibility fallback is removed entirely. Three system dialogs in 30 seconds is gone.
- **`FeatureSuggester`** — Max's system prompt includes a small block listing optional-but-OFF features (voice in/out, sound effects, autonomy, music-reactive, weather grounding, agent audio fetch, soul auto-apply). The prompt explicitly says "suggest at most one, only when contextually relevant — never list, never enumerate, never lead a reply with a suggestion." Gated on `Prefs.allowMaxToSuggestFeatures` (default true). Settings → General → Permissions has the toggle.
- **Settings → General → Permissions section** — current grant state per permission with Grant / Open System Settings buttons.

### Added — Tests + tooling
- **`CompanionTests` target** — 25 cases across `StripSystemBlocksTests`, `ChannelStoreTests`, `MaxClawdroomBaselineTests`. Coverage maps directly to bugs shipped in this session (`Human:` leak families, transcript prefix, bracket pair / XML, channel kind raw-value stability, baseline op-set membership). `swift test` runs in <10ms.
- **`tools/build-icon.swift` + `tools/build-icon.sh`** — renders the 🌝 glyph at 10 sizes into `Packaging/AppIcon.icns`. `package.sh` copies it into `Contents/Resources/` and re-renders if missing. Bundle now ships with a real Finder/Launchpad/Spotlight icon.
- **`tools/setup-notarization.sh`** — one-shot interactive setup. Stores Apple credentials under the project-scoped Keychain profile `notarytool-max_clawdroom` (never `notarytool` plain — avoids cross-app collision). Optionally grants `apple-tool:` / `apple:` / `codesign:` partition access so subsequent `package.sh` runs don't pop password prompts mid-build. Verifies the Developer ID Application cert is installed.

### Fixed
- **macOS 26.x runtime executor-check kill switch.** New `CompanionRuntimePatch` C target installs three dyld interpose records (`swift_task_isCurrentExecutor`, `…WithFlags`, `swift_task_isMainExecutor`) plus a `__attribute__((constructor))` that overrides `swift_task_isMainExecutor_hook`. Each replacement returns `pthread_main_np() != 0` instead of going through the broken `objc_msgSend`-on-vtable lookup the system runtime does. Kills the entire family of crashes — `_ButtonGesture.internalBody.getter`, `NSEvent` monitors, NSTimer callbacks, NSWindow `@objc` getters, SwiftUI body closures — in one drop. Revert when Apple ships the runtime fix.
- **`stripSystemBlocks` `Human:` leaks** — bracket/JSON early-out was bypassing the transcript-prefix strip when the buffer contained no `[`/`{`/`"`; `Human: Hello there!` landed unstripped in chat AND voice. Strip + lookahead now always run. Streaming partial-prefix lookahead trims trailing `Human` / `Assistant` / `User` / `System` words so the voice engine doesn't speak "human" before the colon arrives.
- **Per-channel chat session interrupt-on-user-send** — typing a new message while Max is streaming now cancels the in-flight reply (commits partial text) and starts the new turn. Silent autonomy turns still respect the guard so they don't self-collide.
- **Auto-retry on transient stream errors** — single transparent retry on URLError network blips, server 5xx, or claude subprocess crash, only when no user-visible text has streamed yet. 401s post `companionChannelAuthFailed` so health flips to `.unauthorized` immediately.
- **`pulsePart` no longer drifts** — bound-part scale was compounding via `scale(by:)` whenever telemetry signals fired faster than the action could complete. Now stores per-node canonical rest scale and animates to/from absolute values; arms can't ratchet up over time.
- **`SoundEngine` round-robin node selection** — `AVAudioPlayerNode.isPlaying` is sticky after first `play()`; the old `!isPlaying` filter starved the pool after 6 fires. Round-robin restored playback after the second sound.
- **`MouseTracker` mouseMoved → 200ms poll** — the `mouseMoved` `@MainActor` callback was firing hundreds of times per second, slamming the broken executor probe. Replaced with a `Timer.scheduledTimer` poll. Click-passthrough updates 5×/sec instead of per-pixel; dramatic stability improvement.
- **`AgencyStrip` follow timer** — `Task { @MainActor in }` inside the timer block was deferring or no-op'ing under the executor-hook workaround. Plain `DispatchQueue.main.async` hop now.
- **`ChatBubbleView` cursor blink** — Combine `Timer.publish().autoconnect()` chain was triggering body re-renders that hit the broken probe. Replaced with plain NSTimer.
- **Audio fetch (myinstants + URL)** — `Task { @MainActor in await URLSession.data(...) }` was deadlocking under the executor-hook workaround. Switched to URLSession completion-handler API + GCD hops; nonisolated fetcher functions; `BufferBox` `@unchecked Sendable` wrapper for the AVAudioPCMBuffer hop.
- **TV-mode subtitle strip** — bar reads `streamingDisplayText` live during streaming and re-runs `stripSystemBlocks` defensively over committed text. TV marquee and chat bubble can no longer disagree about cleaned content.
- **Cape sized to actual torso** (5 panels × 26 wide spanning x ∈ {-46…+46}, height 120, mid-thigh drape). Earlier it was sized for an imagined 60-wide torso and hidden behind the body.
- **`pointForward` gesture** — old straight-arm-forward silhouette read as a fascist / Roman salute, especially on the left arm. Replaced with shoulder near-vertical + elbow forward bend; reads as a clear "look up at this" raised-hand point.
- **Chat-bubble border softened** — strokeBorder opacity 0.9 → 0.35, lineWidth 1 → 0.6. Curved corners no longer read as floating arcs.
- **WorkStateEffects opacity** — deepFocus 0.97 → 1.0 (signalled via scale 0.97 + focused expression), ambient 0.85 → 0.95. Max no longer reads as faintly transparent during ordinary working sessions.

### Changed
- Renamed all 11 `Companion`-prefixed types to `MaxClawdroom`-prefixed (`MaxClawdroomAction`, `MaxClawdroomContext`, `MaxClawdroomMode`, `MaxClawdroomState`, etc.). Cosmetic only — UserDefaults keys, file paths, Keychain accounts, Bonjour service type, SPM target name, and bundle resource name are untouched (would need a one-shot data migration to rename without losing user state).
- System prompt updated to refer to the app as `max_clawdroom` (was "Companion").
- Sound effects independent of voice mute by default — ⌥⌘V "Silence Max" still kills both via the menu handler, but per-feature Settings toggles work independently.

### Security
- **Soul-patch review-by-default + content filter** — `update_soul`/`propose_soul_patch` ops now ENQUEUE for user review (was: auto-apply). New `Prefs.soulAutoApply` (default off) restores the auto-apply path for users who explicitly want it. Both paths run a deny-list against ~25 prompt-injection / exfiltration phrases and a 30-patch-per-30-days monthly cap on top of the existing 3/hr rate limit. Rejected patches surface a chat-visible reason and post a system notification.
- **Accessibility-bridge sensitive-app denylist** — `AccessibilityBridge` now refuses to snapshot AX state from password managers (1Password, Bitwarden, KeePassXC, Keychain Access, Dashlane, LastPass), mail clients (Apple Mail, Outlook, Airmail, Spark, Superhuman), terminals (Terminal, iTerm, Warp, Alacritty, Kitty, Hyper, WezTerm), banking/financial apps (Mint, QuickBooks, YNAB), and secure messengers (Signal, Element). Also short-circuits whenever `IsSecureEventInputEnabled()` is true (banking/sudo/FileVault password fields). The frontmost-app name is hidden from the `[env]` block in those cases too — agent receives no signal of what the user is doing in those apps.
- **Hardened-runtime entitlements trimmed** — Removed `allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation`, and `allow-dyld-environment-variables` now that MLX is gone. `ClaudeCodeProcess.start()` now strips `DYLD_*` / `LD_*` keys from the inherited environment before spawning the `claude` subprocess so a poisoned `~/.zshrc` can't dylib-inject the child.
- **Sparkle key build-time guard** — `tools/package.sh` refuses to ship a build whose `SUPublicEDKey` is still the placeholder; override with `ALLOW_PLACEHOLDER_SPARKLE_KEY=1` for unsigned local builds.
- **SessionStore at-rest encryption** — chat sessions (which contain `[env]`/`[editor]` blocks with file paths, cursor-line text, app names, and full transcripts) are now sealed with AES-GCM via `EncryptedJSONStore` using the same Keychain-stored key MemoryStore/UserModelStore use. Legacy plaintext files auto-migrate on next save. Per-cwd dirs get `0o700`; individual files get `0o600`.
- **MemoryStore atomic-rewrite** — `appendToDisk` now actually uses the atomic full-rewrite path the previous CHANGELOG entry claimed (the old code still used `FileHandle.seekToEnd + write`, which left torn JSONL lines on crash).
- **Per-turn memory-op cap** — `remember` / `set_preference` / `write_journal` are limited to 20 calls per agent turn (resets on `onTurnStart`). Bursty or poisoned replies that try to spam memory now hit the cap and surface a single chat warning.
- **MemoryStore TTL + entry cap** — observations and journals older than 365 days roll off on the next append; total non-preference / non-topic entries cap at 5 000.

### Accessibility
- **Reduce-motion gate on dispatcher motion ops** — `walk`, `look_around`, `jitter`, `greet`, `wave`, `beckon`, `point_forward`, `shrug`, `nod`, `shake_head`, `dance`, `jump`, `spin`, `clap`, `salute`, `flex`, `facepalm`, `thumbs_up`, `bow`, `backflip`, `juggle`, `moonwalk`, `headbang`, `karate_chop`, `breakdance`, `typing`, `play_guitar`, `sip`, `reading`, `take_photo`, `pop_wheelie` all check `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` (and the per-session `Prefs.sessionReduceMotion` override). When set, the op is suppressed but `announce()` still fires for VoiceOver parity. `farewell` still posts the chat-close notification but skips the wave.
- **Reduce-motion gate on rag-doll sway** — `Pet.startRagDoll()` skips its sinusoidal limb / head sway entirely when reduce-motion is on. The `stopRagDoll()` settle still runs so toggling gravity off→on→off doesn't leave Max in a stuck pose.
- **Missing VoiceOver announcements added** — gestures that previously executed silently (`look_around`, `jitter`, `greet`, `point_forward`, `shrug`, `nod`, `shake_head`) now post `NSAccessibility` announcements with the existing `Prefs.announceStageChanges` opt-out.

### Localisation
- **`Localizable.xcstrings` scaffold** — first-class String Catalog landed under `Resources/`. Initial coverage spans menu titles, the Jamie premium-voice first-launch alert, the menu-bar tooltip, stage announcements ("X is thinking"/"X is speaking"), and soul-flow notifications. Translated into 9 macOS-popular locales: English (US), English (UK), German, French, Spanish, Italian, Japanese, Korean, Dutch, Brazilian Portuguese, Simplified Chinese. Remaining English strings will migrate incrementally; the pipeline is in.

### Added — World grounding
- **Music-reactive mode** — new `NowPlayingObserver` (`Music/NowPlayingObserver.swift`) `dlopen`s the system MediaRemote framework and publishes track / play-state / tempo events onto the `TelemetryBus`. Three new signals — `music.track_changed`, `music.play_state`, `music.tempo` (continuous, 0..1) — that the agent can `bind` to any body part, so Max's tie pulses to the beat. Off by default; toggle in **Behaviour → Music-reactive**.
- **Weather grounding** — new `WeatherSensor` polls `wttr.in` (no API key, no entitlement, IP-based location) every 30 minutes and folds a `[world]` block into the env on each turn: `[world] weather="Light rain" temp_c=12 temp_f=54 location="Edinburgh, UK"`. Lets Max flavour replies + outfit choices to what's actually outside. Off by default; toggle in **Behaviour → Weather grounding**. System-prompt prefix updated so the agent knows to read `[world]` for grounding without reciting it.
- **Window-awareness expansion** — `[context]` block now includes `tabs=N` for browsers (sum across all windows; lets Max notice tab-clutter without enumerating URLs) and `dwell_s=N` (whole seconds the same `bundleIdentifier` has been frontmost; long dwell on a docs page or Stack Overflow question is the agent's cue to proactively offer help). System-prompt prefix updated to teach both fields.

### Added
- **CRT Phase 7.2** — Full-framebuffer post-process via `SCNTechnique`: RGB chromatic aberration split, animated horizontal roll (~83 s period), and scanlines applied in a single `DRAW_QUAD` pass over the rendered scene. Metal shader compiled at runtime from bundled `crt.metal` source. Falls back to the Phase 7.1 per-material scanline modifier when no Metal device is present.
- **Sensor awareness** — `SensorController` watches `NSWorkspace.screensDidSleepNotification` / `screensDidWakeNotification` so Max reacts to lid close (goes to sleep) and lid open (wakes and greets). Fling-drag proxy fires `.companionTapDetected` when drag velocity exceeds 1200 px/s, causing Max to jitter.
- **System notifications** — `NotificationController` wraps `UNUserNotificationCenter`. Permission requested on first launch. Soul patch proposals now post a system notification so the user sees them even with the chat closed.
- **Confidence-gated speech** — `VoiceEngine.hesitation` (fed from `TelemetrySignal.tokenHesitation`) scales speech rate down by up to 60% toward `AVSpeechUtteranceMinimumSpeechRate`. Max literally slows down when uncertain.
- **Multi-monitor singleton refactor** — `VoiceEngine`, `MemoryStore`, and `SessionStore` are now created once in `AppDelegate` and shared across all `OverlayController` instances. Previously each screen had its own, causing duplicate footprint and conflicting state on multi-monitor setups.

### Changed
- Project renamed from `get_schwifty` → `max_clawdroom`. Bundle ID updated to `com.peterhanily.max_clawdroom`; binary, repo, and all user-visible strings updated accordingly.
- **Kokoro / MLX removed** — `mlx-audio-swift` dependency dropped; `LocalTTSEngine.swift` deleted; `VoiceSource` enum removed from `Prefs`. Voice is Apple `AVSpeechSynthesizer` only, using Premium voices. Jamie Premium is the default; first-launch prompt guides installation on new machines.
- `MemoryStore.appendToDisk` now uses the same atomic full-rewrite path as `rewriteDisk` instead of `FileHandle` append, eliminating the risk of a mid-write crash corrupting a JSONL line.
- `tools/build.sh` simplified to a plain `swift build` wrapper (no longer needs to compile MLX Metal shaders).

## [0.1.0] — 2026-04-21

Initial import. Everything below shipped in the pre-v0.1.0 development sprint (phases 1–4, 6, 7.1, 8 of the 2026-04-21 roadmap).

### Added — Intelligence (Phase 1)
- Per-project `MemoryStore` (JSONL under `~/Library/Application Support/Companion/memory/<cwd-hash>/`) with observations, preferences, journals, topic threads
- `EnvironmentSensors` rich `[env]` block (time, part-of-day, date, frontmost app, mode, register, idle seconds, battery, display topology, short git SHA, accessibility flags)
- `EditorAwareness` bridge over the macOS Accessibility API — per-turn `[editor]` block with document path, cursor line, cursor-line text, selection
- Tool-result pipe — stdout/stderr from agent tool calls attaches to the tool-call message and surfaces on the next agent turn

### Added — Autonomous soul (Phase 2)
- `SoulPatchQueue` — agent `propose_soul_patch` op queues user-reviewable soul amendments with rationale + patch body; rate-limited 3/hr, 10 pending max
- `SoulPatchReviewWindowController` — dedicated review window; Accept appends patch to `SettingsStore.systemPrompt` and pushes a snapshot to `SoulHistory`
- `SoulHistory` — versioned revert path with one-click rollback, visible as a Soul Growth summary card in Settings
- Session journal — silent `[session_wrap_up]` prompt fires on chat close with ≥3 turns so Max writes a persistent observation
- `PreferenceLearner` — singleton that observes voice/gravity/mode/autonomy flips, aggregates into an `=== Observed preferences ===` prompt block

### Added — Conversation lifecycle (Phase 3)
- Per-cwd `SessionStore` with 500 ms debounced JSON saves per message
- claude-code `--resume <session-id>` passthrough so picking a past conversation resumes the real server-side state
- Clock-icon menu in chat header listing up to 10 recent conversations + "New conversation"
- `farewell` action op — pet waves, stage → sleeping, chat auto-closes after ~1.4 s

### Added — Accessibility (Phase 4)
- VoiceOver stage announcements (thinking / speaking / tool name / error) via `NSAccessibility.announcementRequested`
- Dynamic Type via `@ScaledMetric` throughout chat UI
- Caption-only mode — silences TTS, surfaces replies in a big bottom-of-screen caption bar
- High-contrast theme — pure-black / white / amber palette; auto-applies when `accessibilityDisplayShouldIncreaseContrast` is set
- `set_accessibility_mode` agent op so Max can self-tune based on `[env]` flags

### Added — Performance (Phase 6)
- Adaptive `SCNView.preferredFramesPerSecond` — 60 on focused screen, 30 unfocused, 15 when `stage == .idle` and no SCNActions running
- ChatBubble follow-tracker sleeps when `hypot(current - target) < 0.5px`; `wakeTracker()` re-arms on target change
- Kokoro-82M preload at overlay init when `voiceSource == .local` so the first utterance doesn't hang on MLX warmup

### Added — Visual (Phase 7.1)
- Opt-in `CRTEffects` fragment modifier (scanline multiplier). Shader rewritten branchless + alpha-gated after the initial "pink silhouette" regression
- Menu-bar toggle: **CRT Effects (experimental)**

### Added — Wardrobe & morphs (Phase 8)
- `set_part_pattern` — 7 procedural patterns (solid / stripes / polka / plaid / houndstooth / static / gradient) painted onto any body part's materials with primary + accent color; `NSImage` tiles cached by (kind, primary, accent)
- `set_hair` — pompadour, crew, afro, bob, mohawk, bald
- `set_grooming` — clean, stubble, moustache, goatee, beard
- `set_physique` — lanky, default, stocky (non-uniform body scale)
- `set_face_morph` — single-axis Y-scale on nose or brow
- **Rag-doll mode** — gravity-off triggers sinusoidal limb + head sway on non-commensurate periods so limbs never lock in phase

### Added — Event-driven autonomy
- **Morning greeting** — first launch in 6–10 am after a >6 h shutdown fires a chat-visible greeting grounded in memory
- **Idle variants** — active-ambient / quiet-idle / welcome-back picked from `CGEventSource` idle reading on each autonomy tick
- **Monthly summary** — first launch of a new calendar month fires a visible `[monthly_summary]` prompt so Max reports what he's noticed

### Added — Chat UX
- Voice toggle icon in chat header with pause/resume buffer (60-sentence cap) so mute mid-sentence resumes properly on unmute
- Conversation picker in chat header (clock icon)
- Copy-all keyboard shortcut (⌘⇧C), right-click "Copy All" context menu, text selection enabled throughout

### Added — Branding
- Menu bar icon: 🌝 (full moon face)
- Product renamed from internal "Companion" → user-visible **get_schwifty**
- SPM executable product renamed; binary builds as `.build/arm64-apple-macosx/debug/max_clawdroom`

### Added — Debug surfaces
- Menu → Debug submenu with manual triggers: Fire Morning Greeting Now / Fire Monthly Summary Now / Fire Welcome-Back Now / Ask Max for a Soul Patch / Fire Session Journal Now
- Silent-decode failures across MemoryStore / SessionStore / SoulPatchQueue / SoulHistory / PreferenceLearner now log to stderr via `NSLog`

### Security
- `walk` distance clamped to `0…800` pixels
- `remember` / `write_journal` truncated at 10 KB; `set_preference` keys capped at 200 chars, values at 2 KB
- Soul patches rate-limited per hour + hard-capped pending queue

### Reliability
- `AccessibilityBridge` `as!` force-casts replaced with `CFGetTypeID` guards — malformed AX returns short-circuit to `nil` instead of crashing
- Window-occlusion observer pauses `Pet.startPeriodicBlink` / `startPeriodicJitter` `DispatchQueue.asyncAfter` chains when the overlay is hidden

### Known gaps
- Multi-monitor: every overlay spawns its own `ChatSession`, `MemoryStore`, `SessionStore`, `VoiceEngine`, `BindingEngine`. Should be app-level singletons; 4-monitor setups are 4× footprint today.
- MemoryStore / SessionStore writes are append-mode, not WAL-style atomic-rename. A crash mid-write can corrupt a JSONL line.
- `ActionParser` still rescans the full accumulated reply per streaming token (O(n·k)).
- Session-end journal writes to disk but isn't surfaced to the user.
- No system notification surface — Max can only speak through the chat panel.

Full deferred list is in the internal roadmap notes.
