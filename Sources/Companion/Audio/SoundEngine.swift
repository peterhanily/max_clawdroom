import AVFoundation
import Foundation

/// Single shared `AVAudioEngine` plus a small pool of `AVAudioPlayerNode`s.
/// All sound effects in the app go through here — both the system
/// reactor (footsteps on walk, glitch on channel swap) and Max's own
/// `play_sound` action op.
///
/// Mixing model:
///   master gain (Prefs.soundEffectsVolume)
///     ├── sting bus
///     ├── body bus
///     ├── ui bus
///     ├── mode bus
///     └── channel bus
///
/// Buffers are decoded once on demand into `AVAudioPCMBuffer`s and
/// reused across plays — no decode-per-fire latency. Procedural
/// recipes from `ProceduralSounds` and bundled samples from
/// `Bundle.companionResources` both land in the same buffer cache.
@MainActor
final class SoundEngine {
    static let shared = SoundEngine()

    /// Effective gate. Just the master sound-effects toggle —
    /// independent from voice mute. Earlier the cascade silenced
    /// effects whenever voice was off, but users with voice off
    /// (working in shared spaces, late at night) still want to hear
    /// the punctuation effects. The "Silence Max" menu item flips
    /// BOTH flags together so the unified-mute UX still holds.
    var isActive: Bool {
        Prefs.soundEffectsEnabled
    }

    private let engine = AVAudioEngine()
    /// Shared player nodes — pool size of 6 covers typical concurrency
    /// (two footsteps + a chime + a glitch swoop is the busiest realistic
    /// scenario). Out-of-pool plays are dropped silently.
    private let nodes: [AVAudioPlayerNode]
    /// Pre-decoded buffers keyed by sound name. Filled lazily.
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    /// Per-category mixer gains. Master gain is applied to the engine's
    /// main mixer; per-category gains scale individual schedules.
    private var categoryGain: [SoundCategory: Float] = {
        var d: [SoundCategory: Float] = [:]
        for cat in SoundCategory.allCases { d[cat] = 1.0 }
        return d
    }()
    /// Last-fire timestamp per name — used to debounce repeats. The
    /// reactor wires walk/jitter to short repeats so the natural
    /// debounce isn't very tight; 60ms is enough to avoid clipping.
    private var lastFireAt: [String: Date] = [:]
    private static let debounceSeconds: TimeInterval = 0.04
    /// Per-node current connection format. Updated whenever we
    /// reconnect a node to match a buffer's format on play.
    private var nodeFormats: [ObjectIdentifier: AVAudioFormat] = [:]
    /// Round-robin index into the player-node pool. AVAudioPlayerNode's
    /// `isPlaying` stays true after the first `play()` call and never
    /// auto-resets when the scheduled buffer finishes (only `.stop()`
    /// or `.reset()` clears it). Filtering on `isPlaying` therefore
    /// reads the entire pool as busy after 6 plays and silently drops
    /// every subsequent fire — that was the "myinstants worked once
    /// or twice then nothing" symptom. Round-robin gives every fire
    /// a node; `.interrupts` on scheduleBuffer cancels any in-flight
    /// content on that slot.
    private var nextNodeIdx: Int = 0
    /// Format used when connecting player nodes to the main mixer.
    /// Pinned to the procedural buffer format (44.1 kHz mono Float32)
    /// so the connection is well-defined regardless of the system
    /// output device. Bundled samples that don't match the expected
    /// format will get auto-converted by AVAudioPlayerNode at schedule
    /// time.
    private let playerFormat: AVAudioFormat

    private init() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: ProceduralSounds.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            // Should never happen — these parameters are valid on every
            // macOS version. Fall back to mainMixer's format if it does.
            fatalError("Could not construct SoundEngine player format")
        }
        self.playerFormat = format

        let pool = (0..<6).map { _ in AVAudioPlayerNode() }
        self.nodes = pool
        for node in pool {
            engine.attach(node)
            // Specify format explicitly. format=nil left the connection
            // partly resolved; on macOS 26.x with mismatched sample
            // rates between the source buffer and the system output
            // device, that produced silent playback. With an explicit
            // format AVAudioEngine inserts a sample-rate converter on
            // the route automatically.
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        engine.mainMixerNode.outputVolume = Prefs.soundEffectsVolume
        do {
            try engine.start()
            AppLog.audio.notice("SoundEngine started: \(self.engine.isRunning ? "running" : "not running")")
        } catch {
            AppLog.audio.error("AVAudioEngine failed to start: \(error.localizedDescription, privacy: .public)")
        }
        // React to volume + mute changes so the engine reflects the
        // user's intent immediately.
        NotificationCenter.default.addObserver(
            forName: .companionVoiceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyMasterGain() }
        }
        NotificationCenter.default.addObserver(
            forName: .companionSoundEffectsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyMasterGain() }
        }
    }

    /// Play one named sound. Drops silently if the engine is muted, the
    /// pool is full, or the name isn't in the catalog. Optional
    /// `volume` (0…1) scales just this fire.
    func play(_ name: String, volume: Float = 1.0) {
        guard isActive else {
            AppLog.audio.notice("play(\(name, privacy: .public)) skipped — sound effects disabled")
            return
        }
        // Engine can drop to stopped if the audio route changes (head-
        // phones plugged/unplugged, output device switch). Restart on
        // demand so the next play tone actually reaches the speaker.
        if !engine.isRunning {
            do {
                try engine.start()
                AppLog.audio.notice("SoundEngine restarted on play")
            } catch {
                AppLog.audio.error("SoundEngine restart failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        let now = Date()
        if let last = lastFireAt[name], now.timeIntervalSince(last) < Self.debounceSeconds {
            return
        }
        guard let buffer = buffer(for: name) else {
            AppLog.audio.error("play(\(name, privacy: .public)) — buffer build failed")
            return
        }
        guard let node = idleNode() else {
            AppLog.audio.notice("play(\(name, privacy: .public)) — pool busy, drop")
            return
        }
        // Per-category gain × per-fire volume. Master is on the main
        // mixer so we don't multiply it here.
        let cat = SoundLibrary.category(for: name) ?? .ui
        let gain = (categoryGain[cat] ?? 1.0) * max(0, min(1, volume))
        node.volume = gain
        // scheduleBuffer throws NSException when the buffer's format
        // doesn't match the node→mixer connection format. With
        // round-robin selection, a node previously reconnected to
        // (say) stereo may receive a mono buffer next round and vice
        // versa. Track each node's current connection format and
        // reconnect on mismatch. Stop + reset first so the reconnect
        // doesn't fight an in-flight buffer (the round-robin already
        // accepts that the previous play is interrupted).
        let nodeKey = ObjectIdentifier(node)
        let currentFormat = nodeFormats[nodeKey] ?? playerFormat
        if buffer.format != currentFormat {
            node.stop()
            node.reset()
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
            nodeFormats[nodeKey] = buffer.format
        }
        node.scheduleBuffer(buffer, at: nil, options: [.interrupts]) { /* no-op */ }
        node.play()
        lastFireAt[name] = now
        AppLog.audio.notice("play(\(name, privacy: .public)) — gain=\(gain), master=\(self.engine.mainMixerNode.outputVolume), running=\(self.engine.isRunning), fmt=\(buffer.format.sampleRate)Hz/\(buffer.format.channelCount)ch")
    }

    /// Play an audio buffer fetched from `url`. Caches the decoded
    /// buffer keyed by either `cacheKey` (when supplied) or the URL
    /// string itself, so a repeat play with the same key skips the
    /// network entirely.
    ///
    /// Uses RemoteAudioFetcher's completion-handler API rather than
    /// async/await — Task{@MainActor in await ...} deadlocks under
    /// the macOS 26.x executor-hook workaround. Plain URLSession
    /// completion → DispatchQueue.main.async → mutate state pattern.
    func playFromURL(_ url: URL, cacheKey: String? = nil, volume: Float = 1.0) {
        guard isActive else {
            AppLog.audio.notice("playFromURL skipped — sound effects disabled")
            return
        }
        guard Prefs.allowAgentAudioFetch else {
            AppLog.audio.notice("playFromURL skipped — agent audio fetch not allowed")
            return
        }
        let key = cacheKey ?? url.absoluteString
        if buffers[key] != nil {
            play(key, volume: volume)
            return
        }
        RemoteAudioFetcher.fetch(url: url) { result in
            switch result {
            case .success(let box):
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.buffers[key] = box.buffer
                    self.play(key, volume: volume)
                    AppLog.audio.notice("playFromURL cached and played: \(key, privacy: .public)")
                }
            case .failure(let error):
                AppLog.audio.error("playFromURL(\(url.absoluteString, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Resolve a free-text myinstants query into a URL and play.
    /// Same caching + concurrency model as `playFromURL`.
    func playFromMyInstants(query: String, cacheKey: String? = nil, volume: Float = 1.0) {
        guard isActive else {
            AppLog.audio.notice("playFromMyInstants skipped — sound effects disabled")
            return
        }
        guard Prefs.allowAgentAudioFetch else {
            AppLog.audio.notice("playFromMyInstants skipped — agent audio fetch not allowed")
            return
        }
        let key = cacheKey ?? "myinstants:\(query)"
        if buffers[key] != nil {
            play(key, volume: volume)
            return
        }
        MyInstantsLookup.resolveFirstMP3(query: query) { lookupResult in
            switch lookupResult {
            case .failure(let error):
                AppLog.audio.error("playFromMyInstants(\(query, privacy: .public)) lookup failed: \(error.localizedDescription, privacy: .public)")
            case .success(let url):
                RemoteAudioFetcher.fetch(url: url) { fetchResult in
                    switch fetchResult {
                    case .success(let box):
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.buffers[key] = box.buffer
                            self.play(key, volume: volume)
                            AppLog.audio.notice("playFromMyInstants(\(query, privacy: .public)) → \(url.absoluteString, privacy: .public)")
                        }
                    case .failure(let error):
                        AppLog.audio.error("playFromMyInstants(\(query, privacy: .public)) fetch failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    /// Set the master gain (0…1). Persisted via `Prefs.soundEffectsVolume`.
    func setMasterVolume(_ value: Float) {
        Prefs.soundEffectsVolume = max(0, min(1, value))
        applyMasterGain()
    }

    /// Per-category mute / scale. 1.0 = full, 0.0 = silent. Used by
    /// the Settings panel and TTS ducking (see `setTTSDucking`).
    func setCategoryGain(_ category: SoundCategory, _ gain: Float) {
        categoryGain[category] = max(0, min(1, gain))
    }

    /// Drop *all* category gains while voice is speaking so footsteps
    /// don't compete with words. Reactor calls this on
    /// AVSpeechSynthesizer didStart / didFinish.
    func setTTSDucking(_ ducking: Bool) {
        let target: Float = ducking ? 0.30 : 1.0
        for cat in SoundCategory.allCases {
            // Only override when not already user-muted via category
            // toggle. We use the convention "0 = user muted, ≥0.3 ok"
            // to detect — anyone deliberately at <0.3 stays silent.
            if (categoryGain[cat] ?? 1.0) >= 0.30 {
                categoryGain[cat] = target
            }
        }
    }

    // MARK: - Internals

    private func applyMasterGain() {
        engine.mainMixerNode.outputVolume = isActive ? Prefs.soundEffectsVolume : 0
    }

    private func idleNode() -> AVAudioPlayerNode? {
        guard !nodes.isEmpty else { return nil }
        let n = nodes[nextNodeIdx]
        nextNodeIdx = (nextNodeIdx + 1) % nodes.count
        return n
    }

    private func buffer(for name: String) -> AVAudioPCMBuffer? {
        if let cached = buffers[name] { return cached }
        // Bundled sample first; fall back to procedural recipe.
        if let url = Bundle.companionResources.url(
            forResource: name, withExtension: nil, subdirectory: "Sounds"
        ) ?? Bundle.companionResources.url(
            forResource: name, withExtension: "m4a", subdirectory: "Sounds"
        ) ?? Bundle.companionResources.url(
            forResource: name, withExtension: "wav", subdirectory: "Sounds"
        ) {
            if let buf = loadFile(url: url) {
                buffers[name] = buf
                return buf
            }
        }
        if let buf = ProceduralSounds.render(name) {
            buffers[name] = buf
            return buf
        }
        return nil
    }

    private func loadFile(url: URL) -> AVAudioPCMBuffer? {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard let buf = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(file.length)
            ) else { return nil }
            try file.read(into: buf)
            return buf
        } catch {
            AppLog.audio.error("AVAudioFile read failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

extension Notification.Name {
    /// Posted by `Prefs` when the master sound-effects toggle or volume
    /// changes. SoundEngine listens to re-apply gain.
    static let companionSoundEffectsChanged =
        Notification.Name("companion.soundEffects.changed")
}
