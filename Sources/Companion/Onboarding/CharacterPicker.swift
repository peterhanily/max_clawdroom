import SwiftUI
import AppKit

/// Output of the lucky roller. Kept as a plain value type so tests can
/// assert on it without spinning up a SwiftUI view.
struct RolledCharacter: Equatable {
    var name: String
    var outfitPreset: OutfitPreset
    var chatThemePreset: ChatThemePreset
}

/// Pure functions that draw a random `RolledCharacter`. Lives in its own
/// type so tests can pass a deterministic `RandomNumberGenerator` and
/// assert the distribution.
enum LuckyRoller {
    /// Curated 30-name pool, mixed across feminine / masculine / neutral
    /// / nicknames. Hand-picked to be playful and to avoid anything that
    /// reads like an existing AI-product brand.
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

    /// Convenience wrapper for the UI — rolls with the system RNG.
    static func roll() -> RolledCharacter {
        var rng = SystemRandomNumberGenerator()
        return roll(using: &rng)
    }
}

/// Choice the picker has settled on. Mirrors `BackendSettings`'
/// `characterPreset` + `customCharacter` shape but keeps the picker
/// view self-contained — the parent commits the result to settings.
enum PickedCharacter: Equatable {
    case max
    case custom(RolledCharacter)
}

/// Reusable picker UI used by the onboarding character step and the
/// Settings → Character row. Two big cards (Max / Custom) plus the
/// lucky button. Lucky updates the in-place preview without committing
/// — the user has to hit "Keep this one" to confirm.
struct CharacterPickerView: View {
    /// Initial value when the view appears.
    let initial: PickedCharacter
    /// Called when the user commits — onboarding writes settings + posts
    /// the apply notification; settings does the same.
    let onCommit: (PickedCharacter) -> Void

    @State private var picked: PickedCharacter
    @State private var rolled: RolledCharacter?
    @State private var showingCustomSheet: Bool = false

    init(initial: PickedCharacter, onCommit: @escaping (PickedCharacter) -> Void) {
        self.initial = initial
        self.onCommit = onCommit
        _picked = State(initialValue: initial)
        if case .custom(let c) = initial {
            _rolled = State(initialValue: c)
        }
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
                    selected: isMaxSelected,
                    swatches: (panel: ChatThemePreset.classic.previewSwatches.panel,
                               accent: ChatThemePreset.classic.previewSwatches.accent)
                ) {
                    picked = .max
                    rolled = nil
                }

                presetCard(
                    title: "Custom…",
                    subtitle: "your name + look",
                    selected: isCustomSelected,
                    swatches: rolled.map {
                        ($0.chatThemePreset.previewSwatches.panel,
                         $0.chatThemePreset.previewSwatches.accent)
                    } ?? (Color.secondary.opacity(0.15), Color.orange)
                ) {
                    showingCustomSheet = true
                }
            }

            Button {
                let r = LuckyRoller.roll()
                rolled = r
                picked = .custom(r)
            } label: {
                Label(rolled == nil
                      ? "I'm feeling lucky"
                      : "Roll again",
                      systemImage: "die.face.5")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            if case .custom(let c) = picked {
                rollPreview(c)
            }

            Spacer(minLength: 0)
        }
        .sheet(isPresented: $showingCustomSheet) {
            CustomCharacterSheet(
                seed: rolled ?? RolledCharacter(
                    name: "Max",
                    outfitPreset: .broadcaster,
                    chatThemePreset: .classic
                )
            ) { final in
                rolled = final
                picked = .custom(final)
                showingCustomSheet = false
                onCommit(.custom(final))
            }
        }
        .onChange(of: picked) { _, new in
            // .max commits immediately; .custom commits via sheet "Use
            // this" or "Keep this one" lucky-confirm. The lucky button
            // alone doesn't commit — user can keep rolling.
            if case .max = new { onCommit(.max) }
        }
    }

    private var isMaxSelected: Bool {
        if case .max = picked { return true } else { return false }
    }

    private var isCustomSelected: Bool {
        if case .custom = picked { return true } else { return false }
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

/// Sub-sheet opened from the picker. Lets the user tweak the rolled
/// values directly — name, outfit dropdown, theme dropdown — and
/// commit. Pre-fills with whatever the picker handed in (either the
/// last roll, or a Max-shaped seed).
struct CustomCharacterSheet: View {
    let seed: RolledCharacter
    let onUse: (RolledCharacter) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var outfit: OutfitPreset
    @State private var theme: ChatThemePreset

    init(seed: RolledCharacter, onUse: @escaping (RolledCharacter) -> Void) {
        self.seed = seed
        self.onUse = onUse
        _name = State(initialValue: seed.name)
        _outfit = State(initialValue: seed.outfitPreset)
        _theme = State(initialValue: seed.chatThemePreset)
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
    }
}

extension Notification.Name {
    /// Posted whenever the user commits a character choice from the
    /// onboarding picker or Settings. UserInfo carries:
    ///   - `companionName: String`
    ///   - `outfitPresetId: String`  (rawValue of OutfitPreset)
    ///   - `chatThemePresetId: String` (rawValue of ChatThemePreset)
    /// AppDelegate observes and routes to every overlay's Pet +
    /// the shared ChatTheme; the `companionName` write is mirrored
    /// into `BackendSettings` by the picker itself.
    static let companionAppliedCharacter = Notification.Name("companion.character.applied")
}

/// User-info keys for `.companionAppliedCharacter`.
enum CompanionAppliedCharacterKey {
    static let name   = "companionName"
    static let outfit = "outfitPresetId"
    static let theme  = "chatThemePresetId"
}
