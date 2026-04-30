import CoreGraphics
import Foundation

/// Named physical contexts Max can inhabit. Drives size, panel anchor,
/// idle behavior, scanline intensity, and the register hint the agent
/// reads from the `[env]` block. The mode is both auto-detected from
/// display topology and manually switchable via the `set_mode` action-tag
/// op or the menu bar.
enum MaxClawdroomMode: String, CaseIterable, Hashable {
    case laptop
    case desktop
    case tv
    case meeting

    var displayName: String {
        switch self {
        case .laptop:  return "Laptop"
        case .desktop: return "Desktop"
        case .tv:      return "TV"
        case .meeting: return "Meeting"
        }
    }
}

/// Where Max's output surface lives on screen. `.sideOfPet` is the
/// current smart placement; the other two anchor types are placeholders
/// for alternate surfaces (subtitle bar for TV, menu-bar status-item for
/// Meeting) that aren't implemented in Phase 1 — they fall back to
/// `.sideOfPet` behavior until the surfaces ship.
enum PanelAnchor: Hashable {
    case sideOfPet
    case subtitleBar
    case menuBar
}

/// Complete per-mode preset bundle. One lookup per mode keeps the
/// transition cheap and the contract explicit.
struct ModePreset: Hashable {
    let mode: MaxClawdroomMode
    let petScale: CGFloat
    let panelAnchor: PanelAnchor
    let idleJitter: Bool
    /// Multiplier on top of `MaxClawdroomState.glitchIntensity` when the CRT
    /// shader pipeline is active. Stored in the preset so a later
    /// re-enable of CRTEffects can pick it up without another round of
    /// plumbing.
    let scanlineScale: Float
    /// Hint passed to the agent via the `[env]` block. Not enforced —
    /// the model chooses how to honour it.
    let registerHint: String

    static let laptop = ModePreset(
        mode: .laptop,
        petScale: 0.75,
        panelAnchor: .sideOfPet,
        idleJitter: true,
        scanlineScale: 0.8,
        registerHint: "terse"
    )

    static let desktop = ModePreset(
        mode: .desktop,
        petScale: 1.0,
        panelAnchor: .sideOfPet,
        idleJitter: true,
        scanlineScale: 1.0,
        registerHint: "normal"
    )

    static let tv = ModePreset(
        mode: .tv,
        petScale: 2.8,
        panelAnchor: .subtitleBar,
        idleJitter: true,
        scanlineScale: 2.0,
        registerHint: "expansive"
    )

    static let meeting = ModePreset(
        mode: .meeting,
        petScale: 0.4,
        panelAnchor: .menuBar,
        idleJitter: false,
        scanlineScale: 0.0,
        registerHint: "silent"
    )

    static func preset(for mode: MaxClawdroomMode) -> ModePreset {
        switch mode {
        case .laptop:  return .laptop
        case .desktop: return .desktop
        case .tv:      return .tv
        case .meeting: return .meeting
        }
    }
}
