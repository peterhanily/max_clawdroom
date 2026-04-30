import AppKit
import Sparkle
import AVFoundation
import Combine

@MainActor
final class VoiceMenuDelegate: NSObject, NSMenuDelegate {
    private weak var controller: MenuBarController?
    init(controller: MenuBarController) {
        self.controller = controller
    }
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        Task { @MainActor in
            self.controller?.rebuildVoiceMenu()
        }
    }
}

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let settingsController = SettingsWindowController()
    private let soulReviewController = SoulPatchReviewWindowController()
    private let maxsRoomController = MaxsRoomWindowController()
    private let addChannelController = AddChannelWindowController()
    private weak var channelsSubmenu: NSMenu?
    private weak var channelsItem: NSMenuItem?
    private var proposalsItem: NSMenuItem?
    private var gravityItem: NSMenuItem?
    private var modeItems: [NSMenuItem] = []
    private var autonomyItem: NSMenuItem?
    /// Non-interactive row showing what Max thinks the user is doing.
    /// Updated from `WorkStateTracker.$state` via Combine.
    private var workStateItem: NSMenuItem?
    private var workStateCancellable: AnyCancellable?
    /// Ambient attention pull — when Max absorbs a soul patch we append a
    /// small amber "•" to the status-bar title for 60s. Nil when calm.
    private var learnGlowTimer: Timer?
    private weak var voiceMenu: NSMenu?
    private weak var hideShowItem: NSMenuItem?
    private lazy var voiceMenuDelegate = VoiceMenuDelegate(controller: self)
    /// Nil when the current mode is auto-detected; otherwise the user-pinned mode.
    private var pinnedMode: MaxClawdroomMode?
    /// The current effective mode (detected or pinned).
    private var currentMode: MaxClawdroomMode = .desktop

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // 🌝 — the "full moon face" emoji. Pale yellow, vaguely
            // smug, iconic. Font size is bumped up a hair because
            // emoji render smaller than system symbols at the same
            // point size. Always full-moon — the dark-moon variant
            // for muted state was ugly; mute state lives in tooltip
            // + menu items instead.
            button.title = "🌝"
            button.font = NSFont.systemFont(ofSize: 15)
            // Inline hotkey discoverability — expanded from just the app
            // name so users can find the input channels without digging
            // through the menu. Order matches frequency-of-use.
            let voiceLine = Prefs.voiceEnabled ? "voice on" : "voice muted"
            button.toolTip = """
            max_clawdroom  (\(voiceLine))
            ⌥Space   summon Max
            ⌘⇧Space  quick reply (send text without opening chat)
            ⌘⌥Space  voice input (hold to talk)
            ⌘,       Settings
            """
            // VoiceOver otherwise announces the button as "🌝" — give it a
            // real label so the menu is discoverable. Pulled from the
            // localised catalog with the user-chosen companion name
            // interpolated, so a renamed Max gets the right VO readout.
            let companion = SettingsStore.shared.settings.companionName
            let label = String(
                format: String(localized: "menubar.tooltip", bundle: .companionResources),
                companion
            )
            button.setAccessibilityLabel(label)
            button.setAccessibilityRoleDescription("menu bar extra")
        }

        let menu = NSMenu()

        // ── Header ──────────────────────────────────────────────────
        let about = NSMenuItem(title: SettingsStore.shared.settings.companionName,
                               action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(.separator())

        // ── Primary actions ────────────────────────────────────────
        let summon = NSMenuItem(
            title: String(localized: "menu.summon", bundle: .companionResources),
            action: #selector(summon),
            keyEquivalent: " "
        )
        summon.keyEquivalentModifierMask = [.option]
        summon.target = self
        menu.addItem(summon)

        // Hide / Show toggle. Title flips with the current state and
        // a `state = .on` checkmark when Max is hidden so the menu
        // reads at a glance. Independent of the menu-bar icon — the
        // app stays alive either way.
        let hideShow = NSMenuItem(
            title: Prefs.maxVisible ? "Hide Max" : "Show Max",
            action: #selector(toggleMaxVisibility),
            keyEquivalent: ""
        )
        hideShow.target = self
        hideShow.state = Prefs.maxVisible ? .off : .on
        hideShow.toolTip = "Hide the 3D character without quitting the app. Use Summon (⌥Space) or this toggle to bring him back."
        self.hideShowItem = hideShow
        menu.addItem(hideShow)

        let revert = NSMenuItem(
            title: "Revert to Baseline",
            action: #selector(revertToBaseline),
            keyEquivalent: ""
        )
        revert.target = self
        revert.toolTip = "Restore Max's default look, voice, font, and gravity — same as right-click → Revert to Baseline."
        menu.addItem(revert)

        let proposals = NSMenuItem(
            title: "Max's Soul History",
            action: #selector(openProposals),
            keyEquivalent: ""
        )
        proposals.target = self
        proposals.toolTip = "View and revert Max's recent soul edits. He updates his own personality in the background — audit after the fact."
        proposalsItem = proposals
        menu.addItem(proposals)
        refreshProposalsItem()

        let room = NSMenuItem(
            title: String(localized: "menu.room", bundle: .companionResources),
            action: #selector(openMaxsRoom),
            keyEquivalent: ""
        )
        room.target = self
        room.toolTip = "Where Max keeps things: observations, soul history, time capsules."
        menu.addItem(room)

        // Work-state indicator — non-interactive read-out of what Max
        // thinks the user is doing. Lets the user see the register Max is
        // operating in (and understand why he's quieter during deep focus).
        let workState = NSMenuItem(title: "Active", action: nil, keyEquivalent: "")
        workState.isEnabled = false
        workState.toolTip = "Max adjusts his presence based on what you're doing. Active = full attention. Deep focus = quieter + dimmer. Ambient = fades back when you're away."
        workStateItem = workState
        menu.addItem(workState)
        // Subscribe to live state so the title updates as the tracker
        // transitions. `WorkStateTracker.shared` is set by the primary
        // overlay; nil on multi-monitor slaves which is fine — no
        // tracker means nothing to subscribe to.
        if let tracker = WorkStateTracker.shared {
            workStateCancellable = tracker.$state
                .sink { [weak self] state in
                    Task { @MainActor in self?.applyWorkState(state) }
                }
        }

        menu.addItem(.separator())

        // ── Behaviour submenu ──────────────────────────────────────
        let behaviorTitle = String(localized: "menu.behaviour", bundle: .companionResources)
        let behaviorItem = NSMenuItem(title: behaviorTitle, action: nil, keyEquivalent: "")
        let behaviorMenu = NSMenu(title: behaviorTitle)

        let gravity = NSMenuItem(
            title: String(localized: "menu.gravity", bundle: .companionResources),
            action: #selector(toggleGravity(_:)),
            keyEquivalent: "g"
        )
        gravity.keyEquivalentModifierMask = [.command, .option]
        gravity.target = self
        gravity.state = Prefs.gravityEnabled ? .on : .off
        self.gravityItem = gravity
        behaviorMenu.addItem(gravity)

        let autonomy = NSMenuItem(
            title: String(localized: "menu.autonomy", bundle: .companionResources),
            action: #selector(toggleAutonomy(_:)),
            keyEquivalent: ""
        )
        autonomy.target = self
        autonomy.state = Prefs.autonomyEnabled ? .on : .off
        autonomy.toolTip = "When on, Max periodically acts on his own — expressions, walks, tiny theme changes. ~10 min cadence."
        self.autonomyItem = autonomy
        behaviorMenu.addItem(autonomy)

        // Music-reactive — pulls Now Playing via the system MediaRemote
        // framework and lets Max bind body parts to the music's tempo.
        let music = NSMenuItem(
            title: String(localized: "menu.music_reactive", bundle: .companionResources),
            action: #selector(toggleMusicReactive(_:)),
            keyEquivalent: ""
        )
        music.target = self
        music.state = Prefs.musicReactiveEnabled ? .on : .off
        music.toolTip = "When on, Max reacts to whatever's playing — tie pulse, color drift, tempo-bound walk cadence. Reads system Now Playing only."
        behaviorMenu.addItem(music)

        // Weather grounding — adds a [world] block to the env so Max
        // knows what's outside (and dresses the part). Network call to
        // wttr.in; off by default.
        let weather = NSMenuItem(
            title: String(localized: "menu.weather_grounding", bundle: .companionResources),
            action: #selector(toggleWeather(_:)),
            keyEquivalent: ""
        )
        weather.target = self
        weather.state = Prefs.weatherEnabled ? .on : .off
        weather.toolTip = "Pulls current weather + city from wttr.in (no API key) so Max can flavour replies and outfits to what's outside."
        behaviorMenu.addItem(weather)

        // Soul auto-apply (default off) — when on, Max's update_soul
        // ops mutate his system prompt directly; when off, they queue
        // for user review in Max's Room. Off is safer.
        let soulAuto = NSMenuItem(
            title: String(localized: "menu.soul_auto_apply", bundle: .companionResources),
            action: #selector(toggleSoulAutoApply(_:)),
            keyEquivalent: ""
        )
        soulAuto.target = self
        soulAuto.state = Prefs.soulAutoApply ? .on : .off
        soulAuto.toolTip = "When off (default), Max's soul-update proposals queue for your review in Max's Room. When on, they apply directly after passing the safety filter."
        behaviorMenu.addItem(soulAuto)

        behaviorMenu.addItem(.separator())

        // Mode submenu (nested under Behaviour).
        let modeTitle = String(localized: "menu.mode", bundle: .companionResources)
        let modeItem = NSMenuItem(title: modeTitle, action: nil, keyEquivalent: "")
        let modeMenu = NSMenu(title: modeTitle)
        let auto = NSMenuItem(
            title: String(localized: "menu.mode.auto", bundle: .companionResources),
            action: #selector(pickMode(_:)),
            keyEquivalent: ""
        )
        auto.target = self
        auto.representedObject = "auto"
        modeMenu.addItem(auto)
        modeItems.append(auto)
        modeMenu.addItem(.separator())
        for mode in MaxClawdroomMode.allCases {
            let item = NSMenuItem(
                title: mode.displayName,
                action: #selector(pickMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            modeMenu.addItem(item)
            modeItems.append(item)
        }
        modeItem.submenu = modeMenu
        behaviorMenu.addItem(modeItem)

        // Multi-screen mode picker. Each item flips a Prefs flag and
        // surfaces a "restart required" alert — the overlay set is
        // built once in AppDelegate, changing count mid-flight would
        // require tearing down + reconstructing the OverlayController
        // graph which is more invasive than a relaunch.
        let multiScreenTitle = "Multi-Screen Mode"
        let multiScreenItem = NSMenuItem(title: multiScreenTitle, action: nil, keyEquivalent: "")
        let multiScreenMenu = NSMenu(title: multiScreenTitle)
        for mode in Prefs.MultiScreenMode.allCases {
            let entry = NSMenuItem(
                title: mode.displayName,
                action: #selector(setMultiScreenMode(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = mode.rawValue
            entry.state = (Prefs.multiScreenMode == mode) ? .on : .off
            multiScreenMenu.addItem(entry)
        }
        multiScreenItem.submenu = multiScreenMenu
        multiScreenItem.toolTip = "Whether to render Max on every screen or just the primary. One-Max mode is much cheaper on CPU + GPU. Requires app restart."
        behaviorMenu.addItem(multiScreenItem)

        behaviorItem.submenu = behaviorMenu
        menu.addItem(behaviorItem)

        // ── Appearance submenu ─────────────────────────────────────
        let appearanceTitle = String(localized: "menu.appearance", bundle: .companionResources)
        let appearanceItem = NSMenuItem(title: appearanceTitle, action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu(title: appearanceTitle)

        // Voice (nested under Appearance).
        let voiceTitle = String(localized: "menu.voice", bundle: .companionResources)
        let voiceItem = NSMenuItem(title: voiceTitle, action: nil, keyEquivalent: "")
        let voiceMenu = NSMenu(title: voiceTitle)
        voiceMenu.delegate = voiceMenuDelegate
        voiceItem.submenu = voiceMenu
        self.voiceMenu = voiceMenu
        rebuildVoiceMenu()
        appearanceMenu.addItem(voiceItem)

        // Accessibility (nested under Appearance).
        let a11yTitle = String(localized: "menu.accessibility", bundle: .companionResources)
        let a11yItem = NSMenuItem(title: a11yTitle, action: nil, keyEquivalent: "")
        let a11yMenu = NSMenu(title: a11yTitle)

        let caption = NSMenuItem(
            title: String(localized: "menu.caption_only", bundle: .companionResources),
            action: #selector(toggleCaptionOnly(_:)),
            keyEquivalent: "c"
        )
        caption.keyEquivalentModifierMask = [.command, .option]
        caption.target = self
        caption.state = Prefs.captionOnly ? .on : .off
        caption.toolTip = "Silence TTS and show Max's replies in a large caption bar. ⌥⌘C."
        a11yMenu.addItem(caption)

        // Voice mute — separate from caption-only because a user can
        // want "quiet for now" without flipping on the subtitle bar.
        let voiceMute = NSMenuItem(
            title: "Silence Max",
            action: #selector(toggleVoiceEnabled(_:)),
            keyEquivalent: "v"
        )
        voiceMute.keyEquivalentModifierMask = [.command, .option]
        voiceMute.target = self
        voiceMute.state = Prefs.voiceEnabled ? .off : .on
        voiceMute.toolTip = "Mute Max's voice and sound effects together. ⌥⌘V."
        a11yMenu.addItem(voiceMute)

        let hc = NSMenuItem(
            title: String(localized: "menu.high_contrast", bundle: .companionResources),
            action: #selector(toggleHighContrast(_:)),
            keyEquivalent: ""
        )
        hc.target = self
        hc.state = Prefs.highContrastUserOverride ? .on : .off
        hc.toolTip = "Pure-black panel, white text, yellow accents. Also auto-applies when System → Accessibility → Display → Increase Contrast is on."
        a11yMenu.addItem(hc)

        let announce = NSMenuItem(
            title: String(localized: "menu.announce_stage", bundle: .companionResources),
            action: #selector(toggleAnnounceStage(_:)),
            keyEquivalent: ""
        )
        announce.target = self
        announce.state = Prefs.announceStageChanges ? .on : .off
        announce.toolTip = "Post NSAccessibility announcements on stage changes (thinking, speaking, tool use, error)."
        a11yMenu.addItem(announce)

        a11yItem.submenu = a11yMenu
        appearanceMenu.addItem(a11yItem)

        appearanceMenu.addItem(.separator())

        let launchAtLogin = NSMenuItem(
            title: String(localized: "menu.launch_at_login", bundle: .companionResources),
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        launchAtLogin.state = LaunchAtLoginController.isEnabled ? .on : .off
        launchAtLogin.toolTip = "Open max_clawdroom automatically when you log in. macOS asks you once to confirm — that's normal. Toggle off here any time to remove it from your login items."
        appearanceMenu.addItem(launchAtLogin)

        appearanceMenu.addItem(.separator())

        let ambientAudio = NSMenuItem(
            title: String(localized: "menu.ambient_audio", bundle: .companionResources),
            action: #selector(toggleAmbientAudio(_:)),
            keyEquivalent: ""
        )
        ambientAudio.target = self
        ambientAudio.state = Prefs.ambientAudioEnabled ? .on : .off
        ambientAudio.toolTip = "Low-volume CRT hiss under Max while he's active. Off by default."
        appearanceMenu.addItem(ambientAudio)

        let crt = NSMenuItem(
            title: String(localized: "menu.crt_effects", bundle: .companionResources),
            action: #selector(toggleCrtEffects(_:)),
            keyEquivalent: ""
        )
        crt.target = self
        crt.state = Prefs.crtEffectsEnabled ? .on : .off
        crt.toolTip = "Adds scanlines + phosphor grain to Max's character. Opt-in because the first implementation had a silhouette artifact; the shader's been hardened but you get to decide."
        appearanceMenu.addItem(crt)

        appearanceItem.submenu = appearanceMenu
        menu.addItem(appearanceItem)

        // ── Help submenu ───────────────────────────────────────────
        let helpTitle = String(localized: "menu.help", bundle: .companionResources)
        let helpItem = NSMenuItem(title: helpTitle, action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: helpTitle)

        let welcome = NSMenuItem(
            title: String(localized: "menu.show_welcome", bundle: .companionResources),
            action: #selector(showWelcome),
            keyEquivalent: ""
        )
        welcome.target = self
        helpMenu.addItem(welcome)

        let tour = NSMenuItem(
            title: String(localized: "menu.tour", bundle: .companionResources),
            action: #selector(startTour),
            keyEquivalent: ""
        )
        tour.target = self
        helpMenu.addItem(tour)

        helpItem.submenu = helpMenu
        menu.addItem(helpItem)

        menu.addItem(.separator())

        // ── Channels submenu ───────────────────────────────────────
        let channelsItem = NSMenuItem(title: "Channels", action: nil, keyEquivalent: "")
        channelsItem.image = Self.menuIcon("antenna.radiowaves.left.and.right")
        let channelsMenu = NSMenu(title: "Channels")
        channelsItem.submenu = channelsMenu
        self.channelsItem = channelsItem
        self.channelsSubmenu = channelsMenu
        rebuildChannelsSubmenu()
        menu.addItem(channelsItem)

        menu.addItem(.separator())

        // ── Settings + Debug ───────────────────────────────────────
        let settings = NSMenuItem(
            title: String(localized: "menu.settings", bundle: .companionResources),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        settings.image = Self.menuIcon("gearshape")
        menu.addItem(settings)

        // Sparkle's own check-for-updates action. Routes through the
        // AppDelegate's SPUStandardUpdaterController so the "user
        // initiated the check" flow fires (shows no-update dialog
        // if up to date, instead of silently doing nothing).
        let update = NSMenuItem(
            title: String(localized: "menu.check_updates", bundle: .companionResources),
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        update.target = (NSApp.delegate as? AppDelegate)?.updaterController
        update.image = Self.menuIcon("arrow.down.circle")
        menu.addItem(update)

        // Debug submenu — manual triggers for long-duration autonomy
        // features (morning greeting, monthly summary, soul-patch
        // proposal, welcome-back). Lets the user validate end-to-end
        // without waiting for natural conditions.
        let debugTitle = String(localized: "menu.debug", bundle: .companionResources)
        let debugItem = NSMenuItem(title: debugTitle, action: nil, keyEquivalent: "")
        debugItem.image = Self.menuIcon("ladybug")
        let debugMenu = NSMenu(title: debugTitle)

        let fireMorning = NSMenuItem(
            title: "Fire Morning Greeting Now",
            action: #selector(debugFireMorningGreeting),
            keyEquivalent: ""
        )
        fireMorning.target = self
        fireMorning.toolTip = "Bypasses the hour + shutdown-gap checks. Opens chat + fires the [morning_greeting] prompt."
        debugMenu.addItem(fireMorning)

        let fireMonthly = NSMenuItem(
            title: "Fire Monthly Summary Now",
            action: #selector(debugFireMonthlySummary),
            keyEquivalent: ""
        )
        fireMonthly.target = self
        debugMenu.addItem(fireMonthly)

        let fireWelcomeBack = NSMenuItem(
            title: "Fire Welcome-Back Now",
            action: #selector(debugFireWelcomeBack),
            keyEquivalent: ""
        )
        fireWelcomeBack.target = self
        fireWelcomeBack.toolTip = "Simulate the idle→active transition so the welcome-back autonomy prompt fires."
        debugMenu.addItem(fireWelcomeBack)

        let fireSoulPatch = NSMenuItem(
            title: "Ask Max for a Soul Patch",
            action: #selector(debugAskForSoulPatch),
            keyEquivalent: ""
        )
        fireSoulPatch.target = self
        fireSoulPatch.toolTip = "Force Max to propose ONE soul patch based on whatever he's observed so far. Bypasses the 3+-signals guideline."
        debugMenu.addItem(fireSoulPatch)

        debugMenu.addItem(.separator())

        let fireSessionJournal = NSMenuItem(
            title: "Fire Session Journal Now",
            action: #selector(debugFireSessionJournal),
            keyEquivalent: ""
        )
        fireSessionJournal.target = self
        fireSessionJournal.toolTip = "Triggers the [session_wrap_up] prompt even if <3 user turns this session."
        debugMenu.addItem(fireSessionJournal)

        debugItem.submenu = debugMenu
        menu.addItem(debugItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: String(localized: "menu.quit", bundle: .companionResources),
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onModeChanged(_:)),
            name: .companionModeChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onProposalsChanged),
            name: .companionSoulPatchQueueChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onProposalsChanged),
            name: .companionSoulChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onSoulLearn),
            name: .companionSoulChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onOpenSettingsRequested),
            name: .companionOpenSettings,
            object: nil
        )
        // Flip the menu-bar glyph to the "dark side" when voice is muted so
        // the state is visible without opening the menu. 🌝 → 🌚.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onVoiceChanged),
            name: .companionVoiceChanged,
            object: nil
        )
        applyVoiceGlyph()

        // Sync the Hide/Show item with externally-driven visibility
        // changes — right-click "Hide Max", summon-while-hidden, or
        // an action op flipping the flag. Without this the title +
        // checkmark drift out of sync with the actual state.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onVisibilityChanged),
            name: .companionVisibilityChanged,
            object: nil
        )
        // Rebuild the Channels submenu whenever the channel list or
        // active id changes so the checkmarks + titles stay accurate.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onChannelsChanged),
            name: .companionActiveChannelChanged,
            object: nil
        )
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func onOpenSettingsRequested() {
        settingsController.present()
    }

    @objc private func toggleMaxVisibility() {
        // Setter posts companionVisibilityChanged → onVisibilityChanged
        // refreshes the menu item below, so the title + state update is
        // single-sourced rather than duplicated here. That also means
        // right-click → "Hide Max" or summon-while-hidden keep the menu
        // bar item in sync without their own bespoke wiring.
        Prefs.maxVisible.toggle()
    }

    @objc private func onVisibilityChanged() {
        hideShowItem?.title = Prefs.maxVisible ? "Hide Max" : "Show Max"
        hideShowItem?.state = Prefs.maxVisible ? .off : .on
    }

    @objc private func onChannelsChanged() {
        rebuildChannelsSubmenu()
    }

    /// (Re)build the Channels submenu. One row per channel (with kind
    /// glyph + active checkmark) followed by "Add Channel…" and
    /// "Manage Channels…" (deep-link into Settings).
    private func rebuildChannelsSubmenu() {
        guard let submenu = channelsSubmenu else { return }
        submenu.removeAllItems()
        let store = ChannelStore.shared

        for (idx, channel) in store.channels.enumerated() {
            // Glyph reflects the transport tier so the menu is scannable
            // without reading every name.
            let glyph: String
            switch channel.kind {
            case .local:         glyph = "💻"
            case .lan:           glyph = "📡"
            case .remote:        glyph = "☁️"
            case .claudeCodeCLI: glyph = "▶︎"
            }
            let item = NSMenuItem(
                title: "\(glyph)  \(channel.name)",
                action: #selector(pickChannel(_:)),
                keyEquivalent: idx < 9 ? "\(idx + 1)" : ""
            )
            item.target = self
            item.representedObject = channel.id.uuidString
            item.state = (channel.id == store.activeID) ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())

        let add = NSMenuItem(
            title: "Add Channel…",
            action: #selector(addChannel),
            keyEquivalent: ""
        )
        add.target = self
        submenu.addItem(add)

        let manage = NSMenuItem(
            title: "Manage Channels…",
            action: #selector(manageChannels),
            keyEquivalent: ""
        )
        manage.target = self
        submenu.addItem(manage)

        // Top-level item subtitle — show the active channel name plus a
        // health glyph so the user sees both the routing target and
        // whether it's reachable without opening the submenu.
        if let active = store.channels.first(where: { $0.id == store.activeID }) {
            let health: String
            switch ChannelHealth.shared.state {
            case .unknown:      health = "·"
            case .live:         health = "●"
            case .slow:         health = "◐"
            case .unreachable:  health = "○"
            case .unauthorized: health = "✕"
            }
            channelsItem?.title = "Channels  \(health)  \(active.name)"
        } else {
            channelsItem?.title = "Channels"
        }
    }

    @objc private func pickChannel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw)
        else { return }
        ChannelStore.shared.setActive(id: id)
    }

    @objc private func addChannel() {
        addChannelController.present()
    }

    @objc private func manageChannels() {
        settingsController.present()
        // SettingsView's channel section sits near the top — opening
        // settings is enough; deep-link scroll-to-section is a nicety
        // we can add later if the panel grows.
    }

    @objc private func revertToBaseline() {
        NotificationCenter.default.post(name: .companionRevertToBaseline, object: nil)
    }

    @objc private func setMultiScreenMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = Prefs.MultiScreenMode(rawValue: raw),
              mode != Prefs.multiScreenMode
        else { return }
        Prefs.multiScreenMode = mode
        let alert = NSAlert()
        alert.messageText = "Restart required"
        alert.informativeText = "The multi-screen mode changes how many overlay instances Max uses. Quit and relaunch max_clawdroom for the new mode to take effect."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func summon() {
        NotificationCenter.default.post(name: .companionSummon, object: nil)
    }

    @objc private func openSettings() {
        settingsController.present()
    }

    @objc private func openProposals() {
        soulReviewController.present()
    }

    @objc private func openMaxsRoom() {
        maxsRoomController.present()
    }

    @objc private func onProposalsChanged() {
        refreshProposalsItem()
    }

    /// Pull attention to the menu bar for 60s after Max absorbs a soul
    /// patch. Appends a small amber dot to the status-bar title (emoji
    /// can't be tinted but adjacent characters can, so we render via
    /// attributedTitle). Auto-expires so the menu returns to calm state.
    @objc private func onSoulLearn() {
        guard let button = statusItem.button else { return }
        let attr = NSMutableAttributedString(
            string: "🌝",
            attributes: [.font: NSFont.systemFont(ofSize: 15)]
        )
        attr.append(NSAttributedString(
            string: " •",
            attributes: [
                .foregroundColor: NSColor.systemOrange,
                .font: NSFont.systemFont(ofSize: 14, weight: .bold)
            ]
        ))
        button.attributedTitle = attr
        button.toolTip = "Max learned something — open the menu to see."

        learnGlowTimer?.invalidate()
        learnGlowTimer = Timer.scheduledTimer(
            withTimeInterval: 60,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.resetStatusTitle() }
        }
    }

    private func resetStatusTitle() {
        guard let button = statusItem.button else { return }
        // Clearing attributedTitle falls back to `title`, so restore the
        // plain emoji and the expanded tooltip. Keep in sync with the
        // initial setup in `init`.
        button.attributedTitle = NSAttributedString()
        button.title = currentStatusGlyph
        button.toolTip = currentStatusTooltip
    }

    /// Always 🌝. Voice mute state lives in the tooltip and the menu's
    /// "Mute voice" item state — the dark-moon glyph for muted state
    /// reads as "Max is broken" rather than "Max is quiet" and was a
    /// regular point of confusion.
    private var currentStatusGlyph: String {
        "🌝"
    }

    private var currentStatusTooltip: String {
        let voiceLine = Prefs.voiceEnabled ? "voice on" : "voice muted"
        return """
        max_clawdroom  (\(voiceLine))
        ⌥Space   summon Max
        ⌘⇧Space  quick reply (send text without opening chat)
        ⌘⌥Space  voice input (hold to talk)
        ⌘,       Settings
        """
    }

    /// Apply the current voice-based glyph + tooltip to the menu-bar
    /// button. Called on launch and whenever the voice pref changes.
    private func applyVoiceGlyph() {
        guard let button = statusItem.button else { return }
        // Skip if a soul-learn glow is running — let that finish first.
        if learnGlowTimer != nil { return }
        button.attributedTitle = NSAttributedString()
        button.title = currentStatusGlyph
        button.toolTip = currentStatusTooltip
    }

    @objc private func onVoiceChanged() {
        applyVoiceGlyph()
    }

    /// Render the work-state row. Kept disabled (non-interactive) —
    /// it's a read-out, not a control. To change state, the user
    /// changes their actual behaviour, which is the point.
    private func applyWorkState(_ state: WorkState) {
        guard let item = workStateItem else { return }
        item.title = "\(state.glyph)  \(state.displayName)"
    }

    /// Update the "Max's Soul History" menu item title to reflect how
    /// many soul updates Max has made in the last 24 hours. The badge
    /// now signals *recent activity*, not *pending approval* — in the
    /// auto-apply model the user audits after the fact.
    private func refreshProposalsItem() {
        guard let item = proposalsItem else { return }
        let dayAgo = Date().addingTimeInterval(-86_400)
        let recentCount = SoulHistory.shared.entries
            .filter { $0.appliedAt > dayAgo && !$0.rationale.hasPrefix("Reverted to snapshot") }
            .count
        let totalCount = SoulHistory.shared.entries.count
        if totalCount == 0 {
            item.title = "Max's Soul History"
            item.isEnabled = false
        } else if recentCount > 0 {
            item.title = "Max's Soul History  •  \(recentCount) recent"
            item.isEnabled = true
        } else {
            item.title = "Max's Soul History"
            item.isEnabled = true
        }
    }

    @objc private func toggleGravity(_ sender: NSMenuItem) {
        Prefs.gravityEnabled.toggle()
        sender.state = Prefs.gravityEnabled ? .on : .off
    }

    @objc private func showWelcome() {
        NotificationCenter.default.post(name: .companionShowOnboarding, object: nil)
    }

    @objc private func startTour() {
        NotificationCenter.default.post(name: .companionStartTour, object: nil)
    }

    @objc private func toggleAutonomy(_ sender: NSMenuItem) {
        Prefs.autonomyEnabled.toggle()
        sender.state = Prefs.autonomyEnabled ? .on : .off
    }

    @objc private func toggleCaptionOnly(_ sender: NSMenuItem) {
        Prefs.captionOnly.toggle()
        sender.state = Prefs.captionOnly ? .on : .off
    }

    @objc private func toggleHighContrast(_ sender: NSMenuItem) {
        Prefs.highContrast = !Prefs.highContrastUserOverride
        sender.state = Prefs.highContrastUserOverride ? .on : .off
    }

    @objc private func toggleAnnounceStage(_ sender: NSMenuItem) {
        Prefs.announceStageChanges.toggle()
        sender.state = Prefs.announceStageChanges ? .on : .off
    }

    @objc private func toggleMusicReactive(_ sender: NSMenuItem) {
        Prefs.musicReactiveEnabled.toggle()
        sender.state = Prefs.musicReactiveEnabled ? .on : .off
    }

    @objc private func toggleWeather(_ sender: NSMenuItem) {
        Prefs.weatherEnabled.toggle()
        sender.state = Prefs.weatherEnabled ? .on : .off
        // Kick a fetch immediately on enable so the next env block has
        // data without waiting for the 30-min stale-after window.
        if Prefs.weatherEnabled {
            WeatherSensor.shared.refresh()
        }
    }

    @objc private func toggleSoulAutoApply(_ sender: NSMenuItem) {
        Prefs.soulAutoApply.toggle()
        sender.state = Prefs.soulAutoApply ? .on : .off
    }

    @objc private func toggleCrtEffects(_ sender: NSMenuItem) {
        Prefs.crtEffectsEnabled.toggle()
        sender.state = Prefs.crtEffectsEnabled ? .on : .off
    }

    @objc private func toggleAmbientAudio(_ sender: NSMenuItem) {
        Prefs.ambientAudioEnabled.toggle()
        sender.state = Prefs.ambientAudioEnabled ? .on : .off
    }

    @objc private func toggleVoiceEnabled(_ sender: NSMenuItem) {
        // "Silence Max" (⌥⌘V) — flips voice + sound effects together
        // so one keystroke cleanly mutes everything Max emits. The two
        // are otherwise independent (Settings → Voice & Look exposes
        // a per-feature toggle for each); this is the unified kill
        // switch users reach for when something is talking and they
        // need quiet RIGHT NOW.
        let silencing = Prefs.voiceEnabled  // we're going to flip → off
        Prefs.voiceEnabled.toggle()
        Prefs.soundEffectsEnabled = !silencing
        sender.state = Prefs.voiceEnabled ? .off : .on
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        Prefs.launchAtLogin.toggle()
        // AppDelegate observes companionLaunchAtLoginChanged and calls
        // SMAppService.register/unregister; reading isEnabled back here
        // would race that, so reflect the user's intent immediately.
        sender.state = Prefs.launchAtLogin ? .on : .off
    }

    // MARK: - Helpers

    /// 14pt SF Symbol rendered as a template image so AppKit tints it
    /// with the menu item's text colour (highlighted / disabled states
    /// flow through automatically). Returns nil on missing symbols so
    /// older macOS versions degrade to no-icon rather than crashing.
    private static func menuIcon(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    // MARK: - Debug triggers
    //
    // All of these post notifications that AppDelegate or OverlayController
    // translate into the same entry points the natural trigger conditions
    // would hit — so if the debug trigger works, the real trigger works
    // (and vice versa).

    @objc private func debugFireMorningGreeting() {
        NotificationCenter.default.post(name: .companionDebugMorningGreeting, object: nil)
    }

    @objc private func debugFireMonthlySummary() {
        NotificationCenter.default.post(name: .companionDebugMonthlySummary, object: nil)
    }

    @objc private func debugFireWelcomeBack() {
        NotificationCenter.default.post(name: .companionDebugWelcomeBack, object: nil)
    }

    @objc private func debugAskForSoulPatch() {
        NotificationCenter.default.post(name: .companionDebugSoulPatchRequest, object: nil)
    }

    @objc private func debugFireSessionJournal() {
        NotificationCenter.default.post(name: .companionDebugSessionJournal, object: nil)
    }

    @objc fileprivate func pickVoiceOff(_ sender: NSMenuItem) {
        Prefs.voiceEnabled = false
    }

    @objc fileprivate func pickVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Prefs.voiceID = id
        Prefs.voiceEnabled = true
    }

    @objc fileprivate func toggleMaxFilter(_ sender: NSMenuItem) {
        Prefs.voiceMaxFilter.toggle()
    }

    /// Populate the Voice submenu with "Off" + one item per installed
    /// AVSpeechSynthesisVoice for the user's preferred language. Trigger
    /// on init and on open (via `VoiceMenuDelegate.menuNeedsUpdate`) so
    /// newly-downloaded Enhanced/Premium voices appear without restart.
    fileprivate func rebuildVoiceMenu() {
        guard let menu = voiceMenu else { return }
        menu.removeAllItems()

        let off = NSMenuItem(
            title: "Off",
            action: #selector(pickVoiceOff(_:)),
            keyEquivalent: ""
        )
        off.target = self
        off.state = Prefs.voiceEnabled ? .off : .on
        menu.addItem(off)

        menu.addItem(.separator())

        let preferred = Locale.preferredLanguages.first ?? "en-US"
        let langPrefix = String(preferred.prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(langPrefix) && ($0.quality == .premium || $0.quality == .enhanced) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }

        let currentID = Prefs.voiceID
        for v in voices {
            let title: String
            switch v.quality {
            case .premium:  title = "\(v.name) — Premium"
            case .enhanced: title = "\(v.name) — Enhanced"
            default:        title = v.name
            }
            let item = NSMenuItem(
                title: title,
                action: #selector(pickVoice(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = v.identifier
            item.state = (Prefs.voiceEnabled && v.identifier == currentID) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let maxFilter = NSMenuItem(
            title: "Max Filter",
            action: #selector(toggleMaxFilter(_:)),
            keyEquivalent: ""
        )
        maxFilter.target = self
        maxFilter.state = Prefs.voiceMaxFilter ? .on : .off
        maxFilter.toolTip = "Pitch + digital distortion + delay + presence boost. The Max-Headroom-ifier."
        menu.addItem(maxFilter)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        NotificationCenter.default.post(
            name: .companionModeRequest,
            object: nil,
            userInfo: ["mode": raw]
        )
    }

    /// Invoked when any overlay's mode manager applied a new preset.
    /// Mirrors the mode into the menu's checkmarks.
    @objc private func onModeChanged(_ note: Notification) {
        guard
            let info = note.userInfo,
            let modeRaw = info["mode"] as? String,
            let mode = MaxClawdroomMode(rawValue: modeRaw)
        else { return }
        let pinned = info["pinned"] as? Bool ?? false
        currentMode = mode
        pinnedMode = pinned ? mode : nil

        for item in modeItems {
            guard let rep = item.representedObject as? String else { continue }
            if rep == "auto" {
                item.state = pinnedMode == nil ? .on : .off
            } else if let m = MaxClawdroomMode(rawValue: rep) {
                item.state = (pinned && m == mode) ? .on : .off
            }
        }
    }
}

extension Notification.Name {
    static let companionShowOnboarding = Notification.Name("companion.show.onboarding")
}

extension Notification.Name {
    static let companionSummon = Notification.Name("companion.summon")
    static let companionPetClicked = Notification.Name("companion.pet.clicked")
    /// Posted by MenuBarController when the user picks a mode. Payload:
    /// `userInfo["mode"] = "auto"|"laptop"|"desktop"|"tv"|"meeting"`.
    static let companionModeRequest = Notification.Name("companion.mode.request")
    /// Posted by OverlayController when a mode apply runs. Payload:
    /// `userInfo["mode"] = <rawValue>`, `userInfo["pinned"] = Bool`.
    static let companionModeChanged = Notification.Name("companion.mode.changed")
    /// Posted by the farewell action op. OverlayController listens to
    /// drop the stage to `.sleeping` and schedule a slow chat close.
    static let companionFarewellRequested = Notification.Name("companion.farewell")

    // Debug-menu triggers — let the user validate long-duration autonomy
    // features without waiting for natural conditions.
    static let companionDebugMorningGreeting = Notification.Name("companion.debug.morning")
    static let companionDebugMonthlySummary = Notification.Name("companion.debug.monthly")
    static let companionDebugWelcomeBack = Notification.Name("companion.debug.welcome_back")
    static let companionDebugSoulPatchRequest = Notification.Name("companion.debug.soul_patch")
    static let companionDebugSessionJournal = Notification.Name("companion.debug.journal")
    /// Posted by MenuBarController when the user picks "Take the Tour…".
    /// Primary overlay listens and opens the chat + starts TourController.
    static let companionStartTour = Notification.Name("companion.tour.start")
    static let companionOpenSettings = Notification.Name("companion.open.settings")
    static let companionVisibilityChanged = Notification.Name("companion.visibility.changed")
    static let companionMultiScreenModeChanged = Notification.Name("companion.multiscreen.changed")
    static let companionRevertToBaseline = Notification.Name("companion.revert.baseline")
}
