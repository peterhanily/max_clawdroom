import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Typed accessors over the raw AX C API. Returns Cocoa-space (bottom-left
/// origin, y goes up) rectangles so they compose naturally with NSScreen /
/// overlay scene coordinates.
enum AccessibilityBridge {

    /// Bundle-IDs we never read AX from, period. Password managers, system
    /// keychain, mail clients, terminals, banking-style apps. The captured
    /// data here (cursor lines, selections, document paths) would land in
    /// the system prompt and persist to memory / sessions / soul-history;
    /// none of that is acceptable for these surfaces.
    ///
    /// Match is exact on bundleIdentifier OR substring on bundleIdentifier
    /// for prefixes (e.g. all `com.apple.Terminal*` variants). Conservative:
    /// false positives mean Max sees nothing in those apps, which is the
    /// safe default. Users can extend via `Prefs.shareEditor`/`shareEnv`.
    private static let sensitiveBundleIDs: Set<String> = [
        // Password managers
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword4",
        "com.1password.1password",
        "com.1password.1password-launcher",
        "com.lastpass.LastPass",
        "com.dashlane.Dashlane",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "io.kee.KeePassXC",
        "org.keepassxc.keepassxc",
        // Mail
        "com.apple.mail",
        "com.microsoft.Outlook",
        "com.airmailapp.airmail2",
        "com.readdle.smartemail-Mac",
        "com.superhuman.electron",
        // Terminals — agent already knows what's running, but its
        // contents (commands, secrets pasted) are off-limits.
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "co.zeit.hyper",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "dev.warp.Warp-Stable",
        // Banking / financial
        "com.intuit.mint",
        "com.intuit.QuickBooksMacDesktop",
        "com.ynab.YNAB",
        // Secure messaging
        "org.whispersystems.signal-desktop",
        "im.riot.Riot"
    ]
    private static let sensitiveBundlePrefixes: [String] = [
        "com.apple.Keychain",
        "com.apple.Terminal",
        "com.googlecode.iterm",
        "com.1password.",
        "com.agilebits.",
        "com.lastpass.",
        "com.bitwarden."
    ]

    /// Returns true when the frontmost app is on the sensitive denylist
    /// OR macOS reports a SecureInput field is currently active anywhere
    /// (banking site password fields, sudo prompts in unrelated terminals,
    /// FileVault unlock, etc).
    static func frontmostIsSensitive() -> Bool {
        if IsSecureEventInputEnabled() { return true }
        return isSensitiveBundle(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// Pure denylist verdict for a given bundle ID. Extracted from
    /// `frontmostIsSensitive` so tests can exercise the matching logic
    /// against synthetic bundle IDs without touching `NSWorkspace`
    /// (which is global, async-mutable, and effectively un-mockable
    /// in unit tests). nil / empty bundle returns false — neither is a
    /// real app and we'd rather leak nothing than mis-classify.
    static func isSensitiveBundle(_ bundle: String?) -> Bool {
        guard let bundle, !bundle.isEmpty else { return false }
        if sensitiveBundleIDs.contains(bundle) { return true }
        for prefix in sensitiveBundlePrefixes where bundle.hasPrefix(prefix) {
            return true
        }
        return false
    }
    struct EditorSnapshot {
        let appName: String
        let pid: pid_t
        /// Cocoa-space global rect — bottom-left origin, y-up.
        let windowRect: CGRect
    }

    /// Pixel bounds of a single source line in the frontmost editor,
    /// in Cocoa-space global coordinates.
    struct LineSnapshot {
        let editor: EditorSnapshot
        let lineRect: CGRect
        let lineNumber: Int
    }

    /// Higher-level editor context for the `[editor]` system-prompt block.
    /// Every field is best-effort — missing ones come back nil. Electron
    /// editors (VSCode, Cursor) typically surface only `appName` and
    /// `documentPath`; native editors (Xcode, Nova, BBEdit) give the
    /// full set. Selection text is capped to 1 KB to keep the prompt
    /// sane for pathological selections.
    struct EditorContext {
        let appName: String
        let documentPath: String?
        let currentLineNumber: Int?
        let currentLineText: String?
        let selectedText: String?
    }

    /// Snapshot of the frontmost application's focused window — in Cocoa
    /// coordinates. Returns nil if AX permission is missing, no frontmost
    /// app, or we can't resolve a window.
    static func snapshotFrontmostEditor() -> EditorSnapshot? {
        guard AccessibilityPermission.isTrusted else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        // Don't track ourselves.
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }
        // Sensitive apps (password managers, mail, terminals, banking) +
        // any window with SecureInput active are off-limits — what they
        // expose to AX would land in the system prompt and persist.
        if frontmostIsSensitive() { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var focusedWindowRef: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            axApp,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowRef
        )
        guard result == .success,
              let windowValue = focusedWindowRef,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else { return nil }
        let window = windowValue as! AXUIElement

        var positionRef: AnyObject?
        var sizeRef: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef)
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)

        guard
            let posV = positionRef,
            let sizV = sizeRef,
            CFGetTypeID(posV) == AXValueGetTypeID(),
            CFGetTypeID(sizV) == AXValueGetTypeID()
        else { return nil }

        var axPosition = CGPoint.zero
        var axSize = CGSize.zero
        if !AXValueGetValue(posV as! AXValue, .cgPoint, &axPosition) { return nil }
        if !AXValueGetValue(sizV as! AXValue, .cgSize, &axSize) { return nil }

        let axRect = CGRect(origin: axPosition, size: axSize)
        guard let cocoa = cocoaRect(fromAXRect: axRect) else { return nil }

        return EditorSnapshot(
            appName: app.localizedName ?? "Unknown",
            pid: app.processIdentifier,
            windowRect: cocoa
        )
    }

    /// Convert an AX rectangle (top-left origin of the primary display)
    /// to Cocoa global coordinates (bottom-left origin of the primary
    /// display).
    ///
    /// **Why only the primary screen height is needed.** Both coord
    /// systems are anchored to the primary display: AX y=0 is the top
    /// of primary, Cocoa y=0 is the bottom of primary. The transform is
    /// purely vertical and only depends on `primaryHeight`. Rectangles
    /// on secondary displays (negative y for displays above primary,
    /// y > primaryHeight for displays below) Just Work — `axY < 0`
    /// produces `cocoaY > primaryHeight` (above primary in Cocoa) and
    /// `axY > primaryHeight` produces `cocoaY < 0` (below primary in
    /// Cocoa), which is exactly right since both spaces share the same
    /// reference frame.
    ///
    /// `cocoa_y = primary_height - ax_y - rect_height`
    ///
    /// The pure math is in `cocoaRect(fromAXRect:primaryScreenHeight:)`
    /// so tests can exercise multi-display geometries without touching
    /// the real `NSScreen.screens` array (which is global, headless-
    /// hostile, and effectively un-mockable in unit tests).
    static func cocoaRect(fromAXRect axRect: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        return cocoaRect(fromAXRect: axRect, primaryScreenHeight: primary.frame.height)
    }

    /// Pure-math AX→Cocoa transform. Same formula as the live entry
    /// point, parameterised on `primaryScreenHeight` so tests can pin
    /// the contract under synthetic display geometries.
    static func cocoaRect(
        fromAXRect axRect: CGRect,
        primaryScreenHeight: CGFloat
    ) -> CGRect {
        let cocoaY = primaryScreenHeight - axRect.origin.y - axRect.size.height
        return CGRect(
            x: axRect.origin.x,
            y: cocoaY,
            width: axRect.size.width,
            height: axRect.size.height
        )
    }

    // MARK: - Line-level queries

    /// Returns the bounds of the line containing the current cursor (or
    /// selection start) in the frontmost editor. Works in Xcode and most
    /// AppKit text editors; Electron editors may return nil if their AX
    /// layer doesn't expose the parameterized text attributes.
    static func snapshotCursorLine() -> LineSnapshot? {
        guard AccessibilityPermission.isTrusted else { return nil }
        guard let editor = snapshotFrontmostEditor() else { return nil }
        let axApp = AXUIElementCreateApplication(editor.pid)

        guard let element = focusedTextElement(of: axApp) else { return nil }

        var rangeRef: AnyObject?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
            ) == .success,
            let rv = rangeRef,
            CFGetTypeID(rv) == AXValueGetTypeID()
        else { return nil }

        // Bounds of the current selection / cursor position
        let rangeValue = rv as! AXValue
        guard let axBounds = boundsForRange(element: element, rangeValue: rangeValue) else { return nil }
        guard let cocoa = cocoaRect(fromAXRect: axBounds) else { return nil }

        // Extract line number for return value
        var cursorRange = CFRange(location: 0, length: 0)
        _ = AXValueGetValue(rangeValue, .cfRange, &cursorRange)
        let lineNumber = lineNumber(element: element, charIndex: cursorRange.location) ?? 0

        return LineSnapshot(editor: editor, lineRect: cocoa, lineNumber: lineNumber + 1)
    }

    /// Returns the bounds of line `line` (1-indexed) in the frontmost editor.
    static func snapshotLine(_ line: Int) -> LineSnapshot? {
        guard AccessibilityPermission.isTrusted else { return nil }
        guard let editor = snapshotFrontmostEditor() else { return nil }
        let axApp = AXUIElementCreateApplication(editor.pid)

        guard let element = focusedTextElement(of: axApp) else { return nil }

        var lineIndex: CFIndex = CFIndex(max(0, line - 1))
        guard
            let cfLineNum = CFNumberCreate(nil, .cfIndexType, &lineIndex)
        else { return nil }

        var rangeRef: AnyObject?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXRangeForLineParameterizedAttribute as CFString,
                cfLineNum,
                &rangeRef
            ) == .success,
            let rv = rangeRef,
            CFGetTypeID(rv) == AXValueGetTypeID()
        else { return nil }

        guard
            let axBounds = boundsForRange(element: element, rangeValue: rv as! AXValue),
            let cocoa = cocoaRect(fromAXRect: axBounds)
        else { return nil }

        return LineSnapshot(editor: editor, lineRect: cocoa, lineNumber: line)
    }

    // MARK: - Editor context for system prompt

    /// Snapshot the frontmost editor's active document, cursor line, and
    /// selection. Returns nil only if AX permission is missing or there
    /// is no frontmost non-Companion app; otherwise returns a context
    /// with whatever fields could be resolved.
    static func snapshotEditorContext() -> EditorContext? {
        guard AccessibilityPermission.isTrusted else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }
        if frontmostIsSensitive() { return nil }

        let appName = app.localizedName ?? "Unknown"
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        let documentPath = readDocumentPath(axApp: axApp)

        guard let element = focusedTextElement(of: axApp) else {
            return EditorContext(
                appName: appName,
                documentPath: documentPath,
                currentLineNumber: nil,
                currentLineText: nil,
                selectedText: nil
            )
        }

        let fullText = readString(element: element, attribute: kAXValueAttribute)
        let selRange = readSelectedRange(element: element)

        var lineNumber: Int? = nil
        var currentLineText: String? = nil
        var selectedText: String? = nil

        if let selRange {
            lineNumber = lineNumberForCharIndex(element: element, charIndex: selRange.location)
                .map { $0 + 1 }
            if let fullText {
                currentLineText = extractLine(around: selRange.location, in: fullText)
                if selRange.length > 0 {
                    selectedText = extractUTF16Slice(
                        of: fullText,
                        location: selRange.location,
                        length: selRange.length
                    ).map { String($0.prefix(1024)) }
                }
            }
        }

        return EditorContext(
            appName: appName,
            documentPath: documentPath,
            currentLineNumber: lineNumber,
            currentLineText: currentLineText,
            selectedText: selectedText
        )
    }

    private static func readDocumentPath(axApp: AXUIElement) -> String? {
        var winRef: AnyObject?
        guard
            AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
            let win = winRef,
            CFGetTypeID(win) == AXUIElementGetTypeID()
        else { return nil }
        let window = win as! AXUIElement
        var docRef: AnyObject?
        guard
            AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &docRef) == .success,
            let raw = docRef as? String
        else { return nil }
        // Xcode returns a file:// URL; VSCode / Nova return plain paths.
        if raw.hasPrefix("file://"), let url = URL(string: raw) {
            return url.path
        }
        return raw
    }

    private static func readString(element: AXUIElement, attribute: String) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func readSelectedRange(element: AXUIElement) -> CFRange? {
        var rangeRef: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
            let rv = rangeRef,
            CFGetTypeID(rv) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rv as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func lineNumberForCharIndex(element: AXUIElement, charIndex: CFIndex) -> Int? {
        lineNumber(element: element, charIndex: charIndex)
    }

    /// Extract the line of text surrounding a UTF-16 code-unit offset.
    /// AX ranges are UTF-16 indexed; we bridge to `String.utf16View` for
    /// safe slicing.
    private static func extractLine(around utf16Offset: CFIndex, in text: String) -> String? {
        let count = text.utf16.count
        let clamped = max(0, min(Int(utf16Offset), count))
        guard let cursor = text.utf16.index(text.utf16.startIndex, offsetBy: clamped, limitedBy: text.utf16.endIndex)
        else { return nil }
        guard let cursorCharIdx = cursor.samePosition(in: text) else { return nil }

        // Walk backward to the start of the line (after the previous newline).
        let lineStart: String.Index = {
            if let nl = text[..<cursorCharIdx].lastIndex(of: "\n") {
                return text.index(after: nl)
            }
            return text.startIndex
        }()
        // And forward to just before the next newline.
        let lineEnd: String.Index = {
            if let nl = text[cursorCharIdx...].firstIndex(of: "\n") {
                return nl
            }
            return text.endIndex
        }()
        let line = String(text[lineStart..<lineEnd])
        // Cap at 400 chars — prevents prompt bloat on minified single-line files.
        return line.count > 400 ? String(line.prefix(400)) + "…" : line
    }

    private static func extractUTF16Slice(
        of text: String,
        location: CFIndex,
        length: CFIndex
    ) -> String? {
        let count = text.utf16.count
        let start = max(0, min(Int(location), count))
        let end = max(start, min(Int(location + length), count))
        guard
            let si = text.utf16.index(text.utf16.startIndex, offsetBy: start, limitedBy: text.utf16.endIndex),
            let ei = text.utf16.index(text.utf16.startIndex, offsetBy: end, limitedBy: text.utf16.endIndex),
            let siChar = si.samePosition(in: text),
            let eiChar = ei.samePosition(in: text)
        else { return nil }
        return String(text[siChar..<eiChar])
    }

    // MARK: - Helpers

    private static func focusedTextElement(of axApp: AXUIElement) -> AXUIElement? {
        var focusedRef: AnyObject?
        guard
            AXUIElementCopyAttributeValue(
                axApp,
                kAXFocusedUIElementAttribute as CFString,
                &focusedRef
            ) == .success,
            let focused = focusedRef,
            CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        return (focused as! AXUIElement)
    }

    private static func boundsForRange(
        element: AXUIElement,
        rangeValue: AXValue
    ) -> CGRect? {
        var boundsRef: AnyObject?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeValue,
                &boundsRef
            ) == .success,
            let bv = boundsRef,
            CFGetTypeID(bv) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bv as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func lineNumber(element: AXUIElement, charIndex: CFIndex) -> Int? {
        var idx = charIndex
        guard let cfNum = CFNumberCreate(nil, .cfIndexType, &idx) else { return nil }
        var lineRef: AnyObject?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXLineForIndexParameterizedAttribute as CFString,
                cfNum,
                &lineRef
            ) == .success,
            let ln = lineRef,
            CFGetTypeID(ln) == CFNumberGetTypeID()
        else { return nil }
        var num: Int = 0
        guard CFNumberGetValue(ln as! CFNumber, .intType, &num) else { return nil }
        return num
    }
}
