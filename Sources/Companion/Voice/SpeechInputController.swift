import AVFoundation
import Combine
import Foundation
import Speech

/// Live speech-to-text for the voice-input path. Wraps an on-device
/// `SFSpeechRecognizer` driven by an `AVAudioEngine` input tap — no
/// audio ever leaves the machine.
///
/// Lifecycle: `startListening()` spins up the engine + recognition task
/// and publishes partial transcripts on `transcript`. `stopListening()`
/// tears the stack down cleanly and returns the final transcript.
/// `cancel()` discards the in-flight session with no result.
///
/// Permissions: both speech and mic are requested on first use via
/// `prepareAuthorization()`. If either is denied the controller stays
/// in an error state; calling `startListening` is a no-op and publishes
/// via `lastError`. Callers show a user-facing nudge based on that.
@MainActor
final class SpeechInputController: ObservableObject {

    // MARK: - Published state

    /// Live transcript — updated on every partial result from the
    /// recognizer. Cleared when a new session starts.
    @Published private(set) var transcript: String = ""
    @Published private(set) var isListening: Bool = false
    @Published private(set) var lastError: String?
    /// `true` once both speech and mic permissions have been granted.
    /// Used by the hotkey to decide whether to show a "grant access"
    /// nudge instead of silently doing nothing.
    @Published private(set) var isAuthorized: Bool = false

    // MARK: - Internal

    /// Pulled live from the system locale on start so the user's
    /// configured voice-input language follows them. Defaults to en-US
    /// when the locale isn't supported by on-device Speech.
    private var recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    init() {
        // Fire-and-forget perm check so the Settings pane / hotkey can
        // read isAuthorized without waiting for a first keypress.
        Task { @MainActor in await prepareAuthorization() }
    }

    isolated deinit {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
    }

    // MARK: - Authorization

    /// Request speech + mic permissions. No-op after first success.
    /// Safe to call repeatedly. Publishes `isAuthorized` on completion.
    func prepareAuthorization() async {
        let speechStatus = await Self.requestSpeechAuthorization()
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        let granted = (speechStatus == .authorized) && micGranted
        self.isAuthorized = granted
        if !granted {
            if speechStatus != .authorized {
                self.lastError = "Speech recognition access denied. System Settings → Privacy & Security → Speech Recognition."
            } else if !micGranted {
                self.lastError = "Microphone access denied. System Settings → Privacy & Security → Microphone."
            }
        } else {
            self.lastError = nil
        }
    }

    // Marked `nonisolated` so Swift doesn't inherit MainActor from the
    // enclosing type's defaultIsolation. `SFSpeechRecognizer.requestAuthorization`
    // delivers its callback on a background thread; if the closure is
    // inferred @MainActor, Swift 6 runtime traps with an isolation check
    // failure at `_swift_task_checkIsolatedSwift`. This helper doesn't
    // touch MainActor state, so nonisolated is safe and correct.
    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    // MARK: - Start / stop

    /// Begin a listening session. Tears down any in-flight session
    /// first so a rapid press → release → press cycle is safe.
    func startListening() {
        guard isAuthorized else {
            Task { @MainActor in await prepareAuthorization() }
            return
        }
        // Feature-detect the modern Speech API on macOS 26+. We have
        // the scaffold wired but the actual implementation lands when
        // the toolchain ships with the SpeechAnalyzer types — trying
        // to write it against an older SDK breaks the build. For now
        // we log that the preference is set and fall through to the
        // battle-tested SFSpeechRecognizer path so nothing regresses.
        //
        // When upgrading Xcode: drop a new file
        // `Voice/Speech/AnalyzerSpeechPath.swift` that wraps the
        // SpeechAnalyzer+SpeechTranscriber pipeline and call it from
        // inside the availability branch below.
        if #available(macOS 26.0, *), Prefs.useSpeechAnalyzer {
            AppLog.voice.notice("SpeechAnalyzer path requested but not yet wired; using SFSpeechRecognizer")
        }

        // Stop any prior session cleanly before starting a new one.
        stopEngineAndTask()

        transcript = ""
        lastError = nil

        // Prefer the user's system language; fall back to en-US if
        // on-device Speech doesn't support it. `isAvailable` is the
        // runtime go/no-go signal.
        let preferred = Locale.current
        let recog = SFSpeechRecognizer(locale: preferred) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recog, recog.isAvailable else {
            lastError = "Speech recognizer unavailable for current locale."
            return
        }
        recog.defaultTaskHint = .dictation
        // Keep raw audio on-device. `requiresOnDeviceRecognition = true`
        // means no network fallback — recordings never leave the Mac.
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            request.requiresOnDeviceRecognition = true
        }
        self.recognitionRequest = request
        self.recognizer = recog

        // Install an audio tap feeding the recognizer. Format matches
        // the hardware format — Speech handles resampling internally.
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            lastError = "Couldn't start microphone: \(error.localizedDescription)"
            AppLog.voice.error("mic start failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        isListening = true
        recognitionTask = recog.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                if let result {
                    self?.transcript = result.bestTranscription.formattedString
                }
                if let error {
                    // `Error Domain=kAFAssistantErrorDomain Code=1110`
                    // fires on clean end-of-audio — not a real error.
                    let nsErr = error as NSError
                    if nsErr.domain != "kAFAssistantErrorDomain" || nsErr.code != 1110 {
                        self?.lastError = error.localizedDescription
                        AppLog.voice.error("recognition error: \(error.localizedDescription, privacy: .public)")
                    }
                    self?.stopEngineAndTask()
                }
            }
        }
    }

    /// Stop the in-flight session and return the final transcript.
    /// Returns nil when the session wasn't active or produced nothing.
    @discardableResult
    func stopListening() -> String? {
        guard isListening else { return nil }
        stopEngineAndTask()
        let final = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return final.isEmpty ? nil : final
    }

    /// Abandon the session — transcript is discarded, no result is
    /// returned to the caller. Used by Escape / click-away.
    func cancel() {
        guard isListening else { return }
        stopEngineAndTask()
        transcript = ""
    }

    // MARK: - Internal cleanup

    private func stopEngineAndTask() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
    }
}
