import SwiftUI

/// Settings panel for sound effects. Lives in the Voice & Look tab
/// alongside the voice language picker. Two controls today: master
/// enable + master volume. Per-category gain and soundboard packs
/// are reserved for the next pass.
@MainActor
struct SoundEffectsPanel: View {
    @State private var enabled = Prefs.soundEffectsEnabled
    @State private var volume: Float = Prefs.soundEffectsVolume
    @State private var allowFetch = Prefs.allowAgentAudioFetch

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Footsteps when Max walks, a chime when his expression shifts, a glitch when channels swap, a small fanfare when he absorbs a soul patch. Independent of the TTS voice — turn this on to hear effects without speech, or use ⌥⌘V (Silence Max) to mute both at once.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Toggle("Sound effects", isOn: $enabled)
                    .onChange(of: enabled) { _, new in
                        Prefs.soundEffectsEnabled = new
                    }
                Spacer()
            }

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Allow agent audio fetch", isOn: $allowFetch)
                    .onChange(of: allowFetch) { _, new in
                        Prefs.allowAgentAudioFetch = new
                    }
                Text("Lets Max reach beyond the built-in catalog — fetch any audio URL or search myinstants.com (\"vine boom\", \"airhorn\", \"sad trombone\", etc.). 2 MB cap per clip, 5 s timeout, audio-only Content-Type, in-memory only (nothing on disk). Off by default; turn on if you want Max's meme vocabulary.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(enabled ? 1 : 0.4)
            .disabled(!enabled)

            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                Slider(value: $volume, in: 0.0...1.0)
                    .frame(maxWidth: 240)
                    .onChange(of: volume) { _, new in
                        Prefs.soundEffectsVolume = new
                    }
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                Text("\(Int(volume * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            .opacity(enabled ? 1 : 0.4)
            .disabled(!enabled)

            HStack(spacing: 8) {
                Button("Test") {
                    SoundEngine.shared.play("chord_resolve")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!enabled)
            }
        }
    }
}
