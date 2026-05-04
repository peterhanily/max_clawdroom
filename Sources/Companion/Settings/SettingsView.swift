import AppKit
import SwiftUI

struct SoulHistoryView: View {
    let history: SoulHistory
    @State private var confirmingRevertID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            growthSummary
            if history.entries.isEmpty {
                Text("No accepted patches yet. When you accept one from Max's Proposals (or revert via this list), it'll appear here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(history.entries.prefix(10)) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.rationale.isEmpty ? "(manual edit)" : entry.rationale)
                                    .font(.system(size: 12))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(relativeDate(entry.appliedAt))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(String(localized: "settings.button.revert", bundle: .companionResources)) {
                                history.revert(to: entry.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.04))
                        )
                    }
                    if history.entries.count > 10 {
                        Text("\(history.entries.count - 10) older entries not shown.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Small "how much has Max grown" readout at the top of the list.
    /// Makes the compounding visible instead of burying it in a list
    /// of line items the user has to scan to feel.
    private var growthSummary: some View {
        let accepted = history.entries.filter { !$0.rationale.hasPrefix("Reverted to snapshot") }.count
        let reverts = history.entries.count - accepted
        let span = spanDescription(from: history.entries.last?.appliedAt, to: history.entries.first?.appliedAt)
        return HStack(spacing: 16) {
            metric(number: accepted, label: accepted == 1 ? "patch accepted" : "patches accepted")
            if reverts > 0 {
                metric(number: reverts, label: reverts == 1 ? "revert" : "reverts")
            }
            if let span {
                VStack(alignment: .leading, spacing: 2) {
                    Text(span)
                        .font(.system(size: 12, weight: .medium))
                    Text("span")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.08))
        )
    }

    private func metric(number: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(number)")
                .font(.system(size: 18, weight: .semibold))
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .tracking(1)
                .foregroundStyle(.secondary)
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    /// Returns "21 days", "3 months", "over a year" etc. based on the
    /// span between first and last entry. Nil when there's only one
    /// entry or none.
    private func spanDescription(from earliest: Date?, to latest: Date?) -> String? {
        guard let earliest, let latest, earliest != latest else { return nil }
        let days = Int(latest.timeIntervalSince(earliest) / 86_400)
        if days < 1 { return "<1 day" }
        if days < 14 { return "\(days) days" }
        let months = days / 30
        if months < 12 { return "\(months) mo" }
        return "over a year"
    }
}

struct SettingsView: View {
    @Bindable var store: SettingsStore
    @State private var testResult: TestState = .idle

    enum TestState: Equatable {
        case idle
        case testing
        case ok(String)
        case fail(String)
    }

    private let accent = Color.orange
    @State private var accessibilityTrusted: Bool = AccessibilityPermission.isTrusted
    @State private var accessibilityTimer: Timer?

    private let permissionModes: [(label: String, value: String, help: String)] = [
        ("Accept edits", "acceptEdits", "Pre-approves file writes; other tools still prompt. Safest default."),
        ("Bypass all", "bypassPermissions", "No permission prompts at all. Fastest; use only in trusted dirs."),
        ("Plan", "plan", "Claude proposes actions without executing them.")
    ]

    private let modelAliases = ["", "sonnet", "opus", "haiku"]

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 8)

            TabView {
                generalTab
                    .tabItem { Label("General", systemImage: "gearshape") }

                channelsTab
                    .tabItem { Label("Channels", systemImage: "antenna.radiowaves.left.and.right") }

                mindTab
                    .tabItem { Label("Mind", systemImage: "brain") }

                lookTab
                    .tabItem { Label("Voice & Look", systemImage: "waveform") }

                behaviourTab
                    .tabItem { Label("Behaviour", systemImage: "sparkle") }

                PrivacyTab()
                    .tabItem { Label("Privacy", systemImage: "lock.shield") }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            footer
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
        }
        .frame(minWidth: 580, idealWidth: 620, minHeight: 520, idealHeight: 640)
    }

    // MARK: - Tabs

    @ViewBuilder
    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section(title: String(localized: "settings.section.name", bundle: .companionResources), icon: "person.text.rectangle") {
                    VStack(alignment: .leading, spacing: 8) {
                        field(label: "Call him") {
                            TextField(
                                "Max",
                                text: Binding(
                                    get: { store.settings.companionName },
                                    set: { store.settings.companionName = MaxClawdroomIdentity.sanitise($0) }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                        }
                        Text("Renames him across the chat header, TV ticker, \(MaxClawdroomIdentity.possessive()) Room window title, notifications, and VoiceOver. Max \(MaxClawdroomIdentity.maxLength) characters; special characters and line breaks are stripped for safety.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                section(title: "Character", icon: "theatermasks") {
                    CharacterPickerView(initial: store.settings.pickedCharacter) { picked in
                        store.applyCharacter(picked)
                    }
                }

                section(title: String(localized: "settings.section.privacy", bundle: .companionResources), icon: "hand.raised") {
                    PrivacyPanel()
                }

                section(title: "Permissions", icon: "lock.shield") {
                    PermissionsPanel()
                }

                section(title: String(localized: "settings.section.accessibility", bundle: .companionResources), icon: "figure.arms.open") {
                    accessibilityBody
                }

                section(title: "Diagnostics", icon: "stethoscope") {
                    DiagnosticsPanel()
                }

                Spacer(minLength: 0)
            }
            .padding(22)
        }
    }

    @ViewBuilder
    private var channelsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section(title: "Channels", icon: "antenna.radiowaves.left.and.right") {
                    ChannelListPanel()
                }

                // CLI fields feed every `.claudeCodeCLI` channel. Hidden
                // when no channel uses that kind so non-CLI users don't
                // see knobs that don't apply.
                if hasCLIChannel {
                    section(title: String(localized: "settings.section.claude_cli", bundle: .companionResources), icon: "terminal") {
                        cliFields
                    }

                    section(title: String(localized: "settings.section.tools_permissions", bundle: .companionResources), icon: "lock.shield") {
                        toolsAndPermissionsFields
                    }
                }

                section(title: String(localized: "settings.section.local_server", bundle: .companionResources), icon: "server.rack") {
                    LocalOpenAIServerPanel()
                }

                if hasCLIChannel {
                    section(title: String(localized: "settings.section.cli_check", bundle: .companionResources), icon: "checkmark.shield") {
                        cliCheckRow
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(22)
        }
    }

    @ViewBuilder
    private var mindTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section(title: String(localized: "settings.section.soul", bundle: .companionResources), icon: "sparkles") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Appended to Claude Code's system prompt via --append-system-prompt. Takes effect on the next chat reset.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $store.settings.systemPrompt)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 120)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.primary.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                            )
                    }
                }

                section(title: String(localized: "settings.section.soul_history", bundle: .companionResources), icon: "clock.arrow.circlepath") {
                    SoulHistoryView(history: SoulHistory.shared)
                }

                section(title: String(localized: "settings.section.how_max_sees_you", bundle: .companionResources), icon: "person.crop.circle") {
                    UserModelPanel()
                }

                Spacer(minLength: 0)
            }
            .padding(22)
        }
    }

    @ViewBuilder
    private var lookTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section(title: String(localized: "settings.section.voice", bundle: .companionResources), icon: "waveform") {
                    VoiceLanguagePanel()
                }

                section(title: "Sound effects", icon: "speaker.wave.2") {
                    SoundEffectsPanel()
                }

                section(title: String(localized: "settings.section.images", bundle: .companionResources), icon: "photo.on.rectangle.angled") {
                    ImageLibraryPanel()
                }

                Spacer(minLength: 0)
            }
            .padding(22)
        }
    }

    @ViewBuilder
    private var behaviourTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section(title: String(localized: "settings.section.autonomy", bundle: .companionResources), icon: "sparkle") {
                    AutonomyPanel()
                }

                section(title: String(localized: "settings.section.agent_lifecycle", bundle: .companionResources), icon: "arrow.triangle.2.circlepath") {
                    AgentLifecyclePanel()
                }

                Spacer(minLength: 0)
            }
            .padding(22)
        }
    }

    // MARK: - Tab fragments

    private var hasCLIChannel: Bool {
        ChannelStore.shared.channels.contains { $0.kind == .claudeCodeCLI }
    }

    @ViewBuilder
    private var cliFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("These fields feed every channel of kind \"Claude Code CLI\". Per-channel overrides aren't supported yet — the values here apply to all CLI channels.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            field(label: "Binary") {
                HStack {
                    TextField("/path/to/claude", text: $store.settings.claudeBinaryPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button(String(localized: "settings.button.detect", bundle: .companionResources)) {
                        store.settings.claudeBinaryPath =
                            BackendSettings.autoDetectedClaudePath()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            field(label: "Working dir") {
                HStack {
                    TextField("~", text: $store.settings.cwd)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button(String(localized: "settings.button.choose", bundle: .companionResources)) {
                        chooseCwd()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            field(label: "Model") {
                Picker("", selection: $store.settings.model) {
                    ForEach(modelAliases, id: \.self) { alias in
                        Text(alias.isEmpty ? "CLI default" : alias).tag(alias)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private var toolsAndPermissionsFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            field(label: "Mode") {
                Picker("", selection: $store.settings.permissionMode) {
                    ForEach(permissionModes, id: \.value) { mode in
                        Text(mode.label).tag(mode.value)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            if let help = permissionModes.first(where: { $0.value == store.settings.permissionMode })?.help {
                Text(help)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 98)
            }
            field(label: "Allowed tools") {
                TextField(
                    BackendSettings.defaultAllowedTools,
                    text: $store.settings.allowedTools
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            }
            Text("Comma-separated list. Tools not listed will block on a permission prompt that a GUI app can't answer. Bash(*), WebFetch(*) etc. are pattern wildcards.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 98)
        }
    }

    @ViewBuilder
    private var cliCheckRow: some View {
        HStack(spacing: 12) {
            Button {
                runTest()
            } label: {
                HStack(spacing: 6) {
                    if testResult == .testing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11))
                    }
                    Text(testResult == .testing ? "Checking…" : "Check claude --version")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(testResult == .testing)

            testStatusView

            Spacer()
        }
    }

    private var footer: some View {
        VStack(alignment: .center, spacing: 4) {
            Link(destination: URL(string: "https://caddylabs.io")!) {
                Text("caddylabs.io")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            Text("Made with love and tokens in Ireland 🇮🇪")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func chooseCwd() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: store.settings.cwd)
        if panel.runModal() == .OK, let url = panel.url {
            store.settings.cwd = url.path
        }
    }

    private func runTest() {
        testResult = .testing
        let path = store.settings.claudeBinaryPath
        Task.detached {
            let (ok, message) = probeVersion(path: path)
            await MainActor.run {
                testResult = ok ? .ok("OK — \(message)") : .fail(message)
            }
        }
    }

    private nonisolated func probeVersion(path: String) -> (Bool, String) {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return (false, "No executable at \(path)")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return (false, "Failed to run: \(error.localizedDescription)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if proc.terminationStatus != 0 {
            return (false, "Exit \(proc.terminationStatus): \(String(output.prefix(60)))")
        }
        return (true, output)
    }

    // MARK: - Accessibility

    private var accessibilityBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(accessibilityTrusted ? .green : Color.secondary.opacity(0.45))
                    .frame(width: 10, height: 10)
                Text(accessibilityTrusted ? "Granted" : "Not granted")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if !accessibilityTrusted {
                    Button(String(localized: "settings.button.request", bundle: .companionResources)) {
                        _ = AccessibilityPermission.requestTrust()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Open Settings") {
                        AccessibilityPermission.openSystemSettings()
                    }
                    .buttonStyle(.bordered)
                }
            }
            Text("Lets the companion see your focused editor window so it can walk over to where you're working (e.g. when the agent runs `walk_to_editor`). Nothing leaves your machine.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: startPollingTrust)
        .onDisappear(perform: stopPollingTrust)
    }

    private func startPollingTrust() {
        stopPollingTrust()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                accessibilityTrusted = AccessibilityPermission.isTrusted
            }
        }
    }

    private func stopPollingTrust() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("🌝")
                .font(.system(size: 22))
            Text("max_clawdroom")
                .font(.system(size: 18, weight: .semibold, design: .serif))
            Spacer()
        }
    }

    // MARK: - Section container

    private func section<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 90, alignment: .trailing)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            content()
        }
    }

    @ViewBuilder
    private var testStatusView: some View {
        switch testResult {
        case .idle, .testing:
            EmptyView()
        case .ok(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 11))
        case .fail(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
                .font(.system(size: 11))
        }
    }
}

/// "How Max sees you" — a rendered view of the `UserModel` synthesised
/// from raw memory entries. First cut is read-only; knowing what Max
/// sees is enough of a feature on its own that shipping the editor can
/// follow. Refresh button forces a fresh synthesis.
struct UserModelPanel: View {
    // Migrated from @StateObject → @State for @Observable pattern.
    // Granular tracking: view only re-renders on the specific
    // UserModel fields it reads, not on every proxy update.
    @State private var proxy = UserModelProxy()
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if proxy.model.isEmpty {
                Text("Max hasn't formed a picture of you yet. A fresh install needs a few turns of memory before synthesis kicks in. Chat with him for a bit; the model fills in.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                identityRows
                if !proxy.model.preferences.isEmpty { preferenceRows }
                if !proxy.model.runningThreads.isEmpty { threadRows }
                if !proxy.model.rituals.isEmpty { ritualRows }
                if !proxy.model.recentMoodSignal.isEmpty {
                    labelRow("Mood", proxy.model.recentMoodSignal)
                }
            }

            HStack(spacing: 10) {
                Button {
                    isRefreshing = true
                    UserModelSynthesiser.shared?.forceRefresh()
                    // Naïve re-enable — synthesiser publishes through the
                    // store, so we just flip the flag after a short delay.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        isRefreshing = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                        Text(isRefreshing ? "Asking Max…" : "Refresh")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshing)

                Text(refreshedStamp)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var identityRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !proxy.model.identity.role.isEmpty {
                labelRow("Role", proxy.model.identity.role)
            }
            if !proxy.model.identity.stack.isEmpty {
                labelRow("Stack", proxy.model.identity.stack)
            }
            if !proxy.model.identity.timezone.isEmpty {
                labelRow("Timezone", proxy.model.identity.timezone)
            }
            if !proxy.model.identity.communication.isEmpty {
                labelRow("Tone", proxy.model.identity.communication)
            }
        }
    }

    private var preferenceRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            labelHeader("Preferences")
            ForEach(proxy.model.preferences) { p in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(p.pref)
                        .font(.system(size: 12))
                    Text(p.confidence.rawValue)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.primary.opacity(0.08))
                        )
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 98)
            }
        }
    }

    private var threadRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            labelHeader("Running threads")
            ForEach(proxy.model.runningThreads) { t in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(t.topic)
                        .font(.system(size: 12))
                    Text(t.status.rawValue)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(statusTint(t.status).opacity(0.18))
                        )
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 98)
            }
        }
    }

    private var ritualRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            labelHeader("Rituals")
            ForEach(proxy.model.rituals) { r in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("\(r.name):")
                        .font(.system(size: 12, weight: .medium))
                    Text(r.pattern)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 98)
            }
        }
    }

    private func labelRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 90, alignment: .trailing)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            Text(value)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func labelHeader(_ label: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 90, alignment: .trailing)
                .foregroundStyle(.secondary)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
        }
    }

    private func statusTint(_ s: UserModel.RunningThread.Status) -> Color {
        switch s {
        case .inFlight: return .accentColor
        case .parked:   return .orange
        case .done:     return .secondary
        }
    }

    private var refreshedStamp: String {
        guard proxy.model.refreshedAt != .distantPast else {
            return "never synthesised"
        }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return "Refreshed \(fmt.localizedString(for: proxy.model.refreshedAt, relativeTo: Date()))"
    }
}

/// Lightweight bridge so the panel can observe whichever `UserModelStore`
/// `AppDelegate` wired up. The store itself is the @Observable source;
/// this proxy just mirrors its model to the view so the Settings pane
/// always sees a live value regardless of when the overlay is rebuilt.
@Observable
@MainActor
private final class UserModelProxy {
    var model: UserModel = .empty

    init() {
        if let store = UserModelStore.shared {
            self.model = store.model
        }
        trackStore()
    }

    private func trackStore() {
        withObservationTracking {
            _ = UserModelStore.shared?.model  // register a read on the tracked property
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let store = UserModelStore.shared {
                    self.model = store.model
                }
                self.trackStore()  // re-arm — onChange fires exactly once
            }
        }
    }
}

/// Language-override picker for the TTS voice. Used when the user wants
/// Max to speak in a language other than the system default — e.g. a
/// native Spanish user who wants English banter, or vice versa. Only
/// visible entries are the handful of languages most AVSpeech voices
/// Toggle + status for the built-in OpenAI-compatible HTTP server. When
/// ON, max_clawdroom binds `http://127.0.0.1:52429/v1/chat/completions`
/// so other tools (Cursor, Continue, `openai` Python SDK, shell scripts)
/// can call Claude through the same backend as the companion chat.
///
/// Off by default — opening a listening port deserves a deliberate action
/// even on loopback. When on, the port is localhost-only (no LAN bind,
/// no discovery).
struct LocalOpenAIServerPanel: View {
    @State private var enabled: Bool = Prefs.localOpenAIServerEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { enabled },
                set: { newValue in
                    enabled = newValue
                    Prefs.localOpenAIServerEnabled = newValue
                }
            )) {
                Text("Serve OpenAI-compatible endpoint on 127.0.0.1:52429")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)

            if enabled {
                Text("Point any OpenAI client at `http://127.0.0.1:52429/v1`. Loopback only — not exposed to the network. Replaces the standalone clawdex proxy.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("When on, Cursor/Continue/scripts can call Claude through this app. Localhost only.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// User-curated image library — images Max can wrap onto his clothes
/// or use as chat backgrounds. The agent references images by NAME;
/// it can't load arbitrary filesystem paths, only items the user has
/// explicitly added here.
struct ImageLibraryPanel: View {
    @State private var library = ImageLibrary.shared
    @State private var renamingID: UUID?
    @State private var renameDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                importImage()
            } label: {
                Label("Add image…", systemImage: "plus.square.on.square")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)

            Toggle(isOn: Binding(
                get: { Prefs.allowAgentImageOps },
                set: { Prefs.allowAgentImageOps = $0 }
            )) {
                Text("Let Max download + generate images on his own")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            Text("When ON, Max can fetch images from URLs (HTTPS only, loopback and private ranges blocked, 10 MB cap, image-type required) and render procedural patterns into the library. OFF by default.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if library.images.isEmpty {
                Text("No images yet. Add PNG/JPG files here; Max can then wrap them onto his clothes (`set_part_texture`) or use them as chat backgrounds (`set_chat_background`).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(library.images) { entry in
                        HStack(spacing: 8) {
                            if let ns = ImageLibrary.shared.loadNSImage(named: entry.name) {
                                Image(nsImage: ns)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            } else {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(width: 36, height: 36)
                            }
                            if renamingID == entry.id {
                                TextField("name", text: $renameDraft, onCommit: {
                                    library.rename(id: entry.id, to: renameDraft)
                                    renamingID = nil
                                })
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 180)
                            } else {
                                Text(entry.name).font(.system(size: 12, design: .monospaced))
                            }
                            Spacer()
                            Button {
                                renamingID = entry.id
                                renameDraft = entry.name
                            } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                            Button {
                                library.remove(id: entry.id)
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red.opacity(0.85))
                        }
                    }
                }
            }
        }
    }

    private func importImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .gif, .bmp]
        panel.message = "Choose an image Max can use."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let baseName = url.deletingPathExtension().lastPathComponent
        library.importImage(from: url, name: baseName)
    }
}

/// Toggle for the deliberate agent lifecycle — wake → survey → plan →
/// work → idle → sleep loop on top of the basic autonomy tick. When
/// on, Max accumulates a self-assigned task queue per project and
/// periodically surveys for new work.
struct AgentLifecyclePanel: View {
    @State private var enabled: Bool = Prefs.agentLifecycleEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { enabled },
                set: { newValue in
                    enabled = newValue
                    Prefs.agentLifecycleEnabled = newValue
                }
            )) {
                Text("Enable wake / survey / plan / sleep cycle")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            Text("Max explicitly cycles through phases: wakes, surveys for new work (git commits, unfinished memory threads, task queue), plans a silent action, and sleeps when idle. State persists across relaunches. Off by default — autonomy still ticks periodically without it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// ship for; a nil choice (Follow System) is the out-of-box behaviour
/// and matches what shipped before this toggle existed.
struct VoiceLanguagePanel: View {
    @State private var selection: String = Prefs.voiceLanguageOverride ?? ""

    private static let choices: [(String, String)] = [
        ("", "Follow system"),
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("en-AU", "English (AU)"),
        ("fr-FR", "French"),
        ("de-DE", "German"),
        ("es-ES", "Spanish"),
        ("it-IT", "Italian"),
        ("pt-BR", "Portuguese (BR)"),
        ("ja-JP", "Japanese"),
        ("zh-CN", "Chinese (Mandarin)")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Language")
                    .frame(width: 90, alignment: .trailing)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                Picker("", selection: $selection) {
                    ForEach(Self.choices, id: \.0) { code, label in
                        Text(label).tag(code)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: selection) { _, new in
                    Prefs.voiceLanguageOverride = new.isEmpty ? nil : new
                }
            }
            Text("Overrides the system locale when picking a default voice. A specific voice chosen from the menu-bar Voice list still wins over this — this only kicks in when no voice is explicitly selected.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 98)
        }
    }
}

/// Per-block toggles for what gets prepended to each user message.
/// Defaults are ON for the out-of-box "Max is aware of what you're up to"
/// experience; flip OFF when working with sensitive apps / code.
/// `EnvironmentSensors.contextSnapshot` reads these live on each turn
/// so changes take effect immediately — no session restart.
struct PrivacyPanel: View {
    @State private var shareEnv: Bool = Prefs.shareEnvBlock
    @State private var shareEditor: Bool = Prefs.shareEditorBlock
    @State private var shareAppContext: Bool = Prefs.shareAppContextBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $shareEnv) {
                Text("Share ambient context")
                    .font(.system(size: 12))
            }
            .onChange(of: shareEnv) { _, new in Prefs.shareEnvBlock = new }
            Text("Time, frontmost app, git SHA, battery, display config, idle seconds. Off = Max has no situational awareness.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $shareEditor) {
                Text("Share editor context")
                    .font(.system(size: 12))
            }
            .disabled(!shareEnv)
            .onChange(of: shareEditor) { _, new in Prefs.shareEditorBlock = new }
            Text("Focused file path, cursor line, selected text. Turn off for confidential code bases — Max still answers, he just can't see your screen.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $shareAppContext) {
                Text("Share browser / window titles")
                    .font(.system(size: 12))
            }
            .disabled(!shareEnv)
            .onChange(of: shareAppContext) { _, new in Prefs.shareAppContextBlock = new }
            Text("Browser URL + tab title, Finder folder, terminal / Electron window title. Off = no window-title history in Max's prompt.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Autonomy controls. Binds directly to `Prefs` (not `BackendSettings`) —
/// autonomy lives in UserDefaults alongside voice/gravity, not in the
/// backend-config struct. `AutonomyController` listens for
/// `companionAutonomyChanged` and reacts, so changes take effect on the
/// next tick without a restart.
struct AutonomyPanel: View {
    @State private var enabled: Bool = Prefs.autonomyEnabled
    @State private var intervalMinutes: Double = Prefs.autonomyInterval / 60
    @State private var banter: Prefs.BanterFrequency = Prefs.banterFrequency

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $enabled) {
                Text("Run autonomy ticks")
                    .font(.system(size: 12))
            }
            .onChange(of: enabled) { _, new in Prefs.autonomyEnabled = new }

            Text("When on, Max sends himself silent prompts so he can react to what you're doing without being spoken to. Turn off for a fully manual companion.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline) {
                Text("Interval")
                    .frame(width: 90, alignment: .trailing)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                Slider(value: $intervalMinutes, in: 2...60, step: 1)
                    .disabled(!enabled)
                    .onChange(of: intervalMinutes) { _, new in
                        Prefs.autonomyInterval = new * 60
                    }
                Text("\(Int(intervalMinutes)) min")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Banter")
                    .frame(width: 90, alignment: .trailing)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                Picker("", selection: $banter) {
                    Text("Off (silent)").tag(Prefs.BanterFrequency.off)
                    Text("Rare").tag(Prefs.BanterFrequency.rare)
                    Text("Often").tag(Prefs.BanterFrequency.often)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!enabled)
                .onChange(of: banter) { _, new in Prefs.banterFrequency = new }
            }
            Text("How often Max speaks unprompted during autonomy ticks. Off = action-only; he fiddles silently. Rare = a short line now and then. Often = frequent commentary.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 98)
        }
    }
}
