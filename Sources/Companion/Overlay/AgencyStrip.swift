import AppKit
import Observation
import SwiftUI

/// Thin transparent status strip showing what Max is *doing* right now —
/// "thinking", "running Grep", "reading UserAuth.swift". Makes invisible
/// agent activity legible. Borrows from Cursor's live agency-indicator
/// pattern.
///
/// Positioned directly below the pet's on-screen rect, follows as Max
/// walks, click-through, fades in/out on state changes. Hidden when Max
/// is speaking (prose arriving) or idle — only shows during the
/// thinking / tool-execution beats.
///
/// Primary-overlay-only, like AnnotationOverlay + autonomy. Secondary
/// monitors get nothing, which is fine — the activity surface is singular.
@MainActor
final class AgencyStrip {

    private var window: NSPanel?
    private let viewModel: AgencyStripViewModel
    /// Pet-rect supplier — evaluated each tick so the strip follows Max
    /// as he walks. Same pattern CursorGazeController uses.
    private let petScreenRect: () -> NSRect
    private var positionTimer: Timer?

    init(session: ChatSession, petScreenRect: @escaping () -> NSRect) {
        self.viewModel = AgencyStripViewModel(session: session)
        self.petScreenRect = petScreenRect
        buildWindow()
        startFollowing()
    }

    isolated deinit {
        // Swift 6.2 isolated deinit (SE-0371): runs on MainActor since
        // the class is MainActor-isolated. Lets us touch MainActor-
        // isolated state (positionTimer, window) during teardown
        // without hopping via Task — correct AND race-free.
        positionTimer?.invalidate()
    }

    // MARK: - Window

    private func buildWindow() {
        let size = NSSize(width: 320, height: 22)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true  // pure indicator, never accepts input
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        panel.contentViewController = NSHostingController(
            rootView: AgencyStripView(viewModel: viewModel)
        )
        panel.orderFrontRegardless()
        self.window = panel
        reposition()
    }

    // MARK: - Follow Max as he walks

    /// 5 Hz position tracker — cheap, and the pet moves slowly enough
    /// that a faster cadence wouldn't help. Re-evaluates petScreenRect
    /// and slides the window under it.
    private func startFollowing() {
        // Plain DispatchQueue.main.async hop instead of Task{@MainActor in…}.
        // The timer fires on main run loop already; the GCD hop just
        // satisfies the C ABI of the Timer block (non-@Sendable). No
        // Swift concurrency, no executor hop — works correctly under
        // the macOS 26.x runtime hooks (CompanionRuntimePatch).
        positionTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.reposition() }
        }
        RunLoop.main.add(t, forMode: .common)
        positionTimer = t
    }

    private func reposition() {
        guard let window else { return }
        let petRect = petScreenRect()
        // petRect can be .zero before the scene graph is fully laid out;
        // skip positioning until it's real so we don't flash the strip
        // top-left at app launch.
        guard petRect.width > 0 else { return }
        let size = window.frame.size
        // Centred horizontally ABOVE the pet (was below, which crowded
        // his feet and read as "weird circle under him"). Cocoa
        // bottom-left origin — "above" the pet means larger y.
        let origin = NSPoint(
            x: petRect.midX - size.width / 2,
            y: petRect.maxY + 8
        )
        window.setFrameOrigin(origin)
    }
}

// MARK: - View model

/// Derives a single display string from ChatSession's streaming state.
/// Hidden state is modelled as `nil` so the SwiftUI view can use the
/// `if let` pattern to transition cleanly.
@Observable
@MainActor
final class AgencyStripViewModel {
    private(set) var activity: String?
    @ObservationIgnored private weak var session: ChatSession?

    init(session: ChatSession) {
        self.session = session
        recomputeFromSession()
        track()
    }

    private func track() {
        withObservationTracking { [weak session] in
            guard let session else { return }
            _ = session.isStreaming
            _ = session.activeStreamingToolName
            _ = session.hasStreamingText
            _ = session.currentSilentLabel
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.recomputeFromSession()
                self.track()
            }
        }
    }

    private func recomputeFromSession() {
        guard let session else { activity = nil; return }
        activity = Self.derive(
            isStreaming: session.isStreaming,
            tool: session.activeStreamingToolName,
            hasText: session.hasStreamingText,
            silentLabel: session.currentSilentLabel
        )
    }

    /// State derivation — single place where the display logic lives.
    /// - Not streaming → hidden.
    /// - Streaming + silent label set → show that label (autonomy tick,
    ///   lifecycle plan, etc.) so the user sees what Max is up to
    ///   instead of a mysterious "thinking" with no voiced output.
    /// - Streaming + tool running → "running \(name)".
    /// - Streaming + prose arriving → hidden (he's speaking; the bubble
    ///   already shows activity).
    /// - Streaming + neither → "thinking".
    private static func derive(
        isStreaming: Bool,
        tool: String?,
        hasText: Bool,
        silentLabel: String?
    ) -> String? {
        guard isStreaming else { return nil }
        if let tool, !tool.isEmpty { return "running \(tool)" }
        if hasText { return nil }
        if let label = silentLabel, !label.isEmpty { return label }
        return "thinking"
    }
}

// MARK: - View

private struct AgencyStripView: View {
    let viewModel: AgencyStripViewModel

    @State private var dotPhase: Int = 0
    /// 0.45 s tick driving the typing-dots animation. SwiftUI binds the
    /// publisher to the view lifecycle automatically — when the
    /// `if let activity` branch goes false the View leaves the tree and
    /// the publisher stops. No manual invalidate needed.
    private let dotTimer = Timer.publish(every: 0.45, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        Group {
            if let activity = viewModel.activity {
                HStack(spacing: 6) {
                    Text(activity)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // Three dots that fill in sequentially. Reads as
                    // "typing / working" without the indeterminate-circle
                    // ambiguity that ProgressView landed near Max's feet.
                    Text(dots)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(CRTPalette.magenta)
                        .frame(width: 16, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.72))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(CRTPalette.magenta.opacity(0.55), lineWidth: 0.5)
                        )
                )
                .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 3)
                .transition(.opacity.combined(with: .offset(y: 4)))
                .onReceive(dotTimer) { _ in dotPhase += 1 }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: viewModel.activity)
    }

    /// Builds the visible dot string from `dotPhase` (0…3 → "", ".", "..", "...").
    private var dots: String {
        switch dotPhase % 4 {
        case 1:  return "."
        case 2:  return ".."
        case 3:  return "..."
        default: return ""
        }
    }
}
