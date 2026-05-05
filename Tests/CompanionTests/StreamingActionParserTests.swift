import XCTest
@testable import Companion

/// Boundary-condition tests for `ActionParser.process(raw:from:)`
/// — the streaming action-tag parser. The hard cases live where stream
/// chunks split mid-tag: a chunk ending with `[`, `[a`, `[act…` looks
/// like safe text but is actually the prefix of an opener. Flushing it
/// would leave the next chunk unable to find a complete `[action]` and
/// either drop the action silently OR (worse) speak the leftover prose
/// aloud as "ction]…".
///
/// The parser handles this via `ambiguousOpenerSuffixLength` — these
/// tests pin its contract end-to-end. Each test simulates the exact
/// re-call shape ChatSession does: feed the parser progressively
/// longer raw strings, advance the cursor returned, and check that
/// (a) all actions fire eventually, (b) no opener-prefix bytes leak
/// into safe (display / voice) output along the way, (c) cursor
/// advances monotonically.
@MainActor
final class StreamingActionParserTests: XCTestCase {

    // MARK: - Simple full-buffer parse

    func test_fullCompleteAction_parsesInOnePass() {
        let raw = #"hello [action]{"op":"set_expression","value":"happy"}[/action] world"#
        let (display, actions) = ActionParser.process(fullText: raw)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.op, "set_expression")
        XCTAssertEqual(display, "hello  world")
    }

    func test_noAction_passesProseThrough() {
        let raw = "no action tags here at all"
        let (display, actions) = ActionParser.process(fullText: raw)
        XCTAssertEqual(actions.count, 0)
        XCTAssertEqual(display, raw)
    }

    // MARK: - Streaming with ambiguous suffix

    /// Helper: drive `process(raw:from:)` chunk-by-chunk and assemble
    /// the final actions list + safe display + cursor trace. Mirrors
    /// the call shape ChatSession uses while a stream is in flight.
    private func driveStreaming(_ chunks: [String]) -> (
        safe: String,
        actions: [MaxClawdroomAction],
        cursors: [Int]
    ) {
        var raw = ""
        var cursor = 0
        var safe = ""
        var actions: [MaxClawdroomAction] = []
        var cursors: [Int] = []
        for chunk in chunks {
            raw += chunk
            let result = ActionParser.process(raw: raw, from: cursor)
            safe += result.safeDisplay
            actions.append(contentsOf: result.actions)
            cursor = result.nextCursor
            cursors.append(cursor)
        }
        // Final flush — call once more from the held cursor over the
        // full buffer; this is what ChatSession does when the stream
        // ends to flush any held-back prefix that ended up being safe.
        let final = ActionParser.process(raw: raw, from: cursor)
        safe += final.safeDisplay + final.unsafeDisplay
        actions.append(contentsOf: final.actions)
        return (safe, actions, cursors)
    }

    private struct StreamResult {
        let safe: String
        let actions: [MaxClawdroomAction]
        let cursors: [Int]
    }

    func test_actionSplitAtOpenerBoundary_holdsPrefixThenCompletes() {
        // Chunk 1 ends with `[` — must NOT be flushed as safe text,
        // because chunk 2 turns it into a real `[action]…` opener.
        let result = driveStreaming([
            "before text [",
            #"action]{"op":"set_expression","value":"happy"}[/action] after"#
        ])
        XCTAssertEqual(result.actions.count, 1)
        XCTAssertEqual(result.actions.first?.op, "set_expression")
        XCTAssertFalse(result.safe.contains("[action]"))
        XCTAssertFalse(result.safe.contains("ction]"),
                       "leftover bytes from a held opener prefix must NOT leak into safe output")
        XCTAssertTrue(result.safe.contains("before text"))
        XCTAssertTrue(result.safe.contains(" after"))
    }

    func test_actionSplitMidOpenerToken_eachPartialPrefixIsHeld() {
        // Stream the opener byte-by-byte — every partial prefix
        // (`[`, `[a`, `[ac`, … `[action`) must be held back until the
        // next chunk resolves it. Final result identical to one-shot.
        let result = driveStreaming([
            "x ", "[", "a", "c", "t", "i", "o", "n", "]",
            #"{"op":"walk","x":1}[/action] y"#
        ])
        XCTAssertEqual(result.actions.count, 1)
        XCTAssertEqual(result.actions.first?.op, "walk")
        XCTAssertFalse(result.safe.contains("[action]"))
        XCTAssertFalse(result.safe.lowercased().contains("ction"),
                       "no partial-opener bytes should land in safe stream")
    }

    func test_actionSplitMidJSON_unsafeRegionRetried() {
        // Splitting AFTER `[action]` opens an unclosed-action state.
        // The parser should hold from `[action]` onward as unsafe; the
        // next chunk completes the JSON + closer.
        let result = driveStreaming([
            #"hello [action]{"op":"set_expression","value":"hap"#,
            #"py"}[/action] tail"#
        ])
        XCTAssertEqual(result.actions.count, 1)
        XCTAssertEqual(result.actions.first?.op, "set_expression")
        XCTAssertEqual(result.actions.first?.args["value"] as? String, "happy")
        XCTAssertFalse(result.safe.contains("[action]"))
    }

    func test_actionSplitInCloserToken_eventuallyCompletes() {
        // Split right inside the `[/action]` closer — three chunks,
        // closer's bytes streamed across the second/third boundary.
        let result = driveStreaming([
            #"x [action]{"op":"walk","y":2}[/"#,
            #"action]"#,
            " y"
        ])
        XCTAssertEqual(result.actions.count, 1)
        XCTAssertEqual(result.actions.first?.op, "walk")
    }

    // MARK: - Multiple actions

    func test_twoActionsWithMidSplit_bothFire() {
        let result = driveStreaming([
            #"a [action]{"op":"set_expression","value":"focused"}[/action] b ["#,
            #"action]{"op":"walk","x":3}[/action] c"#
        ])
        XCTAssertEqual(result.actions.count, 2)
        XCTAssertEqual(result.actions[0].op, "set_expression")
        XCTAssertEqual(result.actions[1].op, "walk")
    }

    // MARK: - Cursor monotonicity

    func test_cursorAdvancesMonotonically_acrossChunks() {
        let result = driveStreaming([
            "before ",
            #"[action]{"op":"walk"}[/action]"#,
            " middle [",
            #"action]{"op":"set_expression","value":"happy"}[/action]"#,
            " end"
        ])
        XCTAssertEqual(result.actions.count, 2)
        // Cursor must be non-decreasing across chunks; the parser's
        // contract is that `nextCursor` only advances or stays put,
        // never rewinds (which would re-emit the same actions).
        for i in 1..<result.cursors.count {
            XCTAssertGreaterThanOrEqual(
                result.cursors[i], result.cursors[i - 1],
                "cursor regressed at chunk \(i): \(result.cursors)"
            )
        }
    }

    // MARK: - Lookalikes that must NOT trigger holdback

    func test_squareBracketProseDoesNotTriggerHoldback() {
        // Plain `[` followed by non-opener content shouldn't get held
        // back forever — the parser checks against `[action]` exactly,
        // and a `[` followed by ` ` falls outside the prefix set.
        let result = driveStreaming([
            "see [important] note",
            " — done"
        ])
        XCTAssertEqual(result.actions.count, 0)
        XCTAssertTrue(result.safe.contains("[important]"))
    }
}
