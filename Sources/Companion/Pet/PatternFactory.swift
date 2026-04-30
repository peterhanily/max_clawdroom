import AppKit
import CoreGraphics

/// Procedural pattern-texture factory for Max's wardrobe. Renders a tileable
/// NSImage at 256×256 for a given pattern + primary/accent color pair, then
/// hands it to SceneKit materials as `diffuse.contents`.
///
/// Why procedural: lets the agent pick any color combo and pattern on the fly
/// without us shipping a PNG atlas. Each unique (pattern, primary, accent)
/// triple is cached so repeat applications don't re-draw.
enum PatternFactory {

    enum Kind: String, CaseIterable {
        case solid, stripes, polka, plaid, houndstooth, `static`, gradient
    }

    static let all: [String] = Kind.allCases.map(\.rawValue)

    /// Returns a tileable image for the given pattern. `accent` is optional
    /// (only used by patterns that have a second colour).
    static func image(kind: Kind, primary: NSColor, accent: NSColor?) -> NSImage {
        let key = cacheKey(kind: kind, primary: primary, accent: accent)
        if let cached = cache[key] {
            touchLRU(key: key)
            return cached
        }
        let size = NSSize(width: 256, height: 256)
        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus() }
        let rect = NSRect(origin: .zero, size: size)
        let eff = accent ?? primary.blended(withFraction: 0.35, of: .black) ?? primary
        switch kind {
        case .solid:       drawSolid(primary: primary, rect: rect)
        case .stripes:     drawStripes(primary: primary, accent: eff, rect: rect)
        case .polka:       drawPolka(primary: primary, accent: eff, rect: rect)
        case .plaid:       drawPlaid(primary: primary, accent: eff, rect: rect)
        case .houndstooth: drawHoundstooth(primary: primary, accent: eff, rect: rect)
        case .static:      drawStatic(primary: primary, accent: eff, rect: rect)
        case .gradient:    drawGradient(primary: primary, accent: eff, rect: rect)
        }
        insertLRU(key: key, image: img)
        return img
    }

    // MARK: - Cache (bounded LRU — each NSImage is a 256×256 bitmap so a
    // runaway agent cycling through colour/pattern combos would otherwise
    // retain unbounded VRAM-backed textures).

    private static let cacheCapacity = 128
    private static var cache: [String: NSImage] = [:]
    /// MRU order — end of array is most recently touched; the head is the
    /// first victim when we hit `cacheCapacity`. O(n) on each access, but
    /// n ≤ 128 and the hot path is the `if let cached` early-return above.
    private static var cacheOrder: [String] = []

    private static func touchLRU(key: String) {
        if let i = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: i)
        }
        cacheOrder.append(key)
    }

    private static func insertLRU(key: String, image: NSImage) {
        cache[key] = image
        cacheOrder.append(key)
        while cache.count > cacheCapacity, let victim = cacheOrder.first {
            cacheOrder.removeFirst()
            cache.removeValue(forKey: victim)
        }
    }

    private static func cacheKey(kind: Kind, primary: NSColor, accent: NSColor?) -> String {
        func hex(_ c: NSColor) -> String {
            guard let rgb = c.usingColorSpace(.sRGB) else { return "_" }
            return String(
                format: "%02X%02X%02X",
                Int(rgb.redComponent * 255),
                Int(rgb.greenComponent * 255),
                Int(rgb.blueComponent * 255)
            )
        }
        return "\(kind.rawValue):\(hex(primary)):\(accent.map(hex) ?? "-")"
    }

    // MARK: - Draw primitives

    private static func drawSolid(primary: NSColor, rect: NSRect) {
        primary.setFill()
        rect.fill()
    }

    private static func drawStripes(primary: NSColor, accent: NSColor, rect: NSRect) {
        primary.setFill()
        rect.fill()
        accent.setFill()
        let stripeWidth: CGFloat = 14
        let gap: CGFloat = 30
        var x: CGFloat = 0
        while x < rect.width {
            NSRect(x: x, y: 0, width: stripeWidth, height: rect.height).fill()
            x += gap
        }
    }

    private static func drawPolka(primary: NSColor, accent: NSColor, rect: NSRect) {
        primary.setFill()
        rect.fill()
        accent.setFill()
        let radius: CGFloat = 12
        let step: CGFloat = 36
        // Two offset rows for a proper polka-dot lattice.
        var y: CGFloat = 0
        var rowParity = 0
        while y < rect.height + radius {
            var x: CGFloat = rowParity == 0 ? 0 : step / 2
            while x < rect.width + radius {
                let dotRect = NSRect(
                    x: x - radius,
                    y: y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                NSBezierPath(ovalIn: dotRect).fill()
                x += step
            }
            y += step
            rowParity = 1 - rowParity
        }
    }

    private static func drawPlaid(primary: NSColor, accent: NSColor, rect: NSRect) {
        primary.setFill()
        rect.fill()
        // Two sets of stripes (horizontal + vertical) at low alpha so they
        // mix to form a plaid lattice where they cross.
        let alphaBand = accent.withAlphaComponent(0.55)
        alphaBand.setFill()
        let bandWidth: CGFloat = 10
        let step: CGFloat = 42
        var x: CGFloat = 0
        while x < rect.width {
            NSRect(x: x, y: 0, width: bandWidth, height: rect.height).fill()
            x += step
        }
        var y: CGFloat = 0
        while y < rect.height {
            NSRect(x: 0, y: y, width: rect.width, height: bandWidth).fill()
            y += step
        }
    }

    private static func drawHoundstooth(primary: NSColor, accent: NSColor, rect: NSRect) {
        primary.setFill()
        rect.fill()
        accent.setFill()
        // Classic 4-shape tooth built from a 32px tile, tiled across.
        let tile: CGFloat = 32
        var y: CGFloat = 0
        while y < rect.height {
            var x: CGFloat = 0
            while x < rect.width {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: x + tile * 0.25, y: y))
                path.line(to: NSPoint(x: x + tile * 0.75, y: y))
                path.line(to: NSPoint(x: x + tile, y: y + tile * 0.25))
                path.line(to: NSPoint(x: x + tile, y: y + tile * 0.75))
                path.line(to: NSPoint(x: x + tile * 0.75, y: y + tile))
                path.line(to: NSPoint(x: x + tile * 0.25, y: y + tile))
                path.line(to: NSPoint(x: x, y: y + tile * 0.75))
                path.line(to: NSPoint(x: x, y: y + tile * 0.25))
                path.close()
                path.fill()
                x += tile
            }
            y += tile
        }
    }

    private static func drawStatic(primary: NSColor, accent: NSColor, rect: NSRect) {
        // CRT snow — random 2×2 specks of both colors over a mid-field fill.
        let mid = primary.blended(withFraction: 0.5, of: accent) ?? primary
        mid.setFill()
        rect.fill()
        let pixelsPerAxis = 128
        let pixelSize = rect.width / CGFloat(pixelsPerAxis)
        var rng = SystemRandomNumberGenerator()
        for py in 0..<pixelsPerAxis {
            for px in 0..<pixelsPerAxis {
                let roll = Double(rng.next() % 1_000_000) / 1_000_000.0
                if roll < 0.30 {
                    (roll < 0.15 ? primary : accent).setFill()
                    NSRect(
                        x: CGFloat(px) * pixelSize,
                        y: CGFloat(py) * pixelSize,
                        width: pixelSize,
                        height: pixelSize
                    ).fill()
                }
            }
        }
    }

    private static func drawGradient(primary: NSColor, accent: NSColor, rect: NSRect) {
        let grad = NSGradient(colors: [primary, accent])
        grad?.draw(in: rect, angle: -45)
    }
}
