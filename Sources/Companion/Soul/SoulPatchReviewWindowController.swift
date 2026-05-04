import AppKit
import SwiftUI

/// Max's Soul — pending review + applied history in one window.
///
/// **Pending section** (visible when `SoulPatchQueue.shared.pending` is
/// non-empty): each proposal renders rationale + patch text with
/// Approve / Reject buttons. Approve calls `SoulPatchQueue.accept` which
/// runs the same deny-pattern + rate-limit + soul-cap gates as the
/// auto-apply path; reject silently removes the proposal so Max won't
/// know the difference from queue pressure.
///
/// **Applied section**: post-hoc audit of accepted patches, each with
/// rationale, patch text, timestamp, and a Revert button that rolls
/// back to that snapshot's `priorPrompt`.
///
/// **Header**: cumulative soul size meter. Surfaces the
/// `SoulPatchQueue.soulCharCap` ceiling so users can see how full
/// their soul is — a slow-drift warning that lives next to the
/// per-patch deny-list and rate limits.
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
            rootView: SoulReviewView(
                history: SoulHistory.shared,
                queue: SoulPatchQueue.shared
            )
                // Pin the SwiftUI intrinsic size so NSHostingController
                // doesn't ask the window for infinite height. Without
                // this, `maxHeight: .infinity` inside the empty state
                // propagates up and setContentSize gets overridden at
                // layout time.
                .frame(minWidth: 420, idealWidth: 480, maxWidth: 640,
                       minHeight: 320, idealHeight: 440, maxHeight: 640)
        )
        host.preferredContentSize = NSSize(width: 480, height: 440)
        let window = NSWindow(contentViewController: host)
        window.title = "Max's Soul"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.setContentSize(NSSize(width: 480, height: 440))
        window.minSize = NSSize(width: 420, height: 320)
        window.maxSize = NSSize(width: 640, height: 640)
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

private struct SoulReviewView: View {
    let history: SoulHistory
    let queue: SoulPatchQueue

    /// Bumped by the `companionSoulPatchQueueChanged` /
    /// `companionSoulChanged` observers so SwiftUI re-reads
    /// `queue.pending` and `history.entries` while the window is open.
    /// Cheaper than making the singletons ObservableObject for this one
    /// view; the values are tiny and re-fetch is O(N entries).
    @State private var revision: Int = 0
    private let queueTick = NotificationCenter.default.publisher(
        for: .companionSoulPatchQueueChanged
    )
    private let historyTick = NotificationCenter.default.publisher(
        for: .companionSoulChanged
    )

    private var pending: [SoulPatchProposal] { queue.pending }
    private var entries: [SoulVersion] { history.entries }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if pending.isEmpty && entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !pending.isEmpty {
                            sectionLabel(
                                "Pending review (\(pending.count))",
                                systemImage: "sparkles"
                            )
                            ForEach(pending) { proposal in
                                ProposalCard(proposal: proposal, queue: queue)
                            }
                        }
                        if !pending.isEmpty && !entries.isEmpty {
                            Divider().padding(.vertical, 4)
                        }
                        if !entries.isEmpty {
                            sectionLabel(
                                "Applied (\(entries.count))",
                                systemImage: "clock.arrow.circlepath"
                            )
                            ForEach(entries) { entry in
                                EntryCard(entry: entry, history: history)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .onReceive(queueTick) { _ in revision &+= 1 }
        .onReceive(historyTick) { _ in revision &+= 1 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Max's Soul")
                    .font(.title3.bold())
                Spacer()
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
            Text("Pending proposals queue here for your review; applied patches are below with revert buttons. Max's full soul lives in Settings → Mind.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            soulSizeMeter
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var soulSizeMeter: some View {
        let size = SettingsStore.shared.settings.systemPrompt.count
        let cap = SoulPatchQueue.soulCharCap
        let ratio = max(0.0, min(1.0, Double(size) / Double(cap)))
        let pct = Int(ratio * 100)
        let tint: Color = ratio > 0.85 ? .orange : (ratio > 0.6 ? .yellow : .green)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Soul size")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(size.formatted()) / \(cap.formatted()) chars · \(pct)%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: ratio)
                .tint(tint)
        }
        .padding(.top, 4)
    }

    private func sectionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
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

private struct ProposalCard: View {
    let proposal: SoulPatchProposal
    let queue: SoulPatchQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                    .font(.system(size: 11))
                Text("Proposal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text(timeAgo(proposal.createdAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if !proposal.rationale.isEmpty {
                Text(proposal.rationale)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !proposal.patch.isEmpty {
                Text(proposal.patch)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.purple.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.purple.opacity(0.25), lineWidth: 0.6)
                    )
                    .cornerRadius(5)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                Spacer()
                Button("Reject") { queue.reject(id: proposal.id) }
                    .controlSize(.small)
                Button("Approve") { queue.accept(id: proposal.id) }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.purple.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.purple.opacity(0.20), lineWidth: 0.6)
        )
        .cornerRadius(8)
    }

    private func timeAgo(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: Date())
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
