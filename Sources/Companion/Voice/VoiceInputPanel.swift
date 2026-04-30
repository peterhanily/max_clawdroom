import AppKit
import SwiftUI

/// Floating panel that appears while the user holds the voice hotkey,
/// rendering live recognised words as they arrive from
/// `SpeechInputController`. Positioned relative to Max (falls back to
/// cursor if Max's position isn't available) so the listening feedback
/// reads as coming FROM him.
///
/// Intentionally transient — no titlebar, no buttons, dismisses the
/// instant the caller tears it down. Cancellation / submit decisions
/// live in the hotkey + AppDelegate, not here.
@MainActor
final class VoiceInputPanel {
    private weak var window: NSPanel?
    private let controller: SpeechInputController

    init(controller: SpeechInputController) {
        self.controller = controller
    }

    /// Bring up the panel anchored to a given point in screen coords.
    /// Caller typically hands us the primary overlay's pet origin so
    /// the panel floats just above Max.
    func show(anchoredAt anchor: NSPoint) {
        if window != nil { return }

        let size = NSSize(width: 360, height: 76)
        let origin = NSPoint(
            x: anchor.x - size.width / 2,
            y: anchor.y + 20
        )
        let frame = NSRect(origin: origin, size: size)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true   // hold-to-talk — no pointer interaction
        panel.contentViewController = NSHostingController(
            rootView: VoiceBubble(controller: controller)
        )
        panel.orderFrontRegardless()
        self.window = panel
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}

// MARK: - SwiftUI

private struct VoiceBubble: View {
    @ObservedObject var controller: SpeechInputController
    @State private var pulse: Double = 0

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Pulsing mic — the only animation; gives the user proof the
            // mic is hot without needing to stare at the text. When an
            // error is up the dot holds steady in red so the feedback
            // reads as "problem" not "listening".
            ZStack {
                Circle()
                    .fill(indicatorColor.opacity(0.25))
                    .scaleEffect(hasError ? 1.0 : (1.0 + pulse * 0.35))
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 10, height: 10)
            }
            .frame(width: 22, height: 22)
            .onAppear {
                guard !hasError else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = 1
                }
            }

            Text(displayText)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(hasError ? Color(nsColor: .systemRed) : Color.white)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(indicatorColor.opacity(0.75), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.55), radius: 22, x: 0, y: 10)
    }

    private var hasError: Bool {
        (controller.lastError ?? "").isEmpty == false
    }

    private var indicatorColor: Color {
        hasError ? Color(nsColor: .systemRed) : CRTPalette.magenta
    }

    /// Placeholder → live transcript → error message. An error takes
    /// precedence — if mic or speech access is denied, the user sees
    /// why instead of a misleading "listening…" while nothing records.
    private var displayText: String {
        if let err = controller.lastError, !err.isEmpty {
            return err
        }
        let t = controller.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "listening…" }
        return t
    }
}
