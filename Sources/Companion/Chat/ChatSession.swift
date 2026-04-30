import Foundation
import Observation

enum ChatRole: String, Codable {
    case user
    case assistant
    case tool
}

enum ChatMessageKind: Hashable {
    case text(String)
    /// name + accumulated arguments (JSON-ish) + status + optional result
    case toolCall(name: String, arguments: String, status: ToolCallStatus, result: ToolCallResult?)
    /// Rich inline media. `libraryName` references an entry in
    /// `ImageLibrary` (auto-animates if the file is a .gif). Optional
    /// caption renders below the media as normal assistant prose.
    case media(libraryName: String, caption: String?)
    /// Clickable link-preview card — title, optional description, and
    /// optional thumbnail. URL opens in the default browser on click.
    /// Used for YouTube videos, articles, tweets, anything Max wants
    /// to "post" as a tappable reference instead of a bare URL.
    case link(url: String, title: String, description: String?, thumbnailLibraryName: String?)
}

enum ToolCallStatus: Hashable {
    case streaming
    case done
    case error(String)
}

/// Tool execution output piped back from the claude subprocess via its
/// tool_result user messages. Populated on a `.toolCall` message after
/// the tool has produced stdout/stderr.
struct ToolCallResult: Hashable {
    let content: String
    let isError: Bool
}

struct ChatMessage: Identifiable, Hashable {
    let id: UUID
    let role: ChatRole
    var kind: ChatMessageKind
    var firedActions: [String] = []

    init(id: UUID = UUID(), role: ChatRole, kind: ChatMessageKind) {
        self.id = id
        self.role = role
        self.kind = kind
    }

    var plainText: String {
        if case .text(let s) = kind { return s }
        return ""
    }
}

@Observable
@MainActor
final class ChatSession {
    var messages: [ChatMessage] = []
    var isStreaming: Bool = false
    var errorMessage: String?

    @ObservationIgnored let systemPrompt: String?
    @ObservationIgnored let greeting: String?
    /// Called when the agent emits a companion action. Set by OverlayController.
    @ObservationIgnored var actionHandler: ((MaxClawdroomAction) -> Void)?
    /// Called at the start of each new assistant reply so subscribers
    /// can reset per-turn state. Primary consumer: AnnotationOverlay,
    /// which caps marks per turn so a runaway reply can't carpet-bomb
    /// the screen. Fires for EVERY turn including autonomy / silent.
    @ObservationIgnored var onTurnStart: (() -> Void)?
    /// Called only when a user-visible turn begins — i.e. the user
    /// actually initiated the exchange (chat Enter, voice hotkey).
    /// Used for the anticipation-lean cue so Max doesn't lean forward
    /// for silent autonomy pings. Distinct from `onTurnStart` so
    /// subscribers can opt into the specific semantic they need.
    @ObservationIgnored var onUserTurnStart: (() -> Void)?
    /// Fires exactly once per visible reply, on the first text token.
    /// Consumers end the anticipation lean here — by this point Max
    /// has started actually speaking, so the "I'm receiving" posture
    /// should unwind. No-op for silent replies (no first token ever
    /// reaches the display path).
    @ObservationIgnored var onFirstToken: (() -> Void)?
    /// Flag tracking whether we've dispatched `onFirstToken` for the
    /// current reply. Reset each turn.
    @ObservationIgnored private var firstTokenDispatchedForReply: [UUID: Bool] = [:]
    /// Telemetry bus — tool events from the streaming response are forwarded
    /// here so the BindingEngine can react.
    @ObservationIgnored var telemetryBus: TelemetryBus?
    /// Ambient sensors — prepended as a `[env]` line to each user message
    /// so the agent can react to context (frontmost app, time of day, etc).
    @ObservationIgnored var environmentSensors: EnvironmentSensors?
    /// Optional voice engine — speaks assistant replies aloud when enabled.
    /// Receives streamUpdate on each `.text` event.
    @ObservationIgnored var voiceEngine: VoiceEngine?
    /// Per-project memory store. The `[memory]` block in the system
    /// prompt is rendered from this on each `clientOrBuild` when no
    /// structured user model is available yet.
    @ObservationIgnored weak var memory: MemoryStore?
    /// Per-cwd structured model of the user, synthesised from memory.
    /// When non-empty, the `[you]` block takes precedence over the raw
    /// `[memory]` block — it's the same information, tighter.
    @ObservationIgnored weak var userModelStore: UserModelStore?
    /// Per-cwd session persistence. Wired in OverlayController. Nil
    /// means no persistence (tests / inline use).
    @ObservationIgnored weak var sessionStore: SessionStore?

    /// Our internal record for the current in-flight session. Nil only
    /// briefly between `clear()` and the next send. On each non-silent
    /// turn we write through to `sessionStore`.
    @ObservationIgnored private(set) var currentRecord: SessionRecord?
    /// Stashed by `load(record:)` — forwarded to the next `clientOrBuild`
    /// so the claude subprocess resumes the right server-side session
    /// rather than starting fresh.
    @ObservationIgnored private var pendingResumeSessionID: String?

    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var toolCallMessageIDByID: [String: UUID] = [:]
    @ObservationIgnored private var toolNamesByID: [String: String] = [:]

    /// Raw assistant text per reply (with action tags still embedded) —
    /// needed so the parser can detect completions across chunk boundaries.
    @ObservationIgnored private var rawAssistantText: [UUID: String] = [:]
    @ObservationIgnored private var dispatchedActionCounts: [UUID: Int] = [:]
    /// Incremental parser state — avoids re-scanning the full raw text on every
    /// chunk (was O(n·k); now O(new_chunk + k_new)).
    @ObservationIgnored private var rawActionCursors: [UUID: Int] = [:]
    @ObservationIgnored private var safeDisplayTexts: [UUID: String] = [:]
    /// Reply IDs flagged as silent (autonomy pings) — skip voice + UI
    /// updates for these, but still dispatch action-tag ops.
    @ObservationIgnored private var silentReplyIDs: Set<UUID> = []
    /// Optional callbacks keyed by replyID — fired with the raw assistant
    /// text at stream end (success or partial). Used by `UserModelSynthesiser`
    /// to receive the agent's structured JSON response without any of it
    /// appearing in the visible transcript.
    @ObservationIgnored private var onRawCompleteCallbacks: [UUID: (String) -> Void] = [:]
    /// Timestamp of the last actual disk write in persistAssistantText.
    /// Throttles writes to once per 2s during streaming so we're not
    /// thrashing storage on every token.
    @ObservationIgnored private var lastPersistAt: Date = .distantPast

    /// UUID → current index in `messages`. Kept in sync by appendMsg /
    /// insertMsg / removeMsg so all by-ID lookups are O(1) instead of
    /// O(n). The text hot path fires on every streaming token, so this
    /// matters a lot at high token rates.
    @ObservationIgnored private var messageIndexByID: [UUID: Int] = [:]
    /// Name of the tool currently streaming. Observable so downstream
    /// (StageDriver, AgencyStrip) can react without scanning `messages`.
    private(set) var activeStreamingToolName: String?
    /// True once any non-empty display text has arrived in the current reply.
    /// Lets StageDriver distinguish thinking vs speaking without scanning messages.
    private(set) var hasStreamingText: Bool = false
    /// UUID of the reply currently streaming. Nil between turns. ChatView
    /// renders a separate live bubble from streamingDisplayText rather than
    /// updating messages[] per token — keeps the ForEach stable so only
    /// the live bubble re-renders during streaming.
    private(set) var streamingReplyID: UUID?
    /// Display text for the in-flight reply, updated on every token.
    /// Committed into messages[streamingReplyID] exactly once when the
    /// stream ends (or on error/cancel).
    private(set) var streamingDisplayText: String = ""
    /// Action ops fired during the current in-flight reply. Shown as pill
    /// badges in the chat bubble alongside the streaming text.
    private(set) var streamingFiredActions: [String] = []
    /// Short label explaining a silent turn to the user. Set by the
    /// caller of `send(silent:)` (AutonomyController / AgentLifecycle)
    /// BEFORE the send so AgencyStrip can show "autonomy check" or
    /// "lifecycle plan" instead of a mysterious "thinking" when Max's
    /// internals are in motion but no chat appears. Cleared on turn end.
    private(set) var currentSilentLabel: String?

    /// Set the silent-turn label that AgencyStrip surfaces. Exposed so
    /// the two silent-prompt sources can tag their turns without
    /// threading a parameter through `send(...)`.
    func setSilentLabel(_ label: String?) {
        currentSilentLabel = label
    }

    /// User turns since the last journal was requested. Drives the
    /// session-end journal trigger: only meaningful sessions (3+ turns)
    /// earn a journal entry, so trivial "hi"/"bye" opens don't accumulate
    /// as memory noise.
    @ObservationIgnored private var userTurnsSinceLastJournal: Int = 0

    /// Lazy-initialized agent backend. Built from SettingsStore on
    /// first send(); reset on clear() so soul / model / cwd / backend
    /// type changes take effect on the next turn.
    ///
    /// Typed as the `AgentBackend` protocol so either `ClaudeCodeClient`
    /// (subprocess) or `OpenAIHTTPBackend` (HTTP streaming) can fill
    /// the slot transparently.
    @ObservationIgnored private var client: AgentBackend?

    @ObservationIgnored private var soulObserver: NSObjectProtocol?
    @ObservationIgnored private var channelObserver: NSObjectProtocol?

    init(systemPrompt: String? = nil, greeting: String? = nil) {
        self.systemPrompt = systemPrompt
        self.greeting = greeting
        if let g = greeting, !g.isEmpty {
            appendMsg(ChatMessage(role: .assistant, kind: .text(g)))
        }
        // When the user accepts a soul patch, drop the cached client so
        // the next turn rebuilds with the fresh prompt. Safe to do even
        // mid-session — claude-code will spin up a new subprocess on the
        // next send().
        soulObserver = NotificationCenter.default.addObserver(
            forName: .companionSoulChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.client = nil }
        }
        // Channel switch / edit / token rotation: tear down the cached
        // client and reset the backend. Plus per-channel transcripts:
        // save the current record under whichever channel it was
        // tagged with, then resume the most-recent record for the new
        // active channel (or start fresh if none exists / the user
        // disabled resume in Prefs).
        channelObserver = NotificationCenter.default.addObserver(
            forName: .companionActiveChannelChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Snapshot the current record before tearing down,
                // so the channel we just LEFT keeps its transcript.
                if let rec = self.currentRecord, let store = self.sessionStore {
                    store.saveNow(rec)
                }
                self.client?.reset()
                self.client = nil
                self.pendingResumeSessionID = nil

                // Resume the new channel's most recent record (or
                // clear if the user opted out).
                if Prefs.resumeTranscriptOnChannelSwitch,
                   let store = self.sessionStore {
                    let newID = ChannelStore.shared.activeID
                    if let resumed = store.latestRecord(forChannel: newID) {
                        self.load(record: resumed)
                        return
                    }
                }
                // No resumable record (or user disabled resume) —
                // start fresh on the new channel. clear() also wipes
                // currentRecord, so the next persistUserTurn opens a
                // brand-new record stamped with the new channel id.
                self.clear()
            }
        }
    }

    isolated deinit {
        if let obs = soulObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = channelObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Message array helpers

    /// Hard cap on `messages.count`. Pre-cap, the array grew unbounded
    /// across the session — every chat turn (user + assistant) plus
    /// every media / link card stayed pinned in memory. 500 is enough
    /// for a multi-day conversation while keeping the visible
    /// transcript bounded; the underlying claude subprocess owns its
    /// own conversation history via `--resume <session_id>` and isn't
    /// affected by this cap. SessionRecord persistence is also independent
    /// — it appends to disk regardless of the array size.
    static let maxRetainedMessages = 500

    /// Public append. Use this instead of `session.messages.append(...)`
    /// directly — it keeps `messageIndexByID` in sync and enforces the
    /// retention cap. Sites that mutate fields on EXISTING messages
    /// (`messages[idx].kind = ...`) don't go through here; only fresh
    /// appends do.
    func appendMessage(_ msg: ChatMessage) {
        appendMsg(msg)
    }

    private func appendMsg(_ msg: ChatMessage) {
        messageIndexByID[msg.id] = messages.count
        messages.append(msg)
        // FIFO eviction. The streaming reply's index — if any —
        // stays correct because `removeMsg(at:)` shifts every entry
        // in `messageIndexByID` accordingly.
        while messages.count > Self.maxRetainedMessages {
            removeMsg(at: 0)
        }
    }

    private func insertMsg(_ msg: ChatMessage, at i: Int) {
        for (id, idx) in messageIndexByID where idx >= i {
            messageIndexByID[id] = idx + 1
        }
        messageIndexByID[msg.id] = i
        messages.insert(msg, at: i)
    }

    private func removeMsg(at i: Int) {
        messageIndexByID.removeValue(forKey: messages[i].id)
        for (id, idx) in messageIndexByID where idx > i {
            messageIndexByID[id] = idx - 1
        }
        messages.remove(at: i)
    }

    private func resetMessages(_ replacement: [ChatMessage] = []) {
        messages = replacement
        messageIndexByID = Dictionary(
            uniqueKeysWithValues: replacement.enumerated().map { ($0.element.id, $0.offset) }
        )
    }

    /// Wipes the conversation, terminates the claude subprocess so the
    /// next turn starts in a fresh session, and re-seeds the greeting.
    func clear() {
        cancel()
        // Flush any in-flight save before wiping so the record on disk
        // reflects the visible state at the moment of reset.
        if let rec = currentRecord {
            sessionStore?.saveNow(rec)
        }
        currentRecord = nil
        pendingResumeSessionID = nil
        errorMessage = nil
        resetMessages()
        toolCallMessageIDByID = [:]
        toolNamesByID = [:]
        rawAssistantText = [:]
        dispatchedActionCounts = [:]
        rawActionCursors = [:]
        safeDisplayTexts = [:]
        activeStreamingToolName = nil
        hasStreamingText = false
        streamingReplyID = nil
        streamingDisplayText = ""
        streamingFiredActions = []
        userTurnsSinceLastJournal = 0
        client?.reset()
        client = nil
        voiceEngine?.stop()
        voiceEngine?.resetStream()
        if let g = greeting, !g.isEmpty {
            appendMsg(ChatMessage(role: .assistant, kind: .text(g)))
        }
    }

    /// Send a message to the agent. When `silent` is true the user and
    /// assistant turns are NOT appended to the transcript — action-tag
    /// blocks still dispatch via the stream event handler, prose is
    /// discarded. Used by `AutonomyController` to let Max act without
    /// cluttering the visible chat.
    ///
    /// `hideUser` is the middle ground: the user prompt is not shown
    /// (so the agent's reply looks like it was unprompted), but the
    /// assistant reply IS appended + voiced normally. Used by the
    /// morning-greeting hook so Max appears to greet spontaneously.
    ///
    /// `onRawComplete` is fired once at stream end (or error) with the
    /// raw accumulated assistant text for this reply. Primarily used by
    /// `UserModelSynthesiser` — it needs the JSON the agent produces
    /// without routing any of it through the UI. Fires with `""` on
    /// error so the caller can resolve its promise either way.
    func send(
        _ text: String,
        silent: Bool = false,
        hideUser: Bool = false,
        onRawComplete: ((String) -> Void)? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Interrupt-on-user-send.
        //
        // If a reply is already streaming and another USER message
        // comes in, the user wants to skip ahead — they've typed
        // and hit return BECAUSE Max is rambling and they want to
        // change the subject. Cancel the in-flight reply (commits
        // whatever's already streamed), stop voice playback, then
        // proceed with the new turn.
        //
        // Silent autonomy turns still respect the guard so they
        // don't self-collide with each other or step on a real
        // user reply mid-stream.
        if isStreaming {
            if silent { return }
            cancel()
            voiceEngine?.stop()
        }
        // Close the double-send race window. The original code set
        // `isStreaming = true` ~30 lines below this guard; in between we
        // append the user message, persist it, and run the discovery
        // nudge. A user smashing ⌘Return twice in succession (or key-
        // repeat firing while the chat input still says enabled) could
        // pass the second guard before this flag flipped, and BOTH
        // turns would be sent. Setting it synchronously right after the
        // guard makes the second call's guard fail.
        isStreaming = true
        // Belt-and-suspenders: a prior streamTask should already be nil
        // once the completion handler runs, but if something goes wrong
        // (error path lost a race, cancel() wasn't called) we'd leak
        // the old Task and its closures. Explicit cancel is free when
        // the task is already finished.
        streamTask?.cancel()
        streamTask = nil

        let suppressUser = silent || hideUser
        let suppressAssistant = silent  // hideUser still shows the reply
        if !suppressUser {
            appendMsg(ChatMessage(role: .user, kind: .text(trimmed)))
            userTurnsSinceLastJournal += 1
            persistUserTurn(text: trimmed)
            // First-week discovery nudge — after the 5th real user turn
            // on this install, drop a local notification pointing at
            // Settings → How Max Sees You. The pane is the main user-
            // facing proof that Max is learning; without this, users on
            // the default happy path rarely scroll deep enough to find
            // it. One-shot via Prefs flag.
            if !Prefs.hasShownUserModelHint,
               userTurnsSinceLastJournal >= 5 {
                Prefs.hasShownUserModelHint = true
                NotificationController.shared.post(
                    title: "Max is learning about you",
                    body: "Open Settings → How Max Sees You to see the picture he's built.",
                    identifier: "companion.discovery.user_model"
                )
            }
        }
        errorMessage = nil
        toolCallMessageIDByID = [:]
        activeStreamingToolName = nil
        hasStreamingText = false
        streamingFiredActions = []

        let replyID = UUID()
        if !suppressAssistant {
            appendMsg(ChatMessage(id: replyID, role: .assistant, kind: .text("")))
            streamingReplyID = replyID
            streamingDisplayText = ""
            voiceEngine?.resetStream()
        } else {
            silentReplyIDs.insert(replyID)
        }
        // Reset per-turn subscribers (e.g. AnnotationOverlay's mark
        // budget) so each reply starts with a fresh quota.
        onTurnStart?()
        // Reset the dispatcher's per-turn memory-op budget. A bursty or
        // poisoned reply that emits 100 `remember` calls now stops at
        // the cap (warning to user) instead of bloating MemoryStore.
        ActionDispatcher.resetMemoryOpsThisTurn()
        // User-visible turns get the anticipation cue fired immediately
        // so Max leans in before the first LLM token lands. Silent
        // autonomy pings skip it — leaning toward nothing would read as
        // a glitch.
        if !suppressUser {
            onUserTurnStart?()
        }
        // Reset first-token tracking so the next stream can fire
        // `onFirstToken` on its first .text event.
        firstTokenDispatchedForReply[replyID] = false
        if let onRawComplete {
            onRawCompleteCallbacks[replyID] = onRawComplete
        }

        // Prepend env context to what the model actually sees.
        let payload: String
        if let snap = environmentSensors?.contextSnapshot, !snap.isEmpty {
            payload = snap + "\n\n" + trimmed
        } else {
            payload = trimmed
        }

        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // One transparent retry on transient errors (network blips,
            // subprocess crashes, server 5xx). We only retry if no text
            // has reached the user yet — otherwise the retry would
            // duplicate visible content. Auth failures and rate limits
            // are NOT retried; they need user action.
            var attempt = 0
            let maxRetries = 1
            var lastError: Error?
            while true {
                let client = self.clientOrBuild()
                do {
                    for try await event in client.stream(userText: payload) {
                        self.apply(event: event, replyID: replyID)
                    }
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    let hasUserVisibleText = !self.streamingDisplayText.isEmpty
                    let canRetry = attempt < maxRetries
                        && !Task.isCancelled
                        && !hasUserVisibleText
                        && Self.isTransient(error)
                    if canRetry {
                        AppLog.chat.notice("transient stream error — retrying once: \(error.localizedDescription, privacy: .public)")
                        // Drop the cached client so the next attempt
                        // gets a fresh subprocess / URLSession.
                        self.client?.reset()
                        self.client = nil
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        attempt += 1
                        continue
                    }
                    break
                }
            }
            if let error = lastError {
                // Commit whatever partial text streamed before the error.
                // The reply slot in messages is always .text("") during
                // streaming now; either populate it or remove it.
                if let idx = self.messageIndexByID[replyID] {
                    if !self.streamingDisplayText.isEmpty {
                        self.messages[idx].kind = .text(self.streamingDisplayText)
                    } else {
                        self.removeMsg(at: idx)
                    }
                }
                self.streamingReplyID = nil
                self.streamingDisplayText = ""
                self.errorMessage = Self.friendlyError(error)
                // Auth failures: post a targeted notification so the
                // menu / chat UI can offer a re-pair affordance for
                // the channel that just lost its token.
                if Self.isAuthFailure(error) {
                    let channelID = ChannelStore.shared.activeID
                    NotificationCenter.default.post(
                        name: .companionChannelAuthFailed,
                        object: nil,
                        userInfo: ["channelID": channelID.uuidString]
                    )
                }
                // Let the inquiry caller resolve with partial text
                // (or empty on outright failure) so it isn't left
                // waiting forever.
                if let cb = self.onRawCompleteCallbacks.removeValue(forKey: replyID) {
                    cb(self.rawAssistantText[replyID] ?? "")
                }
                // Unlatch anticipation if the error path fired before
                // any text arrived — otherwise Max stays leaning
                // forever with no reply coming.
                if self.firstTokenDispatchedForReply[replyID] == false {
                    self.firstTokenDispatchedForReply[replyID] = true
                    self.onFirstToken?()
                }
                self.firstTokenDispatchedForReply.removeValue(forKey: replyID)
            }
            do {
                self.isStreaming = false
                // Commit the final display text into the messages array.
                // All the per-token updates went to streamingDisplayText
                // so the ForEach never had to re-diff during streaming.
                if let rid = self.streamingReplyID,
                   let idx = self.messageIndexByID[rid] {
                    self.messages[idx].kind = .text(self.streamingDisplayText)
                    self.messages[idx].firedActions = self.streamingFiredActions
                }
                self.streamingReplyID = nil
                self.streamingDisplayText = ""
                self.streamingFiredActions = []
                self.currentSilentLabel = nil
                self.finalizeStreamingToolCalls()
                self.silentReplyIDs.remove(replyID)
                self.flushPersist()
                self.captureClaudeSessionIDIfNeeded()
                // OpenAI HTTP backend doesn't track conversation state
                // server-side — we have to feed the assistant reply
                // back so the next turn sees it as history. No-op for
                // ClaudeCodeClient (subprocess owns its own history).
                if let http = self.client as? OpenAIHTTPBackend,
                   let raw = self.rawAssistantText[replyID] {
                    http.appendAssistantReply(raw)
                }
                // Hand the raw accumulated text to any inquiry caller
                // (e.g. UserModelSynthesiser) waiting on this reply.
                if let cb = self.onRawCompleteCallbacks.removeValue(forKey: replyID) {
                    cb(self.rawAssistantText[replyID] ?? "")
                }
                // Defensive unlatch — if a reply completed without any
                // text token (e.g. a silent/action-only turn), the lean
                // would otherwise stay held until the next turn.
                if self.firstTokenDispatchedForReply[replyID] == false {
                    self.firstTokenDispatchedForReply[replyID] = true
                    self.onFirstToken?()
                }
                self.firstTokenDispatchedForReply.removeValue(forKey: replyID)
                // Per-reply tracking dicts grow forever otherwise — every
                // streamed reply leaves a dead UUID → String mapping
                // behind, accumulating ~MB per ~50 turns. The committed
                // text is on `messages[idx]` already; the raw text was
                // handed to the HTTP backend and onRawComplete callback
                // above, so nothing else reads these for this replyID.
                self.rawAssistantText.removeValue(forKey: replyID)
                self.rawActionCursors.removeValue(forKey: replyID)
                self.safeDisplayTexts.removeValue(forKey: replyID)
                self.dispatchedActionCounts.removeValue(forKey: replyID)
            }
        }
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        // Commit whatever was streaming so it doesn't disappear on stop.
        if let rid = streamingReplyID, let idx = messageIndexByID[rid] {
            messages[idx].kind = .text(streamingDisplayText)
        }
        streamingReplyID = nil
        streamingDisplayText = ""
        streamingFiredActions = []
        flushPersist()
    }

    // MARK: - Persistence

    /// Start a new conversation: saves any in-flight record, wipes
    /// the current session subprocess, and clears the record pointer
    /// so the next send() spawns a brand-new one.
    func startNewConversation() {
        if let rec = currentRecord {
            sessionStore?.saveNow(rec)
        }
        currentRecord = nil
        pendingResumeSessionID = nil
        clear()
    }

    /// Load a persisted session: replays visible messages in the UI
    /// and stashes the claude `session_id` so the next send() passes
    /// `--resume <id>` to claude-code for true conversational continuity.
    func load(record: SessionRecord) {
        cancel()
        client?.reset()
        client = nil
        errorMessage = nil
        toolCallMessageIDByID = [:]
        toolNamesByID = [:]
        rawAssistantText = [:]
        dispatchedActionCounts = [:]
        rawActionCursors = [:]
        safeDisplayTexts = [:]
        activeStreamingToolName = nil
        hasStreamingText = false
        streamingReplyID = nil
        streamingDisplayText = ""
        streamingFiredActions = []
        userTurnsSinceLastJournal = 0

        // Replay persisted messages as display-only ChatMessages.
        let loaded = record.messages.map {
            ChatMessage(
                role: $0.role == .user ? .user : .assistant,
                kind: .text($0.text)
            )
        }
        resetMessages(loaded)
        currentRecord = record
        pendingResumeSessionID = record.claudeSessionID
    }

    private func persistUserTurn(text: String) {
        guard let store = sessionStore else { return }
        var rec = currentRecord ?? SessionRecord(cwd: SettingsStore.shared.settings.cwd)
        rec.messages.append(PersistedMessage(role: .user, text: text))
        if rec.title.isEmpty {
            rec.title = String(text.prefix(60))
        }
        rec.updatedAt = Date()
        // Stamp the active channel on every save so per-channel
        // listing can filter cleanly. Stamps even existing records
        // so a legacy (untagged) session inherits the channel it
        // was first reused under.
        rec.channelID = ChannelStore.shared.activeID
        currentRecord = rec
        store.save(rec)
    }

    /// Called when the in-flight assistant reply's display text updates.
    /// Appends-or-updates a trailing assistant entry in the record so the
    /// saved conversation mirrors what's on screen.
    private func persistAssistantText(_ text: String) {
        guard var rec = currentRecord else { return }
        if let last = rec.messages.last, last.role == .assistant {
            rec.messages[rec.messages.count - 1] = PersistedMessage(role: .assistant, text: text, at: last.at)
        } else {
            rec.messages.append(PersistedMessage(role: .assistant, text: text))
        }
        rec.updatedAt = Date()
        rec.channelID = ChannelStore.shared.activeID
        currentRecord = rec
        // Throttle disk writes during streaming — update in-memory record every
        // token but only flush to disk at most once per 2s. flushPersist() is
        // called at stream end to guarantee the final text is written.
        let now = Date()
        guard now.timeIntervalSince(lastPersistAt) >= 2.0 else { return }
        lastPersistAt = now
        sessionStore?.save(rec)
    }

    private func flushPersist() {
        guard let store = sessionStore, let rec = currentRecord else { return }
        lastPersistAt = Date()
        store.save(rec)
    }

    /// Called when a stream finishes. Pulls the `session_id` the claude
    /// subprocess assigned and writes it into the record so the next
    /// load can resume this specific server-side conversation.
    private func captureClaudeSessionIDIfNeeded() {
        guard let store = sessionStore, var rec = currentRecord else { return }
        if rec.claudeSessionID == nil, let id = client?.sessionID, !id.isEmpty {
            rec.claudeSessionID = id
            currentRecord = rec
            store.saveNow(rec)
        }
    }

    /// Fire a silent end-of-session prompt asking Max to journal, but
    /// only if the session carried enough substance to be worth
    /// remembering. The `write_journal` action-tag handler persists
    /// through to the MemoryStore; any prose Max writes in the same
    /// turn is discarded because the reply is silent.
    ///
    /// Called from `OverlayController` when the chat panel closes.
    /// The live `ClaudeCodeClient` keeps running so the silent turn
    /// completes in the background while the UI is already fading.
    func requestSessionJournalIfMeaningful() {
        // Thresholds: at least three user turns since the last journal,
        // and no in-flight stream (otherwise we'd stomp it).
        guard userTurnsSinceLastJournal >= 3, !isStreaming else { return }
        userTurnsSinceLastJournal = 0
        let prompt = """
        [session_wrap_up]
        The chat panel is about to close. If anything in this session is \
        worth remembering next time — what the user's working on, a \
        preference they expressed, an observation about how they work — \
        write a short 2–4 sentence entry via write_journal. Just the \
        action block; no prose back. If nothing notable happened, \
        skip it and reply with nothing.
        """
        send(prompt, silent: true)
    }

    // MARK: - Client lazy-init

    private func clientOrBuild() -> AgentBackend {
        if let c = client { return c }
        let snapshot = SettingsStore.shared.settings
        let userSoul = snapshot.systemPrompt.isEmpty ? (systemPrompt ?? "") : snapshot.systemPrompt
        var composed = ActionInstructions.systemPromptPrefix
        // Tell the agent what he's called. Sanitised name is already
        // injection-safe (brackets/quotes/controls stripped), so literal
        // interpolation is fine.
        let name = MaxClawdroomIdentity.displayName()
        composed += "\n\nYour name is \(name). Refer to yourself as \(name) when appropriate; don't announce the name change, just use it."
        if !userSoul.isEmpty {
            composed += "\n\n" + userSoul
        }
        // Inject model-of-the-user. Prefer the structured `[you]` block
        // when a non-empty UserModel has been synthesised — it's the
        // same memory distilled into a form the agent can reason about
        // directly. Fall back to the raw `[memory]` block on fresh
        // installs or when the synthesiser hasn't run yet.
        let youBlock = userModelStore?.model.promptBlock() ?? ""
        if !youBlock.isEmpty {
            composed += "\n\n" + youBlock
        } else if let memBlock = memory?.formattedForPrompt(), !memBlock.isEmpty {
            composed += "\n\n" + memBlock
        }
        // Inject observed-preferences block so Max can ground soul-
        // patch proposals in actual behavioural patterns rather than
        // assumptions. Silent when the log is too thin to be useful.
        let prefBlock = PreferenceLearner.shared.promptBlock()
        if !prefBlock.isEmpty {
            composed += "\n\n" + prefBlock
        }
        // Expose the user's curated image library by name so the agent
        // knows what it can reference in `set_part_texture` /
        // `set_chat_background`. Empty library → no block, and the
        // agent's system-prompt paragraph about those ops is self-
        // contained so the agent won't attempt calls with names that
        // don't exist.
        let imageNames = ImageLibrary.shared.agentVisibleNames
        if !imageNames.isEmpty {
            let sanitised = imageNames.map {
                EnvironmentSensors.sanitiseForPrompt($0)
            }.joined(separator: ", ")
            composed += "\n\nAvailable images in the user's library (reference by name in set_part_texture / set_chat_background): \(sanitised)"
        }
        // Sound effects catalog — always advertised so Max knows what
        // sounds exist regardless of whether the master toggle is on.
        // Earlier we gated this on `Prefs.soundEffectsEnabled`, but
        // that left Max improvising onomatopoeia ("boom, whoosh, ding")
        // when the user hadn't yet flipped the toggle in Settings —
        // and the toggle is precisely the discoverable surface that
        // gets flipped after Max starts reaching for sounds. The
        // SoundEngine no-ops cleanly when the toggle is off
        // (`isActive` returns false), so a play_sound call from a
        // muted Max is silent rather than broken.
        composed += "\n\n" + SoundLibrary.promptBlock()
        // Baseline appearance / voice / chat. Tells Max what his
        // canonical defaults are so "look normal" / "go back to
        // default" mean the same concrete things to him as they do
        // to the right-click "Revert to Baseline" menu item, and
        // exposes the `revert_to_baseline` action op in the same
        // breath. Single source of truth: `MaxClawdroomBaseline`.
        composed += "\n\n" + MaxClawdroomBaseline.promptBlock()
        // Optional features that are currently OFF. Lets Max suggest
        // one when contextually relevant — voice input if the user
        // seems to be voice-curious, autonomy if they ask "what do
        // you do when I'm away", etc. Empty when the user opted out
        // (Prefs.allowMaxToSuggestFeatures) or every feature is on.
        let suggesterBlock = FeatureSuggester.promptBlock()
        if !suggesterBlock.isEmpty {
            composed += "\n\n" + suggesterBlock
        }
        // Consume the stashed resume ID exactly once: capture, then clear so a
        // reset() or soul-swap triggered mid-session doesn't re-use it.
        let resumeID = pendingResumeSessionID
        pendingResumeSessionID = nil
        // Active channel drives the backend. The factory maps each
        // channel kind onto an existing AgentBackend implementation;
        // BackendSettings continues to feed the CLI tail (binary path,
        // permission mode, allowed tools).
        let channel = ChannelStore.shared.active
        let c = ClawdexBackendFactory.makeBackend(
            for: channel,
            composedSystemPrompt: composed,
            resumeSessionID: resumeID
        )
        client = c
        return c
    }

    // MARK: - Event application

    private func apply(event: AgentEvent, replyID: UUID) {
        switch event {
        case .text(let chunk):
            // First visible token of the reply — unlatch the
            // anticipation lean. Silent replies never set firstToken to
            // false in the first place (we only track when suppressAssistant
            // is false), so this branch is correctly skipped for them.
            if firstTokenDispatchedForReply[replyID] == false,
               !silentReplyIDs.contains(replyID) {
                firstTokenDispatchedForReply[replyID] = true
                onFirstToken?()
            }
            // Mutate in place via the default-subscript _modify accessor so
            // the stored String's buffer grows amortised O(1) per token
            // instead of the old `raw = prior + chunk` pattern, which made
            // a full copy on every token and cost O(n²) over a long reply.
            rawAssistantText[replyID, default: ""].append(chunk)
            let raw = rawAssistantText[replyID] ?? ""

            let cursor = rawActionCursors[replyID, default: 0]
            let (safeDelta, _, newActions, nextCursor) = ActionParser.process(raw: raw, from: cursor)
            rawActionCursors[replyID] = nextCursor
            safeDisplayTexts[replyID, default: ""].append(safeDelta)
            let safeDisplay = safeDisplayTexts[replyID] ?? ""

            for action in newActions {
                dispatchAction(action, afterReplyID: replyID)
            }
            dispatchedActionCounts[replyID, default: 0] += newActions.count

            // Publish streaming text separately rather than mutating
            // messages[] per token. This keeps the ForEach stable during
            // streaming — only the live bubble re-renders, not every row.
            // Only safe text (action tags stripped) is shown and spoken —
            // the unsafeTail is a partial [action]{...} block that must
            // never appear as literal JSON in the chat or be read aloud.
            //
            // Action blocks usually arrive surrounded by blank lines:
            // "foo.\n\n[action]{…}[/action]\n\nbar." After the parser strips
            // the tag, both blank lines remain, producing a visible 3–4
            // line gap in the rendered bubble. Collapse 3+ consecutive
            // newlines to 2 so the reply reads as a single paragraph break.
            if !silentReplyIDs.contains(replyID) {
                // System-tag strip first, THEN blank-run collapse. The strip
                // can leave surrounding blank lines behind — collapseBlankRuns
                // folds them so there's no visible gap where the tag was.
                let stripped = Self.stripSystemBlocks(safeDisplay)
                let display = Self.collapseBlankRuns(stripped)
                streamingDisplayText = display
                if !display.isEmpty { hasStreamingText = true }
                voiceEngine?.streamUpdate(fullText: display)
                if !display.isEmpty {
                    persistAssistantText(display)
                }
            }
        case .toolCallBegin(let id, let name):
            let msgID = UUID()
            toolCallMessageIDByID[id] = msgID
            toolNamesByID[id] = name
            let insertAt: Int
            if let replyIdx = messageIndexByID[replyID] {
                // messages[replyIdx] is always .text("") now (content lives in
                // streamingDisplayText), so check the streaming text instead.
                let hasText = replyID == streamingReplyID
                    ? !streamingDisplayText.isEmpty
                    : { if case .text(let s) = messages[replyIdx].kind { return !s.isEmpty }; return false }()
                insertAt = hasText ? replyIdx + 1 : replyIdx
            } else {
                insertAt = messages.count
            }
            insertMsg(
                ChatMessage(
                    id: msgID,
                    role: .tool,
                    kind: .toolCall(name: name, arguments: "", status: .streaming, result: nil)
                ),
                at: insertAt
            )
            activeStreamingToolName = name
            telemetryBus?.emit(
                signal: TelemetrySignal.toolStart,
                payload: ["id": id, "name": name]
            )
            telemetryBus?.emit(
                signal: "tool.\(name.lowercased())",
                payload: ["id": id]
            )
            if Self.isSubagentTool(name) {
                telemetryBus?.emit(
                    signal: TelemetrySignal.subagentSpawn,
                    payload: ["id": id, "name": name]
                )
            }
        case .toolCallArgs(let id, let argumentsDelta):
            guard let msgID = toolCallMessageIDByID[id],
                  let idx = messageIndexByID[msgID] else { return }
            if case .toolCall(let name, let args, _, let result) = messages[idx].kind {
                messages[idx].kind = .toolCall(
                    name: name,
                    arguments: args + argumentsDelta,
                    status: .streaming,
                    result: result
                )
            }
        case .toolCallEnd(let id):
            guard let msgID = toolCallMessageIDByID[id],
                  let idx = messageIndexByID[msgID] else { return }
            if case .toolCall(let name, let args, _, let result) = messages[idx].kind {
                messages[idx].kind = .toolCall(
                    name: name,
                    arguments: args,
                    status: .done,
                    result: result
                )
            }
            let finishedName = toolNamesByID[id] ?? ""
            telemetryBus?.emit(
                signal: TelemetrySignal.toolEnd,
                payload: ["id": id, "name": finishedName]
            )
            if Self.isSubagentTool(finishedName) {
                telemetryBus?.emit(
                    signal: TelemetrySignal.subagentEnd,
                    payload: ["id": id]
                )
            }
            toolNamesByID.removeValue(forKey: id)
            activeStreamingToolName = toolNamesByID.values.first

        case .toolCallResult(let id, let content, let isError):
            // Attach the stdout/stderr payload to the existing tool-call
            // message. If we don't have one for this id (tool result
            // arrived before its begin — rare), drop it silently.
            if let msgID = toolCallMessageIDByID[id],
               let idx = messageIndexByID[msgID],
               case .toolCall(let name, let args, let status, _) = messages[idx].kind {
                let result = ToolCallResult(content: content, isError: isError)
                // Upgrade status to .error if the tool flagged an error.
                let newStatus: ToolCallStatus
                if isError {
                    let snippet = String(content.prefix(60))
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    newStatus = .error(snippet.isEmpty ? "error" : snippet)
                } else {
                    newStatus = status
                }
                messages[idx].kind = .toolCall(
                    name: name,
                    arguments: args,
                    status: newStatus,
                    result: result
                )
            }
            // Also emit a telemetry signal so cognition-as-body bindings
            // can react (e.g. tint the tie red on tool failure).
            telemetryBus?.emit(
                signal: isError ? TelemetrySignal.toolError : TelemetrySignal.toolResult,
                payload: ["id": id, "size": content.count]
            )

        case .tokenEntropy(let value):
            telemetryBus?.emit(signal: TelemetrySignal.tokenHesitation, value: value)

        case .tokenLatency(let value):
            telemetryBus?.emit(signal: TelemetrySignal.latency, value: value)
        }
    }

    private func finalizeStreamingToolCalls() {
        for i in messages.indices {
            if case .toolCall(let name, let args, let status, let result) = messages[i].kind,
               status == .streaming {
                messages[i].kind = .toolCall(name: name, arguments: args, status: .done, result: result)
            }
        }
        activeStreamingToolName = nil
    }

    /// Dispatch a companion-control action. These are invisible in chat —
    /// the only feedback is the resulting body change.
    private func dispatchAction(_ action: MaxClawdroomAction, afterReplyID replyID: UUID) {
        _ = replyID
        actionHandler?(action)
        if !silentReplyIDs.contains(replyID) {
            streamingFiredActions.append(action.op)
        }
    }

    private static func isSubagentTool(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "task" || lower == "agent" || lower.contains("subagent")
    }

    /// Errors worth retrying once: network blips, server 5xx,
    /// subprocess crashes that happened before any user-visible text.
    /// NOT auth failures, NOT rate limits — those need user action.
    private static func isTransient(_ error: Error) -> Bool {
        if let http = error as? OpenAIHTTPError {
            switch http {
            case .networkUnreachable, .serverError:
                return true
            case .unauthorized, .rateLimited, .badResponse:
                return false
            }
        }
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .timedOut, .notConnectedToInternet, .networkConnectionLost,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .resourceUnavailable:
                return true
            default:
                return false
            }
        }
        if let cli = error as? ClaudeCodeProcess.LaunchError {
            // Subprocess died unexpectedly — restart and try once more.
            // executableMissing isn't transient; the user has to install.
            switch cli {
            case .terminated, .failedToStart: return true
            case .executableMissing:          return false
            }
        }
        return false
    }

    /// Auth-rejected — token expired, key rotated, etc. The chat UI
    /// surfaces a re-pair affordance and the channel's health flips
    /// to `.unauthorized` on the next probe.
    private static func isAuthFailure(_ error: Error) -> Bool {
        if let http = error as? OpenAIHTTPError, case .unauthorized = http {
            return true
        }
        return false
    }

    private static func friendlyError(_ error: Error) -> String {
        // Claude Code subprocess errors — the LaunchError type already
        // carries good strings, but add an inline hint so users know
        // where the fix lives rather than staring at a raw failure.
        if let e = error as? ClaudeCodeProcess.LaunchError {
            switch e {
            case .executableMissing(let path):
                return "claude CLI not found at \(path). Install Claude Code (brew install claude-code) or update the path in Settings → Claude CLI."
            case .failedToStart(let msg):
                return "Couldn't start claude: \(msg). Check Settings → CLI Check to verify the binary path."
            case .terminated(let code, let tail):
                // Tail is the last ~20 stderr lines. Show the final line
                // (or two) — the rest is usually context and drowns the
                // actual error in a chat bubble.
                let firstErrLine = tail
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .first(where: { !$0.isEmpty })
                    .map(String.init) ?? ""
                if firstErrLine.isEmpty {
                    return "claude exited with code \(code). Try opening Settings → CLI Check."
                }
                return "claude exited with code \(code): \(firstErrLine)"
            }
        }
        // OpenAI HTTP backend errors. 401 gets a channels-aware hint
        // because the active channel may be a LAN pair where the right
        // fix is "open Channels and re-pair," not "edit an API key."
        if let http = error as? OpenAIHTTPError {
            if case .unauthorized = http {
                let active = ChannelStore.shared.active
                switch active.kind {
                case .lan:
                    return "Channel \"\(active.name)\" rejected the token (clawdex was probably restarted). Open the menu bar → Channels → Add Channel… → LAN to re-pair."
                case .remote:
                    return "Channel \"\(active.name)\" rejected the token (401). Check the bearer in Settings → Channels."
                case .local, .claudeCodeCLI:
                    return http.localizedDescription
                }
            }
            return http.localizedDescription
        }
        // URL / network fallthrough — distinguish offline from endpoint-
        // specific failures so users know whether to check their connection.
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost:
                return "No network connection. Max needs internet for the OpenAI-compatible backend; switch to Claude Code CLI in Settings to run fully local."
            case .timedOut:
                return "The backend didn't respond in time. If you're on a self-hosted endpoint, check it's running."
            case .cancelled:
                return "Cancelled."
            default:
                return "Network error: \(urlErr.localizedDescription)"
            }
        }
        return (error as NSError).localizedDescription
    }

    /// Collapse runs of 3+ consecutive newlines into a single paragraph
    /// break. Action-tag stripping leaves both the newline before `[action]`
    /// and the one after `[/action]`, producing visible multi-line gaps in
    /// the rendered bubble. Called on the safe display text before it's
    /// shown / spoken / persisted.
    static func collapseBlankRuns(_ s: String) -> String {
        guard s.contains("\n\n\n") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var newlineRun = 0
        for ch in s {
            if ch == "\n" {
                newlineRun += 1
                if newlineRun <= 2 { out.append(ch) }
            } else {
                newlineRun = 0
                out.append(ch)
            }
        }
        return out
    }

    /// System-context tags (env / memory / you / persona / soul / user)
    /// are only supposed to appear on the INPUT side — prepended to the
    /// user turn or baked into the system prompt. If the agent hallucinates
    /// one into its reply, we strip it before display / voice / persistence
    /// so users don't see or hear the ambient context being read back at
    /// them. Matches any of a fixed set of known system tag names; anything
    /// else (like the `[action]` stream that ActionParser handles, or
    /// markdown like `[link](url)`) passes through untouched.
    ///
    /// Three passes:
    ///   1. Matched pairs `[tag]…[/tag]` — drop the whole block.
    ///   2. Unmatched openers `[tag]…` to end of line — drop to `\n`.
    ///      This catches the case where the agent starts echoing its
    ///      context but forgets (or never writes) the closing tag.
    ///   3. Literal JSON-ish lines that look like user_model dumps:
    ///      leading `{` or `}`, or keys like `"recent_mood_signal":`,
    ///      `"identity":`, `"preferences":`, etc. Strip those lines
    ///      whole — they're never legitimate agent prose.
    /// All three are case-insensitive so `[ENV]` / `[Env]` / `[env]`
    /// all match.
    static func stripSystemBlocks(_ s: String) -> String {
        // Pass 0 — content-fingerprint defense. When the agent is
        // confused on a silent / hidden-user harness prompt, it tends
        // to echo the WHOLE prompt body back as its reply. Prompt
        // bodies have no distinctive bracket tokens (we stripped the
        // `[autonomy ping]` / `[max-initiated chat]` markers in pass
        // 2b), so bracket-based matching misses them. Fingerprint list
        // below covers ALL harness prompts shipped by the app:
        //   - AutonomyController variants (silent / banter / idle /
        //     returned / self-reflection / contextual / follow-up /
        //     max-initiated chat)
        //   - AgentLifecycle (`[lifecycle_plan]`)
        //   - RitualEngine (sunday, evening, anniversary)
        //   - AppDelegate debug / welcome-back paths
        //
        // Strategy: if ANY fingerprint phrase appears anywhere in the
        // reply, discard the entire reply. These phrases are harness-
        // specific and no natural Max response would legitimately use
        // them in first-person prose. Silence is always better than
        // reading out instructions.
        //
        // Audit: grep -rnE '^\s{4,}[A-Z]' Sources/Companion/Autonomy/
        // Sources/Companion/Rituals/ Sources/Companion/App/AppDelegate.swift
        // and look for multi-line-string lines that are clearly harness
        // wording, not agent-facing examples.
        let promptFingerprints = [
            // Autonomy — banter / silent / idle / returned / reflection
            "You're alive on the user's desktop",
            "You're alive. Nobody's talking to you",
            "Nobody's explicitly asked you anything",
            "Nobody's speaking to you right",
            "You MAY — if and only if the context",
            "You MAY --- if and only if the context",
            "You MAY if and only if the context",
            "Use the [env] block",
            "Examples of warranted:",
            "Examples of NOT warranted:",
            "Examples of the register, not verbatim",
            "If you speak, do it warm and brief",
            "If you speak, one line only",
            "If nothing's worth doing, output nothing",
            "If nothing is worth doing, output nothing",
            "Your prose this turn is discarded",
            "Your prose this turn is shown in chat",
            "Emit actions or nothing",
            "One sentence. Then stop",
            "Quiet moment. Look at what you've accumulated",
            // Autonomy — max-initiated chat opener
            "You've chosen to start a conversation",
            "The user hasn't said anything yet",
            "Make it worth opening for",
            "Ground your opener in what you actually know",
            "Good openers (register only, not verbatim)",
            "NOT acceptable:",
            // Autonomy — contextual event
            "Something specific just happened that you should be aware",
            "React naturally. You can:",
            // Autonomy — scheduled follow-up
            "You scheduled this turn yourself",
            // Autonomy — user idle / returned
            "The user has been away from the keyboard",
            // AgentLifecycle — planning
            "background survey picked up work",
            "Top task:",
            "this is a silent plan tick",
            "Do not speak to the user; this is a silent",
            // Rituals
            "It's Sunday evening local time",
            "Evening local time, and the user has been idle",
            "Quiet bedtime check-in",
            "Recent memory so you can reference something real",
            // Debug
            "This is a pipeline test",
            "Do NOT write any prose outside the action block"
        ]
        // Search the whole string (not line-by-line). A per-line scan let
        // an attacker-shaped reply split a fingerprint across a newline
        // ("You're alive on\nthe user's desktop") and slip past the
        // trimmed-line contains() check. Whole-string match also skips
        // the per-token `.split(separator:)` + `.trimmingCharacters`
        // overhead on the streaming hot path.
        for phrase in promptFingerprints {
            if s.contains(phrase) {
                return ""
            }
        }

        var out = s

        // Pass 0b — angle-bracket harness tags. Claude Code wraps its
        // own injections in `<system-reminder>…</system-reminder>`
        // blocks. When Max's claude subprocess echoes one back, the
        // bracket-prefix matcher below misses it (chars are `<`/`>`,
        // not `[`/`]`).
        //
        // Matched-pair only — DO NOT strip orphan openers. This function
        // runs on every streaming chunk; an orphan `<system-reminder>`
        // appears at the moment the opener arrives but the closer is
        // still in flight, and a strip-to-EOS pass at that instant
        // would wipe the entire reply for as long as the block remains
        // open. UX-wise that reads as Max being stuck — voice + chat
        // both produce nothing for several seconds. Waiting for the
        // matched closer means a brief flash of the raw tag chars is
        // possible during streaming, but the user always sees forward
        // motion. Once the closer arrives the whole block disappears.
        let xmlTags = ["system-reminder", "system_reminder", "system-instruction", "thinking"]
        for tag in xmlTags {
            while let open = out.range(of: "<\(tag)>", options: .caseInsensitive),
                  let close = out.range(of: "</\(tag)>", options: .caseInsensitive,
                                        range: open.upperBound..<out.endIndex) {
                out.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }

        // NOTE: an earlier early-out gate sat here that returned `out`
        // unchanged when the buffer had no `[`, `{`, or `"`. That
        // bypassed the transcript-prefix strip (Pass 2c) below, which
        // runs on plain text — letting `Human: Hello there!` land
        // unstripped in chat + voice when no other punctuation was
        // present. The early-out has been narrowed to just the
        // bracket/JSON passes (2c stays unconditional).
        // Keep this in sync with every bracket-prefix the harness ever
        // injects. Missing one means the agent can echo it back as
        // prose and TTS will read the user's own context to them.
        // Audit: grep -rE '"\[[a-z_]+\]' Sources/ to find anywhere a
        // string literal starts with a bracket-tag shape.
        let tags = ["env", "world", "memory", "you", "persona", "soul", "user", "context", "editor"]
        let needsBracketPasses =
            out.contains("[") || out.contains("{") || out.contains("\"")

        if needsBracketPasses {
        // Pass 1 — matched pairs.
        for tag in tags {
            while let open = out.range(of: "[\(tag)]", options: .caseInsensitive),
                  let close = out.range(of: "[/\(tag)]", options: .caseInsensitive,
                                        range: open.upperBound..<out.endIndex) {
                out.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }

        // Pass 2 — unmatched openers. Anchor at any position the tag
        // appears; delete from the `[` through the next newline (or EOS).
        for tag in tags {
            while let open = out.range(of: "[\(tag)]", options: .caseInsensitive) {
                let endOfLine = out.range(of: "\n", range: open.upperBound..<out.endIndex)?.lowerBound
                    ?? out.endIndex
                out.removeSubrange(open.lowerBound..<endOfLine)
            }
            // Also catch the close tag on its own, e.g. a `[/env]` hanging
            // around from a truncated matched pair.
            while let close = out.range(of: "[/\(tag)]", options: .caseInsensitive) {
                let endOfLine = out.range(of: "\n", range: close.upperBound..<out.endIndex)?.lowerBound
                    ?? out.endIndex
                out.removeSubrange(close.lowerBound..<endOfLine)
            }
        }

        // Pass 2b — prompt-internal markers WE wrote into silent prompts.
        // `[autonomy ping — banter allowed]`, `[lifecycle_plan]`, etc.
        // These have spaces/punctuation inside the brackets so the
        // literal `[tag]` matcher above doesn't catch them. When the
        // agent echoes these back as part of a confused reply, they get
        // voiced as-is ("autonomy ping, banter allowed" — robotic, bad).
        //
        // Approach: any bracketed block whose FIRST word is one of our
        // known prompt-internal markers gets deleted from the opening
        // `[` through the closing `]` (single line, no nesting).
        let promptMarkers = [
            "autonomy ping", "autonomy_ping", "autonomy",
            "lifecycle_plan", "lifecycle plan",
            "silent plan tick",
            "reflection ping",
            "follow-up", "followup ping",
            "max-initiated chat", "max initiated chat",
            "ritual",
            "debug",
            "internal"
        ]
        for marker in promptMarkers {
            // Case-insensitive substring match inside a `[…]` block.
            while let open = out.range(of: "[", options: .literal) {
                guard let close = out.range(of: "]", options: .literal,
                                            range: open.upperBound..<out.endIndex) else { break }
                let inside = out[open.upperBound..<close.lowerBound]
                if inside.range(of: marker, options: .caseInsensitive) != nil {
                    out.removeSubrange(open.lowerBound..<close.upperBound)
                    continue  // scan again from beginning
                }
                // This bracket pair isn't a marker; bail to avoid
                // re-finding it every iteration. Strip handles subsequent
                // occurrences via the outer for-loop over markers.
                break
            }
        }
        } // end needsBracketPasses

        // Pass 2c — transcript prefixes. The `claude` CLI formats
        // conversations with `Human:` / `Assistant:` line prefixes; when
        // the agent's reply includes one, it reads as "the agent just
        // claimed a user turn," which is nonsense when voiced. Strip
        // any leading `Human:` or `Assistant:` on a line (plus blank
        // lines that follow, which are almost always the echo padding).
        let transcriptPrefixes = ["Human:", "Assistant:", "User:", "System:"]
        let prefixLines = out.split(separator: "\n", omittingEmptySubsequences: false)
        var filteredForPrefixes: [Substring] = []
        var skipUntilNonBlank = false
        for line in prefixLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if transcriptPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
                skipUntilNonBlank = true
                continue
            }
            if skipUntilNonBlank && trimmed.isEmpty {
                continue
            }
            skipUntilNonBlank = false
            filteredForPrefixes.append(line)
        }
        out = filteredForPrefixes.joined(separator: "\n")

        // Pass 2c.5 — partial-prefix lookahead. The line strip above
        // requires the full token (`Human:`) to match. During streaming
        // the chunks arrive token-by-token: "\n", "Human", ":", " ".
        // When `out` ends mid-prefix ("…\nHuman" before the colon
        // arrives), the line strip can't see it yet — but the voice
        // engine's incremental TTS happily speaks "human" in that
        // window, then the next chunk completes the prefix and the
        // strip silently removes it. Net effect: Max randomly says
        // "human" / "user" mid-reply.
        //
        // Fix: when `out` ends in a partial prefix word (case-insensitive,
        // letters-only tail at the very end of the buffer matching the
        // bare prefix without colon), elide that fragment. Worst case
        // we hold back one legitimate word for one extra token; in
        // practice the agent doesn't end replies on these words.
        let bareTokens = transcriptPrefixes.map { String($0.dropLast()) } // "Human", "Assistant", …
        // Find the start of the trailing alphabetic run.
        var tailStart = out.endIndex
        while tailStart > out.startIndex {
            let prev = out.index(before: tailStart)
            let ch = out[prev]
            if ch.isLetter { tailStart = prev } else { break }
        }
        if tailStart < out.endIndex {
            let tail = out[tailStart...]
            if bareTokens.contains(where: { $0.compare(String(tail), options: .caseInsensitive) == .orderedSame }) {
                // Trim the partial token AND any whitespace immediately
                // before it — otherwise we leave a trailing "\n " that
                // the voice engine treats as silence padding.
                var cut = tailStart
                while cut > out.startIndex {
                    let prev = out.index(before: cut)
                    if out[prev] == " " || out[prev] == "\t" || out[prev] == "\n" {
                        cut = prev
                    } else {
                        break
                    }
                }
                out = String(out[..<cut])
            }
        }

        // Pass 3 — bare JSON fragments. When the agent quotes its user_model
        // block without the surrounding tags, the remaining prose reads as
        // { ... } or "key": "value" lines. These never show up in natural
        // speech; stripping whole lines containing these markers is safe.
        //
        // Note: this is deliberately conservative. Legit code-containing
        // answers use fenced ``` blocks or inline backticks; users who
        // ask Max to write JSON usually get it inside markdown — that
        // format still has quote-colon patterns but ALSO has code fences
        // right next to them. We'd need a smarter heuristic for perfect
        // fidelity, but the common "agent echoes context" case has:
        //   - bare `{` or `}` on its own line
        //   - JSON-key lines without an enclosing fence
        // and those are what we're targeting.
        let userModelKeys = [
            "\"recent_mood_signal\":",
            "\"identity\":",
            "\"preferences\":",
            "\"runningThreads\":",
            "\"running_threads\":",
            "\"rituals\":",
            "\"refreshedAt\":",
            "\"synthesiserVersion\":",
            "\"refreshed_at\":"
        ]
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var insideFence = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                insideFence.toggle()
                kept.append(line)
                continue
            }
            if insideFence {
                kept.append(line)
                continue
            }
            // Bare `{` or `}` on a line — skip.
            if trimmed == "{" || trimmed == "}" || trimmed == "}," || trimmed == "}]," || trimmed == "]" || trimmed == "]," {
                continue
            }
            // Contains a user-model key outside a fence — skip.
            if userModelKeys.contains(where: { trimmed.contains($0) }) {
                continue
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }
}
