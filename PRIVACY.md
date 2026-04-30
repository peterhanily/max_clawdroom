# Privacy Policy

**max_clawdroom** is a desktop companion app. This document describes what data it handles, where that data lives, and what (if anything) leaves your machine. Written in plain language; technical details below each section.

Last updated: 2026-04-24

---

## Principle

**Your data stays on your Mac.** max_clawdroom has no backend server, no telemetry endpoint, and no analytics pipeline. The only time data leaves your machine is when *you* configure a remote LLM backend and *you* send a message.

---

## What's stored locally

All persistent state lives under:

```
~/Library/Application Support/Companion/
```

- **Chat sessions** (`sessions/*.json`) — your conversations, per project (cwd). Grow with use; delete the directory to wipe.
- **Memory** (`memory/<hash>/entries.jsonl`) — one per project, append-only. Contains observations the agent recorded about your preferences, projects, and recent topics. The directory hash obscures the project name on disk.
- **User model** (`memory/<hash>/user_model.json`) — a distilled, structured summary of the above. **Encrypted at rest** using AES-GCM with a key held in your macOS Keychain; the file on disk is ciphertext.
- **Time capsules** (`memory/<hash>/time_capsules.json`) — periodic (~90-day) snapshots of the user model + companion personality. Encrypted the same way.
- **Soul history** (`soul_history.json`) — a log of personality patches the companion has applied to itself, with timestamps and rationales. Plain JSON.
- **Preferences** (`UserDefaults` at `com.peterhanily.max_clawdroom`) — app settings (backend choice, voice on/off, mode, etc.).

Secrets (API keys) **never** land in UserDefaults or on disk in plaintext. They live in the macOS Keychain, service name `com.peterhanily.max_clawdroom`.

---

## What leaves your machine

Only when you deliberately configure it:

### Claude Code CLI backend (default)
Your messages are sent to Anthropic's API **via the `claude` CLI running locally as a subprocess**. max_clawdroom itself opens no network sockets for LLM calls; it pipes data to the CLI over stdin and reads its stdout. Anthropic's own privacy policy applies to whatever the CLI uploads: <https://www.anthropic.com/legal/privacy>

### OpenAI-compatible HTTP backend
When you switch to the OpenAI HTTP backend, your messages + optional system context are sent directly to whichever URL you've configured — that could be OpenAI, a self-hosted Ollama/LM Studio endpoint, or any service that speaks the OpenAI Chat Completions protocol. Only you know what's on the other end of that URL; the privacy policy of that service applies.

### Voice transcription
Dictated voice input uses Apple's **on-device** `SFSpeechRecognizer` (`requiresOnDeviceRecognition = true` where the OS supports it). Audio **never** leaves your machine for transcription. The resulting text *is* then sent to whichever backend you've configured, same as typed input.

### Speech output (TTS)
Text-to-speech is Apple's `AVSpeechSynthesizer`. Entirely local.

---

## What *doesn't* leave

- **Screen contents** — max_clawdroom does not capture your screen.
- **Keystrokes** — no keylogging. The Fn voice hotkey works via macOS's global event tap but only activates mic streaming while held, and only if you've granted Accessibility permission.
- **File contents** — the `claude` CLI can *read* files you grant it access to (its `Allowed Tools` list is visible and editable in Settings → Tools & Permissions), and those files may be included in prompts sent to Anthropic. The app itself does not read your filesystem otherwise, except for its own state directory above.
- **Other apps' data** — the Accessibility integration reads the *focused editor's* current line and filename (for the "Max walks to your cursor" feature) but does not read other apps or other windows. Secrets detected in scraped editor text (API keys, tokens) are redacted client-side before any prompt is built.

---

## Permissions the app asks for

| Permission | Why | When asked |
|---|---|---|
| **Microphone** | Voice input (Fn hotkey) | First time you press Fn |
| **Speech Recognition** | Transcribe voice input on-device | Alongside microphone |
| **Accessibility** | Read focused editor line for `walk_to_editor` | First time the feature is used |
| **Notifications** | Companion's ambient nudges (soul patches, memory milestones) | First launch |

All are optional. Denying any one disables only the feature it powers.

---

## Crash reports & telemetry

**None.** No Sentry, no Crashlytics, no analytics. If the app crashes, the standard macOS crash report is produced locally under `~/Library/Logs/DiagnosticReports/`. It is not uploaded anywhere by this app.

---

## Auto-updates

max_clawdroom uses [Sparkle](https://sparkle-project.org) to check for updates. When enabled, the app periodically fetches a signed XML feed (`appcast.xml`) from the project's distribution host. The only data transmitted is your current app version and your macOS version (standard `User-Agent` header). No user-identifying information is sent. You can disable update checks in Settings.

---

## Third-party components

- **[Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)** — Anthropic subprocess. See Anthropic's privacy policy.
- **[GLTFSceneKit](https://github.com/magicien/GLTFSceneKit)** — 3D model loading. Runs entirely locally, no network.
- **[Sparkle](https://sparkle-project.org)** — auto-update framework. See the update-check note above.

---

## Data deletion

To wipe everything:

```bash
rm -rf ~/Library/Application\ Support/Companion/
security delete-generic-password -s com.peterhanily.max_clawdroom
defaults delete com.peterhanily.max_clawdroom
```

This removes all chat history, memory, user-model, capsules, soul history, the at-rest encryption key, and all app preferences. The companion starts fresh on next launch.

---

## Contact

Issues and questions: <https://github.com/peterhanily/max_clawdroom/issues>
