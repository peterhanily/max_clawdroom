import AppKit
import ApplicationServices

/// Context scraped from the frontmost app to inject into the `[context]`
/// prompt block. Covers browsers (URL + page title), Finder (current folder),
/// terminals (window title / cwd), and a generic AX window-title fallback
/// for Electron apps like Slack, Notion, Linear, etc.
struct AppContext: Sendable {
    enum Kind: String, Sendable { case browser, finder, terminal, generic }
    let kind: Kind
    let url: String?
    let title: String?
    /// Total open tabs across all browser windows (browsers only).
    /// Lets the agent notice tab clutter without naming every URL.
    let tabCount: Int?

    // Explicit `nonisolated` — the file lives under the package's
    // MainActor default isolation, but `AppContextBridge.fetch*` runs
    // on a Task.detached background thread and constructs values here.
    nonisolated init(kind: Kind, url: String?, title: String?, tabCount: Int? = nil) {
        self.kind = kind
        self.url = url
        self.title = title
        self.tabCount = tabCount
    }
}

enum AppContextBridge {

    // MARK: - App classification

    /// Chromium-based browsers (share the same AppleScript dictionary).
    /// Mapped to a trusted display name — the AppleScript `tell application
    /// "<name>"` addresses by display name, and we must NOT interpolate
    /// `NSRunningApplication.localizedName` directly because any app can set
    /// its own localizedName to a string containing quotes + `do shell script`
    /// and thereby run arbitrary commands under the user when Max scrapes the
    /// browser context. Keys come from trusted bundle IDs only.
    private nonisolated static let chromiumAppNames: [String: String] = [
        "com.google.Chrome":         "Google Chrome",
        "com.google.Chrome.beta":    "Google Chrome Beta",
        "com.google.Chrome.canary":  "Google Chrome Canary",
        "company.thebrowser.Browser": "Arc",
        "com.brave.Browser":         "Brave Browser",
        "com.brave.Browser.beta":    "Brave Browser Beta",
        "com.microsoft.edgemac":     "Microsoft Edge",
        "com.microsoft.edgemac.Beta": "Microsoft Edge Beta",
        "com.operasoftware.Opera":   "Opera",
        "com.vivaldi.Vivaldi":       "Vivaldi",
        "org.chromium.Chromium":     "Chromium",
    ]

    private nonisolated static let safariBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
    ]

    private nonisolated static let finderBundleID = "com.apple.finder"

    private nonisolated static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
    ]

    // MARK: - Main entry point

    /// Fetch context for the given app. Called on a background thread.
    /// Returns nil only when AX permission is missing or nothing useful
    /// is available (e.g. a system app with no focused window).
    ///
    /// `appName` is accepted for backward compat but is IGNORED for AppleScript
    /// targets — we resolve the display name from the trusted bundle ID map
    /// so a hostile app can't inject via `localizedName`.
    nonisolated static func fetch(
        appName: String,
        bundleID: String,
        pid: pid_t
    ) -> AppContext? {
        if let chromiumName = chromiumAppNames[bundleID] {
            return fetchChromiumContext(appName: chromiumName)
        }
        if safariBundleIDs.contains(bundleID) {
            return fetchSafariContext()
        }
        if bundleID == finderBundleID {
            return fetchFinderContext(pid: pid)
        }
        if terminalBundleIDs.contains(bundleID) {
            // Terminal window title typically carries cwd or command.
            return axWindowTitle(pid: pid).map {
                AppContext(kind: .terminal, url: nil, title: $0)
            }
        }
        // Generic fallback: AX window title. Covers Electron apps (Slack,
        // Notion, Linear, Figma, etc.) whose window titles are informative.
        return axWindowTitle(pid: pid).map {
            AppContext(kind: .generic, url: nil, title: $0)
        }
    }

    // MARK: - Browsers

    /// Chromium-based browsers share the same AppleScript dictionary so
    /// we parameterise by app name ("Google Chrome", "Arc", etc.).
    /// Callers MUST pass a name from `chromiumAppNames` — the name is
    /// interpolated into `tell application "…"` and anything but an entry
    /// from our allow-list is an injection surface.
    nonisolated static func fetchChromiumContext(appName: String) -> AppContext? {
        guard chromiumAppNames.values.contains(appName) else { return nil }
        // Returns: <url>\n<title>\n<total-tab-count>. The tab-count line
        // sums tabs across all open windows so a user with 47 tabs
        // sees a single number, not per-window detail.
        let script = """
        tell application "\(appName)"
            if (count windows) > 0 then
                set t to active tab of window 1
                set tc to 0
                repeat with w in windows
                    set tc to tc + (count tabs of w)
                end repeat
                return (URL of t) & "\n" & (title of t) & "\n" & tc
            end if
        end tell
        """
        return parseBrowserResult(osascript(script))
    }

    nonisolated static func fetchSafariContext() -> AppContext? {
        let script = """
        tell application "Safari"
            if (count windows) > 0 then
                set t to current tab of window 1
                set tc to 0
                repeat with w in windows
                    set tc to tc + (count tabs of w)
                end repeat
                return (URL of t) & "\n" & (name of t) & "\n" & tc
            end if
        end tell
        """
        return parseBrowserResult(osascript(script))
    }

    private nonisolated static func parseBrowserResult(_ raw: String?) -> AppContext? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "\n")
        let url = parts.first?.nilIfEmpty
        let title = parts.dropFirst().first.flatMap { $0.nilIfEmpty }
        let tabCount = parts.dropFirst(2).first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard url != nil || title != nil else { return nil }
        return AppContext(kind: .browser, url: url, title: title, tabCount: tabCount)
    }

    // MARK: - Finder

    /// Reads the current Finder window's folder via `kAXDocumentAttribute`,
    /// which returns a `file://` URL of the displayed directory.
    nonisolated static func fetchFinderContext(pid: pid_t) -> AppContext? {
        let axApp = AXUIElementCreateApplication(pid)
        var winRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            axApp, kAXFocusedWindowAttribute as CFString, &winRef
        ) == .success,
              let win = winRef,
              CFGetTypeID(win) == AXUIElementGetTypeID()
        else { return nil }

        var docRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            win as! AXUIElement, kAXDocumentAttribute as CFString, &docRef
        ) == .success,
              let raw = docRef as? String, !raw.isEmpty
        else {
            // No document attribute (Desktop or special windows) — use title.
            return axWindowTitle(pid: pid).map {
                AppContext(kind: .finder, url: nil, title: $0)
            }
        }

        let path: String
        if raw.hasPrefix("file://"), let url = URL(string: raw) {
            path = url.path
        } else {
            path = raw
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let display = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        return AppContext(kind: .finder, url: nil, title: display)
    }

    // MARK: - AX helpers

    nonisolated static func axWindowTitle(pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        var winRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            axApp, kAXFocusedWindowAttribute as CFString, &winRef
        ) == .success,
              let win = winRef,
              CFGetTypeID(win) == AXUIElementGetTypeID()
        else { return nil }
        var titleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            win as! AXUIElement, kAXTitleAttribute as CFString, &titleRef
        ) == .success
        else { return nil }
        return (titleRef as? String)?.nilIfEmpty
    }

    // MARK: - osascript runner

    nonisolated static func osascript(_ source: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
