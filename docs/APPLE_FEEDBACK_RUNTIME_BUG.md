# Apple Feedback — `swift_task_isMainExecutorImpl` crash on macOS 26

This is a self-contained bug report ready to paste into Apple Feedback
Assistant or radar (`bugreport.apple.com`).

## Summary

`swift_task_isCurrentExecutorWithFlagsImpl` and
`swift_task_isMainExecutorImpl` (the implementation helpers Swift 6
emits at the prologue of every `@MainActor`-isolated function and
inside `MainActor.assumeIsolated`) intermittently crash with
`EXC_BAD_ACCESS` (KERN_PROTECTION_FAILURE in the GPU carveout VM
range) or `EXC_BAD_ACCESS / SIGSEGV` (NULL deref through
`objc_msgSend`) or `EXC_BAD_INSTRUCTION` (`objc_fatal` from
`lookUpImpOrForward`) on macOS 26 (build 25D125).

The crash address pattern (consistently inside `objc_msgSend` invoked
from `swift_getObjectType`, with the receiver pointer landing in the
GPU-carveout reserved address range `0x1000000000…0x7000000000`)
suggests the runtime is dereferencing corrupted state — most likely
the current executor TLS pointer or a metaclass pointer on the
executor reference — under heap pressure.

## Reproducer (high-level)

A SwiftPM macOS executable target with `defaultIsolation(MainActor.self)`
+ `swiftLanguageModes: [.v6]`, running a SwiftUI overlay app that:

- Registers `NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved])`
- Has a `Combine Timer.publish(every: 0.5).autoconnect()` driving a
  cursor-blink @State

After several seconds of normal cursor motion (which fires the
NSEvent monitor at hundreds of Hz, each fire entering a
`@MainActor`-annotated closure prologue), the crash fires reliably.

Observed across multiple sites in our app: NSEvent global+local
monitors, NSTimer block callbacks, NSWindow `@objc` property
getters, SwiftUI body closures (specifically
`closure #5 in ChatBubbleView.body.getter` and
`closure #1 in _ButtonGesture.internalBody.getter`), and
`MainActor.assumeIsolated` calls in pre-compiled SwiftUI
gesture-recognizer code paths invoked via
`AppKitEventBindingBridge.flushActions`.

## Crash stacks (typical)

```
0  libobjc.A.dylib                 objc_msgSend + 56
1  libswiftCore.dylib              swift_getObjectType + 88
2  libswift_Concurrency.dylib      swift_task_isMainExecutorImpl + 36
3  libswift_Concurrency.dylib      swift::SerialExecutorRef::isMainExecutor() + 24
4  libswift_Concurrency.dylib      swift_task_isCurrentExecutorWithFlagsImpl + 72
5  <our binary>                    closure #3 in VoiceHotkey.register()  ← anywhere
```

`Exception Codes: 0x0000000000000002, 0x0000001800001120` —
KERN_PROTECTION_FAILURE at `0x1800001120`, which is inside the
`GPU Carveout (reserved)` VM region per the report's `vmregioninfo`.

## Workaround we shipped

We ship a C-only library target that:

1. Installs a `__DATA,__interpose` record for each of
   `swift_task_isCurrentExecutor`, `…WithFlags`, and
   `swift_task_isMainExecutor`, replacing each with a stub that
   returns `pthread_main_np() != 0` instead of doing the buggy
   vtable lookup.
2. From a `__attribute__((constructor))`, sets the
   `swift_task_isMainExecutor_hook` writable function pointer to a
   stub of the same shape, covering the C++-internal path
   `SerialExecutorRef::isMainExecutor() → swift_task_isMainExecutorImpl`
   that the dyld interposes can't reach.

This is correct for our app because all our actor-isolated state is
on `@MainActor` and there are no custom serial executors — so
`pthread_main_np()` is a correct answer to "is the calling task on
the expected executor." It is NOT a safe general workaround for
apps that use custom serial executors.

## Reproducer project

The full source is at <private repo URL — share on request via
Feedback Assistant private response>. Running a clean build under
macOS 26 (Apple Silicon) and clicking around the chat panel for ~10s
reliably hits the crash. A minimal trigger isn't isolated yet, but
the key ingredients are:

- `defaultIsolation(MainActor.self)` swift setting
- swiftLanguageModes `.v6`
- An NSEvent monitor closure with a body that touches `@MainActor` state
- Sustained event firing (mouse motion across the bound region)

## Environment

- macOS: 26.3 (build 25D125)
- Hardware: Apple Silicon (Mac16,10 — MacBook Pro)
- Toolchain: Swift 6.2 (Xcode 26 / `swiftc --version` to confirm
  exact build at submission time)
- Architecture: arm64

## Behaviour with workaround

With the dyld interpose + hook constructor in place, the app runs
indefinitely on the same hardware with no crashes from this code
path across all the sites listed above. Reverting the workaround
reproduces the crashes within seconds of cursor motion or chat
interaction.

## Asks

1. Fix `swift_task_isMainExecutorImpl` /
   `swift_task_isCurrentExecutorWithFlagsImpl` so the executor
   metadata pointer it dereferences via `objc_msgSend` /
   `swift_getObjectType` is reliably valid under heap pressure.
2. If a fix isn't imminent, document
   `swift_task_isMainExecutor_hook` as a sanctioned override surface
   so apps can install correct replacements without dyld interpose
   tricks.
