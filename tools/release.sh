#!/usr/bin/env bash
#
# Release driver for max_clawdroom.
#
# Reads the version from Packaging/Info.plist, builds + signs +
# notarizes via package.sh, computes the DMG sha256, bumps the
# Homebrew cask, commits + tags + pushes, and creates the GitHub
# Release with both DMG and ZIP attached.
#
# Does NOT touch the Sparkle appcast — that lives in the separate
# maxclawdroom-site repo and ships when you deploy the site. After
# this script completes, the new release is downloadable via the
# direct URL and via `brew install --cask`, but Sparkle won't push
# the update to existing users until the appcast.xml is bumped.
#
# Usage:
#   export DEVELOPER_ID_APPLICATION="Developer ID Application: ..."
#   ./tools/release.sh
#
# Prerequisites (one-time):
#   ./tools/setup-notarization.sh
#   gh auth login          (one-time, for GitHub release creation)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION env var (Developer ID Application: Your Name (TEAMID))}"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Packaging/Info.plist)"
TAG="v${VERSION}"
DMG_NAME="max_clawdroom-${VERSION}.dmg"
ZIP_NAME="max_clawdroom-${VERSION}.zip"
DMG_PATH="dist/${DMG_NAME}"
ZIP_PATH="dist/${ZIP_NAME}"
CASK_PATH="Casks/max_clawdroom.rb"

echo "→ Releasing max_clawdroom ${VERSION} (tag ${TAG})"
echo

# ─── pre-flight ────────────────────────────────────────────────
if git rev-parse --verify "${TAG}" >/dev/null 2>&1; then
  echo "ERROR: tag ${TAG} already exists. Bump the version in" >&2
  echo "       Packaging/Info.plist first (CFBundleShortVersionString)." >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree has uncommitted changes:"
  git status --short
  echo
  read -p "Commit them as 'Pre-release: prep for ${TAG}' before tagging? [y/N] " ANS
  case "${ANS}" in [yY]*) git add -A && git commit -m "Pre-release: prep for ${TAG}" ;; *) echo "Aborting — clean the working tree first." >&2; exit 1 ;; esac
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI not found. Install with brew install gh." >&2
  exit 1
fi
gh auth status >/dev/null 2>&1 || { echo "ERROR: not authenticated with gh. Run gh auth login." >&2; exit 1; }

# ─── 1. Build + sign + notarize + staple via package.sh ─────────
echo "→ [1/4] Building, signing, notarizing — via tools/package.sh"
./tools/package.sh

if [ ! -f "${DMG_PATH}" ]; then
  echo "ERROR: ${DMG_PATH} not produced by package.sh" >&2
  exit 1
fi
if [ ! -f "${ZIP_PATH}" ]; then
  echo "ERROR: ${ZIP_PATH} not produced by package.sh" >&2
  exit 1
fi

# ─── 2. Compute sha256, bump cask ─────────────────────────────
SHA="$(/usr/bin/shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"
echo
echo "→ [2/4] DMG sha256: ${SHA}"

if [ ! -f "${CASK_PATH}" ]; then
  echo "ERROR: ${CASK_PATH} missing" >&2
  exit 1
fi

# Update version + sha256 in the cask. Conservative regex — matches
# only inside the existing cask block; bails if either line is missing.
perl -i -pe 's/^(\s*version\s+)"[^"]*"/$1"'${VERSION}'"/' "${CASK_PATH}"
perl -i -pe 's/^(\s*sha256\s+)"[^"]*"/$1"'${SHA}'"/' "${CASK_PATH}"

# Sanity-check the substitutions actually landed.
grep -q "version \"${VERSION}\"" "${CASK_PATH}" || { echo "ERROR: cask version line wasn't updated" >&2; exit 1; }
grep -q "sha256 \"${SHA}\"" "${CASK_PATH}" || { echo "ERROR: cask sha256 line wasn't updated" >&2; exit 1; }

git add "${CASK_PATH}"
git commit -m "Cask: bump to ${TAG} (sha256 ${SHA:0:12}…)"

# ─── 3. Tag + push ────────────────────────────────────────────
echo
echo "→ [3/4] Tagging ${TAG} and pushing"
git tag -a "${TAG}" -m "max_clawdroom ${VERSION}"
git push origin main
git push origin "${TAG}"

# ─── 4. GitHub Release with assets ────────────────────────────
echo
echo "→ [4/4] Creating GitHub release with DMG + ZIP attached"

# Pull the unreleased section from the changelog as the release body.
# Falls back to a minimal note if the section markers aren't found.
NOTES_FILE="$(mktemp)"
trap "rm -f '${NOTES_FILE}'" EXIT
awk '
  /^## \[Unreleased\]/         { capture = 1; next }
  /^## \[/ && capture           { exit }
  capture                       { print }
' CHANGELOG.md > "${NOTES_FILE}"
if [ ! -s "${NOTES_FILE}" ]; then
  printf "max_clawdroom %s\n\nSee CHANGELOG.md for full notes.\n" "${VERSION}" > "${NOTES_FILE}"
fi

gh release create "${TAG}" \
  "${DMG_PATH}" \
  "${ZIP_PATH}" \
  --title "${TAG}" \
  --notes-file "${NOTES_FILE}"

echo
echo "✓ Released ${TAG}"
echo "  DMG: $(stat -f %z "${DMG_PATH}") bytes  sha256 ${SHA}"
echo "  ZIP: $(stat -f %z "${ZIP_PATH}") bytes"
echo
echo "→ NEXT: update appcast.xml on the maxclawdroom-site repo so"
echo "  Sparkle pushes the update to existing users. Sign the DMG"
echo "  with sign_update + put the new <item> entry in appcast.xml,"
echo "  then deploy the site. The cask + GitHub release are live now"
echo "  for new users via brew install / direct download."
