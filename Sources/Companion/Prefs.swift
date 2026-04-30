import AppKit
import AVFoundation
import Foundation

/// Lightweight key-value preferences persisted to UserDefaults.
/// Distinct from `BackendSettings` (which covers LLM endpoint config) —
/// Prefs holds runtime behaviors (gravity, autorun, etc).
enum Prefs {
    private static let gravityKey = "companion.gravity.enabled"
    private static let voiceEnabledKey = "companion.voice.enabled"
    private static let voiceIDKey = "companion.voice.id"
    private static let voiceLanguageKey = "companion.voice.language_override"
    private static let useSpeechAnalyzerKey = "companion.voice.use_speech_analyzer"
    private static let voiceMaxFilterKey = "companion.voice.max_filter"
    private static let autonomyEnabledKey = "companion.autonomy.enabled"
    private static let autonomyIntervalKey = "companion.autonomy.interval"
    private static let captionOnlyKey = "companion.a11y.caption_only"
    private static let highContrastKey = "companion.a11y.high_contrast"
    private static let announceStageKey = "companion.a11y.announce_stage"
    private static let sessionReduceMotionKey = "companion.a11y.session_reduce_motion"
    private static let crtEffectsKey = "companion.visual.crt_effects"
    private static let launchAtLoginKey = "companion.session.launch_at_login"
    private static let firstLaunchedAtKey = "companion.session.first_launched_at"
    private static let hasRequestedAccessibilityKey = "companion.session.has_requested_accessibility"
    private static let hasShownUserModelHintKey = "companion.session.has_shown_user_model_hint"
    private static let ambientAudioKey = "companion.ambient.audio_enabled"
    private static let ambientVolumeKey = "companion.ambient.volume"
    private static let allowNonLocalSynthesisKey = "companion.privacy.allow_non_local_synthesis"
    private static let shareEnvKey = "companion.privacy.share_env"
    private static let shareEditorKey = "companion.privacy.share_editor"
    private static let shareAppContextKey = "companion.privacy.share_app_context"
    private static let lastShutdownAtKey = "companion.session.last_shutdown_at"
    private static let lastMorningGreetingKey = "companion.session.last_morning_greeting"
    private static let lastMonthlySummaryKey = "companion.session.last_monthly_summary"
    private static let banterFrequencyKey = "companion.autonomy.banter_frequency"
    private static let localServerEnabledKey = "companion.server.openai_local_enabled"
    private static let agentLifecycleEnabledKey = "companion.autonomy.lifecycle_enabled"
    private static let allowAgentImageOpsKey = "companion.agent.allow_image_ops"
    private static let soulAutoApplyKey = "companion.soul.auto_apply"
    private static let musicReactiveKey = "companion.visual.music_reactive"
    private static let weatherEnabledKey = "companion.world.weather_enabled"
    private static let maxVisibleKey = "companion.session.max_visible"
    private static let multiScreenModeKey = "companion.session.multi_screen_mode"
    private static let soundEffectsEnabledKey = "companion.audio.sound_effects_enabled"
    private static let soundEffectsVolumeKey = "companion.audio.sound_effects_volume"
    private static let allowAgentAudioFetchKey = "companion.audio.allow_agent_fetch"
    private static let resumeTranscriptOnChannelSwitchKey = "companion.session.resume_transcript_on_channel_switch"
    private static let hasOptedIntoNotificationsKey = "companion.permissions.has_opted_into_notifications"
    private static let hasOptedIntoMicrophoneKey = "companion.permissions.has_opted_into_microphone"
    private static let allowMaxToSuggestFeaturesKey = "companion.agent.allow_feature_suggestions"

    /// User explicitly opted into notifications. Default OFF — Max
    /// stays silent on launch and only fires the system "would like
    /// to send you notifications" dialog when the user toggles it
    /// on (Onboarding's permissions step or Settings → General →
    /// Permissions). Without this flag, deferred-notification call
    /// sites (morning greeting, soul patch nudges) silently no-op.
    static var hasOptedIntoNotifications: Bool {
        get {
            (UserDefaults.standard.object(forKey: hasOptedIntoNotificationsKey) as? Bool) ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: hasOptedIntoNotificationsKey)
        }
    }

    /// User explicitly opted into microphone. Default OFF — voice
    /// input still works because AVAudioSession's hold-to-talk path
    /// triggers the prompt lazily on first use, but the Settings UI
    /// uses this flag to render the toggle state without doing a
    /// privacy-DB query.
    static var hasOptedIntoMicrophone: Bool {
        get {
            (UserDefaults.standard.object(forKey: hasOptedIntoMicrophoneKey) as? Bool) ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: hasOptedIntoMicrophoneKey)
        }
    }

    /// When true (default), Max's system prompt includes a small
    /// block enumerating optional-but-OFF features so he can suggest
    /// one to the user when contextually relevant. Off → Max only
    /// uses what's already enabled. Privacy / no-upsell users flip
    /// this off.
    static var allowMaxToSuggestFeatures: Bool {
        get {
            (UserDefaults.standard.object(forKey: allowMaxToSuggestFeaturesKey) as? Bool) ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: allowMaxToSuggestFeaturesKey)
        }
    }

    /// On channel switch, restore the most recent saved transcript
    /// for the new channel (default ON). When off, every channel
    /// switch starts with a clean chat — useful for users who treat
    /// each channel as ephemeral. Posts no notification; the next
    /// `.companionActiveChannelChanged` event picks up the new value.
    static var resumeTranscriptOnChannelSwitch: Bool {
        get {
            (UserDefaults.standard.object(forKey: resumeTranscriptOnChannelSwitchKey) as? Bool) ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: resumeTranscriptOnChannelSwitchKey)
        }
    }

    /// Lets Max reach outside the bundled / procedural catalog and
    /// fetch audio from the network (a direct URL the agent provides,
    /// or a myinstants.com search query). Default OFF — same opt-in
    /// posture as `allowAgentImageOps`. When off, both the URL and
    /// myinstants paths short-circuit with a clear error message
    /// the agent can show in chat. When on, fetches go through
    /// `RemoteAudioFetcher` which enforces a 2 MB size cap, 5 s
    /// timeout, audio-only Content-Type check, and in-memory cache
    /// only (nothing on disk). Posts `companionSoundEffectsChanged`
    /// so the engine can pick up the change.
    static var allowAgentAudioFetch: Bool {
        get {
            (UserDefaults.standard.object(forKey: allowAgentAudioFetchKey) as? Bool) ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: allowAgentAudioFetchKey)
            NotificationCenter.default.post(name: .companionSoundEffectsChanged, object: nil)
        }
    }

    /// Master toggle for short SFX and music stings (footsteps, channel
    /// glitch, expression chimes, soundboard pack hits). Default ON.
    /// SoundEngine is still lazy-initialised on first play (via
    /// SoundEngine.shared), so the at-launch heap shape stays clear of
    /// the macOS 26.x executor-probe bug — the engine only spins up
    /// once Max calls `play_sound` or the user clicks Test, and by
    /// that point the runtime's main-actor closure population has
    /// settled. Posts `companionSoundEffectsChanged`.
    static var soundEffectsEnabled: Bool {
        get {
            (UserDefaults.standard.object(forKey: soundEffectsEnabledKey) as? Bool) ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: soundEffectsEnabledKey)
            NotificationCenter.default.post(name: .companionSoundEffectsChanged, object: nil)
        }
    }

    /// Master volume for the sound effects bus. 0…1, default 0.7.
    /// Independent of TTS volume (system) and ambient bed volume.
    static var soundEffectsVolume: Float {
        get {
            (UserDefaults.standard.object(forKey: soundEffectsVolumeKey) as? Float) ?? 0.7
        }
        set {
            UserDefaults.standard.set(newValue, forKey: soundEffectsVolumeKey)
            NotificationCenter.default.post(name: .companionSoundEffectsChanged, object: nil)
        }
    }

    /// Whether Max himself (the 3D character + overlay window) is shown.
    /// Independent of menu-bar presence — when hidden, the app stays
    /// running and the menu-bar icon plus chat hotkeys still work, but
    /// the overlay window is ordered out. "Summon" via the menu bar
    /// flips this back on.
    static var maxVisible: Bool {
        get {
            (UserDefaults.standard.object(forKey: maxVisibleKey) as? Bool) ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: maxVisibleKey)
            NotificationCenter.default.post(name: .companionVisibilityChanged, object: nil)
        }
    }

    /// Multi-monitor presentation mode.
    /// - `.single` — one Max instance pinned to the primary screen.
    ///   Lower CPU + GPU cost; user drags him within that screen.
    /// - `.perScreen` — one Max per `NSScreen` (the v0.1.0 default
    ///   behaviour). Heavier but lets Max appear on every display.
    enum MultiScreenMode: String, CaseIterable {
        case single
        case perScreen

        var displayName: String {
            switch self {
            case .single:    return "One Max (primary screen)"
            case .perScreen: return "One Max per screen"
            }
        }
    }
    static var multiScreenMode: MultiScreenMode {
        get {
            let raw = UserDefaults.standard.string(forKey: multiScreenModeKey) ?? ""
            return MultiScreenMode(rawValue: raw) ?? .single
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: multiScreenModeKey)
            NotificationCenter.default.post(name: .companionMultiScreenModeChanged, object: nil)
        }
    }

    /// When true, agent-emitted `update_soul` / `propose_soul_patch` ops
    /// apply directly to the live system prompt (after deny-list + rate
    /// limit + monthly cap). When false (the default), the op enqueues a
    /// proposal the user reviews in Max's Room before it takes effect.
    ///
    /// Default OFF: a single poisoned reply that slips a deny-list pattern
    /// can otherwise persist across every subsequent turn. The opt-in is
    /// for users who specifically want the "Max writes his own soul"
    /// experience and have accepted that trust trade-off.
    static var soulAutoApply: Bool {
        get { (UserDefaults.standard.object(forKey: soulAutoApplyKey) as? Bool) ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: soulAutoApplyKey)
            NotificationCenter.default.post(name: .companionSoulAutoApplyChanged, object: nil)
        }
    }

    /// When true, Max's body cadence + chat tint drift to the user's
    /// currently playing media (Now Playing). Off by default — the
    /// Now Playing observer registers a system-wide MediaRemote handler
    /// the user might not want active.
    static var musicReactiveEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: musicReactiveKey) as? Bool) ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: musicReactiveKey)
            NotificationCenter.default.post(name: .companionMusicReactiveChanged, object: nil)
        }
    }

    /// When true, Max grounds himself in current weather (and time-of-day
    /// adjustments based on it). Off by default — pulls from WeatherKit
    /// which requires an Apple ID-bound entitlement that we keep optional.
    static var weatherEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: weatherEnabledKey) as? Bool) ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: weatherEnabledKey)
            NotificationCenter.default.post(name: .companionWeatherChanged, object: nil)
        }
    }

    /// When true, the agent can ADD images to the user's library via
    /// `download_image` (fetch a URL) or `generate_image` (render a
    /// procedural pattern) action ops. Default OFF because both paths
    /// result in filesystem writes the user didn't explicitly authorise.
    /// Agent can still REFERENCE existing library images regardless of
    /// this flag — this gate only controls whether it can add new ones.
    static var allowAgentImageOps: Bool {
        get { (UserDefaults.standard.object(forKey: allowAgentImageOpsKey) as? Bool) ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: allowAgentImageOpsKey)
            NotificationCenter.default.post(name: .companionAllowAgentImagesChanged, object: nil)
        }
    }

    /// Explicit wake → survey → plan → work → idle → sleep loop layered
    /// on top of the autonomy controller. When off, autonomy still
    /// works via its periodic tick but Max has no task queue and no
    /// explicit sleeping state. When on, survey / plan / sleep run on
    /// their own cadence and Max accumulates a self-assigned task list
    /// across sessions.
    ///
    /// Default OFF — same caution as the other agent-initiated features.
    static var agentLifecycleEnabled: Bool {
        get {
            (UserDefaults.standard.object(forKey: agentLifecycleEnabledKey) as? Bool) ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: agentLifecycleEnabledKey)
            NotificationCenter.default.post(name: .companionAgentLifecycleChanged, object: nil)
        }
    }

    /// When true, max_clawdroom binds a local HTTP server on
    /// 127.0.0.1:52429 that speaks OpenAI-compatible Chat Completions,
    /// backed by the same claude CLI plumbing the app uses internally.
    /// Replaces the standalone `clawdex` Node proxy — other tools
    /// (Cursor, Continue, Python `openai` SDK, scripts) can point
    /// there directly.
    ///
    /// Default OFF. Opt-in because opening a listening port deserves
    /// a deliberate user action even on loopback.
    static var localOpenAIServerEnabled: Bool {
        get {
            (UserDefaults.standard.object(forKey: localServerEnabledKey) as? Bool) ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: localServerEnabledKey)
            NotificationCenter.default.post(name: .companionLocalServerChanged, object: nil)
        }
    }

    /// When true, the pet falls back to Form.baseY after drag-release and
    /// locomotion targets baseY on every walk. When false, the pet stays at
    /// whatever Y position you leave him at.
    static var gravityEnabled: Bool {
        get {
            (UserDefaults.standard.object(forKey: gravityKey) as? Bool) ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: gravityKey)
            NotificationCenter.default.post(name: .companionGravityChanged, object: nil)
        }
    }

    /// Whether Max speaks his replies aloud via AVSpeechSynthesizer.
    /// Default off — ship quiet, let the user turn him on.
    static var voiceEnabled: Bool {
        get {
            (UserDefaults.standard.object(forKey: voiceEnabledKey) as? Bool) ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: voiceEnabledKey)
            NotificationCenter.default.post(name: .companionVoiceChanged, object: nil)
        }
    }

    /// When true, Max's voice is routed through the DSP effect chain
    /// (pitch up + digital distortion + delay + presence EQ). Default
    /// false — the filter is an OPT-IN broadcaster effect, not the
    /// baseline. Normal Max = clean Apple Premium voice (Jamie); the
    /// filter is for character beats. Lets users (and Max himself, via
    /// `set_voice_filter`) treat off as the canonical "go back to
    /// normal" state.
    static var voiceMaxFilter: Bool {
        get {
            (UserDefaults.standard.object(forKey: voiceMaxFilterKey) as? Bool) ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: voiceMaxFilterKey)
            NotificationCenter.default.post(name: .companionVoiceChanged, object: nil)
        }
    }

    private static let speechRateKey = "companion.voice.speech_rate"
    /// Baseline AVSpeechUtterance rate (0.0–1.0). Default 0.56 — slightly
    /// above Apple's 0.5 default which feels sluggish for conversational TTS.
    /// Confidence-gating scales down from this value when hesitation is high.
    static var speechRate: Float {
        get {
            let stored = UserDefaults.standard.float(forKey: speechRateKey)
            return stored > 0 ? stored : 0.56
        }
        set {
            UserDefaults.standard.set(max(0.1, min(1.0, newValue)), forKey: speechRateKey)
            NotificationCenter.default.post(name: .companionVoiceChanged, object: nil)
        }
    }

    /// When true, AutonomyController periodically sends silent prompts
    /// to the agent so Max can act without being spoken to, and the new
    /// `ReflexController` emits zero-token micro-reactions to observed
    /// events. Default ON — without autonomy Max is visually inert, and
    /// the reflex layer alone (no LLM cost) earns its keep on most setups.
    /// Users who want a silent Max can flip it off in Settings → Autonomy.
    static var autonomyEnabled: Bool {
        get {
            (UserDefaults.standard.object(forKey: autonomyEnabledKey) as? Bool) ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autonomyEnabledKey)
            NotificationCenter.default.post(name: .companionAutonomyChanged, object: nil)
        }
    }

    /// How willingly Max speaks unprompted lines during autonomy ticks.
    /// - `.off`: action-tags only; never prose during active autonomy
    /// - `.rare`: at most one short sentence per ~3 ticks when env has
    ///   something genuinely interesting (default)
    /// - `.often`: can speak on most ticks; more chatty-friend feel
    ///
    /// Separate axis from `autonomyEnabled` — autonomy could be on
    /// with banter off (Max fiddles silently) or banter often (Max
    /// occasionally comments on your work).
    enum BanterFrequency: String {
        case off, rare, often
    }
    static var banterFrequency: BanterFrequency {
        get {
            let raw = UserDefaults.standard.string(forKey: banterFrequencyKey) ?? "rare"
            return BanterFrequency(rawValue: raw) ?? .rare
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: banterFrequencyKey)
            NotificationCenter.default.post(name: .companionAutonomyChanged, object: nil)
        }
    }

    /// Reflective autonomy tick interval in seconds. Default 300 (5 min).
    /// This is the cadence for LLM-touching ticks (mood checks, soul
    /// reflection, idle colour-shifts). Zero-token reflex reactions to
    /// observed events fire independently via `ReflexController`.
    static var autonomyInterval: TimeInterval {
        get {
            let v = UserDefaults.standard.double(forKey: autonomyIntervalKey)
            return v > 0 ? v : 300
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autonomyIntervalKey)
            NotificationCenter.default.post(name: .companionAutonomyChanged, object: nil)
        }
    }

    // MARK: - Accessibility

    /// When true, `VoiceEngine.speak` is a no-op and the subtitle bar
    /// renders Max's replies in a larger high-contrast caption style.
    /// For users who want Max's words visible but not audible.
    static var captionOnly: Bool {
        get { (UserDefaults.standard.object(forKey: captionOnlyKey) as? Bool) ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: captionOnlyKey)
            NotificationCenter.default.post(name: .companionAccessibilityChanged, object: nil)
        }
    }

    /// When true (or the system setting forces it), chat uses the pure-
    /// black-background / white-text palette with yellow accents instead
    /// of the CRT magenta/cyan.
    static var highContrast: Bool {
        get {
            let user = (UserDefaults.standard.object(forKey: highContrastKey) as? Bool) ?? false
            return user || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        }
        set {
            UserDefaults.standard.set(newValue, forKey: highContrastKey)
            NotificationCenter.default.post(name: .companionAccessibilityChanged, object: nil)
        }
    }

    /// Raw user override — distinct from `highContrast` which folds in
    /// the system flag. Used by Settings UI so the toggle reflects the
    /// user's explicit choice only.
    static var highContrastUserOverride: Bool {
        (UserDefaults.standard.object(forKey: highContrastKey) as? Bool) ?? false
    }

    /// When true, StageDriver posts NSAccessibility announcements on
    /// every stage change so VoiceOver users hear "Max is thinking" etc.
    /// Default on — cheap and unhelpful signals are dropped anyway.
    static var announceStageChanges: Bool {
        get { (UserDefaults.standard.object(forKey: announceStageKey) as? Bool) ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: announceStageKey)
            NotificationCenter.default.post(name: .companionAccessibilityChanged, object: nil)
        }
    }

    /// Opt-in CRT fragment-modifier effects (scanlines + grain) on Max's
    /// character. Off by default because the initial roll caused a
    /// pink-silhouette regression; the shader has been hardened
    /// (alpha-gated, clamped, uniforms pre-seeded) but the conservative
    /// default keeps the stock look untouched unless the user opts in.
    static var crtEffectsEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: crtEffectsKey) as? Bool) ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: crtEffectsKey)
            NotificationCenter.default.post(name: .companionCrtEffectsChanged, object: nil)
        }
    }

    // MARK: - Ambient audio

    /// When true, a low-volume pink-noise bed plays while Max is active
    /// — a subliminal CRT hum that wraps him in a vibe. Off by default
    /// because silent-is-polite; users who want it opt in via the
    /// menu bar. `AmbientAudioBed` reads this live.
    static var ambientAudioEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: ambientAudioKey) as? Bool) ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: ambientAudioKey)
            NotificationCenter.default.post(name: .companionAmbientAudioChanged, object: nil)
        }
    }

    /// Master volume for the ambient bed. 0.0–1.0, default 0.3 — well
    /// under "noticeable" so even an accidental-on is forgivable.
    static var ambientVolume: Float {
        get {
            let v = UserDefaults.standard.float(forKey: ambientVolumeKey)
            return v > 0 ? v : 0.3
        }
        set {
            UserDefaults.standard.set(max(0, min(1, newValue)), forKey: ambientVolumeKey)
            NotificationCenter.default.post(name: .companionAmbientAudioChanged, object: nil)
        }
    }

    // MARK: - Launch at login

    /// When true, the system auto-launches max_clawdroom on login. Backed
    /// by `SMAppService.mainApp` (macOS 13+) — the launch service is
    /// registered/unregistered with the OS via `LaunchAtLoginController`
    /// whenever this toggle flips. The Prefs key mirrors the OS state so
    /// the menu-bar toggle's initial state matches what Login Items says.
    static var launchAtLogin: Bool {
        get { (UserDefaults.standard.object(forKey: launchAtLoginKey) as? Bool) ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: launchAtLoginKey)
            NotificationCenter.default.post(name: .companionLaunchAtLoginChanged, object: nil)
        }
    }

    // MARK: - Privacy (non-local synthesis opt-in)

    /// When true, `UserModelSynthesiser` is allowed to ship raw memory
    /// entries to the OpenAI-compatible HTTP backend even when its URL
    /// isn't `127.0.0.1` / `localhost`. Off by default — memory entries
    /// can include whatever the user has discussed with Max, so the
    /// stock assumption is "stay on-device." Users who point at a
    /// remote endpoint (their own hosted endpoint, a friend's Ollama,
    /// OpenAI proper) and actively want synthesis there opt in here.
    ///
    /// The Claude Code subprocess path is unaffected — that's local.
    static var allowNonLocalSynthesis: Bool {
        get { (UserDefaults.standard.object(forKey: allowNonLocalSynthesisKey) as? Bool) ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: allowNonLocalSynthesisKey)
            NotificationCenter.default.post(name: .companionPrivacyChanged, object: nil)
        }
    }

    // MARK: - Privacy (context sharing)

    /// When true, the ambient `[env]` block (time, frontmost app, git SHA,
    /// battery, display config, idle seconds) is prepended to every user
    /// message. Default on — without it Max has no situational awareness
    /// and can't react to "you've been in Slack for 20 minutes" etc. Off
    /// for users who'd rather not broadcast app-switching patterns.
    static var shareEnvBlock: Bool {
        get { (UserDefaults.standard.object(forKey: shareEnvKey) as? Bool) ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: shareEnvKey)
            NotificationCenter.default.post(name: .companionPrivacyChanged, object: nil)
        }
    }

    /// When true, the `[editor]` block (focused document path, cursor
    /// line, selection text) ships with each user turn so Max can speak
    /// about code the user is looking at. Default ON for "he noticed I'm
    /// in UserAuth.swift" behaviour; OFF if the user is working with
    /// confidential source and doesn't want selections leaving the app.
    static var shareEditorBlock: Bool {
        get { (UserDefaults.standard.object(forKey: shareEditorKey) as? Bool) ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: shareEditorKey)
            NotificationCenter.default.post(name: .companionPrivacyChanged, object: nil)
        }
    }

    /// When true, the `[context]` block carries browser URL + tab title,
    /// Finder folder, terminal / Electron window title. Default ON; turn
    /// off when you don't want window-title history ending up in logs.
    static var shareAppContextBlock: Bool {
        get { (UserDefaults.standard.object(forKey: shareAppContextKey) as? Bool) ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: shareAppContextKey)
            NotificationCenter.default.post(name: .companionPrivacyChanged, object: nil)
        }
    }

    /// Agent-settable session-scoped reduce-motion override. Layered on
    /// top of the system's `accessibilityDisplayShouldReduceMotion` flag
    /// (which MaxClawdroomState already reads); this gives the agent a way
    /// to quiet animations per-conversation without touching system prefs.
    static var sessionReduceMotion: Bool {
        get { (UserDefaults.standard.object(forKey: sessionReduceMotionKey) as? Bool) ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: sessionReduceMotionKey)
            NotificationCenter.default.post(name: .companionAccessibilityChanged, object: nil)
        }
    }

    // MARK: - Session lifecycle tracking

    /// Timestamp of the very first launch on this machine — used by the
    /// install-anniversary ritual. Stamped lazily on first read if never
    /// set (so an existing install doesn't retroactively "celebrate" a
    /// fake 7-day mark right after an update).
    static var firstLaunchedAt: Date {
        if let existing = UserDefaults.standard.object(forKey: firstLaunchedAtKey) as? Date {
            return existing
        }
        let now = Date()
        UserDefaults.standard.set(now, forKey: firstLaunchedAtKey)
        return now
    }

    /// One-shot flag for "we've already asked for Accessibility access on
    /// this install." Prevents the first-launch prompt from re-firing on
    /// every launch if the user denies — if they want to grant it later,
    /// Settings → Accessibility has a Request button.
    static var hasRequestedAccessibility: Bool {
        get { UserDefaults.standard.bool(forKey: hasRequestedAccessibilityKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasRequestedAccessibilityKey) }
    }

    /// One-shot flag for "we've shown the user-model discovery nudge."
    /// Fires after the 5th real user turn on a fresh install.
    static var hasShownUserModelHint: Bool {
        get { UserDefaults.standard.bool(forKey: hasShownUserModelHintKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasShownUserModelHintKey) }
    }

    /// Timestamp of the most recent clean app shutdown. Used by the
    /// morning-greeting hook to detect "first open after overnight gap."
    /// Updated from `applicationWillTerminate`.
    static var lastShutdownAt: Date? {
        get { UserDefaults.standard.object(forKey: lastShutdownAtKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastShutdownAtKey) }
    }

    /// Date (yyyy-MM-dd string) the last morning greeting fired. Guards
    /// against multiple greetings on the same day (e.g. app restarted
    /// twice before noon).
    static var lastMorningGreetingDay: String? {
        get { UserDefaults.standard.string(forKey: lastMorningGreetingKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastMorningGreetingKey) }
    }

    /// Month (yyyy-MM) the last "what I learned this month" summary
    /// fired. Guards against the summary firing on every launch within
    /// the first week of a new month.
    static var lastMonthlySummaryMonth: String? {
        get { UserDefaults.standard.string(forKey: lastMonthlySummaryKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastMonthlySummaryKey) }
    }

    /// Opt-in for the macOS 26+ `SpeechAnalyzer` / `SpeechTranscriber`
    /// transcription path. Off by default because the API is only
    /// available on macOS 26 and the build is currently on an older
    /// SDK — when we upgrade the toolchain we'll wire the actual
    /// Analyzer implementation and ship this flag to `true`.
    /// Callers treat this as a HINT; availability checks still gate
    /// the actual selection at runtime.
    static var useSpeechAnalyzer: Bool {
        get { (UserDefaults.standard.object(forKey: useSpeechAnalyzerKey) as? Bool) ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: useSpeechAnalyzerKey)
            NotificationCenter.default.post(name: .companionVoiceChanged, object: nil)
        }
    }

    /// Explicit voice-language override ("en-US", "en-GB", "fr-FR", etc.).
    /// When set, `VoiceEngine` hands this to `AVSpeechSynthesisVoice` in
    /// preference to `Locale.preferredLanguages.first` so a user on a
    /// Spanish system can still hear Max in English (or vice versa). nil =
    /// follow system locale.
    static var voiceLanguageOverride: String? {
        get {
            let s = UserDefaults.standard.string(forKey: voiceLanguageKey)
            return (s?.isEmpty ?? true) ? nil : s
        }
        set {
            if let v = newValue, !v.isEmpty {
                UserDefaults.standard.set(v, forKey: voiceLanguageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: voiceLanguageKey)
            }
            NotificationCenter.default.post(name: .companionVoiceChanged, object: nil)
        }
    }

    /// Selected voice identifier. Resolution order:
    ///   1. Stored UserDefaults choice (user picked one explicitly).
    ///   2. Jamie Premium (matched by name + quality, not by identifier
    ///      — the canonical com.apple.voice.premium.en-GB.Jamie ID
    ///      shifts between macOS versions and previously hardcoded
    ///      "Malcolm" missed it on every modern install, so the fallback
    ///      silently dropped through to a random Premium voice and the
    ///      user had to ask Max to switch every time).
    ///   3. Jamie Enhanced — same name match if Premium isn't installed.
    ///   4. Any en-GB Premium voice.
    ///   5. Any Premium voice.
    ///   6. Any Enhanced voice.
    static var voiceID: String? {
        get {
            if let stored = UserDefaults.standard.string(forKey: voiceIDKey) { return stored }
            let voices = AVSpeechSynthesisVoice.speechVoices()
            // Name matches are case-insensitive — Apple's `name` is
            // typically "Jamie (Premium)" or just "Jamie" depending on
            // version. Substring match handles both.
            func find(name: String, quality: AVSpeechSynthesisVoiceQuality) -> String? {
                let needle = name.lowercased()
                return voices.first { v in
                    v.quality == quality && v.name.lowercased().contains(needle)
                }?.identifier
            }
            return find(name: "Jamie", quality: .premium)
                ?? find(name: "Jamie", quality: .enhanced)
                ?? voices.first { $0.quality == .premium && $0.language.hasPrefix("en-GB") }?.identifier
                ?? voices.first { $0.quality == .premium }?.identifier
                ?? voices.first { $0.quality == .enhanced }?.identifier
        }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: voiceIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: voiceIDKey)
            }
            NotificationCenter.default.post(name: .companionVoiceChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let companionGravityChanged = Notification.Name("companion.gravity.changed")
    static let companionVoiceChanged = Notification.Name("companion.voice.changed")
    static let companionAutonomyChanged = Notification.Name("companion.autonomy.changed")
    /// Posted when any Prefs.a11y.* flag flips. UI layers subscribe to
    /// re-theme / re-size / etc. without every accessibility flag needing
    /// its own dedicated notification name.
    static let companionAccessibilityChanged = Notification.Name("companion.accessibility.changed")
    /// Posted when the CRT-effects opt-in flips. Each overlay listens to
    /// attach or detach the shader modifier on its pet.
    static let companionCrtEffectsChanged = Notification.Name("companion.crt.changed")
    /// Posted when any Prefs.share* toggle flips.
    static let companionPrivacyChanged = Notification.Name("companion.privacy.changed")
    /// Posted when the launch-at-login toggle flips.
    static let companionLaunchAtLoginChanged = Notification.Name("companion.launch.changed")
    /// Posted when the local OpenAI-compatible server toggle flips.
    /// AppDelegate listens to start/stop the listener live.
    static let companionLocalServerChanged = Notification.Name("companion.server.local.changed")
    /// Posted when the agent lifecycle toggle flips.
    static let companionAgentLifecycleChanged = Notification.Name("companion.agent.lifecycle.changed")
    /// Posted when the agent-image-ops toggle flips.
    static let companionAllowAgentImagesChanged = Notification.Name("companion.agent.images.changed")
    /// Posted when ambient-audio on/off or volume changes.
    static let companionAmbientAudioChanged = Notification.Name("companion.ambient.changed")
    /// Posted when the soul-auto-apply toggle flips. Settings panes
    /// subscribe to refresh; ChatSession reads at dispatch time.
    static let companionSoulAutoApplyChanged = Notification.Name("companion.soul.autoapply.changed")
    /// Posted when the music-reactive toggle flips. Overlays subscribe to
    /// attach/detach the Now Playing observer.
    static let companionMusicReactiveChanged = Notification.Name("companion.music.changed")
    /// Posted when the weather-grounding toggle flips. EnvironmentSensors
    /// subscribes to start/stop its WeatherKit poll.
    static let companionWeatherChanged = Notification.Name("companion.weather.changed")
}
