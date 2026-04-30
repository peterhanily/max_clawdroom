# Notarization guide

End-to-end walkthrough for taking `max_clawdroom` from the SPM binary you build locally to a signed, hardened-runtime, notarized, stapled `.app` that Gatekeeper will open on any macOS machine without a "developer cannot be verified" warning.

Everything below runs from the repo root.

---

## TL;DR

One-time:
1. Enrol in [Apple Developer Program](https://developer.apple.com/programs/) (USD $99/year)
2. Create a **Developer ID Application** certificate in Keychain Access (or via Xcode → Settings → Accounts → Manage Certificates)
3. Generate an app-specific password at [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords
4. Save it to your keychain:
   ```bash
   xcrun notarytool store-credentials notarytool \
     --apple-id you@example.com \
     --team-id XXXXXXXXXX \
     --password <app-specific-password>
   ```

Every release:
```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (XXXXXXXXXX)"
./tools/package.sh
# → dist/max_clawdroom-0.1.0.zip
```

That zip is what you distribute.

---

## What notarization actually is

Apple's notarization service scans your signed binary for known malware signatures and confirms it was signed with a valid Developer ID certificate. On success you get a **notarization ticket**. `xcrun stapler` then staples that ticket into the `.app` so Gatekeeper can verify offline. Without notarization, macOS shows "cannot verify this app is free of malware" on first launch.

Three hard requirements:
1. **Signed with Developer ID** (not self-signed, not Ad-Hoc, not Apple Development)
2. **Hardened Runtime** enabled (`codesign --options runtime`)
3. **All executables** inside the bundle signed with timestamps (no unsigned dylibs / metallibs)

Our `tools/package.sh` handles all three.

---

## Prerequisites

### 1. Apple Developer Program enrolment
- $99/yr at <https://developer.apple.com/programs/>
- Can be personal or a D-U-N-S-registered company. Personal is fine for private alpha distribution.
- After approval (usually 24–48h), you get a Team ID (10-char string like `ABC1234DEF`).

### 2. Developer ID Application certificate
This is the cert used to sign. **Distinct** from "Apple Development" (for Xcode local builds) and "Mac Installer" (for .pkg packages).

Fastest path in Xcode:
1. Open Xcode → Settings → Accounts
2. Add your Apple ID
3. Select your team, click **Manage Certificates…**
4. `+` → **Developer ID Application**
5. Certificate now lives in your login keychain.

Verify:
```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
# → 1) ABCDEF1234... "Developer ID Application: Your Name (XXXXXXXXXX)"
```

Copy that full quoted string — you'll export it as `$DEVELOPER_ID_APPLICATION`.

### 3. App-specific password
`notarytool` needs a credential to talk to Apple's notary API. App-specific passwords are the easy path (the alternative is an API key JSON).

1. <https://appleid.apple.com> → Sign-In and Security → App-Specific Passwords
2. Generate one. Label it something memorable (e.g. `notarytool-max_clawdroom`).
3. Copy the 19-char password immediately — you can't see it again.

Store it in your keychain so future invocations don't have to retype:
```bash
xcrun notarytool store-credentials notarytool \
  --apple-id you@example.com \
  --team-id XXXXXXXXXX \
  --password abcd-efgh-ijkl-mnop
```

`notarytool` is the profile name. `tools/package.sh` defaults to reading this profile; override with `$NOTARY_PROFILE` if you use multiple Apple IDs.

---

## What gets signed, with which entitlements

See `Packaging/Info.plist` and `Packaging/max_clawdroom.entitlements`.

### Info.plist highlights
- `CFBundleIdentifier = com.peterhanily.max_clawdroom`
- `LSUIElement = YES` — menu-bar-only, no Dock icon
- `LSMinimumSystemVersion = 14.0`
- `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription` — for the upcoming wake-on-voice phase. Apple requires these even if unused today because the entitlement is present.

### Entitlements highlights
- **No sandbox** — `max_clawdroom` reads other apps' UI via the Accessibility API (EditorAwareness reads cursor line + selection from Xcode/Nova/VSCode). Sandboxing forbids this. Developer ID distribution permits it; Mac App Store distribution would not.
- `com.apple.security.cs.allow-jit` + `allow-unsigned-executable-memory` — MLX / Kokoro compiles Metal shaders at runtime.
- `com.apple.security.cs.disable-library-validation` — the bundled `mlx.metallib` isn't signed by Apple; library validation would otherwise refuse to load it.
- `com.apple.security.cs.allow-dyld-environment-variables` — the `claude` subprocess inherits our env; some users need `DYLD_*` or `PATH` overrides.
- `com.apple.security.network.client` — future agent ops might fetch URLs.
- `com.apple.security.device.audio-input` — wake-on-voice microphone access.

### What is NOT entitled
- `com.apple.security.app-sandbox` — intentional, see above.
- `com.apple.security.automation.apple-events` — Accessibility API uses a separate TCC bucket that the user grants in System Settings. No entitlement needed.
- `com.apple.security.files.user-selected.read-write` — not sandboxed, so filesystem access just works for `~/Library/Application Support/Companion/`.

---

## Running the pipeline

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (XXXXXXXXXX)"

# Full path: build + bundle + sign + notarize + staple
./tools/package.sh

# Or, incremental:
SKIP_NOTARIZE=1 ./tools/package.sh   # local signed .app only, skip submission
SKIP_BUILD=1 ./tools/package.sh      # reuse existing .build/ tree
```

Expected wall-clock times:
- `swift build -c release` — 2–4 min first time, <30s incremental
- Sign + zip — 10s
- Notarization submission + wait — **3–15 minutes** (Apple's queue; slower on release days)
- Staple — 2s

On success, `dist/` contains:
- `max_clawdroom.app` — the signed, notarized, stapled bundle
- `max_clawdroom-0.1.0.zip` — the distributable zip

Verify:
```bash
spctl --assess --type execute --verbose=4 dist/max_clawdroom.app
# Expect: "source=Notarized Developer ID"
```

---

## Verifying the ticket is stapled

Anyone with the zip should be able to launch without an internet connection and without a scary prompt. The staple check:

```bash
xcrun stapler validate dist/max_clawdroom.app
# → The validate action worked!
```

If that fails but `spctl --assess` passed, the ticket was produced but not stapled. Re-run `xcrun stapler staple dist/max_clawdroom.app`.

---

## Distribution

1. Upload `dist/max_clawdroom-0.1.0.zip` to the GitHub release (private repo releases are visible to collaborators).
2. Anyone on the repo's collaborator list can download, unzip, drag to `/Applications`, and launch.
3. First launch: macOS confirms "max_clawdroom" is from an identified developer and opened without a warning. Done.

### For non-collaborator distribution

If you want to hand the zip out beyond the GitHub team, the above still works — notarization is independent of distribution channel. Gatekeeper on the recipient's Mac will verify the stapled ticket offline. Most users won't even see a prompt.

### DMG alternative

If you want the "drag to Applications" installer feel:

```bash
# After a successful package.sh run:
hdiutil create -volname "max_clawdroom" \
  -srcfolder dist/max_clawdroom.app \
  -ov -format UDZO \
  dist/max_clawdroom-0.1.0.dmg

# DMGs need to be signed + notarized too:
codesign --force --sign "$DEVELOPER_ID_APPLICATION" \
  --timestamp \
  dist/max_clawdroom-0.1.0.dmg

xcrun notarytool submit dist/max_clawdroom-0.1.0.dmg \
  --keychain-profile notarytool \
  --wait

xcrun stapler staple dist/max_clawdroom-0.1.0.dmg
```

---

## Troubleshooting

### "No identity found"
Your `DEVELOPER_ID_APPLICATION` string doesn't match any certificate in your keychain. List them:
```bash
security find-identity -v -p codesigning
```

### "CSSMERR_TP_NOT_TRUSTED"
Your Developer ID cert expired or was revoked. Issue a new one in Xcode → Settings → Accounts → Manage Certificates.

### Notarization fails with "code object is not signed at all"
Something inside the bundle slipped through without a signature. Most common culprit: an extra dylib dropped into `Contents/Frameworks` after signing. Dig with:
```bash
xcrun notarytool log <submission-id> --keychain-profile notarytool
```

### Notarization fails with "hardened runtime not enabled"
The main executable was signed without `--options runtime`. Check the script didn't skip step 3. Re-sign manually:
```bash
codesign --force --sign "$DEVELOPER_ID_APPLICATION" \
  --timestamp --options runtime \
  --entitlements Packaging/max_clawdroom.entitlements \
  dist/max_clawdroom.app/Contents/MacOS/max_clawdroom
```

### Accessibility permission resets after each rebuild
macOS TCC keys the AX-trust record on the signing certificate + bundle ID. Your local SPM debug builds are signed ad-hoc with a different identity each build, so TCC forgets. Notarized Developer ID builds are signed with a **stable** identity, so once the user grants AX once, it persists across updates.

### MLX metallib rejected by notarization
The notary service catches unsigned code in the bundle. `tools/package.sh` signs `mlx.metallib` before signing the wrapper; if you add other binaries (e.g. a separate CLI helper), sign them too before the main executable.

### "ERROR ITMS-90000: Unable to extract embedded profile"
You're trying to distribute to the Mac App Store without a sandbox entitlement. Wrong channel. Developer ID distribution doesn't need a provisioning profile and doesn't care about the MAS checks.

### Gatekeeper quarantine dialog still appears after notarization
The staple is scoped to the `.app` bundle, not the containing zip. When you ditto-zip a notarized app, the ticket travels with the app *inside* the zip; macOS re-reads it on first launch. If you see the dialog anyway, re-run:
```bash
xcrun stapler staple dist/max_clawdroom.app
xcrun stapler validate dist/max_clawdroom.app
```

### "You must first sign the relevant contracts online"
Your developer account has new agreements to accept. Go to <https://developer.apple.com/account/> and accept any pending agreements. Then re-submit.

---

## CI notes (future)

When moving the pipeline to GitHub Actions:
- Store `DEVELOPER_ID_APPLICATION` and an **API key** (not an app-specific password) as repo secrets. App-specific passwords tied to a human Apple ID are brittle for CI.
- Import the cert from a `.p12` file at job start, delete it at job end (`security delete-keychain`).
- Cache `.build/` across runs for faster incremental builds.
- The notary submission wait (10+ min) is cheap but bounds your CI budget; consider a nightly release workflow rather than per-PR.

This is out of scope for v0.1.0 — local `package.sh` is the path for now.

---

## Reference

- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)
- [Hardened Runtime entitlements](https://developer.apple.com/documentation/bundleresources/entitlements/hardened_runtime)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- `xcrun notarytool --help`
- `man codesign`
