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

    // MARK: - Happy path — every registered op shape

    func test_remember_validArgs_passesValidation() {
        let action = MaxClawdroomAction(
            op: "remember",
            args: ["text": "user just shipped a release"]
        )
        XCTAssertEqual(ActionInputValidator.validate(action), .ok)
    }

    func test_setPreference_validArgs_passesValidation() {
        let action = MaxClawdroomAction(
            op: "set_preference",
            args: ["key": "theme", "value": "dark"]
        )
        XCTAssertEqual(ActionInputValidator.validate(action), .ok)
    }

    func test_setChatColor_validArgs_usingHex_passesValidation() {
        // Regression: v0.4.0 shipped this schema with `color` instead
        // of `hex`, which falsely rejected every real `set_chat_color`
        // emission ("Max's `set_chat_color` action was rejected —
        // unknown field (hex)"). Pin the correct field name forever.
        let action = MaxClawdroomAction(
            op: "set_chat_color",
            args: ["target": "panel", "hex": "#FF5040"]
        )
        XCTAssertEqual(ActionInputValidator.validate(action), .ok)
    }

    func test_downloadImage_validArgs_passesValidation() {
        let action = MaxClawdroomAction(
            op: "download_image",
            args: ["url": "https://example.com/img.png", "name": "vibe"]
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

    // MARK: - Bind: optional fields including amplitude/duration

    func test_bind_validWithOnlyRequired() {
        let action = MaxClawdroomAction(
            op: "bind",
            args: ["signal": "tool.bash", "part": "tie", "mode": "flash"]
        )
        XCTAssertEqual(ActionInputValidator.validate(action), .ok)
    }

    func test_bind_validWithColor() {
        let action = MaxClawdroomAction(
            op: "bind",
            args: ["signal": "tool.bash", "part": "tie", "mode": "flash", "color": "#FF5040"]
        )
        XCTAssertEqual(ActionInputValidator.validate(action), .ok)
    }

    func test_bind_validWithAmplitudeAndDuration() {
        // Regression: v0.4.0 shipped without amplitude/duration in
        // expectedKeys, which falsely rejected any agent emission
        // tuning these. Pin the correct full surface.
        let action = MaxClawdroomAction(
            op: "bind",
            args: ["signal": "logprob.entropy", "part": "head", "mode": "shake",
                   "amplitude": 0.4, "duration": 0.8]
        )
        XCTAssertEqual(ActionInputValidator.validate(action), .ok)
    }

    // MARK: - Unknown-key (typo) rejection

    func test_remember_typoFieldName_rejected() {
        // Typo `txt` instead of `text` — would silently no-op today.
        let action = MaxClawdroomAction(
            op: "remember",
            args: ["txt": "loves espresso"]
        )
        guard case .failure(let reason) = ActionInputValidator.validate(action) else {
            XCTFail("expected failure for typo'd field")
            return
        }
        XCTAssertTrue(reason.contains("txt"),
                      "rejection reason should name the offending key, got: \(reason)")
    }

    func test_multipleUnknownKeys_listedInRejection() {
        let action = MaxClawdroomAction(
            op: "set_chat_color",
            args: ["target": "panel", "hex": "#FF0000",
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

    func test_remember_missingRequiredField_rejected() {
        // Missing `text` — required on the schema.
        let action = MaxClawdroomAction(
            op: "remember",
            args: [:]
        )
        guard case .failure(let reason) = ActionInputValidator.validate(action) else {
            XCTFail("expected failure for missing field")
            return
        }
        XCTAssertTrue(reason.contains("text"),
                      "rejection reason should name the missing field, got: \(reason)")
    }

    func test_setPreference_missingValue_rejected() {
        let action = MaxClawdroomAction(
            op: "set_preference",
            args: ["key": "theme"]
        )
        guard case .failure(let reason) = ActionInputValidator.validate(action) else {
            XCTFail("expected failure for missing value")
            return
        }
        XCTAssertTrue(reason.contains("value"))
    }

    // MARK: - Wrong type

    func test_remember_wrongFieldType_rejected() {
        // `text` declared String; pass a number.
        let action = MaxClawdroomAction(
            op: "remember",
            args: ["text": 42]
        )
        guard case .failure(let reason) = ActionInputValidator.validate(action) else {
            XCTFail("expected failure for wrong type")
            return
        }
        XCTAssertTrue(reason.lowercased().contains("type") || reason.contains("text"),
                      "rejection reason should mention the type problem or field, got: \(reason)")
    }
}
