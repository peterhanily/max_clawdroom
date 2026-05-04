import XCTest
@testable import Companion

/// Pins the schema-first validation gate that fronts the action
/// dispatcher. Each test exercises one failure mode — typo, missing
/// field, wrong type — so a future refactor that lets one of these
/// regress doesn't silently put rejected actions back on the dispatch
/// path.
@MainActor
final class ActionInputValidatorTests: XCTestCase {

    // MARK: - Skip path (unmigrated ops)

    func test_unknownOp_skipsValidation() {
        // Ops without a registered schema must dispatch as before so
        // the migration can land cohort by cohort. Tested with a
        // deliberately fake op so this test won't accidentally start
        // failing when a future cohort gains a schema.
        let action = MaxClawdroomAction(op: "definitely_not_a_real_op", args: [:])
        XCTAssertEqual(ActionInputValidator.validate(action), .skipped)
    }

    // MARK: - Happy path

    func test_writeMemory_validArgs_passesValidation() {
        let action = MaxClawdroomAction(
            op: "write_memory",
            args: ["kind": "preference", "text": "loves espresso"]
        )
        XCTAssertEqual(ActionInputValidator.validate(action), .ok)
    }

    func test_writeMemory_optionalFieldOmitted_stillPasses() {
        // `key` is optional on WriteMemoryInput; absent is allowed.
        // (The schema declares it as `String?` so missing → nil.)
        let action = MaxClawdroomAction(
            op: "write_memory",
            args: ["kind": "observation", "text": "user just shipped a release"]
        )
        XCTAssertEqual(ActionInputValidator.validate(action), .ok)
    }

    func test_proposeSoulPatch_legacyAlias_alsoValidates() {
        // `update_soul` shares the schema with `propose_soul_patch`.
        // Both alias entries in the registry must hit the same gate.
        let action = MaxClawdroomAction(
            op: "update_soul",
            args: ["rationale": "Noticed the user prefers terse replies",
                   "patch": "Keep responses tight unless asked otherwise."]
        )
        XCTAssertEqual(ActionInputValidator.validate(action), .ok)
    }

    // MARK: - Unknown-key (typo) rejection

    func test_writeMemory_typoFieldName_rejected() {
        // Typo `type` instead of `kind` — the dispatcher's `as? String`
        // cast would silently no-op today. With schema validation, the
        // user sees why the action didn't take.
        let action = MaxClawdroomAction(
            op: "write_memory",
            args: ["type": "preference", "text": "loves espresso"]
        )
        guard case .failure(let reason) = ActionInputValidator.validate(action) else {
            XCTFail("expected failure for typo'd field")
            return
        }
        XCTAssertTrue(reason.contains("type"),
                      "rejection reason should name the offending key, got: \(reason)")
    }

    func test_multipleUnknownKeys_listedInRejection() {
        let action = MaxClawdroomAction(
            op: "set_chat_color",
            args: ["target": "panel", "color": "#FF0000",
                   "alpha": "0.5", "border": "#000000"]
        )
        guard case .failure(let reason) = ActionInputValidator.validate(action) else {
            XCTFail("expected failure for unknown extras")
            return
        }
        XCTAssertTrue(reason.contains("alpha") && reason.contains("border"),
                      "rejection should list both unknown keys, got: \(reason)")
    }

    // MARK: - Missing required field

    func test_writeMemory_missingRequiredField_rejected() {
        // Missing `text` — required on the schema.
        let action = MaxClawdroomAction(
            op: "write_memory",
            args: ["kind": "preference"]
        )
        guard case .failure(let reason) = ActionInputValidator.validate(action) else {
            XCTFail("expected failure for missing field")
            return
        }
        XCTAssertTrue(reason.contains("text"),
                      "rejection reason should name the missing field, got: \(reason)")
    }

    // MARK: - Wrong type

    func test_writeMemory_wrongFieldType_rejected() {
        // `kind` declared String; pass a number.
        let action = MaxClawdroomAction(
            op: "write_memory",
            args: ["kind": 42, "text": "x"]
        )
        guard case .failure(let reason) = ActionInputValidator.validate(action) else {
            XCTFail("expected failure for wrong type")
            return
        }
        XCTAssertTrue(reason.lowercased().contains("type") || reason.contains("kind"),
                      "rejection reason should mention the type problem or field, got: \(reason)")
    }

    // MARK: - Bind has an optional `color`

    func test_bind_validWithOptionalColorOmitted() {
        let action = MaxClawdroomAction(
            op: "bind",
            args: ["signal": "tool.bash", "part": "tie", "mode": "flash"]
        )
        XCTAssertEqual(ActionInputValidator.validate(action), .ok)
    }

    func test_bind_validWithOptionalColorPresent() {
        let action = MaxClawdroomAction(
            op: "bind",
            args: ["signal": "tool.bash", "part": "tie", "mode": "flash", "color": "#FF5040"]
        )
        XCTAssertEqual(ActionInputValidator.validate(action), .ok)
    }
}
