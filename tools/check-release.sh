#!/usr/bin/env bash
#
# Release manifest consistency check for max_clawdroom.
#
# Two modes:
#
#   ./tools/check-release.sh --pre-build
#       Validates only the things that MUST match in the repo at the
#       moment we're about to build (Info.plist ↔ CHANGELOG most-
#       recent dated heading). Skips downstream gates that get updated
#       *after* the build by design (cask sha256, GitHub release tag,
#       site copy, Sparkle sig). Wired into tools/package.sh.
#
#   ./tools/check-release.sh           (full mode, default)
#       Validates the entire chain — everything in pre-build mode plus
#       cask version, latest GitHub release tag, site JSON-LD + hero
#       pill, appcast head item, and Sparkle sig verify. Run this AFTER
#       the release is fully published as a smoke gate before
#       announcing.
#
# Exit codes:
#   0  — all checks passed
#   1  — at least one mismatch / missing artefact / bad signature
#   2  — invocation error (missing tool, wrong cwd, etc.)
#
# Site repo path can be overridden via SITE_REPO=...; defaults to a
# sibling checkout next to this repo. Full mode warns (not errors) on
# missing site repo; pre-build mode never reads it.

set -uo pipefail

MODE=full
case "${1:-}" in
  --pre-build) MODE=pre-build ;;
  "") MODE=full ;;
  -h|--help)
    sed -n '/^#/p' "$0" | head -30
    exit 0
    ;;
  *)
    echo "usage: $0 [--pre-build]" >&2
    exit 2
    ;;
esac

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

echo "${BOLD}max_clawdroom release manifest check (mode: ${MODE})${NC}"
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
# Cask version is bumped AFTER the DMG exists (so the sha256 is real),
# so it lags Info.plist during a release-in-progress. Skip in pre-build
# mode; full mode runs it as part of the post-publish smoke check.
if [ "$MODE" = full ]; then
  CASK_VERSION=$(grep -m1 -E '^[[:space:]]*version "' Casks/max_clawdroom.rb 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/' || true)
  if [ "$CASK_VERSION" = "$EXPECTED" ]; then
    ok "Casks/max_clawdroom.rb: ${CASK_VERSION}"
  else
    err "Casks/max_clawdroom.rb: ${CASK_VERSION:-<none>} (expected ${EXPECTED})"
  fi
fi

# ── 4. GitHub release (network) ──────────────────────────────────────
# GitHub release tag is created AFTER the DMG is built and uploaded,
# so it also lags during release-in-progress. Full mode only.
if [ "$MODE" = full ]; then
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
fi

# ── 5/6. Site repo ────────────────────────────────────────────────────
# Site appcast + hero pill + JSON-LD all updated after the DMG is
# Sparkle-signed. Full mode only.
if [ "$MODE" = full ] && [ -n "$SITE_REPO" ] && [ -d "$SITE_REPO" ]; then
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
elif [ "$MODE" = full ]; then
  warn "site repo not found (set SITE_REPO=path or check out next to this repo)"
fi

# ── 7. Sparkle signature ──────────────────────────────────────────────
# DMG + Sparkle sig don't exist until after the build. Full mode only.
if [ "$MODE" = full ]; then
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
fi  # end Sparkle sig block

echo
if [ $FAIL -eq 0 ]; then
  printf "${GREEN}${BOLD}all checks passed${NC} — manifest consistent at v${EXPECTED}\n"
  exit 0
else
  printf "${RED}${BOLD}manifest mismatch${NC} — fix the items marked ${RED}✗${NC} above before shipping\n"
  exit 1
fi
