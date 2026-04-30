#!/usr/bin/env bash
#
# One-time notarization setup for max_clawdroom.
#
#   ./tools/setup-notarization.sh
#
# Walks through the three things package.sh needs to run unattended:
#
#   1. App-specific password stored under the project-scoped Keychain
#      profile name `notarytool-max_clawdroom`. Project-scoped so it
#      can never collide with another app's notary profile on the
#      same machine.
#
#   2. (Optional) Keychain partition list updated to grant
#      `apple-tool:` and `apple:` ACLs to xcrun / codesign / notarytool.
#      Without this, every codesign + notarytool call during a build
#      pops "allow access?" dialogs interactively. Granting the
#      partition list once removes them all.
#
#   3. Verifies the Developer ID Application cert is present in the
#      login keychain so signing won't fail at the codesign step.
#
# What this DOESN'T do:
#   - Create your Apple Developer account
#   - Create the app-specific password (you do that at appleid.apple.com
#     → Sign-In and Security → App-Specific Passwords)
#   - Touch any other app's notary profile — uses a name that mentions
#     max_clawdroom explicitly so cross-pollination with other Mac apps
#     you maintain (or anyone else's) is impossible.
#
# Safe to re-run; idempotent. Existing profile + partition entries
# are overwritten with the values you re-enter.

set -euo pipefail

PROFILE_NAME="notarytool-max_clawdroom"

cat <<EOF

╭─────────────────────────────────────────────────────────────╮
│  max_clawdroom — notarization setup                         │
╰─────────────────────────────────────────────────────────────╯

This stores your Apple credentials so package.sh can sign + notarize
+ staple without prompting you mid-build.

You'll need:
  • Your Apple ID email
  • Your Team ID (10-char string from developer.apple.com → Membership)
  • An app-specific password — generate at:
      https://account.apple.com/account/manage → Sign-In and Security
      → App-Specific Passwords → "+" → label it "max_clawdroom-notary"

EOF

read -p "Apple ID email: " APPLE_ID
read -p "Team ID (10 chars, e.g. ABC1234DEF): " TEAM_ID
echo
echo "App-specific password (input hidden): "
read -s APP_PASSWORD
echo

if [ -z "${APPLE_ID}" ] || [ -z "${TEAM_ID}" ] || [ -z "${APP_PASSWORD}" ]; then
  echo "ERROR: all three values are required." >&2
  exit 1
fi

echo "→ Storing credentials under Keychain profile: ${PROFILE_NAME}"
xcrun notarytool store-credentials "${PROFILE_NAME}" \
  --apple-id "${APPLE_ID}" \
  --team-id "${TEAM_ID}" \
  --password "${APP_PASSWORD}"

echo
echo "→ Verifying Developer ID Application cert is installed…"
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  CERT_LINE=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1)
  echo "  ✓ Found: ${CERT_LINE}"
else
  cat <<EOF >&2
  ✗ No "Developer ID Application" cert found in your codesigning keychain.

  Get one at developer.apple.com → Certificates → "+" → Developer ID
  Application. Download + double-click the .cer to install. Re-run
  this script when done.
EOF
  exit 1
fi

echo
read -p "Grant apple-tool:/apple: keychain access so signing doesn't prompt? [Y/n] " GRANT_ACL
GRANT_ACL=${GRANT_ACL:-Y}
if [[ "${GRANT_ACL}" =~ ^[Yy]$ ]]; then
  echo
  echo "→ Setting partition list on login keychain (will prompt for your"
  echo "  Mac login password ONCE — this is the only password popup;"
  echo "  after this signing + notarytool run silently)."
  echo
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "" \
    "$HOME/Library/Keychains/login.keychain-db" \
    || {
      echo
      echo "  Partition list update failed. Most likely cause: your"
      echo "  login keychain is locked, or the password prompt was"
      echo "  cancelled. Re-run this script if you want to retry."
      exit 1
    }
  echo "  ✓ Partition list updated."
fi

cat <<EOF

╭─────────────────────────────────────────────────────────────╮
│  Setup complete.                                            │
╰─────────────────────────────────────────────────────────────╯

Profile name : ${PROFILE_NAME}
Apple ID     : ${APPLE_ID}
Team ID      : ${TEAM_ID}

Next: build a signed + notarized DMG with

  DEVELOPER_ID_APPLICATION="Developer ID Application: <Your Name> (${TEAM_ID})" \\
  ./tools/package.sh

To rotate the app-specific password later, just re-run this script.
To use a different profile name (e.g. for a CI runner), set
NOTARY_PROFILE before running package.sh:

  NOTARY_PROFILE=notarytool-max_clawdroom-ci ./tools/package.sh

EOF
