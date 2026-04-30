import AppKit
import SwiftUI

/// A small, borderless, transparent NSWindow that hosts the chat UI as a
/// SwiftUI view. Its screen position tracks the pet's projected position each frame.
@MainActor
final class ChatBubbleController: NSObject {
    let window: ChatBubbleWindow
    let session: ChatSession
    let presence = ChatBubblePresence()
    weak var overlay: OverlayController?
    var onClose: (() -> Void)?

    private var tracker: Timer?
    private var targetOrigin: NSPoint = .zero
    private var smoothedOrigin: NSPoint = .zero
    /// True = bubble follows the pet. Flipped to false the first time the
    /// user manually drags the window, so the user's placement sticks.
    private var autoTrack: Bool = true
    /// Guards our own setFrameOrigin calls from being mistaken for a user drag.
    private var isInternalMove: Bool = false

    init(overlay: OverlayController, session: ChatSession) {
        self.overlay = overlay
        self.session = session

        // Default 420×440. Smaller than the original 420×560 — the
        // messages area used to be hard-capped at 280pt so the extra
        // height was mostly dead space; now that the list fills the
        // window vertically, a shorter default feels right and the user
        // can drag the window larger for long conversations.
        let window = ChatBubbleWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 340, height: 320)
        window.maxSize = NSSize(width: 720, height: 900)
        self.window = window

        super.init()
        window.delegate = self

        // When the view finishes its close animation, the presence
        // object fires this. We actually orderOut here.
        presence.onAnimationComplete = { [weak self] in
            self?.finalizeClose()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: window
        )

        let root = ChatBubbleView(
            session: session,
            theme: overlay.chatTheme,
            tour: overlay.tour,
            presence: presence,
            tint: Color(overlay.pet.form.bubbleAccent),
            undoStack: overlay.undoStack,
            onSubmit: { [weak self] text in
                self?.session.send(text)
            }
        )
        let host = NSHostingView(rootView: root)
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 320))
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = container
    }

    func show() {
        autoTrack = true
        updateTargetOrigin(force: true)
        isInternalMove = true
        window.setFrameOrigin(smoothedOrigin)
        isInternalMove = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        tracker?.invalidate()
        tracker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let tracker { RunLoop.main.add(tracker, forMode: .common) }
    }

    /// Request a close. Triggers the view's CRT-collapse animation; the
    /// actual `orderOut` happens in `finalizeClose` once the view signals
    /// via `presence.onAnimationComplete`. Safe to call multiple times —
    /// the presence flag guards re-entry.
    func close() {
        guard presence.isOpen else { return }
        presence.isOpen = false
    }

    private func finalizeClose() {
        tracker?.invalidate()
        tracker = nil
        session.cancel()
        window.orderOut(nil)
        onClose?()
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        tracker?.invalidate()
        tracker = nil
    }
}

extension ChatBubbleController: NSWindowDelegate {}

// A no-op extension closer above — the one that follows is a dummy to let
// Swift know ChatBubbleController conforms. Real methods live above.
extension ChatBubbleController {

    private func tick() {
        guard autoTrack else { return }
        updateTargetOrigin()
        // Sleep when we've converged to target. A 60 Hz timer running
        // just to redundantly setFrameOrigin(settled) was burning ~2%
        // CPU for no visual effect. Re-arms on any target change via
        // `wakeTracker()` below.
        let dx = targetOrigin.x - smoothedOrigin.x
        let dy = targetOrigin.y - smoothedOrigin.y
        if hypot(dx, dy) < 0.5 {
            smoothedOrigin = targetOrigin
            isInternalMove = true
            window.setFrameOrigin(smoothedOrigin)
            isInternalMove = false
            tracker?.invalidate()
            tracker = nil
            return
        }
        let lerp: CGFloat = 0.25
        let nx = smoothedOrigin.x + dx * lerp
        let ny = smoothedOrigin.y + dy * lerp
        smoothedOrigin = NSPoint(x: nx, y: ny)
        isInternalMove = true
        window.setFrameOrigin(smoothedOrigin)
        isInternalMove = false
    }

    /// Restart the 60 Hz follow timer. Called from updateTargetOrigin
    /// whenever the target moves — ensures the tracker wakes up from
    /// its settled-idle state when the pet moves, window resizes, or
    /// mode change shifts the anchor.
    private func wakeTracker() {
        guard tracker == nil, autoTrack else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        tracker = t
    }

    @objc private func handleWindowDidMove(_ notification: Notification) {
        if !isInternalMove {
            autoTrack = false
        }
    }

    private func updateTargetOrigin(force: Bool = false) {
        guard let overlay else { return }
        let petRect = overlay.petScreenRect()
        let windowSize = window.frame.size

        let screen = overlay.screen.frame
        let margin: CGFloat = 20
        let edgePad: CGFloat = 12
        let minX = screen.minX + edgePad
        let maxX = screen.maxX - windowSize.width - edgePad
        let minY = screen.minY + edgePad
        let maxY = screen.maxY - windowSize.height - edgePad

        func clampX(_ v: CGFloat) -> CGFloat { max(minX, min(v, maxX)) }
        func clampY(_ v: CGFloat) -> CGFloat { max(minY, min(v, maxY)) }

        // Priority: above → right → left → below. The first that doesn't
        // run off-screen wins. When scaling the pet up, "above" often
        // clips the menu bar — side placement becomes the natural fallback
        // instead of covering his face.
        let chosen: NSPoint
        let candidateAboveY = petRect.maxY + margin
        let candidateSideY = petRect.midY - windowSize.height / 2
        let candidateBelowY = petRect.minY - windowSize.height - margin

        if candidateAboveY + windowSize.height <= screen.maxY - edgePad {
            chosen = NSPoint(
                x: clampX(petRect.midX - windowSize.width / 2),
                y: candidateAboveY
            )
        } else if petRect.maxX + margin + windowSize.width <= screen.maxX - edgePad {
            // Right side
            chosen = NSPoint(
                x: petRect.maxX + margin,
                y: clampY(candidateSideY)
            )
        } else if petRect.minX - margin - windowSize.width >= screen.minX + edgePad {
            // Left side
            chosen = NSPoint(
                x: petRect.minX - margin - windowSize.width,
                y: clampY(candidateSideY)
            )
        } else {
            // Below as last resort
            chosen = NSPoint(
                x: clampX(petRect.midX - windowSize.width / 2),
                y: clampY(candidateBelowY)
            )
        }

        let previousTarget = targetOrigin
        targetOrigin = chosen
        if force {
            smoothedOrigin = targetOrigin
        } else if hypot(chosen.x - previousTarget.x, chosen.y - previousTarget.y) > 0.5 {
            // Target moved — wake the tracker if it had gone to sleep
            // after convergence. Cheap; no-op when already running.
            wakeTracker()
        }
    }
}
