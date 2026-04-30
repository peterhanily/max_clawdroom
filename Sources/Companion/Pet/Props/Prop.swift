import AppKit
import SceneKit

/// Agent-attachable props Max can hold, ride, or stand near. Shipped
/// as an enum so the action-tag dispatcher can validate agent input
/// via rawValue lookup, and as a catalog of pure-SceneKit builders so
/// nothing depends on asset bundles.
///
/// Each prop knows:
/// - How to build its node subtree (PropCatalog.build(_:))
/// - Which anchor it belongs at (defaultAnchor)
///
/// Anchor-exclusivity (only one hat, one prop per hand, etc.) is
/// enforced by `Pet.holdProp` via `conflictingAnchors(for:)`, so props
/// themselves don't need a per-case uniqueness flag.
enum Prop: String, CaseIterable {
    // Original kit
    case bike
    case ladder
    case water_gun
    case guitar
    case skateboard
    case coffee_mug
    case umbrella
    case briefcase
    case phone
    case book
    case balloon
    case flower
    // Phase B — transport
    case scooter
    case rollerblades
    case pogo_stick
    case hoverboard
    case motorcycle
    case jetpack
    // Phase B — novelties
    case sparkler
    case party_horn
    // Phase B — persona items
    case laptop
    case paintbrush
    case magnifier
    case wand
    case football
    case baseball_bat
    case wrench
    // Phase B — food
    case pizza_slice
    case ice_cream_cone
    case donut
    case cupcake
    // Hats — worn above the head
    case baseball_cap
    case top_hat
    case cowboy_hat
    case beanie
    case crown
    // Phase B — more hats
    case party_hat
    case wizard_hat
    case hard_hat
    // Phase C — jewelry
    case necklace
    case earrings
    case bracelet
    case watch
    case ring
    // Phase E.1 — persona hats (completes the chef/soldier/pirate/… looks)
    case chef_hat
    case military_helmet
    case motorcycle_helmet
    case pirate_hat
    case astronaut_helmet
    case ninja_headband
    // Phase E.2 — face accessory + more chain-class jewelry
    case eye_patch
    case gold_chain
    case silver_chain
    // Sleep / time-of-day kit. Pairs with the `pajamas` /
    // `bathrobe` / `loungewear` outfit presets.
    case nightcap         // pointy soft cap with tassel — "Wee Willie Winkie"
    case sleep_mask       // black or pastel band over the eyes
    case slippers         // soft house slippers — under the feet

    // Face masks — render as oversized face emojis floated in front
    // of Max's head. Anchored at `.onFace` so they stack with eye
    // accessories and hats. Each named case is a fixed emoji; for the
    // long tail of well-known faces, use `.face_emoji` with a `name`
    // arg.
    case surgical_mask    // 😷
    case bandit_mask      // 🥷
    case gas_mask         // 🥴
    case hockey_mask      // 💀
    case plague_doctor    // 👹

    /// Generic face-emoji mask. Agent passes `{"name": "<key>"}` or
    /// `{"emoji": "<glyph>"}` to choose. See `PropCatalog.faceEmojiTable`
    /// for the curated name → emoji map (every well-known smiley face
    /// across the Unicode emoji set). If both args are missing or the
    /// name is unknown, falls back to ❓ so the failure is visible.
    case face_emoji

    // Shoggoth kit — undulating tentacles emerging from the back of
    // the torso. `count` arg (4–10, default 6) tunes the density. Tips
    // are eye-shaped: pale spheres with dark pupils, ⌘Z-undoable.
    case tentacles

    /// Heroic cape — drapes behind Max from a small collar around the
    /// neck. Gentle billowing animation gives it cloth-like motion.
    /// Default colour is classic comic-book red; agent can pass
    /// `{"color": "#rrggbb"}` to tint (e.g. black for noir, gold for
    /// fancy). Single back-mount slot — conflicts with jetpack +
    /// tentacles, same as those two conflict with each other.
    case cape

    /// Where on / around Max this prop lives by default.
    var defaultAnchor: PropAnchor {
        switch self {
        case .bike, .skateboard, .scooter, .rollerblades,
             .pogo_stick, .hoverboard, .motorcycle:        return .ridden
        case .ladder:                                      return .leaningNearby
        case .jetpack:                                     return .backMounted
        case .cape:                                        return .backMounted
        case .water_gun, .guitar,
             .umbrella, .phone, .book,
             .balloon, .flower,
             .sparkler, .party_horn,
             .paintbrush, .magnifier, .wand,
             .football, .wrench,
             .pizza_slice, .ice_cream_cone,
             .donut, .cupcake:                             return .heldRight
        case .laptop, .baseball_bat:                       return .heldBoth
        case .coffee_mug, .briefcase:                      return .heldRight
        case .baseball_cap, .top_hat, .cowboy_hat,
             .beanie, .crown,
             .party_hat, .wizard_hat, .hard_hat,
             .chef_hat, .military_helmet, .motorcycle_helmet,
             .pirate_hat, .astronaut_helmet, .ninja_headband,
             .nightcap:                                    return .aboveHead
        case .necklace, .gold_chain, .silver_chain:        return .aroundNeck
        case .earrings:                                    return .onEars
        case .bracelet, .watch:                            return .onWrist
        case .ring:                                        return .onFinger
        case .eye_patch, .sleep_mask:                      return .onEye
        case .slippers:                                    return .leaningNearby
        case .surgical_mask, .bandit_mask, .gas_mask,
             .hockey_mask, .plague_doctor, .face_emoji:    return .onFace
        case .tentacles:                                   return .backMounted
        }
    }

    /// Human-readable display name for debug / logs.
    var displayName: String {
        switch self {
        case .bike:              return "bike"
        case .ladder:            return "ladder"
        case .water_gun:         return "water gun"
        case .guitar:            return "guitar"
        case .skateboard:        return "skateboard"
        case .coffee_mug:        return "coffee mug"
        case .umbrella:          return "umbrella"
        case .briefcase:         return "briefcase"
        case .phone:             return "phone"
        case .book:              return "book"
        case .balloon:           return "balloon"
        case .flower:            return "flower"
        case .scooter:           return "scooter"
        case .rollerblades:      return "rollerblades"
        case .pogo_stick:        return "pogo stick"
        case .hoverboard:        return "hoverboard"
        case .motorcycle:        return "motorcycle"
        case .jetpack:           return "jetpack"
        case .sparkler:          return "sparkler"
        case .party_horn:        return "party horn"
        case .laptop:            return "laptop"
        case .paintbrush:        return "paintbrush"
        case .magnifier:         return "magnifying glass"
        case .wand:              return "wand"
        case .football:          return "football"
        case .baseball_bat:      return "baseball bat"
        case .wrench:            return "wrench"
        case .pizza_slice:       return "pizza slice"
        case .ice_cream_cone:    return "ice cream cone"
        case .donut:             return "donut"
        case .cupcake:           return "cupcake"
        case .baseball_cap:      return "baseball cap"
        case .top_hat:           return "top hat"
        case .cowboy_hat:        return "cowboy hat"
        case .beanie:            return "beanie"
        case .crown:             return "crown"
        case .party_hat:         return "party hat"
        case .wizard_hat:        return "wizard hat"
        case .hard_hat:          return "hard hat"
        case .necklace:          return "necklace"
        case .earrings:          return "earrings"
        case .bracelet:          return "bracelet"
        case .watch:             return "watch"
        case .ring:              return "ring"
        case .chef_hat:          return "chef hat"
        case .military_helmet:   return "military helmet"
        case .motorcycle_helmet: return "motorcycle helmet"
        case .pirate_hat:        return "pirate hat"
        case .astronaut_helmet:  return "astronaut helmet"
        case .ninja_headband:    return "ninja headband"
        case .eye_patch:         return "eye patch"
        case .gold_chain:        return "gold chain"
        case .silver_chain:      return "silver chain"
        case .nightcap:          return "nightcap"
        case .sleep_mask:        return "sleep mask"
        case .slippers:          return "slippers"
        case .surgical_mask:     return "medical mask"
        case .bandit_mask:       return "ninja mask"
        case .gas_mask:          return "woozy mask"
        case .hockey_mask:       return "skull mask"
        case .plague_doctor:     return "oni mask"
        case .face_emoji:        return "face emoji"
        case .tentacles:         return "tentacles"
        case .cape:              return "cape"
        }
    }
}

/// Where a prop attaches in the pet's scene graph.
///
/// - heldRight / heldLeft: parented to `part.skin.hand` right/left,
///   positioned naturally as if gripped.
/// - heldBoth: parented to the torso-middle; positioned in front of
///   chest so it reads as grasped in both hands.
/// - ridden: parented to `pet.root` — props positions Max as riding
///   it (e.g. bike seat under pet origin).
/// - leaningNearby: parented to `pet.root` — sits on the ground next
///   to Max, not attached to his body.
/// - aboveHead: parented to `part.head` — floats above, like an
///   umbrella held by an off-screen hand.
/// - backMounted: parented to body-torso rear — jetpacks, rocket
///   boosters, anything worn on the back.
enum PropAnchor: String, CaseIterable {
    case heldRight
    case heldLeft
    case heldBoth
    case ridden
    case leaningNearby
    case aboveHead
    case backMounted
    // Phase C — jewelry
    case aroundNeck
    case onEars
    case onWrist
    case onFinger
    // Phase E.2 — face slot (single-eye cover; doesn't conflict with hats)
    case onEye
    // Lower-face slot (masks). Distinct from `.onEye` so masks stack
    // with sunglasses + hats. Single-slot — only one mask at a time.
    case onFace

    static let all: [String] = PropAnchor.allCases.map(\.rawValue)

    /// Anchors that can't coexist with `self`. Attaching a prop at `self`
    /// requires Pet.holdProp to drop anything currently attached at any
    /// of these. Encoded here (vs. on Pet) because the rule is a property
    /// of the anchor, not of the pet that owns them — adding a new anchor
    /// should update this table in one place.
    ///
    /// Exclusivity rules:
    /// - hands: each hand accepts one prop, and a two-handed prop evicts
    ///   both single-hand props.
    /// - hat / ridden / leaning: single slot.
    var conflictingAnchors: Set<PropAnchor> {
        switch self {
        case .heldRight:     return [.heldRight, .heldBoth]
        case .heldLeft:      return [.heldLeft, .heldBoth]
        case .heldBoth:      return [.heldRight, .heldLeft, .heldBoth]
        case .aboveHead:     return [.aboveHead]
        case .ridden:        return [.ridden]
        case .leaningNearby: return [.leaningNearby]
        case .backMounted:   return [.backMounted]
        case .aroundNeck:    return [.aroundNeck]
        case .onEars:        return [.onEars]
        case .onWrist:       return [.onWrist]
        case .onFinger:      return [.onFinger]
        case .onEye:         return [.onEye]
        case .onFace:        return [.onFace]
        }
    }
}
