// Renders 🌝 to a full macOS .iconset at all required sizes.
//
// Run via tools/build-icon.sh, or directly:
//   swift tools/build-icon.swift
//
// Output: Packaging/AppIcon.iconset/icon_NxN[@2x].png (10 PNGs).
// build-icon.sh then runs `iconutil -c icns` against that directory
// to produce Packaging/AppIcon.icns.
//
// Re-run whenever the icon glyph or styling changes.

import AppKit
import Foundation

let glyph = "🌝"
let outDir = "Packaging/AppIcon.iconset"

// macOS icon set: each pt-size has @1x and @2x. iconutil pairs them
// into the multi-resolution .icns automatically based on filenames.
let sizes: [(name: String, px: Int)] = [
    ("16x16",      16),
    ("16x16@2x",   32),
    ("32x32",      32),
    ("32x32@2x",   64),
    ("128x128",   128),
    ("128x128@2x", 256),
    ("256x256",   256),
    ("256x256@2x", 512),
    ("512x512",   512),
    ("512x512@2x", 1024),
]

try? FileManager.default.createDirectory(
    atPath: outDir, withIntermediateDirectories: true
)

for (name, px) in sizes {
    let size = CGSize(width: px, height: px)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()

    // Emoji is rendered through the system font at most of the
    // pixel size — leaving a small breathing margin so the disk
    // doesn't touch the canvas edges (matches the conventional
    // Apple-icon padding).
    let fontSize = CGFloat(px) * 0.84
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize),
        .foregroundColor: NSColor.black
    ]
    let str = NSAttributedString(string: glyph, attributes: attrs)
    let drawSize = str.size()
    let origin = CGPoint(
        x: (size.width  - drawSize.width)  / 2,
        y: (size.height - drawSize.height) / 2 - CGFloat(px) * 0.04
    )
    str.draw(at: origin)
    image.unlockFocus()

    guard
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write(Data("failed to encode \(name)\n".utf8))
        continue
    }
    let path = "\(outDir)/icon_\(name).png"
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(px)px)")
}
