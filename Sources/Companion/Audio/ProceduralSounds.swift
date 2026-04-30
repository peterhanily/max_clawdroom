import AVFoundation
import Foundation

/// Bank of synthesised effects — zero asset bytes, generated once per
/// app launch into `AVAudioPCMBuffer`s and reused on every fire.
///
/// Each recipe is a tiny synth program: oscillator + amplitude envelope
/// (and occasionally a frequency envelope or noise modulation). Output
/// is mono Float32 at the engine's working sample rate (44.1 kHz). The
/// engine handles routing + gain; recipes only render the raw waveform.
///
/// Why procedural over samples for the small effects: a footstep is
/// 60ms of brown-noise burst with a soft attack — packaging that as
/// an `m4a` is theatre. Procedural keeps the catalog editable in code
/// and ships with zero binary weight; bundled samples are reserved for
/// the music stings where actual instruments are doing actual work.
enum ProceduralSounds {

    static let sampleRate: Double = 44_100

    /// Build a buffer for one of the named recipes. Returns nil only
    /// on AVAudioFormat construction failure (which would be a bug —
    /// the format is constant).
    static func render(_ name: String) -> AVAudioPCMBuffer? {
        guard let recipe = recipes[name] else { return nil }
        return render(recipe)
    }

    /// Catalog. Names here are the canonical SoundLibrary identifiers
    /// the reactor + the agent's `play_sound` op refer to.
    static let recipes: [String: Recipe] = [
        // Body effects
        "footstep":      .noiseTap(durationMs: 60, freqHz: 280, attack: 0.005, decay: 0.05, gain: 0.18),
        "jitter":        .squareSweep(startHz: 880, endHz: 1320, durationMs: 70, gain: 0.10),
        "wave_woosh":    .noiseSweep(startHz: 1600, endHz: 800,  durationMs: 180, gain: 0.10),
        "nod_tick":      .squareTick(freqHz: 1100, durationMs: 30, gain: 0.10),
        "look_around":   .noiseSweep(startHz: 800,  endHz: 1600, durationMs: 240, gain: 0.08),
        "blink":         .squareTick(freqHz: 2200, durationMs: 14, gain: 0.06),

        // Expression mood pips
        "chime_soft":    .arpeggio(notes: [659, 880],  noteMs: 90, gain: 0.10), // E5 → A5
        "chord_low":     .arpeggio(notes: [220, 196],  noteMs: 240, gain: 0.10), // A3 → G3 (sad)
        "chord_resolve": .arpeggio(notes: [392, 523, 659], noteMs: 110, gain: 0.10), // G4-C5-E5
        "synth_riser":   .sineSweep(startHz: 220, endHz: 880, durationMs: 320, gain: 0.10),
        "bonk_uplift":   .arpeggio(notes: [196, 247], noteMs: 90, gain: 0.10),

        // UI / system
        "pop_pickup":    .sineBlip(freqHz: 880, durationMs: 80, gain: 0.10),
        "thunk_low":     .sineBlip(freqHz: 110, durationMs: 140, gain: 0.18),
        "pip_chord":     .arpeggio(notes: [523, 659, 784], noteMs: 50, gain: 0.10),
        "pip_low":       .sineBlip(freqHz: 392, durationMs: 60, gain: 0.10),
        "paper_flip":    .noiseTap(durationMs: 90, freqHz: 1800, attack: 0.002, decay: 0.08, gain: 0.10),

        // Mode transitions
        "tv_static_in":  .noiseSweep(startHz: 4000, endHz: 1200, durationMs: 380, gain: 0.14),
        "whoosh_settle": .noiseSweep(startHz: 1600, endHz: 300,  durationMs: 320, gain: 0.10),

        // Channel cues
        "glitch_swoop":  .arpeggio(notes: [880, 220, 440], noteMs: 70, gain: 0.12),
        "error_bonk":    .arpeggio(notes: [220, 174], noteMs: 130, gain: 0.14),

        // Stings (procedural placeholders — bundled samples will replace
        // the music ones when sourced).
        "fanfare_tiny":  .arpeggio(notes: [523, 659, 784, 1046], noteMs: 100, gain: 0.12),
        "lofi_morning":  .arpeggio(notes: [392, 466, 587, 392], noteMs: 200, gain: 0.10),
        "magic_shimmer": .arpeggio(notes: [1046, 1318, 1568, 2093, 1568, 1318], noteMs: 60, gain: 0.10)
    ]

    // MARK: - Recipe types

    enum Recipe {
        /// Pure sine, single frequency, decaying envelope.
        case sineBlip(freqHz: Double, durationMs: Int, gain: Float)
        /// Sine with linear pitch sweep over the duration.
        case sineSweep(startHz: Double, endHz: Double, durationMs: Int, gain: Float)
        /// Square wave at one freq with sharp envelope — clicky.
        case squareTick(freqHz: Double, durationMs: Int, gain: Float)
        /// Square with linear pitch sweep — alarm/zap-like.
        case squareSweep(startHz: Double, endHz: Double, durationMs: Int, gain: Float)
        /// White-noise burst lowpass-shaped at `freqHz` with separate
        /// attack/decay times. Good for footsteps + paper-flips.
        case noiseTap(durationMs: Int, freqHz: Double, attack: Double, decay: Double, gain: Float)
        /// Noise burst with a tilted spectral centroid sweep — whooshes.
        case noiseSweep(startHz: Double, endHz: Double, durationMs: Int, gain: Float)
        /// Sequence of sine tones, fixed step duration, half-overlapped
        /// envelopes. Good for arpeggios + chord pips.
        case arpeggio(notes: [Double], noteMs: Int, gain: Float)
    }

    // MARK: - Renderer

    private static func render(_ recipe: Recipe) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        let totalFrames: AVAudioFrameCount = {
            switch recipe {
            case .sineBlip(_, let ms, _): return frames(ms)
            case .sineSweep(_, _, let ms, _): return frames(ms)
            case .squareTick(_, let ms, _): return frames(ms)
            case .squareSweep(_, _, let ms, _): return frames(ms)
            case .noiseTap(let ms, _, _, _, _): return frames(ms)
            case .noiseSweep(_, _, let ms, _): return frames(ms)
            case .arpeggio(let notes, let ms, _): return frames(ms * notes.count)
            }
        }()

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: totalFrames
        ) else { return nil }
        buffer.frameLength = totalFrames

        guard let dst = buffer.floatChannelData?[0] else { return nil }
        for i in 0..<Int(totalFrames) { dst[i] = 0 }

        switch recipe {
        case .sineBlip(let f, let ms, let g):
            renderSine(into: dst, frames: frames(ms), startHz: f, endHz: f, gain: g, env: .pluck)
        case .sineSweep(let f0, let f1, let ms, let g):
            renderSine(into: dst, frames: frames(ms), startHz: f0, endHz: f1, gain: g, env: .swell)
        case .squareTick(let f, let ms, let g):
            renderSquare(into: dst, frames: frames(ms), startHz: f, endHz: f, gain: g, env: .clickFast)
        case .squareSweep(let f0, let f1, let ms, let g):
            renderSquare(into: dst, frames: frames(ms), startHz: f0, endHz: f1, gain: g, env: .pluck)
        case .noiseTap(let ms, let cutoff, let attack, let decay, let g):
            renderNoiseTap(into: dst, frames: frames(ms), cutoff: cutoff, attack: attack, decay: decay, gain: g)
        case .noiseSweep(let f0, let f1, let ms, let g):
            renderNoiseSweep(into: dst, frames: frames(ms), startHz: f0, endHz: f1, gain: g)
        case .arpeggio(let notes, let ms, let g):
            let stepFrames = Int(frames(ms))
            for (idx, hz) in notes.enumerated() {
                let offset = idx * stepFrames
                let writable = min(stepFrames, Int(totalFrames) - offset)
                if writable <= 0 { break }
                renderSine(
                    into: dst.advanced(by: offset),
                    frames: AVAudioFrameCount(writable),
                    startHz: hz, endHz: hz, gain: g, env: .pluck
                )
            }
        }

        return buffer
    }

    private static func frames(_ ms: Int) -> AVAudioFrameCount {
        AVAudioFrameCount((Double(ms) / 1000.0) * sampleRate)
    }

    // MARK: - Oscillators

    /// Amplitude envelope shapes. All are normalised 0…1 at peak.
    private enum Envelope {
        case pluck      // fast attack, exponential decay
        case swell      // slow attack, slow decay (rises into the pitch sweep)
        case clickFast  // very fast attack, very fast decay (square tick)
    }

    private static func envValue(_ env: Envelope, t: Double, total: Double) -> Float {
        let p = max(0, min(1, t / total))
        switch env {
        case .pluck:
            // Fast linear attack to 0.02s, then exp decay over remainder.
            let attackFrac = min(0.04, 0.02 / total)
            if p < attackFrac { return Float(p / attackFrac) }
            let decayP = (p - attackFrac) / (1 - attackFrac)
            return Float(exp(-3.0 * decayP))
        case .swell:
            // Triangular: rises to mid then falls to zero.
            return Float(p < 0.5 ? p * 2 : (1 - p) * 2)
        case .clickFast:
            // 2ms attack / 2ms hold / sharp decay.
            let attackFrac = min(0.2, 0.002 / total)
            if p < attackFrac { return Float(p / attackFrac) }
            let decayP = (p - attackFrac) / (1 - attackFrac)
            return Float(exp(-8.0 * decayP))
        }
    }

    private static func renderSine(
        into dst: UnsafeMutablePointer<Float>,
        frames: AVAudioFrameCount,
        startHz: Double, endHz: Double, gain: Float, env: Envelope
    ) {
        let n = Int(frames)
        let total = Double(n) / sampleRate
        var phase: Double = 0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let p = Double(i) / Double(n - 1).orOne
            let f = startHz + (endHz - startHz) * p
            let dphase = 2 * .pi * f / sampleRate
            phase += dphase
            let sample = Float(sin(phase)) * envValue(env, t: t, total: total) * gain
            dst[i] += sample
        }
    }

    private static func renderSquare(
        into dst: UnsafeMutablePointer<Float>,
        frames: AVAudioFrameCount,
        startHz: Double, endHz: Double, gain: Float, env: Envelope
    ) {
        let n = Int(frames)
        let total = Double(n) / sampleRate
        var phase: Double = 0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let p = Double(i) / Double(n - 1).orOne
            let f = startHz + (endHz - startHz) * p
            phase += 2 * .pi * f / sampleRate
            let sq: Float = sin(phase) >= 0 ? 1 : -1
            dst[i] += sq * envValue(env, t: t, total: total) * gain
        }
    }

    private static func renderNoiseTap(
        into dst: UnsafeMutablePointer<Float>,
        frames: AVAudioFrameCount,
        cutoff: Double, attack: Double, decay: Double, gain: Float
    ) {
        let n = Int(frames)
        let total = Double(n) / sampleRate
        // 1-pole IIR low-pass; alpha derived from cutoff.
        let dt = 1.0 / sampleRate
        let rc = 1.0 / (2.0 * .pi * cutoff)
        let alpha = Float(dt / (rc + dt))
        var lp: Float = 0
        var rng: UInt32 = 0xC0FFEE
        for i in 0..<n {
            let t = Double(i) / sampleRate
            // xorshift32
            rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
            let white = Float(Int32(bitPattern: rng)) / Float(Int32.max)
            lp += alpha * (white - lp)
            let envGain: Float
            if t < attack {
                envGain = Float(t / attack)
            } else if t < attack + decay {
                let p = (t - attack) / decay
                envGain = Float(exp(-3.0 * p))
            } else {
                envGain = 0
            }
            // Lightly fade the tail in case attack+decay > total.
            let tailFade = Float(max(0, 1 - max(0, t - (attack + decay)) / max(0.001, total - attack - decay)))
            dst[i] += lp * envGain * tailFade * gain
        }
    }

    private static func renderNoiseSweep(
        into dst: UnsafeMutablePointer<Float>,
        frames: AVAudioFrameCount,
        startHz: Double, endHz: Double, gain: Float
    ) {
        let n = Int(frames)
        var lp: Float = 0
        let dt = 1.0 / sampleRate
        var rng: UInt32 = 0xBADA55
        for i in 0..<n {
            let p = Double(i) / Double(n - 1).orOne
            let cutoff = startHz + (endHz - startHz) * p
            let rc = 1.0 / (2.0 * .pi * cutoff)
            let alpha = Float(dt / (rc + dt))
            rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
            let white = Float(Int32(bitPattern: rng)) / Float(Int32.max)
            lp += alpha * (white - lp)
            // Triangular envelope across the sweep.
            let env = Float(p < 0.5 ? p * 2 : (1 - p) * 2)
            dst[i] += lp * env * gain
        }
    }
}

private extension Double {
    /// Avoids div-by-zero when frames == 1.
    var orOne: Double { self <= 0 ? 1 : self }
}
