import Foundation

/// Typed `Codable` schemas for the highest-stakes durable action ops.
///
/// **Why this layer exists.** The action grammar is action-tags-in-prose
/// (`[action]{"op":"…",…}[/action]`), parsed into `MaxClawdroomAction`
/// with an untyped `[String: AnyHashable]` arg dict. The dispatcher
/// then reads fields via `as? String` casts. That works, but a typo'd
/// field name (`"type"` instead of `"kind"`) silently fails the cast
/// and the whole action is a no-op the user can't see.
///
/// `ActionInputValidator.validate` runs *before* dispatch, decoding the
/// args through a typed schema. Three failure modes surface as
/// structured errors back to the chat session:
///   - Missing required field
///   - Wrong type
///   - Unknown key (typo / hallucinated arg)
///
/// Unknown ops (no schema) skip validation and dispatch as before — we
/// migrate ops to schemas one cohort at a time, starting with the five
/// here that have the highest blast radius if mis-invoked.
///
/// **Not in this layer:** value-level validation (URL well-formedness,
/// memory entry kind enum, etc.). Per-op handlers in `CompanionActions`
/// already do that and the boundaries differ — keep schemas about
/// shape, leave semantics to the dispatcher.

nonisolated protocol TypedActionInput: Decodable {
    /// The op name this schema validates.
    static var op: String { get }
    /// Strict whitelist of allowed keys. Inputs containing any other
    /// key are rejected — typos like `type` for `kind` surface as
    /// structured errors rather than silent no-ops.
    static var expectedKeys: Set<String> { get }
}

// MARK: - Per-op schemas

/// `remember` — agent records an observation about the user. Single
/// `text` field; the dispatcher stores it as a `MemoryEntry.observation`
/// and counts against the per-turn memory-op budget. High-stakes
/// because the text lands in future `[memory]` system-prompt blocks.
struct RememberInput: TypedActionInput {
    static let op = "remember"
    static let expectedKeys: Set<String> = ["text"]

    let text: String
}

/// `set_preference` — agent records a typed user preference (latest-
/// write-wins by `key`). Same blast radius as `remember` — preference
/// values render verbatim in the `[memory]` block.
struct SetPreferenceInput: TypedActionInput {
    static let op = "set_preference"
    static let expectedKeys: Set<String> = ["key", "value"]

    let key: String
    let value: String
}

/// `propose_soul_patch` / `update_soul` — agent proposes a personality
/// amendment. Highest-stakes durable op; gates through SoulPatchQueue
/// after this validation.
struct ProposeSoulPatchInput: TypedActionInput {
    static let op = "propose_soul_patch"
    static let expectedKeys: Set<String> = ["rationale", "patch"]

    let rationale: String
    let patch: String
}

/// `set_chat_color` — persisted chat-theme channel mutation. The
/// dispatcher's handler reads `target` (which `ChatTheme.Target` enum
/// case) and `hex` (the `#rrggbb` colour). Unknown `target` values
/// silently no-op today; the schema rejects garbage before the
/// dispatcher's switch.
struct SetChatColorInput: TypedActionInput {
    static let op = "set_chat_color"
    static let expectedKeys: Set<String> = ["target", "hex"]

    let target: String
    let hex: String
}

/// `download_image` — fetches an arbitrary URL into the image library
/// (gated by `Prefs.allowAgentAudioFetch` / image equivalent). Validating
/// shape stops a typo'd field from leaving the user's `errorMessage`
/// banner blank when nothing happens.
struct DownloadImageInput: TypedActionInput {
    static let op = "download_image"
    static let expectedKeys: Set<String> = ["url", "name"]

    let url: String
    let name: String
}

/// `bind` — wires an agent telemetry signal to a body part. Persisted
/// across sessions; mistyped signal names today surface only by Max
/// not visibly reacting. Optional `amplitude` and `duration` tune the
/// resulting animation (per `BindingParams`).
struct BindInput: TypedActionInput {
    static let op = "bind"
    static let expectedKeys: Set<String> = ["signal", "part", "mode", "color", "amplitude", "duration"]

    let signal: String
    let part: String
    let mode: String
    let color: String?
    let amplitude: Double?
    let duration: Double?
}

// MARK: - Validator

enum ActionInputValidator {

    enum Result: Equatable {
        /// No schema registered for this op — dispatch proceeds as
        /// before. Most ops live here today; cohorts migrate over time.
        case skipped
        /// Args parsed cleanly through the schema.
        case ok
        /// Validation failed. The reason is a one-line human-readable
        /// summary suitable for `ChatSession.errorMessage`.
        case failure(reason: String)
    }

    /// Registry of op → schema. Add an entry here AFTER its handler in
    /// `CompanionActions.dispatch` has been audited for backwards
    /// compatibility — turning on validation for an op whose existing
    /// handler tolerated a sloppy arg shape would surface false
    /// rejections.
    private static let schemas: [String: any TypedActionInput.Type] = [
        RememberInput.op:           RememberInput.self,
        SetPreferenceInput.op:      SetPreferenceInput.self,
        ProposeSoulPatchInput.op:   ProposeSoulPatchInput.self,
        // `update_soul` is the legacy alias for propose_soul_patch
        // (handled by the same dispatcher arm) — both share the schema.
        "update_soul":              ProposeSoulPatchInput.self,
        SetChatColorInput.op:       SetChatColorInput.self,
        DownloadImageInput.op:      DownloadImageInput.self,
        BindInput.op:               BindInput.self
    ]

    /// Validate `action` against its registered schema, if any.
    static func validate(_ action: MaxClawdroomAction) -> Result {
        guard let schemaType = schemas[action.op] else { return .skipped }

        // 1. Unknown-key check. Whitelist enforcement so typos surface
        //    as structured failures rather than being silently dropped
        //    by the dispatcher's `as?` casts.
        let inputKeys = Set(action.args.keys)
        let unexpected = inputKeys.subtracting(schemaType.expectedKeys)
        if !unexpected.isEmpty {
            let listed = unexpected.sorted().joined(separator: ", ")
            return .failure(reason: "\(action.op): unknown field\(unexpected.count == 1 ? "" : "s") (\(listed))")
        }

        // 2. Re-serialize the args dict back to JSON, then decode
        //    through the schema. Catches missing required fields and
        //    wrong types. AnyHashable values from `parseAction` were
        //    populated with JSON-serialisable types only (String,
        //    Double, NSArray, NSDictionary), so the round-trip is safe.
        let argsForJSON = action.args.mapValues { $0.base }
        guard JSONSerialization.isValidJSONObject(argsForJSON),
              let data = try? JSONSerialization.data(withJSONObject: argsForJSON)
        else {
            return .failure(reason: "\(action.op): args could not be re-serialised for validation")
        }
        do {
            _ = try JSONDecoder().decode(schemaType, from: data)
            return .ok
        } catch let DecodingError.keyNotFound(key, _) {
            return .failure(reason: "\(action.op): missing required field `\(key.stringValue)`")
        } catch let DecodingError.typeMismatch(_, ctx) {
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return .failure(reason: "\(action.op): wrong type for field `\(path)`")
        } catch let DecodingError.valueNotFound(_, ctx) {
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return .failure(reason: "\(action.op): null in non-optional field `\(path)`")
        } catch {
            return .failure(reason: "\(action.op): \(error.localizedDescription)")
        }
    }
}
