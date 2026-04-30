import AppKit
import AVFoundation
import Foundation

/// Translates app events into sound names and pushes them to
/// `SoundEngine`. Two input streams:
///
/// 1. **Action ops** — observed via the global agent action notification.
///    `walk` → footstep, `set_expression "amused"` → chime_soft, etc.
///    Auto-bindings; the agent doesn't need to think about audio for
///    standard moves to feel right.
/// 2. **Notification feed** — channel swaps, auth failures, mode
///    transitions, soul absorptions. Things outside the action-tag
///    vocabulary that still want a cue.
///
/// Constructed by the primary `OverlayController` (same screen-gating
/// pattern as `ChannelStageDirector`) so secondary monitors don't
/// double-fire on multi-display setups.
@MainActor
final class SoundReactor {
    private let engine = SoundEngine.shared

    private var actionObserver: NSObjectProtocol?
    private var channelObserver: NSObjectProtocol?
    private var authObserver: NSObjectProtocol?
    private var modeObserver: NSObjectProtocol?
    private var soulObserver: NSObjectProtocol?
    /// AVSpeechSynthesizerDelegate-style hooks live in VoiceEngine —
    /// here we just listen for a coarse "voice changed" notification
    /// to set ducking. Finer-grained sample-accurate ducking would
    /// need a delegate, but this is enough for the ear.
    private var voiceTickTask: Task<Void, Never>?

    init() {
        actionObserver = NotificationCenter.default.addObserver(
            forName: .companionAgentAction,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Extract the payload BEFORE the Task to avoid capturing
            // the non-Sendable Notification across the actor hop.
            let op = note.userInfo?["op"] as? String
            let args = note.userInfo?["args"] as? [String: String]
            Task { @MainActor in
                self?.handleAction(op: op, args: args)
            }
        }

        channelObserver = NotificationCenter.default.addObserver(
            forName: .companionActiveChannelChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.engine.play("glitch_swoop") }
        }

        authObserver = NotificationCenter.default.addObserver(
            forName: .companionChannelAuthFailed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.engine.play("error_bonk") }
        }

        modeObserver = NotificationCenter.default.addObserver(
            forName: .companionModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let mode = note.userInfo?["mode"] as? String
            Task { @MainActor in
                self?.handleMode(mode)
            }
        }

        soulObserver = NotificationCenter.default.addObserver(
            forName: .companionSoulChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.engine.play("fanfare_tiny") }
        }

        // TTS ducking — poll AVSpeechSynthesizer's state via the system
        // since we don't get sample-accurate callbacks. 100ms cadence
        // is fine; voice transitions happen on hundreds-of-ms boundaries.
        voiceTickTask = Task { @MainActor [weak self] in
            var lastSpeaking = false
            while !Task.isCancelled {
                let speaking = AnySpeechSynthesizerActive.isSpeaking
                if speaking != lastSpeaking {
                    self?.engine.setTTSDucking(speaking)
                    lastSpeaking = speaking
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    isolated deinit {
        voiceTickTask?.cancel()
        for obs in [actionObserver, channelObserver, authObserver, modeObserver, soulObserver] {
            if let obs { NotificationCenter.default.removeObserver(obs) }
        }
    }

    // MARK: - Action → sound mapping

    private func handleAction(op: String?, args: [String: String]?) {
        guard let op else { return }
        switch op {
        case "walk":           engine.play("footstep")
        case "jitter":         engine.play("jitter")
        case "wave":           engine.play("wave_woosh")
        case "nod":            engine.play("nod_tick")
        case "look_around":    engine.play("look_around")
        case "set_expression":
            switch args?["name"] {
            case "amused", "smug":           engine.play("chime_soft")
            case "sad", "concerned":         engine.play("chord_low")
            case "devious", "excited":       engine.play("synth_riser")
            case "confused":                 engine.play("bonk_uplift")
            case "focused", "neutral":       break // intentionally silent
            default:                         engine.play("chime_soft")
            }
        case "hold_prop":
            engine.play(args?["item"] == "wizard_hat" ? "magic_shimmer" : "pop_pickup")
        case "drop_prop":      engine.play("thunk_low")
        case "set_part_color": engine.play("pip_chord")
        case "set_chat_color": engine.play("pip_low")
        case "set_chat_font":  engine.play("paper_flip")
        case "play_sound":
            // Direct agent op — see `dispatchPlaySound`. Reactor doesn't
            // double-fire here; the dispatcher in MaxClawdroomActions
            // already played the sound. Listed here so we don't
            // accidentally bind `play_sound` to a default sound.
            break
        default:
            break
        }
    }

    private func handleMode(_ mode: String?) {
        switch mode {
        case "tv":      engine.play("tv_static_in")
        case "desktop": engine.play("whoosh_settle")
        default:        break
        }
    }
}

extension Notification.Name {
    /// Posted by `ActionDispatcher` after every action it dispatches
    /// so layers like `SoundReactor` can react without monkey-patching
    /// the dispatcher. `userInfo["op"]: String`,
    /// `userInfo["args"]: [String: String]?`.
    static let companionAgentAction =
        Notification.Name("companion.agent.action")
}

// MARK: - Voice-active probe

/// Cheap "is something speaking right now" probe. We can't subscribe
/// to AVSpeechSynthesizer.isSpeaking from outside its delegate, so
/// VoiceEngine (which IS the delegate) sets `isSpeaking` here on
/// didStart / didFinish. SoundReactor polls it for ducking.
@MainActor
enum AnySpeechSynthesizerActive {
    static var isSpeaking: Bool = false
}
