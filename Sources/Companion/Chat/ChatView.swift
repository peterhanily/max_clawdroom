import AppKit
import SwiftUI

struct ChatBubbleView: View {
    let session: ChatSession
    @ObservedObject var theme: ChatTheme
    @ObservedObject var tour: TourController
    @ObservedObject var presence: ChatBubblePresence
    var tint: Color
    var undoStack: UndoStack
    var onSubmit: (String) -> Void

    @State private var input: String = ""
    @State private var modIndicatorVisible: Bool = false
    @State private var modFlashID: UUID = UUID()
    @State private var cursorBlinkOn: Bool = true
    @State private var isRevealed: Bool = false
    @State private var bootFlashVisible: Bool = false
    @State private var isClosing: Bool = false
    /// Last time we auto-scrolled during streaming. Throttle to ~5Hz so
    /// token bursts don't stack animations and look jittery.
    @State private var lastAutoscrollAt: Date = .distantPast
    /// IDs of tool-call messages whose output section is currently expanded.
    @State private var expandedResults: Set<UUID> = []
    /// Forced redraw key for the voice toggle — Prefs.voiceEnabled isn't
    /// Combine-observable, so we bump this on every notification arrival.
    @State private var voiceTick: UUID = UUID()
    @FocusState private var inputFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Dynamic-Type-aware baseline for the main chat body text. All the
    /// hardcoded `.system(size: 13, ...)` call sites feed off this +
    /// `scaledDelta(N)` so the entire chat chrome scales together.
    @ScaledMetric(relativeTo: .body) private var bodyFontSize: CGFloat = 13

    /// Scale a hardcoded pixel size relative to the 13pt body baseline.
    /// Keeps the header ("MAX", the ▸/> glyphs, tool-call labels) in the
    /// same proportion as the body as the user bumps Dynamic Type up.
    private func scaled(_ size: CGFloat) -> CGFloat {
        let ratio = bodyFontSize / 13
        return size * ratio
    }

    /// Plain NSTimer holder for the cursor blink. Earlier this was a
    /// Combine `Timer.publish(...).autoconnect()` publisher, but on
    /// macOS 26.x every emission routed through
    /// `swift_task_isCurrentExecutorWithFlagsImpl` (the broken
    /// executor probe) on the SwiftUI body re-render, intermittently
    /// crashing inside `closure #5 in ChatBubbleView.body.getter`.
    /// `Timer.scheduledTimer` with a plain block callback skips the
    /// Combine pipeline and the actor check entirely.
    @State private var cursorTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)

            hairlineDivider

            messagesList
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            hairlineDivider

            inputBar
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .background(bubbleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(scanlineOverlay)
        .overlay(panelBorder)
        .overlay(bootFlashOverlay)
        // Reduce Transparency: pin shadow opacity high so the bubble
        // reads as solid chrome instead of fading into the desktop.
        .shadow(
            color: .black.opacity(reduceTransparency ? 0.85 : 0.45),
            radius: reduceTransparency ? 16 : 32,
            x: 0, y: 14
        )
        .shadow(
            color: theme.border.opacity(reduceTransparency ? 0.55 : 0.22),
            radius: reduceTransparency ? 10 : 18,
            x: 0, y: 0
        )
        .textSelection(.enabled)
        .overlay(undoHotkeyCatcher)
        // CRT boot reveal: thin horizontal slit → vertical sweep to full
        // height. Anchor on bottom so the bubble reads as "emerging from"
        // Max when it's placed above him. Reduce-motion skips the
        // animation and just shows the bubble.
        .scaleEffect(
            x: isRevealed || reduceMotion ? 1.0 : 0.88,
            y: isRevealed || reduceMotion ? 1.0 : 0.04,
            anchor: .bottom
        )
        .opacity(isRevealed || reduceMotion ? 1.0 : 0.0)
        .onAppear {
            inputFocused = true
            revealBubble()
        }
        // Escape aborts the tour if one is running, otherwise closes the
        // bubble. Tour-skip was click-only before — keyboard users had no
        // way out without grabbing the mouse.
        .onExitCommand {
            if tour.isActive {
                tour.skip()
            } else {
                requestClose()
            }
        }
        .onReceive(undoStack.pushes) { _ in
            flashModIndicator()
        }
        .onAppear {
            // Plain NSTimer block callback. Scheduled from main run
            // loop (.onAppear is @MainActor); the block fires on the
            // same run loop. Plain DispatchQueue.main.async hop into
            // the @State mutation — no Task, no Combine, no
            // MainActor.assumeIsolated, none of which run the actor
            // probe that crashes on macOS 26.x.
            cursorTimer?.invalidate()
            cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                DispatchQueue.main.async {
                    cursorBlinkOn.toggle()
                }
            }
        }
        .onDisappear {
            cursorTimer?.invalidate()
            cursorTimer = nil
        }
        .onChange(of: presence.isOpen) { _, open in
            if !open { startCloseAnimation() }
        }
    }

    /// Brief cyan glow overlay during the boot reveal — the CRT "turn-on
    /// line" flash. Fades in fast then out.
    @ViewBuilder
    private var bootFlashOverlay: some View {
        if bootFlashVisible && !reduceMotion {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            theme.assistant.opacity(0.0),
                            theme.assistant.opacity(0.45),
                            theme.assistant.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func revealBubble() {
        if reduceMotion {
            isRevealed = true
            return
        }
        // Frame 1: CRT horizontal slit flash.
        withAnimation(.easeOut(duration: 0.08)) {
            bootFlashVisible = true
        }
        // Frame 2: vertical scan-out to full height.
        withAnimation(.spring(response: 0.28, dampingFraction: 0.78).delay(0.05)) {
            isRevealed = true
        }
        // Frame 3: flash fades.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.easeOut(duration: 0.35)) {
                bootFlashVisible = false
            }
        }
    }

    /// Called when the user clicks the X or hits Escape — asks the
    /// controller to close, which flips `presence.isOpen` to false and
    /// we see it via onChange.
    private func requestClose() {
        presence.isOpen = false
    }

    /// Mirror of revealBubble — collapse back down to a CRT slit, fade
    /// the flash, and after the animation completes tell the controller
    /// to orderOut the window.
    private func startCloseAnimation() {
        guard !isClosing else { return }
        isClosing = true

        if reduceMotion {
            presence.onAnimationComplete?()
            return
        }

        // 1. Brief shutdown flash.
        withAnimation(.easeIn(duration: 0.08)) {
            bootFlashVisible = true
        }
        // 2. Vertical collapse.
        withAnimation(.easeIn(duration: 0.22).delay(0.04)) {
            isRevealed = false
        }
        // 3. Flash out.
        withAnimation(.easeIn(duration: 0.18).delay(0.12)) {
            bootFlashVisible = false
        }
        // 4. Hand off to the controller to actually close the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            presence.onAnimationComplete?()
        }
    }

    /// CRT scanline overlay per spec §3.1 — 0.06 opacity over the whole
    /// panel. Clipped to the rounded rect so it doesn't bleed past the chrome.
    /// Skipped under `NSAccessibilityReduceMotion` (spec §10).
    @ViewBuilder
    private var scanlineOverlay: some View {
        if !reduceMotion {
            Canvas { ctx, size in
                ctx.opacity = 0.06
                var y: CGFloat = 0
                while y < size.height {
                    ctx.fill(
                        Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                        with: .color(.black)
                    )
                    y += 3
                }
            }
            // Rasterise once into an offscreen texture. The scanlines are
            // purely static — no state deps — so this prevents re-drawing
            // the O(height/3) paths on every streaming token render.
            .drawingGroup()
            .allowsHitTesting(false)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// Themed solid border — the agent can re-skin it via
    /// `set_chat_color({"target":"border"})`.
    private var panelBorder: some View {
        // 0.9 alpha at lineWidth 1 made the curved-corner antialiased
        // pixels read as a "stronger" feature than the straight runs
        // (which blend into scanlines/text). Net effect: the four
        // corners looked like floating arcs in the empty corner
        // region. Drop opacity + lineWidth so the border becomes
        // ambient chrome instead of a graphic feature; the corners
        // and straight edges read at the same visual weight.
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(theme.border.opacity(0.35), lineWidth: 0.6)
            .allowsHitTesting(false)
    }

    /// Hidden ⌘Z button that pops the undo stack. Placed in an overlay so it
    /// participates in the key equivalent chain without occupying layout.
    private var undoHotkeyCatcher: some View {
        ZStack {
            Button("Undo last agent change") {
                _ = undoStack.undo()
            }
            .keyboardShortcut("z", modifiers: .command)
            .accessibilityLabel("Undo last agent self-modification")

            Button("Copy All") {
                copyAllTranscript()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .accessibilityLabel("Copy full chat transcript")
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }

    /// Build a flat-text transcript of everything currently in the chat.
    /// Shared by Copy All (clipboard) and Export Transcript (save-to-file).
    private func buildTranscriptText() -> String {
        var out = ""
        for msg in session.messages {
            switch msg.kind {
            case .text(let content):
                let prefix: String
                switch msg.role {
                case .user:      prefix = "> "
                case .assistant: prefix = "▸ "
                case .tool:      prefix = "· "
                }
                out += prefix + content + "\n"
            case .toolCall(let name, let args, _, let result):
                let argsOneLine = args.split(separator: "\n").joined(separator: " ")
                out += "· [\(name)] \(argsOneLine)\n"
                if let result, !result.content.isEmpty {
                    // Indent tool output under its call in the transcript.
                    let resultLines = result.content.split(separator: "\n", omittingEmptySubsequences: false)
                    for line in resultLines {
                        out += "    " + String(line) + "\n"
                    }
                }
            case .media(let libraryName, let caption):
                // Text transcripts can't render inline images, so
                // describe the post instead.
                out += "▸ [image: \(libraryName)]\n"
                if let caption, !caption.isEmpty {
                    out += "▸ \(caption)\n"
                }
            case .link(let url, let title, let description, _):
                out += "▸ \(title) → \(url)\n"
                if let description, !description.isEmpty {
                    out += "  \(description)\n"
                }
            }
        }
        return out
    }

    /// Put the transcript on the clipboard. Used by ⌘⇧C and the Copy All
    /// context menu on any message.
    private func copyAllTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(buildTranscriptText(), forType: .string)
    }

    /// Write the transcript to a user-chosen file via NSSavePanel. Default
    /// filename is dated so successive exports don't clobber each other.
    private func exportTranscript() {
        let text = buildTranscriptText()
        let panel = NSSavePanel()
        panel.title = "Export Chat Transcript"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        // Second-precision so two exports in the same minute don't collide
        // on the default filename. DateFormatter without a locale is
        // fine here — the pattern is ISO-safe.
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        panel.nameFieldStringValue = "max-chat-\(fmt.string(from: Date())).txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't save transcript"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// Briefly show the 🛠 indicator for ~2s. Re-triggers restart the window
    /// so stacked mutations keep it visible.
    private func flashModIndicator() {
        let id = UUID()
        modFlashID = id
        withAnimation(.easeIn(duration: 0.15)) {
            modIndicatorVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if modFlashID == id {
                withAnimation(.easeOut(duration: 0.35)) {
                    modIndicatorVisible = false
                }
            }
        }
    }

    // MARK: - Chrome

    private var hairlineDivider: some View {
        Rectangle()
            .fill(theme.border.opacity(0.30))
            .frame(height: 0.5)
    }

    /// Solid themed panel — v1 of this view layered `.ultraThinMaterial`
    /// underneath which washed to grey on light wallpapers and made the
    /// text unreadable. The agent can theme this via `set_chat_color`.
    private var bubbleBackground: some View {
        ZStack {
            // Base panel colour — always present. When a background
            // image is set, the panel dims so the image shows through.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.panel.opacity(theme.backgroundImageName == nil ? 1.0 : 0.35))
            // Optional image layer — set via `set_chat_background`
            // action op. Clipped to the same rounded shape as the panel
            // and opacity-adjusted per theme setting.
            if let name = theme.backgroundImageName,
               let ns = ImageLibrary.shared.loadNSImage(named: name) {
                Image(nsImage: ns)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(theme.backgroundImageOpacity)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(theme.border)
                .frame(width: 7, height: 7)
                .shadow(color: theme.border.opacity(0.8), radius: 5)
            Text(MaxClawdroomIdentity.uppercasedDisplayName())
                .font(theme.fontFamily.font(size: scaled(12), weight: .bold))
                .tracking(2.5)
                .foregroundStyle(theme.text)
            if modIndicatorVisible {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(CRTPalette.amber)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .help("Agent self-modified — press ⌘Z to undo")
                    .accessibilityLabel("Agent modified its own state")
            }
            Spacer()
            if tour.isActive {
                Button {
                    tour.skip()
                } label: {
                    Text("chat.skip", bundle: .companionResources)
                        .font(theme.fontFamily.font(size: 10, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(CRTPalette.fgDim)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(theme.border.opacity(0.5), lineWidth: 0.6)
                        )
                }
                .buttonStyle(.plain)
                .help("End the tour early")
                .accessibilityLabel("Skip tour")
            }
            historyMenu
            voiceToggle
            iconButton(system: "square.and.arrow.up") { exportTranscript() }
                .help("Export transcript to a file")
                .accessibilityLabel("Export transcript")
            iconButton(system: "trash")       { session.clear() }
                .help("Clear conversation")
            iconButton(system: "xmark")       { requestClose() }
                .help("Close")
        }
    }

    /// Audio on/off toggle. Reads `Prefs.voiceEnabled` and redraws on the
    /// `companionVoiceChanged` notification so menu-bar flips and agent
    /// `mute_voice` actions keep this icon in sync. In addition to
    /// flipping the pref (which notifies OverlayController), calls
    /// `setEnabled` on the active voice engine directly — belt-and-
    /// suspenders so the mute/resume is instant regardless of
    /// notification-listener ordering.
    private var voiceToggle: some View {
        Button {
            Prefs.voiceEnabled.toggle()
            session.voiceEngine?.setEnabled(Prefs.voiceEnabled)
            voiceTick = UUID()
        } label: {
            Image(systemName: Prefs.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Prefs.voiceEnabled ? CRTPalette.fgDim : CRTPalette.fgDim.opacity(0.45))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.assistant.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(theme.assistant.opacity(0.35), lineWidth: 0.5)
                        )
                )
                .contentShape(Rectangle())
        }
        .id(voiceTick)
        .buttonStyle(.plain)
        .help(Prefs.voiceEnabled ? "Voice on — click to mute" : "Voice off — click to unmute")
        .accessibilityLabel(Prefs.voiceEnabled ? "Voice on" : "Voice off")
        .onReceive(NotificationCenter.default.publisher(for: .companionVoiceChanged)) { _ in
            voiceTick = UUID()
        }
    }

    /// Recent-conversations menu — lists up to 10 past sessions for this
    /// cwd plus a "New conversation" reset. Anchored under a clock icon
    /// so it looks like a history affordance rather than settings.
    private var historyMenu: some View {
        Menu {
            Button("New conversation") {
                session.startNewConversation()
            }
            if let store = session.sessionStore {
                let entries = store.list(limit: 10)
                if !entries.isEmpty {
                    Divider()
                    ForEach(entries) { rec in
                        Button(rec.title.isEmpty ? "(empty)" : rec.title) {
                            session.load(record: rec)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CRTPalette.fgDim)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.assistant.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(theme.assistant.opacity(0.35), lineWidth: 0.5)
                        )
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recent conversations")
    }

    private func iconButton(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CRTPalette.fgDim)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.assistant.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(theme.assistant.opacity(0.35), lineWidth: 0.5)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Messages

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    // Completed messages — stable during streaming so
                    // ForEach doesn't re-diff on every token.
                    ForEach(session.messages.filter { $0.id != session.streamingReplyID }) { msg in
                        messageRow(for: msg)
                            .id(msg.id)
                    }
                    // Live streaming bubble — only this view re-renders
                    // per token instead of the entire message list.
                    if let rid = session.streamingReplyID {
                        streamingBubble
                            .id(rid)
                    }
                    if let error = session.errorMessage {
                        errorPill(error)
                    }
                }
                .padding(.top, 4)
                .padding(.horizontal, 2)
            }
            // Grow to fill whatever height the user drags the bubble to
            // (ChatBubbleWindow is resizable 340×320 … 720×900). Previously
            // capped at 280pt which made the window resize feel broken.
            .frame(maxHeight: .infinity)
            .onChange(of: session.messages.last?.id) { _, newValue in
                if let id = newValue {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: session.streamingReplyID) { _, rid in
                if let id = rid {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
            // Keep the view anchored to the bottom while prose streams in.
            // Throttle to ~5 Hz so a fast token burst doesn't stack
            // scroll animations and jitter — we scroll on token arrival
            // but at most every 200 ms, and use a short .easeOut so the
            // motion reads as "following" not "chasing".
            .onChange(of: session.streamingDisplayText) { _, _ in
                guard let id = session.streamingReplyID else { return }
                let now = Date()
                if now.timeIntervalSince(lastAutoscrollAt) >= 0.2 {
                    lastAutoscrollAt = now
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }

    /// Live streaming reply — reads from session.streamingDisplayText so
    /// only this view re-renders per token, not the full message ForEach.
    /// Expose the streaming text as an accessibility value so VoiceOver
    /// announces updates as tokens arrive. SwiftUI's iOS-only
    /// accessibilityLiveRegion isn't available on macOS, so we lean on
    /// value-change announcements instead.
    @ViewBuilder
    private var streamingBubble: some View {
        if session.streamingDisplayText.isEmpty {
            thinkingDots
        } else {
            assistantBubble(text: session.streamingDisplayText, actions: session.streamingFiredActions)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Assistant reply, streaming")
                .accessibilityValue(session.streamingDisplayText)
        }
    }

    @ViewBuilder
    private func messageRow(for msg: ChatMessage) -> some View {
        switch msg.kind {
        case .text(let content):
            // Committed messages never render thinking dots. The only
            // reply that can legitimately be "empty + streaming" is
            // `session.streamingReplyID`, which is filtered out of the
            // completed-messages ForEach and rendered by `streamingBubble`.
            // Any other empty assistant placeholder is a past reply that
            // finished empty (cancelled stream, silent autonomy turn) —
            // showing dots for ALL of them caused every prior empty row
            // to animate the moment the user typed a new message.
            //
            // Skip the row entirely when committed content is empty, so
            // old placeholders don't leave blank gaps in the scroll.
            if msg.role == .assistant && content.isEmpty {
                EmptyView()
            } else {
                textRow(role: msg.role, content: content, actions: msg.firedActions)
            }
        case .toolCall(let name, let arguments, let status, let result):
            toolCallRow(id: msg.id, name: name, arguments: arguments, status: status, result: result)
        case .media(let libraryName, let caption):
            // Agent-posted image / gif from the curated library. GIFs
            // animate via the NSImageView bridge inside MediaMessageView.
            HStack(spacing: 0) {
                MediaMessageView(libraryName: libraryName, caption: caption, theme: theme)
                Spacer(minLength: 44)
            }
        case .link(let url, let title, let description, let thumbnail):
            HStack(spacing: 0) {
                LinkCardView(
                    urlString: url,
                    title: title,
                    description: description,
                    thumbnailLibraryName: thumbnail,
                    theme: theme
                )
                Spacer(minLength: 44)
            }
        }
    }

    private func textRow(role: ChatRole, content: String, actions: [String] = []) -> some View {
        HStack(spacing: 0) {
            if role == .assistant {
                assistantBubble(text: content, actions: actions)
                Spacer(minLength: 44)
            } else {
                Spacer(minLength: 44)
                userBubble(text: content)
            }
        }
    }

    private func assistantBubble(text: String, actions: [String] = []) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // `arrowtriangle.right.fill` auto-mirrors in RTL via
            // SF Symbols' semantic flipping; the hand-rolled `▸` glyph
            // would otherwise still point right in Arabic / Hebrew.
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: scaled(11), weight: .bold))
                .foregroundStyle(theme.assistant)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(Self.renderMarkdown(text.isEmpty ? " " : text))
                    .font(theme.fontFamily.font(size: scaled(13)))
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !actions.isEmpty {
                    actionPills(actions)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu { copyButton(text) }
    }

    private func actionPills(_ actions: [String]) -> some View {
        let unique = actions.reduce(into: [(String, Int)]()) { acc, op in
            if let i = acc.firstIndex(where: { $0.0 == op }) {
                acc[i].1 += 1
            } else {
                acc.append((op, 1))
            }
        }
        // Stack vertically — a burst of 4+ actions previously squeezed into
        // one HStack and clipped. One pill per line is readable at any count
        // and reads as a small activity log under the reply.
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(unique, id: \.0) { op, count in
                HStack(spacing: 3) {
                    Circle()
                        .fill(theme.assistant.opacity(0.7))
                        .frame(width: 4, height: 4)
                    Text(count > 1 ? "\(op) ×\(count)" : op)
                        .font(theme.fontFamily.font(size: 9, weight: .medium))
                        .foregroundStyle(theme.assistant.opacity(0.85))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(theme.assistant.opacity(0.10))
                        .overlay(Capsule().strokeBorder(theme.assistant.opacity(0.30), lineWidth: 0.5))
                )
            }
            Spacer(minLength: 0)
        }
    }

    private func userBubble(text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // Chevron — semantic "input prompt" glyph, auto-mirrors in RTL.
            Image(systemName: "chevron.right")
                .font(.system(size: scaled(11), weight: .bold))
                .foregroundStyle(theme.user)
                .padding(.top, 3)
            Text(text.isEmpty ? " " : text)
                .font(theme.fontFamily.font(size: scaled(13)))
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu { copyButton(text) }
    }

    /// Right-click → Copy on every message bubble. Fallback for when
    /// click-and-drag selection is finicky inside the borderless panel.
    @ViewBuilder
    private func copyButton(_ text: String) -> some View {
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        Button("Copy All (⌘⇧C)") {
            copyAllTranscript()
        }
    }

    private func toolCallRow(
        id: UUID,
        name: String,
        arguments: String,
        status: ToolCallStatus,
        result: ToolCallResult?
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(result?.isError == true ? Color(red: 1.00, green: 0.35, blue: 0.40) : theme.assistant.opacity(0.7))
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: toolIcon(for: name))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.assistant)
                    Text(name)
                        .font(theme.fontFamily.font(size: scaled(11), weight: .semibold))
                        .foregroundStyle(theme.text)
                    Spacer(minLength: 4)
                    statusBadge(status)
                }
                if !arguments.isEmpty {
                    Text(prettyArguments(arguments))
                        .font(theme.fontFamily.font(size: 10))
                        .foregroundStyle(CRTPalette.fgDim)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                if let result, !result.content.isEmpty {
                    toolResultSection(id: id, result: result)
                }
            }
        }
        .padding(.leading, 4)
        .padding(.vertical, 6)
        .padding(.trailing, 10)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.black.opacity(0.28))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            (result?.isError == true ? Color(red: 1.00, green: 0.35, blue: 0.40) : theme.assistant).opacity(0.3),
                            lineWidth: 0.5
                        )
                )
        )
        .contextMenu {
            copyButton(composedToolCopy(name: name, arguments: arguments, result: result))
        }
    }

    /// Small output pane under a tool card. Collapsed by default to a
    /// single-line preview; tap the disclosure to expand to the full
    /// stdout/stderr with scroll.
    private func toolResultSection(id: UUID, result: ToolCallResult) -> some View {
        let expanded = expandedResults.contains(id)
        let trimmed = result.content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let lineCount = trimmed.split(separator: "\n", omittingEmptySubsequences: false).count

        return VStack(alignment: .leading, spacing: 2) {
            Button {
                if expanded {
                    expandedResults.remove(id)
                } else {
                    expandedResults.insert(id)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(CRTPalette.fgDim)
                    Text(expanded ? "output" : (firstLine.isEmpty ? "\(lineCount) line\(lineCount == 1 ? "" : "s") of output" : firstLine))
                        .font(theme.fontFamily.font(size: 10))
                        .foregroundStyle(CRTPalette.fgDim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView {
                    Text(result.content)
                        .font(theme.fontFamily.font(size: 10))
                        .foregroundStyle(result.isError ? Color(red: 1.00, green: 0.65, blue: 0.70) : theme.text.opacity(0.88))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                }
                .frame(maxHeight: 160)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                )
            }
        }
        .padding(.top, 2)
    }

    private func composedToolCopy(name: String, arguments: String, result: ToolCallResult?) -> String {
        var out = arguments.isEmpty ? name : "\(name) \(arguments)"
        if let result, !result.content.isEmpty {
            out += "\n\n--- output ---\n" + result.content
        }
        return out
    }

    private func statusBadge(_ status: ToolCallStatus) -> some View {
        // Icons + text carry the signal; colour is redundant cue only.
        // Previous version used coloured circles (red vs green, 5×5pt)
        // which are indistinguishable to deuteranopic users — the text
        // label ("done" / error msg) was the only non-redundant signal
        // and relied on the user reading it.
        Group {
            switch status {
            case .streaming:
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(theme.assistant)
                    Text("running")
                        .foregroundStyle(CRTPalette.fgDim)
                }
            case .done:
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(red: 0.30, green: 0.95, blue: 0.45))
                    Text("done")
                        .foregroundStyle(Color(red: 0.30, green: 0.95, blue: 0.45))
                }
            case .error(let msg):
                HStack(spacing: 3) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(Color(red: 1.00, green: 0.35, blue: 0.40))
                    Text(msg)
                        .foregroundStyle(Color(red: 1.00, green: 0.35, blue: 0.40))
                }
            }
        }
        .font(.system(size: 9, weight: .medium))
    }

    private func toolIcon(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("bash") || n.contains("shell") || n.contains("exec") { return "terminal.fill" }
        if n.contains("read") { return "doc.text" }
        if n.contains("write") { return "square.and.pencil" }
        if n.contains("edit") { return "pencil" }
        if n.contains("grep") || n.contains("search") { return "magnifyingglass" }
        if n.contains("glob") || n.contains("find") { return "folder" }
        if n.contains("fetch") || n.contains("http") || n.contains("web") { return "globe" }
        if n.contains("task") || n.contains("agent") { return "person.2" }
        return "gearshape"
    }

    private func prettyArguments(_ raw: String) -> String {
        guard
            let data = raw.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
            let str = String(data: pretty, encoding: .utf8)
        else { return raw }
        return str
    }

    private var thinkingDots: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("▸")
                .font(theme.fontFamily.font(size: scaled(13), weight: .bold))
                .foregroundStyle(theme.assistant)
                .padding(.top, 2)
            Text("t h i n k i n g")
                .font(theme.fontFamily.font(size: scaled(13)))
                .foregroundStyle(theme.text.opacity(0.65))
                .tracking(1)
                .phaseAnimator([0.35, 1.0]) { view, phase in
                    view.opacity(reduceMotion ? 0.7 : phase)
                } animation: { _ in
                    .easeInOut(duration: 0.9)
                }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityLabel("thinking")
    }

    private func errorPill(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(Color.red.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            // Inline recovery: most backend errors are resolvable in
            // Settings (wrong endpoint, missing API key, binary path).
            // Offer a one-click jump instead of leaving the user to
            // hunt through menus.
            if errorPointsToSettings(error) {
                Button {
                    NotificationCenter.default.post(name: .companionOpenSettings, object: nil)
                } label: {
                    Text("chat.open_settings", bundle: .companionResources)
                        .font(theme.fontFamily.font(size: 10, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.red.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.25), lineWidth: 0.5)
                )
        )
    }

    /// The `friendlyError` strings already name Settings in the cases
    /// where it's the right fix — we match on those cues so the button
    /// only appears when it's actionable. Avoids an "Open Settings"
    /// button next to a plain network-offline error.
    private func errorPointsToSettings(_ error: String) -> Bool {
        let needles = [
            "Settings",
            "API key",
            "CLI Check",
            "claude CLI",
            "binary path",
            // Extra recovery paths: a timeout, a subprocess death, or a
            // "didn't respond" is usually fixed by pointing at the right
            // endpoint in Settings (or re-running CLI Check). Previously
            // these errors showed no recovery action and left the user
            // to hunt.
            "timeout",
            "timed out",
            "didn't respond",
            "exited with code",
            "endpoint"
        ]
        let lower = error.lowercased()
        return needles.contains(where: { lower.contains($0.lowercased()) })
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(MaxClawdroomIdentity.promptTag())
                .font(theme.fontFamily.font(size: scaled(13), weight: .bold))
                .foregroundStyle(tour.isActive ? theme.prompt.opacity(0.35) : theme.prompt)
                .padding(.top, 10)
                .padding(.leading, 12)

            ZStack(alignment: .topLeading) {
                TextField(
                    tour.isActive ? "tour running — press SKIP to end" : "",
                    text: $input,
                    axis: .vertical
                )
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(theme.fontFamily.font(size: scaled(13), weight: .medium))
                .foregroundStyle(theme.text)
                .tint(theme.prompt)
                .padding(.vertical, 10)
                .focused($inputFocused)
                .disabled(tour.isActive)
                .onSubmit { submit() }

                if input.isEmpty && !tour.isActive {
                    // Blinking block cursor aligned with the top of the
                    // TextField's text — shares the TextField's vertical
                    // padding so the block sits ON the baseline, not
                    // below the field.
                    Rectangle()
                        .fill((reduceMotion || cursorBlinkOn) ? theme.cursor : Color.clear)
                        .frame(width: 8, height: 14)
                        .padding(.top, 11)
                        .padding(.leading, 2)
                        .allowsHitTesting(false)
                }
            }

            sendButton
                .padding(.top, 6)
                .padding(.trailing, 8)
                .disabled(tour.isActive)
                .opacity(tour.isActive ? 0.4 : 1.0)
        }
        .background(inputBackground)
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(theme.input)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(theme.border.opacity(0.55), lineWidth: 1)
            )
    }

    private var sendButton: some View {
        Button(action: submit) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(theme.send)
                    .shadow(color: theme.send.opacity(0.55), radius: 5, x: 0, y: 2)
                Image(systemName: session.isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
    }

    private func submit() {
        if session.isStreaming {
            session.cancel()
            return
        }
        let text = input
        input = ""
        onSubmit(text)
    }

    /// Parse inline markdown (**bold**, *italic*, `code`, [link](url)) so
    /// agent replies render with emphasis rather than literal asterisks.
    /// `.inlineOnlyPreservingWhitespace` keeps multi-line streaming text
    /// intact; block-level syntax (fenced code, lists) passes through as
    /// plain text — still readable, better than swallowing whitespace.
    /// `.returnPartiallyParsedIfPossible` means a half-written `[link]`
    /// mid-stream never causes the whole bubble to render empty.
    fileprivate static func renderMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let parsed = try? AttributedString(markdown: text, options: options) {
            return parsed
        }
        return AttributedString(text)
    }
}

