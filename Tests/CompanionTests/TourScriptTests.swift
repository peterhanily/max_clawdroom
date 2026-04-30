import XCTest
@testable import Companion

/// Tour-script integrity. The tour is the first interaction most
/// new users have with Max — every action it fires must be one
/// the dispatcher actually handles, every prop / expression / mode
/// it references must exist, and the timings can't go absurdly long.
///
/// Pure data-shape checks: we don't run the actions (that needs a
/// scene graph + main run loop). We just verify the script is
/// internally consistent so a typo or rename here won't ship a
/// broken first impression.
@MainActor
final class TourScriptTests: XCTestCase {

    func test_steps_non_empty() {
        XCTAssertFalse(TourScript.steps.isEmpty)
    }

    func test_every_step_has_narration_or_actions() {
        // A step with neither is dead time — the user just stares
        // at Max for `dwell` seconds with nothing happening.
        for (idx, step) in TourScript.steps.enumerated() {
            let hasContent =
                !step.narration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !step.actions.isEmpty
            XCTAssertTrue(
                hasContent,
                "Tour step \(idx) has no narration AND no actions"
            )
        }
    }

    func test_action_ops_are_known() {
        // Mirror of MaxClawdroomActions.dispatch's switch — every
        // op the tour fires has to have a case in the dispatcher.
        // Not exhaustive of all dispatcher ops; just the subset
        // we use in the tour today.
        let known: Set<String> = [
            "greet", "set_expression", "walk", "set_part_color",
            "hold_prop", "drop_prop", "set_mode", "set_chat_color",
            "jitter", "look_around", "nod", "wave"
        ]
        for (idx, step) in TourScript.steps.enumerated() {
            for action in step.actions {
                XCTAssertTrue(
                    known.contains(action.op),
                    "Tour step \(idx) fires unknown op `\(action.op)`"
                )
            }
        }
    }

    func test_dwell_is_bounded() {
        // Cap the visible per-step dwell at 6 seconds so a runaway
        // value can't make a step feel broken. Legit beats are
        // 1.0–3.0s; anything longer in the script is almost
        // certainly a typo.
        for (idx, step) in TourScript.steps.enumerated() {
            XCTAssertLessThanOrEqual(
                step.dwell, 6.0,
                "Tour step \(idx) dwell \(step.dwell)s is suspiciously long"
            )
            XCTAssertGreaterThanOrEqual(
                step.dwell, 0,
                "Tour step \(idx) dwell is negative"
            )
        }
    }

    func test_action_delays_non_negative_and_bounded() {
        // `runStep` awaits all action delays BEFORE applying `dwell`,
        // so a per-action delay can exceed step.dwell without
        // misfiring (the step just takes longer overall). What we
        // do check: delays are non-negative and within a sane upper
        // bound — anything past 5s within a single step is almost
        // certainly a typo.
        for (idx, step) in TourScript.steps.enumerated() {
            for action in step.actions {
                XCTAssertGreaterThanOrEqual(
                    action.delay, 0,
                    "Tour step \(idx) action `\(action.op)` delay is negative"
                )
                XCTAssertLessThanOrEqual(
                    action.delay, 5.0,
                    "Tour step \(idx) action `\(action.op)` delay \(action.delay)s is suspiciously long"
                )
            }
        }
    }

    func test_expression_names_are_valid() {
        for (stepIdx, step) in TourScript.steps.enumerated() {
            for action in step.actions where action.op == "set_expression" {
                guard let name = action.args["name"] as? String else { continue }
                XCTAssertNotNil(
                    MaxClawdroomExpression(rawValue: name),
                    "Tour step \(stepIdx) uses unknown expression `\(name)`"
                )
            }
        }
    }

    func test_prop_names_are_valid() {
        for (stepIdx, step) in TourScript.steps.enumerated() {
            for action in step.actions where action.op == "hold_prop" || action.op == "drop_prop" {
                guard let item = action.args["item"] as? String else { continue }
                XCTAssertNotNil(
                    Prop(rawValue: item),
                    "Tour step \(stepIdx) uses unknown prop `\(item)`"
                )
            }
        }
    }

    func test_mode_names_are_valid() {
        for (stepIdx, step) in TourScript.steps.enumerated() {
            for action in step.actions where action.op == "set_mode" {
                guard let name = action.args["name"] as? String else { continue }
                XCTAssertNotNil(
                    MaxClawdroomMode(rawValue: name),
                    "Tour step \(stepIdx) uses unknown mode `\(name)`"
                )
            }
        }
    }

    func test_total_runtime_under_two_minutes() {
        // Tour is supposed to be ~60–90s. If the sum exceeds
        // 120s, somebody added too many steps or bumped dwell
        // values — first-time users won't sit through it.
        let total = TourScript.steps.reduce(0.0) { $0 + $1.dwell }
        XCTAssertLessThanOrEqual(
            total, 120.0,
            "Tour total runtime \(total)s exceeds the 2-minute target"
        )
    }
}
