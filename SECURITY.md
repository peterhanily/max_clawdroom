# Security policy

## Reporting a vulnerability

**Do not file a public GitHub issue for security vulnerabilities.**

Instead, email **security@peterhanily.com** with:

- A description of the issue and its impact.
- Steps to reproduce, ideally with a minimal proof-of-concept.
- The version of `max_clawdroom` affected (visible in `🌝 → About` or in the `Info.plist`'s `CFBundleShortVersionString`).
- Your macOS version and architecture.
- Whether you'd like to be credited in the fix announcement.

You should expect:

- An acknowledgement within **3 business days**.
- A first assessment (severity, planned fix window) within **7 business days**.
- A coordinated disclosure window of **up to 90 days** for high-severity issues, less for lower-severity ones. We're a small project — we'll work with you on a realistic timeline.

We do not currently run a paid bounty programme. We will credit reporters publicly (with consent) in the release notes for the fix.

## Supported versions

| Version | Supported          |
|---------|--------------------|
| 0.3.x   | ✅ current         |
| 0.2.x   | ❌ end-of-life     |
| 0.1.x   | ❌ end-of-life     |

Only the current minor version receives security updates. Users are auto-updated through Sparkle when an appcast entry is published.

## Scope

In scope:

- The `max_clawdroom` macOS app and any code shipped inside the `.app` bundle.
- The Homebrew cask in [`Casks/max_clawdroom.rb`](Casks/max_clawdroom.rb).
- The release scripts in [`tools/`](tools/) — particularly anything affecting the integrity of the shipping `.app`, DMG, or Sparkle update.
- The Sparkle update channel served from `https://maxclawdroom.app/appcast.xml`.

Out of scope:

- Bugs in third-party dependencies (Sparkle, GLTFSceneKit, Apple frameworks). Please report those upstream. We'll bump our pin once a fix is available.
- Issues that require an attacker to already have local code execution on the user's Mac.
- Social engineering of the maintainer.
- The marketing site at `maxclawdroom.app` is in a separate repo and out of scope here.

## What we consider a security issue

In approximate order of severity:

- **Code execution** — anything that lets an attacker run arbitrary code via `max_clawdroom`. Including but not limited to: chat-input parsing, `[action]` block parsing, channel message handling, MyInstants URL fetching, Sparkle update verification.
- **Sandbox / TCC bypass** — bypasses of macOS Accessibility, microphone, or other TCC permissions; tricks that cause Max to act with privileges he shouldn't have.
- **Authentication bypass** — defeating the per-pair shared key on LAN channels, or making a remote channel's bearer token leak.
- **Update tampering** — anything that lets a non-Apple-trusted binary be installed via Sparkle, or that bypasses Sparkle's EdDSA signature verification.
- **Data exfiltration** — chat content, memory store, or keychain credentials leaking off-device by any path other than a user-configured remote channel.
- **Privacy leaks in shipped binaries** — embedded paths revealing the developer's local environment, hardcoded credentials, or similar.

If you're not sure whether something counts, email anyway. We'd rather hear about a non-issue than miss a real one.

## Defense-in-depth assumptions

Before reporting, please note our threat model:

- **Local-first by design.** The default channel is `127.0.0.1`. We do not assume the user's other local processes are trustworthy, but we also do not aggressively defend against them — an attacker who can already run code as the user has many easier targets.
- **The Claude Code backend is trusted.** Max is driven by `claude`. We trust the model output enough to act on its `[action]` blocks. We do parse defensively (every op validates input shape), but a model that intentionally tries to harm the user via op input is out of our threat model.
- **Notarization is required.** Any path that lets an unsigned or non-notarized payload run as part of the app is a security issue.
- **The user grants permissions explicitly.** Microphone, accessibility, automation — each has its own consent prompt and Settings toggle. Anything that bypasses these is a security issue.

## Response process

When you report:

1. We confirm receipt within 3 business days.
2. We reproduce + assess severity. If we can't reproduce, we'll ask for help.
3. We develop a fix on a private branch.
4. We cut a release with the fix, give you a chance to verify, and credit you in the release notes (with consent).
5. We publish the fix via Sparkle and update the GitHub Release.
6. After 30 days from release we may publish a more detailed advisory.

Thanks for helping keep Max safe.
