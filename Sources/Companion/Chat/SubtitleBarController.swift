import AppKit
import SwiftUI

/// TV-mode's alternate output surface: a borderless panel along the
/// bottom of the main screen that renders Max's latest assistant reply in
/// big monospace. Visible only while `mode == .tv`; hidden otherwise.
/// Pure presentation — ignores mouse events, doesn't take focus.
@MainActor
final class SubtitleBarController: NSObject {
    static let barHeight: CGFloat = 80

    private let window: NSPanel
    private let session: ChatSession
    private let theme: ChatTheme
    private let screen: NSScreen
    private var isShowing: Bool = false

    init(session: ChatSession, theme: ChatTheme, screen: NSScreen) {
        self.session = session
        self.theme = theme
        self.screen = screen

        let frame = NSRect(
            x: screen.frame.minX,
            y: screen.frame.minY,
            width: screen.frame.width,
            height: Self.barHeight
        )

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        self.window = panel

        super.init()

        let root = SubtitleBarView(session: session, theme: theme)
        let host = NSHostingView(rootView: root)
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(
            x: 0, y: 0,
            width: frame.width, height: frame.height
        ))
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        panel.contentView = container

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onModeChanged(_:)),
            name: .companionModeChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onAccessibilityChanged),
            name: .companionAccessibilityChanged,
            object: nil
        )
        reconcileVisibility()
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func onModeChanged(_ note: Notification) {
        reconcileVisibility(latestMode: note.userInfo?["mode"] as? String)
    }

    @objc private func onAccessibilityChanged() {
        reconcileVisibility()
    }

    private var cachedMode: String = MaxClawdroomMode.desktop.rawValue

    /// Show the bar when either the mode is `.tv` (the original trigger)
    /// or Prefs.captionOnly is true (accessibility use case). Either
    /// signal alone is enough; neither keeps it hidden.
    private func reconcileVisibility(latestMode: String? = nil) {
        if let m = latestMode { cachedMode = m }
        let wantTV = cachedMode == MaxClawdroomMode.tv.rawValue
        let wantCaption = Prefs.captionOnly
        if wantTV || wantCaption {
            show()
        } else {
            hide()
        }
    }

    private func show() {
        guard !isShowing else { return }
        isShowing = true
        window.orderFrontRegardless()
    }

    private func hide() {
        guard isShowing else { return }
        isShowing = false
        window.orderOut(nil)
    }
}

// MARK: - SwiftUI

private struct SubtitleBarView: View {
    let session: ChatSession
    @ObservedObject var theme: ChatTheme

    /// Caption-only mode is accessibility territory — scale both the "MAX"
    /// tag and the caption body through Dynamic Type so users with larger
    /// system text sizes see bigger captions. Relative-to .title keeps the
    /// headline feel even when scaled up.
    @ScaledMetric(relativeTo: .title) private var maxTagSize: CGFloat = 22
    @ScaledMetric(relativeTo: .title) private var captionBodySize: CGFloat = 26

    private var latestAssistantText: String {
        // While streaming, read the live in-flight display directly.
        // ChatSession's per-chunk pipeline already strips action /
        // system / world / `Human:` tags and writes the cleaned text
        // to streamingDisplayText, so the subtitle ticker matches the
        // chat bubble exactly during a streaming reply.
        if session.isStreaming, !session.streamingDisplayText.isEmpty {
            return ChatSession.stripSystemBlocks(session.streamingDisplayText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for msg in session.messages.reversed() {
            if msg.role == .assistant, case .text(let t) = msg.kind {
                // Defensive belt-and-suspenders. The committed text is
                // already stripped on stream end, but if any tag
                // survives (e.g. a chunk-boundary edge case the
                // streaming stripper missed) we re-run the strip here
                // so the TV-mode marquee never advertises a raw tag
                // that the chat bubble already hid.
                let cleaned = ChatSession.stripSystemBlocks(t)
                let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            Text(MaxClawdroomIdentity.uppercasedDisplayName())
                .font(.system(size: maxTagSize, weight: .bold, design: .monospaced))
                .tracking(4)
                .foregroundStyle(theme.border)
                .shadow(color: theme.border.opacity(0.6), radius: 6)
                .padding(.leading, 28)

            MarqueeText(
                text: latestAssistantText.isEmpty ? "…" : latestAssistantText,
                fontSize: captionBodySize,
                color: theme.text
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.trailing, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.panel)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.border)
                .frame(height: 2)
                .shadow(color: theme.border.opacity(0.6), radius: 6)
        }
        .overlay(scanlines)
    }

    private var scanlines: some View {
        Canvas { ctx, size in
            ctx.opacity = 0.12
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                    with: .color(.black)
                )
                y += 3
            }
        }
        .allowsHitTesting(false)
    }
}

/// News-ticker scroller. Shows `text` statically when it fits the
/// available width; scrolls continuously left-to-right when it doesn't.
/// Two copies of the text are drawn side-by-side with a gap so the
/// loop seam is hidden.
///
/// Text width is measured directly via `NSAttributedString` — the earlier
/// `.background(GeometryReader)` approach inside `.fixedSize` didn't emit
/// a stable value in time to trigger the animation, so long captions just
/// sat truncated. Direct measurement avoids that whole dance.
private struct MarqueeText: View {
    let text: String
    let fontSize: CGFloat
    let color: Color

    /// Drives the scroll animation. Cycles between 0 and -(textWidth + gap).
    @State private var scrollOffset: CGFloat = 0
    /// Animation key — only flips when `text` stops changing for the
    /// settle window. Decouples scroll restarts from per-char streaming
    /// updates. Without this, the typewriter's 30ms-per-char appends
    /// reset the scroll on every keystroke and the marquee never
    /// actually moves.
    @State private var settledText: String = ""
    @State private var settleTask: Task<Void, Never>?

    private static let gap: CGFloat = 60
    /// Pixels-per-second — long captions read comfortably at this speed,
    /// slightly faster than natural reading pace for a news-ticker feel.
    private static let speed: CGFloat = 80
    /// How long after the last text mutation we wait before treating the
    /// caption as "done" and (re)starting the scroll animation. Long
    /// enough to absorb a typewriter stream (28–40ms per char), short
    /// enough that real users don't perceive the pause.
    private static let settleWindow: Duration = .milliseconds(450)

    private var nsFont: NSFont {
        .monospacedSystemFont(ofSize: fontSize, weight: .medium)
    }

    private var swiftUIFont: Font {
        .system(size: fontSize, weight: .medium, design: .monospaced)
    }

    /// Deterministic text width via NSString measurement. Cheap and not
    /// dependent on the view hierarchy resolving its layout pass.
    private func measureWidth() -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: nsFont]
        return (text as NSString).size(withAttributes: attrs).width
    }

    var body: some View {
        GeometryReader { geo in
            let tWidth = measureWidth()
            let overflowing = tWidth + 4 > geo.size.width  // 4pt fudge
            ZStack(alignment: .leading) {
                HStack(spacing: Self.gap) {
                    Text(text)
                        .font(swiftUIFont)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: true, vertical: false)
                    if overflowing {
                        Text(text)
                            .font(swiftUIFont)
                            .foregroundStyle(color)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .offset(x: scrollOffset)
            }
            // Hard-clip via clipShape on a Rectangle PLUS .clipped().
            // Belt + braces — Catalyst-era SwiftUI sometimes ignores
            // `.clipped()` on free-floating HStacks inside GeometryReader,
            // letting the second-copy text bleed past the right edge of
            // the bar when the marquee is mid-cycle. clipShape is more
            // reliable for hit-testing + draw-bounds clamping.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipShape(Rectangle())
            .clipped()
            // Debounce text changes — settledText only catches up after
            // `settleWindow` of quiet, so a streaming typewriter doesn't
            // reset the scroll every char.
            .onChange(of: text, initial: true) { _, newValue in
                settleTask?.cancel()
                settleTask = Task { @MainActor in
                    try? await Task.sleep(for: Self.settleWindow)
                    guard !Task.isCancelled else { return }
                    settledText = newValue
                }
            }
            // Re-key the animation only on settled text or container
            // width changes. `task(id:)` cancels the prior task and
            // starts a fresh one — clean restart, no stacking.
            .task(id: "\(settledText)|\(Int(geo.size.width))") {
                guard overflowing else {
                    scrollOffset = 0
                    return
                }
                scrollOffset = 0
                let distance = tWidth + Self.gap
                let duration = Double(distance) / Double(Self.speed)
                withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                    scrollOffset = -distance
                }
            }
        }
    }
}
