import AppKit
import Combine
import SceneKit

@MainActor
final class OverlayController {
    let screen: NSScreen
    let window: OverlayWindow
    let scnView: MaxClawdroomSCNView
    let scene: SCNScene
    let pet: Pet
    let locomotion: Locomotion
    let chatSession: ChatSession
    let telemetryBus: TelemetryBus
    let bindingEngine: BindingEngine
    let swarmController: SwarmController
    let editorAwareness: EditorAwareness
    let undoStack: UndoStack
    let maxClawdroomState: MaxClawdroomState
    let chatTheme: ChatTheme
    let environmentSensors: EnvironmentSensors
    let modeManager: MaxClawdroomModeManager
    let tour: TourController
    let voice: VoiceEngine
    let memory: MemoryStore
    let sessionStore: SessionStore
    let userModelStore: UserModelStore
    private var crtEffects: CRTEffects?
    private var reflex: ReflexController?
    private var soulTintDrift: SoulTintDrift?
    private var userModelSynthesiser: UserModelSynthesiser?
    private var workWatcher: WorkWatcher?
    private var annotationOverlay: AnnotationOverlay?
    private var workStateTracker: WorkStateTracker?
    private var workStateEffects: WorkStateEffects?
    private var agencyStrip: AgencyStrip?
    private var modeCancellable: AnyCancellable?
    private var hesitancyCancellable: AnyCancellable?
    private var expressionDriver: ExpressionDriver?
    private var stageDriver: StageDriver?
    private var channelStageDirector: ChannelStageDirector?
    private var soundReactor: SoundReactor?
    private var autonomy: AutonomyController?
    private var cursorGazeController: CursorGazeController?
    /// Only the primary-screen overlay owns the subtitle bar — one bar
    /// for the whole app regardless of monitor count.
    private var subtitleBar: SubtitleBarController?
    private(set) var chat: ChatBubbleController?
    /// When true, MouseTracker leaves this overlay's window clickable (ignoresMouseEvents=false)
    /// regardless of cursor position. Used during pet drag.
    var mouseEventsLocked: Bool = false
    private var dragOffset: NSPoint?
    /// Follow-mouse mode: when on, Max chases the cursor live instead of
    /// running his normal locomotion. Toggled from the right-click menu;
    /// `followMouseTimer` drives the chase at ~15 Hz.
    private var isFollowingMouse: Bool = false
    private var followMouseTimer: Timer?

    init(
        screen: NSScreen,
        voice: VoiceEngine,
        memory: MemoryStore,
        sessionStore: SessionStore,
        userModelStore: UserModelStore,
        editorAwareness: EditorAwareness,
        undoStack: UndoStack,
        maxClawdroomState: MaxClawdroomState,
        chatTheme: ChatTheme,
        modeManager: MaxClawdroomModeManager,
        environmentSensors: EnvironmentSensors,
        chatSession: ChatSession
    ) {
        self.screen = screen
        self.voice = voice
        self.memory = memory
        self.sessionStore = sessionStore
        self.userModelStore = userModelStore
        // Stage-1 of the overlay refactor (docs/overlay-refactor.md):
        // these were per-overlay before; now app-shared instances passed
        // in by AppDelegate. The fields stay `let` here so existing
        // call sites (`self.editorAwareness`, etc.) keep working without
        // a global rename — only the lifetime owner changed.
        self.editorAwareness = editorAwareness
        self.undoStack = undoStack
        self.maxClawdroomState = maxClawdroomState
        self.chatTheme = chatTheme
        self.modeManager = modeManager
        self.environmentSensors = environmentSensors
        // Stage-2: the chat session is shared across overlays so we run
        // ONE `claude` subprocess per app instead of N per screen. The
        // primary OverlayController still owns the per-overlay TelemetryBus
        // / BindingEngine / SwarmController — those drive the per-screen
        // Pet's reactivity — and wires this session's actionHandler to
        // dispatch into ITS Pet/binding context. Secondary overlays skip
        // that wiring (would clobber primary's) and their Pets are
        // decorative; agent-driven body changes show on primary only.
        // The full Pet/scene/coord-change refactor is Stage 3 in
        // docs/overlay-refactor.md.
        self.chatSession = chatSession
        self.window = OverlayWindow(screen: screen)

        let view = MaxClawdroomSCNView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.autoresizingMask = [.width, .height]
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60

        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        view.scene = scene

        let aspect = screen.frame.width / screen.frame.height
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(screen.frame.height / 2)
        camera.zNear = 0.1
        camera.zFar = 4000

        // Post-process pass — SCNCamera built-ins, runs before the CRT
        // SCNTechnique. We're deliberately NOT enabling `wantsHDR` or
        // `wantsExposureAdaptation`: the overlay window is alpha-
        // transparent, and SceneKit's HDR pipeline treats empty pixels
        // as black for auto-exposure purposes. On a scene that's mostly
        // transparent (just Max on a clear background), the exposure
        // algorithm cranks up trying to lift the "dark" frame, Max
        // clips to white, and premultiplied alpha composite makes
        // him invisible on the desktop. LDR only.
        //
        // Bloom requires HDR so we lose that one — emissive props
        // (sparkler tip, wand star, jetpack flame, eye glow) fall back
        // to their base emissive colour, which still reads as "lit"
        // thanks to the material's own emission.contents.
        //
        // SSAO, vignette, saturation, and contrast all work in LDR and
        // compose correctly against the clear background. The SSAO pass
        // is the single biggest improvement — soft occlusion in
        // creases (collar, fingers, hat brim) does the "looks 3D" work.
        // SSAO is the expensive bit — skip it entirely in Low Power Mode
        // so the overlay doesn't keep the GPU warm on battery. The pet
        // still reads as shaded because of the three-point lighting, he
        // just loses the soft cavity occlusion. `onLowPowerModeChanged`
        // below flips this live if the user toggles battery saver.
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        camera.screenSpaceAmbientOcclusionIntensity = lowPower ? 0 : 0.55
        camera.screenSpaceAmbientOcclusionRadius = 14
        camera.screenSpaceAmbientOcclusionBias = 0.03
        camera.vignettingIntensity = lowPower ? 0.15 : 0.35
        camera.vignettingPower = 1.2
        camera.saturation = 1.08
        camera.contrast = 1.04

        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(
            Double(screen.frame.width) / 2,
            Double(screen.frame.height) / 2,
            1500
        )
        scene.rootNode.addChildNode(cameraNode)
        _ = aspect

        // TV-studio lighting per v2 spec §2.2 — hard forward-upper key, small
        // shadow fill, two-point coloured rim (magenta + cyan) as ACCENTS.
        // Rim intensity is kept well below the key so 3D shading reads first
        // and the rim catches edges — overcooked rims turn everything into a
        // flat magenta silhouette.
        let key = SCNLight()
        key.type = .directional
        key.color = NSColor.white
        key.intensity = 1100
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowRadius = 2
        key.shadowSampleCount = 8
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-Double.pi / 4.5, 0, 0)
        scene.rootNode.addChildNode(keyNode)

        // Shadow fill so pure-black cavities don't swallow detail on the face.
        let fill = SCNLight()
        fill.type = .directional
        fill.color = NSColor(white: 1.0, alpha: 1.0)
        fill.intensity = 120
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.eulerAngles = SCNVector3(-Double.pi / 10, 0, 0)
        scene.rootNode.addChildNode(fillNode)

        // Left rim — magenta. Behind and slightly above the subject.
        // Rims explicitly do NOT cast shadows — at the studio angles here,
        // a shadow-casting rim puts a magenta/cyan band across the face.
        // Bumped 150→220 so the edge catches more visibly against
        // outfits other than the default teal suit; bloom on the camera
        // reads brighter magenta/cyan as "neon" rather than overbake.
        let rimLeft = SCNLight()
        rimLeft.type = .directional
        rimLeft.color = NSColor(srgbRed: 1.00, green: 0.18, blue: 0.54, alpha: 1.0)
        rimLeft.intensity = 220
        rimLeft.castsShadow = false
        let rimLeftNode = SCNNode()
        rimLeftNode.light = rimLeft
        rimLeftNode.eulerAngles = SCNVector3(Double.pi / 7, Double.pi * 0.78, 0)
        scene.rootNode.addChildNode(rimLeftNode)

        // Right rim — cyan. Opposite side.
        let rimRight = SCNLight()
        rimRight.type = .directional
        rimRight.color = NSColor(srgbRed: 0.18, green: 0.88, blue: 0.99, alpha: 1.0)
        rimRight.intensity = 220
        rimRight.castsShadow = false
        let rimRightNode = SCNNode()
        rimRightNode.light = rimRight
        rimRightNode.eulerAngles = SCNVector3(Double.pi / 7, -Double.pi * 0.78, 0)
        scene.rootNode.addChildNode(rimRightNode)

        // Warm bounce from below — tiny amber uplight that fakes a
        // ground-colour bounce. Helps undersides of the jaw / hands /
        // feet read as "lit from a real environment" instead of
        // terminator-black. Low intensity so it doesn't fight the key.
        let bounce = SCNLight()
        bounce.type = .directional
        bounce.color = NSColor(srgbRed: 1.00, green: 0.78, blue: 0.52, alpha: 1.0)
        bounce.intensity = 70
        bounce.castsShadow = false
        let bounceNode = SCNNode()
        bounceNode.light = bounce
        // Pointing up-and-slightly-forward at the subject.
        bounceNode.eulerAngles = SCNVector3(Double.pi / 3.5, 0, 0)
        scene.rootNode.addChildNode(bounceNode)

        // Ambient to lift mids so diffuse materials don't go pure black.
        // Previously at 240 which washed the figure flat; 120 keeps blacks
        // liftable without killing the key-light's shaping.
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = NSColor(white: 0.65, alpha: 1.0)
        ambient.intensity = 120
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        // IBL — metals need env to reflect. Slightly higher so lenses look
        // like glass rather than matte black holes.
        scene.lightingEnvironment.contents = NSColor(white: 0.5, alpha: 1.0)
        scene.lightingEnvironment.intensity = 0.30

        let pet = Pet(form: BroadcasterForm())
        pet.node.position = SCNVector3(
            Double(screen.frame.width) / 2,
            Double(pet.form.baseY),
            0
        )
        pet.setGlassesVisible(false)
        scene.rootNode.addChildNode(pet.node)

        self.scene = scene
        self.scnView = view
        self.pet = pet
        self.locomotion = Locomotion(pet: pet, bounds: screen.frame)
        let bus = TelemetryBus()
        self.telemetryBus = bus
        self.bindingEngine = BindingEngine(bus: bus, pet: pet)
        self.swarmController = SwarmController(
            bus: bus,
            scene: scene,
            mainPet: pet,
            screenBounds: screen.frame
        )
        // EditorAwareness, UndoStack, MaxClawdroomState, ChatTheme,
        // MaxClawdroomModeManager, EnvironmentSensors are now constructed
        // once in AppDelegate (Stage-1 of the overlay refactor — see
        // docs/overlay-refactor.md). They're passed into init above and
        // shared across every overlay, so multi-monitor footprint loses
        // these 6 duplicates and the per-overlay polling they triggered.
        // PreferenceLearner.shared.start() also moved up to AppDelegate.
        // Default bindings — agent can override via clear_bindings + re-bind.
        // token.hesitation → head shake: the character's stutter reflects
        // the variance in the model's inter-token pace.
        self.bindingEngine.register(
            TelemetryBinding(
                signal: TelemetrySignal.tokenHesitation,
                part: "head",
                mode: .shake,
                params: BindingParams(amplitude: 0.14)
            )
        )
        // Stage-2 of overlay refactor: ChatSession is constructed once
        // in AppDelegate and shared. environmentSensors / voiceEngine /
        // memory / userModelStore / sessionStore wirings are also done
        // there (they always pointed at the same shared singletons).
        // Only the telemetryBus link is per-overlay because the bus
        // carries primary-only events (token hesitation drives primary's
        // BindingEngine + Pet); secondary overlays leave it alone so
        // they don't clobber primary's bus reference.
        if screen === NSScreen.main {
            self.chatSession.telemetryBus = bus
        }

        // Wire the voice engine's per-word callback to bounce the mouth.
        // Cheap visual lipsync — no AVAudioEngine tap required.
        self.voice.onSpeechWord = { [weak pet] in
            pet?.mouthBounce()
        }
        // Autonomy first so the dispatch context can hold a weak ref
        // to it — schedule_follow_up routes through this.
        if screen === NSScreen.main {
            self.autonomy = AutonomyController(session: self.chatSession)
            // Screen annotation layer — primary-only so annotation
            // action tags don't double-render on multi-monitor.
            self.annotationOverlay = AnnotationOverlay(screen: screen)
            // AgencyStrip construction (which captures `self` via
            // [weak self] inside its closure) moved below `self.tour`
            // so Swift's init-order rule is satisfied.
        }

        let context = MaxClawdroomContext(
            pet: pet,
            bindingEngine: self.bindingEngine,
            editorAwareness: self.editorAwareness,
            overlayScreen: screen,
            undoStack: self.undoStack,
            chatTheme: self.chatTheme,
            modeManager: self.modeManager,
            memory: self.memory,
            autonomy: self.autonomy,
            annotationOverlay: self.annotationOverlay,
            chatSession: self.chatSession
        )
        // Stage-2: shared ChatSession means only the primary overlay
        // sets actionHandler. Secondary overlays would otherwise clobber
        // primary's wiring on app launch — last-overlay-wins, which on
        // multi-monitor is non-deterministic. Primary owns the agent's
        // dispatch target; secondary Pets are decorative.
        if screen === NSScreen.main {
            self.chatSession.actionHandler = { action in
                ActionDispatcher.dispatch(action, in: context)
            }
            // Channels: persona-on-swap + health→expression. Same
            // dispatch target as the agent's actionHandler so the
            // existing action vocabulary drives the channel-shape
            // transform with no new ops.
            self.channelStageDirector = ChannelStageDirector { action in
                ActionDispatcher.dispatch(action, in: context)
            }
            // Sound effects: deliberately NOT instantiated at launch
            // on macOS 26.x. Bringing AVAudioEngine + the reactor's
            // observer set up here shifted heap layout enough that
            // unrelated main-actor closures (NSEvent monitors, NSTimer
            // callbacks in Pet.swift, etc.) tripped the runtime
            // executor-probe bug in swift_task_isCurrentExecutorWith-
            // FlagsImpl. Three crash reports filed before the
            // correlation became clear. Reactor + engine now lazy-init
            // on the first explicit play_sound call so the start path
            // matches the prior good build's heap shape.
            // self.soundReactor = SoundReactor()
            // _ = SoundEngine.shared
        }

        // Reflex layer: subscribes to the autonomy event bus and fires
        // zero-token micro-reactions for observed events. Only wired on
        // the primary overlay (where `autonomy` is non-nil) so events
        // don't fire N times on multi-monitor.
        if let autonomy = self.autonomy {
            // Work-watcher runs only on the primary screen (same gate as
            // autonomy) — commits are singular events; firing them per-
            // monitor would stack up reactions.
            let watcher = WorkWatcher()
            self.workWatcher = watcher

            // Merge the two event sources into one feed. Reflex doesn't
            // need to know the provenance — an event is an event.
            let merged = Publishers.Merge(
                autonomy.events,
                watcher.events
            ).eraseToAnyPublisher()

            self.reflex = ReflexController(
                pet: pet,
                session: self.chatSession,
                memory: self.memory,
                events: merged
            )
            // Visible growth — a tiny tie-tint nudge per accepted soul
            // patch, deterministic from the patch text. Over time the
            // tie's hue drifts as a record of Max's evolution.
            self.soulTintDrift = SoulTintDrift(pet: pet)

            // Work-state tracker + mood layer — primary-only, polls
            // every minute and transitions pet opacity + scale + held
            // expression based on what the user is doing. Cheap and
            // visible; the feel of "Max matches my register".
            let tracker = WorkStateTracker(editorAwareness: self.editorAwareness)
            self.workStateTracker = tracker
            WorkStateTracker.shared = tracker
            self.workStateEffects = WorkStateEffects(pet: pet, tracker: tracker)

            // Model-of-you synthesiser. Only the primary overlay owns
            // one (so we don't fire N parallel LLM refreshes on a multi-
            // monitor setup). Deferred a few seconds after launch so the
            // session + backend finish warming up first.
            let synth = UserModelSynthesiser(
                session: self.chatSession,
                memory: self.memory,
                store: self.userModelStore
            )
            self.userModelSynthesiser = synth
            UserModelSynthesiser.shared = synth
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak synth] in
                synth?.refreshIfStale()
            }
        }

        // Tour narration speaks aloud via the same VoiceEngine the
        // chat uses, so Max actually TALKS during the first-run demo.
        self.tour = TourController(session: self.chatSession, context: context, voice: self.voice)

        // Turn-lifecycle callbacks live here (not next to actionHandler)
        // so the `[weak self]` captures are legal — Swift forbids
        // self-forming closures until every stored property on the actor
        // is init'd, and `tour` above is the last stored property.
        //
        // Stage-2 gate: shared ChatSession holds ONE callback per slot;
        // primary owns them so anticipation cues + turn counters reflect
        // the primary Pet (which is what the agent actually drives).
        if screen === NSScreen.main {
            self.chatSession.onTurnStart = { [weak self] in
                self?.annotationOverlay?.resetTurnCounter()
            }
            self.chatSession.onUserTurnStart = { [weak pet] in
                // Pre-latency cue — lean Max forward the instant the user
                // commits a turn, unlatched on first-token arrival below.
                pet?.beginAnticipation()
            }
            self.chatSession.onFirstToken = { [weak pet] in
                pet?.endAnticipation()
            }
        }

        // Agency strip (primary only) — built here, after `tour` so the
        // weak-self capture in its closure is legal.
        if screen === NSScreen.main {
            self.agencyStrip = AgencyStrip(
                session: self.chatSession,
                petScreenRect: { [weak self] in
                    self?.petScreenRect() ?? .zero
                }
            )
        }

        // Wire proactive-chat callbacks now that all stored properties exist.
        self.autonomy?.isChatOpen = { [weak self] in self?.chat != nil }
        self.autonomy?.onInitiateChat = { [weak self] prompt in
            self?.initiateProactiveChat(prompt: prompt)
        }

        // Feed token-hesitation signal into voice rate so Max speaks
        // slower when the model is uncertain (high inter-token latency variance).
        hesitancyCancellable = bus.events
            .filter { $0.signal == TelemetrySignal.tokenHesitation }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.voice.hesitation = event.value ?? 0 }

        // Opt-in CRT fragment-modifier (scanlines + grain). Off by
        // default — the initial roll caused a pink-silhouette regression.
        // Shader has been hardened (alpha-gated, clamped, uniforms
        // pre-seeded) so re-enabling is safe; flip Prefs.crtEffectsEnabled
        // or the menu-bar toggle to try it.
        if Prefs.crtEffectsEnabled {
            self.crtEffects = CRTEffects(pet: pet, state: self.maxClawdroomState, scnView: view)
        }

        self.expressionDriver = ExpressionDriver(pet: pet, state: self.maxClawdroomState)
        self.stageDriver = StageDriver(session: self.chatSession, state: self.maxClawdroomState)

        // Subscribe to mode-change events and apply the initial preset so
        // the pet starts at the auto-detected scale and idle config.
        self.modeCancellable = self.modeManager.onApply
            .receive(on: RunLoop.main)
            .sink { [weak self] preset in
                self?.applyModePreset(preset)
            }

        // One subtitle bar for the whole app — on the primary screen only.
        if screen === NSScreen.main {
            self.subtitleBar = SubtitleBarController(
                session: self.chatSession,
                theme: self.chatTheme,
                screen: screen
            )
        }

        self.applyModePreset(ModePreset.preset(for: self.modeManager.mode))

        window.contentView = view
        view.isPlaying = true

        view.onMouseDown = { [weak self] localPoint in
            guard let self else { return false }
            return self.handleDown(at: localPoint)
        }
        view.onMouseDragged = { [weak self] localPoint in
            self?.handleDrag(to: localPoint)
        }
        view.onMouseUp = { [weak self] localPoint, didDrag in
            self?.handleUp(at: localPoint, didDrag: didDrag)
        }
        view.onRightMouseDown = { [weak self] localPoint in
            self?.handleRightClick(at: localPoint)
        }

        locomotion.start()

        cursorGazeController = CursorGazeController(pet: pet, petCenter: { [weak self] in
            guard let self else { return .zero }
            let r = petScreenRect()
            return NSPoint(x: r.midX, y: r.midY)
        })
        cursorGazeController?.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onSummon),
            name: .companionSummon,
            object: nil
        )

        // Revert-to-baseline — only the primary overlay listens (the
        // ones with the canonical action dispatch context). Fires the
        // canonical reset chain documented in `Your defaults` in the
        // system prompt: outfit → hair → grooming → physique →
        // expression → glasses → props → scale → colors → voice → font.
        if screen === NSScreen.main {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onRevertToBaseline),
                name: .companionRevertToBaseline,
                object: nil
            )
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onGravityChanged),
            name: .companionGravityChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onFarewellRequested),
            name: .companionFarewellRequested,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onCrtEffectsChanged),
            name: .companionCrtEffectsChanged,
            object: nil
        )

        // Flip SSAO / vignette live when the user toggles Low Power Mode.
        // macOS posts this notification on both entering and leaving, so
        // the same handler re-reads the current state.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onLowPowerModeChanged),
            name: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )

        applyAccessibilityPrefs()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onAccessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onModeRequest(_:)),
            name: .companionModeRequest,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onTourStart),
            name: .companionStartTour,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onVoiceChanged),
            name: .companionVoiceChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self, selector: #selector(onLidClosing),
            name: .companionLidClosing, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLidOpening),
            name: .companionLidOpening, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(onTapDetected),
            name: .companionTapDetected, object: nil
        )
    }

    /// Tracked across `onVoiceChanged` calls so we can detect which
    /// specific pref flipped. The generic `companionVoiceChanged`
    /// notification fires for every voice-related pref (enabled,
    /// voiceID, voiceMaxFilter) and we need to react differently to
    /// each — in particular, an enabled-flip must NOT run `voice.stop()`
    /// because that wipes the pause buffer the unmute path just flushed.
    private var lastKnownVoiceID: String?
    private var lastKnownMaxFilter: Bool?

    @objc private func onVoiceChanged() {
        // Route enabled flips through setEnabled so the pause-buffer
        // flush fires on mute→unmute. Idempotent when the state is
        // already in sync (e.g. when the chat-button handler already
        // called setEnabled directly).
        voice.setEnabled(Prefs.voiceEnabled)
        voice.voiceID = Prefs.voiceID
        voice.applyMaxFilterPref()
        // Only interrupt the current utterance if voiceID or filter
        // actually changed — not on a bare enabled flip. Interrupting
        // on enabled-flip would wipe the pause buffer.
        let voiceIDChanged = lastKnownVoiceID != Prefs.voiceID
        let filterChanged = lastKnownMaxFilter != Prefs.voiceMaxFilter
        if voiceIDChanged || filterChanged {
            voice.stop()
        }
        lastKnownVoiceID = Prefs.voiceID
        lastKnownMaxFilter = Prefs.voiceMaxFilter
    }

    /// Tour is a one-shot and runs on the primary overlay only (there's
    /// one chat session per overlay and we don't want duplicate tours on
    /// multi-monitor setups).
    @objc private func onTourStart() {
        guard screen === NSScreen.main else { return }
        openChatIfNeeded()
        tour.start()
    }

    @objc private func onLidClosing() {
        pet.poseExpression(.tired)
        voice.stop()
        maxClawdroomState.setStage(.sleeping)
    }

    @objc private func onLidOpening() {
        maxClawdroomState.setStage(.idle)
        pet.poseExpression(.neutral)
        pet.greet()
    }

    @objc private func onTapDetected() {
        pet.manualJitter()
    }

    /// Handles mode requests from the menu bar. "auto" drops the user pin
    /// and falls back to detected topology; any other value pins the mode.
    @objc private func onModeRequest(_ note: Notification) {
        guard
            let info = note.userInfo,
            let raw = info["mode"] as? String
        else { return }
        if raw == "auto" {
            modeManager.resetToAuto()
        } else if let mode = MaxClawdroomMode(rawValue: raw) {
            modeManager.setMode(mode, userOverride: true)
        }
    }

    /// v2 spec §10 — honour `NSAccessibilityReduceMotion`. Turns off the
    /// periodic head jitter and holds MaxClawdroomState at its non-transient
    /// baseline so the CRT shader modifier renders a minimal steady look.
    @objc private func onAccessibilityChanged() {
        applyAccessibilityPrefs()
    }

    /// Runs whenever the mode manager emits a preset — switch of mode,
    /// topology change, or initial boot. Keeps the body-level effects of
    /// a mode in one place: scale, idle jitter. Panel anchor is read by
    /// ChatBubbleController directly off the manager when it places the
    /// bubble; subtitle-bar / menu-bar surfaces are Phase 4 work.
    private func applyModePreset(_ preset: ModePreset) {
        pet.setRootScale(preset.petScale)
        if preset.idleJitter {
            if !pet.isPeriodicJitterActive { pet.startPeriodicJitter() }
        } else {
            pet.stopPeriodicJitter()
        }

        // Broadcast so the menu bar can update checkmarks and any other
        // observer (subtitle bar, status item subtitle) can react.
        NotificationCenter.default.post(
            name: .companionModeChanged,
            object: nil,
            userInfo: [
                "mode": preset.mode.rawValue,
                "pinned": modeManager.userOverride != nil
            ]
        )
    }

    private func applyAccessibilityPrefs() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        maxClawdroomState.reduceMotion = reduce
        if reduce {
            pet.stopPeriodicJitter()
        } else if !pet.isPeriodicJitterActive {
            pet.startPeriodicJitter()
        }
    }

    /// Timer that re-evaluates the SCNView's preferredFramesPerSecond on
    /// a 2 Hz cadence. 2 Hz is the sweet spot: tight enough that a wake-
    /// up feels instant, slow enough that the check itself is free.
    private var framerateTimer: Timer?

    /// Pick a framerate based on how visible and active Max is:
    /// - 60 fps when he's on the focused screen and doing something
    /// - 30 fps on an unfocused screen (still animating but doesn't
    ///   compete for GPU with whatever the user's actually using)
    /// - 15 fps when stage is idle AND no SCNActions are running —
    ///   he's just breathing/blinking, which is dirt-cheap to render
    ///   at 15 fps.
    private func updatePreferredFramerate() {
        let isFocused = (NSApp.keyWindow?.screen === screen) || isPetScreenFocused
        let stage = maxClawdroomState.stage
        let hasActions = pet.node.hasActions || pet.bodyNode.hasActions
        let target: Int
        if stage == .idle, !hasActions {
            target = isFocused ? 30 : 15
        } else if isFocused {
            target = 60
        } else {
            target = 30
        }
        if scnView.preferredFramesPerSecond != target {
            scnView.preferredFramesPerSecond = target
        }
    }

    /// Whether the window containing Max is currently on the focused
    /// screen. `NSApp.keyWindow` can be any app's window; we want "is
    /// Max on the same screen as the user's current attention." Use
    /// the workspace's frontmost window's screen as proxy.
    private var isPetScreenFocused: Bool {
        guard let frontScreen = NSScreen.main else { return true }
        return frontScreen === screen
    }

    @objc private func onCrtEffectsChanged() {
        if Prefs.crtEffectsEnabled {
            if crtEffects == nil {
                crtEffects = CRTEffects(pet: pet, state: maxClawdroomState, scnView: scnView)
            }
        } else {
            crtEffects?.teardown()
            crtEffects = nil
        }
    }

    /// Called when macOS Low Power Mode toggles. Drops the expensive
    /// SSAO pass so battery-saver mode actually saves battery when Max
    /// is on screen. Vignette also dims a touch since the darker edges
    /// are mostly for mood, not shape-reading.
    @objc private func onLowPowerModeChanged() {
        guard let camera = scnView.pointOfView?.camera else { return }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        camera.screenSpaceAmbientOcclusionIntensity = lowPower ? 0 : 0.55
        camera.vignettingIntensity = lowPower ? 0.15 : 0.35
    }

    @objc private func onFarewellRequested() {
        // Drop the stage so the expression/CRT pipeline reads "done".
        maxClawdroomState.setStage(.sleeping)
        // Give the wave ~1.4s to play before we fade the chat out. The
        // bubble controller's own close animation handles the CRT
        // collapse; we just trigger the sequence.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.closeChat()
        }
    }

    @objc private func onGravityChanged() {
        if Prefs.gravityEnabled {
            // Gravity was just re-enabled — if the pet is hovering, bring him down.
            pet.stopRagDoll()
            let current = pet.node.presentation.position
            let delta = abs(CGFloat(current.y) - pet.form.baseY)
            if delta > 4 {
                pet.node.removeAction(forKey: "walk")
                pet.moveTo(
                    x: CGFloat(current.x),
                    y: pet.form.baseY,
                    duration: max(0.5, Double(delta / 120))
                )
            }
        } else {
            // Gravity off — he's floating, so limbs go slack and he sways
            // on gentle pendulum cadences. Amplitudes are small so he
            // doesn't look like he's drowning.
            pet.startRagDoll()
        }
    }

    // MARK: - Right-click context menu

    private func handleRightClick(at localPoint: NSPoint) {
        guard hitPet(at: localPoint) else { return }

        let menu = NSMenu(title: "")
        menu.autoenablesItems = false

        menu.addItem(MenuItem(chat == nil ? "Chat" : "Close Chat") { [weak self] in
            self?.toggleChat()
        })
        menu.addItem(MenuItem(isFollowingMouse ? "Stop Following" : "Follow Mouse") { [weak self] in
            self?.toggleFollowMouse()
        })

        menu.addItem(.separator())

        menu.addItem(MenuItem(Prefs.voiceEnabled ? "Mute Voice" : "Unmute Voice") {
            Prefs.voiceEnabled.toggle()
        })

        menu.addItem(.separator())

        menu.addItem(MenuItem("Shuffle Look") { [weak self] in
            self?.chatSession.send("""
            [context: shuffle look request]
            Change your appearance completely — pick a new outfit, colour \
            palette, and expression. Emit set_part_pattern, set_part_color, \
            set_hair, set_grooming, and/or set_expression. Make it a coherent \
            style. No prose — actions only.
            """, silent: true)
        })

        menu.addItem(MenuItem("Revert to Baseline") {
            NotificationCenter.default.post(name: .companionRevertToBaseline, object: nil)
        })

        menu.addItem(.separator())

        menu.addItem(MenuItem("Hide Max") {
            Prefs.maxVisible = false
        })

        menu.addItem(.separator())

        menu.addItem(MenuItem("Settings…") {
            NotificationCenter.default.post(name: .companionOpenSettings, object: nil)
        })
        menu.addItem(MenuItem("Quit") {
            NSApplication.shared.terminate(nil)
        })

        menu.popUp(positioning: nil, at: localPoint, in: scnView)
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        // Adaptive-framerate timer gets added to RunLoop.main explicitly
        // (not held by the owner alone), so it must be invalidated here
        // or it keeps firing on a zombie controller when the overlay is
        // torn down without going through `finalizeClose()`.
        framerateTimer?.invalidate()
        followMouseTimer?.invalidate()
    }

    /// Re-apply the current screen frame to the overlay window + SCNView
    /// + camera ortho scale. Called by AppDelegate on
    /// NSApplication.didChangeScreenParameters so an unplugged second
    /// monitor or a resolution flip doesn't strand the pet off-screen.
    /// Nothing is rebuilt — we just reframe in place.
    func reflectScreenChange() {
        let frame = screen.frame
        window.setFrame(frame, display: true, animate: false)
        scnView.frame = NSRect(origin: .zero, size: frame.size)
        if let cam = scene.rootNode.childNodes.first(where: { $0.camera != nil })?.camera {
            cam.orthographicScale = Double(frame.height / 2)
        }
    }

    func show() {
        // Visibility observer is registered UNCONDITIONALLY so a user
        // who relaunched while hidden can still flip back via menu /
        // summon. Earlier version registered it inside the early-return
        // branch below, which left the controller deaf to visibility
        // changes if startup found Prefs.maxVisible == false.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onVisibilityChanged),
            name: .companionVisibilityChanged,
            object: nil
        )
        if !Prefs.maxVisible {
            // Hidden at startup — leave the window orderOut'd. Render
            // loop stays paused. The visibility observer above will
            // bring everything back up when the user flips the flag.
            return
        }
        window.orderFrontRegardless()
        // Start adaptive framerate polling once the window is visible.
        // 2 Hz is enough to feel instant when Max wakes up and cheap
        // enough that we can run it unconditionally.
        if framerateTimer == nil {
            let timer = Timer.scheduledTimer(
                withTimeInterval: 0.5,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor in self?.updatePreferredFramerate() }
            }
            RunLoop.main.add(timer, forMode: .common)
            framerateTimer = timer
        }
        // Pause idle behaviors (blink / jitter) when the window gets
        // occluded — no point running their SCNAction / asyncAfter
        // chain if nothing's on screen to see them.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onWindowOcclusionChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
    }

    /// Fire the full reset chain through the existing action dispatch
    /// pipeline. Order matches the canonical "full reset recipe" in the
    /// system prompt's `Your defaults` section so Max's idea of "normal"
    /// (which the agent reads from the prompt) and the actual restored
    /// state always agree. Each step is ⌘Z-undoable individually.
    @objc private func onRevertToBaseline() {
        // Single source of truth lives in MaxClawdroomBaseline. The
        // agent's system prompt advertises these same values so
        // "revert to default" means the same thing whether the user
        // clicks the menu, the agent fires `revert_to_baseline`, or
        // the user describes it in prose.
        for (op, args) in MaxClawdroomBaseline.revertSequence {
            chatSession.actionHandler?(MaxClawdroomAction(op: op, args: args))
        }
        // WorkStateEffects dims pet.node.opacity to 0.97/0.85 in
        // deepFocus / ambient states, and there's no action op that
        // owns it (it's a passive observer of the work-state tracker,
        // not an agent-controllable axis). Force opacity back to 1.0
        // here so revert reads as "fully present and crisp" even if
        // the user happens to be mid-deep-focus when they hit the
        // button. WorkStateEffects will re-apply its dim when the
        // tracker next changes state — this is a momentary reset,
        // not a permanent override.
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.4
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pet.node.opacity = 1.0
        SCNTransaction.commit()
    }

    @objc private func onVisibilityChanged() {
        if Prefs.maxVisible {
            // makeKeyAndOrderFront is more robust than plain
            // orderFrontRegardless when bringing back a window that
            // was previously orderOut'd — the latter sometimes leaves
            // the window stuck below the menu-bar layer until the
            // first user interaction. SCNView's render loop also
            // pauses on occlusion; nudge the periodic behaviours so
            // the pet visibly resumes life on first frame.
            window.orderFrontRegardless()
            scnView.isPlaying = true
            pet.startPeriodicBlink()
            pet.startPeriodicJitter()
        } else {
            window.orderOut(nil)
            // Close any open chat bubble — hidden means hidden, even
            // if autonomy was mid-stream. The bubble is a separate
            // NSWindow that openChatIfNeeded refuses to reopen while
            // hidden.
            chat?.close()
            pet.stopPeriodicBlink()
            pet.stopPeriodicJitter()
            // SCNView render loop is wasted work while hidden.
            scnView.isPlaying = false
        }
    }

    @objc private func onWindowOcclusionChanged(_ note: Notification) {
        let visible = window.occlusionState.contains(.visible)
        if visible {
            pet.startPeriodicBlink()
            pet.startPeriodicJitter()
        } else {
            pet.stopPeriodicBlink()
            pet.stopPeriodicJitter()
        }
    }

    /// Converts the pet's hit bounds to absolute screen coordinates.
    /// World units are pixels because the camera is orthographic at 1:1, so
    /// scene x/y ≡ view x/y. Accounts for the current root scale so the
    /// chat bubble tracks above his actual head when he grows or shrinks
    /// via `set_scale`.
    func petScreenRect() -> NSRect {
        let rel = pet.form.hitBoundsRelative
        let local = pet.node.presentation.position
        let scale = CGFloat(pet.node.presentation.scale.x)
        let scaled = CGRect(
            x: rel.origin.x * scale,
            y: rel.origin.y * scale,
            width: rel.size.width * scale,
            height: rel.size.height * scale
        )
        let viewX = CGFloat(local.x) + scaled.origin.x
        let viewY = CGFloat(local.y) + scaled.origin.y
        let viewPt = NSPoint(x: viewX, y: viewY)
        let windowPt = scnView.convert(viewPt, to: nil)
        let absolute = window.convertPoint(toScreen: windowPt)
        return NSRect(origin: absolute, size: scaled.size)
    }

    private func hitPet(at point: NSPoint) -> Bool {
        let hits = scnView.hitTest(point, options: [.boundingBoxOnly: true])
        return hits.contains { result in
            var n: SCNNode? = result.node
            while let cur = n {
                if cur === pet.node { return true }
                n = cur.parent
            }
            return false
        }
    }

    private func handleDown(at localPoint: NSPoint) -> Bool {
        guard hitPet(at: localPoint) else { return false }
        // Drag takes priority over follow-mouse. If the user grabs Max
        // while he's chasing the cursor, stop the chase so the drag isn't
        // fighting a 15 Hz moveTo.
        if isFollowingMouse { stopFollowingMouse() }
        let current = pet.node.presentation.position
        dragOffset = NSPoint(
            x: localPoint.x - CGFloat(current.x),
            y: localPoint.y - CGFloat(current.y)
        )
        pet.stopAll()
        locomotion.pause()
        cursorGazeController?.pause()
        mouseEventsLocked = true
        return true
    }

    private func handleDrag(to localPoint: NSPoint) {
        SensorController.shared.reportDragPosition(localPoint)
        guard let offset = dragOffset else { return }
        let nx = localPoint.x - offset.x
        let ny = localPoint.y - offset.y
        let clampedX = max(40, min(nx, screen.frame.width - 40))
        let clampedY = max(10, min(ny, screen.frame.height - 40))
        pet.node.position = SCNVector3(Double(clampedX), Double(clampedY), 0)
    }

    private func handleUp(at localPoint: NSPoint, didDrag: Bool) {
        dragOffset = nil
        mouseEventsLocked = false

        if didDrag {
            // Post-drag stillness — when the user just put Max somewhere
            // deliberate, immediately wandering off feels rude and
            // disrespects the placement. Hold position for ~6 s before
            // resuming locomotion. Cursor gaze still resumes at full
            // settle so he keeps looking at the user. The pauseFor
            // helper auto-resumes after the duration.
            let postDragStillness: TimeInterval = 6.0

            if Prefs.gravityEnabled {
                // Settle gently back to ground.
                let current = pet.node.presentation.position
                let settle = SCNAction.move(
                    to: SCNVector3(Double(current.x), Double(pet.form.baseY), 0),
                    duration: 0.45
                )
                settle.timingMode = .easeOut
                pet.node.runAction(settle) { [weak self] in
                    Task { @MainActor in
                        self?.locomotion.pauseFor(duration: postDragStillness)
                        self?.cursorGazeController?.resume()
                    }
                }
            } else {
                // Gravity off — leave him floating wherever the user dropped him.
                locomotion.pauseFor(duration: postDragStillness)
                cursorGazeController?.resume()
            }
        } else {
            toggleChat()
            locomotion.resume()
            cursorGazeController?.resume()
        }
    }

    @objc private func onSummon() {
        // Summon also un-hides Max — if the user explicitly hid him via
        // the menu / right-click, this is the inverse: bring the
        // overlay back, move him to the cursor, open chat.
        if !Prefs.maxVisible {
            Prefs.maxVisible = true
        }
        guard window.screen === screen || window.screen == nil else { return }
        let mouse = NSEvent.mouseLocation
        if !NSMouseInRect(mouse, screen.frame, false) { return }
        let target = window.convertPoint(fromScreen: mouse)
        pet.moveTo(x: target.x, y: 220)
        openChatIfNeeded()
    }

    private func toggleChat() {
        if chat == nil {
            openChatIfNeeded()
        } else {
            closeChat()
        }
    }

    /// Flip follow-mouse mode. Normal locomotion pauses while on — Max
    /// chases the cursor at ~15 Hz using short `moveTo` calls so motion
    /// stays smooth. Stopping resumes locomotion (and CursorGaze).
    private func toggleFollowMouse() {
        if isFollowingMouse {
            stopFollowingMouse()
        } else {
            startFollowingMouse()
        }
    }

    private func startFollowingMouse() {
        guard !isFollowingMouse else { return }
        isFollowingMouse = true
        locomotion.pause()
        cursorGazeController?.pause()
        pet.stopAll()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickFollowMouse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        followMouseTimer = timer
        tickFollowMouse()
    }

    private func stopFollowingMouse() {
        guard isFollowingMouse else { return }
        isFollowingMouse = false
        followMouseTimer?.invalidate()
        followMouseTimer = nil
        locomotion.resume()
        cursorGazeController?.resume()
    }

    private func tickFollowMouse() {
        guard window.screen === screen || window.screen == nil else { return }
        let mouse = NSEvent.mouseLocation
        // When the cursor crosses to another monitor, stop chasing — this
        // overlay is per-screen so we'd just run Max to the edge and spin.
        guard NSMouseInRect(mouse, screen.frame, false) else { return }
        let target = window.convertPoint(fromScreen: mouse)
        let clampedX = max(40, min(CGFloat(screen.frame.width) - 40, target.x))
        // Slightly lag the cursor vertically so Max doesn't cover what the
        // user's pointing at; use the sprite height as the offset.
        let desiredY = max(10, target.y - 80)
        let current = pet.node.presentation.position
        // Short duration so animation blends smoothly across ticks instead
        // of creating a perceptible stop-start rhythm.
        let dx = clampedX - CGFloat(current.x)
        let dy = desiredY - CGFloat(current.y)
        if dx * dx + dy * dy < 4 { return }  // already there
        pet.moveTo(x: clampedX, y: desiredY, duration: 0.25)
    }

    private func openChatIfNeeded() {
        // Hidden = both pet AND chat stay hidden. Otherwise an autonomy
        // ping or `[max-initiated chat]` prompt can pop the bubble back
        // up while the user has explicitly silenced him. Summon
        // restores `Prefs.maxVisible = true` first; that's the only
        // surface that re-shows.
        if !Prefs.maxVisible { return }
        if chat != nil { return }
        pet.greet()
        let controller = ChatBubbleController(
            overlay: self,
            session: chatSession
        )
        controller.onClose = { [weak self] in
            // End-of-session journal: fire-and-forget silent prompt so
            // Max captures anything worth remembering from this chat
            // before it fades. The claude subprocess stays alive, so the
            // silent turn completes in the background.
            self?.chatSession.requestSessionJournalIfMeaningful()
            self?.chat = nil
            self?.locomotion.resume()
            self?.cursorGazeController?.resume()
        }
        controller.show()
        chat = controller
        // Pause auto-wandering for the duration the chat is open so
        // Max stays where the user put him. The close handler restores.
        locomotion.pause()
        cursorGazeController?.pause()
    }

    private func closeChat() {
        chat?.close()
        // Don't nil out chat here — animated close relies on the
        // controller staying alive through its fade. The onClose
        // callback (set in openChatIfNeeded) will nil chat + resume
        // locomotion once finalizeClose runs.
    }

    /// Called by AutonomyController when Max decides to initiate a
    /// conversation himself. Opens the chat window, then after the
    /// reveal animation settles, sends the framing prompt so Max's
    /// response appears as his opening line. No-op if chat is already open.
    private func initiateProactiveChat(prompt: String) {
        guard chat == nil else { return }
        openChatIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.chatSession.send(prompt, hideUser: true)
        }
    }

    /// Entry point for the morning-greeting hook: open the chat (so
    /// the reply is visible) and send a silent framing prompt so
    /// Max's response appears as his own opening line rather than a
    /// reply to the user. The user sees Max greet them first.
    func openChatForMorningGreeting(prompt: String) {
        openChatIfNeeded()
        // Short delay so the chat bubble's boot-reveal finishes before
        // we start streaming into it — otherwise the reply pops before
        // the user sees the bubble opened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.chatSession.send(prompt, hideUser: true)
        }
    }
}

// MARK: - Context menu item helper

/// NSMenuItem subclass that carries its own closure target, avoiding the
/// need for OverlayController (a non-NSObject @MainActor type) to expose
/// @objc selectors.
///
/// Marked `nonisolated` so init matches NSMenuItem's nonisolated parent
/// initialisers under Swift 6.2 strict concurrency. The handler closure
/// itself is still @MainActor (captured from the builder call site) so
/// the fire() path lands back on the main actor naturally.
private nonisolated final class MenuItem: NSMenuItem, @unchecked Sendable {
    private var handler: (@MainActor () -> Void)?

    init(_ title: String, handler: @MainActor @escaping () -> Void) {
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
        self.isEnabled = true
        self.handler = handler
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    // fire() runs on main — AppKit only dispatches menu actions on the
    // main thread, so hopping via MainActor.assumeIsolated matches the
    // runtime guarantee and satisfies strict concurrency. Read `handler`
    // into a local before crossing the isolation boundary so `self` isn't
    // implicitly captured into a MainActor-isolated closure.
    @objc private func fire() {
        let h = handler
        MainActor.assumeIsolated { h?() }
    }
}
