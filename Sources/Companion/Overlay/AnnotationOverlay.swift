import AppKit
import SwiftUI

/// Full-screen transparent click-through overlay for Max's on-screen
/// annotations — he can point at a coordinate, draw an arrow, or ring
/// the current editor line. The window sits above normal app windows
/// (status-bar level) and passes every mouse event straight through,
/// so annotations never get in the user's way.
///
/// Each `Mark` is a self-expiring visual: added via `addPoint` / `addArrow`
/// / `addRect`, rendered by the SwiftUI `AnnotationCanvas`, and removed
/// on a timer so a runaway agent can't accumulate clutter.
///
/// One overlay per app instance — primary-overlay-owned, same gate as
/// autonomy and rituals. Secondary monitors can still be annotated
/// because `NSScreen.screens` is consulted when sizing, but this first
/// cut spans only the screen Max lives on (the common case).
@MainActor
final class AnnotationOverlay: ObservableObject {

    /// A single visual annotation with an expiry stamp. SwiftUI drives
    /// the actual animation via `.transition(.opacity)` — this type just
    /// holds the data.
    struct Mark: Identifiable, Equatable {
        let id: UUID
        let kind: Kind
        let expiresAt: Date

        enum Kind: Equatable {
            case point(at: CGPoint, label: String?)
            case arrow(from: CGPoint, to: CGPoint, label: String?)
            case rect(CGRect, label: String?)
        }
    }

    @Published private(set) var marks: [Mark] = []

    private var window: NSPanel?
    private let screen: NSScreen

    /// Default durations applied when the agent doesn't specify one.
    /// Short enough not to clutter, long enough for the user to look up.
    private let defaultPointDuration: TimeInterval = 3.0
    private let defaultArrowDuration: TimeInterval = 3.5
    private let defaultRectDuration: TimeInterval = 4.0

    /// Maximum annotations per incoming "turn" (reset between LLM
    /// replies via `resetTurnCounter`). Prevents a prompt-injected or
    /// runaway reply from carpet-bombing the screen with marks.
    private let perTurnCap: Int = 5
    private var marksThisTurn: Int = 0

    init(screen: NSScreen) {
        self.screen = screen
        buildWindow()
    }

    isolated deinit {
        window?.orderOut(nil)
    }

    // MARK: - Public API

    func addPoint(at p: CGPoint, label: String?, duration: TimeInterval?) {
        guard canAddMark() else { return }
        add(Mark(
            id: UUID(),
            kind: .point(at: clamp(p), label: label),
            expiresAt: Date().addingTimeInterval(duration ?? defaultPointDuration)
        ))
    }

    func addArrow(from: CGPoint, to: CGPoint, label: String?, duration: TimeInterval?) {
        guard canAddMark() else { return }
        add(Mark(
            id: UUID(),
            kind: .arrow(from: clamp(from), to: clamp(to), label: label),
            expiresAt: Date().addingTimeInterval(duration ?? defaultArrowDuration)
        ))
    }

    func addRect(_ rect: CGRect, label: String?, duration: TimeInterval?) {
        guard canAddMark() else { return }
        add(Mark(
            id: UUID(),
            kind: .rect(clamp(rect), label: label),
            expiresAt: Date().addingTimeInterval(duration ?? defaultRectDuration)
        ))
    }

    /// Clear every in-flight annotation. Called on chat close / session
    /// reset so a fresh conversation doesn't inherit stale marks.
    func clearAll() {
        marks.removeAll()
    }

    /// Reset the per-turn annotation budget. Called at the start of each
    /// new LLM streaming reply — an assistant turn gets up to
    /// `perTurnCap` marks; anything past that is dropped. Prevents
    /// prompt-injected or runaway replies from spamming the overlay.
    func resetTurnCounter() {
        marksThisTurn = 0
    }

    private func canAddMark() -> Bool {
        if marksThisTurn >= perTurnCap {
            AppLog.app.notice("annotation rate-limited (already \(self.marksThisTurn) this turn)")
            return false
        }
        marksThisTurn += 1
        return true
    }

    /// Clamp a point into the union of all currently-connected screens
    /// so an LLM-supplied coord can't place marks off-screen (or abuse
    /// negative / huge coords to cause rendering weirdness). Defaults
    /// to the overlay's own screen when screen lookup fails.
    private func clamp(_ p: CGPoint) -> CGPoint {
        let bounds = Self.allScreensUnion() ?? screen.frame
        return CGPoint(
            x: max(bounds.minX, min(bounds.maxX, p.x)),
            y: max(bounds.minY, min(bounds.maxY, p.y))
        )
    }

    /// Clamp a rect into the screen union. Width / height are clamped
    /// too so an enormous "rect" can't paint the whole display magenta.
    private func clamp(_ r: CGRect) -> CGRect {
        let bounds = Self.allScreensUnion() ?? screen.frame
        let originX = max(bounds.minX, min(bounds.maxX, r.origin.x))
        let originY = max(bounds.minY, min(bounds.maxY, r.origin.y))
        let maxW = bounds.maxX - originX
        let maxH = bounds.maxY - originY
        return CGRect(
            x: originX,
            y: originY,
            width: max(0, min(maxW, r.width)),
            height: max(0, min(maxH, r.height))
        )
    }

    private static func allScreensUnion() -> CGRect? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        return screens.reduce(screens[0].frame) { $0.union($1.frame) }
    }

    // MARK: - Internals

    private func add(_ mark: Mark) {
        marks.append(mark)
        // Fire-and-forget removal. Using the mark's id means stale
        // timers can't remove a freshly-added mark of the same kind.
        let ttl = mark.expiresAt.timeIntervalSinceNow
        let markID = mark.id
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, ttl)) { [weak self] in
            self?.marks.removeAll { $0.id == markID }
        }
    }

    private func buildWindow() {
        let frame = screen.frame
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Click-through: the entire point of this overlay is that it
        // never catches a mouse event. Max draws on top of the user's
        // work; the user never drags on Max's drawing.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        panel.contentViewController = NSHostingController(
            rootView: AnnotationCanvas(overlay: self, screenFrame: frame)
        )
        panel.orderFrontRegardless()
        self.window = panel
    }
}

// MARK: - SwiftUI canvas

/// Renders the current marks. Subscribes to the overlay's @Published
/// `marks` — each mark fades in on insert and fades out when it's
/// removed (the asyncAfter timer drops it; SwiftUI's identified ForEach
/// animates the exit).
private struct AnnotationCanvas: View {
    @ObservedObject var overlay: AnnotationOverlay
    let screenFrame: CGRect

    var body: some View {
        ZStack {
            // Invisible background takes up the whole screen so the
            // NSPanel reports the right content size for hit-testing
            // (we're click-through anyway but hit-testing code paths
            // assume a non-zero view).
            Color.clear
            ForEach(overlay.marks) { mark in
                MarkView(mark: mark, screenFrame: screenFrame)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .animation(.easeOut(duration: 0.22), value: overlay.marks.map(\.id))
        .allowsHitTesting(false)
    }
}

private struct MarkView: View {
    let mark: AnnotationOverlay.Mark
    let screenFrame: CGRect

    var body: some View {
        switch mark.kind {
        case .point(let p, let label):
            pointView(at: p, label: label)
        case .arrow(let from, let to, let label):
            arrowView(from: from, to: to, label: label)
        case .rect(let rect, let label):
            rectView(rect: rect, label: label)
        }
    }

    // MARK: Point

    /// A pulsing ring at a screen coord. Converts Cocoa screen coords
    /// (bottom-left origin) into the canvas's top-left origin by
    /// flipping against `screenFrame`.
    private func pointView(at p: CGPoint, label: String?) -> some View {
        let local = flipped(p)
        return ZStack {
            Circle()
                .strokeBorder(CRTPalette.magenta, lineWidth: 3)
                .frame(width: 44, height: 44)
                .shadow(color: CRTPalette.magenta.opacity(0.65), radius: 12)
            Circle()
                .fill(CRTPalette.magenta.opacity(0.35))
                .frame(width: 14, height: 14)
            if let label, !label.isEmpty {
                annotationLabel(label)
                    .offset(y: 40)
            }
        }
        .position(x: local.x, y: local.y)
    }

    // MARK: Arrow

    private func arrowView(from: CGPoint, to: CGPoint, label: String?) -> some View {
        let a = flipped(from)
        let b = flipped(to)
        return ZStack {
            Path { p in
                p.move(to: a)
                p.addLine(to: b)
            }
            .stroke(CRTPalette.magenta, lineWidth: 3)
            .shadow(color: CRTPalette.magenta.opacity(0.55), radius: 8)
            // Arrowhead — compute tangent at `to`, draw a small wedge.
            arrowhead(at: b, from: a)
            if let label, !label.isEmpty {
                annotationLabel(label)
                    .position(
                        x: (a.x + b.x) / 2,
                        y: (a.y + b.y) / 2 - 18
                    )
            }
        }
    }

    private func arrowhead(at tip: CGPoint, from origin: CGPoint) -> some View {
        let dx = tip.x - origin.x
        let dy = tip.y - origin.y
        let angle = atan2(dy, dx)
        let size: CGFloat = 14
        let spread: CGFloat = .pi / 6
        let left = CGPoint(
            x: tip.x - size * cos(angle - spread),
            y: tip.y - size * sin(angle - spread)
        )
        let right = CGPoint(
            x: tip.x - size * cos(angle + spread),
            y: tip.y - size * sin(angle + spread)
        )
        return Path { p in
            p.move(to: tip)
            p.addLine(to: left)
            p.addLine(to: right)
            p.closeSubpath()
        }
        .fill(CRTPalette.magenta)
        .shadow(color: CRTPalette.magenta.opacity(0.7), radius: 6)
    }

    // MARK: Rect

    /// A glowing ring around a rectangle — used by `annotate_cursor_line`
    /// where the AccessibilityBridge returns the line's bounds.
    private func rectView(rect: CGRect, label: String?) -> some View {
        let flipped = CGRect(
            x: rect.origin.x - screenFrame.minX,
            y: screenFrame.height - (rect.origin.y - screenFrame.minY) - rect.height,
            width: rect.width,
            height: rect.height
        )
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(CRTPalette.magenta, lineWidth: 2)
                .frame(width: flipped.width + 8, height: flipped.height + 8)
                .shadow(color: CRTPalette.magenta.opacity(0.6), radius: 10)
            if let label, !label.isEmpty {
                annotationLabel(label)
                    .offset(x: 0, y: -26)
            }
        }
        .position(x: flipped.midX, y: flipped.midY)
    }

    // MARK: Label

    private func annotationLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(CRTPalette.magenta.opacity(0.8), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.45), radius: 8)
            .fixedSize()
    }

    // MARK: - Coord helpers

    /// AX / NSScreen return points in Cocoa bottom-left coords. SwiftUI
    /// canvases use top-left. Flip against the overlay's screen frame so
    /// an annotation at y=100 lands at the bottom of the screen, not the
    /// top.
    private func flipped(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: p.x - screenFrame.minX,
            y: screenFrame.height - (p.y - screenFrame.minY)
        )
    }
}
