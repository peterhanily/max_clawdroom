import AVFoundation
import Foundation

/// Ambient audio bed — a low-volume pink-noise hiss looping under Max
/// while he's active. Opt-in via `Prefs.ambientAudioEnabled`, volume via
/// `Prefs.ambientVolume`. Synthesised procedurally (Voss-McCartney pink
/// noise) so there's no asset to ship and no royalties to track.
///
/// Design:
/// - One `AVAudioEngine` held as a property for its lifetime.
/// - A single 2-second stereo `AVAudioPCMBuffer` of pink noise,
///   scheduled on repeat so the loop is seamless.
/// - Volume is a smooth ramp on the player's main-mixer input — a
///   0.0 → 0.3 flip doesn't pop.
/// - Skipped entirely if the OS denies audio init; the app stays
///   fully functional without sound.
@MainActor
final class AmbientAudioBed {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var started = false
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .companionAmbientAudioChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyPrefs() }
        }
        applyPrefs()
    }

    isolated deinit {
        if let obs = observer {
            NotificationCenter.default.removeObserver(obs)
        }
        engine.stop()
    }

    // MARK: - Lifecycle

    /// Re-read the prefs and start / stop the bed + adjust volume.
    /// Idempotent.
    func applyPrefs() {
        if Prefs.ambientAudioEnabled {
            start()
            setVolumeSmoothly(Prefs.ambientVolume)
        } else {
            stop()
        }
    }

    private func start() {
        guard !started else { return }
        do {
            try configureGraph()
            try engine.start()
            if let buffer {
                player.scheduleBuffer(buffer, at: nil, options: [.loops])
                player.volume = 0 // ramp up in applyPrefs
                player.play()
            }
            started = true
        } catch {
            AppLog.voice.error("ambient audio init failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stop() {
        guard started else { return }
        setVolumeSmoothly(0)
        // Let the ramp finish before actually stopping — 0.4s is enough.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.player.stop()
            self?.engine.stop()
            self?.started = false
        }
    }

    private func setVolumeSmoothly(_ target: Float) {
        // AVAudioMixerNode has no native ramp; we step via a short timer.
        // 10 ticks / 300ms is imperceptible but non-popping.
        let from = player.volume
        let to = max(0, min(1, target))
        let steps: Int = 10
        let interval: TimeInterval = 0.03
        for i in 1...steps {
            let alpha = Float(i) / Float(steps)
            let v = from + (to - from) * alpha
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * interval) { [weak self] in
                self?.player.volume = v
            }
        }
    }

    // MARK: - Graph

    private func configureGraph() throws {
        guard buffer == nil else { return }

        // 44.1 kHz stereo; plenty for noise-bed purposes. Use the
        // default output format so we don't fight format conversions.
        let format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 2
        )!
        buffer = Self.makePinkNoiseBuffer(format: format, seconds: 2)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    // MARK: - Pink-noise synthesis

    /// Voss-McCartney pink-noise algorithm. Sums N independent random
    /// generators updated at different rates — produces a 1/f spectrum
    /// that sounds like tape hiss (warmer than pure white noise).
    ///
    /// Each channel gets its own independent stream so the bed has a
    /// subtle stereo field instead of sounding mono-glued-to-centre.
    private static func makePinkNoiseBuffer(
        format: AVAudioFormat,
        seconds: Double
    ) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(format.sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        let channels = Int(format.channelCount)
        // A little headroom under 0dBFS so clipping can't happen when
        // mixed with TTS. -18 dB roughly = 0.126 linear.
        let peakGain: Float = 0.126
        for channel in 0..<channels {
            guard let dst = buffer.floatChannelData?[channel] else { continue }
            var generator = PinkNoise(octaves: 7, seed: UInt64(channel + 1) * 0x9E3779B97F4A7C15)
            for i in 0..<Int(frameCount) {
                dst[i] = generator.next() * peakGain
            }
        }
        return buffer
    }
}

// MARK: - Pink noise generator

/// Voss-McCartney: N parallel counters, each updates a new random value
/// at rate 1/2^i. Summing them gives 1/f noise. Output is normalised
/// roughly to ±1.0.
private struct PinkNoise {
    private var rng: SplitMix64
    private var counters: [Float]
    private var stepIndex: UInt64 = 0
    private let octaves: Int

    init(octaves: Int, seed: UInt64) {
        self.octaves = octaves
        self.rng = SplitMix64(state: seed == 0 ? 0xA53CBE2 : seed)
        self.counters = (0..<octaves).map { _ in 0 }
        for i in 0..<octaves {
            counters[i] = Self.nextFloat(rng: &rng)
        }
    }

    mutating func next() -> Float {
        stepIndex &+= 1
        // For each octave, if the index has a bit set at that position,
        // resample the counter. Classic Voss trick.
        var bit: UInt64 = 1
        for i in 0..<octaves {
            if stepIndex & bit != 0 {
                counters[i] = Self.nextFloat(rng: &rng)
            }
            bit <<= 1
        }
        let sum = counters.reduce(0, +)
        // Normalise: N counters each in [-1, 1] summed → range roughly
        // [-N, N]; divide by sqrt(N) for RMS-stable output.
        return sum / sqrtf(Float(octaves))
    }

    private static func nextFloat(rng: inout SplitMix64) -> Float {
        // Map UInt64 → [-1, 1].
        let x = Float(rng.next() >> 32) / Float(UInt32.max)
        return x * 2 - 1
    }
}

/// Tiny deterministic PRNG (SplitMix64). Used instead of `Int.random`
/// so ambient noise is reproducible in unit tests — the generated buffer
/// has the same energy profile across runs.
private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
