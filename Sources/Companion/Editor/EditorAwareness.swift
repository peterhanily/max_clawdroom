import AppKit
import Combine

/// Polls the AX bridge for the currently focused editor window and exposes
/// both a lightweight `snapshot` (window bounds, used for overlay
/// pointing) and a richer `context` (document path + cursor line + line
/// text + selection, fed into the system prompt).
@MainActor
final class EditorAwareness: ObservableObject {
    @Published private(set) var snapshot: AccessibilityBridge.EditorSnapshot?
    @Published private(set) var context: AccessibilityBridge.EditorContext?
    @Published private(set) var isTrusted: Bool = AccessibilityPermission.isTrusted

    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        isTrusted = AccessibilityPermission.isTrusted
        snapshot = AccessibilityBridge.snapshotFrontmostEditor()
        context = AccessibilityBridge.snapshotEditorContext()
    }

    isolated deinit {
        timer?.invalidate()
    }
}
