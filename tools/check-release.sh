#!/usr/bin/env bash
#
# Pre-release manifest consistency check for max_clawdroom.
#
# Run with no args to validate the *current* state — every place that
# carries a version string must agree on one number, and the appcast
# entry for that version must verify against the Sparkle keychain
# account whose pubkey the app embeds.
#
#   ./tools/check-release.sh
#
# Exit codes:
#   0  — all checks passed
#   1  — at least one mismatch / missing artefact / bad signature
#   2  — invocation error (missing tool, wrong cwd, etc.)
#
# Designed to be cheap to run and safe to call repeatedly. The package
# build invokes this before staging artefacts so a misaligned ship
# never reaches notary.
#
# What it checks (one version string everywhere):
#   1. Packaging/Info.plist CFBundleShortVersionString
#   2. CHANGELOG.md most recent dated heading
#   3. Casks/max_clawdroom.rb `version`
#   4. Latest GitHub release tag (gh CLI, network)
#   5. Site `softwareVersion` JSON-LD + hero pill in index.html
#   6. Site appcast.xml head <item> sparkle:shortVersionString
#   7. Sparkle signature on dist/max_clawdroom-<v>.dmg verifies under
#      the `max_clawdroom` keychain account (the keychain default
#      `ed25519` account uses the wrong key — see RELEASE.md)
#
# Site repo path can be overridden via SITE_REPO=...; defaults to a
# sibling checkout next to this repo.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SITE_REPO="${SITE_REPO:-$(cd "$ROOT/../../maxclawdroom-site" 2>/dev/null && pwd || true)}"

# Coloured output only when stdout is a tty
if [ -t 1 ]; then
  GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  GREEN=""; RED=""; YELLOW=""; BOLD=""; NC=""
fi

FAIL=0
ok()   { printf "  ${GREEN}✓${NC} %s\n" "$1"; }
err()  { printf "  ${RED}✗${NC} %s\n" "$1"; FAIL=1; }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$1"; }

echo "${BOLD}max_clawdroom release manifest check${NC}"
echo

# ── 1. Info.plist ─────────────────────────────────────────────────────
INFO_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Packaging/Info.plist 2>/dev/null || true)
INFO_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Packaging/Info.plist 2>/dev/null || true)
if [ -z "$INFO_VERSION" ]; then
  err "Info.plist: CFBundleShortVersionString missing"
  exit 2
fi
ok "Info.plist: ${INFO_VERSION} (build ${INFO_BUILD})"

EXPECTED="$INFO_VERSION"

# ── 2. CHANGELOG.md ───────────────────────────────────────────────────
CHANGELOG_VERSION=$(grep -m1 -E '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md 2>/dev/null | sed -E 's/^## \[([0-9.]+)\].*/\1/' || true)
if [ "$CHANGELOG_VERSION" = "$EXPECTED" ]; then
  ok "CHANGELOG.md: ${CHANGELOG_VERSION}"
else
  err "CHANGELOG.md: ${CHANGELOG_VERSION:-<none>} (expected ${EXPECTED})"
fi

# ── 3. Cask ───────────────────────────────────────────────────────────
CASK_VERSION=$(grep -m1 -E '^[[:space:]]*version "' Casks/max_clawdroom.rb 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/' || true)
if [ "$CASK_VERSION" = "$EXPECTED" ]; then
  ok "Casks/max_clawdroom.rb: ${CASK_VERSION}"
else
  err "Casks/max_clawdroom.rb: ${CASK_VERSION:-<none>} (expected ${EXPECTED})"
fi

# ── 4. GitHub release (network) ──────────────────────────────────────
if command -v gh >/dev/null 2>&1; then
  GH_TAG=$(gh release list --repo peterhanily/max_clawdroom --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null || true)
  if [ "$GH_TAG" = "v$EXPECTED" ]; then
    ok "GitHub latest release: ${GH_TAG}"
  elif [ -z "$GH_TAG" ]; then
    warn "GitHub release lookup failed (offline? unauthenticated gh?)"
  else
    err "GitHub latest release: ${GH_TAG} (expected v${EXPECTED})"
  fi
else
  warn "gh CLI not found; skipping GitHub release tag check"
fi

# ── 5/6. Site repo ────────────────────────────────────────────────────
if [ -n "$SITE_REPO" ] && [ -d "$SITE_REPO" ]; then
  SITE_JSONLD=$(grep -E '"softwareVersion"' "$SITE_REPO/index.html" 2>/dev/null | sed -E 's/.*"softwareVersion": "([^"]+)".*/\1/' || true)
  if [ "$SITE_JSONLD" = "$EXPECTED" ]; then
    ok "site index.html JSON-LD softwareVersion: ${SITE_JSONLD}"
  else
    err "site index.html JSON-LD softwareVersion: ${SITE_JSONLD:-<none>} (expected ${EXPECTED})"
  fi

  SITE_PILL=$(grep -E 'pill.*v[0-9]+\.[0-9]+\.[0-9]+' "$SITE_REPO/index.html" 2>/dev/null | sed -E 's/.*v([0-9.]+).*/\1/' | head -1 || true)
  if [ "$SITE_PILL" = "$EXPECTED" ]; then
    ok "site index.html hero pill: v${SITE_PILL}"
  else
    err "site index.html hero pill: v${SITE_PILL:-<none>} (expected v${EXPECTED})"
  fi

  APPCAST_VERSION=$(grep -m1 -E 'sparkle:shortVersionString="' "$SITE_REPO/appcast.xml" 2>/dev/null | sed -E 's/.*sparkle:shortVersionString="([^"]+)".*/\1/' || true)
  if [ "$APPCAST_VERSION" = "$EXPECTED" ]; then
    ok "site appcast.xml head item: ${APPCAST_VERSION}"
  else
    err "site appcast.xml head item: ${APPCAST_VERSION:-<none>} (expected ${EXPECTED})"
  fi
else
  warn "site repo not found (set SITE_REPO=path or check out next to this repo)"
fi

# ── 7. Sparkle signature ──────────────────────────────────────────────
DMG="dist/max_clawdroom-${EXPECTED}.dmg"
SIGNER=".build/artifacts/sparkle/Sparkle/bin/sign_update"
if [ -f "$DMG" ] && [ -x "$SIGNER" ]; then
  if [ -n "$SITE_REPO" ] && [ -d "$SITE_REPO" ] && [ -n "${APPCAST_VERSION:-}" ] && [ "$APPCAST_VERSION" = "$EXPECTED" ]; then
    APPCAST_SIG=$(grep -A4 "sparkle:shortVersionString=\"${EXPECTED}\"" "$SITE_REPO/appcast.xml" 2>/dev/null | grep -m1 'edSignature' | sed -E 's/.*edSignature="([^"]+)".*/\1/' || true)
    if [ -n "$APPCAST_SIG" ]; then
      if "$SIGNER" --account max_clawdroom --verify "$DMG" "$APPCAST_SIG" >/dev/null 2>&1; then
        ok "appcast Sparkle sig verifies against DMG (account max_clawdroom)"
      else
        err "appcast Sparkle sig does NOT verify — wrong key, edited appcast, or stale DMG"
      fi
    else
      warn "couldn't extract Sparkle sig from appcast for v${EXPECTED}"
    fi
  else
    warn "skipping Sparkle sig verify (appcast not at ${EXPECTED} yet)"
  fi
elif [ ! -f "$DMG" ]; then
  warn "DMG not built yet (${DMG} missing); skipping Sparkle sig verify"
else
  warn "sign_update not found at ${SIGNER}; run swift build first"
fi

echo
if [ $FAIL -eq 0 ]; then
  printf "${GREEN}${BOLD}all checks passed${NC} — manifest consistent at v${EXPECTED}\n"
  exit 0
else
  printf "${RED}${BOLD}manifest mismatch${NC} — fix the items marked ${RED}✗${NC} above before shipping\n"
  exit 1
fi
