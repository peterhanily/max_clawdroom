import Combine
import Foundation

/// Shared open/close signal between `ChatBubbleController` (AppKit side)
/// and `ChatBubbleView` (SwiftUI side). The controller sets `isOpen =
/// false` to request a close; the view observes, runs its CRT collapse
/// animation, then calls back via `onAnimationComplete` so the
/// controller can `orderOut` the NSWindow.
///
/// Keeping this as a dedicated object (rather than a Binding) lets both
/// internal close triggers (X button, Escape) and external ones (click
/// Max again to toggle) share one animation path.
@MainActor
final class ChatBubblePresence: ObservableObject {
    @Published var isOpen: Bool = true

    /// Called by the view after its close animation has played through.
    /// The controller wires this to the actual NSWindow.orderOut.
    var onAnimationComplete: (() -> Void)?
}
