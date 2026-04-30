import AVFoundation
import Combine
import Foundation

/// Max's voice. Wraps `AVSpeechSynthesizer` with a sentence chunker so
/// streamed chat text is spoken at sentence boundaries rather than
/// per-token.
///
/// Critical: `AVSpeechSynthesizer` MUST be held as a strong instance
/// property. If it deallocs mid-utterance, delegate callbacks silently
/// never fire — a well-known footgun.
@MainActor
final class VoiceEngine: NSObject {
    @Published var enabled: Bool
    @Published var voiceID: String?

    /// Normalized hesitation in [0, 1] from the token-latency telemetry.
    /// Scales speech rate down: 0 = default rate, 1 = minimum rate.
    var hesitation: Double = 0

    var onSpeechWord: (() -> Void)?
    var onSpeechEnd: (() -> Void)?

    private let synth = AVSpeechSynthesizer()
    private let chunker = SentenceChunker()
    private let effects = MaxVoiceEffects()

    private var pausedSentences: [String] = []
    private let pausedSentencesCap = 60

    /// How many utterances we've handed to `synth` that haven't yet
    /// reported `didFinish` / `didCancel`. AVSpeechSynthesizer queues
    /// internally without a public cap; on long replies the queue used
    /// to grow without bound, so TTS lagged 30+ seconds behind the
    /// on-screen text. We cap the outstanding count and drop the oldest
    /// pending sentence if we'd exceed it — the user sees the trailing
    /// sentences in the bubble anyway; they just don't get voiced.
    private var outstandingUtterances = 0
    private let outstandingUtteranceCap = 8
    private var deferredUtterances: [AVSpeechUtterance] = []

    init(enabled: Bool, voiceID: String? = nil) {
        self.enabled = enabled
        self.voiceID = voiceID
        super.init()
        synth.delegate = self
    }

    func speakNow(_ text: String) {
        guard enabled, !Prefs.captionOnly else { return }
        enqueue(text)
    }

    func streamUpdate(fullText: String) {
        guard !Prefs.captionOnly else { return }
        let newSentences = chunker.extractNew(fullText: fullText)
        if enabled {
            for s in newSentences { enqueue(s) }
        } else {
            pausedSentences.append(contentsOf: newSentences)
            if pausedSentences.count > pausedSentencesCap {
                pausedSentences.removeFirst(pausedSentences.count - pausedSentencesCap)
            }
        }
    }

    func setEnabled(_ newValue: Bool) {
        let wasEnabled = enabled
        enabled = newValue
        if !wasEnabled, newValue {
            let pending = pausedSentences
            pausedSentences.removeAll()
            for s in pending { enqueue(s) }
        } else if wasEnabled, !newValue {
            synth.stopSpeaking(at: .immediate)
            effects.stop()
        }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        effects.stop()
        pausedSentences.removeAll()
        deferredUtterances.removeAll()
        outstandingUtterances = 0
    }

    func applyMaxFilterPref() {
        effects.setMaxFilter(Prefs.voiceMaxFilter)
    }

    func resetStream() {
        chunker.reset()
        pausedSentences.removeAll()
    }

    // MARK: - Private

    private func enqueue(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let utt = AVSpeechUtterance(string: trimmed)
        if let id = voiceID, let v = AVSpeechSynthesisVoice(identifier: id) {
            utt.voice = v
        } else if let override = Prefs.voiceLanguageOverride,
                  let v = AVSpeechSynthesisVoice(language: override) {
            utt.voice = v
        } else if let locale = Locale.preferredLanguages.first {
            utt.voice = AVSpeechSynthesisVoice(language: locale)
        }

        // Confidence-gated rate: high hesitation → slower speech.
        // Base rate comes from Prefs so the user / agent can tune it.
        let h = max(0, min(1, hesitation))
        let minRate = AVSpeechUtteranceMinimumSpeechRate
        let baseRate = Prefs.speechRate
        utt.rate = baseRate - Float(h) * (baseRate - minRate) * 0.6
        utt.pitchMultiplier = 1.0
        utt.volume = 1.0

        if Prefs.voiceMaxFilter {
            // Max-filter path: we route through `write(_:toBufferCallback:)`
            // into our own audio effects chain. Bounded by the same
            // outstanding-cap as the speak() path so filtered voice can't
            // run away either.
            if outstandingUtterances >= outstandingUtteranceCap {
                deferredUtterances.append(utt)
                trimDeferred()
                return
            }
            outstandingUtterances += 1
            synth.write(utt, toBufferCallback: { [weak self] buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                Task { @MainActor [weak self] in
                    self?.effects.schedule(pcm)
                }
            }, toMarkerCallback: { [weak self] markers in
                let wordCount = markers.filter {
                    $0.mark == AVSpeechSynthesisMarker.Mark.word
                }.count
                guard wordCount > 0 else { return }
                Task { @MainActor [weak self] in
                    for _ in 0..<wordCount { self?.onSpeechWord?() }
                }
            })
        } else {
            if outstandingUtterances >= outstandingUtteranceCap {
                deferredUtterances.append(utt)
                trimDeferred()
                return
            }
            outstandingUtterances += 1
            synth.speak(utt)
        }
    }

    /// Drain the deferred queue when an utterance finishes. Called from
    /// the delegate's didFinish / didCancel.
    fileprivate func utteranceCompleted() {
        if outstandingUtterances > 0 { outstandingUtterances -= 1 }
        guard outstandingUtterances < outstandingUtteranceCap,
              !deferredUtterances.isEmpty else { return }
        let next = deferredUtterances.removeFirst()
        outstandingUtterances += 1
        if Prefs.voiceMaxFilter {
            synth.write(next, toBufferCallback: { [weak self] buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                Task { @MainActor [weak self] in
                    self?.effects.schedule(pcm)
                }
            }, toMarkerCallback: { [weak self] markers in
                let wordCount = markers.filter {
                    $0.mark == AVSpeechSynthesisMarker.Mark.word
                }.count
                guard wordCount > 0 else { return }
                Task { @MainActor [weak self] in
                    for _ in 0..<wordCount { self?.onSpeechWord?() }
                }
            })
        } else {
            synth.speak(next)
        }
    }

    /// Keep the deferred queue from growing forever in pathological
    /// cases (e.g. user mutes but doesn't stop). Drop the oldest past
    /// a generous threshold — the user sees the text in the chat bubble
    /// regardless; only the voiced echo is lost.
    private func trimDeferred() {
        let cap = 40
        if deferredUtterances.count > cap {
            deferredUtterances.removeFirst(deferredUtterances.count - cap)
        }
    }
}

extension VoiceEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.onSpeechWord?() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        // Set the global speech-active flag so SoundReactor can duck
        // sound effects while voice is speaking.
        Task { @MainActor in
            AnySpeechSynthesizerActive.isSpeaking = true
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            AnySpeechSynthesizerActive.isSpeaking = false
            self?.onSpeechEnd?()
            self?.utteranceCompleted()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            AnySpeechSynthesizerActive.isSpeaking = false
            self?.onSpeechEnd?()
            self?.utteranceCompleted()
        }
    }
}
