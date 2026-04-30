#!/bin/bash
#
# Renders the app icon (🌝 glyph) into Packaging/AppIcon.icns.
#
# Run from the project root:
#   ./tools/build-icon.sh
#
# Outputs:
#   Packaging/AppIcon.iconset/  — 10 PNGs (16/32/128/256/512 @1x and @2x)
#   Packaging/AppIcon.icns      — multi-resolution icns the bundle ships
#
# package.sh expects AppIcon.icns to exist; if it doesn't, the .app
# bundle ships without an icon (Finder shows a generic white box).
# Re-run this whenever the glyph or styling changes.

set -e

cd "$(dirname "$0")/.."

echo "→ Rendering glyph at 10 sizes…"
swift tools/build-icon.swift

echo "→ Packing into multi-resolution .icns…"
iconutil -c icns Packaging/AppIcon.iconset -o Packaging/AppIcon.icns

echo "✓ Wrote Packaging/AppIcon.icns ($(stat -f %z Packaging/AppIcon.icns) bytes)"
