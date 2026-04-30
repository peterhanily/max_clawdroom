import AppKit
import OSLog
import SwiftUI

/// Read-back surface for max_clawdroom's logs. Plain `os.Logger` calls
/// across the app go to Apple's unified logging system; this panel
/// pulls them back out so users can copy a recent slice into a bug
/// report without learning the `log show` command line.
///
/// macOS exposes its OWN process's log entries via `OSLogStore.local()`
/// without any entitlement. We filter to our subsystem
/// (`com.peterhanily.max_clawdroom`) and render the last hour by default.
@MainActor
struct DiagnosticsPanel: View {
    @State private var lastSnapshot: String = ""
    @State private var snapshotTakenAt: Date?
    @State private var copied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where Max's logs live and how to share them when something breaks.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Live unified log")
                    .font(.system(size: 11, weight: .semibold))
                Text("Subsystem `com.peterhanily.max_clawdroom`. Categories: app, chat, session, memory, settings, soul, voice, autonomy, pet, audio, keychain.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))

            HStack(spacing: 8) {
                Button {
                    Task { await copyRecent(minutes: 60) }
                } label: {
                    Label("Copy last hour", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.borderedProminent)

                Button("Open Console") { openConsole() }
                    .buttonStyle(.bordered)

                Button("Show Application Support folder") { openAppSupport() }
                    .buttonStyle(.bordered)

                Spacer()
            }
            if copied {
                Text("Copied to clipboard.")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            }

            if !lastSnapshot.isEmpty {
                Divider().padding(.vertical, 4)
                Text("Snapshot (\(snapshotTakenAt.map { Self.relative($0) } ?? "")):")
                    .font(.system(size: 11, weight: .semibold))
                ScrollView {
                    Text(lastSnapshot)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 200)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            }
        }
    }

    // MARK: - Actions

    private func copyRecent(minutes: Int) async {
        copied = false
        let snapshot = await Self.readLogs(lastMinutes: minutes)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(snapshot, forType: .string)
        lastSnapshot = snapshot
        snapshotTakenAt = Date()
        copied = true
        // Auto-clear the "Copied" hint after 2.5s so the panel doesn't
        // shout at the user when they look back later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            copied = false
        }
    }

    private func openConsole() {
        // Console.app accepts no documented launch args for filtering,
        // so we just open it. The user can paste the subsystem into the
        // search bar themselves; the explainer above tells them what to
        // type.
        if let url = URL(string: "/System/Applications/Utilities/Console.app").flatMap({ URL(fileURLWithPath: $0.path) }) {
            NSWorkspace.shared.open(url)
        }
    }

    private func openAppSupport() {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Companion", isDirectory: true)
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - OSLogStore reader

    /// Pulls our own process's log entries via OSLogStore. Filtered to
    /// our subsystem, formatted as one line per entry. Last `minutes`
    /// of history. Returns a string suitable for direct paste into a
    /// bug report.
    nonisolated static func readLogs(lastMinutes: Int) async -> String {
        let subsystem = "com.peterhanily.max_clawdroom"
        let since = Date().addingTimeInterval(TimeInterval(-lastMinutes * 60))
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: since)
            let predicate = NSPredicate(format: "subsystem == %@", subsystem)
            let entries = try store.getEntries(at: position, matching: predicate)
            var lines: [String] = []
            let formatter = ISO8601DateFormatter()
            for entry in entries {
                guard let log = entry as? OSLogEntryLog else { continue }
                let level: String
                switch log.level {
                case .debug:    level = "DBG"
                case .info:     level = "INFO"
                case .notice:   level = "NOTE"
                case .error:    level = "ERR "
                case .fault:    level = "FAULT"
                default:        level = "?   "
                }
                let ts = formatter.string(from: log.date)
                lines.append("\(ts) \(level) [\(log.category)] \(log.composedMessage)")
            }
            if lines.isEmpty {
                return "(no log entries in the last \(lastMinutes) minutes)"
            }
            return lines.joined(separator: "\n")
        } catch {
            return "Couldn't read logs: \(error.localizedDescription)"
        }
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
