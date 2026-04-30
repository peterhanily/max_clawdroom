import AppKit
import Foundation

/// Visible growth on the pet. Each accepted soul patch shifts the tie's
/// hue a small, deterministic amount — hash the patch text, map into
/// ±12° hue / ±5% saturation, and apply via `Pet.setPartColor("tie", …)`.
///
/// Deterministic means: the same patch text always produces the same
/// tint drift, so re-applying history in tests gives the same visible
/// result, and two users who happen to accept the same patch converge
/// to the same colour shift.
///
/// Bounded so Max's tie can't migrate into illegible zones — hue drifts
/// around the palette, but saturation and brightness are clamped so the
/// tie never becomes white or black.
@MainActor
final class SoulTintDrift {
    private weak var pet: Pet?
    private var observer: NSObjectProtocol?

    init(pet: Pet) {
        self.pet = pet
        observer = NotificationCenter.default.addObserver(
            forName: .companionSoulChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let patch = (note.userInfo?["patch"] as? String) ?? ""
            guard !patch.isEmpty else { return }
            Task { @MainActor in self?.applyDrift(fromPatch: patch) }
        }
    }

    isolated deinit {
        if let obs = observer {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func applyDrift(fromPatch patch: String) {
        guard let pet else { return }
        guard let tieColor = currentTieColor(pet: pet) else { return }
        let shifted = SoulTintDrift.drift(color: tieColor, patchText: patch)
        pet.setPartColor("tie", to: shifted)
    }

    /// Pull the current tie tint off the first tie material so drift is
    /// *relative* — each patch moves where we currently are, not back to
    /// an authored baseline. Composition is the point.
    private func currentTieColor(pet: Pet) -> NSColor? {
        let root = pet.node
        var found: NSColor?
        root.enumerateHierarchy { node, _ in
            guard found == nil,
                  let name = node.name,
                  name.hasPrefix("part.tie"),
                  let mat = node.geometry?.materials.first,
                  let c = mat.diffuse.contents as? NSColor
            else { return }
            found = c.usingColorSpace(.sRGB) ?? c
        }
        return found
    }

    // MARK: - Drift math (testable)

    /// Hash `patchText` → deterministic hue/sat delta, apply to `color`.
    /// Returns clamped sRGB colour.
    static func drift(color: NSColor, patchText: String) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        // Stable 64-bit hash over UTF-8 bytes. Swift's String.hashValue is
        // per-process randomised, which would make drift non-deterministic
        // across launches — use FNV-1a instead.
        let hash = SoulTintDrift.fnv1a(patchText)

        // Pull two signed components out of the hash.
        let hueDeltaDegrees = Double(Int32(truncatingIfNeeded: hash)) / Double(Int32.max) * 12.0
        let satDeltaPct = Double(Int32(truncatingIfNeeded: hash >> 32)) / Double(Int32.max) * 5.0

        let newH = CGFloat((Double(h) * 360.0 + hueDeltaDegrees).truncatingRemainder(dividingBy: 360.0))
        let newHClamped: CGFloat = newH < 0 ? (newH + 360) / 360 : newH / 360
        // Saturation stays in [0.25, 0.95] so the tie is never washed out
        // or painfully oversaturated. Brightness is left alone.
        let newS = max(0.25, min(0.95, s + CGFloat(satDeltaPct / 100.0)))

        return NSColor(hue: newHClamped, saturation: newS, brightness: b, alpha: a)
    }

    /// FNV-1a 64-bit. Stable across launches and architectures — Swift's
    /// `Hasher` explicitly is not. Small, no dependencies, well-defined.
    private static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
}
