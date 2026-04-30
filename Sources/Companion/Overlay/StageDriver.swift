import AppKit
import Foundation
import Observation

/// Bridges `ChatSession` streaming state onto `MaxClawdroomState.stage` so
/// the expression driver, CRT intensity, and anything else downstream
/// reacts to what Max is actually doing right now.
///
/// Priority: error > toolUse > speaking > thinking > idle.
@MainActor
final class StageDriver {
    private weak var session: ChatSession?
    private let state: MaxClawdroomState

    init(session: ChatSession, state: MaxClawdroomState) {
        self.session = session
        self.state = state

        // Prime once, then self-rearm via withObservationTracking.
        // Tracks the same four discrete signals the old CombineLatest4
        // pipeline did — NOT `messages`, which would invalidate on every
        // streaming token and trigger an O(n) scan per chunk.
        recomputeFromSession()
        track()
    }

    private func track() {
        withObservationTracking { [weak session] in
            guard let session else { return }
            _ = session.isStreaming
            _ = session.errorMessage
            _ = session.activeStreamingToolName
            _ = session.hasStreamingText
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.recomputeFromSession()
                self.track()
            }
        }
    }

    private func recomputeFromSession() {
        guard let session else { return }
        recompute(
            isStreaming: session.isStreaming,
            error: session.errorMessage,
            toolName: session.activeStreamingToolName,
            hasText: session.hasStreamingText
        )
    }

    private func recompute(
        isStreaming: Bool,
        error: String?,
        toolName: String?,
        hasText: Bool
    ) {
        let newStage: MaxClawdroomStage
        if error != nil {
            newStage = .error
        } else if !isStreaming {
            newStage = .idle
        } else if let name = toolName {
            newStage = .toolUse(tool: name)
        } else if hasText {
            newStage = .speaking
        } else {
            newStage = .thinking
        }

        if state.stage != newStage {
            state.setStage(newStage)
            announce(newStage)
        }
    }

    /// Fire a VoiceOver announcement for the new stage. The system drops
    /// the announcement on the floor when VO isn't running, so posting
    /// unconditionally is cheaper than trying to detect VO state (macOS
    /// doesn't expose a public `isVoiceOverEnabled` property on NSWorkspace).
    /// `.high` priority interrupts an in-progress readback so "thinking…"
    /// becomes "speaking" mid-sentence. Skipped when the user has opted
    /// out via Prefs.announceStageChanges.
    private func announce(_ stage: MaxClawdroomStage) {
        guard Prefs.announceStageChanges else { return }
        let label: String
        switch stage {
        case .idle:                  return  // Silence between thoughts.
        case .listening:             label = "Max is listening"
        case .thinking:              label = "Max is thinking"
        case .speaking:              label = "Max is speaking"
        case .toolUse(let tool):     label = "Running tool: \(tool)"
        case .error:                 label = "Error encountered"
        case .sleeping:              label = "Max is idle"
        }
        NSAccessibility.post(
            element: NSApp.mainWindow ?? NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: label,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}
