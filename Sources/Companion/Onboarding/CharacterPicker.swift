import SwiftUI
import AppKit

struct RolledCharacter: Equatable {
    var name: String
    var outfitPreset: OutfitPreset
    var chatThemePreset: ChatThemePreset
}

enum LuckyRoller {
    static let namePool: [String] = [
        "Nova", "Rex", "Pixel", "Juno", "Echo", "Zephyr", "Mango",
        "Iris", "Atlas", "Sable", "Wren", "Orion", "Luna", "Bandit",
        "Sage", "Koa", "Pepper", "Onyx", "Tilly", "Comet", "Roo",
        "Dash", "Maple", "Kit", "Soren", "Vesper", "Quill", "Birdie",
        "Felix", "Ziggy"
    ]

    static func roll<G: RandomNumberGenerator>(using rng: inout G) -> RolledCharacter {
        let name = namePool.randomElement(using: &rng) ?? "Max"
        let outfit = OutfitPreset.allCases.randomElement(using: &rng) ?? .broadcaster
        let theme = ChatThemePreset.allCases.randomElement(using: &rng) ?? .classic
        return RolledCharacter(name: name, outfitPreset: outfit, chatThemePreset: theme)
    }

    static func roll() -> RolledCharacter {
        var rng = SystemRandomNumberGenerator()
        return roll(using: &rng)
    }
}

enum PickedCharacter: Equatable {
    case max
    case custom(RolledCharacter)

    var asCustom: RolledCharacter? {
        if case .custom(let c) = self { return c }
        return nil
    }
}

extension BackendSettings {
    /// Reconstruct a `PickedCharacter` from the stored fields. Falls back
    /// to `.max` if a `.custom` save references an outfit or theme id
    /// that the current build no longer ships — failing soft beats
    /// crashing the picker on a future preset rename.
    var pickedCharacter: PickedCharacter {
        guard characterPreset == .custom,
              let c = customCharacter,
              let outfit = OutfitPreset(rawValue: c.outfitPresetId),
              let theme = ChatThemePreset(rawValue: c.chatThemePresetId)
        else { return .max }
        return .custom(RolledCharacter(
            name: c.name,
            outfitPreset: outfit,
            chatThemePreset: theme
        ))
    }
}

extension SettingsStore {
    /// Single commit path used by both the onboarding character step
    /// and the Settings → Character row: write the picked values into
    /// `BackendSettings`, then post `companionAppliedCharacter` so
    /// AppDelegate can propagate the visual half to the live Pet +
    /// ChatTheme. Mutator owns the notification (matches the Prefs.swift
    /// convention — see `companionVoiceChanged` / `companionAccessibilityChanged`).
    func applyCharacter(_ picked: PickedCharacter) {
        let resolvedName: String
        let outfitId: String
        let themeId: String
        switch picked {
        case .max:
            resolvedName = "Max"
            outfitId = OutfitPreset.broadcaster.rawValue
            themeId  = ChatThemePreset.classic.rawValue
            settings.characterPreset = .max
            settings.customCharacter = nil
        case .custom(let c):
            resolvedName = MaxClawdroomIdentity.sanitise(c.name.isEmpty ? "Max" : c.name)
            outfitId = c.outfitPreset.rawValue
            themeId  = c.chatThemePreset.rawValue
            settings.characterPreset = .custom
            settings.customCharacter = CustomCharacter(
                name: resolvedName,
                outfitPresetId: outfitId,
                chatThemePresetId: themeId
            )
        }
        settings.companionName = resolvedName
        NotificationCenter.default.post(
            name: .companionAppliedCharacter,
            object: nil,
            userInfo: [
                CompanionAppliedCharacterKey.name:   resolvedName,
                CompanionAppliedCharacterKey.outfit: outfitId,
                CompanionAppliedCharacterKey.theme:  themeId
            ]
        )
    }
}

struct CharacterPickerView: View {
    let initial: PickedCharacter
    let onCommit: (PickedCharacter) -> Void

    @State private var picked: PickedCharacter
    @State private var showingCustomSheet: Bool = false

    init(initial: PickedCharacter, onCommit: @escaping (PickedCharacter) -> Void) {
        self.initial = initial
        self.onCommit = onCommit
        _picked = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Who's your companion?")
                .font(.system(size: 20, weight: .semibold))
            Text("Pick the canonical Max, or roll something custom — name, outfit, and chat look. You can change this later in Settings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                presetCard(
                    title: "Max",
                    subtitle: "broadcaster outfit, CRT chat",
                    selected: picked.asCustom == nil,
                    swatches: (panel: ChatThemePreset.classic.previewSwatches.panel,
                               accent: ChatThemePreset.classic.previewSwatches.accent)
                ) {
                    picked = .max
                    onCommit(.max)
                }

                presetCard(
                    title: "Custom…",
                    subtitle: "your name + look",
                    selected: picked.asCustom != nil,
                    swatches: picked.asCustom.map {
                        ($0.chatThemePreset.previewSwatches.panel,
                         $0.chatThemePreset.previewSwatches.accent)
                    } ?? (Color.secondary.opacity(0.15), Color.orange)
                ) {
                    showingCustomSheet = true
                }
            }

            Button {
                let rolled = LuckyRoller.roll()
                picked = .custom(rolled)
                onCommit(.custom(rolled))
            } label: {
                Label(picked.asCustom == nil
                      ? "I'm feeling lucky"
                      : "Roll again",
                      systemImage: "die.face.5")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            if let custom = picked.asCustom {
                rollPreview(custom)
            }

            Spacer(minLength: 0)
        }
        .sheet(isPresented: $showingCustomSheet) {
            CustomCharacterSheet(
                seed: picked.asCustom ?? RolledCharacter(
                    name: "Max",
                    outfitPreset: .broadcaster,
                    chatThemePreset: .classic
                ),
                onPreview: { rolled in
                    picked = .custom(rolled)
                    onCommit(.custom(rolled))
                }
            ) { final in
                picked = .custom(final)
                showingCustomSheet = false
                onCommit(.custom(final))
            }
        }
    }

    @ViewBuilder
    private func presetCard(
        title: String,
        subtitle: String,
        selected: Bool,
        swatches: (panel: Color, accent: Color),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(swatches.panel)
                        .frame(width: 22, height: 22)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(swatches.accent, lineWidth: 1.5)
                        )
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(selected ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.orange : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func rollPreview(_ c: RolledCharacter) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(c.name)
                    .font(.system(size: 16, weight: .semibold))
                Text("\(c.outfitPreset.rawValue) · \(c.chatThemePreset.displayName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Customize…") { showingCustomSheet = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Keep this one") { onCommit(.custom(c)) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }
}

struct CustomCharacterSheet: View {
    let seed: RolledCharacter
    let onPreview: (RolledCharacter) -> Void
    let onUse: (RolledCharacter) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var outfit: OutfitPreset
    @State private var theme: ChatThemePreset

    init(
        seed: RolledCharacter,
        onPreview: @escaping (RolledCharacter) -> Void,
        onUse: @escaping (RolledCharacter) -> Void
    ) {
        self.seed = seed
        self.onPreview = onPreview
        self.onUse = onUse
        _name = State(initialValue: seed.name)
        _outfit = State(initialValue: seed.outfitPreset)
        _theme = State(initialValue: seed.chatThemePreset)
    }

    private var current: RolledCharacter {
        RolledCharacter(
            name: name.isEmpty ? "Max" : name,
            outfitPreset: outfit,
            chatThemePreset: theme
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Custom companion")
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                TextField("Max", text: Binding(
                    get: { name },
                    set: { name = MaxClawdroomIdentity.sanitise($0) }
                ))
                .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Outfit").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Picker("", selection: $outfit) {
                    ForEach(OutfitPreset.allCases, id: \.self) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Chat look").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Picker("", selection: $theme) {
                    ForEach(ChatThemePreset.allCases, id: \.self) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .labelsHidden()
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Use this") {
                    let final = RolledCharacter(
                        name: name.isEmpty ? "Max" : name,
                        outfitPreset: outfit,
                        chatThemePreset: theme
                    )
                    onUse(final)
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onChange(of: outfit) { _, _ in onPreview(current) }
        .onChange(of: theme)  { _, _ in onPreview(current) }
    }
}

extension Notification.Name {
    /// Posted by `SettingsStore.applyCharacter`. UserInfo carries the
    /// three String values listed in `CompanionAppliedCharacterKey`.
    /// AppDelegate observes and routes to every overlay's Pet + the
    /// shared ChatTheme; the name write is already in BackendSettings.
    static let companionAppliedCharacter = Notification.Name("companion.character.applied")
}

enum CompanionAppliedCharacterKey {
    static let name   = "companionName"
    static let outfit = "outfitPresetId"
    static let theme  = "chatThemePresetId"
}
