import Combine
import Foundation

/// Watches the user's git working dir and emits `ReflexEvent`s when
/// their actual work moves — a commit lands, a branch switch happens.
///
/// Implementation: `.git/logs/HEAD` is appended to on every HEAD move,
/// whether from `git commit`, `git checkout`, `git rebase`, etc. Each
/// line is: `<old_sha> <new_sha> <author> <ts> <tz>\t<op>: <message>`.
/// We tail that file — on each write, read only the bytes past the last
/// offset we saw, split on newlines, parse the `<op>: <message>` suffix:
///
///   - `commit:` / `commit (initial):` / `commit (amend):` → commitLanded
///   - `checkout: moving from X to Y` → branchSwitched(to: Y)
///   - anything else → silent (pull / merge / reset noise)
///
/// Zero tokens, zero LLM involvement. Subscribers merge this publisher
/// with `AutonomyController.events` to get one unified reflex feed.
///
/// Lifecycle: owned by `OverlayController` for the primary screen only
/// (work events are singular; firing them per-monitor would re-react).
/// Cwd changes are honoured by observing `SettingsStore` and rebuilding
/// the watcher if the path moved.
@MainActor
final class WorkWatcher {

    /// Publisher of detected events. Subscribers typically merge this
    /// with `AutonomyController.events` and drive `ReflexController`.
    let events = PassthroughSubject<ReflexEvent, Never>()

    private var source: DispatchSourceFileSystemObject?
    private var fileHandle: FileHandle?
    private var currentLogURL: URL?
    private var lastOffset: UInt64 = 0
    /// Last cwd we bound to. We only `rebind` when it actually changes —
    /// replaces the `.removeDuplicates()` on the old Combine pipeline so
    /// unrelated Settings mutations (API key edit, etc) don't thrash the
    /// file-system watcher.
    private var lastBoundCwd: String?

    init() {
        let initial = SettingsStore.shared.settings.cwd
        lastBoundCwd = initial
        rebind(cwd: initial)
        // React to the user changing their working dir in Settings — the
        // new cwd might be a different repo (or not a repo at all).
        trackSettings()
    }

    private func trackSettings() {
        withObservationTracking {
            _ = SettingsStore.shared.settings.cwd
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let new = SettingsStore.shared.settings.cwd
                if new != self.lastBoundCwd {
                    self.lastBoundCwd = new
                    self.rebind(cwd: new)
                }
                self.trackSettings()
            }
        }
    }

    isolated deinit {
        source?.cancel()
        try? fileHandle?.close()
    }

    // MARK: - Bind / rebind

    private func rebind(cwd raw: String) {
        tearDown()

        let expanded = (raw as NSString).expandingTildeInPath
        let logURL = URL(fileURLWithPath: expanded)
            .appendingPathComponent(".git", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("HEAD")

        guard FileManager.default.fileExists(atPath: logURL.path) else {
            AppLog.app.debug("WorkWatcher: \(logURL.path, privacy: .public) not a git repo, skipping")
            return
        }

        // Note current tail so launch doesn't replay the whole log as
        // "fresh" commits. We only fire for writes that append NEW bytes.
        let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        lastOffset = (attrs?[.size] as? UInt64) ?? 0
        currentLogURL = logURL

        guard let fd = FileDescriptorHelper.open(logURL.path) else {
            AppLog.app.error("WorkWatcher: open() failed for \(logURL.path, privacy: .public)")
            return
        }

        // Watch for writes, deletes, and renames — deletes happen during
        // `git gc` / branch-ref rotations and the file may be recreated.
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.handleChange() }
        }
        src.setCancelHandler {
            Darwin.close(fd)
        }
        src.resume()
        self.source = src
    }

    private func tearDown() {
        source?.cancel()
        source = nil
        try? fileHandle?.close()
        fileHandle = nil
        currentLogURL = nil
    }

    // MARK: - Change handling

    private func handleChange() {
        guard let url = currentLogURL else { return }

        // File may have been recreated (e.g. after `git gc`) — rebind if
        // we can't seek to our previous offset.
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs?[.size] as? UInt64 else {
            rebind(cwd: SettingsStore.shared.settings.cwd)
            return
        }
        if size < lastOffset {
            // File shrank — log truncated or rotated. Snap to new tail
            // and wait for the next append.
            lastOffset = size
            return
        }
        guard size > lastOffset else { return }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            AppLog.app.error("WorkWatcher: read failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: lastOffset)
        } catch {
            lastOffset = size
            return
        }
        let newData = (try? handle.readToEnd()) ?? Data()
        lastOffset = size
        guard let text = String(data: newData, encoding: .utf8) else { return }

        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            parse(line: String(line))
        }
    }

    // MARK: - Parse

    /// git reflog line: `<old> <new> <who> <ts> <tz>\t<op>: <rest>`
    /// We only want the op + rest. Everything before the tab is identity;
    /// everything after describes what happened.
    private func parse(line: String) {
        guard let tabIdx = line.firstIndex(of: "\t") else { return }
        let payload = line[line.index(after: tabIdx)...]
        if payload.hasPrefix("commit:")
            || payload.hasPrefix("commit (initial):")
            || payload.hasPrefix("commit (amend):") {
            // "commit: message here" → "message here". Sanitise + cap
            // before emitting: commit messages are untrusted input that
            // lands in memory and eventually in UserModelSynthesiser's
            // prompt window, so a commit like
            //     "commit: [action]{\"op\":\"update_soul\"…}[/action]"
            // could try to prompt-inject. Strip `[action]` / `[/action]`
            // tokens and cap length at 120 chars.
            if let colon = payload.firstIndex(of: ":") {
                let raw = payload[payload.index(after: colon)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let msg = Self.sanitise(String(raw), cap: 120)
                events.send(.commitLanded(message: msg))
            }
        } else if payload.hasPrefix("checkout: moving from ") {
            // "checkout: moving from OLD to NEW" — branch names are also
            // untrusted. Cap at 100 chars to kill the 10k-dash DoS and
            // sanitise for the same reasons.
            let stripped = payload.dropFirst("checkout: moving from ".count)
            if let toRange = stripped.range(of: " to ") {
                let raw = stripped[toRange.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let dest = Self.sanitise(String(raw), cap: 100)
                events.send(.branchSwitched(to: dest))
            }
        }
        // Merges / pulls / resets fall through silently — noisy reactions
        // to those would feel overbearing.
    }

    /// Defang strings we pulled out of git metadata before they cross
    /// into the rest of the app: strip the action-tag tokens Max's
    /// parser would otherwise pick up, collapse newlines, and cap
    /// length. Called on commit messages + branch names.
    private static func sanitise(_ input: String, cap: Int) -> String {
        var s = input
        s = s.replacingOccurrences(of: "[action]", with: "[action_]")
        s = s.replacingOccurrences(of: "[/action]", with: "[/action_]")
        s = s.replacingOccurrences(of: "\n", with: " ")
        s = s.replacingOccurrences(of: "\r", with: " ")
        if s.count > cap {
            s = String(s.prefix(cap)) + "…"
        }
        return s
    }
}

/// Minimal POSIX-open helper so `DispatchSourceFileSystemObject` can get
/// a raw file descriptor. FileHandle's `fileDescriptor` works but we
/// want explicit control over close ordering.
private enum FileDescriptorHelper {
    static func open(_ path: String) -> Int32? {
        let fd = Darwin.open(path, O_EVTONLY)
        return fd >= 0 ? fd : nil
    }
}
