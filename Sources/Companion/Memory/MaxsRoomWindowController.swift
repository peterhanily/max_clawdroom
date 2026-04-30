import AppKit
import SwiftUI

/// "Max's Room" — the companion's workspace, discoverable from the
/// menu bar. Three sections: recent memories (Max's notebook about the
/// user), soul timeline (how he's changed), time capsules (frozen
/// snapshots of both). A retention / attachment artefact more than a
/// feature — users come back to visit.
@MainActor
final class MaxsRoomWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func present() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(
            rootView: MaxsRoomView()
                .frame(
                    minWidth: 520, idealWidth: 620, maxWidth: 900,
                    minHeight: 480, idealHeight: 600, maxHeight: 1200
                )
        )
        hosting.preferredContentSize = NSSize(width: 620, height: 600)

        let w = NSWindow(contentViewController: hosting)
        w.title = "Max's Room"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.level = .normal
        w.setContentSize(NSSize(width: 620, height: 600))
        w.minSize = NSSize(width: 520, height: 480)
        w.center()
        w.delegate = self
        self.window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - SwiftUI

private struct MaxsRoomView: View {
    // @Observable classes hold by reference through @State. The view
    // only re-renders on the specific properties it reads — a
    // meaningful upgrade over @StateObject's all-or-nothing invalidation
    // when the proxies publish multiple fields.
    @State private var memoryProxy = MemoryProxy()
    @State private var capsulesProxy = CapsulesProxy()
    private let soulHistory = SoulHistory.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                section(
                    title: "Observations",
                    subtitle: "What Max has jotted down about you."
                ) {
                    memoriesPane
                }

                section(
                    title: "Soul timeline",
                    subtitle: "Patches Max has written to himself. Each one shifted him a little."
                ) {
                    soulPane
                }

                section(
                    title: "Session journal",
                    subtitle: "Reflections Max wrote at the end of meaningful chats."
                ) {
                    journalPane
                }

                section(
                    title: "Running threads",
                    subtitle: "Topics Max is keeping an eye on across sessions. Newest update on top."
                ) {
                    threadsPane
                }

                section(
                    title: "Time capsules",
                    subtitle: "Frozen snapshots of who Max is and who he thinks you are. Auto-captured every 90 days; open one to see the past."
                ) {
                    capsulesPane
                }
            }
            .padding(24)
        }
        .background(Color(NSColor.windowBackgroundColor))
        // Tie the observations timer to the view's on-screen lifetime.
        // Previously the proxy polled from init → deinit, but SwiftUI
        // @StateObject lifecycle can outlive window close (rapid open-
        // close cycles accumulate polling timers until the view state
        // finally releases).
        .onAppear { memoryProxy.startPolling() }
        .onDisappear { memoryProxy.stopPolling() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Text("🌝")
                .font(.system(size: 40))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(MaxClawdroomIdentity.possessive()) Room")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                Text("Where he keeps things.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                triggerCapsuleCapture()
            } label: {
                Label("Capture capsule now", systemImage: "camera.aperture")
            }
            .buttonStyle(.bordered)
        }
    }

    private func triggerCapsuleCapture() {
        guard let store = TimeCapsuleStore.shared else { return }
        let mem = MemoryProxy.liveMemoryStore()
        guard let mem else { return }
        store.captureNow(
            userModel: UserModelStore.shared?.model ?? .empty,
            soulPrompt: SettingsStore.shared.settings.systemPrompt,
            memory: mem
        )
    }

    // MARK: - Sections

    private func section<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }

    // MARK: - Memories

    private var memoriesPane: some View {
        Group {
            if memoryProxy.entries.isEmpty {
                emptyRow("No memory entries yet. Chat with Max and entries will accrue here.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(memoryProxy.entries.prefix(20)) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text(entry.promptLine())
                                .font(.system(size: 12, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if memoryProxy.entries.count > 20 {
                        Text("and \(memoryProxy.entries.count - 20) older entries.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
            }
        }
    }

    // MARK: - Soul

    private var soulPane: some View {
        Group {
            if soulHistory.entries.isEmpty {
                emptyRow("No soul edits yet — Max'll write them as he learns about you.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(soulHistory.entries.prefix(8)) { entry in
                        SoulRow(entry: entry)
                    }
                }
            }
        }
    }

    // MARK: - Journal

    /// Filters the live memory feed down to journal entries and groups
    /// them by ISO calendar week. The proxy is the same one Observations
    /// uses, so this view picks up new journals on the next 5 s poll
    /// without its own subscription.
    private var journalPane: some View {
        let journals = memoryProxy.entries.filter { $0.kind == .journal }
        return Group {
            if journals.isEmpty {
                emptyRow("Max writes journal entries when chats run long enough to leave a trace.")
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Self.groupByWeek(journals), id: \.weekKey) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.headline)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            ForEach(group.entries) { entry in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.text)
                                        .font(.system(size: 12))
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(Self.relative(entry.timestamp))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.primary.opacity(0.04))
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private struct WeekGroup {
        let weekKey: String        // sortable: "2026-W17"
        let headline: String       // user-facing: "Week of Apr 21"
        let entries: [MemoryEntry]
    }

    /// Bucket entries by ISO-week (Monday-anchored), produce a stable
    /// sort key + a localised headline. Static so it can be called from
    /// the property body without triggering MainActor capture issues.
    nonisolated private static func groupByWeek(_ entries: [MemoryEntry]) -> [WeekGroup] {
        var cal = Calendar(identifier: .iso8601)
        cal.firstWeekday = 2   // Monday
        let bucketed = Dictionary(grouping: entries) { entry -> String in
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: entry.timestamp)
            return String(
                format: "%04d-W%02d",
                comps.yearForWeekOfYear ?? 0,
                comps.weekOfYear ?? 0
            )
        }
        let fmt = DateFormatter()
        fmt.locale = Locale.autoupdatingCurrent
        fmt.setLocalizedDateFormatFromTemplate("MMM d")
        return bucketed.map { (key, items) -> WeekGroup in
            let firstDate = items.map(\.timestamp).min() ?? Date()
            let monday = cal.dateInterval(of: .weekOfYear, for: firstDate)?.start ?? firstDate
            return WeekGroup(
                weekKey: key,
                headline: "Week of \(fmt.string(from: monday))",
                entries: items.sorted { $0.timestamp > $1.timestamp }
            )
        }
        .sorted { $0.weekKey > $1.weekKey }
    }

    // MARK: - Threads

    /// `.topic` memory entries — agent-named running threads with a
    /// short summary. Multiple entries can share a name (the agent
    /// updates a thread by emitting a fresh `topic` op); we collapse
    /// to one row per unique name showing the LATEST summary, with
    /// the count of updates surfaced as a badge so the user sees how
    /// often Max has revisited it.
    private var threadsPane: some View {
        let topics = memoryProxy.entries.filter { $0.kind == .topic }
        return Group {
            if topics.isEmpty {
                emptyRow("Max hasn't named any running threads yet. He'll start when a topic comes up across more than one chat.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Self.collapseTopics(topics), id: \.name) { thread in
                        threadRow(thread)
                    }
                }
            }
        }
    }

    private func threadRow(_ thread: TopicThread) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(thread.name)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                if thread.updateCount > 1 {
                    Text("\(thread.updateCount) updates")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Color.primary.opacity(0.06))
                        )
                }
                Spacer()
                Text(Self.relative(thread.latestAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(thread.summary)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private struct TopicThread {
        let name: String
        let summary: String
        let latestAt: Date
        let updateCount: Int
    }

    /// Collapse multiple `.topic` entries that share a `key` into one
    /// thread row. Latest entry's summary wins (Max may have refined
    /// the thread); update count surfaces how often the thread has been
    /// revisited. Sorted by latest-touch desc so active threads bubble.
    nonisolated private static func collapseTopics(_ topics: [MemoryEntry]) -> [TopicThread] {
        var byName: [String: [MemoryEntry]] = [:]
        for entry in topics {
            let name = (entry.key ?? "").isEmpty ? "(unnamed)" : (entry.key ?? "")
            byName[name, default: []].append(entry)
        }
        return byName.map { (name, entries) -> TopicThread in
            let sorted = entries.sorted { $0.timestamp > $1.timestamp }
            let latest = sorted.first!     // safe: only here because group is non-empty
            return TopicThread(
                name: name,
                summary: latest.text,
                latestAt: latest.timestamp,
                updateCount: entries.count
            )
        }
        .sorted { $0.latestAt > $1.latestAt }
    }

    // MARK: - Capsules

    private var capsulesPane: some View {
        Group {
            if capsulesProxy.capsules.isEmpty {
                emptyRow("No time capsules captured yet. The first one will appear after 90 days; you can also capture one manually from the header.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(capsulesProxy.capsules.reversed()) { capsule in
                        CapsuleRow(capsule: capsule)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.03))
            )
    }

    private func relative(_ date: Date) -> String {
        Self.relative(date)
    }

    /// Static variant — used by `journalPane` (and indirectly by SoulRow)
    /// without needing to capture the enclosing view.
    nonisolated private static func relative(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Soul row

/// Per-entry view for the soul timeline. Owns its own expand state so
/// rows toggle independently, and surfaces a Revert button gated behind
/// a confirmation dialog — reverting Max's soul is a real change and
/// should require deliberate intent.
private struct SoulRow: View {
    let entry: SoulVersion
    @State private var expanded = false
    @State private var confirmingRevert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(entry.rationale.isEmpty ? "(manual edit)" : entry.rationale)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !entry.patch.isEmpty {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Button("Revert") {
                    confirmingRevert = true
                }
                .controlSize(.mini)
            }
            Text(MaxsRoomViewRelative.relative(entry.appliedAt))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if expanded, !entry.patch.isEmpty {
                Text(entry.patch)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.top, 4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
        .confirmationDialog(
            "Revert Max's soul to before this patch?",
            isPresented: $confirmingRevert,
            titleVisibility: .visible
        ) {
            Button("Revert", role: .destructive) {
                _ = SoulHistory.shared.revert(to: entry.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(entry.rationale.isEmpty
                 ? "This restores the prior soul prompt."
                 : entry.rationale)
        }
    }
}

/// Tiny shim so SoulRow (a `private struct` outside `MaxsRoomView`)
/// can call the same relative-date formatter the view uses without
/// re-implementing it. A free function would do, but routing through
/// a typed enum keeps the namespace clean.
private enum MaxsRoomViewRelative {
    static func relative(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Capsule row

private struct CapsuleRow: View {
    let capsule: TimeCapsule
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(capsule.headline)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            statsLine
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            if expanded {
                Divider()
                    .padding(.vertical, 4)
                if !capsule.userModelSnapshot.isEmpty {
                    Text("Max's view of you:")
                        .font(.system(size: 11, weight: .medium))
                    Text(capsule.userModelSnapshot.promptBlock())
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.bottom, 8)
                }
                if !capsule.soulPrompt.isEmpty {
                    Text("Soul at capture:")
                        .font(.system(size: 11, weight: .medium))
                    Text(capsule.soulPrompt)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(expanded ? nil : 3)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var statsLine: some View {
        let s = capsule.stats
        let parts = [
            "\(s.memoryEntriesTotal) memories",
            "\(s.soulPatchesApplied) patches",
            "\(s.rituals.values.reduce(0, +)) rituals"
        ]
        return Text(parts.joined(separator: " · "))
    }
}

// MARK: - Proxies

/// SwiftUI bridge to whichever live `MemoryStore` the primary overlay
/// owns. The store lives on `ChatSession.memory` — we reach it via a
/// helper that grabs the primary overlay's ChatSession through Settings.
@Observable
@MainActor
final class MemoryProxy {
    var entries: [MemoryEntry] = []
    @ObservationIgnored private var timer: Timer?

    init() {
        refresh()
    }

    isolated deinit { timer?.invalidate() }

    /// Start polling. Called from `MaxsRoomView.onAppear` so the timer
    /// runs only while the window is actually on-screen. Matching
    /// `stopPolling()` goes in `.onDisappear` — previously the timer
    /// started in `init()` and ran until the SwiftUI state released
    /// the proxy, which can outlive window close.
    func startPolling() {
        guard timer == nil else { return }
        // MemoryStore publishes objectWillChange on append; we don't
        // have a direct handle to it here. Polling every 5 s is cheap.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        entries = Self.liveMemoryStore()?.entries.reversed().map { $0 } ?? []
    }

    /// Best-effort lookup of the primary `MemoryStore`. We don't expose
    /// it via a static today; the path through `UserModelStore.shared`
    /// is indirect but stable enough for a diagnostic-ish window.
    static func liveMemoryStore() -> MemoryStore? {
        // Walk the NSApp delegate → the primary overlay → its memory.
        guard let delegate = NSApp.delegate as? AppDelegate else { return nil }
        return delegate.primaryMemoryStore
    }
}

/// Mirror of `TimeCapsuleStore.shared.capsules`. The proxy exists so
/// the Max's Room view can bind to a concrete @Observable surface even
/// when the store is held weakly on AppDelegate.
@Observable
@MainActor
private final class CapsulesProxy {
    var capsules: [TimeCapsule] = []

    init() {
        if let store = TimeCapsuleStore.shared {
            capsules = store.capsules
        }
        trackStore()
    }

    private func trackStore() {
        withObservationTracking {
            _ = TimeCapsuleStore.shared?.capsules
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let store = TimeCapsuleStore.shared {
                    self.capsules = store.capsules
                }
                self.trackStore()
            }
        }
    }
}
