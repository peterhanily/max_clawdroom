import AVFoundation
import Foundation

/// AVAudioEngine DSP chain that transforms any AVSpeechSynthesizer
/// output into a Max-Headroom-adjacent voice: pitched-up formant,
/// digital distortion preset Apple ships for exactly this look, short
/// delay, and a 2.5kHz presence boost. All first-party audio units —
/// no custom DSP, no licensed third-party effects.
///
/// The signal chain:
///   player → pitch → distortion → delay → EQ → mainMixer → output
///
/// Fed by PCM buffers from `AVSpeechSynthesizer.write(_:toBufferCallback:toMarkerCallback:)`
/// so we can keep the per-word markers for visual lipsync while still
/// running the audio through effects.
@MainActor
final class MaxVoiceEffects {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let pitch = AVAudioUnitTimePitch()
    let distortion = AVAudioUnitDistortion()
    let delay = AVAudioUnitDelay()
    let eq = AVAudioUnitEQ(numberOfBands: 1)

    private var connected = false
    private var currentFormat: AVAudioFormat?

    /// When false, every effect unit in the chain is parameter-zeroed so
    /// the signal passes through unchanged. Controlled by the `Max
    /// Filter` toggle in the Voice submenu. Default tracks the current
    /// pref at init.
    private(set) var maxFilterEnabled: Bool

    init() {
        self.maxFilterEnabled = Prefs.voiceMaxFilter

        distortion.loadFactoryPreset(.speechCosmicInterference)
        let band = eq.bands[0]
        band.filterType = .parametric
        band.frequency = 2500
        band.bandwidth = 0.8
        band.bypass = false

        delay.delayTime = 0.028
        delay.feedback = 22
        pitch.rate = 1.0

        applyMaxFilter(maxFilterEnabled)

        engine.attach(player)
        engine.attach(pitch)
        engine.attach(distortion)
        engine.attach(delay)
        engine.attach(eq)
    }

    /// Set whether the Max-ification chain is active. When disabled,
    /// every unit is parameter-zeroed so the signal passes through
    /// unchanged — critical for Kokoro's already-crisp output, which
    /// gets destroyed by the distortion + pitch shift.
    func setMaxFilter(_ on: Bool) {
        guard maxFilterEnabled != on else { return }
        maxFilterEnabled = on
        applyMaxFilter(on)
    }

    private func applyMaxFilter(_ on: Bool) {
        if on {
            // Pitch shift ~+220 cents (~two semitones up). Pushes formants
            // into Max's nasal register without the "chipmunk" tell that
            // comes with pitch > +400.
            pitch.pitch = 220
            // Apple ships this preset specifically for synthetic/robotic
            // speech. Exactly the digital-degraded timbre we want.
            distortion.wetDryMix = 35
            // Short delay with modest feedback — gives the subtle "double-
            // speak" that 80s broadcast synths had.
            delay.wetDryMix = 18
            // 2.5 kHz narrow presence lift — the "broadcast" frequency
            // that makes speech read as through-a-CRT-speaker.
            eq.bands[0].gain = 6
        } else {
            pitch.pitch = 0
            distortion.wetDryMix = 0
            delay.wetDryMix = 0
            eq.bands[0].gain = 0
        }
    }

    /// Schedule a PCM buffer from the speech synthesizer onto the chain.
    /// First call connects the graph using the buffer's format (which
    /// varies by voice quality — Premium is 48kHz float32, Default is
    /// often 22.05kHz int16).
    func schedule(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        connectIfNeeded(format: buffer.format)
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying {
            player.play()
        }
    }

    /// Flush any scheduled audio and silence the chain.
    func stop() {
        if player.isPlaying {
            player.stop()
        }
    }

    private func connectIfNeeded(format: AVAudioFormat) {
        if connected, currentFormat == format { return }

        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(pitch)
        engine.disconnectNodeOutput(distortion)
        engine.disconnectNodeOutput(delay)
        engine.disconnectNodeOutput(eq)

        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: distortion, format: format)
        engine.connect(distortion, to: delay, format: format)
        engine.connect(delay, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)

        currentFormat = format
        connected = true

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                AppLog.voice.error("engine failed to start: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
