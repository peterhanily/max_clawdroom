import Combine
import Foundation
import Observation

/// Glues channel changes + channel health to Max's body. Owns two
/// behaviours:
///
/// 1. **Persona apply on swap** — when the active channel changes,
///    fires the channel's `ChannelPersona` through the existing
///    action vocabulary (`set_part_color`, `set_chat_color`,
///    `set_expression`, optional gesture) so switching channels
///    visibly transforms Max. Voice id + filter pref are written
///    directly.
///
/// 2. **Health → expression** — observes `ChannelHealth.state` and
///    fires `set_expression` deltas so connection state is felt as a
///    mood shift rather than a status dot. Debounced — health flaps
///    don't whip Max back and forth.
///
/// The director is constructed once by the primary overlay and given
/// a closure that dispatches a `MaxClawdroomAction` (the same closure
/// `ChatSession.actionHandler` uses). That keeps secondary overlays
/// from clobbering wiring on multi-monitor setups.
@MainActor
final class ChannelStageDirector {
    typealias Dispatch = @MainActor (MaxClawdroomAction) -> Void

    private let dispatch: Dispatch
    private var channelObserver: NSObjectProtocol?
    private var healthCancellable: AnyCancellable?
    private var lastExpression: String?
    private var lastDispatchAt: Date = .distantPast

    init(dispatch: @escaping Dispatch) {
        self.dispatch = dispatch
        // Apply current channel's persona once on construction so a
        // launch into a non-default channel comes up looking right.
        applyPersona(ChannelStore.shared.active)
        channelObserver = NotificationCenter.default.addObserver(
            forName: .companionActiveChannelChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onChannelChanged()
            }
        }
        // ChannelHealth is @Observable — bridge to a polling tick so
        // we don't pull Combine into every consumer. 1.5s cadence is
        // enough granularity for an expression that lives on a 2s+
        // debounce floor.
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.reactToHealth()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if self == nil { return }
            }
        }
    }

    isolated deinit {
        if let obs = channelObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        healthCancellable?.cancel()
    }

    // MARK: - Persona apply

    private func onChannelChanged() {
        let active = ChannelStore.shared.active
        applyPersona(active)
        // Force a fresh probe so the post-swap expression reflects the
        // new endpoint instead of the previous one's stale state.
        ChannelHealth.shared.probeNow()
    }

    private func applyPersona(_ channel: Channel) {
        let p = channel.persona
        dispatch(MaxClawdroomAction(
            op: "set_part_color",
            args: ["part": "tie" as AnyHashable, "hex": p.tieHex as AnyHashable]
        ))
        dispatch(MaxClawdroomAction(
            op: "set_chat_color",
            args: ["target": "border" as AnyHashable, "hex": p.chatBorderHex as AnyHashable]
        ))
        dispatch(MaxClawdroomAction(
            op: "set_chat_color",
            args: ["target": "user" as AnyHashable, "hex": p.chatUserHex as AnyHashable]
        ))
        dispatch(MaxClawdroomAction(
            op: "set_expression",
            args: ["name": p.baselineExpression as AnyHashable]
        ))
        if let gesture = p.greetGesture, !gesture.isEmpty {
            dispatch(MaxClawdroomAction(op: gesture, args: [:]))
        }
        if !p.voiceID.isEmpty {
            Prefs.voiceID = p.voiceID
        }
        Prefs.voiceMaxFilter = p.voiceFilter
        lastExpression = p.baselineExpression
        lastDispatchAt = Date()
    }

    // MARK: - Health → expression

    private func reactToHealth() {
        // Honour a soft floor so health flaps don't override expression
        // ops the user just triggered (mode change, manual revert).
        guard Date().timeIntervalSince(lastDispatchAt) > 4.0 else { return }
        let target: String? = {
            switch ChannelHealth.shared.state {
            case .unknown:      return nil
            case .live:         return ChannelStore.shared.active.persona.baselineExpression
            case .slow:         return "focused"
            case .unreachable:  return "sad"
            case .unauthorized: return "confused"
            }
        }()
        guard let target, target != lastExpression else { return }
        dispatch(MaxClawdroomAction(
            op: "set_expression",
            args: ["name": target as AnyHashable]
        ))
        lastExpression = target
        lastDispatchAt = Date()
    }
}
