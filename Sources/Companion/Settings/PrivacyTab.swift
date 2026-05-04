import SwiftUI
import AppKit

/// Settings → Privacy. Two trust-visibility surfaces in one tab:
///
///   1. **What Max sees** — live mirror of what the Accessibility
///      bridge is reading from the frontmost app *right now*. Renders
///      the same `EditorContext` that lands in the `[editor]` system-
///      prompt block, plus the sensitive-app denylist verdict.
///      Turning a scary permission into something inspectable.
///
///   2. **Action history** — every action op the agent dispatched, in
///      reverse chronological order. Sourced from `ActionAuditLog`,
///      which observes the existing `companionAgentAction` broadcast
///      and persists JSONL under
///      `~/Library/Application Support/Companion/actions/audit.jsonl`.
///      A "durable only" toggle filters down to ops that wrote state
///      that survives a session (memory, soul, settings, downloads).
///
/// Both surfaces are read-only. Sensitive editor content (passwords,
/// terminal, banking apps) never reaches this view because
/// `AccessibilityBridge` returns nil for those — same path the prompt
/// builder takes.
struct PrivacyTab: View {
    @StateObject private var editorAwareness = EditorAwareness()
    @ObservedObject private var auditLog = ActionAuditLog.shared

    @State private var durableOnly: Bool = false
    @State private var sensitiveTickKey: Int = 0
    private let sensitiveTickTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                whatMaxSeesSection
                Divider()
                actionHistorySection
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 12)
        }
        .onAppear { editorAwareness.start() }
        .onReceive(sensitiveTickTimer) { _ in
            // The sensitive-frontmost verdict isn't @Published anywhere —
            // it's a synchronous query against NSWorkspace.frontmost.
            // Bumping a state key once a second is the cheapest way to
            // get the panel to re-evaluate without coupling to a new
            // notification.
            sensitiveTickKey &+= 1
        }
    }

    // MARK: - What Max sees

    private var whatMaxSeesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("What Max sees", systemImage: "eye")
            Text("Live mirror of the editor context your prompt builder receives. Sensitive apps (password managers, Keychain, terminals, mail, banking, secure messaging) are blocked entirely — Max gets nil for those.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let sensitive = AccessibilityBridge.frontmostIsSensitive()
            // Force the `let` to participate in invalidation so the
            // 1Hz tick refreshes the verdict live.
            let _ = sensitiveTickKey

            VStack(alignment: .leading, spacing: 8) {
                if !editorAwareness.isTrusted {
                    statusBadge(
                        "Accessibility permission not granted",
                        tint: .orange,
                        systemImage: "lock.shield"
                    )
                    Text("Max can't see anything until you grant Accessibility in System Settings → Privacy & Security.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if sensitive {
                    statusBadge(
                        "Sensitive app in front — Max is blind",
                        tint: .green,
                        systemImage: "eye.slash"
                    )
                    Text("Frontmost app is on the denylist (or Secure Event Input is active). Nothing leaves this machine.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if let ctx = editorAwareness.context {
                    statusBadge(
                        "Reading from \(ctx.appName)",
                        tint: .blue,
                        systemImage: "doc.text.magnifyingglass"
                    )
                    fieldRow("App", ctx.appName)
                    fieldRow("Document", ctx.documentPath ?? "—")
                    fieldRow(
                        "Cursor line",
                        ctx.currentLineNumber.map { "\($0)" } ?? "—"
                    )
                    fieldRow(
                        "Line text",
                        truncated(ctx.currentLineText, max: 200) ?? "—",
                        mono: true
                    )
                    fieldRow(
                        "Selection",
                        truncated(ctx.selectedText, max: 200) ?? "—",
                        mono: true
                    )
                } else {
                    statusBadge(
                        "Nothing in focus",
                        tint: .secondary,
                        systemImage: "moon.zzz"
                    )
                    Text("No frontmost app, or nothing in focus that Max can read.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }

    // MARK: - Action history

    private var actionHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("Action history", systemImage: "clock.arrow.circlepath")
                Spacer()
                Toggle("Durable only", isOn: $durableOnly)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button("Clear", role: .destructive) { auditLog.clear() }
                    .controlSize(.small)
                    .disabled(auditLog.entries.isEmpty)
            }
            Text("Every action Max executed this session and prior. \"Durable\" filters to ops that wrote state that survives a session — memory, soul patches, settings, downloads — and drops body movement / expressions / walks.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let visible = filteredEntries
            if visible.isEmpty {
                Text(auditLog.entries.isEmpty
                     ? "No actions recorded yet."
                     : "No durable actions in the last session.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(visible) { entry in
                        auditRow(entry)
                    }
                }
            }
        }
    }

    private var filteredEntries: [ActionAuditEntry] {
        let source = auditLog.entries.reversed()
        let filtered = durableOnly ? source.filter(\.durable) : Array(source)
        return Array(filtered.prefix(200))
    }

    private func auditRow(_ entry: ActionAuditEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(timestampLabel(entry.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            Image(systemName: entry.durable ? "circle.fill" : "circle")
                .foregroundStyle(entry.durable ? Color.orange : Color.secondary.opacity(0.4))
                .font(.system(size: 6))
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.op)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                if !entry.argsPreview.isEmpty {
                    Text(entry.argsPreview)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.025)))
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
        }
    }

    private func statusBadge(_ text: String, tint: Color, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.15)))
        .foregroundStyle(tint)
    }

    private func fieldRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: mono ? .monospaced : .default))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func truncated(_ s: String?, max: Int) -> String? {
        guard let s, !s.isEmpty else { return s }
        return s.count > max ? String(s.prefix(max)) + "…" : s
    }

    private func timestampLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
