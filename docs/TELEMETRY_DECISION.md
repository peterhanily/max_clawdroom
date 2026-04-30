# Telemetry — design decision pending

Status: **not implemented**. v0.2 ships without telemetry. This doc
captures the comparison so the choice can land in v0.3 without
re-doing the analysis.

## What v1.0 needs from telemetry

1. **Crash reports** — when the app dies on a user's machine, we want
   the stack + OS version + relevant state. Today the only signal is
   "user stopped using it" or "user filed a GitHub issue."
2. **In-app feedback** — a "report a problem" button that pre-fills
   a bug template with version / OS / recent log tail and either
   opens email or POSTs to a server.
3. **Feature-use counters (opt-in)** — anonymous numbers like "how
   many users add a LAN channel," "how many flip on autonomy."
   Without this we can't prioritise — every product decision is a
   guess.

All three are **opt-in**. Privacy is part of Max's brand and
adding telemetry that isn't would undermine it. Default OFF; first-
launch onboarding has a single toggle ("Help improve Max — send
opt-in crash reports and anonymous usage counters") with a
one-paragraph plain-language explainer.

## Three viable approaches

### A. Sentry (managed SaaS)

Drop in `sentry-cocoa` SwiftPM dependency. ~3 lines of init code.
Free tier covers 5,000 events/month — plenty for an alpha.
Crash symbolication, breadcrumbs, source maps, web dashboard.

**Pros:**
- 1 hour to working crash reporting.
- Real symbolicated stacks with deobfuscation.
- Dashboards tell us "20% of crashes are in `swift_task_isMainExecutorImpl`" automatically.
- Add-on API for custom events covers feature-use counters too.

**Cons:**
- Third-party SaaS — even with PII stripping enabled, every crashing
  user's machine talks to `sentry.io`. Brand-incompatible if we
  position Max as fully local.
- Vendor lock-in. Swapping later means re-instrumenting.
- Cost grows with usage. Free tier is generous but not infinite.

### B. PLCrashReporter + self-hosted intake

`plcrashreporter` SwiftPM dep + a tiny POST endpoint we run.
Crash logs land in Application Support, get uploaded on next launch
to `https://crash.maxclawdroom.app/v1/report`. Symbolication runs
server-side via a stored dSYM bundle.

**Pros:**
- No third party. We own the data + the privacy story.
- We can write the wire format — strip PII at source.
- Same tech the open-source community uses for similar concerns.

**Cons:**
- 1-2 days of work, not 1 hour. Endpoint, dSYM symbolication
  pipeline, dashboard, alerting.
- Ongoing ops burden — keep the endpoint up, retain the dSYMs,
  rotate logs.
- Custom-event API doesn't come for free; would need a separate
  counter-aggregation endpoint.

### C. Apple's `MetricKit` (built-in)

`MXMetricManager.shared.add(self)` — no third-party dependency,
Apple delivers crash + hang + battery + signpost data daily.

**Pros:**
- Zero PII risk — Apple curates the payload, no user identifiers.
- No external dependency.
- Crash symbolication done by Apple.

**Cons:**
- 24-hour latency on the daily payload. Useless for "user just
  hit a bug, they're filing an issue now."
- No custom events / counters. Crashes only.
- Aggregated across the user base from Apple's side; we only
  get our own app's data via the on-device delegate, NOT a
  server-side rollup. Means we'd need to set up the same
  upload + dashboard as PLCrashReporter on top.

## Recommendation

**Phase 1 (alpha → 1.0): Sentry, default OFF, opt-in toggle in
onboarding + Settings.** Optimise for "we know when our users hit
real bugs in real time." Privacy concern is mitigated by the opt-in
default and the up-front Settings toggle.

**Phase 2 (post-1.0, when we have 100+ users): re-evaluate.**
If the privacy concern bites, swap to PLCrashReporter + self-host.
The code surface is small enough to make this a 1-day refactor.

**Don't ship MetricKit** — the latency makes it useless for the
debugging loop we actually need it for.

## Wire shape (whichever backend)

When implementing, every payload is:

```
{
  "schema": 1,
  "timestamp": <ISO8601>,
  "app_version": "0.2.0",
  "os_version": "14.5.0",
  "arch": "arm64",
  "crash_signature": "<hash of top 5 frames, no symbols>",
  "stack": [<symbolicated frames, max 50>],
  "log_tail": [<last 20 OSLogStore entries, our subsystem only>],
  "channel_kind": "local|lan|remote|claudeCodeCLI",
  "feature_flags": {
    "voiceEnabled": false,
    "autonomyEnabled": true,
    ...
  }
}
```

Explicitly NOT included: cwd path, machine name, user name,
chat content, memory content, channel endpoint, channel bearer
token (the keychain account name leaks nothing — but we redact even
that), file paths from the editor block, frontmost app name.

## Open questions for whoever picks this up

- Where does the Settings toggle live? Suggest **Settings → General
  → Privacy** — same place as the existing privacy panel. New row:
  "Send anonymous crash reports + usage counters."
- Where does the report-a-problem button live? Suggest **menu bar
  → Help → Report a Problem…** — opens a small SwiftUI sheet with
  the pre-filled payload + a free-form text box.
- Does the user see the payload before it's sent? Yes — the report-
  a-problem flow shows the JSON in a scroll view with a "Send" /
  "Copy and email instead" choice. The crash flow on next launch
  shows a one-line "Max crashed last time. Send report? [Send] [Not
  this time] [Never ask]."

When we pick up this work, this doc is the spec.
