# Contributing to max_clawdroom

Thanks for your interest. This is a small project run by one person and a 3D character; PRs and bug reports are very welcome, but please read this first so we don't waste each other's time.

## Quick links

- **Bug?** [Open an issue](https://github.com/peterhanily/max_clawdroom/issues/new) with steps + macOS version + the version string from `🌝 → About`.
- **Security issue?** Don't open a public issue — see [SECURITY.md](SECURITY.md).
- **Feature idea?** Open an issue first. Please don't open a PR for a new feature without prior discussion.
- **PR ready?** Read "Before opening a PR" below.

## Ground rules

1. **Be kind.** Disagree with ideas, never with people.
2. **Small PRs win.** One concern per PR. A 50-line PR gets reviewed; a 2,000-line PR sits for a month.
3. **No drive-by refactors.** If your bug fix touches `Pet.swift`, don't also "tidy up" `ChatView.swift`.
4. **No new dependencies without discussion.** Every SwiftPM dependency is a notarization headache. We have a high bar.

## Development setup

Requirements:

- macOS 14 (Sonoma) or later, Apple Silicon
- Xcode 15+ / Swift 6.2+
- A working `claude` CLI for the CLI channel (most channels work without it)

Clone + run:

```bash
git clone https://github.com/peterhanily/max_clawdroom.git
cd max_clawdroom
swift build
.build/arm64-apple-macosx/debug/max_clawdroom
```

If Max launches into a black overlay, check that you've granted Accessibility permission (he asks on first need).

## Running the test suite

```bash
swift test
```

The test target is `CompanionTests` under [`Tests/`](Tests/). It covers:

- `StripSystemBlocksTests` — the `[action]` parser invariants. **Critical** — bugs here let raw JSON leak into Max's spoken voice.
- `ChannelStoreTests` — channel persistence, persona round-tripping.
- `MaxClawdroomBaselineTests` — revert-to-baseline single-source-of-truth invariants.
- `TourScriptTests` — every action op / expression / prop / mode the tour references must exist in the dispatcher.

CI runs `swift build` + `swift test` on `macos-latest` for every push and PR; see [`.github/workflows/test.yml`](.github/workflows/test.yml).

## Project layout

See the **Architecture** section in [README.md](README.md#architecture) for a tour of the directory tree. The short version:

- `Sources/Companion/` — the app proper.
- `Sources/CompanionRuntimePatch/` — a small C target that ships a `__DATA,__interpose` Mach-O record to work around the macOS 26.x `swift_task_isMainExecutorImpl` crash. **Don't touch this without reading the file's top comment.**
- `Tests/CompanionTests/` — XCTest target.
- `Packaging/` — Info.plist, entitlements, app icon assets.
- `Casks/max_clawdroom.rb` — the Homebrew Cask. Bumped automatically by `tools/release.sh`.
- `tools/` — build, package, release scripts.
- `docs/` — design notes and decisions (notably [`TELEMETRY_DECISION.md`](docs/TELEMETRY_DECISION.md) and [`APPLE_FEEDBACK_RUNTIME_BUG.md`](docs/APPLE_FEEDBACK_RUNTIME_BUG.md)).

## Code style

- **Swift 6 default-MainActor isolation** — the package uses `swiftLanguageModes: [.v6]`. Most code is MainActor by default. If you're touching async code, understand why we use `assumeIsolated` in some places and not others (hint: it's the runtime patch).
- **No comments unless they explain *why*.** Self-explanatory names beat comments. Code that needs a comment to explain *what* it does should be rewritten. A comment is justified when it explains a hidden constraint, a workaround, or behavior that would surprise a reader.
- **Match existing patterns.** If you'd format a new file differently from the rest of the codebase, format it like the rest of the codebase.
- **`MaxClawdroomBaseline` is canonical.** Anything that defines "Max's normal appearance" goes through that struct. Don't add a parallel source of truth.

## The action-op contract

Max's appearance/voice/sound/chat are controlled exclusively by `[action]` blocks he emits inline in his chat responses. Adding a new op is a contract change and needs care:

1. Add the op to `Sources/Companion/Actions/CompanionActions.swift` — both the `Op` enum case and the dispatcher.
2. Add a corresponding test in `TourScriptTests.swift` if the tour exercises the op, **and** a parser-level test in `StripSystemBlocksTests.swift` to verify the strip pass doesn't leak the JSON into spoken text.
3. Document the op in `README.md` under **Agent ops**.
4. Update the system prompt advertised to Max so he knows the op exists. (Search for the prompt assembly site to find where new ops are listed.)
5. If the op mutates state, make it `⌘Z`-undoable via `Sources/Companion/Actions/UndoStack.swift`.

## Before opening a PR

- [ ] `swift build` is clean.
- [ ] `swift test` passes.
- [ ] You ran the app and exercised the change interactively. Type-check passes ≠ feature works.
- [ ] No personal paths (`/Users/<your-name>/...`) leak into committed files. Test fixtures should use `/Users/USER`.
- [ ] No secrets or tokens. Run `git diff` against your branch and look at every line.
- [ ] Commit messages explain *why*, not just *what*. The diff already shows the *what*.
- [ ] If you added a new dependency, it's defended in the PR description.
- [ ] If you touched the Mach-O interpose in `CompanionRuntimePatch`, you tested on both macOS 14 (no-op path) and macOS 26 (active path). If you only have one of those, say so.

## PR review

PRs go through a single human reviewer. Expect:

- A pass for code style + correctness.
- Questions about *why*, not just *how*.
- Sometimes "this is a great idea but the wrong shape" — don't take it personally; it usually means we'll iterate together on the design.

Turnaround is typically a few days. If a week passes with no response, ping the PR.

## Distribution & licensing

This project is licensed under [Apache License 2.0](LICENSE). By submitting a contribution you agree your work is licensed under the same terms.

We don't require a CLA. Don't paste in code you don't have the right to distribute.

## Code of conduct

Be respectful. Assume good faith. If someone's behavior is making the project worse to work on, email **conduct@peterhanily.com** and it will be addressed privately.

## Inspiration & credits

This project owes its existence to **[Matias Brutti](https://github.com/mrbrutti)** — the original spark that put a Max-Headroom-shaped idea in the maintainer's head. Thank you, Matias.

A running list of contributors is maintained in the GitHub commit history and the contributors graph. If your contribution belongs there and isn't, open a PR adjusting this file or ping the maintainer.

## Thanks

Max will be subtly nicer to your branch in the next dev build. Probably.
