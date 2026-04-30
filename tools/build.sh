#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Compile Localizable.xcstrings into per-locale .lproj/Localizable.strings.
# `swift build` ships .xcstrings as a raw resource — at runtime
# `String(localized:bundle:.module)` then can't resolve and falls back to
# rendering the KEY itself (visible as `menu.summon` in the menu bar
# instead of "Summon"). Pre-compiling to .lproj/.strings produces what
# CFBundle expects and the lookup works. Source of truth is the catalog
# JSON; the .lproj outputs are committed alongside it as build artefacts.
if [ -f Sources/Companion/Resources/Localizable.xcstrings ]; then
  echo "==> compiling Localizable.xcstrings"
  xcrun xcstringstool compile \
    Sources/Companion/Resources/Localizable.xcstrings \
    --output-directory Sources/Companion/Resources/
fi

swift build
echo "==> done"
