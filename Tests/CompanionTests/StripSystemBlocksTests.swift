import XCTest
@testable import Companion

/// Regression tests for `ChatSession.stripSystemBlocks` — the agent-
/// reply sanitiser that has produced more user-visible bugs in a
/// single session than any other piece of code.
///
/// Coverage is biased toward the failure modes we've actually shipped:
///   - `Human:` leaking when the reply contained no other punctuation
///   - `Human` (no colon) speaking aloud during streaming when the
///     trailing-prefix lookahead missed a pure-text buffer
///   - `<system-reminder>` blocks across newlines
///   - matched-pair `[env]` / `[world]` etc. tags
///
/// Test names describe the exact failure they prevent so a future
/// regression here points straight at the production bug it would
/// have caused.
@MainActor
final class StripSystemBlocksTests: XCTestCase {

    // MARK: - Transcript prefixes (the Human: bug family)

    func test_strips_full_human_prefix_line() {
        let input = "Some prose.\nHuman: this should not appear.\nMore prose."
        let out = ChatSession.stripSystemBlocks(input)
        XCTAssertFalse(out.contains("Human:"))
        XCTAssertTrue(out.contains("Some prose."))
        XCTAssertTrue(out.contains("More prose."))
    }

    func test_strips_human_prefix_when_buffer_has_no_brackets_or_quotes() {
        // 065e353 / f821f53 regression. The early-out at the top of
        // stripSystemBlocks short-circuited when the buffer had no
        // `[`, `{`, or `"`, bypassing the transcript-prefix strip.
        // A reply like this landed unstripped in chat AND voice.
        let input = "Human: Hello there!"
        let out = ChatSession.stripSystemBlocks(input)
        XCTAssertFalse(out.contains("Human:"))
    }

    func test_strips_partial_trailing_prefix_during_streaming() {
        // The streaming chunks arrive token-by-token: "\n", "Human", ":".
        // Between the "Human" chunk and the ":" chunk the cumulative
        // buffer ends "...\nHuman" with no colon yet. The line-strip
        // can't see the prefix at that moment; the lookahead pass has
        // to trim the trailing word so voice doesn't speak "human".
        let mid = "I told him.\nHuman"
        let out = ChatSession.stripSystemBlocks(mid)
        XCTAssertEqual(
            out.trimmingCharacters(in: .whitespacesAndNewlines),
            "I told him."
        )
    }

    func test_does_not_strip_human_in_prose() {
        // "Human" mid-sentence isn't a transcript prefix. Don't false-
        // strip — the user can talk about humans without hiding the word.
        let input = "Every human is unique."
        let out = ChatSession.stripSystemBlocks(input)
        XCTAssertEqual(out, "Every human is unique.")
    }

    func test_strips_assistant_user_system_prefixes_too() {
        for prefix in ["Assistant:", "User:", "System:"] {
            let input = "Hello.\n\(prefix) something private.\nGoodbye."
            let out = ChatSession.stripSystemBlocks(input)
            XCTAssertFalse(out.contains(prefix), "Failed for \(prefix)")
            XCTAssertTrue(out.contains("Hello."))
            XCTAssertTrue(out.contains("Goodbye."))
        }
    }

    // MARK: - Bracket / XML tag pairs

    func test_strips_matched_env_block() {
        let input = "Hi.\n[env] time=14:22 [/env]\nReady."
        let out = ChatSession.stripSystemBlocks(input)
        XCTAssertFalse(out.contains("[env]"))
        XCTAssertFalse(out.contains("time=14:22"))
        XCTAssertTrue(out.contains("Hi."))
        XCTAssertTrue(out.contains("Ready."))
    }

    func test_strips_matched_world_block() {
        let input = "[world] weather=Clear [/world] All set."
        let out = ChatSession.stripSystemBlocks(input)
        XCTAssertFalse(out.contains("[world]"))
        XCTAssertFalse(out.contains("weather=Clear"))
        XCTAssertTrue(out.contains("All set."))
    }

    func test_strips_system_reminder_xml_block() {
        let input = "Sure.<system-reminder>internal note</system-reminder> Done."
        let out = ChatSession.stripSystemBlocks(input)
        XCTAssertFalse(out.contains("system-reminder"))
        XCTAssertFalse(out.contains("internal note"))
        XCTAssertTrue(out.contains("Sure."))
        XCTAssertTrue(out.contains("Done."))
    }

    func test_does_not_strip_orphan_system_reminder_opener_mid_stream() {
        // Matched-pair only: an unclosed `<system-reminder>` opener
        // streaming in mid-reply must NOT zero the whole buffer.
        // Earlier orphan-handling did exactly that and the user saw
        // Max go silent for several seconds. Here the closer hasn't
        // arrived yet — strip should leave the buffer alone (the
        // pass strips when the matched closer eventually lands).
        let mid = "Sure thing.<system-reminder>not yet closed"
        let out = ChatSession.stripSystemBlocks(mid)
        XCTAssertTrue(out.contains("Sure thing."))
    }

    // MARK: - Fingerprint defense

    func test_drops_entire_reply_on_autonomy_prompt_echo() {
        // When the agent echoes a harness prompt back as prose, the
        // fingerprint pass drops the whole reply. Without this we'd
        // read the user's own context aloud.
        let input = """
            Sure thing.
            You're alive on the user's desktop. Use the [env] block …
            """
        let out = ChatSession.stripSystemBlocks(input)
        XCTAssertEqual(out, "")
    }
}
