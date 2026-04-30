import AppKit
import SceneKit

/// Coordinated clothing looks. Each preset maps to a specific
/// combination of `setPartPattern` + `setPartColor` calls across
/// suit / tie / shirt / shoe part-groups, reusing the existing
/// pattern + color machinery without shipping any new geometry.
///
/// Geometry-level outfit swaps (replacing the suit jacket with a
/// hoodie or a lab coat) are deferred to a follow-up pass — those
/// require alternate meshes authored per form. For v0.1.1 the
/// patterns + palette shifts give enough visual range.
enum OutfitPreset: String, CaseIterable {
    case broadcaster     // default Max look — teal suit + pink tie
    case casual          // hoodie vibes: solid navy, muted accents
    case formal          // pinstripe black suit, white shirt, black tie
    case beach           // hawaiian: polka-dot shirt, bright accents
    case lab             // white labcoat vibe: white suit, colored tie
    case athletic        // track-suit: gradient panels, bold accents
    case goth            // all black with blood-red accent
    case tropical        // lime green + coral, loud polka dots
    case neon            // electric purple suit, hot-pink tie, cyan shoes
    case vintage         // brown plaid, cream shirt, rust tie
    case stealth         // matte charcoal, no-contrast accents
    case royal           // deep purple + gold, plaid pattern
    // Phase C — new presets
    case superhero       // primary red + blue with gold accent
    case chef            // white jacket, red scarf, dark pants
    case pirate          // black + deep red, rust-copper tones
    case astronaut       // stark white with cool blue accents
    case ninja           // matte black monochrome
    case pajamas         // soft pastel plaid, cloudy tones
    case tuxedo          // glossy black + crisp white + shimmer shoes
    case hawaiian        // bright polka + tropical green
    // Time-of-day / loungewear additions
    case bathrobe        // soft cream robe with sash-belt tie
    case loungewear      // heather grey sweats, deep-comfort vibe
    case cocktail        // evening dressed-up — burgundy + cream
    case swimwear        // bright trunks + tropical accents
    case kimono          // silken pattern — indigo + gold

    static let all: [String] = OutfitPreset.allCases.map(\.rawValue)

    /// Instructions for what `setPartPattern` / `setPartColor` calls
    /// should fire for this preset. Consumed by `Pet.applyOutfit(_:)`.
    var recipe: OutfitRecipe {
        switch self {
        case .broadcaster:
            return OutfitRecipe(
                suit:  .init(pattern: .solid, primary: "#0A6B8E", accent: nil),
                tie:   .init(pattern: .solid, primary: "#FF2D8A", accent: nil),
                shirt: .init(pattern: .solid, primary: "#F0EFE8", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#0D0D12", accent: nil)
            )
        case .casual:
            return OutfitRecipe(
                suit:  .init(pattern: .solid, primary: "#1F2A44", accent: nil),
                tie:   .init(pattern: .solid, primary: "#5C6578", accent: nil),
                shirt: .init(pattern: .solid, primary: "#C4BCA8", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#2A2825", accent: nil)
            )
        case .formal:
            return OutfitRecipe(
                suit:  .init(pattern: .stripes, primary: "#0D0D18", accent: "#4A4A55"),
                tie:   .init(pattern: .solid, primary: "#0A0A10", accent: nil),
                shirt: .init(pattern: .solid, primary: "#FFFFFF", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#000000", accent: nil)
            )
        case .beach:
            return OutfitRecipe(
                suit:  .init(pattern: .polka, primary: "#F49A1C", accent: "#FFFFFF"),
                tie:   .init(pattern: .solid, primary: "#F8C84E", accent: nil),
                shirt: .init(pattern: .solid, primary: "#E8F1D4", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#C97A3C", accent: nil)
            )
        case .lab:
            return OutfitRecipe(
                suit:  .init(pattern: .solid, primary: "#F2F2F0", accent: nil),
                tie:   .init(pattern: .solid, primary: "#6FA6F7", accent: nil),
                shirt: .init(pattern: .solid, primary: "#FFFFFF", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#2A3540", accent: nil)
            )
        case .athletic:
            return OutfitRecipe(
                suit:  .init(pattern: .gradient, primary: "#D7302A", accent: "#FFFFFF"),
                tie:   .init(pattern: .stripes, primary: "#FFFFFF", accent: "#D7302A"),
                shirt: .init(pattern: .solid, primary: "#F8F8F8", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#FFFFFF", accent: nil)
            )
        case .goth:
            return OutfitRecipe(
                suit:  .init(pattern: .solid, primary: "#0A0A0E", accent: nil),
                tie:   .init(pattern: .solid, primary: "#8A0D1A", accent: nil),
                shirt: .init(pattern: .solid, primary: "#1A1A20", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#000000", accent: nil)
            )
        case .tropical:
            return OutfitRecipe(
                suit:  .init(pattern: .polka, primary: "#1DB85A", accent: "#FF6B35"),
                tie:   .init(pattern: .solid, primary: "#FF6B35", accent: nil),
                shirt: .init(pattern: .solid, primary: "#FFF5E0", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#B54A0A", accent: nil)
            )
        case .neon:
            return OutfitRecipe(
                suit:  .init(pattern: .solid, primary: "#6A00FF", accent: nil),
                tie:   .init(pattern: .solid, primary: "#FF007F", accent: nil),
                shirt: .init(pattern: .solid, primary: "#0AFFD4", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#0AFFD4", accent: nil)
            )
        case .vintage:
            return OutfitRecipe(
                suit:  .init(pattern: .plaid, primary: "#6B4226", accent: "#C5A46A"),
                tie:   .init(pattern: .solid, primary: "#A0471E", accent: nil),
                shirt: .init(pattern: .solid, primary: "#F2E8CC", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#3D2210", accent: nil)
            )
        case .stealth:
            return OutfitRecipe(
                suit:  .init(pattern: .solid, primary: "#1C1C1E", accent: nil),
                tie:   .init(pattern: .solid, primary: "#2A2A2E", accent: nil),
                shirt: .init(pattern: .solid, primary: "#242428", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#141416", accent: nil)
            )
        case .royal:
            return OutfitRecipe(
                suit:  .init(pattern: .plaid, primary: "#2C006E", accent: "#D4AF37"),
                tie:   .init(pattern: .solid, primary: "#D4AF37", accent: nil),
                shirt: .init(pattern: .solid, primary: "#FFFBE6", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#1A0040", accent: nil)
            )
        case .superhero:
            return OutfitRecipe(
                suit:  .init(pattern: .solid, primary: "#C8102E", accent: nil),
                tie:   .init(pattern: .solid, primary: "#F0B000", accent: nil),
                shirt: .init(pattern: .solid, primary: "#0B4A9E", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#F0B000", accent: nil)
            )
        case .chef:
            return OutfitRecipe(
                suit:  .init(pattern: .solid, primary: "#FAFAF8", accent: nil),
                tie:   .init(pattern: .solid, primary: "#B11D1D", accent: nil),
                shirt: .init(pattern: .solid, primary: "#FFFFFF", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#1C1C1C", accent: nil)
            )
        case .pirate:
            return OutfitRecipe(
                suit:  .init(pattern: .solid, primary: "#15110E", accent: nil),
                tie:   .init(pattern: .solid, primary: "#8B1A1A", accent: nil),
                shirt: .init(pattern: .stripes, primary: "#EFE4C0", accent: "#1C1C1C"),
                shoe:  .init(pattern: .solid, primary: "#4D2A10", accent: nil)
            )
        case .astronaut:
            return OutfitRecipe(
                suit:  .init(pattern: .solid, primary: "#F6F7FA", accent: nil),
                tie:   .init(pattern: .solid, primary: "#6EC5F5", accent: nil),
                shirt: .init(pattern: .solid, primary: "#D8E6EE", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#B0B7BF", accent: nil)
            )
        case .ninja:
            return OutfitRecipe(
                suit:  .init(pattern: .solid, primary: "#0A0A0A", accent: nil),
                tie:   .init(pattern: .solid, primary: "#1A1A1A", accent: nil),
                shirt: .init(pattern: .solid, primary: "#121214", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#000000", accent: nil)
            )
        case .pajamas:
            return OutfitRecipe(
                suit:  .init(pattern: .plaid, primary: "#A8C2E8", accent: "#F0D1E2"),
                tie:   .init(pattern: .solid, primary: "#E8B8D4", accent: nil),
                shirt: .init(pattern: .solid, primary: "#FEFAF6", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#D4C2A8", accent: nil)
            )
        case .tuxedo:
            return OutfitRecipe(
                suit:  .init(pattern: .solid, primary: "#060608", accent: nil),
                tie:   .init(pattern: .solid, primary: "#040406", accent: nil),
                shirt: .init(pattern: .solid, primary: "#FFFFFF", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#0A0A0C", accent: nil)
            )
        case .hawaiian:
            return OutfitRecipe(
                suit:  .init(pattern: .polka, primary: "#1D9F56", accent: "#FFD94A"),
                tie:   .init(pattern: .solid, primary: "#F24E4E", accent: nil),
                shirt: .init(pattern: .solid, primary: "#FFF5D4", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#8B5E2A", accent: nil)
            )
        case .bathrobe:
            // Cream waffle robe with a darker sash belt (rendered as the
            // "tie" part). Pairs naturally with `nightcap` and `slippers`.
            return OutfitRecipe(
                suit:  .init(pattern: .solid, primary: "#F2EAD6", accent: nil),
                tie:   .init(pattern: .solid, primary: "#9C7A5A", accent: nil),
                shirt: .init(pattern: .solid, primary: "#FBF7EE", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#5C4632", accent: nil)
            )
        case .loungewear:
            return OutfitRecipe(
                suit:  .init(pattern: .solid, primary: "#5A6068", accent: nil),
                tie:   .init(pattern: .solid, primary: "#3F4148", accent: nil),
                shirt: .init(pattern: .solid, primary: "#A6ABB2", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#2A2C30", accent: nil)
            )
        case .cocktail:
            // Burgundy jacket, cream shirt, deep-gold tie. A step up from
            // casual without going full tuxedo — the after-work look.
            return OutfitRecipe(
                suit:  .init(pattern: .solid, primary: "#5A1224", accent: nil),
                tie:   .init(pattern: .solid, primary: "#C99A3D", accent: nil),
                shirt: .init(pattern: .solid, primary: "#F5EBD8", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#1A0F0A", accent: nil)
            )
        case .swimwear:
            // Bright trunks + tropical-shirt accents. Pairs with sunglasses
            // (set_glasses_style "sunglasses") for a beach moment.
            return OutfitRecipe(
                suit:  .init(pattern: .stripes, primary: "#16A8E0", accent: "#FFE066"),
                tie:   .init(pattern: .solid, primary: "#FF7733", accent: nil),
                shirt: .init(pattern: .solid, primary: "#FFFAE8", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#9D6F3A", accent: nil)
            )
        case .kimono:
            // Indigo silk with gold sash. Patterned suit reads as the
            // robe panels; tie becomes the obi.
            return OutfitRecipe(
                suit:  .init(pattern: .stripes, primary: "#1B2A52", accent: "#D4AF37"),
                tie:   .init(pattern: .solid, primary: "#D4AF37", accent: nil),
                shirt: .init(pattern: .solid, primary: "#F2EBD8", accent: nil),
                shoe:  .init(pattern: .solid, primary: "#0E1430", accent: nil)
            )
        }
    }
}

/// Concrete pattern + color instruction for one body part group.
struct OutfitPartSpec {
    let pattern: PatternFactory.Kind
    let primary: String
    let accent: String?
}

/// Aggregate recipe for a full outfit — suit, tie, shirt, shoes.
struct OutfitRecipe {
    let suit: OutfitPartSpec
    let tie: OutfitPartSpec
    let shirt: OutfitPartSpec
    let shoe: OutfitPartSpec
}
