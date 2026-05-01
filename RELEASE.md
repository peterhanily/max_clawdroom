# Release & distribution

This document covers everything from "clean working tree" to "user can `brew install` a notarized .app." For the nuts-and-bolts Apple notarization walk-through see [NOTARIZATION.md](./NOTARIZATION.md); that piece is already wired.

## Artefacts the release produces

`tools/package.sh` now produces three files in `dist/`:

- `max_clawdroom-<version>.app` — signed, notarized, stapled. Runs directly on any Mac.
- `max_clawdroom-<version>.zip` — identical `.app` in a zip, for arbitrary download hosts.
- `max_clawdroom-<version>.dmg` — drag-to-Applications image, signed + notarized + stapled. **Primary end-user artefact.**

For the prettiest DMG window: `brew install create-dmg`. Without it, `hdiutil` falls back to a plain-but-functional image.

## Where things live

- **maxclawdroom.app** — marketing site (separate repo: `~/Documents/claude_code/maxclawdroom-site/`). Links to download.
- **GitHub releases** — `github.com/peterhanily/max_clawdroom/releases`. Upload `.dmg` + `.zip` to each tagged release.
- **Homebrew tap** — `github.com/peterhanily/homebrew-max_clawdroom` (to be created). Users install with:
  ```bash
  brew install --cask peterhanily/max_clawdroom/max_clawdroom
  ```

## Versioning

Semver on `CFBundleShortVersionString` in `Packaging/Info.plist`. `CFBundleVersion` is the build number (monotonic). `tools/package.sh` reads `CFBundleShortVersionString` as `VERSION` for artefact naming.

## Sparkle integration

Sparkle is the auto-updater. Wiring:

1. **Add dependency** — SwiftPM-compatible fork: `github.com/sparkle-project/Sparkle`. Already a standard macOS choice.
2. **Generate an EdDSA keypair** once:
   ```bash
   ./Pods/Sparkle/bin/generate_keys   # or the Sparkle tools download
   ```
   Private key stays in your keychain. Public key goes into `Info.plist` as `SUPublicEDKey`.
3. **Info.plist additions** (already in `Packaging/Info.plist`? check):
   - `SUFeedURL` — URL to `appcast.xml` (e.g. `https://maxclawdroom.app/appcast.xml`)
   - `SUPublicEDKey` — base64 public key from step 2
   - `SUEnableAutomaticChecks` — `true` (user can override in Settings)
4. **App integration** — `SPUStandardUpdaterController` in `AppDelegate`:
   ```swift
   private lazy var updaterController = SPUStandardUpdaterController(
       startingUpdater: true,
       updaterDelegate: nil,
       userDriverDelegate: nil
   )
   ```
5. **Release flow** — after `tools/package.sh`, sign the DMG with the Sparkle EdDSA key:
   ```bash
   ./Pods/Sparkle/bin/sign_update dist/max_clawdroom-<version>.dmg
   ```
   Output is the `edSignature` that goes into `appcast.xml`.

Appcast XML template (`Packaging/appcast-template.xml`):

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>max_clawdroom</title>
    <link>https://maxclawdroom.app</link>
    <description>Your desktop companion.</description>
    <language>en</language>
    <item>
      <title>Version __VERSION__</title>
      <sparkle:releaseNotesLink>https://maxclawdroom.app/releases/__VERSION__</sparkle:releaseNotesLink>
      <pubDate>__PUBDATE__</pubDate>
      <enclosure url="https://github.com/peterhanily/max_clawdroom/releases/download/v__VERSION__/max_clawdroom-__VERSION__.dmg"
                 sparkle:version="__BUILD__"
                 sparkle:shortVersionString="__VERSION__"
                 sparkle:edSignature="__ED_SIGNATURE__"
                 length="__LENGTH__"
                 type="application/octet-stream"/>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
```

## Homebrew tap

The cask lives in THIS repo at [`Casks/max_clawdroom.rb`](./Casks/max_clawdroom.rb) — no separate `homebrew-max_clawdroom` tap repo needed. Homebrew taps any git repo that contains a `Casks/` directory.

After each release, bump `version` + `sha256` in that file. The hash:
```bash
shasum -a 256 dist/max_clawdroom-<version>.dmg
```

Users install with (one-time tap, then standard cask install):
```bash
brew tap peterhanily/max_clawdroom https://github.com/peterhanily/max_clawdroom.git
brew install --cask max_clawdroom
```

Or the one-liner after the tap is added:
```bash
brew install --cask peterhanily/max_clawdroom/max_clawdroom
```

The cask's `zap trash:` block mirrors PRIVACY.md's "Data deletion" section so `brew uninstall --zap max_clawdroom` leaves the user's machine clean.

## Release checklist

```text
[ ] Bump CFBundleShortVersionString in Packaging/Info.plist
[ ] Bump CFBundleVersion (build number) — must be monotonic
[ ] Update CHANGELOG.md with the new version's notes
[ ] git tag v<VERSION> && git push --tags
[ ] DEVELOPER_ID_APPLICATION="..." ./tools/package.sh
[ ]   ↪ Verify the run printed "==> smoke ok (process survived 3s)"
       (catches dyld / framework / executor-probe regressions that pass
       notary but break at runtime; runs post-staple, before DMG build)
[ ] Sparkle-sign the DMG:  sign_update dist/max_clawdroom-<version>.dmg
[ ] Update appcast.xml with the new <item> + EdDSA signature + file length
[ ]   ↪ Release-notes URL form is /releases/<VERSION> (no .html — Cloudflare
       Pages strips it, the trailing-slash form would 307)
[ ] Publish GitHub Release, attach .dmg and .zip
[ ] Deploy updated appcast.xml to maxclawdroom.app
[ ] Update the Homebrew tap's Casks/max_clawdroom.rb (version + sha256)
[ ] Test: install on a fresh VM via DMG and via brew install --cask
[ ] Announce
```
