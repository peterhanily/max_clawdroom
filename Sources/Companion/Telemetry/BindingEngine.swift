import AppKit
import Combine
import Foundation

/// Holds the current list of bindings and applies them to the Pet when
/// matching events arrive on the bus.
@MainActor
final class BindingEngine {
    /// Signal name → list of bindings for that signal. O(1) lookup on hot path.
    private var bindingsBySignal: [String: [TelemetryBinding]] = [:]
    private weak var pet: Pet?
    private var subscription: AnyCancellable?

    init(bus: TelemetryBus, pet: Pet) {
        self.pet = pet
        subscription = bus.events.sink { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
        }
    }

    func register(_ binding: TelemetryBinding) {
        // Dedup: same (signal, part) replaces.
        var list = bindingsBySignal[binding.signal, default: []]
        list.removeAll { $0.part == binding.part }
        list.append(binding)
        bindingsBySignal[binding.signal] = list
    }

    func unregister(signal: String, part: String) {
        bindingsBySignal[signal]?.removeAll { $0.part == part }
        if bindingsBySignal[signal]?.isEmpty == true {
            bindingsBySignal.removeValue(forKey: signal)
        }
    }

    func clearAll() {
        bindingsBySignal.removeAll()
    }

    var currentBindings: [TelemetryBinding] {
        bindingsBySignal.values.flatMap { $0 }
    }

    private func handle(_ event: TelemetryEvent) {
        guard let pet = pet,
              let list = bindingsBySignal[event.signal] else { return }
        for b in list {
            apply(binding: b, event: event, pet: pet)
        }
    }

    private func apply(binding b: TelemetryBinding, event: TelemetryEvent, pet: Pet) {
        switch b.mode {
        case .flash:
            let color = b.params.color ?? NSColor(srgbRed: 1, green: 0.35, blue: 0.25, alpha: 1)
            let duration = b.params.duration ?? 0.3
            pet.flashPart(b.part, to: color, duration: duration)

        case .ripple:
            let color = b.params.color ?? NSColor.white
            let duration = b.params.duration ?? 0.5
            pet.ripplePart(b.part, color: color, duration: duration)

        case .pulse:
            let base = b.params.amplitude.map { CGFloat($0) } ?? 0.08
            let amp = event.value.map { CGFloat($0) * base } ?? base
            pet.pulsePart(b.part, amplitude: amp)

        case .shake:
            let base = b.params.amplitude.map { CGFloat($0) } ?? 0.06
            let amp = event.value.map { CGFloat($0) * base } ?? base
            pet.shakePart(b.part, amplitude: amp)

        case .tint:
            let target = b.params.color ?? NSColor.cyan
            let amount = event.value.map { CGFloat($0) } ?? 1.0
            pet.tintPart(b.part, toward: target, amount: amount)

        case .tilt:
            let base = b.params.amplitude.map { CGFloat($0) } ?? 0.15
            let amount = event.value.map { CGFloat($0) * base } ?? base
            pet.tiltPart(b.part, amount: amount)

        case .brightness:
            let intensity = event.value.map { CGFloat($0) } ?? 1.0
            pet.brightnessPart(b.part, intensity: intensity)
        }
    }

    /// `subscription` would otherwise outlive the engine — `bus.events`
    /// is a `PassthroughSubject` that retains the sink until cancelled,
    /// so without this the engine + every `[weak self]` closure capture
    /// stays alive past deinit. Isolated deinit (SE-0371) so cancel
    /// runs on the @MainActor queue the subscription was attached on.
    isolated deinit {
        subscription?.cancel()
    }
}
