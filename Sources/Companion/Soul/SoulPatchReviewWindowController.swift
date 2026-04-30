import AppKit
import SwiftUI

/// Soul-change history viewer. In the auto-apply model, Max writes to
/// his own soul without a review gate — but the user audits after the
/// fact via this window and the full editor in Settings → Soul.
///
/// Each history entry shows:
/// - Timestamp
/// - Max's rationale for the change
/// - The literal patch text that was appended
/// - Revert button (rolls back to that snapshot's priorPrompt)
/// - Edit button (opens Settings with the Soul section focused so the
///   user can tweak the final assembled prompt directly)
@MainActor
final class SoulPatchReviewWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func present() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(
            rootView: SoulHistoryReviewView(history: SoulHistory.shared)
                // Pin the SwiftUI intrinsic size so NSHostingController
                // doesn't ask the window for infinite height. Without
                // this, `maxHeight: .infinity` inside the empty state
                // propagates up and setContentSize gets overridden at
                // layout time.
                .frame(minWidth: 380, idealWidth: 440, maxWidth: 600,
                       minHeight: 280, idealHeight: 360, maxHeight: 560)
        )
        host.preferredContentSize = NSSize(width: 440, height: 360)
        let window = NSWindow(contentViewController: host)
        window.title = "Max's Soul History"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.setContentSize(NSSize(width: 440, height: 360))
        window.minSize = NSSize(width: 380, height: 280)
        window.maxSize = NSSize(width: 600, height: 560)
        window.center()
        window.delegate = self
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct SoulHistoryReviewView: View {
    let history: SoulHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if history.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(history.entries) { entry in
                            EntryCard(entry: entry, history: history)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("soul_review.title", bundle: .companionResources)
                    .font(.title3.bold())
                Spacer()
                if !history.entries.isEmpty {
                    Button {
                        NotificationCenter.default.post(
                            name: .companionDebugSoulPatchRequest, object: nil
                        )
                    } label: {
                        Label("Ask Max to reflect", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Text("soul_review.subtitle", bundle: .companionResources)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text("soul_review.empty.title", bundle: .companionResources)
                .font(.headline)
            Text("Max writes his own personality when he notices patterns. Trigger one now, or edit the soul directly in Settings.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    NotificationCenter.default.post(
                        name: .companionDebugSoulPatchRequest, object: nil
                    )
                } label: {
                    Label("Ask Max to reflect", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)

                Button("Edit soul…") {
                    NotificationCenter.default.post(
                        name: .companionOpenSoulEditor, object: nil
                    )
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}

private struct EntryCard: View {
    let entry: SoulVersion
    let history: SoulHistory

    private var isRevert: Bool {
        entry.rationale.hasPrefix("Reverted to snapshot")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: isRevert ? "arrow.uturn.backward.circle" : "sparkles")
                    .foregroundStyle(isRevert ? .orange : .purple)
                    .font(.system(size: 11))
                Text(isRevert ? "Reverted" : "Patch applied")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(timeAgo(entry.appliedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if !entry.rationale.isEmpty {
                Text(entry.rationale)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !entry.patch.isEmpty {
                Text(entry.patch)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(5)
                    .lineLimit(4)
                    .truncationMode(.tail)
            }
            HStack(spacing: 6) {
                Spacer()
                Button("Edit…") {
                    NotificationCenter.default.post(name: .companionOpenSoulEditor, object: nil)
                }
                .controlSize(.small)
                Button("Revert") {
                    history.revert(to: entry.id)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    private func timeAgo(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}
