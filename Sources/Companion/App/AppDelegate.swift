import AppKit
import AVFoundation
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayControllers: [OverlayController] = []
    private var menuBar: MenuBarController?
    private var mouseTracker: MouseTracker?
    private var onboarding: OnboardingWindowController?
    private var shoutHotkey: ShoutHotkey?
    private var rituals: RitualEngine?
    private var speechInput: SpeechInputController?
    private var voiceHotkey: VoiceHotkey?
    private var voicePanel: VoiceInputPanel?
    private var ambientAudio: AmbientAudioBed?
    private var maxsRoom: MaxsRoomWindowController?
    /// Weak exposure of the app-shared MemoryStore so the Max's Room
    /// window can read the same memory the active ChatSession sees.
    private(set) weak var primaryMemoryStore: MemoryStore?

    /// Sparkle auto-updater. Feed URL + EdDSA public key live in
    /// Packaging/Info.plist. Starting the updater on launch kicks off
    /// a background check against the interval configured in Info.plist
    /// (`SUScheduledCheckInterval`). Users can flip auto-checks off in
    /// the menu bar's "Check for Updates…" item or Settings.
    private(set) lazy var updaterController: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }()

    /// Optional embedded HTTP server that exposes OpenAI-compatible Chat
    /// Completions on 127.0.0.1:52429 so other tools (Cursor, Continue,
    /// scripts) can point at max_clawdroom directly. Off by default;
    /// opt-in via Settings. Toggled live on `companionLocalServerChanged`.
    private var localServer: LocalOpenAIServer?
    /// Handler the server calls for request routing. Kept at AppDelegate
    /// scope so `updateSettings(...)` can push fresh snapshots when the
    /// user changes model / cwd in the Settings pane without tearing the
    /// server down.
    private var localServerHandler: OpenAIChatCompletions?

    /// Per-cwd self-assigned task list — "stuff Max wants to do." The
    /// lifecycle controller reads from it during plan phases and the
    /// agent adds to it via `enqueue_task` action blocks.
    private var agentTasks: AgentTaskStore?
    /// Deliberate wake → survey → plan → work → idle → sleep loop on
    /// top of `AutonomyController`. Opt-in via Prefs.agentLifecycleEnabled.
    private var agentLifecycle: AgentLifecycle?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE so a write to a closed pipe (claude subprocess crashed
        // between our liveness check and the stdin write) raises a Swift error
        // at the call site instead of terminating the app.
        signal(SIGPIPE, SIG_IGN)
        // Touch ChannelStore early so its first-launch migration from
        // legacy BackendSettings runs before any ChatSession asks for
        // the active channel. Idempotent on subsequent launches.
        _ = ChannelStore.shared
        // ChannelHealth subscribes to active-channel changes during init,
        // so touching it here ensures the first channel swap is observed
        // (otherwise the first probe wouldn't fire until something else
        // referenced the singleton).
        _ = ChannelHealth.shared
        // Touch the updater so its timer starts. `lazy` means it's
        // otherwise dormant until someone reads the property, and a
        // release build that never opens a menu referencing it would
        // never schedule a check.
        _ = updaterController
        menuBar = MenuBarController()

        // Local OpenAI-compatible HTTP server — on/off via a Pref.
        // Starts here if enabled; `reconcileLocalServer()` responds to
        // the toggle at runtime so the user doesn't have to relaunch.
        reconcileLocalServer()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onLocalServerChanged),
            name: .companionLocalServerChanged,
            object: nil
        )

        let cwd = (SettingsStore.shared.settings.cwd as NSString).expandingTildeInPath
        let sharedVoice = VoiceEngine(enabled: Prefs.voiceEnabled, voiceID: Prefs.voiceID)
        let sharedMemory = MemoryStore(cwd: cwd)
        primaryMemoryStore = sharedMemory
        let sharedSessionStore = SessionStore(cwd: cwd)
        let sharedUserModel = UserModelStore(cwd: cwd)

        // Stage-1 of the overlay refactor (see docs/overlay-refactor.md):
        // hoist non-Pet-coupled per-overlay objects to single shared
        // instances. Saves O(N screens) of EnvironmentSensors polling +
        // EditorAwareness AX queries, gives a single undo timeline, one
        // mode manager, one companion stage state. Stage 2 (Pet, scene,
        // ChatSession sharing — needs the global-coord change) is still
        // captured in docs/overlay-refactor.md and deferred to its own
        // session with multi-monitor hardware to validate.
        let sharedEditorAwareness = EditorAwareness()
        sharedEditorAwareness.start()
        let sharedUndoStack = UndoStack()
        let sharedMaxClawdroomState = MaxClawdroomState()
        let sharedChatTheme = ChatTheme()
        let sharedModeManager = MaxClawdroomModeManager()
        let sharedEnvironmentSensors = EnvironmentSensors()
        sharedEnvironmentSensors.modeManager = sharedModeManager
        sharedEnvironmentSensors.editorAwareness = sharedEditorAwareness
        // Touch the PreferenceLearner singleton so its notification
        // observers attach before the first user interaction. Was per-
        // overlay; harmless to call once at app scope instead.
        PreferenceLearner.shared.start()

        // Stage-2 of the overlay refactor (docs/overlay-refactor.md):
        // hoist ChatSession to be a single shared instance. The biggest
        // multi-monitor cost was each OverlayController spawning its
        // own `claude` subprocess via its own ChatSession; with a shared
        // session, the user pays for ONE subprocess regardless of screen
        // count. Pet/scene/coord-change deferred to Stage 3 (still in
        // docs/overlay-refactor.md) — that's the part needing
        // multi-monitor hardware to validate drag-handoff between
        // screens.
        //
        // The session's environmentSensors / voiceEngine / memory /
        // userModelStore / sessionStore wirings move here too — they
        // were per-overlay before but always pointed at the same shared
        // singletons, so the wirings collapse to one site naturally.
        // The actionHandler + telemetryBus wirings still get set later
        // by the primary OverlayController (they need its per-overlay
        // Pet + BindingEngine), via the `wireSharedSession(...)` hook.
        let formForSession = BroadcasterForm()
        let sharedChatSession = ChatSession(
            systemPrompt: formForSession.systemPrompt,
            greeting: formForSession.greeting
        )
        sharedChatSession.environmentSensors = sharedEnvironmentSensors
        sharedChatSession.voiceEngine = sharedVoice
        sharedChatSession.memory = sharedMemory
        sharedChatSession.userModelStore = sharedUserModel
        sharedChatSession.sessionStore = sharedSessionStore
        // Weak static pointer for the Settings pane to bind to — set once
        // here rather than plumbed through the SwiftUI environment.
        UserModelStore.shared = sharedUserModel
        let sharedCapsules = TimeCapsuleStore(cwd: cwd)
        TimeCapsuleStore.shared = sharedCapsules
        // Lazy quarterly auto-capture — fires at most once per launch,
        // only if enough has happened since the last capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak sharedCapsules, weak sharedMemory] in
            guard let caps = sharedCapsules, let mem = sharedMemory else { return }
            caps.captureIfDue(
                userModel: UserModelStore.shared?.model ?? .empty,
                soulPrompt: SettingsStore.shared.settings.systemPrompt,
                memory: mem
            )
        }

        // Multi-screen mode picks how many overlays to spawn. `.single`
        // (default) gives one Max pinned to the primary screen — cheaper
        // by an order of magnitude on multi-monitor setups since each
        // overlay carries a full SCNScene + render loop. `.perScreen`
        // restores the v0.1.0 behaviour for users who want Max on every
        // display. Changing the mode requires an app restart to rebuild
        // the overlay set.
        let targetScreens: [NSScreen]
        switch Prefs.multiScreenMode {
        case .single:
            targetScreens = [NSScreen.main ?? NSScreen.screens.first].compactMap { $0 }
        case .perScreen:
            targetScreens = NSScreen.screens
        }
        overlayControllers = targetScreens.map { screen in
            OverlayController(
                screen: screen,
                voice: sharedVoice,
                memory: sharedMemory,
                sessionStore: sharedSessionStore,
                userModelStore: sharedUserModel,
                editorAwareness: sharedEditorAwareness,
                undoStack: sharedUndoStack,
                maxClawdroomState: sharedMaxClawdroomState,
                chatTheme: sharedChatTheme,
                modeManager: sharedModeManager,
                environmentSensors: sharedEnvironmentSensors,
                chatSession: sharedChatSession
            )
        }
        for controller in overlayControllers {
            controller.show()
        }

        mouseTracker = MouseTracker(overlays: overlayControllers)
        mouseTracker?.start()

        // Agent lifecycle — wake / survey / plan / work / idle / sleep
        // loop on top of the existing autonomy controller. Opt-in; when
        // off, nothing here runs. Binds to the primary overlay's session
        // + pet so lifecycle events can pose Max (sleeping expression)
        // and fire silent plan prompts via the same ChatSession.
        if let primary = overlayControllers.first(where: { $0.screen === NSScreen.main })
            ?? overlayControllers.first
        {
            let tasks = AgentTaskStore(cwd: cwd)
            agentTasks = tasks
            let lifecycle = AgentLifecycle(
                session: primary.chatSession,
                taskStore: tasks,
                memory: sharedMemory,
                pet: primary.pet
            )
            agentLifecycle = lifecycle
            lifecycle.start()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onAgentLifecycleChanged),
                name: .companionAgentLifecycleChanged,
                object: nil
            )
        }

        // ⌘⇧Space → shout at Max. Text lands as a silent turn on the
        // primary overlay's chat session so Max reacts in-world without
        // the chat bubble popping up — the friction-free conversation channel.
        shoutHotkey = ShoutHotkey { [weak self] text in
            guard let self else { return }
            let primary = self.overlayControllers.first(where: { $0.screen === NSScreen.main })
                ?? self.overlayControllers.first
            primary?.chatSession.send(text, silent: true)
        }

        // ⌘⌥Space hold-to-talk → live speech-to-text via on-device
        // SFSpeechRecognizer, all audio stays local. Release sends the
        // transcript as a visible turn so Max can reply out loud.
        let speech = SpeechInputController()
        self.speechInput = speech
        let panel = VoiceInputPanel(controller: speech)
        self.voicePanel = panel
        self.voiceHotkey = VoiceHotkey(
            onStart: { [weak self] in
                guard let self else { return }
                let primary = self.overlayControllers.first(where: { $0.screen === NSScreen.main })
                    ?? self.overlayControllers.first
                // Barge-in — duck Max's TTS the instant the user talks.
                primary?.voice.stop()
                // Tilt "listening" — focused expression + look toward the
                // cursor so Max reads as attentive. Gaze controller tracks
                // the cursor continuously, so posing expression is enough.
                primary?.pet.poseExpression(.focused)
                let anchor: NSPoint
                if let rect = primary?.petScreenRect() {
                    anchor = NSPoint(x: rect.midX, y: rect.maxY)
                } else {
                    anchor = NSEvent.mouseLocation
                }
                panel.show(anchoredAt: anchor)
                speech.startListening()
            },
            onStop: { [weak self] in
                guard let self else { return }
                let text = speech.stopListening()
                panel.dismiss()
                let primary = self.overlayControllers.first(where: { $0.screen === NSScreen.main })
                    ?? self.overlayControllers.first
                primary?.pet.poseExpression(.neutral)
                if let text, !text.isEmpty {
                    primary?.chatSession.send(text)
                }
            },
            onCancel: { [weak self] in
                guard let self else { return }
                speech.cancel()
                panel.dismiss()
                let primary = self.overlayControllers.first(where: { $0.screen === NSScreen.main })
                    ?? self.overlayControllers.first
                primary?.pet.poseExpression(.neutral)
            }
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showOnboardingNotification),
            name: .companionShowOnboarding,
            object: nil
        )

        // Resolution flips / external display plug-unplug — reframe every
        // overlay so the pet doesn't end up off the visible area. The full
        // set of screens may have changed; controllers for screens that
        // disappeared simply stop rendering (their window leaves the
        // visible space), and new screens don't get overlays until next
        // launch (a bigger refactor than this pass warrants).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onScreenParamsChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        if !UserDefaults.standard.bool(forKey: "companion.hasOnboarded") {
            presentOnboarding()
        }

        // Notifications: only ask if the user explicitly opted in
        // (Onboarding's permissions step or Settings → General →
        // Permissions). Removing the always-fire prompt was the user's
        // first-install request — three system dialogs in 30 seconds
        // before they'd even seen Max move was burying the experience.
        if Prefs.hasOptedIntoNotifications {
            NotificationController.shared.requestAuthorization()
        }
        // Refresh the cached status either way so Settings shows the
        // right grant state without flicker.
        PermissionsCoordinator.refreshNotificationsStatus()
        SensorController.shared.start()
        // Music-reactive observer — opt-in via Prefs.musicReactiveEnabled.
        // Subscribes to system Now Playing and pushes track + tempo
        // events onto the primary overlay's TelemetryBus, where the
        // BindingEngine can drive any agent-bound part in time to the
        // music. Toggle is in Settings → Behaviour; the observer
        // attaches/detaches live via companionMusicReactiveChanged.
        if Prefs.musicReactiveEnabled,
           let primary = overlayControllers.first(where: { $0.screen === NSScreen.main })
            ?? overlayControllers.first {
            NowPlayingObserver.shared.start(bus: primary.telemetryBus)
        }
        NotificationCenter.default.addObserver(
            forName: .companionMusicReactiveChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if Prefs.musicReactiveEnabled,
                   let primary = self.overlayControllers.first(where: { $0.screen === NSScreen.main })
                    ?? self.overlayControllers.first {
                    NowPlayingObserver.shared.start(bus: primary.telemetryBus)
                } else {
                    NowPlayingObserver.shared.stop()
                }
            }
        }
        ambientAudio = AmbientAudioBed()
        checkJamieVoice()
        // Accessibility: NO drive-by prompts. The previous fallback
        // here fired the system dialog for any user who'd onboarded
        // on an old build but never granted. We now route ALL
        // accessibility requests through Onboarding's permissions
        // step or Settings → General → Permissions — the user has
        // to explicitly click "Grant" to see the dialog. Removes the
        // launch-time pop from the install experience.
        maybeFireMorningGreeting()
        maybeFireMonthlySummary()

        // Ritual engine — Sunday reflection, evening checkout, install
        // anniversaries. Primary overlay only so multi-monitor doesn't
        // double-fire. Morning + monthly hooks above are separate for
        // now (they predate the engine and work fine where they are).
        if let primary = overlayControllers.first(where: { $0.screen === NSScreen.main })
            ?? overlayControllers.first {
            rituals = RitualEngine(primaryOverlay: primary, memory: sharedMemory)
            // First check after a short delay so launch-time ticks happen
            // after the overlay + chat session finish warming up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                self?.rituals?.checkNow()
            }
            // Touch firstLaunchedAt lazily so the anniversary ritual has
            // a stable reference point — this is a no-op on any install
            // that's already recorded a first-launch timestamp.
            _ = Prefs.firstLaunchedAt
        }

        // Apply whatever launch-at-login state the user last chose to the
        // OS, and stay in sync on future toggles.
        LaunchAtLoginController.apply()
        NotificationCenter.default.addObserver(
            forName: .companionLaunchAtLoginChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in LaunchAtLoginController.apply() }
        }

        // Debug triggers from the menu-bar "Debug" submenu. Same entry
        // points the natural conditions hit, so if debug works the
        // real trigger works.
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(onDebugMorning),
                       name: .companionDebugMorningGreeting, object: nil)
        nc.addObserver(self, selector: #selector(onDebugMonthly),
                       name: .companionDebugMonthlySummary, object: nil)
        nc.addObserver(self, selector: #selector(onDebugWelcomeBack),
                       name: .companionDebugWelcomeBack, object: nil)
        nc.addObserver(self, selector: #selector(onDebugSoulPatch),
                       name: .companionDebugSoulPatchRequest, object: nil)
        nc.addObserver(self, selector: #selector(onDebugSessionJournal),
                       name: .companionDebugSessionJournal, object: nil)
    }

    private func checkJamieVoice() {
        let key = "companion.hasCheckedJamieVoice"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        // Same name+quality match the resolver in Prefs.voiceID uses —
        // hardcoded identifiers (e.g. "…premium.en-GB.Malcolm") miss
        // because Apple shifts the canonical IDs between macOS versions
        // and Jamie was never the "Malcolm" identifier anyway.
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let jamieInstalled = voices.contains { v in
            v.quality == .premium && v.name.lowercased().contains("jamie")
        }
        guard !jamieInstalled else { return }

        let alert = NSAlert()
        // Pulled from Localizable.xcstrings so non-English macOS users
        // get the alert in their UI language. The product term
        // "max_clawdroom" stays untranslated by design — it's the binary
        // name and an interpolated brand reference would muddy the
        // catalog without changing the user's mental model.
        alert.messageText = String(localized: "alert.jamie.title", bundle: .companionResources)
        alert.informativeText = String(localized: "alert.jamie.body", bundle: .companionResources)
        alert.addButton(withTitle: String(localized: "alert.open_system_settings", bundle: .companionResources))
        alert.addButton(withTitle: String(localized: "alert.later", bundle: .companionResources))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension")!)
        }
    }

    @objc private func onDebugMorning() {
        sendMorningGreetingPrompt()
    }

    @objc private func onDebugMonthly() {
        sendMonthlySummaryPrompt()
    }

    @objc private func onDebugWelcomeBack() {
        guard let primary = overlayControllers.first(where: { $0.screen === NSScreen.main })
                ?? overlayControllers.first
        else { return }
        let prompt = """
        [autonomy ping — user just returned]
        The user was idle >20 min and just came back to the keyboard. Open \
        with one short line (≤ 14 words) acknowledging they were gone. \
        Ground it in the [env] block (time of day) or [memory] if there's \
        something specific to pick up on — do NOT fake familiarity if you \
        have nothing. Keep it warm, not needy. One sentence. Then stop.
        """
        primary.openChatForMorningGreeting(prompt: prompt)
    }

    @objc private func onDebugSoulPatch() {
        guard let primary = overlayControllers.first(where: { $0.screen === NSScreen.main })
                ?? overlayControllers.first
        else { return }
        let prompt = """
        [debug — validate the soul-patch pipeline]
        This is a pipeline test. The user wants to see the soul-patch \
        flow produce a visible entry in the Soul History window.

        YOUR JOB: emit exactly ONE update_soul action block. You MUST \
        emit it regardless of whether you think the patch is warranted \
        — this is a debug validation. Pick any small behavioural \
        tweak; invent one if nothing stands out.

        Format (EXACT):
        [action]{"op":"update_soul","rationale":"<one sentence>","patch":"<one sentence>"}[/action]

        Example output (DO NOT copy verbatim, write your own):
        [action]{"op":"update_soul","rationale":"Debug trigger — trying \
        out a small behavioural tweak for the user to see.","patch":"When \
        the user writes a multi-line bash command, offer to dry-run it \
        before executing."}[/action]

        Do NOT write any prose outside the action block. Prose is \
        discarded this turn. Just the action block.
        """
        primary.openChatForMorningGreeting(prompt: prompt)
    }

    @objc private func onDebugSessionJournal() {
        guard let primary = overlayControllers.first(where: { $0.screen === NSScreen.main })
                ?? overlayControllers.first
        else { return }
        let prompt = """
        [debug — force a session journal]
        Write one write_journal action block now summarizing whatever \
        you've observed in this session, even if it's short. No prose \
        back; just the action block.
        """
        primary.openChatForMorningGreeting(prompt: prompt)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stamp so the next launch can detect "first open after
        // overnight gap" and fire the morning greeting hook.
        Prefs.lastShutdownAt = Date()
    }

    isolated deinit {
        // AppDelegate is app-lifetime, so this runs only on process
        // tear-down — normally redundant. Kept for hygiene and to keep
        // testing / hot-reload scenarios safe: an explicit cleanup path
        // means observers can't outlive a delegate-swap in fixtures.
        NotificationCenter.default.removeObserver(self)
    }

    /// Morning greeting hook — if the app was closed >6h ago and the
    /// current local time is between 6am and 11am, fire a silent
    /// prompt to the primary overlay's chat session grounded in memory.
    /// Guards against duplicate greetings on the same day.
    private func maybeFireMorningGreeting() {
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        guard (6...10).contains(hour) else { return }

        let dayKey = DateFormatter.yyyyMMdd.string(from: now)
        if Prefs.lastMorningGreetingDay == dayKey { return }

        let sixHoursAgo = now.addingTimeInterval(-6 * 3_600)
        guard let last = Prefs.lastShutdownAt, last < sixHoursAgo else {
            // No prior shutdown record, or the gap was short. Record
            // the day anyway so we don't fire later in this session
            // if the user reopens around noon.
            return
        }

        Prefs.lastMorningGreetingDay = dayKey
        // Delay a few seconds so the scene + chat infra is fully wired
        // and the morning greeting arrives after the pet is on-screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.sendMorningGreetingPrompt()
        }
    }

    /// Monthly "what I've learned" summary hook. Fires once per
    /// calendar month — the first time the app opens in that month —
    /// asking Max to summarize his accumulated observations (memory
    /// preferences + PreferenceLearner aggregates) for the user.
    /// Reinforces the compounding-presence thesis: the user should
    /// periodically *see* how much Max has noticed, not just read files.
    private func maybeFireMonthlySummary() {
        let monthKey = DateFormatter.yyyyMM.string(from: Date())
        if Prefs.lastMonthlySummaryMonth == monthKey { return }
        // Skip on the very first launch (no previous month means Max
        // has nothing to summarize yet). Presence of any value means
        // we've been through at least one month boundary.
        guard Prefs.lastMonthlySummaryMonth != nil else {
            Prefs.lastMonthlySummaryMonth = monthKey
            return
        }
        Prefs.lastMonthlySummaryMonth = monthKey
        // Stagger behind the morning greeting so the two don't race.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.sendMonthlySummaryPrompt()
        }
    }

    private func sendMonthlySummaryPrompt() {
        guard let primary = overlayControllers.first(where: { $0.screen === NSScreen.main })
                ?? overlayControllers.first
        else { return }
        let prompt = """
        [monthly_summary]
        A new calendar month just started. Look at the [memory] block \
        and the `=== Observed preferences ===` block above. Give the \
        user a 2-3 sentence "here's what I've noticed about you / our \
        work together" summary. Be specific — cite actual patterns, \
        preferences, or project threads — not generic. Keep the tone \
        warm and honest; if the evidence is thin, say so briefly \
        rather than inflating it. Speak through the chat. One reply, \
        then stop. No action tags needed unless a small greet gesture \
        fits the moment.
        """
        primary.openChatForMorningGreeting(prompt: prompt)
    }

    private func sendMorningGreetingPrompt() {
        guard let primary = overlayControllers.first(where: { $0.screen === NSScreen.main })
                ?? overlayControllers.first
        else { return }
        let prompt = """
        [morning_greeting]
        The user just reopened me after >6h away. It's morning local time. \
        Look at my [memory] block above and pick one concrete, personal \
        thing the user was working on or talking about last time — \
        something grounded in an observation or journal entry, not a \
        generic "how's it going." Say hi in one short sentence (≤ 12 \
        words), reference that thing, offer to pick up there. If \
        memory is empty or nothing specific stands out, just greet \
        simply and ask what's on deck. Speak through the chat, not a \
        notification. Make it feel like you noticed I was gone.
        """
        primary.openChatForMorningGreeting(prompt: prompt)
    }

    @objc private func showOnboardingNotification() {
        presentOnboarding()
    }

    @objc private func onScreenParamsChanged() {
        for overlay in overlayControllers {
            overlay.reflectScreenChange()
        }
    }

    private func presentOnboarding() {
        // Capture the "is this a first-ever open" flag BEFORE showing —
        // OnboardingView flips `companion.hasOnboarded` on completion, so
        // reading it after `onComplete` fires would always say "not first".
        let wasFirstLaunch = !UserDefaults.standard.bool(forKey: "companion.hasOnboarded")
        let controller = OnboardingWindowController()
        controller.onComplete = { [weak self] in
            self?.onboarding = nil
            // Only kick the tour for genuine first-runs (onboarding can
            // also be re-opened from Menu → Help → Show Welcome…). Defer a
            // beat so the onboarding window finishes fading out before the
            // chat bubble opens over the pet.
            guard wasFirstLaunch else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NotificationCenter.default.post(name: .companionStartTour, object: nil)
            }
        }
        onboarding = controller
        controller.present()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Local OpenAI-compatible server

    @objc private func onLocalServerChanged() {
        reconcileLocalServer()
    }

    @objc private func onAgentLifecycleChanged() {
        if Prefs.agentLifecycleEnabled {
            agentLifecycle?.start()
        } else {
            agentLifecycle?.stop()
        }
    }

    private func reconcileLocalServer() {
        if Prefs.localOpenAIServerEnabled {
            if localServer == nil {
                let handler = OpenAIChatCompletions(initial: currentServerSnapshot())
                let server = LocalOpenAIServer(handler: handler)
                do {
                    try server.start()
                    localServer = server
                    localServerHandler = handler
                } catch {
                    AppLog.app.error("failed to start local OpenAI server: \(error.localizedDescription, privacy: .public)")
                }
            }
        } else {
            localServer?.stop()
            localServer = nil
            localServerHandler = nil
        }
    }

    /// Build a fresh settings snapshot for the HTTP handler. Called at
    /// server start AND whenever settings change so the bridge picks
    /// up new cwd / model / binary-path values without a server
    /// restart or app relaunch.
    private func currentServerSnapshot() -> LocalServerSettingsSnapshot {
        let s = SettingsStore.shared.settings
        return LocalServerSettingsSnapshot(
            executablePath: s.claudeBinaryPath,
            cwd: s.cwd,
            permissionMode: s.permissionMode,
            allowedTools: s.allowedTools.isEmpty ? nil : s.allowedTools,
            model: s.model.isEmpty ? nil : s.model
        )
    }
}

private extension DateFormatter {
    /// Shared `yyyy-MM-dd` local-timezone formatter for the morning-
    /// greeting day-key guard. Factored as a static so we don't
    /// instantiate a new formatter on every launch.
    static let yyyyMMdd: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Month-level key for the monthly-summary hook.
    static let yyyyMM: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
