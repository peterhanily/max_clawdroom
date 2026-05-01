import SwiftUI
import AppKit

struct OnboardingView: View {
    @Bindable var store: SettingsStore
    var onDone: () -> Void

    @State private var step: Int = 0
    /// 6 steps: welcome → character → connect → permissions → soul → tour-prompt.
    /// Welcome still does the name rename (kept for users who want
    /// the simplest path); character lets them pick Max / Custom /
    /// 🎲 with outfit + chat theme. Choosing a custom character
    /// overwrites the welcome-page name field on commit.
    private let totalSteps = 6

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 580, height: 540)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("🌝")
                .font(.system(size: 24))
            Text("max_clawdroom")
                .font(.system(size: 18, weight: .semibold, design: .serif))
            Spacer()
            progressDots
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<totalSteps, id: \.self) { i in
                Capsule()
                    .fill(i == step ? Color.orange : Color.secondary.opacity(0.25))
                    .frame(width: i == step ? 22 : 7, height: 7)
                    .animation(.easeInOut(duration: 0.2), value: step)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcomePage
        case 1: characterPage
        case 2: connectPage
        case 3: permissionsPage
        case 4: soulPage
        default: tourPage
        }
    }

    private var characterPage: some View {
        CharacterPickerView(initial: store.settings.pickedCharacter) { picked in
            store.applyCharacter(picked)
        }
    }

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("onboarding.welcome.title", bundle: .companionResources)
                .font(.system(size: 22, weight: .semibold))

            // Name field — first thing the user does. Defaults to "Max"
            // but anyone who wants to call him "Rex" or "Nova" can do it
            // before any of his name surfaces elsewhere in the UI.
            VStack(alignment: .leading, spacing: 6) {
                Text("onboarding.welcome.name_prompt", bundle: .companionResources)
                    .font(.system(size: 13, weight: .medium))
                TextField(
                    "Max",
                    text: Binding(
                        get: { store.settings.companionName },
                        set: { store.settings.companionName = MaxClawdroomIdentity.sanitise($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                Text("onboarding.welcome.name_hint", bundle: .companionResources)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                bullet(String(localized: "onboarding.welcome.bullet1", bundle: .companionResources))
                bullet(String(localized: "onboarding.welcome.bullet2", bundle: .companionResources))
                bullet(String(localized: "onboarding.welcome.bullet3", bundle: .companionResources))
                bullet(String(localized: "onboarding.welcome.bullet4", bundle: .companionResources))
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 4) {
                Text("onboarding.welcome.shortcuts", bundle: .companionResources)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("onboarding.shortcut.summon", bundle: .companionResources)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("onboarding.shortcut.settings_quit", bundle: .companionResources)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Connect step

    /// Replaces the legacy "backend" page. Walks the user from "no
    /// idea what to pick" to "Max has a working channel" with three
    /// branches based on what's available on the machine:
    ///   1. claude CLI present + local server enabled → Local channel ready.
    ///   2. claude CLI present, server off → one-click "Start local server."
    ///   3. claude CLI missing → guided install with copy-able command;
    ///      offer the Claude Code CLI channel as a delayed fallback.
    private var connectPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect Max")
                .font(.system(size: 20, weight: .semibold))
            Text("Max needs a brain. The simplest setup runs claude-code on this Mac and exposes it on a loopback port — Max talks to that. You can add LAN or remote channels later from the Channels menu.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            claudeDetectionPanel

            connectActionPanel

            VStack(alignment: .leading, spacing: 8) {
                labeled(String(localized: "onboarding.backend.workdir_label", bundle: .companionResources)) {
                    HStack {
                        TextField("~", text: $store.settings.cwd)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        Button(String(localized: "settings.button.choose", bundle: .companionResources)) {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            panel.directoryURL = URL(fileURLWithPath: store.settings.cwd)
                            if panel.runModal() == .OK, let url = panel.url {
                                store.settings.cwd = url.path
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var connectActionPanel: some View {
        let claudePresent = FileManager.default.isExecutableFile(
            atPath: store.settings.claudeBinaryPath
        )
        VStack(alignment: .leading, spacing: 10) {
            if claudePresent {
                if Prefs.localOpenAIServerEnabled {
                    Label("Local server is on. The Local channel will route to it.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12))
                } else {
                    HStack(spacing: 10) {
                        Button {
                            Prefs.localOpenAIServerEnabled = true
                        } label: {
                            Label("Start local server", systemImage: "play.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Text("Hosts /v1/chat/completions on 127.0.0.1:52429 backed by claude-code. You can also turn this off later in Settings → Channels.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Install Claude Code, or use a remote channel",
                          systemImage: "info.circle")
                        .font(.system(size: 12, weight: .medium))
                    Text("Run this in Terminal, then come back and click Re-detect:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text("brew install claude-code")
                            .font(.system(size: 12, design: .monospaced))
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.06)))
                            .textSelection(.enabled)
                        Button {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString("brew install claude-code", forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Copy command")
                    }
                    Text("Already running clawdex on a different Mac, a Tailscale host, or a Cloudflare Tunnel? Skip this step — you can add a LAN or Remote channel from the menu bar.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - Permissions step

    /// Explainer for the macOS Accessibility prompt — replaces the
    /// bare system dialog from AppDelegate. Users denied 60% of the
    /// time on the bare prompt because they don't know why it's
    /// asked; here we say what it unlocks before asking.
    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions")
                .font(.system(size: 20, weight: .semibold))
            Text("Max can run with no permissions at all — most features work either way. Granting Accessibility unlocks a few extras that need to see other apps.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            permissionRow(
                title: "Accessibility",
                trusted: AccessibilityPermission.isTrusted,
                description: "Lets Max see your focused editor window so he can walk to where you're working, follow your cursor for gaze, and trigger the global hotkeys (⌥Space, ⌘⌥Space). Nothing leaves your machine.",
                onGrant: {
                    _ = AccessibilityPermission.requestTrust()
                },
                onOpenSettings: {
                    AccessibilityPermission.openSystemSettings()
                }
            )

            Text("Microphone and Notifications prompts will appear the first time you use voice input or receive a daily nudge — Max won't ask up front.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        trusted: Bool,
        description: String,
        onGrant: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(trusted ? .green : .orange)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if !trusted {
                    Button("Grant", action: onGrant).buttonStyle(.borderedProminent).controlSize(.small)
                    Button("System Settings", action: onOpenSettings).buttonStyle(.bordered).controlSize(.small)
                } else {
                    Text("Granted").font(.system(size: 11)).foregroundStyle(.green)
                }
            }
            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - Tour prompt step

    /// Last step. Offers the tour as the final action so the user
    /// lands in motion instead of staring at a still pet.
    private var tourPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Take the tour?")
                .font(.system(size: 20, weight: .semibold))
            Text("60 seconds of Max showing what he can do — walk, change expression, swap clothes, talk in TV mode. Skippable any time.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recommended for first-time users")
                        .font(.system(size: 12, weight: .medium))
                    Text("You can re-run it later from the menu bar → Help → Take the tour.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var claudeDetectionPanel: some View {
        let path = store.settings.claudeBinaryPath
        let exists = FileManager.default.isExecutableFile(atPath: path)
        HStack(spacing: 10) {
            Image(systemName: exists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(exists ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(exists
                     ? String(localized: "onboarding.backend.detected", bundle: .companionResources)
                     : String(localized: "onboarding.backend.not_found", bundle: .companionResources))
                    .font(.system(size: 12, weight: .semibold))
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                if !exists {
                    Text("onboarding.backend.install_hint", bundle: .companionResources)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(String(localized: "onboarding.backend.redetect", bundle: .companionResources)) {
                store.settings.claudeBinaryPath = BackendSettings.autoDetectedClaudePath()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var soulPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("onboarding.soul.title", bundle: .companionResources)
                .font(.system(size: 20, weight: .semibold))
            Text("onboarding.soul.body", bundle: .companionResources)
                .foregroundStyle(.secondary)

            TextEditor(text: $store.settings.systemPrompt)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )

            HStack {
                Button(String(localized: "onboarding.soul.use_suggested", bundle: .companionResources)) {
                    store.settings.systemPrompt = Self.suggestedPrompt
                }
                .buttonStyle(.bordered)
                Button(String(localized: "onboarding.soul.clear", bundle: .companionResources)) {
                    store.settings.systemPrompt = ""
                }
                .buttonStyle(.bordered)
                Spacer()
            }

            Text("onboarding.soul.footer_hint", bundle: .companionResources)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button(String(localized: "onboarding.button.back", bundle: .companionResources)) { step -= 1 }
                    .buttonStyle(.bordered)
            }
            Spacer()
            if step < totalSteps - 1 {
                Button(String(localized: "onboarding.button.next", bundle: .companionResources)) { step += 1 }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Skip the tour") { finish(startTour: false) }
                    .buttonStyle(.bordered)
                Button("Take the tour") { finish(startTour: true) }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func finish(startTour: Bool) {
        UserDefaults.standard.set(true, forKey: "companion.hasOnboarded")
        if startTour {
            // Slight delay so the onboarding window's close animation
            // doesn't fight the chat-open animation the tour kicks off.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotificationCenter.default.post(name: .companionStartTour, object: nil)
            }
        }
        onDone()
    }

    // MARK: - Helpers

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(.orange)
                .padding(.top, 8)
            Text(text)
                .font(.system(size: 13))
        }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 90, alignment: .trailing)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            content()
        }
    }

    private static let suggestedPrompt = """
    You are a quiet, thoughtful companion. Speak in short, considered \
    sentences. Help the person you're talking to with their code, their \
    day, their mood. Don't over-explain. Don't fill silence. Reflect \
    before you reply.
    """
}
