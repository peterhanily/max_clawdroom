#!/usr/bin/env bash
# Build → bundle → sign → notarize → staple max_clawdroom.
#
# Prerequisites (one-time setup):
#   - Paid Apple Developer Program membership
#   - `Developer ID Application: <Your Name> (<TEAMID>)` cert in
#     login keychain
#   - App-scoped app-specific password stored under the profile name
#     `notarytool-max_clawdroom`. Run tools/setup-notarization.sh once
#     and follow the prompts — it creates the profile under the
#     project-scoped name AND grants xcrun/codesign keychain access
#     so signing/notarizing don't pop password prompts mid-build.
#     Manual equivalent:
#       xcrun notarytool store-credentials notarytool-max_clawdroom \
#         --apple-id you@example.com \
#         --team-id XXXXXXXXXX \
#         --password <app-specific-password>
#
# Env vars (required):
#   DEVELOPER_ID_APPLICATION  — e.g. "Developer ID Application: Your Name (ABC1234DEF)"
#
# Env vars (optional):
#   NOTARY_PROFILE            — keychain profile name (default: "notarytool-max_clawdroom")
#   SKIP_NOTARIZE=1           — skip the submit+staple step (local signed build only)
#   SKIP_BUILD=1              — skip `swift build` (reuse what's in .build/)
#
# Output:
#   dist/max_clawdroom.app  — signed, notarized, stapled
#   dist/max_clawdroom-0.1.0.zip  — distributable zip
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION env var — see tools/package.sh for details}"
# App-scoped notary profile name. Each Mac app should have its own
# keychain profile so an unrelated pipeline on the same machine can't
# clobber this one. Override with NOTARY_PROFILE=… if you've been using
# a different name historically.
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool-max_clawdroom}"

# Refuse to ship a build whose Sparkle EdDSA key is still the placeholder.
# Without a real key the auto-update flow accepts arbitrary signed appcasts
# — i.e. any MITM can serve a malicious DMG. See RELEASE.md for the
# `generate_keys` flow. Override with ALLOW_PLACEHOLDER_SPARKLE_KEY=1 if
# you're knowingly cutting an internal build with no update channel.
SPARKLE_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Packaging/Info.plist 2>/dev/null || true)"
if [ "${SPARKLE_KEY}" = "REPLACE_WITH_SPARKLE_EDDSA_PUBLIC_KEY" ]; then
  if [ -z "${ALLOW_PLACEHOLDER_SPARKLE_KEY:-}" ]; then
    cat >&2 <<EOF
ERROR: Sparkle SUPublicEDKey is still the placeholder.

Generate the keypair, store the private half in your login keychain,
copy the public half into Packaging/Info.plist:

    .build/checkouts/Sparkle/bin/generate_keys
    # Public key prints to stdout — paste into <key>SUPublicEDKey</key>

If this is an unsigned local build with no update channel:
    ALLOW_PLACEHOLDER_SPARKLE_KEY=1 ${0}
EOF
    exit 1
  else
    echo "WARN: SUPublicEDKey is the placeholder — auto-update is unverifiable."
  fi
fi

BUILD_CONFIG="release"
BINARY_NAME="max_clawdroom"
APP_NAME="max_clawdroom.app"
DIST_DIR="dist"
APP_PATH="${DIST_DIR}/${APP_NAME}"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Packaging/Info.plist)"

# Build into a sanitized path. SwiftPM's auto-generated
# resource_bundle_accessor.swift (one per package that ships
# resources — GLTFSceneKit and Sparkle in our graph) embeds the
# absolute build path as a string constant in the resulting
# Mach-O. With the default `.build/` location, that means the
# shipping DMG leaks the developer's home-directory username via
# `strings ./max_clawdroom.app/Contents/MacOS/max_clawdroom`.
# Redirecting --build-path to /private/tmp/maxclawdroom-build
# makes the embedded path generic across machines + users.
RELEASE_BUILD_PATH="/private/tmp/maxclawdroom-release-build"
BUILD_DIR="${RELEASE_BUILD_PATH}/arm64-apple-macosx/${BUILD_CONFIG}"

# ───────────────────────────────────────────────────────────── 1. Build
if [ -z "${SKIP_BUILD:-}" ]; then
  # Wipe any prior contents so a previous user/branch's build
  # artefacts can't sneak into this release. Cheap; release builds
  # are fully redo'd anyway.
  rm -rf "${RELEASE_BUILD_PATH}"
  echo "==> swift build -c ${BUILD_CONFIG} --build-path ${RELEASE_BUILD_PATH}"
  swift build -c "${BUILD_CONFIG}" --build-path "${RELEASE_BUILD_PATH}"
fi

if [ ! -f "${BUILD_DIR}/${BINARY_NAME}" ]; then
  echo "ERROR: ${BUILD_DIR}/${BINARY_NAME} missing after build" >&2
  exit 1
fi

# ──────────────────────────────────────────────────── 2. Assemble .app
echo "==> assembling ${APP_PATH}"
rm -rf "${APP_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS"
mkdir -p "${APP_PATH}/Contents/Resources"

cp "${BUILD_DIR}/${BINARY_NAME}" "${APP_PATH}/Contents/MacOS/${BINARY_NAME}"
chmod +x "${APP_PATH}/Contents/MacOS/${BINARY_NAME}"
cp Packaging/Info.plist "${APP_PATH}/Contents/Info.plist"

# Bundle icon. tools/build-icon.sh renders it from the 🌝 glyph; if
# the .icns isn't present (someone forgot to run it), we render on
# demand here so the .app never ships with Finder's generic white-box
# icon for un-iconned bundles.
if [ ! -f "Packaging/AppIcon.icns" ]; then
  echo "→ AppIcon.icns missing — rendering now via tools/build-icon.sh"
  ./tools/build-icon.sh
fi
cp "Packaging/AppIcon.icns" "${APP_PATH}/Contents/Resources/AppIcon.icns"

# Stage Sparkle.framework into Contents/Frameworks. SwiftPM resolves
# the binary XCFramework into BUILD_DIR but doesn't copy it next to
# the product, so the resulting .app would otherwise have a dangling
# `@rpath/Sparkle.framework/...` load command and crash before main()
# with "Library not loaded".
SPARKLE_SRC="${BUILD_DIR}/Sparkle.framework"
if [ -d "${SPARKLE_SRC}" ]; then
  mkdir -p "${APP_PATH}/Contents/Frameworks"
  rm -rf "${APP_PATH}/Contents/Frameworks/Sparkle.framework"
  /usr/bin/ditto "${SPARKLE_SRC}" "${APP_PATH}/Contents/Frameworks/Sparkle.framework"
else
  echo "WARN: ${SPARKLE_SRC} missing — bundle will fail to launch with 'Library not loaded: @rpath/Sparkle.framework'." >&2
fi

# Add the missing @executable_path/../Frameworks rpath so dyld can
# resolve `@rpath/Sparkle.framework/...` at launch. SwiftPM only emits
# `@executable_path/` as an LC_RPATH on its plain executable products,
# which breaks the "framework next to the binary's parent" convention
# every Cocoa-style .app bundle relies on. install_name_tool is the
# standard tool for the surgery; it edits the load commands in place.
# Idempotent — `|| true` so a second run (e.g. SKIP_BUILD retries)
# doesn't fail when the rpath is already there.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "${APP_PATH}/Contents/MacOS/${BINARY_NAME}" 2>/dev/null || true

# Stage MLX metallib next to the executable if it was built.
if [ -f "${BUILD_DIR}/mlx.metallib" ]; then
  cp "${BUILD_DIR}/mlx.metallib" "${APP_PATH}/Contents/MacOS/mlx.metallib"
fi
# Debug builds sometimes produce metallib at a different path.
if [ -f ".build/arm64-apple-macosx/debug/mlx.metallib" ] && [ ! -f "${APP_PATH}/Contents/MacOS/mlx.metallib" ]; then
  cp ".build/arm64-apple-macosx/debug/mlx.metallib" "${APP_PATH}/Contents/MacOS/mlx.metallib"
fi

# Stage SwiftPM-generated resource bundles into Contents/Resources/.
# Standard macOS app structure → codesign happy, notary happy.
#
# We replaced SwiftPM's auto-generated `Bundle.module` accessor with
# our own `Bundle.companionResources` (in _BundleAccessor.swift) that
# looks at `Bundle.main.resourceURL.appendingPathComponent(<name>)`,
# which IS Contents/Resources/. Every `bundle: .module` callsite in
# Sources/Companion/ has been refactored to `.companionResources`.
#
# GLTFSceneKit's own resource bundle (containing GLTF/VRM shaders)
# would still try to use its auto-generated Bundle.module which we
# can't refactor. We don't ship its bundle here — only triggered if
# the user loads a custom .glb/.gltf file, which v0.1.0 doesn't do
# in any first-run path. If they ever do, GLTFSceneKit fatalErrors
# and we fix forward.
shopt -s nullglob 2>/dev/null || true
mkdir -p "${APP_PATH}/Contents/Resources"
for src in "${BUILD_DIR}"/*.bundle; do
  [ -d "$src" ] || continue
  name="$(basename "${src}")"
  # Skip GLTFSceneKit's bundle — see above.
  case "${name}" in
    GLTFSceneKit_*) continue ;;
  esac
  rm -rf "${APP_PATH}/Contents/Resources/${name}"
  /usr/bin/ditto "${src}" "${APP_PATH}/Contents/Resources/${name}"
done

# ───────────────────────────────────────────────────────── 3. Codesign
# Sign inside-out: nested frameworks/libs first, then the app wrapper.
# Hardened Runtime (--options runtime) is required for notarization.
echo "==> codesigning"

# Sign the metallib if present so library validation + notarization accept it.
if [ -f "${APP_PATH}/Contents/MacOS/mlx.metallib" ]; then
  codesign --force --sign "${DEVELOPER_ID_APPLICATION}" \
    --timestamp \
    "${APP_PATH}/Contents/MacOS/mlx.metallib"
fi

# Sign every nested executable + bundle under Sparkle.framework
# inside-out. Sparkle's published layout (as of Sparkle 2.6) ships
# multiple binaries with original signatures from the Sparkle project,
# all of which must be re-signed with OUR Developer ID for notary:
#   Versions/B/Sparkle                         (main dylib)
#   Versions/B/Autoupdate                      (bare CLI helper)
#   Versions/B/Updater.app/Contents/MacOS/...  (auto-update helper)
#   Versions/B/XPCServices/Downloader.xpc/...  (sandboxed downloader)
#   Versions/B/XPCServices/Installer.xpc/...   (sandboxed installer)
#
# Hand-listing them is fragile — Sparkle has shipped new helpers (e.g.
# the Autoupdate CLI in 2.6) without notice. Walk for ALL executables
# instead, then bundle wrappers, then the framework wrapper.
SPARKLE_FW="${APP_PATH}/Contents/Frameworks/Sparkle.framework"
if [ -d "${SPARKLE_FW}" ]; then
  # 1. Every executable file (regular files with the user-execute bit).
  #    Sort reversed so deeper paths sign first — codesign requires
  #    inner code to be signed before the wrapper that contains it.
  find "${SPARKLE_FW}" -type f -perm +0100 | sort -r | while read -r exe; do
    codesign --force --sign "${DEVELOPER_ID_APPLICATION}" \
      --timestamp --options runtime \
      "$exe"
  done
  # 2. Bundle wrappers (.app, .xpc) — inner executables are already signed.
  find "${SPARKLE_FW}" -type d \( -name "*.app" -o -name "*.xpc" \) | sort -r | while read -r bundle; do
    codesign --force --sign "${DEVELOPER_ID_APPLICATION}" \
      --timestamp --options runtime \
      "${bundle}"
  done
  # 3. Framework wrapper.
  codesign --force --sign "${DEVELOPER_ID_APPLICATION}" \
    --timestamp --options runtime \
    "${SPARKLE_FW}"
fi

# Sign any other dylib siblings under Frameworks/ (future-proofing).
if [ -d "${APP_PATH}/Contents/Frameworks" ]; then
  find "${APP_PATH}/Contents/Frameworks" -maxdepth 2 -type f -name "*.dylib" | while read -r f; do
    codesign --force --sign "${DEVELOPER_ID_APPLICATION}" \
      --timestamp --options runtime \
      "$f"
  done
fi

# Sign the main executable WITH hardened runtime + entitlements.
codesign --force --sign "${DEVELOPER_ID_APPLICATION}" \
  --timestamp \
  --options runtime \
  --entitlements Packaging/max_clawdroom.entitlements \
  "${APP_PATH}/Contents/MacOS/${BINARY_NAME}"

# Sign the wrapper. Same options as the executable; no entitlements at
# the wrapper level (entitlements on the executable propagate).
codesign --force --sign "${DEVELOPER_ID_APPLICATION}" \
  --timestamp \
  --options runtime \
  --entitlements Packaging/max_clawdroom.entitlements \
  "${APP_PATH}"

# Verify.
echo "==> verifying signature"
codesign --verify --verbose=2 "${APP_PATH}"
spctl --assess --type execute --verbose "${APP_PATH}" 2>&1 | head -5 || true

if [ -n "${SKIP_NOTARIZE:-}" ]; then
  echo "==> SKIP_NOTARIZE set; stopping after sign"
  exit 0
fi

# ──────────────────────────────────────────────────────── 4. Notarize
# Zip for upload (notarytool accepts .zip, .pkg, or .dmg).
ZIP_PATH="${DIST_DIR}/${BINARY_NAME}-${VERSION}-notarize.zip"
echo "==> zipping for notarization submission"
/usr/bin/ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

echo "==> submitting to Apple notary service (may take a few minutes)"
xcrun notarytool submit "${ZIP_PATH}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait

# ───────────────────────────────────────────────────────── 5. Staple
echo "==> stapling ticket"
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"

# ──────────────────────────────────────────────── 6. Distributable artefacts
FINAL_ZIP="${DIST_DIR}/${BINARY_NAME}-${VERSION}.zip"
rm -f "${FINAL_ZIP}"
/usr/bin/ditto -c -k --keepParent "${APP_PATH}" "${FINAL_ZIP}"

# Clean up the notarization-only zip.
rm -f "${ZIP_PATH}"

# DMG — user-friendly download artefact. Drag-to-Applications shortcut
# baked in via create-dmg if available, else a plain hdiutil image.
# hdiutil is always present on macOS so the fallback is zero-install.
DMG_PATH="${DIST_DIR}/${BINARY_NAME}-${VERSION}.dmg"
rm -f "${DMG_PATH}"
if command -v create-dmg >/dev/null 2>&1; then
  echo "==> building DMG with create-dmg (drag-to-Applications)"
  create-dmg \
    --volname "${BINARY_NAME}" \
    --window-pos 200 120 \
    --window-size 600 320 \
    --icon-size 96 \
    --icon "${BINARY_NAME}.app" 150 160 \
    --app-drop-link 450 160 \
    --no-internet-enable \
    "${DMG_PATH}" \
    "${APP_PATH}" \
    >/dev/null
else
  echo "==> create-dmg not found; building plain hdiutil DMG"
  echo "    (brew install create-dmg for a nicer drag-to-Applications layout)"
  STAGING_DIR="$(mktemp -d)"
  cp -R "${APP_PATH}" "${STAGING_DIR}/"
  ln -s /Applications "${STAGING_DIR}/Applications"
  hdiutil create \
    -volname "${BINARY_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -ov -format UDZO \
    "${DMG_PATH}" \
    >/dev/null
  rm -rf "${STAGING_DIR}"
fi

# Sign + notarize the DMG itself so Gatekeeper is happy when users
# double-click it. `stapler staple` on the DMG requires the inner .app
# to already be stapled — which it is, from step 5.
echo "==> signing DMG"
codesign --force --sign "${DEVELOPER_ID_APPLICATION}" \
  --options runtime \
  --timestamp \
  "${DMG_PATH}"

if [ -z "${SKIP_DMG_NOTARIZE:-}" ]; then
  echo "==> submitting DMG to notary (Gatekeeper needs this too)"
  xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait
  xcrun stapler staple "${DMG_PATH}"
fi

echo ""
echo "==> done"
echo "    signed + notarized + stapled .app:  ${APP_PATH}"
echo "    distributable zip:                  ${FINAL_ZIP}"
echo "    distributable DMG:                  ${DMG_PATH}"
echo ""
echo "Final verify (should print 'source=Notarized Developer ID'):"
spctl --assess --type execute --verbose=4 "${APP_PATH}" 2>&1 | head -5
