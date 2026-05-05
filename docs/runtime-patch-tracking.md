# Runtime patch tracking

Per-release log for the macOS 26.x `swift_task_isCurrentExecutorWithFlagsImpl` runtime workaround. Tracked here so a future maintainer (or a future me) can answer "is this still load-bearing?" without re-deriving the analysis from scratch every quarter.

The patch lives at:
- `Sources/CompanionRuntimePatch/Interpose.c` (the dyld interposer)
- `Sources/CompanionRuntimePatch/include/CompanionRuntimePatch.h`
- `Package.swift` `CompanionRuntimePatch` target + `-Xfrontend -disable-dynamic-actor-isolation` flag on the Companion target
- All four sites carry `REMOVE_WHEN:` markers pointing at this file.

## Re-evaluation procedure

Run this on each macOS 26 point release (26.1, 26.2, 26.x) until the underlying bug is confirmed fixed.

1. **Fresh-VM dev build.** Don't use the dogfood machine — heap layout there has been pre-conditioned by hours of session state. Spin up a clean macOS 26.x VM, install Xcode, clone the repo, `swift build` from cold.
2. **Gate the patch off.** Comment out (or otherwise disable) the interposer registration in `CompanionRuntimePatch.h`. Re-build.
3. **Exercise the eight repro sites in one session:**
   - NSEvent.addGlobalMonitorForEvents (open the chat panel, type, observe)
   - NSTimer + Combine `.publish().autoconnect()` (let the chat-bubble cursor blink for 30 s)
   - MouseTracker mouseMoved poll (move the mouse over Max for 30 s)
   - NSWindow @objc property getter (resize the chat panel)
   - SwiftUI body closure (open Settings, switch tabs)
   - `_ButtonGesture.internalBody` — clicks (press every button in Settings)
   - NSGestureRecognizer @objc handlers (right-click Max for the context menu)
   - AVAudioEngine completion callback (play 5 sounds via `play_sound`)
4. **Run for ≥ 30 minutes** under Instruments' Time Profiler + Allocations. The bug has been heap-layout-sensitive; short runs are unreliable.
5. **If no probe crash reproduces** AND the system Swift runtime has shipped a fix in `libswift_Concurrency.dylib`'s release notes, the patch is removable. Restore the gate, then drop:
   - `Sources/CompanionRuntimePatch/` (whole directory)
   - The target + dependency in `Package.swift`
   - The `-Xfrontend -disable-dynamic-actor-isolation` flag in the Companion target's `swiftSettings`
   - All `REMOVE_WHEN` comment blocks
   - This file
6. **CHANGELOG entry** under the next version bump citing the macOS version where the fix was confirmed (e.g. *"Removed CompanionRuntimePatch — macOS 26.4 ships the fixed `swift_task_isCurrentExecutorWithFlagsImpl`."*).

## Per-release log

Append a row each time the procedure runs. Quarterly cadence is fine; more often if a 26.x point release is announced as a Swift-runtime release.

| Date | macOS version | Result | Action |
|---|---|---|---|
| 2026-04-22 | 26.0 (initial issue) | All 8 sites crashed within 5 minutes | Patch landed |
| _add the next entry the day you re-test_ | | | |

## If you're considering removing this without doing the procedure

Don't. The bug surfaced **eight times in one session** across distinct call sites; we burned a full afternoon characterising it before settling on the interpose. The reason the patch can be a single const-true stub is that Swift 6 STATIC isolation analysis at compile time already proves the call is reachable only from MainActor contexts — the dynamic check is a runtime sanity assertion, not a correctness primitive. Removing the patch without the procedure means the next user-visible crash is a `_ButtonGesture.internalBody` blow-up that's effectively impossible to recover from in user code.

Trust the procedure.
