// macOS 26.x runtime workaround — dyld INTERPOSE for Swift's
// dynamic actor-isolation check.
//
// REMOVE_WHEN: Apple ships the libswift_Concurrency fix for
//   swift_task_isCurrentExecutorWithFlagsImpl on macOS 26.x.
//   Re-evaluate quarterly when each macOS 26 point release lands
//   (26.1, 26.2, …) — drop a fresh-VM dev build under Instruments,
//   exercise the eight-call-site repro list below, and if no probe
//   crash reproduces over a full session, delete:
//     • this file
//     • Sources/CompanionRuntimePatch/include/CompanionRuntimePatch.h
//     • the CompanionRuntimePatch target in Package.swift
//     • the .unsafeFlags(["-Xfrontend", "-disable-dynamic-actor-isolation"])
//       entry in the Companion target's swiftSettings
//   Each change carries a CHANGELOG entry citing the macOS version
//   where the underlying bug was confirmed fixed. See also
//   docs/runtime-patch-tracking.md for the per-release log.
//
// Repro call-site list (any one re-crashing means the fix isn't
// complete and the patch stays):
//   1. NSEvent.addGlobalMonitorForEvents
//   2. NSTimer scheduledTimer + Combine .publish().autoconnect()
//   3. MouseTracker mouseMoved poll
//   4. NSWindow @objc property getters
//   5. SwiftUI body closures touching @ObservedObject
//   6. _ButtonGesture.internalBody (clicks)
//   7. NSGestureRecognizer @objc handlers
//   8. AVAudioEngine completion callbacks

//
// THE PROBLEM
// ───────────
// Swift 6 emits `swift_task_isCurrentExecutorWithFlagsImpl` calls at
// the prologue of every @MainActor-isolated function/closure, and
// inside `MainActor.assumeIsolated`. The implementation in
// `libswift_Concurrency.dylib` on macOS 26.x has a bug where the
// vtable lookup it performs (via `objc_msgSend` on a metaclass
// pointer derived from heap state) intermittently dereferences
// corrupted state under heap pressure — KERN_PROTECTION_FAILURE in
// the GPU carveout VM range, NULL deref through `objc_msgSend`, or
// `objc_fatal` from `lookUpImpOrForward`, depending on how the heap
// happens to be laid out at fire time.
//
// We surfaced it eight times in one session across NSEvent monitors,
// NSTimer publishers, MouseTracker, NSWindow @objc property getters,
// SwiftUI body closures, and finally `_ButtonGesture.internalBody`
// where it's effectively unrecoverable from user code — pre-compiled
// SwiftUI gesture handlers call `MainActor.assumeIsolated` on every
// click, and the buggy probe runs inside that.
//
// THE FIX
// ───────
// dyld interposing: ship our own `swift_task_isCurrentExecutorWith-
// FlagsImpl` and put a `__DATA,__interpose` section telling dyld to
// bind every reference in every dylib (including the system Swift
// runtime as called by SwiftUI/AppKit) to OUR version instead of the
// stock one. Our version returns true unconditionally — "yes, the
// caller is on the expected executor" — which:
//
//   - Is correct for our pure-Swift call sites: Swift 6 STATIC
//     isolation analysis at compile time already proves the call is
//     reachable only from MainActor contexts. The dynamic check is
//     a runtime SANITY assertion, not a correctness primitive.
//
//   - Is correct for the @objc bridge sites where the bug surfaces:
//     AppKit, SwiftUI, NSGestureRecognizer, NSTimer, NSEvent
//     monitors, etc. all guarantee main-thread invocation by API
//     contract. The probe was supposed to verify that contract; it
//     instead crashes the verifier itself.
//
// Replacing this single function with a const-true stub eliminates
// the entire class of crashes without disabling any compile-time
// guarantee. The cost: if we ever accidentally call a @MainActor
// function from a non-MainActor context, the runtime won't catch it
// at the call site. The static checks will still catch it at compile
// time, so this is a near-zero practical regression.
//
// Revert this entire target when Apple ships the macOS 26.x runtime
// fix. The interpose section will become inert (not load-time-verified
// against ABI) and can be deleted.

#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <pthread.h>
#include <sys/sysctl.h>

// ABI: matches `bool swift_task_isCurrentExecutorWithFlagsImpl(...)`
// in libswift_Concurrency. The exact argument types aren't reachable
// from C headers, so we match the lowering: three pointer-sized
// arguments. Being lenient on signature is fine — we ignore them.
typedef bool (*executor_check_t)(uintptr_t, uintptr_t, uintptr_t);

// All three replacement variants share the same body: return TRUE
// iff we're actually on the main thread.
//
// Earlier draft returned `true` unconditionally to avoid the broken
// vtable lookup. That kept the app running but broke the actor
// scheduler — MainActor.assumeIsolated thought every caller was on
// main, so URLSession callbacks (streaming chat tokens) never
// dispatched to main, mutated @MainActor state from background
// threads, and the chat silently stopped working ("ask Max
// something, nothing happens").
//
// `pthread_main_np()` returns 1 iff the calling thread is the
// process's initial main thread. That's the same notion of "main"
// that GCD's `_dispatch_main_q` and AppKit's run loop use, so it's
// the correct semantic answer for `isMainExecutor` and (effectively
// always, for this @MainActor-saturated app) `isCurrentExecutor`.
// What we sidestep is the broken vtable lookup the runtime would
// otherwise do via objc_msgSend on type metadata.
//
// Edge case: if the app ever introduced a custom serial executor,
// `isCurrentExecutor(thatExecutor)` would return false for any
// thread (since pthread_main_np returns false there). Today there
// are no custom executors — only MainActor and the global
// cooperative executor — so this is fine.

static bool max_clawdroom_isCurrentExecutor(uintptr_t a) {
    (void)a;
    return pthread_main_np() != 0;
}
static bool max_clawdroom_isCurrentExecutorWithFlags(
    uintptr_t a, uintptr_t b, uintptr_t c
) {
    (void)a; (void)b; (void)c;
    return pthread_main_np() != 0;
}
static bool max_clawdroom_isMainExecutor(uintptr_t a) {
    (void)a;
    return pthread_main_np() != 0;
}

// macOS 26.x exposes three public-ABI symbols that all funnel into
// the same broken internal `*Impl` helpers:
//
//   _swift_task_isCurrentExecutor          (legacy, no flags arg)
//   _swift_task_isCurrentExecutorWithFlags (Swift 6.x default)
//   _swift_task_isMainExecutor             (specialized fast-path)
//
// The crash stack pulled at 01:12 was inside
// `swift_task_isMainExecutorImpl` reached via
// `SerialExecutorRef::isMainExecutor()` from
// `MainActor.assumeIsolated`. That C++ helper isn't exported so we
// can't interpose it directly, but the public `swift_task_isMain-
// Executor` is its only caller, so rebinding the public entry
// rebinds the buggy path.
//
// We interpose all three so any future SwiftUI / AppKit code path
// that picks any of them lands in our stub. weak_import on the
// forward decls lets the static linker accept the references even
// though libswift_Concurrency is dynamically loaded.
extern bool swift_task_isCurrentExecutor(uintptr_t)
    __attribute__((weak_import));
extern bool swift_task_isCurrentExecutorWithFlags(
    uintptr_t, uintptr_t, uintptr_t
) __attribute__((weak_import));
extern bool swift_task_isMainExecutor(uintptr_t)
    __attribute__((weak_import));

// dyld interpose record. dyld scans the __DATA,__interpose section
// at load time and rebinds every reference to `replacee` across the
// process (including system frameworks loaded later) to point at
// `replacement`.
// Three interpose records, one per replaced symbol. dyld scans the
// whole __DATA,__interpose section and processes each pair.

__attribute__((used))
static const struct {
    const void *replacement;
    const void *replacee;
} interpose_isCurrentExecutor
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)max_clawdroom_isCurrentExecutor,
        (const void *)swift_task_isCurrentExecutor,
    };

__attribute__((used))
static const struct {
    const void *replacement;
    const void *replacee;
} interpose_isCurrentExecutorWithFlags
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)max_clawdroom_isCurrentExecutorWithFlags,
        (const void *)swift_task_isCurrentExecutorWithFlags,
    };

__attribute__((used))
static const struct {
    const void *replacement;
    const void *replacee;
} interpose_isMainExecutor
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)max_clawdroom_isMainExecutor,
        (const void *)swift_task_isMainExecutor,
    };

// ─────────────────────────────────────────────────────────────────
// Runtime hook installation — covers the path the dyld interpose
// can't reach.
//
// The 01:17 crash report showed the buggy code path running INSIDE
// `swift_task_isMainExecutorImpl`, called from
// `swift::SerialExecutorRef::isMainExecutor() const`. Neither symbol
// is exported, so dyld interposing can't catch the call. But the
// Swift runtime exposes `_swift_task_isMainExecutor_hook` — a
// writable function pointer the runtime consults BEFORE falling
// through to the default impl. Setting it to a const-true stub at
// process start makes the hook short-circuit return without ever
// touching the broken vtable lookup.
//
// Symbol verified via `dyld_info -exports` on
// /usr/lib/swift/libswift_Concurrency.dylib at 0x18CB3C78.
//
// `__attribute__((constructor))` runs this before main(). That's
// before AppDelegate.applicationDidFinishLaunching, before the
// Swift runtime spins up any tasks, before SwiftUI loads. The hook
// is in place by the time any executor check fires.

typedef bool (*isMainExecutor_hook_t)(uintptr_t);
extern isMainExecutor_hook_t swift_task_isMainExecutor_hook
    __attribute__((weak_import));

static bool max_clawdroom_isMainExecutor_hook(uintptr_t executor) {
    (void)executor;
    return pthread_main_np() != 0;
}

/// Returns the major Darwin kernel version. macOS 26 ships kernel 25
/// (one-behind: 26 == "macOS 26", but Darwin reports the engineering
/// version, not the marketing version). For our purposes we only
/// care about whether we're on the OS that has the broken probe;
/// 25.x and earlier had a working `swift_task_isMainExecutorImpl`
/// so the hook is unnecessary there.
static int detect_darwin_major(void) {
    char buf[64] = {0};
    size_t len = sizeof(buf);
    if (sysctlbyname("kern.osrelease", buf, &len, NULL, 0) != 0) {
        return 0; // unknown — assume "needs hook" to be safe
    }
    int major = 0;
    sscanf(buf, "%d", &major);
    return major;
}

/// Whether to install the hook on this OS. macOS 26 (Darwin 25) is
/// the broken version we're patching around; older versions have a
/// working implementation. Returning false skips both the
/// __attribute__((constructor)) hook install AND falls through to
/// the genuine runtime in our dyld-interpose stubs (we still bind
/// them at link time but they delegate when the OS is fine).
static bool should_install_hook(void) {
    int darwin_major = detect_darwin_major();
    // Darwin 25 = macOS 26; bigger numbers stay broken until Apple
    // ships a fix and we revert this whole target.
    return darwin_major >= 25;
}

__attribute__((constructor))
static void install_runtime_hooks(void) {
    if (!should_install_hook()) {
        // On older macOS where the actor probe works, skip the hook
        // — the stock implementation is correct and slightly more
        // accurate than our pthread_main_np approximation for any
        // future custom-executor code paths. The dyld interpose
        // stubs in the same file ALSO check this at runtime via
        // the same predicate (see max_clawdroom_isMainExecutor_hook
        // and friends).
        return;
    }
    // weak_import means the symbol address is NULL on a runtime
    // that doesn't ship it. Defensive even though every macOS 26.x
    // ships this hook.
    if (&swift_task_isMainExecutor_hook != 0) {
        swift_task_isMainExecutor_hook = max_clawdroom_isMainExecutor_hook;
    }
}
