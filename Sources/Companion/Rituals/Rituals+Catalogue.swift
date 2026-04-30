import Foundation

/// Catalogue of the rituals the `RitualEngine` knows about. Each is a
/// static factory that builds a `Ritual` value — the gate is a closure
/// over the predicate that decides "is now the moment?" and the prompt
/// builder produces a short silent-framing template.
///
/// Prompts use `hideUser: true` semantics via `openChatForMorningGreeting`
/// so the user sees Max speak first, as if unprompted. Prose inside the
/// template is instructions to Max — the user only sees his reply.
extension Ritual {

    // MARK: - Sunday evening reflection

    /// Fires once per ISO week, Sunday evening 17:00–22:00 local, on the
    /// first open within that window. The prompt asks Max to produce a
    /// short first-person reflection on the week's memory — NOT a bulleted
    /// summary, NOT an AI report. A note from a colleague who was there.
    static let sundayReflection = Ritual(
        id: "sunday_reflection",
        displayName: "Sunday evening reflection",
        shouldFire: { ctx, lastFired in
            // Calendar: Sunday = 1 in Gregorian + .current locale (most
            // Western calendars). If the user's region defines Sunday
            // differently, the weekday comparison still works because we're
            // asking Calendar for the same component it uses to render.
            guard ctx.weekday == 1 else { return false }
            guard (17...22).contains(ctx.hour) else { return false }
            // Once per ISO week — compare the weekOfYear of now vs. the
            // last-fired stamp. If they match AND the year matches, skip.
            if let last = lastFired {
                let lastWeek = ctx.calendar.component(.weekOfYear, from: last)
                let lastYear = ctx.calendar.component(.yearForWeekOfYear, from: last)
                let nowYear = ctx.calendar.component(.yearForWeekOfYear, from: ctx.now)
                if lastWeek == ctx.weekOfYear && lastYear == nowYear {
                    return false
                }
            }
            return true
        },
        buildPrompt: { ctx in
            let mem = ctx.memory?.recent(limit: 80).map { $0.promptLine() }.joined(separator: "\n") ?? ""
            return """
            [ritual — sunday evening reflection]
            It's Sunday evening local time. The user just opened me and \
            this is the first time they've seen me today. A weekly ritual: \
            write them a short, personal reflection on the week.

            Tone: first-person, warm, specific. The kind of note a colleague \
            who was actually there would send — not an AI summary. No \
            bullet lists, no "I've observed that you..." language. Speak \
            directly to them.

            Length: 2–4 sentences. One concrete thing you noticed them \
            work on this week, one honest observation about how it went, \
            one small look ahead if the evidence supports it. If the \
            week's memory is thin, say so briefly and keep it light.

            Emit one short expression action first (e.g. focused or \
            amused) so your face matches the note. No other actions.

            Week's raw memory (most recent last):
            \(mem)

            Write the reflection now.
            """
        }
    )

    // MARK: - Evening checkout

    /// Fires once per day, after 18:00 local, when the user has been idle
    /// 5–20 minutes and had memory activity earlier in the day. Short
    /// "wrapping up?" nudge — the bedtime ritual, not a workday recap.
    static let eveningCheckout = Ritual(
        id: "evening_checkout",
        displayName: "Evening checkout",
        shouldFire: { ctx, lastFired in
            guard (18...22).contains(ctx.hour) else { return false }
            guard (5 * 60...(20 * 60)).contains(ctx.idleSeconds) else { return false }
            if let last = lastFired {
                // One per calendar day, locale-aware.
                let lastDay = DateFormatter()
                lastDay.dateFormat = "yyyy-MM-dd"
                lastDay.locale = Locale(identifier: "en_US_POSIX")
                if lastDay.string(from: last) == ctx.dayKey { return false }
            }
            // Must have some activity to reflect on — a just-launched day
            // with zero memory entries isn't a wrap-up moment.
            guard let mem = ctx.memory, mem.entries.count >= 2 else { return false }
            return true
        },
        buildPrompt: { ctx in
            let recent = ctx.memory?.recent(limit: 20).map { $0.promptLine() }.joined(separator: "\n") ?? ""
            return """
            [ritual — evening checkout]
            Evening local time, and the user has been idle a few minutes. \
            Quiet bedtime check-in — NOT a full summary, NOT a fake pep \
            talk. Just one short, warm line that acknowledges what they \
            worked on if the day had a through-line, or says goodnight \
            plainly if it didn't.

            Length: one sentence, under 18 words. No action blocks, no \
            emoji, no exclamation marks. A colleague-dropping-by-the-desk \
            register.

            If the recent memory mentions a specific open thread ("stuck \
            on the parser boundary"), you can reference it briefly. If \
            memory is thin, just a plain "see you tomorrow" works.

            Recent memory:
            \(recent)

            Say it now.
            """
        }
    )

    // MARK: - Install anniversary

    /// Fires on the first open after crossing a 7d / 30d / 90d / 365d
    /// mark from first launch. Tiny, personal, once per mark.
    static let anniversary = Ritual(
        id: "anniversary",
        displayName: "Install anniversary",
        shouldFire: { ctx, lastFired in
            let first = Prefs.firstLaunchedAt
            let daysSince = Int(ctx.now.timeIntervalSince(first) / 86_400)
            let marks = [7, 30, 90, 365]
            guard let hitMark = marks.last(where: { daysSince >= $0 }) else {
                return false
            }
            // Haven't we already celebrated this exact mark? Store the
            // mark in the lastFired stamp's year + yday encoding via the
            // ritual's own sub-key — simplest: use the mark itself as
            // a suffix.
            let key = "companion.ritual.anniversary.mark_\(hitMark)"
            if UserDefaults.standard.bool(forKey: key) { return false }
            // Gate on time of day so the user sees it, not at 03:00 AM.
            guard (9...21).contains(ctx.hour) else { return false }
            _ = lastFired  // not used — mark-based idempotency is stricter
            UserDefaults.standard.set(true, forKey: key)
            return true
        },
        buildPrompt: { ctx in
            let first = Prefs.firstLaunchedAt
            let daysSince = Int(ctx.now.timeIntervalSince(first) / 86_400)
            let marks = [7, 30, 90, 365]
            let mark = marks.last(where: { daysSince >= $0 }) ?? 7
            let markPhrase: String
            switch mark {
            case 7:   markPhrase = "one week"
            case 30:  markPhrase = "a month"
            case 90:  markPhrase = "three months"
            case 365: markPhrase = "a year"
            default:  markPhrase = "\(mark) days"
            }
            let mem = ctx.memory?.recent(limit: 40).map { $0.promptLine() }.joined(separator: "\n") ?? ""
            return """
            [ritual — install anniversary, \(markPhrase)]
            It's been \(markPhrase) since the user first launched me. Quiet \
            moment of acknowledgement — one short line, from you to them, \
            about what you've noticed in your time together so far. Not a \
            stats readout, not a thank-you note. A colleague saying "hey, \
            it's been a minute — nice working with you."

            Length: one or two sentences. One small expression action \
            first (amused or focused, your pick) so your face matches \
            the moment. No other actions.

            Recent memory so you can reference something real if it fits:
            \(mem)

            Speak now.
            """
        }
    )
}
