import AppKit
import SwiftUI

/// Fixed reference colours used as theme defaults and for elements that
/// aren't agent-customisable (dim icon text, mod indicator glyph).
enum CRTPalette {
    static let panel   = Color(red: 0.031, green: 0.039, blue: 0.094)  // #080A18
    static let fg      = Color(red: 0.949, green: 0.949, blue: 0.968)  // #F2F2F7
    static let fgDim   = Color(red: 0.612, green: 0.639, blue: 0.737)  // #9CA3BC
    static let magenta = Color(red: 1.000, green: 0.176, blue: 0.541)  // #FF2D8A
    static let cyan    = Color(red: 0.176, green: 0.882, blue: 0.988)  // #2DE1FC
    static let amber   = Color(red: 0.969, green: 0.816, blue: 0.275)  // #F7D046
}

/// Observable chat-chrome palette that the agent can author at runtime via
/// the `set_chat_color` action-tag op. Every field is both read by
/// `ChatBubbleView` and addressable as a `Target` for the dispatcher.
@MainActor
final class ChatTheme: ObservableObject {
    enum Target: String, CaseIterable {
        case panel
        case border
        case text
        case user
        case assistant
        case prompt
        case cursor
        case input
        case send
    }

    @Published var panel: Color
    @Published var border: Color
    @Published var text: Color
    @Published var user: Color
    @Published var assistant: Color
    @Published var prompt: Color
    @Published var cursor: Color
    @Published var input: Color
    @Published var send: Color

    /// Optional background image (from `ImageLibrary`) layered UNDER the
    /// panel fill. When set, the panel colour is dimmed to 0.35 opacity
    /// so the image shows through. Clearing it returns to the plain
    /// colour fill. Agent sets this via `set_chat_background`.
    @Published var backgroundImageName: String?
    @Published var backgroundImageOpacity: Double = 0.6

    /// Type-family applied across every text surface in the chat bubble
    /// (header, body, prompt glyph, input, send, role icons). Monospaced
    /// is the default — the CRT chrome reads as a terminal — but the
    /// agent can swap to a much wider catalog via `set_chat_font`.
    /// Rendering only; does NOT touch the strip pipeline (action / env /
    /// world blocks still get filtered before any text reaches the font
    /// path).
    ///
    /// Twenty-one options across four buckets:
    ///   • System designs: mono, serif, rounded, sans
    ///   • Specific monos: menlo, courier
    ///   • Specific serifs: georgia, times, baskerville, didot, palatino
    ///   • Specific sans: helvetica, avenir, futura, verdana, impact
    ///   • Display / decorative: chalkboard, marker, copperplate,
    ///     papyrus, comic
    /// All `Font.custom` names are macOS preinstalled fonts (Big Sur+),
    /// no resource shipping required. Unknown names fall back to mono
    /// at the dispatcher level.
    enum FontFamily: String, CaseIterable {
        // System designs
        case mono, serif, rounded, sans
        // Mono variants
        case menlo, courier
        // Serif variants
        case georgia, times, baskerville, didot, palatino
        // Sans variants
        case helvetica, avenir, futura, verdana, impact
        // Display / decorative
        case chalkboard, marker, copperplate, papyrus, comic

        /// Build a SwiftUI `Font` for this family at the given size +
        /// weight. System designs use `.system(size:weight:design:)`;
        /// named fonts use `Font.custom(_:size:).weight(_:)` because
        /// `Font.custom` doesn't take a weight argument directly.
        func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            switch self {
            case .mono:    return .system(size: size, weight: weight, design: .monospaced)
            case .serif:   return .system(size: size, weight: weight, design: .serif)
            case .rounded: return .system(size: size, weight: weight, design: .rounded)
            case .sans:    return .system(size: size, weight: weight, design: .default)

            case .menlo:       return Font.custom("Menlo", size: size).weight(weight)
            case .courier:     return Font.custom("Courier New", size: size).weight(weight)

            case .georgia:     return Font.custom("Georgia", size: size).weight(weight)
            case .times:       return Font.custom("Times New Roman", size: size).weight(weight)
            case .baskerville: return Font.custom("Baskerville", size: size).weight(weight)
            case .didot:       return Font.custom("Didot", size: size).weight(weight)
            case .palatino:    return Font.custom("Palatino", size: size).weight(weight)

            case .helvetica:   return Font.custom("Helvetica Neue", size: size).weight(weight)
            case .avenir:      return Font.custom("Avenir Next", size: size).weight(weight)
            case .futura:      return Font.custom("Futura", size: size).weight(weight)
            case .verdana:     return Font.custom("Verdana", size: size).weight(weight)
            case .impact:      return Font.custom("Impact", size: size).weight(weight)

            case .chalkboard:  return Font.custom("Chalkboard SE", size: size).weight(weight)
            case .marker:      return Font.custom("Marker Felt", size: size).weight(weight)
            case .copperplate: return Font.custom("Copperplate", size: size).weight(weight)
            case .papyrus:     return Font.custom("Papyrus", size: size).weight(weight)
            case .comic:       return Font.custom("Comic Sans MS", size: size).weight(weight)
            }
        }
    }
    @Published var fontFamily: FontFamily = .mono

    init() {
        // Solid-dark default — the translucent panel over `.ultraThinMaterial`
        // washed to grey on light wallpapers, which made text illegible.
        panel     = CRTPalette.panel
        border    = CRTPalette.magenta
        text      = CRTPalette.fg
        user      = CRTPalette.magenta
        assistant = CRTPalette.cyan
        prompt    = CRTPalette.magenta
        cursor    = CRTPalette.fg
        input     = Color(red: 0.015, green: 0.015, blue: 0.03)  // darker than panel
        send      = CRTPalette.magenta
        applyHighContrastIfNeeded()

        // Re-apply on system or user accessibility flag changes so the
        // palette follows "Increase Contrast" without a relaunch.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onAccessibilityChanged),
            name: .companionAccessibilityChanged,
            object: nil
        )
    }

    @objc private func onAccessibilityChanged() {
        applyHighContrastIfNeeded()
    }

    /// Reassigns every customisable channel back to the CRTPalette
    /// defaults. Used by the agent's `revert_to_baseline` op and the
    /// right-click "Revert to Baseline" menu so chat colors / font /
    /// background image all snap back together. Re-runs the
    /// high-contrast override at the end so accessibility users
    /// don't lose their palette to a revert.
    func resetToDefaults() {
        panel     = CRTPalette.panel
        border    = CRTPalette.magenta
        text      = CRTPalette.fg
        user      = CRTPalette.magenta
        assistant = CRTPalette.cyan
        prompt    = CRTPalette.magenta
        cursor    = CRTPalette.fg
        input     = Color(red: 0.015, green: 0.015, blue: 0.03)
        send      = CRTPalette.magenta
        fontFamily = .mono
        backgroundImageName = nil
        backgroundImageOpacity = 0.6
        applyHighContrastIfNeeded()
    }

    /// Override every channel to the high-contrast palette when the
    /// flag is on. Leaves the CRT defaults untouched otherwise so agent
    /// customisations still work normally.
    private func applyHighContrastIfNeeded() {
        guard Prefs.highContrast else { return }
        panel     = .black
        border    = CRTPalette.amber
        text      = .white
        user      = CRTPalette.amber
        assistant = .white
        prompt    = CRTPalette.amber
        cursor    = .white
        input     = .black
        send      = CRTPalette.amber
    }

    func color(for target: Target) -> Color {
        switch target {
        case .panel:     return panel
        case .border:    return border
        case .text:      return text
        case .user:      return user
        case .assistant: return assistant
        case .prompt:    return prompt
        case .cursor:    return cursor
        case .input:     return input
        case .send:      return send
        }
    }

    func setColor(_ target: Target, to color: Color) {
        switch target {
        case .panel:     panel = color
        case .border:    border = color
        case .text:      text = color
        case .user:      user = color
        case .assistant: assistant = color
        case .prompt:    prompt = color
        case .cursor:    cursor = color
        case .input:     input = color
        case .send:      send = color
        }
    }
}
