import Foundation

/// Coarse buckets so the user can mute footsteps without losing the
/// "Max made a mood shift" stings. Each `Sound` carries a category;
/// the mixer applies a per-category gain (0…1, with the master gain
/// on top).
///
/// Kept intentionally small. New sounds pick the closest bucket;
/// adding a new bucket means new UI surface, which is the part the
/// user cares about.
enum SoundCategory: String, Codable, CaseIterable, Hashable {
    case sting   // music phrases — soul-patch, channel swap, fanfare
    case body    // footsteps, jitter, expression shifts
    case ui      // chat send, link click, generic confirms
    case mode    // tv-static, desktop-settle, meeting-dampen
    case channel // glitch on swap, bonk on auth fail

    var displayName: String {
        switch self {
        case .sting:   return "Stings"
        case .body:    return "Body effects"
        case .ui:      return "UI cues"
        case .mode:    return "Mode transitions"
        case .channel: return "Channel cues"
        }
    }
}
