import Combine
import Foundation

/// Central pub/sub fabric for telemetry events.
/// Emitters (ChatSession, SwarmController, EditorAwareness, …) call `emit`.
/// Consumers (BindingEngine) subscribe to `events`.
@MainActor
final class TelemetryBus {
    private let subject = PassthroughSubject<TelemetryEvent, Never>()

    /// Publisher of all emitted events. Subscribe with sink or assign.
    var events: AnyPublisher<TelemetryEvent, Never> { subject.eraseToAnyPublisher() }

    func emit(_ event: TelemetryEvent) {
        subject.send(event)
    }

    func emit(signal: String, value: Double? = nil, payload: [String: Any]? = nil) {
        emit(TelemetryEvent(signal: signal, value: value, payload: payload))
    }
}
