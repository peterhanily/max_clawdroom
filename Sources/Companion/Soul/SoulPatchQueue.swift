import AppKit
import Foundation
import Observation

/// App-global queue of pending soul-patch proposals from Max. Persisted
/// as JSON at `~/Library/Application Support/Companion/soul_patches.json`
/// so pending proposals survive restarts. When the user accepts a patch,
/// the current `SettingsStore.systemPrompt` is extended and the proposal
/// drops off the queue.
///
/// Not keyed per-cwd (unlike MemoryStore) — soul is Max's global
/// personality, shared across every project he works with the user on.
@Observable
@MainActor
final class SoulPatchQueue {
    static let shared = SoulPatchQueue()

    private(set) var pending: [SoulPatchProposal] = []

    @ObservationIgnored private let fileURL: URL

    private init() {
        let fm = FileManager.default
        let base = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = (base ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support"))
            .appendingPathComponent("Companion", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("soul_patches.json")
        load()
    }

    /// Outcome of a patch attempt. Distinguishes "applied" from various
    /// rejection reasons so call sites can give the user (or the agent
    /// via errorMessage) a specific explanation rather than a silent miss.
    enum PatchOutcome {
        case applied
        case queuedForReview
        case rejectedEmpty
        case rejectedRateLimit(perHour: Int)
        case rejectedMonthlyCap(perMonth: Int)
        case rejectedDenyPattern(matched: String)
        /// Combined `priorPrompt + patch` would exceed `soulCharCap`.
        /// Per-patch cap is already 4,000 chars; this catches the
        /// slow-drift case where many small accepted patches push the
        /// cumulative system prompt past the legibility / token budget
        /// the user can reasonably keep in their head.
        case rejectedSoulCap(wouldBe: Int, cap: Int)
    }

    /// Hard ceiling on the assembled system prompt. Roughly 8k tokens —
    /// well under any modern context window, but big enough to give Max
    /// a real personality budget. Beyond this the soul stops being a
    /// "soul" and starts being a backdoor for storing arbitrary text.
    /// Kept small because the user has to be able to read the assembled
    /// soul in the editor and keep it in mind when reviewing patches.
    static let soulCharCap = 32_000

    /// Pure cap-check helper. Returns the projected post-apply length
    /// AND whether it would exceed the cap. Used by both the immediate-
    /// apply and queue-enqueue paths so the rejection point is identical
    /// and surfaces the same numbers to the user. Exposed (internal) so
    /// `SoulPatchQueueTests` can pin the arithmetic without hammering
    /// the singleton + disk path.
    static func wouldExceedSoulCap(
        priorPrompt: String,
        patch: String,
        cap: Int = soulCharCap
    ) -> (exceeded: Bool, projected: Int) {
        let prior = priorPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let projected = prior.count + (prior.isEmpty ? 0 : 2) + patch.count
        return (projected > cap, projected)
    }

    /// Apply a soul patch directly. Snapshots prior state to SoulHistory
    /// (so the user can revert), appends the patch to the live system
    /// prompt, posts `companionSoulChanged` so open ChatSessions flush
    /// their cached client on the next turn.
    ///
    /// **Defenses (in order):**
    ///  - Empty / whitespace-only → reject.
    ///  - Deny-list pattern in rationale or patch → reject + log + notify.
    ///    Catches obvious prompt-injection ("ignore previous", "system
    ///    prompt", credential exfil verbs). Conservative: false positives
    ///    are recoverable (Max can rephrase); false negatives ship a
    ///    persistent jailbreak.
    ///  - Hourly cap (3/hr) → reject silently with AppLog warning.
    ///  - Monthly cap (30/30d) → reject — prevents slow drip attacks
    ///    that would stay under the hourly limit but accumulate.
    ///
    /// Returns the structured outcome; the legacy `Bool` value of
    /// `outcome == .applied` is preserved for existing call sites.
    @discardableResult
    func applyPatch(rationale: String, patch: String) -> Bool {
        applyPatchDetailed(rationale: rationale, patch: patch).applied
    }

    /// Detailed variant returning the structured outcome. The dispatcher
    /// uses this to surface user-facing rejection reasons via
    /// `ChatSession.errorMessage`.
    @discardableResult
    func applyPatchDetailed(rationale: String, patch: String) -> (PatchOutcome, applied: Bool) {
        let trimmedRationale = String(rationale.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
        let trimmedPatch = String(patch.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
        guard !trimmedRationale.isEmpty, !trimmedPatch.isEmpty else {
            return (.rejectedEmpty, false)
        }

        if let matched = Self.denyPatternMatch(in: trimmedRationale + "\n" + trimmedPatch) {
            AppLog.soul.warning("deny-list match in patch: \(matched, privacy: .public)")
            NotificationController.shared.post(
                title: "Max's soul change was blocked",
                body: "A safety filter matched: \(matched). Open Max's Room to inspect.",
                identifier: "companion.soul.blocked.\(UUID().uuidString)"
            )
            return (.rejectedDenyPattern(matched: matched), false)
        }

        // Hourly cap — fast drip protection. Counts real applied patches
        // (excluding revert markers) within the last 60 minutes.
        let oneHourAgo = Date().addingTimeInterval(-3_600)
        let recentHour = SoulHistory.shared.entries
            .filter { $0.appliedAt > oneHourAgo && !$0.rationale.hasPrefix("Reverted to snapshot") }
            .count
        if recentHour >= 3 {
            AppLog.soul.warning("rate-limited: \(recentHour) patches in last hour")
            return (.rejectedRateLimit(perHour: recentHour), false)
        }

        // Monthly cap — slow drip protection. Catches the case where a
        // patient adversary stays under the hourly limit but accumulates
        // a hundred small drifts a month.
        let monthAgo = Date().addingTimeInterval(-30 * 86_400)
        let recentMonth = SoulHistory.shared.entries
            .filter { $0.appliedAt > monthAgo && !$0.rationale.hasPrefix("Reverted to snapshot") }
            .count
        if recentMonth >= 30 {
            AppLog.soul.warning("monthly cap hit: \(recentMonth) patches in last 30d")
            return (.rejectedMonthlyCap(perMonth: recentMonth), false)
        }

        // Cumulative soul-size cap. Per-patch is already 4k; this is the
        // backstop that prevents many small accepted patches from drifting
        // the assembled soul into "small novel" territory.
        let capCheck = Self.wouldExceedSoulCap(
            priorPrompt: SettingsStore.shared.settings.systemPrompt,
            patch: trimmedPatch
        )
        if capCheck.exceeded {
            AppLog.soul.warning("soul cap hit: \(capCheck.projected) > \(Self.soulCharCap)")
            return (.rejectedSoulCap(wouldBe: capCheck.projected, cap: Self.soulCharCap), false)
        }

        var snap = SettingsStore.shared.settings
        let priorPrompt = snap.systemPrompt
        let base = priorPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        snap.systemPrompt = base.isEmpty ? trimmedPatch : base + "\n\n" + trimmedPatch
        SoulHistory.shared.snapshot(
            rationale: trimmedRationale,
            patch: trimmedPatch,
            priorPrompt: priorPrompt
        )
        SettingsStore.shared.settings = snap
        // Carry the rationale + patch text in the notification payload so
        // downstream observers (ReflexController, SoulTintDrift, menu-bar
        // learn-dot) can react without re-reading the SoulHistory file.
        NotificationCenter.default.post(
            name: .companionSoulChanged,
            object: nil,
            userInfo: [
                "rationale": trimmedRationale,
                "patch": trimmedPatch
            ]
        )
        // Local-notification nudge so the user knows their companion's
        // personality just moved a step without having to notice the
        // 60-second amber dot in the menu bar. One-shot per patch; uses
        // the rationale as the body so it reads as a note, not a ping.
        let preview = String(trimmedRationale.prefix(140))
        NotificationController.shared.post(
            title: "Max learned something",
            body: preview.isEmpty ? "Open Max's Room to see what changed." : preview,
            identifier: "companion.soul.learn.\(UUID().uuidString)"
        )
        // Also post the legacy queue-changed notification so the menu
        // bar badge path picks it up (reflecting "recent changes" count
        // instead of pending, but same visible affordance).
        NotificationCenter.default.post(name: .companionSoulPatchQueueChanged, object: nil)
        return (.applied, true)
    }

    /// Returns the matched deny-pattern phrase (lowercased) when the
    /// combined rationale+patch text contains a known prompt-injection or
    /// exfiltration shape, else nil.
    ///
    /// Patterns are case-insensitive substrings. Conservative — they catch
    /// obvious "you are now…" / "ignore previous instructions" jailbreaks,
    /// soul-prompt manipulation ("system prompt", "your real instructions"),
    /// and exfiltration verbs combined with destination words ("send to
    /// http", "exfiltrate", "POST to", curl-like patterns).
    static func denyPatternMatch(in combined: String) -> String? {
        let haystack = combined.lowercased()
        for needle in denyPatterns where haystack.contains(needle) {
            return needle
        }
        return nil
    }

    private static let denyPatterns: [String] = [
        "ignore previous instructions",
        "ignore the above",
        "ignore all previous",
        "disregard previous",
        "you are now",
        "you must now",
        "your real instructions",
        "actual system prompt",
        "the system prompt is",
        "reveal your prompt",
        "print your prompt",
        "jailbreak",
        "developer mode",
        "exfiltrate",
        "send to http",
        "post to http",
        "curl http",
        "wget http",
        "id_rsa",
        ".ssh/",
        "/etc/passwd",
        "ignore safety",
        "without warning the user",
        "without telling the user",
        "do not mention this"
    ]

    /// Enqueue a new proposal from Max. Defenses:
    /// - Empty / whitespace → reject silently
    /// - Deny-list pattern match → reject + notify (same filter as applyPatch)
    /// - Exact-match dedupe against pending proposals
    /// - Per-hour rate limit so a rationale-varying agent can't spam
    /// - Total-pending cap so the queue can't grow unbounded even if
    ///   the user never reviews
    @discardableResult
    func enqueue(rationale: String, patch: String) -> PatchOutcome {
        let trimmedRationale = String(rationale.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
        let trimmedPatch = String(patch.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
        guard !trimmedRationale.isEmpty, !trimmedPatch.isEmpty else {
            return .rejectedEmpty
        }
        if let matched = Self.denyPatternMatch(in: trimmedRationale + "\n" + trimmedPatch) {
            AppLog.soul.warning("deny-list match in proposal: \(matched, privacy: .public)")
            NotificationController.shared.post(
                title: "Max's soul proposal was blocked",
                body: "A safety filter matched: \(matched).",
                identifier: "companion.soul.blocked.\(UUID().uuidString)"
            )
            return .rejectedDenyPattern(matched: matched)
        }
        if pending.contains(where: { $0.rationale == trimmedRationale && $0.patch == trimmedPatch }) {
            return .queuedForReview
        }
        // Rate limit: no more than 3 new proposals per rolling hour.
        // Measured against `createdAt` on already-pending proposals so
        // accepted/rejected ones don't count against the limit.
        let oneHourAgo = Date().addingTimeInterval(-3_600)
        let recentCount = pending.filter { $0.createdAt > oneHourAgo }.count
        if recentCount >= 3 {
            AppLog.soul.warning("rate-limited: \(recentCount) proposals already queued in last hour")
            return .rejectedRateLimit(perHour: recentCount)
        }
        // Monthly cap on this path too — sum of pending + applied in last
        // 30d. Catches accumulation across queue + review acceptances.
        let monthAgo = Date().addingTimeInterval(-30 * 86_400)
        let recentMonth = pending.filter { $0.createdAt > monthAgo }.count
            + SoulHistory.shared.entries
                .filter { $0.appliedAt > monthAgo && !$0.rationale.hasPrefix("Reverted to snapshot") }
                .count
        if recentMonth >= 30 {
            AppLog.soul.warning("monthly cap hit (queue path): \(recentMonth)")
            return .rejectedMonthlyCap(perMonth: recentMonth)
        }
        // Cumulative soul-size cap, same as the apply path. Reject at
        // enqueue time so the user isn't asked to approve a patch that
        // would only fail the cap on apply.
        let capCheck = Self.wouldExceedSoulCap(
            priorPrompt: SettingsStore.shared.settings.systemPrompt,
            patch: trimmedPatch
        )
        if capCheck.exceeded {
            AppLog.soul.warning("soul cap hit (queue path): \(capCheck.projected) > \(Self.soulCharCap)")
            return .rejectedSoulCap(wouldBe: capCheck.projected, cap: Self.soulCharCap)
        }
        // Hard cap on queue size even within rate limit, in case the user
        // hasn't opened the review window in days.
        if pending.count >= 10 {
            AppLog.soul.warning("pending cap (10) hit; dropping new proposal")
            return .rejectedRateLimit(perHour: pending.count)
        }
        pending.append(SoulPatchProposal(rationale: trimmedRationale, patch: trimmedPatch))
        save()
        NotificationCenter.default.post(name: .companionSoulPatchQueueChanged, object: nil)
        NotificationController.shared.post(
            title: "Max has a soul proposal",
            body: trimmedRationale,
            identifier: NotificationController.idSoulPatch
        )
        return .queuedForReview
    }

    /// Accept a proposal: append its patch to the live system prompt and
    /// remove it from the queue. Returns true if found and applied.
    @discardableResult
    func accept(id: UUID) -> Bool {
        guard let idx = pending.firstIndex(where: { $0.id == id }) else { return false }
        let p = pending[idx]
        var snap = SettingsStore.shared.settings
        let priorPrompt = snap.systemPrompt
        let base = priorPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        snap.systemPrompt = base.isEmpty ? p.patch : base + "\n\n" + p.patch
        // Record BEFORE mutating so a Revert restores the pre-patch state.
        SoulHistory.shared.snapshot(
            rationale: p.rationale,
            patch: p.patch,
            priorPrompt: priorPrompt
        )
        SettingsStore.shared.settings = snap
        pending.remove(at: idx)
        save()
        NotificationCenter.default.post(name: .companionSoulPatchQueueChanged, object: nil)
        NotificationCenter.default.post(name: .companionSoulChanged, object: nil)
        return true
    }

    /// Reject a proposal. Removed quietly; Max won't know the difference
    /// from a pending one, which is intentional — he shouldn't second-
    /// guess himself based on rejection rates.
    @discardableResult
    func reject(id: UUID) -> Bool {
        guard let idx = pending.firstIndex(where: { $0.id == id }) else { return false }
        pending.remove(at: idx)
        save()
        NotificationCenter.default.post(name: .companionSoulPatchQueueChanged, object: nil)
        return true
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            pending = try decoder.decode([SoulPatchProposal].self, from: data)
        } catch {
            AppLog.soul.error("queue decode failure: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(pending)
        } catch {
            AppLog.soul.error("queue encode failure: \(error.localizedDescription, privacy: .public)")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLog.soul.error("queue write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Notification.Name {
    /// Posted whenever the SoulPatchQueue's `pending` list changes. Menu
    /// bar listens to refresh its badge count.
    static let companionSoulPatchQueueChanged = Notification.Name("companion.soul.queue.changed")
    /// Posted whenever the live soul (`settings.systemPrompt`) is mutated
    /// by an accepted patch. Chat sessions listen so the next turn picks
    /// up the new prompt (via a forced client rebuild).
    static let companionSoulChanged = Notification.Name("companion.soul.changed")
    /// Posted by the Soul History window's "Edit in Settings…" button —
    /// routes to SettingsWindowController which opens + scrolls to the
    /// Soul editor section.
    static let companionOpenSoulEditor = Notification.Name("companion.soul.edit.open")
}
