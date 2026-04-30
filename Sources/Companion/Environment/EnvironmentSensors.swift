import AppKit
import Combine
import CoreGraphics
import Foundation
import IOKit
import IOKit.ps

/// Ambient awareness Max carries into every turn: which macOS app the user
/// is focused on, and the time. Injected as a one-line `[env]` prefix on
/// each user message so he can react to context without the user having
/// to spell it out ("you've been in Xcode all afternoon").
///
/// Stays deliberately narrow for the first slice — just frontmost app + clock.
/// Battery, network, screen brightness etc. can layer on later.
@MainActor
final class EnvironmentSensors: ObservableObject {
    @Published private(set) var frontmostApp: String?
    /// Weak ref so the env block can include `mode=` and `register=`.
    /// Wired up by `OverlayController` after both are built.
    weak var modeManager: MaxClawdroomModeManager?
    /// Weak ref for `[editor]` context (document path, cursor line,
    /// selected text). Wired in OverlayController after EditorAwareness
    /// is started.
    weak var editorAwareness: EditorAwareness?

    private var activationObserver: NSObjectProtocol?

    /// Short localised time (e.g. "2:22 PM" in en-US, "14:22" in en-GB).
    /// Using `.short` + the user's locale so the agent sees the format the
    /// user reads clocks in, not a hardcoded 24-hour stamp.
    private let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        f.locale = Locale.autoupdatingCurrent
        return f
    }()
    /// Date key stays `yyyy-MM-dd` with a fixed locale because it's also
    /// a sort key / lookup key in persisted stores (morning-greeting guard,
    /// journal rollups), so it must not vary with user locale.
    private let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // App context cache (browser URL, Finder folder, window title, etc.)
    // Keyed by bundle ID so a switch to a new app invalidates immediately.
    // Refreshed on every app-activation so the cache is warm by the time
    // the user types a message.
    private var appContextCache: (bundleID: String, context: AppContext?, fetchedAt: Date)?
    private var appContextRefreshInFlight = false
    private let appContextTTL: TimeInterval = 5

    // Cached git SHA keyed by cwd. Git shell-out is ~10-30ms on warm FS and
    // would otherwise hit every user turn — refresh async on staleness but
    // serve the cached value sync so `contextSnapshot` stays cheap.
    //
    // Concurrency note: all mutations to gitCache / gitRefreshInFlightCwd
    // happen on MainActor, so no lock is needed. The pattern is classic
    // stale-while-revalidate — callers always get whatever is cached and
    // a background refresh eventually updates it.
    private var gitCache: (cwd: String, sha: String?, fetchedAt: Date)?
    /// The cwd for which a refresh is currently in flight, or nil when no
    /// task is pending. A per-cwd flag (rather than app-wide boolean) lets
    /// a rapid cwd change kick a fresh fetch even while the prior cwd's
    /// task is still running.
    private var gitRefreshInFlightCwd: String?
    private let gitTTL: TimeInterval = 5

    init() {
        updateFrontmost()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateFrontmost()
                self?.refreshAppContext()   // warm the cache before user types
            }
        }
    }

    isolated deinit {
        if let obs = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    private func updateFrontmost() {
        let app = NSWorkspace.shared.frontmostApplication
        // Skip Companion itself — otherwise clicking Max flips frontmost to
        // us and the env block would read "frontmost_app=Companion" on every
        // turn, which teaches him nothing.
        if app?.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        // Sensitive apps + SecureInput: leave the previous frontmost in
        // place rather than naming the password manager / mail / banking
        // app in the prompt. The AX bridge already refuses to read them;
        // hiding the bundle name too is consistent.
        if AccessibilityBridge.frontmostIsSensitive() { return }
        frontmostApp = app?.localizedName
        // Track dwell on the same bundleID — re-anchor only when the
        // bundleID actually changes, so a Cmd-Tab-to-self-and-back
        // doesn't reset the clock. Used by `[context] dwell_s=...`.
        if let bundle = app?.bundleIdentifier {
            if frontmostSince?.bundleID != bundle {
                frontmostSince = (bundle, Date())
            }
        }
    }

    /// Kick off a background fetch of the frontmost app's context (URL,
    /// folder, window title, etc.). Serves stale-while-revalidate so
    /// `contextSnapshot` is never blocked on I/O.
    private func refreshAppContext() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }
        // Skip context fetch for sensitive apps — same denylist as AX.
        if AccessibilityBridge.frontmostIsSensitive() {
            appContextCache = nil
            return
        }
        let bundleID = app.bundleIdentifier ?? ""
        let appName = app.localizedName ?? ""
        let pid = app.processIdentifier
        // Invalidate cache immediately on app switch even before refresh lands.
        if appContextCache?.bundleID != bundleID {
            appContextCache = nil
        }
        guard !appContextRefreshInFlight else { return }
        appContextRefreshInFlight = true
        Task.detached(priority: .utility) {
            let ctx = AppContextBridge.fetch(appName: appName, bundleID: bundleID, pid: pid)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.appContextCache = (bundleID, ctx, Date())
                self.appContextRefreshInFlight = false
            }
        }
    }

    /// One-line snapshot suitable for prepending to a user message.
    /// Example:
    ///   `[env] time=14:22 · part_of_day=afternoon · date=2026-04-19 · frontmost_app="Xcode"`
    ///
    /// Returns empty string when `Prefs.shareEnvBlock` is off so the user
    /// can run Max without broadcasting their activity. `[editor]` and
    /// `[context]` are gated by separate per-block toggles below.
    var contextSnapshot: String {
        guard Prefs.shareEnvBlock else { return "" }
        let now = Date()
        let time = timeFmt.string(from: now)
        let date = dateFmt.string(from: now)

        let hour = Calendar.current.component(.hour, from: now)
        let partOfDay: String
        switch hour {
        case 5..<12:  partOfDay = "morning"
        case 12..<17: partOfDay = "afternoon"
        case 17..<21: partOfDay = "evening"
        default:      partOfDay = "night"
        }

        var parts: [String] = [
            "time=\(time)",
            "part_of_day=\(partOfDay)",
            "date=\(date)"
        ]
        if let app = frontmostApp, !app.isEmpty {
            parts.append("frontmost_app=\"\(Self.sanitiseForPrompt(app))\"")
        }
        if let m = modeManager?.mode {
            parts.append("mode=\(m.rawValue)")
            parts.append("register=\(ModePreset.preset(for: m).registerHint)")
        }
        if let idle = idleDurationSeconds() {
            parts.append("idle_s=\(idle)")
        }
        if let battery = batterySnapshot() {
            parts.append("battery=\(battery)")
        }
        parts.append("displays=\(displaySnapshot())")
        let cwd = SettingsStore.shared.settings.cwd
        if let sha = gitSHA(for: cwd) {
            parts.append("git=\(sha)")
        }
        // Accessibility flags — exposed so Max can self-tune (e.g. go
        // terser + disable heavy visual ops when captionOnly is on).
        let a11y = accessibilitySnapshot()
        if !a11y.isEmpty {
            parts.append(contentsOf: a11y)
        }
        var envLine = "[env] " + parts.joined(separator: " · ")

        // Refresh app context if cache is stale (belt-and-suspenders alongside
        // the activation-observer refresh).
        let appContextStale: Bool = {
            guard let c = appContextCache,
                  let app = NSWorkspace.shared.frontmostApplication,
                  c.bundleID == (app.bundleIdentifier ?? "")
            else { return true }
            return Date().timeIntervalSince(c.fetchedAt) >= appContextTTL
        }()
        if appContextStale { refreshAppContext() }

        let editorCtx = editorAwareness?.context
        // [editor] block — rich code context (path, line, cursor text, selection).
        if Prefs.shareEditorBlock, let ctx = editorCtx {
            envLine += "\n" + formatEditorBlock(ctx)
        }
        // [context] block — browser URL/title, Finder folder, window title for
        // Electron apps, etc. Suppressed when the editor block already carries
        // line-level code context (no point duplicating for Xcode/VSCode) or
        // when the user has opted out of app-context sharing.
        let editorHasCodeContext = editorCtx?.currentLineNumber != nil
        if Prefs.shareAppContextBlock,
           !editorHasCodeContext,
           let block = formatAppContextBlock() {
            envLine += "\n" + block
        }
        // [world] block — outside-of-the-mac grounding. Currently weather;
        // future grist for time-zone / sunrise / events. Behind its own
        // pref (default off) so a fresh install doesn't make a network
        // call to a third-party service unprompted.
        if let snap = WeatherSensor.shared.snapshotForEnvBlock() {
            let safeCondition = Self.sanitiseForPrompt(snap.condition)
            let safeLocation = Self.sanitiseForPrompt(snap.location)
            envLine += "\n[world] weather=\"\(safeCondition)\" temp_c=\(snap.temperatureC) temp_f=\(snap.temperatureF)"
            if !safeLocation.isEmpty {
                envLine += " location=\"\(safeLocation)\""
            }
        }
        return envLine
    }

    /// Accessibility state keyed into the env block so Max can tailor
    /// his behaviour (shorter replies under caption-only, fewer CRT
    /// spectacles under high-contrast, no body flourishes under reduce
    /// motion, etc.). Emits only the flags that are on so the env line
    /// stays terse when nothing's special.
    private func accessibilitySnapshot() -> [String] {
        var parts: [String] = []
        if Prefs.captionOnly { parts.append("caption_only=on") }
        if Prefs.highContrast { parts.append("high_contrast=on") }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || Prefs.sessionReduceMotion {
            parts.append("reduce_motion=on")
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            parts.append("reduce_transparency=on")
        }
        return parts
    }

    /// Seconds since the last HID event at the session level. Rounded to int
    /// because we don't need sub-second resolution in the prompt.
    private func idleDurationSeconds() -> Int? {
        // `kCGAnyInputEventType` isn't exported to Swift; rawValue ~0 picks
        // the catch-all sentinel CG uses internally.
        guard let anyType = CGEventType(rawValue: ~0) else { return nil }
        let secs = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyType)
        guard secs.isFinite, secs >= 0 else { return nil }
        return Int(secs)
    }

    /// Compact battery string, e.g. `"charging:82%"`, `"discharging:47%"`,
    /// `"ac"` when no battery (desktops, docked mini), or nil on failure.
    private func batterySnapshot() -> String? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        if sources.isEmpty { return "ac" }
        guard let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any]
        else { return nil }
        let state = desc[kIOPSPowerSourceStateKey as String] as? String
        let capacity = desc[kIOPSCurrentCapacityKey as String] as? Int
        let max = (desc[kIOPSMaxCapacityKey as String] as? Int) ?? 100
        let pct = capacity.map { Int(Double($0) / Double(max) * 100) }
        let label: String
        switch state {
        case kIOPSACPowerValue:        label = "charging"
        case kIOPSBatteryPowerValue:   label = "discharging"
        default:                       label = state ?? "unknown"
        }
        if let pct { return "\(label):\(pct)%" }
        return label
    }

    /// `"1920x1080"` for single-display, `"3 displays, main 3440x1440"`
    /// otherwise. Keeps the prompt line terse but still signals multi-display
    /// setups (which change the user's spatial context meaningfully).
    private func displaySnapshot() -> String {
        let screens = NSScreen.screens
        let main = NSScreen.main ?? screens.first
        let dims: String
        if let f = main?.frame {
            dims = "\(Int(f.width))x\(Int(f.height))"
        } else {
            dims = "unknown"
        }
        if screens.count <= 1 { return dims }
        return "\(screens.count) displays, main \(dims)"
    }

    /// Short git SHA for the configured cwd, served from a 5s cache. First
    /// call (or cwd change) returns nil and kicks off a background refresh;
    /// subsequent calls within TTL return the cached value without forking.
    private func gitSHA(for cwd: String) -> String? {
        let now = Date()
        if let c = gitCache, c.cwd == cwd, now.timeIntervalSince(c.fetchedAt) < gitTTL {
            return c.sha
        }
        // Kick a refresh if nothing is running OR if the inflight task is
        // for a different cwd (the user changed the working dir in
        // Settings between ticks). The prior task completes harmlessly
        // — its writeback matches on captured cwd so it won't clobber
        // the newer cwd's eventual result.
        if gitRefreshInFlightCwd != cwd {
            gitRefreshInFlightCwd = cwd
            let capturedCwd = cwd
            Task.detached(priority: .utility) {
                let sha = Self.runGitSHA(cwd: capturedCwd)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.gitCache = (capturedCwd, sha, Date())
                    // Only clear the inflight flag if nobody else has
                    // already overwritten it with a newer cwd.
                    if self.gitRefreshInFlightCwd == capturedCwd {
                        self.gitRefreshInFlightCwd = nil
                    }
                }
            }
        }
        // Serve stale-but-same-cwd cache rather than nil while refreshing.
        if let c = gitCache, c.cwd == cwd { return c.sha }
        return nil
    }

    nonisolated private static func runGitSHA(cwd: String) -> String? {
        // Defense-in-depth: `Process.arguments` is an argv array (no shell
        // involvement) so literal metacharacters can't escape into a
        // subshell, but validate the cwd anyway so a future code path
        // where cwd becomes agent-writable doesn't regress.
        //
        // We require:
        //   - absolute path (relative cwds resolve against the app's own
        //     working directory, which is rarely what the user meant)
        //   - no control characters or newlines (would confuse git's own
        //     arg parser and have no legitimate use in a project path)
        //   - leading char isn't `-` (git would treat it as an option)
        //   - the path actually exists as a directory
        guard isSafeCwd(cwd) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git", "-C", cwd, "rev-parse", "--short", "HEAD"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let sha = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (sha?.isEmpty ?? true) ? nil : sha
    }

    /// Whitelist-style check for paths we're willing to hand to git/-C.
    /// Rejects anything that could surprise an argv parser downstream,
    /// plus non-existent or non-directory paths (no point shelling out).
    nonisolated private static func isSafeCwd(_ path: String) -> Bool {
        guard !path.isEmpty, path.hasPrefix("/") else { return false }
        guard !path.hasPrefix("-") else { return false }
        for scalar in path.unicodeScalars {
            // ASCII control chars (incl. \n, \r, \t, NUL) never belong
            // in a project path; reject outright.
            if scalar.value < 0x20 || scalar.value == 0x7F { return false }
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }

    private func formatEditorBlock(_ ctx: AccessibilityBridge.EditorContext) -> String {
        var editorParts: [String] = ["app=\"\(Self.sanitiseForPrompt(ctx.appName))\""]
        if let path = ctx.documentPath, !path.isEmpty {
            editorParts.append("file=\"\(Self.sanitiseForPrompt(path))\"")
        }
        if let line = ctx.currentLineNumber {
            editorParts.append("line=\(line)")
        }
        var block = "[editor] " + editorParts.joined(separator: " · ")

        // Short, sanitised line text on its own line so commas / quotes
        // inside code don't corrupt the parse. Secrets are redacted before
        // leaving the process.
        if let text = ctx.currentLineText {
            let oneLine = Self.sanitiseForPrompt(Self.redactSecrets(text))
                .replacingOccurrences(of: "\n", with: "⏎")
            block += "\n  cursor_line: \(oneLine)"
        }
        if let sel = ctx.selectedText, !sel.isEmpty {
            let short = sel.count > 300 ? String(sel.prefix(300)) + "…" : sel
            let oneLine = Self.sanitiseForPrompt(Self.redactSecrets(short))
                .replacingOccurrences(of: "\n", with: "⏎")
            block += "\n  selection: \(oneLine)"
        }
        return block
    }

    /// Replace common secret shapes in a string with a `[REDACTED]` marker
    /// before it lands in the agent's prompt. Patterns cover: OpenAI / Claude
    /// / GitHub token prefixes, generic bearer tokens, assignments of keys /
    /// passwords / secrets, and any long hex/base64-ish string that's almost
    /// certainly an API key. Conservative — false positives (redacting a
    /// harmless hash) are preferable to leaking real credentials.
    fileprivate static func redactSecrets(_ input: String) -> String {
        guard let regex = secretRedactionRegex else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(
            in: input, options: [], range: range,
            withTemplate: "[REDACTED]"
        )
    }

    private static let secretRedactionRegex: NSRegularExpression? = {
        // Vendor-prefixed tokens: sk-…, sk-ant-…, ghp_…, github_pat_…,
        // xoxb-… (Slack), AKIA… (AWS key IDs). Conservative length cap so
        // "sk-learn" style unrelated strings don't trip.
        let vendorTokens = "(?:sk-ant-|sk-|ghp_|gho_|ghu_|ghs_|ghr_|github_pat_|xoxb-|xoxp-|AKIA)[A-Za-z0-9_\\-]{16,}"
        // Bearer in headers or env dumps.
        let bearer = "(?i)bearer\\s+[A-Za-z0-9_\\.\\-=]{12,}"
        // Assignments like API_KEY=abcdef…, password: "hunter2" etc. We
        // redact the value part; key left intact so the prompt still
        // signals "there's a secret here" without the actual bytes.
        let assignment = "(?i)(api[-_]?key|api[-_]?secret|access[-_]?token|auth[-_]?token|secret|password|passwd|pwd)\\s*[:=]\\s*[\"']?[A-Za-z0-9_\\-\\.\\/+=]{8,}[\"']?"
        let pattern = [vendorTokens, bearer, assignment].joined(separator: "|")
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Format the cached app context as a `[context]` prompt block.
    /// Returns nil when the cache is empty or carries nothing useful.
    private func formatAppContextBlock() -> String? {
        guard let cached = appContextCache, let ctx = cached.context else { return nil }
        var parts: [String] = ["type=\(ctx.kind.rawValue)"]
        switch ctx.kind {
        case .browser:
            if let url = ctx.url    { parts.append("url=\"\(Self.sanitiseForPrompt(url))\"") }
            if let title = ctx.title { parts.append("title=\"\(Self.sanitiseForPrompt(String(title.prefix(120))))\"") }
            if let n = ctx.tabCount { parts.append("tabs=\(n)") }
        case .finder:
            if let title = ctx.title { parts.append("folder=\"\(Self.sanitiseForPrompt(title))\"") }
        case .terminal:
            if let title = ctx.title { parts.append("window=\"\(Self.sanitiseForPrompt(String(title.prefix(120))))\"") }
        case .generic:
            if let title = ctx.title { parts.append("window=\"\(Self.sanitiseForPrompt(String(title.prefix(120))))\"") }
        }
        // Dwell time on the current frontmost context — derived from the
        // activation observer below. Lets the agent observe "user has
        // been on this Stack Overflow page 12 minutes" and proactively
        // offer help via the autonomy ping path.
        if let dwell = currentFrontmostDwellSeconds(), dwell >= 30 {
            parts.append("dwell_s=\(dwell)")
        }
        guard parts.count > 1 else { return nil }   // only type= — nothing useful
        return "[context] " + parts.joined(separator: " · ")
    }

    /// `(bundleID, sinceWhen)` of the currently frontmost app — refreshed
    /// in `updateFrontmost`. Used for the `dwell_s` field in [context].
    /// Nil during the gap between launch and the first activation event.
    private var frontmostSince: (bundleID: String, at: Date)?

    /// Whole seconds the same bundleID has been frontmost. Returns nil
    /// when we have no record yet (cold start) or the bundleID changed
    /// in the same tick we're rendering — both cases the agent sees no
    /// dwell signal, which is correct.
    private func currentFrontmostDwellSeconds() -> Int? {
        guard let f = frontmostSince,
              let now = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              f.bundleID == now
        else { return nil }
        return Int(Date().timeIntervalSince(f.at))
    }

    /// Neutralise content we pulled from other apps (browser titles, URLs,
    /// window titles, editor text) OR content that agent-written memory
    /// echoes back into the prompt — before it lands in the next turn's
    /// system prompt. A hostile webpage / malicious memory write can
    /// embed `[action]{"op":"…"}[/action]`, or mimic the system-context
    /// tags the harness injects (`[env]`, `[memory]`, `[you]`, etc.), or
    /// break out of a single line with a raw newline and start writing
    /// instructions as if they were from the harness. This function:
    ///
    /// 1. Defangs `[action]`/`[/action]` so the action parser can't see
    ///    a tag someone else authored.
    /// 2. Defangs every known system-context tag (env/memory/you/persona/
    ///    soul/user) — match is case-INSENSITIVE because the strip layer
    ///    on the output side is also case-insensitive; asymmetric rules
    ///    would leak.
    /// 3. Escapes raw newlines to `⏎` so a value can't introduce a new
    ///    prompt line that looks like a harness directive. The visible
    ///    glyph preserves the information for humans + the model.
    /// 4. Escapes double-quotes so values inside `field="…"` don't
    ///    terminate the quoted region early.
    static func sanitiseForPrompt(_ raw: String) -> String {
        var s = raw
        // Tag set — MUST match the stripSystemBlocks list in ChatSession.
        // Each needs both open + close forms defanged.
        let tags = ["action", "env", "memory", "you", "persona", "soul", "user", "context", "editor"]
        for tag in tags {
            s = s.replacingOccurrences(
                of: "[\(tag)]", with: "[\(tag)_]", options: .caseInsensitive
            )
            s = s.replacingOccurrences(
                of: "[/\(tag)]", with: "[/\(tag)_]", options: .caseInsensitive
            )
        }
        s = s.replacingOccurrences(of: "\"", with: "'")
        // Prompt-line-break defense.
        s = s.replacingOccurrences(of: "\r\n", with: "⏎")
        s = s.replacingOccurrences(of: "\n", with: "⏎")
        s = s.replacingOccurrences(of: "\r", with: "⏎")
        return s
    }
}
