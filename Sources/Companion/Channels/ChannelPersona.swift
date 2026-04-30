import Foundation

/// Per-channel cosmetic + voice bundle. Applied via existing action ops
/// (`set_part_color`, `set_chat_color`, voice swap) when the active
/// channel changes, so switching channels visibly transforms Max
/// without any new dispatch logic.
///
/// Phase 0 stores this on every Channel; Phase 3 wires `applyPersona`
/// on `ChannelStore.didChange`.
struct ChannelPersona: Codable, Equatable, Hashable {
    var tieHex: String
    var chatBorderHex: String
    var chatUserHex: String
    /// VoiceEngine voice id. Empty means "leave the user's current
    /// voice alone" — useful for migrated channels where the user
    /// hasn't customised anything yet.
    var voiceID: String
    /// Override for `Prefs.voiceMaxFilter` while this channel is active.
    var voiceFilter: Bool
    /// Expression name passed to `set_expression` after a channel swap
    /// settles. Must match a known expression in `Pet/Expressions`.
    var baselineExpression: String
    /// Optional gesture fired once on channel activation. nil = silent
    /// swap. Existing supported names: "wave", "nod", "look_around".
    var greetGesture: String?

    static let `default` = ChannelPersona(
        tieHex: "#2DE1FC",
        chatBorderHex: "#2DE1FC",
        chatUserHex: "#F7D046",
        voiceID: "",
        voiceFilter: false,
        baselineExpression: "neutral",
        greetGesture: "wave"
    )
}
