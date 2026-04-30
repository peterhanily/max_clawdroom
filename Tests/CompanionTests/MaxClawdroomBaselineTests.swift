import XCTest
@testable import Companion

/// `MaxClawdroomBaseline` is the single source of truth for revert-to-
/// default. Bugs here mean either:
///   - the menu's "Revert to Baseline" leaves something stuck, or
///   - the agent thinks "normal" means something different than the
///     menu does.
///
/// Tests pin the contract instead of the values: the *shape* of the
/// sequence stays correct (mode first, valid op names, no empties)
/// while the actual hex / preset values can change without touching
/// the tests.
@MainActor
final class MaxClawdroomBaselineTests: XCTestCase {

    func test_revert_sequence_is_non_empty() {
        XCTAssertFalse(MaxClawdroomBaseline.revertSequence.isEmpty)
    }

    func test_revert_starts_with_set_mode() {
        // Mode must reset BEFORE body work, because body builds /
        // overlay sizing read the active mode for camera-distance
        // assumptions. If mode comes after, "revert from TV mode"
        // produces the wrong sized overlay until the next manual
        // mode switch.
        XCTAssertEqual(
            MaxClawdroomBaseline.revertSequence.first?.op,
            "set_mode"
        )
    }

    func test_revert_includes_chat_theme_reset() {
        // Earlier the sequence only reset chat font, leaving border /
        // user-bubble / panel colors at whatever the agent had last
        // set them to. reset_chat_theme covers all chat surfaces in
        // one op.
        let ops = MaxClawdroomBaseline.revertSequence.map(\.op)
        XCTAssertTrue(ops.contains("reset_chat_theme"))
    }

    func test_revert_resets_voice_filter_to_off() {
        // The Max-Headroom DSP filter is OPT-IN, not the default.
        // Revert must explicitly turn it off in case the agent or
        // user enabled it for a character moment.
        let voiceFilter = MaxClawdroomBaseline.revertSequence.first {
            $0.op == "set_voice_filter"
        }
        XCTAssertNotNil(voiceFilter)
        XCTAssertEqual(voiceFilter?.args["enabled"] as? Bool, false)
    }

    func test_revert_drops_all_props() {
        let ops = MaxClawdroomBaseline.revertSequence.map(\.op)
        XCTAssertTrue(ops.contains("drop_all_props"))
    }

    func test_revert_resets_scale_to_unity() {
        let scaleStep = MaxClawdroomBaseline.revertSequence.first {
            $0.op == "set_scale"
        }
        XCTAssertNotNil(scaleStep)
        XCTAssertEqual(scaleStep?.args["scale"] as? Double, 1.0)
    }

    func test_no_unknown_op_names_in_sequence() {
        // Every op in the revert sequence should be one the
        // dispatcher actually handles. This list mirrors the cases
        // in MaxClawdroomActions.dispatch — extending the dispatcher
        // requires extending this list, which is exactly the audit
        // we want.
        let known: Set<String> = [
            "set_mode", "set_outfit_preset", "set_hair", "set_grooming",
            "set_physique", "set_expression", "toggle_glasses",
            "drop_all_props", "set_scale", "reset_colors",
            "set_voice", "set_voice_filter",
            "reset_chat_theme", "set_chat_font"
        ]
        for (op, _) in MaxClawdroomBaseline.revertSequence {
            XCTAssertTrue(
                known.contains(op),
                "Baseline references op `\(op)` not in known dispatcher set"
            )
        }
    }

    func test_prompt_block_advertises_revert_to_baseline_op() {
        // The agent's only programmatic awareness of the revert is
        // this prompt block. If it stops mentioning the op, Max
        // can't fire it self-directedly.
        let block = MaxClawdroomBaseline.promptBlock()
        XCTAssertTrue(block.contains("revert_to_baseline"))
    }
}
