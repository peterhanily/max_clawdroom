import XCTest
@testable import Companion

/// Pure-arithmetic tests for the cumulative soul-size cap. The
/// SoulPatchQueue singleton itself has disk + Settings side effects we
/// don't want to hammer in unit tests (matches ChannelStoreTests'
/// "don't touch the singleton" note), so the live cap-check call is
/// factored into `wouldExceedSoulCap` which we can pin here without
/// any I/O.
@MainActor
final class SoulPatchQueueTests: XCTestCase {

    func test_cap_clearlyUnderLimit_doesNotExceed() {
        let result = SoulPatchQueue.wouldExceedSoulCap(
            priorPrompt: String(repeating: "a", count: 1_000),
            patch: String(repeating: "b", count: 100)
        )
        XCTAssertFalse(result.exceeded)
        XCTAssertEqual(result.projected, 1_000 + 2 + 100)
    }

    func test_cap_emptyPriorPrompt_skipsSeparator() {
        // Empty prior must NOT add the +2 separator — first patch
        // becomes the entire soul, no leading newlines.
        let result = SoulPatchQueue.wouldExceedSoulCap(
            priorPrompt: "",
            patch: String(repeating: "c", count: 50)
        )
        XCTAssertFalse(result.exceeded)
        XCTAssertEqual(result.projected, 50,
                       "empty prior must not contribute the separator")
    }

    func test_cap_whitespaceOnlyPriorPrompt_skipsSeparator() {
        // Whitespace-only prior trims to empty → same path as empty.
        let result = SoulPatchQueue.wouldExceedSoulCap(
            priorPrompt: "   \n\n   ",
            patch: "x"
        )
        XCTAssertFalse(result.exceeded)
        XCTAssertEqual(result.projected, 1)
    }

    func test_cap_atLimitExactly_doesNotExceed() {
        // Edge: projected == cap → NOT exceeded (`>` not `>=`). A patch
        // that lands exactly at the cap should still apply; the cap is
        // a ceiling, not a target.
        let prior = String(repeating: "p", count: 100)
        let patchLen = SoulPatchQueue.soulCharCap - 100 - 2
        let result = SoulPatchQueue.wouldExceedSoulCap(
            priorPrompt: prior,
            patch: String(repeating: "q", count: patchLen)
        )
        XCTAssertFalse(result.exceeded)
        XCTAssertEqual(result.projected, SoulPatchQueue.soulCharCap)
    }

    func test_cap_oneOverLimit_exceeds() {
        // Edge: projected == cap + 1 → exceeded.
        let prior = String(repeating: "p", count: 100)
        let patchLen = SoulPatchQueue.soulCharCap - 100 - 2 + 1
        let result = SoulPatchQueue.wouldExceedSoulCap(
            priorPrompt: prior,
            patch: String(repeating: "q", count: patchLen)
        )
        XCTAssertTrue(result.exceeded)
        XCTAssertEqual(result.projected, SoulPatchQueue.soulCharCap + 1)
    }

    func test_cap_customCap_overridable() {
        // Tests + future tooling can pass a tighter cap; the function
        // honours the parameter rather than hard-coding to soulCharCap.
        let result = SoulPatchQueue.wouldExceedSoulCap(
            priorPrompt: "abc",
            patch: "defg",
            cap: 5
        )
        XCTAssertTrue(result.exceeded)
        XCTAssertEqual(result.projected, 3 + 2 + 4)
    }

    func test_soulCharCap_constantIsAround8kTokens() {
        // 32k chars ≈ 8k tokens at standard ~4 chars/token. Pin so a
        // future careless edit doesn't draw it down to something tiny
        // (which would reject most patches) or push it past a context
        // budget — the comment on the constant is the source of truth.
        XCTAssertEqual(SoulPatchQueue.soulCharCap, 32_000)
    }
}
